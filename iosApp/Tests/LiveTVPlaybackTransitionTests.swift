import Foundation
import XCTest
@testable import Silo

/// Build 50: every move between the portrait watch screen, full screen, Sports Hub's inline
/// player and Picture in Picture keeps one stream, returns to the screen it left, and never lets
/// a screen that is on its way out stop what a newer one is playing.
@MainActor
final class LiveTVPlaybackTransitionTests: XCTestCase {
    private var presentation: LiveTVPresentation!
    private var stops = 0
    private var pictureInPictureStops = 0

    override func setUp() async throws {
        presentation = LiveTVPresentation(scheduler: TransitionTestScheduler())
        stops = 0
        pictureInPictureStops = 0
        presentation.stopPlayback = { [unowned self] in stops += 1 }
        presentation.stopPictureInPicture = { [unowned self] in pictureInPictureStops += 1 }
        presentation.navigateToLiveTV = {}
    }

    private func channel(_ id: String) -> LiveTVChannel {
        LiveTVChannel(id: id, guideID: id, name: "Channel \(id)",
                      streamURL: URL(string: "https://tv.example/\(id).ts")!, logoURL: nil, category: "News")
    }

    private var surface: LiveTVWatchSurfaceMode {
        .make(phase: presentation.phase, isExpanded: presentation.isWatchExpanded)
    }

    private func openWatchScreen(_ channel: LiveTVChannel) {
        presentation.surfaceAppeared(.guide)
        XCTAssertEqual(presentation.select(channel, from: .guide), .present)
    }

    private func playInline(_ channel: LiveTVChannel) {
        presentation.inlineHostAppeared()
        XCTAssertTrue(presentation.showInline(channel))
    }

    func testSportsInlineDeviceExpansionKeepsTheEventSession() {
        let a = channel("sports")
        playInline(a)
        let epoch = presentation.presentationEpoch
        presentation.expandInline(byRotation: true)
        XCTAssertTrue(presentation.isInlineExpandedByRotation)
        XCTAssertEqual(presentation.phase, .presented(a, .shell))
        XCTAssertTrue(presentation.collapseToInline())
        XCTAssertEqual(presentation.phase, .inline(a))
        XCTAssertFalse(presentation.isInlineExpandedByRotation)
        XCTAssertEqual(presentation.presentationEpoch, epoch + 1, "only the cover identity changes")
        XCTAssertEqual(stops, 0)
    }

    // MARK: Picture in Picture returns where it started

    func testPictureInPictureFromThePortraitWatchScreenRestoresToPortrait() {
        let a = channel("a")
        openWatchScreen(a)
        presentation.pictureInPictureStartedFromControl()
        XCTAssertEqual(presentation.pictureInPictureOrigin, .cover(.guide, expanded: false))

        var restored: Bool?
        presentation.restoreRequested { restored = $0 }
        XCTAssertEqual(surface, .video(a))
        presentation.playerDidAppear(a)
        XCTAssertEqual(restored, true)
        XCTAssertEqual(presentation.phase, .presented(a, .guide))
        XCTAssertFalse(presentation.isWatchExpanded)
        XCTAssertNil(presentation.pictureInPictureOrigin)
        XCTAssertEqual(stops, 0)
    }

    func testPictureInPictureFromFullScreenRestoresToFullScreenOverTheWatchScreen() {
        let a = channel("a")
        openWatchScreen(a)
        presentation.expandWatch()
        presentation.pictureInPictureStartedFromControl()
        XCTAssertEqual(presentation.pictureInPictureOrigin, .cover(.guide, expanded: true))
        XCTAssertFalse(presentation.isWatchExpanded, "nothing is expanded while the window has the stream")

        var restored: Bool?
        presentation.restoreRequested { restored = $0 }
        XCTAssertEqual(presentation.phase, .restoring(a, .guide))
        XCTAssertTrue(presentation.isWatchExpanded)
        XCTAssertEqual(surface, .expanded(a), "the watch frame mounts no surface under the returning full screen")

        presentation.playerDidAppear(a)
        XCTAssertEqual(restored, true)
        XCTAssertEqual(presentation.phase, .presented(a, .guide))
        XCTAssertTrue(presentation.isWatchExpanded, "the expansion survives the restore completing")

        presentation.collapseWatch()
        XCTAssertEqual(surface, .video(a), "Exit Full Screen still returns to the portrait watch screen")
        XCTAssertEqual(stops, 0)
    }

