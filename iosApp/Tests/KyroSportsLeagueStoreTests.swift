import Foundation
import XCTest
@testable import Silo

/// Phase S5: the store's per-league state, routing, caching, cancellation and
/// persistence, plus league-specific windowing through the shared dashboard.
@MainActor
final class KyroSportsLeagueStoreTests: XCTestCase {

    // MARK: Fixtures and doubles

    private let now = Date(timeIntervalSince1970: 1_793_988_000) // 2026-11-06 18:00 UTC

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func game(
        _ id: String,
        _ league: KyroSportLeague,
        _ status: KyroGameStatus = .scheduled,
        hoursFromNow: Double,
        week: Int? = nil,
        note: String? = nil
    ) -> KyroSportsGame {
        KyroSportsGame(
            id: KyroGameID(provider: "espn", league: league, rawID: id),
            league: league,
            season: 2026,
            seasonType: .regular,
            week: week,
            startTime: now.addingTimeInterval(hoursFromNow * 3600),
            status: status,
            home: KyroGameTeam(team: .placeholder(abbreviation: "HOM", league: league), score: status.isScheduled ? nil : 3),
            away: KyroGameTeam(team: .placeholder(abbreviation: "AWY", league: league), score: status.isScheduled ? nil : 2),
            note: note
        )
    }

    private func output(_ games: [KyroSportsGame], week: Int = 0, error: KyroSportsDataError? = nil) -> KyroSportsProviderOutput {
        KyroSportsProviderOutput(provider: "stub", games: games, season: 2026, week: week, refreshError: error)
    }

    /// Records calls per league and optionally parks a league until released.
    private actor LeagueStub: KyroSportsLeagueProviding {
        private(set) var calls: [KyroSportLeague] = []
        private var results: [KyroSportLeague: KyroSportsProviderOutput] = [:]
        private var failing: Set<KyroSportLeague> = []
        private var gated: Set<KyroSportLeague> = []
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var parked = 0

        func set(_ league: KyroSportLeague, _ output: KyroSportsProviderOutput) { results[league] = output }
        func setFailing(_ league: KyroSportLeague, _ value: Bool) {
            if value { failing.insert(league) } else { failing.remove(league) }
        }
        func gate(_ league: KyroSportLeague) { gated.insert(league) }
        func release() {
            gated.removeAll()
            let pending = waiters
            waiters = []
            pending.forEach { $0.resume() }
        }
        func callCount(_ league: KyroSportLeague) -> Int { calls.filter { $0 == league }.count }

        func fetchLeagueWindow(league: KyroSportLeague, now: Date, force: Bool) async throws -> KyroSportsProviderOutput {
            calls.append(league)
            if gated.contains(league) {
                parked += 1
                await withCheckedContinuation { waiters.append($0) }
            }
            if failing.contains(league) { throw KyroSportsDataError.httpStatus(503) }
            return results[league] ?? KyroSportsProviderOutput(
                provider: "stub", games: [], season: 2026, week: 0, refreshError: nil
            )
        }
    }

