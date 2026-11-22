import Foundation
import XCTest
@testable import Silo

/// Build 61: the Sports Feed returns exactly where it was left when Game, Stats or News covered it,
/// and the first load of a day says "loading" rather than "not loaded yet, try again".
@MainActor
final class KyroSportsFeedScrollTests: XCTestCase {
    // MARK: Feed position

    /// Build 60 recording (323.1–324.0 s): the Feed was still coasting when Game was tapped and
    /// came back at the top. Leaving now freezes it at the offset it had at the tap.
    func testLeavingTheFeedFreezesItWhereItWas() {
        var memory = KyroSportsFeedScrollMemory()
        XCTAssertEqual(memory.visibilityChanged(isVisible: false, offset: 1_840, maximumOffset: 6_000), .freeze(1_840))
        XCTAssertEqual(memory.saved, 1_840)
    }

    /// Momentum or anything else moved the hidden Feed; returning puts the saved offset back.
    func testReturningRestoresTheOffsetAfterAnyMovement() {
        var memory = KyroSportsFeedScrollMemory()
        _ = memory.visibilityChanged(isVisible: false, offset: 1_840, maximumOffset: 6_000)
        XCTAssertEqual(memory.visibilityChanged(isVisible: true, offset: 0, maximumOffset: 6_000), .restore(1_840))
        XCTAssertNil(memory.saved, "Restored once, then the Feed scrolls freely")
    }

    func testReturningToAnUnmovedFeedDoesNothing() {
        var memory = KyroSportsFeedScrollMemory()
        _ = memory.visibilityChanged(isVisible: false, offset: 1_840, maximumOffset: 6_000)
        XCTAssertNil(memory.visibilityChanged(isVisible: true, offset: 1_840.5, maximumOffset: 6_000))
    }

    /// Feed → Game → Stats → News → Feed, several times, with scrolling in between.
    func testRepeatedTabRoundTripsKeepEachPosition() {
        var memory = KyroSportsFeedScrollMemory()
        for offset in [420.0, 2_960.0, 75.0, 0.0] as [CGFloat] {
            _ = memory.visibilityChanged(isVisible: false, offset: offset, maximumOffset: 6_000)
            // Game, Stats and News switch among themselves: the Feed stays hidden, nothing changes.
            XCTAssertEqual(memory.saved, offset)
            XCTAssertEqual(memory.visibilityChanged(isVisible: true, offset: offset == 0 ? 300 : 0, maximumOffset: 6_000),
                           .restore(offset))
        }
    }

    /// A score refresh that shortened the Feed while it was hidden: the restore stays in range.
    func testRestoreIsClampedToTheCurrentContent() {
        var memory = KyroSportsFeedScrollMemory()
        _ = memory.visibilityChanged(isVisible: false, offset: 5_000, maximumOffset: 6_000)
        XCTAssertEqual(memory.visibilityChanged(isVisible: true, offset: 0, maximumOffset: 3_200), .restore(3_200))
    }

    /// Another sport or day replaces the rows; an offset saved for the old rows is not reapplied.
    func testNewContentDropsTheSavedOffset() {
        var memory = KyroSportsFeedScrollMemory()
        _ = memory.visibilityChanged(isVisible: false, offset: 1_840, maximumOffset: 6_000)
        memory.contentReplaced()
        XCTAssertNil(memory.visibilityChanged(isVisible: true, offset: 0, maximumOffset: 6_000))
    }

    func testTrackerNeverClampsBeforeTheFeedHasReportedItsContent() {
        let tracker = KyroSportsFeedScrollTracker()
        XCTAssertEqual(tracker.maximumOffset, .greatestFiniteMagnitude)
        tracker.contentHeight = 4_000
        tracker.viewportHeight = 600
        XCTAssertEqual(tracker.maximumOffset, 3_400)
    }

    // MARK: Coordinator (Build 62: tab tapped mid-flick)

