import Foundation
import SwiftUI
import XCTest
@testable import Silo

/// Build 73: the full-page Live TV Categories browser. Covers the one-pass category directory
/// (counts, artwork, favorites), search and empty results, unusual names, provider changes, and
/// the navigation decisions each caller (Home, channel browser, Guide) makes.
final class KyroBuild73CategoriesTests: XCTestCase {
    func testBuild78PreferencesAndHistory() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let providerID = UUID()
        var value = LiveTVCategoryPreferences()
        XCTAssertEqual(value.appearance, .hybrid)
        value.appearance = .grid
        value.grouping = .grouped
        value.togglePin("Sports")
        value.togglePin("News")
        value.movePin(from: IndexSet(integer: 1), to: 0)
        for name in ["A", "B", "C", "D", "E", "F", "A"] { value.opened(name) }
        value.hidden.insert("News")
        value.save(providerID: providerID, to: defaults)
        let loaded = LiveTVCategoryPreferences.load(providerID: providerID, from: defaults)
        XCTAssertEqual(loaded.appearance, .grid)
        XCTAssertEqual(loaded.grouping, .grouped)
        XCTAssertEqual(loaded.pinned, ["News", "Sports"])
        XCTAssertEqual(loaded.recent, ["A", "F", "E", "D", "C"])
        XCTAssertEqual(loaded.availablePinned(in: ["Sports", "News"]), ["Sports"])
        XCTAssertEqual(loaded.availableRecent(in: ["A", "Sports"]), ["A"])
        XCTAssertEqual(loaded.pinned, ["News", "Sports"]) // provider refresh does not erase it
        let otherProvider = LiveTVCategoryPreferences.load(providerID: UUID(), from: defaults)
        XCTAssertEqual(otherProvider.appearance, .grid)
        XCTAssertEqual(otherProvider.grouping, .grouped)
        XCTAssertTrue(otherProvider.pinned.isEmpty)
        XCTAssertTrue(otherProvider.hidden.isEmpty)
    }

    func testBuild831PinActionMutatesOnlyPinnedPreference() {
        var preferences = LiveTVCategoryPreferences(
            appearance: .grid, grouping: .grouped, pinned: [], recent: ["News"], hidden: ["News"])
        let before = preferences

        preferences.togglePin("News")

        XCTAssertEqual(preferences.pinned, ["News"])
        XCTAssertEqual(preferences.hidden, before.hidden)
        XCTAssertEqual(preferences.recent, before.recent)
        XCTAssertEqual(preferences.appearance, before.appearance)
        XCTAssertEqual(preferences.grouping, before.grouping)

        preferences.togglePin("News")
        XCTAssertTrue(preferences.pinned.isEmpty)
        XCTAssertEqual(preferences.hidden, before.hidden, "Unpinning must not change visibility")
    }

    func testBuild831HideActionMutatesOnlyHiddenPreference() {
        var preferences = LiveTVCategoryPreferences(
            appearance: .list, grouping: .provider, pinned: ["Sports"], recent: ["Sports"], hidden: [])
        let before = preferences

        preferences.toggleHidden("Sports")

        XCTAssertEqual(preferences.hidden, ["Sports"])
        XCTAssertEqual(preferences.pinned, before.pinned, "Hiding a pinned category must keep it pinned")
        XCTAssertEqual(preferences.recent, before.recent)
        XCTAssertEqual(preferences.appearance, before.appearance)
        XCTAssertEqual(preferences.grouping, before.grouping)

        preferences.toggleHidden("Sports")
        XCTAssertTrue(preferences.hidden.isEmpty)
        XCTAssertEqual(preferences.pinned, before.pinned, "Unhiding must not change pinning")
    }

    func testBuild78SearchAndConservativeGroups() {
        let query = LiveTVCategorySearch.tokens("esPaNa   copa")
        XCTAssertTrue(LiveTVCategorySearch.matches("USA | España: Copa ⚽️", query: query))
        XCTAssertTrue(LiveTVCategorySearch.matches("UK - NEWS!!!", query: ["news"]))
        XCTAssertFalse(LiveTVCategorySearch.matches("Movies", query: ["news"]))
        XCTAssertEqual(LiveTVCategoryGroup.classify("US: Sports"), .sports)
        XCTAssertEqual(LiveTVCategoryGroup.classify("News and Sports"), .other)
        XCTAssertEqual(LiveTVCategoryGroup.classify("UK - Premium"), .other)
        let names = (0..<500).map { "USA | Category \($0)" }
        XCTAssertEqual(names.filter { LiveTVCategorySearch.matches($0, query: ["category", "499"]) }, ["USA | Category 499"])
    }
    private func channel(_ id: String, _ category: String, logo: Bool = false) -> LiveTVChannel {
        LiveTVChannel(id: id, guideID: nil, name: id, streamURL: URL(string: "https://example.com/\(id).ts")!,
                      logoURL: logo ? URL(string: "https://example.com/\(id).png") : nil, category: category)
    }

    // MARK: Directory

    func testDirectoryCountsEveryCategoryInProviderOrder() {
        let categories = ["USA | News", "UK | Sports", "Empty"]
        let channels = [channel("a", "UK | Sports"), channel("b", "USA | News"), channel("c", "UK | Sports"),
                        channel("d", "Not Listed")]
        let directory = LiveTVCategoryDirectory.build(categories: categories, channels: channels, favoriteIDs: [])
        XCTAssertEqual(directory.categories, categories)
        XCTAssertEqual(directory.entry(for: "UK | Sports").channelCount, 2)
        XCTAssertEqual(directory.entry(for: "USA | News").channelCount, 1)
        XCTAssertEqual(directory.entry(for: "Empty").channelCount, 0)
        XCTAssertEqual(directory.totalChannelCount, 4)
    }

    func testDirectoryArtworkIsFirstChannelWithALogo() {
        let channels = [channel("a", "Sports"), channel("b", "Sports", logo: true), channel("c", "Sports", logo: true)]
        let directory = LiveTVCategoryDirectory.build(categories: ["Sports", "News"], channels: channels, favoriteIDs: [])
        XCTAssertEqual(directory.entry(for: "Sports").artworkChannel?.id, "b")
        XCTAssertNil(directory.entry(for: "News").artworkChannel)
    }

    func testDirectoryCountsFavoritesAndRanksFrequentOnce() {
        let channels = [channel("a", "News"), channel("b", "Sports"), channel("c", "Sports")]
        let directory = LiveTVCategoryDirectory.build(categories: ["News", "Sports"], channels: channels,
                                                      favoriteIDs: ["a", "missing"])
        XCTAssertEqual(directory.favoriteChannelCount, 1)
        // A favorite outranks a larger category, as in Build 72.
        XCTAssertEqual(directory.frequent.first, "News")
    }

    func testDuplicateProviderCategoriesDoNotCrashAndKeepOneEntry() {
        let directory = LiveTVCategoryDirectory.build(categories: ["News", "News"], channels: [channel("a", "News")],
                                                      favoriteIDs: [])
        XCTAssertEqual(directory.entry(for: "News").channelCount, 1)
    }

    func testProviderChangeDropsRemovedCategories() {
        let before = LiveTVCategoryDirectory.build(categories: ["Old", "Kept"], channels: [channel("a", "Old")],
                                                   favoriteIDs: [])
        let after = LiveTVCategoryDirectory.build(categories: ["Kept", "New"], channels: [channel("b", "New")],
                                                  favoriteIDs: [])
        XCTAssertEqual(before.entry(for: "Old").channelCount, 1)
        XCTAssertEqual(after.categories, ["Kept", "New"])
        XCTAssertEqual(after.entry(for: "Old").channelCount, 0)
        let projection = LiveTVGuideCategoryPickerModel.projection(categories: after.categories, query: "",
                                                                   frequent: after.frequent)
        XCTAssertFalse((projection.frequent + projection.remaining).contains("Old"))
    }

    // MARK: Search and identities

    func testSearchHidesFrequentAndFindsSpecialCharacters() {
        let categories = ["USA | NCAA MEN's BASKETBALL (Alt) ⚽️", "España | Copa del Rey Replay", "DE | Sky Sports+"]
        let projection = LiveTVGuideCategoryPickerModel.projection(categories: categories, query: "espana",
                                                                   frequent: [categories[0]])
        XCTAssertEqual(projection.frequent, [])
        // Case- and diacritic-tolerant matching is not promised; the exact accented text matches.
        let accented = LiveTVGuideCategoryPickerModel.projection(categories: categories, query: "España",
                                                                 frequent: [])
        XCTAssertEqual(accented.remaining, ["España | Copa del Rey Replay"])
        let plus = LiveTVGuideCategoryPickerModel.projection(categories: categories, query: "sports+", frequent: [])
        XCTAssertEqual(plus.remaining, ["DE | Sky Sports+"])
        let apostrophe = LiveTVGuideCategoryPickerModel.projection(categories: categories, query: "men's", frequent: [])
        XCTAssertEqual(apostrophe.remaining.count, 1)
    }

    func testSearchWithNoMatchesIsEmpty() {
        let projection = LiveTVGuideCategoryPickerModel.projection(categories: ["News"], query: "zzz", frequent: [])
        XCTAssertTrue(projection.frequent.isEmpty && projection.remaining.isEmpty)
    }

    func testRowIdentitiesAreUniqueAndStable() {
        let categories = (0..<300).map { "Category \($0)" }
        let frequent = Array(categories.prefix(4))
        let first = LiveTVGuideCategoryPickerModel.projection(categories: categories, query: "", frequent: frequent)
        let second = LiveTVGuideCategoryPickerModel.projection(categories: categories, query: "", frequent: frequent)
        let ids = (first.frequent + first.remaining).map(LiveTVGuideCategoryPickerID.category)
        XCTAssertEqual(Set(ids).count, categories.count)
        XCTAssertEqual(first, second)
        XCTAssertFalse(ids.contains(.allCategories))
    }

    // MARK: Fallback icon

    func testFallbackLetterUsesNameAfterRegionPrefix() {
        XCTAssertEqual(LiveTVCategoryFallbackIcon.letter(for: "UK | Amazon Prime Channels"), "A")
        XCTAssertEqual(LiveTVCategoryFallbackIcon.letter(for: "fight club"), "F")
        XCTAssertEqual(LiveTVCategoryFallbackIcon.letter(for: "USA | 🏈"), "U")
        XCTAssertEqual(LiveTVCategoryFallbackIcon.letter(for: "★ ★"), "#")
        XCTAssertEqual(LiveTVCategoryFallbackIcon.letter(for: ""), "#")
    }

    func testFallbackHueIsStableAndInRange() {
        let hue = LiveTVCategoryFallbackIcon.hue(for: "Live | F1 TV")
        XCTAssertEqual(hue, LiveTVCategoryFallbackIcon.hue(for: "Live | F1 TV"))
        XCTAssertTrue((0..<1).contains(hue))
    }

    // MARK: Navigation

    func testHomeChoicesBecomeBrowserFilters() {
        XCTAssertEqual(LiveTVCategoryNavigation.homeFilters(for: .category("USA | News")), .category("USA | News"))
        XCTAssertEqual(LiveTVCategoryNavigation.homeFilters(for: .all), .channels)
        XCTAssertEqual(LiveTVCategoryNavigation.homeFilters(for: .favorites), .favorites)
    }

    /// Home → Categories → Channels → Back: the Categories page owns the pushed browser, so popping
    /// it lands on Categories; Home's own destination never pushes a second browser.
    func testOnlyOneDestinationOwnsThePushedBrowser() {
        for showingCategories in [false, true] {
            let owners = [false, true].filter {
                LiveTVCategoryNavigation.ownsPushedBrowser(fromCategories: $0, isBrowserPushed: true,
                                                           openedFromCategories: showingCategories)
            }
            XCTAssertEqual(owners, [showingCategories])
        }
        XCTAssertFalse(LiveTVCategoryNavigation.ownsPushedBrowser(fromCategories: true, isBrowserPushed: false,
                                                                  openedFromCategories: true))
    }

    func testNestedCategorySelectionKeepsItsParentAndOnlyOwnerHandlesBack() {
        let filters = LiveTVCategoryNavigation.homeFilters(for: .category("Sports"))
        XCTAssertEqual(filters.category, "Sports")
        XCTAssertTrue(LiveTVCategoryNavigation.ownsPushedBrowser(
            fromCategories: true, isBrowserPushed: true, openedFromCategories: true))
        XCTAssertFalse(LiveTVCategoryNavigation.shouldHandleBrowserPop(
            fromCategories: false, openedFromCategories: true,
            showingBrowser: true, stackShowsBrowser: false))
        XCTAssertFalse(LiveTVCategoryNavigation.shouldDismissCategories(
            showingCategories: true, browserPushedFromCategories: true))
        XCTAssertTrue(LiveTVCategoryNavigation.shouldHandleBrowserPop(
            fromCategories: true, openedFromCategories: true,
            showingBrowser: true, stackShowsBrowser: false))
        XCTAssertTrue(LiveTVCategoryNavigation.shouldDismissCategories(
            showingCategories: true, browserPushedFromCategories: false))
    }

    func testRepeatedSelectionsDoNotMakeTwoBrowserOwners() {
        for category in ["News", "Sports", "Empty", "News"] {
            XCTAssertEqual(LiveTVCategoryNavigation.homeFilters(for: .category(category)).category, category)
            let owners = [false, true].filter {
                LiveTVCategoryNavigation.ownsPushedBrowser(
                    fromCategories: $0, isBrowserPushed: true, openedFromCategories: true)
            }
            XCTAssertEqual(owners, [true])
        }
    }

    func testBuild781NestedBackAndSwipeOwnershipForEveryAppearance() {
        for appearance in LiveTVCategoryAppearance.allCases {
            for selected in ["News", "Sports", "News"] {
                // Appearance does not participate in routing: only the Categories parent owns
                // the pushed browser, including after another category is chosen.
                XCTAssertEqual(LiveTVCategoryNavigation.homeFilters(for: .category(selected)).category, selected,
                               "\(appearance)")
                XCTAssertTrue(LiveTVCategoryNavigation.ownsPushedBrowser(
                    fromCategories: true, isBrowserPushed: true, openedFromCategories: true))
                XCTAssertFalse(LiveTVCategoryNavigation.ownsPushedBrowser(
                    fromCategories: false, isBrowserPushed: true, openedFromCategories: true))
                XCTAssertFalse(LiveTVCategoryNavigation.shouldDismissCategories(
                    showingCategories: true, browserPushedFromCategories: true))
                // A canceled edge swipe keeps the child; a completed swipe and toolbar Back
                // both report false through the same binding setter.
                XCTAssertFalse(LiveTVCategoryNavigation.shouldHandleBrowserPop(
                    fromCategories: true, openedFromCategories: true,
                    showingBrowser: true, stackShowsBrowser: true))
                XCTAssertTrue(LiveTVCategoryNavigation.shouldHandleBrowserPop(
                    fromCategories: true, openedFromCategories: true,
                    showingBrowser: true, stackShowsBrowser: false))
                XCTAssertTrue(LiveTVCategoryNavigation.shouldDismissCategories(
                    showingCategories: true, browserPushedFromCategories: false))
            }
        }
    }

    func testBuild781RecentHistoryCanPersistWithoutMovingLiveNavigationRow() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let provider = UUID()
        var visible = LiveTVCategoryPreferences()
        for appearance in LiveTVCategoryAppearance.allCases {
            visible.appearance = appearance
            var saved = visible
            saved.opened("Sports")
            saved.save(providerID: provider, to: defaults)
            XCTAssertTrue(visible.recent.isEmpty, "Tapped row must remain in its current section during push")
            XCTAssertEqual(LiveTVCategoryPreferences.load(providerID: provider, from: defaults).recent, ["Sports"])
        }
    }

    func testCategoriesStaysUnderThePushedBrowserInTabs() {
        XCTAssertFalse(LiveTVCategoryNavigation.popsCategoriesOnChoice(isTabRoot: true))
        XCTAssertTrue(LiveTVCategoryNavigation.popsCategoriesOnChoice(isTabRoot: false))
    }

    func testFilterChoiceSetsSelection() {
        XCTAssertEqual(LiveTVCategoryNavigation.filterSelection(for: .category("Sports")), "Sports")
        XCTAssertNil(LiveTVCategoryNavigation.filterSelection(for: .all))
        XCTAssertEqual(LiveTVCategoryNavigation.browserFilters(for: .category("Disney Events")), .category("Disney Events"))
        XCTAssertEqual(LiveTVCategoryNavigation.browserFilters(for: .favorites), .favorites)
        XCTAssertEqual(LiveTVCategoryNavigation.browserFilters(for: .all), .channels)
    }

    /// The watch screen's Guide keeps Watch and its player: a fixed full-height page, never a push
    /// into the tab under the player. The full Guide pushes.
    func testGuidePresentationMatchesItsHost() {
        XCTAssertEqual(LiveTVCategoryNavigation.guidePresentation(isWatchGuide: true), .fullHeightSheet)
        XCTAssertEqual(LiveTVCategoryNavigation.guidePresentation(isWatchGuide: false), .push)
    }

    /// Home, browser and Guide each keep their own remembered row; cancelling (no remember call
    /// with a new row) leaves another caller's state alone.
    func testCallersKeepIndependentPositions() {
        let provider = UUID()
        let categories = ["A", "B", "C"]
        var home = LiveTVGuideCategoryPickerState()
        var guide = LiveTVGuideCategoryPickerState()
        home.remember(.category("C"), providerID: provider, categories: categories)
        XCTAssertEqual(home.target(providerID: provider, selectedCategory: nil, categories: categories), .category("C"))
        XCTAssertEqual(guide.target(providerID: provider, selectedCategory: "B", categories: categories), .category("B"))
        guide.reconcile(providerID: provider, categories: categories)
        XCTAssertEqual(home.target(providerID: provider, selectedCategory: nil, categories: ["A"]), .allCategories)
    }

    // MARK: Performance

    /// Data preparation runs once per page open or catalog change, separately from scrolling.
    func testDirectoryBuildIsFastForLargeCatalogs() {
        let categories = (0..<600).map { "Region \($0 % 12) | Category \($0)" }
        let channels = (0..<40_000).map { channel("ch\($0)", categories[$0 % categories.count], logo: $0 % 3 == 0) }
        let favorites = Set((0..<200).map { "ch\($0 * 7)" })
        let start = ProcessInfo.processInfo.systemUptime
        let directory = LiveTVCategoryDirectory.build(categories: categories, channels: channels, favoriteIDs: favorites)
        let buildMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let projStart = ProcessInfo.processInfo.systemUptime
        for query in ["", "R", "Region 3", "Category 59", "zzz"] {
            _ = LiveTVGuideCategoryPickerModel.projection(categories: categories, query: query,
                                                          frequent: directory.frequent)
        }
        let projectionMS = (ProcessInfo.processInfo.systemUptime - projStart) * 1000 / 5
        print("Build 73 category directory: build \(String(format: "%.1f", buildMS)) ms, "
              + "projection \(String(format: "%.2f", projectionMS)) ms/query (600 categories, 40k channels)")
        XCTAssertEqual(directory.entry(for: categories[0]).channelCount, 40_000 / 600 + 1)
        XCTAssertLessThan(buildMS, 500, "unoptimized host build; device Release is far faster")
        XCTAssertLessThan(projectionMS, 50)
    }
}

