#if os(iOS)
import AetherEngine
import Combine
import Observation

extension LiveTVStatsSample {
    /// Reads the Live TV engine's public state and its 1 Hz telemetry. Read-only: sampling never
    /// changes playback, routes, tracks or the audio session.
    @MainActor
    init(engine: AetherEngine) {
        route = switch engine.videoRoute {
        case .none: .none
        case .remoteBypass: .remoteHLS
        case .loopback: .loopbackHLS
        case .software: .software
        case .audio: .audioOnly
        }
        phase = switch engine.playbackPhase {
        case .idle: .idle
        case .loading: .loading
        case .playing: .playing
        case .paused: .paused
        case .seeking, .rebuffering: .rebuffering
        case .stalled(let reconnecting): reconnecting ? .reconnecting : .stalled
        case .ended: .ended
        case .error: .failed
        }

        videoCodec = engine.sourceVideoCodecName
        videoDecoder = engine.activeVideoDecoder
        width = Int(engine.sourceVideoWidth)
        height = Int(engine.sourceVideoHeight)
        pixelAspectRatio = engine.sourceVideoPixelAspectRatio
        declaredFrameRate = engine.sourceVideoFrameRate
        if width > 0, height > 0 {
            dynamicRange = switch engine.sourceVideoFormat {
            case .sdr: .sdr
            case .hdr10: .hdr10
            case .hdr10Plus: .hdr10Plus
            case .hlg: .hlg
            case .dolbyVision: .dolbyVision
            }
        }
        declaredVideoBitrateBps = engine.sourceVideoBitrate > 0 ? Double(engine.sourceVideoBitrate) : nil

        let activeAudio = engine.activeAudioTrackIndex.flatMap { id in engine.audioTracks.first { $0.id == id } }
        audioCodec = activeAudio?.codec
        audioChannels = activeAudio.flatMap { $0.channels > 0 ? $0.channels : nil }
        isAtmos = activeAudio?.isAtmos ?? false
        audioPipeline = engine.activeAudioDecoder
        container = engine.sourceContainerFormat

        let telemetry = engine.liveTelemetry
        displayedFrameRate = telemetry?.observedFps
        playedBitrateBps = Self.bitsPerSecond(telemetry?.instantBitrateMbps)
        averageBitrateBps = Self.bitsPerSecond(telemetry?.averageBitrateMbps)
        networkThroughputBps = Self.bitsPerSecond(telemetry?.networkThroughputMbps)
        forwardBufferSeconds = telemetry?.forwardBufferSeconds
        decodedVideoQueueSeconds = telemetry?.displayCushionSeconds
        droppedFrames = telemetry?.droppedFrameCount
        lateFrameDelaySeconds = telemetry?.accumulatedFrameDelaySeconds
        avSyncOffsetMilliseconds = telemetry?.avSyncGapMs
    }

    private static func bitsPerSecond(_ mbps: Double?) -> Double? {
        guard let mbps, mbps.isFinite, mbps >= 0 else { return nil }
        return mbps * 1_000_000
    }
}

/// Holds the watch screen's latest engine reading. Values are reassigned only when they change, so
/// a view that reads just `badges` is not redrawn by every 1 Hz telemetry tick.
@MainActor
@Observable
final class LiveTVWatchStatsMonitor {
    private(set) var sample: LiveTVStatsSample?
    private(set) var badges: [LiveTVQualityBadge] = []

    func refresh(from engine: AetherEngine?) {
        var next = engine.map(LiveTVStatsSample.init(engine:))
        if next?.route == LiveTVStatsSample.Route.none { next = nil }
        if next != sample { sample = next }
        let nextBadges = LiveTVQualityBadge.detected(in: next)
        if nextBadges != badges { badges = nextBadges }
    }

    /// Drops the previous channel's reading so a retune never shows stale values.
    func reset() {
        if sample != nil { sample = nil }
        if !badges.isEmpty { badges = [] }
    }
}

