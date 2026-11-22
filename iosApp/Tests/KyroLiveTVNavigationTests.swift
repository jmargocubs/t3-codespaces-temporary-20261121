#if os(iOS)
import CoreGraphics
import XCTest
@testable import Silo

final class KyroLiveTVNavigationTests: XCTestCase {
    /// Live TV content areas (inside the navigation bar and home indicator) on
    /// the smallest and largest supported iPhones, and a landscape phone.
    private let screens: [(name: String, size: CGSize)] = [
        ("iPhone SE", CGSize(width: 375, height: 603)),
        ("iPhone 17", CGSize(width: 402, height: 724)),
        ("iPhone 16 Plus", CGSize(width: 430, height: 795)),
        ("iPhone 18 Pro Max", CGSize(width: 440, height: 818)),
        ("iPhone 17 landscape", CGSize(width: 750, height: 349)),
    ]
    private let positions: [Double] = [0, 0.05, 0.15, 0.3, 0.5, 0.7, 0.85, 0.95, 1]

    private func geometry(_ size: CGSize) -> KyroNavigationGeometry {
        KyroNavigationGeometry(bounds: CGRect(origin: .zero, size: size))
    }

    // MARK: Destinations and preferences

    func testInitialDestinationsAreTheFiveExistingScreensAndSportsHubNeverAppears() {
        let preferences = KyroLiveTVNavigationPreferences()
        XCTAssertEqual(preferences.visibleDestinations, [.home, .guide, .favorites, .channels, .search])
        XCTAssertFalse(KyroLiveTVDestination.sportsHub.isAvailable)
        XCTAssertFalse(KyroLiveTVDestination.available.contains(.sportsHub))

        // Even a saved order that names it, first, keeps it out.
        let json = #"{"order":["sportsHub","search","home"],"hidden":[]}"#
        let decoded = try? JSONDecoder().decode(KyroLiveTVNavigationPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(decoded?.visibleDestinations, [.search, .home, .guide, .favorites, .channels])
    }

    func testHomeCannotBeHiddenSoTheUserAlwaysHasAWayBack() {
        var preferences = KyroLiveTVNavigationPreferences()
        for destination in KyroLiveTVDestination.allCases { preferences.setVisible(false, for: destination) }
        XCTAssertEqual(preferences.visibleDestinations, [.home])

        let json = #"{"hidden":["home","guide"]}"#
        let decoded = try? JSONDecoder().decode(KyroLiveTVNavigationPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(decoded?.visibleDestinations, [.home, .favorites, .channels, .search])
    }

    func testReorderingAndShowingAgainKeepEachDestinationsPlace() {
        var preferences = KyroLiveTVNavigationPreferences()
        preferences.move(fromOffsets: IndexSet(integer: 4), toOffset: 0)
        XCTAssertEqual(preferences.visibleDestinations, [.search, .home, .guide, .favorites, .channels])
        preferences.move(fromOffsets: IndexSet(integer: 0), toOffset: 5)
        XCTAssertEqual(preferences.visibleDestinations, [.home, .guide, .favorites, .channels, .search])

        preferences.setVisible(false, for: .guide)
        preferences.move(fromOffsets: IndexSet(integer: 1), toOffset: 4)
        preferences.setVisible(true, for: .guide)
        XCTAssertEqual(preferences.visibleDestinations, [.home, .favorites, .channels, .guide, .search])

        preferences.resetDestinations()
        XCTAssertEqual(preferences.visibleDestinations, KyroLiveTVDestination.defaultOrder)
    }

    /// Classic is the default for anyone without saved navigation; a style saved by
    /// Build 14 or 15 (always a floating one) is kept, with its positions.
    @MainActor
    func testClassicIsTheDefaultAndSavedFloatingStylesAreKept() throws {
        XCTAssertEqual(KyroLiveTVNavigationPreferences().style, .classic)
        XCTAssertFalse(KyroLiveTVNavigationStyle.classic.isFloating)
        XCTAssertEqual(KyroLiveTVNavigationStyle.allCases.first, .classic, "Listed first in Settings")

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "kyro.tests.navigation.migration"))
        defaults.removePersistentDomain(forName: "kyro.tests.navigation.migration")
        XCTAssertEqual(KyroLiveTVNavigationStore(defaults: defaults).preferences.style, .classic, "Nothing saved")

        for (saved, expected) in [("glassDock", KyroLiveTVNavigationStyle.glassDock), ("thumbFan", .thumbFan)] {
            let build15 = #"{"style":"\#(saved)","order":["home","guide","favorites","channels","search"],"hidden":[],"#
                + #""autoCollapse":true,"idleBehavior":"collapse","hapticsEnabled":true,"thumbScrubbing":true,"#
                + #""allowsDragging":true,"startingEdge":"right","fanAnchor":{"edge":"left","position":0.25}}"#
            defaults.set(Data(build15.utf8), forKey: KyroLiveTVNavigationStore.defaultsKey)
            let store = KyroLiveTVNavigationStore(defaults: defaults)
            XCTAssertEqual(store.preferences.style, expected, "Saved \(saved) is kept")
            XCTAssertEqual(store.preferences.anchor(for: .thumbFan), KyroNavigationAnchor(edge: .left, position: 0.25))
        }

        var preferences = KyroLiveTVNavigationPreferences()
        preferences.setAnchor(KyroNavigationAnchor(edge: .top, position: 0.1), for: .classic)
        XCTAssertEqual(preferences, KyroLiveTVNavigationPreferences(), "Classic has no position to save")
        defaults.removePersistentDomain(forName: "kyro.tests.navigation.migration")
    }

