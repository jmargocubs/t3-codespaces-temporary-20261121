import Foundation
import XCTest
@testable import Silo

/// Build 63: WTA match statistics and tennis player headlines. Fixtures are trimmed copies of real
/// responses captured 2026-11-12 (WTA Finals Indian Wells, tournament 808; ESPN event 382-2026).
@MainActor
final class TennisSupplementTests: XCTestCase {
    static let tournamentsJSON = #"""
    {"content":[
     {"title":"FAGE WTA Finals Indian Wells","year":2026,"tournamentGroup":{"id":808}},
     {"title":"DIRECTV Open Presentado por Compesar - Sopo, COL","year":2026,"tournamentGroup":{"id":1181}}]}
    """#

    // LS010: A = Kostyuk lost to B = Noskova 2-6 4-6. ScoreString is winner-first ("6-2,6-4").
    static let matchesJSON = #"""
    {"matches":[
     {"MatchID":"LS010","DrawMatchType":"S","MatchState":"F","PlayerNameFirstA":"Marta","PlayerNameLastA":"Kostyuk","PlayerNameFirstB":"Linda","PlayerNameLastB":"Noskova","PlayerNameFirstA2":"","ScoreString":"6-2,6-4","ScoreSet1A":"2","ScoreSet1B":"6","ScoreSet2A":"4","ScoreSet2B":"6","ScoreSet3A":"","ScoreSet3B":""},
     {"MatchID":"LS011","DrawMatchType":"S","MatchState":"F","PlayerNameFirstA":"Coco","PlayerNameLastA":"Gauff","PlayerNameFirstB":"Jessica","PlayerNameLastB":"Pegula","PlayerNameFirstA2":"","ScoreString":"6-4,6-7(5),6-2","ScoreSet1A":"6","ScoreSet1B":"4","ScoreSet2A":"6","ScoreSet2B":"7","ScoreSet3A":"6","ScoreSet3B":"2"}]}
    """#

    static let statsJSON = #"""
    [{"matchid":"LS010","setnum":0,"acesa":6,"acesb":2,"dblflta":6,"dblfltb":4,"ptswon1stserva":14,"ptswon1stservb":26,"ptsplayed1stserva":20,"ptsplayed1stservb":38,"ptstotwonserva":29,"ptstotwonservb":41,"totservplayeda":53,"totservplayedb":65,"breakptsconva":1,"breakptsconvb":4,"breakptsplayeda":4,"breakptsplayedb":4,"totptswona":53,"totptswonb":65},
     {"matchid":"LS010","setnum":1,"acesa":1,"acesb":1,"dblflta":3,"dblfltb":3,"breakptsconva":1,"breakptsconvb":1,"breakptsplayeda":2,"breakptsplayedb":2},
     {"matchid":"LS010","setnum":2,"acesa":5,"acesb":1,"dblflta":3,"dblfltb":1,"breakptsconva":0,"breakptsconvb":3,"breakptsplayeda":2,"breakptsplayedb":2}]
    """#

    private final class Transport: ESPNTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        var status = 200
        var statsBody = TennisSupplementTests.statsJSON
        var matchesBody = TennisSupplementTests.matchesJSON
        var feeds: [String: String] = [:]

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = try XCTUnwrap(request.url)
            lock.withLock { paths.append(url.host! + url.path) }
            func reply(_ body: String, _ code: Int = 200) -> (Data, HTTPURLResponse) {
                (Data(body.utf8), HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1",
                                                  headerFields: ["Cache-Control": "max-age=600"])!)
            }
            if status != 200 { return reply("", status) }
            if let feed = feeds[url.host!], !url.path.hasPrefix("/tennis") { return reply(feed) }
            if url.path.hasSuffix("/stats") { return reply(statsBody) }
            if url.path.hasSuffix("/matches") { return reply(matchesBody) }
            return reply(TennisSupplementTests.tournamentsJSON)
        }

        func requests() -> [String] { lock.withLock { paths } }
    }

    private func player(_ id: String, _ name: String, league: KyroSportLeague = .wta) -> KyroSportsTeam {
        let parts = name.split(separator: " ")
        return KyroSportsTeam(id: "espn.\(league.rawValue).\(id)", league: league,
                              abbreviation: String(name.prefix(3)).uppercased(), nickname: name,
                              alternateNames: ["\(parts[0].prefix(1)). \(parts[parts.count - 1])"])
    }

    /// ESPN lists Noskova first (away) and Kostyuk second (home); WTA's A/B order is the reverse.
    private func game(
        status: KyroGameStatus = .final, tournament: String? = "FAGE WTA Finals Indian Wells",
        sets: [(home: Int, away: Int)] = [(2, 6), (4, 6)], singles: Bool = true, league: KyroSportLeague = .wta,
        home: String = "Marta Kostyuk", away: String = "Linda Noskova", rawID: String = "187373"
    ) -> KyroSportsGame {
        KyroSportsGame(
            id: KyroGameID(provider: "espn", league: league, rawID: rawID), league: league,
            startTime: ISO8601DateFormatter().date(from: "2026-11-08T20:15:00Z"), status: status,
            home: KyroGameTeam(team: player("1", home, league: league), score: 0),
            away: KyroGameTeam(team: player("2", away, league: league), score: 2),
            periods: sets.enumerated().map { .init(id: "s\($0.offset)", label: "S\($0.offset + 1)", homeScore: $0.element.home, awayScore: $0.element.away) },
            tournament: tournament, round: "Group Stage", isSingles: singles
        )
    }

    private func client(_ transport: Transport) -> WTAMatchStatsClient {
        WTAMatchStatsClient(transport: transport, gate: TheSportsDBRequestGate(spacing: 0, limit: 100, now: { Date() }, sleep: { _ in }),
                            cache: ESPNEventDetailResponseCache())
    }

    // MARK: WTA matching

    func testWTAStatsMatchOnPlayersOrientedSetScoresAndTournamentWithThreeRequests() async throws {
        let transport = Transport()
        let outcome = await client(transport).supplementalStatistics(for: game(), existingLabels: [])
        guard case .available(let stats) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(stats.providerName, "WTA")
        XCTAssertEqual(stats.providerEventID, "LS010")
        XCTAssertEqual(transport.requests().count, 3)
        // WTA A (Kostyuk) is ESPN's home player; Kostyuk hit 6 aces, Noskova 2.
        let aces = try XCTUnwrap(stats.rows.first { $0.label == "Aces" })
        XCTAssertEqual(aces.home, "6")
        XCTAssertEqual(aces.away, "2")
        XCTAssertEqual(stats.rows.first { $0.label == "1st serve in" }?.home, "38%", "20 of 53")
        XCTAssertEqual(stats.rows.first { $0.label == "1st serve in" }?.away, "58%", "38 of 65")
        XCTAssertEqual(stats.rows.first { $0.label == "1st serve points won" }?.home, "70%", "14 of 20")
        XCTAssertEqual(stats.rows.first { $0.label == "2nd serve points won" }?.home, "45%", "(29-14) of (53-20)")
        XCTAssertEqual(stats.rows.first { $0.label == "Break points converted" }?.away, "4/4")
        XCTAssertEqual(stats.sections.map(\.title), ["Set 1", "Set 2"])
        XCTAssertEqual(stats.sections[1].rows.first?.home, "5")
    }

    func testWinnerFirstScoreStringIsNeverUsedForOrientation() {
        // If ESPN's sets were compared against ScoreString (winner-first), 6-2 6-4 would wrongly
        // verify a game where Kostyuk (home) won 6-2 6-4.
        let wrong = game(sets: [(6, 2), (6, 4)])
        let matches = try? JSONDecoder().decode(WTAMatchesResponse.self, from: Data(Self.matchesJSON.utf8)).matches
        XCTAssertEqual(WTAMatchMatcher.match(game: wrong, matches: matches ?? []), .none)
    }

    func testRejectsWrongPlayersWrongScoresDoublesAndNonFinal() async {
        let transport = Transport()
        let c = client(transport)
        let wrongScore = await c.supplementalStatistics(for: game(sets: [(2, 6), (5, 7)]), existingLabels: [])
        XCTAssertEqual(wrongScore, .noVerifiedMatch)
        let wrongPlayer = await c.supplementalStatistics(for: game(home: "Marta Kostyuk", away: "Linda Fruhvirtova"), existingLabels: [])
        XCTAssertEqual(wrongPlayer, .noVerifiedMatch)
        let unknownTournament = await c.supplementalStatistics(for: game(tournament: "Some Other Open"), existingLabels: [])
        XCTAssertEqual(unknownTournament, .noVerifiedMatch)
        for ineligible in [game(status: .live), game(singles: false), game(league: .atp)] {
            let outcome = await c.supplementalStatistics(for: ineligible, existingLabels: [])
            XCTAssertEqual(outcome, .notEligible)
        }
    }

    func testATPNeverContactsTheWTAService() async {
        let transport = Transport()
        let before = transport.requests().count
        _ = await client(transport).supplementalStatistics(for: game(league: .atp), existingLabels: [])
        XCTAssertEqual(transport.requests().count, before)
    }

    func testTournamentNamesMatchAfterDroppingYearAndCitySuffixAndNeverAmbiguously() {
        XCTAssertEqual(WTAMatchMatcher.tournamentKey("DIRECTV Open Presentado por Compesar - Sopo, COL"),
                       WTAMatchMatcher.tournamentKey("DIRECTV Open Presentado por Compesar"))
        XCTAssertEqual(WTAMatchMatcher.tournamentKey("2026 Bybit Stockholm Open"), "bybit stockholm open")
        let dup = WTATournamentsResponse.Tournament(title: "X Open - A", year: 2026, tournamentGroup: .init(id: 1))
        let dup2 = WTATournamentsResponse.Tournament(title: "X Open - B", year: 2026, tournamentGroup: .init(id: 2))
        XCTAssertNil(WTAMatchMatcher.tournament(for: game(tournament: "X Open"), in: [dup, dup2]))
    }

    func testRateLimitAndMissingStatisticsGiveUnavailableStates() async {
        let limited = Transport()
        limited.status = 429
        let outcome = await client(limited).supplementalStatistics(for: game(), existingLabels: [])
        XCTAssertEqual(outcome, .providerUnavailable)
        XCTAssertEqual(limited.requests().count, 1, "No retries")

        let empty = Transport()
        empty.statsBody = "[]"
        let none = await client(empty).supplementalStatistics(for: game(), existingLabels: [])
        XCTAssertEqual(none, .noAdditionalStatistics)
    }

    func testPercentHelpersRefuseImpossibleOrEmptyInputs() {
        XCTAssertNil(WTAStatisticMapping.percent(5, of: 0))
        XCTAssertNil(WTAStatisticMapping.percent(6, of: 5))
        XCTAssertNil(WTAStatisticMapping.percent(nil, of: 5))
        XCTAssertEqual(WTAStatisticMapping.ratio(3, 7), "3/7")
        XCTAssertNil(WTAStatisticMapping.ratio(8, 7))
    }

    // MARK: News

    // Trimmed real Guardian and WTA items (2026-11-12).
    static let guardianRSS = #"""
    <?xml version="1.0" encoding="utf-8"?><rss version="2.0"><channel><title>x</title>
    <item><title>Svitolina stays in WTA Finals hunt after remarkable fightback sees off Muchova</title>
     <link>https://www.theguardian.com/sport/2026/nov/11/elina-svitolina-karolina-muchova-wta-finals-tennis</link>
     <description>&lt;ul&gt;&lt;li&gt;&lt;p&gt;Ukrainian wins 3-6, 6-2, 6-2&lt;/p&gt;&lt;/li&gt;&lt;/ul&gt;</description>
     <pubDate>Thu, 12 Nov 2026 00:23:53 GMT</pubDate></item>
    <item><title>Unrelated Davis Cup preview</title><link>http://insecure.example/a</link><pubDate>Thu, 12 Nov 2026 00:23:53 GMT</pubDate></item>
    </channel></rss>
    """#

    static let wtaNewsJSON = #"""
    {"content":[
     {"id":4608276,"title":"FAGE WTA Finals Day 6 preview: Sabalenka, Svitolina play for a semifinals berth","description":"Aryna Sabalenka and Elina Svitolina will play.","date":"2026-11-12T14:26:00Z","titleUrlSegment":"fage-wta-finals-day-6-preview"},
     {"id":1,"title":"Noskova beats Kostyuk in straight sets","description":"","date":"2026-11-08T22:00:00Z","titleUrlSegment":"noskova-beats-kostyuk"},
     {"id":2,"title":"Noskova beats Kostyuk in straight sets","description":"","date":"2026-11-08T22:00:00Z","titleUrlSegment":"noskova-beats-kostyuk"},
     {"id":3,"title":"Old story about Noskova","description":"","date":"2026-01-01T22:00:00Z","titleUrlSegment":"old"}]}
    """#

    private let now = ISO8601DateFormatter().date(from: "2026-11-12T18:00:00Z")!

    func testRSSParsingKeepsHTTPSLinksStripsHTMLAndReadsDates() {
        let entries = TennisFeedParsing.rssEntries(from: Data(Self.guardianRSS.utf8), source: "The Guardian")
        XCTAssertEqual(entries.count, 1, "The http:// link is dropped")
        XCTAssertEqual(entries[0].summary, "Ukrainian wins 3-6, 6-2, 6-2")
        XCTAssertNotNil(entries[0].publishedAt)
        XCTAssertEqual(entries[0].url.scheme, "https")
    }

    func testWTAEntriesBuildTheArticleURLFromIDAndSegment() {
        let entries = TennisFeedParsing.wtaEntries(from: Data(Self.wtaNewsJSON.utf8))
        XCTAssertEqual(entries[0].url.absoluteString, "https://www.wtatennis.com/news/4608276/fage-wta-finals-day-6-preview")
        XCTAssertEqual(entries[0].source, "WTA")
    }

    func testNewsKeepsOnlyNamedPlayersDedupesDropsOldAndLabelsRelevance() {
        let entries = TennisFeedParsing.wtaEntries(from: Data(Self.wtaNewsJSON.utf8))
            + TennisFeedParsing.rssEntries(from: Data(Self.guardianRSS.utf8), source: "The Guardian")
        let items = TennisNewsMatcher.items(from: entries, game: game(), now: now)
        XCTAssertEqual(items.map(\.headline), ["Noskova beats Kostyuk in straight sets"],
                       "Both players named; duplicate and 10-month-old story dropped; Sabalenka/Svitolina story excluded")
        XCTAssertEqual(items.first?.relevance, .matchup)
        let svitolina = TennisNewsMatcher.items(from: entries, game: game(home: "Elina Svitolina", away: "Karolina Muchova"), now: now)
        XCTAssertEqual(svitolina.first?.relevance, .matchup)
        XCTAssertEqual(svitolina.first?.source, "The Guardian")
    }

    func testNewsClientRequestsOnlyApplicableFeedsAndSurvivesAFailingFeed() async {
        let transport = Transport()
        transport.feeds = ["api.wtatennis.com": Self.wtaNewsJSON, "www.theguardian.com": Self.guardianRSS]
        let news = TennisNewsClient(transport: transport,
                                    gate: TheSportsDBRequestGate(spacing: 0, limit: 100, now: { Date() }, sleep: { _ in }),
                                    cache: ESPNEventDetailResponseCache(), now: { self.now })
        let result = await news.supplementalNews(for: game())
        XCTAssertEqual(result?.items.count, 1)
        XCTAssertEqual(Set(transport.requests().map { $0.components(separatedBy: "/")[0] }),
                       ["api.wtatennis.com", "feeds.bbci.co.uk", "www.theguardian.com", "www.espn.com", "www.tennis365.com", "www.tennismajors.com", "www.tennisnow.com"])

        let atpTransport = Transport()
        atpTransport.feeds = ["www.theguardian.com": Self.guardianRSS]
        let atpClient = TennisNewsClient(transport: atpTransport,
                                         gate: TheSportsDBRequestGate(spacing: 0, limit: 100, now: { Date() }, sleep: { _ in }),
                                         cache: ESPNEventDetailResponseCache(), now: { self.now })
        _ = await atpClient.supplementalNews(for: game(league: .atp))
        XCTAssertFalse(atpTransport.requests().contains { $0.hasPrefix("api.wtatennis.com") }, "WTA's site is not used for ATP matches")
    }

    func testDoublesAndNonTennisAreNotEligibleForNews() {
        let news = TennisNewsClient()
        XCTAssertFalse(news.isEligible(game(singles: false)))
    }

    // MARK: Store

    func testStoreShowsTennisStatsAndNewsPerEventAndHonoursFlags() async {
        let transport = Transport()
        transport.feeds = ["api.wtatennis.com": Self.wtaNewsJSON, "www.theguardian.com": Self.guardianRSS]
        let gate = { TheSportsDBRequestGate(spacing: 0, limit: 100, now: { Date() }, sleep: { _ in }) }
        let store = KyroSportsEventDetailStore(
            client: ESPNEventDetailClient(transport: transport),
            supplementProviders: [WTAMatchStatsClient(transport: transport, gate: gate(), cache: ESPNEventDetailResponseCache())],
            newsProvider: TennisNewsClient(transport: transport, gate: gate(), cache: ESPNEventDetailResponseCache(), now: { self.now }),
            flagEnabled: { $0 != KyroSportsSupplementFlag.tennisNewsKey }
        )
        let g = game()
        await store.loadSupplement(for: g)
        XCTAssertEqual(store.supplement?.providerEventID, "LS010")
        let afterFirst = transport.requests().count
        await store.loadSupplement(for: g)
        XCTAssertEqual(transport.requests().count, afterFirst, "Remembered per event")
        await store.loadSupplementalNews(for: g)
        XCTAssertNil(store.supplementalNews, "News flag off: no news requests")
        XCTAssertFalse(transport.requests().contains { $0.hasPrefix("feeds.bbci.co.uk") })
        await store.loadSupplement(for: game(sets: [(1, 6), (1, 6)], rawID: "999"))
        XCTAssertNil(store.supplement, "Another event never inherits the previous statistics")
    }
}
