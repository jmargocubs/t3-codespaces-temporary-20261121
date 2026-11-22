#if os(iOS) || KYRO_STANDALONE_TESTS
import Foundation
import Observation

/// The state behind Settings → Account & Connections → Backup & Restore. Importing only ever loads
/// a preview; nothing is written until `applySelected()`.
@MainActor @Observable
final class SettingsBackupModel {
    struct Banner: Equatable {
        enum Kind: Equatable { case success, warning, failure }
        let kind: Kind
        let text: String
    }

    var exportSelection: Set<SettingsBackupGroup> = SettingsBackupGroup.defaultSelection
    private(set) var preview: RestorePreview?
    var importSelection: Set<SettingsBackupGroup> = []
    private(set) var selectedSettingIDs: Set<String> = []
    private(set) var lastRestoredCount: Int?
    private(set) var banner: Banner?
    private(set) var undoAvailable = false
    private(set) var needsRecovery = false
    private(set) var restoreDate: Date?
    private(set) var isBusy = false
    /// Synced settings the last export left out, each with its reason.
    private(set) var exportOmissions: [String] = []

    @ObservationIgnored private let registry: SettingsBackupRegistry
    @ObservationIgnored private let applier: SettingsBackupApplier
    @ObservationIgnored private let app: SettingsBackupAppInfo
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let notifications: NotificationCenter
    @ObservationIgnored private let remote: SettingsBackupRemoteAdapter?
    @ObservationIgnored private var incomingBackup: IncomingBackup?

    var availablePortableGroups: [SettingsBackupGroup] {
        SettingsBackupGroup.portable.filter {
            !registry.settings(in: $0).isEmpty || (remote != nil && $0.isServerSynced)
        }
    }

    var availableDeviceGroups: [SettingsBackupGroup] {
        SettingsBackupGroup.deviceSpecific.filter { !registry.settings(in: $0).isEmpty }
    }

    init(
        registry: SettingsBackupRegistry,
        journal: RestoreJournalStoring,
        app: SettingsBackupAppInfo,
        now: @escaping () -> Date = Date.init,
        notifications: NotificationCenter = .default,
        remote: SettingsBackupRemoteAdapter? = nil
    ) {
        self.notifications = notifications
        self.registry = registry
        self.exportSelection = SettingsBackupGroup.defaultSelection.filter { !registry.settings(in: $0).isEmpty }
        self.applier = SettingsBackupApplier(registry: registry, journal: journal, now: now)
        self.app = app
        self.now = now
        self.remote = remote
        if remote != nil { self.exportSelection.formUnion(SettingsBackupRemoteAdapter.groups) }
        refreshRestorePointState()
    }

    // MARK: Export

    func exportDocument() -> Data? {
        do {
            let data = try SettingsBackupExporter.export(registry: registry, groups: exportSelection, app: app, now: now())
            banner = nil
            return data
        } catch {
            banner = Banner(kind: .failure, text: error.localizedDescription)
            return nil
        }
    }

    /// The production export reads remote owners before creating one schema-2 file.
    /// A remote failure aborts export; a local-only file must not masquerade as complete.
    func exportUnifiedDocument() async -> Data? {
        guard !isBusy else { return nil }
        exportOmissions = []
        guard let remote else { return exportDocument() }
        isBusy = true
        defer { isBusy = false }
        do {
            let localSelection = Set(exportSelection.filter { !registry.settings(in: $0).isEmpty })
            var groups: [String: [String: BackupValue]] = [:]
            if !localSelection.isEmpty {
                let local = try SettingsBackupExporter.export(registry: registry, groups: localSelection,
                                                              app: app, now: now())
                groups = try SettingsBackupCodec.decode(local).groups
            }
            var scope: SettingsBackupScope?
            var omitted: [String] = []
            if exportSelection.contains(where: \.isServerSynced) {
                let synced = try await remote.export()
                scope = synced.scope
                omitted = synced.omitted
                for (group, values) in synced.groups {
                    if let selection = SettingsBackupGroup(rawValue: group), exportSelection.contains(selection) {
                        groups[group] = values
                    }
                }
            }
            let data = try SettingsBackupCodec.makeUnifiedDocument(groups: groups, scope: scope,
                                                                    app: app, now: now())
            banner = nil
            exportOmissions = omitted
            return data
        } catch {
            banner = Banner(kind: .failure, text: "The backup was not created: \(error.localizedDescription)")
            return nil
        }
    }

