import Foundation
import Observation

/// Which Live TV screen presents the full-screen player. The channel list and the guide sit in one
/// navigation stack, and each presents its own cover, so exactly one of them may show it.
enum LiveTVPresenter: Hashable, Sendable {
    case list
    case guide
    /// Kyro's unified navigation: the app shell, over whatever the user has open, when no Live TV
    /// screen can come forward without closing it. Never counted as a visible screen.
    case shell
}

/// One presenter's full-screen cover. Its identity is the presenter, not the channel: a retune
/// inside the player (its channel picker, Sports Hub's Other Streams) changes the channel but must
/// keep the same cover. Keying a cover by channel makes SwiftUI dismiss it and present a new one,
/// and the dismissed player's disappearance stops the stream that was just retuned.
struct LiveTVPlayerCoverItem: Identifiable, Equatable {
    let presenter: LiveTVPresenter
    let channel: LiveTVChannel
    var id: LiveTVPresenter { presenter }
}

/// What a channel selection means right now.
enum LiveTVSelection: Equatable, Sendable {
    /// The full-screen player opens for the channel.
    case present
    /// Picture in Picture keeps playing; tune the live session to the channel.
    case playInPlace
    /// Picture in Picture is being closed first; the full-screen player opens when it has closed.
    case exitingPictureInPicture
    /// A restore is in flight; the selection is not acted on.
    case ignored
}

/// What ending Picture in Picture should do to playback.
enum LiveTVEngagementOutcome: Equatable, Sendable {
    /// Nothing is left to watch: stop the session.
    case stopPlayback
    /// Playback continues in the full-screen player that was just presented.
    case continuePlayback
}

/// The single source of truth for Live TV's full-screen player and its Picture in Picture hand-offs,
/// shared by the channel list and the guide.
///
/// It owns no playback. The host wires `stopPlayback`, `stopPictureInPicture` and
/// `navigateToLiveTV` to the Live TV session, the Picture in Picture coordinator and the router, so
/// the rules here run with no AVKit and no engine.
@MainActor
@Observable
final class LiveTVPresentation {
    enum Phase: Equatable {
        /// No player on screen and none in Picture in Picture.
        case idle
        /// The full-screen player is showing, from the named screen.
        case presented(LiveTVChannel, LiveTVPresenter)
        /// The player's cover is closed and Picture in Picture owns the stream.
        case pictureInPicture(LiveTVChannel)
        /// Picture in Picture asked for the player back and its cover has not appeared yet.
        /// `nil` waits for a Live TV screen to appear.
        case restoring(LiveTVChannel, LiveTVPresenter?)
        /// Sports Hub's inline player shows the stream. No cover is up; expanding presents the
        /// full-screen player over the shell, and collapsing it comes back here.
        case inline(LiveTVChannel)
    }

    static let restoreTimeoutSeconds: Double = 4

    /// The phase without its channel, for the lifecycle journal.
    static func journalName(_ phase: Phase) -> String {
        switch phase {
        case .idle: "idle"
        case .presented: "presented"
        case .pictureInPicture: "pip"
        case .restoring: "restoring"
        case .inline: "inline"
        }
    }

    private(set) var phase: Phase = .idle {
        didSet {
            KyroLifecycleJournal.record("livetv", "presentation_phase", "\(Self.journalName(oldValue))->\(Self.journalName(phase))")
            switch phase {
            case .presented:
                pictureInPictureOrigin = nil
            case .restoring:
                // A restore may be bringing the full-screen player back; `restoreRequested`
                // decides, and the expansion it sets must survive into `.presented`.
                break
            case .pictureInPicture:
                isWatchExpanded = false
                isWatchExpandedByRotation = false
                isInlineExpandedByRotation = false
            case .idle, .inline:
                // Expansion belongs to one presented watch screen. A closed cover or a stop
                // leaves it, so the next watch screen opens in portrait.
                isWatchExpanded = false
                isWatchExpandedByRotation = false
                if case .idle = phase { isInlineExpandedByRotation = false }
                pictureInPictureOrigin = nil
            }
        }
    }

