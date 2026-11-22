import Foundation
import XCTest
@testable import Silo

/// Build 64: ATP match statistics (TennisMyLife data files), tournament news tier, and theScore
/// player context. CSV rows are copied from the real files fetched 2026-11-12; theScore JSON is a
/// trimmed copy of real responses (events list, Rolex Paris Masters match 171499).
@MainActor
final class TennisBuild64Tests: XCTestCase {
    static let header = "tourney_id,tourney_name,surface,draw_size,tourney_level,indoor,tourney_date,match_num,winner_id,winner_seed,winner_entry,winner_name,winner_hand,winner_ht,winner_ioc,winner_age,winner_rank,winner_rank_points,loser_id,loser_seed,loser_entry,loser_name,loser_hand,loser_ht,loser_ioc,loser_age,loser_rank,loser_rank_points,score,best_of,round,minutes,w_ace,w_df,w_svpt,w_1stIn,w_1stWon,w_2ndWon,w_SvGms,w_bpSaved,w_bpFaced,l_ace,l_df,l_svpt,l_1stIn,l_1stWon,l_2ndWon,l_SvGms,l_bpSaved,l_bpFaced"
    static let parisFinal = "2026-352,Paris Masters,Hard,56,M,I,20261108,55,A0E2,2,,Carlos Alcaraz,R,183,ESP,23.513,3,6100,S0S1,3,,Ben Shelton,L,193,USA,24.082,4,4530,7-6(5) 7-5,3,F,118,6,2,78,56,40,13,12,6,7,12,1,80,52,33,15,12,3,5"
    static let stockholm = "2026-429,Stockholm,Hard,28,250,,20261108,25,C0C8,,,Juan Manuel Cerundolo,L,183,ARG,24.980,54,1000,Y218,,WC,Elias Ymer,R,185,SWE,30.579,245,226,6-1 7-6(4),3,R32,97,2,2,59,33,21,20,9,1,1,8,1,66,42,29,9,10,2,5"
    static let walkover = "2026-429,Stockholm,Hard,28,250,,20261108,26,T0A1,,,Thiago Agustin Tirante,R,185,ARG,25.580,53,1023,Z999,,,Nicolas Etcheverry,R,183,ARG,26.0,60,900,W/O,3,R16,,,,,,,,,,,,,,,,,,"
    static let ongoing = ([header, stockholm, walkover]).joined(separator: "\n") + "\n"
    static let season = ([header, parisFinal, stockholm]).joined(separator: "\n") + "\n"

