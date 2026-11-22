import Foundation
import XCTest
@testable import Silo

/// Build 63: TheSportsDB supplement. Fixtures are trimmed copies of real responses captured on
/// 2026-11-08/12 (eventsday.php?d=2026-11-08&l=4328 and lookupeventstats.php?id=2494090).
@MainActor
final class TheSportsDBSupplementTests: XCTestCase {
    static let dayJSON = #"""
    {"events":[
     {"idEvent":"2494090","idLeague":"4328","strHomeTeam":"Manchester United","strAwayTeam":"Aston Villa","strTimestamp":"2026-11-08T16:30:00","strStatus":"FT","strPostponed":"no","intHomeScore":"4","intAwayScore":"4"},
     {"idEvent":"2494094","idLeague":"4328","strHomeTeam":"Brighton and Hove Albion","strAwayTeam":"Brentford","strTimestamp":"2026-11-08T14:00:00","strStatus":"FT","strPostponed":"no","intHomeScore":"2","intAwayScore":"0"}
    ]}
    """#

    // Real five-row response (the free tier's cap): note Free Kicks is the only row ESPN lacks here.
    static let statsJSON = #"""
    {"eventstats":[
     {"idEvent":"2494090","strStat":"Passes accurate","intHome":"438","intAway":"347"},
     {"idEvent":"2494090","strStat":"Shots insidebox","intHome":"14","intAway":"10"},
     {"idEvent":"2494090","strStat":"Shots outsidebox","intHome":"12","intAway":"2"},
     {"idEvent":"2494090","strStat":"Blocked Shots","intHome":"7","intAway":"2"},
     {"idEvent":"2494090","strStat":"Free Kicks","intHome":"9","intAway":"18"}
    ]}
    """#

    private static let espnSummary = #"""
    {"header":{"id":"E1","competitions":[{"id":"E1","competitors":[
      {"id":"360","homeAway":"home","team":{"id":"360","abbreviation":"MAN","displayName":"Manchester United"}},
      {"id":"362","homeAway":"away","team":{"id":"362","abbreviation":"AVL","displayName":"Aston Villa"}}]}]},
     "boxscore":{"teams":[
      {"team":{"id":"362","abbreviation":"AVL","displayName":"Aston Villa"},"homeAway":"away","statistics":[{"label":"Possession","displayValue":"40"},{"label":"Blocked Shots","displayValue":"2"}]},
      {"team":{"id":"360","abbreviation":"MAN","displayName":"Manchester United"},"homeAway":"home","statistics":[{"label":"Possession","displayValue":"60"},{"label":"Blocked Shots","displayValue":"7"}]}]},
     "keyEvents":[{"id":"g1","type":{"text":"Goal"},"clock":{"displayValue":"16'"},"team":{"id":"360"},"athletesInvolved":[{"displayName":"Bruno Fernandes"}]}]}
    """#

    /// Serves ESPN (host site.api.espn.com) and TheSportsDB by host, recording each request.
    private final class Transport: ESPNTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        var tsdbStatus = 200
        var tsdbBodyOverride: String?
        var dayJSON = TheSportsDBSupplementTests.dayJSON
        var statsJSON = TheSportsDBSupplementTests.statsJSON

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = try XCTUnwrap(request.url)
            lock.withLock { urls.append(url) }
            func reply(_ body: String, _ status: Int = 200) -> (Data, HTTPURLResponse) {
                (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                  headerFields: ["Cache-Control": "max-age=600"])!)
            }
            if url.host == "site.api.espn.com" {
                return url.path.hasSuffix("/summary") ? reply(TheSportsDBSupplementTests.espnSummary)
                                                      : reply(#"{"articles":[]}"#)
            }
            if let override = tsdbBodyOverride { return reply(override, tsdbStatus) }
            if tsdbStatus != 200 { return reply("", tsdbStatus) }
            return url.path.hasSuffix("eventsday.php") ? reply(dayJSON) : reply(statsJSON)
        }

        func tsdbRequests() -> [String] {
            lock.withLock { urls.filter { $0.host == "www.thesportsdb.com" }.map { $0.lastPathComponent + "?" + ($0.query ?? "") } }
        }
    }

    private func instantGate() -> TheSportsDBRequestGate {
        TheSportsDBRequestGate(now: { Date() }, sleep: { _ in })
    }

    private func game(
        competition: String? = "eng.1", status: KyroGameStatus = .final,
        home: String = "Manchester United", away: String = "Aston Villa",
        homeScore: Int? = 4, awayScore: Int? = 4, start: String = "2026-11-08T16:30:00Z",
        rawID: String = "E1"
    ) -> KyroSportsGame {
        let homeTeam = KyroSportsTeam(id: "espn.soccer.360", league: .soccer, abbreviation: "MAN",
                                      nickname: home, location: nil, alternateNames: [])
        let awayTeam = KyroSportsTeam(id: "espn.soccer.362", league: .soccer, abbreviation: "AVL",
                                      nickname: away, location: nil, alternateNames: [])
        return KyroSportsGame(
            id: KyroGameID(provider: "espn", league: .soccer, rawID: rawID), league: .soccer,
            startTime: ISO8601DateFormatter().date(from: start), status: status,
            home: KyroGameTeam(team: homeTeam, score: homeScore), away: KyroGameTeam(team: awayTeam, score: awayScore),
            competitionKey: competition
        )
    }

    private func events() throws -> [TheSportsDBDayResponse.Event] {
        try XCTUnwrap(JSONDecoder().decode(TheSportsDBDayResponse.self, from: Data(Self.dayJSON.utf8)).events)
    }

    // MARK: Exact matching

    func testExactMatchRequiresEveryFieldAndReturnsOnlyTheVerifiedEvent() throws {
        XCTAssertEqual(TheSportsDBEventMatcher.match(game: game(), events: try events()), .matched("2494090"))
    }

    func testRejectsSwappedHomeAwayWrongScoreWrongTimeWrongLeagueAndNonFinal() throws {
        let all = try events()
        XCTAssertEqual(TheSportsDBEventMatcher.match(game: game(home: "Aston Villa", away: "Manchester United"), events: all), .none)
        XCTAssertEqual(TheSportsDBEventMatcher.match(game: game(homeScore: 3), events: all), .none)
        XCTAssertEqual(TheSportsDBEventMatcher.match(game: game(start: "2026-11-08T17:30:00Z"), events: all), .none)
        XCTAssertEqual(TheSportsDBEventMatcher.match(game: game(competition: "esp.1"), events: all), .none)
        XCTAssertEqual(TheSportsDBEventMatcher.match(game: game(home: "Manchester City"), events: all), .none,
                       "A similar name is not a match")
        var live = all
        live[0] = .init(idEvent: "2494090", idLeague: "4328", strHomeTeam: "Manchester United", strAwayTeam: "Aston Villa",
                        strTimestamp: "2026-11-08T16:30:00", strStatus: "1H", strPostponed: "no", intHomeScore: "4", intAwayScore: "4")
        XCTAssertEqual(TheSportsDBEventMatcher.match(game: game(), events: live), .none)
    }

    func testDuplicateCandidatesAreAmbiguousAndNeverResolved() throws {
        let one = try events()[0]
        XCTAssertEqual(TheSportsDBEventMatcher.match(game: game(), events: [one, one]), .ambiguous)
    }

    func testOnlyVerifiedLeaguesAndFinishedGamesAreEligible() {
        XCTAssertTrue(TheSportsDBEventMatcher.isEligible(game()))
        XCTAssertFalse(TheSportsDBEventMatcher.isEligible(game(competition: "usa.1")), "MLS stats were not available")
        XCTAssertFalse(TheSportsDBEventMatcher.isEligible(game(competition: nil)))
        XCTAssertFalse(TheSportsDBEventMatcher.isEligible(game(status: .live)))
        XCTAssertFalse(TheSportsDBEventMatcher.isEligible(game(status: .scheduled)))
    }

    func testNameNormalizationFoldsAccentsAndClubNoiseButNotDistinctClubs() {
        XCTAssertEqual(TheSportsDBEventMatcher.normalize("Atlético Madrid"), "atletico madrid")
        XCTAssertEqual(TheSportsDBEventMatcher.normalize("AC Milan"), TheSportsDBEventMatcher.normalize("Milan"))
        XCTAssertNotEqual(TheSportsDBEventMatcher.normalize("Inter Milan"), TheSportsDBEventMatcher.normalize("AC Milan"))
    }

    // MARK: Statistic mapping

    func testMappingKeepsOnlyNumericKnownRowsAndNeverDuplicatesEspnLabels() throws {
        let stats = try JSONDecoder().decode(TheSportsDBStatsResponse.self, from: Data(Self.statsJSON.utf8)).eventstats ?? []
        let rows = TheSportsDBStatisticMapping.rows(from: stats, existingLabels: ["Possession", "Blocked Shots"])
        XCTAssertEqual(rows.map(\.label), ["Accurate passes", "Shots inside box", "Shots outside box", "Free kicks"])
        XCTAssertEqual(rows.first?.home, "438")
        XCTAssertEqual(rows.first?.away, "347")

        let odd: [TheSportsDBStatsResponse.Stat] = [
            .init(idEvent: "1", strStat: "Mystery", intHome: "1", intAway: "2"),
            .init(idEvent: "1", strStat: "Free Kicks", intHome: "n/a", intAway: "2"),
            .init(idEvent: "1", strStat: "expected_goals", intHome: "2.24", intAway: "0.75"),
        ]
        XCTAssertEqual(TheSportsDBStatisticMapping.rows(from: odd, existingLabels: []).map(\.label), ["Expected goals (xG)"])
    }

    // MARK: Client

    private func client(_ transport: Transport, gate: TheSportsDBRequestGate? = nil) -> TheSportsDBClient {
        TheSportsDBClient(transport: transport, gate: gate ?? instantGate(), cache: ESPNEventDetailResponseCache())
    }

    func testVerifiedMatchProducesAttributedRowsWithTwoRequests() async {
        let transport = Transport()
        let outcome = await client(transport).supplementalStatistics(for: game(), existingLabels: ["Possession"])
        guard case .available(let stats) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(stats.providerEventID, "2494090")
        XCTAssertEqual(stats.gameID, game().id)
        XCTAssertEqual(transport.tsdbRequests().count, 2)
    }

    func testIneligibleGamesNeverContactTheProvider() async {
        let transport = Transport()
        let c = client(transport)
        for g in [game(status: .live), game(competition: "usa.1"), game(status: .scheduled)] {
            let outcome = await c.supplementalStatistics(for: g, existingLabels: [])
            XCTAssertEqual(outcome, .notEligible)
        }
        XCTAssertTrue(transport.tsdbRequests().isEmpty)
    }

    func testUnmatchedEventStopsAfterOneRequestAndShowsNothing() async {
        let transport = Transport()
        let outcome = await client(transport).supplementalStatistics(for: game(awayScore: 0), existingLabels: [])
        XCTAssertEqual(outcome, .noVerifiedMatch)
        XCTAssertEqual(transport.tsdbRequests().count, 1)
    }

    func testStatisticsForAnotherEventAreDiscarded() async {
        let transport = Transport()
        transport.statsJSON = Self.statsJSON.replacingOccurrences(of: "2494090", with: "999")
        let outcome = await client(transport).supplementalStatistics(for: game(), existingLabels: [])
        XCTAssertEqual(outcome, .noAdditionalStatistics)
    }

    func testNullStatisticsAreNoAdditionalStatistics() async {
        let transport = Transport()
        transport.statsJSON = #"{"eventstats":null}"#
        let outcome = await client(transport).supplementalStatistics(for: game(), existingLabels: [])
        XCTAssertEqual(outcome, .noAdditionalStatistics)
    }

    func testRateLimitStartsCooldownAndLaterRequestsAreNotSent() async {
        let transport = Transport()
        transport.tsdbStatus = 429
        let gate = instantGate()
        let c = client(transport, gate: gate)
        let first = await c.supplementalStatistics(for: game(), existingLabels: [])
        XCTAssertEqual(first, .providerUnavailable)
        let second = await c.supplementalStatistics(for: game(rawID: "E2"), existingLabels: [])
        XCTAssertEqual(second, .providerUnavailable)
        XCTAssertEqual(transport.tsdbRequests().count, 1, "No request while cooling down; no retry loop")
        let cooling = await gate.isCoolingDown
        XCTAssertTrue(cooling)
    }

    func testCloudflare1015BodyCountsAsRateLimit() async {
        let transport = Transport()
        transport.tsdbBodyOverride = "error code: 1015"
        let gate = instantGate()
        let outcome = await client(transport, gate: gate).supplementalStatistics(for: game(), existingLabels: [])
        XCTAssertEqual(outcome, .providerUnavailable)
        let cooling = await gate.isCoolingDown
        XCTAssertTrue(cooling)
    }

    func testSecondCallForTheSameEventIsServedFromCache() async {
        let transport = Transport()
        let c = client(transport)
        _ = await c.supplementalStatistics(for: game(), existingLabels: [])
        _ = await c.supplementalStatistics(for: game(), existingLabels: [])
        XCTAssertEqual(transport.tsdbRequests().count, 2)
    }

    // MARK: Gate

    func testGateSpacesRequestsAndCapsTheWindow() async throws {
        let recorded = SleepRecorder()
        let gate = TheSportsDBRequestGate(now: { Date(timeIntervalSince1970: 1_000) }, sleep: { await recorded.add($0) })
        try await gate.admit()
        try await gate.admit()
        try await gate.admit()
        let waits = await recorded.values
        XCTAssertEqual(waits, [3, 6], "Spacing keeps us under 30/min")
        for _ in 0..<(TheSportsDBRequestGate.windowLimit - 3) { try await gate.admit() }
        do {
            try await gate.admit()
            XCTFail("window limit")
        } catch {
            XCTAssertEqual(error as? KyroSportsDataError, .httpStatus(429))
        }
    }

    private actor SleepRecorder {
        var values: [TimeInterval] = []
        func add(_ value: TimeInterval) { values.append(value) }
    }

    // MARK: Store

    private func store(_ transport: Transport, enabled: Bool = true) -> KyroSportsEventDetailStore {
        KyroSportsEventDetailStore(
            client: ESPNEventDetailClient(transport: transport),
            supplementProviders: [client(transport)],
            newsProvider: nil,
            flagEnabled: { _ in enabled }
        )
    }

    private func gameWithProvenance() -> KyroSportsGame { game() }

    func testFlagOffNeverRequestsTheProviderAndLeavesEspnDetails() async {
        let transport = Transport()
        let s = store(transport, enabled: false)
        let g = gameWithProvenance()
        await s.load(for: g)
        await s.loadSupplement(for: g)
        XCTAssertNil(s.supplement)
        XCTAssertTrue(transport.tsdbRequests().isEmpty)
        XCTAssertEqual(s.details?.teamStatistics.count, 2, "ESPN statistics are untouched")
        XCTAssertEqual(s.details?.matchEvents.first?.kind, "Goal")
    }

    func testStoreAddsSupplementWithoutChangingEspnDetailsAndRemembersTheOutcome() async {
        let transport = Transport()
        let s = store(transport)
        let g = gameWithProvenance()
        await s.load(for: g)
        let espnBefore = s.details
        await s.loadSupplement(for: g)
        XCTAssertEqual(s.details, espnBefore)
        XCTAssertEqual(s.supplement?.rows.map(\.label), ["Accurate passes", "Shots inside box", "Shots outside box", "Free kicks"],
                       "Blocked Shots is already shown from ESPN")
        await s.loadSupplement(for: g)
        await s.loadSupplement(for: g)
        XCTAssertEqual(transport.tsdbRequests().count, 2, "Remembered per event: no repeat requests")
    }

    func testSupplementWaitsForEspnDetailsAndNeverShowsAnotherEventsRows() async {
        let transport = Transport()
        let s = store(transport)
        let g = gameWithProvenance()
        await s.loadSupplement(for: g)
        XCTAssertNil(s.supplement)
        XCTAssertTrue(transport.tsdbRequests().isEmpty, "Nothing is requested before ESPN's details exist")
        await s.load(for: g)
        await s.loadSupplement(for: g)
        XCTAssertNotNil(s.supplement)
        let other = game(awayScore: 0, rawID: "E9")
        await s.loadSupplement(for: other)
        XCTAssertNil(s.supplement, "A different event never inherits the previous rows")
    }
}