    /// Where the stream was showing when Picture in Picture took it from a player's own control.
    /// A restore returns there: the inline player, the portrait watch screen, or full screen.
    enum PictureInPictureOrigin: Equatable {
        /// A cover from `presenter`. `expanded` is the watch screen's full-screen player.
        case cover(LiveTVPresenter, expanded: Bool)
        /// Sports Hub's inline player.
        case inline
    }

    @ObservationIgnored private(set) var pictureInPictureOrigin: PictureInPictureOrigin?

    /// Counts player presentations: a selection that opens a cover, an inline expansion, a
    /// restore, a return from Picture in Picture. A player view records the value it appeared
    /// under, so when it later disappears it can tell whether it is still the presentation that
    /// owns the stream, or an earlier one whose dismissal finished after a newer one began.
    @ObservationIgnored private(set) var presentationEpoch = 0

    /// Whether a player view that appeared under `epoch` should end the stream as it disappears.
    /// Only the current presentation may, and only when nothing else (Picture in Picture, the
    /// inline player) holds the stream. An explicit close stops the session itself.
    ///
    /// Build 68.1: `isPictureInPictureEngaged` is whether the system window is starting or showing
    /// this session. Automatic Picture in Picture keeps the phase `.presented` (the cover stays, so
    /// coming back lands on it), so the phase alone said "stop" while the window was on screen.
    /// On the iPhone (Build 68 journal, 2026-11-13) the watch screen was rebuilt about 0.2 s after
    /// the app entered the background: its disappearance stopped the session, the rebuilt screen
    /// replayed the channel, the new video layer closed the window and playback ended. The window
    /// owns the stream until it closes (`engagementEnded`) or the app returns and restores into
    /// the cover, so a disappearing view never ends it.
    func shouldStopWhenPlayerDisappears(presentedAt epoch: Int, isPictureInPictureEngaged: Bool = false) -> Bool {
        guard !isPictureInPictureEngaged else { return false }
        return epoch == presentationEpoch && LiveTVPictureInPicturePolicy.shouldStopWhenPlayerDisappears(phase)
    }

    /// The portrait watch screen (iPhone, opened from the guide) has handed its stream to the
    /// full-screen player above it. The watch screen's own surface is unmounted meanwhile: the
    /// engine has one layer, and it follows the surface bound last.
    private(set) var isWatchExpanded = false
    /// A device-driven expansion returns to portrait when UIKit rotates back. A manual expansion
    /// is different: it must stay full screen even with system Portrait Orientation Lock enabled.
    private(set) var isWatchExpandedByRotation = false
    private(set) var isInlineExpandedByRotation = false

    /// Ends the Live TV session: stop playback, release Picture in Picture.
    @ObservationIgnored var stopPlayback: (() -> Void)?
    /// Asks the Picture in Picture coordinator to close its window.
    @ObservationIgnored var stopPictureInPicture: (() -> Void)?
    /// Brings a Live TV screen on screen when none is.
    @ObservationIgnored var navigateToLiveTV: (() -> Void)?

    @ObservationIgnored private let scheduler: any LiveTVScheduling
    @ObservationIgnored private var visible: Set<LiveTVPresenter> = []
    @ObservationIgnored private var lastPresenter: LiveTVPresenter = .list
    @ObservationIgnored private var pendingRestore: ((Bool) -> Void)?
    @ObservationIgnored private var restoreTimer: LiveTVTimerHandle?
    @ObservationIgnored private var restoreRequestID = UUID()
    /// Where the full-screen player opens if Picture in Picture ends without the user asking for it.
    @ObservationIgnored private var returnChannel: LiveTVChannel?
    @ObservationIgnored private var inPlaceTargetID: String?
    /// The full-screen player was expanded from the inline player, so closing it can return there.
    /// Only `showInline` and `expandInline` set it; every other selection clears it.
    @ObservationIgnored private var expandedFromInline = false
    /// Whether the screen that hosts the inline player (Sports Hub) is on screen.
    private(set) var isInlineHostVisible = false

    init(scheduler: any LiveTVScheduling) {
        self.scheduler = scheduler
    }

    /// The channel whose cover `presenter` should show, nil when it should show none.
    func channel(for presenter: LiveTVPresenter) -> LiveTVChannel? {
        switch phase {
        case .presented(let channel, let owner) where owner == presenter: channel
        case .restoring(let channel, let owner) where owner == presenter: channel
        default: nil
        }
    }

