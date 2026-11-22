import Foundation
import XCTest
@testable import Silo

/// The hub store's user-visible states: what it renders while loading, after a
/// failure, when offline, provider fallback and bounded weekly score windows.
@MainActor
final class KyroSportsHubStoreTests: XCTestCase {

    private struct StubSportsProvider: KyroSportsProviding {
        let providerID: String
        let output: KyroSportsProviderOutput?
        let error: KyroSportsDataError?

        func fetchNFLWindow(now: Date, force: Bool) async throws -> KyroSportsProviderOutput {
            if let error { throw error }
            return try XCTUnwrap(output)
        }
    }

    private let scorePath = "/scores/nfl/regular/2026/9"
    private let teamsPath = "/teams/nfl"
    private let statePath = "/v1/state/nfl"

    private func fixture(_ name: String) throws -> Data {
        try SleeperFixtureSupport.data(named: name, bundleClass: Self.self)
    }

    private func makeStore(
        transport: StubSleeperTransport,
        now: Date = Date(timeIntervalSince1970: 1_793_988_000)
    ) -> KyroSportsHubStore {
        let client = SleeperAPIClient(transport: transport, cache: SleeperResponseCache())
        let store = KyroSportsHubStore(
            client: client,
            season: "2026",
            calendar: Calendar(identifier: .gregorian),
            now: { now }
        )
        store.selectCategory(.nfl)
        return store
    }

    private func loadedTransport() throws -> StubSleeperTransport {
        let transport = StubSleeperTransport()
        transport.set(.init(data: try fixture("scores_nfl_week9")), forPath: scorePath)
        setEmptyNeighborWeeks(on: transport)
        transport.set(.init(data: try fixture("teams_nfl")), forPath: teamsPath)
        transport.set(.init(data: Data(#"{"week":9,"season":"2026","season_type":"regular","display_week":9}"#.utf8)),
                       forPath: statePath)
        return transport
    }

    private func setEmptyNeighborWeeks(on transport: StubSleeperTransport) {
        for week in [8, 10, 11] {
            transport.set(
                .init(data: Data("[]".utf8)),
                forPath: "/scores/nfl/regular/2026/\(week)"
            )
        }
    }

    // MARK: - Success

    func testLoadPopulatesSectionsAndTeams() async throws {
        let store = makeStore(transport: try loadedTransport())
        await store.load()

        XCTAssertEqual(store.phase, .loaded)
        XCTAssertFalse(store.sections.isEmpty)
        XCTAssertFalse(store.isShowingStaleData)

        let allGames = store.sections.flatMap(\.games)
        // The trimmed team fixture holds SF, CHI, CIN and BUF only, so CHI
        // resolves from the catalog while BAL falls back to a placeholder.
        let chicago = try XCTUnwrap(allGames.first { $0.home.team.abbreviation == "CHI" })
        XCTAssertEqual(chicago.home.team.nickname, "Bears")
        XCTAssertEqual(chicago.home.team.location, "Chicago")
        XCTAssertNotNil(chicago.home.team.logoURL, "team catalog was available")

        let final = try XCTUnwrap(allGames.first { $0.status.isFinal })
        XCTAssertEqual(final.home.team.nickname, "BAL", "uncatalogued team keeps its abbreviation")
    }

    func testWeeklyScoreFeedSuppliesVerifiedUpcomingKickoffs() async throws {
        let store = makeStore(transport: try loadedTransport())
        await store.load()
        let allGames = store.sections.flatMap(\.games)
        let upcoming = allGames.filter { $0.status.isScheduled }
        XCTAssertFalse(upcoming.isEmpty)
        XCTAssertTrue(upcoming.allSatisfy { $0.startTime != nil })
    }

    func testProviderChainFallsBackAfterPrimaryOutage() async {
        let now = Date(timeIntervalSince1970: 1_793_988_000)
        let game = KyroSportsGame(
            id: KyroGameID(provider: "fallback", league: .nfl, rawID: "g1"),
            league: .nfl,
            season: 2026,
            seasonType: .regular,
            week: 9,
            startTime: now.addingTimeInterval(3600),
            status: .scheduled,
            home: KyroGameTeam(team: .placeholder(abbreviation: "KC", league: .nfl)),
            away: KyroGameTeam(team: .placeholder(abbreviation: "DEN", league: .nfl))
        )
        let fallbackOutput = KyroSportsProviderOutput(
            provider: "fallback",
            games: [game],
            season: 2026,
            week: 9,
            refreshError: nil
        )
        let store = KyroSportsHubStore(
            providers: [
                StubSportsProvider(providerID: "primary", output: nil, error: .offline),
                StubSportsProvider(providerID: "fallback", output: fallbackOutput, error: nil)
            ],
            now: { now }
        )

        await store.load()

        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.sections.flatMap(\.games).first?.id.provider, "fallback")
    }

    func testJanuaryUsesSeasonStartYearWhenStateIsUnavailable() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let january = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-05T18:00:00Z"))
        XCTAssertEqual(SleeperSportsProvider.seasonYear(for: january, calendar: calendar), 2026)
    }

