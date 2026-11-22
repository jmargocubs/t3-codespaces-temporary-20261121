#if os(iOS)
import SwiftUI

struct DiagnosticsSettingsView: View {
    @Bindable var model: DiagnosticsViewModel
    let profile: UserProfile?

    var body: some View {
        List {
            availabilitySection
            loggingSection
            pendingSection
            manualSection
            sentHistorySection
        }
        .settingsListChrome()
        .navigationTitle("Diagnostics")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
        .task {
            await model.load(profile: profile)
        }
    }

    private var availabilitySection: some View {
        Section {
            LabeledContent("Status", value: model.featureState.title)
            LabeledContent("Destination", value: model.destinationServerName)
        } header: {
            Text("Feature State")
        } footer: {
            if model.featureState == .offline {
                Text("Showing the last known diagnostics state. Reports stay on this device while the server is offline.")
            }
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private var loggingSection: some View {
        Section {
            Toggle("Debug Logging", isOn: $model.debugLoggingEnabled)
                .tint(.siloSwitchOn)
        } footer: {
            Text("Technical logging is stored on this device. Crash-report consent and sharing destination are managed under Privacy.")
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private var pendingSection: some View {
        Section {
            if model.pendingReports.isEmpty {
                Text("No pending reports")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.pendingReports) { report in
                    NavigationLink {
                        DiagnosticsReportDetailView(report: report, model: model)
                    } label: {
                        DiagnosticsPendingReportRow(report: report)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            Task { await model.delete(report) }
                        }
                    }
                }
            }
        } header: {
            Text("Pending Reports (\(model.pendingReports.count))")
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private var manualSection: some View {
        Section {
            Button("Send Diagnostics Now", systemImage: "paperplane.fill") {
                Task { await model.createAndSendManualReport() }
            }
            .disabled(!model.featureState.isUploadAvailable || model.isWorking)

            if !model.debugLoggingEnabled {
                Label(
                    "Debug logging is off. This report contains only the last few minutes of basic logs.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }

            if model.isWorking {
                ProgressView("Preparing diagnostics…")
            }

            if let notice = model.notice {
                Text(notice.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } footer: {
            if model.selectedDestination == .hosted {
                Text("A hosted report includes device capability details and recent redacted diagnostic logs. It omits account, profile, server address, and playback session identifiers.")
            } else {
                Text("A manual report includes device capability details, recent playback session identifiers, and recent diagnostic logs for this server.")
            }
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private var sentHistorySection: some View {
        Section("Sent History") {
            if model.sentHistory.isEmpty {
                Text("No reports sent yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.sentHistory) { item in
                    LabeledContent {
                        Text(item.sentAtDate ?? .distantPast, format: .dateTime.month().day().hour().minute())
                            .foregroundStyle(.secondary)
                    } label: {
                        Text(item.shortID)
                            .textSelection(.enabled)
                    }
                    .contextMenu {
                        Button("Copy ID", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = item.shortID
                        }
                    }
                }
            }
        }
        .listRowBackground(Color.siloGroupedCell)
    }

}

private extension DiagnosticsSentReport {
    var sentAtDate: Date? {
        DiagnosticsDates.date(from: sentAt)
    }
}
#endif
