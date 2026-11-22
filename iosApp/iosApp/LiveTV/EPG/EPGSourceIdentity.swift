import CryptoKit
import Foundation
import Security

/// A keyed fingerprint of where a guide came from, stored in the cache header so a guide is never
/// shown for a different source. It is HMAC-SHA256 under a per-device Keychain key, so the URL and
/// credentials it covers can't be recovered or brute-forced from a disk image or backup.
struct EPGSourceFingerprint: Equatable, Sendable, CustomStringConvertible {
    static let length = 32

    let bytes: Data

    var description: String { "EPGSourceFingerprint(redacted)" }
}

/// Whether a stored fingerprint still describes the current source.
enum EPGSourceIdentityCheck: Equatable, Sendable {
    case matches
    /// The source changed, the stored value is malformed, or the current source is invalid.
    case changed
    /// The key can't be read right now. Keep the cache but don't show it; never treat it as changed.
    case unavailable
}

enum EPGSourceIdentityError: Error, Equatable, Sendable {
    case keyUnavailable
}

/// The exact bytes a source's fingerprint covers. Never log or persist them: they hold the URL and
/// any credentials verbatim.
///
/// Version 1 encoding:
///
///     message  = field("kyro.epg.source-fingerprint") || u8(1) || u8(kind) || fields...
///     field(b) = u32 big-endian byte length || b
///     opt(b)   = u8(0) when absent, else u8(1) || field(b)
///     xmltv  (kind 1): scheme, opt(user), opt(password), host, port, path, opt(query)
///     xtream (kind 2): scheme, opt(user), opt(password), host, port, basePath, username, password
///
/// Only rewrites that leave the request unchanged are applied: scheme and host are lowercased, a
/// default port (80 for http, 443 for https) becomes empty, an empty XMLTV path becomes `/`, and
/// the fragment, which is never sent, is dropped. Paths, queries, percent-encoding, parameter order
/// and credentials are kept byte for byte. Xtream fields follow `XtreamEPG.xmltvURL` exactly: the
/// server's query and fragment are replaced there, its base path is slash-trimmed, and username
/// and password are sent as given. Changing any rule requires a new version, which changes every
/// fingerprint once.
enum EPGSourceIdentity {
    static let version: UInt8 = 1
    private static let domain = Data("kyro.epg.source-fingerprint".utf8)

    static func canonicalBytes(for source: EPGFeedSource) throws -> Data {
        var message = Data()
        message.appendField(domain)
        message.append(version)
        switch source {
        case .xmltv(let url):
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let endpoint = Endpoint(components) else { throw EPGError.invalidSource }
            message.append(1)
            endpoint.append(to: &message)
            message.appendField(Data((components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath).utf8))
            message.appendOptionalField(components.percentEncodedQuery.map { Data($0.utf8) })
        case let .xtream(server, username, password):
            guard let components = URLComponents(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let endpoint = Endpoint(components), !username.isEmpty else { throw EPGError.invalidSource }
            message.append(2)
            endpoint.append(to: &message)
            message.appendField(Data(components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).utf8))
            message.appendField(Data(username.utf8))
            message.appendField(Data(password.utf8))
        }
        return message
    }

    /// Scheme, userinfo, host and port, shared by both kinds.
    private struct Endpoint {
        let scheme: String
        let user: String?
        let password: String?
        let host: String
        let port: String

        init?(_ components: URLComponents) {
            guard let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = components.percentEncodedHost, !host.isEmpty else { return nil }
            let defaultPort = scheme == "http" ? 80 : 443
            self.scheme = scheme
            user = components.percentEncodedUser
            password = components.percentEncodedPassword
            self.host = host.lowercased()
            port = components.port.map { $0 == defaultPort ? "" : String($0) } ?? ""
        }

        func append(to message: inout Data) {
            message.appendField(Data(scheme.utf8))
            message.appendOptionalField(user.map { Data($0.utf8) })
            message.appendOptionalField(password.map { Data($0.utf8) })
            message.appendField(Data(host.utf8))
            message.appendField(Data(port.utf8))
        }
    }
}

/// Computes and checks source fingerprints. Synchronous Keychain access on first use: call it from
/// a nonisolated async context, never the main actor.
struct EPGSourceFingerprinter: Sendable {
    let keys: EPGFingerprintKeyProvider

    init(keys: EPGFingerprintKeyProvider = EPGFingerprintKeyProvider()) {
        self.keys = keys
    }

    func fingerprint(for source: EPGFeedSource) throws -> EPGSourceFingerprint {
        let message = try EPGSourceIdentity.canonicalBytes(for: source)
        let code = HMAC<SHA256>.authenticationCode(for: message, using: try keys.key())
        return EPGSourceFingerprint(bytes: Data(code))
    }

    /// Compares in constant time. A Keychain failure is `unavailable`, never `changed`, so a locked
    /// device can't cause a valid guide to be discarded.
    func check(stored: Data, against source: EPGFeedSource) -> EPGSourceIdentityCheck {
        guard stored.count == EPGSourceFingerprint.length,
              let message = try? EPGSourceIdentity.canonicalBytes(for: source) else { return .changed }
        guard let key = try? keys.key() else { return .unavailable }
        return HMAC<SHA256>.isValidAuthenticationCode(stored, authenticating: message, using: key) ? .matches : .changed
    }
}

