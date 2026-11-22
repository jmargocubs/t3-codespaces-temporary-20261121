import Foundation
import XCTest
@testable import Silo

@MainActor
final class LiveTVPictureInPictureTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var presentation: LiveTVPresentation!
    private var stops = 0
    private var pictureInPictureStops = 0
    private var navigations = 0

    override func setUp() async throws {
        scheduler = ManualScheduler()
        presentation = LiveTVPresentation(scheduler: scheduler)
        stops = 0
        pictureInPictureStops = 0
        navigations = 0
        presentation.stopPlayback = { [unowned self] in stops += 1 }
        presentation.stopPictureInPicture = { [unowned self] in pictureInPictureStops += 1 }
        presentation.navigateToLiveTV = { [unowned self] in navigations += 1 }
    }

    private func channel(_ name: String, hls: Bool = false) -> LiveTVChannel {
        LiveTVChannel(id: name, guideID: name, name: name,
                      streamURL: URL(string: "https://tv.example/\(name).\(hls ? "m3u8" : "ts")")!,
                      logoURL: nil, category: "News")
    }

    /// A channel playing in the full-screen player from the list, moved into Picture in Picture.
    private func enterPictureInPicture(_ channel: LiveTVChannel, from presenter: LiveTVPresenter = .list) {
        presentation.surfaceAppeared(presenter)
        XCTAssertEqual(presentation.select(channel, from: presenter), .present)
        presentation.pictureInPictureStartedFromControl()
        XCTAssertEqual(presentation.phase, .pictureInPicture(channel))
    }

    // MARK: - Ownership

    func testOwnPictureInPictureDoesNotBlockLiveTVButAnotherPlayersDoes() {
        typealias Policy = LiveTVPictureInPicturePolicy
        XCTAssertFalse(Policy.isOtherVideoActive(isEngaged: false, liveTVOwnsEngagement: false))
        XCTAssertFalse(Policy.isOtherVideoActive(isEngaged: true, liveTVOwnsEngagement: true), "Live TV's own window")
        XCTAssertTrue(Policy.isOtherVideoActive(isEngaged: true, liveTVOwnsEngagement: false), "a Silo movie's window")
    }

    func testSessionTunesDuringItsOwnPictureInPictureButRefusesDuringAMoviesWindow() async {
        for (ownsEngagement, expectsPlayback) in [(true, true), (false, false)] {
            let engine = FakeEngine()
            let session = LiveTVPlayerSession(
                scheduler: scheduler, makeEngine: { engine },
                isOtherVideoActive: {
                    LiveTVPictureInPicturePolicy.isOtherVideoActive(isEngaged: true, liveTVOwnsEngagement: ownsEngagement)
                })
            session.play(channel("a"))
            for _ in 0..<8 { await Task.yield() }
            XCTAssertEqual(engine.loads, expectsPlayback ? 1 : 0, "owns engagement: \(ownsEngagement)")
            if !expectsPlayback { XCTAssertEqual(session.state, .failed) }
        }
    }

    // MARK: - Dismissal

    func testOnlyThePresentingScreenShowsTheCoverAndAPlainCloseEndsTheSession() {
        let news = channel("news")
        XCTAssertEqual(presentation.select(news, from: .guide), .present)
        XCTAssertEqual(presentation.channel(for: .guide), news)
        XCTAssertNil(presentation.channel(for: .list), "the list must not also present")

        presentation.coverDismissed(from: .list)
        XCTAssertEqual(presentation.channel(for: .guide), news, "another screen cannot dismiss it")
        presentation.coverDismissed(from: .guide)
        XCTAssertEqual(presentation.phase, .idle)
        XCTAssertTrue(LiveTVPictureInPicturePolicy.shouldStopWhenPlayerDisappears(presentation.phase))
    }

    func testStartingPictureInPictureFromTheButtonClosesTheCoverWithoutStoppingTheStream() {
        let news = channel("news")
        enterPictureInPicture(news)
        XCTAssertNil(presentation.channel(for: .list))
        XCTAssertFalse(LiveTVPictureInPicturePolicy.shouldStopWhenPlayerDisappears(presentation.phase),
                       "the player's disappearance must leave the stream running")
        presentation.coverDismissed(from: .list)
        XCTAssertEqual(presentation.phase, .pictureInPicture(news), "SwiftUI's dismissal callback is not a close")
        XCTAssertEqual(stops, 0)
        XCTAssertTrue(presentation.isPictureInPictureOwningPlayback)
    }

    // MARK: - Restoration

    func testAutomaticPictureInPictureLeavesTheCoverUpSoRestoreIsAlreadyDone() {
        presentation.surfaceAppeared(.list)
        _ = presentation.select(channel("news"), from: .list)
        var answers: [Bool] = []
        presentation.restoreRequested { answers.append($0) }
        XCTAssertEqual(answers, [true])
        XCTAssertEqual(presentation.channel(for: .list), channel("news"))
    }

    func testRestoreReopensTheCurrentChannelOnTheScreenThatIsVisible() {
        let news = channel("news"), sport = channel("sport")
        presentation.surfaceAppeared(.list)
        presentation.surfaceAppeared(.guide)
        _ = presentation.select(news, from: .list)
        presentation.playerChannelChanged(to: sport)
        presentation.pictureInPictureStartedFromControl()
        // The guide was popped while the window played, so only the list is on screen.
        presentation.surfaceDisappeared(.guide)

        var answers: [Bool] = []
        presentation.restoreRequested { answers.append($0) }
        XCTAssertEqual(presentation.phase, .restoring(sport, .list), "the channel picked in the player, not the first tapped")
        XCTAssertEqual(presentation.channel(for: .list), sport)
        XCTAssertNil(presentation.channel(for: .guide))
        XCTAssertEqual(answers, [], "AVKit is answered only once the player is on screen")

        presentation.playerDidAppear(news)
        XCTAssertEqual(answers, [], "another channel's player does not confirm it")
        presentation.playerDidAppear(sport)
        XCTAssertEqual(answers, [true])
        XCTAssertEqual(presentation.phase, .presented(sport, .list))
        XCTAssertEqual(navigations, 0)
    }

    func testRestoreWithNoLiveTVScreenOpensLiveTVThenPresentsWhenItAppears() {
        let news = channel("news")
        enterPictureInPicture(news)
        presentation.surfaceDisappeared(.list)  // the user went to Silo Home
        var answers: [Bool] = []
        presentation.restoreRequested { answers.append($0) }
        XCTAssertEqual(navigations, 1)
        XCTAssertEqual(presentation.phase, .restoring(news, nil))

        presentation.surfaceAppeared(.list)
        XCTAssertEqual(presentation.channel(for: .list), news)
        presentation.playerDidAppear(news)
        XCTAssertEqual(answers, [true])
    }

    func testRestoreThatNeverMountsStopsPlaybackInsteadOfLeavingItHeadless() {
        let news = channel("news")
        enterPictureInPicture(news)
        presentation.surfaceDisappeared(.list)
        var answers: [Bool] = []
        presentation.restoreRequested { answers.append($0) }
        scheduler.fireAll()
        XCTAssertEqual(answers, [false])
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(presentation.phase, .idle)

        presentation.restoreTimedOut()
        XCTAssertEqual(stops, 1, "a late timeout does nothing")
    }

    func testAScreenReportingDisappearUnderItsOwnCoverStillCountsAsPresent() {
        let news = channel("news")
        presentation.surfaceAppeared(.list)
        _ = presentation.select(news, from: .list)
        presentation.surfaceDisappeared(.list)  // fullScreenCover reports the presenter as disappearing
        presentation.pictureInPictureStartedFromControl()
        presentation.restoreRequested { _ in }
        XCTAssertEqual(presentation.phase, .restoring(news, .list))
        XCTAssertEqual(navigations, 0)
    }

    // MARK: - Channel switching

    func testSelectingAnotherChannelOnTheSameRouteSwitchesTheWindowInPlace() {
        let news = channel("news"), sport = channel("sport")
        enterPictureInPicture(news)
        XCTAssertEqual(presentation.select(sport, from: .list), .playInPlace)
        XCTAssertEqual(presentation.phase, .pictureInPicture(sport))
        XCTAssertEqual(pictureInPictureStops, 0)

        presentation.pictureInPictureSettled(activeChannelID: sport.id)
        XCTAssertEqual(presentation.engagementEnded(), .stopPlayback, "once settled, closing the window is the user's")
        XCTAssertEqual(stops, 1)
    }

    func testAClosedWindowBeforeTheSwitchSettledOpensThePlayerInsteadOfStopping() {
        let news = channel("news"), sport = channel("sport")
        enterPictureInPicture(news)
        _ = presentation.select(sport, from: .list)  // the engine may still change renderer route
        XCTAssertEqual(presentation.engagementEnded(), .continuePlayback)
        XCTAssertEqual(presentation.phase, .presented(sport, .list))
        XCTAssertEqual(stops, 0)
    }

    func testSelectingAcrossRendererRoutesClosesTheWindowAndOpensThePlayer() {
        let news = channel("news"), hlsChannel = channel("hls", hls: true)
        enterPictureInPicture(news)
        XCTAssertEqual(presentation.select(hlsChannel, from: .list), .exitingPictureInPicture)
        XCTAssertEqual(pictureInPictureStops, 1)

        XCTAssertEqual(presentation.engagementEnded(), .continuePlayback)
        XCTAssertEqual(presentation.phase, .presented(hlsChannel, .list))
        XCTAssertEqual(presentation.channel(for: .list), hlsChannel)
        XCTAssertEqual(stops, 0, "the new stream plays on in the player")
    }

    func testReturningToThePlayerWithNoLiveTVScreenOpensLiveTVFirst() {
        let news = channel("news"), hlsChannel = channel("hls", hls: true)
        enterPictureInPicture(news)
        presentation.surfaceDisappeared(.list)
        _ = presentation.select(hlsChannel, from: .list)
        XCTAssertEqual(presentation.engagementEnded(), .continuePlayback)
        XCTAssertEqual(navigations, 1)
        XCTAssertEqual(presentation.channel(for: .list), hlsChannel)
    }

    func testSelectionsDuringARestoreAreNotActedOn() {
        let news = channel("news")
        enterPictureInPicture(news)
        presentation.restoreRequested { _ in }
        XCTAssertEqual(presentation.select(channel("sport"), from: .list), .ignored)
        XCTAssertEqual(presentation.activeChannel, news)
    }

    func testCrossRouteRestoreThenNewPictureInPictureClosesWithoutReopening() {
        let news = channel("news"), hls = channel("hls", hls: true)
        enterPictureInPicture(news)
        _ = presentation.select(hls, from: .list)
        var restored = false
        presentation.restoreRequested { restored = $0 }
        presentation.playerDidAppear(hls)
        XCTAssertTrue(restored)
        presentation.pictureInPictureStartedFromControl()
        XCTAssertEqual(presentation.engagementEnded(), .stopPlayback)
        XCTAssertEqual(presentation.phase, .idle)
        XCTAssertEqual(stops, 1)
    }

    func testOnlyExpectedInPlaceTargetCanSettleAndCrossRouteExitCannotSettle() {
        let news = channel("news"), sport = channel("sport")
        enterPictureInPicture(news)
        _ = presentation.select(sport, from: .list)
        presentation.pictureInPictureSettled(activeChannelID: news.id)
        XCTAssertEqual(presentation.engagementEnded(), .continuePlayback)

        presentation.pictureInPictureStartedFromControl()
        _ = presentation.select(channel("hls", hls: true), from: .list)
        presentation.pictureInPictureSettled(activeChannelID: sport.id)
        presentation.pictureInPictureSettled(activeChannelID: "hls")
        XCTAssertEqual(presentation.engagementEnded(), .continuePlayback)
        XCTAssertEqual(presentation.activeChannel?.id, "hls")
        XCTAssertEqual(stops, 0)
    }

    func testProviderRemovalStopsOnlyItsSessionAndInvalidatesDelayedRestoration() {
        let owner = UUID(), other = UUID()
        let news = channel("\(owner.uuidString):news")
        enterPictureInPicture(news)
        presentation.providerRemoved(other, activeChannelID: news.id)
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(presentation.phase, .pictureInPicture(news))
        var answers: [Bool] = []
        presentation.restoreRequested { answers.append($0) }
        presentation.providerRemoved(owner, activeChannelID: news.id)
        XCTAssertEqual(answers, [false])
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(presentation.phase, .idle)
        presentation.playerDidAppear(news)
        presentation.pictureInPictureSettled(activeChannelID: news.id)
        _ = presentation.engagementEnded()
        scheduler.fireAll()
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(presentation.phase, .idle)
    }

    func testRemovingProviderWithNoLiveTVDoesNotStopAnotherOwnersPlayback() {
        presentation.providerRemoved(UUID(), activeChannelID: nil)
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(pictureInPictureStops, 0)
    }

    func testTappingCurrentPictureInPictureChannelRestoresWithoutReloading() async {
        let engine = FakeEngine()
        let session = LiveTVPlayerSession(scheduler: scheduler, makeEngine: { engine }, isOtherVideoActive: { false })
        let news = channel("news")
        session.play(news)
        for _ in 0..<8 { await Task.yield() }
        enterPictureInPicture(news)
        XCTAssertEqual(presentation.select(news, from: .guide), .exitingPictureInPicture)
        XCTAssertEqual(pictureInPictureStops, 1)
        var answers: [Bool] = []
        presentation.restoreRequested { answers.append($0) }
        presentation.playerDidAppear(news)
        session.play(news) // The restored player's .task.
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(answers, [true])
        XCTAssertEqual(engine.loads, 1)
        XCTAssertEqual(stops, 0)
    }

    func testRetryFromEngineCreationFailureBindsOnPlayingAndIgnoresLateEventsAfterStop() async {
        enum Failure: Error { case unavailable }
        let engine = FakeEngine()
        var attempts = 0
        let session = LiveTVPlayerSession(scheduler: scheduler, makeEngine: {
            attempts += 1
            if attempts == 1 { throw Failure.unavailable }
            return engine
        }, isOtherVideoActive: { false })
        var bindings = 0
        let monitor = LiveTVPictureInPictureMonitor(session: session, presentation: presentation) {
            XCTAssertNotNil(session.engine)
            bindings += 1
        }
        session.play(channel("news"))
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(session.state, .failed)
        XCTAssertEqual(bindings, 0)
        session.retry()
        for _ in 0..<12 { await Task.yield() }
        engine.onPhase?(.playing)
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(session.state, .playing)
        XCTAssertEqual(bindings, 1)
        engine.onPhase?(.playing)
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(bindings, 1)
        session.stop()
        engine.onPhase?(.playing)
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(bindings, 1)
        withExtendedLifetime(monitor) {}
    }

    // MARK: - Ending

    func testClosingTheWindowStopsPlaybackAndClearsEverything() {
        let news = channel("news")
        enterPictureInPicture(news)
        XCTAssertEqual(presentation.engagementEnded(), .stopPlayback)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(presentation.phase, .idle)
        XCTAssertNil(presentation.activeChannel)
    }

    func testClosingTheWindowAfterAutomaticPictureInPictureDismissesTheCoverAndStops() {
        presentation.surfaceAppeared(.list)
        _ = presentation.select(channel("news"), from: .list)
        XCTAssertEqual(presentation.engagementEnded(), .stopPlayback)
        XCTAssertNil(presentation.channel(for: .list), "the cover goes with the stream")
        XCTAssertEqual(stops, 1)
    }

    func testAPlaybackFailureInTheWindowClosesItAndShowsThePlayerWithItsError() {
        let news = channel("news")
        enterPictureInPicture(news)
        presentation.playbackFailedInPictureInPicture()
        XCTAssertEqual(pictureInPictureStops, 1)
        XCTAssertEqual(presentation.engagementEnded(), .continuePlayback)
        XCTAssertEqual(presentation.phase, .presented(news, .list))
        XCTAssertEqual(stops, 0, "the player keeps the failed session so Retry can run")

        presentation.playbackFailedInPictureInPicture()
        XCTAssertEqual(pictureInPictureStops, 1, "no window left to close")
    }

    func testTearingDownThePictureInPictureCoordinatorAlwaysStopsPlayback() {
        let news = channel("news"), hlsChannel = channel("hls", hls: true)
        enterPictureInPicture(news)
        _ = presentation.select(hlsChannel, from: .list)  // a pending return, then the app signs out
        XCTAssertEqual(presentation.engagementEnded(isStillBound: false), .stopPlayback)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(presentation.phase, .idle)
        XCTAssertEqual(navigations, 0)
    }

    func testAnEndedWindowCancelsAPendingRestore() {
        let news = channel("news")
        enterPictureInPicture(news)
        presentation.surfaceDisappeared(.list)
        var answers: [Bool] = []
        presentation.restoreRequested { answers.append($0) }
        _ = presentation.engagementEnded()
        scheduler.fireAll()
        XCTAssertEqual(answers, [], "AVKit's handler is not answered after the window is gone")
        XCTAssertEqual(stops, 1)
    }
}

@MainActor
private final class ManualScheduler: LiveTVScheduling {
    private var timers: [(id: Int, action: @MainActor @Sendable () -> Void)] = []
    private var nextID = 0
    var now: Double { 0 }

    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) -> LiveTVTimerHandle {
        nextID += 1
        let id = nextID
        timers.append((id, action))
        return LiveTVTimerHandle { [weak self] in self?.timers.removeAll { $0.id == id } }
    }

    func fireAll() {
        let due = timers
        timers.removeAll()
        for timer in due { timer.action() }
    }
}

@MainActor
private final class FakeEngine: LiveTVEngineDriving {
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
