import Foundation
import XCTest
@testable import Silo

final class KyroSoccerTests: XCTestCase {
    func testVerifiedRegistryContainsMajorClubAndWomensRoutes() {
        let keys = Set(KyroSoccerCompetitionRegistry.verified.map(\.key))
        XCTAssertTrue(keys.contains("eng.1"))
        XCTAssertTrue(keys.contains("usa.1"))
        XCTAssertTrue(keys.contains("uefa.champions"))
        XCTAssertTrue(keys.contains("usa.nwsl"))
        XCTAssertFalse(keys.contains("swi.1"), "Unverified/rejected routes stay out of working coverage")
    }

    func testSoccerScoreboardMappingKeepsCompetitionAndStatus() throws {
        let data = Data(#"""
        {"events":[{"id":"soc-1","date":"2026-11-08T14:00Z","season":{"year":2026,"slug":"2026-27"},"competitions":[{"id":"soc-1","altGameNote":"English Premier League","status":{"displayClock":"90'+6'","period":2,"type":{"name":"STATUS_FULL_TIME","state":"post","completed":true,"shortDetail":"FT"}},"venue":{"fullName":"American Express Stadium"},"competitors":[{"id":"331","homeAway":"home","winner":true,"score":"2","team":{"id":"331","abbreviation":"BHA","displayName":"Brighton & Hove Albion","shortDisplayName":"Brighton","location":"Brighton","logo":"https://a.espncdn.com/i/teamlogos/soccer/500/331.png"}},{"id":"337","homeAway":"away","score":"0","team":{"id":"337","abbreviation":"BRE","displayName":"Brentford","shortDisplayName":"Brentford","location":"Brentford","logo":"https://a.espncdn.com/i/teamlogos/soccer/500/337.png"}}]}]}
        """#.utf8)
        let response = try JSONDecoder().decode(ESPNScoreboardResponse.self, from: data)
        let game = try XCTUnwrap(ESPNMapping.game(from: response.events[0], league: .soccer,
                                                  competitionKey: "eng.1", competitionName: "English Premier League"))
        XCTAssertEqual(game.competitionKey, "eng.1")
        XCTAssertEqual(game.note, "English Premier League")
        XCTAssertEqual(game.status, .final)
        XCTAssertEqual(game.home.score, 2)
        XCTAssertEqual(game.away.score, 0)
        XCTAssertEqual(game.venue, "American Express Stadium")
    }

    func testSoccerEventDetailsMapTeamStatsTimelineAndRosterStats() throws {
        let json = #"""
        {"header":{"id":"soc-1","competitions":[{"id":"soc-1","competitors":[{"id":"1","homeAway":"home","team":{"id":"1","abbreviation":"BHA"}},{"id":"2","homeAway":"away","team":{"id":"2","abbreviation":"BRE"}}]}]},"boxscore":{"teams":[{"team":{"id":"1","abbreviation":"BHA","displayName":"Brighton"},"homeAway":"home","statistics":[{"label":"Possession","displayValue":"75.3"}]}]},"keyEvents":[{"id":"g1","type":{"text":"Goal"},"clock":{"displayValue":"15'"},"team":{"id":"1"},"athletesInvolved":[{"displayName":"Diego Gómez"}]}],"rosters":[{"team":{"id":"1","abbreviation":"BHA","displayName":"Brighton"},"roster":[{"starter":true,"athlete":{"id":"7","displayName":"Diego Gómez","shortName":"D. Gómez"},"position":{"abbreviation":"M"},"stats":[{"name":"totalGoals","displayName":"Goals","displayValue":"1"}]}]}]}
        """#
        let summary = try JSONDecoder().decode(ESPNEventSummaryResponse.self, from: Data(json.utf8))
        let away = KyroSportsTeam(id: "espn.soccer.2", league: .soccer, abbreviation: "BRE", nickname: "Brentford")
        let home = KyroSportsTeam(id: "espn.soccer.1", league: .soccer, abbreviation: "BHA", nickname: "Brighton")
        let game = KyroSportsGame(id: KyroGameID(provider: "espn", league: .soccer, rawID: "soc-1"), league: .soccer,
                                  startTime: nil, status: .final, home: KyroGameTeam(team: home, score: 2), away: KyroGameTeam(team: away, score: 0))
        let details = try ESPNEventDetailMapping.details(summary: summary, additionalNews: [], eventID: "soc-1", game: game)
        XCTAssertEqual(details.teamStatistics.first?.statistics.first?.value, "75.3")
        XCTAssertEqual(details.matchEvents.first?.kind, "Goal")
        XCTAssertEqual(details.matchEvents.first?.playerNames, ["Diego Gómez"])
        XCTAssertEqual(details.playerBoxScores.first?.groups.first?.athletes.first?.values, ["1"])
    }
}
