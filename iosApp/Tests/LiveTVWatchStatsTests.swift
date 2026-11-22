import XCTest
@testable import Silo

final class LiveTVWatchStatsTests: XCTestCase {
    private func value(_ stats: LiveTVWatchStats, _ section: String, _ label: String) -> String?? {
        guard let row = stats.sections.first(where: { $0.title == section })?.rows.first(where: { $0.label == label })
        else { return .none }
        return .some(row.value)
    }

    private var nativeHD: LiveTVStatsSample {
        var s = LiveTVStatsSample()
        s.route = .loopbackHLS
        s.phase = .playing
        s.videoCodec = "h264"
        s.width = 1920
        s.height = 1080
        s.declaredFrameRate = 50
        s.dynamicRange = .sdr
        s.audioCodec = "aac"
        s.audioChannels = 2
        s.container = "mpegts"
        s.playedBitrateBps = 6_400_000
        s.forwardBufferSeconds = 3.25
        s.droppedFrames = 2
        s.avSyncOffsetMilliseconds = -12.5
        return s
    }

    func testWatchTabsContainOnlyDetailsAndGuide() {
        XCTAssertEqual(LiveTVWatchTab.allCases, [.details, .guide])
    }

    func testNoSampleWaitsWithoutInventingRows() {
        let stats = LiveTVWatchStats.make(nil)
        XCTAssertEqual(stats.status, "Waiting for the stream")
        XCTAssertFalse(stats.isPlaying)
        XCTAssertTrue(stats.sections.isEmpty)
        XCTAssertTrue(stats.badges.isEmpty)
        XCTAssertTrue(LiveTVWatchStats.make(LiveTVStatsSample()).sections.isEmpty, "route .none is not a stream")
    }

    func testNativeRouteShowsMeasuredValues() {
        let stats = LiveTVWatchStats.make(nativeHD)
        XCTAssertTrue(stats.isPlaying)
        XCTAssertEqual(value(stats, "Video", "Codec"), "H.264")
        XCTAssertEqual(value(stats, "Video", "Resolution"), "1920×1080")
        XCTAssertEqual(value(stats, "Video", "Frame rate"), "50 fps")
        XCTAssertEqual(value(stats, "Video", "Bitrate"), "6.40 Mbps")
        XCTAssertEqual(value(stats, "Advanced diagnostics", "Audio channels"), "Stereo")
        XCTAssertEqual(value(stats, "Advanced diagnostics", "Container"), "MPEG-TS")
        XCTAssertEqual(value(stats, "Buffer health", "Buffer ahead"), "3.25 s")
        XCTAssertEqual(value(stats, "Buffer health", "Dropped frames"), "2")
        XCTAssertEqual(value(stats, "Advanced diagnostics", "A/V offset"), "-12.5 ms")
    }

    /// The native route has no decoded-video queue, late-frame delay or audio buffer: those rows
    /// stay listed and read Unavailable instead of zero.
    func testUnmeasuredRowsStayListedAsUnavailable() {
        let stats = LiveTVWatchStats.make(nativeHD)
        XCTAssertEqual(value(stats, "Buffer health", "Video buffer"), .some(nil))
        XCTAssertEqual(value(stats, "Buffer health", "Audio buffer"), .some(nil))
        XCTAssertEqual(value(stats, "Advanced diagnostics", "Late-frame delay"), .some(nil))
        XCTAssertEqual(value(stats, "Advanced diagnostics", "Displayed frame rate"), .some(nil))
        XCTAssertEqual(value(stats, "Advanced diagnostics", "Declared video bitrate"), .some(nil))
    }

