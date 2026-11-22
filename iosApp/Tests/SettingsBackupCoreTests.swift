#if os(iOS) || KYRO_STANDALONE_TESTS
import XCTest
import UniformTypeIdentifiers
@testable import Silo

// Build 88 core tests. They use in-memory settings and an in-memory restore point, never live
// account settings, the network or the Keychain.

@MainActor
final class BackupFakeStore {
    var values: [String: BackupValue]
    /// Every write attempted, in order.
    private(set) var writes: [String] = []
    /// A write of this id with this value throws.
    var failWrite: (String, BackupValue) -> Bool = { _, _ in false }
    /// A write of this id succeeds but the store keeps its old value.
    var ignoreWrite: (String, BackupValue) -> Bool = { _, _ in false }

    init(_ values: [String: BackupValue]) { self.values = values }

    struct WriteFailed: Error {}

    func registry(idiom: String = "phone", unsupported: Set<String> = []) -> SettingsBackupRegistry {
        let defs: [(String, SettingsBackupGroup, String, BackupValue)] = [
            ("navigation.fourthTab", .navigation, "Fourth tab", .string("sports")),
            ("liveTV.categoryAppearance", .liveTVCategories, "Category layout", .string("Hybrid")),
            ("downloads.wifiOnly", .downloads, "Download on Wi-Fi only", .bool(true)),
            ("downloads.simultaneous", .downloads, "Simultaneous downloads", .int(2)),
            ("sports.tennisNews", .sports, "Tennis news", .bool(true)),
            ("playback.bufferAhead", .playbackOptions, "Buffer ahead", .string("automatic")),
            ("pip.backgroundPlayback", .pictureInPicture, "Background playback", .bool(false)),
            ("nav.style", .navigationLayout, "Navigation style", .string("classic")),
        ]
        let settings = defs.map { id, group, title, sample -> BackupSetting in
            BackupSetting(
                id: id, group: group, title: title,
                validate: { value in
                    switch (sample, value) {
                    case (.bool, .bool): return true
                    case (.int, .int(let n)): return (1...4).contains(n)
                    case (.string, .string(let s)):
                        switch id {
                        case "navigation.fourthTab": return ["sports", "forYou", "favorites"].contains(s)
                        case "liveTV.categoryAppearance": return ["List", "Hybrid", "Grid"].contains(s)
                        case "playback.bufferAhead": return ["automatic", "standard", "extended", "unlimited"].contains(s)
                        default: return ["classic", "glassDock", "thumbFan"].contains(s)
                        }
                    default: return false
                    }
                },
                read: { [self] in values[id] },
                write: { [self] value in
                    writes.append(id)
                    if failWrite(id, value) { throw WriteFailed() }
                    if ignoreWrite(id, value) { return }
                    values[id] = value
                },
                unsupportedReason: { unsupported.contains(id) ? "Not available here." : nil })
        }
        return SettingsBackupRegistry(settings: settings, deviceIdiom: idiom)
    }
}

final class BackupMemoryJournal: RestoreJournalStoring {
    var journal: RestoreJournal?
    var failSave = false
    /// Saves fail once this many have succeeded.
    var failSaveAfter: Int?
    var failClear = false
    private(set) var saves = 0
    func load() throws -> RestoreJournal? { journal }
    func save(_ journal: RestoreJournal) throws {
        if failSave || (failSaveAfter.map { saves >= $0 } ?? false) { throw BackupFakeStoreError.journal }
        saves += 1
        self.journal = journal
    }
    func clear() throws {
        if failClear { throw BackupFakeStoreError.journal }
        journal = nil
    }
}
enum BackupFakeStoreError: Error { case journal }

@MainActor
final class SettingsBackupCoreTests: XCTestCase {
    private let app = SettingsBackupAppInfo(version: "1.0.0", build: "88", platform: "iOS", idiom: "phone")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func baseValues() -> [String: BackupValue] {
        [
            "navigation.fourthTab": .string("sports"),
            "liveTV.categoryAppearance": .string("Hybrid"),
            "downloads.wifiOnly": .bool(true),
            "downloads.simultaneous": .int(2),
            "sports.tennisNews": .bool(true),
            "playback.bufferAhead": .string("automatic"),
            "pip.backgroundPlayback": .bool(false),
            "nav.style": .string("classic"),
        ]
    }

    private func changedValues() -> [String: BackupValue] {
        [
            "navigation.fourthTab": .string("favorites"),
            "liveTV.categoryAppearance": .string("Grid"),
            "downloads.wifiOnly": .bool(false),
            "downloads.simultaneous": .int(4),
            "sports.tennisNews": .bool(false),
            "playback.bufferAhead": .string("extended"),
            "pip.backgroundPlayback": .bool(true),
            "nav.style": .string("glassDock"),
        ]
    }

    private func document(
        _ groups: [String: [String: BackupValue]], schema: Int = 1, minReader: Int = 1, idiom: String = "phone"
    ) throws -> Data {
        try SettingsBackupCodec.makeDocument(
            groups: groups, schemaVersion: schema, minReaderVersion: minReader,
            app: SettingsBackupAppInfo(version: "1.0.0", build: "88", platform: "iOS", idiom: idiom), now: now)
    }

    private func sourceBackup(groups: Set<SettingsBackupGroup>, idiom: String = "phone") throws -> Data {
        let source = BackupFakeStore(changedValues())
        return try SettingsBackupExporter.export(
            registry: source.registry(idiom: idiom), groups: groups,
            app: SettingsBackupAppInfo(version: "1.0.0", build: "88", platform: "iOS", idiom: idiom), now: now)
    }

    private func makeApplier(_ store: BackupFakeStore, _ journal: BackupMemoryJournal, idiom: String = "phone") -> SettingsBackupApplier {
        SettingsBackupApplier(registry: store.registry(idiom: idiom), journal: journal, now: { self.now })
    }

