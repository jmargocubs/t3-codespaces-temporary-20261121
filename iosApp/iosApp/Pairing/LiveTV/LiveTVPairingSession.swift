import Foundation
import CryptoKit

/// The Apple TV's side of one pairing session, as a pure state machine. The clock is passed in,
/// so expiry, attempt limits and single use are testable without a network or a timer.
///
/// Lifecycle: `listening` → `phoneConnected` → `awaitingApproval` → `completed`. A session accepts
/// one phone, one delivery and one approval; every terminal phase refuses all further input, so a
/// replayed frame can never produce a second provider.
struct LiveTVPairingSession {
    enum Phase: Equatable {
        case listening
        case phoneConnected(deviceName: String)
        case awaitingApproval(LiveTVPairingPayload.Summary, deviceName: String)
        case completed
        case cancelled
        case expired
        case failed(LiveTVPairingFailure)
    }

    private(set) var phase: Phase = .listening
    let sessionID: Data
    let code: String
    let createdAt: Date
    let expiresAt: Date
    let tvName: String
    private(set) var failedAttempts = 0

    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private var key: SymmetricKey?
    private var phonePublic: Data?
    private var pending: LiveTVPairingPayload?

    init(tvName: String, now: Date = Date(), lifetime: TimeInterval = LiveTVPairing.sessionLifetime) {
        self.init(tvName: tvName, sessionID: LiveTVPairingCrypto.makeSessionID(), code: LiveTVPairingCrypto.makeCode(),
                  privateKey: Curve25519.KeyAgreement.PrivateKey(), now: now, lifetime: lifetime)
    }

    /// Fixed inputs, for tests.
    init(tvName: String, sessionID: Data, code: String, privateKey: Curve25519.KeyAgreement.PrivateKey,
         now: Date, lifetime: TimeInterval = LiveTVPairing.sessionLifetime) {
        self.tvName = tvName
        self.sessionID = sessionID
        self.code = LiveTVPairingCrypto.normalizedCode(code)
        self.privateKey = privateKey
        self.createdAt = now
        self.expiresAt = now.addingTimeInterval(lifetime)
    }

    var sessionIDString: String { LiveTVPairingEncoding.base64URL(sessionID) }
    var tvPublic: Data { privateKey.publicKey.rawRepresentation }
    var displayCode: String { LiveTVPairingCrypto.displayCode(code) }

    var isTerminal: Bool {
        switch phase {
        case .completed, .cancelled, .expired, .failed: true
        case .listening, .phoneConnected, .awaitingApproval: false
        }
    }

    func remaining(at now: Date) -> TimeInterval { max(0, expiresAt.timeIntervalSince(now)) }

    /// Ends the session when its time is up. Call from the countdown and before every input.
    mutating func tick(now: Date) {
        guard !isTerminal, now >= expiresAt else { return }
        end(.expired)
    }

    // MARK: Phone input

    /// Step 1: the phone proves it knows the code. Replies with the TV's key and its own proof, so
    /// the phone can authenticate the TV before sending anything.
    mutating func handleHello(_ frame: LiveTVPairingFrame, now: Date) -> Result<LiveTVPairingFrame, LiveTVPairingFailure> {
        tick(now: now)
        if let closed = closedFailure() { return .failure(closed) }
        guard frame.v == LiveTVPairing.version else { return .failure(.unsupportedVersion) }
        // A second connection must not be able to kill or take over a session in progress.
        guard phase == .listening else { return .failure(.sessionInUse) }
        guard frame.type == .hello, let sid = frame.sid.flatMap(LiveTVPairingEncoding.data(base64URL:)),
              let pk = frame.pk.flatMap(LiveTVPairingEncoding.data(base64URL:)), pk.count == 32,
              let proof = frame.proof.flatMap(LiveTVPairingEncoding.data(base64URL:)) else {
            return .failure(.invalidMessage)
        }
        guard LiveTVPairingCrypto.verify(sid, expected: sessionID) else { return recordFailure(.invalidSession) }
        let expected = LiveTVPairingCrypto.phoneProof(code: code, sessionID: sessionID, phonePublic: pk)
        guard LiveTVPairingCrypto.verify(proof, expected: expected) else { return recordFailure(.invalidProof) }
        guard let derived = try? LiveTVPairingCrypto.deriveKey(
            privateKey: privateKey, peerPublic: pk, code: code, sessionID: sessionID,
            phonePublic: pk, tvPublic: tvPublic) else { return .failure(.invalidMessage) }
        key = derived
        phonePublic = pk
        phase = .phoneConnected(deviceName: Self.cleanDeviceName(frame.name))
        let tvProof = LiveTVPairingCrypto.tvProof(code: code, sessionID: sessionID, phonePublic: pk, tvPublic: tvPublic)
        return .success(LiveTVPairingFrame(type: .helloAck, pk: LiveTVPairingEncoding.base64URL(tvPublic), name: tvName,
                                           proof: LiveTVPairingEncoding.base64URL(tvProof)))
    }

