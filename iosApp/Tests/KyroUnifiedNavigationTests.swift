import Foundation
import XCTest
@testable import Silo

/// Kyro's unified navigation prototype: where the Live TV tab goes, when it
/// can be shown, and how Picture in Picture returns without a Live TV screen.
@MainActor
final class KyroUnifiedNavigationTests: XCTestCase {
    private var presentation: LiveTVPresentation!
    private var navigations = 0
    private var stops = 0

    override func setUp() async throws {
        presentation = LiveTVPresentation(scheduler: IdleScheduler())
        navigations = 0
        stops = 0
        presentation.navigateToLiveTV = { [unowned self] in navigations += 1 }
        presentation.stopPlayback = { [unowned self] in stops += 1 }
        presentation.stopPictureInPicture = {}
    }

    private let news = LiveTVChannel(id: "news", guideID: "news", name: "News",
                                     streamURL: URL(string: "https://tv.example/news.ts")!, logoURL: nil,
                                     category: "News")

    // MARK: Global selection and secondary routes

    func testNativeShellAdapterMapsTheFiveRequiredDestinationsOneToOne() {
        XCTAssertEqual(KyroGlobalDestination.tabDestinations(fourthTab: .default),
                       [.home, .movies, .series, .sports, .liveTV])
        for destination in KyroGlobalDestination.tabDestinations(fourthTab: .default) {
            let root = MainTabDestination.global(destination)
            XCTAssertEqual(kyroGlobalDestination(for: root.id), destination)
        }
        XCTAssertEqual(MainTabDestination.global(.home).id, .app(.home),
                       "Global Home remains the Kyro Home screen")
        XCTAssertEqual(MainTabDestination.global(.movies).id, .libraryCategory(.movies))
        XCTAssertEqual(MainTabDestination.global(.series).id, .libraryCategory(.series))
        XCTAssertEqual(MainTabDestination.global(.forYou).id, .app(.recommendations))
        XCTAssertEqual(MainTabDestination.global(.sports).id, .kyroRoot(.sports))
        XCTAssertEqual(MainTabDestination.global(.sports).title, "Sports")
        XCTAssertEqual(MainTabDestination.global(.sports).icon, "trophy")
        for destination in KyroGlobalDestination.allCases {
            XCTAssertEqual(kyroGlobalDestination(for: MainTabDestination.global(destination).id), destination)
        }
    }

    func testForYouStaysOutOfMoreWhenItIsNotATab() {
        let projected = KyroGlobalDestination.tabDestinations(fourthTab: .default).map(MainTabDestination.global)
            + [.app(.recommendations), .app(.calendar)]
        XCTAssertEqual(kyroSecondaryDestinations(from: projected).map(\.id), [.app(.calendar)],
                       "For You is in the profile menu, not a second time in More")
    }

    @MainActor
    func testProfileMenuForYouSelectsTheTabOrPushesForYou() throws {
        let suite = "KyroForYouEntry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KyroGlobalNavigationStore(defaults: defaults)

        let router = AppRouter()
        KyroShellHeader.openForYou(router: router, store: store)
        XCTAssertEqual(router.visiblePushedRoutes, [.secondaryDestination(.app(.recommendations))])
        XCTAssertEqual(store.selectedDestination, .home, "pushing For You leaves the tab alone")

        store.preferences.fourthTab = .forYou
        let tabRouter = AppRouter()
        KyroShellHeader.openForYou(router: tabRouter, store: store)
        XCTAssertTrue(tabRouter.visiblePushedRoutes.isEmpty)
        XCTAssertEqual(store.selectedDestination, .forYou)
    }

    func testMoviesAndSeriesRemainPrimaryWhenNoMatchingLibrariesAreAvailable() {
        let globalRoots = KyroGlobalDestination.tabDestinations(fourthTab: .default).map(MainTabDestination.global)
        XCTAssertEqual(globalRoots.count, 5)
        XCTAssertTrue(globalRoots.contains { $0.id == .libraryCategory(.movies) })
        XCTAssertTrue(globalRoots.contains { $0.id == .libraryCategory(.series) })
        XCTAssertFalse(mainTabSupportsDestination(.builtin(.movies), availableLibraries: []))
        XCTAssertFalse(mainTabSupportsDestination(.builtin(.series), availableLibraries: []))
    }