    private func preview(_ data: Data, _ store: BackupFakeStore, idiom: String = "phone") throws -> RestorePreview {
        SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(data), registry: store.registry(idiom: idiom))
    }

    // MARK: Round trip, groups

    func testExportImportRoundTripRestoresEveryValue() throws {
        let data = try sourceBackup(groups: Set(SettingsBackupGroup.allCases))
        let store = BackupFakeStore(baseValues())
        let result = try preview(data, store)
        XCTAssertEqual(result.totalChanges, 8)
        let outcome = makeApplier(store, BackupMemoryJournal()).apply(preview: result, selectedGroups: Set(SettingsBackupGroup.allCases))
        guard case .applied(let changes, true) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(changes.count, 8)
        XCTAssertEqual(store.values, changedValues())
    }

    func testDefaultExportIncludesSafeLocalDeviceGroups() throws {
        let data = try sourceBackup(groups: SettingsBackupGroup.defaultSelection)
        let incoming = try SettingsBackupCodec.decode(data)
        XCTAssertEqual(Set(incoming.groups.keys), Set([
            "navigation", "liveTVCategories", "downloads", "playbackOptions", "pictureInPicture", "navigationLayout"
        ]))
        XCTAssertNil(incoming.groups["sports"])
    }

    func testDeviceSpecificGroupCanStillBeExcluded() throws {
        let data = try sourceBackup(groups: SettingsBackupGroup.defaultSelection.subtracting([.playbackOptions]))
        let incoming = try SettingsBackupCodec.decode(data)
        XCTAssertNil(incoming.groups["playbackOptions"])
        XCTAssertNotNil(incoming.groups["navigationLayout"])
    }

    func testUnsupportedSettingIsLeftOutOfExport() throws {
        let source = BackupFakeStore(changedValues())
        let data = try SettingsBackupExporter.export(
            registry: source.registry(unsupported: ["pip.backgroundPlayback"]), groups: [.pictureInPicture, .navigation], app: app, now: now)
        XCTAssertNil(try SettingsBackupCodec.decode(data).groups["pictureInPicture"])
    }

    func testEmptySelectionCannotBeExported() {
        let source = BackupFakeStore(changedValues())
        XCTAssertThrowsError(try SettingsBackupExporter.export(registry: source.registry(), groups: [], app: app, now: now)) {
            XCTAssertEqual($0 as? SettingsBackupError, .nothingToExport)
        }
    }

    // MARK: Device compatibility

    func testDeviceSpecificGroupFromAnotherIdiomIsUnsupportedAndNotWritten() throws {
        let data = try sourceBackup(groups: [.playbackOptions, .navigation], idiom: "pad")
        let store = BackupFakeStore(baseValues())
        let result = try preview(data, store, idiom: "phone")
        let device = try XCTUnwrap(result.groups.first { $0.group == .playbackOptions })
        XCTAssertNotNil(device.groupUnsupportedReason)
        XCTAssertFalse(device.canRestore)
        // Even when a caller selects it, it is not applied.
        _ = makeApplier(store, BackupMemoryJournal()).apply(preview: result, selectedGroups: [.playbackOptions, .navigation])
        XCTAssertEqual(store.values["playback.bufferAhead"], .string("automatic"))
        XCTAssertEqual(store.values["navigation.fourthTab"], .string("favorites"))
    }

    func testDeviceSpecificGroupRestoresOnSameIdiom() throws {
        let data = try sourceBackup(groups: [.playbackOptions])
        let store = BackupFakeStore(baseValues())
        let result = try preview(data, store)
        XCTAssertTrue(try XCTUnwrap(result.groups.first).canRestore)
    }

    func testSettingUnsupportedOnThisDeviceIsSkipped() throws {
        let data = try sourceBackup(groups: [.pictureInPicture])
        let store = BackupFakeStore(baseValues())
        let result = SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(data), registry: store.registry(unsupported: ["pip.backgroundPlayback"]))
        XCTAssertEqual(result.groups.first?.items.first?.status, .unsupported("Not available here."))
        XCTAssertEqual(result.totalChanges, 0)
    }

    // MARK: Malformed and unsafe files

    func testMalformedFilesAreRejected() {
        let bad: [Data] = [
            Data(), Data("not json".utf8), Data("{".utf8), Data("[]".utf8), Data("{}".utf8),
            Data(#"{"format":"kyro.settings-backup","schemaVersion":1,"minReaderVersion":1}"#.utf8),
            Data(#"{"format":"kyro.settings-backup","schemaVersion":1,"minReaderVersion":1,"createdAt":"x","payloadSha256":"00","payload":{"groups":{"navigation":{"a":1.5}}}}"#.utf8),
            Data(#"{"format":"kyro.settings-backup","schemaVersion":1,"minReaderVersion":1,"createdAt":"x","payloadSha256":"00","payload":{"groups":{"navigation":{"a":null}}}}"#.utf8),
            Data(#"{"format":"kyro.settings-backup","schemaVersion":1,"minReaderVersion":1,"createdAt":"x","payloadSha256":"00","payload":{"groups":{"navigation":{"a":{"b":1}}}}}"#.utf8),
            Data(#"{"format":"kyro.settings-backup","schemaVersion":1,"minReaderVersion":1,"createdAt":"x","payloadSha256":"00","payload":{"groups":{"navigation":{"a":[1]}}}}"#.utf8),
        ]
        for data in bad {
            XCTAssertThrowsError(try SettingsBackupCodec.decode(data), String(decoding: data.prefix(60), as: UTF8.self))
        }
    }

    func testWrongFormatIsNotABackup() {
        let data = Data(#"{"format":"something.else","schemaVersion":1,"minReaderVersion":1}"#.utf8)
        XCTAssertThrowsError(try SettingsBackupCodec.decode(data)) { XCTAssertEqual($0 as? SettingsBackupError, .notABackup) }
    }

    func testInvalidVersionsAreRejected() throws {
        for (schema, minReader) in [(0, 1), (1, 0), (1, 2), (-1, -1)] {
            let data = try document(["navigation": ["navigation.fourthTab": .string("sports")]], schema: schema, minReader: minReader)
            XCTAssertThrowsError(try SettingsBackupCodec.decode(data), "\(schema)/\(minReader)")
        }
    }

    func testOversizedFileIsRejectedBeforeParsing() {
        let data = Data(repeating: 0x20, count: SettingsBackupSafety.maxFileBytes + 1)
        XCTAssertThrowsError(try SettingsBackupCodec.decode(data)) { XCTAssertEqual($0 as? SettingsBackupError, .tooLarge) }
    }

    func testDeeplyNestedFileIsRejected() {
        let data = Data(String(repeating: "[", count: 100_000).utf8)
        XCTAssertThrowsError(try SettingsBackupCodec.decode(data)) { XCTAssertEqual($0 as? SettingsBackupError, .malformed) }
    }

    func testBracketsInsideStringsDoNotCountAsNesting() {
        XCTAssertLessThanOrEqual(SettingsBackupCodec.nestingDepth(of: Data(#"{"a":"[[[[[[[[[[[[[[[[[[["}"#.utf8)), 1)
    }

    func testChangedValueFailsIntegrityCheck() throws {
        let text = String(decoding: try sourceBackup(groups: [.downloads]), as: UTF8.self)
        let tampered = text.replacingOccurrences(of: "\"downloads.simultaneous\" : 4", with: "\"downloads.simultaneous\" : 1")
        XCTAssertNotEqual(text, tampered)
        XCTAssertThrowsError(try SettingsBackupCodec.decode(Data(tampered.utf8))) {
            XCTAssertEqual($0 as? SettingsBackupError, .integrityMismatch)
        }
    }

    func testWrongHashFailsIntegrityCheck() throws {
        let text = String(decoding: try sourceBackup(groups: [.downloads]), as: UTF8.self)
        let hash = try XCTUnwrap(text.range(of: #"(?<="payloadSha256" : ")[0-9a-f]{64}"#, options: .regularExpression))
        let tampered = text.replacingCharacters(in: hash, with: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try SettingsBackupCodec.decode(Data(tampered.utf8))) {
            XCTAssertEqual($0 as? SettingsBackupError, .integrityMismatch)
        }
    }

    // MARK: Sensitive data

    func testNoRegisteredIdentifierLooksSensitive() {
        let registry = BackupFakeStore(baseValues()).registry()
        for setting in registry.settings { XCTAssertFalse(SettingsBackupSafety.isSensitiveName(setting.id), setting.id) }
        for group in SettingsBackupGroup.allCases { XCTAssertFalse(SettingsBackupSafety.isSensitiveName(group.rawValue), group.rawValue) }
    }

    func testExportedFileCarriesNoUrlOrIdentifier() throws {
        let text = String(decoding: try sourceBackup(groups: Set(SettingsBackupGroup.allCases)), as: UTF8.self).lowercased()
        for forbidden in ["http", "://", "password", "token", "secret", "keychain", "uuid", "server", "profile", "provider"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        XCTAssertNil(text.range(of: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", options: .regularExpression))
    }

    func testFilesWithSensitiveNamesOrValuesAreRejected() throws {
        let cases: [[String: [String: BackupValue]]] = [
            ["navigation": ["accessToken": .string("x")]],
            ["navigation": ["navigation.fourthTab": .string("sports"), "password": .string("x")]],
            ["liveTVProviders": ["name": .string("x")]],
            ["navigation": ["navigation.fourthTab": .string("https://example.com/a")]],
            ["navigation": ["navigation.fourthTab": .string("Bearer abc")]],
            ["navigation": ["navigation.fourthTab": .string(String(repeating: "a", count: 200))]],
            ["navigation": ["serverUrl": .string("x")]],
            ["navigation": ["profileId": .string("x")]],
        ]
        for groups in cases {
            XCTAssertThrowsError(try SettingsBackupCodec.decode(try document(groups)), "\(groups)") {
                XCTAssertEqual($0 as? SettingsBackupError, .unsafeContent)
            }
        }
    }

    func testEncodingASensitiveIdentifierIsRefused() {
        XCTAssertThrowsError(try SettingsBackupCodec.encode(values: [("apiToken", .navigation, .string("x"))], app: app, now: now)) {
            XCTAssertEqual($0 as? SettingsBackupError, .registryUnsafe(id: "apiToken"))
        }
    }

    func testTooManyEntriesAreRejected() throws {
        var values: [String: BackupValue] = [:]
        for index in 0..<(SettingsBackupSafety.maxEntries + 1) { values["setting\(index)"] = .int(index) }
        XCTAssertThrowsError(try SettingsBackupCodec.decode(try document(["navigation": values]))) {
            XCTAssertEqual($0 as? SettingsBackupError, .unsafeContent)
        }
    }

    // MARK: Values, unknown keys, versions

    func testInvalidEnumAndOutOfRangeValuesAreSkippedNotApplied() throws {
        let data = try document(["navigation": ["navigation.fourthTab": .string("hologram")],
                                 "downloads": ["downloads.simultaneous": .int(99), "downloads.wifiOnly": .string("yes")]])
        let store = BackupFakeStore(baseValues())
        let result = try preview(data, store)
        XCTAssertEqual(result.totalChanges, 0)
        for item in result.groups.flatMap(\.items) {
            guard case .invalid = item.status else { return XCTFail("\(item.id): \(item.status)") }
        }
        let outcome = makeApplier(store, BackupMemoryJournal()).apply(preview: result, selectedGroups: Set(SettingsBackupGroup.allCases))
        XCTAssertEqual(outcome, .nothingToApply)
        XCTAssertEqual(store.values, baseValues())
    }

    func testUnknownGroupsAndKeysAreCountedAndIgnored() throws {
        let data = try document([
            "navigation": ["navigation.fourthTab": .string("forYou"), "navigation.futureThing": .bool(true)],
            "holograms": ["a": .int(1), "b": .int(2)],
        ])
        let store = BackupFakeStore(baseValues())
        let result = try preview(data, store)
        XCTAssertEqual(result.unrecognizedGroups, 1)
        XCTAssertEqual(result.unrecognizedSettings, 3)
        XCTAssertEqual(result.totalChanges, 1)
    }

    func testFutureSchemaWithOldEnoughReaderVersionIsAccepted() throws {
        let data = try document(["navigation": ["navigation.fourthTab": .string("forYou")]], schema: 4, minReader: 1)
        let incoming = try SettingsBackupCodec.decode(data)
        XCTAssertTrue(incoming.isNewerThanSupported)
        XCTAssertTrue(try preview(data, BackupFakeStore(baseValues())).isNewerThanSupported)
    }

    func testFutureSchemaThatNeedsANewerReaderIsRefusedWithAClearError() throws {
        let data = try document(["navigation": ["navigation.fourthTab": .string("forYou")]], schema: 5, minReader: 4)
        XCTAssertThrowsError(try SettingsBackupCodec.decode(data)) {
            XCTAssertEqual($0 as? SettingsBackupError, .requiresNewerApp(minReaderVersion: 4))
            XCTAssertNotNil(($0 as? SettingsBackupError)?.errorDescription)
        }
    }

    func testFutureTopLevelFieldsAreIgnored() throws {
        let text = String(decoding: try sourceBackup(groups: [.navigation]), as: UTF8.self)
        let open = try XCTUnwrap(text.range(of: "{\n"))
        let withFuture = text.replacingCharacters(in: open, with: "{\n  \"futureField\" : {\"nested\": [1, 2]},\n")
        XCTAssertNoThrow(try SettingsBackupCodec.decode(Data(withFuture.utf8)))
    }

    // MARK: Preview and cancel

    func testPreviewShowsCurrentAndIncomingAndUnchanged() throws {
        let data = try document(["downloads": ["downloads.wifiOnly": .bool(false), "downloads.simultaneous": .int(2)]])
        let store = BackupFakeStore(baseValues())
        let items = try preview(data, store).groups.flatMap(\.items)
        let changed = try XCTUnwrap(items.first { $0.id == "downloads.wifiOnly" })
        XCTAssertEqual(changed.status, .willChange)
        XCTAssertEqual(changed.current, "On")
        XCTAssertEqual(changed.incoming, "Off")
        XCTAssertEqual(items.first { $0.id == "downloads.simultaneous" }?.status, .unchanged)
    }

    func testPreviewAndCancelNeverWrite() throws {
        let store = BackupFakeStore(baseValues())
        let journal = BackupMemoryJournal()
        let model = SettingsBackupModel(registry: store.registry(), journal: journal, app: app, now: { self.now })
        model.loadImport(data: try sourceBackup(groups: Set(SettingsBackupGroup.allCases)))
        XCTAssertNotNil(model.preview)
        XCTAssertGreaterThan(model.selectedChangeCount, 0)
        model.cancelImport()
        XCTAssertNil(model.preview)
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertNil(journal.journal)
        XCTAssertEqual(store.values, baseValues())
    }

    func testImportDefaultsSelectPortableGroupsOnly() throws {
        let store = BackupFakeStore(baseValues())
        let model = SettingsBackupModel(registry: store.registry(), journal: BackupMemoryJournal(), app: app)
        model.loadImport(data: try sourceBackup(groups: Set(SettingsBackupGroup.allCases)))
        XCTAssertEqual(model.importSelection, Set(["navigation", "liveTVCategories", "downloads", "sports"].compactMap(SettingsBackupGroup.init(rawValue:))))
    }

    func testReviewSelectsOnlyDifferencesAndCanRestoreOneSetting() throws {
        let store = BackupFakeStore(baseValues())
        let journal = BackupMemoryJournal()
        let model = SettingsBackupModel(registry: store.registry(), journal: journal, app: app)
        model.loadImport(data: try sourceBackup(groups: [.navigation, .downloads]))
        XCTAssertEqual(model.selectedChangeCount, 3)
        XCTAssertEqual(model.selectedSettingIDs, Set(["navigation.fourthTab", "downloads.wifiOnly", "downloads.simultaneous"]))

        model.setImport("downloads.wifiOnly", enabled: false)
        model.setImport("downloads.simultaneous", enabled: false)
        XCTAssertEqual(model.selectedChangeCount, 1)
        model.applySelected()

        XCTAssertEqual(store.writes, ["navigation.fourthTab"])
        XCTAssertEqual(store.values["navigation.fourthTab"], .string("favorites"))
        XCTAssertEqual(store.values["downloads.wifiOnly"], .bool(true))
        XCTAssertEqual(store.values["downloads.simultaneous"], .int(2))
        XCTAssertEqual(model.lastRestoredCount, 1)
        XCTAssertTrue(model.undoAvailable)

        model.undo()
        XCTAssertEqual(store.values, baseValues())
        XCTAssertFalse(model.undoAvailable)
    }

    func testUnchangedBackupHasNoSelectedDifferencesAndWritesNothing() throws {
        let store = BackupFakeStore(baseValues())
        let model = SettingsBackupModel(registry: store.registry(), journal: BackupMemoryJournal(), app: app)
        let data = try SettingsBackupExporter.export(
            registry: store.registry(), groups: SettingsBackupGroup.defaultSelection, app: app, now: now)
        model.loadImport(data: data)
        XCTAssertEqual(model.preview?.totalChanges, 0)
        XCTAssertTrue(model.selectedSettingIDs.isEmpty)
        model.applySelected()
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertNil(model.lastRestoredCount)
    }

    func testReviewPreservesExcludedDeviceSpecificValues() throws {
        let store = BackupFakeStore(baseValues())
        let model = SettingsBackupModel(registry: store.registry(), journal: BackupMemoryJournal(), app: app)
        model.loadImport(data: try sourceBackup(groups: [.navigation, .navigationLayout]))
        XCTAssertEqual(model.selectedSettingIDs, ["navigation.fourthTab"])
        model.applySelected()
        XCTAssertEqual(store.values["nav.style"], .string("classic"))
        XCTAssertEqual(store.writes, ["navigation.fourthTab"])
    }

    func testRejectedImportShowsErrorAndLoadsNothing() {
        let store = BackupFakeStore(baseValues())
        let model = SettingsBackupModel(registry: store.registry(), journal: BackupMemoryJournal(), app: app)
        model.loadImport(data: Data("nope".utf8))
        XCTAssertNil(model.preview)
        XCTAssertEqual(model.banner?.kind, .failure)
        XCTAssertTrue(store.writes.isEmpty)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kyro-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testImportingFromFileEnforcesTheSizeLimit() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let big = directory.appendingPathComponent("big.kyrosettings")
        try Data(repeating: 0x20, count: SettingsBackupSafety.maxFileBytes + 10).write(to: big)
        let good = directory.appendingPathComponent("good.kyrosettings")
        try sourceBackup(groups: [.navigation]).write(to: good)

        let model = SettingsBackupModel(registry: BackupFakeStore(baseValues()).registry(), journal: BackupMemoryJournal(), app: app)
        await model.loadImport(from: big)
        XCTAssertNil(model.preview)
        XCTAssertEqual(model.banner?.text, SettingsBackupError.tooLarge.errorDescription)
        await model.loadImport(from: good)
        XCTAssertNotNil(model.preview)
        await model.loadImport(from: directory.appendingPathComponent("missing.kyrosettings"))
        XCTAssertNil(model.preview)
    }

    // MARK: File picker registration

    func testTheImporterNamesTheRegisteredBackupTypeAndAcceptsProviderFallbacks() {
        let identifiers = SettingsBackupFileType.importerTypes.map(\.identifier)
        XCTAssertEqual(identifiers.first, SettingsBackupFileType.exportIdentifier)
        XCTAssertTrue(identifiers.contains(UTType.json.identifier))
        XCTAssertTrue(identifiers.contains(UTType.data.identifier))
        XCTAssertTrue(identifiers.contains(UTType.item.identifier))
    }

    func testBackupFilesAreNamedKyrosettings() {
        XCTAssertEqual(SettingsBackupFileType.fileExtension, "kyrosettings")
        XCTAssertEqual(SettingsBackupCodec.fileExtension, "kyrosettings")
        XCTAssertEqual(SettingsBackupFileType.exportType.preferredFilenameExtension, "kyrosettings")
    }

    func testTheBackupExtensionResolvesToAnAllowedImporterType() throws {
        let reported = try XCTUnwrap(UTType(filenameExtension: "kyrosettings"))
        XCTAssertEqual(reported.identifier, SettingsBackupFileType.exportIdentifier)
        XCTAssertTrue(SettingsBackupFileType.importerTypes.contains { $0.identifier == reported.identifier })
    }

    func testInfoPlistDeclaresTheExportedTypeAsJsonAndData() throws {
        // The source plist of the iOS app target, found relative to this file.
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("iosApp/Info.plist")
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)
        let info = try XCTUnwrap(object as? [String: Any])
        let declarations = try XCTUnwrap(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        let declaration = try XCTUnwrap(declarations.first { $0["UTTypeIdentifier"] as? String == SettingsBackupFileType.exportIdentifier })
        let conforms = try XCTUnwrap(declaration["UTTypeConformsTo"] as? [String])
        XCTAssertTrue(conforms.contains("public.json"))
        XCTAssertTrue(conforms.contains("public.data"))
        let tags = try XCTUnwrap(declaration["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], ["kyrosettings"])
        // The Files app already identifies the exported file as Kyro Settings Backup. Declaring
        // an external document handler is unnecessary for import through an in-app picker.
        XCTAssertNil(info["CFBundleDocumentTypes"])
        XCTAssertNil(info["LSSupportsOpeningDocumentsInPlace"])
    }

    func testValidBackupsLoadFromAnyFileNameAndExtension() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["Kyro Settings.kyrosettings", "backup.json", "backup", "backup.txt", "Kyro Settings 2026-11-17 (1).kyrosettings"] {
            let url = directory.appendingPathComponent(name)
            try sourceBackup(groups: Set(SettingsBackupGroup.portable)).write(to: url)
            let store = BackupFakeStore(baseValues())
            let model = SettingsBackupModel(registry: store.registry(), journal: BackupMemoryJournal(), app: app)
            await model.loadImport(from: url)
            XCTAssertNotNil(model.preview, name)
            XCTAssertNil(model.banner, name)
            XCTAssertTrue(store.writes.isEmpty, "a preview never writes (\(name))")
        }
    }

    func testInvalidFilesAreRejectedWithAMessageAndNothingChanges() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
        let cases: [(String, Data)] = [
            ("photo.png", png),
            ("notes.txt", Data("shopping list".utf8)),
            ("empty.kyrosettings", Data()),
            ("other.json", Data(#"{"hello":"world"}"#.utf8)),
            ("truncated.kyrosettings", Data(try sourceBackup(groups: [.navigation]).prefix(40))),
        ]
        for (name, data) in cases {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            let store = BackupFakeStore(baseValues())
            let journal = BackupMemoryJournal()
            let model = SettingsBackupModel(registry: store.registry(), journal: journal, app: app)
            await model.loadImport(from: url)
            XCTAssertNil(model.preview, name)
            XCTAssertEqual(model.banner?.kind, .failure, name)
            XCTAssertFalse((model.banner?.text ?? "").isEmpty, name)
            XCTAssertTrue(store.writes.isEmpty, name)
            XCTAssertNil(journal.journal, name)
            XCTAssertEqual(store.values, baseValues(), name)
        }
        // A folder, as the picker can hand over by mistake.
        let folder = directory.appendingPathComponent("folder.kyrosettings")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = SettingsBackupModel(registry: BackupFakeStore(baseValues()).registry(), journal: BackupMemoryJournal(), app: app)
        await model.loadImport(from: folder)
        XCTAssertNil(model.preview)
        XCTAssertEqual(model.banner?.kind, .failure)
    }

    func testTheErrorForANonBackupNamesTheFileToChoose() {
        XCTAssertTrue(SettingsBackupError.malformed.errorDescription?.contains(".kyrosettings") == true)
        XCTAssertTrue(SettingsBackupError.notABackup.errorDescription?.contains(".kyrosettings") == true)
    }

    // MARK: Apply

    func testUnselectedGroupsAndSettingsNotInTheBackupAreUntouched() throws {
        // Only downloads values are in the file, and only navigation is selected.
        let data = try document(["downloads": ["downloads.wifiOnly": .bool(false)], "navigation": ["navigation.fourthTab": .string("forYou")]])
        var start = baseValues()
        start["sports.tennisNews"] = .bool(false)
        let store = BackupFakeStore(start)
        let result = try preview(data, store)
        let outcome = makeApplier(store, BackupMemoryJournal()).apply(preview: result, selectedGroups: [.navigation])
        guard case .applied(let changes, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(changes.map(\.id), ["navigation.fourthTab"])
        XCTAssertEqual(store.writes, ["navigation.fourthTab"])
        var expected = start
        expected["navigation.fourthTab"] = .string("forYou")
        XCTAssertEqual(store.values, expected)
    }

    func testApplyWritesInAFixedOrder() throws {
        let store = BackupFakeStore(baseValues())
        let result = try preview(try sourceBackup(groups: Set(SettingsBackupGroup.portable)), store)
        _ = makeApplier(store, BackupMemoryJournal()).apply(preview: result, selectedGroups: Set(SettingsBackupGroup.portable))
        // Group order, then registry order inside a group, so a restore always writes the same way.
        let expected = SettingsBackupGroup.portable.flatMap { store.registry().settings(in: $0).map(\.id) }
        XCTAssertEqual(store.writes, expected)
    }

    func testRestorePointIsSavedBeforeTheFirstWrite() throws {
        let store = BackupFakeStore(baseValues())
        let journal = BackupMemoryJournal()
        store.failWrite = { _, _ in
            XCTAssertEqual(journal.journal?.state, .applying)
            return false
        }
        let result = try preview(try sourceBackup(groups: [.navigation]), store)
        _ = makeApplier(store, journal).apply(preview: result, selectedGroups: [.navigation])
        XCTAssertEqual(journal.journal?.state, .applied)
    }

    func testFailureToSaveRestorePointChangesNothing() throws {
        let store = BackupFakeStore(baseValues())
        let journal = BackupMemoryJournal()
        journal.failSave = true
        let result = try preview(try sourceBackup(groups: Set(SettingsBackupGroup.portable)), store)
        let outcome = makeApplier(store, journal).apply(preview: result, selectedGroups: Set(SettingsBackupGroup.portable))
        guard case .failed(nil, _, let report) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(report.restored.isEmpty && report.unrestored.isEmpty)
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertEqual(store.values, baseValues())
    }

    func testPartialFailureRollsBackEarlierWrites() throws {
        let store = BackupFakeStore(baseValues())
        let journal = BackupMemoryJournal()
        store.failWrite = { id, value in id == "downloads.simultaneous" && value == .int(4) }
        let result = try preview(try sourceBackup(groups: Set(SettingsBackupGroup.portable)), store)
        let outcome = makeApplier(store, journal).apply(preview: result, selectedGroups: Set(SettingsBackupGroup.portable))
        guard case .failed(let failedID, _, let report) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(failedID, "downloads.simultaneous")
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(store.values, baseValues())
        XCTAssertNil(journal.journal)
    }

    func testValueThatIsNotKeptCountsAsAFailureAndIsRolledBack() throws {
        let store = BackupFakeStore(baseValues())
        store.ignoreWrite = { id, value in id == "sports.tennisNews" && value == .bool(false) }
        let result = try preview(try sourceBackup(groups: Set(SettingsBackupGroup.portable)), store)
        let outcome = makeApplier(store, BackupMemoryJournal()).apply(preview: result, selectedGroups: Set(SettingsBackupGroup.portable))
        guard case .failed(let failedID, _, let report) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(failedID, "sports.tennisNews")
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(store.values, baseValues())
    }

    private func failingRollbackSetup() -> BackupFakeStore {
        let store = BackupFakeStore(baseValues())
        // The last write fails, and putting the first value back fails too.
        store.failWrite = { id, value in
            (id == "sports.tennisNews" && value == .bool(false)) || (id == "navigation.fourthTab" && value == .string("sports"))
        }
        return store
    }

    func testRollbackFailureIsReportedAndKeptForRecovery() throws {
        let store = failingRollbackSetup()
        let journal = BackupMemoryJournal()
        let result = try preview(try sourceBackup(groups: Set(SettingsBackupGroup.portable)), store)
        let outcome = makeApplier(store, journal).apply(preview: result, selectedGroups: Set(SettingsBackupGroup.portable))
        guard case .failed(let failedID, _, let report) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(failedID, "sports.tennisNews")
        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(report.unrestored, ["navigation.fourthTab"])
        XCTAssertTrue(report.restored.contains("liveTV.categoryAppearance"))
        XCTAssertEqual(journal.journal?.state, .rollbackIncomplete)
        XCTAssertEqual(journal.journal?.changes.map(\.id), ["navigation.fourthTab"])
        // The value that could not be put back is still the incoming one.
        XCTAssertEqual(store.values["navigation.fourthTab"], .string("favorites"))
    }

    func testBannerNeverClaimsCompleteRollbackWhenItWasNot() throws {
        let store = failingRollbackSetup()
        let journal = BackupMemoryJournal()
        let model = SettingsBackupModel(registry: store.registry(), journal: journal, app: app, now: { self.now })
        model.loadImport(data: try sourceBackup(groups: Set(SettingsBackupGroup.portable)))
        model.applySelected()
        XCTAssertEqual(model.banner?.kind, .failure)
        let text = model.banner?.text ?? ""
        XCTAssertTrue(text.contains("couldn't put back"), text)
        XCTAssertTrue(text.contains("Fourth tab"), text)
        XCTAssertFalse(text.contains("earlier settings were put back"), text)
        XCTAssertTrue(model.needsRecovery)

        // Once the store works again, recovery finishes the rollback.
        store.failWrite = { _, _ in false }
        model.recoverInterruptedRestore()
        XCTAssertEqual(store.values, baseValues())
        XCTAssertFalse(model.needsRecovery)
    }

    func testBannerReportsCompleteRollbackOnlyWhenVerified() throws {
        let store = BackupFakeStore(baseValues())
        store.failWrite = { id, value in id == "sports.tennisNews" && value == .bool(false) }
        let model = SettingsBackupModel(registry: store.registry(), journal: BackupMemoryJournal(), app: app, now: { self.now })
        model.loadImport(data: try sourceBackup(groups: Set(SettingsBackupGroup.portable)))
        model.applySelected()
        XCTAssertTrue(model.banner?.text.contains("earlier settings were put back") == true)
        XCTAssertEqual(store.values, baseValues())
    }

    // MARK: Undo and recovery

    func testUndoRestoresPreviousValuesAndClearsTheRestorePoint() throws {
        let store = BackupFakeStore(baseValues())
        let journal = BackupMemoryJournal()
        let applier = makeApplier(store, journal)
        let result = try preview(try sourceBackup(groups: Set(SettingsBackupGroup.portable)), store)
        _ = applier.apply(preview: result, selectedGroups: Set(SettingsBackupGroup.portable))
        XCTAssertTrue(applier.undoAvailable)
        let report = applier.undo()
        XCTAssertTrue(report.isClean)
        XCTAssertEqual(report.changedSince, [])
        XCTAssertEqual(store.values, baseValues())
        XCTAssertFalse(applier.undoAvailable)
    }

    func testUndoLeavesSettingsChangedAfterTheRestore() throws {
        let store = BackupFakeStore(baseValues())
        let applier = makeApplier(store, BackupMemoryJournal())
        let result = try preview(try sourceBackup(groups: [.downloads]), store)
        _ = applier.apply(preview: result, selectedGroups: [.downloads])
        store.values["downloads.simultaneous"] = .int(3)   // changed again by the user
        let report = applier.undo()
        XCTAssertEqual(report.changedSince, ["downloads.simultaneous"])
        XCTAssertEqual(store.values["downloads.simultaneous"], .int(3))
        XCTAssertEqual(store.values["downloads.wifiOnly"], .bool(true))
    }

    func testUndoFailureKeepsTheRestorePointForRetry() throws {
        let store = BackupFakeStore(baseValues())
        let journal = BackupMemoryJournal()
        let applier = makeApplier(store, journal)
        let result = try preview(try sourceBackup(groups: [.downloads]), store)
        _ = applier.apply(preview: result, selectedGroups: [.downloads])
        store.failWrite = { id, _ in id == "downloads.wifiOnly" }
        let report = applier.undo()
        XCTAssertEqual(report.failed, ["downloads.wifiOnly"])
        XCTAssertEqual(journal.journal?.changes.map(\.id), ["downloads.wifiOnly"])
        store.failWrite = { _, _ in false }
        XCTAssertTrue(applier.undo().isClean)
        XCTAssertEqual(store.values, baseValues())
    }

    func testInterruptedRestoreIsRolledBackFromTheRestorePoint() throws {
        // Simulates a crash after two writes: the restore point says "applying".
        let store = BackupFakeStore(baseValues())
        let journal = BackupMemoryJournal()
        journal.journal = RestoreJournal(state: .applying, changes: [
            AppliedChange(id: "navigation.fourthTab", previous: .string("sports"), applied: .string("favorites")),
            AppliedChange(id: "downloads.wifiOnly", previous: .bool(true), applied: .bool(false)),
            AppliedChange(id: "downloads.simultaneous", previous: .int(2), applied: .int(4)),
        ], date: now)
        store.values["navigation.fourthTab"] = .string("favorites")
        store.values["downloads.wifiOnly"] = .bool(false)    // the third write never happened
        let applier = makeApplier(store, journal)
        XCTAssertTrue(applier.needsRecovery)
        XCTAssertFalse(applier.undoAvailable)
        let report = applier.recoverInterruptedRestore()
        XCTAssertTrue(report.isClean)
        // Two values were put back; the third was never written, so it is not counted as reverted.
        XCTAssertEqual(Set(report.reverted), ["navigation.fourthTab", "downloads.wifiOnly"])
        XCTAssertEqual(report.unchanged, ["downloads.simultaneous"])
        XCTAssertEqual(store.values, baseValues())
        XCTAssertFalse(applier.needsRecovery)
        XCTAssertNil(journal.journal)
    }

    func testFailedRestorePointPersistenceAfterApplyIsReportedAndLeavesNoStaleRecord() throws {
        let store = BackupFakeStore(baseValues())
        let journal = BackupMemoryJournal()
        journal.failSaveAfter = 1     // the first restore point saves; the final "applied" record does not
        let model = SettingsBackupModel(registry: store.registry(), journal: journal, app: app, now: { self.now })
        model.loadImport(data: try sourceBackup(groups: Set(SettingsBackupGroup.portable)))
        model.applySelected()
        XCTAssertEqual(store.values["navigation.fourthTab"], .string("favorites"))   // the restore did apply
        XCTAssertNil(journal.journal)                                               // no stale "applying" record
        XCTAssertFalse(model.undoAvailable)
        XCTAssertFalse(model.needsRecovery)
        XCTAssertEqual(model.banner?.kind, .success)
        XCTAssertTrue(model.banner?.text.contains("Undo isn't available") == true, model.banner?.text ?? "")
    }

    func testNewRestoreIsRefusedWhileAnInterruptedOneIsUnresolved() throws {
        let store = BackupFakeStore(baseValues())
        let journal = BackupMemoryJournal()
        let pending = RestoreJournal(state: .rollbackIncomplete, changes: [
            AppliedChange(id: "downloads.wifiOnly", previous: .bool(true), applied: .bool(false))], date: now)
        journal.journal = pending
        let result = try preview(try sourceBackup(groups: Set(SettingsBackupGroup.portable)), store)
        let outcome = makeApplier(store, journal).apply(preview: result, selectedGroups: Set(SettingsBackupGroup.portable))
        guard case .failed(nil, _, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertEqual(journal.journal, pending)    // the recovery record is not overwritten
    }

    func testUndoSurvivesReopeningTheScreen() throws {
        let store = BackupFakeStore(baseValues())
        let journal = BackupMemoryJournal()
        let first = SettingsBackupModel(registry: store.registry(), journal: journal, app: app, now: { self.now })
        first.loadImport(data: try sourceBackup(groups: Set(SettingsBackupGroup.portable)))
        first.applySelected()
        XCTAssertTrue(first.undoAvailable)

        // A new model, as when the screen is opened again.
        let reopened = SettingsBackupModel(registry: store.registry(), journal: journal, app: app, now: { self.now })
        XCTAssertTrue(reopened.undoAvailable)
        XCTAssertEqual(reopened.restoreDate, now)
        reopened.undo()
        XCTAssertEqual(store.values, baseValues())
        XCTAssertFalse(reopened.undoAvailable)
        XCTAssertNil(journal.journal)
        XCTAssertEqual(reopened.banner?.kind, .success)
    }

    func testUndoDoesNotClaimSettingsItDidNotChange() throws {
        let store = BackupFakeStore(baseValues())
        let model = SettingsBackupModel(registry: store.registry(), journal: BackupMemoryJournal(), app: app, now: { self.now })
        model.loadImport(data: try sourceBackup(groups: [.downloads]))
        model.applySelected()
        store.values["downloads.wifiOnly"] = .bool(true)        // put back by hand already
        store.values["downloads.simultaneous"] = .int(3)        // changed again by hand
        model.undo()
        let text = model.banner?.text ?? ""
        XCTAssertTrue(text.contains("1 already had the earlier value"), text)
        XCTAssertTrue(text.contains("Downloads") || text.contains("Simultaneous downloads"), text)
        XCTAssertFalse(text.contains("Undid"), text)
        XCTAssertEqual(store.values["downloads.simultaneous"], .int(3))
    }

    func testPartialUndoFailureIsNeverReportedAsComplete() throws {
        let store = BackupFakeStore(baseValues())
        let journal = BackupMemoryJournal()
        let model = SettingsBackupModel(registry: store.registry(), journal: journal, app: app, now: { self.now })
        model.loadImport(data: try sourceBackup(groups: Set(SettingsBackupGroup.portable)))
        model.applySelected()
        store.failWrite = { id, _ in id == "sports.tennisNews" }
        model.undo()
        XCTAssertEqual(model.banner?.kind, .failure)
        XCTAssertTrue(model.banner?.text.contains("couldn't put back: Tennis news") == true, model.banner?.text ?? "")
        XCTAssertTrue(model.undoAvailable)                      // kept for a retry
        XCTAssertEqual(journal.journal?.changes.map(\.id), ["sports.tennisNews"])
        store.failWrite = { _, _ in false }
        model.undo()
        XCTAssertEqual(store.values, baseValues())
        XCTAssertNil(journal.journal)
    }

    func testRestoreUndoAndRecoveryAnnounceThemselvesToOpenScreens() throws {
        let center = NotificationCenter()
        var posts = 0
        let token = center.addObserver(forName: .kyroSettingsDidRestore, object: nil, queue: nil) { _ in posts += 1 }
        defer { center.removeObserver(token) }
        let store = BackupFakeStore(baseValues())
        let journal = BackupMemoryJournal()
        let model = SettingsBackupModel(registry: store.registry(), journal: journal, app: app, now: { self.now }, notifications: center)

        model.loadImport(data: try sourceBackup(groups: Set(SettingsBackupGroup.portable)))
        model.cancelImport()
        XCTAssertEqual(posts, 0, "preview and cancel write nothing, so they announce nothing")

        model.loadImport(data: try sourceBackup(groups: Set(SettingsBackupGroup.portable)))
        model.applySelected()
        XCTAssertEqual(posts, 1)
        model.undo()
        XCTAssertEqual(posts, 2)
        journal.journal = RestoreJournal(state: .applying, changes: [], date: now)
        model.recoverInterruptedRestore()
        XCTAssertEqual(posts, 3)
    }

    func testRecoveryDoesNotLeaveARestorePointBehindAfterACompleteRollbackWhoseClearFailed() throws {
        // The rollback finished but the restore point could not be deleted: the next recovery finds
        // every value already back, writes nothing and removes it.
        let store = BackupFakeStore(baseValues())
        let journal = BackupMemoryJournal()
        journal.failClear = true
        store.failWrite = { id, value in id == "downloads.simultaneous" && value == .int(4) }
        let result = try preview(try sourceBackup(groups: Set(SettingsBackupGroup.portable)), store)
        let applier = makeApplier(store, journal)
        guard case .failed(_, _, let report) = applier.apply(preview: result, selectedGroups: Set(SettingsBackupGroup.portable)) else { return XCTFail() }
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(store.values, baseValues())
        XCTAssertTrue(applier.needsRecovery)
        journal.failClear = false
        store.failWrite = { _, _ in false }
        let writesBefore = store.writes.count
        let recovered = applier.recoverInterruptedRestore()
        XCTAssertTrue(recovered.reverted.isEmpty)
        XCTAssertEqual(store.writes.count, writesBefore)
        XCTAssertNil(journal.journal)
    }

    func testRecoveryDoesNotTouchAnAppliedRestorePoint() {
        let store = BackupFakeStore(baseValues())
        let journal = BackupMemoryJournal()
        journal.journal = RestoreJournal(state: .applied, changes: [
            AppliedChange(id: "downloads.wifiOnly", previous: .bool(false), applied: .bool(true))], date: now)
        let report = makeApplier(store, journal).recoverInterruptedRestore()
        XCTAssertEqual(report, UndoReport())
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertEqual(journal.journal?.state, .applied)
    }

    func testFileRestorePointRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kyro-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileRestoreJournalStore(url: directory.appendingPathComponent("SettingsBackup/restore-point.json"))
        XCTAssertNil(try store.load())
        let record = RestoreJournal(state: .applying, changes: [
            AppliedChange(id: "downloads.wifiOnly", previous: .bool(true), applied: .bool(false))], date: now)
        try store.save(record)
        XCTAssertEqual(try store.load(), record)
        try store.clear()
        XCTAssertNil(try store.load())
    }
}
#endif
