import Foundation
import XCTest
@testable import Silo

/// Build 67 Sports Hub refinement: Live Now's layout around the pinned player, the strip that keeps
/// its height while a stream connects, schedule-card period columns, tennis set emphasis and the
/// statistic comparison bars.
@MainActor
final class KyroBuild67SportsLayoutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func channel(_ id: String, name: String? = nil) -> LiveTVChannel {
        LiveTVChannel(id: id, guideID: nil, name: name ?? "Stream \(id)",
                      streamURL: URL(string: "https://tv.example/\(id).ts")!, logoURL: nil, category: "Sports")
    }

    private func match(_ id: String) -> KyroSportsStreamMatch {
        KyroSportsStreamMatch(id: id, channel: channel(id), program: nil, confidence: .high, score: 90, reasons: [],
                              isStale: false, source: .guide, isAutoPlayEligible: true)
    }

    private func game(_ rawID: String = "1", league: KyroSportLeague = .nhl, status: KyroGameStatus = .live,
                      homeScore: Int? = 2, awayScore: Int? = 5, periods: [KyroGamePeriod] = []) -> KyroSportsGame {
        let away = KyroSportsTeam(id: "a\(rawID)", league: league, abbreviation: "NYI", nickname: "Islanders", location: "New York")
        let home = KyroSportsTeam(id: "h\(rawID)", league: league, abbreviation: "LA", nickname: "Kings", location: "Los Angeles")
        return KyroSportsGame(id: KyroGameID(provider: "espn", league: league, rawID: rawID), league: league,
                              startTime: now, status: status,
                              home: KyroGameTeam(team: home, score: homeScore),
                              away: KyroGameTeam(team: away, score: awayScore),
                              periods: periods)
    }

    private func item(_ rawID: String) -> KyroSportsLiveNowModel.Item {
        KyroSportsLiveNowModel.Item(game: game(rawID), streamCount: 3)
    }

    // MARK: Live Now

    func testLiveNowLeavesOutThePinnedEventAndHidesWhenNothingElseIsLive() {
        let items = [item("1"), item("2")]
        let pinned = items[0].id
        XCTAssertEqual(KyroSportsLiveNowLayout.visibleItems(items, pinnedGameID: nil).map(\.id), items.map(\.id))
        XCTAssertEqual(KyroSportsLiveNowLayout.visibleItems(items, pinnedGameID: pinned).map(\.id), [items[1].id])

        XCTAssertTrue(KyroSportsLiveNowLayout.showsSection(visibleItemCount: 0, hasPinnedEvent: false),
                      "unpinned, the section keeps its fixed height in every state")
        XCTAssertFalse(KyroSportsLiveNowLayout.showsSection(visibleItemCount: 0, hasPinnedEvent: true),
                       "pinned with nothing else live, the section would only repeat the player")
        XCTAssertTrue(KyroSportsLiveNowLayout.showsSection(visibleItemCount: 1, hasPinnedEvent: true))
    }

    func testLiveNowColumnsFollowTheNumberOfCardsUpToTheTextSizeLimit() {
        XCTAssertEqual(KyroSportsLiveNowLayout.columns(itemCount: 1, isAccessibilitySize: false, isExtraLarge: false), 1,
                       "a single live event takes the whole row (Build 66 left two thirds empty)")
        XCTAssertEqual(KyroSportsLiveNowLayout.columns(itemCount: 2, isAccessibilitySize: false, isExtraLarge: false), 2)
        XCTAssertEqual(KyroSportsLiveNowLayout.columns(itemCount: 7, isAccessibilitySize: false, isExtraLarge: false), 3)
        XCTAssertEqual(KyroSportsLiveNowLayout.columns(itemCount: 7, isAccessibilitySize: false, isExtraLarge: true), 2)
        XCTAssertEqual(KyroSportsLiveNowLayout.columns(itemCount: 7, isAccessibilitySize: true, isExtraLarge: true), 1)
        XCTAssertEqual(KyroSportsLiveNowLayout.columns(itemCount: 0, isAccessibilitySize: false, isExtraLarge: false), 1)
    }

    // MARK: Strip under the inline player

    func testStripNamesTheEventWhileSearchingAndConnectingSoItsHeightNeverChanges() throws {
        let event = game()
        let searching = try XCTUnwrap(KyroSportsInlineStrip.make(
            mode: .finding, phase: .searching(event.id), context: nil, current: nil, games: [event]))
        XCTAssertEqual(searching.game.id, event.id)
        XCTAssertEqual(searching.stream, .finding("Finding a stream"))
        XCTAssertFalse(searching.showsPlaybackActions)
        XCTAssertEqual(searching.awayScore, "5")

        let context = KyroSportsPlaybackContext(game: event, alternatives: [match("a"), match("b")], broadcasters: [])
        let connecting = try XCTUnwrap(KyroSportsInlineStrip.make(
            mode: .finding, phase: .connecting(channelName: "SportsNet", attempt: 2, total: 3),
            context: context, current: nil, games: []))
        XCTAssertEqual(connecting.stream, .finding("Connecting · Stream 2 of 3"))

        let playing = try XCTUnwrap(KyroSportsInlineStrip.make(
            mode: .playing(channel("a", name: " SportsNet  Pacific ")), phase: .presented, context: context,
            current: game(homeScore: 3), games: []))
        XCTAssertEqual(playing.stream, .playing(name: "SportsNet Pacific", location: .inline))
        XCTAssertTrue(playing.showsPlaybackActions)
        XCTAssertTrue(playing.hasOtherStreams)
        XCTAssertEqual(playing.homeScore, "3", "the pinned event's refreshed score wins over the context snapshot")
    }

    func testStripIsAbsentWhenHiddenOrTheSearchedEventIsUnknown() {
        let event = game()
        XCTAssertNil(KyroSportsInlineStrip.make(mode: .hidden, phase: .idle, context: nil, current: nil, games: [event]))
        XCTAssertNil(KyroSportsInlineStrip.make(mode: .finding, phase: .searching(game("9").id), context: nil,
                                                current: nil, games: [event]))
    }

    func testTennisStripHasNoTeamScore() throws {
        let match = game(league: .atp, homeScore: 1, awayScore: 2)
        let strip = try XCTUnwrap(KyroSportsInlineStrip.make(
            mode: .finding, phase: .searching(match.id), context: nil, current: nil, games: [match]))
        XCTAssertNil(strip.awayScore)
        XCTAssertNil(strip.homeScore)
        XCTAssertEqual(strip.accessibilityMatchup, "Islanders vs Kings")
    }

    func testConnectingStatusKeepsTheWholeChannelNameOffTheTitle() throws {
        let status = try XCTUnwrap(KyroSportsConnectingStatus(
            phase: .connecting(channelName: "CA  Prime Sportsnet Pacific FHD V2", attempt: 1, total: 3), games: []))
        XCTAssertEqual(status.title, "Connecting")
        XCTAssertEqual(status.detail, "CA Prime Sportsnet Pacific FHD V2")
        XCTAssertEqual(status.attempt, "Stream 1 of 3")
        let single = try XCTUnwrap(KyroSportsConnectingStatus(
            phase: .connecting(channelName: "ESPN", attempt: 1, total: 1), games: []))
        XCTAssertNil(single.attempt)
    }

    // MARK: Schedule cards

    func testCardsShowUpToSixScoredPeriodColumns() {
        let quarters = (1...4).map { KyroGamePeriod(id: "q\($0)", label: "Q\($0)", homeScore: 7, awayScore: 3) }
        XCTAssertTrue(KyroSportsCardPeriods.shows(quarters, isAccessibilitySize: false))
        XCTAssertFalse(KyroSportsCardPeriods.shows(quarters, isAccessibilitySize: true),
                       "at accessibility sizes the team names get the width")
        let innings = (1...9).map { KyroGamePeriod(id: "i\($0)", label: "\($0)", homeScore: 0, awayScore: 1) }
        XCTAssertFalse(KyroSportsCardPeriods.shows(innings, isAccessibilitySize: false),
                       "nine innings stay on the Game tab")
        let unscored = [KyroGamePeriod(id: "q1", label: "Q1", homeScore: nil, awayScore: nil)]
        XCTAssertFalse(KyroSportsCardPeriods.shows(unscored, isAccessibilitySize: false))
    }

    func testTennisSetWinnersSkipTheSetStillInPlay() {
        let sets = [KyroGamePeriod(id: "set1", label: "Set 1", homeScore: 4, awayScore: 6),
                    KyroGamePeriod(id: "set2", label: "Set 2", homeScore: 7, awayScore: 5),
                    KyroGamePeriod(id: "set3", label: "Set 3", homeScore: 2, awayScore: 3)]
        XCTAssertEqual(KyroSportsTennisSets.winners(of: sets, isFinal: false), [.away, .home, nil])
        XCTAssertEqual(KyroSportsTennisSets.winners(of: sets, isFinal: true), [.away, .home, .away])
        let level = [KyroGamePeriod(id: "set1", label: "Set 1", homeScore: 3, awayScore: 3)]
        XCTAssertEqual(KyroSportsTennisSets.winners(of: level, isFinal: true), [nil])
    }

    // MARK: Statistic comparison

    func testComparisonReadsTheLeadingNumberOrTheRate() {
        XCTAssertEqual(KyroSportsStatComparison.number(in: "62%"), 62)
        XCTAssertEqual(KyroSportsStatComparison.number(in: "38-85"), 38)
        XCTAssertEqual(KyroSportsStatComparison.number(in: "7/12 (58%)"), 58)
        XCTAssertEqual(KyroSportsStatComparison.number(in: "33.3"), 33.3)
        XCTAssertEqual(KyroSportsStatComparison.number(in: "+4"), 4)
        XCTAssertNil(KyroSportsStatComparison.number(in: "28:14"), "clock values are not compared")
        XCTAssertNil(KyroSportsStatComparison.number(in: "–"))
        XCTAssertNil(KyroSportsStatComparison.number(in: "N/A"))
    }

    func testComparisonSharesAreProportionsAndSkipZeroPairs() throws {
        let shares = try XCTUnwrap(KyroSportsStatComparison.shares(away: "30", home: "10"))
        XCTAssertEqual(shares.away, 0.75, accuracy: 0.0001)
        XCTAssertEqual(shares.home, 0.25, accuracy: 0.0001)
        XCTAssertNil(KyroSportsStatComparison.shares(away: "0", home: "0"))
        XCTAssertNil(KyroSportsStatComparison.shares(away: "12", home: "–"))
    }
}
