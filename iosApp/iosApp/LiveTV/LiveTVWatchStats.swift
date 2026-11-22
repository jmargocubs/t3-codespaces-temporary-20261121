import Foundation

/// One reading of what the Live TV engine reports, in Silo's own terms.
///
/// Every optional is nil when AetherEngine does not measure that value on the active route; nothing
/// here is estimated or derived from another field. The engine reports by route: the native (HLS
/// loopback) path measures the forward buffer and the A/V gap but not a displayed frame rate, and
/// the software path measures the decoded video queue, the displayed frame rate and late-frame delay
/// but not the forward buffer or the A/V gap. No route reports a separate audio buffer.
///
/// Kept free of AetherEngine types so the presentation rules can be tested on their own.
struct LiveTVStatsSample: Equatable {
    enum Route: Equatable { case none, remoteHLS, loopbackHLS, software, audioOnly }
    enum Phase: Equatable { case idle, loading, playing, paused, rebuffering, reconnecting, stalled, ended, failed }
    enum DynamicRange: Equatable { case sdr, hdr10, hdr10Plus, hlg, dolbyVision }

    var route: Route = .none
    var phase: Phase = .idle

    var videoCodec: String?
    var videoDecoder: String?
    var width: Int = 0
    var height: Int = 0
    var pixelAspectRatio: Double = 1
    /// The rate the stream declares.
    var declaredFrameRate: Double?
    /// The rate the display actually showed over the last second (software route only).
    var displayedFrameRate: Double?
    /// Nil until the engine knows the video's dimensions.
    var dynamicRange: DynamicRange?
    /// The video stream's own declared bitrate, when its header carries one.
    var declaredVideoBitrateBps: Double?

    var audioCodec: String?
    var audioChannels: Int?
    var isAtmos = false
    var audioPipeline: String?

    var container: String?
    /// Bytes of media the playhead crossed over about the last 10 s, over the seconds covered.
    var playedBitrateBps: Double?
    var averageBitrateBps: Double?
    var networkThroughputBps: Double?

    /// Loaded media ahead of the playhead, audio and video together (native route).
    var forwardBufferSeconds: Double?
    /// Decoded video queued ahead of the clock (software route).
    var decodedVideoQueueSeconds: Double?
    var droppedFrames: Int?
    /// Cumulative late-frame delay for the session (software route).
    var lateFrameDelaySeconds: Double?
    var avSyncOffsetMilliseconds: Double?
}

/// The small, session-scoped subset of engine metadata needed for the compact quality badges.
/// It intentionally excludes `liveTelemetry`: the Details tab must not start or depend on the
/// Stream Stats panel's 1 Hz diagnostics sampling.
struct LiveTVQualityMetadata: Equatable {
    let route: LiveTVStatsSample.Route
    let width: Int
    let height: Int
    let pixelAspectRatio: Double
    let declaredFrameRate: Double?
    let dynamicRange: LiveTVStatsSample.DynamicRange?
    let audioChannels: Int?
    let isAtmos: Bool

    init(
        route: LiveTVStatsSample.Route,
        width: Int = 0,
        height: Int = 0,
        pixelAspectRatio: Double = 1,
        declaredFrameRate: Double? = nil,
        dynamicRange: LiveTVStatsSample.DynamicRange? = nil,
        audioChannels: Int? = nil,
        isAtmos: Bool = false
    ) {
        self.route = route
        self.width = width
        self.height = height
        self.pixelAspectRatio = pixelAspectRatio
        self.declaredFrameRate = declaredFrameRate
        self.dynamicRange = dynamicRange
        self.audioChannels = audioChannels
        self.isAtmos = isAtmos
    }

    init(_ sample: LiveTVStatsSample) {
        self.init(
            route: sample.route,
            width: sample.width,
            height: sample.height,
            pixelAspectRatio: sample.pixelAspectRatio,
            declaredFrameRate: sample.declaredFrameRate,
            dynamicRange: sample.dynamicRange,
            audioChannels: sample.audioChannels,
            isAtmos: sample.isAtmos)
    }
}

