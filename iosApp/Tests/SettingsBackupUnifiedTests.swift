#if os(iOS)
import XCTest
@testable import Silo

private actor FakeBackupRemoteTransport: SettingsBackupRemoteTransport {
    enum Failure: Error { case offline }

    private var destination = SettingsBackupRemoteOwner(
        request: HTTPRequestIdentity(serverId: "server-local", serverURL: "https://example.invalid",
                                     profileId: "profile-one", clientFamily: "ios"),
        scope: SettingsBackupScope(serverFingerprint: String(repeating: "a", count: 64),
                                   profileFingerprint: String(repeating: "b", count: 64)))
    private var stored: [SettingKey: SettingJSONValue] = [
        .playbackPreferredQuality: .string("1080p"),
        .playbackAudioLanguage: .string("en"),
        .playbackSubtitleLanguage: .string("en"),
    ]
    private var profileRows: [SettingKey: SettingJSONValue] = [:]
    private var unserved: Set<SettingKey> = []
    private var overrides: [SettingKey: (scope: SettingScope, value: SettingJSONValue)] = [:]
    /// Subtitle appearance and sync live at both `profile_device` and `profile`.
    private var deviceRows: [SettingKey: SettingJSONValue] = [:]
    private var profileScopeRows: [SettingKey: SettingJSONValue] = [:]
    private var revision = SettingKey.revision
    private var failWrite: (key: SettingKey, scope: SettingScopeIdentity)?
    static let dual: Set<SettingKey> = [.playbackSubtitleAppearance, .playerSubtitleSyncMs]
    private var failedKey: SettingKey?
    private var offline = false
    private var delay: Duration?
    private(set) var writes: [SettingKey] = []
    private(set) var writeScopes: [SettingScopeIdentity] = []

    func owner() async throws -> SettingsBackupRemoteOwner { destination }

    func read(_ keys: [SettingKey], owner: SettingsBackupRemoteOwner) async throws -> EffectiveSettingValuesResponse {
        if let delay { try await Task.sleep(for: delay) }
        if offline { throw Failure.offline }
        let rows = keys.filter { !unserved.contains($0) }.map { key -> EffectiveSettingValue in
            let ownScope: SettingScope = Self.profileScoped.contains(key) ? .profile : .profileDevice
            if Self.dual.contains(key) {
                if let hidden = overrides[key] {
                    return EffectiveSettingValue(key: key.rawValue, value: hidden.value, source: .scope(hidden.scope),
                                                 scope: hidden.scope, profileId: destination.request.profileId)
                }
                for (rows, scope) in [(deviceRows, SettingScope.profileDevice), (profileScopeRows, .profile)] {
                    if let value = rows[key] {
                        return EffectiveSettingValue(key: key.rawValue, value: value, source: .scope(scope),
                                                     scope: scope, profileId: destination.request.profileId)
                    }
                }
                return EffectiveSettingValue(
                    key: key.rawValue, value: key == .playerSubtitleSyncMs ? .int(0) : Self.appearance([:]),
                    source: .contractDefault, scope: nil, profileId: nil)
            }
            if let hidden = overrides[key] {
                return EffectiveSettingValue(key: key.rawValue, value: hidden.value, source: .scope(hidden.scope),
                                             scope: hidden.scope, profileId: destination.request.profileId)
            }
            if stored[key] == nil, !Self.profileScoped.contains(key), let inherited = profileRows[key] {
                return EffectiveSettingValue(key: key.rawValue, value: inherited, source: .scope(.profile),
                                             scope: .profile, profileId: destination.request.profileId)
            }
            let scope = ownScope
            let value = stored[key]
            return EffectiveSettingValue(
                key: key.rawValue,
                value: value ?? (key == .playbackPreferredQuality ? .string("auto") : .null),
                source: value == nil ? .contractDefault : .scope(scope),
                scope: value == nil ? nil : scope,
                profileId: value == nil ? nil : destination.request.profileId)
        }
        return EffectiveSettingValuesResponse(settings: rows, revision: SettingKey.revision)
    }

    func put(_ key: SettingKey, scope: SettingScopeIdentity, value: SettingJSONValue,
             owner: SettingsBackupRemoteOwner) async throws {
        if offline || key == failedKey || unserved.contains(key) { throw Failure.offline }
        if let failWrite, failWrite.key == key, failWrite.scope == scope { throw Failure.offline }
        guard owner.request == destination.request else { throw SettingsBackupRemoteError.changedOwner }
        if Self.dual.contains(key) {
            if scope == .profileDevice { deviceRows[key] = value } else { profileScopeRows[key] = value }
        } else { stored[key] = value }
        writes.append(key)
        writeScopes.append(scope)
    }

    func delete(_ key: SettingKey, scope: SettingScopeIdentity,
                owner: SettingsBackupRemoteOwner) async throws {
        if offline || key == failedKey || unserved.contains(key) { throw Failure.offline }
        if let failWrite, failWrite.key == key, failWrite.scope == scope { throw Failure.offline }
        if Self.dual.contains(key) {
            if scope == .profileDevice { deviceRows[key] = nil } else { profileScopeRows[key] = nil }
        } else { stored[key] = nil }
        writes.append(key)
        writeScopes.append(scope)
    }

    func set(_ key: SettingKey, to value: SettingJSONValue?) { stored[key] = value }
    func setProfileRow(_ key: SettingKey, to value: SettingJSONValue?) { profileRows[key] = value }
    func setUnserved(_ keys: Set<SettingKey>) { unserved = keys }
    func manifestRevision(owner: SettingsBackupRemoteOwner) async throws -> Int { revision }
    func setRevision(_ value: Int) { revision = value }
    func setRow(_ key: SettingKey, _ scope: SettingScopeIdentity, _ value: SettingJSONValue?) {
        if scope == .profileDevice { deviceRows[key] = value } else { profileScopeRows[key] = value }
    }
    func row(_ key: SettingKey, _ scope: SettingScopeIdentity) -> SettingJSONValue? {
        scope == .profileDevice ? deviceRows[key] : profileScopeRows[key]
    }
    func failWriting(_ key: SettingKey?, _ scope: SettingScopeIdentity = .profile) {
        failWrite = key.map { ($0, scope) }
    }
    /// A complete appearance object as the server returns it, with `changes` applied.
    static func appearance(_ changes: [String: SettingJSONValue]) -> SettingJSONValue {
        var fields: [String: SettingJSONValue] = [
            "fontSize": "large", "fontFamily": "sans-serif", "fontColor": "#ffffff",
            "backgroundColor": "#000000", "backgroundStyle": "box", "backgroundOpacity": 75,
            "textOpacity": 100, "textOutline": false, "textOutlineColor": "#000000", "position": "bottom",
        ]
        for (name, value) in changes { fields[name] = value }
        return .object(fields)
    }
    func setOverride(_ key: SettingKey, _ scope: SettingScope?, _ value: SettingJSONValue = .null) {
        overrides[key] = scope.map { ($0, value) }
    }
    /// The keys the contract stores at profile scope; the rest of this fake's keys are per device.
    static let profileScoped: Set<SettingKey> = [
        .playbackSubtitleLanguage, .catalogShowAdvisoryAge, .catalogHideUnwatchedEpisodeImages,
        .catalogHideUnwatchedEpisodeOverviews, .playerVideoSkipBackSeconds, .playerVideoSkipForwardSeconds,
        .playerAudiobookSkipBackSeconds, .playerAudiobookSkipForwardSeconds, .playbackSubtitleMode,
        .playbackShowForcedSubtitles, .catalogMetadataLanguage,
    ]
    func clearWrites() { writes = []; writeScopes = [] }
    func value(_ key: SettingKey) -> SettingJSONValue? { stored[key] }
    func fail(_ key: SettingKey?) { failedKey = key }
    func setOffline(_ flag: Bool) { offline = flag }
    func setDelay(_ value: Duration?) { delay = value }
    func moveProfile() {
        destination = SettingsBackupRemoteOwner(
            request: HTTPRequestIdentity(serverId: destination.request.serverId,
                                         serverURL: destination.request.serverURL,
                                         profileId: "profile-two", clientFamily: destination.request.clientFamily),
            scope: SettingsBackupScope(serverFingerprint: destination.scope.serverFingerprint,
                                       profileFingerprint: String(repeating: "c", count: 64)))
    }
}