/// Exercises the actual NavigationPath mutation adapter used by LiveTVView, not Boolean destinations.
final class KyroExplicitNavigationPathTests: XCTestCase {
    private func push(_ routes: inout LiveTVHomeRoutes, _ root: inout NavigationPath,
                      _ change: (inout LiveTVHomeRoutes) -> Void) {
        let before = routes.path
        change(&routes)
        routes.apply(previous: before, to: &root, reason: "test intent")
    }

    func testNativeBackAndSwipeRemoveOnlyOneTypedDestination() {
        for appearance in LiveTVCategoryAppearance.allCases {
            for source in ["pinned", "recent", "ordinary"] {
                var routes = LiveTVHomeRoutes()
                var root = NavigationPath()
                push(&routes, &root) { $0.openCategories(source: "Home") }
                XCTAssertEqual(root, NavigationPath([LiveTVHomeRoutes.Destination.categories]))
                for _ in 0..<3 {
                    push(&routes, &root) { $0.openBrowser(fromCategories: true, source: source, category: "Sports") }
                    XCTAssertEqual(root, NavigationPath(routes.path), "\(appearance)")
                    XCTAssertEqual(root.count, 2)
                    // Canceled swipe / playback return: same path; no disappearance callback mutates it.
                    routes.reconcile(rootDepth: root.count)
                    XCTAssertEqual(root.count, 2)
                    root.removeLast() // same native path mutation for Back and completed swipe
                    routes.reconcile(rootDepth: root.count)
                    XCTAssertEqual(routes.path, [.categories])
                    XCTAssertEqual(root.count, 1)
                    routes.reconcile(rootDepth: root.count) // duplicate notification does not pop again
                    XCTAssertEqual(root.count, 1)
                }
                root.removeLast()
                routes.reconcile(rootDepth: root.count)
                XCTAssertTrue(routes.path.isEmpty)
                XCTAssertTrue(root.isEmpty)
            }
        }
    }

