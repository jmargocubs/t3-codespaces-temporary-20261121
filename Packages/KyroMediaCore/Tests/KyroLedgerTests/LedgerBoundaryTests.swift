import Foundation
import KyroFoundation
import KyroLedger
import XCTest

final class LedgerBoundaryTests: XCTestCase {
  func testDecodedProgressCannotBypassValidation() {
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        PlaybackProgress.self, from: Data(#"{"position":-1,"duration":100}"#.utf8)))
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        PlaybackProgress.self, from: Data(#"{"position":101,"duration":100}"#.utf8)))
  }
  func testSameClockRegistersConvergeAndRemovePreference() {
    let profile = KyroProfileID()
    let id = UUID()
    let clock = HybridLogicalClock(physicalMilliseconds: 10, logical: 0, node: "one")
    let a = LedgerOperation(
      id: id, profileID: profile, media: "film", value: .watchlist(true), clock: clock)
    let b = LedgerOperation(
      id: id, profileID: profile, media: "film", value: .watchlist(false), clock: clock)
    let lhs = LedgerState(operations: [a]).merged(with: LedgerState(operations: [b]))
    let rhs = LedgerState(operations: [b]).merged(with: LedgerState(operations: [a]))
    XCTAssertEqual(
      lhs.latest(profile: profile, media: "film", register: "watchlist"),
      rhs.latest(profile: profile, media: "film", register: "watchlist"))
    XCTAssertTrue(lhs.watchlist(profile: KyroProfileID()).isEmpty)
  }
}
