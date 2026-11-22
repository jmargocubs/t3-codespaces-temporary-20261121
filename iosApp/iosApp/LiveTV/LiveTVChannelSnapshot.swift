import Foundation

/// A deliberately allow-listed on-disk representation. In particular, it has no URL fields.
struct LiveTVChannelSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    struct Entry: Codable, Equatable, Sendable {
        let id: String
        let guideID: String?
        let name: String
        let category: String
    }
    let version: Int
    let providerID: UUID
    let savedAt: Date
    let channels: [Entry]

    init(providerID: UUID, channels: [LiveTVChannel], savedAt: Date = .now,
         secrets: LiveTVSnapshotSecrets = LiveTVSnapshotSecrets()) {
        version = Self.currentVersion
        self.providerID = providerID
        self.savedAt = savedAt
        self.channels = Self.safeEntries(providerID: providerID, entries: channels.map {
            Entry(id: $0.id, guideID: $0.guideID, name: $0.name, category: $0.category)
        }, secrets: secrets)
    }

    func sanitized(secrets: LiveTVSnapshotSecrets = LiveTVSnapshotSecrets()) -> Self {
        Self(version: version, providerID: providerID, savedAt: savedAt,
             channels: Self.safeEntries(providerID: providerID, entries: channels, secrets: secrets))
    }

    private init(version: Int, providerID: UUID, savedAt: Date, channels: [Entry]) {
        self.version = version
        self.providerID = providerID
        self.savedAt = savedAt
        self.channels = channels
    }

    /// Entries whose identity and every persisted field pass the redaction policy. Unsafe entries
    /// are dropped whole rather than edited, so a stored channel never changes identity or guide match.
    private static func safeEntries(providerID: UUID, entries: [Entry], secrets: LiveTVSnapshotSecrets) -> [Entry] {
        var seen = Set<String>()
        return entries.filter { entry in
            let digest = entry.id.dropFirst(providerID.uuidString.count + 1)
            guard entry.id.utf8.count == providerID.uuidString.utf8.count + 1 + 64,
                  entry.id.hasPrefix("\(providerID.uuidString):"),
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  LiveTVSnapshotRedaction.isSafe(entry.name, maximumBytes: 256, secrets: secrets),
                  LiveTVSnapshotRedaction.isSafe(entry.category, maximumBytes: 128, secrets: secrets),
                  entry.guideID.map({ LiveTVSnapshotRedaction.isSafe($0, maximumBytes: 256, secrets: secrets) }) ?? true
            else { return false }
            return seen.insert(entry.id).inserted
        }
    }

    func materialize() -> [LiveTVChannel] {
        channels.map { entry in
            // Cached rows are browseable, not playable. Never retain a stream address on disk.
            LiveTVChannel(id: entry.id, guideID: entry.guideID, name: entry.name,
                          streamURL: URL(string: "about:blank")!, logoURL: nil, category: entry.category)
        }
    }
}

/// Cached channels ready to show: browseable rows plus their ordered categories.
struct LiveTVCachedCatalog: Sendable {
    let channels: [LiveTVChannel]
    let categories: [String]
    /// True when import stopped at the channel cap with more playlist/stream entries remaining.
    /// Offline snapshot restores leave this false; they never invent a remote total.
    let hitChannelLimit: Bool

    init(channels: [LiveTVChannel], categories: [String], hitChannelLimit: Bool = false) {
        self.channels = channels
        self.categories = categories
        self.hitChannelLimit = hitChannelLimit
    }
}

/// Outcome of a snapshot write. Failed or refused writes leave any prior valid file untouched.
enum LiveTVChannelSnapshotSaveResult: Equatable, Sendable {
    case saved
    case refusedOverChannelLimit
    case refusedOverFileLimit
    case writeFailed
}

/// Soft catalog notices that must not be confused with hard import failures such as an oversized download.
enum LiveTVCatalogNotice {
    /// Shown when M3U or Xtream import stops at the configured channel cap. Does not claim a total.
    static func channelLimitReached(limit: Int) -> String {
        let formatted = limit.formatted(.number.grouping(.automatic))
        return "Import stopped at the \(formatted) channel limit. Additional channels were not imported."
    }
}

