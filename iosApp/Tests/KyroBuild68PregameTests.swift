import Foundation
import XCTest
@testable import Silo

/// Build 68 pregame mode: what an upcoming event's ESPN summary becomes (records, form, meetings,
/// standings, leaders, injuries and season figures kept apart from the game's box score), the
/// lifecycle from scheduled to live to final, the detail store's per-event reuse, news
/// de-duplication, local start times and tennis surfaces. Fixtures: Tests/Fixtures/ESPN/SOURCE.
final class KyroBuild68PregameTests: XCTestCase {

    // MARK: Fixtures

    private struct Case {
        let fixture: String
        let league: KyroSportLeague
        let competitionKey: String?
    }

    private let cases = [
        Case(fixture: "espn_b68_pregame_nba", league: .nba, competitionKey: nil),
        Case(fixture: "espn_b68_pregame_nhl", league: .nhl, competitionKey: nil),
        Case(fixture: "espn_b68_pregame_nfl", league: .nfl, competitionKey: nil),
        Case(fixture: "espn_b68_pregame_cfb", league: .collegeFootball, competitionKey: nil),
        Case(fixture: "espn_b68_pregame_soccer", league: .soccer, competitionKey: "eng.1"),
    ]

    private func fixtureData(named name: String) throws -> Data {
        let bundled = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ESPN/\(name).json")
        return try Data(contentsOf: try XCTUnwrap(bundled ?? (FileManager.default.fileExists(atPath: source.path) ? source : nil)))
    }

    private func summary(_ data: Data) throws -> ESPNEventSummaryResponse {
        try JSONDecoder().decode(ESPNEventSummaryResponse.self, from: data)
    }

    /// The selected game as the scoreboard would describe it, from the summary's own competitors.
    private func game(for summary: ESPNEventSummaryResponse, league: KyroSportLeague, competitionKey: String?,
                      status: KyroGameStatus = .scheduled) throws -> KyroSportsGame {
        let eventID = try XCTUnwrap(summary.header?.id)
        let competitors = try XCTUnwrap(summary.header?.competitions?.first?.competitors)
        func side(_ homeAway: String) throws -> KyroGameTeam {
            let competitor = try XCTUnwrap(competitors.first { $0.homeAway == homeAway })
            let wire = try XCTUnwrap(competitor.team)
            let abbreviation = try XCTUnwrap(wire.abbreviation)
            return KyroGameTeam(team: KyroSportsTeam(
                id: "espn.\(league.rawValue).\(wire.id ?? abbreviation)", league: league,
                abbreviation: abbreviation, nickname: wire.shortDisplayName ?? wire.displayName ?? abbreviation))
        }
        return KyroSportsGame(id: KyroGameID(provider: "espn", league: league, rawID: eventID), league: league,
                              startTime: ISO8601DateFormatter().date(from: "2026-11-14T00:00:00Z"), status: status,
                              home: try side("home"), away: try side("away"), competitionKey: competitionKey)
    }

    private func details(_ name: String, league: KyroSportLeague, competitionKey: String? = nil,
                         status: KyroGameStatus = .scheduled,
                         mutate: ((inout [String: Any]) -> Void)? = nil) throws -> KyroSportsEventDetails {
        var data = try fixtureData(named: name)
        if let mutate {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            mutate(&object)
            data = try JSONSerialization.data(withJSONObject: object)
        }
        let decoded = try summary(data)
        let selected = try game(for: decoded, league: league, competitionKey: competitionKey, status: status)
        return try ESPNEventDetailMapping.details(summary: decoded, additionalNews: [],
                                                  eventID: try XCTUnwrap(decoded.header?.id), game: selected)
    }

    /// Sets the header competition's status, as ESPN reports a game that started, finished or was
    /// postponed. Everything else in the summary stays as captured.
    private func status(_ state: String, completed: Bool) -> (inout [String: Any]) -> Void {
        { object in
            guard var header = object["header"] as? [String: Any],
                  var competitions = header["competitions"] as? [[String: Any]], !competitions.isEmpty else { return }
            competitions[0]["status"] = ["type": ["state": state, "completed": completed]]
            header["competitions"] = competitions
            object["header"] = header
        }
    }

    // MARK: Season figures are never the game's box score

