import Foundation
import KyroCapabilities
import XCTest

final class CapabilityBoundaryTests: XCTestCase {
  func testUnavailableCapabilityPreservesReasonAcrossSerialization() throws {
    let capability = Capability(id: "downloads", state: .unavailable, reason: "Source offline")
    let decoded = try JSONDecoder().decode(Capability.self, from: JSONEncoder().encode(capability))
    XCTAssertEqual(decoded, capability)
    XCTAssertEqual(
      CapabilityRequirements(supported: true, authenticated: true, granted: true, reachable: false)
        .state, .unavailable)
  }
}