    func testSoftwareRouteReportsItsOwnMeasurements() {
        var s = nativeHD
        s.route = .software
        s.forwardBufferSeconds = nil
        s.avSyncOffsetMilliseconds = nil
        s.decodedVideoQueueSeconds = 0.42
        s.lateFrameDelaySeconds = 0.08
        s.displayedFrameRate = 49.96
        let stats = LiveTVWatchStats.make(s)
        XCTAssertEqual(value(stats, "Buffer health", "Buffer ahead"), .some(nil))
        XCTAssertEqual(value(stats, "Buffer health", "Video buffer"), "0.42 s")
        XCTAssertEqual(value(stats, "Advanced diagnostics", "Late-frame delay"), "0.08 s")
        XCTAssertEqual(value(stats, "Advanced diagnostics", "A/V offset"), .some(nil))
        XCTAssertEqual(value(stats, "Video", "Displayed frame rate"), "49.96 fps")
        XCTAssertEqual(value(stats, "Advanced diagnostics", "Playback route"), "Software decode")
    }

    func testDroppedFramesAndLateFrameDelayRemainDistinctMeasurements() {
        var s = nativeHD
        s.droppedFrames = 3
        s.lateFrameDelaySeconds = 0.12
        let stats = LiveTVWatchStats.make(s)
        XCTAssertEqual(value(stats, "Buffer health", "Dropped frames"), "3")
        XCTAssertEqual(value(stats, "Advanced diagnostics", "Late-frame delay"), "0.12 s")
        XCTAssertTrue(stats.sections.flatMap(\.rows).contains { $0.label == "Dropped frames" })
        XCTAssertFalse(stats.sections.flatMap(\.rows).contains { $0.label == "Late-frame count" })
    }

    func testZeroAndNonFiniteReadingsAreNotShownAsMeasurements() {
        var s = nativeHD
        s.playedBitrateBps = 0
        s.forwardBufferSeconds = .nan
        s.declaredFrameRate = 0
        let stats = LiveTVWatchStats.make(s)
        XCTAssertEqual(value(stats, "Video", "Bitrate"), .some(nil))
        XCTAssertEqual(value(stats, "Buffer health", "Buffer ahead"), .some(nil))
        XCTAssertEqual(value(stats, "Video", "Frame rate"), .some(nil))
    }

    func testBadgesComeOnlyFromDetectedProperties() {
        XCTAssertEqual(LiveTVQualityBadge.detected(in: nativeHD).map(\.text), ["FHD", "50 fps"])

        var uhd = nativeHD
        uhd.width = 3840
        uhd.height = 2160
        uhd.declaredFrameRate = 59.94
        uhd.dynamicRange = .hlg
        uhd.audioChannels = 6
        XCTAssertEqual(LiveTVQualityBadge.detected(in: uhd).map(\.text), ["4K", "60 fps", "HLG", "5.1"])

        var sd = nativeHD
        sd.width = 720
        sd.height = 576
        sd.declaredFrameRate = 25
        XCTAssertEqual(LiveTVQualityBadge.detected(in: sd).map(\.text), ["SD"], "25 fps is not called out")

        var unknown = LiveTVStatsSample()
        unknown.route = .loopbackHLS
        XCTAssertTrue(LiveTVQualityBadge.detected(in: unknown).isEmpty)
        XCTAssertTrue(LiveTVQualityBadge.detected(in: Optional<LiveTVStatsSample>.none).isEmpty)
    }

    func testDetailsQualityMetadataCanUpdateWithoutStatsSampling() {
        let metadata = LiveTVQualityMetadata(
            route: .loopbackHLS, width: 1920, height: 1080, declaredFrameRate: 29.97)
        XCTAssertEqual(LiveTVQualityBadge.detected(in: metadata).map(\.text), ["FHD"])
        XCTAssertTrue(
            LiveTVQualityBadge.detected(in: LiveTVQualityMetadata(route: .loopbackHLS)).isEmpty,
            "unknown dimensions must not create a guessed badge")
    }

    func testESPNMetadataProducesFullHDAndSixtyFPSBadgesWithoutStats() {
        let metadata = LiveTVQualityMetadata(
            route: .loopbackHLS, width: 1920, height: 1080, declaredFrameRate: 59.94)

        XCTAssertEqual(LiveTVQualityBadge.detected(in: metadata).map(\.text), ["FHD", "60 fps"])
    }

