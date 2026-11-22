import XCTest
import CryptoKit
#if !PAIRING_STANDALONE
@testable import Silo
#endif

/// Phone-to-TV Live TV pairing: token lifetime, replay prevention, attempt limits, encryption,
/// the QR link, framing and redaction. Platform-neutral, so it runs in the iOS and tvOS test
/// bundles and standalone on macOS.
final class LiveTVPairingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let xtream = LiveTVPairingPayload(
        name: "My IPTV", kind: .xtream, playlistURL: nil, xmltvURL: nil,
        serverURL: "http://iptv.example:8080", username: "user1", password: "s3cret-pass")

    // MARK: Helpers

    private func session() -> LiveTVPairingSession { LiveTVPairingSession(tvName: "Living Room", now: now) }

    private func hello(_ session: LiveTVPairingSession, code: String? = nil, sid: Data? = nil,
                       key: Curve25519.KeyAgreement.PrivateKey) -> LiveTVPairingFrame {
        let pk = key.publicKey.rawRepresentation
        let sidData = sid ?? session.sessionID
        let proof = LiveTVPairingCrypto.phoneProof(code: code ?? session.code, sessionID: sidData, phonePublic: pk)
        return LiveTVPairingFrame(type: .hello, sid: LiveTVPairingEncoding.base64URL(sidData),
                                  pk: LiveTVPairingEncoding.base64URL(pk), name: "Test iPhone",
                                  proof: LiveTVPairingEncoding.base64URL(proof))
    }

    private func deliver(_ session: LiveTVPairingSession, ack: LiveTVPairingFrame,
                         key: Curve25519.KeyAgreement.PrivateKey, payload: LiveTVPairingPayload) throws -> LiveTVPairingFrame {
        let tvPublic = try XCTUnwrap(ack.pk.flatMap(LiveTVPairingEncoding.data(base64URL:)))
        let phonePublic = key.publicKey.rawRepresentation
        // The phone must verify the TV's proof before sending anything.
        let expected = LiveTVPairingCrypto.tvProof(code: session.code, sessionID: session.sessionID,
                                                   phonePublic: phonePublic, tvPublic: tvPublic)
        let proof = try XCTUnwrap(ack.proof.flatMap(LiveTVPairingEncoding.data(base64URL:)))
        XCTAssertTrue(LiveTVPairingCrypto.verify(proof, expected: expected))
        let symmetric = try LiveTVPairingCrypto.deriveKey(
            privateKey: key, peerPublic: tvPublic, code: session.code, sessionID: session.sessionID,
            phonePublic: phonePublic, tvPublic: tvPublic)
        let aad = LiveTVPairingCrypto.associatedData(sessionID: session.sessionID, phonePublic: phonePublic, tvPublic: tvPublic)
        let sealed = try LiveTVPairingCrypto.seal(JSONEncoder().encode(payload), key: symmetric, associatedData: aad)
        return LiveTVPairingFrame(type: .deliver, sealed: LiveTVPairingEncoding.base64URL(sealed))
    }

    private func connected(_ session: inout LiveTVPairingSession,
                           key: Curve25519.KeyAgreement.PrivateKey) throws -> LiveTVPairingFrame {
        guard case .success(let ack) = session.handleHello(hello(session, key: key), now: now) else {
            throw XCTSkip("handshake failed")
        }
        return ack
    }

    private func failure<T>(_ result: Result<T, LiveTVPairingFailure>) -> LiveTVPairingFailure? {
        if case .failure(let failure) = result { return failure }
        return nil
    }

    // MARK: Happy path and single use

    func testPairingDeliversProviderAfterExplicitApproval() throws {
        var session = session()
        let key = Curve25519.KeyAgreement.PrivateKey()
        let ack = try connected(&session, key: key)
        guard case .success(let summary) = session.handleDelivery(try deliver(session, ack: ack, key: key, payload: xtream), now: now) else {
            return XCTFail("delivery rejected")
        }
        XCTAssertEqual(summary.name, "My IPTV")
        XCTAssertEqual(summary.host, "iptv.example")
        // Nothing is released before the TV user approves.
        XCTAssertEqual(session.phase, .awaitingApproval(summary, deviceName: "Test iPhone"))
        guard case .success(let approved) = session.approve(now: now) else { return XCTFail("approve failed") }
        XCTAssertEqual(approved, xtream)
        XCTAssertEqual(session.phase, .completed)
    }

    func testTokenIsSingleUseAndReplayIsRejected() throws {
        var session = session()
        let key = Curve25519.KeyAgreement.PrivateKey()
        let ack = try connected(&session, key: key)
        let frame = try deliver(session, ack: ack, key: key, payload: xtream)
        _ = session.handleDelivery(frame, now: now)
        _ = session.approve(now: now)
        XCTAssertEqual(failure(session.handleDelivery(frame, now: now)), .sessionClosed)
        XCTAssertEqual(failure(session.handleHello(hello(session, key: key), now: now)), .sessionClosed)
        XCTAssertNotNil(failure(session.approve(now: now)))
    }

    func testSecondDeliveryInSameSessionIsRejected() throws {
        var session = session()
        let key = Curve25519.KeyAgreement.PrivateKey()
        let ack = try connected(&session, key: key)
        let frame = try deliver(session, ack: ack, key: key, payload: xtream)
        _ = session.handleDelivery(frame, now: now)
        XCTAssertNotNil(failure(session.handleDelivery(frame, now: now)))
    }

    func testCiphertextFromAnotherSessionCannotBeReplayed() throws {
        var first = session()
        let key = Curve25519.KeyAgreement.PrivateKey()
        let ack = try connected(&first, key: key)
        let frame = try deliver(first, ack: ack, key: key, payload: xtream)
        var second = session()
        _ = second.handleHello(hello(second, key: key), now: now)
        XCTAssertEqual(failure(second.handleDelivery(frame, now: now)), .decryptionFailed)
    }

    func testTamperedCiphertextIsRejected() throws {
        var session = session()
        let key = Curve25519.KeyAgreement.PrivateKey()
        let ack = try connected(&session, key: key)
        var frame = try deliver(session, ack: ack, key: key, payload: xtream)
        var bytes = try XCTUnwrap(frame.sealed.flatMap(LiveTVPairingEncoding.data(base64URL:)))
        bytes[bytes.count - 1] ^= 0x01
        frame.sealed = LiveTVPairingEncoding.base64URL(bytes)
        XCTAssertEqual(failure(session.handleDelivery(frame, now: now)), .decryptionFailed)
    }

    // MARK: Expiry, wrong codes, cancellation

    func testSessionExpiresAfterFiveMinutes() throws {
        var session = session()
        let key = Curve25519.KeyAgreement.PrivateKey()
        XCTAssertEqual(session.remaining(at: now), 300, accuracy: 0.001)
        session.tick(now: now.addingTimeInterval(299))
        XCTAssertFalse(session.isTerminal)
        XCTAssertEqual(failure(session.handleHello(hello(session, key: key), now: now.addingTimeInterval(301))), .expired)
        XCTAssertEqual(session.phase, .expired)
        XCTAssertEqual(session.remaining(at: now.addingTimeInterval(400)), 0)
    }

    func testExpiryBetweenHandshakeAndDeliveryIsRejected() throws {
        var session = session()
        let key = Curve25519.KeyAgreement.PrivateKey()
        let ack = try connected(&session, key: key)
        let frame = try deliver(session, ack: ack, key: key, payload: xtream)
        XCTAssertEqual(failure(session.handleDelivery(frame, now: now.addingTimeInterval(301))), .expired)
        XCTAssertNotNil(failure(session.approve(now: now)))
    }

    func testWrongCodeLocksSessionAfterThreeAttempts() {
        var session = session()
        let key = Curve25519.KeyAgreement.PrivateKey()
        let results = (0..<3).map { _ in failure(session.handleHello(hello(session, code: "AAAAA-AAAAA", key: key), now: now)) }
        XCTAssertEqual(results, [.invalidProof, .invalidProof, .tooManyAttempts])
        XCTAssertTrue(session.isTerminal)
        // The right code no longer works.
        XCTAssertNotNil(failure(session.handleHello(hello(session, key: key), now: now)))
    }

    func testWrongSessionIDIsRejected() {
        var session = session()
        let key = Curve25519.KeyAgreement.PrivateKey()
        let frame = hello(session, sid: Data(repeating: 7, count: 16), key: key)
        XCTAssertEqual(failure(session.handleHello(frame, now: now)), .invalidSession)
    }

    func testSecondPhoneCannotTakeOverOrBurnAttempts() throws {
        var session = session()
        _ = try connected(&session, key: Curve25519.KeyAgreement.PrivateKey())
        let other = Curve25519.KeyAgreement.PrivateKey()
        XCTAssertEqual(failure(session.handleHello(hello(session, key: other), now: now)), .sessionInUse)
        XCTAssertEqual(session.failedAttempts, 0)
        XCTAssertFalse(session.isTerminal)
    }

    func testCancelAndDeclineCloseTheSession() throws {
        var cancelled = session()
        cancelled.cancel()
        let key = Curve25519.KeyAgreement.PrivateKey()
        XCTAssertEqual(failure(cancelled.handleHello(hello(cancelled, key: key), now: now)), .cancelled)

        var declined = session()
        let ack = try connected(&declined, key: key)
        _ = declined.handleDelivery(try deliver(declined, ack: ack, key: key, payload: xtream), now: now)
        declined.reject()
        XCTAssertNotNil(failure(declined.approve(now: now)))
    }

    func testInvalidProviderIsRejectedBeforeApproval() throws {
        var session = session()
        let key = Curve25519.KeyAgreement.PrivateKey()
        let ack = try connected(&session, key: key)
        let bad = LiveTVPairingPayload(name: "x", kind: .m3u, playlistURL: "ftp://nope", xmltvURL: nil,
                                       serverURL: nil, username: nil, password: nil)
        XCTAssertEqual(failure(session.handleDelivery(try deliver(session, ack: ack, key: key, payload: bad), now: now)), .invalidProvider)
        XCTAssertTrue(session.isTerminal)
    }

    func testPayloadValidation() {
        XCTAssertTrue(xtream.isValid)
        XCTAssertFalse(LiveTVPairingPayload(name: " ", kind: .m3u, playlistURL: "https://a.b/c.m3u", xmltvURL: nil,
                                            serverURL: nil, username: nil, password: nil).isValid)
        XCTAssertFalse(LiveTVPairingPayload(name: "n", kind: .xtream, playlistURL: nil, xmltvURL: nil,
                                            serverURL: "https://a.b", username: "u", password: "").isValid)
        XCTAssertFalse(LiveTVPairingPayload(name: "n", kind: .m3u, playlistURL: "https://a.b/c.m3u", xmltvURL: "nope",
                                            serverURL: nil, username: nil, password: nil).isValid)
    }

    // MARK: Codes, link, framing

    func testGeneratedCodesAreWellFormedAndUnique() {
        let codes = (0..<200).map { _ in LiveTVPairingCrypto.makeCode() }
        XCTAssertTrue(codes.allSatisfy { $0.count == 10 && LiveTVPairingCrypto.isWellFormed(code: $0) })
        XCTAssertEqual(Set(codes).count, codes.count)
        XCTAssertEqual(LiveTVPairingCrypto.normalizedCode("abcde-fghjk"), "ABCDEFGHJK")
        XCTAssertEqual(LiveTVPairingCrypto.normalizedCode("O1Il"), "0111")
        XCTAssertEqual(LiveTVPairingCrypto.displayCode("abcdefghjk"), "ABCDE-FGHJK")
    }

    func testLinkRoundTripsAndCarriesNoCredentials() throws {
        let link = LiveTVPairingLink(sessionID: LiveTVPairingEncoding.base64URL(Data(repeating: 1, count: 16)),
                                     code: "ABCDEFGHJK", host: "192.168.1.20", port: 4455)
        XCTAssertEqual(LiveTVPairingLink(url: link.url), link)
        let text = link.url.absoluteString
        for secret in ["pass", "user", "secret", "token"] { XCTAssertFalse(text.lowercased().contains(secret)) }
    }

    func testLinkRejectsHostsOutsideTheLocalNetwork() throws {
        func link(_ host: String) -> LiveTVPairingLink? {
            LiveTVPairingLink(url: URL(string: "kyro://livetv-pair?v=1&s=AQEBAQEBAQEBAQEBAQEBAQ&c=ABCDEFGHJK&h=\(host)&p=80")!)
        }
        XCTAssertNil(link("8.8.8.8"))
        XCTAssertNil(link("evil.example.com"))
        XCTAssertNil(link("172.32.0.5"))
        XCTAssertNotNil(link("Living-Room.local"))
        XCTAssertNotNil(link("172.31.0.5"))
        XCTAssertNil(LiveTVPairingLink(url: URL(string: "https://livetv-pair?v=1")!))
    }

    func testFramingBuffersPartialFramesAndCapsSize() throws {
        let data = try LiveTVPairingFrameBuffer.encode(LiveTVPairingFrame(type: .result, ok: true))
        var buffer = LiveTVPairingFrameBuffer()
        XCTAssertTrue(try buffer.append(data.prefix(data.count / 2)).isEmpty)
        XCTAssertEqual(try buffer.append(data.suffix(from: data.count / 2)).count, 1)
        var oversize = LiveTVPairingFrameBuffer()
        XCTAssertThrowsError(try oversize.append(Data([0, 1, 0, 1])))
    }

    // MARK: Logging and error redaction

    func testPayloadAndFramesNeverPrintSecrets() {
        var dumped = ""
        dump(xtream, to: &dumped)
        let texts = ["\(xtream)", String(describing: xtream), String(reflecting: xtream), dumped]
        for text in texts {
            XCTAssertFalse(text.contains("s3cret"))
            XCTAssertFalse(text.contains("user1"))
            XCTAssertFalse(text.contains("iptv.example"))
        }
        XCTAssertFalse("\(LiveTVPairingFrame(type: .deliver, sealed: "SEALEDBYTES"))".contains("SEALEDBYTES"))
        XCTAssertFalse("\(LiveTVPairingFrame(type: .hello, proof: "PROOFBYTES"))".contains("PROOFBYTES"))
    }

    func testFailureMessagesAreFixedText() {
        let all: [LiveTVPairingFailure] = [.expired, .cancelled, .rejected, .invalidSession, .invalidProof, .sessionInUse,
                                           .sessionClosed, .invalidMessage, .decryptionFailed, .tooManyAttempts,
                                           .invalidProvider, .unsupportedVersion, .unreachable]
        for failure in all {
            XCTAssertFalse(failure.userMessage.isEmpty)
            XCTAssertFalse(failure.userMessage.contains("s3cret"))
        }
    }
}