    func testRepeatedSelectionRefreshAndPreferenceChangesPreserveIdentity() {
        var routes = LiveTVHomeRoutes()
        var root = NavigationPath()
        let provider = UUID()
        push(&routes, &root) { $0.openCategories(source: "Home") }
        push(&routes, &root) { $0.openBrowser(fromCategories: true, source: "recent", providerID: provider, category: "News") }
        let snapshot = root
        push(&routes, &root) { $0.openBrowser(fromCategories: true, source: "pinned", providerID: provider, category: "News") }
        XCTAssertEqual(root, snapshot)
        var preferences = LiveTVCategoryPreferences()
        for appearance in LiveTVCategoryAppearance.allCases { preferences.appearance = appearance }
        preferences.opened("News")
        preferences.togglePin("News")
        preferences.hidden.insert("News")
        routes.reconcile(rootDepth: root.count) // unchanged provider refresh / playback return
        XCTAssertEqual(root, snapshot)
        push(&routes, &root) { $0.closeBrowser(reason: "provider changed / category removed") }
        XCTAssertEqual(root, NavigationPath([LiveTVHomeRoutes.Destination.categories]))
    }

    func testDirectBrowserAndExistingShellPrefixArePreserved() {
        var root = NavigationPath()
        root.append("existing shell destination")
        var routes = LiveTVHomeRoutes()
        push(&routes, &root) { $0.openBrowser(fromCategories: false, source: "Home") }
        XCTAssertEqual(root.count, 2)
        root.removeLast()
        routes.reconcile(rootDepth: root.count)
        XCTAssertTrue(routes.path.isEmpty)
        XCTAssertEqual(root.count, 1)
    }

