#if os(iOS) && KYRO_INTERNAL_EPG_STORAGE_TOGGLE
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// INTERNAL TEST builds only. Holds the latest Sports Match Report in memory on this device until
/// it is discarded, replaced by the next report or the app quits. Nothing is written to disk or
/// sent anywhere; the viewer exports it explicitly with the share sheet.
@MainActor
@Observable
final class KyroSportsMatchReportStore {
    static let shared = KyroSportsMatchReportStore()

    private(set) var latest: KyroSportsMatchReport?
    private(set) var isBuilding = false
    private(set) var didFail = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    func create(for game: KyroSportsGame, service: LiveTVService) {
        task?.cancel()
        generation &+= 1
        let token = generation
        isBuilding = true
        didFail = false
        task = Task { [weak self] in
            let report = await service.sportsMatchReport(for: game)
            guard let self, token == self.generation, !Task.isCancelled else { return }
            self.isBuilding = false
            if let report { self.latest = report } else { self.didFail = true }
        }
    }

    func discard() {
        task?.cancel()
        generation &+= 1
        latest = nil
        isBuilding = false
        didFail = false
    }
}

extension KyroSportsMatchReport: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { report in try report.jsonData() }
            .suggestedFileName("Kyro-Sports-Match-Report.json")
    }
}

/// The report controls for one event, where the stream picker and Other Streams place them. They
/// appear only after a developer turns Sports diagnostics on in Live TV Settings.
struct KyroSportsMatchReportSlot: View {
    let game: KyroSportsGame
    @AppStorage(KyroSportsDiagnosticsVisibility.defaultsKey) private var isEnabled = false

    var body: some View {
        if KyroSportsDiagnosticsVisibility.showsMatchReport(
            isCompiledIn: KyroSportsDiagnosticsVisibility.isCompiledIn, isEnabled: isEnabled) {
            KyroSportsMatchReportSection(game: game)
        }
    }
}

/// The report controls for one event.
struct KyroSportsMatchReportSection: View {
    let game: KyroSportsGame
    private let store = KyroSportsMatchReportStore.shared

    var body: some View {
        Section {
            if let report = store.latest, report.event.id == game.id.description {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Accepted \(report.summary.accepted) · initial \(report.summary.initial) · more \(report.summary.overflow) · rejected \(report.summary.rejected)")
                    Text("Guide \(report.guide.storageMode): \(report.guide.strongPassRows)+\(report.guide.weakPassRows) of \(report.guide.rowBudget) rows\(report.guide.truncated ? ", truncated" : "")")
                    Text("Autoplay candidates \(report.summary.autoPlayCandidates) · network channels \(report.summary.networkChannels)")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(KyroTheme.textSecondary)
                ShareLink(item: report, preview: SharePreview("Kyro Sports Match Report")) {
                    Label("Export Report", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("kyroSportsMatchReportExport")
                Button("Discard Report", role: .destructive) { store.discard() }
            }
            if store.isBuilding {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Building report…").foregroundStyle(KyroTheme.textSecondary)
                }
            } else {
                Button("Create Sports Match Report") { store.create(for: game, service: .shared) }
                    .accessibilityIdentifier("kyroSportsMatchReportCreate")
                if store.didFail {
                    Text("The report couldn't be built. Make sure Live TV has finished loading, then try again.")
                        .font(.caption).foregroundStyle(KyroTheme.textSecondary)
                }
            }
        } header: {
            Text("INTERNAL TEST — Sports Match Report")
        } footer: {
            Text("Lists channel names, groups and guide titles with match reasons. It never includes stream or provider addresses or sign-in details, and stays on this iPhone until you export it.")
        }
        .listRowBackground(Color.white.opacity(0.05))
    }
}
#endif
