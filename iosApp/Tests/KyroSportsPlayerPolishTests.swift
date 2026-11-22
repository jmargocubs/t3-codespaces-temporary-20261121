import Foundation
import XCTest
@testable import Silo

/// Sports Hub player polish: the strip beneath the inline player, Other Streams' order, and the
/// internal Sports Match Report staying out of the normal interface.
@MainActor
final class KyroSportsPlayerPolishTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func channel(_ id: String, name: String? = nil) -> LiveTVChannel {
        LiveTVChannel(id: id, guideID: nil, name: name ?? "Stream \(id)",
                      streamURL: URL(string: "https://tv.example/\(id).ts")!, logoURL: nil, category: "Sports")
    }

    private func match(_ id: String, eligible: Bool = true,
                       source: KyroSportsStreamMatch.Source = .guide) -> KyroSportsStreamMatch {
        KyroSportsStreamMatch(id: id, channel: channel(id), program: nil, confidence: .high, score: 90, reasons: [],
                              isStale: false, source: source, isAutoPlayEligible: eligible)
    }

    private func game(league: KyroSportLeague = .nba, homeScore: Int? = 98, awayScore: Int? = 102) -> KyroSportsGame {
        let away = KyroSportsTeam(id: "a", league: league, abbreviation: "BOS", nickname: "Celtics", location: "Boston")
        let home = KyroSportsTeam(id: "h", league: league, abbreviation: "NYK", nickname: "Knicks", location: "New York")
        return KyroSportsGame(id: KyroGameID(provider: "espn", league: league, rawID: "1"), league: league,
                              startTime: now, status: .live,
                              home: KyroGameTeam(team: home, score: homeScore),
                              away: KyroGameTeam(team: away, score: awayScore))
    }

    private func context(_ game: KyroSportsGame, alternatives: [String] = ["a", "b"],
                         broadcasters: [String] = []) -> KyroSportsPlaybackContext {
        KyroSportsPlaybackContext(game: game, alternatives: alternatives.map { match($0) },
                                  broadcasters: broadcasters.map { match($0, eligible: false, source: .broadcaster) })
    }

    // MARK: Strip beneath the inline player

    func testInlineStripNamesTheMatchupTheStreamAndOffersItsActions() throws {
        let info = try XCTUnwrap(KyroSportsInlineInfo(
            mode: .playing(channel("a", name: "  ESPN   2 ")), context: context(game())))
        XCTAssertEqual(info.matchup, "Celtics at Knicks")
        XCTAssertEqual(info.score, "102–98")
        XCTAssertEqual(info.channelName, "ESPN 2", "catalog whitespace collapses for one line")
        XCTAssertTrue(info.isLive)
        XCTAssertEqual(info.location, .inline)
        XCTAssertTrue(info.showsPlaybackActions)
        XCTAssertTrue(info.hasOtherStreams)
    }

    func testStripWhileTheStreamIsElsewhereDescribesItWithoutActions() throws {
        let pip = try XCTUnwrap(KyroSportsInlineInfo(
            mode: .elsewhere(channel("a"), isPictureInPicture: true), context: context(game())))
        XCTAssertEqual(pip.location, .pictureInPicture)
        XCTAssertFalse(pip.showsPlaybackActions, "the window owns the stream; inline actions would act on nothing")
        let full = try XCTUnwrap(KyroSportsInlineInfo(
            mode: .elsewhere(channel("a"), isPictureInPicture: false), context: context(game())))
        XCTAssertEqual(full.location, .fullScreen)
    }

    func testNoStripWhileSearchingOrWithoutAnEvent() {
        XCTAssertNil(KyroSportsInlineInfo(mode: .finding, context: context(game())),
                     "the frame already shows the search status")
        XCTAssertNil(KyroSportsInlineInfo(mode: .hidden, context: context(game())))
        XCTAssertNil(KyroSportsInlineInfo(mode: .playing(channel("a")), context: nil))
    }

    func testTennisHasNoTeamScoreAndASingleStreamOffersNoOtherStreams() throws {
        let info = try XCTUnwrap(KyroSportsInlineInfo(
            mode: .playing(channel("a")), context: context(game(league: .atp), alternatives: ["a"])))
        XCTAssertEqual(info.matchup, "Celtics vs Knicks")
        XCTAssertNil(info.score)
        XCTAssertFalse(info.hasOtherStreams)
    }

    // MARK: Other Streams order

    func testOtherStreamsPutsTheCurrentStreamFirstThenPlayedThenUntriedThenFailed() {
        let statuses: [String: KyroSportsStreamStatus] = ["failed": .failed, "played": .verified, "now": .verified]
        let sections = KyroSportsStreamSection.make(
            matches: [match("failed"), match("untried"), match("played"), match("now"), match("weak", eligible: false)],
            broadcasters: [match("net", eligible: false, source: .broadcaster)],
            status: { statuses[$0] ?? .untested }, currentChannelID: "now")

        let ordered = KyroSportsStreamSection.prioritizedForSwitching(sections)
        XCTAssertEqual(ordered.map(\.kind), [.nowPlaying, .eventMatches, .possibleMatches, .networkChannels])
        XCTAssertEqual(ordered[0].rows.map(\.channelID), ["now"])
        XCTAssertTrue(ordered[0].rows[0].isCurrent)
        XCTAssertEqual(ordered[1].rows.map(\.channelID), ["played", "untried", "failed"])
        XCTAssertFalse(ordered.dropFirst().flatMap(\.rows).contains { $0.isCurrent },
                       "the current stream appears once")
    }

    func testOtherStreamsKeepsTheMatcherOrderWithinATier() {
        let sections = KyroSportsStreamSection.make(
            matches: [match("x"), match("y"), match("z")], broadcasters: [],
            status: { _ in .untested }, currentChannelID: nil)
        let ordered = KyroSportsStreamSection.prioritizedForSwitching(sections)
        XCTAssertEqual(ordered.map(\.kind), [.eventMatches], "no Now Playing group without a current stream")
        XCTAssertEqual(ordered[0].rows.map(\.channelID), ["x", "y", "z"])
    }

    func testAFailedCurrentStreamStaysOnTopAndCanBeRetried() {
        let sections = KyroSportsStreamSection.make(
            matches: [match("a"), match("b")], broadcasters: [],
            status: { $0 == "a" ? .failed : .untested }, currentChannelID: "a")
        let ordered = KyroSportsStreamSection.prioritizedForSwitching(sections)
        XCTAssertEqual(ordered.first?.kind, .nowPlaying)
        XCTAssertEqual(ordered.first?.rows.first?.status, .didNotPlay)
        XCTAssertEqual(ordered.first?.rows.first?.isSelectable, true)
    }

    // MARK: Internal diagnostics

    func testMatchReportStaysHiddenUnlessCompiledInAndTurnedOn() {
        XCTAssertFalse(KyroSportsDiagnosticsVisibility.showsMatchReport(isCompiledIn: true, isEnabled: false),
                       "internal builds keep the normal interface clean by default")
        XCTAssertFalse(KyroSportsDiagnosticsVisibility.showsMatchReport(isCompiledIn: false, isEnabled: true))
        XCTAssertTrue(KyroSportsDiagnosticsVisibility.showsMatchReport(isCompiledIn: true, isEnabled: true))
        XCTAssertFalse(UserDefaults(suiteName: "kyro.sports.polish.\(UUID().uuidString)")!
            .bool(forKey: KyroSportsDiagnosticsVisibility.defaultsKey), "the toggle defaults off")
    }
}
