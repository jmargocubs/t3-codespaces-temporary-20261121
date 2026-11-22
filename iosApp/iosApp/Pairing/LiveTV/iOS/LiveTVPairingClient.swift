#if os(iOS)
import Foundation
import Network
import Observation
import CryptoKit
import UIKit
import os

/// The iPhone's side of Live TV pairing: connects to the Apple TV, proves it knows the pairing
/// code, checks the TV's own proof, and only then sends the provider sealed under the session key.
///
/// Two steps, so the person confirms before anything leaves the phone: `connect` authenticates
/// the TV; `send` transfers the chosen provider after the person taps Send.
@MainActor
@Observable
final class LiveTVPairingClient {
    enum State: Equatable {
        case idle
        case connecting
        case ready(tvName: String)
        case sending
        case sent
        case failed(LiveTVPairingFailure)
    }

    private(set) var state: State = .idle

    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var buffer = LiveTVPairingFrameBuffer()
    @ObservationIgnored private var phoneKey: Curve25519.KeyAgreement.PrivateKey?
    @ObservationIgnored private var sessionKey: SymmetricKey?
    @ObservationIgnored private var sessionID = Data()
    @ObservationIgnored private var code = ""
    @ObservationIgnored private var tvPublic = Data()
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    /// Static text only: provider data never reaches the log.
    private static let log = Logger(subsystem: "com.cubbiestream.kyro", category: "livetv-pairing")

    /// Long enough for someone to answer the first-run Local Network prompt.
    static let connectTimeout: Duration = .seconds(45)

    var isFinished: Bool {
        switch state {
        case .sent, .failed: true
        default: false
        }
    }

    /// Opens the connection and authenticates the Apple TV. Does not send any provider.
    func connect(to endpoint: NWEndpoint, sessionID sessionIDText: String, code rawCode: String) {
        cancelConnection()
        guard LiveTVPairingCrypto.isWellFormed(code: rawCode),
              let sessionData = LiveTVPairingEncoding.data(base64URL: sessionIDText), sessionData.count == 16 else {
            state = .failed(.invalidSession)
            return
        }
        sessionID = sessionData
        code = LiveTVPairingCrypto.normalizedCode(rawCode)
        phoneKey = Curve25519.KeyAgreement.PrivateKey()
        buffer = LiveTVPairingFrameBuffer()
        state = .connecting

        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in self?.connectionStateChanged(newState, connection: connection) }
        }
        connection.start(queue: .main)
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.connectTimeout)
            guard let self, !Task.isCancelled, case .connecting = self.state else { return }
            self.fail(.unreachable)
        }
    }

    /// Sends the provider. Call only after the person approved the transfer.
    func send(_ payload: LiveTVPairingPayload) {
        guard case .ready = state, let sessionKey, let phoneKey else { return }
        guard let plaintext = try? JSONEncoder().encode(payload) else { fail(.invalidProvider); return }
        let phonePublic = phoneKey.publicKey.rawRepresentation
        let aad = LiveTVPairingCrypto.associatedData(sessionID: sessionID, phonePublic: phonePublic, tvPublic: tvPublic)
        guard let sealed = try? LiveTVPairingCrypto.seal(plaintext, key: sessionKey, associatedData: aad) else {
            fail(.invalidMessage)
            return
        }
        state = .sending
        transmit(LiveTVPairingFrame(type: .deliver, sealed: LiveTVPairingEncoding.base64URL(sealed)))
    }

    func cancel() {
        cancelConnection()
        state = .failed(.cancelled)
    }

    // MARK: Connection

    private func connectionStateChanged(_ newState: NWConnection.State, connection: NWConnection) {
        guard self.connection === connection else { return }
        switch newState {
        case .ready:
            sendHello()
            receive(on: connection)
        case .failed:
            if case .connecting = state { fail(.unreachable) }
        case .waiting:
            // iOS parks the connection here while it shows the first-run Local Network prompt,
            // and resumes it once the person answers. Failing now would break every first pairing;
            // the watchdog still ends a connection that never becomes ready.
            break
        case .cancelled:
            if case .sending = state { fail(.unreachable) }
        default:
            break
        }
    }

    private func sendHello() {
        guard let phoneKey else { return }
        let phonePublic = phoneKey.publicKey.rawRepresentation
        let proof = LiveTVPairingCrypto.phoneProof(code: code, sessionID: sessionID, phonePublic: phonePublic)
        transmit(LiveTVPairingFrame(type: .hello, sid: LiveTVPairingEncoding.base64URL(sessionID),
                                    pk: LiveTVPairingEncoding.base64URL(phonePublic), name: Self.deviceName,
                                    proof: LiveTVPairingEncoding.base64URL(proof)))
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                if let data, !data.isEmpty {
                    do {
                        for frame in try self.buffer.append(data) { self.handle(frame) }
                    } catch {
                        self.fail(.invalidMessage)
                        return
                    }
                }
                if self.isFinished { return }
                if error != nil || isComplete {
                    // The TV closed without a result: the session ended or was cancelled.
                    if case .sending = self.state { self.fail(.unreachable) }
                    else if case .connecting = self.state { self.fail(.unreachable) }
                    return
                }
                self.receive(on: connection)
            }
        }
    }

    private func handle(_ frame: LiveTVPairingFrame) {
        switch frame.type {
        case .helloAck:
            guard case .connecting = state, let phoneKey,
                  let tvPublicData = frame.pk.flatMap(LiveTVPairingEncoding.data(base64URL:)), tvPublicData.count == 32,
                  let proof = frame.proof.flatMap(LiveTVPairingEncoding.data(base64URL:)) else {
                fail(.invalidMessage)
                return
            }
            let phonePublic = phoneKey.publicKey.rawRepresentation
            // The TV must prove it knows the code before anything is sent to it.
            let expected = LiveTVPairingCrypto.tvProof(code: code, sessionID: sessionID,
                                                       phonePublic: phonePublic, tvPublic: tvPublicData)
            guard LiveTVPairingCrypto.verify(proof, expected: expected),
                  let derived = try? LiveTVPairingCrypto.deriveKey(
                    privateKey: phoneKey, peerPublic: tvPublicData, code: code, sessionID: sessionID,
                    phonePublic: phonePublic, tvPublic: tvPublicData) else {
                fail(.invalidProof)
                return
            }
            tvPublic = tvPublicData
            sessionKey = derived
            watchdog?.cancel()
            state = .ready(tvName: Self.cleanTVName(frame.name))
        case .result:
            if frame.ok == true {
                Self.log.notice("Provider sent to Apple TV")
                finishConnection()
                state = .sent
            } else {
                fail(frame.error ?? .rejected)
            }
        case .error:
            fail(frame.error ?? .invalidMessage)
        default:
            fail(.invalidMessage)
        }
    }

    private func transmit(_ frame: LiveTVPairingFrame) {
        guard let connection, let data = try? LiveTVPairingFrameBuffer.encode(frame) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func fail(_ failure: LiveTVPairingFailure) {
        Self.log.error("Pairing failed")
        finishConnection()
        state = .failed(failure)
    }

    private func finishConnection() {
        watchdog?.cancel()
        watchdog = nil
        connection?.cancel()
        connection = nil
        sessionKey = nil
        phoneKey = nil
    }

    private func cancelConnection() {
        finishConnection()
        buffer = LiveTVPairingFrameBuffer()
    }

    // MARK: Names

    private static var deviceName: String { String(UIDevice.current.name.prefix(40)) }

    static func cleanTVName(_ name: String?) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Apple TV" : String(trimmed.prefix(40))
    }
}
#endif
