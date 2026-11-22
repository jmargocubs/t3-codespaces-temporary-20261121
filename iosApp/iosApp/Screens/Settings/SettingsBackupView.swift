#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsBackupFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [SettingsBackupFileType.exportType, .json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct SettingsBackupView: View {
    @State private var model: SettingsBackupModel
    @State private var exportDocument: SettingsBackupFileDocument?
    @State private var showsExporter = false
    @State private var showsPaste = false
    @State private var showsOptions = false
    @State private var showsReview = false
    @State private var confirmsUndo = false
    @State private var filePicker = SettingsBackupFilePicker()

    init() {
        let info = Bundle.main.infoDictionary
        _model = State(initialValue: SettingsBackupModel(
            registry: SettingsBackupLiveRegistry.standard(),
            journal: FileRestoreJournalStore.standard(),
            app: SettingsBackupAppInfo(
                version: info?["CFBundleShortVersionString"] as? String ?? "",
                build: info?["CFBundleVersion"] as? String ?? "",
                platform: "iOS", idiom: SettingsBackupLiveRegistry.currentIdiom),
            remote: SettingsBackupRemoteAdapter(
                transport: SiloSettingsBackupTransport(), journal: FileRemoteBackupJournal.standard())))
    }

    var body: some View {
        List {
            if let banner = model.banner {
                Section {
                    Label(banner.text, systemImage: banner.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(banner.kind == .success ? Color.green : Color.orange)
                }
                .listRowBackground(Color.siloGroupedCell)
            }
            if model.needsRecovery {
                Section {
                    Button("Roll Back Interrupted Restore") { Task { await model.recoverUnified() } }
                        .disabled(model.isBusy)
                } footer: {
                    Text("A restore didn't finish. Roll it back before importing another backup.")
                }
                .listRowBackground(Color.siloGroupedCell)
            }
            backupSection
            restoreSection
            if model.undoAvailable && !model.needsRecovery { undoSection }
        }
        .settingsListChrome()
        .navigationTitle("Backup & Restore")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
        .fileExporter(isPresented: $showsExporter, document: exportDocument,
                      contentType: SettingsBackupFileType.exportType, defaultFilename: model.exportFilename) { result in
            switch result {
            case .success: model.didExport(success: true)
            case .failure(let error): model.didExport(success: false, message: error.localizedDescription)
            }
            exportDocument = nil
        }
        // Build 92's UIKit picker is intentionally retained.
        .sheet(isPresented: $showsPaste) { SettingsBackupPasteView(model: model) }
        .navigationDestination(isPresented: $showsReview) { SettingsBackupReviewScreen(model: model) }
        .confirmationDialog("Undo last restore?", isPresented: $confirmsUndo, titleVisibility: .visible) {
            Button("Undo Last Restore") { Task { await model.undoUnified() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Earlier values will be restored. Settings you changed since the restore will stay as they are.")
        }
        .onChange(of: model.preview != nil) { _, ready in
            if ready && !showsPaste { showsReview = true }
        }
        .onChange(of: showsPaste) { _, showing in
            if !showing && model.preview != nil { showsReview = true }
        }
        .onAppear { model.refreshRestorePointState() }
    }

    private var backupSection: some View {
        Section {
            Button {
                Task {
                    if let data = await model.exportUnifiedDocument() {
                        exportDocument = SettingsBackupFileDocument(data: data)
                        showsExporter = true
                    }
                }
            } label: {
                Label("Create Backup", systemImage: "square.and.arrow.up")
            }
            .disabled(model.exportSelection.isEmpty || model.isBusy)
            .accessibilityIdentifier("settingsBackup.export")

            DisclosureGroup("Choose what to include", isExpanded: $showsOptions) {
                ForEach(model.availablePortableGroups) { group in exportToggle(group) }
                Text("Synced settings require the same verified server and profile on the destination. They are read from the server; an offline export fails rather than using cached values.")
                    .font(.footnote).foregroundStyle(Color.siloSecondaryText)
                Text("Device-specific settings")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Color.siloSecondaryText)
                ForEach(model.availableDeviceGroups) { group in exportToggle(group) }
                Text("Device-specific settings restore only to the same kind of device.")
                    .font(.footnote).foregroundStyle(Color.siloSecondaryText)
                Button {
                    Task {
                        if let data = await model.exportUnifiedDocument() {
                            UIPasteboard.general.string = String(decoding: data, as: UTF8.self)
                            model.didCopyExport()
                        }
                    }
                } label: {
                    Label("Copy Settings as Text", systemImage: "doc.on.doc")
                }
                .disabled(model.exportSelection.isEmpty || model.isBusy)
                .accessibilityIdentifier("settingsBackup.copyText")
            }
            .accessibilityIdentifier("settingsBackup.options")
        } header: {
            Text("Back Up Settings")
        } footer: {
            Text("Includes supported settings. Passwords, account credentials, server addresses, and provider details are never included.")
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private func exportToggle(_ group: SettingsBackupGroup) -> some View {
        Toggle(isOn: Binding(
            get: { model.exportSelection.contains(group) },
            set: { enabled in
                if enabled { model.exportSelection.insert(group) } else { model.exportSelection.remove(group) }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title).foregroundStyle(Color.siloOnSurface)
                Text(group.summary).font(.footnote).foregroundStyle(Color.siloSecondaryText)
            }
        }
        .tint(.siloSwitchOn)
    }

    private var restoreSection: some View {
        Section {
            Button { presentFilePicker() } label: {
                Label("Choose Backup File", systemImage: "square.and.arrow.down")
            }
            .disabled(model.needsRecovery || model.isBusy)
            .accessibilityIdentifier("settingsBackup.import")
            Button { showsPaste = true } label: {
                Label("Paste Backup Text", systemImage: "doc.on.clipboard")
            }
            .disabled(model.needsRecovery || model.isBusy)
            .font(.subheadline)
            .accessibilityIdentifier("settingsBackup.paste")
        } header: {
            Text("Restore Settings")
        } footer: {
            Text(model.needsRecovery
                 ? "Roll back the interrupted restore before importing again."
                 : "Choose a .kyrosettings file to review changes before restoring. Paste text if you can't choose the file.")
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private func presentFilePicker() {
        let shown = filePicker.present { url in
            guard let url else { return }
            Task {
                await model.loadImport(from: url)
                SettingsBackupFilePicker.discardCopy(url)
            }
        }
        if !shown {
            model.didExport(success: false, message: "Kyro couldn't open Files. Use Paste Backup Text instead.")
        }
    }

    private var undoSection: some View {
        Section {
            Button { confirmsUndo = true } label: {
                Label("Undo Last Restore", systemImage: "arrow.uturn.backward")
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("settingsBackup.undo")
        } footer: {
            Text("Puts back values from the last restore. Settings changed since then stay as they are.")
        }
        .listRowBackground(Color.siloGroupedCell)
    }
}

private struct SettingsBackupReviewScreen: View {
    let model: SettingsBackupModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsAll = false
    @State private var confirmsRestore = false
    @State private var confirmsUndo = false

    var body: some View {
        List {
            if let count = model.lastRestoredCount {
                Section {
                    Label("Settings restored", systemImage: "checkmark.circle.fill")
                        .font(.headline).foregroundStyle(Color.green)
                    Text("\(count) setting\(count == 1 ? "" : "s") updated.")
                    if model.undoAvailable {
                        Button("Undo Last Restore") { confirmsUndo = true }
                            .disabled(model.isBusy)
                            .accessibilityIdentifier("settingsBackup.successUndo")
                    }
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settingsBackup.done")
                }
                .listRowBackground(Color.siloGroupedCell)
            } else if let preview = model.preview {
                if let banner = model.banner {
                    Section {
                        Text(banner.text).foregroundStyle(Color.orange)
                    }
                    .listRowBackground(Color.siloGroupedCell)
                }
                Section {
                    if preview.totalChanges == 0 {
                        Text(preview.skippedCount == 0
                             ? "Your settings already match this backup."
                             : "No supported settings need to change.")
                    } else {
                        Text("\(model.selectedChangeCount) setting\(model.selectedChangeCount == 1 ? "" : "s") will change.")
                            .font(.headline)
                    }
                    if preview.isNewerThanSupported {
                        Text("This backup came from a newer Kyro. Only supported settings are shown.")
                            .font(.footnote).foregroundStyle(Color.siloSecondaryText)
                    }
                    if preview.skippedCount > 0 {
                        Text("\(preview.skippedCount) setting\(preview.skippedCount == 1 ? "" : "s") will be skipped.")
                            .font(.footnote).foregroundStyle(Color.siloSecondaryText)
                    }
                }
                .listRowBackground(Color.siloGroupedCell)

                ForEach(preview.groups) { group in
                    if group.changeCount > 0 {
                        Section(group.group.title) {
                            ForEach(group.items.filter { $0.status == .willChange }) { item in
                                Toggle(isOn: Binding(
                                    get: { model.selectedSettingIDs.contains(item.id) },
                                    set: { model.setImport(item.id, enabled: $0) }
                                )) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title).foregroundStyle(Color.siloOnSurface)
                                        Text("\(item.current ?? "—") → \(item.incoming)")
                                            .font(.footnote).foregroundStyle(Color.siloSecondaryText)
                                    }
                                }
                                .tint(.siloSwitchOn)
                                .accessibilityIdentifier("settingsBackup.change.\(item.id)")
                            }
                        }
                        .listRowBackground(Color.siloGroupedCell)
                    }
                }

                Section {
                    DisclosureGroup("View all backed-up settings", isExpanded: $showsAll) {
                        ForEach(preview.groups) { group in
                            ForEach(group.items) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                    Text(detail(for: item))
                                        .font(.footnote).foregroundStyle(Color.siloSecondaryText)
                                }
                            }
                        }
                        if preview.unrecognizedSettings > 0 {
                            Text("\(preview.unrecognizedSettings) unknown settings will be skipped.")
                                .font(.footnote)
                        }
                    }
                }
                .listRowBackground(Color.siloGroupedCell)

                Section {
                    DisclosureGroup("Settings not included in backups") {
                        Text("IPTV providers, playlist URLs, credentials and EPG sources are excluded because the source configuration can contain secrets. Reconnect providers on the destination.")
                        Text("Live TV favorites and pinned or hidden categories are tied to a provider's local ID and catalog. Kyro cannot verify that another installation has the same provider and channels, so these are skipped.")
                        Text("Library favorites and saved browse filters depend on server, profile and catalog identities. They are not transferred without a verified destination mapping.")
                        Text("Privacy consent, diagnostics switches and last-opened screens are intentionally not restored.")
                    }
                    .font(.footnote)
                    .foregroundStyle(Color.siloSecondaryText)
                }
                .listRowBackground(Color.siloGroupedCell)

                Section {
                    if preview.totalChanges == 0 {
                        Button("Done") { model.cancelImport(); dismiss() }
                            .accessibilityIdentifier("settingsBackup.done")
                    } else {
                        Button("Restore \(model.selectedChangeCount) Setting\(model.selectedChangeCount == 1 ? "" : "s")") {
                            confirmsRestore = true
                        }
                        .disabled(model.selectedChangeCount == 0 || model.isBusy)
                        .accessibilityIdentifier("settingsBackup.apply")
                    }
                }
                .listRowBackground(Color.siloGroupedCell)
            } else if let banner = model.banner {
                Section {
                    Text(banner.text)
                    Button("Done") { dismiss() }
                }
            }
        }
        .settingsListChrome()
        .navigationTitle(model.lastRestoredCount == nil ? "Review Backup" : "Restore Complete")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
        .confirmationDialog("Restore \(model.selectedChangeCount) setting\(model.selectedChangeCount == 1 ? "" : "s")?",
                            isPresented: $confirmsRestore, titleVisibility: .visible) {
            Button("Restore Settings") { Task { await model.applyUnifiedSelected() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only selected settings will change. You can undo this afterwards when a restore point is available.")
        }
        .confirmationDialog("Undo last restore?", isPresented: $confirmsUndo, titleVisibility: .visible) {
            Button("Undo Last Restore") { Task { await model.undoUnified(); dismiss() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Earlier values will be restored. Settings you changed since the restore will stay as they are.")
        }
        .onDisappear {
            if model.preview != nil { model.cancelImport() }
        }
    }

    private func detail(for item: RestorePreviewItem) -> String {
        switch item.status {
        case .willChange: "\(item.current ?? "—") → \(item.incoming)"
        case .unchanged: "Already \(item.incoming)"
        case .unsupported(let reason), .invalid(let reason): "Skipped: \(reason)"
        }
    }
}
#endif
