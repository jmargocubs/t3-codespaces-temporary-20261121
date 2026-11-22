import Foundation
import XCTest
@testable import Silo

@MainActor
final class KyroSportsEventPreviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func game(_ league: KyroSportLeague, _ status: KyroGameStatus = .scheduled,
                      id: String? = nil, offset: TimeInterval = 0) -> KyroSportsGame {
        KyroSportsGame(id: KyroGameID(provider: "espn", league: league, rawID: id ?? league.rawValue),
                       league: league, startTime: now.addingTimeInterval(offset), status: status,
                       home: KyroGameTeam(team: .placeholder(abbreviation: "HOM", league: league)),
                       away: KyroGameTeam(team: .placeholder(abbreviation: "AWY", league: league)))
    }

    private func match(_ id: String, source: KyroSportsStreamMatch.Source = .guide,
                       eligible: Bool = true, stale: Bool = false,
                       withProgramme: Bool = true) -> KyroSportsStreamMatch {
        let channel = LiveTVChannel(id: id, guideID: nil, name: id,
                                    streamURL: URL(string: "https://example.com/\(id).ts")!,
                                    logoURL: nil, category: "Sports")
        let programme = withProgramme
            ? EPGProgram(channelID: id, start: now, end: now.addingTimeInterval(7200), title: "AWY at HOM")
            : nil
        return KyroSportsStreamMatch(id: id, channel: channel, program: programme,
                                     confidence: eligible ? .high : .medium, score: 80,
                                     reasons: [], isStale: stale, source: source,
                                     isAutoPlayEligible: eligible)
    }

    private func result(_ matches: [KyroSportsStreamMatch]) -> KyroSportsStreamMatchResult {
        KyroSportsStreamMatchResult(confidence: .high, matches: matches,
                                    manualSearchQuery: "", guideWasStale: false, indexWasCancelled: false)
    }

    func testAllSevenSportsKeepOrderAndDistinctIdentity() {
        let games = KyroSportsDaySchedule.sectionOrder.reversed().map { game($0) }
        let sections = KyroSportsDaySchedule.sportSections(from: games)
        XCTAssertEqual(sections.map(\.league), KyroSportsDaySchedule.sectionOrder)
        XCTAssertEqual(Set(sections.map { $0.league.symbolName }).count, 5,
                       "NFL/NCAA and ATP/WTA share recognizable sport symbols")
        XCTAssertEqual(Set(sections.map { $0.league.accentRGB }).count, 7)
        XCTAssertEqual(KyroSportLeague.nfl.symbolName, "football.fill")
        XCTAssertEqual(KyroSportLeague.wta.symbolName, "tennisball.fill")
    }

    func testAllSportsOrdersEventsWithinEachSportWithoutDroppingOne() {
        let games = KyroSportsDaySchedule.sectionOrder.flatMap { league in
            [game(league, id: "later", offset: 3600), game(league, .live, id: "live", offset: -3600)]
        }
        let sections = KyroSportsDaySchedule.sportSections(from: games)
        XCTAssertEqual(sections.count, 7)
        XCTAssertTrue(sections.allSatisfy { $0.games.map(\.id.rawID) == ["live", "later"] })
    }

    func testPreviewRoutesEveryStatusWithoutGrantingPlayback() {
        XCTAssertEqual(KyroSportsEventPreviewPolicy.mode(for: .scheduled), .upcoming)
        XCTAssertEqual(KyroSportsEventPreviewPolicy.mode(for: .live), .live)
        XCTAssertEqual(KyroSportsEventPreviewPolicy.mode(for: .final), .completed)
        for status in [KyroGameStatus.postponed, .canceled, .suspended] {
            XCTAssertEqual(KyroSportsEventPreviewPolicy.mode(for: status), .interrupted)
            XCTAssertFalse(KyroSportsPlaybackEligibility.isInProgress(game(.nfl, status)))
        }
        XCTAssertEqual(KyroSportsEventPreviewPolicy.mode(for: .unknown("delayed")), .unknown)
        XCTAssertFalse(KyroSportsPlaybackEligibility.isInProgress(game(.nfl)))
        XCTAssertFalse(KyroSportsPlaybackEligibility.isInProgress(game(.nfl, .final)))
    }

    func testExpectedBroadcastsRequireFreshStrongEventSpecificGuideEvidence() {
        let matches = [match("guide"), match("network", source: .broadcaster),
                       match("name", source: .channelName, withProgramme: false),
                       match("weak", eligible: false), match("old", stale: true),
                       match("missing", withProgramme: false)]
        XCTAssertEqual(KyroSportsEventPreviewPolicy.expectedBroadcasts(from: result(matches)).map(\.id), ["guide"])
        XCTAssertEqual(KyroSportsEventPreviewPolicy.liveStreams(from: result(matches)).map(\.id),
                       ["guide", "name", "old", "missing"])
        XCTAssertTrue(KyroSportsEventPreviewPolicy.expectedBroadcasts(from: result([])).isEmpty)
    }
}
