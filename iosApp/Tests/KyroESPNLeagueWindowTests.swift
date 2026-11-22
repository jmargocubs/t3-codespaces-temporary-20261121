import Foundation
import XCTest
@testable import Silo

/// Counts overlapping transport calls so tests can prove the concurrency cap.
private final class ConcurrencyProbeTransport: ESPNTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var peak = 0
    private var requests: [URLRequest] = []
    private let responder: @Sendable (URLRequest) -> (Data, Int)

    init(responder: @escaping @Sendable (URLRequest) -> (Data, Int)) {
        self.responder = responder
    }

    var maxConcurrent: Int { lock.withLock { peak } }
    var allRequests: [URLRequest] { lock.withLock { requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock {
            current += 1
            peak = max(peak, current)
            requests.append(request)
        }
        defer { lock.withLock { current -= 1 } }
        try await Task.sleep(for: .milliseconds(20))
        let (data, status) = responder(request)
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        return (data, http)
    }
}

final class KyroESPNLeagueWindowTests: XCTestCase {
    // MARK: Helpers

    private func fixture(_ name: String) throws -> Data {
        let bundled = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
        let sourceRelative = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ESPN/\(name).json")
        return try Data(contentsOf: try XCTUnwrap(bundled ?? sourceRelative))
    }

    private func games(_ name: String, league: KyroSportLeague) throws -> [KyroSportsGame] {
        let response = try JSONDecoder().decode(ESPNScoreboardResponse.self, from: fixture(name))
        return response.events.compactMap { ESPNMapping.game(from: $0, league: league) }
    }