    func testMoreProjectionKeepsSecondarySiloRootsOutOfGlobalTabs() {
        let projected = KyroGlobalDestination.tabDestinations(fourthTab: .default).map(MainTabDestination.global)
            + [.app(.downloads), .app(.calendar), .library(id: 42, label: "Kids")]
        let secondary = kyroSecondaryDestinations(from: projected)
        XCTAssertEqual(secondary.map(\.id), [.app(.downloads), .app(.calendar), .library(42)])
        XCTAssertFalse(secondary.contains { kyroGlobalDestination(for: $0.id) != nil })
    }

    func testMoreAddsCalendarIndependentOfPrimaryMenuAndDownloadsOnlyWhenEnabled() {
        let onlyGlobalTabs = KyroGlobalDestination.tabDestinations(fourthTab: .default).map(MainTabDestination.global)

        let withoutDownloads = kyroMoreDestinations(from: onlyGlobalTabs, downloadsEnabled: false)
        XCTAssertEqual(withoutDownloads.map(\.id), [.app(.calendar)])

        let withDownloads = kyroMoreDestinations(from: onlyGlobalTabs, downloadsEnabled: true)
        XCTAssertEqual(withDownloads.map(\.id), [.app(.calendar), .app(.downloads)])
        XCTAssertFalse(withDownloads.contains { $0.title == "Collections" })
        XCTAssertEqual(KyroGlobalDestination.tabDestinations(fourthTab: .default).count, 5)
    }

    func testMorePreservesEligibleSecondaryRootsWithoutDuplicatingCalendarOrDownloads() {
        let projected = KyroGlobalDestination.tabDestinations(fourthTab: .default).map(MainTabDestination.global)
            + [.app(.calendar), .app(.downloads), .library(id: 42, label: "Kids")]
        XCTAssertEqual(kyroMoreDestinations(from: projected, downloadsEnabled: true).map(\.id),
                       [.app(.calendar), .app(.downloads), .library(42)])
    }

    func testDownloadsDeepLinkAndCalendarTabRequestsResolveToSecondaryRoutes() {
        let projected = KyroGlobalDestination.tabDestinations(fourthTab: .default).map(MainTabDestination.global)
            + [.app(.downloads), .app(.calendar)]

        XCTAssertEqual(
            kyroSecondaryRouteID(for: .downloads, visibleDestinations: projected),
            .app(.downloads),
            "The existing downloads deep-link's requestedTab path must still open Downloads"
        )
        XCTAssertEqual(
            kyroSecondaryRouteID(for: .calendar, visibleDestinations: projected),
            .app(.calendar)
        )
        XCTAssertNil(kyroSecondaryRouteID(for: .home, visibleDestinations: projected))
    }

    func testIneligibleSecondaryRequestFailsClosed() {
        let projected = KyroGlobalDestination.tabDestinations(fourthTab: .default).map(MainTabDestination.global)
        XCTAssertNil(kyroSecondaryRouteID(for: .downloads, visibleDestinations: projected))
    }

    func testLiveTVInternalGuideAndBrowserHaveContextualHomeReturnWithoutChangingGlobalHome() {
        XCTAssertEqual(LiveTVNavigationPolicy.backDestination(showingBrowser: true), .home)
        XCTAssertEqual(LiveTVNavigationPolicy.backLabel(showingBrowser: true), "Back to Live TV Home")
        XCTAssertEqual(MainTabDestination.global(.home).id, .app(.home),
                       "The app-wide Home tab remains Kyro Home")
    }

    /// Builds 21 to 24 drew the browser's Back in toolbars, the header or a bar on the page, so the
    /// browser replaced Home's content and had no native edge swipe. Build 25 pushes the browser
    /// onto the app's stack: it uses the system Back, and Live TV Home, a tab root, draws no Back.
    func testTheUnifiedBrowserUsesTheSystemBackAndLiveTVHomeNoBack() {
        XCTAssertEqual(LiveTVNavigationPolicy.homeBackPlacement(isTabRoot: true, showingBrowser: true), .system)
        XCTAssertEqual(LiveTVNavigationPolicy.homeBackPlacement(isTabRoot: true, showingBrowser: false), .none,
                       "Live TV Home is a tab root: nothing behind it, and global Home is never a Live TV back")
        XCTAssertEqual(LiveTVNavigationPolicy.backDestination(showingBrowser: true), .home,
                       "Back returns to Live TV Home, never to Kyro Home")
    }

    // MARK: Default and opt-out