    func testSeasonPhasesStayExplicitInsteadOfMixingWeekNumbers() {
        XCTAssertEqual(SleeperSportsProvider.seasonType(from: "pre"), .preseason)
        XCTAssertEqual(SleeperSportsProvider.seasonType(from: "regular"), .regular)
        XCTAssertEqual(SleeperSportsProvider.seasonType(from: "post"), .postseason)
        XCTAssertEqual(SleeperSportsProvider.seasonType(from: "unexpected"), .unknown)
        XCTAssertEqual(SleeperSportsProvider.windowWeeks(around: 1), [1, 2, 3])
        XCTAssertEqual(SleeperSportsProvider.windowWeeks(around: 18), [17, 18])
    }

    func testPostseasonStateDoesNotLeakIntoRegularWeekOne() async {
        let transport = StubSleeperTransport()
        transport.set(
            .init(data: Data(#"{"week":1,"season":"2026","season_type":"post"}"#.utf8)),
            forPath: statePath
        )
        let store = makeStore(transport: transport)

        await store.load()

        XCTAssertEqual(store.phase, .failed(.unsupportedSeasonPhase(.postseason)))
        XCTAssertTrue(store.sections.isEmpty)
    }

    // MARK: - Failure

    func testOfflineWithNoCacheShowsOfflinePhase() async {
        let transport = StubSleeperTransport()
        transport.setFailure(SleeperAPIError.offline)
        let store = makeStore(transport: transport)
        await store.load()

        XCTAssertEqual(store.phase, .offline)
        XCTAssertTrue(store.sections.isEmpty)
    }

    func testMalformedResponseShowsFailedPhase() async {
        let transport = StubSleeperTransport()
        transport.set(.init(data: Data("nope".utf8)), forPath: scorePath)
        setEmptyNeighborWeeks(on: transport)
        transport.set(.init(data: Data("nope".utf8)), forPath: teamsPath)
        transport.set(.init(data: Data(#"{"week":9}"#.utf8)), forPath: statePath)
        let store = makeStore(transport: transport)
        await store.load()

        XCTAssertEqual(store.phase, .failed(.malformedResponse))
    }

    func testFailureAfterSuccessKeepsGamesAndFlagsStale() async throws {
        let transport = try loadedTransport()
        let store = makeStore(transport: transport)
        await store.load()
        XCTAssertEqual(store.phase, .loaded)

        // A later refresh fails, but the cache still serves the last payload,
        // so the page keeps its rows and only raises the quiet notice.
        transport.setFailure(SleeperAPIError.httpStatus(500))
        await store.load(force: true)

        XCTAssertEqual(store.phase, .loaded)
        XCTAssertFalse(store.sections.isEmpty)
        XCTAssertTrue(store.isShowingStaleData)
        XCTAssertEqual(store.lastRefreshError, .httpStatus(500))
    }

    // MARK: - Leagues

    func testSelectingAnotherLeagueNeverShowsNFLRowsAndKeepsNFLCache() async throws {
        let transport = try loadedTransport()
        let store = makeStore(transport: transport)
        await store.load()
        let nflSections = store.sections
        XCTAssertFalse(nflSections.isEmpty)

        // A Sleeper-only store has no NBA source, so NBA must fail cleanly
        // instead of reusing NFL rows.
        store.selectedLeague = .nba
        XCTAssertTrue(store.sections.isEmpty)
        await store.load()
        XCTAssertTrue(store.sections.isEmpty)
        XCTAssertEqual(store.phase, .failed(.malformedResponse))

        store.selectedLeague = .nfl
        XCTAssertEqual(store.sections, nflSections)
        XCTAssertEqual(store.phase, .loaded)
    }

    func testEveryLeagueIsAvailableInS5() {
        for league in KyroSportLeague.allCases {
            XCTAssertTrue(league.isAvailable, "\(league.displayName) is active in S5")
        }
    }

    // MARK: - Polling

    func testNoPollingWhenNothingIsLiveOrStarting() async throws {
        let store = makeStore(transport: try loadedTransport())
        await store.load()
        // The fixture has one final game and scheduled games three days out.
        XCTAssertNil(store.refreshInterval)
        XCTAssertFalse(store.shouldPoll)
    }

    func testLiveGameRequestsTheFastInterval() async throws {
        let transport = StubSleeperTransport()
        transport.set(.init(data: try fixture("scores_nfl_live")), forPath: scorePath)
        setEmptyNeighborWeeks(on: transport)
        transport.set(.init(data: try fixture("teams_nfl")), forPath: teamsPath)
        transport.set(.init(data: Data(#"{"week":9,"season":"2026"}"#.utf8)), forPath: statePath)

        let liveLocalDay = ISO8601DateFormatter().date(from: "2026-11-06T02:00:00Z")!
        let store = makeStore(transport: transport, now: liveLocalDay)
        store.selectCategory(.nfl)
        await store.load()

        XCTAssertTrue(store.shouldPoll)
        XCTAssertEqual(store.refreshInterval, 20)
    }

    func testForceReloadBypassesTheFreshCache() async throws {
        let transport = try loadedTransport()
        let store = makeStore(transport: transport)
        await store.load()
        let first = transport.requestCount()
        await store.load() // fresh cache: no new requests
        XCTAssertEqual(transport.requestCount(), first)

        await store.load(force: true)
        XCTAssertGreaterThan(transport.requestCount(), first)
    }

    func testReentryReusesFreshScoresButExplicitRefreshStillFetches() async throws {
        let transport = try loadedTransport()
        let store = makeStore(transport: transport)
        await store.loadIfNeeded()
        let initialRequests = transport.requestCount()
        XCTAssertGreaterThan(initialRequests, 0)

        await store.loadIfNeeded() // Returning to the hub must use the warm snapshot.
        XCTAssertEqual(transport.requestCount(), initialRequests)

        await store.refresh() // Freshness must never suppress a user refresh.
        XCTAssertGreaterThan(transport.requestCount(), initialRequests)
    }

    // MARK: - Empty

    func testEmptyScoresAndScheduleProduceLoadedWithoutSections() async {
        let transport = StubSleeperTransport()
        transport.set(.init(data: Data("[]".utf8)), forPath: scorePath)
        setEmptyNeighborWeeks(on: transport)
        transport.set(.init(data: Data("[]".utf8)), forPath: teamsPath)
        transport.set(.init(data: Data(#"{"week":9}"#.utf8)), forPath: statePath)

        let store = makeStore(transport: transport)
        await store.load()

        // No games decoded, but the provider answered: the page shows the
        // "no games" message rather than an error.
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertTrue(store.sections.isEmpty)
    }
}
