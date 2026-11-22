import AVFoundation
import AetherEngine
import Combine
import Observation
import SwiftUI

/// The production Live TV engine: a dedicated AetherEngine, separate from Silo's VOD playback
/// controller. It reports no watch progress and does not own Now Playing.
@MainActor
final class AetherLiveTVEngine: LiveTVEngineDriving {
    let engine: AetherEngine
    var onPhase: ((LiveTVEnginePhase) -> Void)?
    var onLiveSourceReset: (() -> Void)?
    var onSystemInterruption: (() -> Void)?
    var onSystemInterruptionEnded: (() -> Void)?
    var onAudioRouteLost: (() -> Void)?
    private var cancellables: Set<AnyCancellable> = []
    private let systemObservers = LiveTVNotificationTokens()
    private var runtimeCancellables: Set<AnyCancellable> = []
    private var runtimeSession: RuntimeAudioDiagnosticSession?
    private var runtimeID: UUID?
    private var runtimeGeneration = 0
    private var runtimeRoute = "unknown"

    init() throws {
        engine = try AetherEngine()
        engine.logTag = "livetv"
        engine.videoGravity = .resizeAspect
        // `playbackPhase` tracks motion, unlike `state`, which turns `.playing` as soon as the
        // engine calls play() on a live join that may not move for seconds.
        engine.$playbackPhase
            .sink { [weak self] phase in self?.publish(phase) }
            .store(in: &cancellables)
        engine.liveSourceReset
            .sink { [weak self] in self?.onLiveSourceReset?() }
            .store(in: &cancellables)
        observeSystemAudioEvents()
    }

    func load(_ url: URL, route: LiveTVStreamRoute) async throws {
        // Live only, fast-zap joins. HLS takes the engine's live HLS route, whose ingest fallback
        // covers HEVC-in-TS carriage and refused mounts; everything else is read by the engine.
        let options = LoadOptions(isLive: true, liveJoinProfile: .fastZap, nativeRemoteHLS: route == .hls)
        do {
            _ = try await engine.load(url: url, options: options)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LiveTVEngineLoadError(failure: Self.failure(engine.errorInfo), detail: Self.detail(engine.errorInfo))
        }
    }

    func recoverLiveSource() -> Bool { engine.retryLiveSourceRecovery() }

    func play() { engine.play() }

    func pause() { engine.pause() }

    func stop(final: Bool, releaseAudioSession: Bool) {
        finishRuntimeDiagnostics(phase: "stopped")
        // Silo's ownership rule: release only when no other Silo engine holds audio. Across
        // engines the release still belongs to the last one out (AetherEngine's shared output book).
        engine.deactivatesAudioSessionOnStop = releaseAudioSession
        engine.stop(finalTeardown: final)
    }

    private func publish(_ phase: PlaybackPhase) {
        let mapped: LiveTVEnginePhase = switch phase {
        case .idle: .idle
        case .loading: .loading
        case .playing: .playing
        case .paused: .paused
        case .seeking, .rebuffering: .rebuffering
        case .stalled(let reconnecting): .stalled(reconnecting: reconnecting)
        case .ended: .ended
        // `errorInfo` is assigned before the state it describes.
        case .error: .failed(Self.failure(engine.errorInfo), detail: Self.detail(engine.errorInfo))
        }
        if case .playing = phase {
            if runtimeSession == nil { beginRuntimeDiagnostics() }
            else { captureRuntimeSnapshot() }
        } else if runtimeSession != nil {
            captureRuntimeSnapshot()
            switch phase {
            case .ended: finishRuntimeDiagnostics(phase: "ended")
            case .error: finishRuntimeDiagnostics(phase: "error")
            default: break
            }
        }
        onPhase?(mapped)
    }

    /// Selection metadata contains only an opaque UUID, generation and the app's route enum.
    func prepareRuntimeDiagnostics(sessionID: UUID, generation: Int, route: LiveTVStreamRoute) {
        finishRuntimeDiagnostics(phase: "replaced")
        runtimeID = sessionID
        runtimeGeneration = generation
        runtimeRoute = route == .hls ? "hls" : "transport_stream"
    }

