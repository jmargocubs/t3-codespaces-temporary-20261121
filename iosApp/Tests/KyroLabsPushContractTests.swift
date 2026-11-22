import XCTest
@testable import Silo

/// Kyro Labs must not create or change anything in the Silo server's push records.
///
/// The server only accepts the stable bundle ID as an APNs topic, and the client refuses to send
/// any other topic before it allocates a journal generation or makes a request
/// (`ApplePushRegistrar.register` → `ApplePushRegistrationWire.contractViolation`). Labs's
/// bundle ID is therefore refused for every push mode, including `off`.
final class KyroLabsPushContractTests: XCTestCase {
    private func body(topic: String, mode: String = ApplePushRegistrationWire.privatePushMode)
        -> APIv2ApplePushRegistrationBody {
        APIv2ApplePushRegistrationBody(
            deviceId: "device-1", apnsToken: String(repeating: "a", count: 64),
            apnsEnvironment: "sandbox", apnsTopic: topic, pushMode: mode)
    }

    func testLabsTopicIsTheLabsBundleIDAndIsRefused() {
        let topic = ApplePushRegistrationWire.topic(bundleIdentifier: KyroAppIdentity.labs.bundleID)
        XCTAssertEqual(topic, "com.cubbiestream.kyro.labs")
        for mode in [ApplePushRegistrationWire.privatePushMode, ApplePushRegistrationWire.offPushMode] {
            XCTAssertEqual(ApplePushRegistrationWire.contractViolation(in: body(topic: topic, mode: mode)),
                           "apns_topic", "Labs must never reach the push registration endpoint (\(mode))")
        }
    }

    func testStableTopicStillSatisfiesTheServerContract() {
        let topic = ApplePushRegistrationWire.topic(bundleIdentifier: KyroAppIdentity.stable.bundleID)
        XCTAssertNil(ApplePushRegistrationWire.contractViolation(in: body(topic: topic)))
    }

    func testLabsEntitlementsRequestNoPush() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("SiloLabs.entitlements"))
        let e = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertNil(e["aps-environment"])
    }
}