    func testGuideSelectionDoesNotMutateHomePath() {
        var routes = LiveTVHomeRoutes()
        var root = NavigationPath()
        push(&routes, &root) { $0.openCategories(source: "Home") }
        let before = root
        XCTAssertEqual(LiveTVCategoryNavigation.filterSelection(for: .category("Sports")), "Sports")
        XCTAssertEqual(LiveTVCategoryNavigation.guidePresentation(isWatchGuide: true), .fullHeightSheet)
        XCTAssertEqual(LiveTVCategoryNavigation.guidePresentation(isWatchGuide: false), .push)
        XCTAssertEqual(root, before)
    }

    func testHomeCannotPopAnUnrelatedShellDestination() {
        var routes = LiveTVHomeRoutes()
        var root = NavigationPath()
        push(&routes, &root) { $0.openCategories(source: "Home") }
        push(&routes, &root) { $0.openBrowser(fromCategories: true, source: "pinned") }
        root.append("unrelated shell destination")
        let before = root
        push(&routes, &root) { $0.closeBrowser(reason: "stale callback") }
        XCTAssertEqual(root, before)
        XCTAssertEqual(routes.path.count, 2)
    }
}

/// Build 82: Live TV's Categories and channel routes live on the shell's own `NavigationPath` and
/// are registered by `liveTVShellRoutes` beside the shell's `Route` registration. These drive the
/// production ledger (`LiveTVHomeRoutes.perform`/`reconcile`, the exact calls `LiveTVBrowseModel`
/// makes) and the production resolver (`LiveTVRouteScreen`). Whether UIKit draws the screens is
/// not testable here; that needs the iPhone.
final class KyroBuild82ShellRouteTests: XCTestCase {
    private typealias Destination = LiveTVHomeRoutes.Destination