    private final class Transport: ESPNTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [String] = []
        var bodies: [String: String] = [:]
        var status = 200
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = try XCTUnwrap(request.url)
            lock.withLock { urls.append(url.host! + url.path) }
            let name = url.lastPathComponent
            let body = status == 200 ? (bodies[name] ?? bodies[url.host! + url.path] ?? "") : ""
            let code = status == 200 && bodies[name] == nil && bodies[url.host! + url.path] == nil ? 404 : status
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1",
                                                     headerFields: ["Cache-Control": "max-age=600"])!)
        }
        func requests() -> [String] { lock.withLock { urls } }
    }

    private func team(_ name: String, league: KyroSportLeague = .atp) -> KyroSportsTeam {
        let parts = name.split(separator: " ")
        return KyroSportsTeam(id: "espn.\(league.rawValue).\(name)", league: league, abbreviation: String(name.prefix(3)).uppercased(),
                              nickname: name, alternateNames: ["\(parts[0].prefix(1)). \(parts[parts.count - 1])"])
    }

    private func game(
        home: String = "Carlos Alcaraz", away: String = "Ben Shelton", sets: [(home: Int, away: Int)] = [(7, 6), (7, 5)],
        tournament: String? = "Rolex Paris Masters", round: String? = "Final", status: KyroGameStatus = .final,
        league: KyroSportLeague = .atp, start: String = "2026-11-08T14:00:00Z", rawID: String = "1", singles: Bool = true
    ) -> KyroSportsGame {
        KyroSportsGame(
            id: KyroGameID(provider: "espn", league: league, rawID: rawID), league: league,
            startTime: ISO8601DateFormatter().date(from: start), status: status,
            home: KyroGameTeam(team: team(home, league: league), score: 2), away: KyroGameTeam(team: team(away, league: league), score: 0),
            periods: sets.enumerated().map { .init(id: "s\($0.offset)", label: "S\($0.offset + 1)", homeScore: $0.element.home, awayScore: $0.element.away) },
            tournament: tournament, round: round, isSingles: singles)
    }

    private func client(_ transport: Transport) -> TMLMatchStatsClient {
        TMLMatchStatsClient(transport: transport, gate: TheSportsDBRequestGate(spacing: 0, limit: 100, now: { Date() }, sleep: { _ in }),
                            cache: ESPNEventDetailResponseCache())
    }

    private func rows(_ csv: String, around g: KyroSportsGame) -> [TMLMatchRow] {
        TMLCSV.rows(from: Data(csv.utf8), window: TMLMatchMatcher.window(for: g.startTime!))
    }

    // MARK: ATP statistics

    func testATPStatisticsMatchOnPlayersOrientedSetsRoundAndMapToTheCorrectPlayers() throws {
        let g = game()
        guard case .matched(let row, let winnerIsHome) = TMLMatchMatcher.match(game: g, rows: rows(Self.season, around: g)) else { return XCTFail("no match") }
        XCTAssertTrue(winnerIsHome)
        let stats = Dictionary(uniqueKeysWithValues: TMLStatisticMapping.rows(row, winnerIsHome: winnerIsHome).map { ($0.label, $0) })
        // Alcaraz (home) recorded 6 aces, Shelton (away) 12.
        XCTAssertEqual(stats["Aces"]?.home, "6"); XCTAssertEqual(stats["Aces"]?.away, "12")
        XCTAssertEqual(stats["1st serve in"]?.home, "72%")       // 56/78
        XCTAssertEqual(stats["1st serve points won"]?.home, "71%") // 40/56
        XCTAssertEqual(stats["2nd serve points won"]?.home, "59%") // 13/(78-56)
        XCTAssertEqual(stats["Service points won"]?.home, "68%")   // 53/78
        XCTAssertEqual(stats["Return points won"]?.home, "40%")    // 80-48=32 of 80
        XCTAssertEqual(stats["Break points converted"]?.home, "2/5") // Shelton faced 5, saved 3
        XCTAssertEqual(stats["Break points saved"]?.home, "6/7")
        XCTAssertEqual(stats["Total points won"]?.home, "85"); XCTAssertEqual(stats["Total points won"]?.away, "73")
        XCTAssertEqual(TMLStatisticMapping.duration(minutes: row.minutes), "Match time 1h 58m")
    }

    func testReversedPlayerOrderStillAssignsStatisticsToTheRightPlayer() {
        let g = game(home: "Ben Shelton", away: "Carlos Alcaraz", sets: [(6, 7), (5, 7)])
        guard case .matched(let row, let winnerIsHome) = TMLMatchMatcher.match(game: g, rows: rows(Self.season, around: g)) else { return XCTFail("no match") }
        XCTAssertFalse(winnerIsHome)
        let aces = TMLStatisticMapping.rows(row, winnerIsHome: winnerIsHome).first { $0.label == "Aces" }
        XCTAssertEqual(aces?.home, "12", "Shelton is home and recorded 12 aces")
        XCTAssertEqual(aces?.away, "6")
    }

    func testShortEspnNamesMatchButWrongPlayersScoresRoundsAndSinglesFlagsDoNot() {
        let all = rows(Self.season, around: game())
        XCTAssertTrue(TMLMatchMatcher.samePlayer("Juan Manuel Cerundolo", team("J. Cerundolo")))
        XCTAssertFalse(TMLMatchMatcher.samePlayer("Juan Manuel Cerundolo", team("F. Cerundolo")), "same surname, other initial")
        XCTAssertFalse(TMLMatchMatcher.samePlayer("Ben Shelton", team("Ben Sheldon")))
        XCTAssertTrue(TMLMatchMatcher.samePlayer("Zhizhen Zhang", team("Zhang Zhizhen")), "family name first")
        XCTAssertFalse(TMLMatchMatcher.samePlayer("Zhizhen Zhang", team("Zhang Wei")))
        XCTAssertTrue(TMLMatchMatcher.samePlayer("Xin Yu Wang", team("Wang Xinyu")), "given name split differently")
        XCTAssertTrue(WTAMatchMatcher.samePlayer(("Xin Yu", "Wang"), team("Wang Xinyu", league: .wta)))
        XCTAssertFalse(TMLMatchMatcher.samePlayer("Xin Yu Wang", team("Wang Xiyu")), "a different player with a near-identical name")
        // wrong score, wrong round (ESPN says Semifinal), wrong player, still-only-one set
        XCTAssertEqual(TMLMatchMatcher.match(game: game(sets: [(7, 6), (6, 7)]), rows: all), .none)
        XCTAssertEqual(TMLMatchMatcher.match(game: game(round: "Semifinal"), rows: all), .none)
        XCTAssertEqual(TMLMatchMatcher.match(game: game(away: "Taylor Fritz"), rows: all), .none)
        XCTAssertEqual(TMLMatchMatcher.match(game: game(sets: [(7, 6)]), rows: all), .none)
        // ESPN round wording the file cannot compare ("Round 1") does not reject a verified pair
        if case .matched = TMLMatchMatcher.match(game: game(round: "Round 1"), rows: all) {} else { XCTFail("unknown round wording must not reject") }
    }

    func testRetirementsMayCarryOneExtraInterruptedSetButCompletedMatchesMayNot() {
        let retired = Self.parisFinal.replacingOccurrences(of: "7-6(5) 7-5", with: "3-6 6-4 6-4 RET")
        // Alcaraz (home) won 3-6 6-4 6-4 and the fourth set was interrupted on ESPN's side only.
        let espn = game(sets: [(3, 6), (6, 4), (6, 4), (0, 1)].map { (home: $0.0, away: $0.1) }, round: nil)
        let rowsRet = rows(([Self.header, retired]).joined(separator: "\n"), around: espn)
        if case .matched = TMLMatchMatcher.match(game: espn, rows: rowsRet) {} else { XCTFail("retirement with a trailing partial set") }
        let completed = rows(Self.season, around: game())
        XCTAssertEqual(TMLMatchMatcher.match(game: game(sets: [(7, 6), (7, 5), (0, 1)]), rows: completed), .none)
    }

    func testDuplicateCandidatesAreAmbiguousUnlessTheTournamentBreaksTheTie() {
        let other = Self.parisFinal.replacingOccurrences(of: "Paris Masters", with: "Bercy Exhibition")
        let g = game(tournament: "Rolex Paris Masters")
        let both = rows(([Self.header, Self.parisFinal, other]).joined(separator: "\n"), around: g)
        if case .matched(let row, _) = TMLMatchMatcher.match(game: g, rows: both) { XCTAssertEqual(row.tournament, "Paris Masters") } else { XCTFail("tournament should break the tie") }
        let unrelated = game(tournament: "Something Else Entirely")
        XCTAssertEqual(TMLMatchMatcher.match(game: unrelated, rows: both), .ambiguous)
    }

    func testDateWindowExcludesOtherWeeksAndOnlyThatWeeksRowsAreParsed() {
        let far = game(start: "2026-02-01T14:00:00Z")
        XCTAssertTrue(rows(Self.season, around: far).isEmpty)
        XCTAssertEqual(rows(Self.season, around: game()).count, 2)
    }

    func testWalkoverAndMissingStatisticsNeverProduceRows() {
        let g = game(home: "Thiago Agustin Tirante", away: "Nicolas Etcheverry", sets: [], tournament: "Bybit Stockholm Open", round: "Round of 16")
        XCTAssertEqual(TMLMatchMatcher.match(game: g, rows: rows(Self.ongoing, around: g)), .none, "no set scores to verify")
        let walk = rows(Self.ongoing, around: g).first { $0.score == "W/O" }!
        XCTAssertTrue(TMLStatisticMapping.rows(walk, winnerIsHome: true).isEmpty)
    }

    func testRowsDropImpossibleCounts() {
        var row = rows(Self.season, around: game()).first { $0.round == "F" }!
        row = TMLMatchRow(tournament: row.tournament, tournamentStart: row.tournamentStart, surface: row.surface, round: row.round,
                          winner: row.winner, loser: row.loser, score: row.score, minutes: 5,
                          w: .init(ace: 6, df: 2, svpt: 78, firstIn: 90, firstWon: 40, secondWon: 13, bpSaved: 9, bpFaced: 7), l: row.l)
        let labels = TMLStatisticMapping.rows(row, winnerIsHome: true).map(\.label)
        XCTAssertFalse(labels.contains("1st serve in"), "90 of 78 is impossible")
        XCTAssertFalse(labels.contains("Break points saved"), "9 saved of 7 faced is impossible")
        XCTAssertNil(TMLStatisticMapping.duration(minutes: row.minutes), "5 minutes is not a match duration")
    }

    // MARK: Client: requests, failures, caching

    func testClientUsesTheSmallOngoingFileFirstAndTheSeasonFileOnlyWhenNeeded() async {
        let transport = Transport()
        transport.bodies = ["ongoing_tourneys.csv": Self.ongoing, "2026.csv": Self.season]
        let c = client(transport)
        let stockholmGame = game(home: "Juan Manuel Cerundolo", away: "Elias Ymer", sets: [(6, 1), (7, 6)], tournament: "Bybit Stockholm Open", round: "Round of 32", start: "2026-11-09T10:00:00Z")
        let first = await c.supplementalStatistics(for: stockholmGame, existingLabels: [])
        guard case .available(let stats) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(stats.providerName, "TennisMyLife")
        XCTAssertEqual(transport.requests().count, 1, "found in the ongoing file")
        let paris = await c.supplementalStatistics(for: game(), existingLabels: [])
        guard case .available = paris else { return XCTFail("\(paris)") }
        XCTAssertEqual(transport.requests().filter { $0.hasSuffix("2026.csv") }.count, 1)
        XCTAssertEqual(transport.requests().filter { $0.hasSuffix("ongoing_tourneys.csv") }.count, 1, "ongoing file served from cache for the second event")
    }

    func testWTAGamesUseTheWTAFilesAndLiveOrScheduledAndDoublesAreNotEligible() async {
        let transport = Transport()
        let c = client(transport)
        _ = await c.supplementalStatistics(for: game(league: .wta), existingLabels: [])
        XCTAssertTrue(transport.requests().allSatisfy { $0.contains("wta") })
        XCTAssertFalse(c.isEligible(game(status: .live)), "no live statistics")
        XCTAssertFalse(c.isEligible(game(singles: false)))
        let out = await c.supplementalStatistics(for: game(status: .live), existingLabels: [])
        XCTAssertEqual(out, .notEligible)
    }

    func testBlockedOrMissingFilesAreUnavailableWithoutRetries() async {
        let blocked = Transport(); blocked.status = 403
        let out = await client(blocked).supplementalStatistics(for: game(), existingLabels: [])
        XCTAssertEqual(out, .providerUnavailable)
        XCTAssertEqual(blocked.requests().count, 2, "one attempt per file, no retries")
        let limited = Transport(); limited.status = 429
        let out429 = await client(limited).supplementalStatistics(for: game(), existingLabels: [])
        XCTAssertEqual(out429, .providerUnavailable)
        let empty = Transport(); empty.bodies = ["ongoing_tourneys.csv": Self.header + "\n", "2026.csv": Self.header + "\n"]
        let none = await client(empty).supplementalStatistics(for: game(), existingLabels: [])
        XCTAssertEqual(none, .noVerifiedMatch)
    }

    func testCSVParserCopesWithQuotesBlankStatsAndGarbage() {
        XCTAssertEqual(TMLCSV.fields("a,\"b,c\",d"), ["a", "b,c", "d"])
        XCTAssertTrue(TMLCSV.rows(from: Data("not,a,csv\n1,2,3".utf8), window: Date.distantPast...Date.distantFuture).isEmpty)
        XCTAssertTrue(TMLCSV.rows(from: Data([0xff, 0xfe, 0x00]), window: Date.distantPast...Date.distantFuture).isEmpty)
    }

    // MARK: Store: fallback chain, caching, rapid event changes

    private struct StubProvider: KyroSportsSupplementProviding {
        let flagKey: String
        let outcome: KyroSportsSupplementOutcome
        let calls: Counter
        func isEligible(_ game: KyroSportsGame) -> Bool { true }
        func supplementalStatistics(for game: KyroSportsGame, existingLabels: [String]) async -> KyroSportsSupplementOutcome {
            calls.increment(); return outcome
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func increment() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    func testStoreFallsThroughToTheNextProviderAndRemembersTheOutcome() async {
        let first = Counter(), second = Counter()
        let g = game()
        let available = KyroSportsSupplementOutcome.available(.init(gameID: g.id, providerName: "TennisMyLife", providerEventID: "x", rows: [.init(label: "Aces", home: "1", away: "2")]))
        let store = KyroSportsEventDetailStore(
            client: ESPNEventDetailClient(transport: Transport()),
            supplementProviders: [StubProvider(flagKey: "a", outcome: .noVerifiedMatch, calls: first), StubProvider(flagKey: "b", outcome: available, calls: second)],
            newsProvider: nil, playerInfoProvider: nil, flagEnabled: { _ in true })
        await store.loadSupplement(for: g)
        XCTAssertEqual(store.supplement?.providerName, "TennisMyLife")
        await store.loadSupplement(for: g)
        XCTAssertEqual(first.value, 1); XCTAssertEqual(second.value, 1, "remembered per event")

        let off = KyroSportsEventDetailStore(
            client: ESPNEventDetailClient(transport: Transport()),
            supplementProviders: [StubProvider(flagKey: "a", outcome: .noVerifiedMatch, calls: first), StubProvider(flagKey: "b", outcome: available, calls: second)],
            newsProvider: nil, playerInfoProvider: nil, flagEnabled: { $0 != "b" })
        await off.loadSupplement(for: g)
        XCTAssertNil(off.supplement, "a disabled provider is never consulted")
    }

    // MARK: News tiers

    private let now = ISO8601DateFormatter().date(from: "2026-11-12T18:00:00Z")!

    private func entry(_ title: String, summary: String = "", url: String, source: String, hoursAgo: Double = 5) -> TennisFeedEntry {
        TennisFeedEntry(title: title, summary: summary, url: URL(string: url)!, publishedAt: now.addingTimeInterval(-hoursAgo * 3600), source: source)
    }

    func testNewsIsTieredMatchupThenPlayerThenTournamentAndExcludesUnrelatedStories() {
        let g = game(home: "Casper Ruud", away: "Taylor Fritz", sets: [(6, 4), (6, 4)], tournament: "Bybit Stockholm Open", round: "Quarterfinal")
        let entries = [
            entry("Stockholm Open: Rune out of quarter-final", url: "https://a.example/1", source: "Tennis Majors"),
            entry("Casper Ruud beats Taylor Fritz to reach the semi-finals", url: "https://a.example/2", source: "BBC Sport", hoursAgo: 9),
            entry("Taylor Fritz talks about his season", url: "https://a.example/3", source: "ESPN", hoursAgo: 2),
            entry("Sabalenka wins at the WTA Finals", url: "https://a.example/4", source: "ESPN"),
            entry("ATP Finals draw revealed", url: "https://a.example/5", source: "Tennis365"),
            entry("Casper Ruud beats Taylor Fritz to reach the semi-finals", url: "https://b.example/dupe", source: "Guardian", hoursAgo: 8),
        ]
        let items = TennisNewsMatcher.items(from: entries, game: g, now: now)
        XCTAssertEqual(items.map(\.relevance), [.matchup, .team, .tournament])
        XCTAssertEqual(items.map(\.source), ["BBC Sport", "ESPN", "Tennis Majors"])
        XCTAssertEqual(items.count, 3, "duplicate headline across providers collapses; unrelated stories dropped")
    }

    func testTournamentPhrasesNeverReduceToAGenericWordAndAreCapped() {
        XCTAssertTrue(TennisNewsMatcher.tournamentPhrases("Bybit Stockholm Open").contains("stockholm open"))
        XCTAssertTrue(TennisNewsMatcher.tournamentPhrases("Rolex Paris Masters").contains("paris masters"))
        XCTAssertFalse(TennisNewsMatcher.tournamentPhrases("Open").contains("open"))
        XCTAssertTrue(TennisNewsMatcher.tournamentPhrases(nil).isEmpty)
        let g = game(home: "Casper Ruud", away: "Taylor Fritz", tournament: "Bybit Stockholm Open")
        let many = (0..<8).map { entry("Stockholm Open story \($0)", url: "https://t.example/\($0)", source: "Tennis365", hoursAgo: Double($0)) }
        let items = TennisNewsMatcher.items(from: many, game: g, now: now)
        XCTAssertEqual(items.count, TennisNewsMatcher.maxTournamentItems)
        let old = [entry("Stockholm Open history", url: "https://t.example/old", source: "Tennis365", hoursAgo: 24 * 30)]
        XCTAssertTrue(TennisNewsMatcher.items(from: old, game: g, now: now).isEmpty, "stale tournament news is dropped")
    }

    // MARK: theScore player context

    static let eventsJSON = #"""
    [{"id":10460,"name":"Rolex Paris Masters","start_date":"Sat, 31 Oct 2026 10:00:00 -0000","end_date":"Mon, 09 Nov 2026 00:00:00 -0000"},
     {"id":10488,"name":"BNP Paribas Nordic Open","start_date":"Sat, 07 Nov 2026 10:00:00 -0000","end_date":"Sun, 15 Nov 2026 00:00:00 -0000"},
     {"id":10470,"name":"Swiss Indoors Basel","start_date":"Sat, 24 Oct 2026 10:00:00 -0000","end_date":"Mon, 02 Nov 2026 00:00:00 -0000"}]
    """#
    static let eventMatchesJSON = #"""
    [{"id":171499,"is_double":false,"team_1":{"id":67218,"player1":{"first_name":"Alex","last_name":"Michelsen"}},"team_2":{"id":59902,"player1":{"first_name":"Jiri","last_name":"Lehecka"}}},
     {"id":171500,"is_double":true,"team_1":{"id":1,"player1":{"first_name":"Alex","last_name":"Michelsen"}},"team_2":{"id":2,"player1":{"first_name":"Jiri","last_name":"Lehecka"}}}]
    """#
    static let matchJSON = #"""
    {"id":171499,"is_double":false,
     "team_1":{"id":67218,"player1":{"first_name":"Alex","last_name":"Michelsen","country":"USA","plays":"Right","age":22}},
     "team_2":{"id":59902,"player1":{"first_name":"Jiri","last_name":"Lehecka","country":"Czech Republic","plays":"Right","age":24}},
     "team_1_standing":{"place":35,"points":1460},"team_2_standing":{"place":15,"points":2540},
     "past_meetings_matches":[
       {"api_uri":"/atp/matches/166552","match_date":"Sun, 26 Apr 2026 09:00:00 -0000","winner":{"id":59902},"result_text":"Lehecka d. Michelsen","event_name":"Mutua Madrid Open","round_name_abbreviation":"R32"},
       {"api_uri":"/atp/matches/171450","match_date":"Thu, 29 Oct 2026 14:00:00 -0000","winner":{"id":67218},"result_text":"Michelsen d. Lehecka","event_name":"Swiss Indoors Basel","round_name_abbreviation":"R16"},
       {"api_uri":"/atp/matches/171499","match_date":"Tue, 03 Nov 2026 15:45:00 -0000","winner":{"id":67218},"result_text":"this match","event_name":"Rolex Paris Masters","round_name_abbreviation":"R64"}],
     "team_1_last_matches":[
       {"api_uri":"/atp/matches/171450","match_date":"Thu, 29 Oct 2026 14:00:00 -0000","winner":{"id":67218},"result_text":"Michelsen d. Lehecka","event_name":"Swiss Indoors Basel","round_name_abbreviation":"R16"},
       {"api_uri":"/atp/matches/170000","match_date":"Tue, 27 Oct 2026 14:00:00 -0000","winner":{"id":999},"result_text":"Other d. Michelsen","event_name":"Swiss Indoors Basel","round_name_abbreviation":"R32"}],
     "team_2_last_matches":[]}
    """#

    private func infoTransport() -> Transport {
        let t = Transport()
        t.bodies = ["api.thescore.com/atp/events": Self.eventsJSON, "api.thescore.com/atp/events/10460/matches": Self.eventMatchesJSON,
                    "api.thescore.com/atp/events/10488/matches": "[]", "api.thescore.com/atp/matches/171499": Self.matchJSON]
        return t
    }

    private func infoClient(_ t: Transport) -> TheScoreTennisInfoClient {
        TheScoreTennisInfoClient(transport: t, gate: TheSportsDBRequestGate(spacing: 0, limit: 100, now: { Date() }, sleep: { _ in }),
                                 cache: ESPNEventDetailResponseCache())
    }

    func testPlayerInfoOrientsRankingHeadToHeadAndFormToTheEspnSides() async throws {
        let g = game(home: "Jiri Lehecka", away: "Alex Michelsen", tournament: "Rolex Paris Masters", round: "Round of 64", start: "2026-11-03T15:45:00Z")
        let t = infoTransport()
        let loaded = await infoClient(t).playerInfo(for: g)
        let info = try XCTUnwrap(loaded)
        XCTAssertEqual(info.home.name, "Jiri Lehecka"); XCTAssertEqual(info.home.rank, 15); XCTAssertEqual(info.home.points, 2540)
        XCTAssertEqual(info.away.rank, 35)
        XCTAssertEqual(info.meetings, 2, "the match itself is not counted as an earlier meeting")
        XCTAssertEqual(info.homeHeadToHeadWins, 1); XCTAssertEqual(info.awayHeadToHeadWins, 1)
        XCTAssertEqual(info.away.recent.map(\.won), [true, false])
        XCTAssertEqual(info.away.country, "USA")
        XCTAssertEqual(t.requests().count, 3)
    }

    func testPlayerInfoFindsTheEventWhenTheSponsorNameDiffersAndNeverGuessesDoubles() async throws {
        // ESPN says "Bybit Stockholm Open"; theScore says "BNP Paribas Nordic Open" (no shared word).
        let g = game(home: "Jiri Lehecka", away: "Alex Michelsen", tournament: "Bybit Stockholm Open", start: "2026-11-08T12:00:00Z")
        let t = infoTransport()
        t.bodies["api.thescore.com/atp/events/10488/matches"] = Self.eventMatchesJSON
        t.bodies["api.thescore.com/atp/events/10460/matches"] = "[]"
        let info = await infoClient(t).playerInfo(for: g)
        XCTAssertNotNil(info, "found by searching the events running that week for both players")
        let unknown = await infoClient(infoTransport()).playerInfo(for: game(home: "Jiri Lehecka", away: "Taylor Fritz", tournament: "Rolex Paris Masters", start: "2026-11-03T15:45:00Z"))
        XCTAssertNil(unknown, "unknown pairing: nothing")
        XCTAssertFalse(infoClient(t).isEligible(game(singles: false)))
    }

    func testPlayerInfoFailuresAreQuietAndNotRetried() async {
        let t = Transport(); t.status = 429
        let info = await infoClient(t).playerInfo(for: game(home: "Jiri Lehecka", away: "Alex Michelsen", start: "2026-11-03T15:45:00Z"))
        XCTAssertNil(info)
        XCTAssertEqual(t.requests().count, 1)
    }

    func testStoreLoadsPlayerInfoPerEventAndHonoursItsFlag() async {
        let g = game(home: "Jiri Lehecka", away: "Alex Michelsen", tournament: "Rolex Paris Masters", start: "2026-11-03T15:45:00Z")
        let t = infoTransport()
        let store = KyroSportsEventDetailStore(client: ESPNEventDetailClient(transport: t), supplementProviders: [], newsProvider: nil,
                                               playerInfoProvider: infoClient(t), flagEnabled: { _ in true })
        await store.loadPlayerInfo(for: g)
        XCTAssertEqual(store.playerInfo?.away.rank, 35)
        let n = t.requests().count
        await store.loadPlayerInfo(for: g)
        XCTAssertEqual(t.requests().count, n, "remembered")
        await store.loadPlayerInfo(for: game(rawID: "other"))
        XCTAssertNil(store.playerInfo, "another event never shows these players")
        let off = KyroSportsEventDetailStore(client: ESPNEventDetailClient(transport: t), supplementProviders: [], newsProvider: nil,
                                             playerInfoProvider: infoClient(t), flagEnabled: { $0 != KyroSportsSupplementFlag.tennisPlayerInfoKey })
        await off.loadPlayerInfo(for: g)
        XCTAssertNil(off.playerInfo)
    }
}
