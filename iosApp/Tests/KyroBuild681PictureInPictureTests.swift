import Foundation
import XCTest
@testable import Silo

/// Build 68.1: automatic Picture in Picture from a Live TV player.
///
/// On the iPhone (Build 68 lifecycle journal, 2026-11-13 20:22–20:23, four attempts) the window
/// started over the Home Screen, then about 0.2 s after `did_enter_background` the session went
/// playing → stopped → connecting twice, the reload's new video layer made the coordinator close
/// the window (`pip_stop_source_change native_layer_changed`, `pip_did_stop closed`) and playback
/// ended. That is the watch screen being rebuilt: its `onDisappear` stopped the stream (the phase
/// stays `.presented` under automatic Picture in Picture) and the rebuilt screen's task replayed
/// it. These tests drive the same presentation and session the views use, with the window's
/// engagement passed in as the views read it from `PictureInPictureCoordinator`. They cannot show
/// that AVKit keeps the window up on a device.
@MainActor
final class KyroBuild681PictureInPictureTests: XCTestCase {
    private var scheduler: PiPTestScheduler!
    private var presentation: LiveTVPresentation!
    private var engine: PiPFakeEngine!
    private var session: LiveTVPlayerSession!
    private var enginesCreated = 0
    private var presentationStops = 0

    override func setUp() async throws {
        scheduler = PiPTestScheduler()
        presentation = LiveTVPresentation(scheduler: scheduler)
        engine = PiPFakeEngine()
        enginesCreated = 0
        presentationStops = 0
        session = LiveTVPlayerSession(scheduler: scheduler, makeEngine: { [unowned self] in
            enginesCreated += 1
            return engine
        }, isOtherVideoActive: { false })
        // What `LiveTVService` wires: a presentation that ends playback stops the one session.
        presentation.stopPlayback = { [unowned self] in
            presentationStops += 1
            session.stop()
        }
        presentation.stopPictureInPicture = {}
        presentation.navigateToLiveTV = {}
    }

    // MARK: Fixtures

    private func channel(_ id: String) -> LiveTVChannel {
        LiveTVChannel(id: id, guideID: id, name: "Channel \(id)",
                      streamURL: URL(string: "https://tv.example/\(id).ts")!, logoURL: nil, category: "News")
    }

    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    /// One watch screen instance: the epoch its `onAppear` recorded.
    private struct WatchScreen { let epoch: Int }

    /// The watch screen's `.task` and `onAppear`: play the presented channel (a no-op when it is
    /// already playing) and remember the presentation it appeared under.
    private func appear(_ channel: LiveTVChannel) async -> WatchScreen {
        session.play(channel)
        await settle()
        return WatchScreen(epoch: presentation.presentationEpoch)
    }

    /// The watch screen's `onDisappear`, with the window's engagement as `ownsEngagedSession`
    /// reports it. Returns whether it stopped the stream.
    @discardableResult
    private func disappear(_ screen: WatchScreen, pictureInPictureEngaged: Bool) -> Bool {
        let stops = LiveTVWatchScreen.shouldStopWhenWatchScreenDisappears(
            presentation: presentation, presentedAt: screen.epoch,
            isPictureInPictureEngaged: pictureInPictureEngaged)
        if stops { session.stop() }
        return stops
    }

    /// A channel chosen in the guide plays on the watch screen.
    private func watch(_ channel: LiveTVChannel) async -> WatchScreen {
        presentation.surfaceAppeared(.guide)
        XCTAssertEqual(presentation.select(channel, from: .guide), .present)
        let screen = await appear(channel)
        engine.onPhase?(.playing)
        await settle()
        XCTAssertEqual(session.state, .playing)
        XCTAssertEqual(engine.loads, 1)
        return screen
    }

    // MARK: Automatic start and backgrounding

    func testAWatchScreenRebuiltAfterAutomaticPictureInPictureStartsKeepsTheStream() async {
        let a = channel("a")
        let first = await watch(a)
        // Swipe Home: the window starts and the cover stays up (phase still `.presented`).
        XCTAssertEqual(presentation.phase, .presented(a, .guide))

        // ~0.2 s later SwiftUI rebuilds the screen: the old instance disappears, a new one appears.
        XCTAssertFalse(disappear(first, pictureInPictureEngaged: true), "the window owns the stream")
        let second = await appear(a)
        XCTAssertEqual(session.state, .playing)
        XCTAssertEqual(engine.loads, 1, "no reload, so the video layer under the window is unchanged")
        XCTAssertEqual(enginesCreated, 1)
        XCTAssertEqual(presentationStops, 0)
        XCTAssertEqual(second.epoch, first.epoch)
    }

