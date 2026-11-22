import Foundation
import Observation

/// What the coordinator asks of Live TV. `LiveTVService` is the only production driver; it routes
/// every call through the one Live TV player session and the shared presentation, so Sports Hub
/// never owns a player, an engine or a second session.
@MainActor
protocol KyroSportsPlaybackDriving: AnyObject {
    /// The one Live TV session's state and the channel it is tuned to.
    var sportsPlaybackState: LiveTVPlaybackState { get }
    var sportsPlaybackChannelID: String? { get }
    /// The session failed for a reason another channel cannot fix (another app video owns
    /// Picture in Picture). Trying more streams would only fail the same way.
    var sportsPlaybackFailureIsTerminal: Bool { get }
    /// Revalidates the channel against the current catalog. Nil when it is gone or unplayable.
    func sportsResolve(_ channel: LiveTVChannel) -> LiveTVChannel?
    /// Starts or retunes the session without presenting the player.
    func sportsStartPlayback(_ channel: LiveTVChannel)
    /// Shows the channel now playing in Sports Hub's inline player (Build 46). The inline player
    /// expands to the full-screen player and Picture in Picture over the same session.
    func sportsPresentPlayer(_ channel: LiveTVChannel)
    /// Retunes the presented player through its own channel-switch route.
    func sportsRetunePresentedPlayer(_ channel: LiveTVChannel) -> Bool
    func sportsStopPlayback()
}

/// A stream's standing for the selected event.
enum KyroSportsStreamStatus: Equatable, Sendable {
    /// Credible, not tried yet.
    case untested
    case connecting
    /// Reached actual playback (motion) in this session.
    case verified
    case failed
}

/// The event a Sports Hub playback belongs to and every stream offered for it. Kept for the
/// whole player session, across switches, so Other Streams never re-runs discovery.
struct KyroSportsPlaybackContext: Equatable, Sendable {
    let id: UUID
    let game: KyroSportsGame
    /// Event-specific matches, best first, plus any channel the viewer chose from search.
    private(set) var alternatives: [KyroSportsStreamMatch]
    /// Accepted event matches beyond the initial list, best first. Offered, never tried automatically.
    let overflow: [KyroSportsStreamMatch]
    /// Listed-broadcaster channels with no event evidence. Offered, never tried automatically.
    let broadcasters: [KyroSportsStreamMatch]
    private(set) var statuses: [String: KyroSportsStreamStatus] = [:]
    var currentChannelID: String?

    init(game: KyroSportsGame, alternatives: [KyroSportsStreamMatch], overflow: [KyroSportsStreamMatch] = [],
         broadcasters: [KyroSportsStreamMatch]) {
        id = UUID()
        self.game = game
        var seen = Set<String>()
        self.alternatives = alternatives.filter { seen.insert($0.channel.id).inserted }
        self.overflow = overflow.prefix(KyroSportsStreamMatcher.maximumOverflowMatches)
            .filter { seen.insert($0.channel.id).inserted }
        self.broadcasters = broadcasters.filter { seen.insert($0.channel.id).inserted }
    }

    func status(of channelID: String) -> KyroSportsStreamStatus { statuses[channelID] ?? .untested }

    mutating func setStatus(_ status: KyroSportsStreamStatus, for channelID: String) {
        statuses[channelID] = status
    }

    /// Adds a channel picked from channel search so it stays listed after a switch.
    mutating func include(_ match: KyroSportsStreamMatch) {
        guard !alternatives.contains(where: { $0.channel.id == match.channel.id }),
              !overflow.contains(where: { $0.channel.id == match.channel.id }),
              !broadcasters.contains(where: { $0.channel.id == match.channel.id }) else { return }
        alternatives.append(match)
    }

    func match(for channelID: String) -> KyroSportsStreamMatch? {
        alternatives.first { $0.channel.id == channelID }
            ?? overflow.first { $0.channel.id == channelID }
            ?? broadcasters.first { $0.channel.id == channelID }
    }
}

