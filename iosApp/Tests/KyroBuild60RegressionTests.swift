#if os(iOS)
import Foundation
import Observation
import XCTest
@testable import Silo

/// Build 60 regressions that need the app's iOS types (the watch screen's quality monitor and the
/// Sports Hub inline header).
@MainActor
final class KyroBuild60RegressionTests: XCTestCase {
    /// The monitor runs on every engine `objectWillChange` (once per live segment at least). An
    /// unchanged reading must not notify, or the watch screen redraws for nothing.
    func testQualityMonitorDoesNotNotifyForAnUnchangedReading() {
        let monitor = LiveTVWatchQualityMonitor()
        monitor.reset(for: "channel-a")
        var notified = false
        withObservationTracking { _ = monitor.badges } onChange: { notified = true }
        monitor.reset(for: "channel-a")
        XCTAssertFalse(notified)
        monitor.reset(for: "channel-b")
        XCTAssertTrue(notified, "A different channel still clears the badges")
    }

    /// Build 59 screenshot: the strip under the video read 96–112, 1:25 4th while the broadcast
    /// showed 97–112, 1:17. The header now follows the hub's refreshed copy of the same event.
    func testInlineHeaderShowsTheRefreshedScoreOfTheSameEventOnly() throws {
        let wizards = KyroSportsTeam(id: "espn.nba.27", league: .nba, abbreviation: "WSH", nickname: "Wizards", location: "Washington")
        let pacers = KyroSportsTeam(id: "espn.nba.11", league: .nba, abbreviation: "IND", nickname: "Pacers", location: "Indiana")
        let id = KyroGameID(provider: "espn", league: .nba, rawID: "401909966")
        func game(_ clock: String, away: Int) -> KyroSportsGame {
            KyroSportsGame(id: id, league: .nba, startTime: Date(), status: .live, statusDetail: clock,
                           home: KyroGameTeam(team: pacers, score: 112), away: KyroGameTeam(team: wizards, score: away))
        }
        let channel = LiveTVChannel(id: "p:1", guideID: nil, name: "US: Monumental Sports Network",
                                    streamURL: URL(string: "https://tv.example/1.ts")!, logoURL: nil, category: "Sports")
        let context = KyroSportsPlaybackContext(game: game("1:25 - 4th", away: 96), alternatives: [], broadcasters: [])

        let refreshed = try XCTUnwrap(KyroSportsInlineInfo(mode: .playing(channel), context: context,
                                                           current: game("1:17 - 4th", away: 97)))
        XCTAssertEqual(refreshed.score, "97–112")
        XCTAssertEqual(refreshed.statusLine, "1:17 - 4th")

        let other = KyroSportsGame(id: KyroGameID(provider: "espn", league: .wta, rawID: "187385"), league: .wta,
                                   startTime: Date(), status: .final, home: context.game.home, away: context.game.away)
        let ignored = try XCTUnwrap(KyroSportsInlineInfo(mode: .playing(channel), context: context, current: other))
        XCTAssertEqual(ignored.statusLine, "1:25 - 4th", "Another event's copy never replaces the pinned one")
    }
}
#endif
