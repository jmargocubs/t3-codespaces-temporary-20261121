import XCTest
@testable import Silo

final class PlaybackDiagnosticsTests: XCTestCase {
    private func makeStore(_ label: String = #function) -> (PlaybackDiagnosticsStore, UserDefaults) {
        let name = "PlaybackDiagnosticsTests-\(label)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (PlaybackDiagnosticsStore(defaults: defaults, key: "records", runtimeKey: "runtime"), defaults)
    }

    func testSuccessCapturesMonotonicTimingsAndCorrelationIDOnce() {
        let (store, _) = makeStore()
        let trace = LiveTVStartupTrace(channelID: "private-channel-name", backend: "sqlite", store: store)
        trace.record("player_initialization_requested")
        trace.record("player_engine_ready", detail: "engine_cold_initialized")
        trace.record("playing_motion_ready")
        trace.record("playing_motion_ready")
        store.flush()
        let record = store.read().first
        XCTAssertEqual(store.read().count, 1)
        XCTAssertEqual(record?.id, trace.id)
        XCTAssertEqual(record?.outcome, .completed)
        XCTAssertEqual(record?.backend, "sqlite")
        XCTAssertEqual(record?.engine, "cold")
        XCTAssertGreaterThanOrEqual(record?.tapToRequestMS ?? -1, 0)
        XCTAssertGreaterThanOrEqual(record?.requestToReadyMS ?? -1, 0)
        XCTAssertGreaterThanOrEqual(record?.totalMS ?? -1, 0)
    }

