#if os(iOS) || KYRO_STANDALONE_TESTS
import Foundation

// Build 88: preview, apply, rollback and undo.
//
// Preview only reads. Apply writes through each setting's own setter, one value at a time, and
// reads every value back. It is not crash-atomic: each store persists on its own. What it does
// provide is a restore point written before the first change, so an interrupted restore can be
// rolled back the next time the Backup & Restore screen opens.

// MARK: - Preview

enum RestoreItemStatus: Equatable {
    case willChange
    case unchanged
    case unsupported(String)
    case invalid(String)
}

struct RestorePreviewItem: Identifiable, Equatable {
    let id: String
    let group: SettingsBackupGroup
    let title: String
    let current: String?
    let incoming: String
    let status: RestoreItemStatus
    let incomingValue: BackupValue
}

struct RestorePreviewGroup: Identifiable, Equatable {
    let group: SettingsBackupGroup
    let items: [RestorePreviewItem]
    /// Why the whole group cannot be restored on this device, if it cannot.
    let groupUnsupportedReason: String?

    var id: String { group.rawValue }
    var changeCount: Int { items.filter { $0.status == .willChange }.count }
    var canRestore: Bool { groupUnsupportedReason == nil && changeCount > 0 }
}

struct RestorePreview: Equatable {
    let createdAt: String
    let app: SettingsBackupAppInfo?
    let groups: [RestorePreviewGroup]
    let unrecognizedGroups: Int
    let unrecognizedSettings: Int
    let isNewerThanSupported: Bool

    var totalChanges: Int { groups.reduce(0) { $0 + $1.changeCount } }
    var skippedCount: Int {
        unrecognizedSettings + groups.reduce(0) { count, group in
            count + group.items.filter { item in
                switch item.status {
                case .unsupported, .invalid: true
                case .willChange, .unchanged: false
                }
            }.count
        }
    }
}

enum SettingsBackupPlanner {
    /// Compares a backup with the current values. Reads only; never writes.
    @MainActor
    static func preview(_ incoming: IncomingBackup, registry: SettingsBackupRegistry) -> RestorePreview {
        var groups: [RestorePreviewGroup] = []
        var unrecognizedGroups = 0
        var unrecognizedSettings = 0

        for name in incoming.groups.keys where SettingsBackupGroup(rawValue: name) == nil {
            unrecognizedGroups += 1
            unrecognizedSettings += incoming.groups[name]?.count ?? 0
        }

        for group in SettingsBackupGroup.allCases {
            guard let values = incoming.groups[group.rawValue] else { continue }
            let known = Set(registry.settings(in: group).map(\.id))
            unrecognizedSettings += values.keys.filter { !known.contains($0) }.count

            let groupReason = deviceReason(group: group, incoming: incoming, registry: registry)
            var items: [RestorePreviewItem] = []
            for setting in registry.settings(in: group) {
                guard let value = values[setting.id] else { continue }
                let current = setting.read()
                let currentText = current.map(setting.label)
                let status: RestoreItemStatus
                if let groupReason {
                    status = .unsupported(groupReason)
                } else if let reason = setting.unsupportedReason() {
                    status = .unsupported(reason)
                } else if !setting.validate(value) {
                    status = .invalid("This value isn't supported by this version of Kyro.")
                } else if current == value {
                    status = .unchanged
                } else {
                    status = .willChange
                }
                items.append(RestorePreviewItem(
                    id: setting.id, group: group, title: setting.title,
                    current: currentText, incoming: setting.validate(value) ? setting.label(value) : value.plainText,
                    status: status, incomingValue: value))
            }
            groups.append(RestorePreviewGroup(group: group, items: items, groupUnsupportedReason: groupReason))
        }

        return RestorePreview(
            createdAt: incoming.createdAt, app: incoming.app, groups: groups,
            unrecognizedGroups: unrecognizedGroups, unrecognizedSettings: unrecognizedSettings,
            isNewerThanSupported: incoming.isNewerThanSupported)
    }

