import Foundation
import CryptoKit
import Security

// Phone-to-TV Live TV provider pairing: cryptography.
//
// Threat model: a device on the same LAN can see the Bonjour record and the TCP bytes, but not
// the TV screen. The TV shows a random pairing secret (`code`, 50 bits) and embeds it in the QR.
// Both sides prove they know it with HMACs over an ephemeral X25519 exchange, and the provider
// is sent as ChaChaPoly ciphertext under a key that mixes the ECDH secret with the code. No
// credential ever travels in the QR, the Bonjour record, a URL, or in plain text.

enum LiveTVPairing {
    static let version = 1
    /// A pairing session lives about five minutes.
    static let sessionLifetime: TimeInterval = 300
    /// Failed proofs or failed decryptions before the session is destroyed.
    static let maxFailedAttempts = 3
    static let maxFrameBytes = 16 * 1024
    static let bonjourType = "_kyrolive._tcp"
    static let linkScheme = "kyro"
    static let linkHost = "livetv-pair"
    static let codeLength = 10
}

enum LiveTVPairingEncoding {
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64URL string: String) -> Data? {
        var value = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        return Data(base64Encoded: value)
    }
}

enum LiveTVPairingCrypto {
    /// Crockford base32: no I, L, O or U, so a code read off a TV is hard to mistype.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        // A failed system RNG must never produce a predictable token.
        precondition(status == errSecSuccess, "System random generator unavailable")
        return Data(bytes)
    }

    /// 128-bit public session identifier.
    static func makeSessionID() -> Data { randomBytes(16) }

    /// 50-bit pairing secret as ten Crockford characters. `& 31` is unbiased because 32 divides 256.
    static func makeCode() -> String {
        String(randomBytes(LiveTVPairing.codeLength).map { alphabet[Int($0 & 31)] })
    }

    /// Uppercases, drops separators, and maps the characters Crockford treats as look-alikes.
    static func normalizedCode(_ input: String) -> String {
        String(input.uppercased().compactMap { character -> Character? in
            switch character {
            case " ", "-", "_": nil
            case "O": "0"
            case "I", "L": "1"
            default: character
            }
        })
    }

    static func isWellFormed(code: String) -> Bool {
        let normalized = normalizedCode(code)
        return normalized.count == LiveTVPairing.codeLength && normalized.allSatisfy { alphabet.contains($0) }
    }

    /// "ABCDE-FGHJK" for the TV screen.
    static func displayCode(_ code: String) -> String {
        let normalized = normalizedCode(code)
        guard normalized.count == LiveTVPairing.codeLength else { return normalized }
        let middle = normalized.index(normalized.startIndex, offsetBy: LiveTVPairing.codeLength / 2)
        return normalized[..<middle] + "-" + normalized[middle...]
    }

    // MARK: Proofs

    private static func mac(_ label: String, _ parts: [Data], code: String) -> Data {
        var message = Data(label.utf8)
        for part in parts { message.append(part) }
        let key = SymmetricKey(data: Data(normalizedCode(code).utf8))
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    /// Phone to TV: proves the phone knows the code, bound to this session and key.
    static func phoneProof(code: String, sessionID: Data, phonePublic: Data) -> Data {
        mac("kyro-livetv-pair-v1/phone", [sessionID, phonePublic], code: code)
    }

    /// TV to phone: proves the TV knows the code, bound to both keys.
    static func tvProof(code: String, sessionID: Data, phonePublic: Data, tvPublic: Data) -> Data {
        mac("kyro-livetv-pair-v1/tv", [sessionID, phonePublic, tvPublic], code: code)
    }

    /// Constant-time comparison.
    static func verify(_ proof: Data, expected: Data) -> Bool {
        guard proof.count == expected.count else { return false }
        return zip(proof, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: Key agreement and sealing

    static func deriveKey(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublic: Data,
                          code: String, sessionID: Data, phonePublic: Data, tvPublic: Data) throws -> SymmetricKey {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublic)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        var salt = Data("kyro-livetv-pair-v1/salt".utf8)
        salt.append(sessionID)
        salt.append(Data(normalizedCode(code).utf8))
        var info = Data("kyro-livetv-pair-v1/key".utf8)
        info.append(phonePublic)
        info.append(tvPublic)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(SHA256.hash(data: salt)),
                                              sharedInfo: info, outputByteCount: 32)
    }

    /// Binds the ciphertext to this session, so it cannot be replayed into another.
    static func associatedData(sessionID: Data, phonePublic: Data, tvPublic: Data) -> Data {
        var data = Data("kyro-livetv-pair-v1/deliver".utf8)
        data.append(sessionID)
        data.append(phonePublic)
        data.append(tvPublic)
        return data
    }

    static func seal(_ plaintext: Data, key: SymmetricKey, associatedData: Data) throws -> Data {
        try ChaChaPoly.seal(plaintext, using: key, authenticating: associatedData).combined
    }

    static func open(_ combined: Data, key: SymmetricKey, associatedData: Data) throws -> Data {
        let box = try ChaChaPoly.SealedBox(combined: combined)
        return try ChaChaPoly.open(box, using: key, authenticating: associatedData)
    }
}

/// Why a pairing step failed. Raw values travel on the wire, so they are stable codes and never
/// carry provider data. `userMessage` strings are fixed text for the same reason.
enum LiveTVPairingFailure: String, Error, Codable, Equatable, Sendable {
    case expired
    case cancelled
    case rejected
    case invalidSession
    case invalidProof
    case sessionInUse
    case sessionClosed
    case invalidMessage
    case decryptionFailed
    case tooManyAttempts
    case invalidProvider
    case unsupportedVersion
    case unreachable

    var userMessage: String {
        switch self {
        case .expired: "The pairing code expired. Start again on your Apple TV."
        case .cancelled: "Pairing was cancelled."
        case .rejected: "The Apple TV declined the provider."
        case .invalidSession, .invalidProof: "That pairing code did not match. Check the code on your Apple TV."
        case .sessionInUse: "Another device is already pairing with this Apple TV."
        case .sessionClosed: "This pairing session has already ended. Start again on your Apple TV."
        case .invalidMessage, .decryptionFailed: "The pairing message could not be verified."
        case .tooManyAttempts: "Too many failed attempts. Start again on your Apple TV."
        case .invalidProvider: "The provider details were not valid."
        case .unsupportedVersion: "Update Kyro on both devices to pair."
        case .unreachable: "Could not reach the Apple TV on this network."
        }
    }
}