    func testAFullScreenRestoreWithoutItsGuideOpensAPlainPlayer() {
        let a = channel("a")
        openWatchScreen(a)
        presentation.expandWatch()
        presentation.pictureInPictureStartedFromControl()
        presentation.surfaceDisappeared(.guide)
        presentation.surfaceAppeared(.list)

        presentation.restoreRequested { _ in }
        XCTAssertEqual(presentation.phase, .restoring(a, .list))
        XCTAssertFalse(presentation.isWatchExpanded, "the list has no watch screen to expand over")
    }

    func testPictureInPictureFromTheSportsInlinePlayerRestoresInline() {
        let a = channel("a")
        playInline(a)
        let epoch = presentation.presentationEpoch
        presentation.pictureInPictureStartedFromControl()
        XCTAssertEqual(presentation.pictureInPictureOrigin, .inline)

        var restored: Bool?
        presentation.restoreRequested { restored = $0 }
        XCTAssertNil(restored, "AVKit must wait until the inline video surface has remounted")
        XCTAssertEqual(presentation.phase, .inline(a))
        presentation.inlinePlayerDidAppear(a)
        XCTAssertEqual(restored, true)
        XCTAssertNil(presentation.coverItem(for: .shell), "no full-screen cover opens over Sports Hub")
        XCTAssertEqual(presentation.presentationEpoch, epoch)
        XCTAssertEqual(stops, 0)
    }

    func testAnInlineRestoreAfterLeavingSportsHubOpensFullScreenInstead() {
        let a = channel("a")
        playInline(a)
        presentation.pictureInPictureStartedFromControl()
        presentation.inlineHostDisappeared()

        presentation.restoreRequested { _ in }
        XCTAssertEqual(presentation.phase, .restoring(a, .shell))
        XCTAssertFalse(presentation.isFullScreenFromInline, "nothing to collapse into, so it is a plain player")
    }

    func testPictureInPictureFromSportsFullScreenRestoresToLandscapeFullScreenThatStillCollapses() {
        let a = channel("a")
        playInline(a)
        presentation.expandInline()
        XCTAssertTrue(presentation.isFullScreenFromInline)
        presentation.pictureInPictureStartedFromControl()
        XCTAssertEqual(presentation.pictureInPictureOrigin, .cover(.shell, expanded: false))

        presentation.restoreRequested { _ in }
        XCTAssertEqual(presentation.phase, .restoring(a, .shell))
        XCTAssertTrue(presentation.isFullScreenFromInline,
                      "the returning player is created mid-restore and must still open in landscape")
        XCTAssertEqual(LiveTVFullScreenOrientation.resolve(
            isPhone: true, isExpandedFromInline: presentation.isFullScreenFromInline), .landscapeLocked)

        presentation.playerDidAppear(a)
        XCTAssertTrue(presentation.canCollapseToInline)
        XCTAssertTrue(presentation.collapseToInline())
        XCTAssertEqual(presentation.phase, .inline(a))
        XCTAssertEqual(stops, 0)
    }

    func testAFailedStreamInPictureInPictureReturnsToTheInlinePlayer() {
        let a = channel("a")
        playInline(a)
        presentation.pictureInPictureStartedFromControl()
        presentation.playbackFailedInPictureInPicture()
        XCTAssertEqual(pictureInPictureStops, 1)
        XCTAssertEqual(presentation.engagementEnded(), .continuePlayback)
        XCTAssertEqual(presentation.phase, .inline(a), "Retry is on the inline player")
        XCTAssertEqual(stops, 0)
    }