    func testUpcomingSummariesMoveSeasonFiguresOutOfTheBoxScoreInEveryLeague() throws {
        for item in cases {
            let details = try details(item.fixture, league: item.league, competitionKey: item.competitionKey)
            XCTAssertEqual(details.statisticsPhase, .pregame, item.fixture)
            XCTAssertTrue(details.teamStatistics.isEmpty, "\(item.fixture): season averages are not this game's box score")
            XCTAssertTrue(details.playerBoxScores.isEmpty, item.fixture)
            XCTAssertTrue(details.matchEvents.isEmpty, item.fixture)
            XCTAssertFalse(details.hasStatistics, item.fixture)

            let pregame = try XCTUnwrap(details.pregame, item.fixture)
            let away = try XCTUnwrap(pregame.away, item.fixture)
            let home = try XCTUnwrap(pregame.home, item.fixture)
            XCTAssertFalse(away.seasonStatistics.isEmpty, item.fixture)
            XCTAssertFalse(home.seasonStatistics.isEmpty, item.fixture)
            XCTAssertTrue(away.records.contains { $0.label.hasPrefix("Overall") }, item.fixture)
            XCTAssertEqual(away.recent.count, 5, item.fixture)
            XCTAssertEqual(home.recent.count, 5, item.fixture)
            for team in [away, home] {
                let dates = team.recent.compactMap(\.date)
                XCTAssertEqual(dates, dates.sorted(by: >), "\(item.fixture): newest first")
            }
            XCTAssertFalse(away.leaders.isEmpty, item.fixture)
            XCTAssertTrue(pregame.standings.allSatisfy { $0.rows.contains(where: \.isSelected) }, item.fixture)
            XCTAssertTrue(pregame.hasGameContent && pregame.hasStatsContent, item.fixture)
            XCTAssertNotNil(pregame.venue, item.fixture)
        }
    }

    func testStreakAndLastTenAreRecordsNotComparedStatistics() throws {
        let pregame = try XCTUnwrap(try details("espn_b68_pregame_nba", league: .nba).pregame)
        let knicks = try XCTUnwrap(pregame.away)
        XCTAssertEqual(knicks.abbreviation, "NY")
        XCTAssertEqual(knicks.records.first { $0.label == "Overall" }?.value, "6-5")
        XCTAssertEqual(knicks.records.first { $0.label == "Road" }?.value, "2-2")
        XCTAssertEqual(knicks.records.first { $0.label == "Streak" }?.value, "L1")
        XCTAssertEqual(knicks.records.first { $0.label == "Last 10" }?.value, "6-4")
        let labels = knicks.seasonStatistics.map(\.label)
        XCTAssertFalse(labels.contains("Streak"))
        XCTAssertFalse(labels.contains("Last Ten Games"))
        XCTAssertEqual(knicks.seasonStatistics.first { $0.label == "Points Per Game" }?.value, "110.3")
    }

    func testSoccerAndHockeyRecordsSayWhatTheirThreeParts() throws {
        let soccer = try XCTUnwrap(try details("espn_b68_pregame_soccer", league: .soccer, competitionKey: "eng.1").pregame)
        XCTAssertEqual(soccer.home?.records.first?.label, "Overall (W-D-L)")
        XCTAssertNotNil(soccer.home?.records.first { $0.label == "Points" })
        let hockey = try XCTUnwrap(try details("espn_b68_pregame_nhl", league: .nhl).pregame)
        XCTAssertEqual(hockey.home?.records.first?.label, "Overall (W-L-OT)")
    }

    // MARK: Recent form

    func testRecentGamesReadFromTheTeamsOwnSide() throws {
        let pregame = try XCTUnwrap(try details("espn_b68_pregame_nba", league: .nba).pregame)
        let pacers = try XCTUnwrap(pregame.home)
        // Captured: 2026-11-03 Indiana lost 104-108 at home to Atlanta (ESPN's `score` reads "108-104").
        let loss = try XCTUnwrap(pacers.recent.first { $0.opponent == "ATL" })
        XCTAssertTrue(loss.isHome)
        XCTAssertEqual(loss.outcome, .loss)
        XCTAssertEqual(loss.scoreLine, "104–108")
        XCTAssertNil(loss.competition, "a league game is not labelled with its competition")
        let road = try XCTUnwrap(pacers.recent.first { $0.opponent == "MEM" })
        XCTAssertFalse(road.isHome)
        XCTAssertEqual(road.outcome, .win)
        XCTAssertEqual(road.scoreLine, "107–103")
    }