    /// The cover `presenter` should show, keyed by presenter so a retune keeps it up.
    func coverItem(for presenter: LiveTVPresenter) -> LiveTVPlayerCoverItem? {
        channel(for: presenter).map { LiveTVPlayerCoverItem(presenter: presenter, channel: $0) }
    }

    /// The channel Live TV is playing, wherever it is shown.
    var activeChannel: LiveTVChannel? {
        switch phase {
        case .idle: nil
        case .presented(let channel, _), .pictureInPicture(let channel), .restoring(let channel, _),
             .inline(let channel): channel
        }
    }

    var isInline: Bool {
        if case .inline = phase { return true }
        return false
    }

    /// The full-screen player can close back into the inline player instead of ending the stream.
    var canCollapseToInline: Bool {
        guard expandedFromInline, isInlineHostVisible, case .presented(_, .shell) = phase else { return false }
        return true
    }

    /// The full-screen player over the shell came from Sports Hub's inline player, which is still
    /// on screen: it opens in landscape, including while a Picture in Picture restore brings it back.
    var isFullScreenFromInline: Bool {
        guard expandedFromInline, isInlineHostVisible else { return false }
        switch phase {
        case .presented(_, .shell), .restoring(_, .shell): return true
        case .idle, .presented, .pictureInPicture, .restoring, .inline: return false
        }
    }

    var isPictureInPictureOwningPlayback: Bool {
        if case .pictureInPicture = phase { return true }
        return false
    }

    // MARK: Selecting and closing

    /// A channel was chosen in the list or the guide.
    func select(_ channel: LiveTVChannel, from presenter: LiveTVPresenter) -> LiveTVSelection {
        expandedFromInline = false
        isInlineExpandedByRotation = false
        isWatchExpanded = false
        isWatchExpandedByRotation = false
        switch phase {
        case .idle, .presented, .inline:
            lastPresenter = presenter
            presentationEpoch += 1
            phase = .presented(channel, presenter)
            return .present
        case .restoring:
            return .ignored
        case .pictureInPicture(let current):
            lastPresenter = presenter
            // The window now returns to the screen that made this selection.
            pictureInPictureOrigin = .cover(presenter, expanded: false)
            if channel.id == current.id {
                returnChannel = channel
                inPlaceTargetID = nil
                stopPictureInPicture?()
                return .exitingPictureInPicture
            }
            returnChannel = channel
            inPlaceTargetID = nil
            // The window survives a reload on the same route class; crossing between native HLS and
            // the software renderer makes the coordinator close it, so leave it deliberately and show
            // the player instead.
            if LiveTVStreamRoute(url: channel.streamURL) == LiveTVStreamRoute(url: current.streamURL) {
                inPlaceTargetID = channel.id
                phase = .pictureInPicture(channel)
                return .playInPlace
            }
            phase = .pictureInPicture(channel)
            stopPictureInPicture?()
            return .exitingPictureInPicture
        }
    }

    /// SwiftUI closed the cover for `presenter`: the user left the player.
    func coverDismissed(from presenter: LiveTVPresenter) {
        guard case .presented(_, let owner) = phase, owner == presenter else { return }
        phase = .idle
    }

    /// The player switched channel through its own picker.
    func playerChannelChanged(to channel: LiveTVChannel) {
        switch phase {
        case .presented(_, let presenter): phase = .presented(channel, presenter)
        case .pictureInPicture: phase = .pictureInPicture(channel)
        case .restoring(_, let presenter): phase = .restoring(channel, presenter)
        case .inline: phase = .inline(channel)
        case .idle: break
        }
    }

    // MARK: Portrait watch screen

    /// The watch screen's Full Screen control: the same stream moves to the full-screen player.
    /// The phase stays `.presented`, so nothing retunes and the cover underneath stays up.
    @discardableResult
    func expandWatch(byRotation: Bool = false) -> Bool {
        guard case .presented = phase, !isWatchExpanded else { return false }
        isWatchExpanded = true
        isWatchExpandedByRotation = byRotation
        return true
    }

    /// The full-screen player's collapse control: the stream returns to the watch screen.
    func collapseWatch() {
        isWatchExpanded = false
        isWatchExpandedByRotation = false
    }

    // MARK: Inline playback