/// One-tap Sports Hub playback.
///
/// Tap → candidates → try the best one in the existing Live TV session → show the inline player
/// only once a stream actually plays. A failure or a silent stream moves to the next credible
/// candidate, within a fixed number of attempts and a total time budget. Only one session exists,
/// so at most one stream is ever connecting, and a newer tap or Cancel supersedes the attempt.
@MainActor
@Observable
final class KyroSportsPlaybackCoordinator {
    enum Phase: Equatable {
        case idle
        /// Discovering candidates for a tapped event.
        case searching(KyroGameID)
        /// Trying `attempt` (1-based) of `total` before the player is shown.
        case connecting(channelName: String, attempt: Int, total: Int)
        /// This event owns the session: inline, full screen or in Picture in Picture.
        case presented
        /// Nothing credible played. The event's discovery screen takes over.
        case exhausted(KyroSportsGame, KyroSportsStreamMatchResult)
        /// Playback cannot start for a reason that trying other streams will not fix.
        case unavailable(KyroSportsGame, KyroSportsStreamMatchResult, message: String)
    }

    /// A stream that has not moved by then is treated as not working.
    static let attemptTimeoutSeconds: Double = 12
    /// No tap keeps trying for longer than this, whatever is left to try.
    static let totalBudgetSeconds: Double = 30

    private(set) var phase: Phase = .idle
    private(set) var context: KyroSportsPlaybackContext?

    @ObservationIgnored weak var driver: (any KyroSportsPlaybackDriving)?
    @ObservationIgnored private let scheduler: any LiveTVScheduling
    @ObservationIgnored private var queue: [KyroSportsStreamMatch] = []
    @ObservationIgnored private var attemptNumber = 0
    @ObservationIgnored private var attemptTotal = 0
    @ObservationIgnored private var startedAt: Double = 0
    @ObservationIgnored private var attemptChannelID: String?
    @ObservationIgnored private var attemptTimer: LiveTVTimerHandle?
    @ObservationIgnored private var pendingResult: KyroSportsStreamMatchResult?
    /// Bumps on every start, cancel and attempt, so a late timer or search result is ignored.
    @ObservationIgnored private(set) var generation = 0
    /// Channel the presented player is switching to from Other Streams.
    @ObservationIgnored private var switchingChannelID: String?
    /// The stream the viewer picked on the discovery screen, while it is the latest attempt.
    @ObservationIgnored private var chosenChannelID: String?

    init(scheduler: any LiveTVScheduling) {
        self.scheduler = scheduler
    }

    var isBusy: Bool {
        switch phase {
        case .searching, .connecting: true
        case .idle, .presented, .exhausted, .unavailable: false
        }
    }

    /// Whether `gameID` is the event that owns the playing session.
    func isPlaying(_ gameID: KyroGameID) -> Bool {
        phase == .presented && context?.game.id == gameID
    }

    // MARK: Starting and stopping

    /// Discovery is about to run for `game`. Supersedes any attempt in flight.
    @discardableResult
    func beginSearching(_ game: KyroSportsGame) -> Int {
        cancelAttempt(stopPlayback: isConnecting)
        generation &+= 1
        phase = .searching(game.id)
        return generation
    }

    /// Candidates for the search started as `token`. Tries them in order, or hands over to the
    /// discovery screen when none is strong enough to try.
    func start(_ result: KyroSportsStreamMatchResult, for game: KyroSportsGame, token: Int, allowsAutomaticPlayback: Bool) {
        guard token == generation, case .searching(let id) = phase, id == game.id else { return }
        pendingResult = result
        chosenChannelID = nil
        context = KyroSportsPlaybackContext(game: game, alternatives: result.matches,
                                            overflow: result.overflowMatches,
                                            broadcasters: result.possibleBroadcasters)
        queue = allowsAutomaticPlayback ? Array(result.autoPlayCandidates.prefix(KyroSportsStreamMatcher.maximumAutoPlayCandidates)) : []
        attemptNumber = 0
        attemptTotal = queue.count
        startedAt = scheduler.now
        guard !queue.isEmpty else {
            phase = .exhausted(game, result)
            return
        }
        tryNext()
    }

    /// Playback cannot start now (Live TV's Picture in Picture would not close). The discovery
    /// screen shows the candidates with `message`. When this follows a stream picked on that
    /// screen, the event's context stays, so streams that already failed are still marked.
    func startUnavailable(_ result: KyroSportsStreamMatchResult, for game: KyroSportsGame, token: Int, message: String) {
        guard token == generation, case .searching(let id) = phase, id == game.id else { return }
        pendingResult = result
        if let context, context.game.id == game.id {
            phase = .unavailable(game, annotated(result, with: context), message: message)
        } else {
            context = nil
            phase = .unavailable(game, result, message: message)
        }
    }

