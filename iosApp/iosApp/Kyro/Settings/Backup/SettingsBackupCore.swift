#if os(iOS) || KYRO_STANDALONE_TESTS
import CryptoKit
import Foundation
import UniformTypeIdentifiers

// Build 88: Settings Backup & Restore, the Foundation-only core.
//
// Nothing here knows about a concrete preference store. A `BackupSetting` is one explicitly
// allowlisted setting with a typed validator and the existing store's own getter and setter, so the
// document, preview and apply logic can be tested with in-memory fakes. Settings are never
// discovered by scanning `UserDefaults`: a key that is not registered cannot be exported or
// restored.

// MARK: - File types

/// The file types Backup & Restore uses.
///
/// Files reports Kyro's own exported file as `com.cubbiestream.kyro.settings-backup`. Name that
/// exact type in the importer: accepting only its system supertypes left the exported file disabled
/// in the iPhone document picker. System fallbacks accommodate providers that report generic types;
/// the decoder still validates every selected file.
enum SettingsBackupFileType {
    static let exportIdentifier = "com.cubbiestream.kyro.settings-backup"
    static let fileExtension = "kyrosettings"

    /// The type used to export and identify Kyro backup documents.
    static let exportType = UTType(exportedAs: exportIdentifier, conformingTo: .json)

    /// Include the registered document type explicitly, with system fallbacks for file providers.
    static let importerTypes: [UTType] = [exportType, .json, .data, .item]
}

// MARK: - Notification

extension Notification.Name {
    /// Posted on the main thread after a restore, an Undo or a recovery has written settings, so a
    /// screen that keeps its own copy of a restored preference can reload it. Carries no payload.
    static let kyroSettingsDidRestore = Notification.Name("kyro.settings.didRestore")
}

// MARK: - Values

/// Schema 4 adds bounded ordered arrays and nested records for navigation destinations. Older
/// documents retain their original scalar/flat-record representation and canonical hash.
enum BackupValue: Equatable, Sendable, Codable {
    case bool(Bool)
    case int(Int)
    case string(String)
    /// A flat set of named scalars, such as the subtitle appearance. Schema 3 only.
    case record([String: BackupValue])
    case array([BackupValue])

    var isRecord: Bool { if case .record = self { true } else { false } }
    var requiresSchema4: Bool {
        switch self {
        case .array: true
        case .record(let fields): fields.values.contains { $0.isRecord || $0.requiresSchema4 }
        default: false
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: BackupValue].self) {
            self = .record(value)
        } else if let value = try? container.decode([BackupValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Only booleans, integers, strings and flat records are allowed.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .record(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        }
    }

    /// Plain text for a setting without its own labels.
    var plainText: String {
        switch self {
        case .bool(let value): value ? "On" : "Off"
        case .int(let value): String(value)
        case .string(let value): value
        case .record: "Custom"
        case .array(let values): "\(values.count) items"
        }
    }
}

// MARK: - Groups

/// The unit a user chooses to export or restore. Safe local groups are on by default; device-specific
/// groups still restore only onto the same kind of device they were saved from.
enum SettingsBackupGroup: String, CaseIterable, Codable, Sendable, Identifiable {
    case general
    case calendar
    case navigation
    case liveTVCategories
    case guideLayout
    case sports
    case downloads
    case playbackOptions
    case pictureInPicture
    case advancedAudioVideo
    case subtitleDisplay
    case navigationLayout
    case streaming
    case subtitles
    case features
    case player
    case interface

    var id: String { rawValue }

    var isDeviceSpecific: Bool {
        switch self {
        case .general, .calendar, .navigation, .liveTVCategories, .guideLayout, .sports, .downloads, .streaming,
             .subtitles, .features, .player, .interface: false
        case .playbackOptions, .pictureInPicture, .advancedAudioVideo, .subtitleDisplay, .navigationLayout: true
        }
    }

    var title: String {
        switch self {
        case .general: "General"
        case .calendar: "Calendar"
        case .navigation: "Navigation"
        case .liveTVCategories: "Live TV categories"
        case .guideLayout: "Guide layout"
        case .sports: "Sports dashboard"
        case .downloads: "Downloads"
        case .playbackOptions: "Playback options"
        case .pictureInPicture: "Picture in Picture"
        case .advancedAudioVideo: "Advanced audio & video"
        case .subtitleDisplay: "Subtitle display"
        case .navigationLayout: "Navigation layout & appearance"
        case .streaming: "Streaming"
        case .subtitles: "Subtitles"
        case .features: "Features"
        case .player: "Player"
        case .interface: "Interface"
        }
    }