/// Capabilities exposed by the current Aether route to the small Live TV control sheet.
/// This stays free of AetherEngine types so route policy can be tested on the host.
enum LiveTVPlayerControlCapabilities {
    static func canSelectAudio(route: LiveTVStatsSample.Route, trackCount: Int) -> Bool {
        route != .none && route != .remoteHLS && route != .audioOnly && trackCount > 1
    }

    static func canSelectSubtitles(route: LiveTVStatsSample.Route, trackCount: Int) -> Bool {
        route != .none && trackCount > 0
    }

    static func canChangeAspect(route: LiveTVStatsSample.Route) -> Bool {
        route != .none && route != .audioOnly
    }

    static func canRouteOutput(route: LiveTVStatsSample.Route) -> Bool {
        route != .none
    }

    /// The same route gate the old player-overlay Stream Stats button used. Build 71 moves the
    /// entry into Live TV Controls without changing which playing streams expose the metrics.
    static func canShowStreamInformation(route: LiveTVStatsSample.Route) -> Bool {
        route != .none
    }
}

/// Presentation state for the badges that survive opening and closing Stream Stats. The
/// channel identity is part of the state so a late metadata publication cannot repopulate the
/// previous channel after a retune.
struct LiveTVWatchQualityState: Equatable {
    private(set) var channelID: String?
    private(set) var badges: [LiveTVQualityBadge] = []

    init(channelID: String? = nil) {
        self.channelID = channelID
    }

    mutating func reset(for channelID: String?) {
        self.channelID = channelID
        badges = []
    }

    mutating func update(for channelID: String?, metadata: LiveTVQualityMetadata?) {
        guard self.channelID == channelID else { return }
        badges = LiveTVQualityBadge.detected(in: metadata)
    }
}

/// A compact indicator of a quality the engine detected in the stream. Only produced from measured
/// stream properties, so a channel never shows a badge it was not seen to deliver.
struct LiveTVQualityBadge: Equatable, Hashable, Identifiable {
    let text: String
    let accessibilityLabel: String
    var id: String { text }

    static func detected(in sample: LiveTVStatsSample?) -> [LiveTVQualityBadge] {
        detected(in: sample.map(LiveTVQualityMetadata.init))
    }

    static func detected(in metadata: LiveTVQualityMetadata?) -> [LiveTVQualityBadge] {
        guard let metadata, metadata.route != .none else { return [] }
        var badges: [LiveTVQualityBadge] = []
        let hasVideo = metadata.route != .audioOnly
        if hasVideo, let resolution = resolutionBadge(metadata) { badges.append(resolution) }
        if hasVideo, let fps = metadata.declaredFrameRate, fps.isFinite, fps >= 47.5 {
            let rounded = Int(fps.rounded())
            badges.append(.init(text: "\(rounded) fps", accessibilityLabel: "\(rounded) frames per second"))
        }
        switch hasVideo ? metadata.dynamicRange : nil {
        case .hdr10: badges.append(.init(text: "HDR10", accessibilityLabel: "HDR10"))
        case .hdr10Plus: badges.append(.init(text: "HDR10+", accessibilityLabel: "HDR10 plus"))
        case .hlg: badges.append(.init(text: "HLG", accessibilityLabel: "HLG high dynamic range"))
        case .dolbyVision: badges.append(.init(text: "Dolby Vision", accessibilityLabel: "Dolby Vision"))
        case .sdr, nil: break
        }
        if metadata.isAtmos {
            badges.append(.init(text: "Atmos", accessibilityLabel: "Dolby Atmos audio"))
        } else if metadata.audioChannels == 6 {
            badges.append(.init(text: "5.1", accessibilityLabel: "5.1 surround audio"))
        } else if metadata.audioChannels == 8 {
            badges.append(.init(text: "7.1", accessibilityLabel: "7.1 surround audio"))
        }
        return badges
    }

    /// Classed by the picture's displayed size, so a letterboxed 1920×800 stream is still Full HD.
    private static func resolutionBadge(_ metadata: LiveTVQualityMetadata) -> LiveTVQualityBadge? {
        guard metadata.width > 0, metadata.height > 0 else { return nil }
        let par = metadata.pixelAspectRatio.isFinite && metadata.pixelAspectRatio > 0 ? metadata.pixelAspectRatio : 1
        let displayWidth = Double(metadata.width) * par
        let lines = max(Double(metadata.height), displayWidth * 9 / 16)
        switch lines {
        case 2000...: return .init(text: "4K", accessibilityLabel: "4K Ultra HD")
        case 1000...: return .init(text: "FHD", accessibilityLabel: "Full HD")
        case 700...: return .init(text: "HD", accessibilityLabel: "HD")
        default: return .init(text: "SD", accessibilityLabel: "Standard definition")
        }
    }
}