    private func perform(_ routes: inout LiveTVHomeRoutes, _ root: inout NavigationPath,
                         _ change: (inout LiveTVHomeRoutes) -> Void) {
        routes.perform(on: &root, reason: "test", change)
    }

    func testEveryLiveTVRouteResolvesToItsScreen() {
        XCTAssertEqual(LiveTVRouteScreen.screen(for: .categories), .categories)
        for route: Destination in [.channels(provider: nil, category: nil),
                                   .channels(provider: UUID(), category: "USA | Sports"),
                                   .channels(provider: UUID(), category: "")] {
            XCTAssertEqual(LiveTVRouteScreen.screen(for: route), .channelBrowser)
        }
    }

    func testHomeCategoriesChannelsBackBackOnTheShellPathInEveryAppearance() {
        for appearance in LiveTVCategoryAppearance.allCases {
            for source in ["list row", "grid card", "hybrid tile", "pinned", "recently visited"] {
                var routes = LiveTVHomeRoutes()
                var root = NavigationPath()
                perform(&routes, &root) { $0.openCategories(source: "Home View All") }
                XCTAssertEqual(root, NavigationPath([Destination.categories]), "\(appearance) \(source)")
                XCTAssertEqual(routes.path.map(LiveTVRouteScreen.screen(for:)), [.categories])
                perform(&routes, &root) { $0.openBrowser(fromCategories: true, source: source, category: "News") }
                XCTAssertEqual(root.count, 2)
                XCTAssertEqual(routes.path.map(LiveTVRouteScreen.screen(for:)), [.categories, .channelBrowser])
                // Toolbar Back and a completed edge swipe are the same native removal.
                root.removeLast()
                XCTAssertTrue(routes.reconcile(rootDepth: root.count), "closing the browser is reported once")
                XCTAssertEqual(routes.path, [.categories], "first Back returns to Categories: \(appearance) \(source)")
                XCTAssertFalse(routes.reconcile(rootDepth: root.count), "a duplicate notification changes nothing")
                root.removeLast()
                XCTAssertFalse(routes.reconcile(rootDepth: root.count))
                XCTAssertTrue(routes.path.isEmpty, "second Back returns Home: \(appearance) \(source)")
                XCTAssertTrue(root.isEmpty)
            }
        }
    }

