import Foundation
import XCTest
@testable import Silo

/// Build 70: the Stats tab's two-team player box scores, Other Streams' opening height, and the
/// rotation ledger that left UIKit animations off after a full-screen Picture in Picture test.
final class KyroBuild70SportsPolishTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_600_000)

    private func team(_ abbreviation: String, nickname: String, location: String?, league: KyroSportLeague,
                      alternates: [String] = []) -> KyroSportsTeam {
        KyroSportsTeam(id: "espn.\(league.rawValue).\(abbreviation)", league: league, abbreviation: abbreviation,
                       nickname: nickname, location: location, alternateNames: alternates)
    }

    private func game(_ rawID: String = "1", league: KyroSportLeague = .collegeFootball,
                      away: KyroSportsTeam? = nil, home: KyroSportsTeam? = nil) -> KyroSportsGame {
        let away = away ?? team("ILL", nickname: "Fighting Illini", location: "Illinois", league: league,
                                alternates: ["Illinois Fighting Illini", "Illinois"])
        let home = home ?? team("UCLA", nickname: "Bruins", location: "UCLA", league: league,
                                alternates: ["UCLA Bruins", "UCLA"])
        return KyroSportsGame(id: KyroGameID(provider: "espn", league: league, rawID: rawID), league: league,
                              startTime: now, status: .live,
                              home: KyroGameTeam(team: home, score: 19),
                              away: KyroGameTeam(team: away, score: 14))
    }

    private func boxScore(_ id: String, _ abbreviation: String, _ name: String,
                          players: [String] = ["A", "B"]) -> KyroSportsPlayerTeamBoxScore {
        let athletes = players.map {
            KyroSportsPlayerStatLine(providerAthleteID: "\(id)-\($0)", displayName: "\(name) \($0)", shortName: nil,
                                     position: nil, starter: true, values: ["1"])
        }
        return KyroSportsPlayerTeamBoxScore(providerTeamID: id, abbreviation: abbreviation, displayName: name,
                                            groups: athletes.isEmpty ? []
                                                : [KyroSportsPlayerStatGroup(name: "Passing", labels: ["YDS"], athletes: athletes)])
    }

    // MARK: Team order and default

    func testTeamsReadAwayThenHomeWhateverOrderTheProviderUses() {
        let game = game()
        let ucla = boxScore("26", "UCLA", "UCLA Bruins")
        let illinois = boxScore("356", "ILL", "Illinois Fighting Illini")

        let ordered = KyroSportsPlayerBoxScoreSelection.orderedTeams([ucla, illinois], game: game)

        XCTAssertEqual(ordered.map(\.id), ["356", "26"], "the selector reads like the comparison above: away | home")
        XCTAssertEqual(KyroSportsPlayerBoxScoreSelection().resolvedTeamID(in: ordered, gameID: game.id), "356",
                       "with no choice yet the first (away) team shows, as Build 69 listed it first")
    }

    func testAnUnmatchedTeamFollowsTheSidesAndADuplicateIsDropped() {
        let game = game()
        let illinois = boxScore("356", "ILL", "Illinois Fighting Illini")
        let other = boxScore("9", "ZZZ", "Unlisted")
        let ordered = KyroSportsPlayerBoxScoreSelection.orderedTeams([other, illinois, illinois], game: game)
        XCTAssertEqual(ordered.map(\.id), ["356", "9"])
    }

    func testSidesMatchThroughCanonicalAbbreviations() {
        let jaguars = team("JAX", nickname: "Jaguars", location: "Jacksonville", league: .nfl)
        let titans = team("TEN", nickname: "Titans", location: "Tennessee", league: .nfl)
        let game = game(league: .nfl, away: jaguars, home: titans)
        let ordered = KyroSportsPlayerBoxScoreSelection.orderedTeams(
            [boxScore("10", "TEN", "Tennessee Titans"), boxScore("30", "JAC", "Jacksonville Jaguars")], game: game)
        XCTAssertEqual(ordered.map(\.abbreviation), ["JAC", "TEN"], "ESPN's JAC is the scoreboard's JAX")
    }

    // MARK: Retention and reset

    func testAChoiceIsKeptForItsEventAndIgnoredForAnother() {
        let first = game("1")
        let teams = KyroSportsPlayerBoxScoreSelection.orderedTeams(
            [boxScore("356", "ILL", "Illinois"), boxScore("26", "UCLA", "UCLA")], game: first)
        var selection = KyroSportsPlayerBoxScoreSelection()
        selection.select("26", for: first.id)

        // Stats → Game → Stats re-reads the same selection the owning screen kept.
        XCTAssertEqual(selection.resolvedTeamID(in: teams, gameID: first.id), "26")

        let second = game("2")
        let secondTeams = KyroSportsPlayerBoxScoreSelection.orderedTeams(
            [boxScore("356", "ILL", "Illinois"), boxScore("26", "UCLA", "UCLA")], game: second)
        XCTAssertEqual(selection.resolvedTeamID(in: secondTeams, gameID: second.id), "356",
                       "another event starts on its first team, even with the same two teams")
    }

    func testAChosenTeamWhoseBoxScoreDisappearsFallsBackToTheFirst() {
        let game = game()
        var selection = KyroSportsPlayerBoxScoreSelection()
        selection.select("26", for: game.id)
        let onlyIllinois = [boxScore("356", "ILL", "Illinois")]
        XCTAssertEqual(selection.resolvedTeamID(in: onlyIllinois, gameID: game.id), "356")
        XCTAssertNil(selection.resolvedTeamID(in: [], gameID: game.id))
    }

    func testATeamWithoutPlayerStatisticsKeepsItsSegment() {
        let game = game()
        let ordered = KyroSportsPlayerBoxScoreSelection.orderedTeams(
            [boxScore("356", "ILL", "Illinois"), boxScore("26", "UCLA", "UCLA", players: [])], game: game)
        XCTAssertEqual(ordered.map(\.id), ["356", "26"],
                       "the empty side stays selectable and says it has nothing yet, rather than vanishing")
    }

    // MARK: Segment titles

    func testTitlesUseTheSchoolForCollegeFootballAndTheNicknameElsewhere() {
        let cfb = game()
        let cfbTeams = KyroSportsPlayerBoxScoreSelection.orderedTeams(
            [boxScore("356", "ILL", "Illinois Fighting Illini"), boxScore("26", "UCLA", "UCLA Bruins")], game: cfb)
        XCTAssertEqual(KyroSportsPlayerBoxScoreSelection.segmentTitles(for: cfbTeams, game: cfb), ["356": "Illinois", "26": "UCLA"])

        let knicks = team("NY", nickname: "Knicks", location: "New York", league: .nba)
        let pacers = team("IND", nickname: "Pacers", location: "Indiana", league: .nba)
        let nba = game(league: .nba, away: knicks, home: pacers)
        let nbaTeams = KyroSportsPlayerBoxScoreSelection.orderedTeams(
            [boxScore("18", "NY", "New York Knicks"), boxScore("11", "IND", "Indiana Pacers")], game: nba)
        XCTAssertEqual(KyroSportsPlayerBoxScoreSelection.segmentTitles(for: nbaTeams, game: nba), ["18": "Knicks", "11": "Pacers"])
        XCTAssertEqual(KyroSportsPlayerBoxScoreSelection.accessibilityName(for: nbaTeams[0], game: nba), "New York Knicks",
                       "VoiceOver hears the full name")
    }

    func testLongNamesShortenAndEqualTitlesFallBackToAbbreviations() {
        let city = team("MNC", nickname: "Manchester City", location: "Manchester City", league: .soccer,
                        alternates: ["Manchester City", "Man City"])
        let united = team("MAN", nickname: "Manchester United", location: "Manchester United", league: .soccer,
                          alternates: ["Manchester United"])
        let derby = game(league: .soccer, away: united, home: city)
        let teams = KyroSportsPlayerBoxScoreSelection.orderedTeams(
            [boxScore("360", "MAN", "Manchester United"), boxScore("382", "MNC", "Manchester City")], game: derby)
        XCTAssertEqual(KyroSportsPlayerBoxScoreSelection.segmentTitles(for: teams, game: derby), ["360": "MAN", "382": "Man City"],
                       "ESPN's short name when the nickname is too long, else the abbreviation")

        let tigersA = team("LSU", nickname: "Tigers", location: "Louisiana State", league: .nfl)
        let tigersB = team("MIZ", nickname: "Tigers", location: "Missouri", league: .nfl)
        let same = game(league: .nfl, away: tigersA, home: tigersB)
        let sameTeams = KyroSportsPlayerBoxScoreSelection.orderedTeams(
            [boxScore("99", "LSU", "LSU Tigers"), boxScore("142", "MIZ", "Missouri Tigers")], game: same)
        XCTAssertEqual(KyroSportsPlayerBoxScoreSelection.segmentTitles(for: sameTeams, game: same), ["99": "LSU", "142": "MIZ"])
    }

    // MARK: Real ESPN box score

    /// The Build 60 NBA fixture (Wizards at Pacers): each segment holds only its own team's players,
    /// and together they hold every player ESPN listed.
    func testRealBoxScoreSplitsIntoTwoCompleteUnmixedTeams() throws {
        let scoreboard = try JSONDecoder().decode(ESPNScoreboardResponse.self, from: Self.fixture("espn_b60_scoreboard_nba"))
        let event = try XCTUnwrap(scoreboard.events.first { $0.id == "401909966" })
        let game = try XCTUnwrap(ESPNMapping.game(from: event, league: .nba))
        let summary = try JSONDecoder().decode(ESPNEventSummaryResponse.self,
                                               from: Self.fixture("espn_b60_summary_nba_401909966"))
        let details = try ESPNEventDetailMapping.details(summary: summary, additionalNews: [], eventID: "401909966", game: game)

        let ordered = KyroSportsPlayerBoxScoreSelection.orderedTeams(details.playerBoxScores, game: game)

        XCTAssertEqual(ordered.map(\.abbreviation), ["WSH", "IND"])
        let athleteIDs = ordered.map { Set($0.groups.flatMap(\.athletes).map(\.id)) }
        XCTAssertTrue(athleteIDs[0].isDisjoint(with: athleteIDs[1]), "no player appears under both teams")
        XCTAssertEqual(athleteIDs[0].count + athleteIDs[1].count,
                       Set(details.playerBoxScores.flatMap { $0.groups.flatMap(\.athletes) }.map(\.id)).count,
                       "every listed player is still there")
        XCTAssertEqual(KyroSportsPlayerBoxScoreSelection.segmentTitles(for: ordered, game: game).count, 2)
    }

    static func fixture(_ name: String) throws -> Data {
        let bundled = Bundle(for: KyroBuild70SportsPolishTests.self).url(forResource: name, withExtension: "json")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ESPN/\(name).json")
        return try Data(contentsOf: bundled ?? source)
    }

    // MARK: Other Streams opening height

    func testOtherStreamsOpensJustBelowTheInlinePlayer() {
        // iPhone 16 Plus portrait: 932-point window, strip ending about 380 points down.
        let height = KyroSportsOtherStreamsSheetLayout.belowPlayerHeight(windowHeight: 932, playerBottom: 380)
        XCTAssertEqual(height, 544)
        XCTAssertGreaterThan(height ?? 0, 932 / 2, "taller than Build 69's half-height sheet")
    }

    func testOtherStreamsFallsBackToMediumWhenThePlayerIsUnmeasuredOrTall() {
        XCTAssertNil(KyroSportsOtherStreamsSheetLayout.belowPlayerHeight(windowHeight: 932, playerBottom: 0))
        XCTAssertNil(KyroSportsOtherStreamsSheetLayout.belowPlayerHeight(windowHeight: 0, playerBottom: 380))
        XCTAssertNil(KyroSportsOtherStreamsSheetLayout.belowPlayerHeight(windowHeight: 932, playerBottom: 940))
        XCTAssertNil(KyroSportsOtherStreamsSheetLayout.belowPlayerHeight(windowHeight: 932, playerBottom: 600),
                     "a player covering most of the window (large text) leaves too little; .medium is used")
    }

    func testOtherStreamsNeverOpensAtFullHeight() {
        let height = KyroSportsOtherStreamsSheetLayout.belowPlayerHeight(windowHeight: 1000, playerBottom: 40)
        XCTAssertEqual(height, 850)
    }

    // MARK: Rotation animation ledger

    func testOneSuppressedRotationRestoresAnimationsWhenItCompletes() {
        var ledger = PlayerAnimationSuppression()
        let token = ledger.begin()
        XCTAssertTrue(ledger.isSuppressing)
        XCTAssertTrue(ledger.end(token))
        XCTAssertFalse(ledger.isSuppressing)
    }

    /// The Build 69 failure: full screen's landscape rotation had not completed when Picture in
    /// Picture asked for portrait. Animations come back once, with the last completion, in either order.
    func testOverlappingRotationsRestoreOnlyWithTheLastCompletionInEitherOrder() {
        for firstEndsFirst in [true, false] {
            var ledger = PlayerAnimationSuppression()
            let landscape = ledger.begin()
            let portrait = ledger.begin()
            let (earlier, later) = firstEndsFirst ? (landscape, portrait) : (portrait, landscape)
            XCTAssertFalse(ledger.end(earlier), "one rotation is still running")
            XCTAssertTrue(ledger.isSuppressing)
            XCTAssertTrue(ledger.end(later))
            XCTAssertFalse(ledger.isSuppressing)
        }
    }

    func testTheDeadlineAfterACompletionAndAnUnknownTokenDoNothing() {
        var ledger = PlayerAnimationSuppression()
        let token = ledger.begin()
        XCTAssertTrue(ledger.end(token))
        XCTAssertFalse(ledger.end(token), "the deadline firing after the completion")
        XCTAssertFalse(ledger.end(999))
        let next = ledger.begin()
        XCTAssertNotEqual(next, token, "tokens are never reused, so a late deadline cannot end a new rotation")
        XCTAssertFalse(ledger.end(token))
        XCTAssertTrue(ledger.isSuppressing)
    }
}
