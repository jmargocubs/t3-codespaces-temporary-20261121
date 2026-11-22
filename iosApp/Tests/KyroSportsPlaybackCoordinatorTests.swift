import Foundation
import XCTest
@testable import Silo

/// One-tap Sports Hub playback: automatic attempts, bounded fallback, cancellation, the single
/// session rule and Other Streams switching.
@MainActor
final class KyroSportsPlaybackCoordinatorTests: XCTestCase {
    private var scheduler: KyroSportsPlaybackTestScheduler!
    private var driver: KyroSportsPlaybackTestDriver!
    private var coordinator: KyroSportsPlaybackCoordinator!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        scheduler = KyroSportsPlaybackTestScheduler()
        driver = KyroSportsPlaybackTestDriver()
        coordinator = KyroSportsPlaybackCoordinator(scheduler: scheduler)
        coordinator.driver = driver
    }

    // MARK: Fixtures

    private func game(status: KyroGameStatus = .live, start: Date? = nil) -> KyroSportsGame {
        let away = KyroSportsTeam(id: "a", league: .collegeFootball, abbreviation: "MSU", nickname: "Spartans", location: "Michigan State")
        let home = KyroSportsTeam(id: "h", league: .collegeFootball, abbreviation: "MICH", nickname: "Wolverines", location: "Michigan")
        return KyroSportsGame(id: KyroGameID(provider: "espn", league: .collegeFootball, rawID: "1"),
                              league: .collegeFootball, startTime: start ?? now, status: status,
                              home: KyroGameTeam(team: home), away: KyroGameTeam(team: away))
    }

    private func candidate(_ id: String, eligible: Bool = true, source: KyroSportsStreamMatch.Source = .channelName) -> KyroSportsStreamMatch {
        let channel = LiveTVChannel(id: id, guideID: nil, name: "Stream \(id)", streamURL: URL(string: "https://example.com/\(id).ts")!,
                                    logoURL: nil, category: "Events")
        return KyroSportsStreamMatch(id: id, channel: channel, program: nil, confidence: .medium, score: 60, reasons: [],
                                     isStale: false, source: source, isAutoPlayEligible: eligible)
    }

    private func result(_ matches: [KyroSportsStreamMatch], broadcasters: [KyroSportsStreamMatch] = []) -> KyroSportsStreamMatchResult {
        var result = KyroSportsStreamMatchResult(confidence: .medium, matches: matches, manualSearchQuery: "q",
                                                 guideWasStale: false, indexWasCancelled: false)
        result.autoPlayCandidates = matches.filter(\.isAutoPlayEligible)
        result.possibleBroadcasters = broadcasters
        return result
    }

    @discardableResult
    private func tap(_ matches: [KyroSportsStreamMatch], game: KyroSportsGame? = nil, auto: Bool = true) -> KyroSportsGame {
        let game = game ?? self.game()
        let token = coordinator.beginSearching(game)
        coordinator.start(result(matches), for: game, token: token, allowsAutomaticPlayback: auto)
        return game
    }

    private func report(_ state: LiveTVPlaybackState) {
        driver.state = state
        coordinator.sessionDidChange()
    }

    // MARK: Automatic attempts

    func testFirstCandidateThatPlaysIsPresented() {
        tap([candidate("a"), candidate("b")])
        XCTAssertEqual(coordinator.phase, .connecting(channelName: "Stream a", attempt: 1, total: 2))
        XCTAssertNil(driver.presented, "the player waits for real playback")
        report(.playing)
        XCTAssertEqual(coordinator.phase, .presented)
        XCTAssertEqual(driver.presented?.id, "a")
        XCTAssertEqual(driver.starts.map(\.id), ["a"])
        XCTAssertEqual(coordinator.context?.status(of: "a"), .verified)
        XCTAssertEqual(coordinator.context?.status(of: "b"), .untested)
    }

    func testFailedFirstCandidateFallsBackToTheSecond() {
        tap([candidate("a"), candidate("b")])
        report(.failed)
        XCTAssertEqual(coordinator.phase, .connecting(channelName: "Stream b", attempt: 2, total: 2))
        report(.playing)
        XCTAssertEqual(driver.presented?.id, "b")
        XCTAssertEqual(driver.starts.map(\.id), ["a", "b"])
        XCTAssertEqual(coordinator.context?.status(of: "a"), .failed)
        XCTAssertEqual(coordinator.context?.status(of: "b"), .verified)
    }

    func testSilentCandidateTimesOutAndTheNextIsTried() {
        tap([candidate("a"), candidate("b")])
        scheduler.advance(by: KyroSportsPlaybackCoordinator.attemptTimeoutSeconds)
        XCTAssertEqual(driver.starts.map(\.id), ["a", "b"])
        XCTAssertEqual(coordinator.context?.status(of: "a"), .failed)
    }

    func testAllCandidatesFailingHandsOverToDiscoveryAndStopsPlayback() {
        let game = tap([candidate("a"), candidate("b"), candidate("c")])
        report(.failed)
        report(.failed)
        report(.failed)
        guard case .exhausted(let shownGame, let shown) = coordinator.phase else {
            return XCTFail("expected the discovery screen, got \(coordinator.phase)")
        }
        XCTAssertEqual(shownGame.id, game.id)
        XCTAssertEqual(shown.attemptStatuses["a"], .failed)
        XCTAssertEqual(shown.attemptStatuses["c"], .failed)
        XCTAssertEqual(driver.stops, 1)
        XCTAssertNil(driver.presented)
    }

    func testAttemptsAreBoundedByCountAndTotalTime() {
        let many = (0..<8).map { candidate("c\($0)") }
        tap(many)
        XCTAssertEqual(coordinator.phase, .connecting(channelName: "Stream c0", attempt: 1, total: KyroSportsStreamMatcher.maximumAutoPlayCandidates))
        let timeout = KyroSportsPlaybackCoordinator.attemptTimeoutSeconds
        scheduler.advance(by: timeout)
        scheduler.advance(by: timeout)
        XCTAssertEqual(driver.starts.count, 3)
        // 12 + 12 s used: the third attempt only gets what is left of the 30 s budget.
        scheduler.advance(by: KyroSportsPlaybackCoordinator.totalBudgetSeconds - 2 * timeout)
        guard case .exhausted = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        scheduler.advance(by: 120)
        XCTAssertEqual(driver.starts.count, KyroSportsStreamMatcher.maximumAutoPlayCandidates, "never an endless loop")
    }

    func testLeadsThatAreNotStrongEnoughAreNeverTriedAutomatically() {
        tap([candidate("lead", eligible: false), candidate("fox", eligible: false, source: .broadcaster)])
        XCTAssertTrue(driver.starts.isEmpty)
        guard case .exhausted = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
    }

    func testEventThatIsNotLiveOpensDiscoveryWithoutPlaying() {
        let later = game(status: .scheduled, start: now.addingTimeInterval(3 * 3600))
        XCTAssertFalse(KyroSportsPlaybackPolicy.allowsAutomaticPlayback(later, now: now))
        XCTAssertFalse(KyroSportsPlaybackPolicy.allowsAutomaticPlayback(game(status: .final), now: now))
        // Build 39: a game 20 minutes from kickoff is still upcoming, so it never plays.
        XCTAssertFalse(KyroSportsPlaybackPolicy.allowsAutomaticPlayback(game(status: .scheduled, start: now.addingTimeInterval(20 * 60)), now: now))
        XCTAssertFalse(KyroSportsPlaybackPolicy.allowsAutomaticPlayback(game(status: .postponed), now: now))
        XCTAssertFalse(KyroSportsPlaybackPolicy.allowsAutomaticPlayback(game(status: .canceled), now: now))
        XCTAssertTrue(KyroSportsPlaybackPolicy.allowsAutomaticPlayback(game(status: .live), now: now))
        tap([candidate("a")], game: later, auto: KyroSportsPlaybackPolicy.allowsAutomaticPlayback(later, now: now))
        XCTAssertTrue(driver.starts.isEmpty)
        guard case .exhausted = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
    }

    func testOtherVideoInPictureInPictureStopsTheAttemptsAtOnce() {
        tap([candidate("a"), candidate("b")])
        driver.terminal = true
        report(.failed)
        guard case .unavailable = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertEqual(driver.starts.map(\.id), ["a"], "another stream would fail the same way")
    }

    func testCandidateGoneFromTheCatalogIsSkipped() {
        driver.unresolvable = ["a"]
        tap([candidate("a"), candidate("b")])
        XCTAssertEqual(driver.starts.map(\.id), ["b"])
    }

    // MARK: Cancellation and the single session

    func testCancelDuringConnectionStopsAndIgnoresALateSuccess() {
        tap([candidate("a"), candidate("b")])
        coordinator.cancel()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(driver.stops, 1)
        report(.playing)
        scheduler.advance(by: 60)
        XCTAssertNil(driver.presented)
        XCTAssertEqual(driver.starts.map(\.id), ["a"])
    }

    func testANewTapSupersedesTheAttemptInFlight() {
        tap([candidate("a")])
        let second = game()
        let token = coordinator.beginSearching(second)
        XCTAssertEqual(driver.stops, 1, "the first attempt's stream is stopped, never left running")
        let stale = token - 1
        coordinator.start(result([candidate("x")]), for: second, token: stale, allowsAutomaticPlayback: true)
        XCTAssertEqual(coordinator.phase, .searching(second.id), "a stale search result is ignored")
        coordinator.start(result([candidate("b")]), for: second, token: token, allowsAutomaticPlayback: true)
        XCTAssertEqual(driver.starts.map(\.id), ["a", "b"])
    }

    func testOnlyOneStreamIsEverConnecting() {
        tap((0..<3).map { candidate("c\($0)") })
        for _ in 0..<3 {
            XCTAssertLessThanOrEqual(driver.concurrentSessions, 1)
            report(.failed)
        }
        XCTAssertEqual(driver.maximumConcurrentSessions, 1)
    }

    // MARK: Other Streams

    func testSwitchingToAnotherStreamKeepsTheEventContext() {
        let game = tap([candidate("a"), candidate("b"), candidate("c")])
        report(.playing)
        let contextID = coordinator.context?.id
        driver.state = .connecting
        XCTAssertTrue(coordinator.switchTo(candidate("b")))
        XCTAssertEqual(driver.retunes.map(\.id), ["b"])
        XCTAssertEqual(coordinator.context?.status(of: "b"), .connecting)
        report(.playing)
        XCTAssertEqual(coordinator.context?.status(of: "b"), .verified)
        XCTAssertEqual(coordinator.context?.currentChannelID, "b")
        XCTAssertEqual(coordinator.context?.id, contextID, "no new discovery")
        XCTAssertEqual(coordinator.context?.game.id, game.id)
        XCTAssertEqual(coordinator.context?.alternatives.map(\.channel.id), ["a", "b", "c"])
        XCTAssertEqual(driver.presented?.id, "a", "the player is presented once")
    }

    func testFailedAlternativeIsMarkedAndAnotherCanBeChosen() {
        tap([candidate("a"), candidate("b")])
        report(.playing)
        XCTAssertTrue(coordinator.switchTo(candidate("b")))
        report(.failed)
        XCTAssertEqual(coordinator.context?.status(of: "b"), .failed)
        XCTAssertEqual(coordinator.phase, .presented, "the player stays up with its error and Retry")
        XCTAssertTrue(coordinator.switchTo(candidate("a")))
        report(.playing)
        XCTAssertEqual(coordinator.context?.status(of: "a"), .verified)
    }

    func testBroadcastersStaySeparateAndChosenSearchResultsAreKept() {
        let game = self.game()
        let token = coordinator.beginSearching(game)
        coordinator.start(result([candidate("a")], broadcasters: [candidate("fox", eligible: false, source: .broadcaster)]),
                          for: game, token: token, allowsAutomaticPlayback: true)
        report(.playing)
        XCTAssertEqual(coordinator.context?.broadcasters.map(\.channel.id), ["fox"])
        XCTAssertTrue(coordinator.switchTo(candidate("manual", eligible: false, source: .manual)))
        XCTAssertEqual(coordinator.context?.alternatives.map(\.channel.id), ["a", "manual"])
    }

    func testClosingThePlayerOrOrdinaryPlaybackEndsTheEventContext() {
        tap([candidate("a")])
        report(.playing)
        coordinator.playerClosed()
        XCTAssertNil(coordinator.context)
        XCTAssertEqual(coordinator.phase, .idle)

        tap([candidate("a")])
        report(.playing)
        coordinator.ordinaryPlaybackStarted()
        XCTAssertNil(coordinator.context, "Live TV played outside Sports Hub")
        XCTAssertFalse(coordinator.switchTo(candidate("a")))
    }

    func testManualChoiceFromDiscoveryPlaysThroughTheSameRoute() {
        let game = tap([candidate("a")])
        report(.failed)
        guard case .exhausted(_, let shown) = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        coordinator.playChosen(candidate("manual", eligible: false, source: .manual), game: game, result: shown)
        XCTAssertEqual(driver.starts.last?.id, "manual")
        report(.playing)
        XCTAssertEqual(driver.presented?.id, "manual")
        XCTAssertEqual(coordinator.context?.status(of: "a"), .failed, "what was tried stays known")
    }

    func testFailedChoiceFromChannelSearchIsReportedWhenDiscoveryReturns() {
        let game = tap([])
        guard case .exhausted(_, let shown) = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertNil(KyroSportsStreamDiscovery.notice(for: game, result: shown, now: now))

        coordinator.playChosen(candidate("search", eligible: false, source: .manual), game: game, result: shown)
        report(.failed)
        guard case .exhausted(_, let returned) = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertEqual(returned.attemptStatuses["search"], .failed, "a search pick lives only in the context")
        XCTAssertNotNil(KyroSportsStreamDiscovery.notice(for: game, result: returned, now: now),
                        "the screen says the chosen stream did not play")
    }

    // MARK: Build 41: discovery wording and Picture in Picture

    func testFailedChoiceIsDescribedAsTheViewersPickNotTheBestStream() {
        let game = tap([candidate("a")])
        report(.failed)
        guard case .exhausted(_, let automatic) = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertFalse(automatic.choiceDidNotPlay)
        XCTAssertEqual(KyroSportsStreamDiscovery.notice(for: game, result: automatic, now: now),
                       "The best stream for this game didn't start. Choose another or search your channels.")

        coordinator.playChosen(candidate("search", eligible: false, source: .manual), game: game, result: automatic)
        report(.failed)
        guard case .exhausted(_, let chosen) = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertTrue(chosen.choiceDidNotPlay)
        XCTAssertEqual(KyroSportsStreamDiscovery.notice(for: game, result: chosen, now: now),
                       "The stream you chose didn't start. Choose another or search your channels.")
        XCTAssertEqual(chosen.attemptStatuses["a"], .failed, "earlier failures stay marked")
        XCTAssertEqual(chosen.attemptStatuses["search"], .failed)
    }

    func testChoiceThatPlaysIsNotReportedAsFailed() {
        let game = tap([candidate("a")])
        report(.failed)
        guard case .exhausted(_, let shown) = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        coordinator.playChosen(candidate("b", eligible: false), game: game, result: shown)
        report(.playing)
        XCTAssertEqual(coordinator.phase, .presented)
    }

    func testPictureInPictureThatWillNotCloseReturnsTheChoiceToDiscovery() {
        let game = tap([candidate("a")])
        report(.failed)
        guard case .exhausted(_, let shown) = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        let stops = driver.stops
        // What LiveTVService.playSportsStream does: show progress, then report Picture in Picture.
        let token = coordinator.beginSearching(game)
        XCTAssertTrue(coordinator.isBusy, "the connecting banner shows while Picture in Picture closes")
        coordinator.startUnavailable(shown, for: game, token: token, message: "Close Picture in Picture, then try again.")
        guard case .unavailable(_, let returned, let message) = coordinator.phase else {
            return XCTFail("the pick must not fail silently: \(coordinator.phase)")
        }
        XCTAssertEqual(message, "Close Picture in Picture, then try again.")
        XCTAssertEqual(returned.attemptStatuses["a"], .failed, "what was tried stays known")
        XCTAssertEqual(driver.starts.map(\.id), ["a"], "nothing new was started")
        XCTAssertEqual(driver.stops, stops)
    }

    func testCancelWhilePictureInPictureClosesDropsTheLateAnswer() {
        let game = tap([candidate("a")])
        report(.failed)
        guard case .exhausted(_, let shown) = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        let token = coordinator.beginSearching(game)
        coordinator.cancel()
        coordinator.startUnavailable(shown, for: game, token: token, message: "late")
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertNil(coordinator.context)
    }
}