    /// Device-specific groups only restore onto the same kind of device they were saved from.
    private static func deviceReason(
        group: SettingsBackupGroup, incoming: IncomingBackup, registry: SettingsBackupRegistry
    ) -> String? {
        guard group.isDeviceSpecific else { return nil }
        guard let saved = incoming.app?.idiom, !saved.isEmpty else {
            return "This backup doesn't say which kind of device it came from."
        }
        guard saved == registry.deviceIdiom else {
            return "Saved on an iP\(saved == "pad" ? "ad" : "hone"); this is an iP\(registry.deviceIdiom == "pad" ? "ad" : "hone")."
        }
        return nil
    }
}

// MARK: - Journal

struct AppliedChange: Codable, Equatable {
    let id: String
    let previous: BackupValue
    let applied: BackupValue
}

/// The restore point. `applying` means the app may have stopped part way through.
struct RestoreJournal: Codable, Equatable {
    enum State: String, Codable { case applying, applied, rollbackIncomplete }
    var state: State
    var changes: [AppliedChange]
    var date: Date
}

protocol RestoreJournalStoring: AnyObject {
    func load() throws -> RestoreJournal?
    func save(_ journal: RestoreJournal) throws
    func clear() throws
}

/// Stores the restore point as one small file, written atomically.
final class FileRestoreJournalStore: RestoreJournalStoring {
    private let url: URL

    init(url: URL) { self.url = url }

    static func standard() -> FileRestoreJournalStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FileRestoreJournalStore(url: base.appendingPathComponent("SettingsBackup/restore-point.json"))
    }

    func load() throws -> RestoreJournal? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= SettingsBackupSafety.maxFileBytes * 4 else { throw SettingsBackupError.tooLarge }
        return try JSONDecoder().decode(RestoreJournal.self, from: data)
    }

    func save(_ journal: RestoreJournal) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(journal)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

// MARK: - Outcomes

struct RollbackReport: Equatable {
    var restored: [String] = []
    /// Settings whose previous value could not be written back or confirmed.
    var unrestored: [String] = []
    var isComplete: Bool { unrestored.isEmpty }
}

enum RestoreOutcome: Equatable {
    case nothingToApply
    /// Every selected change was written and read back. `undoAvailable` is false only when the
    /// restore point could not be kept.
    case applied(changes: [AppliedChange], undoAvailable: Bool)
    /// A write or its read-back failed. Nothing was written when `attempted` is empty.
    case failed(failedID: String?, reason: String, rollback: RollbackReport)
}

struct UndoReport: Equatable {
    var reverted: [String] = []
    /// Changed again after the restore, so left as they are now.
    var changedSince: [String] = []
    var failed: [String] = []
    /// Already holding their earlier value when Undo or recovery ran, so nothing was written.
    var unchanged: [String] = []
    var isClean: Bool { failed.isEmpty }
}

private struct RestoreWriteFailure: Error { let reason: String }

// MARK: - Applier

@MainActor
final class SettingsBackupApplier {
    private let registry: SettingsBackupRegistry
    private let journal: RestoreJournalStoring
    private let now: () -> Date

    init(registry: SettingsBackupRegistry, journal: RestoreJournalStoring, now: @escaping () -> Date = Date.init) {
        self.registry = registry
        self.journal = journal
        self.now = now
    }

