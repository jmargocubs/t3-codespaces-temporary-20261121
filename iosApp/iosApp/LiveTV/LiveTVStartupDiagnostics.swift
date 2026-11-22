import Foundation
import OSLog

struct PlaybackDiagnosticRecord: Codable, Identifiable, Sendable {
    enum Outcome: String, Codable { case completed, failed, incomplete }
    let id: UUID
    let date: Date
    let tapToRequestMS: Double?
    let requestToReadyMS: Double?
    let totalMS: Double?
    let backend: String
    let engine: String
    let outcome: Outcome
}

struct RuntimeAudioDiagnosticEvent: Codable, Sendable, Equatable {
    let elapsedMS: Int
    let name: String
    let value: String
}

struct RuntimeAudioDiagnosticRecord: Codable, Identifiable, Sendable {
    enum Assessment: String, Codable, Sendable {
        case confirmedVideoOnlyDemotion, suspectedAudioPipelineIssue, insufficientTelemetry, noDetectedPipelineFailure
    }
    var id: UUID { sessionID }
    let sessionID: UUID
    let generation: Int
    let date: Date
    let route: String
    var phase: String
    var audioDelivery: String
    var decoder: String
    var selectedTrack: Int?
    var trackCount: Int
    var assessment: Assessment
    var ended: Bool
    var events: [RuntimeAudioDiagnosticEvent]
}

/// Pure bounded event accumulator, fed only by Aether's published values and system notifications.
struct RuntimeAudioDiagnosticSession: Sendable {
    private(set) var record: RuntimeAudioDiagnosticRecord
    private let startedAt: Double
    private var priorSnapshot: Snapshot?
    private let eventLimit = 80

    struct Snapshot: Equatable, Sendable {
        let phase: String
        let delivery: String
        let decoder: String?
        let selectedTrack: Int?
        let trackCount: Int
    }

    init(sessionID: UUID, generation: Int, route: String, startedAt: Double, initial: Snapshot) {
        self.startedAt = startedAt
        record = RuntimeAudioDiagnosticRecord(sessionID: sessionID, generation: generation, date: Date(), route: route,
            phase: initial.phase, audioDelivery: initial.delivery, decoder: initial.decoder ?? "unavailable",
            selectedTrack: initial.selectedTrack, trackCount: initial.trackCount,
            assessment: initial.delivery == "playerManaged" ? .insufficientTelemetry : .noDetectedPipelineFailure,
            ended: false, events: [])
        observe(initial, now: startedAt)
    }

    @discardableResult
    mutating func observe(_ snapshot: Snapshot, now: Double) -> Bool {
        guard !record.ended else { return false }
        if priorSnapshot == snapshot { return false }
        if let priorSnapshot {
            if snapshot.phase != priorSnapshot.phase { add("phase", snapshot.phase, now) }
            if snapshot.delivery != priorSnapshot.delivery {
                add("audio_delivery", snapshot.delivery, now)
                if snapshot.delivery == "droppedNoPipeline" { record.assessment = .confirmedVideoOnlyDemotion }
                else if snapshot.delivery == "playerManaged" { record.assessment = .insufficientTelemetry }
            }
            if snapshot.decoder != priorSnapshot.decoder {
                add("audio_decoder", snapshot.decoder ?? "unavailable", now)
                if snapshot.decoder == nil && snapshot.delivery != "playerManaged" && record.assessment != .confirmedVideoOnlyDemotion {
                    record.assessment = .suspectedAudioPipelineIssue
                }
            }
            if snapshot.selectedTrack != priorSnapshot.selectedTrack { add("selected_track", snapshot.selectedTrack.map(String.init) ?? "none", now) }
            if snapshot.trackCount != priorSnapshot.trackCount { add("track_count", String(snapshot.trackCount), now) }
        }
        record.phase = snapshot.phase; record.audioDelivery = snapshot.delivery; record.decoder = snapshot.decoder ?? "unavailable"
        record.selectedTrack = snapshot.selectedTrack; record.trackCount = snapshot.trackCount
        if snapshot.delivery == "playerManaged" && record.assessment != .confirmedVideoOnlyDemotion { record.assessment = .insufficientTelemetry }
        priorSnapshot = snapshot
        return true
    }

    mutating func systemEvent(_ name: String, value: String, now: Double) {
        guard !record.ended else { return }; add(name, value, now)
    }