    func testSoccerFormNamesCupTiesAndShootouts() throws {
        let pregame = try XCTUnwrap(try details("espn_b68_pregame_soccer", league: .soccer, competitionKey: "eng.1").pregame)
        let city = try XCTUnwrap(pregame.home)
        XCTAssertEqual(city.abbreviation, "MNC")
        let cup = try XCTUnwrap(city.recent.first { $0.opponent == "BHA" && $0.competition != nil })
        XCTAssertEqual(cup.competition, "Carabao Cup")
        XCTAssertEqual(cup.scoreLine, "2–2 (pens)", "a level score with a result went to penalties")
        XCTAssertTrue(city.recent.contains { $0.competition == "UEFA Champions League" })
        XCTAssertTrue(city.recent.filter { $0.opponent == "NFO" || $0.opponent == "AVL" }.allSatisfy { $0.competition == nil },
                      "Premier League games are the selected competition")
    }

    // MARK: Standings, meetings, leaders, injuries

    func testStandingsShowSmallGroupsWholeAndOnlyTheSelectedTeamsOfLargeOnes() throws {
        let nba = try XCTUnwrap(try details("espn_b68_pregame_nba", league: .nba).pregame)
        XCTAssertEqual(nba.standings.map(\.title), ["Atlantic", "Central"])
        XCTAssertEqual(nba.standings.first?.columns, ["W", "L", "PCT", "GB"])
        XCTAssertTrue(nba.standings.allSatisfy { !$0.isAbridged })
        XCTAssertEqual(nba.standings.flatMap(\.rows).filter(\.isSelected).count, 2)

        let cfb = try XCTUnwrap(try details("espn_b68_pregame_cfb", league: .collegeFootball).pregame)
        let bigTen = try XCTUnwrap(cfb.standings.first)
        XCTAssertEqual(bigTen.totalTeams, 18)
        XCTAssertTrue(bigTen.isAbridged)
        XCTAssertEqual(bigTen.rows.count, 2)
        XCTAssertTrue(bigTen.rows.allSatisfy(\.isSelected))
        XCTAssertEqual(bigTen.columns, ["CONF", "OVR"])
        XCTAssertEqual(bigTen.rows.first?.position, 1, "positions are kept from the full table")

        let soccer = try XCTUnwrap(try details("espn_b68_pregame_soccer", league: .soccer, competitionKey: "eng.1").pregame)
        XCTAssertEqual(soccer.standings.first?.columns, ["GP", "W", "D", "L", "GD", "PTS"])
        XCTAssertEqual(soccer.standings.first?.rows.count, 2)
    }

    func testMeetingsLeaveOutTheSelectedEventAndListNewestFirst() throws {
        let nhl = try XCTUnwrap(try details("espn_b68_pregame_nhl", league: .nhl).pregame)
        let series = try XCTUnwrap(nhl.series.first)
        XCTAssertEqual(series.summary, "NYR lead series 1-0")
        XCTAssertEqual(series.meetings.count, 1)
        XCTAssertEqual(series.meetings.first?.winner, "NYR")
        XCTAssertEqual(series.meetings.first?.homeScore, "6")
        XCTAssertFalse(series.meetings.contains { $0.id == "401892706" })

        let soccer = try XCTUnwrap(try details("espn_b68_pregame_soccer", league: .soccer, competitionKey: "eng.1").pregame)
        let meetings = try XCTUnwrap(soccer.series.first?.meetings)
        XCTAssertFalse(meetings.isEmpty)
        XCTAssertFalse(meetings.contains { $0.id == "401879233" })
        let dates = meetings.compactMap(\.date)
        XCTAssertEqual(dates, dates.sorted(by: >))

        // The NBA series lists only this game and two later ones: nothing to show yet.
        let nba = try XCTUnwrap(try details("espn_b68_pregame_nba", league: .nba).pregame)
        XCTAssertTrue(nba.series.isEmpty)
    }

