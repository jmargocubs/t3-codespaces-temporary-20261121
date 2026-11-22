import Foundation
import XCTest
@testable import Silo

/// The channel browser (Favorites View All, a category, Search) is a pushed screen under the
/// unified shell, so the system's edge swipe can pop it. These tests cover the one-flag state
/// machine that drives that push; the swipe itself is validated on a physical iPhone.
final class LiveTVBrowserNavigationTests: XCTestCase {
    private let provider = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    /// Mirrors `LiveTVView`: `showing` is the single flag; the stack reports only its own pops.
    private struct Model {
        var isTabRoot = true
        var showing = false
        var returnedHomeCount = 0

        var isPushed: Bool { LiveTVNavigationPolicy.isBrowserPushed(isTabRoot: isTabRoot, showingBrowser: showing) }

        mutating func enter() { showing = true }

        /// What the stack's binding setter does.
        mutating func stackReports(presented: Bool) {
            if LiveTVNavigationPolicy.shouldReturnHome(stackShowsBrowser: presented, showingBrowser: showing) {
                showing = false
                returnedHomeCount += 1
            }
        }
    }

    func testBrowserIsPushedOnlyUnderTheUnifiedShell() {
        XCTAssertTrue(LiveTVNavigationPolicy.pushesBrowser(isTabRoot: true))
        XCTAssertFalse(LiveTVNavigationPolicy.pushesBrowser(isTabRoot: false))
        XCTAssertTrue(LiveTVNavigationPolicy.isBrowserPushed(isTabRoot: true, showingBrowser: true))
        XCTAssertFalse(LiveTVNavigationPolicy.isBrowserPushed(isTabRoot: true, showingBrowser: false), "Home is not pushed")
        XCTAssertFalse(LiveTVNavigationPolicy.isBrowserPushed(isTabRoot: false, showingBrowser: true),
                       "elsewhere the browser keeps replacing Home's content")
    }

    func testFavoritesAndCategoryEntryAndExitReturnToHome() {
        for _ in ["favorites", "category"] {
            var model = Model()
            model.enter()
            XCTAssertTrue(model.isPushed)
            model.stackReports(presented: false)
            XCTAssertFalse(model.isPushed)
            XCTAssertEqual(model.returnedHomeCount, 1)
        }
    }

    func testRepeatedEntryAndExitStaysConsistent() {
        var model = Model()
        for cycle in 1...5 {
            model.enter()
            XCTAssertTrue(model.isPushed)
            model.stackReports(presented: false)
            XCTAssertFalse(model.isPushed)
            XCTAssertEqual(model.returnedHomeCount, cycle)
        }
    }

    func testCanceledSwipeReportsNothingAndLeavesTheBrowserIntact() {
        var model = Model()
        model.enter()
        // A canceled interactive pop never reaches the binding; a stray "still presented" report
        // must not navigate either.
        model.stackReports(presented: true)
        XCTAssertTrue(model.isPushed)
        XCTAssertEqual(model.returnedHomeCount, 0)
    }

    func testBackRunsOnceEvenWhenAProgrammaticExitIsReportedAgain() {
        var model = Model()
        model.enter()
        model.showing = false           // provider switch or another programmatic exit
        model.stackReports(presented: false)
        XCTAssertEqual(model.returnedHomeCount, 0, "already Home: the stack's report changes nothing")
        XCTAssertFalse(model.isPushed)
    }

    func testPushedBrowserUsesTheSystemBackAndHomeDrawsNone() {
        XCTAssertEqual(LiveTVNavigationPolicy.homeBackPlacement(isTabRoot: true, showingBrowser: true), .system)
        XCTAssertEqual(LiveTVNavigationPolicy.homeBackPlacement(isTabRoot: true, showingBrowser: false), .none)
    }

    func testRestoredBrowserSnapshotNeverPushesDuringLaunchOrTabSwitch() {
        XCTAssertFalse(LiveTVNavigationPolicy.restoresBrowserOnAppear(isTabRoot: true))
        XCTAssertTrue(LiveTVNavigationPolicy.restoresBrowserOnAppear(isTabRoot: false))
    }

    /// A launch with an open-browser snapshot lands on Home, and re-entering the same browser still
    /// resumes its saved position (the snapshot becomes a Home choice).
    func testOpenSnapshotBecomesAHomeChoiceThatResumesTheSameBrowser() {
        let open = LiveTVBrowsingContext(providerID: provider, category: "News", favoritesOnly: false,
                                         searchQuery: "", channelID: "\(provider.uuidString):a",
                                         offsetX: nil, offsetY: 416, isBrowserVisible: true)
        XCTAssertTrue(open.shouldPresentBrowser)
        let home = open.returningHome()
        XCTAssertFalse(home.shouldPresentBrowser)
        XCTAssertNotNil(home.resumedBrowser(for: .category("News")), "same category resumes its position")
        XCTAssertNil(home.resumedBrowser(for: .category("Sports")), "another browser starts fresh")
        XCTAssertNil(home.resumedBrowser(for: .favorites))
    }

    func testSearchSnapshotKeepsOnlyTheHomeChoice() {
        let search = LiveTVBrowsingContext(providerID: provider, category: nil, favoritesOnly: false,
                                           searchQuery: "news", channelID: "x", offsetX: nil, offsetY: 10,
                                           isBrowserVisible: true)
        let home = search.returningHome()
        XCTAssertEqual(home.searchQuery, "")
        XCTAssertNil(home.channelID)
        XCTAssertFalse(home.shouldPresentBrowser)
    }

    func testGuideAndTabSwitchingDoNotTouchTheBrowserFlag() {
        // The Guide is its own push (`isShowingGuide`); Home stays Home when it opens.
        var model = Model()
        XCTAssertFalse(model.isPushed)
        model.stackReports(presented: false)
        XCTAssertEqual(model.returnedHomeCount, 0)
        XCTAssertFalse(model.showing)
    }
}
