#if os(iOS)
import AetherEngine
import SwiftUI

/// The portrait watch screen, opened by choosing a channel in the guide on iPhone.
///
/// A 16:9 frame pinned at the top hosts the one Live TV session's engine surface. Below it, the
/// Details tab describes what is airing and the Guide tab is the regular guide, scrolling on its
/// own while the stream plays. A guide tap retunes the same session in place. Full Screen hands
/// the stream to the existing full-screen player, and Picture in Picture goes through the same
/// presentation as that player, so no second engine, session or audio claim exists.
struct LiveTVWatchView: View {
    @Bindable var service: LiveTVService

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: LiveTVWatchTab = .details
    /// The guide tab mounts on first use and then stays, so its scroll position, filters and
    /// search survive switching to Details and back.
    @State private var hasOpenedGuide = false
    @State private var controls = LiveTVControlsVisibility(scheduler: LiveTVTaskScheduler())
    @State private var pictureInPicture = PictureInPictureCoordinator.shared
    @State private var orientationCoordinator = PlayerOrientationCoordinator.shared
    /// Lightweight stream metadata for Details badges; it does not read live diagnostics.
    @State private var quality = LiveTVWatchQualityMonitor()
    /// The channel last shown, so the screen keeps its content while the cover animates away.
    @State private var lastChannel: LiveTVChannel?
    /// The presentation this screen appeared under; see `LiveTVPresentation.presentationEpoch`.
    @State private var presentedEpoch: Int?
    /// True only after the nested full-screen Aether surface has bound. Until then the portrait
    /// surface remains mounted, preventing the previously observed empty-frame handoff.
    @State private var fullscreenSurfaceMounted = false
    @Namespace private var tabIndicator

    private var presentation: LiveTVPresentation { service.presentation }
    private var session: LiveTVPlayerSession { service.playerSession }
    private var mode: LiveTVWatchSurfaceMode {
        .make(phase: presentation.phase, isExpanded: presentation.isWatchExpanded,
              isExpandedSurfaceMounted: fullscreenSurfaceMounted)
    }
    private var channel: LiveTVChannel? { mode.channel ?? lastChannel }