    /// The same backup as `exportDocument()`, as text for the clipboard.
    func exportText() -> String? {
        exportDocument().map { String(decoding: $0, as: UTF8.self) }
    }

    func didCopyExport() {
        banner = Banner(kind: .success, text: "Settings copied as text. Paste them into Backup & Restore → Paste Backup Text. The text has no sign-in details, server addresses or Live TV providers.")
    }

    var exportFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Kyro Settings \(formatter.string(from: now()))"
    }

    func didExport(success: Bool, message: String? = nil) {
        let omitted = exportOmissions.isEmpty ? ""
            : " Not included: \(exportOmissions.joined(separator: "; "))."
        banner = success
            ? Banner(kind: exportOmissions.isEmpty ? .success : .warning,
                     text: "Settings exported. The file has no sign-in details, server addresses or Live TV providers.\(omitted)")
            : Banner(kind: .failure, text: message ?? "The export wasn't saved.")
    }

    // MARK: Import

    /// Reads a chosen file with a hard size limit, then validates it. The read is coordinated, so a
    /// file that is only a placeholder in iCloud Drive is downloaded first, and it runs off the main
    /// actor so a slow download never freezes the screen. Reading stops one byte past the limit so a
    /// file that grows while it is read cannot exceed it.
    func loadImport(from url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try await Task.detached(priority: .userInitiated) { try Self.readBackupFile(at: url) }.value
            await loadUnifiedImport(data: data)
        } catch let error as SettingsBackupError {
            reject(error)
        } catch {
            reject(.unreadable)
        }
    }

    nonisolated static func readBackupFile(at url: URL) throws -> Data {
        var coordinationError: NSError?
        var outcome: Result<Data, Error> = .failure(SettingsBackupError.unreadable)
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: [.withoutChanges], error: &coordinationError
        ) { readableURL in
            outcome = Result {
                if let size = try? readableURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   size > SettingsBackupSafety.maxFileBytes {
                    throw SettingsBackupError.tooLarge
                }
                let handle = try FileHandle(forReadingFrom: readableURL)
                defer { try? handle.close() }
                return try handle.read(upToCount: SettingsBackupSafety.maxFileBytes + 1) ?? Data()
            }
        }
        if coordinationError != nil { throw SettingsBackupError.unreadable }
        return try outcome.get()
    }

    func loadImport(data: Data) {
        do {
            try loadPreview(data)
        } catch let error as SettingsBackupError {
            reject(error)
        } catch {
            reject(.malformed)
        }
    }

    func loadUnifiedImport(data: Data) async {
        guard !isBusy else { return }
        guard let remote else { loadImport(data: data); return }
        isBusy = true
        defer { isBusy = false }
        do {
            let incoming = try SettingsBackupCodec.decode(data)
            let localGroups = incoming.groups.filter {
                SettingsBackupGroup(rawValue: $0.key)?.isServerSynced != true
            }
            let local = IncomingBackup(schemaVersion: incoming.schemaVersion, createdAt: incoming.createdAt,
                                       app: incoming.app, groups: localGroups, scope: incoming.scope)
            let localPreview = SettingsBackupPlanner.preview(local, registry: registry)
            let remoteGroups = await remote.preview(incoming)
            // A newer Kyro may add synced settings this build does not know; they are counted as
            // skipped, never dropped silently.
            let unknownRemote = incoming.groups
                .filter { SettingsBackupGroup(rawValue: $0.key)?.isServerSynced == true }
                .reduce(0) { $0 + $1.value.keys.filter { !SettingsBackupRemoteAdapter.settingIDs.contains($0) }.count }
            let result = RestorePreview(
                createdAt: incoming.createdAt, app: incoming.app,
                groups: localPreview.groups + remoteGroups,
                unrecognizedGroups: localPreview.unrecognizedGroups,
                unrecognizedSettings: localPreview.unrecognizedSettings + unknownRemote,
                isNewerThanSupported: localPreview.isNewerThanSupported)
            incomingBackup = incoming
            acceptPreview(result)
        } catch let error as SettingsBackupError { reject(error) }
        catch { reject(.malformed) }
    }

    func loadUnifiedImport(text: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= SettingsBackupSafety.maxFileBytes else {
            return Self.pastedTextMessage(.tooLarge)
        }
        await loadUnifiedImport(data: Data(trimmed.utf8))
        return preview == nil ? banner?.text ?? Self.pastedTextMessage(.malformed) : nil
    }

    /// Loads a backup pasted as text, through the same decoder, size limit, integrity check and
    /// preview as a file. Returns nil when the preview is ready, or the reason the text was refused.
    /// A refusal is returned rather than shown as a banner, so the paste screen can show it in place.
    func loadImport(text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard trimmed.utf8.count <= SettingsBackupSafety.maxFileBytes else { throw SettingsBackupError.tooLarge }
            try loadPreview(Data(trimmed.utf8))
            return nil
        } catch {
            preview = nil
            importSelection = []
            selectedSettingIDs = []
            return Self.pastedTextMessage(error as? SettingsBackupError ?? .malformed)
        }
    }

    private func loadPreview(_ data: Data) throws {
        let incoming = try SettingsBackupCodec.decode(data)
        let result = SettingsBackupPlanner.preview(incoming, registry: registry)
        incomingBackup = incoming
        acceptPreview(result)
    }

    private func acceptPreview(_ result: RestorePreview) {
        preview = result
        importSelection = Set(result.groups.filter { $0.canRestore && !$0.group.isDeviceSpecific }.map(\.group))
        selectedSettingIDs = Set(result.groups.filter { importSelection.contains($0.group) }
            .flatMap { $0.items.filter { $0.status == .willChange }.map(\.id) })
        lastRestoredCount = nil
        banner = nil
    }

    /// File errors talk about "this file"; pasted text gets wording that fits what the person did.
    nonisolated static func pastedTextMessage(_ error: SettingsBackupError) -> String {
        switch error {
        case .tooLarge:
            "This text is too long to be a Kyro settings backup. A backup is at most \(SettingsBackupSafety.maxFileBytes / 1024) KB."
        case .empty:
            "Paste the backup text first."
        case .malformed, .notABackup, .unreadable:
            "This text isn't a Kyro settings backup. Paste the whole backup, from the first { to the last }."
        default:
            error.localizedDescription
        }
    }

    private func reject(_ error: SettingsBackupError) {
        preview = nil
        incomingBackup = nil
        importSelection = []
        selectedSettingIDs = []
        banner = Banner(kind: .failure, text: error.localizedDescription)
    }

    /// Drops the loaded backup. Nothing was written, so there is nothing to undo.
    func cancelImport() {
        preview = nil
        incomingBackup = nil
        importSelection = []
        selectedSettingIDs = []
    }

    func setImport(_ group: SettingsBackupGroup, enabled: Bool) {
        guard preview?.groups.first(where: { $0.group == group })?.canRestore == true else { return }
        if enabled { importSelection.insert(group) } else { importSelection.remove(group) }
        let ids = preview?.groups.first(where: { $0.group == group })?.items
            .filter { $0.status == .willChange }.map(\.id) ?? []
        for id in ids {
            if enabled { selectedSettingIDs.insert(id) } else { selectedSettingIDs.remove(id) }
        }
    }

    func setImport(_ id: String, enabled: Bool) {
        guard let group = preview?.groups.first(where: { $0.items.contains(where: { $0.id == id && $0.status == .willChange }) }),
              group.groupUnsupportedReason == nil else { return }
        if enabled { selectedSettingIDs.insert(id) } else { selectedSettingIDs.remove(id) }
        if group.items.contains(where: { selectedSettingIDs.contains($0.id) }) {
            importSelection.insert(group.group)
        } else {
            importSelection.remove(group.group)
        }
    }

    var selectedChangeCount: Int {
        selectedSettingIDs.count
    }

    // MARK: Apply, undo, recovery

    func applySelected() {
        guard let preview, selectedChangeCount > 0 else { return }
        switch applier.apply(preview: preview, selectedGroups: importSelection, selectedIDs: selectedSettingIDs) {
        case .nothingToApply:
            banner = Banner(kind: .warning, text: "Nothing needed to change.")
        case .applied(let changes, let undoable):
            lastRestoredCount = changes.count
            banner = Banner(kind: .success, text: undoable
                ? "Restored \(changes.count) setting\(changes.count == 1 ? "" : "s"). You can undo this."
                : "Restored \(changes.count) setting\(changes.count == 1 ? "" : "s"). Undo isn't available because Kyro couldn't keep a restore point.")
            self.preview = nil
            importSelection = []
            selectedSettingIDs = []
        case .failed(_, let reason, let rollback):
            if rollback.isComplete {
                banner = Banner(kind: .failure, text: "\(reason) Your earlier settings were put back.")
            } else {
                banner = Banner(kind: .failure, text: "\(reason) Kyro couldn't put back: \(titles(rollback.unrestored)). Reopen this screen to try again.")
            }
            self.preview = nil
            importSelection = []
            selectedSettingIDs = []
        }
        // Any outcome may have written values, even a rolled-back one, so screens reload either way.
        notifications.post(name: .kyroSettingsDidRestore, object: nil)
        refreshRestorePointState()
    }

    func applyUnifiedSelected() async {
        guard let remote, let incomingBackup, let preview, !isBusy else {
            applySelected(); return
        }
        isBusy = true
        defer { isBusy = false; refreshRestorePointState() }
        let remoteIDs = selectedSettingIDs.intersection(SettingsBackupRemoteAdapter.settingIDs)
        let remoteReport = await remote.apply(incomingBackup, selectedIDs: remoteIDs)
        let skippedText = remoteReport.skipped.isEmpty ? "" : " Skipped: "
            + remoteReport.skipped.map { id in
                let title = InterfaceRecordBackup.title(id)
                return remoteReport.skipReasons[id].map { "\(title) (\($0))" } ?? title
            }.joined(separator: "; ") + "."
        if !remoteReport.failed.isEmpty {
            banner = Banner(kind: .failure, text: "Restored \(remoteReport.applied.count) synced settings; "
                + "failed: \(remoteReport.failed.map(InterfaceRecordBackup.title).joined(separator: ", ")). "
                + "Local settings were not changed.\(skippedText) Roll back confirmed changes before another import.")
            lastRestoredCount = nil
            self.preview = nil
            self.incomingBackup = nil
            notifications.post(name: .kyroSettingsDidRestore, object: nil)
            return
        }
        let localIDs = selectedSettingIDs.subtracting(remoteIDs)
        let localGroups = importSelection.filter { !$0.isServerSynced }
        let localOutcome = localIDs.isEmpty ? RestoreOutcome.nothingToApply
            : applier.apply(preview: preview, selectedGroups: localGroups, selectedIDs: localIDs)
        switch localOutcome {
        case .nothingToApply:
            let count = remoteReport.applied.count
            lastRestoredCount = count == 0 ? nil : count
            banner = Banner(kind: count == 0 ? .warning : .success,
                            text: (count == 0 ? "Nothing needed to change." : "Restored \(count) synced settings. You can undo this.") + skippedText)
        case .applied(let changes, _):
            let count = changes.count + remoteReport.applied.count
            lastRestoredCount = count
            banner = Banner(kind: .success, text: "Restored \(count) settings. You can undo this.\(skippedText)")
        case .failed(_, let reason, let rollback):
            lastRestoredCount = nil
            banner = Banner(kind: .failure, text: "\(reason) \(remoteReport.applied.count) synced settings remain restored. "
                + (rollback.isComplete ? "Local changes were rolled back." : "Some local changes could not be rolled back.") + skippedText)
        }
        self.preview = nil
        self.incomingBackup = nil
        importSelection = []
        selectedSettingIDs = []
        notifications.post(name: .kyroSettingsDidRestore, object: nil)
        if !remoteReport.applied.isEmpty { await remote.refreshUI() }
    }

    func undoUnified() async {
        guard let remote, !isBusy else { undo(); return }
        isBusy = true
        defer { isBusy = false; refreshRestorePointState() }
        let remoteReport = await remote.undo()
        let localReport = applier.undo()
        if remoteReport.failed.isEmpty {
            banner = undoBanner(localReport, verb: "Undid")
            if !remoteReport.applied.isEmpty {
                banner = Banner(kind: banner?.kind ?? .success,
                                text: "Undid \(remoteReport.applied.count) synced settings. \(banner?.text ?? "")")
            }
            if !remoteReport.skipped.isEmpty {
                banner = Banner(kind: .warning, text: "\(banner?.text ?? "") Left \(remoteReport.skipped.count) synced settings unchanged because they changed since restore.")
            }
        } else {
            banner = Banner(kind: .failure, text: "Could not undo \(remoteReport.failed.count) synced settings. "
                + "Check that this is the same server and profile, then try again.")
        }
        notifications.post(name: .kyroSettingsDidRestore, object: nil)
        if !remoteReport.applied.isEmpty { await remote.refreshUI() }
    }

    func recoverUnified() async {
        guard let remote else { recoverInterruptedRestore(); return }
        let remoteReport = await remote.undo()
        let localReport = applier.recoverInterruptedRestore()
        banner = remoteReport.failed.isEmpty ? undoBanner(localReport, verb: "Rolled back")
            : Banner(kind: .failure, text: "Some synced settings could not be rolled back. Reconnect to the same server and profile and try again.")
        refreshRestorePointState()
        notifications.post(name: .kyroSettingsDidRestore, object: nil)
    }

    func undo() {
        let report = applier.undo()
        banner = undoBanner(report, verb: "Undid")
        notifications.post(name: .kyroSettingsDidRestore, object: nil)
        refreshRestorePointState()
    }

    func recoverInterruptedRestore() {
        let report = applier.recoverInterruptedRestore()
        banner = undoBanner(report, verb: "Rolled back")
        notifications.post(name: .kyroSettingsDidRestore, object: nil)
        refreshRestorePointState()
    }

    func refreshRestorePointState() {
        undoAvailable = applier.undoAvailable || (remote?.undoAvailable ?? false)
        needsRecovery = applier.needsRecovery || (remote?.needsRecovery ?? false)
        restoreDate = undoAvailable ? applier.restorePointDate : nil
    }

    private func undoBanner(_ report: UndoReport, verb: String) -> Banner {
        if !report.failed.isEmpty {
            let done = report.reverted.isEmpty ? "" : "\(verb) \(report.reverted.count). "
            return Banner(kind: .failure, text: "\(done)Kyro couldn't put back: \(titles(report.failed)). Try again.")
        }
        var parts: [String] = []
        if !report.reverted.isEmpty {
            parts.append("\(verb) \(report.reverted.count) setting\(report.reverted.count == 1 ? "" : "s").")
        }
        if !report.unchanged.isEmpty {
            parts.append("\(report.unchanged.count) already had the earlier value.")
        }
        if !report.changedSince.isEmpty {
            parts.append("Left \(titles(report.changedSince)) as it is now, because you changed it again.")
        }
        if parts.isEmpty { parts.append("Nothing needed to change.") }
        return Banner(kind: report.changedSince.isEmpty ? .success : .warning, text: parts.joined(separator: " "))
    }

    private func titles(_ ids: [String]) -> String {
        ids.map { registry.setting(id: $0)?.title ?? $0 }.joined(separator: ", ")
    }
}
#endif