    mutating func end(phase: String, now: Double) {
        guard !record.ended else { return }
        if phase != record.phase { add("phase", phase, now) }
        add("playback_ended_or_replaced", phase, now)
        record.phase = phase; record.ended = true
    }

    private mutating func add(_ name: String, _ value: String, _ now: Double) {
        record.events.append(.init(elapsedMS: max(0, Int((now - startedAt) * 1_000)), name: name, value: value))
        if record.events.count > eventLimit { record.events.removeFirst(record.events.count - eventLimit) }
    }
}

/// Local-only bounded store. Writes are serialized off the playback/main thread.
final class PlaybackDiagnosticsStore: @unchecked Sendable {
    static let shared = PlaybackDiagnosticsStore()
    private let queue = DispatchQueue(label: "com.cubbiestream.kyro.playback-diagnostics")
    private let key: String
    private let runtimeKey: String
    private let defaults: UserDefaults
    static var isLocalRecordingAvailableInRelease: Bool { true }
    static var writesAreAsynchronous: Bool { true }
    init(defaults: UserDefaults = .standard, key: String = "playback-diagnostics-v1", runtimeKey: String = "playback-audio-diagnostics-v1") {
        self.defaults = defaults
        self.key = key
        self.runtimeKey = runtimeKey
    }
    func append(_ record: PlaybackDiagnosticRecord) {
        queue.async { [defaults, key] in
            var records = (try? JSONDecoder().decode([PlaybackDiagnosticRecord].self, from: defaults.data(forKey: key) ?? Data())) ?? []
            if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
            else { records.append(record) }
            if records.count > 100 { records.removeFirst(records.count - 100) }
            if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: key) }
        }
    }
    func read() -> [PlaybackDiagnosticRecord] {
        queue.sync { (try? JSONDecoder().decode([PlaybackDiagnosticRecord].self, from: defaults.data(forKey: key) ?? Data())) ?? [] }
    }
    func appendRuntime(_ record: RuntimeAudioDiagnosticRecord) {
        queue.async { [defaults, runtimeKey] in
            var records = (try? JSONDecoder().decode([RuntimeAudioDiagnosticRecord].self, from: defaults.data(forKey: runtimeKey) ?? Data())) ?? []
            if let index = records.firstIndex(where: { $0.sessionID == record.sessionID }) { records[index] = record }
            else { records.append(record) }
            if records.count > 100 { records.removeFirst(records.count - 100) }
            if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: runtimeKey) }
        }
    }
    func readRuntime() -> [RuntimeAudioDiagnosticRecord] {
        queue.sync { (try? JSONDecoder().decode([RuntimeAudioDiagnosticRecord].self, from: defaults.data(forKey: runtimeKey) ?? Data())) ?? [] }
    }
    func clear() { queue.async { [defaults, key, runtimeKey] in defaults.removeObject(forKey: key); defaults.removeObject(forKey: runtimeKey) } }
    func flush() { queue.sync {} }
    static func export(_ records: [PlaybackDiagnosticRecord], runtime: [RuntimeAudioDiagnosticRecord] = []) -> String {
        let startup = records.reversed().map { "\($0.date.ISO8601Format()) outcome=\($0.outcome.rawValue) total_ms=\($0.totalMS.map { String(format: "%.0f", $0) } ?? "n/a") tap_to_request_ms=\($0.tapToRequestMS.map { String(format: "%.0f", $0) } ?? "n/a") request_to_ready_ms=\($0.requestToReadyMS.map { String(format: "%.0f", $0) } ?? "n/a") backend=\($0.backend) engine=\($0.engine)" }
        let audio = runtime.reversed().map { record in
            let events = record.events.map { "+\($0.elapsedMS)ms \($0.name)=\($0.value)" }.joined(separator: ";")
            return "\(record.date.ISO8601Format()) runtime_audio session=\(record.sessionID.uuidString) generation=\(record.generation) route=\(record.route) phase=\(record.phase) delivery=\(record.audioDelivery) decoder=\(record.decoder) selected_track=\(record.selectedTrack.map(String.init) ?? "none") track_count=\(record.trackCount) assessment=\(record.assessment.rawValue) ended=\(record.ended) events=[\(events)]"
        }
        return (startup + audio).joined(separator: "\n")
    }
}