    var summary: String {
        switch self {
        case .general: "How Kyro selects a profile when it opens."
        case .calendar: "Which events the Calendar shows."
        case .navigation: "The fourth tab."
        case .liveTVCategories: "How categories look and group."
        case .guideLayout: "List or grid guide on the watch screen."
        case .sports: "Preferred dashboard view for each sport."
        case .downloads: "Wi-Fi only, quality, limits and sorting."
        case .playbackOptions: "Buffering and lossless audio."
        case .pictureInPicture: "Keep playing when you leave the app."
        case .advancedAudioVideo: "Deinterlacing and TrueHD Atmos."
        case .subtitleDisplay: "Use this device's caption appearance."
        case .navigationLayout: "Floating navigation style and behavior."
        case .streaming: "Server-synced playback and cellular quality, audio language, HDR and Dolby Vision."
        case .subtitles: "Profile subtitle preferences."
        case .features: "Opt-in feature preferences."
        case .player: "Server-synced skipping, Next Up, speed, sizing, orientation and seeking."
        case .interface: "Server-synced theme music and title artwork."
        }
    }

    /// Groups whose values belong to the authenticated server's profile or profile-device settings.
    /// They exist only in scoped schema-2 files and restore only to the same server and profile.
    var isServerSynced: Bool {
        switch self {
        case .streaming, .subtitles, .player, .interface: true
        default: false
        }
    }

    // Keep the Sports group identifier for Build 93 imports. Old internal flag IDs remain unknown
    // and are skipped; dashboard-mode IDs are genuine user choices.
    static var portable: [SettingsBackupGroup] { allCases.filter { !$0.isDeviceSpecific } }
    static var deviceSpecific: [SettingsBackupGroup] { allCases.filter(\.isDeviceSpecific) }
    static var defaultSelection: Set<SettingsBackupGroup> { Set(allCases) }
}

// MARK: - Settings

/// One allowlisted setting. `read` and `write` are the owning store's own accessors; `write` must
/// never reach the network or a server-backed contract.
struct BackupSetting {
    let id: String
    let group: SettingsBackupGroup
    let title: String
    let validate: @MainActor (BackupValue) -> Bool
    let read: @MainActor () -> BackupValue?
    let write: @MainActor (BackupValue) throws -> Void
    /// Non-nil when this device cannot use the setting; the text says why.
    let unsupportedReason: @MainActor () -> String?
    let label: @MainActor (BackupValue) -> String

    init(
        id: String,
        group: SettingsBackupGroup,
        title: String,
        validate: @escaping @MainActor (BackupValue) -> Bool,
        read: @escaping @MainActor () -> BackupValue?,
        write: @escaping @MainActor (BackupValue) throws -> Void,
        unsupportedReason: @escaping @MainActor () -> String? = { nil },
        label: @escaping @MainActor (BackupValue) -> String = { $0.plainText }
    ) {
        self.id = id
        self.group = group
        self.title = title
        self.validate = validate
        self.read = read
        self.write = write
        self.unsupportedReason = unsupportedReason
        self.label = label
    }
}

struct SettingsBackupRegistry {
    let settings: [BackupSetting]
    /// "phone" or "pad": the kind of device this registry writes to.
    let deviceIdiom: String

    func setting(id: String) -> BackupSetting? { settings.first { $0.id == id } }
    func settings(in group: SettingsBackupGroup) -> [BackupSetting] { settings.filter { $0.group == group } }
}

// MARK: - Safety limits

enum SettingsBackupSafety {
    static let maxFileBytes = 256 * 1024
    static let maxNestingDepth = 8
    static let maxEntries = 200
    static let maxNameLength = 80
    static let maxStringValueLength = 64
    static let maxRecordMembers = 16
    static let maxArrayMembers = 64
    static let maxStructuredEntries = 1_024

    /// Name fragments that must never appear in a backup, in a group name or a key. A file that has
    /// one is rejected rather than skipped: Kyro never writes it, so it was edited or made elsewhere.
    private static let sensitiveFragments = [
        "token", "password", "passwd", "secret", "credential", "apikey", "api_key", "api-key",
        "bearer", "cookie", "keychain", "session", "authorization", "url", "host",
        "uuid", "profile", "server", "provider", "account", "username", "email", "pairing",
        "diagnostic", "cache", "database",
    ]

    static func isSensitiveName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return sensitiveFragments.contains { lowered.contains($0) }
    }