/// The Stream Stats panel's content. Primary playback facts are listed first; advanced diagnostics are
/// kept in their own section. Values the engine does not measure on the active route read
/// "Unavailable" rather than being estimated. Dropped frames and late-frame delay are separate
/// measurements: the latter is a duration, not a late-frame count.
struct LiveTVWatchStats: Equatable {
    struct Row: Equatable, Identifiable {
        let label: String
        /// Nil renders as `LiveTVWatchStats.unavailable`.
        let value: String?
        var id: String { label }
    }

    struct Section: Equatable, Identifiable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    static let unavailable = "Unavailable"

    let status: String
    let isPlaying: Bool
    let sections: [Section]
    let badges: [LiveTVQualityBadge]

    static func make(_ sample: LiveTVStatsSample?) -> LiveTVWatchStats {
        guard let sample, sample.route != .none else {
            return LiveTVWatchStats(status: "Waiting for the stream", isPlaying: false, sections: [], badges: [])
        }
        return LiveTVWatchStats(
            status: statusText(sample.phase),
            isPlaying: sample.phase == .playing,
            sections: [video(sample), buffer(sample), advanced(sample)].filter { !$0.rows.isEmpty },
            badges: LiveTVQualityBadge.detected(in: sample))
    }

    // MARK: Sections

    private static func video(_ s: LiveTVStatsSample) -> Section {
        guard s.route != .audioOnly else {
            return Section(title: "Video", rows: [
                Row(label: "Video", value: "None (audio only)"),
                Row(label: "Bitrate", value: bitrate(s.playedBitrateBps)),
            ])
        }
        let rows = [
            Row(label: "Resolution", value: resolution(s)),
            Row(label: "Frame rate", value: frameRate(s.declaredFrameRate)),
            Row(label: "Codec", value: codecName(s.videoCodec)),
            Row(label: "Bitrate", value: bitrate(s.playedBitrateBps)),
        ]
        return Section(title: "Video", rows: rows)
    }

    private static func buffer(_ s: LiveTVStatsSample) -> Section {
        Section(title: "Buffer health", rows: [
            Row(label: "Buffer ahead", value: seconds(s.forwardBufferSeconds)),
            Row(label: "Video buffer", value: seconds(s.decodedVideoQueueSeconds)),
            // No AetherEngine route reports an audio-only buffer.
            Row(label: "Audio buffer", value: nil),
            Row(label: "Dropped frames", value: s.droppedFrames.flatMap { $0 >= 0 ? "\($0)" : nil }),
        ])
    }

    private static func advanced(_ s: LiveTVStatsSample) -> Section {
        Section(title: "Advanced diagnostics", rows: [
            Row(label: "Displayed frame rate", value: frameRate(s.displayedFrameRate)),
            Row(label: "Dynamic range", value: dynamicRange(s.dynamicRange)),
            Row(label: "Declared video bitrate", value: bitrate(s.declaredVideoBitrateBps)),
            Row(label: "Video decoder", value: normalized(s.videoDecoder)),
            Row(label: "Audio codec", value: codecName(s.audioCodec)),
            Row(label: "Audio channels", value: s.isAtmos ? "Dolby Atmos" : channels(s.audioChannels)),
            Row(label: "Audio output", value: normalized(s.audioPipeline)),
            Row(label: "Average bitrate", value: bitrate(s.averageBitrateBps)),
            Row(label: "Network throughput", value: bitrate(s.networkThroughputBps)),
            Row(label: "Container", value: containerName(s.container)),
            Row(label: "Playback route", value: routeName(s.route)),
            Row(label: "Late-frame delay", value: seconds(s.lateFrameDelaySeconds)),
            Row(label: "A/V offset", value: milliseconds(s.avSyncOffsetMilliseconds)),
        ])
    }

