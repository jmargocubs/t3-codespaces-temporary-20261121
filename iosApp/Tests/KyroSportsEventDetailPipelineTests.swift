import Foundation
import XCTest
@testable import Silo

/// Build 60: the whole Stats/News path on real ESPN responses, from the scoreboard event the hub
/// shows through the detail client and store to what the Stats and News tabs read.
///
/// Fixtures are minimized copies of responses captured on 2026-11-11 (see Fixtures/ESPN/SOURCE).
@MainActor
final class KyroSportsEventDetailPipelineTests: XCTestCase {
    /// Serves fixtures by endpoint and records every request path.
    private final class FixtureTransport: ESPNTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        private let files: [String: String]

        init(files: [String: String]) { self.files = files }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = try XCTUnwrap(request.url)
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let query = (components?.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }.sorted().joined(separator: "&")
            let key = "\(url.path)?\(query)"
            lock.withLock { paths.append(key) }
            guard let name = files[key] else {
                return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
            let data = try KyroSportsEventDetailPipelineTests.fixture(name)
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                          headerFields: ["Cache-Control": "max-age=10"])!)
        }

        var requested: [String] { lock.withLock { paths } }
    }

    nonisolated static func fixture(_ name: String) throws -> Data {
        let bundled = Bundle(for: KyroSportsEventDetailPipelineTests.self).url(forResource: name, withExtension: "json")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ESPN/\(name).json")
        return try Data(contentsOf: bundled ?? source)
    }

    private func game(scoreboard: String, league: KyroSportLeague, eventID: String) throws -> KyroSportsGame {
        let response = try JSONDecoder().decode(ESPNScoreboardResponse.self, from: Self.fixture(scoreboard))
        let event = try XCTUnwrap(response.events.first { $0.id == eventID })
        return try XCTUnwrap(ESPNMapping.game(from: event, league: league))
    }

    private func tennisGame(matchID: String) throws -> KyroSportsGame {
        let response = try JSONDecoder().decode(ESPNScoreboardResponse.self, from: Self.fixture("espn_b60_scoreboard_wta"))
        let games = try ESPNSportsProvider().mapValidated(response, league: .wta)
        return try XCTUnwrap(games.first { $0.id.rawID == matchID })
    }

    // MARK: Request → decode → validation → store → tab state

    /// The Build 59 screenshot's event. Stats rendered on device; this pins the whole path.
    func testWizardsAtPacersLoadsTeamAndPlayerStatisticsAndVerifiedNews() async throws {
        let game = try game(scoreboard: "espn_b60_scoreboard_nba", league: .nba, eventID: "401909966")
        XCTAssertEqual(game.away.team.abbreviation, "WSH")
        XCTAssertEqual(game.home.team.abbreviation, "IND")
        let transport = FixtureTransport(files: [
            "/apis/site/v2/sports/basketball/nba/summary?event=401909966": "espn_b60_summary_nba_401909966",
            "/apis/site/v2/sports/basketball/nba/news?limit=20&team=11": "espn_b60_news_nba_11",
            "/apis/site/v2/sports/basketball/nba/news?limit=20&team=27": "espn_b60_news_nba_27",
        ])
        let store = KyroSportsEventDetailStore(client: ESPNEventDetailClient(transport: transport))

        await store.load(for: game)

        XCTAssertEqual(store.phase, .loaded)
        let details = try XCTUnwrap(store.details)
        XCTAssertEqual(details.gameID, game.id)
        XCTAssertEqual(details.providerEventID, "401909966")
        XCTAssertEqual(Set(details.teamStatistics.map(\.abbreviation)), ["WSH", "IND"])
        XCTAssertTrue(details.teamStatistics.allSatisfy { $0.statistics.count >= 20 })
        XCTAssertTrue(details.teamStatistics.contains { $0.statistics.contains { $0.label == "Rebounds" } })
        XCTAssertEqual(details.playerBoxScores.count, 2)
        XCTAssertTrue(details.playerBoxScores.allSatisfy { !$0.groups.flatMap(\.athletes).isEmpty })
        XCTAssertTrue(details.hasStatistics)
        XCTAssertFalse(details.news.isEmpty)
        XCTAssertLessThanOrEqual(details.news.count, 12)
        XCTAssertEqual(Set(details.news.map(\.id)).count, details.news.count, "News is deduplicated")
        XCTAssertTrue(details.news.allSatisfy { $0.url.scheme == "https" && $0.publishedAt != nil })
        // League-wide stories tag all 30 teams. They are never presented as this matchup.
        XCTAssertFalse(details.news.contains { $0.relevance == .matchup && $0.headline.contains("Power Rankings") })
        XCTAssertEqual(Set(transport.requested), [
            "/apis/site/v2/sports/basketball/nba/summary?event=401909966",
            "/apis/site/v2/sports/basketball/nba/news?limit=20&team=11",
            "/apis/site/v2/sports/basketball/nba/news?limit=20&team=27",
        ])
    }

    /// Build 59 read MLB's grouped team statistics as empty and listed each team twice.
    func testMLBGroupedTeamStatisticsAndOneBoxScorePerTeam() async throws {
        let game = try game(scoreboard: "espn_b60_scoreboard_mlb", league: .mlb, eventID: "401908046")
        let transport = FixtureTransport(files: [
            "/apis/site/v2/sports/baseball/mlb/summary?event=401908046": "espn_b60_summary_mlb_401908046",
            "/apis/site/v2/sports/baseball/mlb/news?limit=20&team=30": "espn_b60_news_mlb_30",
        ])
        let store = KyroSportsEventDetailStore(client: ESPNEventDetailClient(transport: transport))

        await store.load(for: game)

        let details = try XCTUnwrap(store.details)
        let milwaukee = try XCTUnwrap(details.teamStatistics.first { $0.abbreviation == "MIL" })
        XCTAssertEqual(milwaukee.statistics.first, KyroSportsStatistic(label: "Runs", value: "4"))
        XCTAssertEqual(milwaukee.statistics.first { $0.label == "ERA" }?.value, "1.00")
        XCTAssertEqual(milwaukee.statistics.first { $0.label == "Errors" }?.value, "2")
        XCTAssertFalse(milwaukee.statistics.contains { $0.label.localizedCaseInsensitiveContains("games") })
        XCTAssertEqual(details.playerBoxScores.map(\.abbreviation).sorted(), ["MIL", "TB"])
        XCTAssertEqual(Set(details.playerBoxScores.flatMap { $0.groups.map(\.name) }), ["Batting", "Pitching"])
        XCTAssertEqual(details.news.first?.relevance, .event)
        XCTAssertEqual(details.news.first?.url.absoluteString, "https://www.espn.com/mlb/recap?gameId=401908046")
    }

    /// The recap arrives as http and is opened over https; it ranks first as this game's story.
    func testRecapIsTheExactEventStoryOverHTTPS() async throws {
        let game = try game(scoreboard: "espn_b60_scoreboard_nhl", league: .nhl, eventID: "401892683")
        let transport = FixtureTransport(files: [
            "/apis/site/v2/sports/hockey/nhl/summary?event=401892683": "espn_b60_summary_nhl_401892683",
            "/apis/site/v2/sports/hockey/nhl/news?limit=20&team=21": "espn_b60_news_nhl_21",
            "/apis/site/v2/sports/hockey/nhl/news?limit=20&team=17": "espn_b60_news_nhl_17",
        ])
        let details = try await ESPNEventDetailClient(transport: transport).fetchDetails(for: game)

        let first = try XCTUnwrap(details.news.first)
        XCTAssertEqual(first.relevance, .event)
        XCTAssertEqual(first.url.absoluteString, "https://www.espn.com/nhl/recap?gameId=401892683")
        XCTAssertTrue(first.headline.hasPrefix("Landeskog scores twice"))
        XCTAssertEqual(details.teamStatistics.count, 2)
        // ESPN's empty "skaters" group is dropped; the named groups read as titles.
        XCTAssertEqual(Set(details.playerBoxScores.flatMap { $0.groups.map(\.name) }), ["Forwards", "Defenses", "Goalies"])
    }

    /// The Build 58/59 device tests used WTA tennis, which has no ESPN summary. News now comes
    /// from stories tagged with the two players; Stats keeps its explicit fallback.
    func testTennisNewsIsVerifiedByPlayerIDsWithoutABoxScore() async throws {
        let game = try tennisGame(matchID: "187385")
        XCTAssertEqual(ESPNEventDetailMapping.tennisPlayerIDs(for: game), ["1797", "3039"])
        let transport = FixtureTransport(files: [
            "/apis/site/v2/sports/tennis/wta/news?limit=50": "espn_b60_news_wta",
        ])
        let store = KyroSportsEventDetailStore(client: ESPNEventDetailClient(transport: transport))

        await store.load(for: game)

        XCTAssertEqual(store.phase, .loaded)
        let details = try XCTUnwrap(store.details)
        XCTAssertFalse(details.hasStatistics)
        XCTAssertFalse(details.news.isEmpty)
        XCTAssertTrue(details.news.contains { $0.headline.contains("Muchova") })
        XCTAssertFalse(transport.requested.contains { $0.contains("/summary") }, "No tennis summary request")
    }

    func testTennisMatchupStoryNamesBothPlayers() async throws {
        let game = try tennisGame(matchID: "187373")
        let transport = FixtureTransport(files: [
            "/apis/site/v2/sports/tennis/wta/news?limit=50": "espn_b60_news_wta",
        ])
        let details = try await ESPNEventDetailClient(transport: transport).fetchDetails(for: game)
        XCTAssertTrue(details.news.allSatisfy { $0.relevance != .event })
        XCTAssertTrue(details.news.contains { $0.headline.contains("Noskova") })
    }

    // MARK: Lifecycle

    /// Build 59 keyed the detail task on the clock and the score, so each scoreboard tick of a live
    /// game cancelled and restarted the load. Only the event, the tab and the status kind count.
    func testLoadKeyIgnoresClockAndScoreButNotStatusKind() throws {
        let final = try game(scoreboard: "espn_b60_scoreboard_nba", league: .nba, eventID: "401909966")
        func live(clock: String, away: Int, home: Int) -> KyroSportsGame {
            KyroSportsGame(id: final.id, league: .nba, startTime: final.startTime, status: .live, statusDetail: clock,
                           home: KyroGameTeam(team: final.home.team, score: home),
                           away: KyroGameTeam(team: final.away.team, score: away))
        }
        let a = KyroSportsEventDetailStore.LoadKey(game: live(clock: "1:25 - 4th", away: 96, home: 112), tab: "stats")
        let b = KyroSportsEventDetailStore.LoadKey(game: live(clock: "1:17 - 4th", away: 97, home: 112), tab: "stats")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, KyroSportsEventDetailStore.LoadKey(game: final, tab: "stats"))
        XCTAssertNotEqual(a, KyroSportsEventDetailStore.LoadKey(game: live(clock: "1:25 - 4th", away: 96, home: 112), tab: "news"))
    }

    func testLiveEventRefreshesOnAnIntervalAndFinalEventLoadsOnce() async throws {
        let final = try game(scoreboard: "espn_b60_scoreboard_nba", league: .nba, eventID: "401909966")
        let files = [
            "/apis/site/v2/sports/basketball/nba/summary?event=401909966": "espn_b60_summary_nba_401909966",
            "/apis/site/v2/sports/basketball/nba/news?limit=20&team=11": "espn_b60_news_nba_11",
            "/apis/site/v2/sports/basketball/nba/news?limit=20&team=27": "espn_b60_news_nba_27",
        ]
        let finalTransport = FixtureTransport(files: files)
        let finalStore = KyroSportsEventDetailStore(client: ESPNEventDetailClient(transport: finalTransport))
        await finalStore.keepCurrent(for: final) { _ in XCTFail("A final event must not schedule a refresh") }
        XCTAssertEqual(finalTransport.requested.filter { $0.contains("/summary") }.count, 1)

        let live = KyroSportsGame(id: final.id, league: .nba, startTime: final.startTime, status: .live,
                                  home: final.home, away: final.away)
        let liveTransport = FixtureTransport(files: files)
        // Fresh responses for the test's clock, so each load reaches the network.
        let clock = TestClock()
        let liveStore = KyroSportsEventDetailStore(
            client: ESPNEventDetailClient(transport: liveTransport, cache: ESPNEventDetailResponseCache(now: { clock.now })),
            now: { clock.now })
        let sleeps = SleepCounter(limit: 2)
        await liveStore.keepCurrent(for: live) { _ in
            clock.advance(60)
            try sleeps.tick()
        }
        XCTAssertEqual(liveTransport.requested.filter { $0.contains("/summary") }.count, 3)
        XCTAssertEqual(liveStore.phase, .loaded)
    }

    /// A refresh that fails after the event loaded keeps the loaded answer on screen.
    func testFailedRefreshDoesNotReplaceLoadedDetails() {
        XCTAssertEqual(KyroSportsEventDetailStore.displayPhase(phase: .failed(.unavailable), hasDetailsForEvent: true), .loaded)
        XCTAssertEqual(KyroSportsEventDetailStore.displayPhase(phase: .loading, hasDetailsForEvent: true), .loaded)
        XCTAssertEqual(KyroSportsEventDetailStore.displayPhase(phase: .failed(.unavailable), hasDetailsForEvent: false),
                       .failed(.unavailable))
        XCTAssertEqual(KyroSportsEventDetailStore.displayPhase(phase: .loading, hasDetailsForEvent: false), .loading)
    }

    // MARK: Pinned event

    /// Build 59: the video stayed on Wizards at Pacers while the Feed showed WTA, and the header
    /// froze at 96–112, 1:25 4th while the broadcast showed 97–112, 1:17.
    func testPinnedEventKeepsItsOwnRefreshWhenTheFeedShowsAnotherSport() throws {
        let snapshot = try game(scoreboard: "espn_b60_scoreboard_nba", league: .nba, eventID: "401909966")
        let pinned = KyroSportsGame(id: snapshot.id, league: .nba, startTime: snapshot.startTime, status: .live,
                                    statusDetail: "1:25 - 4th", home: KyroGameTeam(team: snapshot.home.team, score: 112),
                                    away: KyroGameTeam(team: snapshot.away.team, score: 96), venue: "Gainbridge Fieldhouse")
        let refreshed = KyroSportsGame(id: snapshot.id, league: .nba, startTime: snapshot.startTime, status: .live,
                                       statusDetail: "1:17 - 4th", home: KyroGameTeam(team: snapshot.home.team, score: 112),
                                       away: KyroGameTeam(team: snapshot.away.team, score: 97))
        let tennis = try tennisGame(matchID: "187385")

        let shown = KyroSportsPinnedEvent.resolve(pinned: pinned, scheduleGames: [tennis], refreshed: refreshed)

        XCTAssertEqual(shown.id, pinned.id, "The pinned event never switches to the feed's sport")
        XCTAssertEqual(shown.statusLine, "1:17 - 4th")
        XCTAssertEqual(shown.away.score, 97)
        XCTAssertEqual(shown.venue, "Gainbridge Fieldhouse", "Metadata the refresh lacks is kept")
        XCTAssertEqual(KyroSportsPinnedEvent.resolve(pinned: pinned, scheduleGames: [tennis], refreshed: tennis).statusLine,
                       "1:25 - 4th", "Another event's refresh is ignored")
        XCTAssertEqual(KyroSportsPinnedEvent.resolve(pinned: pinned, scheduleGames: [refreshed], refreshed: nil), refreshed)
    }

    func testPinnedRefresherPollsOnlyWhileTheFeedDoesNotCoverTheEvent() async throws {
        let snapshot = try game(scoreboard: "espn_b60_scoreboard_nba", league: .nba, eventID: "401909966")
        let live = KyroSportsGame(id: snapshot.id, league: .nba, startTime: snapshot.startTime, status: .live,
                                  home: snapshot.home, away: snapshot.away)
        let covered = KyroSportsPinnedEventRefresher(fetch: { _ in XCTFail("Covered events are not fetched"); return nil })
        await covered.keepCurrent(live, coveredBySchedule: true) { _ in }
        XCTAssertEqual(covered.fetchCount, 0)

        let responses = ResponseQueue([live, snapshot])
        let refresher = KyroSportsPinnedEventRefresher(fetch: { _ in responses.next() })
        await refresher.keepCurrent(live, coveredBySchedule: false) { _ in }
        XCTAssertEqual(refresher.fetchCount, 2, "Stops once the event is final")
        XCTAssertEqual(refresher.latest?.status, .final)
    }

    // MARK: Layout

    /// Build 59 screenshot: NBA Stats rows drawn under the KYRO header and the status bar.
    func testOnlyTheFeedLeavesTheTopInsetTransparent() {
        XCTAssertFalse(KyroSportsWatchingLayout.needsOpaqueInset(tab: .feed, hasPinnedEvent: true))
        for tab in [KyroSportsWatchingTab.game, .stats, .news] {
            XCTAssertTrue(KyroSportsWatchingLayout.needsOpaqueInset(tab: tab, hasPinnedEvent: true))
            XCTAssertFalse(KyroSportsWatchingLayout.needsOpaqueInset(tab: tab, hasPinnedEvent: false))
        }
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_794_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

private final class SleepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func tick() throws {
        try lock.withLock {
            count += 1
            if count > limit { throw CancellationError() }
        }
    }
}

private final class ResponseQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [KyroSportsGame]
    init(_ items: [KyroSportsGame]) { self.items = items }
    func next() -> KyroSportsGame? { lock.withLock { items.isEmpty ? nil : items.removeFirst() } }
}
