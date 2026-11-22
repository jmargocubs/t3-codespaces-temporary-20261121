#if os(iOS) || KYRO_STANDALONE_TESTS
import XCTest
@testable import Silo

/// Build 92: importing a backup from pasted text. The text must go through exactly the same decoder,
/// limits, integrity check, preview, selective restore and Undo as a file.
@MainActor
final class SettingsBackupTextImportTests: XCTestCase {
    private let app = SettingsBackupAppInfo(version: "1.0.0", build: "92", platform: "iOS", idiom: "phone")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private let current: [String: BackupValue] = [
        "navigation.fourthTab": .string("sports"),
        "liveTV.categoryAppearance": .string("Hybrid"),
        "downloads.wifiOnly": .bool(true),
        "downloads.simultaneous": .int(2),
        "sports.tennisNews": .bool(true),
    ]
    private let saved: [String: BackupValue] = [
        "navigation.fourthTab": .string("favorites"),
        "liveTV.categoryAppearance": .string("Grid"),
        "downloads.wifiOnly": .bool(false),
        "downloads.simultaneous": .int(4),
        "sports.tennisNews": .bool(false),
    ]

    /// The text Copy Settings as Text puts on the clipboard, made by the real model.
    private func copiedText() throws -> String {
        let source = SettingsBackupModel(
            registry: BackupFakeStore(saved).registry(), journal: BackupMemoryJournal(), app: app, now: { self.now })
        return try XCTUnwrap(source.exportText())
    }

    private func model(_ store: BackupFakeStore, _ journal: BackupMemoryJournal = BackupMemoryJournal()) -> SettingsBackupModel {
        SettingsBackupModel(registry: store.registry(), journal: journal, app: app, now: { self.now })
    }

    func testCopiedTextIsTheSameDocumentAsTheExportedFile() throws {
        let source = model(BackupFakeStore(saved))
        let file = try XCTUnwrap(source.exportDocument())
        XCTAssertEqual(try copiedText(), String(decoding: file, as: UTF8.self))
    }

    func testPastedTextPreviewsTheSameChangesAsTheFile() throws {
        let text = try copiedText()
        let fromText = model(BackupFakeStore(current))
        XCTAssertNil(fromText.loadImport(text: text))
        let fromFile = model(BackupFakeStore(current))
        fromFile.loadImport(data: Data(text.utf8))

        let preview = try XCTUnwrap(fromText.preview)
        XCTAssertEqual(preview.totalChanges, 4)
        XCTAssertEqual(preview.totalChanges, fromFile.preview?.totalChanges)
        XCTAssertEqual(fromText.importSelection, fromFile.importSelection)
        let fourthTab = try XCTUnwrap(preview.groups.flatMap(\.items).first { $0.id == "navigation.fourthTab" })
        XCTAssertEqual(fourthTab.status, .willChange)
        XCTAssertEqual(fourthTab.incoming, "favorites")
    }

    func testTextReformattedByAnotherAppStillImports() throws {
        // Notes, Messages or Mail may add surrounding blank lines or change line endings.
        let reformatted = "\n\n  " + (try copiedText()).replacingOccurrences(of: "\n", with: "\r\n") + "  \n"
        let store = BackupFakeStore(current)
        let loaded = model(store)
        XCTAssertNil(loaded.loadImport(text: reformatted))
        XCTAssertEqual(loaded.preview?.totalChanges, 4)
    }

    func testEditedValueFailsTheIntegrityCheck() throws {
        let edited = (try copiedText()).replacingOccurrences(of: "\"favorites\"", with: "\"forYou\"")
        let store = BackupFakeStore(current)
        let loaded = model(store)
        XCTAssertEqual(loaded.loadImport(text: edited), SettingsBackupError.integrityMismatch.errorDescription)
        XCTAssertNil(loaded.preview)
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testTextThatIsNotABackupIsRefusedInPlace() throws {
        let store = BackupFakeStore(current)
        let loaded = model(store)
        for junk in ["hello", "{\"format\": \"something-else\", \"schemaVersion\": 1, \"minReaderVersion\": 1}", "“curly”: {}"] {
            let message = try XCTUnwrap(loaded.loadImport(text: junk), junk)
            XCTAssertTrue(message.contains("isn't a Kyro settings backup") || message.contains("not a Kyro settings backup"), message)
            XCTAssertNil(loaded.preview)
            XCTAssertNil(loaded.banner, "the paste screen shows the problem, not the main screen")
        }
        XCTAssertEqual(loaded.loadImport(text: "  \n "), "Paste the backup text first.")
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testTextOverTheSizeLimitIsRefusedBeforeDecoding() throws {
        let store = BackupFakeStore(current)
        let loaded = model(store)
        let tooLong = String(repeating: "x", count: SettingsBackupSafety.maxFileBytes + 1)
        XCTAssertEqual(loaded.loadImport(text: tooLong), SettingsBackupModel.pastedTextMessage(.tooLarge))
        XCTAssertNil(loaded.preview)
        // A multi-byte character counts by its encoded size, the same as a file.
        let wide = String(repeating: "é", count: SettingsBackupSafety.maxFileBytes / 2 + 1)
        XCTAssertEqual(loaded.loadImport(text: wide), SettingsBackupModel.pastedTextMessage(.tooLarge))
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testRefusedTextClearsAnEarlierPreview() throws {
        let loaded = model(BackupFakeStore(current))
        XCTAssertNil(loaded.loadImport(text: try copiedText()))
        XCTAssertNotNil(loaded.preview)
        XCTAssertNotNil(loaded.loadImport(text: "nope"))
        XCTAssertNil(loaded.preview)
        XCTAssertTrue(loaded.importSelection.isEmpty)
    }

    func testPastedBackupRestoresOnlySelectedGroupsAndUndoes() throws {
        let store = BackupFakeStore(current)
        let journal = BackupMemoryJournal()
        let loaded = model(store, journal)
        XCTAssertNil(loaded.loadImport(text: try copiedText()))
        loaded.setImport(.downloads, enabled: false)
        XCTAssertEqual(loaded.selectedChangeCount, 2)

        loaded.applySelected()
        XCTAssertEqual(loaded.banner?.kind, .success)
        XCTAssertEqual(store.values["navigation.fourthTab"], .string("favorites"))
        XCTAssertEqual(store.values["liveTV.categoryAppearance"], .string("Grid"))
        XCTAssertEqual(store.values["downloads.wifiOnly"], .bool(true), "a deselected group is left alone")
        XCTAssertEqual(store.values["downloads.simultaneous"], .int(2))
        XCTAssertTrue(loaded.undoAvailable)

        loaded.undo()
        XCTAssertEqual(store.values, current)
        XCTAssertFalse(loaded.undoAvailable)
        XCTAssertNil(journal.journal)
    }

    func testPastedBackupPostsTheRestoreNotificationForLiveTVRefresh() throws {
        let center = NotificationCenter()
        let loaded = SettingsBackupModel(
            registry: BackupFakeStore(current).registry(), journal: BackupMemoryJournal(), app: app,
            now: { self.now }, notifications: center)
        var posts = 0
        let token = center.addObserver(forName: .kyroSettingsDidRestore, object: nil, queue: nil) { _ in posts += 1 }
        defer { center.removeObserver(token) }
        XCTAssertNil(loaded.loadImport(text: try copiedText()))
        XCTAssertEqual(posts, 0, "loading a preview writes nothing")
        loaded.applySelected()
        XCTAssertEqual(posts, 1)
    }
}
#endif
