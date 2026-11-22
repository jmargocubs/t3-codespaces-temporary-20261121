import Foundation
import XCTest
@testable import Silo

/// Dashboard policy: featured event, default and visible modes, empty states,
/// schedule windows, ordering, and mode stability across refreshes.
@MainActor
final class KyroSportsDashboardTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_792_152_000) // 2026-10-16 12:00 UTC (Friday)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func game(
        _ id: String,
        _ status: KyroGameStatus,
        hoursFromNow: Double,
        away: String = "DEN",
        home: String = "KC",
        league: KyroSportLeague = .nfl,
        week: Int? = 9,
        season: Int = 2026
    ) -> KyroSportsGame {
        KyroSportsGame(
            id: KyroGameID(provider: "espn", league: league, rawID: id),
            league: league,
            season: season,
            seasonType: .regular,
            week: week,
            startTime: now.addingTimeInterval(hoursFromNow * 3600),
            status: status,
            home: KyroGameTeam(team: .placeholder(abbreviation: home, league: league), score: status.isScheduled ? nil : 10),
            away: KyroGameTeam(team: .placeholder(abbreviation: away, league: league), score: status.isScheduled ? nil : 7)
        )
    }

    private func sections(
        _ games: [KyroSportsGame],
        at date: Date? = nil,
        context: KyroSportsScheduleContext = KyroSportsScheduleContext(
            league: .nfl,
            currentWeek: 9,
            currentSeason: 2026
        )
    ) -> [KyroSportsGameSection] {
        KyroSportsSectioning.sections(
            from: games,
            now: date ?? now,
            calendar: calendar,
            context: context
        )
    }

    // MARK: Featured event

    func testSportFilterOptionsAreStableAndBounded() {
        let first = KyroSportsCategory.filterOrder
        let second = KyroSportsCategory.filterOrder
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, KyroSportsCategory.allCases.count)
        XCTAssertEqual(first.first, .all)
        XCTAssertEqual(Set(first).count, first.count)
    }

    func testFeaturedEventPrefersLiveOverUpcomingAndFinal() {
        let result = sections([
            game("final", .final, hoursFromNow: -30),
            game("soon", .scheduled, hoursFromNow: 3),
            game("live", .live, hoursFromNow: -1)
        ])
        XCTAssertEqual(KyroSportsDashboard.featuredEvent(from: result, now: now)?.id.rawID, "live")
    }

    func testFeaturedEventIsNextUpcomingWhenNothingIsLive() {
        let result = sections([
            game("final", .final, hoursFromNow: -30),
            game("later", .scheduled, hoursFromNow: 60, week: 9),
            game("next", .scheduled, hoursFromNow: 30, week: 9)
        ])
        XCTAssertEqual(KyroSportsDashboard.featuredEvent(from: result, now: now)?.id.rawID, "next")
    }

    func testFeaturedEventIgnoresGamesOutsideVisibleSchedule() {
        let result = sections([
            game("far", .scheduled, hoursFromNow: 24 * 14, week: 11),
            game("next", .scheduled, hoursFromNow: 30, week: 9)
        ])
        XCTAssertEqual(KyroSportsDashboard.featuredEvent(from: result, now: now)?.id.rawID, "next")
        XCTAssertTrue(KyroSportsDashboard.hasFutureGames(in: result))
    }

    func testFeaturedEventFallsBackToMostRecentFinalOnlyWhenNoLiveOrUpcoming() {
        let result = sections([
            game("older", .final, hoursFromNow: -72),
            game("recent", .final, hoursFromNow: -30)
        ])
        XCTAssertEqual(KyroSportsDashboard.featuredEvent(from: result, now: now)?.id.rawID, "recent")
    }

    func testFeaturedEventIsNilWithoutGames() {
        XCTAssertNil(KyroSportsDashboard.featuredEvent(from: [], now: now))
    }

    // MARK: Default mode and visibility

    func testDefaultModeIsLiveOnlyWhenGamesAreLive() {
        let live = sections([game("a", .live, hoursFromNow: -1), game("b", .scheduled, hoursFromNow: 30)])
        let quiet = sections([game("b", .scheduled, hoursFromNow: 30), game("c", .final, hoursFromNow: -30)])
        XCTAssertEqual(KyroSportsDashboard.defaultMode(for: live), .live)
        XCTAssertEqual(KyroSportsDashboard.defaultMode(for: quiet), .upcoming)
    }

    func testResultsAreHiddenUnlessResultsModeIsSelected() {
        let result = sections([
            game("final", .final, hoursFromNow: -30),
            game("next", .scheduled, hoursFromNow: 30)
        ])
        let upcoming = KyroSportsDashboard.visibleSections(from: result, mode: .upcoming)
        XCTAssertFalse(upcoming.contains { $0.bucket == .recent })
        let results = KyroSportsDashboard.visibleSections(from: result, mode: .results)
        XCTAssertEqual(results.map(\.bucket), [.recent])
    }

    func testNoGameAppearsInMoreThanOneVisibleSection() {
        let result = sections([
            game("live", .live, hoursFromNow: -1),
            game("today", .scheduled, hoursFromNow: 2),
            game("final", .final, hoursFromNow: -30),
            game("next", .scheduled, hoursFromNow: 30),
            game("far", .scheduled, hoursFromNow: 24 * 30, week: 14)
        ])
        let all = result.flatMap(\.games).map(\.id)
        XCTAssertEqual(all.count, Set(all).count, "a game must live in exactly one bucket")

        var seen = Set<KyroGameID>()
        for mode in KyroSportsDashboardMode.allCases {
            for section in KyroSportsDashboard.visibleSections(from: result, mode: mode) {
                for game in section.games {
                    XCTAssertTrue(seen.insert(game.id).inserted, "\(game.id) shown under two modes")
                }
            }
        }
    }

    func testLaterWeekGamesRemainCachedButAreNotListed() {
        let result = sections([
            game("next", .scheduled, hoursFromNow: 30, week: 9),
            game("far", .scheduled, hoursFromNow: 24 * 14, week: 11)
        ])
        XCTAssertTrue(KyroSportsDashboard.hasFutureGames(in: result))
        let upcoming = KyroSportsDashboard.visibleSections(from: result, mode: .upcoming)
        XCTAssertFalse(upcoming.flatMap(\.games).contains { $0.id.rawID == "far" })
        XCTAssertTrue(result.flatMap(\.games).contains { $0.id.rawID == "far" })
    }

    // MARK: NFL week window

    func testNFLUpcomingShowsOnlyCurrentWeekIncludingThursdayThroughMonday() {
        // Friday "now": TNF (-22h), Sunday (+50h), MNF (+74h) are week 9.
        let result = sections([
            game("tnf", .scheduled, hoursFromNow: -22, week: 9), // Thursday prior — same local day window if still scheduled unlikely; use Sunday/Mon
            game("sun", .scheduled, hoursFromNow: 50, week: 9),
            game("mnf", .scheduled, hoursFromNow: 74, week: 9),
            game("nextThu", .scheduled, hoursFromNow: 24 * 6, week: 10)
        ])
        let visible = KyroSportsDashboard.visibleSections(from: result, mode: .upcoming)
            .flatMap(\.games).map(\.id.rawID)
        XCTAssertEqual(Set(visible), Set(["sun", "mnf"]))
        XCTAssertTrue(result.contains { $0.bucket == .future && $0.games.contains { $0.id.rawID == "nextThu" } })
    }

    func testNFLByeWeekStillListsOtherCurrentWeekGames() {
        // Week 9 has a short slate (bye-heavy); week 10 stays hidden.
        let result = sections([
            game("only", .scheduled, hoursFromNow: 48, away: "CHI", home: "GB", week: 9),
            game("next", .scheduled, hoursFromNow: 24 * 8, week: 10)
        ])
        let visible = KyroSportsDashboard.visibleSections(from: result, mode: .upcoming)
            .flatMap(\.games).map(\.id.rawID)
        XCTAssertEqual(visible, ["only"])
        XCTAssertTrue(KyroSportsDashboard.hasFutureGames(in: result))
    }

    func testNFLSeasonTransitionKeepsNextSeasonOutOfCurrentWeek() {
        let result = sections(
            [
                game("wk18", .scheduled, hoursFromNow: 30, week: 18, season: 2026),
                game("wk1next", .scheduled, hoursFromNow: 24 * 20, week: 1, season: 2027)
            ],
            context: KyroSportsScheduleContext(league: .nfl, currentWeek: 18, currentSeason: 2026)
        )
        let visible = KyroSportsDashboard.visibleSections(from: result, mode: .upcoming)
            .flatMap(\.games).map(\.id.rawID)
        XCTAssertEqual(visible, ["wk18"])
        XCTAssertTrue(result.flatMap(\.games).contains { $0.id.rawID == "wk1next" })
        XCTAssertFalse(visible.contains("wk1next"))
    }

    func testNFLWeekBoundsUseLocalThursdayThroughMonday() {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // Monday 2026-10-12 20:00 PDT — still inside week opened Thursday 10/08 local.
        let mondayEvening = Date(timeIntervalSince1970: 1_791_860_400)
        let bounds = KyroSportsSectioning.nflGameWeekBounds(containing: mondayEvening, calendar: pacific)
        XCTAssertEqual(pacific.component(.weekday, from: bounds.start), 5, "week opens Thursday local")
        let endWeekday = pacific.component(.weekday, from: bounds.endExclusive)
        XCTAssertEqual(endWeekday, 3, "exclusive end is Tuesday local")
        XCTAssertLessThan(mondayEvening, bounds.endExclusive)
        XCTAssertGreaterThanOrEqual(mondayEvening, bounds.start)
    }

    func testNFLFallsBackToLocalWeekBoundsWhenWeekMetadataIsMissing() {
        let result = sections(
            [
                game("meta", .scheduled, hoursFromNow: 30, week: nil),
                game("far", .scheduled, hoursFromNow: 24 * 20, week: nil)
            ],
            context: KyroSportsScheduleContext(league: .nfl, currentWeek: nil, currentSeason: 2026)
        )
        let visible = Set(
            KyroSportsDashboard.visibleSections(from: result, mode: .upcoming).flatMap(\.games).map(\.id.rawID)
        )
        XCTAssertEqual(visible, ["meta"])
        XCTAssertTrue(KyroSportsDashboard.hasFutureGames(in: result))
    }

    // MARK: Other leagues

    func testOtherLeaguesUseRollingSevenDayUpcomingWindow() {
        let context = KyroSportsScheduleContext(league: .nba)
        let result = sections(
            [
                game("today", .scheduled, hoursFromNow: 2, league: .nba, week: nil),
                game("day6", .scheduled, hoursFromNow: 24 * 6 + 2, league: .nba, week: nil),
                game("day7", .scheduled, hoursFromNow: 24 * 7 + 2, league: .nba, week: nil)
            ],
            context: context
        )
        let visible = Set(
            KyroSportsDashboard.visibleSections(from: result, mode: .upcoming).flatMap(\.games).map(\.id.rawID)
        )
        XCTAssertEqual(visible, Set(["today", "day6"]))
        XCTAssertTrue(result.flatMap(\.games).contains { $0.id.rawID == "day7" })
        XCTAssertFalse(visible.contains("day7"))
    }

    // MARK: Empty states

    func testEmptyStatesAppearOnlyForEmptyModes() {
        let result = sections([game("next", .scheduled, hoursFromNow: 30)])
        XCTAssertNil(KyroSportsDashboard.emptyState(for: .upcoming, in: result))
        XCTAssertNotNil(KyroSportsDashboard.emptyState(for: .live, in: result))
        XCTAssertNotNil(KyroSportsDashboard.emptyState(for: .results, in: result))
        XCTAssertNotNil(KyroSportsDashboard.emptyState(for: .upcoming, in: []))
    }

    // MARK: Ordering and transitions

    func testUpcomingSectionsAreInDateOrder() {
        let result = sections([
            game("c", .scheduled, hoursFromNow: 70, week: 9),
            game("a", .scheduled, hoursFromNow: 30, week: 9),
            game("b", .scheduled, hoursFromNow: 55, week: 9)
        ])
        let days = result.filter { $0.bucket == .upcoming }.compactMap(\.localDay)
        XCTAssertEqual(days, days.sorted())
        XCTAssertEqual(
            result.filter { $0.bucket == .upcoming }.flatMap(\.games).map(\.id.rawID),
            ["a", "b", "c"]
        )
    }

    func testGameMovesBetweenBucketsAsStatusChanges() {
        func bucket(_ status: KyroGameStatus, hours: Double) -> KyroSportsGameBucket? {
            sections([game("g", status, hoursFromNow: hours)]).first?.bucket
        }
        XCTAssertEqual(bucket(.scheduled, hours: 30), .upcoming)
        XCTAssertEqual(bucket(.live, hours: -0.5), .liveNow)
        XCTAssertEqual(bucket(.final, hours: -4), .recent)
    }

    func testResultsKeepSevenDayHistoryIndependentOfUpcomingWindow() {
        let result = sections([
            game("fresh", .final, hoursFromNow: -24),
            game("old", .final, hoursFromNow: -24 * 8)
        ])
        let results = KyroSportsDashboard.visibleSections(from: result, mode: .results)
            .flatMap(\.games).map(\.id.rawID)
        XCTAssertEqual(results, ["fresh"])
    }

    // MARK: Selection across refreshes

    private struct StubProvider: KyroSportsProviding {
        let providerID = "stub"
        let games: [KyroSportsGame]
        func fetchNFLWindow(now: Date, force: Bool) async throws -> KyroSportsProviderOutput {
            KyroSportsProviderOutput(provider: providerID, games: games, season: 2026, week: 9, refreshError: nil)
        }
    }

    func testSelectedModeSurvivesRefreshAndInitialModeResolvesOnce() async {
        let liveGames = [game("live", .live, hoursFromNow: -1), game("next", .scheduled, hoursFromNow: 30)]
        let store = KyroSportsHubStore(
            providers: [StubProvider(games: liveGames)],
            calendar: calendar,
            now: { [now] in now }
        )
        await store.load()
        XCTAssertEqual(store.selectedDashboardMode, .live, "live games choose Live first")

        store.selectDashboardMode(.results)
        await store.load(force: true)
        XCTAssertEqual(store.selectedDashboardMode, .results, "a refresh must not reset the user's choice")
    }
}
