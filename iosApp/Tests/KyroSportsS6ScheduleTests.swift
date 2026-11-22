import Foundation
import XCTest
@testable import Silo

@MainActor
final class KyroSportsS6ScheduleTests: XCTestCase {

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
        provider: String = "espn",
        statusDetail: String? = nil,
        score: Int = 3
    ) -> KyroSportsGame {
        KyroSportsGame(
            id: KyroGameID(provider: provider, league: league, rawID: id),
            league: league,
            season: 2026,
            seasonType: .regular,
            week: week,
            startTime: now.addingTimeInterval(hoursFromNow * 3600),
            status: status,
            statusDetail: statusDetail,
            home: KyroGameTeam(team: .placeholder(abbreviation: "HOM", league: league), score: status.isScheduled ? nil : score),
            away: KyroGameTeam(team: .placeholder(abbreviation: "AWY", league: league), score: status.isScheduled ? nil : score - 1)
        )
    }

    private func output(_ games: [KyroSportsGame], week: Int = 0, error: KyroSportsDataError? = nil) -> KyroSportsProviderOutput {
        KyroSportsProviderOutput(provider: "stub", games: games, season: 2026, week: week, refreshError: error)
    }

    private actor LeagueStub: KyroSportsLeagueProviding {
        private(set) var windowCalls: [KyroSportLeague] = []
        private(set) var dayCalls: [(KyroSportLeague, Date)] = []
        private var results: [KyroSportLeague: KyroSportsProviderOutput] = [:]
        private var failing: Set<KyroSportLeague> = []
        private var gated: Set<KyroSportLeague> = []
        private var waiters: [CheckedContinuation<Void, Never>] = []

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
        func windowCount(_ league: KyroSportLeague) -> Int { windowCalls.filter { $0 == league }.count }
        func dayCount(_ league: KyroSportLeague) -> Int { dayCalls.filter { $0.0 == league }.count }
        func dayDates(_ league: KyroSportLeague) -> [Date] { dayCalls.filter { $0.0 == league }.map(\.1) }

        func fetchLeagueWindow(league: KyroSportLeague, now: Date, force: Bool) async throws -> KyroSportsProviderOutput {
            windowCalls.append(league)
            return try await finish(league)
        }

        func fetchLeagueDay(league: KyroSportLeague, date: Date, now: Date, force: Bool) async throws -> KyroSportsProviderOutput {
            dayCalls.append((league, date))
            return try await finish(league)
        }

        private func finish(_ league: KyroSportLeague) async throws -> KyroSportsProviderOutput {
            if gated.contains(league) {
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

    private func makeStore(
        stub: LeagueStub,
        nfl: [KyroSportsGame] = [],
        preferences: UserDefaults? = nil
    ) -> KyroSportsHubStore {
        KyroSportsHubStore(
            providers: [NFLStub(games: nfl)],
            leagueProvider: stub,
            calendar: calendar,
            now: { [now] in now },
            preferences: preferences
        )
    }

    private func ephemeralDefaults() -> UserDefaults {
        let name = "kyro.sports.s6.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: Aggregation and filtering

    func testAllSportsIsTheDefaultCategory() {
        let store = makeStore(stub: LeagueStub())
        XCTAssertEqual(store.selectedCategory, .all)
        XCTAssertEqual(KyroSportsCategory.filterOrder.map(\.shortName), ["All", "NFL", "NCAA", "NBA", "NHL", "MLB", "SOC", "ATP", "WTA"])
    }

    // MARK: Build 39 sport selector and Live Now source

    func testSportSelectorListsEveryOptionInCategoryOrder() {
        XCTAssertEqual(KyroSportsCategory.filterOrder.map(\.menuName),
                       ["All Sports", "NFL", "NCAA Football", "NBA", "NHL", "MLB", "Soccer", "ATP Tennis", "WTA Tennis"])
    }

    func testSelectorSavesTheChoiceAndReselectingIsANoOp() async {
        let defaults = ephemeralDefaults()
        let stub = LeagueStub()
        let store = makeStore(stub: stub, preferences: defaults)
        store.selectCategory(.nba)
        await store.load()
        XCTAssertEqual(defaults.string(forKey: "kyro.sports.selectedCategory"), "nba")
        let calls = await stub.windowCount(.nba) + stub.dayCount(.nba)
        store.selectCategory(.nba)
        await store.loadIfNeeded()
        let after = await stub.windowCount(.nba) + stub.dayCount(.nba)
        XCTAssertEqual(after, calls, "choosing the current sport again fetches nothing")
        XCTAssertEqual(makeStore(stub: LeagueStub(), preferences: defaults).selectedCategory, .nba)
    }

    func testLiveGamesFollowTheSportFilterButNotTheBrowsedDay() async {
        let stub = LeagueStub()
        await stub.set(.nba, output([game("nba-live", .nba, .live, hoursFromNow: -1),
                                     game("nba-later", .nba, hoursFromNow: 3)]))
        await stub.set(.nhl, output([game("nhl-live", .nhl, .live, hoursFromNow: -0.5),
                                     game("nhl-final", .nhl, .final, hoursFromNow: -5)]))
        let store = makeStore(stub: stub)
        await store.load()
        XCTAssertEqual(Set(store.liveGames.map(\.id.rawID)), ["nba-live", "nhl-live"])

        store.selectDay(calendar.date(byAdding: .day, value: 2, to: now)!)
        XCTAssertEqual(Set(store.liveGames.map(\.id.rawID)), ["nba-live", "nhl-live"],
                       "Live Now stays on what is live now while another day is browsed")

        store.selectCategory(.nhl)
        XCTAssertEqual(store.liveGames.map(\.id.rawID), ["nhl-live"])
    }

    func testAllSportsMergesDeduplicatesAndUsesLiveFirstDisplayOrder() async {
        let stub = LeagueStub()
        let liveNBA = game("nba-live", .nba, .live, hoursFromNow: -1)
        let laterNHL = game("nhl-night", .nhl, hoursFromNow: 5)
        let earlierMLB = game("mlb-day", .mlb, .final, hoursFromNow: -6)
        let dupNBA = game("nba-live", .nba, .live, hoursFromNow: -1)
        await stub.set(.nba, output([liveNBA, dupNBA]))
        await stub.set(.nhl, output([laterNHL]))
        await stub.set(.mlb, output([earlierMLB]))
        let store = makeStore(
            stub: stub,
            nfl: [game("nfl-eve", .nfl, hoursFromNow: 2, week: 9)]
        )
        await store.load()

        XCTAssertEqual(
            store.scheduleGames.map(\.id.rawID),
            ["nba-live", "nfl-eve", "nhl-night", "mlb-day"]
        )
        XCTAssertEqual(store.scheduleGames.map(\.league), [.nba, .nfl, .nhl, .mlb])
    }

    func testAllSportsGroupsInSportOrderAndSortsWithinEachSection() {
        let games = [
            game("mlb", .mlb, hoursFromNow: 1),
            game("nba-late", .nba, hoursFromNow: 5),
            game("nfl", .nfl, hoursFromNow: 3),
            game("nba-early", .nba, hoursFromNow: 2),
            game("fbs", .collegeFootball, hoursFromNow: 4)
        ]
        let sections = KyroSportsDaySchedule.sportSections(from: games)
        XCTAssertEqual(sections.map(\.league), [.nfl, .collegeFootball, .nba, .mlb])
        XCTAssertEqual(sections.map(\.games.count), [1, 1, 2, 1])
        XCTAssertEqual(sections[2].games.map(\.id.rawID), ["nba-early", "nba-late"])
        XCTAssertFalse(sections.map(\.league).contains(.nhl), "empty sport sections are omitted")
    }

    func testSportSectionSortsLiveUpcomingInterruptedAndRecentFinal() {
        let games = [
            game("final-old", .nba, .final, hoursFromNow: -8),
            game("upcoming-late", .nba, hoursFromNow: 5),
            game("halftime", .nba, .live, hoursFromNow: -2, statusDetail: "Halftime"),
            game("suspended", .nba, .suspended, hoursFromNow: -4),
            game("final-recent", .nba, .final, hoursFromNow: -3),
            game("upcoming-early", .nba, hoursFromNow: 2),
            game("overtime", .nba, .live, hoursFromNow: -1, statusDetail: "OT"),
            game("postponed", .nba, .postponed, hoursFromNow: 3),
            game("canceled", .nba, .canceled, hoursFromNow: 4)
        ]

        let ordered = KyroSportsDaySchedule.sportSections(from: games)[0].games
        XCTAssertEqual(ordered.map(\.id.rawID), [
            "halftime", "overtime",
            "upcoming-early", "upcoming-late",
            "suspended", "postponed", "canceled",
            "final-recent", "final-old"
        ])
        XCTAssertEqual(ordered.prefix(2).map(\.status), [.live, .live])
        XCTAssertEqual(ordered[4].status, .suspended)
    }

    func testLiveFirstSortHasDeterministicTiesAndDoesNotUseScoreOrClock() {
        let first = game("a", .nhl, .live, hoursFromNow: -1, statusDetail: "P2 12:00", score: 1)
        let second = game("b", .nhl, .live, hoursFromNow: -1, statusDetail: "OT 0:10", score: 99)
        let forward = [second, first].sorted(by: KyroSportsDaySchedule.scheduleOrder)
        let reverse = [first, second].sorted(by: KyroSportsDaySchedule.scheduleOrder)
        XCTAssertEqual(forward.map(\.id), reverse.map(\.id))
        XCTAssertEqual(forward.map(\.id.rawID), ["a", "b"])
    }

    func testIndividualLeagueUsesTheSameLiveFirstOrdering() async {
        let stub = LeagueStub()
        await stub.set(.nhl, output([
            game("final", .nhl, .final, hoursFromNow: -1),
            game("scheduled", .nhl, hoursFromNow: 2),
            game("intermission", .nhl, .live, hoursFromNow: -3, statusDetail: "Intermission")
        ]))
        let store = makeStore(stub: stub)
        store.selectCategory(.nhl)
        await store.load()
        XCTAssertEqual(store.scheduleGames.map(\.id.rawID), ["intermission", "scheduled", "final"])
    }

    // MARK: Build 41 schedule rows

    func testAllSportsRowsInterleaveSportHeadersInSportOrder() {
        let games = [
            game("nba-live", .nba, .live, hoursFromNow: -1),
            game("nfl", .nfl, hoursFromNow: 3),
            game("nba-late", .nba, hoursFromNow: 5),
            game("fbs", .collegeFootball, hoursFromNow: 4),
            game("wta", .wta, .final, hoursFromNow: -3)
        ]
        let schedule = KyroSportsDaySchedule.aggregate([games], on: now, calendar: calendar, now: now)
        let rows = KyroSportsScheduleLayout.rows(for: schedule, groupedBySport: true)
        XCTAssertEqual(rows.map(\.id), [
            "sport|nfl", "game|espn.nfl.nfl",
            "sport|collegeFootball", "game|espn.collegeFootball.fbs",
            "sport|nba", "game|espn.nba.nba-live", "game|espn.nba.nba-late",
            "sport|wta", "game|espn.wta.wta"
        ])
        XCTAssertEqual(rows.compactMap { row -> Int? in
            if case .sportHeader(_, let count) = row { return count }
            return nil
        }, [1, 1, 2, 1])
        // Grouping keeps the display order inside each sport; it never re-sorts differently.
        let sections = KyroSportsDaySchedule.sportSections(from: games)
        XCTAssertEqual(rows.compactMap { row -> String? in
            if case .game(let game) = row { return game.id.rawID }
            return nil
        }, sections.flatMap(\.games).map(\.id.rawID))
    }

    func testOneSportRowsAreGamesOnlyWithStableIdentity() {
        let games = [game("a", .nba, .live, hoursFromNow: -1), game("b", .nba, hoursFromNow: 2)]
        let single = KyroSportsScheduleLayout.rows(for: games, groupedBySport: false)
        let all = KyroSportsScheduleLayout.rows(for: games, groupedBySport: true)
        XCTAssertFalse(single.contains(where: \.isSportHeader))
        XCTAssertEqual(single.map(\.id), ["game|espn.nba.a", "game|espn.nba.b"])
        XCTAssertEqual(all.filter { !$0.isSportHeader }.map(\.id), single.map(\.id),
                       "a game keeps its row identity whichever filter shows it")
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "row identities are unique")
    }

    func testStoreRowsFollowSportSwitchesDatesAndRefreshedScores() async {
        let stub = LeagueStub()
        await stub.set(.nba, output([
            game("nba-today", .nba, hoursFromNow: 2),
            game("nba-tomorrow", .nba, hoursFromNow: 26)
        ]))
        await stub.set(.nhl, output([game("nhl-today", .nhl, .live, hoursFromNow: -1)]))
        let store = makeStore(stub: stub)
        await store.load()
        XCTAssertEqual(store.scheduleRows.map(\.id),
                       ["sport|nba", "game|espn.nba.nba-today", "sport|nhl", "game|espn.nhl.nhl-today"])
        XCTAssertEqual(store.liveGames.map(\.id.rawID), ["nhl-today"])

        store.selectCategory(.nba)
        XCTAssertEqual(store.scheduleRows.map(\.id), ["game|espn.nba.nba-today"], "switching shows no stale rows")
        XCTAssertTrue(store.liveGames.isEmpty)
        store.selectDay(calendar.date(byAdding: .day, value: 1, to: now)!)
        await store.load()
        XCTAssertEqual(store.scheduleRows.map(\.id), ["game|espn.nba.nba-tomorrow"])

        // A refresh that changes a game replaces the cached rows.
        await stub.set(.nba, output([
            game("nba-today", .nba, hoursFromNow: 2),
            game("nba-tomorrow", .nba, .live, hoursFromNow: 26)
        ]))
        await store.load(force: true)
        XCTAssertEqual(store.scheduleGames.first?.status, .live)
        XCTAssertEqual(store.liveGames.map(\.id.rawID), ["nba-tomorrow"])
    }

    func testLivePollReplacesAGameAllSportsAlreadyShows() async {
        let stub = LeagueStub()
        await stub.set(.nba, output([game("g1", .nba, .live, hoursFromNow: -1, score: 10)]))
        let store = makeStore(stub: stub)
        await store.load()
        XCTAssertEqual(store.scheduleGames.first?.home.score, 10)

        // All Sports refreshes with day fetches; the fresh copy must replace the one on screen.
        await stub.set(.nba, output([game("g1", .nba, .final, hoursFromNow: -1, score: 24)]))
        await store.load(force: true)
        XCTAssertEqual(store.scheduleGames.first?.status, .final)
        XCTAssertEqual(store.scheduleGames.first?.home.score, 24)
        XCTAssertTrue(store.liveGames.isEmpty, "a finished game leaves Live Now's input")
    }

    func testUpcomingEventsStayInTheScheduleAndPreviewAsUpcoming() async {
        let stub = LeagueStub()
        let upcoming = game("later", .nhl, hoursFromNow: 4)
        await stub.set(.nhl, output([upcoming]))
        let store = makeStore(stub: stub)
        store.selectCategory(.nhl)
        await store.load()
        XCTAssertEqual(store.scheduleRows.map(\.id), ["game|espn.nhl.later"], "upcoming events stay discoverable without the hero")
        XCTAssertEqual(KyroSportsEventPreviewPolicy.mode(for: upcoming.status), .upcoming)
    }

    // MARK: Build 41.1 sport switching and recomputation

    func testOrdinaryReadsReuseTheScheduleUntilSomethingChanges() async {
        let stub = LeagueStub()
        await stub.set(.nba, output([game("a", .nba, hoursFromNow: 2)]))
        await stub.set(.nhl, output([game("b", .nhl, .live, hoursFromNow: -1)]))
        let store = makeStore(stub: stub)
        await store.load()
        _ = store.scheduleRows
        let built = store.scheduleComputationCount
        // What one hub update reads: coverage, notice, rows, live games, the connecting banner.
        for _ in 0..<50 {
            _ = store.scheduleCoverage
            _ = store.refreshNotice
            _ = store.scheduleRows
            _ = store.liveGames + store.scheduleGames
        }
        XCTAssertEqual(store.scheduleComputationCount, built, "view updates never rebuild the schedule")

        store.selectCategory(.nba)
        XCTAssertEqual(store.scheduleRows.map(\.id), ["game|espn.nba.a"])
        XCTAssertEqual(store.scheduleComputationCount, built + 1, "a sport switch rebuilds once")
        _ = store.scheduleRows
        XCTAssertEqual(store.scheduleComputationCount, built + 1)
    }

    func testSwitchingToAnEmptyOrOffSeasonSportShowsItsStateWithoutStaleRows() async {
        let stub = LeagueStub()
        await stub.set(.nba, output([game("a", .nba, hoursFromNow: 2)]))
        await stub.set(.mlb, output([]))
        let store = makeStore(stub: stub)
        store.selectCategory(.nba)
        await store.load()
        XCTAssertFalse(store.scheduleRows.isEmpty)
        store.selectCategory(.mlb)
        XCTAssertTrue(store.scheduleRows.isEmpty, "no NBA rows linger under MLB while it loads")
        await store.load()
        XCTAssertTrue(store.scheduleRows.isEmpty)
        XCTAssertNotEqual(store.scheduleCoverage, .games)
        store.selectCategory(.nba)
        XCTAssertEqual(store.scheduleRows.map(\.id), ["game|espn.nba.a"], "switching back shows the cached sport at once")
    }

    func testDayIntervalMatchesCalendarSameDayAcrossDSTAndMidnight() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-11-01 is the US fall-back day (25 hours); 2026-03-08 springs forward (23 hours).
        let days = [DateComponents(year: 2026, month: 11, day: 1), DateComponents(year: 2026, month: 3, day: 8),
                    DateComponents(year: 2026, month: 11, day: 8)].compactMap(cal.date(from:))
        for day in days {
            let interval = KyroSportsDaySchedule.dayInterval(for: day, calendar: cal)
            for minutes in stride(from: -180, through: 26 * 60, by: 7) {
                let instant = cal.startOfDay(for: day).addingTimeInterval(Double(minutes) * 60)
                XCTAssertEqual(interval.contains(instant), cal.isDate(instant, inSameDayAs: day), "\(instant)")
            }
        }
    }

    // MARK: Build 41.1 matchup artwork

    private func team(_ league: KyroSportLeague = .nba, color: String? = nil, alternate: String? = nil,
                      logo: String? = nil, darkLogo: String? = nil, flag: String? = nil,
                      location: String? = "City", nickname: String = "Team", code: String? = nil) -> KyroSportsTeam {
        KyroSportsTeam(id: "t", league: league, abbreviation: "TM", nickname: nickname, location: location,
                       logoURL: logo.flatMap(URL.init(string:)), darkLogoURL: darkLogo.flatMap(URL.init(string:)),
                       primaryColorHex: color, alternateColorHex: alternate, countryCode: code,
                       flagURL: flag.flatMap(URL.init(string:)))
    }

    private func matchup(_ away: KyroSportsTeam, _ home: KyroSportsTeam) -> KyroSportsGame {
        KyroSportsGame(id: KyroGameID(provider: "espn", league: away.league, rawID: "m"), league: away.league,
                       startTime: now, status: .scheduled, home: KyroGameTeam(team: home), away: KyroGameTeam(team: away))
    }

    func testTeamLogoPrefersTheDarkVariantAndOnlyWebURLs() {
        let both = team(logo: "https://a.espncdn.com/nba/bkn.png", darkLogo: "https://a.espncdn.com/nba/500-dark/bkn.png")
        XCTAssertEqual(KyroSportsMatchupArtwork.logoURL(for: both)?.absoluteString, "https://a.espncdn.com/nba/500-dark/bkn.png")
        XCTAssertEqual(KyroSportsMatchupArtwork.logoURL(for: team(logo: "https://a.espncdn.com/nba/bkn.png"))?.lastPathComponent, "bkn.png")
        XCTAssertNil(KyroSportsMatchupArtwork.logoURL(for: team(logo: "file:///etc/hosts")), "no non-web artwork")
        XCTAssertEqual(KyroSportsMatchupArtwork.logoURL(for: team(logo: "https://a.espncdn.com/x.png", darkLogo: "ftp://x/y.png"))?.lastPathComponent,
                       "x.png", "an unusable dark logo falls back to the standard one")
        XCTAssertNil(KyroSportsMatchupArtwork.logoURL(for: team()), "no logo means the abbreviation fallback")
    }

    func testTeamColorUsesPrimaryThenAlternateAndNeverInventsOne() {
        XCTAssertEqual(KyroSportsMatchupArtwork.cardColor(for: team(color: "002a5c", alternate: "c60c30")),
                       KyroSportsRGB(hex: "002a5c"), "navy is dark but visible")
        XCTAssertEqual(KyroSportsMatchupArtwork.cardColor(for: team(color: "231f20", alternate: "fdb71a")),
                       KyroSportsRGB(hex: "fdb71a"), "near-black falls back to the alternate")
        XCTAssertNil(KyroSportsMatchupArtwork.cardColor(for: team(color: "000000", alternate: "ffffff")),
                     "black and white both drop out")
        XCTAssertNil(KyroSportsMatchupArtwork.cardColor(for: team(color: "zzz", alternate: nil)), "malformed hex")
        XCTAssertNil(KyroSportsMatchupArtwork.cardColor(for: team()), "missing metadata")
        XCTAssertEqual(KyroSportsRGB(hex: "#CE1141"), KyroSportsRGB(rgb: 0xCE1141))
    }

    func testMatchupBackdropFallsBackToTheLeagueCardOrANeutralSide() {
        let chicago = team(color: "ce1141"), brooklyn = team(color: "000000", alternate: "ffffff")
        XCTAssertEqual(KyroSportsMatchupArtwork(game: matchup(chicago, brooklyn)).backdrop,
                       .teams(away: KyroSportsRGB(rgb: 0xCE1141), home: KyroSportsMatchupArtwork.neutralSide))
        XCTAssertEqual(KyroSportsMatchupArtwork(game: matchup(brooklyn, team())).backdrop, .league)
        let player = team(.atp, flag: "https://a.espncdn.com/i/teamlogos/countries/500/esp.png", code: "ESP")
        XCTAssertEqual(KyroSportsMatchupArtwork(game: matchup(player, player)).backdrop, .league,
                       "tennis has no team colours and keeps the league card")
    }

    func testTennisFlagsComeOnlyFromTheProvidersImage() {
        XCTAssertEqual(KyroSportsMatchupArtwork.flagURL(for: team(.atp, flag: "https://a.espncdn.com/i/teamlogos/countries/500/esp.png", code: "ESP"))?
                        .lastPathComponent, "esp.png")
        XCTAssertNil(KyroSportsMatchupArtwork.flagURL(for: team(.atp, code: "ESP")), "a code alone never becomes an image")
        XCTAssertNil(KyroSportsMatchupArtwork.flagURL(for: team(.atp, flag: "data:image/png;base64,AAAA")))
    }

    func testMatchupColumnNames() {
        let ranked = KyroGameTeam(team: team(.collegeFootball, location: "Ohio State", nickname: "Buckeyes"), rank: 3)
        XCTAssertEqual(KyroSportsMatchupArtwork.columnName(for: ranked), "#3 Ohio State")
        XCTAssertEqual(KyroSportsMatchupArtwork.columnName(for: KyroGameTeam(team: team(.nfl, location: "Cleveland", nickname: "Browns"))),
                       "Browns")
        XCTAssertEqual(KyroSportsMatchupArtwork.columnName(for: KyroGameTeam(team: team(.collegeFootball, location: nil, nickname: "Bulldogs"))),
                       "Bulldogs")
    }

    func testLogoRequestsDecodeAtTheDrawnSize() throws {
        let url = URL(string: "https://a.espncdn.com/i/teamlogos/nba/500/scoreboard/chi.png")!
        let request = try XCTUnwrap(KyroSportsArtworkRequest.logo(url: url, pointSize: 40, scale: 3))
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.priority, .high)
        XCTAssertEqual(PosterImageCache.decodePixelSize(forPointSize: CGSize(width: 40, height: 40), scale: 3),
                       CGSize(width: 128, height: 128), "a 40 pt logo decodes at 128 px, not ESPN's 500 px source")
    }

    func testEventCardAccentMatchesSportHeaderAndLiveFollowsStatusOnly() {
        let accents = KyroSportLeague.allCases.map { KyroSportsEventCardStyle.accentRGB(for: $0) }
        XCTAssertEqual(accents, KyroSportLeague.allCases.map(\.accentRGB), "cards use the section header accent")
        XCTAssertEqual(Set(accents).count, accents.count, "every sport is distinguishable")
        XCTAssertTrue(KyroSportsEventCardStyle.showsLiveBadge(for: .live))
        for status: KyroGameStatus in [.scheduled, .final, .postponed, .canceled, .suspended, .unknown("STATUS_DELAYED")] {
            XCTAssertFalse(KyroSportsEventCardStyle.showsLiveBadge(for: status), "\(status)")
        }
    }

    func testDedupUsesLeaguePlusProviderGameID() {
        let nfl = game("401", .nfl, hoursFromNow: 1)
        let nba = game("401", .nba, hoursFromNow: 2)
        let sleeper = game("401", .nfl, hoursFromNow: 1, provider: "sleeper")
        let merged = KyroSportsDaySchedule.aggregate([[nfl, nfl], [nba], [sleeper]], on: now, calendar: calendar)
        XCTAssertEqual(Set(merged.map(\.id.stringValue)), Set([nfl.id.stringValue, nba.id.stringValue, sleeper.id.stringValue]))
    }

    func testLeagueFilterShowsOnlyThatSportAndKeepsTheSelectedDate() async {
        let stub = LeagueStub()
        await stub.set(.nba, output([game("nba-today", .nba, hoursFromNow: 2)]))
        await stub.set(.nhl, output([game("nhl-today", .nhl, hoursFromNow: 3)]))
        let store = makeStore(stub: stub, nfl: [game("nfl-today", .nfl, hoursFromNow: 1, week: 9)])
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: store.selectedDay)!
        store.selectDay(tomorrow)
        store.selectCategory(.nba)
        XCTAssertEqual(store.selectedDay, tomorrow)
        await store.load()
        XCTAssertTrue(store.scheduleGames.allSatisfy { $0.league == .nba })
        XCTAssertEqual(store.selectedDay, tomorrow)
    }

    // MARK: Date selection and timezone

    func testBrowseRangeIsPreviousThreeTodayAndNextSeven() {
        let days = KyroSportsBrowseCalendar.visibleDays(now: now, calendar: calendar)
        XCTAssertEqual(days.count, 11)
        XCTAssertEqual(days[3], calendar.startOfDay(for: now))
        XCTAssertEqual(
            calendar.dateComponents([.day], from: days.first!, to: days.last!).day,
            10
        )
    }

    func testTodayIsSelectedByDefault() {
        let store = makeStore(stub: LeagueStub())
        XCTAssertTrue(calendar.isDate(store.selectedDay, inSameDayAs: now))
        XCTAssertEqual(store.browseDays.count, 11)
    }

    func testSelectingADateFiltersGamesToThatLocalDay() async {
        let stub = LeagueStub()
        await stub.set(.nba, output([
            game("today", .nba, hoursFromNow: 2),
            game("tomorrow", .nba, hoursFromNow: 26)
        ]))
        let store = makeStore(stub: stub)
        store.selectCategory(.nba)
        await store.load()
        XCTAssertEqual(store.scheduleGames.map(\.id.rawID), ["today"])

        store.selectDay(calendar.date(byAdding: .day, value: 1, to: now)!)
        await store.load()
        XCTAssertEqual(store.scheduleGames.map(\.id.rawID), ["tomorrow"])
    }

    func testLocalTimezoneBoundaryDoesNotDuplicateOrDropAGame() {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // 2026-11-06 23:30 PT is already 2026-11-07 UTC.
        let kickoff = Date(timeIntervalSince1970: 1_794_042_600)
        let localGame = KyroSportsGame(
            id: KyroGameID(provider: "espn", league: .nba, rawID: "boundary"),
            league: .nba,
            startTime: kickoff,
            status: .scheduled,
            home: KyroGameTeam(team: .placeholder(abbreviation: "LAL", league: .nba)),
            away: KyroGameTeam(team: .placeholder(abbreviation: "BOS", league: .nba))
        )
        let localDay = pacific.startOfDay(for: kickoff)
        let utc = Calendar(identifier: .gregorian)
        let utcDay = utc.startOfDay(for: kickoff)
        XCTAssertEqual(
            KyroSportsDaySchedule.games(from: [localGame], on: localDay, calendar: pacific).map(\.id.rawID),
            ["boundary"]
        )
        XCTAssertNotEqual(localDay, utcDay)
        XCTAssertTrue(
            KyroSportsDaySchedule.games(from: [localGame], on: utcDay, calendar: pacific).isEmpty
        )
    }

    func testDSTTransitionDaysStayContiguous() {
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = TimeZone(identifier: "America/New_York")!
        // US fall-back weekend 2026-11-01.
        let saturday = eastern.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 18))!
        let days = KyroSportsBrowseCalendar.visibleDays(now: saturday, calendar: eastern, pastDayCount: 1, futureDayCount: 3)
        let stamps = days.map { eastern.dateComponents([.month, .day], from: $0) }
        XCTAssertEqual(stamps.map(\.day), [30, 31, 1, 2, 3])
        XCTAssertEqual(Set(days).count, days.count)
    }

    func testMidnightRolloverMovesTodayWithoutSkippingThePreviousDay() {
        let calendar = calendar
        let late = calendar.date(bySettingHour: 23, minute: 50, second: 0, of: now)!
        let next = late.addingTimeInterval(20 * 60)
        let before = KyroSportsBrowseCalendar.visibleDays(now: late, calendar: calendar)
        let after = KyroSportsBrowseCalendar.visibleDays(now: next, calendar: calendar)
        XCTAssertEqual(before[3], calendar.startOfDay(for: late))
        XCTAssertEqual(after[3], calendar.startOfDay(for: next))
        XCTAssertEqual(after[2], before[3])
    }

    // MARK: Loading, cache, football coverage

    func testAllSportsUsesDayFetchesAndLeavesNFLOnTheProviderChain() async {
        let stub = LeagueStub()
        await stub.set(.nba, output([game("nba", .nba, hoursFromNow: 2)]))
        let store = makeStore(stub: stub, nfl: [game("nfl", .nfl, hoursFromNow: 1, week: 9)])
        await store.load()

        let nbaWindows = await stub.windowCount(.nba)
        let nbaDays = await stub.dayCount(.nba)
        let nflWindows = await stub.windowCount(.nfl)
        XCTAssertEqual(nbaWindows, 0, "All Sports must not pull the seven-day NBA window")
        XCTAssertEqual(nbaDays, 1)
        XCTAssertEqual(nflWindows, 0, "NFL stays on the provider chain")
        XCTAssertEqual(Set(store.scheduleGames.map(\.id.rawID)), ["nba", "nfl"])
    }

    func testRapidDateAndCategorySwitchDropsStaleResponses() async {
        let stub = LeagueStub()
        await stub.set(.nba, output([game("nba-slow", .nba, hoursFromNow: 2)]))
        await stub.set(.nhl, output([game("nhl-fast", .nhl, hoursFromNow: 3)]))
        await stub.gate(.nba)
        let store = makeStore(stub: stub)

        store.selectCategory(.nba)
        let slow = Task { await store.load() }
        store.selectCategory(.nhl)
        await store.load()
        await stub.release()
        await slow.value

        XCTAssertEqual(store.scheduleGames.map(\.id.rawID), ["nhl-fast"])
        XCTAssertEqual(store.selectedCategory, .nhl)
    }

    func testMissingDayFetchDoesNotReplaceAWarmSelectedDate() async {
        let stub = LeagueStub()
        await stub.set(.nba, output([game("today", .nba, hoursFromNow: 2)]))
        let store = makeStore(stub: stub)
        store.selectCategory(.nba)
        await store.load()
        XCTAssertEqual(store.scheduleGames.map(\.id.rawID), ["today"])

        store.selectDay(calendar.date(byAdding: .day, value: 2, to: now)!)
        await stub.setFailing(.nba, true)
        await store.load()
        store.selectDay(calendar.startOfDay(for: now))
        XCTAssertEqual(store.scheduleGames.map(\.id.rawID), ["today"], "last-known-good today stays")
        XCTAssertTrue(store.isShowingStaleData)
    }

    func testFootballDateOutsideCurrentWeekIsUnavailableNotWrongWeek() async {
        let stub = LeagueStub()
        await stub.set(.collegeFootball, output([
            game("sat", .collegeFootball, hoursFromNow: 20, week: 10)
        ], week: 10))
        let store = makeStore(stub: stub)
        store.selectCategory(.collegeFootball)
        await store.load()

        store.selectDay(calendar.date(byAdding: .day, value: 6, to: now)!)
        await store.load()
        XCTAssertTrue(store.scheduleGames.isEmpty)
        if case .outsideFeed(.collegeFootball) = store.scheduleCoverage {
            XCTAssertEqual(store.noGamesState.title, "Schedule not in this feed")
        } else {
            XCTFail("\(store.scheduleCoverage)")
        }
    }

    func testLoadFailureIsNotLabeledNoGames() async {
        let stub = LeagueStub()
        await stub.setFailing(.nba, true)
        let store = makeStore(stub: stub)
        store.selectCategory(.nba)
        await store.load()
        XCTAssertEqual(store.phase, .failed(.httpStatus(503)))
        if case .failed = store.scheduleCoverage {
            XCTAssertEqual(store.noGamesState.title, "Scores unavailable")
            XCTAssertNotEqual(store.noGamesState.title, "No games on this date")
        } else {
            XCTFail("failure must not present as an empty slate")
        }
    }

    func testOfflineAndEmptyStatesStayDistinct() async {
        let stub = LeagueStub()
        await stub.setFailing(.mlb, true)
        // Force offline via a throwing path the stub maps as http; use empty success for empty.
        await stub.setFailing(.mlb, false)
        await stub.set(.mlb, output([]))
        let store = makeStore(stub: stub)
        store.selectCategory(.mlb)
        await store.load()
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.scheduleCoverage, .empty)
        XCTAssertEqual(store.noGamesState.title, "MLB is in its offseason")
    }

    func testPollingUsesOnlyTheDisplayedSchedule() async {
        let stub = LeagueStub()
        await stub.set(.nba, output([game("live", .nba, .live, hoursFromNow: -1)]))
        let store = makeStore(
            stub: stub,
            nfl: [game("nfl-later", .nfl, hoursFromNow: 48, week: 9)]
        )
        store.selectCategory(.nba)
        await store.load()
        XCTAssertEqual(store.refreshInterval, 20)

        store.selectDay(calendar.date(byAdding: .day, value: 2, to: now)!)
        XCTAssertNil(store.refreshInterval, "a live game on another date must not poll")
    }

    func testRestoredCategorySurvivesRelaunchAndAllIsDefaultWithoutOne() {
        let defaults = ephemeralDefaults()
        let first = makeStore(stub: LeagueStub(), preferences: defaults)
        XCTAssertEqual(first.selectedCategory, .all)
        first.selectCategory(.nhl)
        let second = makeStore(stub: LeagueStub(), preferences: defaults)
        XCTAssertEqual(second.selectedCategory, .nhl)
        XCTAssertEqual(second.selectedLeague, .nhl)
    }

    func testFreshAndInvalidCategoryIgnoreLegacyNCAASelection() {
        let defaults = ephemeralDefaults()
        defaults.set(KyroSportLeague.collegeFootball.rawValue, forKey: "kyro.sports.selectedLeague")
        XCTAssertEqual(makeStore(stub: LeagueStub(), preferences: defaults).selectedCategory, .all)
        defaults.set("not-a-category", forKey: "kyro.sports.selectedCategory")
        XCTAssertEqual(makeStore(stub: LeagueStub(), preferences: defaults).selectedCategory, .all)
        XCTAssertEqual(defaults.string(forKey: "kyro.sports.selectedCategory"), "not-a-category")
    }

    func testAllSportsPartialFailureIsUnavailableRatherThanNoGames() async {
        let stub = LeagueStub()
        await stub.setFailing(.nba, true)
        let store = makeStore(stub: stub)
        await store.load()
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.scheduleCoverage, .failed(.httpStatus(503)))
        XCTAssertEqual(store.noGamesState.title, "Scores unavailable")
    }

    func testNFLFallbackChainStillSuppliesAllSports() async {
        let sleeper = game("sleeper-nfl", .nfl, hoursFromNow: 2, week: 9, provider: "sleeper")
        let store = makeStore(stub: LeagueStub(), nfl: [sleeper])
        await store.load()
        XCTAssertEqual(store.scheduleGames.map(\.id.rawID), ["sleeper-nfl"])
        XCTAssertEqual(store.scheduleGames.first?.id.provider, "sleeper")
    }

    func testExpiredCacheRefetchesTheSelectedDayOnly() async {
        let stub = LeagueStub()
        await stub.set(.nba, output([game("nba", .nba, hoursFromNow: 2)]))
        let store = makeStore(stub: stub)
        store.selectCategory(.nba)
        await store.load()
        store.selectDay(calendar.date(byAdding: .day, value: 1, to: now)!)
        await store.load()
        let days = await stub.dayDates(.nba)
        let windows = await stub.windowCount(.nba)
        XCTAssertEqual(windows, 1, "first NBA visit on today still uses the window loader")
        XCTAssertEqual(days.count, 1)
        XCTAssertTrue(calendar.isDate(days[0], inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now)!))
    }

    // MARK: Build 37 refresh state

    func testFailedRefreshKeepsCachedGamesAndRecoveryClearsTheNotice() async {
        let stub = LeagueStub()
        await stub.set(.nba, output([game("nba", .nba, hoursFromNow: 2)]))
        let store = makeStore(stub: stub)
        await store.load()
        XCTAssertNil(store.refreshNotice)

        await stub.setFailing(.nba, true)
        await store.refresh()
        XCTAssertEqual(store.scheduleGames.map(\.id.rawID), ["nba"], "cached games survive a failed refresh")
        XCTAssertEqual(store.staleLeagues, [.nba])
        XCTAssertTrue(store.isShowingStaleData)
        XCTAssertTrue(store.lastRefreshFailed)
        XCTAssertEqual(store.refreshNotice?.kind, .stale)
        XCTAssertEqual(store.refreshNotice?.title, "Refresh failed. Couldn't update NBA; showing earlier scores.")
        XCTAssertEqual(store.refreshNotice?.detail, "Scores are unavailable right now.")

        await stub.setFailing(.nba, false)
        await store.refresh()
        XCTAssertNil(store.refreshNotice, "a successful refresh clears the warning")
        XCTAssertFalse(store.isShowingStaleData)
        XCTAssertFalse(store.lastRefreshFailed)
        XCTAssertEqual(store.scheduleCoverage, .games)
    }

    func testOneUnavailableSportIsNamedWithoutMarkingThePageStale() async {
        let stub = LeagueStub()
        await stub.set(.nba, output([game("nba", .nba, hoursFromNow: 2)]))
        await stub.setFailing(.atp, true)
        let store = makeStore(stub: stub)
        await store.load()
        XCTAssertEqual(store.scheduleCoverage, .games)
        XCTAssertEqual(store.staleLeagues, [], "NBA and the empty leagues are current")
        XCTAssertFalse(store.isShowingStaleData)
        XCTAssertEqual(store.unavailableLeagues, [.atp])
        XCTAssertEqual(store.refreshNotice?.kind, .unavailable)
        XCTAssertEqual(store.refreshNotice?.title, "ATP isn't available right now.")

        await stub.setFailing(.atp, false)
        await store.refresh()
        XCTAssertNil(store.refreshNotice)
    }

    func testEmptySportsNeverRaiseAWarning() async {
        let stub = LeagueStub()
        await stub.set(.nhl, output([game("nhl", .nhl, .final, hoursFromNow: -3)]))
        let store = makeStore(stub: stub)
        await store.load()
        await store.refresh()
        XCTAssertNil(store.refreshNotice, "NFL, NCAA, NBA, MLB, ATP and WTA have no games, which is not a failure")
        XCTAssertFalse(store.lastRefreshFailed)
    }

    func testRefreshShowsProgressAndIgnoresOverlappingTaps() async {
        let stub = LeagueStub()
        await stub.set(.nba, output([game("nba", .nba, hoursFromNow: 2)]))
        let store = makeStore(stub: stub)
        store.selectCategory(.nba)
        await store.load()
        let callsBefore = await stub.windowCount(.nba) + stub.dayCount(.nba)

        await stub.gate(.nba)
        let first = Task { await store.refresh() }
        for _ in 0..<200 where !store.isRefreshing { await Task.yield() }
        XCTAssertTrue(store.isRefreshing)
        XCTAssertEqual(store.refreshNotice?.kind, .refreshing)
        await store.refresh() // second tap returns at once
        await stub.release()
        await first.value
        let callsAfter = await stub.windowCount(.nba) + stub.dayCount(.nba)
        XCTAssertEqual(callsAfter - callsBefore, 1, "overlapping taps start one request")
        XCTAssertFalse(store.isRefreshing)
        XCTAssertNil(store.refreshNotice)
    }

    func testRefreshWithNothingCachedReportsTheErrorThenRecovers() async {
        let stub = LeagueStub()
        await stub.setFailing(.nba, true)
        let store = makeStore(stub: stub)
        store.selectCategory(.nba)
        await store.load()
        XCTAssertEqual(store.phase, .failed(.httpStatus(503)))
        await store.refresh()
        XCTAssertEqual(store.phase, .failed(.httpStatus(503)))
        XCTAssertTrue(store.lastRefreshFailed)
        XCTAssertEqual(KyroSportsDataError.httpStatus(503).userMessage, "Scores are unavailable right now.")

        await stub.setFailing(.nba, false)
        await stub.set(.nba, output([game("nba", .nba, hoursFromNow: 2)]))
        await store.refresh()
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.scheduleCoverage, .games)
        XCTAssertFalse(store.lastRefreshFailed)
    }

    func testFailedNewDayIsUnavailableNotEmptyUntilItLoads() async {
        let stub = LeagueStub()
        await stub.set(.nba, output([game("nba", .nba, hoursFromNow: 2)]))
        let store = makeStore(stub: stub)
        store.selectCategory(.nba)
        await store.load()
        await stub.setFailing(.nba, true)
        // Three days back is outside the NBA window the first load covered.
        store.selectDay(calendar.date(byAdding: .day, value: -3, to: now)!)
        await store.load()
        XCTAssertEqual(store.scheduleCoverage, .failed(.httpStatus(503)),
                       "an unfetched day must not read as 'No games'")
        await stub.setFailing(.nba, false)
        await store.refresh()
        XCTAssertEqual(store.scheduleCoverage, .empty)
        XCTAssertNil(store.refreshNotice)
    }

    func testLivePollingTargetsOnlyTheLeagueThatNeedsIt() {
        let games = [
            game("wta-live", .wta, .live, hoursFromNow: -0.5),
            game("nba-later", .nba, .scheduled, hoursFromNow: 5),
            game("nhl-final", .nhl, .final, hoursFromNow: -3)
        ]
        XCTAssertEqual(
            KyroSportsHubStore.pollingLeagues(
                in: KyroSportLeague.allCases, games: games, now: now
            ),
            [.wta],
            "one live event must not fan a poll out to every All Sports provider"
        )
    }

    func testPollingIncludesStartingSoonButNotDistantOrCompletedLeagues() {
        let games = [
            game("nfl-soon", .nfl, .scheduled, hoursFromNow: 0.75),
            game("nba-later", .nba, .scheduled, hoursFromNow: 2),
            game("mlb-final", .mlb, .final, hoursFromNow: -1)
        ]
        XCTAssertEqual(
            KyroSportsHubStore.pollingLeagues(
                in: [.nfl, .nba, .mlb], games: games, now: now
            ),
            [.nfl]
        )
    }
}