    private func beginRuntimeDiagnostics() {
        guard let runtimeID else { return }
        let now = ProcessInfo.processInfo.systemUptime
        runtimeSession = RuntimeAudioDiagnosticSession(sessionID: runtimeID, generation: runtimeGeneration,
            route: runtimeRoute, startedAt: now, initial: runtimeSnapshot())
        persistRuntime()
        engine.$audioDelivery.sink { [weak self] _ in self?.captureRuntimeSnapshot() }.store(in: &runtimeCancellables)
        engine.$activeAudioDecoder.sink { [weak self] _ in self?.captureRuntimeSnapshot() }.store(in: &runtimeCancellables)
        engine.$audioTracks.sink { [weak self] _ in self?.captureRuntimeSnapshot() }.store(in: &runtimeCancellables)
        engine.$activeAudioTrackIndex.sink { [weak self] _ in self?.captureRuntimeSnapshot() }.store(in: &runtimeCancellables)
    }

    private func runtimeSnapshot() -> RuntimeAudioDiagnosticSession.Snapshot {
        let phase: String = switch engine.playbackPhase {
        case .idle: "idle"
        case .loading: "loading"
        case .playing: "playing"
        case .paused: "paused"
        case .seeking: "seeking"
        case .rebuffering: "rebuffering"
        case .stalled: "stalled"
        case .ended: "ended"
        case .error: "error"
        }
        return .init(phase: phase, delivery: engine.audioDelivery.rawValue,
            decoder: safeDecoderLabel(engine.activeAudioDecoder), selectedTrack: engine.activeAudioTrackIndex,
            trackCount: engine.audioTracks.count)
    }

    private func safeDecoderLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .+-_/()")
        let normalized = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty ? nil : String(normalized.prefix(80))
    }

    private func captureRuntimeSnapshot() {
        guard var runtimeSession else { return }
        guard runtimeSession.observe(runtimeSnapshot(), now: ProcessInfo.processInfo.systemUptime) else { return }
        self.runtimeSession = runtimeSession
        persistRuntime()
    }

    private func recordSystemAudioEvent(_ name: String, value: String) {
        guard var runtimeSession else { return }
        runtimeSession.systemEvent(name, value: value, now: ProcessInfo.processInfo.systemUptime)
        self.runtimeSession = runtimeSession
        persistRuntime()
    }

    private func finishRuntimeDiagnostics(phase: String) {
        guard var runtimeSession else { runtimeID = nil; return }
        runtimeSession.end(phase: phase, now: ProcessInfo.processInfo.systemUptime)
        self.runtimeSession = nil
        runtimeCancellables.removeAll()
        persist(runtimeSession.record)
        runtimeID = nil
    }

    private func persistRuntime() {
        guard let runtimeSession else { return }
        persist(runtimeSession.record)
    }

    private func persist(_ record: RuntimeAudioDiagnosticRecord) {
        PlaybackDiagnosticsStore.shared.appendRuntime(record)
    }

    private static func failure(_ info: PlaybackErrorInfo?) -> LiveTVPlaybackFailure {
        LiveTVPlaybackFailure.classifyEngine(kind: info?.kind.rawValue, code: info?.underlyingCode)
    }

    private static func detail(_ info: PlaybackErrorInfo?) -> String? {
        LiveTVPlaybackFailure.diagnosticDetail(kind: info?.kind.rawValue, code: info?.underlyingCode)
    }

    /// Interruptions and lost routes pause Live TV; it resumes only when the viewer asks.
    private func observeSystemAudioEvents() {
        #if os(iOS) || os(tvOS)
        let center = NotificationCenter.default
        systemObservers.add(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            let typeLabel = type == AVAudioSession.InterruptionType.began.rawValue ? "began"
                : (type == AVAudioSession.InterruptionType.ended.rawValue ? "ended" : "unknown")
            let audioSession = AVAudioSession.sharedInstance()
            KyroPiPDiagnostics.record(
                "live_tv_audio_interruption",
                state: "type=\(typeLabel) options=\(options.map(String.init) ?? "none") category=\(audioSession.category.rawValue) mode=\(audioSession.mode.rawValue) otherAudio=\(audioSession.isOtherAudioPlaying) secondarySilenced=\(audioSession.secondaryAudioShouldBeSilencedHint)"
            )
            if let type { MainActor.assumeIsolated { self?.recordSystemAudioEvent("audio_interruption", value: type == AVAudioSession.InterruptionType.began.rawValue ? "began" : "ended") } }
            if type == AVAudioSession.InterruptionType.began.rawValue {
                MainActor.assumeIsolated { self?.onSystemInterruption?() }
            } else if type == AVAudioSession.InterruptionType.ended.rawValue,
                      let raw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                      AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume) {
                MainActor.assumeIsolated { self?.onSystemInterruptionEnded?() }
            }
        })
        systemObservers.add(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            KyroPiPDiagnostics.record("live_tv_audio_route_change", state: "reason=\(reason.map(String.init) ?? "unknown")")
            if let reason { MainActor.assumeIsolated { self?.recordSystemAudioEvent("audio_route_change", value: String(reason)) } }
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            MainActor.assumeIsolated { self?.onAudioRouteLost?() }
        })
        #endif
    }
}