    func testDirectHomeBrowserPushesOneRouteAndBacksHome() {
        var routes = LiveTVHomeRoutes()
        var root = NavigationPath()
        perform(&routes, &root) { $0.openBrowser(fromCategories: false, source: "All Channels") }
        XCTAssertEqual(routes.path.map(LiveTVRouteScreen.screen(for:)), [.channelBrowser])
        XCTAssertEqual(routes.browserOwner, .home)
        root.removeLast()
        XCTAssertTrue(routes.reconcile(rootDepth: root.count))
        XCTAssertTrue(routes.path.isEmpty)
    }

    func testATapAfterAnUnobservedSwipeIsAppliedNotDropped() {
        // Build 81 rejected this intent as stale, so the next category tap did nothing.
        var routes = LiveTVHomeRoutes()
        var root = NavigationPath()
        perform(&routes, &root) { $0.openCategories(source: "Home") }
        perform(&routes, &root) { $0.openBrowser(fromCategories: true, source: "list row", category: "News") }
        root.removeLast() // swipe completed; the shell's onChange has not reached the model yet
        perform(&routes, &root) { $0.openBrowser(fromCategories: true, source: "list row", category: "Sports") }
        XCTAssertEqual(root.count, 2)
        XCTAssertEqual(routes.path, [.categories, .channels(provider: nil, category: "Sports")])
    }

    func testRepeatedSelectionsNeverStackDuplicateBrowsers() {
        var routes = LiveTVHomeRoutes()
        var root = NavigationPath()
        perform(&routes, &root) { $0.openCategories(source: "Home") }
        for index in 0..<20 {
            perform(&routes, &root) { $0.openBrowser(fromCategories: true, source: "pinned", category: "C\(index % 3)") }
            XCTAssertEqual(root.count, 2, "selection \(index)")
            root.removeLast()
            routes.reconcile(rootDepth: root.count)
        }
        XCTAssertEqual(root, NavigationPath([Destination.categories]))
    }