    func testAChannelChosenElsewhereDuringPictureInPictureReturnsToThatScreenNotTheOrigin() {
        let a = channel("a"), b = channel("b")
        openWatchScreen(a)
        presentation.expandWatch()
        presentation.pictureInPictureStartedFromControl()
        presentation.surfaceAppeared(.list)

        XCTAssertEqual(presentation.select(b, from: .list), .playInPlace)
        XCTAssertEqual(presentation.pictureInPictureOrigin, .cover(.list, expanded: false))
        presentation.restoreRequested { _ in }
        XCTAssertEqual(presentation.phase, .restoring(b, .list))
        XCTAssertFalse(presentation.isWatchExpanded)
    }

    func testClosingThePictureInPictureWindowStopsOnceAndForgetsItsOrigin() {
        openWatchScreen(channel("a"))
        presentation.expandWatch()
        presentation.pictureInPictureStartedFromControl()
        XCTAssertEqual(presentation.engagementEnded(), .stopPlayback)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(presentation.phase, .idle)
        XCTAssertNil(presentation.pictureInPictureOrigin)
        XCTAssertFalse(presentation.isWatchExpanded)
    }

    // MARK: Only the current presentation may stop the stream

    func testAScreenClosingForPictureInPictureCannotStopTheRestoreThatFollows() {
        let a = channel("a")
        openWatchScreen(a)
        let watchScreen = presentation.presentationEpoch
        presentation.pictureInPictureStartedFromControl()
        // The restore begins while the old cover is still animating away.
        presentation.restoreRequested { _ in }
        XCTAssertFalse(presentation.shouldStopWhenPlayerDisappears(presentedAt: watchScreen),
                       "the old screen's late disappearance must not stop the restored stream")
        XCTAssertFalse(LiveTVWatchScreen.shouldStopWhenWatchScreenDisappears(
            presentation: presentation, presentedAt: watchScreen))
        XCTAssertTrue(presentation.shouldStopWhenPlayerDisappears(presentedAt: presentation.presentationEpoch),
                      "the restoring screen itself still owns the stream")
    }

    func testAClosedPlayerCannotStopTheNextChannel() {
        let a = channel("a"), b = channel("b")
        presentation.surfaceAppeared(.list)
        _ = presentation.select(a, from: .list)
        let first = presentation.presentationEpoch
        presentation.coverDismissed(from: .list)
        XCTAssertTrue(presentation.shouldStopWhenPlayerDisappears(presentedAt: first), "closed and nothing follows")

        _ = presentation.select(b, from: .list)
        XCTAssertFalse(presentation.shouldStopWhenPlayerDisappears(presentedAt: first))
    }

    func testMovingBetweenSurfacesNeverAsksTheLeavingScreenToStop() {
        let a = channel("a")
        // Watch screen under its own full-screen player.
        openWatchScreen(a)
        let watchScreen = presentation.presentationEpoch
        presentation.expandWatch()
        XCTAssertFalse(LiveTVWatchScreen.shouldStopWhenWatchScreenDisappears(
            presentation: presentation, presentedAt: watchScreen))
        presentation.collapseWatch()
        XCTAssertEqual(presentation.presentationEpoch, watchScreen, "full screen and back is one presentation")
        XCTAssertTrue(LiveTVWatchScreen.shouldStopWhenWatchScreenDisappears(
            presentation: presentation, presentedAt: watchScreen))
        XCTAssertFalse(LiveTVWatchScreen.shouldStopWhenWatchScreenDisappears(
            presentation: presentation, presentedAt: nil), "a screen that never appeared owns nothing")
        presentation.coverDismissed(from: .guide)

        // Sports full screen collapsing into the inline player, then expanding again.
        playInline(a)
        presentation.expandInline()
        let fullScreen = presentation.presentationEpoch
        XCTAssertTrue(presentation.collapseToInline())
        XCTAssertFalse(presentation.shouldStopWhenPlayerDisappears(presentedAt: fullScreen))
        presentation.expandInline()
        XCTAssertFalse(presentation.shouldStopWhenPlayerDisappears(presentedAt: fullScreen),
                       "the first cover finishing its dismissal cannot stop the second")
        XCTAssertEqual(stops, 0)
    }

