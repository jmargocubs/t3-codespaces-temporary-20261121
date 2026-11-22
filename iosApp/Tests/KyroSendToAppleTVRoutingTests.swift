#if os(iOS)
import XCTest
@testable import Silo

/// Phase 3A: a scanned Apple TV pairing QR must open the send screen, and only a valid pairing
/// link may take that path. Other kyro:// links keep going to the normal deep-link router.
@MainActor
final class KyroSendToAppleTVRoutingTests: XCTestCase {
    private let validLink = "kyro://livetv-pair?v=1&s=AQEBAQEBAQEBAQEBAQEBAQ&c=ABCDEFGHJK&h=192.168.1.20&p=4455"

    override func tearDown() {
        KyroSendToAppleTVInbox.shared.link = nil
        super.tearDown()
    }

    func testValidPairingLinkIsTakenAndHeldForPresentation() throws {
        let inbox = KyroSendToAppleTVInbox.shared
        XCTAssertTrue(inbox.receive(try XCTUnwrap(URL(string: validLink))))
        XCTAssertEqual(inbox.link?.host, "192.168.1.20")
        XCTAssertEqual(inbox.link?.port, 4455)
        XCTAssertEqual(inbox.link?.code, "ABCDEFGHJK")
    }

    func testOtherAppLinksAreLeftForTheDeepLinkRouter() throws {
        let inbox = KyroSendToAppleTVInbox.shared
        for text in ["kyro://search?q=news", "kyro://watch-party?server=x&token=y", "kyro://downloads",
                     "https://example.com/livetv-pair?v=1"] {
            XCTAssertFalse(inbox.receive(try XCTUnwrap(URL(string: text))), text)
        }
        XCTAssertNil(inbox.link)
    }

    func testPairingLinkToANonLocalHostIsRefused() throws {
        let inbox = KyroSendToAppleTVInbox.shared
        let outside = validLink.replacingOccurrences(of: "192.168.1.20", with: "8.8.8.8")
        XCTAssertFalse(inbox.receive(try XCTUnwrap(URL(string: outside))))
        XCTAssertNil(inbox.link, "a QR must not be able to point the phone at the internet")
    }

    func testANewerQRReplacesAnOlderPendingOne() throws {
        let inbox = KyroSendToAppleTVInbox.shared
        inbox.receive(try XCTUnwrap(URL(string: validLink)))
        let newer = validLink.replacingOccurrences(of: "ABCDEFGHJK", with: "ZZZZZ00000")
        inbox.receive(try XCTUnwrap(URL(string: newer)))
        XCTAssertEqual(inbox.link?.code, "ZZZZZ00000")
    }

    func testPresentationRetriesLongEnoughForAColdLaunch() {
        // 20 attempts 250 ms apart: about five seconds for the first window to appear.
        XCTAssertGreaterThanOrEqual(KyroSendToAppleTVPresentation.maxAttempts, 20)
    }

    func testTopmostFollowsNothingWhenNothingIsPresented() {
        let root = UIViewController()
        XCTAssertTrue(KyroSendToAppleTVPresentation.topmost(from: root) === root)
    }
}
#endif