    func testPushedLiveTVKeepsTheShellEntriesBeneathIt() {
        // The earlier shell pushes Live TV itself as a `Route`; its routes start above that entry.
        var root = NavigationPath()
        root.append("Route.liveTV")
        var routes = LiveTVHomeRoutes()
        perform(&routes, &root) { $0.openCategories(source: "Home") }
        perform(&routes, &root) { $0.openBrowser(fromCategories: true, source: "list row") }
        XCTAssertEqual(root.count, 3)
        root.removeLast()
        routes.reconcile(rootDepth: root.count)
        root.removeLast()
        routes.reconcile(rootDepth: root.count)
        XCTAssertTrue(routes.path.isEmpty)
        XCTAssertEqual(root.count, 1, "Live TV itself stays on the stack")
    }

    func testProviderChangeOrRemovedCategoryPopsOnlyTheBrowser() {
        var routes = LiveTVHomeRoutes()
        var root = NavigationPath()
        perform(&routes, &root) { $0.openCategories(source: "Home") }
        perform(&routes, &root) { $0.openBrowser(fromCategories: true, source: "list row", category: "Gone") }
        perform(&routes, &root) { $0.closeBrowser(reason: "catalog removed selected category") }
        XCTAssertEqual(root, NavigationPath([Destination.categories]))
        perform(&routes, &root) { $0.closeBrowser(reason: "duplicate") }
        XCTAssertEqual(root, NavigationPath([Destination.categories]))
    }

    func testPlaybackReturnAndShellResetKeepOneOwner() {
        var routes = LiveTVHomeRoutes()
        var root = NavigationPath()
        perform(&routes, &root) { $0.openCategories(source: "Home") }
        perform(&routes, &root) { $0.openBrowser(fromCategories: true, source: "list row") }
        let snapshot = root
        // Playback is a full-screen cover: the path does not change, so nothing is popped.
        XCTAssertFalse(routes.reconcile(rootDepth: root.count))
        XCTAssertEqual(root, snapshot)
        XCTAssertEqual(routes.browserOwner, .categories)
        // A shell reset (deep link, tab change from the shell, server switch) clears the path.
        root = NavigationPath()
        XCTAssertTrue(routes.reconcile(rootDepth: root.count))
        XCTAssertTrue(routes.path.isEmpty)
        // The next visit starts from a fresh base.
        perform(&routes, &root) { $0.openCategories(source: "Home") }
        XCTAssertEqual(root, NavigationPath([Destination.categories]))
    }

    /// Source guard for the rule Build 81 broke and only a device showed: Live TV's typed routes
    /// are registered once, by the shell modifier, and each shell stack that can host Live TV
    /// applies it. A registration inside the Live TV tab is invisible to the shell's stack.
    func testLiveTVRoutesAreRegisteredAtTheShellNotInsideTheTab() throws {
        let repo = ProcessInfo.processInfo.environment["KYRO_REPO_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
        }
        let registration = "navigationDestination(for: LiveTVHomeRoutes.Destination.self)"
        XCTAssertFalse(try source("iosApp/iosApp/LiveTV/LiveTVViews.swift").contains(registration),
                       "Live TV Home is tab content; its registration would not reach the shell stack")
        XCTAssertEqual(try source("iosApp/iosApp/LiveTV/LiveTVBrowseModel.swift").components(separatedBy: registration).count - 1, 1)
        let shell = try source("iosApp/iosApp/ContentView.swift")
        XCTAssertEqual(shell.components(separatedBy: ".liveTVShellRoutes(service: .shared, path: $router.path)").count - 1, 2,
                       "the phone tab stack and the iPad sidebar stack")
    }
}

/// Build 82.1: Categories large-title top entry and per-category channel-list scroll isolation.
/// These assert the pure restore policy and route ledger; SwiftUI's actual scroll offset needs the iPhone.
final class KyroBuild821ScrollPositionTests: XCTestCase {
    private typealias Destination = LiveTVHomeRoutes.Destination

    func testFreshCategoriesAppearUsesNaturalTopNotAllCategoriesScrollID() {
        XCTAssertNil(LiveTVCategoryScrollRestore.positionForAppear(nil))
        XCTAssertNil(LiveTVCategoryScrollRestore.positionForAppear(.allCategories),
                     "scrolling .allCategories to top hides the search field above the target layout")
        XCTAssertFalse(LiveTVCategoryScrollRestore.isMidListRestore(nil))
        XCTAssertFalse(LiveTVCategoryScrollRestore.isMidListRestore(.allCategories))
    }

    func testReturningFromChildCanRestoreMidListCategoryRow() {
        let mid = LiveTVGuideCategoryPickerID.category("24/7 Cartoon")
        XCTAssertEqual(LiveTVCategoryScrollRestore.positionForAppear(mid), mid)
        XCTAssertTrue(LiveTVCategoryScrollRestore.isMidListRestore(mid))
    }

    func testNewCategorySelectionNeverResumesSavedBrowserOffset() {
        XCTAssertFalse(LiveTVBrowserScrollPolicy.shouldResumeSavedPosition(
            fromCategories: true, resumingSavedPosition: true))
        XCTAssertFalse(LiveTVBrowserScrollPolicy.shouldResumeSavedPosition(
            fromCategories: true, resumingSavedPosition: false))
        XCTAssertTrue(LiveTVBrowserScrollPolicy.shouldResumeSavedPosition(
            fromCategories: false, resumingSavedPosition: true),
                      "Home → All/Favorites may still resume the exact Home snapshot")
        XCTAssertFalse(LiveTVBrowserScrollPolicy.shouldResumeSavedPosition(
            fromCategories: false, resumingSavedPosition: false))
    }