    // MARK: One engine, no reload for a presentation change

    func testAFullTourOfEverySurfaceLoadsEachChannelOnce() async {
        let engine = TransitionFakeEngine()
        let session = LiveTVPlayerSession(scheduler: TransitionTestScheduler(), makeEngine: { engine },
                                          isOtherVideoActive: { false })
        let a = channel("a"), b = channel("b")
        openWatchScreen(a)
        session.play(a)
        await settle()

        presentation.expandWatch()
        session.play(a) // Full screen's task.
        presentation.pictureInPictureStartedFromControl()
        presentation.restoreRequested { _ in }
        session.play(a) // The restored watch screen's task.
        presentation.playerDidAppear(a)
        session.play(a) // The restored full-screen player's task.
        presentation.collapseWatch()
        await settle()
        XCTAssertEqual(engine.loads, 1, "no surface move reloads the stream")

        presentation.playerChannelChanged(to: b) // A guide tap right after the collapse.
        session.play(b)
        presentation.expandWatch()
        session.play(b)
        await settle()
        XCTAssertEqual(engine.loads, 2)
        XCTAssertEqual(session.enginesCreated, 1)
        XCTAssertEqual(surface, .expanded(b))
        XCTAssertEqual(stops, 0)
        session.stop()
    }

    // MARK: Up Next

    func testUpNextTimeColumnFitsATwelveHourTime() {
        XCTAssertGreaterThanOrEqual(LiveTVWatchDetails.upNextTimeColumnWidth, 68)
    }

    // MARK: Build 51: how a restore arrives, and which screen answers it

    func testARestoreIntoTheWatchScreensFullScreenIsAnsweredByThatPlayerNotTheWatchScreen() {
        let a = channel("a")
        openWatchScreen(a)
        presentation.expandWatch()
        presentation.pictureInPictureStartedFromControl()
        XCTAssertTrue(presentation.restoreReturnsToExpandedPlayer, "cuts in; the rotation is the only motion")

        var restored: Bool?
        presentation.restoreRequested { restored = $0 }
        // The watch screen's cover arrives first and hosts no surface while expanded.
        presentation.watchScreenDidAppear(a)
        XCTAssertNil(restored, "answering here would hand the window back before any surface holds the stream")
        XCTAssertEqual(presentation.phase, .restoring(a, .guide))
        XCTAssertEqual(surface, .expanded(a))

        presentation.playerDidAppear(a)
        XCTAssertEqual(restored, true)
        XCTAssertEqual(presentation.phase, .presented(a, .guide))
        XCTAssertTrue(presentation.isWatchExpanded)
        XCTAssertEqual(stops, 0)
    }

    func testARestoreIntoThePortraitWatchScreenIsAnsweredByIt() {
        let a = channel("a")
        openWatchScreen(a)
        presentation.pictureInPictureStartedFromControl()
        XCTAssertFalse(presentation.restoreReturnsToExpandedPlayer, "a portrait restore keeps its slide")

        var restored: Bool?
        presentation.restoreRequested { restored = $0 }
        presentation.watchScreenDidAppear(a)
        XCTAssertEqual(restored, true)
        XCTAssertEqual(presentation.phase, .presented(a, .guide))
        XCTAssertEqual(surface, .video(a))
    }

    func testAnExpandedRestoreWhoseFullScreenNeverAppearsStillEndsTheStream() {
        let a = channel("a")
        openWatchScreen(a)
        presentation.expandWatch()
        presentation.pictureInPictureStartedFromControl()
        var restored: Bool?
        presentation.restoreRequested { restored = $0 }
        presentation.watchScreenDidAppear(a)

        presentation.restoreTimedOut()
        XCTAssertEqual(restored, false)
        XCTAssertEqual(presentation.phase, .idle)
        XCTAssertEqual(stops, 1, "AVKit has closed the window; the stream must not play on headless")
    }