/// The per-device fingerprint key, created once and then only read.
///
/// A key is generated only after the store confirms none exists. Any other read failure, such as a
/// locked device or a missing entitlement, leaves the key unavailable until a later attempt
/// succeeds; creating a replacement then would silently orphan every cached guide. A stored item
/// of the wrong length can never become valid, so it is replaced, which invalidates every guide
/// once. A new key is read back before use. Thread-safe; failures are not cached.
final class EPGFingerprintKeyProvider: @unchecked Sendable {
    static let keyLength = 32

    private let store: any EPGFingerprintKeyStoring
    private let randomBytes: @Sendable (Int) -> Data?
    private let lock = NSLock()
    private var cached: SymmetricKey?

    init(store: any EPGFingerprintKeyStoring = KeychainEPGFingerprintKeyStore(),
         randomBytes: @escaping @Sendable (Int) -> Data? = { EPGFingerprintKeyProvider.secureRandomBytes($0) }) {
        self.store = store
        self.randomBytes = randomBytes
    }

    func key() throws -> SymmetricKey {
        try lock.withLock {
            if let cached { return cached }
            let key = try loadOrCreate()
            cached = key
            return key
        }
    }

    /// Replaces the key. Every existing fingerprint stops matching, so every cached guide is
    /// discarded once.
    func resetKey() throws {
        try lock.withLock {
            cached = nil
            do { try store.deleteKey() } catch { throw EPGSourceIdentityError.keyUnavailable }
        }
    }

    private func loadOrCreate() throws -> SymmetricKey {
        let existing: Data?
        do { existing = try store.readKey() } catch { throw EPGSourceIdentityError.keyUnavailable }
        if let existing {
            if existing.count == Self.keyLength { return SymmetricKey(data: existing) }
            do { try store.deleteKey() } catch { throw EPGSourceIdentityError.keyUnavailable }
        }
        guard let fresh = randomBytes(Self.keyLength), fresh.count == Self.keyLength else {
            throw EPGSourceIdentityError.keyUnavailable
        }
        do {
            try store.addKey(fresh)
        } catch let error as EPGKeyStoreError where error.status == errSecDuplicateItem {
            // Another caller created it first; use theirs.
        } catch {
            throw EPGSourceIdentityError.keyUnavailable
        }
        guard let saved = try? store.readKey(), saved.count == Self.keyLength else {
            throw EPGSourceIdentityError.keyUnavailable
        }
        return SymmetricKey(data: saved)
    }

    static func secureRandomBytes(_ count: Int) -> Data? {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return status == errSecSuccess ? bytes : nil
    }
}

/// Raw Keychain access for the fingerprint key, separated so tests can inject failures.
protocol EPGFingerprintKeyStoring: Sendable {
    /// Nil only when the store confirms no item exists.
    func readKey() throws -> Data?
    /// Adds without overwriting; an existing item throws `errSecDuplicateItem`.
    func addKey(_ key: Data) throws
    /// Succeeds when no item exists.
    func deleteKey() throws
}

struct EPGKeyStoreError: Error, Equatable, Sendable {
    let status: OSStatus
}

/// The key as a generic password in the default access group, readable after the first
/// unlock since boot and never migrated to another device (`AfterFirstUnlockThisDeviceOnly`).
/// On iOS/tvOS the query omits `kSecAttrAccessGroup`, so the item lands in the first configured
/// group, currently `com.cubbiestream.kyro.shared`; Top Shelf and Notification Service entitlements
/// also include that group, though neither extension reads this item. Stage C intentionally keeps
/// that existing shared-group policy. `EPGFeedSource` redacts its description so a later
/// diagnostic can name the source kind without a URL, username, or password.
/// That matches the guide files' protection, so a background launch after first unlock can read
/// both, while a backup restored elsewhere gets a new key and refetches its guides. On macOS it uses
/// the data protection keychain, the only one that honours this accessibility; a build without a
/// keychain entitlement reads as unavailable, which disables cached guides rather than weakening
/// the key.
struct KeychainEPGFingerprintKeyStore: EPGFingerprintKeyStoring {
    static let defaultService = KyroAppIdentity.current.epgKeyKeychainService
    static let account = "hmac-sha256-v1"

    let service: String

    init(service: String = KeychainEPGFingerprintKeyStore.defaultService) {
        self.service = service
    }

    func readKey() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw EPGKeyStoreError(status: errSecDecode) }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw EPGKeyStoreError(status: status)
        }
    }

    func addKey(_ key: Data) throws {
        var query = baseQuery()
        query[kSecValueData as String] = key
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw EPGKeyStoreError(status: status) }
    }

    func deleteKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw EPGKeyStoreError(status: status) }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

private extension Data {
    mutating func appendField(_ bytes: Data) {
        Swift.withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { append(contentsOf: $0) }
        append(bytes)
    }

    mutating func appendOptionalField(_ bytes: Data?) {
        guard let bytes else { return append(0) }
        append(1)
        appendField(bytes)
    }
}