private final class MemoryRemoteBackupJournal: RemoteBackupJournalStoring {
    var record: RemoteBackupJournal?
    func load() throws -> RemoteBackupJournal? { record }
    func save(_ journal: RemoteBackupJournal) throws { record = journal }
    func clear() throws { record = nil }
}

@MainActor
final class SettingsBackupUnifiedTests: XCTestCase {
    private let app = SettingsBackupAppInfo(version: "1", build: "95", platform: "iOS", idiom: "phone")

    private func makeModel(
        local: BackupFakeStore, transport: FakeBackupRemoteTransport,
        remoteJournal: MemoryRemoteBackupJournal = MemoryRemoteBackupJournal()
    ) -> SettingsBackupModel {
        SettingsBackupModel(
            registry: local.registry(), journal: BackupMemoryJournal(), app: app,
            remote: SettingsBackupRemoteAdapter(transport: transport, journal: remoteJournal))
    }

    func testOneFileRoundTripRestoresLocalResolutionAudioAndSubtitleFromAuthoritativeOwners() async throws {
        let local = BackupFakeStore(["navigation.fourthTab": .string("sports")])
        let transport = FakeBackupRemoteTransport()
        let model = makeModel(local: local, transport: transport)
        model.exportSelection = [.navigation, .streaming, .subtitles]
        let exported = await model.exportUnifiedDocument()
        let data = try XCTUnwrap(exported)
        let decoded = try SettingsBackupCodec.decode(data)
        // The file holds the subtitle appearance record, so it is schema 3.
        XCTAssertEqual(decoded.schemaVersion, 3)
        XCTAssertNotNil(decoded.scope)
        XCTAssertEqual(decoded.groups["streaming"]?["streaming.resolution"], .string("1080p"))
        XCTAssertEqual(decoded.groups["streaming"]?["streaming.audioLanguage"], .string("en"))
        XCTAssertEqual(decoded.groups["subtitles"]?["subtitles.language"], .string("en"))

        local.values["navigation.fourthTab"] = .string("forYou")
        await transport.set(.playbackPreferredQuality, to: .string("480p"))
        await transport.set(.playbackAudioLanguage, to: .string("zh"))
        await transport.set(.playbackSubtitleLanguage, to: .string("zh"))
        await model.loadUnifiedImport(data: data)
        let audioPreview = try XCTUnwrap(model.preview?.groups.flatMap(\.items)
            .first { $0.id == "streaming.audioLanguage" })
        XCTAssertEqual(audioPreview.current, "zh")
        XCTAssertEqual(audioPreview.incoming, "en")
        XCTAssertEqual(audioPreview.status, .willChange)
        XCTAssertEqual(model.selectedChangeCount, 4)
        await model.applyUnifiedSelected()
        XCTAssertEqual(local.values["navigation.fourthTab"], .string("sports"))
        let resolution = await transport.value(.playbackPreferredQuality)
        let audio = await transport.value(.playbackAudioLanguage)
        let language = await transport.value(.playbackSubtitleLanguage)
        XCTAssertEqual(resolution, .string("1080p"))
        XCTAssertEqual(audio, .string("en"))
        XCTAssertEqual(language, .string("en"))
        XCTAssertEqual(model.lastRestoredCount, 4)
    }

