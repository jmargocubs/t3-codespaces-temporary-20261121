#if os(iOS)
import AetherEngine
import SwiftUI

/// Build 46: the tapped live event plays in a 16:9 player above the Sports Hub feed.
///
/// It hosts the one Live TV session's engine surface. Expand, Picture in Picture and Other
/// Streams go through the same session and presentation as the full-screen player, so no second
/// player, engine or audio claim exists.
///
/// The video carries only Stop, Full Screen and the transport control, the same corner layout as
/// the Live TV watch screen. The matchup, the stream and the less frequent actions (Picture in
/// Picture, Other Streams) sit in a strip beneath it.
struct KyroSportsInlinePlayer: View {
    let service: LiveTVService
    /// The Sports Hub's games, to name the event while it is still being searched.
    let games: [KyroSportsGame]
    /// The playing event with its latest score and status, when the hub has one.
    var pinnedGame: KyroSportsGame? = nil
    @Binding var isShowingOtherStreams: Bool

    @State private var controls = LiveTVControlsVisibility(scheduler: LiveTVTaskScheduler())
    @State private var pictureInPicture = PictureInPictureCoordinator.shared
    @State private var orientationCoordinator = PlayerOrientationCoordinator.shared
    /// Build 70: the strip's bottom edge, for Other Streams. Not observed, so measuring it (the
    /// entrance transition moves it every frame) never re-renders the player.
    @State private var stripEdge = KyroSportsInlineStripEdge()
    @Environment(\.scenePhase) private var scenePhase