    // MARK: Formatting

    static func statusText(_ phase: LiveTVStatsSample.Phase) -> String {
        switch phase {
        case .idle: "Not playing"
        case .loading: "Connecting"
        case .playing: "Playing"
        case .paused: "Paused"
        case .rebuffering: "Buffering"
        case .reconnecting: "Reconnecting"
        case .stalled: "Stalled"
        case .ended: "Ended"
        case .failed: "Playback error"
        }
    }

    static func codecName(_ raw: String?) -> String? {
        guard let value = normalized(raw) else { return nil }
        switch value.lowercased() {
        case "hevc", "h265", "hvc1", "hev1": return "HEVC"
        case "h264", "avc", "avc1", "avc3": return "H.264"
        case "mpeg2video", "mpeg2": return "MPEG-2"
        case "mpeg4": return "MPEG-4 Part 2"
        case "av1": return "AV1"
        case "vp9": return "VP9"
        case "vc1": return "VC-1"
        case "aac", "mp4a", "aac_latm": return "AAC"
        case "ac3", "ac-3": return "Dolby Digital"
        case "eac3", "e-ac-3", "ec-3": return "Dolby Digital Plus"
        case "mp2": return "MPEG Audio Layer II"
        case "mp3": return "MP3"
        case "opus": return "Opus"
        case "flac": return "FLAC"
        case "truehd": return "Dolby TrueHD"
        case "dts": return "DTS"
        default: return value.uppercased()
        }
    }

    private static func resolution(_ s: LiveTVStatsSample) -> String? {
        guard s.width > 0, s.height > 0 else { return nil }
        let coded = "\(s.width)×\(s.height)"
        guard s.pixelAspectRatio.isFinite, s.pixelAspectRatio > 0,
              abs(s.pixelAspectRatio - 1) > 0.001 else { return coded }
        let displayWidth = Int((Double(s.width) * s.pixelAspectRatio).rounded())
        return "\(coded) (shown \(displayWidth)×\(s.height))"
    }

    static func frameRate(_ fps: Double?) -> String? {
        guard let fps, fps.isFinite, fps > 0 else { return nil }
        let whole = fps.rounded()
        return abs(fps - whole) < 0.005 ? "\(Int(whole)) fps" : String(format: "%.2f fps", fps)
    }

    private static func dynamicRange(_ range: LiveTVStatsSample.DynamicRange?) -> String? {
        switch range {
        case .sdr: "SDR"
        case .hdr10: "HDR10"
        case .hdr10Plus: "HDR10+"
        case .hlg: "HLG"
        case .dolbyVision: "Dolby Vision"
        case nil: nil
        }
    }

    private static func channels(_ count: Int?) -> String? {
        switch count {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        case let count? where count > 0: "\(count) channels"
        default: nil
        }
    }

    private static func containerName(_ raw: String?) -> String? {
        guard let value = normalized(raw) else { return nil }
        // libavformat names a demuxer by every alias it answers to ("mov,mp4,m4a,3gp,3g2,mj2").
        switch value.lowercased().split(separator: ",").first.map(String.init) ?? "" {
        case "mpegts": return "MPEG-TS"
        case "hls": return "HLS"
        case "mov": return "MP4"
        case "matroska": return "Matroska"
        case "flv": return "FLV"
        default: return value
        }
    }

    private static func routeName(_ route: LiveTVStatsSample.Route) -> String? {
        switch route {
        case .none: nil
        case .remoteHLS: "Native HLS"
        case .loopbackHLS: "Hardware (HLS loopback)"
        case .software: "Software decode"
        case .audioOnly: "Audio only"
        }
    }

    static func bitrate(_ bps: Double?) -> String? {
        guard let bps, bps.isFinite, bps > 0 else { return nil }
        return bps >= 1_000_000 ? String(format: "%.2f Mbps", bps / 1_000_000) : String(format: "%.0f kbps", bps / 1_000)
    }

    static func seconds(_ value: Double?) -> String? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return String(format: "%.2f s", value)
    }

    static func milliseconds(_ value: Double?) -> String? {
        guard let value, value.isFinite else { return nil }
        return String(format: "%.1f ms", value)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
