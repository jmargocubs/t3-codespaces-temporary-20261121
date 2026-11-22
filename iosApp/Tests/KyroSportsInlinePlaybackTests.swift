import Foundation
import XCTest
@testable import Silo

/// Build 46: a tapped live event plays in Sports Hub's inline player over the one Live TV session.
/// Expanding, collapsing, Picture in Picture, Other Streams and event switches all move that same
/// stream between surfaces; none of them creates a second player or session.
@MainActor
final class KyroSportsInlinePlaybackTests: XCTestCase {
    private var scheduler: KyroSportsPlaybackTestScheduler!
    private var presentation: LiveTVPresentation!
    private var driver: KyroSportsInlineTestDriver!
    private var coordinator: KyroSportsPlaybackCoordinator!
    private var stops = 0
    private var pictureInPictureStops = 0
    private var navigations = 0
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        scheduler = KyroSportsPlaybackTestScheduler()
        presentation = LiveTVPresentation(scheduler: scheduler)
        stops = 0
        pictureInPictureStops = 0
        navigations = 0
        presentation.stopPlayback = { [unowned self] in
            stops += 1
            driver.sessionStopped()
        }
        presentation.stopPictureInPicture = { [unowned self] in pictureInPictureStops += 1 }
        presentation.navigateToLiveTV = { [unowned self] in navigations += 1 }
        driver = KyroSportsInlineTestDriver(presentation: presentation)
        coordinator = KyroSportsPlaybackCoordinator(scheduler: scheduler)
        coordinator.driver = driver
        presentation.inlineHostAppeared()
    }

    // MARK: Fixtures

    private func channel(_ id: String, hls: Bool = false) -> LiveTVChannel {
        LiveTVChannel(id: id, guideID: nil, name: "Stream \(id)",
                      streamURL: URL(string: "https://tv.example/\(id).\(hls ? "m3u8" : "ts")")!,
                      logoURL: nil, category: "Sports")
    }

    private func game(_ raw: String) -> KyroSportsGame {
        let away = KyroSportsTeam(id: "a\(raw)", league: .nba, abbreviation: "BOS", nickname: "Celtics", location: "Boston")
        let home = KyroSportsTeam(id: "h\(raw)", league: .nba, abbreviation: "NYK", nickname: "Knicks", location: "New York")
        return KyroSportsGame(id: KyroGameID(provider: "espn", league: .nba, rawID: raw), league: .nba,
                              startTime: now, status: .live, home: KyroGameTeam(team: home), away: KyroGameTeam(team: away))
    }

    private func match(_ id: String) -> KyroSportsStreamMatch {
        KyroSportsStreamMatch(id: id, channel: channel(id), program: nil, confidence: .high, score: 90, reasons: [],
                              isStale: false, source: .guide, isAutoPlayEligible: true)
    }

    private func result(_ ids: [String]) -> KyroSportsStreamMatchResult {
        let matches = ids.map(match)
        var result = KyroSportsStreamMatchResult(confidence: .high, matches: matches, manualSearchQuery: "q",
                                                 guideWasStale: false, indexWasCancelled: false)
        result.autoPlayCandidates = matches
        return result
    }

    private var mode: KyroSportsInlinePlayerMode {
        .make(sports: coordinator.phase, presentation: presentation.phase)
    }

    /// What `LiveTVService.playSportsEvent` does, with discovery answering at once.
    @discardableResult
    private func tap(_ game: KyroSportsGame, streams: [String]) -> KyroSportsGame {
        let token = coordinator.beginSearching(game)
        XCTAssertEqual(mode, .finding, "the inline frame appears with the search, before any stream moves")
        // prepareSportsPlayback: another event's inline stream ends before the attempts.
        if presentation.isInline {
            presentation.releaseInline()
            driver.sportsStopPlayback()
        }
        coordinator.start(result(streams), for: game, token: token, allowsAutomaticPlayback: true)
        return game
    }

    private func report(_ state: LiveTVPlaybackState) {
        driver.state = state
        coordinator.sessionDidChange()
    }

    /// LiveTVService's session observer: the presentation went idle under a presented event.
    private func observeSession() {
        coordinator.sessionDidChange()
        if coordinator.phase == .presented, presentation.phase == .idle { coordinator.playerClosed() }
    }

    private func playInline(_ id: String = "a", game raw: String = "1") -> KyroSportsGame {
        let game = tap(game(raw), streams: [id])
        report(.playing)
        XCTAssertEqual(presentation.phase, .inline(channel(id)))
        return game
    }

    // MARK: Immediate inline playback

    func testTapPlaysTheVerifiedStreamInlineWithNoCover() {
        let game = tap(game("1"), streams: ["a", "b"])
        XCTAssertEqual(coordinator.phase, .connecting(channelName: "Stream a", attempt: 1, total: 2))
        XCTAssertEqual(mode, .finding)
        XCTAssertEqual(presentation.phase, .idle, "nothing is shown before the stream moves")

        report(.playing)
        XCTAssertEqual(coordinator.phase, .presented)
        XCTAssertEqual(mode, .playing(channel("a")))
        XCTAssertEqual(presentation.phase, .inline(channel("a")))
        XCTAssertNil(presentation.channel(for: .shell), "no full-screen cover opens on a tap")
        XCTAssertNil(presentation.channel(for: .list))
        XCTAssertEqual(navigations, 0, "Sports Hub stays on screen")
        XCTAssertTrue(coordinator.isPlaying(game.id))
    }

    func testAFailedStreamFallsBackInsideTheInlineFrame() {
        tap(game("1"), streams: ["a", "b"])
        report(.failed)
        XCTAssertEqual(mode, .finding)
        XCTAssertEqual(coordinator.phase, .connecting(channelName: "Stream b", attempt: 2, total: 2))
        report(.playing)
        XCTAssertEqual(mode, .playing(channel("b")))
        XCTAssertEqual(driver.starts.map(\.id), ["a", "b"])
        XCTAssertEqual(coordinator.context?.status(of: "a"), .failed)
    }

    func testNothingPlayingHidesTheFrameForTheDiscoveryScreen() {
        tap(game("1"), streams: ["a"])
        report(.failed)
        guard case .exhausted = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertEqual(mode, .hidden)
        XCTAssertEqual(presentation.phase, .idle)
    }

    // MARK: Single session and event switching

    func testSwitchingEventsRetunesTheOneSessionAndEndsThePreviousStreamFirst() {
        let first = playInline("a", game: "1")
        let second = tap(game("2"), streams: ["b"])
        XCTAssertEqual(driver.stops, 1, "the first event's audio ends before the next attempt")
        XCTAssertEqual(presentation.phase, .idle)
        report(.playing)
        XCTAssertEqual(presentation.phase, .inline(channel("b")))
        XCTAssertEqual(coordinator.context?.game.id, second.id)
        XCTAssertFalse(coordinator.isPlaying(first.id))
        XCTAssertTrue(coordinator.isPlaying(second.id))
        XCTAssertEqual(driver.maximumConcurrentSessions, 1)
        XCTAssertEqual(driver.inlinePresentations.map(\.id), ["a", "b"])
    }

    func testTheEventAlreadyPlayingInlineIsNotRetunedByASecondTap() {
        let game = playInline()
        // LiveTVService.playSportsEvent's guard.
        XCTAssertTrue(coordinator.isPlaying(game.id) && presentation.isInline)
        XCTAssertEqual(driver.starts.count, 1)
    }

    func testOtherStreamsRetunesTheInlinePlayerInPlace() {
        let game = game("1")
        let token = coordinator.beginSearching(game)
        var choices = result(["a"])
        choices.possibleBroadcasters = [match("b")]
        coordinator.start(choices, for: game, token: token, allowsAutomaticPlayback: true)
        report(.playing)
        XCTAssertTrue(coordinator.switchTo(match("b")))
        XCTAssertEqual(presentation.phase, .inline(channel("b")))
        XCTAssertEqual(coordinator.context?.currentChannelID, "b")
        report(.playing)
        XCTAssertEqual(coordinator.context?.status(of: "b"), .verified)
        XCTAssertEqual(driver.starts.count, 1, "a switch retunes, it does not start another session")
        XCTAssertEqual(driver.maximumConcurrentSessions, 1)
    }

    func testOneEngineServesInlineFullScreenAndAnEventSwitch() async {
        let engine = KyroSportsInlineTestEngine()
        let session = LiveTVPlayerSession(scheduler: scheduler, makeEngine: { engine }, isOtherVideoActive: { false })
        session.play(channel("a"))
        for _ in 0..<8 { await Task.yield() }
        presentation.showInline(channel("a"))
        presentation.expandInline()
        session.play(channel("a")) // The full-screen player's .task.
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(engine.loads, 1, "expanding shows the running stream; it does not reload it")
        XCTAssertTrue(presentation.collapseToInline())
        session.play(channel("b")) // The next event's attempt.
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(session.enginesCreated, 1)
        XCTAssertEqual(engine.loads, 2)
        session.stop()
    }

    // MARK: Full screen and inline

    func testExpandingAndCollapsingMovesTheStreamWithoutStoppingIt() {
        let stream = channel("a")
        _ = playInline()
        presentation.expandInline()
        XCTAssertEqual(presentation.phase, .presented(stream, .shell))
        XCTAssertEqual(presentation.channel(for: .shell), stream)
        XCTAssertEqual(mode, .elsewhere(stream, isPictureInPicture: false),
                       "the inline frame hosts no surface while the cover shows the stream")
        XCTAssertTrue(presentation.canCollapseToInline)

        XCTAssertTrue(presentation.collapseToInline())
        XCTAssertEqual(presentation.phase, .inline(stream))
        XCTAssertNil(presentation.channel(for: .shell), "the cover closes")
        XCTAssertFalse(LiveTVPictureInPicturePolicy.shouldStopWhenPlayerDisappears(presentation.phase),
                       "the closing cover leaves the stream to the inline player")
        observeSession()
        XCTAssertEqual(coordinator.phase, .presented)
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(navigations, 0)
    }

    func testAHubCoveredByTheFullScreenPlayerIsStillThereToCollapseInto() {
        _ = playInline()
        presentation.expandInline()
        presentation.inlineHostDisappeared()
        XCTAssertTrue(presentation.canCollapseToInline)
        XCTAssertEqual(stops, 0)
    }

    func testOrdinaryLiveTVPlaybackNeverOffersCollapse() {
        let news = channel("news")
        XCTAssertEqual(presentation.select(news, from: .shell), .present)
        XCTAssertFalse(presentation.canCollapseToInline, "Search and the Live TV tab keep their Stop")
        XCTAssertFalse(presentation.collapseToInline())
        XCTAssertEqual(presentation.phase, .presented(news, .shell))
    }

    func testLiveTVSelectionFromInlineTakesOverAsOrdinaryPlayback() {
        _ = playInline()
        let news = channel("news")
        XCTAssertEqual(presentation.select(news, from: .list), .present)
        XCTAssertEqual(presentation.phase, .presented(news, .list))
        XCTAssertFalse(presentation.canCollapseToInline)
    }

    // MARK: Picture in Picture

    func testPictureInPictureFromInlineRestoresIntoTheInlinePlayer() {
        let stream = channel("a")
        _ = playInline()
        presentation.pictureInPictureStartedFromControl()
        XCTAssertEqual(presentation.phase, .pictureInPicture(stream))
        XCTAssertEqual(mode, .elsewhere(stream, isPictureInPicture: true))
        observeSession()
        XCTAssertEqual(coordinator.phase, .presented, "the event keeps its context in the window")

        var answers: [Bool] = []
        presentation.restoreRequested { answers.append($0) }
        // Build 68.1: this expected an immediate answer, but since Build 62 the restore is answered
        // only once the inline Aether surface has mounted, so AVKit never hands the layer back to
        // nothing (`LiveTVPresentation.restoreRequested`). The test now checks that contract.
        XCTAssertEqual(answers, [], "AVKit waits until the inline surface is back on screen")
        XCTAssertEqual(presentation.phase, .inline(stream))
        presentation.inlinePlayerDidAppear(channel("other"))
        XCTAssertEqual(answers, [], "another channel's surface does not answer")
        presentation.inlinePlayerDidAppear(stream)
        XCTAssertEqual(answers, [true], "the inline player is still on screen and takes the stream back")
        XCTAssertEqual(presentation.phase, .inline(stream))
        XCTAssertEqual(mode, .playing(stream))
        XCTAssertNil(presentation.channel(for: .shell), "no full-screen cover opens over the hub")
        XCTAssertEqual(navigations, 0, "the Live TV tab is not selected")
        XCTAssertEqual(stops, 0)
    }

    func testAutomaticPictureInPictureFromInlineRestoresIntoTheInlinePlayer() {
        _ = playInline()
        var answers: [Bool] = []
        presentation.restoreRequested { answers.append($0) }
        XCTAssertEqual(answers, [true], "the inline player is already the interface")
        XCTAssertEqual(presentation.phase, .inline(channel("a")))
        XCTAssertNil(presentation.channel(for: .shell))
    }

    func testClosingTheWindowAfterAutomaticPictureInPictureEndsTheInlineStream() {
        _ = playInline()
        XCTAssertEqual(presentation.engagementEnded(), .stopPlayback)
        XCTAssertEqual(presentation.phase, .idle)
        XCTAssertEqual(stops, 1)
        observeSession()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertNil(coordinator.context)
    }

    func testAFailureInTheWindowReturnsToTheInlinePlayer() {
        let stream = channel("a")
        _ = playInline()
        presentation.pictureInPictureStartedFromControl()
        presentation.playbackFailedInPictureInPicture()
        XCTAssertEqual(pictureInPictureStops, 1)
        XCTAssertEqual(presentation.engagementEnded(), .continuePlayback)
        XCTAssertEqual(presentation.phase, .inline(stream), "the failure and Retry show on the inline player")
        XCTAssertEqual(navigations, 0)
    }

    func testLeavingTheHubDuringPictureInPictureRestoresWithStopInsteadOfCollapse() {
        let stream = channel("a")
        _ = playInline()
        presentation.pictureInPictureStartedFromControl()
        presentation.inlineHostDisappeared()
        XCTAssertEqual(stops, 0, "the window keeps playing while the viewer browses")
        presentation.restoreRequested { _ in }
        presentation.playerDidAppear(stream)
        XCTAssertEqual(presentation.phase, .presented(stream, .shell))
        XCTAssertFalse(presentation.canCollapseToInline, "no inline player is on screen to return to")
    }

    func testTheInlinePlayerIsNotShownWhileACoverOrWindowOwnsTheStream() {
        let stream = channel("a")
        _ = presentation.select(stream, from: .shell)
        XCTAssertFalse(presentation.showInline(stream))
        presentation.pictureInPictureStartedFromControl()
        XCTAssertFalse(presentation.showInline(stream))
        XCTAssertEqual(presentation.phase, .pictureInPicture(stream))
    }

    // MARK: Dismissal and cancellation

    func testCancelWhileFindingRemovesTheFrameAndStopsTheAttempt() {
        tap(game("1"), streams: ["a"])
        coordinator.cancel()
        XCTAssertEqual(mode, .hidden)
        XCTAssertEqual(driver.stops, 1)
        XCTAssertEqual(presentation.phase, .idle)
    }

    func testStopOnTheInlinePlayerEndsTheStreamAndTheEvent() {
        _ = playInline()
        presentation.closeInline()
        XCTAssertEqual(presentation.phase, .idle)
        XCTAssertEqual(stops, 1)
        observeSession()
        XCTAssertEqual(mode, .hidden)
        XCTAssertNil(coordinator.context)
    }

    func testLeavingSportsHubEndsTheInlineStreamInsteadOfPlayingHeadless() {
        _ = playInline()
        presentation.inlineHostDisappeared()
        XCTAssertEqual(presentation.phase, .idle)
        XCTAssertEqual(stops, 1)
        observeSession()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(driver.state, .stopped, "no audio is left without a picture")
    }

    func testALateSuccessAfterCancelNeverShowsTheInlinePlayer() {
        tap(game("1"), streams: ["a"])
        coordinator.cancel()
        report(.playing)
        XCTAssertEqual(presentation.phase, .idle)
        XCTAssertTrue(driver.inlinePresentations.isEmpty)
    }
}

