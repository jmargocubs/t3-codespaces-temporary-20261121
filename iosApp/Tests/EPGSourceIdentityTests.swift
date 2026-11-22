import CryptoKit
import Security
import XCTest
@testable import Silo

final class EPGSourceIdentityTests: XCTestCase {
    private let fixedKey = Data(0..<32)

    // MARK: - Canonical encoding

    /// Golden values computed independently from the documented encoding.
    func testCanonicalEncodingMatchesTheSpecification() throws {
        let xmltv = EPGFeedSource.xmltv(URL(string: "HTTPS://User:Pa%40ss@EPG.Example.COM:443/Guide.xml?b=2&a=1#frag")!)
        let xtream = EPGFeedSource.xtream(server: " http://Panel.Example:8080/base/ ", username: "Al ice", password: "p&w=1")

        XCTAssertEqual(try EPGSourceIdentity.canonicalBytes(for: xmltv).hex,
                       "0000001b6b79726f2e6570672e736f757263652d66696e6765727072696e74010100000005687474707301000000"
                       + "04557365720100000007506125343073730000000f6570672e6578616d706c652e636f6d000000000000000a2f"
                       + "47756964652e786d6c0100000007623d3226613d31")
        XCTAssertEqual(try EPGSourceIdentity.canonicalBytes(for: xtream).hex,
                       "0000001b6b79726f2e6570672e736f757263652d66696e6765727072696e74010200000004687474700000000000"
                       + "0d70616e656c2e6578616d706c650000000438303830000000046261736500000006416c20696365000000057026"
                       + "773d31")

        let fingerprinter = makeFingerprinter(store: FakeKeyStore(key: fixedKey))
        XCTAssertEqual(try fingerprinter.fingerprint(for: xmltv).bytes.hex,
                       "640d10ca840a4b0cf1338898c757a49b295a6e389be27eb51ed25e3d51060a1b")
        XCTAssertEqual(try fingerprinter.fingerprint(for: xtream).bytes.hex,
                       "04ae7fef34feff563377435a3bf7a76365f7964b176bd2d5ffee9bf833e3ce72")
    }

    func testOnlyRequestPreservingURLRewritesShareAnIdentity() throws {
        func same(_ lhs: String, _ rhs: String, line: UInt = #line) throws {
            XCTAssertEqual(try xmltvBytes(lhs), try xmltvBytes(rhs), "\(lhs) vs \(rhs)", line: line)
        }
        func differs(_ lhs: String, _ rhs: String, line: UInt = #line) throws {
            XCTAssertNotEqual(try xmltvBytes(lhs), try xmltvBytes(rhs), "\(lhs) vs \(rhs)", line: line)
        }
        try same("HTTP://EPG.example.com/guide.xml", "http://epg.example.com/guide.xml")
        try same("http://epg.example.com:80/guide.xml", "http://epg.example.com/guide.xml")
        try same("https://epg.example.com:443/guide.xml", "https://epg.example.com/guide.xml")
        try same("http://epg.example.com", "http://epg.example.com/")
        try same("http://epg.example.com/guide.xml#now", "http://epg.example.com/guide.xml")

        try differs("http://epg.example.com/guide.xml?a=1&b=2", "http://epg.example.com/guide.xml?b=2&a=1")
        try differs("http://epg.example.com/guide.xml?", "http://epg.example.com/guide.xml")
        try differs("http://epg.example.com/%41.xml", "http://epg.example.com/A.xml")
        try differs("http://epg.example.com/Guide.xml", "http://epg.example.com/guide.xml")
        try differs("http://epg.example.com/guide/", "http://epg.example.com/guide")
        try differs("http://epg.example.com:8080/guide.xml", "http://epg.example.com/guide.xml")
        try differs("http://epg.example.com:443/guide.xml", "https://epg.example.com/guide.xml")
        try differs("http://epg.example.com/guide.xml?token=Abc", "http://epg.example.com/guide.xml?token=abc")
        try differs("http://User@epg.example.com/", "http://user@epg.example.com/")
        try differs("http://u:p@epg.example.com/", "http://u@epg.example.com/")
        try differs("http://u:@epg.example.com/", "http://u@epg.example.com/")
    }