/// Reads and writes channel snapshots off the main actor. Calls run one at a time, so a removal is
/// never overtaken by a write that was already running.
actor LiveTVChannelSnapshotStore {
    static let maximumChannels = LiveTVCatalogLimits.maximumChannels
    /// About 250 bytes per channel entry: 40,000 channels need roughly 10 MB.
    static let maximumFileBytes = 32 * 1024 * 1024
    nonisolated let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Silo/LiveTV/Channels", isDirectory: true)
    }

    func load(providerID: UUID, secrets: LiveTVSnapshotSecrets = LiveTVSnapshotSecrets()) -> LiveTVChannelSnapshot? {
        let url = file(providerID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumFileBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let snapshot = try? JSONDecoder().decode(LiveTVChannelSnapshot.self, from: data),
              snapshot.version == LiveTVChannelSnapshot.currentVersion,
              snapshot.providerID == providerID, snapshot.channels.count <= Self.maximumChannels else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let safeSnapshot = snapshot.sanitized(secrets: secrets)
        if safeSnapshot.channels != snapshot.channels {
            try? FileManager.default.removeItem(at: url)
            save(safeSnapshot)
        }
        return safeSnapshot
    }

    func loadCatalog(providerID: UUID, secrets: LiveTVSnapshotSecrets = LiveTVSnapshotSecrets()) -> LiveTVCachedCatalog? {
        guard let snapshot = load(providerID: providerID, secrets: secrets), !snapshot.channels.isEmpty else { return nil }
        let channels = snapshot.materialize()
        return LiveTVCachedCatalog(channels: channels, categories: LiveTVChannel.orderedCategories(of: channels))
    }

    @discardableResult
    func save(providerID: UUID, channels: [LiveTVChannel], secrets: LiveTVSnapshotSecrets = LiveTVSnapshotSecrets()) -> LiveTVChannelSnapshotSaveResult {
        save(LiveTVChannelSnapshot(providerID: providerID, channels: channels,
                                   secrets: secrets))
    }

    /// Writes a new snapshot only when it validates. Over-limit, oversized, or failed writes leave
    /// the previous valid file in place so offline restore keeps working. Explicit `remove` and
    /// load-time rejection of corrupt or wrong-provider files are unchanged.
    @discardableResult
    func save(_ snapshot: LiveTVChannelSnapshot) -> LiveTVChannelSnapshotSaveResult {
        guard snapshot.version == LiveTVChannelSnapshot.currentVersion else { return .writeFailed }
        guard snapshot.channels.count <= Self.maximumChannels else { return .refusedOverChannelLimit }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot.sanitized())
            guard data.count <= Self.maximumFileBytes else { return .refusedOverFileLimit }
            try data.write(to: file(snapshot.providerID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return .saved
        } catch {
            // Leave any prior valid snapshot alone; browsing and playback must not depend on this write.
            return .writeFailed
        }
    }

    func remove(providerID: UUID) { try? FileManager.default.removeItem(at: file(providerID)) }

    private func file(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
}

extension LiveTVChannel {
    /// The one category order used for both cached and refreshed channels.
    nonisolated static func orderedCategories(of channels: [LiveTVChannel]) -> [String] {
        Array(Set(channels.map(\.category))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Provider credentials and endpoints that must never reach a snapshot. Each kind is matched in a
/// way that blocks real leaks without dropping ordinary channel names.
struct LiveTVSnapshotSecrets: Sendable, Equatable {
    /// Matched anywhere in a field; a password is never legitimate channel metadata.
    var passwords: [String] = []
    /// Matched in credential positions (`/user/`, `user:`, `user@`, `=user`), or as the whole
    /// field or a substring when the username looks like an account identifier rather than a word.
    var usernames: [String] = []
    /// Provider hosts and opaque tokens taken from the provider's own URLs.
    var endpoints: [String] = []

    init(passwords: [String] = [], usernames: [String] = [], endpoints: [String] = []) {
        self.passwords = passwords.filter { !$0.isEmpty }
        self.usernames = usernames.filter { !$0.isEmpty }
        self.endpoints = endpoints.filter { !$0.isEmpty }
    }

    /// Credentials, hosts and sensitive query or path values from a provider's configuration.
    /// Generic query values such as `m3u_plus` or `mpegts` are not secrets and are left out.
    init(source: LiveTVSourceConfiguration) {
        var passwords = [source.password].compactMap { $0 }
        var usernames = [source.username].compactMap { $0 }
        var endpoints: [String] = []
        for address in [source.playlistURL, source.xmltvURL, source.serverURL].compactMap({ $0 }) {
            guard let components = URLComponents(string: address) else { continue }
            usernames.append(contentsOf: [components.user].compactMap { $0 })
            passwords.append(contentsOf: [components.password].compactMap { $0 })
            if let host = components.host, host.contains(".") || host.contains(":") { endpoints.append(host) }
            for item in components.queryItems ?? [] {
                guard let value = item.value, !value.isEmpty else { continue }
                switch LiveTVSnapshotRedaction.queryKeyKind(item.name) {
                case .username: usernames.append(value)
                case .password: passwords.append(value)
                case .secret: endpoints.append(value)
                case .other where LiveTVSnapshotRedaction.looksOpaque(value): endpoints.append(value)
                case .other: break
                }
            }
            endpoints.append(contentsOf: components.path.split(separator: "/").map(String.init)
                .filter(LiveTVSnapshotRedaction.looksOpaque))
        }
        self.init(passwords: passwords, usernames: usernames, endpoints: endpoints)
    }
}

/// The snapshot's metadata policy: short display text and opaque guide identifiers only. Values are
/// checked as stored and after up to two layers of percent-decoding, so an encoded URL or
/// credential cannot slip through. Rejected values are never logged.
enum LiveTVSnapshotRedaction {
    static func isSafe(_ value: String, maximumBytes: Int, secrets: LiveTVSnapshotSecrets = LiveTVSnapshotSecrets()) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumBytes else { return false }
        return decodedForms(of: value).allSatisfy { form in
            !form.unicodeScalars.contains(where: isForbiddenScalar)
                && !unsafeExpressions.contains { $0.firstMatch(in: form, range: NSRange(form.startIndex..., in: form)) != nil }
                && !containsSecret(form, secrets: secrets)
        }
    }

    /// The value itself plus up to two percent-decoded layers, with `+` read as a space. Each valid
    /// `%XX` is decoded and a stray `%` is kept as text, so `100% https%3A%2F%2F…` cannot hide a URL
    /// behind a malformed sequence.
    static func decodedForms(of value: String) -> [String] {
        var forms = [value]
        var current = value
        for _ in 0..<2 {
            guard current.contains("%") || current.contains("+") else { break }
            let decoded = lenientlyDecoded(current)
            guard decoded != current else { break }
            forms.append(decoded)
            current = decoded
        }
        return forms
    }

    private static func lenientlyDecoded(_ value: String) -> String {
        let bytes = Array(value.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "%"), index + 2 < bytes.count,
               let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                output.append(high << 4 | low)
                index += 3
            } else {
                output.append(byte == UInt8(ascii: "+") ? UInt8(ascii: " ") : byte)
                index += 1
            }
        }
        // Invalid UTF-8 becomes U+FFFD: still checkable, never trusted as the stored value.
        return String(decoding: output, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// C0/C1 controls and the bidirectional embedding, override and isolate controls that can
    /// disguise text. Zero-width joiners, non-joiners and directional marks are ordinary text in
    /// emoji, Persian, Arabic and Hebrew names, so they stay allowed.
    private static func isForbiddenScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control
            || (0x202A...0x202E).contains(scalar.value)
            || (0x2066...0x2069).contains(scalar.value)
    }

    private static let unsafeExpressions: [NSRegularExpression] = [
        // Any scheme URL, and bare web or IP endpoints with a path.
        #"(?i)\b[a-z][a-z0-9+.-]*://"#,
        #"(?i)\bwww\.[a-z0-9-]+\.[a-z]"#,
        #"(?i)\b[a-z0-9.-]+\.[a-z]{2,}(?::\d{2,5})?/"#,
        #"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d{2,5})?(?:/|\b)"#,
        // Credentials written as `key: value` or `key=value`.
        #"(?i)(?:^|[?&;\s])(?:user(?:name)?|pass(?:word)?|passwd|pwd|token|auth|authorization|api[_-]?key|access[_-]?key|secret)\s*[:=]"#,
        // Signed or authenticated query parameters: `stream.m3u8?sig=…`, `&token=…`, `?st=…&e=…`.
        #"(?i)[?&;](?:sig|signature|hmac|hash|token|auth|key|session|sid|jwt|expires|exp|st|e|policy|key-pair-id|x-amz-[a-z-]+)="#,
        #"(?i)\.[a-z0-9]{2,5}\?[^\s]*="#,
        // Authorization schemes and JSON Web Tokens.
        #"(?i)\b(?:bearer|basic)\s+[a-z0-9._~+/=-]{8,}"#,
        #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static func containsSecret(_ text: String, secrets: LiveTVSnapshotSecrets) -> Bool {
        if secrets.passwords.contains(where: { password in
            password.count < 4 ? text.caseInsensitiveCompare(password) == .orderedSame
                               : text.range(of: password, options: .caseInsensitive) != nil
        }) { return true }
        if secrets.endpoints.contains(where: { endpoint in
            endpoint.count < 6 ? text.caseInsensitiveCompare(endpoint) == .orderedSame
                               : text.range(of: endpoint, options: .caseInsensitive) != nil
        }) { return true }
        return secrets.usernames.contains { username in
            guard username.count >= 3 else { return false }
            let escaped = NSRegularExpression.escapedPattern(for: username)
            // `/user/`, `user:pass`, `user@host`, `=user`: the username as part of a credential.
            let credential = #"(?i)(?:[/=@:]"# + escaped + #"(?:[/:@&]|$))|(?:(?:^|[\s/])"# + escaped + #"[:@](?=\S))"#
            if text.range(of: credential, options: .regularExpression) != nil { return true }
            // A word-like username (`sport`, `news`) is ordinary text; an account-like one is not.
            let accountLike = username.count >= 6
                && username.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) || "._-".unicodeScalars.contains($0) })
            if accountLike { return text.range(of: username, options: .caseInsensitive) != nil }
            return username.count >= 8 && text.caseInsensitiveCompare(username) == .orderedSame
        }
    }

    enum QueryKeyKind { case username, password, secret, other }

    static func queryKeyKind(_ name: String) -> QueryKeyKind {
        switch name.lowercased() {
        case "user", "username", "login", "u": return .username
        case "pass", "password", "passwd", "pwd", "p": return .password
        case "token", "auth", "key", "apikey", "api_key", "access_key", "secret", "sig", "signature",
             "hash", "session", "sid", "jwt", "hmac": return .secret
        default: return .other
        }
    }

    /// A long mixed letter-and-digit value: a token or key, not a word.
    static func looksOpaque(_ value: String) -> Bool {
        value.count >= 16
            && value.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains)
            && value.unicodeScalars.contains(where: CharacterSet.letters.contains)
    }
}