    private struct NFLStub: KyroSportsProviding {
        let providerID = "nfl-stub"
        let games: [KyroSportsGame]
        func fetchNFLWindow(now: Date, force: Bool) async throws -> KyroSportsProviderOutput {
            KyroSportsProviderOutput(provider: providerID, games: games, season: 2026, week: 9, refreshError: nil)
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var date: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    private func makeStore(
        stub: LeagueStub,
        nfl: [KyroSportsGame] = [],
        clock: Clock? = nil,
        preferences: UserDefaults? = nil
    ) -> KyroSportsHubStore {
        let clock = clock ?? Clock(now)
        let store = KyroSportsHubStore(
            providers: [NFLStub(games: nfl)],
            leagueProvider: stub,
            calendar: calendar,
            now: { clock.date },
            preferences: preferences
        )
        if preferences == nil {
            store.selectCategory(.nfl)
        }
        return store
    }

    private func ephemeralDefaults() -> UserDefaults {
        let name = "kyro.sports.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func ids(_ store: KyroSportsHubStore) -> [String] {
        store.sections.flatMap(\.games).map(\.id.rawID)
    }

    /// Waits for the stub to report a parked request, bounded by iteration count.
    private func waitUntilParked(_ stub: LeagueStub) async {
        for _ in 0..<500 {
            if await stub.parked > 0 { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("request never reached the provider")
    }

    // MARK: Routing

    private final class RecordingTransport: ESPNTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { seen } }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { seen.append(request) }
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (Data(#"{"leagues":[],"events":[],"week":{"number":10}}"#.utf8), http)
        }
    }

    func testEachLeagueRoutesToItsESPNScoreboardPath() async throws {
        let expected: [KyroSportLeague: String] = [
            .nfl: "/football/nfl/scoreboard",
            .nba: "/basketball/nba/scoreboard",
            .nhl: "/hockey/nhl/scoreboard",
            .mlb: "/baseball/mlb/scoreboard",
            .collegeFootball: "/football/college-football/scoreboard"
        ]
        for (league, suffix) in expected {
            let transport = RecordingTransport()
            let store = KyroSportsHubStore(
                espnClient: ESPNAPIClient(transport: transport),
                sleeperClient: SleeperAPIClient(transport: StubSleeperTransport(), cache: SleeperResponseCache()),
                calendar: calendar,
                now: { [now] in now }
            )
            store.selectCategory(KyroSportsCategory(league: league))
            await store.load()

            let requests = transport.requests
            XCTAssertFalse(requests.isEmpty, league.displayName)
            XCTAssertTrue(
                requests.allSatisfy { $0.url?.path.hasSuffix(suffix) == true },
                "\(league.displayName) hit \(requests.compactMap { $0.url?.path })"
            )
            let groups = requests.compactMap { request in
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "groups" }?.value
            }
            if league == .collegeFootball {
                XCTAssertEqual(groups, ["80"], "FBS only, one undated week request")
                XCTAssertEqual(requests.count, 1)
            } else {
                XCTAssertTrue(groups.isEmpty, league.displayName)
            }
        }
    }

    func testNFLUsesProviderChainAndOtherLeaguesUseLeagueProvider() async {
        let stub = LeagueStub()
        await stub.set(.nba, output([game("nba1", .nba, hoursFromNow: 3)]))
        let store = makeStore(stub: stub, nfl: [game("nfl1", .nfl, hoursFromNow: 3, week: 9)])

        await store.load()
        XCTAssertEqual(ids(store), ["nfl1"])
        let nflCalls = await stub.callCount(.nfl)
        XCTAssertEqual(nflCalls, 0, "NFL must never reach the league provider")

        store.selectedLeague = .nba
        await store.load()
        XCTAssertEqual(ids(store), ["nba1"])
    }

    // MARK: Switching and contamination

    func testSwitchingLeaguesDuringInFlightRequestNeverContaminatesGames() async {
        let stub = LeagueStub()
        await stub.set(.nba, output([game("nba1", .nba, hoursFromNow: 3)]))
        await stub.set(.nhl, output([game("nhl1", .nhl, hoursFromNow: 4)]))
        await stub.gate(.nba)
        let store = makeStore(stub: stub)

        store.selectedLeague = .nba
        let slowNBA = Task { await store.load() }
        await waitUntilParked(stub)
        XCTAssertEqual(store.phase, .loading)

        store.selectedLeague = .nhl
        XCTAssertTrue(store.sections.isEmpty, "no NBA rows may appear under the NHL chip")
        await store.loadIfNeeded()
        XCTAssertEqual(ids(store), ["nhl1"])

        await stub.release() // the stale NBA response now arrives
        await slowNBA.value
        XCTAssertEqual(ids(store), ["nhl1"], "late NBA response must not replace NHL games")
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.scheduleRows.map(\.id), ["game|espn.nhl.nhl1"], "rows follow the NHL load only")

        // The abandoned NBA load left no data; returning to NBA starts fresh.
        store.selectedLeague = .nba
        XCTAssertTrue(store.sections.isEmpty)
        await store.loadIfNeeded()
        XCTAssertEqual(ids(store), ["nba1"])
        XCTAssertTrue(store.sections.flatMap(\.games).allSatisfy { $0.league == .nba })
    }