    func testXtreamIdentityFollowsTheRequestItBuilds() throws {
        func bytes(_ server: String, _ user: String = "alice", _ password: String = "secret") throws -> Data {
            try EPGSourceIdentity.canonicalBytes(for: .xtream(server: server, username: user, password: password))
        }
        // These servers build the same xmltv.php request.
        let equivalent = ["http://panel.example/sub", " http://Panel.Example:80/sub/ ", "http://panel.example/sub?x=1#f",
                          "HTTP://panel.example//sub//"]
        for server in equivalent {
            XCTAssertEqual(try bytes(server), try bytes(equivalent[0]), server)
            XCTAssertEqual(try XtreamEPG.xmltvURL(server: server, username: "alice", password: "secret").path,
                           "/sub/xmltv.php", "the request path agrees with the identity: \(server)")
        }
        XCTAssertNotEqual(try bytes("http://panel.example/sub"), try bytes("http://panel.example/other"))
        XCTAssertNotEqual(try bytes("http://panel.example"), try bytes("http://panel.example:8080"))
        XCTAssertNotEqual(try bytes("http://panel.example"), try bytes("http://panel.example", "Alice"))
        XCTAssertNotEqual(try bytes("http://panel.example"), try bytes("http://panel.example", "alice", "Secret"))
        XCTAssertNotEqual(try bytes("http://panel.example"), try bytes("http://panel.example", "alice", " secret"))
        XCTAssertNotEqual(try bytes("http://panel.example", "ab", "c"), try bytes("http://panel.example", "a", "bc"),
                          "length prefixes keep field boundaries")
        XCTAssertNotEqual(try bytes("http://panel.example", "a", "b"), try bytes("http://panel.example", "a", "b\0"))

        let url = try XtreamEPG.xmltvURL(server: "http://panel.example", username: "alice", password: "secret")
        XCTAssertNotEqual(try bytes("http://panel.example"), try EPGSourceIdentity.canonicalBytes(for: .xmltv(url)),
                          "the kind is part of the identity")
    }

    func testInvalidSourcesHaveNoIdentity() {
        let invalid: [EPGFeedSource] = [
            .xmltv(URL(string: "ftp://epg.example.com/guide.xml")!),
            .xmltv(URL(string: "file:///tmp/guide.xml")!),
            .xmltv(URL(string: "http:///guide.xml")!),
            .xtream(server: "panel.example", username: "alice", password: "secret"),
            .xtream(server: "http://panel.example", username: "", password: "secret"),
        ]
        for source in invalid {
            XCTAssertThrowsError(try EPGSourceIdentity.canonicalBytes(for: source)) {
                XCTAssertEqual($0 as? EPGError, .invalidSource)
            }
        }
    }

    // MARK: - Fingerprints and provider changes

    func testChangedProvidersAreDetectedAndUnchangedOnesMatch() throws {
        let fingerprinter = makeFingerprinter(store: FakeKeyStore(key: fixedKey))
        let original = EPGFeedSource.xtream(server: "http://panel.example", username: "alice", password: "secret")
        let stored = try fingerprinter.fingerprint(for: original).bytes

        XCTAssertEqual(fingerprinter.check(stored: stored, against: original), .matches)
        XCTAssertEqual(fingerprinter.check(stored: stored, against: .xtream(server: "HTTP://Panel.example:80/",
                                                                             username: "alice", password: "secret")),
                       .matches, "an equivalent server spelling keeps the guide")
        XCTAssertEqual(fingerprinter.check(stored: stored, against: .xtream(server: "http://panel.example",
                                                                             username: "alice", password: "rotated")),
                       .changed, "a new password is a new source")
        XCTAssertEqual(fingerprinter.check(stored: stored, against: .xtream(server: "http://mirror.example",
                                                                             username: "alice", password: "secret")),
                       .changed)
        XCTAssertEqual(fingerprinter.check(stored: stored.dropLast(), against: original), .changed, "malformed value")
        XCTAssertEqual(fingerprinter.check(stored: stored, against: .xtream(server: "panel", username: "alice",
                                                                             password: "secret")),
                       .changed, "an invalid source matches nothing")
    }