/// Privacy-safe timestamps for comparing the Live TV selection path with Release optimization.
/// Stream URLs, provider IDs, and raw channel IDs are deliberately never logged.
///
/// NOTE: `playing_motion_ready` is recorded when the playback engine reports state == .playing.
/// This indicates playing motion is active; it is NOT an exact hardware-rendered first-frame callback.
final class LiveTVStartupTrace: @unchecked Sendable {
    let id = UUID()
    let backend: String
    let startedAt: Double

    init(channelID: String, backend: String? = nil, store: PlaybackDiagnosticsStore = .shared) {
        _ = channelID // Caller uses it only to correlate a selection in memory; it is never retained.
        self.backend = backend ?? (EPGStorageMode.current() == .sqlite ? "sqlite" : "memory")
        self.store = store
        startedAt = ProcessInfo.processInfo.systemUptime
        requestAt = nil
        store.append(makeRecord(.incomplete))
    }
    private(set) var requestAt: Double?
    private(set) var readyAt: Double?
    private(set) var finished = false
    private(set) var engine = "unknown"
    private let lock = NSRecursiveLock()
    private let store: PlaybackDiagnosticsStore

    func record(_ event: String, detail: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if event == "player_initialization_requested" { requestAt = ProcessInfo.processInfo.systemUptime }
        if event == "player_engine_ready" { engine = detail == "engine_warm" ? "warm" : "cold" }
        if event == "playing_motion_ready" { readyAt = ProcessInfo.processInfo.systemUptime; finish(.completed) }
        if event == "player_engine_initialization_failed" || event == "playback_failed" || event == "player_request_rejected_other_video_active" { finish(.failed) }
#if DEBUG || KYRO_LIVETV_STARTUP_DIAGNOSTICS
        let elapsed = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        if let detail {
            Self.logger.notice("event=\(event, privacy: .public) selection=\(self.id.uuidString, privacy: .public) backend=\(self.backend, privacy: .public) detail=\(detail, privacy: .public) elapsed_ms=\(elapsed, format: .fixed(precision: 1), privacy: .public)")
        } else {
            Self.logger.notice("event=\(event, privacy: .public) selection=\(self.id.uuidString, privacy: .public) backend=\(self.backend, privacy: .public) elapsed_ms=\(elapsed, format: .fixed(precision: 1), privacy: .public)")
        }
#endif
    }
    func finish(_ outcome: PlaybackDiagnosticRecord.Outcome) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }; finished = true
        store.append(makeRecord(outcome))
    }

    private func makeRecord(_ outcome: PlaybackDiagnosticRecord.Outcome) -> PlaybackDiagnosticRecord {
        let now = readyAt ?? ProcessInfo.processInfo.systemUptime
        let request = requestAt
        return .init(id: id, date: Date(),
            tapToRequestMS: request.map { max(0, ($0 - startedAt) * 1_000) },
            requestToReadyMS: outcome == .completed ? request.map { max(0, (now - $0) * 1_000) } : nil,
            totalMS: outcome == .completed ? max(0, (now - startedAt) * 1_000) : nil,
            backend: backend, engine: engine, outcome: outcome)
    }

    static func recordEPG(_ event: String, operationID: UUID, startedAt: Double, count: Int? = nil, backend: String? = nil) {
#if DEBUG || KYRO_LIVETV_STARTUP_DIAGNOSTICS
        let elapsed = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        let backendStr = backend ?? (EPGStorageMode.current() == .sqlite ? "sqlite" : "memory")
        if let count {
            logger.notice("event=epg_\(event, privacy: .public) operation=\(operationID.uuidString, privacy: .public) backend=\(backendStr, privacy: .public) count=\(count, privacy: .public) elapsed_ms=\(elapsed, format: .fixed(precision: 1), privacy: .public)")
        } else {
            logger.notice("event=epg_\(event, privacy: .public) operation=\(operationID.uuidString, privacy: .public) backend=\(backendStr, privacy: .public) elapsed_ms=\(elapsed, format: .fixed(precision: 1), privacy: .public)")
        }
#endif
    }

#if DEBUG || KYRO_LIVETV_STARTUP_DIAGNOSTICS
    private static let logger = Logger(subsystem: "com.cubbiestream.kyro", category: "LiveTVStartup")
#endif
}