    func testPreferencesRoundTripAndTolerateMissingUnknownAndDuplicateValues() throws {
        var preferences = KyroLiveTVNavigationPreferences()
        preferences.style = .thumbFan
        preferences.autoCollapse = false
        preferences.idleBehavior = .collapseAndFade
        preferences.hapticsEnabled = false
        preferences.thumbScrubbing = false
        preferences.allowsDragging = false
        preferences.startingEdge = .left
        preferences.setVisible(false, for: .channels)
        preferences.setAnchor(KyroNavigationAnchor(edge: .top, position: 0.2), for: .thumbFan)
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(KyroLiveTVNavigationPreferences.self, from: data), preferences)

        let messy = #"{"style":"hologram","order":["guide","guide","teleport"],"idleBehavior":"sleep","fanAnchor":{"edge":"left","position":7}}"#
        let decoded = try JSONDecoder().decode(KyroLiveTVNavigationPreferences.self, from: Data(messy.utf8))
        XCTAssertEqual(decoded.style, .classic, "An unknown style falls back to the default")
        XCTAssertEqual(decoded.idleBehavior, .collapse)
        XCTAssertEqual(decoded.visibleDestinations, [.guide, .home, .favorites, .channels, .search])
        XCTAssertEqual(decoded.anchor(for: .thumbFan), KyroNavigationAnchor(edge: .left, position: 1))
        XCTAssertEqual(try JSONDecoder().decode(KyroLiveTVNavigationPreferences.self, from: Data("{}".utf8)),
                       KyroLiveTVNavigationPreferences())
    }

    func testEachStyleKeepsItsOwnPositionAndResetReturnsToTheStartingEdge() {
        var preferences = KyroLiveTVNavigationPreferences()
        XCTAssertEqual(preferences.anchor(for: .glassDock).edge, .right, "Default starting edge is Right")
        preferences.setAnchor(KyroNavigationAnchor(edge: .left, position: 0.3), for: .glassDock)
        preferences.setAnchor(KyroNavigationAnchor(edge: .bottom, position: 0.8), for: .thumbFan)
        XCTAssertEqual(preferences.anchor(for: .glassDock), KyroNavigationAnchor(edge: .left, position: 0.3))
        XCTAssertEqual(preferences.anchor(for: .thumbFan), KyroNavigationAnchor(edge: .bottom, position: 0.8))

        preferences.startingEdge = .top
        preferences.resetPositions()
        XCTAssertEqual(preferences.anchor(for: .glassDock), .default(for: .top))
        XCTAssertEqual(preferences.anchor(for: .thumbFan), .default(for: .top))
    }

    @MainActor
    func testStoreSavesLocallyReloadsAndResets() throws {
        let suite = "KyroLiveTVNavigationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = KyroLiveTVNavigationStore(defaults: defaults)
        store.preferences.style = .thumbFan
        store.preferences.setAnchor(KyroNavigationAnchor(edge: .left, position: 0.25), for: .thumbFan)
        store.isExpanded = true

        let reloaded = KyroLiveTVNavigationStore(defaults: defaults)
        XCTAssertEqual(reloaded.preferences, store.preferences)
        XCTAssertFalse(reloaded.isExpanded, "The navigation always starts collapsed")

        reloaded.resetAll()
        XCTAssertEqual(KyroLiveTVNavigationStore(defaults: defaults).preferences, KyroLiveTVNavigationPreferences())
    }

    func testActiveDestinationComesFromTheExistingLiveTVState() {
        typealias Active = KyroLiveTVActiveDestination
        XCTAssertEqual(Active.resolve(showingGuide: false, showingBrowser: false, searching: false, favoritesOnly: false), .home)
        XCTAssertEqual(Active.resolve(showingGuide: true, showingBrowser: true, searching: true, favoritesOnly: true), .guide)
        XCTAssertEqual(Active.resolve(showingGuide: false, showingBrowser: true, searching: true, favoritesOnly: true), .search)
        XCTAssertEqual(Active.resolve(showingGuide: false, showingBrowser: true, searching: false, favoritesOnly: true), .favorites)
        XCTAssertEqual(Active.resolve(showingGuide: false, showingBrowser: true, searching: false, favoritesOnly: false), .channels)
    }

    // MARK: Unified destination row and Favorites

    func testTheRowAlwaysOffersTheFiveDestinationsWithFavoritesAndSearchVisible() {
        XCTAssertEqual(KyroLiveTVDestination.navigationRow, [.home, .guide, .favorites, .channels, .search])
        XCTAssertTrue(KyroLiveTVDestination.navigationRow.allSatisfy(\.isAvailable))
        // Classic's bar lets the user hide a destination; the unified row never does.
        var preferences = KyroLiveTVNavigationPreferences()
        preferences.setVisible(false, for: .favorites)
        XCTAssertFalse(preferences.visibleDestinations.contains(.favorites))
        XCTAssertTrue(KyroLiveTVDestination.navigationRow.contains(.favorites))
    }

    func testFavoritesUsesAStarAndEveryRowDestinationHasADistinctActiveState() {
        XCTAssertEqual(KyroLiveTVDestination.favorites.systemImage, "star")
        XCTAssertEqual(KyroLiveTVDestination.favorites.activeSystemImage, "star.fill")
        XCTAssertEqual(KyroLiveTVDestination.favorites.title, "Favorites")
        for destination in KyroLiveTVDestination.navigationRow {
            XCTAssertFalse(destination.systemImage.contains("heart"), "\(destination.title) uses no heart")
            XCTAssertFalse(destination.title.isEmpty)
        }
    }

    func testEachRowDestinationResolvesFromLiveTVState() {
        typealias Active = KyroLiveTVActiveDestination
        let reached: Set<KyroLiveTVDestination> = [
            Active.resolve(showingGuide: false, showingBrowser: false, searching: false, favoritesOnly: false),
            Active.resolve(showingGuide: true, showingBrowser: false, searching: false, favoritesOnly: false),
            Active.resolve(showingGuide: false, showingBrowser: true, searching: false, favoritesOnly: true),
            Active.resolve(showingGuide: false, showingBrowser: true, searching: false, favoritesOnly: false),
            Active.resolve(showingGuide: false, showingBrowser: true, searching: true, favoritesOnly: false),
        ]
        XCTAssertEqual(reached, Set(KyroLiveTVDestination.navigationRow))
        // Leaving Search for Favorites must resolve Favorites, not a stale search.
        XCTAssertEqual(Active.resolve(showingGuide: false, showingBrowser: true, searching: false, favoritesOnly: true),
                       .favorites)
    }

    func testFavoritesStateSeparatesUnavailableLoadingEmptyAndPopulated() {
        typealias State = LiveTVFavoritesState
        XCTAssertEqual(State.resolve(contentState: .setup, visibleCount: 0, isSearching: false), .unavailable)
        XCTAssertEqual(State.resolve(contentState: .loading, visibleCount: 0, isSearching: true), .unavailable)
        XCTAssertEqual(State.resolve(contentState: .noChannels, visibleCount: 0, isSearching: false), .unavailable)
        XCTAssertEqual(State.resolve(contentState: .ready, visibleCount: 0, isSearching: true), .loading,
                       "the first pass is still running: no empty-state flash")
        XCTAssertEqual(State.resolve(contentState: .ready, visibleCount: 0, isSearching: false), .empty)
        XCTAssertEqual(State.resolve(contentState: .ready, visibleCount: 3, isSearching: true), .populated(3),
                       "channels already shown stay shown while a refresh runs")
        XCTAssertTrue(State.emptyDescription.contains("star"), "the empty state explains how to add Favorites")
    }

    @MainActor
    func testTheChannelSearchModelReportsWhenItsPassIsRunning() async {
        let channels = (0..<5).map { index in
            LiveTVChannel(id: "p:\(index)", guideID: nil, name: "Channel \(index)",
                          streamURL: URL(string: "https://fixture.invalid/\(index).m3u8")!, logoURL: nil, category: "News")
        }
        let search = LiveTVChannelSearchModel()
        XCTAssertFalse(search.isSearching)
        // The Favorites screen asks for one flat list, in catalog order, rather than category groups.
        search.update(channels: channels, query: "", category: nil, favoritesOnly: true, favoriteIDs: ["p:3", "p:1"],
                      debounce: .zero, includeGroups: false)
        XCTAssertTrue(search.isSearching, "set synchronously, before the first frame of the Favorites screen")
        await search.waitForCurrentSearch()
        XCTAssertFalse(search.isSearching)
        XCTAssertEqual(search.matches.map(\.id), ["p:1", "p:3"], "Favorites keep catalog order")
        XCTAssertEqual(search.resultCount, 2)
        search.update(channels: channels, query: "", category: nil, favoritesOnly: true, favoriteIDs: [],
                      debounce: .zero, includeGroups: false)
        search.cancel()
        XCTAssertFalse(search.isSearching)
    }

    // MARK: Snapping

    func testReleasedHandleSnapsToTheNearestEdgeAndKeepsItsPlaceAlongIt() {
        let geometry = geometry(CGSize(width: 402, height: 724))
        let track = geometry.track
        XCTAssertEqual(geometry.anchor(snapping: CGPoint(x: 20, y: 300)).edge, .left)
        XCTAssertEqual(geometry.anchor(snapping: CGPoint(x: 390, y: 300)).edge, .right)
        XCTAssertEqual(geometry.anchor(snapping: CGPoint(x: 200, y: 10)).edge, .top)
        XCTAssertEqual(geometry.anchor(snapping: CGPoint(x: 200, y: 715)).edge, .bottom)

        let left = geometry.anchor(snapping: CGPoint(x: 30, y: track.minY + track.height * 0.25))
        XCTAssertEqual(left.position, 0.25, accuracy: 0.001)
        let bottom = geometry.anchor(snapping: CGPoint(x: track.minX + track.width * 0.8, y: 700))
        XCTAssertEqual(bottom.position, 0.8, accuracy: 0.001)

        // Off-screen drops clamp to a corner of the track.
        let corner = geometry.anchor(snapping: CGPoint(x: 5_000, y: -5_000))
        XCTAssertEqual(geometry.center(for: corner), CGPoint(x: track.maxX, y: track.minY))
    }

    func testSnappedPositionsSurviveAScreenSizeChangeAndStayOnScreen() {
        for screen in screens {
            let geometry = geometry(screen.size)
            for edge in KyroNavigationEdge.allCases {
                for position in positions {
                    let anchor = KyroNavigationAnchor(edge: edge, position: position)
                    let center = geometry.center(for: anchor)
                    let half = KyroNavigationGeometry.handleDiameter / 2
                    let frame = CGRect(x: center.x - half, y: center.y - half, width: half * 2, height: half * 2)
                    XCTAssertTrue(geometry.bounds.insetBy(dx: KyroNavigationGeometry.margin - 0.01,
                                                          dy: KyroNavigationGeometry.margin - 0.01).contains(frame),
                                  "\(screen.name) \(edge) \(position)")
                    // Re-snapping the handle where it sits gives back the same anchor.
                    let resnapped = geometry.anchor(snapping: center)
                    if position > 0.001 && position < 0.999 {
                        XCTAssertEqual(resnapped.edge, edge, "\(screen.name) \(edge) \(position)")
                        XCTAssertEqual(resnapped.position, position, accuracy: 0.001)
                    }
                }
            }
        }
    }

    // MARK: Adaptive Glass Dock

    func testDockIsARailOnSideEdgesAndABarOnTopAndBottomAndNeverLeavesTheScreen() {
        for screen in screens {
            let geometry = geometry(screen.size)
            let usable = geometry.bounds.insetBy(dx: KyroNavigationGeometry.margin - 0.01, dy: KyroNavigationGeometry.margin - 0.01)
            for edge in KyroNavigationEdge.allCases {
                for position in positions {
                    let layout = geometry.dockLayout(for: KyroNavigationAnchor(edge: edge, position: position), itemCount: 5)
                    let label = "\(screen.name) \(edge) \(position)"
                    XCTAssertEqual(layout.isVertical, edge.isVertical, label)
                    XCTAssertTrue(usable.contains(layout.frame), label)
                    XCTAssertGreaterThanOrEqual(layout.itemSize, 44, label)
                    XCTAssertEqual(layout.itemCenters.count, 5)
                    for (a, b) in zip(layout.itemCenters, layout.itemCenters.dropFirst()) {
                        XCTAssertGreaterThanOrEqual(hypot(b.x - a.x, b.y - a.y), layout.itemSize, label)
                    }
                    // The dock hugs the edge it snapped to.
                    switch edge {
                    case .left: XCTAssertEqual(layout.frame.minX, usable.minX, accuracy: 0.5, label)
                    case .right: XCTAssertEqual(layout.frame.maxX, usable.maxX, accuracy: 0.5, label)
                    case .top: XCTAssertEqual(layout.frame.minY, usable.minY, accuracy: 0.5, label)
                    case .bottom: XCTAssertEqual(layout.frame.maxY, usable.maxY, accuracy: 0.5, label)
                    }
                }
            }
        }
    }

    // MARK: Thumb Fan

    func testFanOpensAwayFromItsEdgeAndKeepsEveryTargetOnScreenWithoutOverlap() {
        let size = KyroNavigationGeometry.itemSize
        for screen in screens {
            let geometry = geometry(screen.size)
            let allowed = geometry.bounds.insetBy(dx: KyroNavigationGeometry.margin + size / 2 - 0.6,
                                                  dy: KyroNavigationGeometry.margin + size / 2 - 0.6)
            for edge in KyroNavigationEdge.allCases {
                for position in positions {
                    let anchor = KyroNavigationAnchor(edge: edge, position: position)
                    let handle = geometry.center(for: anchor)
                    let layout = geometry.fanLayout(for: anchor, itemCount: 5)
                    let label = "\(screen.name) \(edge) \(position)"
                    XCTAssertEqual(layout.itemCenters.count, 5, label)
                    for center in layout.itemCenters {
                        XCTAssertTrue(allowed.contains(center), "\(label) \(center)")
                        switch edge {
                        case .right: XCTAssertLessThanOrEqual(center.x, handle.x + 2.5, label)
                        case .left: XCTAssertGreaterThanOrEqual(center.x, handle.x - 2.5, label)
                        case .top: XCTAssertGreaterThanOrEqual(center.y, handle.y - 2.5, label)
                        case .bottom: XCTAssertLessThanOrEqual(center.y, handle.y + 2.5, label)
                        }
                        // No target sits under the orb.
                        XCTAssertGreaterThanOrEqual(hypot(center.x - handle.x, center.y - handle.y),
                                                    (KyroNavigationGeometry.handleDiameter + size) / 2, label)
                    }
                    for i in layout.itemCenters.indices {
                        for j in layout.itemCenters.indices where j > i {
                            let a = layout.itemCenters[i], b = layout.itemCenters[j]
                            XCTAssertGreaterThanOrEqual(hypot(a.x - b.x, a.y - b.y), size, "\(label) \(i)-\(j)")
                        }
                    }
                    // Destination order reads top to bottom on side edges, left to right otherwise.
                    let axis = layout.itemCenters.map { edge.isVertical ? $0.y : $0.x }
                    XCTAssertEqual(axis, axis.sorted(), label)
                }
            }
        }
    }

    func testFanTurnsInwardInACorner() {
        let geometry = geometry(CGSize(width: 402, height: 724))
        let topRight = geometry.fanLayout(for: KyroNavigationAnchor(edge: .right, position: 0), itemCount: 5)
        let handle = geometry.center(for: KyroNavigationAnchor(edge: .right, position: 0))
        XCTAssertTrue(topRight.itemCenters.allSatisfy { $0.y >= handle.y - 2.5 && $0.x <= handle.x + 2.5 })
        let middle = geometry.fanLayout(for: KyroNavigationAnchor(edge: .right, position: 0.5), itemCount: 5)
        XCTAssertLessThan(middle.radius, topRight.radius, "A wide arc mid-edge, a longer quarter arc in the corner")
    }

    func testScrubbingFindsTheDestinationUnderTheThumb() {
        let centers = [CGPoint(x: 100, y: 100), CGPoint(x: 100, y: 156), CGPoint(x: 100, y: 212)]
        XCTAssertEqual(KyroNavigationGeometry.index(at: CGPoint(x: 104, y: 150), in: centers, itemSize: 52), 1)
        XCTAssertEqual(KyroNavigationGeometry.index(at: CGPoint(x: 70, y: 215), in: centers, itemSize: 52), 2)
        XCTAssertNil(KyroNavigationGeometry.index(at: CGPoint(x: 300, y: 150), in: centers, itemSize: 52))
    }
}
#endif