    func testFeedSourceDescriptionsRevealNoCredentialsOrURLSecrets() throws {
        let xmltv = EPGFeedSource.xmltv(URL(string: "https://alice:s3cret-pass@guide.example/xmltv.php?token=private-token&password=hunter2#frag")!)
        let xtream = EPGFeedSource.xtream(server: "http://panel.example:8080/live", username: "alice",
                                          password: "s3cret-pass")
        let secrets = ["alice", "s3cret-pass", "private-token", "hunter2", "guide.example", "panel.example",
                       "xmltv.php", "8080"]
        for source in [xmltv, xtream] {
            let rendered = [String(describing: source), String(reflecting: source), source.description, source.debugDescription]
            XCTAssertEqual(Set(rendered).count, 1)
            let text = rendered[0]
            XCTAssertTrue(text == "EPGFeedSource.xmltv(redacted)" || text == "EPGFeedSource.xtream(redacted)")
            for secret in secrets { XCTAssertFalse(text.contains(secret), text) }
            let reflected = Mirror(reflecting: source).children.map { String(describing: $0.value) }.joined()
            XCTAssertTrue(reflected.isEmpty)
            for secret in secrets { XCTAssertFalse(reflected.contains(secret)) }
        }
    }

    func testFingerprintsRevealNoSourceDetails() throws {
        let fingerprinter = makeFingerprinter(store: FakeKeyStore(key: fixedKey))
        let source = EPGFeedSource.xtream(server: "http://panel.example", username: "alice", password: "secret")
        let fingerprint = try fingerprinter.fingerprint(for: source)
        XCTAssertEqual(fingerprint.bytes.count, 32)
        XCTAssertEqual(String(describing: fingerprint), "EPGSourceFingerprint(redacted)")
        XCTAssertEqual("\(fingerprint)", "EPGSourceFingerprint(redacted)")
        for secret in ["alice", "secret", "panel.example"] {
            XCTAssertNil(fingerprint.bytes.range(of: Data(secret.utf8)))
        }
        XCTAssertNotEqual(fingerprint.bytes, Data(SHA256.hash(data: try EPGSourceIdentity.canonicalBytes(for: source))),
                          "keyed, not a plain hash")
        let otherDevice = makeFingerprinter(store: FakeKeyStore(key: Data(repeating: 7, count: 32)))
        XCTAssertNotEqual(try otherDevice.fingerprint(for: source), fingerprint)
    }

    // MARK: - Key lifecycle

    func testKeyIsCreatedOnlyWhenConfirmedAbsentAndThenReused() throws {
        let store = FakeKeyStore(key: nil)
        let fingerprinter = makeFingerprinter(store: store)
        let first = try fingerprinter.fingerprint(for: sampleSource)
        XCTAssertEqual(store.adds, 1)
        XCTAssertEqual(store.key?.count, 32)
        let readsAfterCreate = store.reads
        XCTAssertEqual(try fingerprinter.fingerprint(for: sampleSource), first)
        XCTAssertEqual(store.reads, readsAfterCreate, "the key is cached after a successful load")

        let relaunched = makeFingerprinter(store: store)
        XCTAssertEqual(try relaunched.fingerprint(for: sampleSource), first, "the key persists across launches")
        XCTAssertEqual(store.adds, 1)
    }

    func testTemporaryKeychainFailuresNeverCreateOrReplaceAKey() throws {
        for status in [errSecInteractionNotAllowed, errSecMissingEntitlement, errSecNotAvailable, errSecAuthFailed] {
            let store = FakeKeyStore(key: fixedKey)
            store.readStatus = status
            let fingerprinter = makeFingerprinter(store: store)
            XCTAssertThrowsError(try fingerprinter.fingerprint(for: sampleSource)) {
                XCTAssertEqual($0 as? EPGSourceIdentityError, .keyUnavailable)
            }
            XCTAssertEqual(fingerprinter.check(stored: Data(count: 32), against: sampleSource), .unavailable,
                           "a locked Keychain never reports a changed source (\(status))")
            XCTAssertEqual(store.adds, 0)
            XCTAssertEqual(store.deletes, 0)
            XCTAssertEqual(store.key, fixedKey)

            store.readStatus = nil
            let expected = try makeFingerprinter(store: FakeKeyStore(key: fixedKey)).fingerprint(for: sampleSource)
            XCTAssertEqual(try fingerprinter.fingerprint(for: sampleSource), expected,
                           "the original key is used once the Keychain is readable (\(status))")
        }
    }