/// Drives a real `LiveTVPresentation` the way `LiveTVService` does, over one fake session.
@MainActor
final class KyroSportsInlineTestDriver: KyroSportsPlaybackDriving {
    let presentation: LiveTVPresentation
    var state: LiveTVPlaybackState = .stopped
    var channelID: String?
    private(set) var starts: [LiveTVChannel] = []
    private(set) var inlinePresentations: [LiveTVChannel] = []
    private(set) var stops = 0
    private var sessions = 0
    private(set) var maximumConcurrentSessions = 0

    init(presentation: LiveTVPresentation) {
        self.presentation = presentation
    }

    var sportsPlaybackState: LiveTVPlaybackState { state }
    var sportsPlaybackChannelID: String? { channelID }
    var sportsPlaybackFailureIsTerminal: Bool { false }

    func sportsResolve(_ channel: LiveTVChannel) -> LiveTVChannel? { channel }

    func sportsStartPlayback(_ channel: LiveTVChannel) {
        sessions = 1
        maximumConcurrentSessions = max(maximumConcurrentSessions, sessions)
        starts.append(channel)
        channelID = channel.id
        state = .connecting
    }

    func sportsPresentPlayer(_ channel: LiveTVChannel) {
        inlinePresentations.append(channel)
        if !presentation.showInline(channel) { _ = presentation.select(channel, from: .shell) }
    }

    func sportsRetunePresentedPlayer(_ channel: LiveTVChannel) -> Bool {
        presentation.playerChannelChanged(to: channel)
        channelID = channel.id
        state = .connecting
        return true
    }

    func sportsStopPlayback() {
        stops += 1
        sessionStopped()
    }

    func sessionStopped() {
        sessions = 0
        state = .stopped
        channelID = nil
    }
}

@MainActor
private final class KyroSportsInlineTestEngine: LiveTVEngineDriving {
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
