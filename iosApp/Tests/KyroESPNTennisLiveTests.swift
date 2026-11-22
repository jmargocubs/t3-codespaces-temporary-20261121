import Foundation
import XCTest
@testable import Silo

/// Build 37 regressions from real ESPN tennis scoreboards, captured
/// 2026-11-07 (`dates=20261108`) and 2026-09-06 (US Open). The fixtures keep
/// ESPN's structure; only links, guids, calendars and statistics were removed
/// and each draw was narrowed to the matches the tests need.
///
/// Build 36 showed "Scores unavailable" for ATP and WTA because ESPN sends
/// `athlete.flag` as an object (the whole response failed to decode) and puts
/// matches in `groupings`, which the flattener never read.
final class KyroESPNTennisLiveTests: XCTestCase {
    private static let atpFixture = "espn_tennis_atp_20261108_real"
    private static let wtaFixture = "espn_tennis_wta_20261108_real"
    private static let slamFixture = "espn_tennis_usopen_20260906_real"

    private func data(_ name: String) throws -> Data {
        if let bundled = Bundle(for: Self.self).url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: bundled)
        }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ESPN/\(name).json")
        return try Data(contentsOf: source)
    }

    private func response(_ name: String) throws -> ESPNScoreboardResponse {
        try JSONDecoder().decode(ESPNScoreboardResponse.self, from: data(name))
    }

    private func games(_ name: String, _ league: KyroSportLeague) throws -> [KyroSportsGame] {
        try ESPNSportsProvider().mapValidated(response(name), league: league)
    }

    private func match(_ games: [KyroSportsGame], _ away: String, _ home: String) throws -> KyroSportsGame {
        try XCTUnwrap(games.first { $0.away.team.nickname == away && $0.home.team.nickname == home },
                      "missing \(away) v \(home)")
    }

    private func utc(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    // MARK: Build 41.1 artwork

    func testPlayersKeepESPNsFlagImageAndItsCode() throws {
        let players = try games(Self.atpFixture, .atp).flatMap { [$0.away.team, $0.home.team] }
        let flagged = players.filter { $0.flagURL != nil }
        XCTAssertFalse(flagged.isEmpty)
        for player in flagged {
            let url = try XCTUnwrap(player.flagURL)
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.deletingPathExtension().lastPathComponent.uppercased(), player.countryCode,
                           "the image and the code come from the same ESPN flag")
        }
    }

    func testFlagWithoutAnImageStaysACode() throws {
        let bare = try JSONDecoder().decode(ESPNFlag.self, from: Data(#""ESP""#.utf8))
        XCTAssertEqual(bare.code, "ESP")
        XCTAssertNil(bare.imageURL)
        let unsafe = try JSONDecoder().decode(ESPNFlag.self, from: Data(#"{"href":"javascript:alert(1)","alt":"x"}"#.utf8))
        XCTAssertNil(unsafe.imageURL)
    }

    // MARK: Decoding and flattening

    func testRealATPResponseDecodesAndFlattensSinglesFromGroupings() throws {
        let payload = try response(Self.atpFixture)
        XCTAssertEqual(payload.events.map(\.name), ["Rolex Paris Masters", "Bybit Stockholm Open"])
        XCTAssertNil(payload.events.first?.competitions, "live tennis has no event-level competitions")

        let games = try games(Self.atpFixture, .atp)
        XCTAssertFalse(games.isEmpty)
        XCTAssertTrue(games.allSatisfy { $0.isSingles && $0.league == .atp })
        XCTAssertFalse(games.contains { $0.home.team.nickname.isEmpty || $0.away.team.nickname.isEmpty })

        let final = try match(games, "Carlos Alcaraz", "Ben Shelton")
        XCTAssertEqual(final.tournament, "Rolex Paris Masters")
        XCTAssertEqual(final.round, "Final")
        XCTAssertEqual(final.status, .scheduled)
        XCTAssertEqual(final.startTime, utc("2026-11-08T14:00:00Z"))
        XCTAssertFalse(final.isStartTimeTBD)
        XCTAssertNil(final.statusDetail, "ESPN's Eastern-time text is replaced by the local clock")
        XCTAssertEqual(final.away.rank, 2)
        XCTAssertEqual(final.home.rank, 3)
        XCTAssertEqual(final.away.team.countryCode, "ESP")
        XCTAssertEqual(final.home.team.countryCode, "USA")
        XCTAssertEqual(final.venue, "Paris, France")
    }

    func testRealResultsKeepSetScoresWinnersRetirementsAndWalkovers() throws {
        let games = try games(Self.atpFixture, .atp)

        let semifinal = try match(games, "Carlos Alcaraz", "Casper Ruud")
        XCTAssertEqual(semifinal.status, .final)
        XCTAssertEqual(semifinal.round, "Semifinal")
        XCTAssertEqual(semifinal.periods.map(\.awayScore), [6, 6])
        XCTAssertEqual(semifinal.periods.map(\.homeScore), [4, 4])
        XCTAssertEqual(semifinal.periods.map(\.label), ["Set 1", "Set 2"])
        XCTAssertEqual(semifinal.winner?.team.nickname, "Carlos Alcaraz")

        let comeback = try match(games, "Ben Shelton", "Luca Van Assche")
        XCTAssertEqual(comeback.periods.map(\.awayScore), [5, 6, 6])
        XCTAssertEqual(comeback.winner?.team.nickname, "Ben Shelton", "winner flag, not a guessed score")

        let retired = try match(games, "Karen Khachanov", "Denis Shapovalov")
        XCTAssertEqual(retired.status, .final)
        XCTAssertEqual(retired.statusDetail, "Retired")
        XCTAssertNotNil(retired.winner, "ESPN names the winner of a retirement")

        let walkover = try match(games, "Carlos Alcaraz", "Matteo Berrettini")
        XCTAssertEqual(walkover.statusDetail, "Walkover")
        XCTAssertTrue(walkover.periods.isEmpty)
    }

    func testDateOnlySlotsAreDayAnchoredAndTBDPairsDropped() throws {
        let games = try games(Self.atpFixture, .atp)
        let slot = try match(games, "Zizou Bergs", "Holger Rune")
        XCTAssertTrue(slot.isStartTimeTBD)
        XCTAssertEqual(slot.statusDetail, "Time TBD")
        // ESPN: 2026-11-09T05:00Z = midnight US Eastern on Nov 9.
        XCTAssertEqual(slot.startTime, utc("2026-11-09T12:00:00Z"))

        let qualifierSlot = try match(games, "TBD", "Leo Borg")
        XCTAssertTrue(qualifierSlot.isStartTimeTBD, "one known player is a real draw slot")

        let wta = try self.games(Self.wtaFixture, .wta)
        XCTAssertFalse(wta.contains { $0.away.team.nickname == "TBD" && $0.home.team.nickname == "TBD" })
        // The Bogotá draw has 16 TBD-vs-TBD first-round slots and four real
        // Nov 8 matches: only the real ones are mapped.
        let bogota = wta.filter { $0.tournament == "DIRECTV Open Presentado por Compesar" }
        XCTAssertEqual(bogota.count, 4)
        XCTAssertTrue(bogota.allSatisfy { !$0.isStartTimeTBD })
    }

    func testRealWTADayHasFinalsAndGroupStage() throws {
        let games = try games(Self.wtaFixture, .wta)
        XCTAssertTrue(games.allSatisfy { $0.league == .wta && $0.isSingles })
        let hongKong = try match(games, "Alexandra Eala", "Claire Liu")
        XCTAssertEqual(hongKong.round, "Final")
        XCTAssertEqual(hongKong.tournament, "Prudential Hong Kong Tennis Open")
        XCTAssertEqual(hongKong.startTime, utc("2026-11-08T08:00:00Z"))
        let finals = try match(games, "Jessica Pegula", "Coco Gauff")
        XCTAssertEqual(finals.tournament, "FAGE WTA Finals Indian Wells")
        XCTAssertEqual(finals.round, "Group Stage")
        XCTAssertEqual(Set(games.compactMap(\.tournament)), [
            "Prudential Hong Kong Tennis Open", "Chennai Open", "Angola Ladies Open", "FAGE WTA Finals Indian Wells",
            "DIRECTV Open Presentado por Compesar"
        ])
    }

    func testGrandSlamDrawDecidesTourNotEventName() throws {
        // ESPN lists the US Open on both feeds with all five draws.
        let atp = try games(Self.slamFixture, .atp)
        let wta = try games(Self.slamFixture, .wta)
        XCTAssertEqual(atp.count, 6)
        XCTAssertEqual(wta.count, 6)
        XCTAssertTrue(atp.contains { $0.away.team.nickname == "Carlos Alcaraz" })
        XCTAssertFalse(atp.contains { $0.away.team.nickname == "Coco Gauff" || $0.home.team.nickname == "Coco Gauff" })
        XCTAssertTrue(wta.contains { $0.away.team.nickname == "Coco Gauff" })
        XCTAssertFalse(wta.contains { $0.away.team.nickname == "Carlos Alcaraz" })
        XCTAssertTrue(Set(atp.map(\.id.rawID)).isDisjoint(with: Set(wta.map(\.id.rawID))))
    }

    func testDrawClassification() {
        XCTAssertEqual(ESPNMapping.tennisDrawIsSingles(slug: "mens-singles", name: "Men's Singles", league: .atp), true)
        XCTAssertEqual(ESPNMapping.tennisDrawIsSingles(slug: "womens-singles", name: "Women's Singles", league: .atp), false)
        XCTAssertEqual(ESPNMapping.tennisDrawIsSingles(slug: "womens-singles", name: nil, league: .wta), true)
        XCTAssertEqual(ESPNMapping.tennisDrawIsSingles(slug: "mixed-doubles", name: nil, league: .wta), false)
        XCTAssertEqual(ESPNMapping.tennisDrawIsSingles(slug: "mens-doubles", name: nil, league: .atp), false)
        XCTAssertNil(ESPNMapping.tennisDrawIsSingles(slug: nil, name: nil, league: .atp))
    }

    // MARK: Empty vs failure

    func testDayWithoutSinglesIsEmptyNotMalformed() throws {
        // Real shape: "Austin 125" on the Nov 9 WTA feed has no groupings yet.
        let noDraws = Data(#"{"events":[{"id":"1031-2026","name":"Austin 125","date":"2026-11-08T05:00Z","groupings":[]}]}"#.utf8)
        let response = try JSONDecoder().decode(ESPNScoreboardResponse.self, from: noDraws)
        XCTAssertEqual(try ESPNSportsProvider().mapValidated(response, league: .wta), [])

        let empty = try JSONDecoder().decode(ESPNScoreboardResponse.self, from: Data(#"{"events":[]}"#.utf8))
        XCTAssertEqual(try ESPNSportsProvider().mapValidated(empty, league: .atp), [])
    }

    func testUnreadableSinglesStillReportMalformed() throws {
        let unreadable = Data(#"""
        {"events":[{"id":"x","name":"Cup","groupings":[{"grouping":{"slug":"mens-singles"},
          "competitions":[{"id":"m1","date":"2026-11-08T14:00Z","status":{"type":{"state":"pre"}},
          "competitors":[{"id":"1","athlete":{}},{"id":"2","athlete":{}}]}]}]}]}
        """#.utf8)
        let response = try JSONDecoder().decode(ESPNScoreboardResponse.self, from: unreadable)
        XCTAssertThrowsError(try ESPNSportsProvider().mapValidated(response, league: .atp)) {
            XCTAssertEqual($0 as? KyroSportsDataError, .malformedResponse)
        }
    }

    func testFlagDecodesESPNObjectAndLegacyString() throws {
        struct Holder: Decodable { let flag: ESPNFlag }
        let object = try JSONDecoder().decode(Holder.self, from: Data(#"{"flag":{"href":"https://a.espncdn.com/i/teamlogos/countries/500/esp.png","alt":"Spain"}}"#.utf8))
        XCTAssertEqual(object.flag.code, "ESP")
        XCTAssertEqual(object.flag.name, "Spain")
        let string = try JSONDecoder().decode(Holder.self, from: Data(#"{"flag":"IT"}"#.utf8))
        XCTAssertEqual(string.flag.code, "IT")
        let odd = try JSONDecoder().decode(Holder.self, from: Data(#"{"flag":42}"#.utf8))
        XCTAssertNil(odd.flag.code, "an unexpected shape degrades to no flag, not a failed scoreboard")
    }

    // MARK: Provider window and cache activity

    func testSelectedDayIsOneRequestFilteredToThatLocalDay() async throws {
        let transport = StubESPNTransport()
        transport.set(.init(data: try data(Self.atpFixture)))
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = TimeZone(identifier: "America/New_York")!
        let provider = ESPNSportsProvider(client: ESPNAPIClient(transport: transport), calendar: eastern)
        let now = utc("2026-11-08T02:00:00Z") // Sat Nov 7, 9 PM Eastern
        let sunday = eastern.date(from: DateComponents(year: 2026, month: 11, day: 8))!

        let output = try await provider.fetchLeagueDay(league: .atp, date: sunday, now: now, force: false)
        XCTAssertEqual(transport.requestCount(), 1, "one ESPN day carries every active tournament")
        XCTAssertNil(output.refreshError)
        XCTAssertFalse(output.games.isEmpty)
        XCTAssertTrue(output.games.allSatisfy { eastern.isDate($0.startTime!, inSameDayAs: sunday) })
        XCTAssertTrue(output.games.contains { $0.round == "Final" && $0.away.team.nickname == "Carlos Alcaraz" })
        XCTAssertFalse(output.games.contains { $0.round == "Semifinal" }, "Saturday's results stay on Saturday")

        // The ATP filter's "today" window is one request for today, not the
        // eight-day loop team sports use.
        let window = try await provider.fetchLeagueWindow(league: .atp, now: now, force: false)
        XCTAssertEqual(transport.requestCount(), 2)
        XCTAssertTrue(window.games.allSatisfy { eastern.isDate($0.startTime!, inSameDayAs: now) })
        XCTAssertTrue(window.games.contains { $0.round == "Semifinal" })
        _ = try await provider.fetchLeagueDay(league: .atp, date: sunday, now: now, force: false)
        XCTAssertEqual(transport.requestCount(), 2, "a revisited day is served from cache")
    }

    func testCacheActivityReadsMatchStatusesNotTournamentStatus() throws {
        let payload = try response(Self.atpFixture)
        // ESPN marks both tournaments STATUS_FINAL while matches remain.
        XCTAssertTrue(payload.events.allSatisfy { ESPNMapping.status(from: $0.status) == .final })
        let activity = ESPNPayloadActivity(payload)
        XCTAssertTrue(activity.hasPending)
        XCTAssertEqual(activity.soonestPendingStart, utc("2026-11-08T11:00:00Z"),
                       "date-only slots are not treated as imminent")
    }
}