    func testFailedCreationIsRetriedWithoutASecondKey() throws {
        let store = FakeKeyStore(key: nil)
        store.addStatus = errSecInteractionNotAllowed
        let fingerprinter = makeFingerprinter(store: store)
        XCTAssertThrowsError(try fingerprinter.fingerprint(for: sampleSource))
        XCTAssertNil(store.key)

        // Saved, but the read-back fails: not used until it can be confirmed.
        store.addStatus = nil
        store.readStatusAfterAdd = errSecInteractionNotAllowed
        XCTAssertThrowsError(try fingerprinter.fingerprint(for: sampleSource))
        let saved = try XCTUnwrap(store.key)

        store.readStatus = nil
        let fingerprint = try fingerprinter.fingerprint(for: sampleSource)
        XCTAssertEqual(store.key, saved, "the saved key is adopted, not replaced")
        XCTAssertEqual(store.adds, 2, "one failed and one successful add")
        XCTAssertEqual(fingerprint, try makeFingerprinter(store: FakeKeyStore(key: saved)).fingerprint(for: sampleSource))
    }

    func testConcurrentCreatorKeepsTheKeyThatWonTheRace() throws {
        let store = FakeKeyStore(key: nil)
        store.keyWrittenByAnotherCaller = Data(repeating: 9, count: 32)
        let fingerprint = try makeFingerprinter(store: store).fingerprint(for: sampleSource)
        XCTAssertEqual(store.key, Data(repeating: 9, count: 32))
        XCTAssertEqual(fingerprint, try makeFingerprinter(store: FakeKeyStore(key: Data(repeating: 9, count: 32)))
            .fingerprint(for: sampleSource))
    }

    func testMalformedStoredKeyIsReplacedButOnlyWhenDeletable() throws {
        let store = FakeKeyStore(key: Data(repeating: 1, count: 16))
        store.deleteStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try makeFingerprinter(store: store).fingerprint(for: sampleSource))
        XCTAssertEqual(store.adds, 0)

        store.deleteStatus = nil
        _ = try makeFingerprinter(store: store).fingerprint(for: sampleSource)
        XCTAssertEqual(store.key?.count, 32)
        XCTAssertEqual(store.adds, 1)
    }

    func testMissingRandomnessLeavesTheKeyUnavailable() {
        let store = FakeKeyStore(key: nil)
        let fingerprinter = EPGSourceFingerprinter(keys: EPGFingerprintKeyProvider(store: store, randomBytes: { _ in nil }))
        XCTAssertThrowsError(try fingerprinter.fingerprint(for: sampleSource))
        XCTAssertEqual(store.adds, 0)
    }

    func testKeyResetInvalidatesEveryFingerprintOnce() throws {
        let store = FakeKeyStore(key: nil)
        let keys = EPGFingerprintKeyProvider(store: store)
        let fingerprinter = EPGSourceFingerprinter(keys: keys)
        let before = try fingerprinter.fingerprint(for: sampleSource).bytes

        store.deleteStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try keys.resetKey())
        store.deleteStatus = nil
        try keys.resetKey()
        XCTAssertEqual(fingerprinter.check(stored: before, against: sampleSource), .changed)
        let after = try fingerprinter.fingerprint(for: sampleSource).bytes
        XCTAssertEqual(fingerprinter.check(stored: after, against: sampleSource), .matches)
        XCTAssertEqual(store.adds, 2)
    }

    // MARK: - Keychain

    func testKeychainStoreAddsWithoutOverwritingUsingThisDeviceOnlyAccessibility() throws {
        let store = KeychainEPGFingerprintKeyStore(service: "com.cubbiestream.kyro.tests.epg-key.\(UUID().uuidString)")
        defer { try? store.deleteKey() }
        XCTAssertNil(try store.readKey())
        try store.addKey(fixedKey)
        XCTAssertEqual(try store.readKey(), fixedKey)
        XCTAssertThrowsError(try store.addKey(Data(repeating: 2, count: 32))) {
            XCTAssertEqual($0 as? EPGKeyStoreError, EPGKeyStoreError(status: errSecDuplicateItem))
        }
        XCTAssertEqual(try store.readKey(), fixedKey, "an existing key is never overwritten")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: store.service,
            kSecAttrAccount as String: KeychainEPGFingerprintKeyStore.account,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

        try store.deleteKey()
        XCTAssertNil(try store.readKey())
        XCTAssertNoThrow(try store.deleteKey(), "deleting a missing key succeeds")

        let fingerprinter = EPGSourceFingerprinter(keys: EPGFingerprintKeyProvider(store: store))
        let first = try fingerprinter.fingerprint(for: sampleSource)
        let relaunched = EPGSourceFingerprinter(keys: EPGFingerprintKeyProvider(store: store))
        XCTAssertEqual(try relaunched.fingerprint(for: sampleSource), first)
    }

    // MARK: - Helpers

    private let sampleSource = EPGFeedSource.xmltv(URL(string: "https://epg.example.com/guide.xml")!)

    private func makeFingerprinter(store: FakeKeyStore) -> EPGSourceFingerprinter {
        EPGSourceFingerprinter(keys: EPGFingerprintKeyProvider(store: store))
    }

    private func xmltvBytes(_ url: String) throws -> Data {
        try EPGSourceIdentity.canonicalBytes(for: .xmltv(try XCTUnwrap(URL(string: url))))
    }
}