    func testLeadersInjuriesAndVenueComeFromTheSelectedTeams() throws {
        let pregame = try XCTUnwrap(try details("espn_b68_pregame_nba", league: .nba).pregame)
        let points = try XCTUnwrap(pregame.home?.leaders.first { $0.id == "pointsPerGame" })
        XCTAssertEqual(points.athlete, "Pascal Siakam")
        XCTAssertEqual(points.value, "22.7")
        let injury = try XCTUnwrap(pregame.home?.injuries.first)
        XCTAssertEqual(injury.name, "T.J. McConnell")
        XCTAssertEqual(injury.status, "Day-To-Day")
        XCTAssertEqual(injury.detail, "Hamstring Strain")
        XCTAssertEqual(pregame.away?.injuries, [], "ESPN lists the Knicks with no injuries")
        XCTAssertEqual(pregame.venue, "Gainbridge Fieldhouse, Indianapolis, IN")
    }

    func testThePreviewArticleLeadsTheNewsAndIsLabelled() throws {
        let details = try details("espn_b68_pregame_nba", league: .nba)
        let first = try XCTUnwrap(details.news.first)
        XCTAssertEqual(first.id, "50459634")
        XCTAssertEqual(first.relevance, .event)
        XCTAssertTrue(first.isPreview)
        XCTAssertTrue(details.news.dropFirst().allSatisfy { !$0.isPreview })
    }

    // MARK: Lifecycle

    func testStatisticsPhaseComesFromTheSummaryStatus() {
        XCTAssertEqual(KyroSportsStatisticsPhase(espnState: "pre", completed: false), .pregame)
        XCTAssertEqual(KyroSportsStatisticsPhase(espnState: "in", completed: false), .live)
        XCTAssertEqual(KyroSportsStatisticsPhase(espnState: "post", completed: true), .final)
        XCTAssertEqual(KyroSportsStatisticsPhase(espnState: "post", completed: nil), .final)
        XCTAssertEqual(KyroSportsStatisticsPhase(espnState: "post", completed: false), .interrupted)
        XCTAssertEqual(KyroSportsStatisticsPhase(espnState: nil, completed: nil), .unknown)
        XCTAssertFalse(KyroSportsStatisticsPhase.pregame.carriesEventStatistics)
        XCTAssertFalse(KyroSportsStatisticsPhase.interrupted.carriesEventStatistics)
        XCTAssertTrue(KyroSportsStatisticsPhase.live.carriesEventStatistics)
        XCTAssertTrue(KyroSportsStatisticsPhase.unknown.carriesEventStatistics, "Build 67 fixtures carry no status")
    }

    func testTheSameEventMovesFromPregameToLiveToFinal() throws {
        let pregame = try details("espn_b68_pregame_nba", league: .nba)
        XCTAssertNotNil(pregame.pregame)
        XCTAssertTrue(pregame.teamStatistics.isEmpty)

        let live = try details("espn_b68_pregame_nba", league: .nba, status: .live, mutate: status("in", completed: false))
        XCTAssertEqual(live.statisticsPhase, .live)
        XCTAssertNil(live.pregame, "pregame context never sits beside a live box score")
        XCTAssertFalse(live.teamStatistics.isEmpty)

        let final = try details("espn_b68_pregame_nba", league: .nba, status: .final, mutate: status("post", completed: true))
        XCTAssertEqual(final.statisticsPhase, .final)
        XCTAssertNil(final.pregame)
        XCTAssertEqual(final.gameID, pregame.gameID)
        XCTAssertEqual(final.providerEventID, pregame.providerEventID)
    }

    func testPostponedEventsShowNeitherABoxScoreNorSeasonFigures() throws {
        let postponed = try details("espn_b68_pregame_nhl", league: .nhl, status: .postponed,
                                    mutate: status("post", completed: false))
        XCTAssertEqual(postponed.statisticsPhase, .interrupted)
        XCTAssertTrue(postponed.teamStatistics.isEmpty)
        XCTAssertNil(postponed.pregame)
        XCTAssertFalse(postponed.news.isEmpty, "headlines still apply")
    }

    func testBuild67FixturesWithoutAStatusKeepTheirBoxScore() throws {
        let data = try fixtureData(named: "espn_detail_nba")
        let decoded = try summary(data)
        let eventID = try XCTUnwrap(decoded.header?.id)
        XCTAssertEqual(ESPNEventDetailMapping.statisticsPhase(summary: decoded, eventID: eventID), .unknown)
        XCTAssertTrue(KyroSportsStatisticsPhase.unknown.carriesEventStatistics)
    }