    func testConcurrentLoadsForTheSameLeagueCoalesce() async {
        let stub = LeagueStub()
        await stub.set(.mlb, output([game("mlb1", .mlb, hoursFromNow: 5)]))
        await stub.gate(.mlb)
        let store = makeStore(stub: stub)
        store.selectedLeague = .mlb

        let first = Task { await store.load() }
        await waitUntilParked(stub)
        let second = Task { await store.load(force: true) }
        await Task.yield()
        await stub.release()
        await first.value
        await second.value

        let calls = await stub.callCount(.mlb)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(ids(store), ["mlb1"])
    }

    // MARK: Caching

    func testPerLeagueCacheAvoidsRepeatedDownloadsWhenSwitching() async {
        let clock = Clock(now)
        let stub = LeagueStub()
        await stub.set(.nba, output([game("nba1", .nba, hoursFromNow: 3)]))
        await stub.set(.nhl, output([game("nhl1", .nhl, hoursFromNow: 3)]))
        let store = makeStore(stub: stub, clock: clock)

        store.selectedLeague = .nba
        await store.loadIfNeeded()
        store.selectedLeague = .nhl
        await store.loadIfNeeded()
        store.selectedLeague = .nba
        XCTAssertEqual(ids(store), ["nba1"], "cached rows show instantly")
        await store.loadIfNeeded()
        store.selectedLeague = .nhl
        await store.loadIfNeeded()

        let nba = await stub.callCount(.nba)
        let nhl = await stub.callCount(.nhl)
        XCTAssertEqual([nba, nhl], [1, 1])

        clock.advance(KyroSportsHubStore.freshnessInterval + 1)
        await store.loadIfNeeded()
        let refreshed = await stub.callCount(.nhl)
        XCTAssertEqual(refreshed, 2, "an expired cache refreshes")
    }

    func testFailedRefreshKeepsLastKnownGoodGamesAndFlagsStale() async {
        let stub = LeagueStub()
        await stub.set(.nba, output([game("nba1", .nba, hoursFromNow: 3)]))
        let store = makeStore(stub: stub)
        store.selectedLeague = .nba
        await store.load()
        XCTAssertFalse(store.isShowingStaleData)

        await stub.setFailing(.nba, true)
        await store.load(force: true)
        XCTAssertEqual(ids(store), ["nba1"])
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertTrue(store.isShowingStaleData)
        XCTAssertEqual(store.lastRefreshError, .httpStatus(503))

        await stub.setFailing(.nba, false)
        await store.load(force: true)
        XCTAssertFalse(store.isShowingStaleData)
        XCTAssertNil(store.lastRefreshError)
    }

    func testFirstLoadFailureIsPerLeague() async {
        let stub = LeagueStub()
        await stub.setFailing(.nhl, true)
        await stub.set(.nba, output([game("nba1", .nba, hoursFromNow: 3)]))
        let store = makeStore(stub: stub)

        store.selectedLeague = .nhl
        await store.load()
        XCTAssertEqual(store.phase, .failed(.httpStatus(503)))

        store.selectedLeague = .nba
        XCTAssertEqual(store.phase, .idle, "NHL's failure must not leak onto NBA")
        await store.load()
        XCTAssertEqual(store.phase, .loaded)
    }

    // MARK: Persistence and mode

    func testSelectedLeagueAndDashboardModePersistPerLeague() async {
        let defaults = ephemeralDefaults()
        let stub = LeagueStub()
        let first = makeStore(stub: stub, preferences: defaults)
        first.selectedLeague = .mlb
        first.selectDashboardMode(.results)
        first.selectedLeague = .nba
        first.selectDashboardMode(.live)

        let second = makeStore(stub: stub, preferences: defaults)
        XCTAssertEqual(second.selectedLeague, .nba)
        XCTAssertEqual(second.selectedDashboardMode, .live)
        second.selectedLeague = .mlb
        XCTAssertEqual(second.selectedDashboardMode, .results)
        second.selectedLeague = .nhl
        XCTAssertEqual(second.selectedDashboardMode, .upcoming, "untouched leagues keep the default")
    }