    /// A scroll view that coasts until something sets its offset, like UIScrollView deceleration.
    private final class FakeScrollView: KyroSportsFeedScrollDriving {
        var offset: CGFloat
        var maximumOffset: CGFloat = 6_000
        var isCoasting = false
        var setCount = 0
        init(offset: CGFloat) { self.offset = offset }

        func setOffset(_ offset: CGFloat) {
            self.offset = offset
            isCoasting = false
            setCount += 1
        }

        /// One frame of deceleration. Does nothing once the momentum has been stopped.
        func coast(by points: CGFloat) {
            guard isCoasting else { return }
            offset = max(0, offset - points)
        }
    }

    private func coordinator(offset: CGFloat, coasting: Bool = false) -> (KyroSportsFeedScrollCoordinator, FakeScrollView) {
        let scrollView = FakeScrollView(offset: offset)
        scrollView.isCoasting = coasting
        let coordinator = KyroSportsFeedScrollCoordinator()
        coordinator.driver = scrollView
        return (coordinator, scrollView)
    }

    /// Feed still decelerating when Game is tapped: the offset at the tap is kept and the
    /// deceleration stops, so the Feed is exactly there on return.
    func testTappingATabMidFlickStopsTheMomentumAtTheTapOffset() {
        let (coordinator, scrollView) = coordinator(offset: 2_400, coasting: true)
        coordinator.feedHidden()
        XCTAssertEqual(coordinator.savedOffset, 2_400)
        for _ in 0..<60 { scrollView.coast(by: 40) }
        XCTAssertEqual(scrollView.offset, 2_400, "Momentum ended at the tap")
        coordinator.feedShown()
        XCTAssertEqual(scrollView.offset, 2_400)
        XCTAssertNil(coordinator.savedOffset)
    }

    /// A callback after the tab switch, from momentum or layout, reports a later offset. It neither
    /// replaces the saved offset nor survives the return.
    func testLateScrollUpdatesAfterLeavingDoNotOverwriteTheSavedOffset() {
        let (coordinator, scrollView) = coordinator(offset: 2_400)
        coordinator.feedHidden()
        scrollView.offset = 0 // a late update moves the hidden Feed
        coordinator.feedHidden() // the onChange backstop runs after the tap already froze it
        XCTAssertEqual(coordinator.savedOffset, 2_400)
        XCTAssertEqual(scrollView.offset, 2_400, "The repeat hide re-freezes at the owned offset")
        scrollView.offset = 17
        coordinator.feedShown()
        XCTAssertEqual(scrollView.offset, 2_400)
    }

    func testRapidTabChangesKeepTheOriginalOffset() {
        let (coordinator, scrollView) = coordinator(offset: 3_100, coasting: true)
        for _ in 0..<5 {
            coordinator.feedHidden()
            scrollView.coast(by: 500)
            coordinator.feedHidden()
        }
        XCTAssertEqual(scrollView.offset, 3_100)
        coordinator.feedShown()
        coordinator.feedShown()
        XCTAssertEqual(scrollView.offset, 3_100)
        // A second visit after scrolling elsewhere saves the new position, not the old one.
        scrollView.offset = 800
        coordinator.feedHidden()
        scrollView.offset = 0
        coordinator.feedShown()
        XCTAssertEqual(scrollView.offset, 800)
    }

    func testNormalRestorationAfterTheFeedMovedWhileHidden() {
        let (coordinator, scrollView) = coordinator(offset: 1_250)
        coordinator.feedHidden()
        scrollView.offset = 0
        coordinator.feedShown()
        XCTAssertEqual(scrollView.offset, 1_250)
    }

    /// A shorter Feed on return is clamped rather than scrolled past its end.
    func testRestoreStaysWithinTheCurrentContent() {
        let (coordinator, scrollView) = coordinator(offset: 5_000)
        coordinator.feedHidden()
        scrollView.maximumOffset = 3_200
        scrollView.offset = 10
        coordinator.feedShown()
        XCTAssertEqual(scrollView.offset, 3_200)
    }

