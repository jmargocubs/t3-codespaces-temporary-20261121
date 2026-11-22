import Foundation
import XCTest
@testable import Silo

/// Fixtures are trimmed copies of live `api.sleeper.app` responses captured
/// 2026-11-06 (see `Fixtures/Sleeper/SOURCE`). They exist to lock the decoder
/// against the shapes Sleeper actually returns, not against a schema doc,
/// because `/scores`, `/schedule` and `/teams` are undocumented.
enum SleeperFixtureSupport {
    static func url(named name: String, bundleClass: AnyClass) throws -> URL {
        try XCTUnwrap(
            Bundle(for: bundleClass).url(forResource: name, withExtension: "json"),
            "Missing Sleeper fixture \(name).json"
        )
    }

    static func data(named name: String, bundleClass: AnyClass) throws -> Data {
        try Data(contentsOf: url(named: name, bundleClass: bundleClass))
    }

    static func decode<T: Decodable>(
        _ type: T.Type,
        named name: String,
        bundleClass: AnyClass
    ) throws -> T {
        try JSONDecoder().decode(type, from: data(named: name, bundleClass: bundleClass))
    }

    /// Teams keyed by abbreviation, as the hub builds them.
    static func nflTeams(bundleClass: AnyClass) throws -> [String: KyroSportsTeam] {
        let wire = try decode([SleeperTeam].self, named: "teams_nfl", bundleClass: bundleClass)
        return SleeperMapping.teams(from: wire, league: .nfl)
    }
}

/// A transport that replays canned responses and records what it was asked.
final class StubSleeperTransport: SleeperTransport, @unchecked Sendable {
    struct Response {
        var data: Data
        var status: Int = 200
        var etag: String?
    }

    private let lock = NSLock()
    private var responses: [String: Response]
    private(set) var requests: [URLRequest] = []
    /// Thrown instead of a response when set.
    var failure: Error?

    init(responses: [String: Response] = [:]) {
        self.responses = responses
    }

    func set(_ response: Response, forPath path: String) {
        lock.lock(); defer { lock.unlock() }
        responses[path] = response
    }

    func setFailure(_ error: Error?) {
        lock.lock(); defer { lock.unlock() }
        failure = error
    }

    func requestCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests.count
    }

    func lastRequest() -> URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return requests.last
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (failure, response) = lock.withLock {
            requests.append(request)
            let path = request.url?.path ?? ""
            return (self.failure, responses[path])
        }

        if let failure { throw failure }
        guard let response else {
            throw SleeperAPIError.httpStatus(404)
        }
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.etag.map { ["ETag": $0] } ?? [:]
        )!
        return (response.data, http)
    }
}

final class KyroSportsDecodingTests: XCTestCase {

    // MARK: - Teams

    func testTeamsMapAbbreviationNicknameAndLogo() throws {
        let teams = try SleeperFixtureSupport.nflTeams(bundleClass: Self.self)
        XCTAssertEqual(teams.count, 4)

        let fortyNiners = try XCTUnwrap(teams["SF"])
        XCTAssertEqual(fortyNiners.abbreviation, "SF")
        XCTAssertEqual(fortyNiners.nickname, "49ers")
        XCTAssertEqual(fortyNiners.location, "San Francisco")
        XCTAssertEqual(fortyNiners.fullName, "San Francisco 49ers")
        XCTAssertEqual(fortyNiners.conference, "NFC")
        XCTAssertEqual(fortyNiners.division, "NFC West")
        XCTAssertEqual(fortyNiners.primaryColorHex, "AA0000")
        XCTAssertEqual(
            fortyNiners.logoURL?.absoluteString,
            "https://sleepercdn.com/images/team_logos/nfl/sf.png"
        )
    }

    // MARK: - Scheduled games