    /// Step 2: the sealed provider. Single use: after one successful decryption the session accepts
    /// no further delivery.
    mutating func handleDelivery(_ frame: LiveTVPairingFrame, now: Date) -> Result<LiveTVPairingPayload.Summary, LiveTVPairingFailure> {
        tick(now: now)
        if let closed = closedFailure() { return .failure(closed) }
        guard frame.v == LiveTVPairing.version else { return .failure(.unsupportedVersion) }
        guard case .phoneConnected(let deviceName) = phase, let key, let phonePublic else { return .failure(.invalidMessage) }
        guard frame.type == .deliver, let sealed = frame.sealed.flatMap(LiveTVPairingEncoding.data(base64URL:)) else {
            return .failure(.invalidMessage)
        }
        let aad = LiveTVPairingCrypto.associatedData(sessionID: sessionID, phonePublic: phonePublic, tvPublic: tvPublic)
        guard let plaintext = try? LiveTVPairingCrypto.open(sealed, key: key, associatedData: aad) else {
            return recordFailure(.decryptionFailed)
        }
        guard let payload = try? JSONDecoder().decode(LiveTVPairingPayload.self, from: plaintext), payload.isValid else {
            end(.failed(.invalidProvider))
            return .failure(.invalidProvider)
        }
        pending = payload
        phase = .awaitingApproval(payload.summary, deviceName: deviceName)
        return .success(payload.summary)
    }

    // MARK: TV user input

    /// The TV user pressed Allow. Hands out the payload exactly once and clears it from the session.
    mutating func approve(now: Date) -> Result<LiveTVPairingPayload, LiveTVPairingFailure> {
        tick(now: now)
        if let closed = closedFailure() { return .failure(closed) }
        guard case .awaitingApproval = phase, let payload = pending else { return .failure(.invalidMessage) }
        end(.completed)
        return .success(payload)
    }

    /// The TV user declined the received provider.
    mutating func reject() {
        guard !isTerminal else { return }
        end(.cancelled)
    }

    mutating func cancel() {
        guard !isTerminal else { return }
        end(.cancelled)
    }

    // MARK: Helpers

    /// Failure to report when input arrives after the session ended.
    private func closedFailure() -> LiveTVPairingFailure? {
        switch phase {
        case .expired: .expired
        case .cancelled: .cancelled
        case .failed(let failure): failure
        case .completed: .sessionClosed
        case .listening, .phoneConnected, .awaitingApproval: nil
        }
    }

    private mutating func recordFailure(_ failure: LiveTVPairingFailure) -> Result<LiveTVPairingFrame, LiveTVPairingFailure> {
        failedAttempts += 1
        if failedAttempts >= LiveTVPairing.maxFailedAttempts {
            end(.failed(.tooManyAttempts))
            return .failure(.tooManyAttempts)
        }
        return .failure(failure)
    }

    private mutating func recordFailure(_ failure: LiveTVPairingFailure) -> Result<LiveTVPairingPayload.Summary, LiveTVPairingFailure> {
        failedAttempts += 1
        if failedAttempts >= LiveTVPairing.maxFailedAttempts {
            end(.failed(.tooManyAttempts))
            return .failure(.tooManyAttempts)
        }
        return .failure(failure)
    }

    /// Enters a terminal phase and drops key material and any received provider.
    private mutating func end(_ phase: Phase) {
        self.phase = phase
        key = nil
        pending = nil
        phonePublic = nil
    }

    static func cleanDeviceName(_ name: String?) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "iPhone" : String(trimmed.prefix(40))
    }
}
