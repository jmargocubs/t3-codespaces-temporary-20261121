import SwiftUI
import XCTest
@testable import Silo

/// Stage 1: one Kyro header, drawn by the shell, shared by the five global destinations.
@MainActor
final class KyroAppHeaderTests: XCTestCase {
    private func context(statusColumn: Bool = false) -> KyroShellHeaderContext {
        KyroShellHeaderContext(scrollStates: KyroShellScrollStates(),
                               runway: KyroShellHeader.runway(hasStatusColumn: statusColumn))
    }

    // MARK: Ownership

    func testEveryGlobalDestinationHasItsOwnScrollStateTheShellHeaderReads() {
        let states = KyroShellScrollStates()
        let all = KyroGlobalDestination.tabDestinations(fourthTab: .default).map { states.state(for: $0) }
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(Set(all.map(ObjectIdentifier.init)).count, 5, "each tab keeps its own scroll offset")
        for destination in KyroGlobalDestination.tabDestinations(fourthTab: .default) {
            XCTAssertTrue(states.state(for: destination) === states.state(for: destination),
                          "the page and the shell's header must read the same state")
        }
    }

    func testAScrollingPageMovesOnlyItsOwnDestinationsGlass() {
        let ctx = context()
        ctx.scrollState(for: .home).update(40)
        XCTAssertEqual(ctx.scrollState(for: .home).offset, 40)
        for other in KyroGlobalDestination.tabDestinations(fourthTab: .default) where other != .home {
            XCTAssertEqual(ctx.scrollState(for: other).offset, 0, "\(other) must not follow Home's scroll")
        }
    }

    func testFastScrollingClampsChromeWithoutResettingOtherDestinations() {
        let states = KyroShellScrollStates()
        let movies = states.state(for: .movies)
        let series = states.state(for: .series)
        movies.update(10_000)
        XCTAssertEqual(movies.offset, PageChromeGlass.fadeEnd)
        series.update(20)
        XCTAssertEqual(movies.offset, PageChromeGlass.fadeEnd)
        XCTAssertEqual(series.offset, 20)
        movies.update(-100)
        XCTAssertEqual(movies.offset, 0)
        XCTAssertEqual(series.offset, 20, "scrolling another tab must not reset this page's chrome")
    }

    func testPagesHostedByTheShellSkipTheirOwnHeaderOnEveryTab() {
        let ctx = context()
        for destination in KyroGlobalDestination.tabDestinations(fourthTab: .default) {
            XCTAssertNotNil(KyroShellHeader.hosted(ctx, secondaryTitle: nil),
                            "\(destination) leaves its header to the shell")
        }
    }

    func testAPagePushedFromMoreKeepsItsOwnHeaderAndNoShellMeansNoSharedHeader() {
        XCTAssertNil(KyroShellHeader.hosted(context(), secondaryTitle: "Calendar"))
        XCTAssertNil(KyroShellHeader.hosted(nil, secondaryTitle: nil),
                     "legacy shell, iPad, Mac and tvOS keep every page's own header")
    }

    func testOnlyMoviesAndSeriesStandForALibraryRootInTheShell() {
        XCTAssertEqual(KyroShellHeader.destination(forCategory: .movies), .movies)
        XCTAssertEqual(KyroShellHeader.destination(forCategory: .series), .series)
        XCTAssertNil(KyroShellHeader.destination(forCategory: .audiobooks))
        XCTAssertNil(KyroShellHeader.destination(forCategory: nil), "a pinned library root is not a global tab")
    }

    // MARK: Glass and runway

    /// Home's own runway was the icon row plus 8 above and 8 below. Pages keep that exact footprint,
    /// so moving the header to the shell moves nothing on Home.
    func testTheRunwayIsTheHeaderTheHomePageAlreadyHad() {
        XCTAssertEqual(KyroShellHeader.runway(hasStatusColumn: false),
                       SiloTheme.topBarIconHitSize + SiloTheme.smallPadding * 2)
        XCTAssertEqual(KyroShellHeader.runway(hasStatusColumn: false), 60)
        XCTAssertEqual(KyroShellHeader.runway(hasStatusColumn: true), 66, "a little more beside the Duo's status column")
    }

    // MARK: Live TV

    func testLiveTVHomeAsATabRootHasNoBackAndTheBrowserHasAContextBar() {
        XCTAssertEqual(LiveTVNavigationPolicy.homeBackPlacement(isTabRoot: true, showingBrowser: false), .none)
        XCTAssertEqual(LiveTVNavigationPolicy.homeBackPlacement(isTabRoot: true, showingBrowser: true), .system)
        XCTAssertEqual(LiveTVNavigationPolicy.homeBackPlacement(isTabRoot: false, showingBrowser: true), .toolbar)
    }

    func testLiveTVIsStillOneOfTheFiveTabsAndThereforeUsesTheSharedHeader() {
        XCTAssertEqual(KyroGlobalDestination.tabDestinations(fourthTab: .default), [.home, .movies, .series, .sports, .liveTV])
    }
}