    /// Changing the sport or day invalidates the saved offset.
    func testSportOrDayChangeInvalidatesTheSavedOffset() {
        let (coordinator, scrollView) = coordinator(offset: 1_250)
        coordinator.feedHidden()
        coordinator.contentReplaced()
        XCTAssertNil(coordinator.savedOffset)
        scrollView.offset = 0
        let setsBefore = scrollView.setCount
        coordinator.feedShown()
        XCTAssertEqual(scrollView.offset, 0)
        XCTAssertEqual(scrollView.setCount, setsBefore, "Nothing is restored over the new rows")
    }

    func testNoScrollViewYetIsHarmless() {
        let coordinator = KyroSportsFeedScrollCoordinator()
        coordinator.feedHidden()
        coordinator.feedShown()
        XCTAssertNil(coordinator.savedOffset)
    }

    // MARK: First load of a day

    private let now = Date(timeIntervalSince1970: 1_793_988_000) // 2026-11-06 18:00 UTC

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private actor GatedLeagues: KyroSportsLeagueProviding {
        private var gated: Set<KyroSportLeague> = []
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var started: [KyroSportLeague] = []

        func gate(_ league: KyroSportLeague) { gated.insert(league) }
        func release() {
            gated.removeAll()
            let pending = waiters
            waiters = []
            pending.forEach { $0.resume() }
        }
        func hasStarted(_ league: KyroSportLeague) -> Bool { started.contains(league) }

        func fetchLeagueWindow(league: KyroSportLeague, now: Date, force: Bool) async throws -> KyroSportsProviderOutput {
            try await answer(league)
        }

        func fetchLeagueDay(league: KyroSportLeague, date: Date, now: Date, force: Bool) async throws -> KyroSportsProviderOutput {
            try await answer(league)
        }

        private func answer(_ league: KyroSportLeague) async throws -> KyroSportsProviderOutput {
            started.append(league)
            if gated.contains(league) { await withCheckedContinuation { waiters.append($0) } }
            return KyroSportsProviderOutput(provider: "stub", games: [], season: 2026, week: 0, refreshError: nil)
        }
    }

    private struct NoNFL: KyroSportsProviding {
        let providerID = "nfl-stub"
        func fetchNFLWindow(now: Date, force: Bool) async throws -> KyroSportsProviderOutput {
            KyroSportsProviderOutput(provider: providerID, games: [], season: 2026, week: 9, refreshError: nil)
        }
    }

    /// Recording 404 s: one sport answered with no games while the others were still loading, and
    /// the page read "Schedule unavailable … has not loaded yet. Try again." for a second.
    func testAnUnansweredSportKeepsTheDayLoadingNotUnavailable() async {
        let leagues = GatedLeagues()
        await leagues.gate(.nba)
        let store = KyroSportsHubStore(providers: [NoNFL()], leagueProvider: leagues, calendar: calendar,
                                       now: { [now] in now }, preferences: nil)
        XCTAssertEqual(store.selectedCategory, .all)
        let load = Task { await store.load() }
        while !(await leagues.hasStarted(.nba)) { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(store.phase, .loaded, "Other sports answered")
        XCTAssertEqual(store.scheduleCoverage, .unavailable)
        XCTAssertTrue(store.isLoadingSelectedDay, "NBA has not answered, so the page shows loading")

        await leagues.release()
        await load.value
        XCTAssertFalse(store.isLoadingSelectedDay)
        XCTAssertEqual(store.scheduleCoverage, .empty)
    }

    /// A live poll of a day already loaded never flips the page back to loading.
    func testPollsOfALoadedDayAreNotFirstLoads() async {
        let leagues = GatedLeagues()
        let store = KyroSportsHubStore(providers: [NoNFL()], leagueProvider: leagues, calendar: calendar,
                                       now: { [now] in now }, preferences: nil)
        store.selectCategory(.nba)
        await store.load()
        await leagues.gate(.nba)
        let poll = Task { await store.load(force: true) }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(store.isLoadingSelectedDay)
        await leagues.release()
        await poll.value
    }
}