    func testSportsFullScreenRestoreCutsInAndAgreesWithTheLandscapePlayerItOpens() {
        let a = channel("a")
        playInline(a)
        presentation.expandInline()
        presentation.pictureInPictureStartedFromControl()
        XCTAssertTrue(presentation.restoreReturnsToExpandedPlayer)
        presentation.restoreRequested { _ in }
        XCTAssertTrue(presentation.isFullScreenFromInline)
    }

    func testRestoresThatDoNotReturnToAnExpandedPlayerKeepTheirTransition() {
        let a = channel("a")
        XCTAssertFalse(presentation.restoreReturnsToExpandedPlayer, "nothing is in Picture in Picture")

        // Sports Hub's inline player takes the stream straight back; no cover opens.
        playInline(a)
        presentation.pictureInPictureStartedFromControl()
        XCTAssertFalse(presentation.restoreReturnsToExpandedPlayer)

        // Sports Hub has gone: a plain full-screen player that rotates freely.
        presentation.inlineHostDisappeared()
        XCTAssertFalse(presentation.restoreReturnsToExpandedPlayer)
        presentation.restoreRequested { _ in }
        XCTAssertFalse(presentation.isFullScreenFromInline)

        // Expanded over a guide that has since gone: the list's ordinary player.
        let other = LiveTVPresentation(scheduler: TransitionTestScheduler())
        other.surfaceAppeared(.guide)
        _ = other.select(a, from: .guide)
        other.expandWatch()
        other.pictureInPictureStartedFromControl()
        other.surfaceDisappeared(.guide)
        other.surfaceAppeared(.list)
        XCTAssertFalse(other.restoreReturnsToExpandedPlayer)
        other.restoreRequested { _ in }
        XCTAssertFalse(other.isWatchExpanded)
    }

    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }
}

/// Build 51: only the rotation the player asked for loses its animation.
final class PlayerRotationTransitionPolicyTests: XCTestCase {
    func testTheRequestedRotationRunsUnanimatedOnce() {
        var policy = PlayerRotationTransitionPolicy()
        policy.requested(.landscape, from: .portrait)
        XCTAssertTrue(policy.transitionWillBegin(to: .landscape))
        XCTAssertFalse(policy.transitionWillBegin(to: .landscape),
                       "a second observer of the same rotation, or a later device turn, keeps the system animation")
    }

    func testLeavingFullScreenReturnsToPortraitUnanimated() {
        var policy = PlayerRotationTransitionPolicy()
        policy.requested(.portrait, from: .landscape)
        XCTAssertTrue(policy.transitionWillBegin(to: .portrait))
    }

    func testAScreenAlreadyThereLeavesNothingToSwallowALaterDeviceRotation() {
        var policy = PlayerRotationTransitionPolicy()
        policy.requested(.landscape, from: .landscape)
        XCTAssertNil(policy.pending)
        XCTAssertFalse(policy.transitionWillBegin(to: .portrait))
    }

    func testARotationTheOtherWaySupersedesTheRequest() {
        var policy = PlayerRotationTransitionPolicy()
        policy.requested(.landscape, from: .portrait)
        XCTAssertFalse(policy.transitionWillBegin(to: .portrait))
        XCTAssertNil(policy.pending)
    }

    func testAnUnknownTargetIsTheRequestedRotation() {
        var policy = PlayerRotationTransitionPolicy()
        policy.requested(.landscape, from: .portrait)
        XCTAssertTrue(policy.transitionWillBegin(to: nil))
    }

    func testAFailedRequestCancelsIt() {
        var policy = PlayerRotationTransitionPolicy()
        policy.requested(.landscape, from: .portrait)
        policy.cancel()
        XCTAssertFalse(policy.transitionWillBegin(to: .landscape))
    }
}

private final class TransitionTestScheduler: LiveTVScheduling {
    var now: Double { 0 }
    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) -> LiveTVTimerHandle {
        LiveTVTimerHandle {}
    }
}

@MainActor
private final class TransitionFakeEngine: LiveTVEngineDriving {
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