    /// The viewer cancelled, the Sports Hub went away, or the app left the foreground before a
    /// stream played. A player already on screen is left alone.
    func cancel() {
        guard isBusy else { return }
        let wasConnecting = isConnecting
        cancelAttempt(stopPlayback: wasConnecting)
        generation &+= 1
        phase = .idle
        context = nil
    }

    /// The discovery screen was shown or closed; nothing is pending any more.
    func acknowledgeFallback() {
        switch phase {
        case .exhausted, .unavailable:
            phase = .idle
            context = nil
            chosenChannelID = nil
        case .idle, .searching, .connecting, .presented:
            break
        }
    }

    /// The viewer picked a stream on the discovery screen. Plays it through the same route,
    /// keeping the event's other streams for Other Streams in the player.
    func playChosen(_ match: KyroSportsStreamMatch, game: KyroSportsGame, result: KyroSportsStreamMatchResult) {
        cancelAttempt(stopPlayback: isConnecting)
        generation &+= 1
        pendingResult = result
        if context?.game.id != game.id {
            context = KyroSportsPlaybackContext(game: game, alternatives: result.matches,
                                                overflow: result.overflowMatches,
                                                broadcasters: result.possibleBroadcasters)
        }
        context?.include(match)
        chosenChannelID = match.channel.id
        queue = [match]
        attemptNumber = 0
        attemptTotal = 1
        startedAt = scheduler.now
        tryNext()
    }

    // MARK: Session events

    /// Re-reads the session. Production wiring calls it on every session state change; tests call
    /// it after changing the fake driver.
    func sessionDidChange() {
        guard let driver else { return }
        if case .connecting = phase, let channelID = attemptChannelID {
            guard driver.sportsPlaybackChannelID == channelID else { return }
            switch driver.sportsPlaybackState {
            case .playing:
                attemptSucceeded(channelID)
            case .failed:
                if driver.sportsPlaybackFailureIsTerminal {
                    stopAsUnavailable("A video is still playing in Picture in Picture. Close it, then try again.")
                } else {
                    attemptFailed(channelID)
                }
            case .stopped:
                // Something else ended the session (sign-out, provider removal).
                cancel()
            case .connecting, .buffering, .paused:
                break
            }
            return
        }
        guard phase == .presented, var context else { return }
        guard let channelID = driver.sportsPlaybackChannelID else { return }
        context.currentChannelID = channelID
        switch driver.sportsPlaybackState {
        case .playing:
            context.setStatus(.verified, for: channelID)
            if switchingChannelID == channelID { switchingChannelID = nil }
        case .failed:
            if context.match(for: channelID) != nil { context.setStatus(.failed, for: channelID) }
            if switchingChannelID == channelID { switchingChannelID = nil }
        case .connecting, .buffering:
            if switchingChannelID == channelID { context.setStatus(.connecting, for: channelID) }
        case .paused, .stopped:
            break
        }
        self.context = context
    }

    /// The player closed (not into Picture in Picture or back into the inline player). The event
    /// context ends with it.
    func playerClosed() {
        guard phase == .presented else { return }
        phase = .idle
        context = nil
        switchingChannelID = nil
    }

    /// Live TV played something outside this event (the Live TV tab, Search). Other Streams must
    /// not follow ordinary playback.
    func ordinaryPlaybackStarted() {
        cancelAttempt(stopPlayback: false)
        generation &+= 1
        phase = .idle
        context = nil
        switchingChannelID = nil
    }

    // MARK: Other Streams

    /// Switches the presented player to another stream for this event. Returns false when the
    /// channel no longer resolves; the player keeps its current stream.
    @discardableResult
    func switchTo(_ match: KyroSportsStreamMatch) -> Bool {
        guard phase == .presented, var context, let driver,
              let channel = driver.sportsResolve(match.channel) else { return false }
        context.include(match)
        guard driver.sportsRetunePresentedPlayer(channel) else { return false }
        switchingChannelID = channel.id
        context.currentChannelID = channel.id
        context.setStatus(.connecting, for: channel.id)
        self.context = context
        sessionDidChange()
        return true
    }

