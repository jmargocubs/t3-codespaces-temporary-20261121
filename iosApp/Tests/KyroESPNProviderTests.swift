import Foundation
import XCTest
@testable import Silo

private enum ESPNFixtureSupport {
    static func data(_ name: String, bundleClass: AnyClass) throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: bundleClass).url(forResource: name, withExtension: "json"),
            "Missing ESPN fixture \(name).json"
        )
        return try Data(contentsOf: url)
    }

    static func response(_ name: String, bundleClass: AnyClass) throws -> ESPNScoreboardResponse {
        try JSONDecoder().decode(
            ESPNScoreboardResponse.self,
            from: data(name, bundleClass: bundleClass)
        )
    }
}

final class StubESPNTransport: ESPNTransport, @unchecked Sendable {
    struct Response {
        var data: Data
        var status = 200
        var etag: String?
        var delay: Duration?
    }

    private let lock = NSLock()
    private var responses: [String: Response] = [:]
    private var fallback: Response?
    private var failure: Error?
    private var requests: [URLRequest] = []

    func set(_ response: Response, leaguePath: String? = nil, dates: String? = nil) {
        lock.withLock {
            if let leaguePath, let dates {
                responses[Self.key(path: leaguePath, dates: dates)] = response
            } else {
                fallback = response
            }
        }
    }

    func setFailure(_ error: Error?) {
        lock.withLock { failure = error }
    }

    func requestCount() -> Int { lock.withLock { requests.count } }
    func lastRequest() -> URLRequest? { lock.withLock { requests.last } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (failure, response) = lock.withLock {
            requests.append(request)
            let dates = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "dates" })?.value ?? ""
            let key = Self.key(path: request.url?.path ?? "", dates: dates)
            return (self.failure, responses[key] ?? fallback)
        }
        if let failure { throw failure }
        guard let response else { throw KyroSportsDataError.httpStatus(404) }
        if let delay = response.delay { try await Task.sleep(for: delay) }
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.etag.map { ["ETag": $0] } ?? [:]
        )!
        return (response.data, http)
    }

    private static func key(path: String, dates: String) -> String { "\(path)|\(dates)" }
}

