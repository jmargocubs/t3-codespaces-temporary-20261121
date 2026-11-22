#if os(iOS)
import SwiftUI
import UIKit

struct PlaybackHealthView: View {
    @State private var records = PlaybackDiagnosticsStore.shared.read()
    @State private var audioRecords = PlaybackDiagnosticsStore.shared.readRuntime()
    @State private var confirmClear = false
    @State private var copied = false
    private var completed: [PlaybackDiagnosticRecord] { records.filter { $0.outcome == .completed && $0.totalMS != nil } }
    private var median: Double? {
        let values = completed.compactMap(\.totalMS).sorted()
        guard !values.isEmpty else { return nil }
        return Self.medianValue(values)
    }
    var body: some View {
        List {
            Section("Summary") {
                LabeledContent("Median startup", value: median.map { Self.duration($0) } ?? "—")
                LabeledContent("Completed", value: "\(completed.count)")
                LabeledContent("Failed", value: "\(records.filter { $0.outcome == .failed }.count)")
                LabeledContent("Incomplete", value: "\(records.filter { $0.outcome == .incomplete }.count)")
                Text("Playing-ready means the playback engine reports playing. It is not an exact measurement of the first rendered frame.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Technical Details") {
                Text("EPG backend comparison")
                    .font(.headline)
                ForEach(["memory", "sqlite"], id: \.self) { backend in
                    let samples = completed.filter { $0.backend == backend }.compactMap(\.totalMS)
                    LabeledContent(backend.capitalized, value: samples.isEmpty ? "No completed starts" : "\(samples.count) starts · median \(Self.duration(Self.medianValue(samples.sorted())))")
                }
                ForEach(["cold", "warm", "unknown"], id: \.self) { engine in
                    LabeledContent("\(engine.capitalized) engine", value: "\(records.filter { $0.engine == engine }.count) attempts")
                }
                Text("Tap-to-request and request-to-playing-ready timings are shown per attempt. EPG refresh activity is not yet included because it is not reliably correlated to playback.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Recent Playback") {
                if records.isEmpty { Text("No playback history yet.").foregroundStyle(.secondary) }
                ForEach(records.reversed()) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(record.outcome.rawValue.capitalized); Spacer(); Text(record.totalMS.map(Self.duration) ?? "—") }
                        Text("\(record.date.formatted(date: .abbreviated, time: .shortened)) · \(record.backend) · \(record.engine) engine")
                            .font(.caption).foregroundStyle(.secondary)
                        if let request = record.tapToRequestMS, let ready = record.requestToReadyMS {
                            Text("Tap → request \(Self.duration(request)) · request → ready \(Self.duration(ready))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Runtime Audio Diagnostics") {
                Text("These observations describe the engine pipeline and iOS audio-session events. They cannot confirm that sound reached the speaker.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Transition times are relative to the engine's playing-ready phase, not the first audible sample.")
                    .font(.footnote).foregroundStyle(.secondary)
                if audioRecords.isEmpty {
                    Text("No runtime audio sessions recorded yet.").foregroundStyle(.secondary)
                }
                ForEach(audioRecords.reversed().prefix(10)) { audio in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(audio.assessment.displayName).font(.headline)
                            Spacer()
                            Text(audio.ended ? "Ended" : "No end event recorded")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(audio.date.formatted(date: .abbreviated, time: .shortened)) · \(audio.route) · generation \(audio.generation)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Delivery: \(audio.audioDelivery) · decoder: \(audio.decoder) · track: \(audio.selectedTrack.map(String.init) ?? "none") / \(audio.trackCount) · phase: \(audio.phase)")
                            .font(.caption)
                        if audio.events.isEmpty { Text("No audio-state transitions observed.").font(.caption2).foregroundStyle(.secondary) }
                        ForEach(Array(audio.events.suffix(8).enumerated()), id: \.offset) { _, event in
                            Text("+\(event.elapsedMS) ms · \(event.name): \(event.value)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
                Text("Audio bridge output-byte counters are not public in the pinned AetherEngine API, so this build cannot identify a stalled bridge counter. Native AVPlayer-managed audio also has no engine-side output counter.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button { UIPasteboard.general.string = PlaybackDiagnosticsStore.export(records, runtime: audioRecords); copied = true } label: {
                    Label(copied ? "Diagnostics Copied" : "Copy Diagnostics", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button("Clear History", role: .destructive) { confirmClear = true }
            }
        }
        .navigationTitle("Playback Health")
        .alert("Clear playback history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { PlaybackDiagnosticsStore.shared.clear(); records = []; audioRecords = [] }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes the locally stored playback startup records.") }
        .onAppear { records = PlaybackDiagnosticsStore.shared.read(); audioRecords = PlaybackDiagnosticsStore.shared.readRuntime() }
    }
    private static func duration(_ ms: Double) -> String { String(format: "%.2f s", ms / 1000) }
    private static func medianValue(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

private extension RuntimeAudioDiagnosticRecord.Assessment {
    var displayName: String {
        switch self {
        case .confirmedVideoOnlyDemotion: "Confirmed engine video-only demotion"
        case .suspectedAudioPipelineIssue: "Possible audio pipeline issue"
        case .insufficientTelemetry: "Insufficient audio telemetry"
        case .noDetectedPipelineFailure: "No detected pipeline failure"
        }
    }
}
#endif