    /// Sports Hub verified a stream: show it in the inline player. Only from idle (Sports Hub
    /// closes Live TV's own Picture in Picture before it tunes) or to retune the inline player.
    @discardableResult
    func showInline(_ channel: LiveTVChannel) -> Bool {
        switch phase {
        case .idle, .inline:
            lastPresenter = .shell
            expandedFromInline = true
            isInlineExpandedByRotation = false
            phase = .inline(channel)
            return true
        case .presented, .pictureInPicture, .restoring:
            return false
        }
    }

    /// The inline player's expand control: the same stream opens full screen over the shell.
    func expandInline(byRotation: Bool = false) {
        guard case .inline(let channel) = phase else { return }
        lastPresenter = .shell
        expandedFromInline = true
        isInlineExpandedByRotation = byRotation
        presentationEpoch += 1
        phase = .presented(channel, .shell)
    }

    /// The full-screen player's collapse control. The cover closes and the stream plays on inline.
    @discardableResult
    func collapseToInline() -> Bool {
        guard canCollapseToInline, case .presented(let channel, _) = phase else { return false }
        isInlineExpandedByRotation = false
        phase = .inline(channel)
        return true
    }

    /// The inline player's close control: the stream ends.
    func closeInline() {
        guard isInline else { return }
        phase = .idle
        stopPlayback?()
    }

    /// Sports Hub is retuning the session for another event. The inline player leaves the screen;
    /// the caller stops or retunes the session itself.
    func releaseInline() {
        guard isInline else { return }
        phase = .idle
    }

    func inlineHostAppeared() {
        isInlineHostVisible = true
    }

    /// Sports Hub left the screen. An inline stream has nowhere left to show, so it ends rather
    /// than play on headless. A full-screen cover over the hub can report it as disappearing; the
    /// hub is still there.
    func inlineHostDisappeared() {
        switch phase {
        case .presented, .restoring:
            return
        case .inline:
            isInlineHostVisible = false
            phase = .idle
            stopPlayback?()
        case .idle, .pictureInPicture:
            isInlineHostVisible = false
        }
    }

    // MARK: Screens appearing

    func surfaceAppeared(_ presenter: LiveTVPresenter) {
        visible.insert(presenter)
        if case .restoring(let channel, nil) = phase {
            lastPresenter = presenter
            phase = .restoring(channel, presenter)
        }
    }

    func surfaceDisappeared(_ presenter: LiveTVPresenter) {
        // A cover over the screen can report it as disappearing; it is still there.
        switch phase {
        case .presented, .restoring: return
        case .idle, .pictureInPicture, .inline: visible.remove(presenter)
        }
    }

    /// Kyro's unified navigation: no Live TV screen can come forward without closing what the user
    /// has open (a pushed Media Server screen), so the player waiting for one opens over it instead.
    func presentOverCurrentScreen() {
        switch phase {
        case .restoring(let channel, nil):
            lastPresenter = .shell
            phase = .restoring(channel, .shell)
        case .presented(let channel, let presenter) where !visible.contains(presenter):
            lastPresenter = .shell
            phase = .presented(channel, .shell)
        case .idle, .presented, .pictureInPicture, .restoring, .inline:
            break
        }
    }

    // MARK: Picture in Picture

    /// Picture in Picture finished starting from the player's own button: the cover (or the inline
    /// player) gives the stream to the window, where it plays on.
    func pictureInPictureStartedFromControl() {
        let channel: LiveTVChannel, presenter: LiveTVPresenter, origin: PictureInPictureOrigin
        switch phase {
        case .presented(let current, let owner):
            (channel, presenter) = (current, owner)
            origin = .cover(owner, expanded: isWatchExpanded)
        case .inline(let current):
            (channel, presenter) = (current, .shell)
            origin = .inline
        case .idle, .pictureInPicture, .restoring: return
        }
        lastPresenter = presenter
        returnChannel = nil
        inPlaceTargetID = nil
        phase = .pictureInPicture(channel)
        pictureInPictureOrigin = origin
    }

    /// The Live TV session failed while Picture in Picture owns it: close the window and show the
    /// player, where the failure and Retry are.
    func playbackFailedInPictureInPicture() {
        guard case .pictureInPicture(let channel) = phase else { return }
        returnChannel = channel
        inPlaceTargetID = nil
        stopPictureInPicture?()
    }

