#if KYRO_STANDALONE_TESTS
import Foundation

@main
enum SettingsBackupCodecHostChecks {
    static func main() throws {
        let app = SettingsBackupAppInfo(version: "1", build: "94", platform: "iOS", idiom: "phone")
        let local = ["navigation": ["navigation.fourthTab": BackupValue.string("sports")]]
        let legacy = try SettingsBackupCodec.makeDocument(
            groups: local, schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        let legacyDecoded = try SettingsBackupCodec.decode(legacy)
        precondition(legacyDecoded.schemaVersion == 1 && legacyDecoded.scope == nil)
        precondition(legacyDecoded.groups == local)
        // Hash calculated from the schema-1 canonical payload before schema 2 existed.
        let oldFile = #"{"format":"kyro.settings-backup","schemaVersion":1,"minReaderVersion":1,"createdAt":"2026-01-01T00:00:00Z","payloadSha256":"9a7ccdb2e54a873a38a430453e2311b6593e6a8db4c258e33774431c7f652b63","payload":{"groups":{"navigation":{"navigation.fourthTab":"sports"}}}}"#
        let oldDecoded = try SettingsBackupCodec.decode(Data(oldFile.utf8))
        precondition(oldDecoded.groups == local)

        let scope = SettingsBackupScope(serverFingerprint: String(repeating: "a", count: 64),
                                        profileFingerprint: String(repeating: "b", count: 64))
        var combined = local
        combined["streaming"] = ["streaming.resolution": .string("480p")]
        combined["subtitles"] = ["subtitles.language": .string("zh")]
        let unified = try SettingsBackupCodec.makeUnifiedDocument(
            groups: combined, scope: scope, app: app, now: Date())
        let decoded = try SettingsBackupCodec.decode(unified)
        precondition(decoded.schemaVersion == 2 && decoded.scope == scope && decoded.groups == combined)

        let edited = String(decoding: unified, as: UTF8.self).replacingOccurrences(of: "480p", with: "720p")
        do {
            _ = try SettingsBackupCodec.decode(Data(edited.utf8))
            fatalError("Tampered backup passed integrity validation")
        } catch SettingsBackupError.integrityMismatch {}

        let unsafe = try SettingsBackupCodec.makeDocument(
            groups: ["streaming": ["streaming.resolution": .string("480p")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        do {
            _ = try SettingsBackupCodec.decode(unsafe)
            fatalError("Schema-1 file carried a scoped setting")
        } catch SettingsBackupError.unsafeContent {}

        do {
            _ = try SettingsBackupCodec.makeUnifiedDocument(
                groups: ["navigation": ["account.token": .string("secret")]],
                scope: scope, app: app, now: Date())
            fatalError("Credential-like setting passed the allowlist")
        } catch SettingsBackupError.unsafeContent {}

        // Schema 3: a flat record of scalars, only when the file holds one.
        let appearance: [String: BackupValue] = [
            "fontSize": .string("xlarge"), "fontColor": .string("#facc15"), "backgroundOpacity": .int(40),
            "textOutline": .bool(true)]
        let withRecord = try SettingsBackupCodec.makeUnifiedDocument(
            groups: ["subtitles": ["subtitles.appearance": .record(appearance)]], scope: scope, app: app, now: Date())
        let recordDecoded = try SettingsBackupCodec.decode(withRecord)
        precondition(recordDecoded.schemaVersion == 3)
        precondition(recordDecoded.groups["subtitles"]?["subtitles.appearance"] == .record(appearance))
        // Earlier builds must refuse it cleanly rather than misread it: minReaderVersion is 3.
        precondition(String(decoding: withRecord, as: UTF8.self).contains("\"minReaderVersion\" : 3"))
        precondition(decoded.schemaVersion == 2)   // a file without a record is unchanged

        let tamperedRecord = String(decoding: withRecord, as: UTF8.self).replacingOccurrences(of: "xlarge", with: "small")
        do { _ = try SettingsBackupCodec.decode(Data(tamperedRecord.utf8)); fatalError("record tamper passed") }
        catch SettingsBackupError.integrityMismatch {}

        for version in [1, 2] {
            let early = try SettingsBackupCodec.makeDocument(
                groups: ["subtitles": ["subtitles.appearance": .record(appearance)]],
                schemaVersion: version, minReaderVersion: 1, app: app, now: Date())
            do { _ = try SettingsBackupCodec.decode(early); fatalError("record in schema \(version)") }
            catch SettingsBackupError.unsafeContent {}
        }
        let unsafeRecords: [[String: BackupValue]] = [
            [:],                                                       // empty
            ["authToken": .string("x")],                               // credential-like member
            ["fontSize": .string("https://example.com")],              // link-like value
            Dictionary(uniqueKeysWithValues: (0..<17).map { ("m\($0)", BackupValue.int($0)) }),   // too many
        ]
        for members in unsafeRecords {
            do {
                _ = try SettingsBackupCodec.makeUnifiedDocument(
                    groups: ["subtitles": ["subtitles.appearance": .record(members)]], scope: scope, app: app, now: Date())
                fatalError("unsafe record accepted: \(members.keys)")
            } catch SettingsBackupError.unsafeContent {}
        }
        let ordered = BackupValue.record(["scope": .string("profile_client"),
            "items": .array((0..<64).map { index in .record(["kind": .string("library"), "libraryId": .int(index + 1)]) })])
        let orderedFile = try SettingsBackupCodec.makeUnifiedDocument(
            groups: ["interface": ["interface.primaryMenu": ordered]], scope: scope, app: app, now: Date())
        let orderedDecoded = try SettingsBackupCodec.decode(orderedFile)
        precondition(orderedDecoded.schemaVersion == 4 && orderedDecoded.groups["interface"]?["interface.primaryMenu"] == ordered)
        let changedOrder = String(decoding: orderedFile, as: UTF8.self).replacingOccurrences(of: "libraryId\" : 1", with: "libraryId\" : 2")
        do { _ = try SettingsBackupCodec.decode(Data(changedOrder.utf8)); fatalError("ordered tamper passed") }
        catch SettingsBackupError.integrityMismatch {}
        for bad in [BackupValue.array((0..<65).map { .int($0) }),
                    .record(["items": .array([.record(["authToken": .string("x")])])])] {
            do {
                _ = try SettingsBackupCodec.makeUnifiedDocument(
                    groups: ["interface": ["interface.primaryMenu": bad]], scope: scope, app: app, now: Date())
                fatalError("unsafe schema-4 value accepted")
            } catch SettingsBackupError.unsafeContent {}
        }
        let schemaThreeArray = try SettingsBackupCodec.makeDocument(
            groups: ["interface": ["interface.primaryMenu": ordered]], schemaVersion: 3,
            minReaderVersion: 3, app: app, now: Date())
        do { _ = try SettingsBackupCodec.decode(schemaThreeArray); fatalError("array in schema 3") }
        catch SettingsBackupError.unsafeContent {}
        // A newer file that this build can read in full still decodes.
        let future = try SettingsBackupCodec.makeDocument(
            groups: ["navigation": ["navigation.fourthTab": .string("sports")]],
            schemaVersion: 5, minReaderVersion: 1, app: app, now: Date())
        let futureDecoded = try SettingsBackupCodec.decode(future)
        precondition(futureDecoded.isNewerThanSupported)

        // New local Sports modes use the existing scalar encoding, so adding them never forces
        // a schema upgrade or changes how a Build-93 document is decoded.
        let sports = try SettingsBackupCodec.makeDocument(
            groups: ["sports": ["sports.dashboardMode.nfl": .string("~automatic"),
                               "sports.dashboardMode.nba": .string("results")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        let decodedSports = try SettingsBackupCodec.decode(sports)
        precondition(decodedSports.groups["sports"]?.count == 2)

        print("SettingsBackupCodecHostChecks: 20 passed")
    }
}
#endif