    func testQualityStateSurvivesDiagnosticsPanelAndFencesChannelChanges() {
        var state = LiveTVWatchQualityState(channelID: "a")
        let first = LiveTVQualityMetadata(route: .loopbackHLS, width: 1920, height: 1080)
        state.update(for: "a", metadata: first)
        XCTAssertEqual(state.badges.map(\.text), ["FHD"])

        // Details remains populated while the diagnostics panel opens and closes.
        XCTAssertEqual(state.badges.map(\.text), ["FHD"])

        state.reset(for: "b")
        XCTAssertTrue(state.badges.isEmpty, "retuning clears the previous channel immediately")
        state.update(for: "a", metadata: LiveTVQualityMetadata(route: .loopbackHLS, width: 3840, height: 2160))
        XCTAssertTrue(state.badges.isEmpty, "late metadata from the old channel is ignored")
        state.update(for: "b", metadata: LiveTVQualityMetadata(route: .loopbackHLS, width: 1280, height: 720))
        XCTAssertEqual(state.badges.map(\.text), ["HD"])
    }

    func testQualityClassificationIncludesHDRAndAudioCapabilitiesWithoutTelemetry() {
        let metadata = LiveTVQualityMetadata(
            route: .software, width: 3840, height: 2160, declaredFrameRate: 59.94,
            dynamicRange: .dolbyVision, audioChannels: 8, isAtmos: false)
        XCTAssertEqual(LiveTVQualityBadge.detected(in: metadata).map(\.text), ["4K", "60 fps", "Dolby Vision", "7.1"])
    }

    func testLetterboxedAndAnamorphicPicturesClassByDisplayedSize() {
        var wide = nativeHD
        wide.height = 800
        XCTAssertEqual(LiveTVQualityBadge.detected(in: wide).first?.text, "FHD")

        var anamorphic = nativeHD
        anamorphic.width = 1440
        anamorphic.pixelAspectRatio = 4.0 / 3.0
        let stats = LiveTVWatchStats.make(anamorphic)
        XCTAssertEqual(value(stats, "Video", "Resolution"), "1440×1080 (shown 1920×1080)")
        XCTAssertEqual(LiveTVQualityBadge.detected(in: anamorphic).first?.text, "FHD")
    }

    func testAudioOnlyStreamSaysSoInsteadOfListingVideoGaps() {
        var s = nativeHD
        s.route = .audioOnly
        let stats = LiveTVWatchStats.make(s)
        XCTAssertEqual(stats.sections.first?.rows.map(\.label), ["Video", "Bitrate"])
        XCTAssertEqual(value(stats, "Video", "Video"), "None (audio only)")
        XCTAssertTrue(stats.badges.isEmpty, "no video badges for an audio-only stream")
    }

    func testLiveTVControlsExposeOnlySupportedRouteCapabilities() {
        XCTAssertTrue(LiveTVPlayerControlCapabilities.canSelectAudio(route: .loopbackHLS, trackCount: 2))
        XCTAssertFalse(LiveTVPlayerControlCapabilities.canSelectAudio(route: .remoteHLS, trackCount: 2),
                       "remote HLS audio selection belongs to AVFoundation and Aether ignores local picks")
        XCTAssertFalse(LiveTVPlayerControlCapabilities.canSelectAudio(route: .loopbackHLS, trackCount: 1))
        XCTAssertTrue(LiveTVPlayerControlCapabilities.canSelectSubtitles(route: .remoteHLS, trackCount: 1))
        XCTAssertFalse(LiveTVPlayerControlCapabilities.canSelectSubtitles(route: .loopbackHLS, trackCount: 0))
        XCTAssertTrue(LiveTVPlayerControlCapabilities.canChangeAspect(route: .software))
        XCTAssertFalse(LiveTVPlayerControlCapabilities.canChangeAspect(route: .audioOnly))
        XCTAssertFalse(LiveTVPlayerControlCapabilities.canRouteOutput(route: .none))
        XCTAssertTrue(LiveTVPlayerControlCapabilities.canShowStreamInformation(route: .remoteHLS))
        XCTAssertTrue(LiveTVPlayerControlCapabilities.canShowStreamInformation(route: .audioOnly))
        XCTAssertFalse(LiveTVPlayerControlCapabilities.canShowStreamInformation(route: .none))
    }
}