    private func game(_ id: String, in games: [KyroSportsGame]) throws -> KyroSportsGame {
        try XCTUnwrap(games.first { $0.id.rawID == id }, "missing game \(id)")
    }

    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
    }

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private let empty = Data(#"{"leagues":[],"events":[]}"#.utf8)

    private func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    private func labels(_ game: KyroSportsGame) -> [String] { game.periods.map(\.label) }

    // MARK: Decoding live payload shapes

    func testLeagueLevelSeasonTypeObjectDoesNotRejectScoreboard() throws {
        // Live ESPN sends `leagues[0].season.type` as an object, not an Int.
        for name in [
            "espn_nfl_live_payload_shape", "espn_nhl_regulation_ot_shootout",
            "espn_nba_finals", "espn_mlb_final", "espn_empty_offseason",
            "espn_cfb_week10_live_ranked", "espn_cfb_bowls_postseason"
        ] {
            let response = try JSONDecoder().decode(ESPNScoreboardResponse.self, from: fixture(name))
            XCTAssertNotNil(response.leagues?.first?.season?.year, name)
            XCTAssertEqual(response.leagues?.first?.season?.type != nil, true, name)
        }
        let nfl = try games("espn_nfl_live_payload_shape", league: .nfl)
        XCTAssertEqual(nfl.count, 2)
        XCTAssertTrue(nfl.allSatisfy { $0.status.isScheduled && $0.seasonType == .regular })
    }

    func testCollegeBasketballPathsAndDivisionOneFixtureMapping() throws {
        XCTAssertEqual(ESPNMapping.path(for: .collegeBasketballMen), "/apis/site/v2/sports/basketball/mens-college-basketball/scoreboard")
        XCTAssertEqual(ESPNMapping.path(for: .collegeBasketballWomen), "/apis/site/v2/sports/basketball/womens-college-basketball/scoreboard")
        XCTAssertEqual(ESPNLeagueWindowStrategy.strategy(for: .collegeBasketballMen), .dailyRequests)
        XCTAssertEqual(ESPNLeagueWindowStrategy.strategy(for: .collegeBasketballWomen), .dailyRequests)
        XCTAssertEqual(KyroSportsCategory(league: .collegeBasketballMen).leagues, [.collegeBasketballMen])
        XCTAssertEqual(KyroSportsCategory(league: .collegeBasketballWomen).leagues, [.collegeBasketballWomen])
    }

    func testCollegeBasketballMapsRankedSchoolsAndFiltersTop25AndConference() throws {
        let json = #"{"events":[{"id":"college-1","date":"2026-11-19T19:00Z","season":{"year":2027,"type":2},"competitions":[{"id":"college-1","date":"2026-11-19T19:00Z","status":{"type":{"state":"pre","name":"STATUS_SCHEDULED","description":"Scheduled"}},"competitors":[{"homeAway":"home","score":"","curatedRank":{"current":4},"team":{"id":"ucla","abbreviation":"UCLA","location":"UCLA","name":"Bruins","displayName":"UCLA Bruins","standingSummary":"1st in Big Ten"}},{"homeAway":"away","score":"","team":{"id":"calpoly","abbreviation":"CP","location":"Cal Poly","name":"Mustangs","displayName":"Cal Poly Mustangs","standingSummary":"1st in Big West"}}]}]}]}"#
        let response = try JSONDecoder().decode(ESPNScoreboardResponse.self, from: Data(json.utf8))
        let men = try XCTUnwrap(ESPNMapping.game(from: response.events[0], league: .collegeBasketballMen))
        XCTAssertEqual(men.home.rank, 4)
        XCTAssertEqual(men.status, .scheduled)
        XCTAssertNil(men.home.score)
        XCTAssertEqual(men.home.team.conference, "Big Ten")
        XCTAssertEqual(KyroSportsDaySchedule.filtered([men], top25Only: true).count, 1)
        XCTAssertEqual(KyroSportsDaySchedule.filtered([men], conference: "Big Ten").count, 1)
        XCTAssertTrue(KyroSportsDaySchedule.filtered([men], conference: "ACC").isEmpty)
        let women = try XCTUnwrap(ESPNMapping.game(from: response.events[0], league: .collegeBasketballWomen))
        XCTAssertEqual(women.league, .collegeBasketballWomen)
    }

    func testRateLimitedCollegeResponseUsesCachedFallback() async throws {
        let transport = StubESPNTransport()
        let client = ESPNAPIClient(transport: transport)
        transport.set(.init(data: Data(#"{"events":[]}"#.utf8)))
        _ = try await client.fetchScoreboard(league: .collegeBasketballMen, dates: "20261119", policy: .today)
        transport.set(.init(data: Data(), status: 429), leaguePath: ESPNMapping.path(for: .collegeBasketballMen), dates: "20261119")
        let payload = try await client.fetchScoreboard(league: .collegeBasketballMen, dates: "20261119", policy: .today, ignoreFreshness: true)
        XCTAssertTrue(payload.response.events.isEmpty)
    }

    // MARK: NBA

    func testNBAFinalsMapTeamsScoresRecordsQuartersAndLogos() throws {
        let mapped = try games("espn_nba_finals", league: .nba)
        let first = try game("401810341", in: mapped)
        XCTAssertEqual(first.home.team.abbreviation, "MIA")
        XCTAssertEqual(first.away.team.abbreviation, "MIN")
        XCTAssertEqual(first.home.score, 115)
        XCTAssertEqual(first.away.score, 125)
        XCTAssertEqual(first.home.displayRecord, "19-16")
        XCTAssertEqual(labels(first), ["Q1", "Q2", "Q3", "Q4"])
        XCTAssertEqual(first.status, .final)
        XCTAssertNotNil(first.home.team.logoURL)
        XCTAssertEqual(first.id.stringValue, "espn.nba.401810341")
        XCTAssertNil(first.week)
    }

    func testNBALiveClockAndOvertimeLabels() throws {
        let mapped = try games("espn_synthetic_nba_live_overtime", league: .nba)
        let live = try game("401810341", in: mapped)
        XCTAssertEqual(live.status, .live)
        XCTAssertEqual(live.statusLine, "5:12 - 4th Quarter")
        XCTAssertEqual(live.home.score, 88)
        XCTAssertEqual(labels(live), ["Q1", "Q2", "Q3"])

        let overtime = try game("401810342", in: mapped)
        XCTAssertEqual(labels(overtime), ["Q1", "Q2", "Q3", "Q4", "OT"])
        XCTAssertEqual(overtime.statusLine, "Final/OT")

        let double = try game("synthetic-nba-2ot", in: mapped)
        XCTAssertEqual(labels(double).suffix(2), ["OT", "2OT"])
    }

    // MARK: NHL

    func testNHLOvertimeAndShootoutRegularSeason() throws {
        let mapped = try games("espn_nhl_regulation_ot_shootout", league: .nhl)
        XCTAssertEqual(labels(try game("401802995", in: mapped)), ["P1", "P2", "P3"])
        let overtime = try game("401803002", in: mapped)
        XCTAssertEqual(labels(overtime), ["P1", "P2", "P3", "OT"])
        XCTAssertEqual(overtime.statusLine, "Final/OT")
        XCTAssertEqual(overtime.winner?.team.abbreviation, "NYI")
        let shootout = try game("401803003", in: mapped)
        XCTAssertEqual(labels(shootout), ["P1", "P2", "P3", "OT", "SO"])
        XCTAssertEqual(shootout.statusLine, "Final/SO")
        XCTAssertEqual(shootout.winner?.team.abbreviation, "CHI")
        XCTAssertNotNil(shootout.away.team.logoURL)
    }

    func testNHLPlayoffOvertimesAreNotLabelledShootouts() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixture("espn_nhl_regulation_ot_shootout")) as? [String: Any]
        )
        var events = try XCTUnwrap(object["events"] as? [[String: Any]])
        for index in events.indices {
            events[index]["season"] = ["year": 2026, "type": 3, "slug": "post-season"]
        }
        object["events"] = events
        let data = try JSONSerialization.data(withJSONObject: object)
        let response = try JSONDecoder().decode(ESPNScoreboardResponse.self, from: data)
        let mapped = response.events.compactMap { ESPNMapping.game(from: $0, league: .nhl) }
        let long = try game("401803003", in: mapped)
        XCTAssertEqual(labels(long), ["P1", "P2", "P3", "OT", "2OT"])
        XCTAssertEqual(long.seasonType, .postseason)
    }

    // MARK: MLB

    func testMLBExtraInningsAndUnevenInnings() throws {
        let extra = try game("401816831", in: try games("espn_mlb_extra_innings", league: .mlb))
        XCTAssertEqual(labels(extra), (1...10).map(String.init))
        XCTAssertEqual(extra.statusLine, "Final/10")
        XCTAssertEqual(extra.home.score, 3)

        let uneven = try game("401816775", in: try games("espn_mlb_final", league: .mlb))
        XCTAssertEqual(uneven.periods.count, 9, "away batted nine, home eight")
        XCTAssertNil(uneven.periods.last?.homeScore)
    }

    func testMLBLiveInningOutsPostponementAndDoubleheaderIdentity() throws {
        let mapped = try games("espn_synthetic_mlb_states", league: .mlb)
        let live = try game("syn-mlb-live", in: mapped)
        XCTAssertEqual(live.status, .live)
        XCTAssertEqual(live.statusLine, "Top 7th")
        XCTAssertEqual(live.situation, "2 outs")

        let postponed = try game("syn-mlb-postponed", in: mapped)
        XCTAssertEqual(postponed.status, .postponed)
        XCTAssertEqual(postponed.statusLine, "Postponed")
        XCTAssertNil(postponed.situation)

        let first = try game("syn-mlb-dh-game1", in: mapped)
        let second = try game("syn-mlb-dh-game2", in: mapped)
        XCTAssertEqual(first.home.team.id, second.home.team.id)
        XCTAssertNotEqual(first.id, second.id)
        let deduped = KyroSportsReconciler.deduplicated(mapped)
        XCTAssertEqual(deduped.count, mapped.count, "same teams, same day: both games survive")
    }

    // MARK: NCAA FBS

    func testFBSRankingsWeekLiveAndRecords() throws {
        let mapped = try games("espn_cfb_week10_live_ranked", league: .collegeFootball)
        let live = try game("401856855", in: mapped)
        XCTAssertEqual(live.status, .live)
        XCTAssertEqual(live.home.rank, 22)
        XCTAssertNil(live.away.rank, "99 means unranked")
        XCTAssertEqual(live.week, 10)
        XCTAssertEqual(live.statusLine, "0:43 - 4th")
        XCTAssertEqual(labels(live), ["Q1", "Q2", "Q3", "Q4"])

        let ranked = try game("401856849", in: mapped)
        XCTAssertEqual([ranked.home.rank, ranked.away.rank], [3, 9])
        XCTAssertNil(ranked.home.score, "scheduled games carry no score")
        XCTAssertEqual(ranked.home.displayRecord, "8-0")
    }

    func testFBSBowlAndChampionshipKeepPostseasonMetadata() throws {
        let bowls = try games("espn_cfb_bowls_postseason", league: .collegeFootball)
        let bowl = try game("401778319", in: bowls)
        XCTAssertEqual(bowl.seasonType, .postseason)
        XCTAssertEqual(bowl.week, 1)
        XCTAssertEqual(bowl.note, "Pop-Tarts Bowl")
        XCTAssertEqual([bowl.home.rank, bowl.away.rank], [12, 22])

        let champ = try game(
            "401777353",
            in: try games("espn_cfb_conference_championship", league: .collegeFootball)
        )
        XCTAssertEqual(champ.note, "Big Ten Championship")
        XCTAssertEqual(champ.seasonType, .regular)
    }

    func testFBSSectioningUsesESPNWeekAndFallsBackToRollingWindow() throws {
        let mapped = try games("espn_cfb_week10_live_ranked", league: .collegeFootball)
        let template = try game("401856849", in: mapped)
        let nextWeek = KyroSportsGame(
            id: KyroGameID(provider: "espn", league: .collegeFootball, rawID: "week11"),
            league: .collegeFootball,
            season: template.season,
            seasonType: .regular,
            week: 11,
            startTime: template.startTime?.addingTimeInterval(86_400),
            status: .scheduled,
            home: template.home,
            away: template.away
        )
        let now = try date("2026-11-07T14:00:00Z")
        let cal = calendar("America/New_York")
        let weekContext = KyroSportsScheduleContext(league: .collegeFootball, currentWeek: 10, currentSeason: 2026)
        XCTAssertTrue(KyroSportsSectioning.isInsideVisibleUpcomingWindow(
            template, now: now, calendar: cal, context: weekContext))
        XCTAssertFalse(KyroSportsSectioning.isInsideVisibleUpcomingWindow(
            nextWeek, now: now, calendar: cal, context: weekContext))
        // No authoritative week: rolling seven local days applies.
        let rolling = KyroSportsScheduleContext(league: .collegeFootball)
        XCTAssertTrue(KyroSportsSectioning.isInsideVisibleUpcomingWindow(
            nextWeek, now: now, calendar: cal, context: rolling))
    }

    // MARK: Window loading

    private func nbaTransport(
        servedDay: String = "20260103",
        failingDays: Set<String> = []
    ) throws -> ConcurrencyProbeTransport {
        let finals = try fixture("espn_nba_finals")
        let empty = empty
        return ConcurrencyProbeTransport { request in
            let day = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "dates" }?.value ?? ""
            if failingDays.contains(day) { return (Data(), 500) }
            return (day == servedDay ? finals : empty, 200)
        }
    }

    func testNBAWindowRequestsBoundedDaysWithoutRangesAndCapsConcurrency() async throws {
        let transport = try nbaTransport()
        let provider = ESPNSportsProvider(
            client: ESPNAPIClient(transport: transport),
            calendar: calendar("America/Los_Angeles")
        )
        let now = try date("2026-01-03T20:00:00Z")

        let output = try await provider.fetchLeagueWindow(league: .nba, now: now, force: false)

        XCTAssertEqual(output.games.map(\.id.rawID).sorted(), ["401810341", "401810342"])
        XCTAssertNil(output.refreshError)
        let days = transport.allRequests.compactMap { query($0, "dates") }.sorted()
        XCTAssertEqual(days, (2...10).map { String(format: "202601%02d", $0) })
        XCTAssertTrue(days.allSatisfy { $0.count == 8 && !$0.contains("-") }, "no date ranges")
        XCTAssertLessThanOrEqual(transport.maxConcurrent, ESPNSportsProvider.maxConcurrentDayRequests)
        XCTAssertTrue(transport.allRequests.allSatisfy { $0.url?.path.hasSuffix("/basketball/nba/scoreboard") == true })
    }

    func testRepeatedWindowLoadsServeFromCacheAndForceRefreshesOnlyToday() async throws {
        let transport = try nbaTransport()
        let provider = ESPNSportsProvider(
            client: ESPNAPIClient(transport: transport),
            calendar: calendar("America/Los_Angeles")
        )
        let now = try date("2026-01-03T20:00:00Z")
        _ = try await provider.fetchLeagueWindow(league: .nba, now: now, force: false)
        let first = transport.allRequests.count

        _ = try await provider.fetchLeagueWindow(league: .nba, now: now, force: false)
        XCTAssertEqual(transport.allRequests.count, first, "tab switching must not refetch")

        _ = try await provider.fetchLeagueWindow(league: .nba, now: now, force: true)
        XCTAssertEqual(transport.allRequests.count, first + 1, "force bypasses only today's day")
    }

    func testPartialDayFailureKeepsGoodDaysAndFlagsStale() async throws {
        let transport = try nbaTransport(failingDays: ["20260105"])
        let provider = ESPNSportsProvider(
            client: ESPNAPIClient(transport: transport),
            calendar: calendar("America/Los_Angeles")
        )
        let output = try await provider.fetchLeagueWindow(
            league: .nba, now: try date("2026-01-03T20:00:00Z"), force: false)
        XCTAssertEqual(output.games.count, 2)
        XCTAssertEqual(output.refreshError, .httpStatus(500))
        XCTAssertTrue(output.isStale)
    }

    func testAllDaysFailingThrowsAndEmptyScheduleIsNotAnError() async throws {
        let failing = ConcurrencyProbeTransport { _ in (Data(), 503) }
        let broken = ESPNSportsProvider(
            client: ESPNAPIClient(transport: failing),
            calendar: calendar("America/Los_Angeles")
        )
        let now = try date("2026-01-03T20:00:00Z")
        do {
            _ = try await broken.fetchLeagueWindow(league: .nhl, now: now, force: false)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? KyroSportsDataError, .httpStatus(503))
        }

        let offseason = ESPNSportsProvider(
            client: ESPNAPIClient(transport: ConcurrencyProbeTransport { [empty] _ in (empty, 200) }),
            calendar: calendar("America/Los_Angeles")
        )
        let output = try await offseason.fetchLeagueWindow(league: .mlb, now: now, force: false)
        XCTAssertTrue(output.games.isEmpty)
        XCTAssertNil(output.refreshError, "an empty schedule is valid, not a provider error")
    }

    func testOverlappingDayResponsesAreDeduplicatedByProviderID() async throws {
        let finals = try fixture("espn_nba_finals")
        let transport = ConcurrencyProbeTransport { _ in (finals, 200) }
        let provider = ESPNSportsProvider(
            client: ESPNAPIClient(transport: transport),
            calendar: calendar("America/Los_Angeles")
        )
        let output = try await provider.fetchLeagueWindow(
            league: .nba, now: try date("2026-01-03T20:00:00Z"), force: false)
        XCTAssertEqual(output.games.count, 2)
    }

    func testCrossMidnightGameGroupsOnUsersLocalCalendarDay() throws {
        // 00:30 UTC Jan 4 is 7:30 pm Jan 3 in Los Angeles. ESPN files it under
        // its own US-Eastern day (Jan 3) and Kyro groups it on the local day.
        let mapped = try games("espn_nba_finals", league: .nba)
        let late = try game("401810342", in: mapped)
        let start = try XCTUnwrap(late.startTime)
        let la = calendar("America/Los_Angeles")
        XCTAssertEqual(ESPNSportsProvider.espnDayString(for: start), "20260103")
        XCTAssertEqual(la.dateComponents([.month, .day], from: start).day, 3)
        let utcDay = calendar("UTC").dateComponents([.day], from: start).day
        XCTAssertEqual(utcDay, 4)

        let now = try date("2026-01-04T08:00:00Z")
        let sections = KyroSportsSectioning.sections(
            from: mapped, now: now, calendar: la, context: KyroSportsScheduleContext(league: .nba))
        let recent = sections.filter { $0.bucket == .recent }.flatMap(\.games).map(\.id.rawID)
        XCTAssertEqual(Set(recent), ["401810341", "401810342"])
    }

    func testESPNDaysAreContiguousAcrossDaylightSavingChanges() throws {
        for (zone, startISO) in [
            ("America/Los_Angeles", "2026-10-30T12:00:00Z"), // fall back 2026-11-01
            ("America/Los_Angeles", "2026-03-05T12:00:00Z"), // spring forward 2026-03-08
            ("Europe/Berlin", "2026-03-26T12:00:00Z"),       // EU change 2026-03-29
            ("Pacific/Auckland", "2026-09-24T12:00:00Z")     // NZ change 2026-09-27
        ] {
            let cal = calendar(zone)
            let start = cal.startOfDay(for: try date(startISO))
            let end = try XCTUnwrap(cal.date(byAdding: .day, value: 7, to: start))
            let days = ESPNSportsProvider.espnDays(covering: start, until: end)
            XCTAssertEqual(days, Array(Set(days)).sorted(), zone)
            XCTAssertTrue((8...9).contains(days.count), "\(zone): \(days)")
            var eastern = Calendar(identifier: .gregorian)
            eastern.timeZone = TimeZone(identifier: "America/New_York")!
            let formatter = DateFormatter()
            formatter.calendar = eastern
            formatter.timeZone = eastern.timeZone
            formatter.dateFormat = "yyyyMMdd"
            let parsed = try days.map { try XCTUnwrap(formatter.date(from: $0)) }
            for pair in zip(parsed, parsed.dropFirst()) {
                XCTAssertEqual(eastern.dateComponents([.day], from: pair.0, to: pair.1).day, 1, zone)
            }
        }
    }

    func testFBSLoadsCurrentWeekWithOneUndatedFBSRequest() async throws {
        let week = try fixture("espn_cfb_week10_live_ranked")
        let transport = ConcurrencyProbeTransport { _ in (week, 200) }
        let provider = ESPNSportsProvider(
            client: ESPNAPIClient(transport: transport),
            calendar: calendar("America/New_York")
        )
        let now = try date("2026-11-07T14:00:00Z")

        let output = try await provider.fetchLeagueWindow(league: .collegeFootball, now: now, force: false)

        XCTAssertEqual(output.week, 10)
        XCTAssertEqual(output.season, 2026)
        XCTAssertEqual(output.games.count, 4)
        let request = try XCTUnwrap(transport.allRequests.first)
        XCTAssertEqual(transport.allRequests.count, 1)
        XCTAssertNil(query(request, "dates"))
        XCTAssertEqual(query(request, "groups"), "80")

        _ = try await provider.fetchLeagueWindow(league: .collegeFootball, now: now, force: false)
        XCTAssertEqual(transport.allRequests.count, 1, "second visit uses the cache")
    }

    func testFBSWithoutWeekMetadataFallsBackToBoundedDailyWindow() async throws {
        let transport = ConcurrencyProbeTransport { [empty] _ in (empty, 200) }
        let provider = ESPNSportsProvider(
            client: ESPNAPIClient(transport: transport),
            calendar: calendar("America/New_York")
        )
        let output = try await provider.fetchLeagueWindow(
            league: .collegeFootball, now: try date("2026-11-07T14:00:00Z"), force: false)
        XCTAssertTrue(output.games.isEmpty)
        let dated = transport.allRequests.compactMap { query($0, "dates") }
        XCTAssertEqual(dated.count, 8, "yesterday plus seven local days, all in one ET calendar")
        XCTAssertEqual(transport.allRequests.count, 9)
        XCTAssertTrue(transport.allRequests.allSatisfy { query($0, "groups") == "80" })
    }

    // MARK: Cache behaviour

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        func now() -> Date { lock.withLock { value } }
        func advance(_ interval: TimeInterval) { lock.withLock { value.addTimeInterval(interval) } }
    }

    func testTodayPolicyIsShortWhileLiveAndLongWhenIdle() async throws {
        let live = try fixture("espn_synthetic_nba_live_overtime")
        let idle = try fixture("espn_nba_finals")
        for (data, expectRefetchAfter20s) in [(live, true), (idle, false)] {
            let clock = Clock(Date(timeIntervalSince1970: 1_767_000_000))
            let transport = StubESPNTransport()
            transport.set(.init(data: data))
            let client = ESPNAPIClient(transport: transport, now: { clock.now() })
            _ = try await client.fetchScoreboard(league: .nba, dates: "20260103", policy: .today)
            clock.advance(25)
            _ = try await client.fetchScoreboard(league: .nba, dates: "20260103", policy: .today)
            XCTAssertEqual(transport.requestCount(), expectRefetchAfter20s ? 2 : 1)
        }
    }

    func testCompletedDayServesStaleResultsDuringOutage() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_767_000_000))
        let transport = StubESPNTransport()
        transport.set(.init(data: try fixture("espn_nba_finals")))
        let client = ESPNAPIClient(transport: transport, now: { clock.now() })
        _ = try await client.fetchScoreboard(league: .nba, dates: "20260103", policy: .completedDay)

        clock.advance(13 * 3600) // past the 12 h freshness window
        transport.setFailure(KyroSportsDataError.offline)
        let stale = try await client.fetchScoreboard(league: .nba, dates: "20260103", policy: .completedDay)
        XCTAssertEqual(stale.response.events.count, 2)
        XCTAssertEqual(stale.refreshError, .offline)

        clock.advance(26 * 3600) // beyond freshness plus the 24 h grace
        do {
            _ = try await client.fetchScoreboard(league: .nba, dates: "20260103", policy: .completedDay)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? KyroSportsDataError, .offline)
        }
    }

    func testCancellingOneWaiterDoesNotCancelTheSharedRequest() async throws {
        let transport = StubESPNTransport()
        transport.set(.init(data: try fixture("espn_nba_finals"), delay: .milliseconds(150)))
        let client = ESPNAPIClient(transport: transport)

        let doomed = Task {
            try await client.fetchScoreboard(league: .nba, dates: "20260103", policy: .today)
        }
        try await Task.sleep(for: .milliseconds(20))
        let survivor = Task {
            try await client.fetchScoreboard(league: .nba, dates: "20260103", policy: .today)
        }
        try await Task.sleep(for: .milliseconds(20))
        doomed.cancel()

        let payload = try await survivor.value
        XCTAssertEqual(payload.response.events.count, 2)
        XCTAssertEqual(transport.requestCount(), 1)
    }

    func testCacheIsBoundedAndOversizedResponsesAreRejected() async throws {
        let transport = StubESPNTransport()
        transport.set(.init(data: empty))
        let client = ESPNAPIClient(transport: transport)
        for index in 0..<(ESPNAPIClient.maxCachedEntries + 10) {
            _ = try await client.fetchScoreboard(
                league: .nba,
                dates: String(format: "2027%04d", index + 101),
                policy: .futureDay
            )
        }
        let count = await client.cachedResponseCount()
        XCTAssertLessThanOrEqual(count, ESPNAPIClient.maxCachedEntries)

        let oversized = StubESPNTransport()
        oversized.set(.init(data: Data(count: ESPNAPIClient.maxResponseBytes + 1)))
        let guarded = ESPNAPIClient(transport: oversized)
        do {
            _ = try await guarded.fetchScoreboard(league: .nba, dates: "20260103", policy: .today)
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? KyroSportsDataError, .malformedResponse)
        }
        let guardedCount = await guarded.cachedResponseCount()
        XCTAssertEqual(guardedCount, 0)
    }

    func testRefreshPolicyOnlyPollsLiveOrImminentGames() throws {
        let now = try date("2026-11-07T14:00:00Z")
        let live = try games("espn_cfb_week10_live_ranked", league: .collegeFootball)
        XCTAssertEqual(KyroSportsRefreshPolicy.interval(for: live, now: now), 20)
        let finals = try games("espn_nba_finals", league: .nba)
        XCTAssertNil(KyroSportsRefreshPolicy.interval(for: finals, now: now))
        XCTAssertNil(KyroSportsRefreshPolicy.interval(for: [], now: now))
    }
}