    /// Applies the willChange items of the selected groups. Settings of other groups, and settings
    /// that are not in the backup, are never read for writing.
    func apply(preview: RestorePreview, selectedGroups: Set<SettingsBackupGroup>, selectedIDs: Set<String>? = nil) -> RestoreOutcome {
        // An unresolved restore point must be rolled back first: a new restore would overwrite it.
        if needsRecovery {
            return .failed(failedID: nil, reason: "An earlier restore didn't finish. Roll it back before restoring again, so nothing was changed.", rollback: RollbackReport())
        }

        // 1. Re-validate against what is current now, and snapshot.
        var changes: [AppliedChange] = []
        for group in preview.groups where selectedGroups.contains(group.group) && group.groupUnsupportedReason == nil {
            for item in group.items where item.status == .willChange && (selectedIDs?.contains(item.id) ?? true) {
                guard let setting = registry.setting(id: item.id), setting.unsupportedReason() == nil,
                      setting.validate(item.incomingValue) else { continue }
                guard let previous = setting.read() else {
                    return .failed(failedID: item.id, reason: "Kyro couldn't read the current value of \(item.title), so nothing was changed.", rollback: RollbackReport())
                }
                if previous != item.incomingValue {
                    changes.append(AppliedChange(id: item.id, previous: previous, applied: item.incomingValue))
                }
            }
        }
        guard !changes.isEmpty else { return .nothingToApply }

        // 2. The restore point comes first. Without it, nothing is written.
        var record = RestoreJournal(state: .applying, changes: changes, date: now())
        do { try journal.save(record) } catch {
            return .failed(failedID: nil, reason: "Kyro couldn't save a restore point, so nothing was changed.", rollback: RollbackReport())
        }

        // 3. Write in the preview's fixed order (group order, then registry order), verifying each value.
        var attempted: [AppliedChange] = []
        for change in changes {
            attempted.append(change)
            guard let setting = registry.setting(id: change.id) else { continue }
            do {
                try setting.write(change.applied)
                guard setting.read() == change.applied else {
                    throw RestoreWriteFailure(reason: "\(setting.title) did not keep the new value.")
                }
            } catch {
                let reason = (error as? RestoreWriteFailure)?.reason ?? "\(setting.title) could not be changed."
                let report = rollBack(attempted)
                if report.isComplete {
                    try? journal.clear()
                } else {
                    record.state = .rollbackIncomplete
                    record.changes = attempted.filter { report.unrestored.contains($0.id) }
                    try? journal.save(record)
                }
                return .failed(failedID: change.id, reason: reason, rollback: report)
            }
        }

        // 4. Keep the restore point as the undo record.
        record.state = .applied
        let kept = (try? journal.save(record)) != nil
        // A stale "applying" record would later offer to roll back a restore that finished.
        if !kept { try? journal.clear() }
        return .applied(changes: changes, undoAvailable: kept)
    }

    private func rollBack(_ attempted: [AppliedChange]) -> RollbackReport {
        var report = RollbackReport()
        for change in attempted.reversed() {
            guard let setting = registry.setting(id: change.id) else { report.unrestored.append(change.id); continue }
            do {
                try setting.write(change.previous)
                if setting.read() == change.previous { report.restored.append(change.id) } else { report.unrestored.append(change.id) }
            } catch {
                report.unrestored.append(change.id)
            }
        }
        return report
    }

    // MARK: Undo and recovery

    /// The restore point, if one is kept and readable.
    func restorePoint() -> RestoreJournal? { try? journal.load() }

    var undoAvailable: Bool { restorePoint()?.state == .applied }
    var restorePointDate: Date? { restorePoint()?.date }
    var needsRecovery: Bool {
        guard let state = restorePoint()?.state else { return false }
        return state == .applying || state == .rollbackIncomplete
    }

    /// Puts back the values the last restore changed. A value that has been changed again since is
    /// left alone: undo never overwrites something the user set later.
    @discardableResult
    func undo() -> UndoReport { revert(expecting: [.applied]) }

    /// Rolls back a restore that was interrupted or only partly rolled back.
    @discardableResult
    func recoverInterruptedRestore() -> UndoReport { revert(expecting: [.applying, .rollbackIncomplete]) }

    private func revert(expecting states: Set<RestoreJournal.State>) -> UndoReport {
        guard var record = try? journal.load(), states.contains(record.state) else { return UndoReport() }
        var report = UndoReport()
        var remaining: [AppliedChange] = []
        for change in record.changes.reversed() {
            guard let setting = registry.setting(id: change.id) else { report.failed.append(change.id); remaining.append(change); continue }
            let current = setting.read()
            if current == change.previous { report.unchanged.append(change.id); continue }
            guard current == change.applied else { report.changedSince.append(change.id); continue }
            do {
                try setting.write(change.previous)
                if setting.read() == change.previous { report.reverted.append(change.id) } else { throw RestoreWriteFailure(reason: "") }
            } catch {
                report.failed.append(change.id)
                remaining.append(change)
            }
        }
        if remaining.isEmpty {
            try? journal.clear()
        } else {
            record.changes = remaining.reversed()
            try? journal.save(record)
        }
        return report
    }

    /// Drops the restore point without reverting anything.
    func discardRestorePoint() { try? journal.clear() }
}
#endif
