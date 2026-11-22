import Foundation
import XCTest
@testable import Silo

/// Build 61 regressions that need app types the Mac-hosted harness cannot compile.
@MainActor
final class KyroBuild61RegressionTests: XCTestCase {
    /// Recording 404 s: on a cold start Live Now read "No games are live right now" while the
    /// selected sports were still loading; a moment later it said seven games were live.
    func testLiveNowSaysLoadingUntilTheSportsHaveAnswered() {
        let loading = KyroSportsLiveNowEmptyContent(status: .ready, liveEventCount: 0, category: .all, isLoadingScores: true)
        XCTAssertEqual(loading.title, "Loading live games…")
        XCTAssertTrue(loading.showsProgress)
        let nba = KyroSportsLiveNowEmptyContent(status: .ready, liveEventCount: 0, category: .nba, isLoadingScores: true)
        XCTAssertEqual(nba.title, "Loading live NBA games…")

        let answered = KyroSportsLiveNowEmptyContent(status: .ready, liveEventCount: 0, category: .all)
        XCTAssertEqual(answered.title, "No games are live right now")
        let live = KyroSportsLiveNowEmptyContent(status: .checking, liveEventCount: 7, category: .all, isLoadingScores: true)
        XCTAssertEqual(live.title, "Checking your channels…", "Known live games are never hidden behind loading")
    }
}