    func testFailedAndIncompleteAttemptsRetainLabelsAndNoSuccessfulDuration() {
        let (store, _) = makeStore()
        let failed = LiveTVStartupTrace(channelID: "a", backend: "memory", store: store)
        failed.record("player_initialization_requested")
        failed.record("playback_failed")
        failed.record("playback_failed")
        let incomplete = LiveTVStartupTrace(channelID: "b", backend: "sqlite", store: store)
        incomplete.record("player_engine_ready", detail: "engine_warm")
        incomplete.finish(.incomplete)
        store.flush()
        let records = store.read()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first(where: { $0.id == failed.id })?.outcome, .failed)
        XCTAssertNil(records.first(where: { $0.id == failed.id })?.totalMS)
        XCTAssertEqual(records.first(where: { $0.id == incomplete.id })?.outcome, .incomplete)
        XCTAssertEqual(records.first(where: { $0.id == incomplete.id })?.engine, "warm")
    }

    func testRetentionPersistenceRecreationAndClear() {
        let (store, defaults) = makeStore()
        for index in 0..<105 {
            store.append(.init(id: UUID(), date: Date(timeIntervalSince1970: TimeInterval(index)),
                               tapToRequestMS: nil, requestToReadyMS: nil, totalMS: nil,
                               backend: index.isMultiple(of: 2) ? "memory" : "sqlite",
                               engine: index.isMultiple(of: 2) ? "cold" : "warm", outcome: .failed))
        }
        store.flush()
        XCTAssertEqual(store.read().count, 100)
        let recreated = PlaybackDiagnosticsStore(defaults: defaults, key: "records")
        XCTAssertEqual(recreated.read().count, 100)
        recreated.clear(); recreated.flush()
        XCTAssertTrue(recreated.read().isEmpty)
    }

    func testExportOmitsChannelProviderAndURLData() {
        let record = PlaybackDiagnosticRecord(id: UUID(), date: Date(timeIntervalSince1970: 0),
            tapToRequestMS: 2, requestToReadyMS: 3, totalMS: 5, backend: "memory", engine: "warm", outcome: .completed)
        let export = PlaybackDiagnosticsStore.export([record])
        XCTAssertTrue(export.contains("backend=memory"))
        XCTAssertFalse(export.contains("private-channel-name"))
        XCTAssertFalse(export.contains("http://"))
        XCTAssertFalse(export.contains("providerID"))
    }

    func testRecorderIsAvailableOutsideDebugAndWritesAsynchronously() {
        XCTAssertTrue(PlaybackDiagnosticsStore.isLocalRecordingAvailableInRelease)
        XCTAssertTrue(PlaybackDiagnosticsStore.writesAreAsynchronous)
    }

    func testRuntimeNormalProgressionAndConfirmedVideoOnlyDemotion() {
        let start = ProcessInfo.processInfo.systemUptime
        var session = RuntimeAudioDiagnosticSession(sessionID: UUID(), generation: 4, route: "hls", startedAt: start,
            initial: .init(phase: "playing", delivery: "bridged", decoder: "AAC bridge", selectedTrack: 2, trackCount: 3))
        session.observe(.init(phase: "playing", delivery: "droppedNoPipeline", decoder: nil, selectedTrack: nil, trackCount: 0), now: start + 2.5)
        XCTAssertEqual(session.record.assessment, .confirmedVideoOnlyDemotion)
        XCTAssertEqual(session.record.audioDelivery, "droppedNoPipeline")
        XCTAssertTrue(session.record.events.contains(where: { $0.name == "audio_delivery" && $0.value == "droppedNoPipeline" }))
        XCTAssertTrue(session.record.events.contains(where: { $0.name == "audio_decoder" && $0.value == "unavailable" }))
    }

    func testRuntimeDecoderTrackAndSystemTransitionsAreBounded() {
        let start = ProcessInfo.processInfo.systemUptime
        var session = RuntimeAudioDiagnosticSession(sessionID: UUID(), generation: 1, route: "transport_stream", startedAt: start,
            initial: .init(phase: "playing", delivery: "decoded", decoder: "AAC", selectedTrack: 0, trackCount: 1))
        session.observe(.init(phase: "playing", delivery: "decoded", decoder: "AAC", selectedTrack: 1, trackCount: 2), now: start + 1)
        XCTAssertTrue(session.record.events.contains(where: { $0.name == "selected_track" && $0.value == "1" }))
        XCTAssertTrue(session.record.events.contains(where: { $0.name == "track_count" && $0.value == "2" }))
        for index in 0..<100 { session.systemEvent("audio_route_change", value: String(index), now: start + Double(index)) }
        XCTAssertEqual(session.record.events.count, 80)
        XCTAssertEqual(session.record.events.last?.value, "99")
    }

    func testNativePlayerManagedHasInsufficientTelemetryAndNoBridgeStallClaim() {
        let start = ProcessInfo.processInfo.systemUptime
        let session = RuntimeAudioDiagnosticSession(sessionID: UUID(), generation: 8, route: "hls", startedAt: start,
            initial: .init(phase: "playing", delivery: "playerManaged", decoder: "AVPlayer", selectedTrack: 0, trackCount: 1))
        XCTAssertEqual(session.record.assessment, .insufficientTelemetry)
        XCTAssertFalse(session.record.events.contains(where: { $0.name.contains("bridge") || $0.name.contains("stall") }))
    }

    func testRuntimeExportContainsOnlyDiagnosticFields() {
        let start = ProcessInfo.processInfo.systemUptime
        var session = RuntimeAudioDiagnosticSession(sessionID: UUID(), generation: 7, route: "hls", startedAt: start,
            initial: .init(phase: "playing", delivery: "decoded", decoder: "AAC decoder", selectedTrack: 0, trackCount: 1))
        session.systemEvent("audio_route_change", value: "2", now: start + 1)
        let export = PlaybackDiagnosticsStore.export([], runtime: [session.record])
        XCTAssertTrue(export.contains("runtime_audio"))
        XCTAssertTrue(export.contains("audio_route_change=2"))
        XCTAssertFalse(export.contains("https://"))
        XCTAssertFalse(export.contains("authorization"))
        XCTAssertFalse(export.contains("provider"))
        XCTAssertFalse(export.contains("channel name"))
    }

    func testRuntimeGenerationEndPersistenceRetentionAndClear() {
        let (store, _) = makeStore()
        for index in 0..<105 {
            let session = RuntimeAudioDiagnosticSession(sessionID: UUID(), generation: index, route: "hls", startedAt: 1,
                initial: .init(phase: "playing", delivery: "playerManaged", decoder: nil, selectedTrack: nil, trackCount: 0))
            store.appendRuntime(session.record)
        }
        store.flush()
        XCTAssertEqual(store.readRuntime().count, 100)
        XCTAssertEqual(store.readRuntime().last?.generation, 104)
        var ending = RuntimeAudioDiagnosticSession(sessionID: UUID(), generation: 106, route: "hls", startedAt: 1,
            initial: .init(phase: "playing", delivery: "decoded", decoder: "AAC", selectedTrack: 0, trackCount: 1))
        ending.end(phase: "replaced", now: 2)
        XCTAssertTrue(ending.record.ended)
        XCTAssertEqual(ending.record.events.last?.name, "playback_ended_or_replaced")
        store.clear(); store.flush()
        XCTAssertTrue(store.readRuntime().isEmpty)
        XCTAssertTrue(store.read().isEmpty)
    }
}
