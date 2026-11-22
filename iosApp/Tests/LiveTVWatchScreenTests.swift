import Foundation
import XCTest
@testable import Silo

/// The iPhone portrait watch screen opened from the guide. It is a layout over the one Live TV
/// session: expanding to full screen, switching channels from its guide and Picture in Picture
/// all move the same stream, so none of them may stop, restart or duplicate playback.
@MainActor
final class LiveTVWatchScreenTests: XCTestCase {
    private var scheduler: WatchTestScheduler!
    private var presentation: LiveTVPresentation!
    private var stops = 0
    private var pictureInPictureStops = 0
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        scheduler = WatchTestScheduler()
        presentation = LiveTVPresentation(scheduler: scheduler)
        stops = 0
        pictureInPictureStops = 0
        presentation.stopPlayback = { [unowned self] in stops += 1 }
        presentation.stopPictureInPicture = { [unowned self] in pictureInPictureStops += 1 }
        presentation.navigateToLiveTV = {}
    }

    // MARK: Fixtures

    private func channel(_ id: String, category: String = "News") -> LiveTVChannel {
        LiveTVChannel(id: id, guideID: id, name: "Channel \(id)",
                      streamURL: URL(string: "https://tv.example/\(id).ts")!, logoURL: nil, category: category)
    }

    private func program(_ title: String, from start: TimeInterval, to end: TimeInterval,
                         summary: String? = nil) -> EPGProgram {
        EPGProgram(channelID: "a", start: now.addingTimeInterval(start * 60), end: now.addingTimeInterval(end * 60),
                   title: title, summary: summary)
    }

    /// The guide's cover is up showing `channel` on the watch screen.
    private func openWatchScreen(_ channel: LiveTVChannel) {
        presentation.surfaceAppeared(.guide)
        XCTAssertEqual(presentation.select(channel, from: .guide), .present)
        XCTAssertEqual(presentation.channel(for: .guide), channel)
    }

    private var surface: LiveTVWatchSurfaceMode {
        .make(phase: presentation.phase, isExpanded: presentation.isWatchExpanded)
    }

    // MARK: Full screen

    func testFullScreenAndBackKeepTheSameStreamWithoutStoppingIt() {
        let a = channel("a")
        openWatchScreen(a)
        XCTAssertEqual(surface, .video(a))

        XCTAssertTrue(presentation.expandWatch())
        XCTAssertTrue(presentation.isWatchExpanded)
        XCTAssertEqual(surface, .expanded(a))
        XCTAssertFalse(surface.hostsSurface, "the watch frame must unmount so it cannot take the layer back")
        XCTAssertEqual(presentation.phase, .presented(a, .guide), "expansion is not a new selection")
        XCTAssertEqual(presentation.channel(for: .guide), a, "the watch screen stays up under full screen")
        XCTAssertFalse(LiveTVWatchScreen.shouldStopWhenWatchScreenDisappears(
            phase: presentation.phase, isExpanded: presentation.isWatchExpanded),
            "the covered watch screen reporting disappear must not end the full-screen stream")

        presentation.collapseWatch()
        XCTAssertEqual(surface, .video(a))
        XCTAssertEqual(presentation.phase, .presented(a, .guide))
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(pictureInPictureStops, 0)
    }

    func testFullScreenKeepsPortraitSurfaceUntilIncomingSurfaceMounted() {
        let a = channel("a")
        openWatchScreen(a)
        XCTAssertTrue(presentation.expandWatch())

        let awaitingIncoming = LiveTVWatchSurfaceMode.make(
            phase: presentation.phase, isExpanded: true, isExpandedSurfaceMounted: false)
        XCTAssertEqual(awaitingIncoming, .video(a),
                       "the outgoing surface remains until the replacement has bound")

        let transferred = LiveTVWatchSurfaceMode.make(
            phase: presentation.phase, isExpanded: true, isExpandedSurfaceMounted: true)
        XCTAssertEqual(transferred, .expanded(a))
        XCTAssertFalse(transferred.hostsSurface,
                       "after confirmation only the full-screen surface owns the engine layer")

        presentation.collapseWatch()
        XCTAssertEqual(LiveTVWatchSurfaceMode.make(
            phase: presentation.phase, isExpanded: false, isExpandedSurfaceMounted: true), .video(a),
                       "collapse remounts portrait before the outgoing cover finishes")
        XCTAssertEqual(stops, 0)
    }

    func testFullScreenNeedsAPresentedStream() {
        XCTAssertFalse(presentation.expandWatch())
        XCTAssertFalse(presentation.isWatchExpanded)
        XCTAssertEqual(surface, .none)
    }

    func testDeviceExpansionIsIdempotentAndReturnsToTheSameWatchScreen() {
        let a = channel("a")
        openWatchScreen(a)
        let epoch = presentation.presentationEpoch
        XCTAssertTrue(presentation.expandWatch(byRotation: true))
        XCTAssertFalse(presentation.expandWatch(byRotation: true), "one device turn presents one cover")
        XCTAssertTrue(presentation.isWatchExpandedByRotation)
        XCTAssertEqual(surface, .expanded(a))
        presentation.collapseWatch()
        XCTAssertEqual(surface, .video(a))
        XCTAssertFalse(presentation.isWatchExpandedByRotation)
        XCTAssertEqual(presentation.presentationEpoch, epoch, "rotation never starts a new session")
        XCTAssertEqual(stops, 0)
    }

    func testManualExpansionIsNotMarkedForAutomaticPortraitCollapse() {
        openWatchScreen(channel("a"))
        XCTAssertTrue(presentation.expandWatch())
        XCTAssertFalse(presentation.isWatchExpandedByRotation)
    }

    func testAChannelChosenInFullScreenIsTheOneTheWatchScreenShowsAfterBack() {
        let a = channel("a"), b = channel("b")
        openWatchScreen(a)
        presentation.expandWatch()

        presentation.playerChannelChanged(to: b)
        XCTAssertTrue(presentation.isWatchExpanded, "a retune in full screen stays in full screen")
        XCTAssertEqual(surface, .expanded(b))

        presentation.collapseWatch()
        XCTAssertEqual(surface, .video(b))
        XCTAssertEqual(presentation.phase, .presented(b, .guide))
        XCTAssertEqual(stops, 0)
    }

    // MARK: Switching from the Guide tab

    func testGuideTabSwitchRetunesInPlaceAndKeepsTheWatchScreen() {
        let a = channel("a"), b = channel("b")
        openWatchScreen(a)
        XCTAssertEqual(LiveTVWatchSwitch.resolve(selectedChannelID: b.id, activeChannelID: a.id), .retune)

        // The service's in-place retune reports the switch through the player-picker path.
        presentation.playerChannelChanged(to: b)
        XCTAssertEqual(presentation.phase, .presented(b, .guide))
        XCTAssertEqual(presentation.channel(for: .guide), b, "the same cover shows the new channel")
        XCTAssertEqual(presentation.activeChannel, b)
        XCTAssertEqual(stops, 0)
    }

    func testTappingThePlayingChannelDoesNotRetune() {
        XCTAssertEqual(LiveTVWatchSwitch.resolve(selectedChannelID: "a", activeChannelID: "a"), .alreadyPlaying)
        XCTAssertEqual(LiveTVWatchSwitch.resolve(selectedChannelID: "a", activeChannelID: nil), .retune)
    }

    func testGuideSwitchesAndFullScreenReplaysUseOneEngineAndNeverReloadThePlayingChannel() async {
        let engine = WatchFakeEngine()
        var created = 0
        let session = LiveTVPlayerSession(scheduler: scheduler, makeEngine: { created += 1; return engine },
                                          isOtherVideoActive: { false })
        session.play(channel("a"))
        await settle()
        XCTAssertEqual(engine.loads, 1)

        // Full screen's player task replays the presented channel; the stream must not restart.
        session.play(channel("a"))
        await settle()
        XCTAssertEqual(engine.loads, 1)

        session.play(channel("b"))
        await settle()
        XCTAssertEqual(engine.loads, 2)
        XCTAssertEqual(created, 1, "a guide switch retunes the same engine")
        XCTAssertEqual(session.enginesCreated, 1)
        XCTAssertEqual(session.activeChannelID, "b")
    }

    // MARK: Picture in Picture and closing

    func testPictureInPictureFromFullScreenLeavesExpansionAndRestoresToFullScreen() {
        let a = channel("a")
        openWatchScreen(a)
        presentation.expandWatch()

        presentation.pictureInPictureStartedFromControl()
        XCTAssertEqual(presentation.phase, .pictureInPicture(a))
        XCTAssertFalse(presentation.isWatchExpanded)
        XCTAssertEqual(surface, .pictureInPicture(a))
        XCTAssertFalse(surface.hostsSurface, "the watch frame must not take the layer back from Picture in Picture")
        XCTAssertNil(presentation.channel(for: .guide), "the watch screen closes for the window")
        XCTAssertFalse(LiveTVWatchScreen.shouldStopWhenWatchScreenDisappears(
            phase: presentation.phase, isExpanded: presentation.isWatchExpanded))

        var restored: Bool?
        presentation.restoreRequested { restored = $0 }
        XCTAssertEqual(presentation.phase, .restoring(a, .guide), "the guide re-presents its watch screen")
        XCTAssertEqual(surface, .expanded(a), "full screen comes back over it")
        presentation.playerDidAppear(a)
        XCTAssertEqual(restored, true)
        XCTAssertEqual(presentation.phase, .presented(a, .guide))
        XCTAssertTrue(presentation.isWatchExpanded, "a restore returns to the full screen it left")
        XCTAssertEqual(stops, 0)
    }

    func testClosingTheWatchScreenEndsTheStreamAndForgetsFullScreen() {
        let a = channel("a")
        openWatchScreen(a)
        presentation.expandWatch()

        presentation.coverDismissed(from: .guide)
        XCTAssertEqual(presentation.phase, .idle)
        XCTAssertFalse(presentation.isWatchExpanded)
        XCTAssertTrue(LiveTVWatchScreen.shouldStopWhenWatchScreenDisappears(
            phase: presentation.phase, isExpanded: presentation.isWatchExpanded))

        openWatchScreen(a)
        XCTAssertEqual(surface, .video(a), "the next watch screen opens in portrait")
    }

    func testRemovingTheProviderStopsPlaybackAndClearsFullScreen() {
        let provider = UUID()
        let a = channel("\(provider.uuidString):1")
        openWatchScreen(a)
        presentation.expandWatch()

        presentation.providerRemoved(provider, activeChannelID: a.id)
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(presentation.isWatchExpanded)
        XCTAssertEqual(surface, .none)
    }

    func testANewSelectionNeverInheritsFullScreen() {
        let a = channel("a"), b = channel("b")
        openWatchScreen(a)
        presentation.expandWatch()
        XCTAssertEqual(presentation.select(b, from: .guide), .present)
        XCTAssertFalse(presentation.isWatchExpanded)
    }

    // MARK: Details

    func testDetailsDescribeWhatIsAiringAndWhatFollows() {
        let details = LiveTVWatchDetails.make(
            channel: channel("a", category: " Sports "),
            programs: [
                program("Later", from: 60, to: 90),
                program("Earlier", from: -120, to: -30),
                program("Now", from: -30, to: 30, summary: "The match."),
                program("Next", from: 30, to: 60),
            ],
            fallback: LiveTVProgramPair(current: nil, next: nil), now: now)

        XCTAssertEqual(details.channelName, "Channel a")
        XCTAssertEqual(details.channelCategory, "Sports")
        XCTAssertEqual(details.current?.title, "Now")
        XCTAssertEqual(details.current?.summary, "The match.")
        XCTAssertEqual(details.progress ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(details.upcoming.map(\.title), ["Next", "Later"], "ended and current listings are not up next")
    }

    func testDetailsFallBackToNowNextWhenTheWindowHasNoListings() {
        let current = LiveTVProgram(id: "c", channelID: "a", title: "Bulletin",
                                    startsAt: now.addingTimeInterval(-600), endsAt: now.addingTimeInterval(600))
        let next = LiveTVProgram(id: "n", channelID: "a", title: "Weather",
                                 startsAt: now.addingTimeInterval(600), endsAt: now.addingTimeInterval(1200))
        let details = LiveTVWatchDetails.make(channel: channel("a", category: ""), programs: [],
                                              fallback: LiveTVProgramPair(current: current, next: next), now: now)
        XCTAssertEqual(details.current?.title, "Bulletin")
        XCTAssertEqual(details.upcoming.map(\.title), ["Weather"])
        XCTAssertNil(details.channelCategory)
    }

    func testDetailsWithoutGuideDataShowNoProgramme() {
        let details = LiveTVWatchDetails.make(channel: channel("a"), programs: [],
                                              fallback: LiveTVProgramPair(current: nil, next: nil), now: now)
        XCTAssertNil(details.current)
        XCTAssertNil(details.progress)
        XCTAssertTrue(details.upcoming.isEmpty)
    }

    func testUpNextIsBounded() {
        let programs = (0..<20).map { program("P\($0)", from: Double($0 * 30), to: Double($0 * 30 + 30)) }
        let details = LiveTVWatchDetails.make(channel: channel("a"), programs: programs,
                                              fallback: LiveTVProgramPair(current: nil, next: nil), now: now)
        XCTAssertEqual(details.current?.title, "P0")
        XCTAssertEqual(details.upcoming.count, LiveTVWatchDetails.upcomingLimit)
        XCTAssertEqual(details.upcoming.first?.title, "P1")
    }

    func testRemainingTimeRoundsUp() {
        XCTAssertEqual(LiveTVWatchDetails.remainingText(end: now.addingTimeInterval(61), now: now), "2 min left")
        XCTAssertEqual(LiveTVWatchDetails.remainingText(end: now.addingTimeInterval(3600), now: now), "1 hr left")
        XCTAssertEqual(LiveTVWatchDetails.remainingText(end: now.addingTimeInterval(3900), now: now), "1 hr 5 min left")
        XCTAssertEqual(LiveTVWatchDetails.remainingText(end: now.addingTimeInterval(-60), now: now), "0 min left")
    }

    func testOnlyIPhoneOpensTheWatchScreen() {
        XCTAssertTrue(LiveTVWatchScreen.isEnabled(isPhone: true))
        XCTAssertFalse(LiveTVWatchScreen.isEnabled(isPhone: false))
    }

    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }
}

private final class WatchTestScheduler: LiveTVScheduling {
    private var timers: [(id: Int, action: @MainActor @Sendable () -> Void)] = []
    private var nextID = 0
    var now: Double { 0 }

    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) -> LiveTVTimerHandle {
        nextID += 1
        let id = nextID
        timers.append((id, action))
        return LiveTVTimerHandle { [weak self] in self?.timers.removeAll { $0.id == id } }
    }
}

@MainActor
private final class WatchFakeEngine: LiveTVEngineDriving {
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