    /// A value that looks like a link, a credential or a path.
    static func isSuspiciousValue(_ value: BackupValue) -> Bool {
        switch value {
        case .record(let fields): return fields.values.contains(where: isSuspiciousValue)
        case .array(let values): return values.contains(where: isSuspiciousValue)
        case .string(let text):
            if text.count > 256 { return true }
            let lowered = text.lowercased()
            return lowered.contains("://") || lowered.contains("bearer ") || lowered.hasPrefix("/")
                || lowered.contains("..") || text.unicodeScalars.contains { $0.value < 0x20 }
        default: return false
        }
    }
}

// MARK: - Errors

enum SettingsBackupError: Error, Equatable, LocalizedError {
    case tooLarge
    case empty
    case malformed
    case notABackup
    case requiresNewerApp(minReaderVersion: Int)
    case invalidVersion
    case integrityMismatch
    case unsafeContent
    case nothingToExport
    case unreadable
    case registryUnsafe(id: String)

    var errorDescription: String? {
        switch self {
        case .tooLarge: "This file is too large to be a Kyro settings backup."
        case .empty: "This file is empty."
        case .malformed: "This file is damaged or is not a Kyro settings backup. Choose a .kyrosettings file saved from Backup & Restore."
        case .notABackup: "This is not a Kyro settings backup. Choose a .kyrosettings file saved from Backup & Restore."
        case .requiresNewerApp: "This backup was made by a newer version of Kyro. Update Kyro to import it."
        case .invalidVersion: "This backup has an invalid version."
        case .integrityMismatch: "This backup was changed or damaged after it was saved, so it was not imported."
        case .unsafeContent: "This backup contains data Kyro never exports, so it was not imported."
        case .nothingToExport: "There are no settings to export in the groups you chose."
        case .unreadable: "Kyro couldn't read this file."
        case .registryUnsafe(let id): "The setting \(id) cannot be backed up."
        }
    }
}

// MARK: - Document

struct SettingsBackupAppInfo: Equatable, Sendable {
    var version: String
    var build: String
    var platform: String
    /// "phone" or "pad".
    var idiom: String
}

/// Non-secret, one-way identifiers used only to refuse writes to a different destination.
/// No URL, account name, token or raw profile identifier is stored in the document.
struct SettingsBackupScope: Codable, Equatable, Sendable {
    let serverFingerprint: String
    let profileFingerprint: String

    var isValid: Bool {
        [serverFingerprint, profileFingerprint].allSatisfy {
            $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }
}

/// A decoded, validated backup. Nothing in it has been applied.
struct IncomingBackup: Equatable {
    let schemaVersion: Int
    let createdAt: String
    let app: SettingsBackupAppInfo?
    /// Group name → key → value, exactly as read. Names Kyro does not know are kept so the preview
    /// can count what it skipped.
    let groups: [String: [String: BackupValue]]
    let scope: SettingsBackupScope?

    var isNewerThanSupported: Bool { schemaVersion > SettingsBackupCodec.currentSchemaVersion }
}

enum SettingsBackupCodec {
    static let format = "kyro.settings-backup"
    /// Schema 3 adds flat records (the subtitle appearance). A file is written as schema 3, with
    /// `minReaderVersion` 3, only when it contains one; every other file stays schema 2 or 1 so
    /// earlier builds keep reading it.
    static let currentSchemaVersion = 4
    static let recordSchemaVersion = 3
    static let orderedSchemaVersion = 4
    /// The oldest reader that understands every file this build writes.
    static let minReaderVersion = 1
    static let fileExtension = SettingsBackupFileType.fileExtension

    private struct Header: Decodable {
        let format: String
        let schemaVersion: Int
        let minReaderVersion: Int
    }

    private struct AppInfoDTO: Codable {
        var version: String
        var build: String
        var platform: String
        var idiom: String
    }

    private struct Payload: Codable {
        var groups: [String: [String: BackupValue]]
        var scope: SettingsBackupScope?
    }

    private struct Envelope: Codable {
        var format: String
        var schemaVersion: Int
        var minReaderVersion: Int
        var createdAt: String
        var app: AppInfoDTO?
        var payloadSha256: String
        var payload: Payload
    }

    // MARK: Encode