    func testTheUnifiedShellIsTheIPhoneDefaultAndIPadKeepsTheEarlierNavigation() {
        let defaults = UserDefaults(suiteName: "KyroUnifiedNavigationTests-\(UUID().uuidString)")!
        XCTAssertTrue(KyroUnifiedNavigation.resolveIsActive(isPhone: true, defaults: defaults))
        XCTAssertFalse(KyroUnifiedNavigation.resolveIsActive(isPhone: false, defaults: defaults))
    }

    #if !KYRO_UNIFIED_NAV_FORCE_ON
    func testTheLegacyOptOutShowsTheEarlierNavigationOnIPhone() {
        let defaults = UserDefaults(suiteName: "KyroUnifiedNavigationTests-\(UUID().uuidString)")!
        defaults.set(true, forKey: KyroUnifiedNavigation.legacyShellKey)
        XCTAssertFalse(KyroUnifiedNavigation.resolveIsActive(isPhone: true, defaults: defaults))
        XCTAssertFalse(KyroUnifiedNavigation.resolveIsActive(isPhone: false, defaults: defaults))
    }
    #endif

    func testAStaleBuild26SettingNoLongerTurnsTheUnifiedShellOff() {
        let defaults = UserDefaults(suiteName: "KyroUnifiedNavigationTests-\(UUID().uuidString)")!
        defaults.set(false, forKey: "kyro.unifiedNavigation.enabled")
        XCTAssertTrue(KyroUnifiedNavigation.resolveIsActive(isPhone: true, defaults: defaults))
    }

    func testTheProfileMenuOffersLiveTVOnlyWhereItIsNotAlreadyATab() {
        XCTAssertFalse(KyroLiveTVEntry.profileMenuOffersLiveTV(unifiedShell: true),
                       "Under the unified shell Live TV is a tab; the menu item would duplicate it")
        XCTAssertTrue(KyroLiveTVEntry.profileMenuOffersLiveTV(unifiedShell: false),
                      "The production fallback keeps its menu entry")
        XCTAssertEqual(KyroLiveTVEntry.profileMenuOffersLiveTV,
                       !KyroUnifiedNavigation.isActive, "the menu reads the shell's own flag")
    }

    func testPushedLiveTVKeepsItsToolbarBackForHomeAndTheBrowser() {
        XCTAssertEqual(LiveTVNavigationPolicy.homeBackPlacement(isTabRoot: false, showingBrowser: true), .toolbar)
        XCTAssertEqual(LiveTVNavigationPolicy.homeBackPlacement(isTabRoot: false, showingBrowser: false), .toolbar)
        XCTAssertEqual(LiveTVNavigationPolicy.backDestination(showingBrowser: false), .exitLiveTV)
    }

    func testCalendarReachesMoreFromAServerMenuThatOmitsItAndCollectionsNeverDoes() {
        let movies = Library(id: 7, name: "Movies", type: "movies", sortOrder: 0, posterUrl: nil)
        let series = Library(id: 8, name: "Series", type: "series", sortOrder: 1, posterUrl: nil)
        let kids = Library(id: 42, name: "Kids", type: "movies", sortOrder: 2, posterUrl: nil)
        let menu = PrimaryMenuPreference(items: [
            .builtin(.home), .builtin(.movies), .builtin(.series), .builtin(.forYou),
            .library(libraryId: 42, label: "Kids"),
            .collection(collectionId: "favorites", label: "Collections", libraryId: 7),
        ])
        let projected = projectedMainTabDestinations(primaryMenu: menu, availableLibraries: [movies, series, kids])
        XCTAssertFalse(projected.contains { $0.id == .app(.calendar) }, "The user removed Calendar from the menu")

        let more = kyroMoreDestinations(from: projected, downloadsEnabled: false)
        XCTAssertEqual(more.map(\.id), [.library(42), .app(.calendar)])
        XCTAssertFalse(more.contains { $0.title == "Collections" })
        XCTAssertFalse(more.contains { $0.id == .app(.downloads) }, "Downloads stays behind the server capability")
        XCTAssertTrue(more.allSatisfy { kyroGlobalDestination(for: $0.id) == nil },
                      "More never repeats one of the five global destinations")
    }

    // MARK: More eligibility

    private func library(_ id: Int, _ name: String, _ type: String) -> Library {
        Library(id: id, name: name, type: type, sortOrder: id, posterUrl: nil)
    }

