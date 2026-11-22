import Foundation
import XCTest
@testable import Silo

/// Live TV stabilization: the watch screen's Guide tab opens on the pushed guide's browsing state
/// and reveals the playing channel; full-screen covers survive a retune instead of being replaced;
/// full screen from an inline player is landscape; and the shared player chrome maps state the
/// same way in every player.
@MainActor
final class LiveTVPlayerStabilizationTests: XCTestCase {
    private var presentation: LiveTVPresentation!
    private var stops = 0
    private let provider = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        presentation = LiveTVPresentation(scheduler: StabilizationTestScheduler())
        stops = 0
        presentation.stopPlayback = { [unowned self] in stops += 1 }
        presentation.stopPictureInPicture = {}
        presentation.navigateToLiveTV = {}
    }

    private func channel(_ id: String) -> LiveTVChannel {
        LiveTVChannel(id: id, guideID: id, name: "Channel \(id)",
                      streamURL: URL(string: "https://tv.example/\(id).ts")!, logoURL: nil, category: "News")
    }

    // MARK: Guide hand-off to the watch screen

    func testHandoffCarriesTheGuideFiltersForItsOwnProvider() {
        let handoff = LiveTVGuideWatchHandoff(providerID: provider, category: "Sports", favoritesOnly: true,
                                              searchQuery: "  espn ", offsetX: 480)
        let filters = handoff.filters(for: provider, categories: ["News", "Sports"])
        XCTAssertEqual(filters, LiveTVBrowserFilters(query: "espn", category: "Sports", favoritesOnly: true))
        XCTAssertEqual(handoff.offsetX, 480)
        XCTAssertNil(handoff.filters(for: UUID(), categories: ["Sports"]),
                     "another provider's guide state never leaks into this one")
    }

    func testHandoffDropsACategoryTheCatalogNoLongerLists() {
        let handoff = LiveTVGuideWatchHandoff(providerID: provider, category: "Gone", favoritesOnly: false,
                                              searchQuery: "", offsetX: nil)
        XCTAssertNil(handoff.filters(for: provider, categories: ["News"])?.category)
        XCTAssertEqual(handoff.filters(for: provider, categories: [])?.category, "Gone",
                       "a catalog still loading keeps the category instead of discarding it")
    }

    func testHandoffRejectsUnusableOffsets() {
        XCTAssertNil(LiveTVGuideWatchHandoff(providerID: provider, category: nil, favoritesOnly: false,
                                             searchQuery: "", offsetX: -.infinity).offsetX)
        XCTAssertNil(LiveTVGuideWatchHandoff(providerID: provider, category: nil, favoritesOnly: false,
                                             searchQuery: "", offsetX: .nan).offsetX)
    }

    func testRevealPutsThePlayingRowOneRowBelowTheHeader() {
        let rows = (0..<40).map { "c\($0)" }
        XCTAssertEqual(LiveTVGuideWatchHandoff.revealOffsetY(channelID: "c12", rowIDs: rows, rowHeight: 54), 11 * 54)
        XCTAssertEqual(LiveTVGuideWatchHandoff.revealOffsetY(channelID: "c0", rowIDs: rows, rowHeight: 54), 0)
        XCTAssertEqual(LiveTVGuideWatchHandoff.revealOffsetY(channelID: "c1", rowIDs: rows, rowHeight: 54), 0)
        XCTAssertEqual(LiveTVGuideWatchHandoff.revealOffsetY(channelID: "c12", rowIDs: rows, rowHeight: 64,
                                                             contextRows: 0), 12 * 64)
    }

    func testRevealDoesNothingWhenTheChannelIsNotListed() {
        XCTAssertNil(LiveTVGuideWatchHandoff.revealOffsetY(channelID: "x", rowIDs: ["a", "b"], rowHeight: 54))
        XCTAssertNil(LiveTVGuideWatchHandoff.revealOffsetY(channelID: nil, rowIDs: ["a"], rowHeight: 54))
    }

    #if os(iOS)
    func testTheWatchScreenGuideIsCompact() {
        let compact = LiveTVGuideMetrics.forWatchScreen(true), regular = LiveTVGuideMetrics.forWatchScreen(false)
        XCTAssertEqual(regular, .regular, "the pushed guide keeps its geometry")
        XCTAssertLessThan(compact.rowHeight, regular.rowHeight)
        XCTAssertLessThan(compact.channelColumnWidth, regular.channelColumnWidth)
        XCTAssertLessThan(compact.headerHeight, regular.headerHeight)
        XCTAssertGreaterThanOrEqual(compact.rowHeight, 44, "rows stay a comfortable tap target")
    }
    #endif

    // MARK: Cover identity across retunes

    func testAListPlayerRetuneKeepsTheSameCover() {
        let a = channel("a"), b = channel("b")
        presentation.surfaceAppeared(.list)
        XCTAssertEqual(presentation.select(a, from: .list), .present)
        let before = presentation.coverItem(for: .list)
        XCTAssertEqual(before?.channel, a)

        // The player's channel picker retunes through `playFromPlayerPicker`.
        presentation.playerChannelChanged(to: b)
        let after = presentation.coverItem(for: .list)
        XCTAssertEqual(after?.id, before?.id, "a new cover identity would dismiss the player and stop the stream")
        XCTAssertEqual(after?.channel, b)
        XCTAssertNil(presentation.coverItem(for: .guide))
        XCTAssertEqual(stops, 0)
    }

    func testSportsFullScreenOtherStreamsKeepsTheShellCoverAndCollapsesToTheNewStream() {
        let a = channel("a"), b = channel("b")
        presentation.inlineHostAppeared()
        XCTAssertTrue(presentation.showInline(a))
        XCTAssertNil(presentation.coverItem(for: .shell), "inline playback has no cover")
        presentation.expandInline()
        let cover = presentation.coverItem(for: .shell)
        XCTAssertEqual(cover?.channel, a)

        presentation.playerChannelChanged(to: b)
        XCTAssertEqual(presentation.coverItem(for: .shell)?.id, cover?.id)
        XCTAssertFalse(LiveTVPictureInPicturePolicy.shouldStopWhenPlayerDisappears(.inline(b)))

        XCTAssertTrue(presentation.collapseToInline())
        XCTAssertEqual(presentation.phase, .inline(b))
        XCTAssertNil(presentation.coverItem(for: .shell))
        XCTAssertEqual(stops, 0)
    }

    func testDismissingTheCoverClearsItsItem() {
        presentation.surfaceAppeared(.guide)
        _ = presentation.select(channel("a"), from: .guide)
        XCTAssertNotNil(presentation.coverItem(for: .guide))
        presentation.coverDismissed(from: .guide)
        XCTAssertNil(presentation.coverItem(for: .guide))
    }

    // MARK: One session across every surface

    func testInlineFullScreenPictureInPictureAndSwitchesShareOneEngine() async {
        let engine = StabilizationFakeEngine()
        var created = 0
        let session = LiveTVPlayerSession(scheduler: StabilizationTestScheduler(),
                                          makeEngine: { created += 1; return engine }, isOtherVideoActive: { false })
        let a = channel("a"), b = channel("b"), c = channel("c")
        presentation.inlineHostAppeared()

        session.play(a)
        await settle()
        presentation.showInline(a)
        presentation.expandInline()
        session.play(a) // The full-screen player's task replays the presented channel.
        await settle()
        XCTAssertEqual(engine.loads, 1, "full screen shows the running stream")

        presentation.playerChannelChanged(to: b) // Other Streams in full screen.
        session.play(b)
        await settle()
        presentation.pictureInPictureStartedFromControl()
        XCTAssertEqual(presentation.phase, .pictureInPicture(b))
        XCTAssertFalse(LiveTVPictureInPicturePolicy.shouldStopWhenPlayerDisappears(presentation.phase),
                       "the cover closing for the window leaves the stream playing")

        var restored: Bool?
        presentation.restoreRequested { restored = $0 }
        presentation.playerDidAppear(b)
        XCTAssertEqual(restored, true)
        XCTAssertTrue(presentation.collapseToInline())
        presentation.playerChannelChanged(to: c) // Other Streams inline.
        session.play(c)
        await settle()

        XCTAssertEqual(created, 1)
        XCTAssertEqual(session.enginesCreated, 1)
        XCTAssertEqual(engine.loads, 3, "one load per distinct channel, none for surface moves")
        XCTAssertEqual(presentation.phase, .inline(c))
        XCTAssertEqual(stops, 0)
        session.stop()
    }

    // MARK: Full-screen orientation

    func testFullScreenFromAnInlinePlayerIsLandscapeOnIPhoneOnly() {
        XCTAssertEqual(LiveTVFullScreenOrientation.resolve(isPhone: true, isExpandedFromInline: true), .landscapeLocked)
        XCTAssertEqual(LiveTVFullScreenOrientation.resolve(isPhone: true, isExpandedFromInline: false), .rotatesFreely)
        XCTAssertEqual(LiveTVFullScreenOrientation.resolve(isPhone: false, isExpandedFromInline: true), .rotatesFreely)
        XCTAssertFalse(LiveTVFullScreenOrientation.landscapeLocked.showsRotateControl,
                       "a portrait toggle would bring back the letterboxed portrait player")
        XCTAssertTrue(LiveTVFullScreenOrientation.rotatesFreely.showsRotateControl)
    }

    #if os(iOS)
    func testLandscapeLockHoldsWhileUprightAndReleasesToPortraitOnExit() {
        var state = PlayerRotationState()
        state.activate(lockedOrientation: PlayerOrientationCoordinator.liveTVLandscapeLock)
        XCTAssertEqual(PlayerOrientationCoordinator.orientationMask(
            isPlayerActive: state.isPlayerActive, lockedOrientation: state.lockedOrientation), .landscape,
            "both landscape sides stay available; portrait does not")
        // The phone held upright (or Portrait Orientation Lock) prefers portrait; the lock wins.
        XCTAssertEqual(PlayerOrientationCoordinator.geometryMask(
            isPlayerActive: state.isPlayerActive, preferredOrientation: .portrait,
            lockedOrientation: state.lockedOrientation), .landscape)
        XCTAssertEqual(PlayerOrientationCoordinator.geometryMask(
            isPlayerActive: state.isPlayerActive, preferredOrientation: .landscapeLeft,
            lockedOrientation: state.lockedOrientation), .landscapeLeft)

        state.deactivate()
        XCTAssertEqual(PlayerOrientationCoordinator.orientationMask(
            isPlayerActive: state.isPlayerActive, lockedOrientation: state.lockedOrientation,
            browsingOrientations: .portrait), .portrait, "Exit Full Screen returns to the portrait inline player")
    }
    #endif

    // MARK: Shared chrome and Details text

    func testTransportControlMatchesEveryPlayer() {
        XCTAssertEqual(LiveTVTransportControl(state: .playing), .pause)
        XCTAssertEqual(LiveTVTransportControl(state: .buffering), .pause)
        XCTAssertEqual(LiveTVTransportControl(state: .paused), .resume)
        XCTAssertNil(LiveTVTransportControl(state: .connecting))
        XCTAssertNil(LiveTVTransportControl(state: .failed), "a failure never shows a pause control")
        XCTAssertNil(LiveTVTransportControl(state: .stopped))
    }

    func testEmbeddedGuideDefaultsToListAndRemembersAChoice() {
        XCTAssertEqual(LiveTVEmbeddedGuideStyle.defaultsKey, "liveTV.watchGuide.style.v1")
        XCTAssertEqual(LiveTVEmbeddedGuideStyle.resolve(stored: nil), .list)
        XCTAssertEqual(LiveTVEmbeddedGuideStyle.resolve(stored: ""), .list)
        XCTAssertEqual(LiveTVEmbeddedGuideStyle.resolve(stored: "timeline"), .list)
        XCTAssertEqual(LiveTVEmbeddedGuideStyle.resolve(stored: LiveTVEmbeddedGuideStyle.list.rawValue), .list)
        XCTAssertEqual(LiveTVEmbeddedGuideStyle.resolve(stored: LiveTVEmbeddedGuideStyle.grid.rawValue), .grid)
    }

    func testSwitchingEmbeddedGuideStyleKeepsFiltersAndDoesNotRetune() {
        let browsing = LiveTVEmbeddedGuideBrowsing(style: .list, category: "Sports", favoritesOnly: true, searchQuery: "espn")
        let grid = browsing.selecting(.grid)
        XCTAssertEqual(grid.style, .grid)
        XCTAssertEqual(grid.category, browsing.category)
        XCTAssertEqual(grid.favoritesOnly, browsing.favoritesOnly)
        XCTAssertEqual(grid.searchQuery, browsing.searchQuery)
        XCTAssertFalse(LiveTVEmbeddedGuideBrowsing.retunes(from: .list, to: .grid))
        XCTAssertFalse(LiveTVEmbeddedGuideBrowsing.retunes(from: .grid, to: .list))
        XCTAssertFalse(LiveTVEmbeddedGuideBrowsing.retunes(from: .list, to: .list))
    }

    func testListRowShowsTheCurrentProgrammeItsProgressAndWhatIsNext() {
        let current = EPGProgram(channelID: "g", start: now.addingTimeInterval(-30 * 60), end: now.addingTimeInterval(30 * 60), title: "Evening News")
        let next = EPGProgram(channelID: "g", start: current.end, end: current.end.addingTimeInterval(60 * 60), title: "Late Game")
        let ended = EPGProgram(channelID: "g", start: now.addingTimeInterval(-3 * 60 * 60), end: now.addingTimeInterval(-60 * 60), title: "Already Over")
        let entry = LiveTVEmbeddedGuideListEntry.make(
            channel: channel("a"), programs: [ended, next, current], fallback: LiveTVProgramPair(current: nil, next: nil), now: now)
        XCTAssertEqual(entry.currentTitle, "Evening News")
        XCTAssertEqual(entry.progress ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(entry.upcomingTitle, "Late Game")
        XCTAssertEqual(entry.upcomingStart, next.start)
    }

    func testListRowUsesTheFallbackPairWhenTheGuideWindowIsEmpty() {
        let current = LiveTVProgram(id: "now", channelID: "a", title: "Live Desk",
                                    startsAt: now.addingTimeInterval(-10 * 60), endsAt: now.addingTimeInterval(50 * 60))
        let next = LiveTVProgram(id: "next", channelID: "a", title: "Nightline",
                                 startsAt: current.endsAt, endsAt: current.endsAt.addingTimeInterval(30 * 60))
        let entry = LiveTVEmbeddedGuideListEntry.make(
            channel: channel("a"), programs: [], fallback: LiveTVProgramPair(current: current, next: next), now: now)
        XCTAssertEqual(entry.currentTitle, "Live Desk")
        XCTAssertNotNil(entry.progress)
        XCTAssertEqual(entry.upcomingTitle, "Nightline")
    }

    func testListRowOmitsUpcomingWhenNothingFollows() {
        let current = EPGProgram(channelID: "g", start: now.addingTimeInterval(-5 * 60), end: now.addingTimeInterval(55 * 60), title: "Only Show")
        let entry = LiveTVEmbeddedGuideListEntry.make(
            channel: channel("a"), programs: [current], fallback: LiveTVProgramPair(current: nil, next: nil), now: now)
        XCTAssertEqual(entry.currentTitle, "Only Show")
        XCTAssertNil(entry.upcomingTitle)
        XCTAssertNil(entry.upcomingStart)
    }

    func testUpNextTimesReadNaturally() {
        let start = now.addingTimeInterval(12 * 60)
        XCTAssertEqual(LiveTVWatchDetails.startsInText(start: start, now: now), "Starts in 12 min")
        XCTAssertEqual(LiveTVWatchDetails.startsInText(start: now.addingTimeInterval(65 * 60), now: now),
                       "Starts in 1 hr 5 min")
        XCTAssertEqual(LiveTVWatchDetails.startsInText(start: now.addingTimeInterval(-30), now: now), "Starting now")
        XCTAssertEqual(LiveTVWatchDetails.durationText(start: now, end: now.addingTimeInterval(30 * 60)), "30 min")
        XCTAssertEqual(LiveTVWatchDetails.durationText(start: now, end: now.addingTimeInterval(60 * 60)), "1 hr")
        XCTAssertEqual(LiveTVWatchDetails.durationText(start: now, end: now.addingTimeInterval(75 * 60)), "1 hr 15 min")
    }

    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }
}

private final class StabilizationTestScheduler: LiveTVScheduling {
    var now: Double { 0 }
    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) -> LiveTVTimerHandle {
        LiveTVTimerHandle {}
    }
}

@MainActor
private final class StabilizationFakeEngine: LiveTVEngineDriving {
    var onPhase: ((LiveTVEnginePhase) -> Void)?
    var onLiveSourceReset: (() -> Void)?
    var onSystemInterruption: (() -> Void)?
    var onSystemInterruptionEnded: (() -> Void)?
    var onAudioRouteLost: (() -> Void)?
    private(set) var loads = 0

    func load(_ url: URL, route: LiveTVStreamRoute) async throws { loads += 1 }
    func recoverLiveSource() -> Bool { true }
    func play() {}
    func pause() {}
    func stop(final: Bool, releaseAudioSession: Bool) {}
}