    static func encode(
        values: [(id: String, group: SettingsBackupGroup, value: BackupValue)],
        app: SettingsBackupAppInfo,
        now: Date
    ) throws -> Data {
        var groups: [String: [String: BackupValue]] = [:]
        for entry in values {
            // The exporter only ever takes registered settings, but the document refuses anything
            // sensitive on its own as well.
            guard !SettingsBackupSafety.isSensitiveName(entry.id),
                  !SettingsBackupSafety.isSuspiciousValue(entry.value) else {
                throw SettingsBackupError.registryUnsafe(id: entry.id)
            }
            groups[entry.group.rawValue, default: [:]][entry.id] = entry.value
        }
        guard !groups.isEmpty else { throw SettingsBackupError.nothingToExport }
        return try makeDocument(
            groups: groups, schemaVersion: 1, minReaderVersion: 1, app: app, now: now)
    }

    /// Writes a document with a correct integrity hash. `encode` is the only production caller; tests
    /// use it to build files with other versions or contents.
    static func makeDocument(
        groups: [String: [String: BackupValue]],
        schemaVersion: Int,
        minReaderVersion: Int,
        app: SettingsBackupAppInfo,
        now: Date
    ) throws -> Data {
        let payload = Payload(groups: groups, scope: nil)
        let envelope = Envelope(
            format: format,
            schemaVersion: schemaVersion,
            minReaderVersion: minReaderVersion,
            createdAt: ISO8601DateFormatter().string(from: now),
            app: AppInfoDTO(version: app.version, build: app.build, platform: app.platform, idiom: app.idiom),
            payloadSha256: try hash(of: payload),
            payload: payload
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    /// Schema 2 adds scoped remote values to the same document as the local groups. The scope
    /// participates in the payload hash; schema-1 files keep their original canonical bytes.
    static func makeUnifiedDocument(
        groups: [String: [String: BackupValue]], scope: SettingsBackupScope?,
        app: SettingsBackupAppInfo, now: Date
    ) throws -> Data {
        guard !groups.isEmpty else { throw SettingsBackupError.nothingToExport }
        let hasRecord = groups.values.contains { $0.values.contains(where: \.isRecord) }
        let hasOrdered = groups.values.contains { $0.values.contains(where: \.requiresSchema4) }
        try validateContent(groups, schemaVersion: hasOrdered ? orderedSchemaVersion : (hasRecord ? recordSchemaVersion : 2))
        guard scope?.isValid ?? true else { throw SettingsBackupError.unsafeContent }
        let payload = Payload(groups: groups, scope: scope)
        let envelope = Envelope(
            format: format, schemaVersion: hasOrdered ? orderedSchemaVersion : (hasRecord ? recordSchemaVersion : 2),
            minReaderVersion: hasOrdered ? orderedSchemaVersion : (hasRecord ? recordSchemaVersion : 1),
            createdAt: ISO8601DateFormatter().string(from: now),
            app: AppInfoDTO(version: app.version, build: app.build, platform: app.platform, idiom: app.idiom),
            payloadSha256: try hash(of: payload), payload: payload
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        guard data.count <= SettingsBackupSafety.maxFileBytes else { throw SettingsBackupError.tooLarge }
        return data
    }

    private static func canonicalBytes(of payload: Payload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    private static func hash(of payload: Payload) throws -> String {
        SHA256.hash(data: try canonicalBytes(of: payload)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Decode

    static func decode(_ data: Data) throws -> IncomingBackup {
        guard data.count <= SettingsBackupSafety.maxFileBytes else { throw SettingsBackupError.tooLarge }
        guard !data.isEmpty else { throw SettingsBackupError.empty }
        guard nestingDepth(of: data) <= SettingsBackupSafety.maxNestingDepth else {
            throw SettingsBackupError.malformed
        }

        let decoder = JSONDecoder()
        let header: Header
        do { header = try decoder.decode(Header.self, from: data) } catch { throw SettingsBackupError.malformed }
        guard header.format == format else { throw SettingsBackupError.notABackup }
        guard header.schemaVersion >= 1, header.minReaderVersion >= 1,
              header.minReaderVersion <= header.schemaVersion else {
            throw SettingsBackupError.invalidVersion
        }
        // A newer file that this build cannot read in full is refused before its payload is looked at.
        guard header.minReaderVersion <= currentSchemaVersion else {
            throw SettingsBackupError.requiresNewerApp(minReaderVersion: header.minReaderVersion)
        }

        let envelope: Envelope
        do { envelope = try decoder.decode(Envelope.self, from: data) } catch { throw SettingsBackupError.malformed }

        try validateContent(envelope.payload.groups, schemaVersion: header.schemaVersion)
        if header.schemaVersion < recordSchemaVersion,
           envelope.payload.groups.values.contains(where: { $0.values.contains(where: \.isRecord) }) {
            throw SettingsBackupError.unsafeContent
        }
        if header.schemaVersion < orderedSchemaVersion,
           envelope.payload.groups.values.contains(where: { $0.values.contains(where: \.requiresSchema4) }) {
            throw SettingsBackupError.unsafeContent
        }
        guard envelope.payload.scope?.isValid ?? true else { throw SettingsBackupError.unsafeContent }
        if header.schemaVersion == 1, envelope.payload.scope != nil { throw SettingsBackupError.unsafeContent }
        if envelope.payload.groups.keys.contains(where: { SettingsBackupGroup(rawValue: $0)?.isServerSynced == true }) {
            guard header.schemaVersion >= 2, envelope.payload.scope != nil else {
                throw SettingsBackupError.unsafeContent
            }
        }

        guard envelope.payloadSha256.lowercased() == (try hash(of: envelope.payload)) else {
            throw SettingsBackupError.integrityMismatch
        }

        return IncomingBackup(
            schemaVersion: header.schemaVersion,
            createdAt: envelope.createdAt,
            app: envelope.app.map {
                SettingsBackupAppInfo(version: $0.version, build: $0.build, platform: $0.platform, idiom: $0.idiom)
            },
            groups: envelope.payload.groups, scope: envelope.payload.scope
        )
    }

    private static func validateContent(_ groups: [String: [String: BackupValue]], schemaVersion: Int) throws {
        var entries = 0
        func validate(_ value: BackupValue, depth: Int) throws {
            entries += 1
            guard entries <= (schemaVersion >= orderedSchemaVersion
                        ? SettingsBackupSafety.maxStructuredEntries : SettingsBackupSafety.maxEntries), depth <= 4,
                  !SettingsBackupSafety.isSuspiciousValue(value) else { throw SettingsBackupError.unsafeContent }
            switch value {
            case .string(let text):
                guard text.count <= (schemaVersion >= orderedSchemaVersion ? 256 : SettingsBackupSafety.maxStringValueLength)
                else { throw SettingsBackupError.unsafeContent }
            case .record(let fields):
                guard !fields.isEmpty, fields.count <= SettingsBackupSafety.maxRecordMembers else {
                    throw SettingsBackupError.unsafeContent
                }
                for (name, member) in fields {
                    guard name.count <= SettingsBackupSafety.maxNameLength,
                          !SettingsBackupSafety.isSensitiveName(name) else { throw SettingsBackupError.unsafeContent }
                    try validate(member, depth: depth + 1)
                }
            case .array(let values):
                guard values.count <= SettingsBackupSafety.maxArrayMembers else { throw SettingsBackupError.unsafeContent }
                for member in values { try validate(member, depth: depth + 1) }
            default: break
            }
        }
        for (groupName, values) in groups {
            guard groupName.count <= SettingsBackupSafety.maxNameLength,
                  !SettingsBackupSafety.isSensitiveName(groupName) else {
                throw SettingsBackupError.unsafeContent
            }
            for (key, value) in values {
                guard key.count <= SettingsBackupSafety.maxNameLength,
                      !SettingsBackupSafety.isSensitiveName(key) else {
                    throw SettingsBackupError.unsafeContent
                }
                try validate(value, depth: 0)
            }
        }
    }

    /// The deepest `{`/`[` nesting in the raw bytes, ignoring brackets inside strings. Checked before
    /// decoding so a file made of thousands of opening brackets never reaches the parser.
    static func nestingDepth(of data: Data) -> Int {
        var depth = 0
        var deepest = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22: inString = true
            case 0x7B, 0x5B:
                depth += 1
                deepest = max(deepest, depth)
                if deepest > SettingsBackupSafety.maxNestingDepth { return deepest }
            case 0x7D, 0x5D: depth = max(0, depth - 1)
            default: break
            }
        }
        return deepest
    }
}

// MARK: - Export

enum SettingsBackupExporter {
    /// Builds a backup of the chosen groups from the registered settings only. A setting this device
    /// cannot use, or cannot read, is left out.
    @MainActor
    static func export(
        registry: SettingsBackupRegistry,
        groups: Set<SettingsBackupGroup>,
        app: SettingsBackupAppInfo,
        now: Date = Date()
    ) throws -> Data {
        var values: [(id: String, group: SettingsBackupGroup, value: BackupValue)] = []
        for setting in registry.settings where groups.contains(setting.group) {
            guard setting.unsupportedReason() == nil, let value = setting.read(), setting.validate(value) else { continue }
            values.append((setting.id, setting.group, value))
        }
        return try SettingsBackupCodec.encode(values: values, app: app, now: now)
    }
}
#endif