    private func more(menu: [PrimaryMenuItem], libraries: [Library], downloads: Bool = false) -> [MainTabDestination] {
        let projected = projectedMainTabDestinations(
            primaryMenu: PrimaryMenuPreference(items: menu), availableLibraries: libraries)
        return kyroMoreDestinations(from: projected, downloadsEnabled: downloads, availableLibraries: libraries)
    }

    private let globals: [PrimaryMenuItem] = [.builtin(.home), .builtin(.movies), .builtin(.series), .builtin(.forYou)]

    func testMoreOmitsAMoviesOrSeriesLibraryTheTabAlreadyShowsAndKeepsUnrelatedLibraries() {
        let movies = library(7, "Movies", "movies")
        let shows = library(8, "Shows", "series")
        let books = library(9, "Audiobooks Plus", "audiobooks")
        let result = more(menu: globals + [.library(libraryId: 7, label: "Movies"), .library(libraryId: 8, label: "Shows"),
                                           .library(libraryId: 9, label: "Audiobooks Plus")],
                          libraries: [movies, shows, books])
        XCTAssertEqual(result.map(\.id), [.library(9), .app(.calendar)],
                       "the sole Movies and Series libraries repeat their tabs; an audiobook library is extra")
    }

    func testMoreKeepsASiblingLibraryShortcutThatTheTabDoesNotGive() {
        let movies = library(7, "Movies", "movies")
        let kids = library(42, "Kids", "movies")
        let result = more(menu: globals + [.library(libraryId: 42, label: "Kids")], libraries: [movies, kids])
        XCTAssertEqual(result.map(\.id), [.library(42), .app(.calendar)])
    }

    func testMoreDropsACollectionsNamedLibraryInsideACategoryButNotByNameAlone() {
        let movies = library(7, "Movies", "movies")
        let collections = library(21, "Collections", "movies")
        let kids = library(42, "Kids", "movies")
        let archive = library(30, "Collections Archive", "movies")
        let audio = library(31, "Collections", "audiobooks")
        let result = more(menu: globals + [.library(libraryId: 21, label: "Collections"),
                                           .library(libraryId: 42, label: "Kids"),
                                           .library(libraryId: 30, label: "Collections Archive"),
                                           .library(libraryId: 31, label: "Collections")],
                          libraries: [movies, collections, kids, archive, audio])
        XCTAssertEqual(result.map(\.id), [.library(42), .library(30), .library(31), .app(.calendar)],
                       "only the Movies-category library named Collections goes; the name alone is not enough")
    }

    func testACollectionTypedLibraryIsNeverAMoreDestination() {
        let boxSets = library(50, "Box Sets", "boxsets")
        let tab = MainTabDestination.library(id: 50, label: "Box Sets")
        XCTAssertTrue(KyroMoreEligibility.isCollectionTypedLibrary(boxSets))
        XCTAssertFalse(KyroMoreEligibility.isEligible(tab, among: [boxSets]))
        XCTAssertFalse(KyroMoreEligibility.isCollectionTypedLibrary(library(1, "Movies", "movies")))
    }

    func testMoreNeverListsLiveTVAndKeepsCalendarAndGatedDownloads() {
        XCTAssertFalse(KyroMoreEligibility.isEligible(MainTabDestination.global(.liveTV), among: []))
        let movies = library(7, "Movies", "movies")
        XCTAssertEqual(more(menu: globals, libraries: [movies], downloads: false).map(\.id), [.app(.calendar)])
        XCTAssertEqual(more(menu: globals, libraries: [movies], downloads: true).map(\.id),
                       [.app(.calendar), .app(.downloads)])
    }

    func testWithoutLibrariesTheProjectionIsUnfiltered() {
        let kids = library(42, "Kids", "movies")
        let projected = projectedMainTabDestinations(
            primaryMenu: PrimaryMenuPreference(items: globals + [.library(libraryId: 42, label: "Kids")]),
            availableLibraries: [kids])
        XCTAssertEqual(kyroMoreDestinations(from: projected, downloadsEnabled: false).map(\.id),
                       [.library(42), .app(.calendar)])
    }

    /// Collections stays a library feature: every Movies, Series and library page keeps the chip.
    func testCollectionsRemainsAChipOfEveryLibraryPage() {
        XCTAssertEqual(LibraryPageTab.allCases.map(\.title), ["Recommended", "Library", "Collections"])
    }

