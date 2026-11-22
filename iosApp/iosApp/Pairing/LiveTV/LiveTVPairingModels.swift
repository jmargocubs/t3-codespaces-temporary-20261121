import Foundation

// Live TV pairing: payload, wire frames and the QR link. Platform-neutral and free of app
// dependencies, so both the Apple TV receiver and the iPhone sender share one definition.

/// The provider configuration moved from phone to TV. Credentials live here only in memory and in
/// the sealed frame; every textual and reflective view of this type is redacted, so logging or
/// dumping it can never print a URL, username or password.
struct LiveTVPairingPayload: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
                             CustomReflectable {
    enum Kind: String, Codable, Sendable { case m3u, xtream }

    var name: String
    var kind: Kind
    var playlistURL: String?
    var xmltvURL: String?
    var serverURL: String?
    var username: String?
    var password: String?

    var description: String { "LiveTVPairingPayload(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }

    /// What the approval screen may show: the provider's name, type and host. Never credentials.
    struct Summary: Equatable, Sendable {
        let name: String
        let kind: Kind
        let host: String
    }

    var summary: Summary {
        let source = kind == .m3u ? playlistURL : serverURL
        let host = source.flatMap { URL(string: $0)?.host } ?? "unknown host"
        return Summary(name: name, kind: kind, host: host)
    }

    static let maxFieldLength = 2048

    /// Structural validation before anything is shown or stored. The receiving store validates again.
    var isValid: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, name.count <= 80 else { return false }
        let fields = [playlistURL, xmltvURL, serverURL, username, password].compactMap { $0 }
        guard fields.allSatisfy({ $0.count <= Self.maxFieldLength }) else { return false }
        switch kind {
        case .m3u:
            guard let playlistURL, Self.isWebURL(playlistURL) else { return false }
            if let xmltvURL, !xmltvURL.isEmpty, !Self.isWebURL(xmltvURL) { return false }
            return true
        case .xtream:
            guard let serverURL, Self.isWebURL(serverURL),
                  let username, !username.isEmpty, let password, !password.isEmpty else { return false }
            return true
        }
    }

    static func isWebURL(_ string: String) -> Bool {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }
}

/// One message on the pairing connection. JSON with a 4-byte big-endian length prefix.
/// Textual output names only the frame type, never keys, proofs or sealed bytes.
struct LiveTVPairingFrame: Codable, Equatable, Sendable, CustomStringConvertible {
    enum Kind: String, Codable, Sendable { case hello, helloAck, deliver, result, error }

    var v: Int = LiveTVPairing.version
    var type: Kind
    var sid: String?
    var pk: String?
    var name: String?
    var proof: String?
    var sealed: String?
    var ok: Bool?
    var error: LiveTVPairingFailure?

    var description: String { "LiveTVPairingFrame(\(type.rawValue))" }

    static func failure(_ failure: LiveTVPairingFailure) -> LiveTVPairingFrame {
        LiveTVPairingFrame(type: .error, error: failure)
    }
}

/// Length-prefixed framing with a hard size cap, so a hostile peer cannot make either side buffer
/// without bound.
struct LiveTVPairingFrameBuffer {
    private var buffer = Data()

    static func encode(_ frame: LiveTVPairingFrame) throws -> Data {
        let body = try JSONEncoder().encode(frame)
        guard body.count <= LiveTVPairing.maxFrameBytes else { throw LiveTVPairingFailure.invalidMessage }
        var length = UInt32(body.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(body)
        return data
    }

    /// Appends received bytes and returns every complete frame. Throws on an oversized or
    /// undecodable frame; the caller closes the connection.
    mutating func append(_ data: Data) throws -> [LiveTVPairingFrame] {
        buffer.append(data)
        var frames: [LiveTVPairingFrame] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length <= UInt32(LiveTVPairing.maxFrameBytes) else { throw LiveTVPairingFailure.invalidMessage }
            guard buffer.count >= 4 + Int(length) else { break }
            let body = buffer.subdata(in: buffer.startIndex.advanced(by: 4)..<buffer.startIndex.advanced(by: 4 + Int(length)))
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex.advanced(by: 4 + Int(length)))
            guard let frame = try? JSONDecoder().decode(LiveTVPairingFrame.self, from: body) else {
                throw LiveTVPairingFailure.invalidMessage
            }
            frames.append(frame)
        }
        return frames
    }
}

/// The QR payload: where the TV listens and the session's public id and short code. It holds no
/// provider credentials. It does hold the session code, which is why the QR is only shown on the
/// TV screen for the five-minute session and the phone re-checks the displayed code.
struct LiveTVPairingLink: Equatable, Sendable {
    let sessionID: String
    let code: String
    let host: String
    let port: UInt16

    init(sessionID: String, code: String, host: String, port: UInt16) {
        self.sessionID = sessionID
        self.code = LiveTVPairingCrypto.normalizedCode(code)
        self.host = host
        self.port = port
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = LiveTVPairing.linkScheme
        components.host = LiveTVPairing.linkHost
        components.queryItems = [
            URLQueryItem(name: "v", value: String(LiveTVPairing.version)),
            URLQueryItem(name: "s", value: sessionID),
            URLQueryItem(name: "c", value: code),
            URLQueryItem(name: "h", value: host),
            URLQueryItem(name: "p", value: String(port)),
        ]
        return components.url!
    }

    /// Parses and validates a scanned link. Rejects other schemes, other versions, malformed
    /// fields, and any host outside the local network, so a QR cannot point the phone at the internet.
    init?(url: URL) {
        guard url.scheme == LiveTVPairing.linkScheme, url.host == LiveTVPairing.linkHost,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("v") == String(LiveTVPairing.version),
              let sid = value("s"), let sidData = LiveTVPairingEncoding.data(base64URL: sid), sidData.count == 16,
              let code = value("c"), LiveTVPairingCrypto.isWellFormed(code: code),
              let host = value("h"), Self.isLocalHost(host),
              let portText = value("p"), let port = UInt16(portText), port > 0 else { return nil }
        self.init(sessionID: sid, code: code, host: host, port: port)
    }

    /// Private IPv4 (10/8, 172.16/12, 192.168/16), link-local, loopback, IPv6 ULA/link-local, or `.local`.
    static func isLocalHost(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if host.hasSuffix(".local"), host.count > ".local".count { return true }
        if host.contains(":") {
            return host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard parts.count == 4, host.split(separator: ".").count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (192, 168), (169, 254), (127, _): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}