    // MARK: Missing, partial and changed data

    func testABrokenPregameBlockLosesOnlyThatBlock() throws {
        let details = try details("espn_b68_pregame_nba", league: .nba) { object in
            object["lastFiveGames"] = "unexpected"
            if var leaders = object["leaders"] as? [Any], !leaders.isEmpty {
                leaders[0] = 42
                object["leaders"] = leaders
            }
            object["standings"] = ["groups": 7]
            object["injuries"] = NSNull()
        }
        let pregame = try XCTUnwrap(details.pregame)
        XCTAssertTrue(pregame.away?.recent.isEmpty ?? false)
        XCTAssertTrue(pregame.standings.isEmpty)
        XCTAssertEqual([pregame.away, pregame.home].compactMap { $0 }.filter { !$0.leaders.isEmpty }.count, 1,
                       "the remaining team's leaders survive")
        XCTAssertFalse(pregame.home?.seasonStatistics.isEmpty ?? true)
        XCTAssertFalse(details.news.isEmpty)
    }

    func testAnEmptyPregameSummaryHasNoContext() throws {
        let details = try details("espn_b68_pregame_nfl", league: .nfl) { object in
            for key in ["lastFiveGames", "seasonseries", "standings", "leaders", "injuries", "gameInfo"] {
                object[key] = nil
            }
            object["boxscore"] = ["teams": []]
            if var header = object["header"] as? [String: Any],
               var competitions = header["competitions"] as? [[String: Any]],
               var competitors = competitions.first?["competitors"] as? [[String: Any]] {
                for index in competitors.indices { competitors[index]["record"] = nil }
                competitions[0]["competitors"] = competitors
                header["competitions"] = competitions
                object["header"] = header
            }
        }
        XCTAssertEqual(details.statisticsPhase, .pregame)
        XCTAssertNil(details.pregame, "nothing is invented when ESPN has nothing")
        XCTAssertTrue(details.teamStatistics.isEmpty)
    }

    func testAnotherGamesSummaryIsRejected() throws {
        let decoded = try summary(try fixtureData(named: "espn_b68_pregame_nba"))
        let wrong = KyroSportsGame(
            id: KyroGameID(provider: "espn", league: .nba, rawID: "401909296"), league: .nba,
            startTime: nil, status: .scheduled,
            home: KyroGameTeam(team: KyroSportsTeam(id: "espn.nba.15", league: .nba, abbreviation: "MIL", nickname: "Bucks")),
            away: KyroGameTeam(team: KyroSportsTeam(id: "espn.nba.18", league: .nba, abbreviation: "NY", nickname: "Knicks")))
        XCTAssertThrowsError(try ESPNEventDetailMapping.details(summary: decoded, additionalNews: [],
                                                                 eventID: "401909296", game: wrong)) { error in
            XCTAssertEqual(error as? KyroSportsEventDetailError, .eventNotMatched)
        }
    }

    // MARK: News

    func testOneStoryPerCanonicalURL() throws {
        let a = try XCTUnwrap(URL(string: "https://www.espn.com/nba/story/_/id/1/knicks-pacers?ex_cid=feed#top"))
        let b = try XCTUnwrap(URL(string: "http://espn.com/nba/story/_/id/1/Knicks-Pacers/"))
        let c = try XCTUnwrap(URL(string: "https://www.espn.com/nba/story/_/id/2/knicks-pacers"))
        XCTAssertEqual(KyroSportsNewsDedup.key(for: a), KyroSportsNewsDedup.key(for: b))
        XCTAssertNotEqual(KyroSportsNewsDedup.key(for: a), KyroSportsNewsDedup.key(for: c))
    }