    func testSecondaryRouteIdentityDoesNotOverlapGlobalSelection() {
        let downloads = Route.secondaryDestination(.app(.downloads))
        let calendar = Route.secondaryDestination(.app(.calendar))
        let kidsLibrary = Route.secondaryDestination(.library(42))
        XCTAssertNotEqual(downloads, calendar)
        XCTAssertNotEqual(calendar, kidsLibrary)
        XCTAssertEqual(MainTabDestinationID(SecondaryDestinationID.app(.downloads)), .app(.downloads))
        XCTAssertEqual(MainTabDestinationID(SecondaryDestinationID.library(42)), .library(42))
    }

    func testLiveTVCanBeATabOnlyFromTheShellRoot() {
        XCTAssertTrue(KyroUnifiedNavigation.canSelectLiveTVTab(pathIsEmpty: true, isPresentingOverShell: false))
        XCTAssertFalse(KyroUnifiedNavigation.canSelectLiveTVTab(pathIsEmpty: false, isPresentingOverShell: false))
        XCTAssertFalse(KyroUnifiedNavigation.canSelectLiveTVTab(pathIsEmpty: true, isPresentingOverShell: true))
    }

    // MARK: Picture in Picture over a pushed Media Server screen

    private func enterPictureInPictureThenLeaveLiveTV() {
        presentation.surfaceAppeared(.list)
        XCTAssertEqual(presentation.select(news, from: .list), .present)
        presentation.pictureInPictureStartedFromControl()
        presentation.surfaceDisappeared(.list)
    }

    func testRestoreOverAPushedScreenOpensThePlayerOverItAndClosingLeavesItThere() {
        enterPictureInPictureThenLeaveLiveTV()
        var answers: [Bool] = []
        presentation.restoreRequested { answers.append($0) }
        XCTAssertEqual(navigations, 1, "Asked for a Live TV screen first")

        // The shell found a pushed Media Server screen and left it in place.
        presentation.presentOverCurrentScreen()
        XCTAssertEqual(presentation.phase, .restoring(news, .shell))
        XCTAssertEqual(presentation.channel(for: .shell), news)
        XCTAssertNil(presentation.channel(for: .list), "Exactly one cover")

        presentation.playerDidAppear(news)
        XCTAssertEqual(answers, [true])
        XCTAssertEqual(presentation.phase, .presented(news, .shell))

        presentation.coverDismissed(from: .shell)
        XCTAssertEqual(presentation.phase, .idle)
    }

    func testReturningToThePlayerAfterAWindowSwitchAlsoUsesTheShell() {
        enterPictureInPictureThenLeaveLiveTV()
        let other = LiveTVChannel(id: "sport", guideID: "sport", name: "Sport",
                                  streamURL: URL(string: "https://tv.example/sport.m3u8")!, logoURL: nil,
                                  category: "Sports")
        _ = presentation.select(other, from: .list)
        XCTAssertEqual(presentation.engagementEnded(), .continuePlayback)
        XCTAssertEqual(navigations, 1)

        presentation.presentOverCurrentScreen()
        XCTAssertEqual(presentation.channel(for: .shell), other)
        XCTAssertNil(presentation.channel(for: .list))
    }

    func testTheShellNeverTakesThePlayerFromAVisibleLiveTVScreen() {
        presentation.surfaceAppeared(.list)
        XCTAssertEqual(presentation.select(news, from: .list), .present)
        presentation.presentOverCurrentScreen()
        XCTAssertEqual(presentation.phase, .presented(news, .list))

        presentation.coverDismissed(from: .list)
        presentation.presentOverCurrentScreen()
        XCTAssertEqual(presentation.phase, .idle)
    }

    func testAfterTheShellPlayerTheListPresentsAgain() {
        enterPictureInPictureThenLeaveLiveTV()
        presentation.restoreRequested { _ in }
        presentation.presentOverCurrentScreen()
        presentation.playerDidAppear(news)
        presentation.coverDismissed(from: .shell)

        presentation.surfaceAppeared(.list)
        XCTAssertEqual(presentation.select(news, from: .list), .present)
        XCTAssertEqual(presentation.channel(for: .list), news)
        XCTAssertNil(presentation.channel(for: .shell))
    }
}

/// Timers that never fire: these tests finish every restore themselves.
@MainActor
private final class IdleScheduler: LiveTVScheduling {
    var now: Double { 0 }

    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) -> LiveTVTimerHandle {
        LiveTVTimerHandle {}
    }
}