/// Observes only the engine's published stream metadata needed for Details badges. This is kept
/// separate from `LiveTVWatchStatsMonitor`: the latter reads the complete diagnostics sample only
/// while the Stream Stats panel is visible; this monitor remains light and session-scoped for Details.
@MainActor
@Observable
final class LiveTVWatchQualityMonitor {
    private(set) var state = LiveTVWatchQualityState()

    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private weak var observedEngine: AetherEngine?
    @ObservationIgnored private var observedEngineID: ObjectIdentifier?

    var badges: [LiveTVQualityBadge] { state.badges }

    /// Attaches once to the session's one engine. Reattaching the same engine only rereads its
    /// current metadata; it never starts a telemetry loop or samples `liveTelemetry`.
    func attach(to engine: AetherEngine?, channelID: String?) {
        let identity = engine.map { ObjectIdentifier($0) }
        guard identity != observedEngineID else {
            if state.channelID != channelID { reset(for: channelID) }
            if let engine { refresh(from: engine) }
            return
        }

        cancellables.removeAll()
        observedEngine = engine
        observedEngineID = identity
        reset(for: channelID)
        guard let engine else { return }

        let changes: [AnyPublisher<Void, Never>] = [
            engine.$videoRoute.map { _ in () }.eraseToAnyPublisher(),
            engine.$sourceVideoWidth.map { _ in () }.eraseToAnyPublisher(),
            engine.$sourceVideoHeight.map { _ in () }.eraseToAnyPublisher(),
            engine.$sourceVideoFrameRate.map { _ in () }.eraseToAnyPublisher(),
            engine.$sourceVideoCodecName.map { _ in () }.eraseToAnyPublisher(),
            engine.$sourceVideoFormat.map { _ in () }.eraseToAnyPublisher(),
            // The pixel aspect ratio is published through the engine's state rather than the
            // width/height publishers. It is part of the same badge snapshot and must not leave
            // an anamorphic stream with a stale classification.
            engine.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            engine.$audioTracks.map { _ in () }.eraseToAnyPublisher(),
            engine.$activeAudioTrackIndex.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .sink { [weak self, weak engine] in
                guard let self, let engine else { return }
                self.refresh(from: engine)
            }
            .store(in: &cancellables)
        refresh(from: engine)
    }

    /// Clears immediately on a retune. The engine's next published metadata update then fills the
    /// badges for the new channel, while channel fencing rejects any late old-session callback.
    func reset(for channelID: String?) {
        var next = state
        next.reset(for: channelID)
        if next != state { state = next }
    }

    /// Runs on every engine `objectWillChange`, which a live loopback stream fires at least once per
    /// segment (`residentRanges`). Mutating `state` in place notifies observers even when nothing
    /// changed (Swift Observation's `_modify` path), which redrew the watch screen each time, so
    /// assign only a different value.
    private func refresh(from engine: AetherEngine) {
        var next = state
        next.update(for: state.channelID, metadata: Self.metadata(from: engine))
        if next != state { state = next }
    }

    private static func metadata(from engine: AetherEngine) -> LiveTVQualityMetadata? {
        let route: LiveTVStatsSample.Route = switch engine.videoRoute {
        case .none: .none
        case .remoteBypass: .remoteHLS
        case .loopback: .loopbackHLS
        case .software: .software
        case .audio: .audioOnly
        }
        guard route != .none else { return nil }

        let width = Int(engine.sourceVideoWidth)
        let height = Int(engine.sourceVideoHeight)
        let dynamicRange: LiveTVStatsSample.DynamicRange? = if width > 0, height > 0 {
            switch engine.sourceVideoFormat {
            case .sdr: .sdr
            case .hdr10: .hdr10
            case .hdr10Plus: .hdr10Plus
            case .hlg: .hlg
            case .dolbyVision: .dolbyVision
            }
        } else {
            nil
        }
        let activeAudio = engine.activeAudioTrackIndex.flatMap { id in
            engine.audioTracks.first { $0.id == id }
        }
        return LiveTVQualityMetadata(
            route: route,
            width: width,
            height: height,
            pixelAspectRatio: engine.sourceVideoPixelAspectRatio,
            declaredFrameRate: engine.sourceVideoFrameRate,
            dynamicRange: dynamicRange,
            audioChannels: activeAudio.flatMap { $0.channels > 0 ? $0.channels : nil },
            isAtmos: activeAudio?.isAtmos ?? false)
    }
}
#endif