    func testTheSameArticleUnderTwoIDsIsListedOnce() throws {
        func article(_ id: Int, _ href: String) throws -> ESPNEventSummaryResponse.Article {
            try JSONDecoder().decode(ESPNEventSummaryResponse.Article.self, from: Data("""
            {"id": \(id), "headline": "Knicks and Pacers renew rivalry", "published": "2026-11-12T10:00:00Z",
             "links": {"web": {"href": "\(href)"}},
             "categories": [{"type": "team", "team": {"id": 18}}, {"type": "team", "team": {"id": 11}}]}
            """.utf8))
        }
        let decoded = try summary(try fixtureData(named: "espn_b68_pregame_nba"))
        let selected = try game(for: decoded, league: .nba, competitionKey: nil)
        let details = try ESPNEventDetailMapping.details(
            summary: decoded,
            additionalNews: [try article(9001, "https://www.espn.com/nba/story/_/id/9/rivalry?src=team"),
                             try article(9002, "http://espn.com/nba/story/_/id/9/rivalry/")],
            eventID: "401909296", game: selected)
        let rivalry = details.news.filter { $0.headline == "Knicks and Pacers renew rivalry" }
        XCTAssertEqual(rivalry.count, 1)
        XCTAssertEqual(rivalry.first?.relevance, .matchup)
    }