extension LiveTVPlayerSession {
    static func makeDefault() -> LiveTVPlayerSession {
        #if os(iOS)
        let reference = LiveTVSessionReference()
        #endif
        let session = LiveTVPlayerSession(
            scheduler: LiveTVTaskScheduler(),
            makeEngine: { try AetherLiveTVEngine() },
            isOtherVideoActive: {
                #if os(iOS)
                // Engaged covers PiP starting as well as active. Live TV's own window is the stream
                // being tuned, so only another player's window blocks it.
                let coordinator = PictureInPictureCoordinator.shared
                return LiveTVPictureInPicturePolicy.isOtherVideoActive(
                    isEngaged: coordinator.isEngaged,
                    liveTVOwnsEngagement: reference.session.map(coordinator.ownsEngagedSession) ?? false)
                #else
                false
                #endif
            },
            isOwnPictureInPictureEngaged: {
                #if os(iOS)
                reference.session.map(PictureInPictureCoordinator.shared.ownsEngagedSession) ?? false
                #else
                false
                #endif
            }
        )
        #if os(iOS)
        reference.session = session
        #endif
        return session
    }
}

/// Removes block-based observers when their owner goes away.
private final class LiveTVNotificationTokens: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []
    func add(_ token: NSObjectProtocol) { tokens.append(token) }
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}