    /// A tuning change that Picture in Picture survived, so a later close is the user's own.
    func pictureInPictureSettled(activeChannelID: String?) {
        guard case .pictureInPicture = phase,
              let target = inPlaceTargetID, target == activeChannelID else { return }
        inPlaceTargetID = nil
        returnChannel = nil
    }

    /// AVKit asks for the full-screen player back. `completion(true)` must mean it is on screen.
    func restoreRequested(completion: @escaping (Bool) -> Void) {
        switch phase {
        case .presented, .inline:
            // Automatic Picture in Picture left the cover (or the inline player) up; it is
            // already the interface.
            completion(true)
        case .pictureInPicture(let channel):
            let origin = pictureInPictureOrigin
            if origin == .inline, isInlineHostVisible {
                // The inline player takes the stream back without a cover, but AVKit must not be
                // told restoration succeeded until its Aether surface has mounted.
                phase = .inline(channel)
                beginRestore(completion)
                return
            }
            let target = visiblePresenter()
            presentationEpoch += 1
            phase = .restoring(channel, target)
            // Picture in Picture started from the watch screen's full-screen player returns to it.
            if case .cover(let presenter, expanded: true) = origin, presenter == target {
                isWatchExpanded = true
            }
            beginRestore(completion)
            if target == nil { navigateToLiveTV?() }
        case .idle, .restoring:
            completion(false)
        }
    }

    /// Whether a restore requested now brings back a full-screen player that was expanded from an
    /// inline player: the watch screen's, or Sports Hub's over the shell. That player opens in
    /// landscape, so its cover cuts in instead of sliding up: the rotation is the only motion, and
    /// the watch screen underneath, which shows no picture while expanded, is not seen first
    /// (Build 50 recording, 3:17–3:19). Matches what `restoreRequested` then does.
    var restoreReturnsToExpandedPlayer: Bool {
        guard case .pictureInPicture = phase else { return false }
        if pictureInPictureOrigin == .inline, isInlineHostVisible { return false }
        let target = visiblePresenter()
        if case .cover(let presenter, expanded: true) = pictureInPictureOrigin, presenter == target { return true }
        return target == .shell && expandedFromInline && isInlineHostVisible
    }

    /// The portrait watch screen is on screen. It answers a restore only when it is the player
    /// being restored. Restoring its expanded full-screen player, the watch screen appears first
    /// with no surface, and answering then would hand the window back before the player that
    /// takes the stream exists; that player answers when it appears.
    func watchScreenDidAppear(_ channel: LiveTVChannel) {
        guard !isWatchExpanded else { return }
        playerDidAppear(channel)
    }

    /// Sports Hub's inline Aether surface is mounted after an inline PiP restore. Only now is it
    /// safe to let AVKit remove the system window and hand the video layer back.
    func inlinePlayerDidAppear(_ channel: LiveTVChannel) {
        guard pendingRestore != nil, case .inline(let current) = phase, current.id == channel.id else { return }
        answerRestore(true)
    }

    /// The full-screen player for `channel` is on screen.
    func playerDidAppear(_ channel: LiveTVChannel) {
        guard case .restoring(let current, let presenter) = phase, current.id == channel.id else { return }
        phase = .presented(current, presenter ?? lastPresenter)
        returnChannel = nil
        inPlaceTargetID = nil
        answerRestore(true)
    }

    /// The cover never mounted. AVKit has taken the window down regardless, so the stream must not
    /// play on headless.
    func restoreTimedOut() {
        guard pendingRestore != nil else { return }
        answerRestore(false)
        phase = .idle
        returnChannel = nil
        stopPlayback?()
    }

