import Foundation
import XCTest
@testable import Silo

final class KyroSportsEventDetailTests: XCTestCase {
    private final class DetailTransport: ESPNTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        let summary: Data
        let news: Data

        init(summary: Data, news: Data = Data(#"{"articles":[]}"#.utf8)) {
            self.summary = summary
            self.news = news
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { requests.append(request) }
            let data = request.url?.path.hasSuffix("/summary") == true ? summary : news
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Cache-Control": "max-age=600", "ETag": "detail-v1"]
            )!
            return (data, response)
        }

        func requestCount() -> Int { lock.withLock { requests.count } }
        func requestedPaths() -> [String] { lock.withLock { requests.compactMap(\.url?.path) } }
    }

    private func game(id: String = "401909960") -> KyroSportsGame {
        let away = KyroSportsTeam(id: "espn.nba.15", league: .nba, abbreviation: "MIL",
                                  nickname: "Bucks", location: "Milwaukee")
        let home = KyroSportsTeam(id: "espn.nba.18", league: .nba, abbreviation: "NY",
                                  nickname: "Knicks", location: "New York")
        return KyroSportsGame(
            id: KyroGameID(provider: "espn", league: .nba, rawID: id), league: .nba,
            startTime: ISO8601DateFormatter().date(from: "2026-11-11T00:30:00Z"), status: .final,
            home: KyroGameTeam(team: home, score: 117), away: KyroGameTeam(team: away, score: 85)
        )
    }

    private var summaryData: Data {
        Data(#"""
        {
          "header":{"id":"401909960","competitions":[{"id":"401909960","competitors":[
            {"id":"18","homeAway":"home","team":{"id":"18","abbreviation":"NY","displayName":"New York Knicks"}},
            {"id":"15","homeAway":"away","team":{"id":"15","abbreviation":"MIL","displayName":"Milwaukee Bucks"}}
          ]}]},
          "boxscore":{
            "teams":[
              {"team":{"id":"15","abbreviation":"MIL","displayName":"Milwaukee Bucks"},"homeAway":"away","statistics":[{"name":"fieldGoalPct","label":"Field Goal %","displayValue":"38"}]},
              {"team":{"id":"18","abbreviation":"NY","displayName":"New York Knicks"},"homeAway":"home","statistics":[{"name":"fieldGoalPct","label":"Field Goal %","displayValue":"45"}]}
            ],
            "players":[{"team":{"id":"18","abbreviation":"NY","displayName":"New York Knicks"},"statistics":[{
              "name":"game","displayName":"Game","labels":["MIN","PTS"],"athletes":[
                {"active":true,"starter":true,"athlete":{"id":"1","displayName":"Jalen Brunson","shortName":"J. Brunson","position":{"abbreviation":"PG"}},"stats":["31","23"]}
              ]
            }]}]
          },
          "article":{"id":900,"headline":"Knicks beat Bucks 117-85","published":"2026-11-11T03:06:34Z","links":{"web":{"href":"http://www.espn.com/nba/recap?gameId=401909960"}}},
          "news":{"articles":[
            {"id":901,"headline":"Knicks prepare for the next test","published":"2026-11-11T04:00:00Z","links":{"web":{"href":"https://www.espn.com/story/901"}},"categories":[{"type":"team","team":{"id":18}}]},
            {"id":902,"headline":"Unrelated league story","links":{"web":{"href":"https://www.espn.com/story/902"}},"categories":[{"type":"team","team":{"id":9}}]}
          ]}
        }
        """#.utf8)
    }

    func testValidatedSummaryMapsTeamAndPlayerBoxScoresAndOnlyRelatedNews() throws {
        let summary = try JSONDecoder().decode(ESPNEventSummaryResponse.self, from: summaryData)
        let details = try ESPNEventDetailMapping.details(
            summary: summary, additionalNews: summary.news?.articles ?? [],
            eventID: "401909960", game: game()
        )

        XCTAssertEqual(details.providerEventID, "401909960")
        XCTAssertEqual(details.teamStatistics.map(\.abbreviation), ["MIL", "NY"])
        XCTAssertEqual(details.teamStatistics[0].statistics.first?.value, "38")
        XCTAssertEqual(details.playerBoxScores.first?.groups.first?.athletes.first?.displayName, "Jalen Brunson")
        XCTAssertEqual(details.playerBoxScores.first?.groups.first?.athletes.first?.values, ["31", "23"])
        XCTAssertEqual(details.news.map(\.id), ["900", "901"])
        XCTAssertEqual(details.news.first?.relevance, .event)
        XCTAssertEqual(details.news.first?.url.scheme, "https", "publisher HTTP links are upgraded")
    }

    func testSummaryIsRejectedWhenItNamesAnotherEventOrTeams() throws {
        let summary = try JSONDecoder().decode(ESPNEventSummaryResponse.self, from: summaryData)
        XCTAssertThrowsError(try ESPNEventDetailMapping.validatedTeamIDs(
            summary: summary, eventID: "different", game: game()
        )) { error in
            XCTAssertEqual(error as? KyroSportsEventDetailError, .eventNotMatched)
        }

        let wrongTeams = String(data: summaryData, encoding: .utf8)!.replacingOccurrences(of: "\"MIL\"", with: "\"BOS\"")
        let wrong = try JSONDecoder().decode(ESPNEventSummaryResponse.self, from: Data(wrongTeams.utf8))
        XCTAssertThrowsError(try ESPNEventDetailMapping.validatedTeamIDs(
            summary: wrong, eventID: "401909960", game: game()
        ))
    }

    func testClientCachesSummaryAndBothTeamNewsResponses() async throws {
        let transport = DetailTransport(summary: summaryData)
        let client = ESPNEventDetailClient(
            baseURL: URL(string: "https://sports.example")!, transport: transport,
            cache: ESPNEventDetailResponseCache()
        )

        let first = try await client.fetchDetails(for: game())
        let second = try await client.fetchDetails(for: game())

        XCTAssertEqual(first, second)
        XCTAssertEqual(transport.requestCount(), 3, "one summary and one cached news call per verified team")
        XCTAssertEqual(transport.requestedPaths().filter { $0.hasSuffix("/summary") }.count, 1)
        XCTAssertEqual(transport.requestedPaths().filter { $0.hasSuffix("/news") }.count, 2)
    }

    func testTennisDoesNotGuessAtAnUnsupportedSummaryEndpoint() async {
        let transport = DetailTransport(summary: summaryData)
        let client = ESPNEventDetailClient(transport: transport)
        var tennis = game()
        tennis = KyroSportsGame(
            id: KyroGameID(provider: "espn", league: .atp, rawID: "187453"), league: .atp,
            startTime: tennis.startTime, status: .live, home: tennis.home, away: tennis.away
        )

        do {
            _ = try await client.fetchDetails(for: tennis)
            XCTFail("Expected unsupported league")
        } catch {
            XCTAssertEqual(error as? KyroSportsEventDetailError, .unsupportedLeague)
            XCTAssertEqual(transport.requestCount(), 0)
        }
    }

    func testRealProviderFixturesDecodeAndStayMatchedToTheSelectedEvent() throws {
        let cases: [(String, KyroSportLeague, String?)] = [
            ("espn_detail_nfl", .nfl, nil),
            ("espn_detail_nba", .nba, nil),
            ("espn_detail_nhl", .nhl, nil),
            ("espn_detail_mlb", .mlb, nil),
            ("espn_detail_cfb", .collegeFootball, nil),
            ("espn_detail_soccer", .soccer, "eng.1")
        ]

        for (fixture, league, competitionKey) in cases {
            let data = try fixtureData(named: fixture)
            let summary = try JSONDecoder().decode(ESPNEventSummaryResponse.self, from: data)
            let eventID = try XCTUnwrap(summary.header?.id, fixture)
            let competitors = try XCTUnwrap(summary.header?.competitions?.first?.competitors, fixture)
            XCTAssertEqual(competitors.count, 2, fixture)
            let selectedGame = try game(eventID: eventID, league: league,
                                        competitionKey: competitionKey, competitors: competitors)
            let details = try ESPNEventDetailMapping.details(
                summary: summary, additionalNews: summary.news?.articles ?? [],
                eventID: eventID, game: selectedGame
            )

            let selectedIDs = Set(competitors.compactMap { $0.team?.id })
            XCTAssertEqual(details.providerEventID, eventID, fixture)
            XCTAssertFalse(details.teamStatistics.isEmpty, fixture)
            XCTAssertFalse(details.playerBoxScores.isEmpty, fixture)
            XCTAssertTrue(details.teamStatistics.allSatisfy { selectedIDs.contains($0.providerTeamID) }, fixture)
            XCTAssertTrue(details.playerBoxScores.allSatisfy { selectedIDs.contains($0.providerTeamID) }, fixture)
            XCTAssertFalse(details.news.isEmpty, fixture)
            XCTAssertTrue(details.news.allSatisfy { $0.url.scheme == "https" && $0.source == "ESPN" }, fixture)
        }
    }

    func testAnUntaggedDuplicateCannotHideALaterVerifiedTeamArticle() throws {
        let summary = try JSONDecoder().decode(ESPNEventSummaryResponse.self, from: summaryData)
        let untagged = try article(#"{"id":777,"headline":"Knicks injury update","published":"2026-11-11T04:00:00Z","links":{"web":{"href":"https://www.espn.com/story/777"}}}"#)
        let verified = try article(#"{"id":777,"headline":"Knicks injury update","published":"2026-11-11T04:00:00Z","links":{"web":{"href":"https://www.espn.com/story/777"}},"categories":[{"type":"team","team":{"id":18}}]}"#)
        let details = try ESPNEventDetailMapping.details(
            summary: summary, additionalNews: [untagged, verified],
            eventID: "401909960", game: game()
        )
        XCTAssertTrue(details.news.contains { $0.id == "777" && $0.relevance == .team })
    }

    private func fixtureData(named name: String) throws -> Data {
        let bundled = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ESPN/\(name).json")
        return try Data(contentsOf: try XCTUnwrap(bundled ?? (FileManager.default.fileExists(atPath: source.path) ? source : nil)))
    }

    private func article(_ json: String) throws -> ESPNEventSummaryResponse.Article {
        try JSONDecoder().decode(ESPNEventSummaryResponse.Article.self, from: Data(json.utf8))
    }

    private func game(
        eventID: String,
        league: KyroSportLeague,
        competitionKey: String?,
        competitors: [ESPNEventSummaryResponse.Competitor]
    ) throws -> KyroSportsGame {
        func side(_ homeAway: String) throws -> KyroGameTeam {
            let competitor = try XCTUnwrap(competitors.first { $0.homeAway == homeAway })
            let wire = try XCTUnwrap(competitor.team)
            let abbreviation = try XCTUnwrap(wire.abbreviation)
            let name = wire.shortDisplayName ?? wire.displayName ?? abbreviation
            return KyroGameTeam(team: KyroSportsTeam(
                id: "espn.\(league.rawValue).\(wire.id ?? competitor.id ?? abbreviation)",
                league: league, abbreviation: abbreviation, nickname: name
            ))
        }
        return KyroSportsGame(
            id: KyroGameID(provider: "espn", league: league, rawID: eventID),
            league: league,
            startTime: nil, status: .final,
            home: try side("home"), away: try side("away"),
            competitionKey: competitionKey
        )
    }
}