    func testBackupRestoreReloadsDashboardModesWithoutChangingSelectedLeague() async {
        let defaults = ephemeralDefaults()
        let store = makeStore(stub: LeagueStub(), preferences: defaults)
        store.selectedLeague = .nba
        store.selectDashboardMode(.results)
        defaults.set("live", forKey: KyroSportsHubStore.modeKey(.nba))
        defaults.set("results", forKey: KyroSportsHubStore.modeKey(.nhl))
        store.reloadDashboardModesFromPreferences()
        XCTAssertEqual(store.selectedLeague, .nba)
        XCTAssertEqual(store.selectedDashboardMode, .live)
        store.selectedLeague = .nhl
        XCTAssertEqual(store.selectedDashboardMode, .results)
        defaults.removeObject(forKey: KyroSportsHubStore.modeKey(.nhl))
        store.reloadDashboardModesFromPreferences()
        XCTAssertEqual(store.selectedDashboardMode, .upcoming)
    }

    func testModeIsIndependentPerLeagueAndSurvivesRefreshes() async {
        let stub = LeagueStub()
        await stub.set(.nba, output([game("live", .nba, .live, hoursFromNow: -1)]))
        await stub.set(.nhl, output([game("next", .nhl, hoursFromNow: 6)]))
        let store = makeStore(stub: stub)

        store.selectedLeague = .nba
        await store.load()
        XCTAssertEqual(store.selectedDashboardMode, .live)

        store.selectedLeague = .nhl
        await store.load()
        XCTAssertEqual(store.selectedDashboardMode, .upcoming)
        store.selectDashboardMode(.results)

        store.selectedLeague = .nba
        XCTAssertEqual(store.selectedDashboardMode, .live)
        await store.load(force: true)
        XCTAssertEqual(store.selectedDashboardMode, .live)
        store.selectedLeague = .nhl
        XCTAssertEqual(store.selectedDashboardMode, .results)
    }

    // MARK: Windows

    func testRollingSevenDayWindowIncludesTodayAndExcludesDayEight() async {
        let stub = LeagueStub()
        // `now` is 18:00 UTC Friday; the window is start-of-today + 7 days.
        await stub.set(.nba, output([
            game("tonight", .nba, hoursFromNow: 3),
            game("day6", .nba, hoursFromNow: 6 * 24),
            game("day7", .nba, hoursFromNow: 7 * 24),
            game("day8", .nba, hoursFromNow: 8 * 24)
        ]))
        let store = makeStore(stub: stub)
        store.selectedLeague = .nba
        await store.load()

        let visible = store.visibleSections.flatMap(\.games).map(\.id.rawID)
        XCTAssertEqual(visible, ["tonight", "day6"])
        XCTAssertEqual(store.visibleSections.first?.bucket, .today)
        let later = store.sections.filter { $0.bucket == .future }.flatMap(\.games).map(\.id.rawID)
        XCTAssertEqual(Set(later), ["day7", "day8"], "kept for cache but not listed")
    }

    func testNCAAShowsOnlyESPNsCurrentWeekAndKeepsBowlNote() async {
        let stub = LeagueStub()
        await stub.set(.collegeFootball, output([
            game("w10-sat", .collegeFootball, hoursFromNow: 20, week: 10),
            game("w10-bowl", .collegeFootball, hoursFromNow: 40, week: 10, note: "Celebration Bowl"),
            game("w11", .collegeFootball, hoursFromNow: 24 * 6, week: 11)
        ], week: 10))
        let store = makeStore(stub: stub)
        store.selectedLeague = .collegeFootball
        await store.load()

        let visible = store.visibleSections.flatMap(\.games)
        XCTAssertEqual(visible.map(\.id.rawID), ["w10-sat", "w10-bowl"])
        XCTAssertEqual(visible.last?.note, "Celebration Bowl")
        XCTAssertFalse(ids(store).isEmpty)
    }

    func testMLBOffseasonLoadsAsEmptyStateNotAnError() async {
        let stub = LeagueStub()
        await stub.set(.mlb, output([]))
        let store = makeStore(stub: stub)
        store.selectedLeague = .mlb
        await store.load()

        XCTAssertEqual(store.phase, .loaded)
        XCTAssertTrue(store.sections.isEmpty)
        XCTAssertTrue(store.scheduleRows.isEmpty)
        XCTAssertEqual(store.noGamesState.title, "MLB is in its offseason")
        XCTAssertFalse(store.isShowingStaleData)
    }