    func testESPNTeamCarriesAlternateColourAndDarkLogo() throws {
        let json = #"""
        {"events":[{"id":"401","date":"2026-11-08T18:00Z","status":{"type":{"state":"pre","name":"STATUS_SCHEDULED"}},
          "competitions":[{"id":"401","competitors":[
            {"homeAway":"home","team":{"id":"17","abbreviation":"BKN","location":"Brooklyn","name":"Nets","color":"000000",
              "alternateColor":"ffffff","logo":"https://a.espncdn.com/i/teamlogos/nba/500/scoreboard/bkn.png",
              "logoDark":"https://a.espncdn.com/i/teamlogos/nba/500-dark/scoreboard/bkn.png"}},
            {"homeAway":"away","team":{"id":"2","abbreviation":"BOS","location":"Boston","name":"Celtics","color":"008348",
              "logo":"https://a.espncdn.com/i/teamlogos/nba/500/scoreboard/bos.png"}}]}]}]}
        """#
        let response = try JSONDecoder().decode(ESPNScoreboardResponse.self, from: Data(json.utf8))
        let game = try XCTUnwrap(response.events.first.flatMap { ESPNMapping.game(from: $0, league: .nba) })
        XCTAssertEqual(game.home.team.alternateColorHex, "ffffff")
        XCTAssertEqual(game.home.team.darkLogoURL?.absoluteString, "https://a.espncdn.com/i/teamlogos/nba/500-dark/scoreboard/bkn.png")
        XCTAssertNil(game.away.team.alternateColorHex, "missing fields stay missing")
        XCTAssertNil(game.away.team.darkLogoURL)
        XCTAssertEqual(KyroSportsMatchupArtwork(game: game).backdrop,
                       .teams(away: KyroSportsRGB(rgb: 0x008348), home: KyroSportsMatchupArtwork.neutralSide))
    }

    func testScheduledGameIsNotLiveAndHasNoScore() throws {
        let wire = try SleeperFixtureSupport.decode(
            [SleeperScoreGame].self, named: "scores_nfl_week9", bundleClass: Self.self
        )
        let teams = try SleeperFixtureSupport.nflTeams(bundleClass: Self.self)

        let scheduled = try XCTUnwrap(wire.compactMap {
            SleeperMapping.game(fromScore: $0, league: .nfl, teamsByAbbreviation: teams)
        }.first { $0.status.isScheduled })

        XCTAssertFalse(scheduled.status.isLive)
        XCTAssertFalse(scheduled.hasScore)
        XCTAssertNil(scheduled.home.score)
        XCTAssertNil(scheduled.away.score)
        XCTAssertTrue(scheduled.periods.isEmpty, "a game that has not kicked off has no quarters")
        XCTAssertNotNil(scheduled.startTime)
        XCTAssertEqual(scheduled.statusLine, "Scheduled")
    }

    // MARK: - Completed games

    func testCompletedGameCarriesFinalScoreAndQuarterTable() throws {
        let wire = try SleeperFixtureSupport.decode(
            [SleeperScoreGame].self, named: "scores_nfl_week9", bundleClass: Self.self
        )
        let teams = try SleeperFixtureSupport.nflTeams(bundleClass: Self.self)

        let final = try XCTUnwrap(wire.compactMap {
            SleeperMapping.game(fromScore: $0, league: .nfl, teamsByAbbreviation: teams)
        }.first { $0.status.isFinal })

        XCTAssertEqual(final.statusDetail, "Final")
        XCTAssertEqual(final.hasScore, true)
        XCTAssertEqual(final.periods.map(\.label), ["Q1", "Q2", "Q3", "Q4"])
        XCTAssertEqual(final.home.score! + final.away.score!, 43, "10 + 33 from the real week 9 game")
        XCTAssertNotNil(final.winner)
        XCTAssertEqual(final.winner?.score, 33)
        XCTAssertEqual(final.venue, "M&T Bank Stadium")
        XCTAssertEqual(final.broadcast, "AMZN")
    }

    func testCompletedGameKeepsRecordsAndTrimsTieColumn() throws {
        let wire = try SleeperFixtureSupport.decode(
            [SleeperScoreGame].self, named: "scores_nfl_week9", bundleClass: Self.self
        )
        let teams = try SleeperFixtureSupport.nflTeams(bundleClass: Self.self)
        let final = try XCTUnwrap(wire.compactMap {
            SleeperMapping.game(fromScore: $0, league: .nfl, teamsByAbbreviation: teams)
        }.first { $0.status.isFinal })

        // Sleeper reports "6-2-0"; the hub shows "6-2".
        XCTAssertEqual(final.away.record, "6-2-0")
        XCTAssertEqual(final.away.displayRecord, "6-2")
        XCTAssertEqual(final.home.displayRecord, "4-5")
    }

    // MARK: - Live structure

    func testLiveGameDecodesClockAndPartialQuarterTable() throws {
        let wire = try SleeperFixtureSupport.decode(
            [SleeperScoreGame].self, named: "scores_nfl_live", bundleClass: Self.self
        )
        let teams = try SleeperFixtureSupport.nflTeams(bundleClass: Self.self)
        let live = try XCTUnwrap(wire.first.flatMap {
            SleeperMapping.game(fromScore: $0, league: .nfl, teamsByAbbreviation: teams)
        })

        XCTAssertTrue(live.status.isLive)
        XCTAssertEqual(live.statusDetail, "Q3 4:32")
        XCTAssertEqual(live.home.score, 17)
        XCTAssertEqual(live.away.score, 20)
        // Q4 has not started, so it is absent rather than drawn as zeros.
        XCTAssertEqual(live.periods.map(\.label), ["Q1", "Q2", "Q3"])
        XCTAssertNil(live.winner, "a live game has no winner")
    }

    func testUnknownStatusStringDoesNotThrow() {
        let status = SleeperMapping.status(
            rawStatus: "reviewing", isInProgress: nil, hasStarted: nil, isOver: nil, canceled: nil
        )
        guard case .unknown(let raw) = status else {
            return XCTFail("expected .unknown for an unrecognised status")
        }
        XCTAssertEqual(raw, "reviewing")
        XCTAssertEqual(status.label, "Update pending")
    }

    func testCancelledMetadataWinsOverPreGameStatus() {
        let status = SleeperMapping.status(
            rawStatus: "pre_game", isInProgress: false, hasStarted: false, isOver: false, canceled: true
        )
        XCTAssertEqual(status, .canceled)
    }

    func testSleeperSuspendedStatusIsExplicit() {
        let status = SleeperMapping.status(
            rawStatus: "suspended", isInProgress: false, hasStarted: true, isOver: false, canceled: false
        )
        XCTAssertEqual(status, .suspended)
        XCTAssertEqual(status.label, "Suspended")
    }

    // MARK: - Missing optional fields

    func testMissingMetadataStillProducesAGame() throws {
        // Only identity and team names: no scores, clock, records or venue.
        let json = """
        [{"game_id":"min1","status":"pre_game","metadata":{"home_team":"KC","away_team":"DEN"}}]
        """.data(using: .utf8)!

        let wire = try JSONDecoder().decode([SleeperScoreGame].self, from: json)
        let game = try XCTUnwrap(SleeperMapping.game(
            fromScore: wire[0], league: .nfl, teamsByAbbreviation: [:]
        ))

        XCTAssertEqual(game.id.rawID, "min1")
        XCTAssertEqual(game.home.team.abbreviation, "KC")
        XCTAssertEqual(game.away.team.abbreviation, "DEN")
        XCTAssertNil(game.home.score)
        XCTAssertNil(game.home.record)
        XCTAssertNil(game.startTime)
        XCTAssertNil(game.venue)
        XCTAssertTrue(game.status.isScheduled)
    }

    func testEmptyMetadataObjectIsTolerated() throws {
        let json = """
        [{"game_id":"empty1","status":"complete","metadata":{}}]
        """.data(using: .utf8)!

        let wire = try JSONDecoder().decode([SleeperScoreGame].self, from: json)
        // No teams: the game has no identity as a matchup and is dropped.
        XCTAssertNil(SleeperMapping.game(fromScore: wire[0], league: .nfl, teamsByAbbreviation: [:]),
                     "a game without both teams cannot be titled, so it is skipped")
    }

    func testGameWithoutIDIsDropped() throws {
        let json = """
        [{"status":"pre_game","metadata":{"home_team":"KC","away_team":"DEN"}}]
        """.data(using: .utf8)!
        let wire = try JSONDecoder().decode([SleeperScoreGame].self, from: json)
        XCTAssertNil(SleeperMapping.game(fromScore: wire[0], league: .nfl, teamsByAbbreviation: [:]))
    }

    func testPlaceholderTeamKeepsRowIdentityWhenCatalogIsUnavailable() throws {
        let json = """
        [{"game_id":"g1","status":"pre_game","metadata":{"home_team":"KC","away_team":"DEN"}}]
        """.data(using: .utf8)!
        let wire = try JSONDecoder().decode([SleeperScoreGame].self, from: json)
        let game = try XCTUnwrap(SleeperMapping.game(
            fromScore: wire[0], league: .nfl, teamsByAbbreviation: [:]
        ))
        XCTAssertEqual(game.home.team.nickname, "KC")
        XCTAssertNil(game.home.team.logoURL)
        XCTAssertEqual(game.home.team.id, "placeholder.nfl.KC")
    }

    func testOvertimePeriodIsAppendedOnlyWhenReported() throws {
        let json = """
        [{"game_id":"ot1","status":"complete","metadata":{
          "home_team":"KC","away_team":"DEN",
          "home_score":27,"away_score":24,
          "home_score_quarter1":7,"away_score_quarter1":7,
          "home_score_quarter2":0,"away_score_quarter2":3,
          "home_score_quarter3":7,"away_score_quarter3":7,
          "home_score_quarter4":10,"away_score_quarter4":7,
          "home_score_overtime":3,"away_score_overtime":0
        }}]
        """.data(using: .utf8)!
        let wire = try JSONDecoder().decode([SleeperScoreGame].self, from: json)
        let game = try XCTUnwrap(SleeperMapping.game(
            fromScore: wire[0], league: .nfl, teamsByAbbreviation: [:]
        ))
        XCTAssertEqual(game.periods.map(\.label), ["Q1", "Q2", "Q3", "Q4", "OT"])
        XCTAssertEqual(game.periods.last?.homeScore, 3)
    }

    // MARK: - Malformed responses

    func testMalformedJSONFailsAsMalformedResponse() async {
        let transport = StubSleeperTransport()
        transport.set(.init(data: Data("not json".utf8)), forPath: "/scores/nfl/regular/2026/9")
        let client = SleeperAPIClient(transport: transport, cache: SleeperResponseCache())

        do {
            _ = try await client.fetchScores(league: .nfl, season: "2026", week: 9)
            XCTFail("expected a malformed-response error")
        } catch {
            XCTAssertEqual(error as? SleeperAPIError, .malformedResponse)
        }
    }

    func testChangedTopLevelShapeFailsSoftly() async {
        // Sleeper returning an object where an array was expected: the hub
        // must surface a retry state, not crash.
        let transport = StubSleeperTransport()
        transport.set(.init(data: Data(#"{"scores":[]}"#.utf8)),
                       forPath: "/scores/nfl/regular/2026/9")
        let client = SleeperAPIClient(transport: transport, cache: SleeperResponseCache())

        do {
            _ = try await client.fetchScores(league: .nfl, season: "2026", week: 9)
            XCTFail("expected a malformed-response error")
        } catch {
            XCTAssertEqual(error as? SleeperAPIError, .malformedResponse)
        }
    }

    func testEmptyArrayDecodesAsEmptyNotError() async throws {
        let transport = StubSleeperTransport()
        transport.set(.init(data: Data("[]".utf8)), forPath: "/scores/nfl/regular/2026/9")
        let client = SleeperAPIClient(transport: transport, cache: SleeperResponseCache())
        let scores = try await client.fetchScores(league: .nfl, season: "2026", week: 9).games
        XCTAssertTrue(scores.isEmpty)
    }

    func testHTTPErrorSurfacesStatus() async {
        let transport = StubSleeperTransport()
        transport.set(.init(data: Data(), status: 503), forPath: "/scores/nfl/regular/2026/9")
        let client = SleeperAPIClient(transport: transport, cache: SleeperResponseCache())
        do {
            _ = try await client.fetchScores(league: .nfl, season: "2026", week: 9)
            XCTFail("expected an HTTP error")
        } catch {
            XCTAssertEqual(error as? SleeperAPIError, .httpStatus(503))
        }
    }

    // MARK: - Identifiers

    func testGameIDIsNamespacedByProviderAndLeague() {
        let id = KyroGameID(provider: "sleeper", league: .nfl, rawID: "202610902")
        XCTAssertEqual(id.stringValue, "sleeper.nfl.202610902")
        XCTAssertEqual(id.description, "sleeper.nfl.202610902")
        // Same raw id in another league is a different identity.
        let other = KyroGameID(provider: "sleeper", league: .nba, rawID: "202610902")
        XCTAssertNotEqual(id, other)
    }

    func testGameIDIsStableAcrossRepeatedDecodes() throws {
        let data = try SleeperFixtureSupport.data(named: "scores_nfl_week9", bundleClass: Self.self)
        let teams = try SleeperFixtureSupport.nflTeams(bundleClass: Self.self)
        func ids() throws -> [String] {
            let wire = try JSONDecoder().decode([SleeperScoreGame].self, from: data)
            return wire.compactMap {
                SleeperMapping.game(fromScore: $0, league: .nfl, teamsByAbbreviation: teams)?.id.stringValue
            }
        }
        XCTAssertEqual(try ids(), try ids())
        XCTAssertEqual(Set(try ids()).count, try ids().count, "ids are unique")
    }

    // MARK: - Grouping

    func testSectionsOrderLiveThenTodayThenUpcoming() throws {
        // 2026-11-06T18:00:00Z — a Friday.
        let now = Date(timeIntervalSince1970: 1_793_988_000)
        let calendar = Calendar(identifier: .gregorian)

        func game(_ id: String, _ status: KyroGameStatus, hoursFromNow: Double) -> KyroSportsGame {
            KyroSportsGame(
                id: KyroGameID(provider: "sleeper", league: .nfl, rawID: id),
                league: .nfl,
                startTime: now.addingTimeInterval(hoursFromNow * 3600),
                status: status,
                home: KyroGameTeam(team: .placeholder(abbreviation: "KC", league: .nfl), score: 0),
                away: KyroGameTeam(team: .placeholder(abbreviation: "DEN", league: .nfl), score: 0)
            )
        }

        let games = [
            game("upcoming", .scheduled, hoursFromNow: 72),
            game("today", .scheduled, hoursFromNow: 3),
            game("live", .live, hoursFromNow: -1)
        ]
        let sections = KyroSportsSectioning.sections(from: games, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.bucket), [.liveNow, .today, .upcoming])
        XCTAssertEqual(sections[0].games.first?.id.rawID, "live")
        XCTAssertEqual(sections[1].games.first?.id.rawID, "today")
        XCTAssertEqual(sections[2].games.first?.id.rawID, "upcoming")
    }

    func testFinishedGameFromAnotherDayIsARecentResultNotUpcoming() {
        let now = Date(timeIntervalSince1970: 1_793_988_000)
        let calendar = Calendar(identifier: .gregorian)
        func game(_ id: String, _ status: KyroGameStatus, hoursFromNow: Double) -> KyroSportsGame {
            KyroSportsGame(
                id: KyroGameID(provider: "sleeper", league: .nfl, rawID: id),
                league: .nfl,
                startTime: now.addingTimeInterval(hoursFromNow * 3600),
                status: status,
                home: KyroGameTeam(team: .placeholder(abbreviation: "KC", league: .nfl), score: 0),
                away: KyroGameTeam(team: .placeholder(abbreviation: "DEN", league: .nfl), score: 0)
            )
        }
        let sections = KyroSportsSectioning.sections(
            from: [game("next", .scheduled, hoursFromNow: 72), game("last", .final, hoursFromNow: -30)],
            now: now, calendar: calendar
        )
        // Sections are ordered live, today, upcoming, recent, later.
        XCTAssertEqual(sections.map(\.bucket), [.upcoming, .recent])
        XCTAssertEqual(sections[0].games.first?.id.rawID, "next")
        XCTAssertEqual(sections[1].games.first?.id.rawID, "last")
    }

    func testEmptySectionsAreOmitted() {
        let sections = KyroSportsSectioning.sections(from: [], now: Date())
        XCTAssertTrue(sections.isEmpty)
    }

    // MARK: - Dates

    func testStartDatePrefersISOThenEpochThenDay() {
        let iso = SleeperMapping.startDate(isoString: "2026-11-08T14:30:00+00:00", millis: nil, day: nil)
        XCTAssertNotNil(iso)
        XCTAssertEqual(iso, Date(timeIntervalSince1970: 1_794_148_200))

        let millis = SleeperMapping.startDate(isoString: nil, millis: 1_794_148_200_000, day: nil)
        XCTAssertEqual(millis, iso, "the epoch and ISO forms agree in the real payload")

        let dayOnly = SleeperMapping.startDate(isoString: nil, millis: nil, day: "2026-11-08")
        XCTAssertNil(dayOnly, "a date label must not become a manufactured midnight kickoff")
    }

    func testUnparseableDateYieldsNilWithoutThrowing() {
        XCTAssertNil(SleeperMapping.startDate(isoString: "not a date", millis: nil, day: "13/40/2026"))
    }

    func testMappedScoreCarriesVerifiedSeasonWeekAndProvenance() throws {
        let wire = try SleeperFixtureSupport.decode(
            [SleeperScoreGame].self,
            named: "scores_nfl_week9",
            bundleClass: Self.self
        )
        let teams = try SleeperFixtureSupport.nflTeams(bundleClass: Self.self)
        let game = try XCTUnwrap(wire.compactMap {
            SleeperMapping.game(
                fromScore: $0,
                league: .nfl,
                season: 2026,
                seasonType: .regular,
                teamsByAbbreviation: teams
            )
        }.first)

        XCTAssertEqual(game.season, 2026)
        XCTAssertEqual(game.week, 9)
        XCTAssertEqual(game.seasonType, .regular)
        XCTAssertEqual(game.weekLabel, "NFL Week 9")
        XCTAssertEqual(game.provenance.first?.provider, "sleeper")
    }

    func testLocalTimezoneControlsTodayAndUpcomingDateGroups() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-08T18:00:00Z"))
        let sundayNight = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-09T01:20:00Z"))
        let mondayNight = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-10T01:15:00Z"))

        let sections = KyroSportsSectioning.sections(
            from: [
                accuracyGame("sun", status: .scheduled, start: sundayNight, week: 9),
                accuracyGame("mon", status: .scheduled, start: mondayNight, week: 9)
            ],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(sections.map(\.bucket), [.today, .upcoming])
        XCTAssertEqual(sections[0].games.map(\.id.rawID), ["sun"])
        XCTAssertEqual(
            calendar.component(.day, from: try XCTUnwrap(sections[1].localDay)),
            9,
            "Monday's UTC-Tuesday kickoff groups under Monday on the iPhone"
        )
    }

    func testUpcomingIsSplitIntoDeterministicCalendarDateSections() {
        let now = Date(timeIntervalSince1970: 1_793_988_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let games = [
            accuracyGame("late", status: .scheduled, start: now.addingTimeInterval(72 * 3600), week: 10),
            accuracyGame("early", status: .scheduled, start: now.addingTimeInterval(48 * 3600), week: 10)
        ]

        let upcoming = KyroSportsSectioning.sections(from: games, now: now, calendar: calendar)
            .filter { $0.bucket == .upcoming }
        XCTAssertEqual(upcoming.count, 2)
        XCTAssertTrue(upcoming[0].isFirstInBucket)
        XCTAssertFalse(upcoming[1].isFirstInBucket)
        XCTAssertEqual(upcoming.flatMap(\.games).map(\.id.rawID), ["early", "late"])
    }

    func testDuplicateProviderRowsAreRemovedDeterministically() {
        let start = Date(timeIntervalSince1970: 1_794_148_200)
        let first = accuracyGame("a", status: .scheduled, start: start, week: 9)
        let duplicate = accuracyGame("b", status: .scheduled, start: start, week: 9)
        let result = KyroSportsReconciler.deduplicated([duplicate, first])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id.rawID, "a")
    }

    func testCrossProviderIDsReconcileBySeasonTeamsWeekAndKickoff() {
        let start = Date(timeIntervalSince1970: 1_794_148_200)
        let primary = accuracyGame(
            "espn-401873038",
            provider: "primary",
            status: .scheduled,
            start: start,
            week: 9,
            away: "WSH",
            home: "DAL"
        )
        let fallback = accuracyGame(
            "sleeper-202610902",
            provider: "fallback",
            status: .scheduled,
            start: start,
            week: 9,
            away: "WAS",
            home: "DAL"
        )

        let result = KyroSportsReconciler.reconcile(primary: [primary], fallback: [fallback])
        XCTAssertEqual(result.games.count, 1)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(Set(result.games[0].provenance.map(\.provider)), ["primary", "fallback"])
    }

    func testRescheduledKickoffKeepsBothRecordsAndReportsConflict() {
        let original = Date(timeIntervalSince1970: 1_794_148_200)
        let moved = original.addingTimeInterval(24 * 3600)
        let primary = accuracyGame("primary", provider: "primary", status: .scheduled, start: moved, week: 9)
        let fallback = accuracyGame("fallback", provider: "fallback", status: .scheduled, start: original, week: 9)

        let result = KyroSportsReconciler.reconcile(primary: [primary], fallback: [fallback])
        XCTAssertEqual(result.games.count, 2, "conflicting kickoff records must not be silently merged")
        XCTAssertTrue(result.games.contains { $0.startTime == moved })
        XCTAssertTrue(result.games.contains { $0.startTime == original })
        XCTAssertEqual(result.conflicts.count, 1)
    }

    func testPostponedAndCanceledFutureGamesHaveOneUpcomingAssignment() {
        let now = Date(timeIntervalSince1970: 1_793_988_000)
        let future = now.addingTimeInterval(48 * 3600)
        let sections = KyroSportsSectioning.sections(
            from: [
                accuracyGame("postponed", status: .postponed, start: future, week: 9),
                // A different matchup: same teams at the same kickoff are one game.
                accuracyGame("canceled", status: .canceled, start: future, week: 9, away: "LV", home: "MIA")
            ],
            now: now
        )

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].bucket, .upcoming)
        XCTAssertTrue(sections[0].games.contains { $0.status == .postponed })
        XCTAssertTrue(sections[0].games.contains { $0.status == .canceled })
    }

    func testMissingTimestampAndStalePastScheduleAreNotMisleadingUpcomingGames() {
        let now = Date(timeIntervalSince1970: 1_793_988_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let sections = KyroSportsSectioning.sections(
            from: [
                accuracyGame("missing", status: .scheduled, start: nil, week: 9),
                accuracyGame("stale", status: .scheduled, start: now.addingTimeInterval(-48 * 3600), week: 9),
                accuracyGame("today-stale", status: .scheduled, start: now.addingTimeInterval(-6 * 3600), week: 9)
            ],
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(sections.isEmpty)
    }

    func testLiveToFinalMovesFromLiveNowToRecentWithoutDuplication() {
        let now = Date(timeIntervalSince1970: 1_793_988_000)
        let start = now.addingTimeInterval(-3600)
        let live = KyroSportsSectioning.sections(
            from: [accuracyGame("game", status: .live, start: start, week: 9)],
            now: now
        )
        let final = KyroSportsSectioning.sections(
            from: [accuracyGame("game", status: .final, start: start, week: 9)],
            now: now
        )

        XCTAssertEqual(live.map(\.bucket), [.liveNow])
        XCTAssertEqual(final.map(\.bucket), [.recent])
        XCTAssertEqual(live.flatMap(\.games).count, 1)
        XCTAssertEqual(final.flatMap(\.games).count, 1)
    }

    private func accuracyGame(
        _ rawID: String,
        provider: String = "sleeper",
        status: KyroGameStatus,
        start: Date?,
        week: Int,
        away: String = "DEN",
        home: String = "KC"
    ) -> KyroSportsGame {
        KyroSportsGame(
            id: KyroGameID(provider: provider, league: .nfl, rawID: rawID),
            league: .nfl,
            season: 2026,
            seasonType: .regular,
            week: week,
            startTime: start,
            status: status,
            home: KyroGameTeam(team: .placeholder(abbreviation: home, league: .nfl)),
            away: KyroGameTeam(team: .placeholder(abbreviation: away, league: .nfl))
        )
    }
}