    // MARK: Local start time

    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    func testStartTimeIsStatedInTheViewersTimeZone() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-14T00:00:00Z"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-13T15:00:00Z"))
        let locale = Locale(identifier: "en_US")
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        XCTAssertEqual(normalized(KyroSportsStartTimeText.line(start: start, isTimeTBD: false, now: now,
                                                               calendar: newYork, locale: locale)), "Today · 7:00 PM")
        var london = Calendar(identifier: .gregorian)
        london.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        XCTAssertEqual(normalized(KyroSportsStartTimeText.line(start: start, isTimeTBD: false, now: now,
                                                               calendar: london, locale: locale)), "Tomorrow · 12:00 AM")
        XCTAssertEqual(KyroSportsStartTimeText.line(start: start, isTimeTBD: true, now: now,
                                                    calendar: newYork, locale: locale), "Today · Time TBD")
        let nextWeek = start.addingTimeInterval(7 * 86_400 + 20 * 3600)
        XCTAssertEqual(normalized(KyroSportsStartTimeText.line(start: nextWeek, isTimeTBD: false, now: now,
                                                               calendar: newYork, locale: locale)), "Sat, Nov 21 · 3:00 PM")
    }

    func testCountdownOnlyWithinTheNextDay() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-14T00:00:00Z"))
        XCTAssertEqual(KyroSportsStartTimeText.countdown(start: start, isTimeTBD: false,
                                                         now: start.addingTimeInterval(-(2 * 3600 + 15 * 60))),
                       "Starts in 2 hr 15 min")
        XCTAssertEqual(KyroSportsStartTimeText.countdown(start: start, isTimeTBD: false, now: start.addingTimeInterval(-45 * 60)),
                       "Starts in 45 min")
        XCTAssertEqual(KyroSportsStartTimeText.countdown(start: start, isTimeTBD: false, now: start.addingTimeInterval(-3 * 3600)),
                       "Starts in 3 hr")
        XCTAssertNil(KyroSportsStartTimeText.countdown(start: start, isTimeTBD: false, now: start.addingTimeInterval(60)))
        XCTAssertNil(KyroSportsStartTimeText.countdown(start: start, isTimeTBD: false, now: start.addingTimeInterval(-30 * 3600)))
        XCTAssertNil(KyroSportsStartTimeText.countdown(start: start, isTimeTBD: true, now: start.addingTimeInterval(-3600)))
    }

    // MARK: Tennis and Event Details rules

    func testTennisSurfaceAndVenueComeFromTheScoresEvent() throws {
        let event = try JSONDecoder().decode(TheScoreEvent.self, from: Data("""
        {"id": 10488, "name": "BNP Paribas Nordic Open", "ground_type": "hardcourt_indoor",
         "tournament_stadium": {"id": 100, "name": "Kungliga Tennishallen", "location": "Stockholm, Sweden"}}
        """.utf8))
        XCTAssertEqual(KyroTennisSurface.label(groundType: event.ground_type), "Hard court, indoor")
        XCTAssertEqual(event.venue, "Kungliga Tennishallen, Stockholm, Sweden")
        XCTAssertEqual(KyroTennisSurface.label(groundType: "red_clay"), "Clay")
        XCTAssertEqual(KyroTennisSurface.label(groundType: "grass"), "Grass")
        XCTAssertNil(KyroTennisSurface.label(groundType: "moon_dust"), "an unknown surface is not guessed")
        XCTAssertNil(KyroTennisSurface.label(groundType: nil))

        let bare = try JSONDecoder().decode(TheScoreEvent.self, from: Data(#"{"id": 1, "ground_type": 5, "tournament_stadium": "x"}"#.utf8))
        XCTAssertEqual(bare.id, 1, "a mistyped surface or stadium does not lose the event")
        XCTAssertNil(bare.venue)
    }

    func testEventDetailsOpensAnyEventAndLoadsPregameOnlyBeforeTheStart() {
        XCTAssertEqual(KyroSportsEventDetailsLayout.tabs, [.game, .stats, .news])
        for league in [KyroSportLeague.nfl, .nba, .nhl, .mlb, .collegeFootball, .soccer] {
            XCTAssertTrue(KyroSportsEventDetailsLayout.loadsPregame(league: league, status: .scheduled, isSingles: false))
            XCTAssertFalse(KyroSportsEventDetailsLayout.loadsPregame(league: league, status: .live, isSingles: false))
            XCTAssertFalse(KyroSportsEventDetailsLayout.loadsPregame(league: league, status: .final, isSingles: false))
            XCTAssertFalse(KyroSportsEventDetailsLayout.loadsPregame(league: league, status: .postponed, isSingles: false))
        }
        XCTAssertTrue(KyroSportsEventDetailsLayout.loadsPregame(league: .atp, status: .scheduled, isSingles: true))
        XCTAssertFalse(KyroSportsEventDetailsLayout.loadsPregame(league: .wta, status: .scheduled, isSingles: false),
                       "doubles teams have no theScore ranking or head to head")
    }

    func testEventDetailsNamesTheCompetitionOnce() {
        XCTAssertEqual(KyroSportsEventDetailsLayout.competitionName(tournament: "Nitto ATP Finals", soccerCompetition: nil),
                       "Nitto ATP Finals")
        XCTAssertEqual(KyroSportsEventDetailsLayout.competitionName(tournament: " ", soccerCompetition: "English Premier League"),
                       "English Premier League")
        XCTAssertNil(KyroSportsEventDetailsLayout.distinctNote("Nitto ATP Finals", competition: "Nitto ATP Finals", round: "Group Stage"))
        XCTAssertNil(KyroSportsEventDetailsLayout.distinctNote("Group Stage", competition: "Nitto ATP Finals", round: "Group Stage"))
        XCTAssertEqual(KyroSportsEventDetailsLayout.distinctNote("NBA Cup · East Group B", competition: nil, round: nil),
                       "NBA Cup · East Group B")
        XCTAssertNil(KyroSportsEventDetailsLayout.distinctNote("  ", competition: nil, round: nil))
    }
}

// MARK: - Detail store: reuse, coalescing and stale answers

@MainActor
final class KyroBuild68PregameStoreTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    /// Serves one pregame summary per event ID with ESPN's real `max-age=1`, after an optional
    /// per-event delay, and counts summary requests per event.
    private final class Transport: ESPNTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var summaryRequests: [String: Int] = [:]
        let summaries: [String: Data]
        let delays: [String: UInt64]

        init(summaries: [String: Data], delays: [String: UInt64] = [:]) {
            self.summaries = summaries
            self.delays = delays
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = try XCTUnwrap(request.url)
            let event = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "event" }?.value
            if url.path.hasSuffix("/summary"), let event {
                lock.withLock { summaryRequests[event, default: 0] += 1 }
                if let delay = delays[event] { try await Task.sleep(nanoseconds: delay) }
            }
            let data = url.path.hasSuffix("/summary") ? (summaries[event ?? ""] ?? Data()) : Data(#"{"articles":[]}"#.utf8)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Cache-Control": "max-age=1"])!
            return (data, response)
        }

        func count(_ event: String) -> Int { lock.withLock { summaryRequests[event, default: 0] } }
    }

    private func fixture(_ name: String) throws -> Data {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ESPN/\(name).json")
        let bundled = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
        return try Data(contentsOf: try XCTUnwrap(bundled ?? source))
    }

    private func game(_ data: Data, league: KyroSportLeague, status: KyroGameStatus = .scheduled) throws -> KyroSportsGame {
        let summary = try JSONDecoder().decode(ESPNEventSummaryResponse.self, from: data)
        let competitors = try XCTUnwrap(summary.header?.competitions?.first?.competitors)
        func side(_ homeAway: String) throws -> KyroGameTeam {
            let wire = try XCTUnwrap(competitors.first { $0.homeAway == homeAway }?.team)
            return KyroGameTeam(team: KyroSportsTeam(id: "espn.\(league.rawValue).\(wire.id ?? "")", league: league,
                                                     abbreviation: wire.abbreviation ?? "", nickname: wire.displayName ?? ""))
        }
        return KyroSportsGame(id: KyroGameID(provider: "espn", league: league, rawID: try XCTUnwrap(summary.header?.id)),
                              league: league, startTime: nil, status: status, home: try side("home"), away: try side("away"))
    }

    private func store(_ transport: Transport, clock: Clock) -> KyroSportsEventDetailStore {
        let cache = ESPNEventDetailResponseCache(now: { clock.now })
        return KyroSportsEventDetailStore(client: ESPNEventDetailClient(transport: transport, cache: cache),
                                          supplementProviders: [], newsProvider: nil, playerInfoProvider: nil,
                                          now: { clock.now })
    }

    func testReturningToAnEventInsideItsFreshnessDoesNotRequestItAgain() async throws {
        let nba = try fixture("espn_b68_pregame_nba"), nhl = try fixture("espn_b68_pregame_nhl")
        let transport = Transport(summaries: ["401909296": nba, "401892706": nhl])
        let clock = Clock()
        let store = store(transport, clock: clock)
        let knicks = try game(nba, league: .nba), rangers = try game(nhl, league: .nhl)

        await store.load(for: knicks)
        clock.advance(30)
        await store.load(for: rangers)
        clock.advance(30)
        await store.load(for: knicks)
        XCTAssertEqual(store.details?.gameID, knicks.id)
        XCTAssertNotNil(store.details?.pregame)
        XCTAssertEqual(transport.count("401909296"), 1, "ESPN's max-age=1 has passed, but the event is reused for 5 minutes")
        XCTAssertEqual(transport.count("401892706"), 1)

        // Switching tabs reloads nothing either.
        await store.load(for: knicks)
        XCTAssertEqual(transport.count("401909296"), 1)

        clock.advance(6 * 60)
        await store.load(for: knicks)
        XCTAssertEqual(transport.count("401909296"), 2, "after its freshness the event is requested again")
    }

    func testAGameThatStartsIsReloadedAtOnce() async throws {
        let nba = try fixture("espn_b68_pregame_nba")
        let transport = Transport(summaries: ["401909296": nba])
        let clock = Clock()
        let store = store(transport, clock: clock)
        await store.load(for: try game(nba, league: .nba))
        clock.advance(5)
        await store.load(for: try game(nba, league: .nba, status: .live))
        XCTAssertEqual(transport.count("401909296"), 2, "a pregame answer is not kept for a game that has started")
    }

    func testIdenticalRequestsAreCoalesced() async throws {
        let nba = try fixture("espn_b68_pregame_nba")
        let transport = Transport(summaries: ["401909296": nba], delays: ["401909296": 50_000_000])
        let client = ESPNEventDetailClient(transport: transport, cache: ESPNEventDetailResponseCache())
        let knicks = try game(nba, league: .nba)
        async let first = client.fetchDetails(for: knicks)
        async let second = client.fetchDetails(for: knicks)
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b)
        XCTAssertEqual(transport.count("401909296"), 1)
    }

    func testASlowAnswerForThePreviousEventNeverReplacesTheSelectedOne() async throws {
        let nba = try fixture("espn_b68_pregame_nba"), nhl = try fixture("espn_b68_pregame_nhl")
        let transport = Transport(summaries: ["401909296": nba, "401892706": nhl],
                                  delays: ["401909296": 150_000_000])
        let store = store(transport, clock: Clock())
        let knicks = try game(nba, league: .nba), rangers = try game(nhl, league: .nhl)
        let slow = Task { await store.load(for: knicks) }
        try await Task.sleep(nanoseconds: 20_000_000)
        await store.load(for: rangers)
        await slow.value
        XCTAssertEqual(store.details?.gameID, rangers.id)
        XCTAssertEqual(store.phase, .loaded)
    }
}