    func testEmptyStateCopyIsOffseasonOnlyForMLBInWinter() {
        let july = Date(timeIntervalSince1970: 1_784_000_000) // 2026-07
        XCTAssertEqual(
            KyroSportsDashboard.noGamesState(for: .mlb, now: july, calendar: calendar).title,
            "No games to show"
        )
        XCTAssertEqual(
            KyroSportsDashboard.noGamesState(for: .nba, now: now, calendar: calendar).message,
            "There are no NBA games in the current window."
        )
    }

    func testDoubleheaderGamesStaySeparate() async {
        let stub = LeagueStub()
        await stub.set(.mlb, output([
            game("g1", .mlb, hoursFromNow: 2),
            game("g2", .mlb, hoursFromNow: 6)
        ]))
        let store = makeStore(stub: stub)
        store.selectedLeague = .mlb
        await store.load()
        XCTAssertEqual(ids(store), ["g1", "g2"])
    }

    // MARK: Polling

    func testOnlyTheSelectedLeaguePolls() async {
        let stub = LeagueStub()
        await stub.set(.nba, output([game("live", .nba, .live, hoursFromNow: -1)]))
        let store = makeStore(stub: stub, nfl: [game("nfl1", .nfl, hoursFromNow: 72, week: 9)])

        store.selectedLeague = .nba
        await store.load()
        XCTAssertEqual(store.refreshInterval, 20)
        XCTAssertTrue(store.shouldPoll)

        store.selectedLeague = .nfl
        XCTAssertNil(store.refreshInterval, "a live NBA game must not poll under the NFL chip")
        XCTAssertFalse(store.shouldPoll)

        store.selectedLeague = .mlb
        XCTAssertFalse(store.shouldPoll)
        let mlbCalls = await stub.callCount(.mlb)
        XCTAssertEqual(mlbCalls, 0, "switching alone never fetches inactive leagues")
    }

    // MARK: League-specific presentation

    private func fixtureGames(_ name: String, league: KyroSportLeague) throws -> [KyroSportsGame] {
        let bundled = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
        let sourceRelative = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ESPN/\(name).json")
        let data = try Data(contentsOf: try XCTUnwrap(bundled ?? sourceRelative))
        let response = try JSONDecoder().decode(ESPNScoreboardResponse.self, from: data)
        return response.events.compactMap { ESPNMapping.game(from: $0, league: league) }
    }

    func testNBAAndNHLScoresRecordsAndPeriodLabels() throws {
        let nba = try XCTUnwrap(fixtureGames("espn_nba_finals", league: .nba).first { $0.id.rawID == "401810341" })
        XCTAssertEqual([nba.away.score, nba.home.score], [125, 115])
        XCTAssertEqual(nba.home.displayRecord, "19-16")
        XCTAssertEqual(nba.periods.map(\.label), ["Q1", "Q2", "Q3", "Q4"])

        let nhl = try fixtureGames("espn_nhl_regulation_ot_shootout", league: .nhl)
        let shootout = try XCTUnwrap(nhl.first { $0.id.rawID == "401803003" })
        XCTAssertEqual(shootout.periods.map(\.label), ["P1", "P2", "P3", "OT", "SO"])
        XCTAssertEqual(shootout.statusLine, "Final/SO")
        XCTAssertEqual([shootout.away.score, shootout.home.score].compactMap { $0 }.count, 2)
    }

    func testNCAARankedTeamsShowRankInDisplayName() throws {
        let games = try fixtureGames("espn_cfb_week10_live_ranked", league: .collegeFootball)
        let ranked = try XCTUnwrap(games.flatMap { [$0.home, $0.away] }.first { ($0.rank ?? 0) > 0 })
        XCTAssertTrue(ranked.rankedName.hasPrefix("#\(ranked.rank!) "))
        let unranked = KyroGameTeam(team: .placeholder(abbreviation: "ABC", league: .collegeFootball))
        XCTAssertEqual(unranked.rankedName, unranked.team.fullName)
    }
}