    func testTheBuild68SequenceReloadedTheStreamTwice() async {
        // Without the window's engagement the old rule applies: this is what the device did.
        let a = channel("a")
        let first = await watch(a)
        XCTAssertTrue(disappear(first, pictureInPictureEngaged: false))
        XCTAssertEqual(session.state, .stopped)
        let second = await appear(a)
        XCTAssertEqual(session.state, .connecting)
        XCTAssertTrue(disappear(second, pictureInPictureEngaged: false))
        _ = await appear(a)
        XCTAssertEqual(engine.loads, 3, "two reloads: each one hands AVKit a new layer and closes the window")
    }

    func testTheWindowStartingAlsoCounts() {
        // `isEngaged` covers will-start until did-start; a rebuild in that gap must not stop either.
        presentation.surfaceAppeared(.guide)
        _ = presentation.select(channel("a"), from: .guide)
        XCTAssertFalse(presentation.shouldStopWhenPlayerDisappears(presentedAt: presentation.presentationEpoch,
                                                                    isPictureInPictureEngaged: true))
    }

    func testRapidHomeAndReturnNeverRestartsTheStream() async {
        let a = channel("a")
        var screen = await watch(a)
        for _ in 0..<4 {
            // Home: engaged, rebuilt.
            disappear(screen, pictureInPictureEngaged: true)
            screen = await appear(a)
            // Back in the app: AVKit restores into the cover, which is already the interface.
            var answers: [Bool] = []
            presentation.restoreRequested { answers.append($0) }
            XCTAssertEqual(answers, [true])
            XCTAssertEqual(presentation.phase, .presented(a, .guide))
        }
        XCTAssertEqual(session.state, .playing)
        XCTAssertEqual(engine.loads, 1)
        XCTAssertEqual(presentationStops, 0)
    }

    // MARK: Legitimate cleanup is unchanged

    func testClosingTheWindowStillEndsPlayback() async {
        let a = channel("a")
        let screen = await watch(a)
        disappear(screen, pictureInPictureEngaged: true)
        // The viewer closes the window over the Home Screen.
        XCTAssertEqual(presentation.engagementEnded(), .stopPlayback)
        XCTAssertEqual(presentation.phase, .idle)
        XCTAssertEqual(presentationStops, 1)
        XCTAssertEqual(session.state, .stopped, "nothing keeps playing headless")
    }

    func testAScreenTakenDownWithoutTheWindowStillStopsTheStream() async {
        let a = channel("a")
        let screen = await watch(a)
        XCTAssertTrue(disappear(screen, pictureInPictureEngaged: false),
                      "no window and no other surface: the stream ends with its screen")
        XCTAssertEqual(session.state, .stopped)
    }

    func testAnEarlierScreenNeverStopsANewerPresentation() async {
        let a = channel("a"), b = channel("b")
        let first = await watch(a)
        presentation.coverDismissed(from: .guide)
        XCTAssertEqual(presentation.select(b, from: .guide), .present)
        _ = await appear(b)
        XCTAssertFalse(disappear(first, pictureInPictureEngaged: false), "its dismissal finished late")
        XCTAssertEqual(session.state, .connecting)
    }

    func testAnExpandedWatchScreenLeavesTheStreamToTheFullScreenPlayer() async {
        let a = channel("a")
        let screen = await watch(a)
        XCTAssertTrue(presentation.expandWatch())
        XCTAssertFalse(disappear(screen, pictureInPictureEngaged: false))
        XCTAssertFalse(disappear(screen, pictureInPictureEngaged: true))
    }

    // MARK: Explicit Picture in Picture and switching

    func testPictureInPictureFromTheButtonHandsTheStreamToTheWindow() async {
        let a = channel("a")
        let screen = await watch(a)
        presentation.pictureInPictureStartedFromControl()
        XCTAssertEqual(presentation.phase, .pictureInPicture(a))
        XCTAssertNil(presentation.channel(for: .guide), "the cover closes")
        XCTAssertFalse(disappear(screen, pictureInPictureEngaged: true))
        XCTAssertFalse(disappear(screen, pictureInPictureEngaged: false), "the window phase alone keeps it")
        XCTAssertEqual(session.state, .playing)
    }

    func testSwitchingChannelsWhilePlayingRetunesTheSameSession() async {
        let a = channel("a"), b = channel("b")
        _ = await watch(a)
        presentation.playerChannelChanged(to: b)
        session.play(b)
        await settle()
        XCTAssertEqual(engine.loads, 2, "a switch reloads once")
        XCTAssertEqual(enginesCreated, 1, "one engine, one session")
        // A rebuild during the next automatic window keeps the new channel.
        let screen = await appear(b)
        disappear(screen, pictureInPictureEngaged: true)
        XCTAssertEqual(engine.loads, 2)
    }
}

private final class PiPTestScheduler: LiveTVScheduling {
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
private final class PiPFakeEngine: LiveTVEngineDriving {
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