/// An in-memory key store with injectable Keychain statuses.
private final class FakeKeyStore: EPGFingerprintKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedKey: Data?
    private var counts = (reads: 0, adds: 0, deletes: 0)
    private var statuses: (read: OSStatus?, readAfterAdd: OSStatus?, add: OSStatus?, delete: OSStatus?)
    private var racingKey: Data?

    init(key: Data?) { storedKey = key }

    var key: Data? { lock.withLock { storedKey } }
    var reads: Int { lock.withLock { counts.reads } }
    var adds: Int { lock.withLock { counts.adds } }
    var deletes: Int { lock.withLock { counts.deletes } }
    var readStatus: OSStatus? {
        get { lock.withLock { statuses.read } }
        set { lock.withLock { statuses.read = newValue } }
    }
    /// Applied to reads after the next successful add, then kept as `readStatus`.
    var readStatusAfterAdd: OSStatus? {
        get { lock.withLock { statuses.readAfterAdd } }
        set { lock.withLock { statuses.readAfterAdd = newValue } }
    }
    var addStatus: OSStatus? {
        get { lock.withLock { statuses.add } }
        set { lock.withLock { statuses.add = newValue } }
    }
    var deleteStatus: OSStatus? {
        get { lock.withLock { statuses.delete } }
        set { lock.withLock { statuses.delete = newValue } }
    }
    /// Simulates another caller adding a key between this caller's read and add.
    var keyWrittenByAnotherCaller: Data? {
        get { lock.withLock { racingKey } }
        set { lock.withLock { racingKey = newValue } }
    }

    func readKey() throws -> Data? {
        try lock.withLock {
            counts.reads += 1
            if let status = statuses.read { throw EPGKeyStoreError(status: status) }
            return storedKey
        }
    }

    func addKey(_ key: Data) throws {
        try lock.withLock {
            counts.adds += 1
            if let racingKey {
                storedKey = racingKey
                self.racingKey = nil
            }
            if let status = statuses.add { throw EPGKeyStoreError(status: status) }
            guard storedKey == nil else { throw EPGKeyStoreError(status: errSecDuplicateItem) }
            storedKey = key
            if let after = statuses.readAfterAdd {
                statuses.read = after
                statuses.readAfterAdd = nil
            }
        }
    }

    func deleteKey() throws {
        try lock.withLock {
            counts.deletes += 1
            if let status = statuses.delete { throw EPGKeyStoreError(status: status) }
            storedKey = nil
        }
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