// MARK: - Test doubles

@MainActor
final class KyroSportsPlaybackTestDriver: KyroSportsPlaybackDriving {
    var state: LiveTVPlaybackState = .stopped
    var channelID: String?
    var terminal = false
    var unresolvable: Set<String> = []
    private(set) var starts: [LiveTVChannel] = []
    private(set) var retunes: [LiveTVChannel] = []
    private(set) var presented: LiveTVChannel?
    private(set) var stops = 0
    private(set) var concurrentSessions = 0
    private(set) var maximumConcurrentSessions = 0

    var sportsPlaybackState: LiveTVPlaybackState { state }
    var sportsPlaybackChannelID: String? { channelID }
    var sportsPlaybackFailureIsTerminal: Bool { terminal && state == .failed }

    func sportsResolve(_ channel: LiveTVChannel) -> LiveTVChannel? {
        unresolvable.contains(channel.id) ? nil : channel
    }

    func sportsStartPlayback(_ channel: LiveTVChannel) {
        // One session: a start retunes it, so at most one stream exists.
        concurrentSessions = 1
        maximumConcurrentSessions = max(maximumConcurrentSessions, concurrentSessions)
        starts.append(channel)
        channelID = channel.id
        state = .connecting
    }

    func sportsPresentPlayer(_ channel: LiveTVChannel) {
        if presented == nil { presented = channel }
    }

    func sportsRetunePresentedPlayer(_ channel: LiveTVChannel) -> Bool {
        retunes.append(channel)
        channelID = channel.id
        state = .connecting
        return true
    }

    func sportsStopPlayback() {
        stops += 1
        concurrentSessions = 0
        state = .stopped
        channelID = nil
    }
}

@MainActor
final class KyroSportsPlaybackTestScheduler: LiveTVScheduling {
    private var timers: [(id: Int, due: Double, action: @MainActor @Sendable () -> Void)] = []
    private var nextID = 0
    private(set) var now: Double = 0

    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) -> LiveTVTimerHandle {
        nextID += 1
        let id = nextID
        timers.append((id, now + seconds, action))
        return LiveTVTimerHandle { [weak self] in self?.timers.removeAll { $0.id == id } }
    }

    func advance(by seconds: Double) {
        let target = now + seconds
        while let next = timers.filter({ $0.due <= target }).min(by: { $0.due < $1.due }) {
            timers.removeAll { $0.id == next.id }
            now = next.due
            next.action()
        }
        now = target
    }
}