    func testDifferentProfileSkipsRemoteWithoutWritingIt() async throws {
        let local = BackupFakeStore(["navigation.fourthTab": .string("sports")])
        let transport = FakeBackupRemoteTransport()
        let model = makeModel(local: local, transport: transport)
        model.exportSelection = [.navigation, .streaming, .subtitles]
        let exported = await model.exportUnifiedDocument()
        let data = try XCTUnwrap(exported)
        await transport.moveProfile()
        await model.loadUnifiedImport(data: data)
        let remote = model.preview?.groups.filter { [.streaming, .subtitles].contains($0.group) }
        // Six streaming settings and seven subtitle settings (language, batch 2's mode, forced
        // subtitles and metadata language, and the three display items) are all refused for a
        // different profile.
        XCTAssertEqual(remote?.flatMap(\.items).count, 13)
        XCTAssertTrue(remote?.flatMap(\.items).allSatisfy {
            if case .unsupported = $0.status { return true }; return false
        } ?? false)
        let writes = await transport.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testOfflineReadNeverFallsBackToCachedValues() async throws {
        let transport = FakeBackupRemoteTransport()
        let model = makeModel(local: BackupFakeStore(["navigation.fourthTab": .string("sports")]),
                              transport: transport)
        model.exportSelection = [.navigation, .streaming, .subtitles]
        await transport.setOffline(true)
        let exported = await model.exportUnifiedDocument()
        XCTAssertNil(exported)
        XCTAssertNotNil(model.banner)
    }

    func testPartialRemoteFailureKeepsUndoPointAndDoesNotApplyLocal() async throws {
        let local = BackupFakeStore(["navigation.fourthTab": .string("sports")])
        let transport = FakeBackupRemoteTransport()
        let journal = MemoryRemoteBackupJournal()
        let model = makeModel(local: local, transport: transport, remoteJournal: journal)
        model.exportSelection = [.navigation, .streaming, .subtitles]
        let exported = await model.exportUnifiedDocument()
        let data = try XCTUnwrap(exported)
        local.values["navigation.fourthTab"] = .string("forYou")
        await transport.set(.playbackPreferredQuality, to: .string("480p"))
        await transport.set(.playbackAudioLanguage, to: .string("zh"))
        await transport.set(.playbackSubtitleLanguage, to: .string("zh"))
        await transport.fail(.playbackSubtitleLanguage)
        await model.loadUnifiedImport(data: data)
        await model.applyUnifiedSelected()
        XCTAssertEqual(local.values["navigation.fourthTab"], .string("forYou"))
        let resolution = await transport.value(.playbackPreferredQuality)
        let audio = await transport.value(.playbackAudioLanguage)
        let language = await transport.value(.playbackSubtitleLanguage)
        XCTAssertEqual(resolution, .string("1080p"))
        XCTAssertEqual(audio, .string("en"))
        XCTAssertEqual(language, .string("zh"))
        XCTAssertEqual(journal.record?.state, .applying)
        XCTAssertTrue(model.needsRecovery)
    }

    func testLegacyFileRestoresLocalAndHasNoRemoteItems() async throws {
        let local = BackupFakeStore(["navigation.fourthTab": .string("forYou")])
        let transport = FakeBackupRemoteTransport()
        let model = makeModel(local: local, transport: transport)
        let data = try SettingsBackupCodec.makeDocument(
            groups: ["navigation": ["navigation.fourthTab": .string("sports")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        await model.loadUnifiedImport(data: data)
        XCTAssertEqual(model.selectedChangeCount, 1)
        await model.applyUnifiedSelected()
        XCTAssertEqual(local.values["navigation.fourthTab"], .string("sports"))
        let writes = await transport.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testRemoteValuesRequireSchemaTwoAndScope() throws {
        let data = try SettingsBackupCodec.makeDocument(
            groups: ["streaming": ["streaming.resolution": .string("480p")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        XCTAssertThrowsError(try SettingsBackupCodec.decode(data)) { error in
            XCTAssertEqual(error as? SettingsBackupError, .unsafeContent)
        }
    }

    func testTimedReadFailsRatherThanUsingLocalCache() async throws {
        let transport = FakeBackupRemoteTransport()
        await transport.setDelay(.milliseconds(200))
        let adapter = SettingsBackupRemoteAdapter(
            transport: transport, journal: MemoryRemoteBackupJournal(), timeout: .milliseconds(20))
        do {
            _ = try await adapter.export()
            XCTFail("A timed-out authoritative read must not produce a backup")
        } catch { XCTAssertTrue(error is SettingsBackupRemoteError) }
    }
}

/// Batch 3: subtitle appearance record, "this device only" switch and sync offset.
@MainActor
final class SettingsBackupSubtitleDisplayTests: XCTestCase {
    private let app = SettingsBackupAppInfo(version: "1", build: "98", platform: "iOS", idiom: "phone")
    private let A = SettingKey.playbackSubtitleAppearance
    private let Y = SettingKey.playerSubtitleSyncMs
    private let all: Set<String> = SubtitleDisplayBackup.ids
    private let custom = FakeBackupRemoteTransport.appearance([
        "fontSize": "xlarge", "fontFamily": "monospace", "fontColor": "#facc15", "backgroundColor": "#1e3a5f",
        "backgroundStyle": "shadow", "backgroundOpacity": 40, "textOpacity": 80, "textOutline": true,
        "textOutlineColor": "#7f1d1d", "position": "top",
    ])
    private let other = FakeBackupRemoteTransport.appearance(["fontSize": "small", "position": "lower-third"])

    private func make(_ transport: FakeBackupRemoteTransport) -> SettingsBackupRemoteAdapter {
        SettingsBackupRemoteAdapter(transport: transport, journal: MemoryRemoteBackupJournal())
    }
    private func file(_ adapter: SettingsBackupRemoteAdapter) async throws -> IncomingBackup {
        let exported = try await adapter.export()
        return try SettingsBackupCodec.decode(SettingsBackupCodec.makeUnifiedDocument(
            groups: exported.groups, scope: exported.scope, app: app, now: Date()))
    }

    /// The backup's lists and defaults are the production appearance's, not a copy that can drift.
    func testRecordMatchesProductionAppearance() throws {
        XCTAssertEqual(SubtitleDisplayBackup.fontSizes, SubtitleFontSizePreset.allCases.map(\.rawValue))
        XCTAssertEqual(SubtitleDisplayBackup.backgroundStyles, SubtitleBackgroundStylePreset.allCases.map(\.rawValue))
        XCTAssertEqual(SubtitleDisplayBackup.positions, SubtitlePositionPreset.allCases.map(\.rawValue))
        let encoded = try SettingJSONValue.encoding(SubtitleAppearance.default)
        guard case .object(let fields) = encoded else { return XCTFail("appearance is an object") }
        // Every synced member is in the backup record, and nothing runtime-only is.
        XCTAssertEqual(Set(fields.keys), Set(SubtitleDisplayBackup.defaults.keys))
        XCTAssertEqual(try SubtitleDisplayBackup.record(from: encoded), SubtitleDisplayBackup.defaults)
        XCTAssertEqual(SubtitleDisplayBackup.profileSyncRevision, SettingKey.subtitleSyncProfileScopeRevision)
        XCTAssertEqual(SubtitleDisplayBackup.textOpacityRevision, SettingKey.subtitleTextOpacityRevision)
        XCTAssertEqual(SettingKey.playbackSubtitleAppearance.revisionGatedMembers["textOpacity"],
                       SubtitleDisplayBackup.textOpacityRevision)
        XCTAssertTrue(SettingKey.playerSubtitleSyncMs.acceptsProfileScope(atRevision: 19))
        XCTAssertFalse(SettingKey.playerSubtitleSyncMs.acceptsProfileScope(atRevision: 18))
    }

    func testEverySavedAppearanceFieldSurvivesTheRoundTrip() async throws {
        let source = FakeBackupRemoteTransport()
        await source.setRow(A, .profile, custom)
        let incoming = try await file(make(source))
        XCTAssertEqual(incoming.schemaVersion, 3)
        XCTAssertEqual(incoming.groups["subtitles"]?["subtitles.appearanceDeviceOnly"], .bool(false))
        let dest = FakeBackupRemoteTransport()
        await dest.setRow(A, .profile, other)
        let adapter = make(dest)
        let report = await adapter.apply(incoming, selectedIDs: all)
        XCTAssertEqual(report.applied, ["subtitles.appearance"])
        let restored = await dest.row(A, .profile)
        XCTAssertEqual(restored, custom)
        let device = await dest.row(A, .profileDevice)
        XCTAssertNil(device)
        _ = await adapter.undo()
        let undone = await dest.row(A, .profile)
        XCTAssertEqual(undone, other)
    }

    func testScopeSwitchRestoresBothDirectionsAndUndoRestoresHiddenRows() async throws {
        let hidden = FakeBackupRemoteTransport.appearance(["fontSize": "medium"])
        // Device → profile: the profile row hidden behind the device row comes back on Undo.
        let toProfile = FakeBackupRemoteTransport()
        await toProfile.setRow(A, .profileDevice, other)
        await toProfile.setRow(A, .profile, hidden)
        let profileFile: IncomingBackup = try await {
            let source = FakeBackupRemoteTransport()
            await source.setRow(A, .profile, custom)
            return try await file(make(source))
        }()
        let adapter = make(toProfile)
        let report = await adapter.apply(profileFile, selectedIDs: all)
        XCTAssertEqual(report.applied, ["subtitles.appearanceDeviceOnly", "subtitles.appearance"])
        let nowDevice = await toProfile.row(A, .profileDevice)
        let nowProfile = await toProfile.row(A, .profile)
        XCTAssertNil(nowDevice)
        XCTAssertEqual(nowProfile, custom)
        _ = await adapter.undo()
        let backDevice = await toProfile.row(A, .profileDevice)
        let backProfile = await toProfile.row(A, .profile)
        XCTAssertEqual(backDevice, other)
        XCTAssertEqual(backProfile, hidden)

        // Profile → device: the device row is created; the profile row is never touched.
        let toDevice = FakeBackupRemoteTransport()
        await toDevice.setRow(A, .profile, hidden)
        let deviceFile: IncomingBackup = try await {
            let source = FakeBackupRemoteTransport()
            await source.setRow(A, .profileDevice, custom)
            return try await file(make(source))
        }()
        let deviceAdapter = make(toDevice)
        let deviceReport = await deviceAdapter.apply(deviceFile, selectedIDs: all)
        XCTAssertTrue(deviceReport.failed.isEmpty)
        let createdDevice = await toDevice.row(A, .profileDevice)
        let untouchedProfile = await toDevice.row(A, .profile)
        let scopes = await toDevice.writeScopes
        XCTAssertEqual(createdDevice, custom)
        XCTAssertEqual(untouchedProfile, hidden)
        XCTAssertEqual(scopes, [.profileDevice])
    }

    func testExplicitDefaultInheritedAndCustomStayDistinct() async throws {
        let explicit = FakeBackupRemoteTransport()
        await explicit.setRow(A, .profile, FakeBackupRemoteTransport.appearance([:]))
        let explicitFile = try await file(make(explicit))
        XCTAssertEqual(explicitFile.groups["subtitles"]?["subtitles.appearance"], .record(SubtitleDisplayBackup.defaults))
        let inheritedFile = try await file(make(FakeBackupRemoteTransport()))
        XCTAssertEqual(inheritedFile.groups["subtitles"]?["subtitles.appearance"], .string("~inherit"))
        let dest = FakeBackupRemoteTransport()
        await dest.setRow(A, .profile, custom)
        let adapter = make(dest)
        _ = await adapter.apply(inheritedFile, selectedIDs: ["subtitles.appearance"])
        let cleared = await dest.row(A, .profile)
        XCTAssertNil(cleared)
    }

    func testSyncOffsetsAtProfileDeviceAndOlderServerScope() async throws {
        for offset in [-750, 0, 1500] {
            let source = FakeBackupRemoteTransport()
            await source.setRow(Y, .profile, .int(offset))
            let incoming = try await file(make(source))
            XCTAssertEqual(incoming.groups["subtitles"]?["subtitles.syncOffsetMs"], .int(offset))
            let dest = FakeBackupRemoteTransport()
            let adapter = make(dest)
            let report = await adapter.apply(incoming, selectedIDs: ["subtitles.syncOffsetMs"])
            let row = await dest.row(Y, .profile)
            XCTAssertEqual(report.applied, ["subtitles.syncOffsetMs"])
            XCTAssertEqual(row, .int(offset))
        }
        let source = FakeBackupRemoteTransport()
        await source.setRow(Y, .profile, .int(-750))
        let incoming = try await file(make(source))
        let old = FakeBackupRemoteTransport()
        await old.setRevision(18)
        _ = await make(old).apply(incoming, selectedIDs: ["subtitles.syncOffsetMs"])
        let deviceOffset = await old.row(Y, .profileDevice)
        let profileOffset = await old.row(Y, .profile)
        XCTAssertEqual(deviceOffset, .int(-750))
        XCTAssertNil(profileOffset)
    }

    func testOlderServerRefusesNonDefaultTextOpacity() async throws {
        let source = FakeBackupRemoteTransport()
        await source.setRow(A, .profile, custom)
        let incoming = try await file(make(source))
        let old = FakeBackupRemoteTransport()
        await old.setRevision(10)
        let adapter = make(old)
        let preview = await adapter.preview(incoming)
        XCTAssertEqual(preview.flatMap(\.items).first { $0.id == "subtitles.appearance" }?.status,
                       .unsupported("This server is too old to store the saved text opacity."))
        let report = await adapter.apply(incoming, selectedIDs: ["subtitles.appearance"])
        XCTAssertEqual(report.skipped, ["subtitles.appearance"])
        let writes = await old.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testPartialFailureReportsEachItemAndRecoveryRestoresRows() async throws {
        let source = FakeBackupRemoteTransport()
        await source.setRow(A, .profile, custom)
        await source.setRow(Y, .profile, .int(-750))
        let incoming = try await file(make(source))
        let dest = FakeBackupRemoteTransport()
        let hidden = FakeBackupRemoteTransport.appearance(["fontSize": "medium"])
        await dest.setRow(A, .profileDevice, other)
        await dest.setRow(A, .profile, hidden)
        await dest.failWriting(A, .profile)
        let adapter = make(dest)
        let report = await adapter.apply(incoming, selectedIDs: all)
        XCTAssertEqual(report.applied, ["subtitles.appearanceDeviceOnly"])
        XCTAssertEqual(report.failed, ["subtitles.appearance"])
        XCTAssertEqual(report.skipped, ["subtitles.syncOffsetMs"])
        XCTAssertTrue(adapter.needsRecovery)
        await dest.failWriting(nil)
        let undo = await adapter.undo()
        XCTAssertTrue(undo.failed.isEmpty)
        let device = await dest.row(A, .profileDevice)
        let profile = await dest.row(A, .profile)
        XCTAssertEqual(device, other)
        XCTAssertEqual(profile, hidden)
        XCTAssertFalse(adapter.undoAvailable)
    }

    func testSelectiveRestoreAndIdentityMismatch() async throws {
        let source = FakeBackupRemoteTransport()
        await source.setRow(A, .profile, custom)
        await source.setRow(Y, .profile, .int(-750))
        let adapter = make(source)
        let incoming = try await file(adapter)
        let dest = FakeBackupRemoteTransport()
        let destAdapter = make(dest)
        _ = await destAdapter.apply(incoming, selectedIDs: ["subtitles.syncOffsetMs"])
        let written = await dest.writes
        XCTAssertEqual(written, [.playerSubtitleSyncMs])

        await source.moveProfile()
        let preview = await adapter.preview(incoming)
        for id in all {
            XCTAssertEqual(preview.flatMap(\.items).first { $0.id == id }?.status,
                           .unsupported(SettingsBackupRemoteError.destinationMismatch.localizedDescription), id)
        }
        await source.clearWrites()
        _ = await adapter.apply(incoming, selectedIDs: all)
        let mismatchWrites = await source.writes
        XCTAssertTrue(mismatchWrites.isEmpty)
    }

    func testRecordNeedsSchemaThreeAndEarlierFilesStillImport() throws {
        let members: [String: BackupValue] = ["fontSize": .string("large")]
        for version in [1, 2] {
            let bad = try SettingsBackupCodec.makeDocument(
                groups: ["subtitles": ["subtitles.appearance": .record(members)]],
                schemaVersion: version, minReaderVersion: 1, app: app, now: Date())
            XCTAssertThrowsError(try SettingsBackupCodec.decode(bad)) {
                XCTAssertEqual($0 as? SettingsBackupError, .unsafeContent)
            }
        }
        let scope = SettingsBackupScope(serverFingerprint: String(repeating: "a", count: 64),
                                        profileFingerprint: String(repeating: "b", count: 64))
        let build96 = try SettingsBackupCodec.makeUnifiedDocument(
            groups: ["subtitles": ["subtitles.language": .string("zh")]], scope: scope, app: app, now: Date())
        XCTAssertEqual(try SettingsBackupCodec.decode(build96).schemaVersion, 2)
        let withRecord = try SettingsBackupCodec.makeUnifiedDocument(
            groups: ["subtitles": ["subtitles.appearance": .record(members)]], scope: scope, app: app, now: Date())
        XCTAssertEqual(try SettingsBackupCodec.decode(withRecord).schemaVersion, 3)
    }
}

/// Batch 1: the fourteen profile-device scalar settings, against the production adapter and the
/// real wire models. One table row per value transition, so both boolean directions, explicit null,
/// and inherited rows are each exercised.
@MainActor
final class SettingsBackupRemoteBatchOneTests: XCTestCase {
    private struct Row {
        let id: String
        let key: SettingKey
        let saved: SettingJSONValue?
        let backup: BackupValue
        let current: SettingJSONValue
        var scope: SettingScopeIdentity = .profileDevice
    }

    private static let inherit = BackupValue.string("~inherit")
    private let app = SettingsBackupAppInfo(version: "1", build: "97", platform: "iOS", idiom: "phone")

    private let rows: [Row] = [
        Row(id: "streaming.maxBitrate", key: .playbackMaxBitrateKbps, saved: .int(6000), backup: .int(6000), current: .null),
        Row(id: "streaming.maxBitrate", key: .playbackMaxBitrateKbps, saved: .null, backup: .string("~null"), current: .int(2000)),
        Row(id: "streaming.maxBitrate", key: .playbackMaxBitrateKbps, saved: nil, backup: inherit, current: .int(2000)),
        Row(id: "streaming.bufferingQuality", key: .playbackBufferingQualityMode, saved: .string("never"), backup: .string("never"), current: .string("always")),
        Row(id: "streaming.hdr", key: .playerHdrEnabled, saved: .bool(false), backup: .bool(false), current: .bool(true)),
        Row(id: "streaming.hdr", key: .playerHdrEnabled, saved: .bool(true), backup: .bool(true), current: .bool(false)),
        Row(id: "streaming.hdr", key: .playerHdrEnabled, saved: nil, backup: inherit, current: .bool(false)),
        Row(id: "streaming.dolbyVision", key: .playerDolbyVisionEnabled, saved: .bool(false), backup: .bool(false), current: .bool(true)),
        Row(id: "streaming.dolbyVision", key: .playerDolbyVisionEnabled, saved: .bool(true), backup: .bool(true), current: .bool(false)),
        Row(id: "player.introSkip", key: .playbackIntroSkipMode, saved: .string("always"), backup: .string("always"), current: .string("never")),
        Row(id: "player.skipCredits", key: .playbackAutoSkipCredits, saved: .bool(true), backup: .bool(true), current: .bool(false)),
        Row(id: "player.skipCredits", key: .playbackAutoSkipCredits, saved: .bool(false), backup: .bool(false), current: .bool(true)),
        Row(id: "player.autoPlayNext", key: .playbackAutoPlayNext, saved: .bool(false), backup: .bool(false), current: .bool(true)),
        Row(id: "player.autoPlayNext", key: .playbackAutoPlayNext, saved: .bool(true), backup: .bool(true), current: .bool(false)),
        Row(id: "player.nextUpSeconds", key: .playbackNextUpPromptSeconds, saved: .int(0), backup: .int(0), current: .int(30)),
        Row(id: "player.speedHundredths", key: .playerPlaybackSpeed, saved: .double(1.25), backup: .int(125), current: .double(2)),
        Row(id: "player.videoSizing", key: .playerVideoGravity, saved: .string("fill"), backup: .string("fill"), current: .string("fit")),
        Row(id: "player.orientation", key: .playerOrientationMode, saved: .string("rotateFreely"), backup: .string("rotateFreely"), current: .string("landscapeLocked")),
        Row(id: "player.fastSeeking", key: .playerSeekCacheEnabled, saved: .bool(false), backup: .bool(false), current: .bool(true)),
        Row(id: "player.fastSeeking", key: .playerSeekCacheEnabled, saved: .bool(true), backup: .bool(true), current: .bool(false)),
        Row(id: "interface.themeMusic", key: .uiThemeMusicEnabled, saved: .bool(true), backup: .bool(true), current: .bool(false)),
        Row(id: "interface.themeMusic", key: .uiThemeMusicEnabled, saved: .bool(false), backup: .bool(false), current: .bool(true)),
        Row(id: "interface.themeMusicLoop", key: .uiThemeMusicLoop, saved: .bool(true), backup: .bool(true), current: .bool(false)),
        Row(id: "interface.themeMusicLoop", key: .uiThemeMusicLoop, saved: .bool(false), backup: .bool(false), current: .bool(true)),
    ] + SettingsBackupRemoteBatchOneTests.profileRowsTable

    /// Batch 2: the ten profile-scope settings. `saved: nil` is an absent profile row (inherits).
    private static let profileRowsTable: [Row] = [
        Row(id: "interface.advisoryAge", key: .catalogShowAdvisoryAge, saved: .bool(true), backup: .bool(true), current: .bool(false), scope: .profile),
        Row(id: "interface.advisoryAge", key: .catalogShowAdvisoryAge, saved: .bool(false), backup: .bool(false), current: .bool(true), scope: .profile),
        Row(id: "interface.advisoryAge", key: .catalogShowAdvisoryAge, saved: nil, backup: inherit, current: .bool(true), scope: .profile),
        Row(id: "interface.hideEpisodeImages", key: .catalogHideUnwatchedEpisodeImages, saved: .bool(true), backup: .bool(true), current: .bool(false), scope: .profile),
        Row(id: "interface.hideEpisodeImages", key: .catalogHideUnwatchedEpisodeImages, saved: .bool(false), backup: .bool(false), current: .bool(true), scope: .profile),
        Row(id: "interface.hideEpisodeDescriptions", key: .catalogHideUnwatchedEpisodeOverviews, saved: .bool(true), backup: .bool(true), current: .bool(false), scope: .profile),
        Row(id: "interface.hideEpisodeDescriptions", key: .catalogHideUnwatchedEpisodeOverviews, saved: .bool(false), backup: .bool(false), current: .bool(true), scope: .profile),
        Row(id: "player.videoSkipBackSeconds", key: .playerVideoSkipBackSeconds, saved: .int(45), backup: .int(45), current: .int(10), scope: .profile),
        Row(id: "player.videoSkipForwardSeconds", key: .playerVideoSkipForwardSeconds, saved: .int(5), backup: .int(5), current: .int(30), scope: .profile),
        Row(id: "player.videoSkipForwardSeconds", key: .playerVideoSkipForwardSeconds, saved: nil, backup: inherit, current: .int(90), scope: .profile),
        Row(id: "player.audiobookSkipBackSeconds", key: .playerAudiobookSkipBackSeconds, saved: .int(90), backup: .int(90), current: .int(10), scope: .profile),
        Row(id: "player.audiobookSkipForwardSeconds", key: .playerAudiobookSkipForwardSeconds, saved: .int(60), backup: .int(60), current: .int(30), scope: .profile),
        Row(id: "subtitles.mode", key: .playbackSubtitleMode, saved: .string("always"), backup: .string("always"), current: .string("auto"), scope: .profile),
        Row(id: "subtitles.mode", key: .playbackSubtitleMode, saved: .string("off"), backup: .string("off"), current: .string("always"), scope: .profile),
        Row(id: "subtitles.showForced", key: .playbackShowForcedSubtitles, saved: .bool(false), backup: .bool(false), current: .bool(true), scope: .profile),
        Row(id: "subtitles.showForced", key: .playbackShowForcedSubtitles, saved: .bool(true), backup: .bool(true), current: .bool(false), scope: .profile),
        Row(id: "subtitles.metadataLanguage", key: .catalogMetadataLanguage, saved: .string("ja"), backup: .string("ja"), current: .string("en"), scope: .profile),
        Row(id: "subtitles.metadataLanguage", key: .catalogMetadataLanguage, saved: .null, backup: .string("~null"), current: .string("en"), scope: .profile),
        Row(id: "subtitles.metadataLanguage", key: .catalogMetadataLanguage, saved: nil, backup: inherit, current: .string("en"), scope: .profile),
    ]

    private func document(_ adapter: SettingsBackupRemoteAdapter) async throws -> IncomingBackup {
        let exported = try await adapter.export()
        return try SettingsBackupCodec.decode(SettingsBackupCodec.makeUnifiedDocument(
            groups: exported.groups, scope: exported.scope, app: app, now: Date()))
    }

    func testEveryBatchOneAndTwoSettingIsCoveredByTheTable() {
        let batch: Set<RemoteBackupDefinition> = [
            .maxBitrate, .bufferingQuality, .hdr, .dolbyVision, .introSkip, .skipCredits, .autoPlayNext,
            .nextUpPrompt, .playbackSpeed, .videoSizing, .orientation, .seekCache, .themeMusic, .themeMusicLoop,
        ]
        let batchTwo: Set<RemoteBackupDefinition> = [
            .advisoryAge, .hideEpisodeImages, .hideEpisodeDescriptions, .videoSkipBack, .videoSkipForward,
            .audiobookSkipBack, .audiobookSkipForward, .subtitleMode, .forcedSubtitles, .metadataLanguage,
        ]
        XCTAssertEqual(Set(rows.map(\.id)), Set(batch.union(batchTwo).map(\.id)))
        XCTAssertEqual(Set(RemoteBackupDefinition.allCases).subtracting(batch).subtracting(batchTwo),
                       [.resolution, .audioLanguage, .subtitleLanguage])
        for definition in batchTwo { XCTAssertEqual(definition.scope, .profile, definition.id) }
        for definition in batch {
            XCTAssertEqual(definition.scope, .profileDevice, definition.id)
            XCTAssertFalse(SettingsBackupSafety.isSensitiveName(definition.id), definition.id)
        }
    }

    /// The adapter writes the same scope the owning screens write, so restore cannot move a value
    /// to the profile or another device.
    func testBatchOneKeysAreTheOwnersProfileDeviceKeys() {
        let playerKeys = Set(SettingKey.playerDeviceSettings + SettingKey.playerBufferingQualitySettings)
        for definition in RemoteBackupDefinition.allCases where definition.scope == .profileDevice {
            let owned = playerKeys.contains(definition.key) || ThemeMusicPreferences.keys.contains(definition.key)
            XCTAssertTrue(owned, "\(definition.id) is not a profile-device key its owner writes")
        }
        // Subtitle timing follows the appearance scope switch and is deliberately not in this batch.
        XCTAssertFalse(RemoteBackupDefinition.allCases.contains { $0.key == .playerSubtitleSyncMs })
    }

    func testCapabilityGatingMatchesTheRevisionTable() {
        for definition in RemoteBackupDefinition.allCases {
            XCTAssertEqual(definition.requiresCapability, definition.key.isNewerThanMinimumServer, definition.id)
        }
    }

    func testChoicesAndLabelsMatchProductionEnums() {
        func choices(_ definition: RemoteBackupDefinition) -> [String] {
            guard case .choice(let options) = definition.kind else { return [] }
            return options.map(\.value)
        }
        XCTAssertEqual(choices(.bufferingQuality), BufferingQualityMode.allCases.map(\.wireValue))
        XCTAssertEqual(choices(.introSkip), IntroSkipMode.allCases.map(\.wireValue))
        XCTAssertEqual(choices(.videoSizing), VideoGravity.allCases.map(\.rawValue))
        XCTAssertEqual(choices(.orientation), [PlayerOrientationMode.landscapeLocked.rawValue,
                                               PlayerOrientationMode.rotateFreely.rawValue])
        for mode in BufferingQualityMode.allCases {
            XCTAssertEqual(RemoteBackupDefinition.bufferingQuality.label(.string(mode.wireValue)), mode.label)
        }
        for mode in IntroSkipMode.allCases {
            XCTAssertEqual(RemoteBackupDefinition.introSkip.label(.string(mode.wireValue)), mode.label)
        }
        for gravity in VideoGravity.allCases {
            XCTAssertEqual(RemoteBackupDefinition.videoSizing.label(.string(gravity.rawValue)), gravity.label)
        }
        XCTAssertEqual(RemoteBackupDefinition.maxBitrate.label(.string("~null")), SiloQualityPresets.noBitrateLimitLabel)
    }

    func testEachSettingRoundTripsThroughTheAuthoritativeScopeAndUndoes() async throws {
        for row in rows {
            let transport = FakeBackupRemoteTransport()
            await transport.set(row.key, to: row.saved)
            if row.saved == nil && row.scope == .profileDevice { await transport.setProfileRow(row.key, to: row.current) }
            let adapter = SettingsBackupRemoteAdapter(transport: transport, journal: MemoryRemoteBackupJournal())
            let incoming = try await document(adapter)
            let group = String(row.id.split(separator: ".")[0])
            XCTAssertEqual(incoming.groups[group]?[row.id], row.backup, "export \(row.id)")

            await transport.set(row.key, to: row.current)
            let preview = await adapter.preview(incoming)
            let item = try XCTUnwrap(preview.flatMap(\.items).first { $0.id == row.id }, row.id)
            XCTAssertEqual(item.status, .willChange, row.id)
            XCTAssertNotEqual(item.current, item.incoming, row.id)

            await transport.clearWrites()
            let report = await adapter.apply(incoming, selectedIDs: [row.id])
            XCTAssertEqual(report.applied, [row.id])
            XCTAssertTrue(report.failed.isEmpty, row.id)
            let restored = await transport.value(row.key)
            XCTAssertEqual(restored, row.saved, "restore \(row.id)")
            let writes = await transport.writes
            let scopes = await transport.writeScopes
            XCTAssertEqual(writes, [row.key], row.id)
            XCTAssertEqual(scopes, [row.scope], row.id)

            let undo = await adapter.undo()
            XCTAssertEqual(undo.applied, [row.id], row.id)
            let undone = await transport.value(row.key)
            XCTAssertEqual(undone, row.current, "undo \(row.id)")
        }
    }

    func testOlderServerOmitsNewerKeysAndReportsThemOnRestore() async throws {
        let full = FakeBackupRemoteTransport()
        await full.set(.playbackBufferingQualityMode, to: .string("ask"))
        await full.set(.uiThemeMusicEnabled, to: .bool(true))
        let fullFile = try await document(SettingsBackupRemoteAdapter(transport: full, journal: MemoryRemoteBackupJournal()))

        let old = FakeBackupRemoteTransport()
        await old.setUnserved([.playbackBufferingQualityMode, .uiThemeMusicEnabled, .uiThemeMusicLoop])
        let oldAdapter = SettingsBackupRemoteAdapter(transport: old, journal: MemoryRemoteBackupJournal())
        let oldFile = try await document(oldAdapter)
        XCTAssertNil(oldFile.groups["streaming"]?["streaming.bufferingQuality"])
        XCTAssertNil(oldFile.groups["interface"])
        let preview = await oldAdapter.preview(fullFile)
        for id in ["streaming.bufferingQuality", "interface.themeMusic", "interface.themeMusicLoop"] {
            XCTAssertEqual(preview.flatMap(\.items).first { $0.id == id }?.status,
                           .unsupported("This server doesn't support this setting."), id)
        }
        let report = await oldAdapter.apply(fullFile, selectedIDs: ["streaming.bufferingQuality", "interface.themeMusic"])
        XCTAssertEqual(report.skipped.count, 2)
        let writes = await old.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testProfileMismatchWritesNothing() async throws {
        let transport = FakeBackupRemoteTransport()
        await transport.set(.playerHdrEnabled, to: .bool(false))
        let adapter = SettingsBackupRemoteAdapter(transport: transport, journal: MemoryRemoteBackupJournal())
        let file = try await document(adapter)
        await transport.set(.playerHdrEnabled, to: .bool(true))
        await transport.moveProfile()
        let preview = await adapter.preview(file)
        XCTAssertTrue(preview.flatMap(\.items).allSatisfy {
            $0.status == .unsupported(SettingsBackupRemoteError.destinationMismatch.localizedDescription)
        })
        _ = await adapter.apply(file, selectedIDs: RemoteBackupDefinition.ids)
        let writes = await transport.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testFailedWriteKeepsRecoveryAndRollsBackConfirmedValues() async throws {
        let transport = FakeBackupRemoteTransport()
        let journal = MemoryRemoteBackupJournal()
        await transport.set(.playbackMaxBitrateKbps, to: .int(10_000))
        await transport.set(.playerHdrEnabled, to: .bool(false))
        let adapter = SettingsBackupRemoteAdapter(transport: transport, journal: journal)
        let file = try await document(adapter)
        await transport.set(.playbackMaxBitrateKbps, to: .null)
        await transport.set(.playerHdrEnabled, to: .bool(true))
        await transport.fail(.playerHdrEnabled)
        let report = await adapter.apply(file, selectedIDs: ["streaming.maxBitrate", "streaming.hdr"])
        XCTAssertEqual(report.applied, ["streaming.maxBitrate"])
        XCTAssertEqual(report.failed, ["streaming.hdr"])
        XCTAssertEqual(journal.record?.state, .applying)
        await transport.fail(nil)
        let recovered = await adapter.undo()
        XCTAssertTrue(recovered.failed.isEmpty)
        let bitrate = await transport.value(.playbackMaxBitrateKbps)
        XCTAssertEqual(bitrate, .null)
        XCTAssertNil(journal.record)
    }

    /// Batch 2 keys are the owners' own profile-scope keys, and the contract lists match production.
    func testBatchTwoMatchesProfileOwnersAndContracts() {
        XCTAssertEqual(RemoteBackupDefinition.seekChoices, SeekIntervalContract.choices)
        for (definition, media, direction) in [
            (RemoteBackupDefinition.videoSkipBack, SeekMedia.video, SeekDirection.backward),
            (.videoSkipForward, .video, .forward), (.audiobookSkipBack, .audiobook, .backward),
            (.audiobookSkipForward, .audiobook, .forward),
        ] {
            XCTAssertEqual(definition.key, SeekIntervalContract.key(media, direction))
        }
        XCTAssertTrue(SeekIntervalContract.keys.allSatisfy { key in
            RemoteBackupDefinition.allCases.contains { $0.key == key }
        })
        XCTAssertEqual(RemoteBackupDefinition.subtitleMode.key, ProfileSettingKeys.subtitleMode)
        XCTAssertEqual(RemoteBackupDefinition.forcedSubtitles.key, ProfileSettingKeys.showForcedSubtitles)
        XCTAssertEqual(RemoteBackupDefinition.metadataLanguage.key, ProfileSettingKeys.metadataLanguage)
        XCTAssertTrue(ProfileSettingKeys.all.allSatisfy { key in
            RemoteBackupDefinition.allCases.contains { $0.key == key && $0.scope == .profile }
        })
        guard case .choice(let modes) = RemoteBackupDefinition.subtitleMode.kind else { return XCTFail("mode kind") }
        XCTAssertEqual(modes.map(\.value), SubtitleMode.allCases.map(\.rawValue))
        XCTAssertEqual(RemoteBackupDefinition.advisoryAge.key, .catalogShowAdvisoryAge)
        XCTAssertEqual(RemoteBackupDefinition.hideEpisodeImages.key, EpisodeSpoilerContract.keys[0])
    }

    func testSeekIntervalsAcceptOnlyContractChoices() {
        for definition in [RemoteBackupDefinition.videoSkipBack, .videoSkipForward, .audiobookSkipBack, .audiobookSkipForward] {
            for seconds in SeekIntervalContract.choices { XCTAssertTrue(definition.validate(.int(seconds))) }
            for bad in [0, 1, 7, 20, 89, 91, 120, -10] { XCTAssertFalse(definition.validate(.int(bad)), "\(bad)") }
            XCTAssertFalse(definition.validate(.string("10")))
            XCTAssertFalse(definition.validate(.string("~null")))
        }
    }

    /// A device, library or series override hides the profile row. It is never exported as the
    /// profile value and never overwritten.
    func testOverrideDoesNotObscureOrOverwriteProfileSubtitleSettings() async throws {
        for hider in [SettingScope.profileDevice, .profileSeries, .profileLibrary] {
            let transport = FakeBackupRemoteTransport()
            await transport.set(.playbackSubtitleMode, to: .string("always"))
            let adapter = SettingsBackupRemoteAdapter(transport: transport, journal: MemoryRemoteBackupJournal())
            let file = try await document(adapter)
            await transport.setOverride(.playbackSubtitleMode, hider, .string("off"))
            let exported = try await adapter.export()
            XCTAssertNil(exported.groups["subtitles"]?["subtitles.mode"])
            XCTAssertTrue(exported.omitted.contains { $0.hasPrefix("Subtitle behavior") && $0.contains("override") })
            let preview = await adapter.preview(file)
            XCTAssertEqual(preview.flatMap(\.items).first { $0.id == "subtitles.mode" }?.status,
                           .unsupported(SettingsBackupRemoteError.overridden.localizedDescription))
            await transport.clearWrites()
            let report = await adapter.apply(file, selectedIDs: ["subtitles.mode"])
            XCTAssertEqual(report.skipped, ["subtitles.mode"])
            XCTAssertTrue(report.failed.isEmpty)
            let writes = await transport.writes
            XCTAssertTrue(writes.isEmpty)
            let profileValue = await transport.value(.playbackSubtitleMode)
            XCTAssertEqual(profileValue, .string("always"))
        }
    }

    func testOlderServerOmitsNewerProfileKeysButKeepsSubtitleSettings() async throws {
        let old = FakeBackupRemoteTransport()
        let gated: Set<SettingKey> = [
            .catalogShowAdvisoryAge, .catalogHideUnwatchedEpisodeImages, .catalogHideUnwatchedEpisodeOverviews,
            .playerVideoSkipBackSeconds, .playerVideoSkipForwardSeconds, .playerAudiobookSkipBackSeconds,
            .playerAudiobookSkipForwardSeconds,
        ]
        await old.setUnserved(gated)
        let adapter = SettingsBackupRemoteAdapter(transport: old, journal: MemoryRemoteBackupJournal())
        let exported = try await adapter.export()
        XCTAssertEqual(exported.groups["subtitles"]?.count, 7)
        XCTAssertEqual(exported.omitted.count, 7)
        XCTAssertNil(exported.groups["player"]?["player.videoSkipBackSeconds"])
    }

    func testOutOfContractValuesAreRefused() {
        XCTAssertFalse(RemoteBackupDefinition.playbackSpeed.validate(.int(127)))
        XCTAssertFalse(RemoteBackupDefinition.playbackSpeed.validate(.int(305)))
        XCTAssertTrue(RemoteBackupDefinition.playbackSpeed.validate(.int(25)))
        XCTAssertFalse(RemoteBackupDefinition.nextUpPrompt.validate(.int(121)))
        XCTAssertFalse(RemoteBackupDefinition.nextUpPrompt.validate(.string("~null")))
        XCTAssertFalse(RemoteBackupDefinition.maxBitrate.validate(.int(99)))
        XCTAssertTrue(RemoteBackupDefinition.maxBitrate.validate(.string("~null")))
        XCTAssertFalse(RemoteBackupDefinition.hdr.validate(.int(1)))
        XCTAssertFalse(RemoteBackupDefinition.hdr.validate(.string("~null")))
        XCTAssertFalse(RemoteBackupDefinition.orientation.validate(.string("sideways")))
        XCTAssertEqual(try RemoteBackupDefinition.playbackSpeed.wireValue(.int(125)), .double(1.25))
        XCTAssertNil(try RemoteBackupDefinition.hdr.wireValue(Self.inherit))
    }
}
#endif