    /// Other Streams opens just below the strip, so the video stays in view above it.
    private var otherStreamsOpeningHeight: Double? {
        let windowHeight = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.bounds.height }
            .first ?? 0
        return KyroSportsOtherStreamsSheetLayout.belowPlayerHeight(windowHeight: Double(windowHeight),
                                                                   playerBottom: Double(stripEdge.bottom))
    }

    private var playback: KyroSportsPlaybackCoordinator { service.sportsPlayback }
    private var session: LiveTVPlayerSession { service.playerSession }
    private var mode: KyroSportsInlinePlayerMode {
        .make(sports: playback.phase, presentation: service.presentation.phase)
    }
    private var info: KyroSportsInlineInfo? {
        KyroSportsInlineInfo(mode: mode, context: playback.context, current: pinnedGame)
    }
    private var strip: KyroSportsInlineStrip? {
        .make(mode: mode, phase: playback.phase, context: playback.context, current: pinnedGame, games: games)
    }

    var body: some View {
        if mode.isVisible {
            VStack(spacing: 0) {
                frame
                if let strip { infoStrip(strip) }
            }
            .padding(.horizontal, SiloTheme.padding)
            .padding(.bottom, 4)
            .frame(maxWidth: 720 + 2 * SiloTheme.padding)
            .frame(maxWidth: .infinity)
            .background(Color.siloPageCanvas)
            .transition(.move(edge: .top).combined(with: .opacity))
            // Build 70: where the strip ends, read when Other Streams opens.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .global).maxY.rounded()
            } action: { [stripEdge] bottom in
                stripEdge.bottom = bottom
            }
            .sheet(isPresented: $isShowingOtherStreams) {
                KyroSportsOtherStreamsSheet(coordinator: playback, openingHeight: otherStreamsOpeningHeight,
                                            select: { match in
                    guard playback.switchTo(match) else { return }
                    isShowingOtherStreams = false
                }, dismiss: { isShowingOtherStreams = false })
            }
        }
    }

    private var frame: some View {
        ZStack {
            Color.black
            switch mode {
            case .playing(let channel):
                video(channel)
            case .finding:
                findingOverlay
            case .elsewhere(_, let isPictureInPicture):
                elsewhereOverlay(isPictureInPicture: isPictureInPicture)
            case .hidden:
                EmptyView()
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(KyroTheme.glassRim, lineWidth: 1)
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kyroSportsInlinePlayer")
        .onChange(of: session.state) { syncControls() }
        .onChange(of: isShowingOtherStreams) { syncControls() }
        .onAppear {
            orientationCoordinator.watchScreenDidAppear()
            syncControls()
        }
        .onChange(of: orientationCoordinator.observedOrientation) { _, orientation in
            if orientation == .landscape { expandForDeviceRotation() }
        }
        .onChange(of: mode) { _, mode in
            // Coming back from full screen or the window: Expand cancelled the controls, so
            // re-read the session before showing them, or they would never hide again.
            if case .playing = mode {
                orientationCoordinator.watchScreenDidAppear()
                syncControls()
                controls.interact()
            } else {
                isShowingOtherStreams = false
                if !service.presentation.isFullScreenFromInline {
                    orientationCoordinator.watchScreenDidDisappear()
                }
            }
        }
        // Picture in Picture started from the inline button: the window takes the stream and the
        // frame shows where it went.
        .onChange(of: pictureInPicture.controlStartToken) { _, _ in
            guard service.presentation.isInline, pictureInPicture.ownsEngagedSession(session) else { return }
            service.presentation.pictureInPictureStartedFromControl()
        }
        // Automatic Picture in Picture on leaving the app keeps the inline player; coming back
        // lands on it, so end the window into it.
        .onChange(of: scenePhase) { _, phase in
            KyroLifecycleJournal.record("sports", "inline_scene_phase", "\(phase) inline=\(service.presentation.isInline)")
            guard phase == .active, service.presentation.isInline else { return }
            pictureInPicture.stopForReturnToPresentedPlayer(owner: session)
        }
        .onDisappear {
            controls.cancel()
            if !service.presentation.isFullScreenFromInline {
                orientationCoordinator.watchScreenDidDisappear()
            }
        }
    }

    // MARK: Playing

    @ViewBuilder
    private func video(_ channel: LiveTVChannel) -> some View {
        if let aether = (session.engine as? AetherLiveTVEngine)?.engine {
            // Mounted only while the stream is inline. The full-screen cover binds its own
            // surface; the engine moves its one layer to whichever surface is bound last.
            AetherPlayerSurface(engine: aether)
                .task {
                    KyroLifecycleJournal.record("sports", "inline_surface", "mounted")
                    service.attachPictureInPicture()
                    service.presentation.inlinePlayerDidAppear(channel)
                }
                .onDisappear { KyroLifecycleJournal.record("sports", "inline_surface", "unmounted") }
        }
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { controls.toggle() }
        LiveTVInlineStatusOverlay(state: session.state, errorMessage: session.errorMessage) {
            if session.canRetry {
                Button("Retry") {
                    controls.interact()
                    session.retry()
                }
                .buttonStyle(.borderedProminent)
                .tint(LiveTVAccent.primary)
            }
            if info?.hasOtherStreams == true {
                Button("Other Streams") { isShowingOtherStreams = true }
                    .buttonStyle(.bordered)
            }
        }
        controlsOverlay
            .opacity(controls.isVisible ? 1 : 0)
            .allowsHitTesting(controls.isVisible)
            .animation(.easeInOut(duration: 0.2), value: controls.isVisible)
    }

    private var controlsOverlay: some View {
        LiveTVInlineControlsOverlay(transport: LiveTVTransportControl(state: session.state)) {
            controls.interact()
            session.togglePlayback()
        } leading: {
            LiveTVInlineIconButton(symbol: "xmark", label: "Stop", identifier: "kyroSportsInlineStop") {
                controls.cancel()
                service.stopSportsInlinePlayback()
            }
        } trailing: {
            if let aether = (session.engine as? AetherLiveTVEngine)?.engine {
                LiveTVBasicControlsButton(engine: aether) { presenting in
                    controls.update(state: session.state, isOverlayPresented: presenting)
                }
            }
            LiveTVInlineIconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Full screen",
                                   identifier: "kyroSportsInlineExpand") {
                controls.cancel()
                LiveTVCoverTransition.immediate { service.presentation.expandInline() }
            }
        }
    }

    private func expandForDeviceRotation() {
        guard case .playing = mode, service.presentation.isInline,
              orientationCoordinator.observedOrientation == .landscape,
              !orientationCoordinator.suppressNaturalExpansionUntilUpright else { return }
        controls.cancel()
        LiveTVCoverTransition.immediate { service.presentation.expandInline(byRotation: true) }
    }

    // MARK: Information strip

    /// Build 67: a scoreboard line (logos, teams, the score in the strip's largest type) over the
    /// clock and stream, with the actions beside both lines instead of under them.
    ///
    /// Build 71.1: two tiers instead of one crowded meta line. The scoreboard leads; the second line
    /// gives the live status and clock in primary type and the stream as a quieter trailing label
    /// that truncates first. The league is shown only when there is no scoreboard (logos already
    /// identify the event), so long college or channel names no longer push the clock off screen.
    /// The strip's height and the actions are unchanged.
    private func infoStrip(_ strip: KyroSportsInlineStrip) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                scoreLine(strip)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(strip.accessibilityMatchup)
                metaLine(strip)
                    .accessibilityIdentifier("kyroSportsInlineStream")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if strip.showsPlaybackActions {
                if pictureInPicture.isSupported, pictureInPicture.hasSource {
                    stripIconButton("pip.enter", label: "Picture in Picture",
                                    identifier: "kyroSportsInlinePictureInPicture") {
                        controls.interact()
                        pictureInPicture.toggle()
                    }
                    .disabled(!pictureInPicture.isPossible)
                }
                if strip.hasOtherStreams {
                    LiveTVInlinePillButton(title: "Streams", symbol: "sportscourt",
                                           identifier: "kyroSportsInlineOtherStreams") {
                        controls.interact()
                        isShowingOtherStreams = true
                    }
                    .accessibilityLabel("Other streams")
                }
            }
        }
        .frame(minHeight: 48)
        .padding(.top, 6)
        .padding(.horizontal, 2)
    }

    /// Logos, names and score for team sports: nicknames, then abbreviations, then abbreviations
    /// without logos (large Dynamic Type); the matchup for tennis and unscored events.
    @ViewBuilder
    private func scoreLine(_ strip: KyroSportsInlineStrip) -> some View {
        if let awayScore = strip.awayScore, let homeScore = strip.homeScore {
            ViewThatFits(in: .horizontal) {
                scoreboard(strip, away: strip.game.away.team.nickname, awayScore: awayScore,
                           home: strip.game.home.team.nickname, homeScore: homeScore, showsLogos: true)
                scoreboard(strip, away: strip.game.away.team.abbreviation, awayScore: awayScore,
                           home: strip.game.home.team.abbreviation, homeScore: homeScore, showsLogos: true)
                scoreboard(strip, away: strip.game.away.team.abbreviation, awayScore: awayScore,
                           home: strip.game.home.team.abbreviation, homeScore: homeScore, showsLogos: false)
            }
        } else {
            Text(strip.game.inlineMatchupTitle)
                .font(.headline)
                .foregroundStyle(KyroTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func scoreboard(_ strip: KyroSportsInlineStrip, away: String, awayScore: String,
                            home: String, homeScore: String, showsLogos: Bool) -> some View {
        HStack(spacing: 6) {
            if showsLogos { KyroSportsTeamLogo(team: strip.game.away.team, size: 20) }
            Text(away).font(.subheadline.weight(.semibold)).foregroundStyle(KyroTheme.silver)
            Text(awayScore).font(.title3.weight(.bold)).monospacedDigit()
            Text("–").font(.subheadline.weight(.semibold)).foregroundStyle(KyroTheme.textSecondary)
            Text(homeScore).font(.title3.weight(.bold)).monospacedDigit()
            Text(home).font(.subheadline.weight(.semibold)).foregroundStyle(KyroTheme.silver)
            if showsLogos { KyroSportsTeamLogo(team: strip.game.home.team, size: 20) }
        }
        .foregroundStyle(KyroTheme.textPrimary)
        .lineLimit(1)
        .fixedSize()
    }

    /// Status tier (live dot, clock) never truncates; the stream tier is smaller, dimmer and gives
    /// way first.
    private func metaLine(_ strip: KyroSportsInlineStrip) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                if strip.isLive {
                    Circle().fill(KyroTheme.live).frame(width: 6, height: 6)
                }
                Text(strip.statusLine)
                    .monospacedDigit()
                    .foregroundStyle(strip.isLive ? KyroTheme.textPrimary : KyroTheme.textSecondary)
                if strip.awayScore == nil {
                    Text(strip.league).foregroundStyle(KyroTheme.accentInk)
                }
            }
            .font(.caption.weight(.semibold))
            .fixedSize()
            .accessibilityElement(children: .combine)
            streamLabel(strip)
                .layoutPriority(-1)
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func streamLabel(_ strip: KyroSportsInlineStrip) -> some View {
        switch strip.stream {
        case .finding(let status):
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(status).truncationMode(.tail)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(KyroTheme.textSecondary)
            .accessibilityElement(children: .combine)
        case .playing(let name, let location):
            HStack(spacing: 4) {
                switch location {
                case .inline: Image(systemName: "tv")
                case .fullScreen: Image(systemName: "arrow.up.left.and.arrow.down.right")
                case .pictureInPicture: Image(systemName: "pip")
                }
                if let compact = strip.compactChannelName {
                    Text(compact).truncationMode(.tail)
                }
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(KyroTheme.textSecondary.opacity(0.8))
            .opacity(name == nil && location == .inline ? 0 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name.map { "Watching \($0)" } ?? "")
            .accessibilityHidden(name == nil)
        }
    }

    private func stripIconButton(_ symbol: String, label: String, identifier: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.siloOnSurface)
                .frame(width: LiveTVInlineChromeMetrics.pillHeight, height: LiveTVInlineChromeMetrics.pillHeight)
                .background(LiveTVSurface.row, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Finding and elsewhere

    /// Build 67: the strip below already names the event, so the frame says what is happening
    /// (finding, or connecting to which stream and which try) over a faint wash of the two teams'
    /// colours instead of a black box with a one-line, truncated channel name.
    private var findingOverlay: some View {
        ZStack {
            if let tint = findingTint {
                LinearGradient(colors: tint, startPoint: .leading, endPoint: .trailing)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 10) {
                ProgressView().tint(.white)
                if let status = KyroSportsConnectingStatus(phase: playback.phase, games: games) {
                    VStack(spacing: 3) {
                        Text(status.title).font(.headline).lineLimit(1)
                        if let detail = status.detail {
                            Text(detail).font(.caption).foregroundStyle(.white.opacity(0.8))
                                .multilineTextAlignment(.center).lineLimit(2)
                        }
                        if let attempt = status.attempt {
                            Text(attempt).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                                .monospacedDigit()
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityIdentifier("kyroSportsConnecting")
                }
                Button("Cancel") { service.cancelSportsPlayback() }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("kyroSportsCancelConnecting")
            }
            .padding(.horizontal, 24)
        }
    }

    /// The event's team colours, faint, for the connecting frame; nil when it has none.
    private var findingTint: [Color]? {
        guard let game = strip?.game else { return nil }
        let away = KyroSportsMatchupArtwork.cardColor(for: game.away.team)
        let home = KyroSportsMatchupArtwork.cardColor(for: game.home.team)
        guard away != nil || home != nil else { return nil }
        func color(_ rgb: KyroSportsRGB?) -> Color {
            let rgb = rgb ?? KyroSportsMatchupArtwork.neutralSide
            return Color(red: rgb.red, green: rgb.green, blue: rgb.blue).opacity(0.28)
        }
        return [color(away), color(home)]
    }

    private func elsewhereOverlay(isPictureInPicture: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: isPictureInPicture ? "pip" : "arrow.up.left.and.arrow.down.right")
                .font(.title2)
            Text(isPictureInPicture ? "Playing in Picture in Picture" : "Playing full screen")
                .font(.subheadline.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Helpers

    private func syncControls() {
        controls.update(state: session.state, isOverlayPresented: isShowingOtherStreams)
    }
}

/// Build 70: the inline player's bottom edge in window coordinates (0 until measured). A plain
/// class, not `@Observable`: writes never invalidate a view.
final class KyroSportsInlineStripEdge {
    var bottom: CGFloat = 0
}
#endif