final class KyroESPNProviderTests: XCTestCase {
    private let nflPath = "/apis/site/v2/sports/football/nfl/scoreboard"

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        func now() -> Date { lock.withLock { value } }
        func advance(_ interval: TimeInterval) { lock.withLock { value.addTimeInterval(interval) } }
    }

    func testNFLFixtureMatchesOfficialWeekNineSamples() throws {
        let response = try ESPNFixtureSupport.response("nfl_scoreboard", bundleClass: Self.self)
        let games = response.events.compactMap { ESPNMapping.game(from: $0, league: .nfl) }
        XCTAssertEqual(games.count, 3)

        let thursday = try XCTUnwrap(games.first { $0.id.rawID == "401873037" })
        XCTAssertEqual(thursday.startTime, ISO8601DateFormatter().date(from: "2026-11-06T01:15:00Z"))
        XCTAssertEqual(thursday.season, 2026)
        XCTAssertEqual(thursday.week, 9)
        XCTAssertEqual(thursday.away.team.abbreviation, "JAX")
        XCTAssertEqual(thursday.home.team.abbreviation, "BAL")
        XCTAssertEqual(thursday.away.score, 33)
        XCTAssertEqual(thursday.home.score, 10)
        XCTAssertEqual(thursday.periods.map(\.label), ["Q1", "Q2", "Q3", "Q4"])
        XCTAssertEqual(thursday.provenance, [.init(provider: "espn", rawID: "401873037")])

        let sunday = try XCTUnwrap(games.first { $0.id.rawID == "401873038" })
        XCTAssertEqual(sunday.startTime, ISO8601DateFormatter().date(from: "2026-11-08T14:30:00Z"))
        XCTAssertNil(sunday.home.score, "ESPN's scheduled zero is not a played score")
        XCTAssertEqual(sunday.broadcast, "NFL Network")

        let monday = try XCTUnwrap(games.first { $0.id.rawID == "401873051" })
        XCTAssertEqual(monday.startTime, ISO8601DateFormatter().date(from: "2026-11-10T01:15:00Z"))
    }

    func testLeagueSpecificPeriodScoringAndCollegeRankings() throws {
        let fixtures: [(String, KyroSportLeague, [String])] = [
            ("nba_scoreboard", .nba, ["Q1", "Q2", "Q3", "Q4", "OT"]),
            ("mlb_scoreboard", .mlb, ["1", "2", "3", "4", "5", "6", "7"]),
            ("nhl_scoreboard", .nhl, ["P1", "P2", "P3", "OT"]),
            ("college_football_scoreboard", .collegeFootball, ["Q1", "Q2", "Q3", "Q4"])
        ]

        for (fixture, league, labels) in fixtures {
            let response = try ESPNFixtureSupport.response(fixture, bundleClass: Self.self)
            let game = try XCTUnwrap(response.events.first.flatMap {
                ESPNMapping.game(from: $0, league: league)
            })
            XCTAssertEqual(game.periods.map(\.label), labels, league.displayName)
            XCTAssertEqual(game.id.provider, "espn")
        }

        let college = try ESPNFixtureSupport.response(
            "college_football_scoreboard",
            bundleClass: Self.self
        )
        let collegeGame = try XCTUnwrap(college.events.first.flatMap {
            ESPNMapping.game(from: $0, league: .collegeFootball)
        })
        XCTAssertEqual(collegeGame.home.rank, 7)
        XCTAssertNil(collegeGame.away.rank, "ESPN rank 99 means unranked")
        XCTAssertEqual(collegeGame.statusDetail, "9:21 - 4th")
    }

    func testTennisTournamentHierarchyPlayersFlagsSetsAndRound() throws {
        let response = try ESPNFixtureSupport.response("espn_tennis_atp", bundleClass: Self.self)
        let games = response.events.flatMap { ESPNMapping.tennisGames(from: $0, league: .atp) }
        let game = try XCTUnwrap(games.first)
        XCTAssertEqual(games.count, 1)
        XCTAssertTrue(game.isSingles)
        XCTAssertEqual(game.tournament, "ATP Finals")
        XCTAssertEqual(game.round, "Semifinal")
        XCTAssertEqual(game.away.team.countryCode, "ES")
        XCTAssertEqual(game.home.team.countryCode, "IT")
        XCTAssertEqual(game.periods.map(\.label), ["Set 1", "Set 2", "Set 3"])
        XCTAssertEqual(game.away.score, 2)
        XCTAssertEqual(game.status, .final)
    }

    func testWTAUnknownTimeAndTourFiltering() throws {
        let response = try ESPNFixtureSupport.response("espn_tennis_wta", bundleClass: Self.self)
        let wta = response.events.flatMap { ESPNMapping.tennisGames(from: $0, league: .wta) }
        XCTAssertEqual(wta.count, 1)
        // timeValid=false: ESPN's date names the day only. Keep the day for
        // the date strip, never show it as a clock time.
        XCTAssertTrue(wta[0].isStartTimeTBD, "timeValid=false must not fabricate a start time")
        XCTAssertEqual(wta[0].statusDetail, "Time TBD")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(wta[0].startTime.map { utc.dateComponents([.month, .day, .hour], from: $0) },
                       DateComponents(month: 11, day: 8, hour: 12), "anchored to the ESPN (US Eastern) calendar day")
        XCTAssertEqual(wta[0].tournament, "WTA Finals")
        XCTAssertEqual(wta[0].home.team.countryCode, "BY")
    }

    func testInterruptedAndActiveStatusesAreExplicit() {
        func status(
            _ name: String,
            description: String,
            state: String = "pre"
        ) -> ESPNScoreboardResponse.Status {
            .init(
                clock: nil,
                displayClock: nil,
                period: nil,
                type: .init(
                    id: nil,
                    name: name,
                    state: state,
                    completed: false,
                    description: description,
                    detail: nil,
                    shortDetail: nil
                )
            )
        }
        XCTAssertEqual(ESPNMapping.status(from: status("STATUS_POSTPONED", description: "Postponed")), .postponed)
        XCTAssertEqual(ESPNMapping.status(from: status("STATUS_CANCELED", description: "Canceled")), .canceled)
        XCTAssertEqual(ESPNMapping.status(from: status("STATUS_SUSPENDED", description: "Suspended")), .suspended)
        XCTAssertEqual(ESPNMapping.status(from: status("STATUS_HALFTIME", description: "Halftime", state: "in")), .live)
        XCTAssertEqual(ESPNMapping.status(from: status("STATUS_INTERMISSION", description: "Intermission", state: "in")), .live)
        XCTAssertEqual(ESPNMapping.status(from: status("STATUS_OVERTIME", description: "Overtime", state: "in")), .live)
    }

    func testAllFiveLeagueEndpointPathsAndFBSGroup() async throws {
        let empty = Data(#"{"leagues":[],"events":[]}"#.utf8)
        for league in KyroSportLeague.allCases {
            let transport = StubESPNTransport()
            transport.set(.init(data: empty))
            let client = ESPNAPIClient(transport: transport)
            _ = try await client.fetchScoreboard(
                league: league,
                dates: "20261108",
                policy: .liveScoreboard
            )
            let request = try XCTUnwrap(transport.lastRequest())
            XCTAssertEqual(request.url?.path, ESPNMapping.path(for: league))
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            let group = query?.first(where: { $0.name == "groups" })?.value
            XCTAssertEqual(group, league == .collegeFootball ? "80" : nil)
        }
    }

    func testNFLProviderUsesSeasonScheduleAndCurrentDayOverlay() async throws {
        let data = try ESPNFixtureSupport.data("nfl_scoreboard", bundleClass: Self.self)
        let transport = StubESPNTransport()
        transport.set(.init(data: data), leaguePath: nflPath, dates: "2026")
        transport.set(.init(data: data), leaguePath: nflPath, dates: "20261108")
        let provider = ESPNSportsProvider(client: ESPNAPIClient(transport: transport))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-08T18:00:00Z"))

        let output = try await provider.fetchNFLWindow(now: now, force: false)

        XCTAssertEqual(output.provider, "espn")
        XCTAssertEqual(output.season, 2026)
        XCTAssertEqual(output.week, 9)
        XCTAssertEqual(output.games.count, 3)
        XCTAssertEqual(transport.requestCount(), 2)
    }

    @MainActor
    func testStoreKeepsLastKnownGoodESPNDataWhenESPNFailsMidSession() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-08T18:00:00Z"))
        let espnData = try ESPNFixtureSupport.data("nfl_scoreboard", bundleClass: Self.self)
        let espnTransport = StubESPNTransport()
        espnTransport.set(.init(data: espnData), leaguePath: nflPath, dates: "2026")
        espnTransport.set(.init(data: espnData), leaguePath: nflPath, dates: "20261108")

        let sleeperTransport = StubSleeperTransport()
        sleeperTransport.set(
            .init(data: try SleeperFixtureSupport.data(named: "scores_nfl_week9", bundleClass: Self.self)),
            forPath: "/scores/nfl/regular/2026/9"
        )
        for week in [8, 10, 11] {
            sleeperTransport.set(
                .init(data: Data("[]".utf8)),
                forPath: "/scores/nfl/regular/2026/\(week)"
            )
        }
        sleeperTransport.set(
            .init(data: try SleeperFixtureSupport.data(named: "teams_nfl", bundleClass: Self.self)),
            forPath: "/teams/nfl"
        )
        sleeperTransport.set(
            .init(data: Data(#"{"week":9,"season":"2026","season_type":"regular"}"#.utf8)),
            forPath: "/v1/state/nfl"
        )

        let store = KyroSportsHubStore(
            espnClient: ESPNAPIClient(transport: espnTransport),
            sleeperClient: SleeperAPIClient(
                transport: sleeperTransport,
                cache: SleeperResponseCache()
            ),
            now: { now }
        )
        await store.load()
        XCTAssertEqual(store.sections.flatMap(\.games).first?.id.provider, "espn")
        XCTAssertEqual(sleeperTransport.requestCount(), 0, "fallback stays idle while ESPN succeeds")

        espnTransport.setFailure(KyroSportsDataError.offline)
        await store.load(force: true)
        // Last-known-good ESPN data stays on screen, flagged stale, instead of
        // swapping to a different provider's records mid-session.
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertTrue(store.sections.flatMap(\.games).allSatisfy { $0.id.provider == "espn" })
        XCTAssertTrue(store.isShowingStaleData)
        XCTAssertEqual(sleeperTransport.requestCount(), 0)
    }

    @MainActor
    func testStoreFallsBackToSleeperWhenESPNFailsOnColdStart() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-08T18:00:00Z"))
        let espnData = try ESPNFixtureSupport.data("nfl_scoreboard", bundleClass: Self.self)
        let espnTransport = StubESPNTransport()
        espnTransport.set(.init(data: espnData), leaguePath: nflPath, dates: "2026")
        espnTransport.set(.init(data: espnData), leaguePath: nflPath, dates: "20261108")

        let sleeperTransport = StubSleeperTransport()
        sleeperTransport.set(
            .init(data: try SleeperFixtureSupport.data(named: "scores_nfl_week9", bundleClass: Self.self)),
            forPath: "/scores/nfl/regular/2026/9"
        )
        for week in [8, 10, 11] {
            sleeperTransport.set(
                .init(data: Data("[]".utf8)),
                forPath: "/scores/nfl/regular/2026/\(week)"
            )
        }
        sleeperTransport.set(
            .init(data: try SleeperFixtureSupport.data(named: "teams_nfl", bundleClass: Self.self)),
            forPath: "/teams/nfl"
        )
        sleeperTransport.set(
            .init(data: Data(#"{"week":9,"season":"2026","season_type":"regular"}"#.utf8)),
            forPath: "/v1/state/nfl"
        )

        let store = KyroSportsHubStore(
            espnClient: ESPNAPIClient(transport: espnTransport),
            sleeperClient: SleeperAPIClient(
                transport: sleeperTransport,
                cache: SleeperResponseCache()
            ),
            now: { now }
        )
        espnTransport.setFailure(KyroSportsDataError.offline)
        await store.load()
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertTrue(store.sections.flatMap(\.games).allSatisfy { $0.id.provider == "sleeper" })
        XCTAssertGreaterThan(sleeperTransport.requestCount(), 0)
    }

    func testEmptyScoreboardIsValid() async throws {
        let transport = StubESPNTransport()
        transport.set(.init(data: Data(#"{"leagues":[],"events":[]}"#.utf8)))
        let provider = ESPNSportsProvider(client: ESPNAPIClient(transport: transport))
        let games = try await provider.fetchScoreboard(league: .nba, on: Date())
        XCTAssertTrue(games.isEmpty)
    }

    func testMalformedResponseIsNotCached() async throws {
        let transport = StubESPNTransport()
        transport.set(.init(data: Data("not-json".utf8)))
        let client = ESPNAPIClient(transport: transport)
        do {
            _ = try await client.fetchScoreboard(
                league: .nfl,
                dates: "20261108",
                policy: .liveScoreboard
            )
            XCTFail("expected malformed response")
        } catch {
            XCTAssertEqual(error as? KyroSportsDataError, .malformedResponse)
        }
        let cachedCount = await client.cachedResponseCount()
        XCTAssertEqual(cachedCount, 0)

        transport.set(.init(data: Data(#"{"leagues":[],"events":[]}"#.utf8)))
        _ = try await client.fetchScoreboard(
            league: .nfl,
            dates: "20261108",
            policy: .liveScoreboard
        )
        XCTAssertEqual(transport.requestCount(), 2)
    }

    func testLiveCacheExpiresAndRevalidates() async throws {
        let start = Date(timeIntervalSince1970: 1_791_396_000)
        let clock = Clock(start)
        let transport = StubESPNTransport()
        transport.set(.init(data: Data(#"{"leagues":[],"events":[]}"#.utf8), etag: "v1"))
        let client = ESPNAPIClient(transport: transport, now: { clock.now() })

        _ = try await client.fetchScoreboard(league: .nfl, dates: "20261108", policy: .liveScoreboard)
        clock.advance(10)
        _ = try await client.fetchScoreboard(league: .nfl, dates: "20261108", policy: .liveScoreboard)
        XCTAssertEqual(transport.requestCount(), 1)

        clock.advance(11)
        _ = try await client.fetchScoreboard(league: .nfl, dates: "20261108", policy: .liveScoreboard)
        XCTAssertEqual(transport.requestCount(), 2)
        XCTAssertEqual(transport.lastRequest()?.value(forHTTPHeaderField: "If-None-Match"), "v1")
    }

    func testDuplicateInFlightRequestsAreCoalesced() async throws {
        let transport = StubESPNTransport()
        transport.set(.init(
            data: Data(#"{"leagues":[],"events":[]}"#.utf8),
            delay: .milliseconds(50)
        ))
        let client = ESPNAPIClient(transport: transport)

        async let first = client.fetchScoreboard(
            league: .nfl,
            dates: "20261108",
            policy: .liveScoreboard
        )
        async let second = client.fetchScoreboard(
            league: .nfl,
            dates: "20261108",
            policy: .liveScoreboard
        )
        _ = try await (first, second)

        XCTAssertEqual(transport.requestCount(), 1)
    }

    func testRescheduledCrossProviderRecordsAreNotSilentlyMerged() {
        let original = crossProviderGame(
            id: "sleeper",
            provider: "sleeper",
            start: Date(timeIntervalSince1970: 1_794_148_200)
        )
        let moved = crossProviderGame(
            id: "espn",
            provider: "espn",
            start: original.startTime!.addingTimeInterval(24 * 3600)
        )
        let result = KyroSportsReconciler.reconcile(primary: [moved], fallback: [original])

        XCTAssertEqual(result.games.count, 2)
        XCTAssertEqual(result.conflicts.count, 1)
        XCTAssertEqual(result.games.flatMap(\.provenance).count, 2)
    }

    private func crossProviderGame(id: String, provider: String, start: Date) -> KyroSportsGame {
        KyroSportsGame(
            id: KyroGameID(provider: provider, league: .nfl, rawID: id),
            league: .nfl,
            season: 2026,
            seasonType: .regular,
            week: 9,
            startTime: start,
            status: .scheduled,
            home: KyroGameTeam(team: .placeholder(abbreviation: "ATL", league: .nfl)),
            away: KyroGameTeam(team: .placeholder(abbreviation: "CIN", league: .nfl))
        )
    }
}