    /// Picture in Picture ended: the user closed it, a restore completed, or a route change or
    /// failure closed it on purpose.
    ///
    /// - Parameter isStillBound: false when the coordinator was torn down (sign-out, profile or
    ///   server change), which always ends playback.
    func engagementEnded(isStillBound: Bool = true) -> LiveTVEngagementOutcome {
        guard phase != .idle else { return .stopPlayback }
        defer { returnChannel = nil; inPlaceTargetID = nil }
        restoreRequestID = UUID()
        restoreTimer?.cancel()
        restoreTimer = nil
        pendingRestore = nil
        if isStillBound, let channel = returnChannel {
            if pictureInPictureOrigin == .inline, isInlineHostVisible {
                // A failed stream closes the window into the inline player, where Retry is.
                phase = .inline(channel)
                return .continuePlayback
            }
            presentationEpoch += 1
            let presenter = visiblePresenter() ?? .list
            lastPresenter = presenter
            phase = .presented(channel, presenter)
            // With no Live TV screen up, the list opens and shows the player. The shell needs no
            // Live TV screen: it presents over whatever is open (Sports Hub, Search).
            if presenter != .shell, visible.isEmpty { navigateToLiveTV?() }
            return .continuePlayback
        }
        phase = .idle
        stopPlayback?()
        return .stopPlayback
    }

    /// Invalidate presentation before stopping the owner-keyed engine/coordinator.
    func providerRemoved(_ id: UUID, activeChannelID: String?) {
        guard (activeChannelID ?? activeChannel?.id)?.hasPrefix("\(id.uuidString):") == true else { return }
        phase = .idle
        returnChannel = nil
        inPlaceTargetID = nil
        answerRestore(false)
        stopPlayback?()
    }

    // MARK: Private

    /// The Live TV screen that can show a cover now: the one that presented last, else any.
    /// A player the shell presented comes back over the shell, wherever the user is, instead of
    /// switching to the Live TV tab.
    private func visiblePresenter() -> LiveTVPresenter? {
        if lastPresenter == .shell { return .shell }
        if visible.contains(lastPresenter) { return lastPresenter }
        return visible.contains(.list) ? .list : visible.first
    }

    private func answerRestore(_ didRestore: Bool) {
        restoreRequestID = UUID()
        restoreTimer?.cancel()
        restoreTimer = nil
        let completion = pendingRestore
        pendingRestore = nil
        completion?(didRestore)
    }

    private func beginRestore(_ completion: @escaping (Bool) -> Void) {
        pendingRestore = completion
        restoreTimer?.cancel()
        restoreRequestID = UUID()
        let requestID = restoreRequestID
        restoreTimer = scheduler.schedule(after: Self.restoreTimeoutSeconds) { [weak self] in
            guard let self, self.restoreRequestID == requestID else { return }
            self.restoreTimedOut()
        }
    }
}

/// The ownership rules that keep Live TV's Picture in Picture from colliding with Silo's own.
enum LiveTVPictureInPicturePolicy {
    /// Only one video engine plays at a time, so another player's Picture in Picture blocks Live TV
    /// playback. Live TV's own window must not: it is the stream being tuned.
    static func isOtherVideoActive(isEngaged: Bool, liveTVOwnsEngagement: Bool) -> Bool {
        isEngaged && !liveTVOwnsEngagement
    }

    /// Whether the player's disappearance ends the stream. Closing the cover for Picture in Picture
    /// leaves the stream playing in the window.
    /// A cover collapsed into the inline player leaves it playing there.
    static func shouldStopWhenPlayerDisappears(_ phase: LiveTVPresentation.Phase) -> Bool {
        switch phase {
        case .pictureInPicture, .inline: false
        case .idle, .presented, .restoring: true
        }
    }
}

/// Watches the Live TV session while Picture in Picture owns it: a failed session closes the window
/// and returns to the player, where the error and Retry are; a stream that is playing again makes a
/// later close the user's own.
@MainActor
final class LiveTVPictureInPictureMonitor {
    private let session: LiveTVPlayerSession
    private let presentation: LiveTVPresentation
    private let bind: () -> Void

    init(session: LiveTVPlayerSession, presentation: LiveTVPresentation, bind: @escaping () -> Void) {
        self.session = session
        self.presentation = presentation
        self.bind = bind
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = session.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.handle()
                self?.observe()
            }
        }
    }

    private func handle() {
        guard session.activeChannelID != nil else { return }
        if session.state == .playing { bind() }
        guard presentation.isPictureInPictureOwningPlayback else { return }
        switch session.state {
        case .failed: presentation.playbackFailedInPictureInPicture()
        case .playing: presentation.pictureInPictureSettled(activeChannelID: session.activeChannelID)
        case .stopped, .connecting, .buffering, .paused: break
        }
    }
}