    // MARK: Private

    private var isConnecting: Bool {
        if case .connecting = phase { return true }
        return false
    }

    private func tryNext() {
        guard let driver else { return exhaust() }
        attemptTimer?.cancel()
        attemptTimer = nil
        while !queue.isEmpty {
            let remaining = Self.totalBudgetSeconds - (scheduler.now - startedAt)
            guard remaining > 0.5 else { break }
            let match = queue.removeFirst()
            attemptNumber += 1
            guard let channel = driver.sportsResolve(match.channel) else {
                context?.setStatus(.failed, for: match.channel.id)
                continue
            }
            generation &+= 1
            let token = generation
            attemptChannelID = channel.id
            context?.setStatus(.connecting, for: channel.id)
            context?.currentChannelID = channel.id
            phase = .connecting(channelName: channel.name, attempt: attemptNumber, total: attemptTotal)
            attemptTimer = scheduler.schedule(after: min(Self.attemptTimeoutSeconds, remaining)) { [weak self] in
                self?.attemptTimedOut(token: token, channelID: channel.id)
            }
            driver.sportsStartPlayback(channel)
            // The session may already have answered (a refused stream fails synchronously).
            sessionDidChange()
            return
        }
        exhaust()
    }

    private func attemptSucceeded(_ channelID: String) {
        attemptTimer?.cancel()
        attemptTimer = nil
        attemptChannelID = nil
        queue = []
        context?.setStatus(.verified, for: channelID)
        guard let driver, let match = context?.match(for: channelID),
              let channel = driver.sportsResolve(match.channel) else { return exhaust() }
        phase = .presented
        driver.sportsPresentPlayer(channel)
    }

    private func attemptFailed(_ channelID: String) {
        context?.setStatus(.failed, for: channelID)
        attemptChannelID = nil
        tryNext()
    }

    private func attemptTimedOut(token: Int, channelID: String) {
        guard token == generation, isConnecting, attemptChannelID == channelID else { return }
        attemptTimer = nil
        attemptFailed(channelID)
    }

    private func exhaust() {
        attemptTimer?.cancel()
        attemptTimer = nil
        attemptChannelID = nil
        queue = []
        driver?.sportsStopPlayback()
        guard let context, let result = pendingResult else {
            phase = .idle
            return
        }
        phase = .exhausted(context.game, annotated(result, with: context))
    }

    private func stopAsUnavailable(_ message: String) {
        attemptTimer?.cancel()
        attemptTimer = nil
        attemptChannelID = nil
        queue = []
        driver?.sportsStopPlayback()
        guard let context, let result = pendingResult else {
            phase = .idle
            return
        }
        phase = .unavailable(context.game, annotated(result, with: context), message: message)
    }

    /// The discovery screen lists what was tried, so it does not offer a failed stream as new.
    /// Includes channels picked from channel search, which only the context holds, so a pick
    /// that did not play is reported rather than forgotten when the screen comes back.
    private func annotated(_ result: KyroSportsStreamMatchResult, with context: KyroSportsPlaybackContext) -> KyroSportsStreamMatchResult {
        var result = result
        let channelIDs = (result.matches + result.overflowMatches + result.possibleBroadcasters + context.alternatives).map(\.channel.id)
        result.attemptStatuses = Dictionary(channelIDs.map { ($0, context.status(of: $0)) },
                                            uniquingKeysWith: { first, _ in first })
        result.choiceDidNotPlay = chosenChannelID.map { context.status(of: $0) == .failed } ?? false
        return result
    }

    private func cancelAttempt(stopPlayback: Bool) {
        attemptTimer?.cancel()
        attemptTimer = nil
        attemptChannelID = nil
        queue = []
        if stopPlayback { driver?.sportsStopPlayback() }
    }
}

/// Whether discovery may try streams by itself. Build 39: only an event ESPN reports in progress.
/// An upcoming game's channel shows something else now, and a finished one is over, so neither
/// starts playback; the Sports Hub shows them as scores and schedules only.
enum KyroSportsPlaybackPolicy {
    static func allowsAutomaticPlayback(_ game: KyroSportsGame, now: Date) -> Bool {
        KyroSportsPlaybackEligibility.isInProgress(game)
    }
}