struct LiveTVPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var channel: LiveTVChannel
    @State private var isShowingChannelPicker = false
    /// Sports Hub only: the event's other streams.
    @State private var isShowingOtherStreams = false
    @State private var controls = LiveTVControlsVisibility(scheduler: LiveTVTaskScheduler())
    #if os(iOS)
    @State private var orientationCoordinator = PlayerOrientationCoordinator.shared
    @State private var pictureInPicture = PictureInPictureCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase
    #endif
    /// Fixed when the cover opens: full screen from an inline player is landscape on iPhone.
    @State private var orientation: LiveTVFullScreenOrientation
    /// The presentation this player appeared under; see `LiveTVPresentation.presentationEpoch`.
    @State private var presentedEpoch: Int?
    let channels: [LiveTVChannel]
    let session: LiveTVPlayerSession
    /// Owns the shared presentation and Picture in Picture hand-off; nil for a bare player.
    let service: LiveTVService?
    /// Set when the iPhone watch screen expanded into this player. Back then returns there and
    /// the stream plays on; the watch screen owns stopping it.
    let onCollapse: (() -> Void)?
    /// Watch-only surface handoff callbacks. The incoming surface reports mounted after Aether has
    /// bound it, allowing the portrait surface to unmount without an empty-frame interval.
    let onSurfaceMounted: (() -> Void)?
    let onSurfaceDismounted: (() -> Void)?
    /// A system-driven watch expansion follows the device back to portrait; the manual button
    /// keeps the existing landscape override, including under Portrait Orientation Lock.
    let naturalRotation: Bool

    init(channel: LiveTVChannel, channels: [LiveTVChannel], session: LiveTVPlayerSession,
         service: LiveTVService? = nil, naturalRotation: Bool = false,
         onCollapse: (() -> Void)? = nil,
         onSurfaceMounted: (() -> Void)? = nil,
         onSurfaceDismounted: (() -> Void)? = nil) {
        _channel = State(initialValue: channel)
        self.channels = channels
        self.session = session
        self.service = service
        self.onCollapse = onCollapse
        self.onSurfaceMounted = onSurfaceMounted
        self.onSurfaceDismounted = onSurfaceDismounted
        self.naturalRotation = naturalRotation
        #if os(iOS)
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        #else
        let isPhone = false
        #endif
        _orientation = State(initialValue: .resolve(
            isPhone: isPhone,
            isExpandedFromInline: !naturalRotation && (onCollapse != nil || service?.presentation.isFullScreenFromInline == true)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let aether = (session.engine as? AetherLiveTVEngine)?.engine {
                // The engine swaps its own layer per route; the surface only hosts it, so rotation
                // remounts the view without recreating the engine.
                ZStack {
                    AetherPlayerSurface(engine: aether)
                        .task {
                            onSurfaceMounted?()
                            service?.presentation.playerDidAppear(channel)
                        }
                        .onDisappear { onSurfaceDismounted?() }
                    LiveTVSubtitleLayer(engine: aether)
                }
                .ignoresSafeArea()
            }

            // Taps on the bare video toggle the controls; hidden controls let taps through to here.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { controls.toggle() }

            VStack(spacing: 0) {
                HStack {
                    if let onCollapse {
                        // Expanded from the watch screen: Back returns to it without a retune.
                        Button {
                            controls.cancel()
                            #if os(iOS)
                            orientationCoordinator.manualInlineCollapseRequested()
                            orientationCoordinator.deactivatePlayer()
                            #endif
                            onCollapse()
                        } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.headline.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel("Exit Full Screen")
                        .accessibilityHint("Returns to the channel details and guide; the channel keeps playing")
                        .accessibilityIdentifier("liveTVWatchCollapsePlayer")
                    } else if let service, service.presentation.canCollapseToInline {
                        // Expanded from Sports Hub's inline player: Back returns there and the
                        // stream plays on. The inline player has its own Stop.
                        Button {
                            controls.cancel()
                            #if os(iOS)
                            orientationCoordinator.manualInlineCollapseRequested()
                            orientationCoordinator.deactivatePlayer()
                            #endif
                            LiveTVCoverTransition.immediate { service.presentation.collapseToInline() }
                        } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.headline.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel("Back to Sports")
                        .accessibilityHint("Keeps the game playing above the Sports Hub")
                        .accessibilityIdentifier("kyroSportsCollapsePlayer")
                    } else {
                        Button {
                            controls.cancel()
                            session.stop()
                            #if os(iOS)
                            orientationCoordinator.deactivatePlayer()
                            #endif
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.headline.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel("Stop Live TV")
                    }

                    Spacer()
                    Text(channel.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()

                    HStack(spacing: 0) {
                    #if os(iOS)
                    if orientation.showsRotateControl {
                        Button {
                            controls.interact()
                            orientationCoordinator.toggleLiveTVOrientation()
                        } label: {
                            Image(systemName: orientationCoordinator.observedOrientation == .landscape
                                  ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .font(.headline.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel(orientationCoordinator.observedOrientation == .landscape
                                            ? "Return to portrait" : "Rotate to landscape")
                        .accessibilityHint("Changes Live TV orientation without stopping playback")
                    }
                    #endif

                    #if os(iOS)
                    if let aether = (session.engine as? AetherLiveTVEngine)?.engine {
                        LiveTVBasicControlsButton(engine: aether) { presenting in
                            controls.update(state: session.state, isOverlayPresented: presenting)
                        }
                    }
                    #endif

                    #if os(iOS)
                    if pictureInPicture.isSupported, pictureInPicture.hasSource {
                        Button {
                            controls.interact()
                            pictureInPicture.toggle()
                        } label: {
                            Image(systemName: pictureInPicture.isActive ? "pip.exit" : "pip.enter")
                                .font(.headline.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .disabled(!pictureInPicture.isPossible && !pictureInPicture.isActive)
                        .accessibilityLabel(pictureInPicture.isActive ? "Exit Picture in Picture" : "Picture in Picture")
                    }
                    #endif

                    #if os(iOS)
                    if let sports = sportsPlayback {
                        Button {
                            controls.interact()
                            isShowingOtherStreams = true
                        } label: {
                            Image(systemName: "sportscourt")
                                .font(.headline.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel("Other streams")
                        .accessibilityHint("Shows other broadcasts of \(sports.context.map { $0.game.away.team.nickname + " and " + $0.game.home.team.nickname } ?? "this event")")
                        .accessibilityIdentifier("kyroSportsOtherStreamsButton")
                    }
                    #endif

                    Button {
                        controls.interact()
                        isShowingChannelPicker = true
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.headline.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Switch channel")
                    }
                    .opacity(controls.isVisible ? 1 : 0)
                    .allowsHitTesting(controls.isVisible)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer()

                statusOverlay

                Spacer()

                if let transport = LiveTVTransportControl(state: session.state) {
                    Button {
                        controls.interact()
                        session.togglePlayback()
                    } label: {
                        Image(systemName: transport.symbol)
                            .font(.title2.weight(.bold))
                            .frame(width: 58, height: 58)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel(transport.accessibilityLabel)
                    .accessibilityHint("Temporary live-stream pause; the provider may not retain paused video.")
                    .padding(.bottom, 30)
                    .opacity(controls.isVisible ? 1 : 0)
                    .allowsHitTesting(controls.isVisible)
                } else {
                    Color.clear.frame(height: 88)
                }
            }
            .foregroundStyle(.white)
        }
        .animation(.easeInOut(duration: 0.2), value: controls.isVisible)
        #if os(iOS)
        .statusBarHidden()
        #endif
        .task {
            if let service {
                service.playPresentedChannel(channel)
                service.attachPictureInPicture()
            } else {
                session.play(channel)
            }
        }
        .onAppear {
            if presentedEpoch == nil { presentedEpoch = service?.presentation.presentationEpoch }
            #if os(iOS)
            // One geometry request either way. Full screen from the watch screen or Sports Hub is
            // locked landscape; activating free rotation first would queue a portrait request
            // that can win the race against the landscape one.
            switch orientation {
            case .landscapeLocked: orientationCoordinator.activateLiveTVLandscapePlayer()
            case .rotatesFreely: orientationCoordinator.activateLiveTVPlayer()
            }
            #endif
        }
        .onChange(of: channel) { oldValue, newValue in
            guard oldValue.id != newValue.id else { return }
            controls.channelChanged()
        }
        // The cover stays up across a retune (its identity is the presenter, not the channel), so
        // a switch made elsewhere, such as Sports Hub moving to another stream, renames it here.
        .onChange(of: service?.presentation.activeChannel?.id) { _, _ in
            guard let active = service?.presentation.activeChannel, active.id != channel.id,
                  case .presented = service?.presentation.phase else { return }
            channel = active
        }
        #if os(iOS)
        // Picture in Picture started from the button: only the cover closes. The stream plays on in
        // the window, and AVKit's restore control re-presents this player.
        .onChange(of: pictureInPicture.controlStartToken) { _, _ in
            guard pictureInPicture.ownsEngagedSession(session) else { return }
            if orientation == .landscapeLocked {
                // Release landscape now, not when the cover has finished closing: otherwise the
                // screens underneath are drawn sideways until it has. The cover swaps out in one
                // frame and the requested rotation back to portrait runs unanimated
                // (`PlayerRotationTransitionHost`), so the whole hand-off is a cut.
                orientationCoordinator.deactivatePlayer()
                LiveTVCoverTransition.immediate {
                    service?.presentation.pictureInPictureStartedFromControl()
                    dismiss()
                }
            } else {
                service?.presentation.pictureInPictureStartedFromControl()
                dismiss()
            }
        }
        // Automatic Picture in Picture on leaving the app keeps this cover, so coming back lands on
        // the player itself; end the window into it.
        .onChange(of: scenePhase) { _, phase in
            KyroPiPDiagnostics.record("live_tv_scene_phase", state: String(describing: phase))
            if phase == .active { pictureInPicture.stopForReturnToPresentedPlayer(owner: session) }
        }
        #endif
        .onChange(of: session.state) { syncControls() }
        #if os(iOS)
        .onChange(of: orientationCoordinator.observedOrientation) { _, orientation in
            guard naturalRotation, orientation == .portrait, let presentation = service?.presentation else { return }
            if presentation.isWatchExpandedByRotation {
                LiveTVCoverTransition.immediate { presentation.collapseWatch() }
            } else if presentation.isInlineExpandedByRotation, presentation.canCollapseToInline {
                LiveTVCoverTransition.immediate { _ = presentation.collapseToInline() }
            }
        }
        #endif
        .onChange(of: isShowingChannelPicker) { syncControls() }
        .onChange(of: isShowingOtherStreams) { syncControls() }
        .onDisappear {
            controls.cancel()
            // Close stops the session itself; this only catches the cover being taken down some
            // other way. A cover closed for Picture in Picture leaves the stream playing in the
            // window, and one collapsed into Sports Hub's inline player leaves it playing there.
            // Expanded from the watch screen, the watch screen underneath owns the stream. And a
            // cover that is no longer the current presentation owns nothing: its dismissal can
            // finish after a restore or a new selection has started the next one.
            if onCollapse == nil, shouldStopOnDisappear {
                session.stop()
            }
            #if os(iOS)
            orientationCoordinator.deactivatePlayer()
            #endif
        }
        .sheet(isPresented: $isShowingChannelPicker) {
            LiveTVChannelPickerView(channels: channels, selectedChannelID: channel.id, service: service) { selected in
                if let service {
                    guard service.playFromPlayerPicker(selected) else { return }
                } else {
                    session.play(selected)
                }
                channel = selected
                isShowingChannelPicker = false
            }
        }
        #if os(iOS)
        .sheet(isPresented: $isShowingOtherStreams) {
            if let sports = sportsPlayback ?? service?.sportsPlayback {
                KyroSportsOtherStreamsSheet(coordinator: sports, select: { match in
                    guard sports.switchTo(match) else { return }
                    channel = match.channel
                    isShowingOtherStreams = false
                }, dismiss: { isShowingOtherStreams = false })
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
            orientationCoordinator.refreshInterfaceOrientation()
        }
        #endif
    }

    private func syncControls() {
        controls.update(state: session.state, isOverlayPresented: isShowingChannelPicker || isShowingOtherStreams)
    }

    private var shouldStopOnDisappear: Bool {
        guard let service else { return true }
        guard let presentedEpoch else { return false }
        #if os(iOS)
        // Build 68.1: the same rule as the watch screen. A full-screen player rebuilt while the
        // automatic window shows its stream must not stop it.
        let isPictureInPictureEngaged = pictureInPicture.ownsEngagedSession(session)
        let stops = service.presentation.shouldStopWhenPlayerDisappears(
            presentedAt: presentedEpoch, isPictureInPictureEngaged: isPictureInPictureEngaged)
        KyroLifecycleJournal.record("livetv", "player_disappear",
                                    "\(LiveTVPresentation.journalName(service.presentation.phase)) epoch=\(presentedEpoch) pip_engaged=\(isPictureInPictureEngaged) app=\(KyroLifecycleJournal.applicationStateName()) stop=\(stops)")
        return stops
        #else
        return service.presentation.shouldStopWhenPlayerDisappears(presentedAt: presentedEpoch)
        #endif
    }

    /// The Sports Hub event this player is showing, when it has more than one stream. Ordinary
    /// Live TV playback has no event context and shows no Other Streams control.
    #if os(iOS)
    private var sportsPlayback: KyroSportsPlaybackCoordinator? {
        guard let service, service.sportsPlayback.phase == .presented,
              let context = service.sportsPlayback.context,
              context.alternatives.count + context.broadcasters.count > 1 else { return nil }
        return service.sportsPlayback
    }
    #endif

    @ViewBuilder
    private var statusOverlay: some View {
        switch session.state {
        case .connecting:
            statusCapsule("Connecting…")
        case .buffering:
            statusCapsule("Buffering…")
        case .failed:
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.title2)
                Text(session.errorMessage ?? LiveTVPlaybackFailure.unknown.message)
                    .font(.subheadline).multilineTextAlignment(.center)
                if let detail = session.failureDetail {
                    Text(detail).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.7))
                }
                if session.canRetry {
                    Button("Retry") {
                        controls.interact()
                        session.retry()
                    }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("Reconnects this channel")
                }
            }
            .foregroundStyle(.white)
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 28)
        case .playing, .paused, .stopped:
            EmptyView()
        }
    }

    private func statusCapsule(_ title: String) -> some View {
        ProgressView(title)
            .tint(.white)
            .foregroundStyle(.white)
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Hosts Aether's decoded subtitle cue stream over the Live TV surface. Aether deliberately keeps
/// subtitle decoding separate from its video surface; without this host overlay a selected EIA-608
/// track can be active (and show a checkmark) while its cues have nowhere to draw.
@MainActor
struct LiveTVSubtitleLayer: View {
    let engine: AetherEngine
    @State private var assSubtitles: ASSSubtitleSession
    @State private var cueHold = SubtitleCueHold()

    init(engine: AetherEngine) {
        self.engine = engine
        _assSubtitles = State(initialValue: ASSSubtitleSession(engine: engine))
    }

    var body: some View {
        AetherSubtitleOverlay(
            engine: engine,
            assSubtitles: assSubtitles,
            cueHold: cueHold,
            sourceTime: engine.clock.sourceTime,
            primaryUsesMovieTimeline: false,
            secondaryUsesMovieTimeline: false,
            livePrimaryCues: [],
            liveSecondaryCues: [],
            appearance: PlayerSettings.shared.effectiveSubtitleAppearance,
            subtitleSyncMs: PlayerSettings.shared.subtitleSyncMs)
    }
}

private struct LiveTVChannelPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let channels: [LiveTVChannel]
    let selectedChannelID: String
    let service: LiveTVService?
    let onSelect: (LiveTVChannel) -> Void
    @State private var query = ""
    @State private var search = LiveTVChannelSearchModel()
    #if os(iOS)
    @State private var paged = LiveTVPagedChannelModel()
    #endif

    var body: some View {
        NavigationStack {
            List {
                ForEach(orderedCategories, id: \.self) { category in
                    Section(category) {
                        ForEach(groups[category] ?? []) { candidate in
                            Button {
                                onSelect(candidate)
                            } label: {
                                HStack {
                                    Text(candidate.name).lineLimit(1)
                                    Spacer()
                                    if candidate.id == selectedChannelID {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onAppear { loadMoreIfNeeded(candidate) }
                        }
                    }
                }
            }
            .navigationTitle("Select Channel")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search channels")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { updateSearch() }
            .onChange(of: query) { updateSearch() }
            .onDisappear { search.cancel() }
        }
    }

    private func updateSearch() {
        #if os(iOS)
        if let service {
            paged.reset(service: service, providerID: service.selectedProviderID,
                        catalogRevision: service.channelCatalogRevision, query: query,
                        category: nil, favoritesOnly: false)
            return
        }
        #endif
        search.update(channels: channels, query: query, category: nil, favoritesOnly: false, favoriteIDs: [])
    }

    private var groups: [String: [LiveTVChannel]] {
        #if os(iOS)
        if service != nil { return paged.groups }
        #endif
        return search.groups
    }

    private var orderedCategories: [String] {
        #if os(iOS)
        if service != nil { return paged.orderedCategories }
        #endif
        return search.orderedCategories
    }

    private func loadMoreIfNeeded(_ channel: LiveTVChannel) {
        #if os(iOS)
        if let service { paged.loadPageIfNeeded(around: channel, service: service) }
        #endif
    }
}

#if os(iOS)
/// The shared Phase B1 entry point used by both the portrait watch frame and the full-screen
/// Live TV player. It owns no playback state: all selections go directly to the session's one
/// AetherEngine, and the sheet observes the engine's published track inventory.
struct LiveTVBasicControlsButton: View {
    @ObservedObject private var engine: AetherEngine
    let onPresentationChanged: (Bool) -> Void
    @State private var isShowingControls = false

    init(engine: AetherEngine, onPresentationChanged: @escaping (Bool) -> Void) {
        _engine = ObservedObject(wrappedValue: engine)
        self.onPresentationChanged = onPresentationChanged
    }

    private var route: LiveTVStatsSample.Route {
        switch engine.videoRoute {
        case .none: .none
        case .remoteBypass: .remoteHLS
        case .loopback: .loopbackHLS
        case .software: .software
        case .audio: .audioOnly
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if route != .none {
                Button {
                    onPresentationChanged(true)
                    isShowingControls = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.headline.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Live TV Controls")
                .accessibilityHint("Choose audio, subtitles, or picture aspect")
                .accessibilityIdentifier("liveTVBasicControls")

            }

            if LiveTVPlayerControlCapabilities.canRouteOutput(route: route) {
                AirPlayRoutePicker { presenting in
                    onPresentationChanged(presenting)
                }
                .frame(width: 44, height: 44)
                .siloPlayerGlass(in: Circle(), interactive: true)
            }
        }
        .sheet(isPresented: $isShowingControls) {
            LiveTVBasicControlsSheet(engine: engine)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: isShowingControls) { _, shown in
            onPresentationChanged(shown)
        }
    }
}

private struct LiveTVBasicControlsSheet: View {
    @ObservedObject var engine: AetherEngine
    @Environment(\.dismiss) private var dismiss
    @State private var aspect: VideoGravity
    @State private var isShowingStreamInformation = false

    init(engine: AetherEngine) {
        self._engine = ObservedObject(wrappedValue: engine)
        self._aspect = State(initialValue: Self.aspect(for: engine.videoGravity))
    }

    private var route: LiveTVStatsSample.Route {
        switch engine.videoRoute {
        case .none: .none
        case .remoteBypass: .remoteHLS
        case .loopback: .loopbackHLS
        case .software: .software
        case .audio: .audioOnly
        }
    }

    private static func aspect(for gravity: AVLayerVideoGravity) -> VideoGravity {
        VideoGravity.allCases.first {
            $0.avGravity.rawValue == gravity.rawValue
        } ?? .fit
    }

    var body: some View {
        NavigationStack {
            List {
                if LiveTVPlayerControlCapabilities.canSelectAudio(
                    route: route, trackCount: engine.audioTracks.count) {
                    Section("Audio") {
                        ForEach(engine.audioTracks) { track in
                            Button {
                                engine.selectAudioTrack(index: track.id)
                            } label: {
                                LiveTVTrackRow(
                                    title: LiveTVTrackLabel.audio(track),
                                    isSelected: engine.activeAudioTrackIndex == track.id)
                            }
                        }
                    }
                }

                if LiveTVPlayerControlCapabilities.canSelectSubtitles(
                    route: route, trackCount: engine.subtitleTracks.count) {
                    Section("Subtitles") {
                        Button {
                            engine.clearSubtitle()
                        } label: {
                            LiveTVTrackRow(
                                title: "Off",
                                isSelected: engine.activeSubtitleTrackIndex == nil)
                        }

                        ForEach(engine.subtitleTracks) { track in
                            Button {
                                engine.selectSubtitleTrack(index: track.id)
                            } label: {
                                LiveTVTrackRow(
                                    title: LiveTVTrackLabel.subtitle(track),
                                    isSelected: engine.activeSubtitleTrackIndex == track.id)
                            }
                        }
                    }
                }

                if LiveTVPlayerControlCapabilities.canChangeAspect(route: route) {
                    Section("Video") {
                        Picker("Aspect", selection: Binding(
                            get: { aspect },
                            set: { newValue in
                                aspect = newValue
                                PlayerSettings.shared.setVideoGravity(newValue)
                                engine.videoGravity = newValue.avGravity
                            })) {
                            ForEach(VideoGravity.allCases, id: \.self) { gravity in
                                Text(gravity.label).tag(gravity)
                            }
                        }
                    }
                }

                if LiveTVPlayerControlCapabilities.canShowStreamInformation(route: route) {
                    Section("Support") {
                        Button {
                            isShowingStreamInformation = true
                        } label: {
                            Label("Stream Information", systemImage: "chart.xyaxis.line")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .accessibilityHint("Shows technical information about the playing stream")
                        .accessibilityIdentifier("liveTVStreamInformation")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Live TV Controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $isShowingStreamInformation) {
            LiveTVStreamStatsSheet(engine: engine)
        }
        .preferredColorScheme(.dark)
    }
}

private struct LiveTVTrackRow: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack {
            Text(title)
                .lineLimit(2)
            Spacer(minLength: 12)
            if isSelected {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }
}

private enum LiveTVTrackLabel {
    static func audio(_ track: TrackInfo) -> String {
        let candidates: [String?] = [track.name, track.language, track.isAtmos ? "Atmos" : nil,
                                     track.isAtmos ? nil : TrackLabels.audioLayout(
                                        channelLayout: track.channelLayout, channels: track.channels),
                                     track.codec.isEmpty ? nil : track.codec.uppercased()]
        var parts = candidates.compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        if parts.isEmpty { parts = ["Audio track \(track.id)"] }
        return parts.joined(separator: " · ")
    }

    static func subtitle(_ track: TrackInfo) -> String {
        let candidates: [String?] = [track.name, track.language, track.codec.isEmpty ? nil : track.codec.uppercased(),
                                     track.isForced ? "Forced" : nil, track.isHearingImpaired ? "SDH" : nil]
        var parts = candidates.compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        if parts.isEmpty { parts = ["Subtitle track \(track.id)"] }
        return parts.joined(separator: " · ")
    }
}
#endif