    func testDifferentCategoriesCannotShareListIdentity() {
        let provider = UUID()
        let cartoon = LiveTVBrowserScrollPolicy.listIdentity(
            providerID: provider, category: "24/7 Cartoon", favoritesOnly: false, searchQuery: "")
        let cinema = LiveTVBrowserScrollPolicy.listIdentity(
            providerID: provider, category: "24/7 Cinemania", favoritesOnly: false, searchQuery: "")
        let all = LiveTVBrowserScrollPolicy.listIdentity(
            providerID: provider, category: nil, favoritesOnly: false, searchQuery: "")
        let favorites = LiveTVBrowserScrollPolicy.listIdentity(
            providerID: provider, category: nil, favoritesOnly: true, searchQuery: "")
        XCTAssertNotEqual(cartoon, cinema)
        XCTAssertNotEqual(cartoon, all)
        XCTAssertNotEqual(all, favorites)
        XCTAssertEqual(
            LiveTVBrowserScrollPolicy.listIdentity(
                providerID: provider, category: "24/7 Cartoon", favoritesOnly: false, searchQuery: ""),
            cartoon)
    }

    func testProviderChangeInvalidatesListIdentityAndForeignResume() {
        let a = UUID()
        let b = UUID()
        XCTAssertNotEqual(
            LiveTVBrowserScrollPolicy.listIdentity(providerID: a, category: "News", favoritesOnly: false, searchQuery: ""),
            LiveTVBrowserScrollPolicy.listIdentity(providerID: b, category: "News", favoritesOnly: false, searchQuery: ""))
        let snapshot = LiveTVBrowsingContext(
            providerID: a, category: "News", favoritesOnly: false, searchQuery: "",
            channelID: "\(a.uuidString.lowercased())|row-9", offsetX: 0, offsetY: 420,
            isBrowserVisible: false)
        XCTAssertNil(snapshot.resumedBrowser(for: LiveTVBrowserFilters(query: "", category: "Sports", favoritesOnly: false)),
                     "a different category must not inherit the saved offset")
        XCTAssertNotNil(snapshot.resumedBrowser(for: LiveTVBrowserFilters(query: "", category: "News", favoritesOnly: false)))
    }

    func testPlaybackCoverLeavesShellPathAndOwnerUntouched() {
        var routes = LiveTVHomeRoutes()
        var root = NavigationPath()
        routes.perform(on: &root, reason: "test") { $0.openCategories(source: "Home") }
        routes.perform(on: &root, reason: "test") {
            $0.openBrowser(fromCategories: true, source: "list", category: "News")
        }
        let before = root
        XCTAssertFalse(routes.reconcile(rootDepth: root.count),
                       "Watch is a cover; returning must not pop Channels")
        XCTAssertEqual(root, before)
        XCTAssertEqual(routes.browserOwner, .categories)
    }

    func testRepeatedBackAndSwipeStillPopOneLiveTVRouteAtATime() {
        for _ in 0..<3 {
            var routes = LiveTVHomeRoutes()
            var root = NavigationPath()
            routes.perform(on: &root, reason: "test") { $0.openCategories(source: "Home") }
            routes.perform(on: &root, reason: "test") {
                $0.openBrowser(fromCategories: true, source: "recent", category: "Kids")
            }
            root.removeLast()
            XCTAssertTrue(routes.reconcile(rootDepth: root.count))
            XCTAssertEqual(routes.path, [.categories])
            root.removeLast()
            XCTAssertFalse(routes.reconcile(rootDepth: root.count))
            XCTAssertTrue(routes.path.isEmpty)
            XCTAssertTrue(root.isEmpty)
        }
    }

    func testChannelsRouteIdentityChangesWithCategorySoListsDoNotReuse() {
        let provider = UUID()
        let a: Destination = .channels(provider: provider, category: "24/7 Cartoon")
        let b: Destination = .channels(provider: provider, category: "24/7 Cinemania")
        XCTAssertNotEqual(a, b)
        var routes = LiveTVHomeRoutes()
        var root = NavigationPath()
        routes.perform(on: &root, reason: "test") { $0.openCategories(source: "Home") }
        routes.perform(on: &root, reason: "test") {
            $0.openBrowser(fromCategories: true, source: "a", providerID: provider, category: "24/7 Cartoon")
        }
        routes.perform(on: &root, reason: "test") {
            $0.openBrowser(fromCategories: true, source: "b", providerID: provider, category: "24/7 Cinemania")
        }
        XCTAssertEqual(routes.path, [.categories, b])
        XCTAssertEqual(root.count, 2)
    }
}