    var body: some View {
        let _ = KyroPerformanceDiagnostics.event("Watch body", .watchBody)
        VStack(spacing: 0) {
            playerFrame
            tabBar
            tabContent
        }
        .liveTVPageBackground()
        .tint(LiveTVAccent.primaryText)
        // A full-screen cover hides the app root's overlay, so the watch screen carries its own.
        .kyroPerformanceOverlay()
        .kyroGuidePerformanceScope("watch", isVisible: tab == .guide)
        .task {
            // The cover's first appearance starts the chosen channel, exactly as the full-screen
            // player's task does. Replaying the playing channel is a no-op in the session.
            guard let channel = mode.channel else { return }
            lastChannel = channel
            service.playPresentedChannel(channel)
            service.attachPictureInPicture()
        }
        .onAppear {
            orientationCoordinator.watchScreenDidAppear()
            if presentedEpoch == nil { presentedEpoch = presentation.presentationEpoch }
            // Build 68.1: shows on the next device run whether the screen is rebuilt while the app
            // goes to the background, and under which presentation.
            KyroLifecycleJournal.record("livetv", "watch_appear",
                                        "\(LiveTVPresentation.journalName(presentation.phase)) epoch=\(presentedEpoch ?? -1) pip_engaged=\(pictureInPicture.ownsEngagedSession(session)) app=\(KyroLifecycleJournal.applicationStateName())")
            attachQualityObservation()
            syncControls()
        }
        .onChange(of: orientationCoordinator.observedOrientation) { _, orientation in
            if orientation == .landscape {
                expandForDeviceRotation()
            } else if presentation.isWatchExpandedByRotation {
                LiveTVCoverTransition.immediate { presentation.collapseWatch() }
            }
        }
        .onChange(of: mode.channel?.id) { oldValue, newValue in
            if let current = mode.channel { lastChannel = current }
            guard oldValue != newValue else { return }
            quality.reset(for: newValue)
            if oldValue != nil, newValue != nil { controls.channelChanged() }
        }
        .onChange(of: session.engine != nil) { _, _ in
            attachQualityObservation()
        }
        // Engine creation and portrait playback begin in the same run-loop turn. Keep the
        // observation tied to the actual engine identity as well as the channel, so an engine
        // that appears after the cover's first onAppear is attached without Stats being opened.
        // This is lifecycle-driven, not a metadata polling loop.
        .task(id: qualityObservationKey) {
            attachQualityObservation()
        }
        .onChange(of: mode.hostsSurface) { _, hostsSurface in
            // Back from full screen: the full-screen player cancelled its own controls; re-read
            // the session here so ours hide again.
            guard hostsSurface else { return }
            attachQualityObservation()
            syncControls()
            controls.interact()
        }
        .onChange(of: presentation.isWatchExpanded) { _, expanded in
            if !expanded { fullscreenSurfaceMounted = false }
            if !expanded, mode.hostsSurface { orientationCoordinator.watchScreenDidAppear() }
        }
        .onChange(of: session.state) { syncControls() }
        // Picture in Picture started from a button: the window takes the stream and this cover
        // closes, exactly as the full-screen player's does. AVKit's restore re-presents it.
        .onChange(of: pictureInPicture.controlStartToken) { _, _ in
            // Expanded, the full-screen player above hands the stream over and closes both.
            guard pictureInPicture.ownsEngagedSession(session), !presentation.isWatchExpanded,
                  presentedEpoch == presentation.presentationEpoch else { return }
            presentation.pictureInPictureStartedFromControl()
            dismiss()
        }
        // Automatic Picture in Picture on leaving the app keeps this cover; coming back lands on
        // it, so end the window into it. Expanded, the full-screen player does this itself.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, !presentation.isWatchExpanded else { return }
            pictureInPicture.stopForReturnToPresentedPlayer(owner: session)
        }
        .onDisappear {
            // A full-screen cover may make SwiftUI report this view as disappeared before its
            // player activates. Keep the landscape permission during that one-surface handoff.
            if !presentation.isWatchExpanded { orientationCoordinator.watchScreenDidDisappear() }
            controls.cancel()
            // Close stops the session itself. This only catches the screen being taken down some
            // other way, and only while it is still the presentation that owns the stream: an
            // earlier screen finishing its dismissal must not stop what a newer one is playing.
            // Build 68.1: never while the Picture in Picture window is starting or showing this
            // session; the window owns it until it closes or the app restores into a cover.
            let isPictureInPictureEngaged = pictureInPicture.ownsEngagedSession(session)
            let stops = LiveTVWatchScreen.shouldStopWhenWatchScreenDisappears(
                presentation: presentation, presentedAt: presentedEpoch,
                isPictureInPictureEngaged: isPictureInPictureEngaged)
            KyroLifecycleJournal.record("livetv", "watch_disappear",
                                        "\(LiveTVPresentation.journalName(presentation.phase)) epoch=\(presentedEpoch ?? -1) pip_engaged=\(isPictureInPictureEngaged) app=\(KyroLifecycleJournal.applicationStateName()) stop=\(stops)")
            if stops {
                session.stop()
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { presentation.isWatchExpanded && mode.channel != nil },
            set: { if !$0 { presentation.collapseWatch() } }
        )) {
            if let channel = mode.channel {
                LiveTVPlayerView(channel: channel, channels: service.channels, session: session,
                                 service: service,
                                 naturalRotation: presentation.isWatchExpandedByRotation,
                                 onCollapse: { LiveTVCoverTransition.immediate { presentation.collapseWatch() } },
                                 onSurfaceMounted: { fullscreenSurfaceMounted = true },
                                 onSurfaceDismounted: { fullscreenSurfaceMounted = false })
            }
        }
    }

    // MARK: Player frame

    private var playerFrame: some View {
        ZStack {
            Color.black
            switch mode {
            case .video(let channel):
                video(channel)
            case .expanded:
                // Reached only after the incoming full-screen surface reported that it mounted.
                EmptyView()
            case .pictureInPicture:
                placeholder(symbol: "pip", title: "Playing in Picture in Picture")
            case .none:
                EmptyView()
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .background(Color.black.ignoresSafeArea(edges: .top))
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveTVWatchPlayer")
    }

    @ViewBuilder
    private func video(_ channel: LiveTVChannel) -> some View {
        if let aether = (session.engine as? AetherLiveTVEngine)?.engine {
            // Mounted only while this frame shows the stream. The full-screen player binds its
            // own surface; the engine moves its one layer to whichever surface is bound last.
            ZStack {
                AetherPlayerSurface(engine: aether)
                LiveTVSubtitleLayer(engine: aether)
            }
                .task {
                    service.attachPictureInPicture()
                    presentation.watchScreenDidAppear(channel)
                }
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
                .accessibilityHint("Reconnects this channel")
            }
        }
        controlsOverlay(channel)
            .opacity(controls.isVisible ? 1 : 0)
            .allowsHitTesting(controls.isVisible)
            .animation(.easeInOut(duration: 0.2), value: controls.isVisible)
    }

    /// Close at the leading corner, Picture in Picture and Full Screen at the trailing one, and the
    /// transport control in the middle. The channel's name is in Details and highlighted in the
    /// Guide, so nothing is written over the picture.
    private func controlsOverlay(_ channel: LiveTVChannel) -> some View {
        LiveTVInlineControlsOverlay(transport: LiveTVTransportControl(state: session.state)) {
            controls.interact()
            session.togglePlayback()
        } leading: {
            LiveTVInlineIconButton(symbol: "xmark", label: "Stop Live TV", identifier: "liveTVWatchClose") {
                controls.cancel()
                session.stop()
                dismiss()
            }
            .accessibilityHint("Stops \(channel.name) and closes the player")
        } trailing: {
            if let aether = (session.engine as? AetherLiveTVEngine)?.engine {
                LiveTVBasicControlsButton(engine: aether) { presenting in
                    controls.update(state: session.state, isOverlayPresented: presenting)
                }
            }
            if pictureInPicture.isSupported, pictureInPicture.hasSource {
                LiveTVInlineIconButton(symbol: "pip.enter", label: "Picture in Picture",
                                       identifier: "liveTVWatchPictureInPicture") {
                    controls.interact()
                    pictureInPicture.toggle()
                }
                .disabled(!pictureInPicture.isPossible)
            }
            LiveTVInlineIconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Full Screen",
                                   identifier: "liveTVWatchFullScreen") {
                expand()
            }
        }
    }

    private func placeholder(symbol: String, title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2)
            Text(title).font(.subheadline.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(LiveTVWatchTab.allCases) { item in
                Button {
                    // No animation transaction: Details and the Guide are both transparent and
                    // full height, so animating the swap cross-faded one list through the other
                    // (Build 50 recording, 3:28.6 and 3:30.0). Only the indicator animates.
                    select(item)
                } label: {
                    VStack(spacing: 8) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(tab == item ? LiveTVAccent.primaryText : Color.siloSecondaryText)
                        ZStack {
                            Capsule().fill(Color.clear).frame(height: 3)
                            if tab == item {
                                Capsule()
                                    .fill(LiveTVAccent.primaryText)
                                    .frame(height: 3)
                                    .matchedGeometryEffect(id: "indicator", in: tabIndicator)
                            }
                        }
                    }
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
                .accessibilityIdentifier("liveTVWatchTab.\(item.rawValue)")
            }
        }
        .background(LiveTVSurface.canvas)
        .overlay(alignment: .bottom) { Divider() }
        .animation(.snappy(duration: 0.25), value: tab)
    }

    private var tabContent: some View {
        ZStack {
            if hasOpenedGuide {
                LiveTVWatchGuideTab(service: service, activeChannelID: mode.channel?.id, tune: switchTo)
                    .equatable()
                    .opacity(tab == .guide ? 1 : 0)
                    .allowsHitTesting(tab == .guide)
                    .accessibilityHidden(tab != .guide)
            }
            if tab == .details, let channel {
                LiveTVWatchDetailsView(
                    service: service, channel: channel,
                    qualityBadges: quality.badges,
                    canPictureInPicture: pictureInPicture.isSupported && pictureInPicture.hasSource,
                    isPictureInPicturePossible: pictureInPicture.isPossible,
                    onFullScreen: expand,
                    onPictureInPicture: { pictureInPicture.toggle() })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func select(_ item: LiveTVWatchTab) {
        if item == .guide { hasOpenedGuide = true }
        tab = item
    }

    /// A channel chosen in the Guide tab plays here, through the same session.
    private func switchTo(_ selected: LiveTVChannel) {
        switch LiveTVWatchSwitch.resolve(selectedChannelID: selected.id, activeChannelID: mode.channel?.id) {
        case .alreadyPlaying:
            if session.state == .failed { session.retry() }
        case .retune:
            guard service.playFromPlayerPicker(selected) else { return }
            lastChannel = selected
        }
        controls.interact()
    }

    private func expand() {
        controls.cancel()
        LiveTVCoverTransition.immediate { presentation.expandWatch() }
    }

    private func expandForDeviceRotation() {
        guard mode.hostsSurface, !presentation.isWatchExpanded,
              !orientationCoordinator.suppressNaturalExpansionUntilUpright else { return }
        controls.cancel()
        LiveTVCoverTransition.immediate { presentation.expandWatch(byRotation: true) }
    }

    private func syncControls() {
        controls.update(state: session.state, isOverlayPresented: false)
    }

    private func attachQualityObservation() {
        quality.attach(
            to: (session.engine as? AetherLiveTVEngine)?.engine,
            channelID: mode.channel?.id ?? lastChannel?.id)
    }

    private var qualityObservationKey: String {
        let engineID = (session.engine as? AetherLiveTVEngine).map { ObjectIdentifier($0.engine) }
        return "\(mode.channel?.id ?? lastChannel?.id ?? ""):\(engineID.map(String.init(describing:)) ?? "none")"
    }
}

/// The Guide tab, insulated from the watch screen's own updates.
///
/// The watch screen redraws on playback state, control visibility, Picture in Picture readiness
/// and, while Details shows, engine metadata. Build 59 passed the guide a context holding a fresh
/// closure each time, which SwiftUI cannot compare, so every one of those redraws rebuilt the guide
/// body and every visible row, mounted behind Details too (measured on macOS: 14 row closures and
/// 14 row bodies per parent update). The guide now updates only for its own state, the service
/// it observes, and a change of playing channel.
private struct LiveTVWatchGuideTab: View, Equatable {
    let service: LiveTVService
    let activeChannelID: String?
    /// Always this watch screen's `switchTo`, which reaches its state through shared storage.
    let tune: (LiveTVChannel) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.service === rhs.service && lhs.activeChannelID == rhs.activeChannelID
    }

    var body: some View {
        NavigationStack {
            LiveTVGuideView(service: service, watch: LiveTVGuideWatchContext(activeChannelID: activeChannelID, tune: tune))
        }
    }
}

/// The Details tab: the channel, what is airing with its progress, two compact actions and what
/// follows, all from the guide data Live TV already holds. The Guide has its own tab, so Details
/// does not repeat it.
private struct LiveTVWatchDetailsView: View {
    @Bindable var service: LiveTVService
    let channel: LiveTVChannel
    /// Qualities the engine detected in the playing stream; empty until it reports them.
    let qualityBadges: [LiveTVQualityBadge]
    let canPictureInPicture: Bool
    let isPictureInPicturePossible: Bool
    let onFullScreen: () -> Void
    let onPictureInPicture: () -> Void
    @State private var isSummaryExpanded = false

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let details = LiveTVWatchDetails.make(
                channel: channel,
                programs: service.guidePrograms(
                    for: channel, overlapping: DateInterval(start: now, duration: LiveTVWatchDetails.lookahead)),
                fallback: service.programPair(for: channel, at: now),
                now: now)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(details)
                    nowAiring(details, now: now)
                    actions
                    if !details.upcoming.isEmpty { upNext(details.upcoming, now: now) }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .onChange(of: channel.id) { isSummaryExpanded = false }
        .accessibilityIdentifier("liveTVWatchDetails")
    }

    private func header(_ details: LiveTVWatchDetails) -> some View {
        let isFavorite = service.isFavorite(channel)
        return HStack(spacing: 12) {
            LiveTVChannelLogo(channel: channel, size: CGSize(width: 48, height: 38))
            VStack(alignment: .leading, spacing: 3) {
                Text(details.channelName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.siloOnSurface)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("LIVE")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(LiveTVAccent.live, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    if let category = details.channelCategory {
                        Text(category)
                            .font(.caption)
                            .foregroundStyle(Color.siloSecondaryText)
                            .lineLimit(1)
                    }
                    LiveTVQualityBadgeRow(badges: qualityBadges)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button {
                service.toggleFavorite(channel)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isFavorite ? LiveTVAccent.ember : Color.siloOnSurface)
                    .frame(width: 36, height: 36)
                    .background(LiveTVSurface.row, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavorite ? "Remove \(channel.name) from Favorites" : "Add \(channel.name) to Favorites")
            .accessibilityIdentifier("liveTVWatchFavorite")
        }
    }

    @ViewBuilder
    private func nowAiring(_ details: LiveTVWatchDetails, now: Date) -> some View {
        if let current = details.current {
            VStack(alignment: .leading, spacing: 10) {
                Text("ON NOW")
                    .font(.caption2.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(LiveTVAccent.primaryText)
                VStack(alignment: .leading, spacing: 3) {
                    Text(current.title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color.siloOnSurface)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle = current.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Color.siloSecondaryText)
                    }
                }
                progress(current, value: details.progress ?? 0, now: now)
                let tags = [current.episode, current.category].compactMap { $0 }
                if !tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.siloSecondaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.siloSurfaceElevated, in: Capsule())
                        }
                    }
                }
                if let summary = current.summary {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(Color.siloOnSurface.opacity(0.9))
                        .lineLimit(isSummaryExpanded ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)
                        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { isSummaryExpanded.toggle() } }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(isSummaryExpanded ? "Shows less" : "Shows the full description")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LiveTVSurface.row, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("liveTVWatchNowAiring")
        } else {
            Label(service.isGuideLoading || service.isGuideChannelLoading(channel)
                  ? "Loading guide…" : "No guide information for this channel",
                  systemImage: "calendar.badge.exclamationmark")
                .font(.subheadline)
                .foregroundStyle(Color.siloSecondaryText)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LiveTVSurface.row, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// A slim bar between the programme's start and end, with the time left beside it.
    private func progress(_ current: LiveTVWatchDetails.Airing, value: Double, now: Date) -> some View {
        VStack(spacing: 5) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(LiveTVAccent.primaryText)
                        .frame(width: max(4, proxy.size.width * value))
                }
            }
            .frame(height: 4)
            HStack {
                Text(current.start, format: .dateTime.hour().minute())
                Spacer(minLength: 8)
                Text(LiveTVWatchDetails.remainingText(end: current.end, now: now))
                    .foregroundStyle(Color.siloOnSurface)
                Spacer(minLength: 8)
                Text(current.end, format: .dateTime.hour().minute())
            }
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(Color.siloSecondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Programme progress")
        .accessibilityValue("\(Int((value * 100).rounded())) percent, \(LiveTVWatchDetails.remainingText(end: current.end, now: now))")
    }

    /// Full Screen and Picture in Picture as small capsules: reachable when the player's own
    /// controls are hidden, without a row of large tiles. Favorite sits in the header.
    private var actions: some View {
        HStack(spacing: 8) {
            LiveTVInlinePillButton(title: "Full Screen", symbol: "arrow.up.left.and.arrow.down.right",
                                   identifier: "liveTVWatchDetailsFullScreen", action: onFullScreen)
            if canPictureInPicture {
                LiveTVInlinePillButton(title: "Picture in Picture", symbol: "pip.enter",
                                       identifier: "liveTVWatchDetailsPictureInPicture", action: onPictureInPicture)
                    .disabled(!isPictureInPicturePossible)
            }
            Spacer(minLength: 0)
        }
    }

    private func upNext(_ airings: [LiveTVWatchDetails.Airing], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("UP NEXT")
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(Color.siloSecondaryText)
                .padding(.leading, 2)
            VStack(spacing: 0) {
                ForEach(Array(airings.enumerated()), id: \.element.id) { index, airing in
                    upNextRow(airing, isNext: index == 0, now: now)
                    if index < airings.count - 1 { Divider().padding(.leading, 24 + CGFloat(LiveTVWatchDetails.upNextTimeColumnWidth)) }
                }
            }
            .background(LiveTVSurface.row, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .accessibilityIdentifier("liveTVWatchUpNext")
    }

    private func upNextRow(_ airing: LiveTVWatchDetails.Airing, isNext: Bool, now: Date) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // One line at its natural width: "11:00 PM" must not break before the AM/PM.
            Text(airing.start, format: .dateTime.hour().minute())
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isNext ? LiveTVAccent.primaryText : Color.siloOnSurface)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: CGFloat(LiveTVWatchDetails.upNextTimeColumnWidth), alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(airing.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.siloOnSurface)
                    .lineLimit(1)
                if let subtitle = airing.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.siloSecondaryText)
                        .lineLimit(1)
                }
                Text(isNext
                     ? "\(LiveTVWatchDetails.startsInText(start: airing.start, now: now)) · \(LiveTVWatchDetails.durationText(start: airing.start, end: airing.end))"
                     : LiveTVWatchDetails.durationText(start: airing.start, end: airing.end))
                    .font(.caption)
                    .foregroundStyle(Color.siloSecondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
#endif
