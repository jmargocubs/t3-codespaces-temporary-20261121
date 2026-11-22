import Foundation
import XCTest
@testable import Silo

/// Verifies that live-shaped ESPN NFL payloads decode and that ESPN is the
/// primary NFL source with Sleeper as the cold-start fallback.
final class KyroESPNNFLPrimaryTests: XCTestCase {
    private let nflPath = "/apis/site/v2/sports/football/nfl/scoreboard"

    // MARK: Helpers

    private func fixture(_ name: String) throws -> Data {
        let bundled = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
        let sourceRelative = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ESPN/\(name).json")
        return try Data(contentsOf: try XCTUnwrap(bundled ?? sourceRelative))
    }

    private func games(_ name: String) throws -> [KyroSportsGame] {
        let response = try JSONDecoder().decode(ESPNScoreboardResponse.self, from: fixture(name))
        return response.events.compactMap { ESPNMapping.game(from: $0, league: .nfl) }
    }

    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
    }

    private var emptyDay: Data { Data(#"{"leagues":[],"events":[]}"#.utf8) }

    private func easternCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func espnTransport(day: String, dayData: Data? = nil) throws -> StubESPNTransport {
        let transport = StubESPNTransport()
        transport.set(.init(data: try fixture("espn_nfl_schedule_week8_9")), leaguePath: nflPath, dates: "2026")
        transport.set(.init(data: dayData ?? emptyDay), leaguePath: nflPath, dates: day)
        return transport
    }

    private func sleeperTransport() throws -> StubSleeperTransport {
        let transport = StubSleeperTransport()
        transport.set(
            .init(data: try SleeperFixtureSupport.data(named: "scores_nfl_week9", bundleClass: Self.self)),
            forPath: "/scores/nfl/regular/2026/9"
        )
        for week in [8, 10, 11] {
            transport.set(.init(data: Data("[]".utf8)), forPath: "/scores/nfl/regular/2026/\(week)")
        }
        transport.set(
            .init(data: try SleeperFixtureSupport.data(named: "teams_nfl", bundleClass: Self.self)),
            forPath: "/teams/nfl"
        )
        transport.set(
            .init(data: Data(#"{"week":9,"season":"2026","season_type":"regular"}"#.utf8)),
            forPath: "/v1/state/nfl"
        )
        return transport
    }

    @MainActor
    private func makeStore(
        espn: StubESPNTransport,
        sleeper: StubSleeperTransport,
        now: Date
    ) -> KyroSportsHubStore {
        KyroSportsHubStore(
            espnClient: ESPNAPIClient(transport: espn),
            sleeperClient: SleeperAPIClient(transport: sleeper, cache: SleeperResponseCache()),
            calendar: easternCalendar(),
            now: { now }
        )
    }

    // MARK: Decoding

    func testLiveNFLPayloadPreservesKickoffLogosScoresAndStatus() throws {
        let finals = try games("espn_nfl_finals_week8")
        XCTAssertEqual(finals.count, 2)
        let buffalo = try XCTUnwrap(finals.first { $0.id.rawID == "401873026" })
        XCTAssertEqual(buffalo.status, .final)
        XCTAssertEqual(buffalo.startTime, try date("2026-11-01T18:00:00Z"), "minute-precision timestamp")
        XCTAssertEqual(buffalo.home.team.abbreviation, "BUF")
        XCTAssertEqual([buffalo.home.score, buffalo.away.score], [36, 10])
        XCTAssertNotNil(buffalo.home.team.logoURL)
        XCTAssertNotNil(buffalo.away.team.logoURL)
        XCTAssertEqual(buffalo.week, 8)
        XCTAssertEqual(buffalo.season, 2026)
        XCTAssertEqual(buffalo.seasonType, .regular)
        XCTAssertEqual(buffalo.periods.map(\.label), ["Q1", "Q2", "Q3", "Q4"])

        let live = try XCTUnwrap(games("espn_synthetic_nfl_live").first)
        XCTAssertEqual(live.status, .live)
        XCTAssertEqual(live.statusLine, "7:41 - 3rd")
        XCTAssertEqual([live.home.score, live.away.score], [17, 14])

        let scheduled = try XCTUnwrap(games("espn_nfl_live_payload_shape").first)
        XCTAssertEqual(scheduled.status, .scheduled)
        XCTAssertEqual(scheduled.startTime, try date("2026-11-08T14:30:00Z"))
        XCTAssertNil(scheduled.home.score, "scheduled games carry no score")
        XCTAssertEqual(scheduled.week, 9)
    }

    // MARK: Provider

    func testProviderReportsESPNSeasonAndAuthoritativeWeekAndFiltersCurrentWeek() async throws {
        let now = try date("2026-11-07T18:00:00Z") // Saturday before week 9
        let provider = ESPNSportsProvider(
            client: ESPNAPIClient(transport: try espnTransport(day: "20261107")),
            calendar: easternCalendar()
        )

        let output = try await provider.fetchNFLWindow(now: now, force: false)

        XCTAssertEqual(output.provider, "espn")
        XCTAssertEqual(output.season, 2026)
        XCTAssertEqual(output.week, 9)
        XCTAssertNil(output.refreshError)
        XCTAssertEqual(Set(output.games.map(\.id.rawID)).count, output.games.count)

        let context = KyroSportsScheduleContext(league: .nfl, currentWeek: output.week, currentSeason: output.season)
        let sections = KyroSportsSectioning.sections(
            from: output.games, now: now, calendar: easternCalendar(), context: context)
        let upcoming = sections.filter { $0.bucket == .upcoming }.flatMap(\.games)
        XCTAssertEqual(Set(upcoming.map(\.id.rawID)), ["401873038", "401873040"])
        XCTAssertTrue(upcoming.allSatisfy { $0.week == 9 })
        let recent = sections.filter { $0.bucket == .recent }.flatMap(\.games)
        XCTAssertEqual(Set(recent.map(\.id.rawID)), ["401873026", "401873031"])
    }

    func testCurrentDayLiveOverlayReplacesScheduleRowWithoutDuplicating() async throws {
        let now = try date("2026-11-08T15:30:00Z")
        let provider = ESPNSportsProvider(
            client: ESPNAPIClient(
                transport: try espnTransport(day: "20261108", dayData: try fixture("espn_synthetic_nfl_live"))
            ),
            calendar: easternCalendar()
        )

        let output = try await provider.fetchNFLWindow(now: now, force: false)

        XCTAssertEqual(output.games.count, 4)
        let live = try XCTUnwrap(output.games.first { $0.id.rawID == "401873038" })
        XCTAssertEqual(live.status, .live)
        XCTAssertEqual(live.home.score, 17)
        XCTAssertEqual(output.games.filter { $0.id.rawID == "401873038" }.count, 1)
    }

    // MARK: Store primary / fallback

    @MainActor
    func testStoreUsesESPNAsPrimaryWithoutTouchingSleeper() async throws {
        let sleeper = try sleeperTransport()
        let store = makeStore(
            espn: try espnTransport(day: "20261107"),
            sleeper: sleeper,
            now: try date("2026-11-07T18:00:00Z")
        )
        store.selectCategory(.nfl)
        await store.load()

        let all = store.sections.flatMap(\.games)
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertFalse(all.isEmpty)
        XCTAssertTrue(all.allSatisfy { $0.id.provider == "espn" })
        XCTAssertTrue(all.allSatisfy { $0.home.team.logoURL != nil && $0.away.team.logoURL != nil })
        XCTAssertFalse(store.isShowingStaleData)
        XCTAssertEqual(sleeper.requestCount(), 0)
    }

    @MainActor
    func testTransientESPNFailureKeepsLastKnownGoodESPNGames() async throws {
        let espn = try espnTransport(day: "20261107")
        let sleeper = try sleeperTransport()
        let store = makeStore(espn: espn, sleeper: sleeper, now: try date("2026-11-07T18:00:00Z"))
        store.selectCategory(.nfl)
        await store.load()
        let before = store.sections.flatMap(\.games).map(\.id)

        espn.setFailure(KyroSportsDataError.offline)
        await store.load(force: true)

        XCTAssertEqual(store.sections.flatMap(\.games).map(\.id), before, "no games lost or replaced")
        XCTAssertTrue(store.isShowingStaleData)
        XCTAssertEqual(sleeper.requestCount(), 0)
    }

    @MainActor
    func testColdStartFallsBackToSleeperThenRecoversToESPNWithoutDuplicates() async throws {
        let espn = try espnTransport(day: "20261107")
        let sleeper = try sleeperTransport()
        espn.setFailure(KyroSportsDataError.offline)
        let store = makeStore(espn: espn, sleeper: sleeper, now: try date("2026-11-07T18:00:00Z"))
        store.selectCategory(.nfl)

        await store.load()
        let fallback = store.sections.flatMap(\.games)
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertFalse(fallback.isEmpty)
        XCTAssertTrue(fallback.allSatisfy { $0.id.provider == "sleeper" })

        espn.setFailure(nil)
        await store.load(force: true)
        let recovered = store.sections.flatMap(\.games)
        XCTAssertTrue(recovered.allSatisfy { $0.id.provider == "espn" }, "providers are never blended")
        XCTAssertEqual(Set(recovered.map(\.id)).count, recovered.count)
        XCTAssertEqual(Set(recovered.map(\.id.rawID)).isSubset(of: ["401873026", "401873031", "401873038", "401873040"]), true)
        XCTAssertFalse(store.isShowingStaleData)
    }
}
