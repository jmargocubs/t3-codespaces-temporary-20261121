#if KYRO_STANDALONE_TESTS
import Foundation

// Minimal wire-model stubs let the production backup adapter and model run on macOS without an
// iOS Simulator, a server, or the rest of the app. iOS XCTest uses the real wire models instead.
struct HTTPRequestIdentity: Equatable, Sendable {
    let serverId: String
    let serverURL: String
    let profileId: String
    let clientFamily: String
}
enum SettingKey: String, Hashable, Sendable, CaseIterable {
    case playbackPreferredQuality = "playback.preferred_quality"
    case playbackAudioLanguage = "playback.audio_language"
    case playbackSubtitleLanguage = "playback.subtitle_language"
    case playbackMaxBitrateKbps = "playback.max_bitrate_kbps"
    case playbackBufferingQualityMode = "playback.buffering_quality_mode"
    case playerHdrEnabled = "player.hdr_enabled"
    case playerDolbyVisionEnabled = "player.dolby_vision_enabled"
    case playbackIntroSkipMode = "playback.intro_skip_mode"
    case playbackAutoSkipCredits = "playback.auto_skip_credits"
    case playbackAutoPlayNext = "playback.auto_play_next"
    case playbackNextUpPromptSeconds = "playback.next_up_prompt_seconds"
    case playerPlaybackSpeed = "player.playback_speed"
    case playerVideoGravity = "player.video_gravity"
    case playerOrientationMode = "player.orientation_mode"
    case playerSeekCacheEnabled = "player.seek_cache_enabled"
    case uiThemeMusicEnabled = "ui.theme_music_enabled"
    case uiThemeMusicLoop = "ui.theme_music_loop"
    case catalogShowAdvisoryAge = "catalog.show_advisory_age"
    case catalogHideUnwatchedEpisodeImages = "catalog.hide_unwatched_episode_images"
    case catalogHideUnwatchedEpisodeOverviews = "catalog.hide_unwatched_episode_overviews"
    case playerVideoSkipBackSeconds = "player.video_skip_back_seconds"
    case playerVideoSkipForwardSeconds = "player.video_skip_forward_seconds"
    case playerAudiobookSkipBackSeconds = "player.audiobook_skip_back_seconds"
    case playerAudiobookSkipForwardSeconds = "player.audiobook_skip_forward_seconds"
    case playbackSubtitleMode = "playback.subtitle_mode"
    case playbackShowForcedSubtitles = "playback.show_forced_subtitles"
    case catalogMetadataLanguage = "catalog.metadata_language"
    case playbackSubtitleAppearance = "playback.subtitle_appearance"
    case playerSubtitleSyncMs = "player.subtitle_sync_ms"
    case playbackCellularPreferredQuality = "playback.cellular_preferred_quality"
    case playbackCellularMaxBitrateKbps = "playback.cellular_max_bitrate_kbps"
    case uiTitleArt = "ui.title_art"
    case uiCardPresentation = "ui.card_presentation"
    case navPrimaryMenu = "nav.primary_menu"
    case navShortcuts = "nav.shortcuts"
    static let cellularQualityRevision = 20
    var introducedIn: Int { self == .uiTitleArt ? 16 : 1 }

    /// Keys the real contract stores at profile scope; everything else here is per device.
    /// Stored at both `profile` and `profile_device`.
    static let dual: Set<SettingKey> = [.playbackSubtitleAppearance, .playerSubtitleSyncMs,
        .playbackCellularPreferredQuality, .playbackCellularMaxBitrateKbps, .uiTitleArt,
        .uiCardPresentation, .navPrimaryMenu]
    static let profileScoped: Set<SettingKey> = [
        .playbackSubtitleLanguage, .catalogShowAdvisoryAge, .catalogHideUnwatchedEpisodeImages,
        .catalogHideUnwatchedEpisodeOverviews, .playerVideoSkipBackSeconds, .playerVideoSkipForwardSeconds,
        .playerAudiobookSkipBackSeconds, .playerAudiobookSkipForwardSeconds, .playbackSubtitleMode,
        .playbackShowForcedSubtitles, .catalogMetadataLanguage,
    ]
}
enum SettingScope: Equatable, Sendable {
    case account, profile, profileClient, profileDevice, profileLibrary, profileSeries
    var rawValue: String {
        switch self {
        case .account: "account"
        case .profile: "profile"
        case .profileClient: "profile_client"
        case .profileDevice: "profile_device"
        case .profileLibrary: "profile_library"
        case .profileSeries: "profile_series"
        }
    }
}
enum SettingScopeIdentity: Equatable, Sendable {
    case profile, profileClient, profileDevice
    var scope: SettingScope {
        switch self {
        case .profile: .profile
        case .profileClient: .profileClient
        case .profileDevice: .profileDevice
        }
    }
}
enum SettingJSONValue: Equatable, Sendable {
    case null, bool(Bool), int(Int), double(Double), string(String), array([SettingJSONValue]), object([String: SettingJSONValue])
    var intValue: Int? {
        switch self {
        case .int(let value): value
        case .double(let value) where value == value.rounded(): Int(exactly: value)
        default: nil
        }
    }
    var doubleValue: Double? {
        switch self {
        case .double(let value): value
        case .int(let value): Double(value)
        default: nil
        }
    }
}
struct EffectiveSettingValue: Sendable {
    let key: String
    let value: SettingJSONValue
    let storedValue: SettingJSONValue?
    let scope: SettingScope?
    let profileId: String?
}
struct EffectiveSettingValuesResponse: Sendable {
    let byKey: [SettingKey: EffectiveSettingValue]
}
enum SiloQualityPresets {
    static let resolutionChoices = ["auto", "2160p", "1080p", "720p", "480p"]
    static func resolutionLabel(_ value: String) -> String { value }
}

private actor FakeTransport: SettingsBackupRemoteTransport {
    enum Failure: Error { case offline }
    var scope = SettingsBackupScope(serverFingerprint: String(repeating: "a", count: 64),
                                    profileFingerprint: String(repeating: "b", count: 64))
    var values: [SettingKey: SettingJSONValue] = [
        .playbackPreferredQuality: .string("1080p"), .playbackAudioLanguage: .string("en"),
        .playbackSubtitleLanguage: .string("en")]
    /// Rows authored at profile scope, which a profile-device setting inherits.
    var profileValues: [SettingKey: SettingJSONValue] = [:]
    /// Keys this fake server does not serve, like a server older than their manifest revision.
    var unserved: Set<SettingKey> = []
    /// Rows of the two keys that live at both scopes: subtitle appearance and subtitle sync.
    var deviceRows: [SettingKey: SettingJSONValue] = [:]
    var profileScopeRows: [SettingKey: SettingJSONValue] = [:]
    var clientRows: [SettingKey: SettingJSONValue] = [:]
    var catalog: [BackupLibraryIdentity] = [
        .init(id: 1, name: "Movies", type: "movie"), .init(id: 2, name: "Shows", type: "series")]
    var sectionsByLibrary: [Int: [BackupSectionIdentity]] = [:]
    var collectionsByLibrary: [Int: [BackupCollectionIdentity]] = [:]
    var revision = 99
    /// Fails one (key, scope) write; every other write still succeeds.
    var failWrite: (key: SettingKey, scope: SettingScopeIdentity)?
    /// A narrower-scope row (device, library or series) that wins over the profile row.
    var overrides: [SettingKey: (scope: SettingScope, value: SettingJSONValue)] = [:]
    var failedKey: SettingKey?
    var offline = false
    var delay: Duration?
    var writes: [SettingKey] = []
    var scopes: [SettingScopeIdentity] = []

    func owner() async throws -> SettingsBackupRemoteOwner {
        SettingsBackupRemoteOwner(
            request: HTTPRequestIdentity(serverId: "local", serverURL: "https://example.invalid",
                                         profileId: "profile", clientFamily: "ios"), scope: scope)
    }
    func read(_ keys: [SettingKey], owner: SettingsBackupRemoteOwner) async throws -> EffectiveSettingValuesResponse {
        if let delay { try await Task.sleep(for: delay) }
        if offline { throw Failure.offline }
        var rows: [SettingKey: EffectiveSettingValue] = [:]
        for key in keys where !unserved.contains(key)
            && !(revision < SettingKey.cellularQualityRevision
                 && (key == .playbackCellularPreferredQuality || key == .playbackCellularMaxBitrateKbps)) {
            let own: SettingScope = key == .navShortcuts || SettingKey.profileScoped.contains(key)
                ? .profile : .profileDevice
            if SettingKey.dual.contains(key) {
                if let hidden = overrides[key] {
                    rows[key] = EffectiveSettingValue(key: key.rawValue, value: hidden.value, storedValue: nil,
                                                      scope: hidden.scope, profileId: "profile")
                } else if key == .uiTitleArt, let value = profileScopeRows[key] {
                    rows[key] = EffectiveSettingValue(key: key.rawValue, value: value, storedValue: nil,
                                                      scope: .profile, profileId: "profile")
                } else if let value = deviceRows[key] {
                    rows[key] = EffectiveSettingValue(key: key.rawValue, value: value, storedValue: nil,
                                                      scope: .profileDevice, profileId: "profile")
                } else if let value = clientRows[key] {
                    rows[key] = EffectiveSettingValue(key: key.rawValue, value: value, storedValue: nil,
                                                      scope: .profileClient, profileId: "profile")
                } else if let value = profileScopeRows[key] {
                    rows[key] = EffectiveSettingValue(key: key.rawValue, value: value, storedValue: nil,
                                                      scope: .profile, profileId: "profile")
                } else {
                    let candidates: [([SettingKey: SettingJSONValue], SettingScope)] = key == .uiTitleArt
                        ? [(profileScopeRows, .profile), (deviceRows, .profileDevice)]
                        : [(deviceRows, .profileDevice), (profileScopeRows, .profile)]
                    if let selected = candidates.first(where: { $0.0[key] != nil }), let value = selected.0[key] {
                        rows[key] = EffectiveSettingValue(key: key.rawValue, value: value, storedValue: nil,
                                                          scope: selected.1, profileId: "profile")
                        continue
                    }
                    rows[key] = EffectiveSettingValue(
                        key: key.rawValue, value: defaultValue(key),
                        storedValue: nil, scope: nil, profileId: nil)
                }
                continue
            }
            if let hidden = overrides[key] {
                rows[key] = EffectiveSettingValue(key: key.rawValue, value: hidden.value, storedValue: nil,
                                                  scope: hidden.scope, profileId: "profile")
            } else if let value = values[key] {
                rows[key] = EffectiveSettingValue(key: key.rawValue, value: value, storedValue: nil,
                                                  scope: own, profileId: "profile")
            } else if let value = profileValues[key] {
                rows[key] = EffectiveSettingValue(key: key.rawValue, value: value, storedValue: nil,
                                                  scope: .profile, profileId: "profile")
            } else {
                rows[key] = EffectiveSettingValue(
                    key: key.rawValue, value: defaultValue(key),
                    storedValue: nil, scope: nil, profileId: nil)
            }
        }
        return EffectiveSettingValuesResponse(byKey: rows)
    }
    func put(_ key: SettingKey, scope: SettingScopeIdentity, value: SettingJSONValue,
             owner: SettingsBackupRemoteOwner) async throws {
        if offline || key == failedKey || unserved.contains(key) { throw Failure.offline }
        if let failWrite, failWrite.key == key, failWrite.scope == scope { throw Failure.offline }
        if SettingKey.dual.contains(key) {
            if scope == .profileDevice { deviceRows[key] = value }
            else if scope == .profileClient { clientRows[key] = value }
            else { profileScopeRows[key] = value }
        } else { values[key] = value }
        writes.append(key)
        scopes.append(scope)
    }
    func delete(_ key: SettingKey, scope: SettingScopeIdentity,
                owner: SettingsBackupRemoteOwner) async throws {
        if offline || key == failedKey || unserved.contains(key) { throw Failure.offline }
        if let failWrite, failWrite.key == key, failWrite.scope == scope { throw Failure.offline }
        if SettingKey.dual.contains(key) {
            if scope == .profileDevice { deviceRows[key] = nil }
            else if scope == .profileClient { clientRows[key] = nil }
            else { profileScopeRows[key] = nil }
        } else { values[key] = nil }
        writes.append(key)
        scopes.append(scope)
    }
    func change(_ key: SettingKey, _ value: SettingJSONValue?) { values[key] = value }
    func setProfileValue(_ key: SettingKey, _ value: SettingJSONValue?) { profileValues[key] = value }
    func setUnserved(_ keys: Set<SettingKey>) { unserved = keys }
    func manifestRevision(owner: SettingsBackupRemoteOwner) async throws -> Int { revision }
    func setRevision(_ value: Int) { revision = value }
    func setRow(_ key: SettingKey, _ scope: SettingScopeIdentity, _ value: SettingJSONValue?) {
        if key == .navShortcuts { values[key] = value; return }
        if scope == .profileDevice { deviceRows[key] = value }
        else if scope == .profileClient { clientRows[key] = value }
        else { profileScopeRows[key] = value }
    }
    func row(_ key: SettingKey, _ scope: SettingScopeIdentity) -> SettingJSONValue? {
        if key == .navShortcuts { return values[key] }
        return scope == .profileDevice ? deviceRows[key]
            : scope == .profileClient ? clientRows[key] : profileScopeRows[key]
    }
    private func defaultValue(_ key: SettingKey) -> SettingJSONValue {
        switch key {
        case .playerSubtitleSyncMs: .int(0)
        case .playbackSubtitleAppearance: SubtitleFixtures.json([:])
        case .playbackCellularPreferredQuality: .string("720p")
        case .playbackCellularMaxBitrateKbps: .int(2000)
        case .uiTitleArt: .bool(true)
        case .uiCardPresentation: .object(["poster_size": .string("standard"), "caption": .string("title_metadata")])
        case .navPrimaryMenu: .null
        case .navShortcuts: .object(["items": .array([])])
        case .playbackPreferredQuality: .string("auto")
        default: .null
        }
    }
    func libraries(owner: SettingsBackupRemoteOwner) async throws -> [BackupLibraryIdentity] {
        if offline { throw Failure.offline }
        return catalog
    }
    func sections(libraryID: Int, owner: SettingsBackupRemoteOwner) async throws -> [BackupSectionIdentity] {
        if offline { throw Failure.offline }
        return sectionsByLibrary[libraryID] ?? []
    }
    func collections(libraryID: Int, owner: SettingsBackupRemoteOwner) async throws -> [BackupCollectionIdentity] {
        if offline { throw Failure.offline }
        return collectionsByLibrary[libraryID] ?? []
    }
    func mutateShortcut(_ value: SettingJSONValue, present: Bool, owner: SettingsBackupRemoteOwner) async throws {
        if offline || failedKey == .navShortcuts { throw Failure.offline }
        guard case .object(let fields) = value,
              case .object(let current) = values[.navShortcuts] ?? .object(["items": .array([])]),
              case .array(let items)? = current["items"] else { throw Failure.offline }
        let identity = fields["library_id"] ?? fields["collection_id"] ?? fields["section_id"]
        var changed = items.filter { item in
            guard case .object(let existing) = item else { return true }
            return (existing["library_id"] ?? existing["collection_id"] ?? existing["section_id"]) != identity
        }
        if present { changed.append(value) }
        values[.navShortcuts] = .object(["items": .array(changed)])
        writes.append(.navShortcuts)
        scopes.append(.profile)
    }
    func setCatalog(_ value: [BackupLibraryIdentity]) { catalog = value }
    func setSections(_ libraryID: Int, _ value: [BackupSectionIdentity]) { sectionsByLibrary[libraryID] = value }
    func setCollections(_ libraryID: Int, _ value: [BackupCollectionIdentity]) { collectionsByLibrary[libraryID] = value }
    func setScope(_ value: SettingsBackupScope) { scope = value }
    func failWriting(_ key: SettingKey?, _ scope: SettingScopeIdentity = .profile) {
        failWrite = key.map { ($0, scope) }
    }
    func setOverride(_ key: SettingKey, _ scope: SettingScope?, _ value: SettingJSONValue = .null) {
        overrides[key] = scope.map { ($0, value) }
    }
    func clearWrites() { writes = []; scopes = [] }
    func writtenKeys() -> [SettingKey] { writes }
    func writtenScopes() -> [SettingScopeIdentity] { scopes }
    func fail(_ key: SettingKey?) { failedKey = key }
    func moveProfile() {
        scope = SettingsBackupScope(serverFingerprint: scope.serverFingerprint,
                                    profileFingerprint: String(repeating: "c", count: 64))
    }
    func setOffline(_ value: Bool) { offline = value }
    func setDelay(_ value: Duration?) { delay = value }
    func current(_ key: SettingKey) -> SettingJSONValue? { values[key] }
    func writeCount() -> Int { writes.count }
}

private final class RemoteMemoryJournal: RemoteBackupJournalStoring {
    var record: RemoteBackupJournal?
    func load() throws -> RemoteBackupJournal? { record }
    func save(_ journal: RemoteBackupJournal) throws { record = journal }
    func clear() throws { record = nil }
}

@main
@MainActor
enum SettingsBackupUnifiedHostChecks {
    static func main() async throws {
        let transport = FakeTransport()
        let local = LocalStore()
        let remoteJournal = RemoteMemoryJournal()
        let model = SettingsBackupModel(
            registry: local.registry(), journal: LocalMemoryJournal(),
            app: SettingsBackupAppInfo(version: "1", build: "95", platform: "iOS", idiom: "phone"),
            remote: SettingsBackupRemoteAdapter(transport: transport, journal: remoteJournal,
                                                timeout: .milliseconds(100)))
        model.exportSelection = [.navigation, .streaming, .subtitles]
        guard let file = await model.exportUnifiedDocument() else { fatalError("export failed") }
        let document = try SettingsBackupCodec.decode(file)
        precondition(document.schemaVersion == 3 && document.scope != nil)
        precondition(document.groups["streaming"]?["streaming.resolution"] == .string("1080p"))
        precondition(document.groups["streaming"]?["streaming.audioLanguage"] == .string("en"))
        precondition(document.groups["subtitles"]?["subtitles.language"] == .string("en"))

        local.fourthTab = "forYou"
        await transport.change(.playbackPreferredQuality, .string("480p"))
        await transport.change(.playbackAudioLanguage, .string("zh"))
        await transport.change(.playbackSubtitleLanguage, .string("zh"))
        await model.loadUnifiedImport(data: file)
        precondition(model.selectedChangeCount == 4)
        await model.applyUnifiedSelected()
        precondition(local.fourthTab == "sports")
        let restoredQuality = await transport.current(.playbackPreferredQuality)
        let restoredAudio = await transport.current(.playbackAudioLanguage)
        let restoredLanguage = await transport.current(.playbackSubtitleLanguage)
        precondition(restoredQuality == .string("1080p"))
        precondition(restoredAudio == .string("en"))
        precondition(restoredLanguage == .string("en"))
        precondition(model.lastRestoredCount == 4)
        await model.undoUnified()
        precondition(local.fourthTab == "forYou")
        let undoneQuality = await transport.current(.playbackPreferredQuality)
        let undoneLanguage = await transport.current(.playbackSubtitleLanguage)
        precondition(undoneQuality == .string("480p"))
        precondition(undoneLanguage == .string("zh"))

        await transport.moveProfile()
        await model.loadUnifiedImport(data: file)
        // Streaming and subtitle values, including the composite cellular pair, are refused for
        // a different profile.
        precondition(model.preview?.skippedCount == 14)
        let before = await transport.writeCount()
        await model.applyUnifiedSelected()
        let after = await transport.writeCount()
        precondition(after == before)

        await transport.setOffline(true)
        let offlineExport = await model.exportUnifiedDocument()
        precondition(offlineExport == nil)
        await transport.setOffline(false)
        await transport.setDelay(.milliseconds(200))
        let timeoutAdapter = SettingsBackupRemoteAdapter(
            transport: transport, journal: RemoteMemoryJournal(), timeout: .milliseconds(20))
        do {
            _ = try await timeoutAdapter.export()
            fatalError("timeout failed")
        } catch SettingsBackupRemoteError.timeout {}

        let partialTransport = FakeTransport()
        let partialLocal = LocalStore()
        let partialJournal = RemoteMemoryJournal()
        let partialModel = SettingsBackupModel(
            registry: partialLocal.registry(), journal: LocalMemoryJournal(),
            app: SettingsBackupAppInfo(version: "1", build: "95", platform: "iOS", idiom: "phone"),
            remote: SettingsBackupRemoteAdapter(transport: partialTransport, journal: partialJournal))
        partialModel.exportSelection = [.navigation, .streaming, .subtitles]
        guard let partialFile = await partialModel.exportUnifiedDocument() else { fatalError("partial export failed") }
        partialLocal.fourthTab = "forYou"
        await partialTransport.change(.playbackPreferredQuality, .string("480p"))
        await partialTransport.change(.playbackAudioLanguage, .string("zh"))
        await partialTransport.change(.playbackSubtitleLanguage, .string("zh"))
        await partialTransport.fail(.playbackSubtitleLanguage)
        await partialModel.loadUnifiedImport(data: partialFile)
        await partialModel.applyUnifiedSelected()
        precondition(partialLocal.fourthTab == "forYou")
        precondition(partialModel.needsRecovery && partialModel.lastRestoredCount == nil)
        let partialQuality = await partialTransport.current(.playbackPreferredQuality)
        let partialAudio = await partialTransport.current(.playbackAudioLanguage)
        let partialLanguage = await partialTransport.current(.playbackSubtitleLanguage)
        precondition(partialQuality == .string("1080p") && partialAudio == .string("en")
                     && partialLanguage == .string("zh"))
        await partialTransport.fail(nil)
        await partialModel.recoverUnified()
        let recoveredQuality = await partialTransport.current(.playbackPreferredQuality)
        let recoveredAudio = await partialTransport.current(.playbackAudioLanguage)
        precondition(recoveredQuality == .string("480p"))
        precondition(recoveredAudio == .string("zh"))

        let selectiveTransport = FakeTransport()
        let selectiveLocal = LocalStore()
        let selectiveModel = SettingsBackupModel(
            registry: selectiveLocal.registry(), journal: LocalMemoryJournal(),
            app: SettingsBackupAppInfo(version: "1", build: "95", platform: "iOS", idiom: "phone"),
            remote: SettingsBackupRemoteAdapter(transport: selectiveTransport, journal: RemoteMemoryJournal()))
        selectiveModel.exportSelection = [.navigation, .streaming, .subtitles]
        guard let selectiveFile = await selectiveModel.exportUnifiedDocument() else { fatalError("selective export failed") }
        selectiveLocal.fourthTab = "forYou"
        await selectiveTransport.change(.playbackPreferredQuality, .string("480p"))
        await selectiveTransport.change(.playbackSubtitleLanguage, .string("zh"))
        await selectiveModel.loadUnifiedImport(data: selectiveFile)
        selectiveModel.setImport("subtitles.language", enabled: false)
        await selectiveModel.applyUnifiedSelected()
        let untouchedLanguage = await selectiveTransport.current(.playbackSubtitleLanguage)
        precondition(untouchedLanguage == .string("zh") && selectiveLocal.fourthTab == "sports")

        let cancellationTransport = FakeTransport()
        await cancellationTransport.setDelay(.milliseconds(200))
        let cancellationAdapter = SettingsBackupRemoteAdapter(
            transport: cancellationTransport, journal: RemoteMemoryJournal(), timeout: .seconds(1))
        let cancelled = Task { try await cancellationAdapter.export() }
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            fatalError("cancelled export returned a file")
        } catch is CancellationError {}

        let batchCount = try await RemoteBatchOneChecks.run()
        let batchThree = try await RemoteBatchThreeChecks.run()
        let batchFour = try await RemoteBatchFourChecks.run()
        let batchFive = try await RemoteBatchFiveChecks.run()
        print("SettingsBackupUnifiedHostChecks: \(10 + batchCount + batchThree + batchFour + batchFive) passed")
    }
}

/// Subtitle appearance fixtures: complete server objects, as the effective API returns them.
enum SubtitleFixtures {
    static let defaults: [String: SettingJSONValue] = [
        "fontSize": .string("large"), "fontFamily": .string("sans-serif"), "fontColor": .string("#ffffff"),
        "backgroundColor": .string("#000000"), "backgroundStyle": .string("box"), "backgroundOpacity": .int(75),
        "textOpacity": .int(100), "textOutline": .bool(false), "textOutlineColor": .string("#000000"),
        "position": .string("bottom"),
    ]
    static func json(_ changes: [String: SettingJSONValue]) -> SettingJSONValue {
        .object(defaults.merging(changes) { _, new in new })
    }
    static let custom = json([
        "fontSize": .string("xlarge"), "fontFamily": .string("monospace"), "fontColor": .string("#facc15"),
        "backgroundColor": .string("#1e3a5f"), "backgroundStyle": .string("shadow"), "backgroundOpacity": .int(40),
        "textOpacity": .int(80), "textOutline": .bool(true), "textOutlineColor": .string("#7f1d1d"),
        "position": .string("top"),
    ])
    static let other = json(["fontSize": .string("small"), "fontColor": .string("#22c55e"), "position": .string("lower-third")])
}

/// Batch 1: the fourteen profile-device scalar settings, one table row per value transition.
@MainActor
private enum RemoteBatchOneChecks {
    struct Row {
        let id: String
        let key: SettingKey
        /// The backed-up server value; nil means this device has no row (it inherits).
        let saved: SettingJSONValue?
        let backup: BackupValue
        /// The value the destination holds before restore.
        let current: SettingJSONValue?
        var scope: SettingScopeIdentity = .profileDevice
    }

    static let inherit = BackupValue.string("~inherit")

    static let rows: [Row] = [
        Row(id: "streaming.maxBitrate", key: .playbackMaxBitrateKbps, saved: .int(6000), backup: .int(6000), current: .null),
        Row(id: "streaming.maxBitrate", key: .playbackMaxBitrateKbps, saved: .null, backup: .string("~null"), current: .int(2000)),
        Row(id: "streaming.maxBitrate", key: .playbackMaxBitrateKbps, saved: nil, backup: inherit, current: .int(2000)),
        Row(id: "streaming.bufferingQuality", key: .playbackBufferingQualityMode, saved: .string("never"), backup: .string("never"), current: .string("always")),
        Row(id: "streaming.hdr", key: .playerHdrEnabled, saved: .bool(false), backup: .bool(false), current: .bool(true)),
        Row(id: "streaming.hdr", key: .playerHdrEnabled, saved: .bool(true), backup: .bool(true), current: .bool(false)),
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
    ] + profileRows

    /// Batch 2: profile-scope scalars. `saved: nil` is an absent profile row, so the value inherits.
    static let profileRows: [Row] = [
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

    static let app = SettingsBackupAppInfo(version: "1", build: "97", platform: "iOS", idiom: "phone")

    static func document(_ adapter: SettingsBackupRemoteAdapter) async throws -> IncomingBackup {
        let exported = try await adapter.export()
        return try SettingsBackupCodec.decode(SettingsBackupCodec.makeUnifiedDocument(
            groups: exported.groups, scope: exported.scope, app: app, now: Date()))
    }

    static func item(_ groups: [RestorePreviewGroup], _ id: String) -> RestorePreviewItem? {
        groups.flatMap(\.items).first { $0.id == id }
    }

    static func run() async throws -> Int {
        var checks = 0

        // Every new ID passes the document's sensitive-name filter and is owned by the adapter.
        let newIDs = Set(rows.map(\.id))
        precondition(newIDs.count == 24 && newIDs.isSubset(of: SettingsBackupRemoteAdapter.settingIDs))
        precondition(SettingsBackupRemoteAdapter.settingIDs.count == 35)
        precondition(SettingsBackupRemoteAdapter.settingIDs.allSatisfy { !SettingsBackupSafety.isSensitiveName($0) })
        checks += 1

        // Round trip per row: export → change → preview → restore → confirm → Undo.
        for row in rows {
            let transport = FakeTransport()
            await transport.change(row.key, row.saved)
            if row.saved == nil && row.scope == .profileDevice { await transport.setProfileValue(row.key, row.current) }
            let adapter = SettingsBackupRemoteAdapter(transport: transport, journal: RemoteMemoryJournal(),
                                                      timeout: .seconds(1))
            let incoming = try await document(adapter)
            let group = row.id.split(separator: ".").first.map(String.init)!
            if row.scope == .profile && row.saved == nil {
                // Inherited: exporting must find no profile row, and a different value is set after.
                precondition(incoming.groups[group]?[row.id] == row.backup, "inherited export \(row.id)")
            }
            precondition(incoming.groups[group]?[row.id] == row.backup, "export \(row.id) \(row.backup)")

            await transport.change(row.key, row.current)
            let preview = await adapter.preview(incoming)
            guard let entry = item(preview, row.id) else { fatalError("preview missing \(row.id)") }
            precondition(entry.status == .willChange, "preview \(row.id) \(entry.status)")
            precondition(entry.current != nil && entry.current != entry.incoming)

            await transport.clearWrites()
            let report = await adapter.apply(incoming, selectedIDs: [row.id])
            precondition(report.applied == [row.id] && report.failed.isEmpty, "apply \(row.id)")
            let restored = await transport.current(row.key)
            precondition(restored == row.saved, "restored \(row.id) \(String(describing: restored))")
            let written = await transport.writtenKeys()
            let scopes = await transport.writtenScopes()
            precondition(written == [row.key] && scopes == [row.scope], "scope \(row.id)")

            let undo = await adapter.undo()
            precondition(undo.applied == [row.id] && undo.failed.isEmpty, "undo \(row.id)")
            let undone = await transport.current(row.key)
            precondition(undone == row.current, "undo value \(row.id)")
            precondition(!adapter.undoAvailable)
            checks += 1
        }

        // A server older than revision 23/11 omits those keys from export and reports them as
        // unsupported on restore; the rest of the backup still works.
        let full = FakeTransport()
        await full.change(.playbackBufferingQualityMode, .string("ask"))
        await full.change(.uiThemeMusicEnabled, .bool(true))
        let fullFile = try await document(SettingsBackupRemoteAdapter(transport: full, journal: RemoteMemoryJournal()))
        let old = FakeTransport()
        let gated: Set<SettingKey> = [.playbackBufferingQualityMode, .uiThemeMusicEnabled, .uiThemeMusicLoop]
        await old.setUnserved(gated)
        let oldAdapter = SettingsBackupRemoteAdapter(transport: old, journal: RemoteMemoryJournal())
        let oldFile = try await document(oldAdapter)
        precondition(oldFile.groups["streaming"]?["streaming.bufferingQuality"] == nil)
        precondition(oldFile.groups["interface"]?["interface.themeMusic"] == nil)
        precondition(oldFile.groups["interface"]?["interface.themeMusicLoop"] == nil)
        precondition(oldFile.groups["streaming"]?["streaming.hdr"] == inherit)
        let oldPreview = await oldAdapter.preview(fullFile)
        for id in ["streaming.bufferingQuality", "interface.themeMusic", "interface.themeMusicLoop"] {
            precondition(item(oldPreview, id)?.status == .unsupported("This server doesn't support this setting."))
        }
        let oldReport = await oldAdapter.apply(fullFile, selectedIDs: ["streaming.bufferingQuality", "interface.themeMusic"])
        let oldWrites = await old.writeCount()
        precondition(oldReport.skipped.count == 2 && oldReport.failed.isEmpty && oldWrites == 0)
        checks += 1

        // Profile mismatch: nothing in batch 1 is written, and every item says why.
        let source = FakeTransport()
        await source.change(.playerHdrEnabled, .bool(false))
        await source.change(.playbackAutoPlayNext, .bool(false))
        let sourceAdapter = SettingsBackupRemoteAdapter(transport: source, journal: RemoteMemoryJournal())
        let sourceFile = try await document(sourceAdapter)
        await source.change(.playerHdrEnabled, .bool(true))
        await source.moveProfile()
        let mismatch = await sourceAdapter.preview(sourceFile)
        precondition(mismatch.flatMap(\.items).allSatisfy {
            $0.status == .unsupported(SettingsBackupRemoteError.destinationMismatch.localizedDescription)
        })
        precondition(mismatch.flatMap(\.items).count == SettingsBackupRemoteAdapter.settingIDs.count)
        let mismatchReport = await sourceAdapter.apply(sourceFile, selectedIDs: newIDs)
        let mismatchWrites = await source.writeCount()
        precondition(mismatchWrites == 0 && mismatchReport.applied.isEmpty)
        checks += 1

        // API failure mid-restore: earlier writes are confirmed, the failed one is reported, the
        // journal stays in recovery, and recovery puts the confirmed writes back.
        let failing = FakeTransport()
        await failing.change(.playbackMaxBitrateKbps, .int(10_000))
        await failing.change(.playerHdrEnabled, .bool(false))
        await failing.change(.playbackAutoPlayNext, .bool(false))
        let failingJournal = RemoteMemoryJournal()
        let failingAdapter = SettingsBackupRemoteAdapter(transport: failing, journal: failingJournal)
        let failingFile = try await document(failingAdapter)
        await failing.change(.playbackMaxBitrateKbps, .null)
        await failing.change(.playerHdrEnabled, .bool(true))
        await failing.change(.playbackAutoPlayNext, .bool(true))
        await failing.fail(.playerHdrEnabled)
        let failedReport = await failingAdapter.apply(
            failingFile, selectedIDs: ["streaming.maxBitrate", "streaming.hdr", "player.autoPlayNext"])
        precondition(failedReport.applied == ["streaming.maxBitrate"] && failedReport.failed == ["streaming.hdr"])
        precondition(failingAdapter.needsRecovery)
        await failing.fail(nil)
        let recovered = await failingAdapter.undo()
        precondition(recovered.failed.isEmpty)
        let recoveredBitrate = await failing.current(.playbackMaxBitrateKbps)
        let untouchedNext = await failing.current(.playbackAutoPlayNext)
        precondition(recoveredBitrate == .null && untouchedNext == .bool(true) && !failingAdapter.undoAvailable)
        checks += 1

        // Selective restore across groups writes only the chosen setting.
        let selective = FakeTransport()
        await selective.change(.playerVideoGravity, .string("stretch"))
        await selective.change(.uiThemeMusicLoop, .bool(true))
        let selectiveAdapter = SettingsBackupRemoteAdapter(transport: selective, journal: RemoteMemoryJournal())
        let selectiveFile = try await document(selectiveAdapter)
        await selective.change(.playerVideoGravity, .string("fit"))
        await selective.change(.uiThemeMusicLoop, .bool(false))
        await selective.clearWrites()
        _ = await selectiveAdapter.apply(selectiveFile, selectedIDs: ["interface.themeMusicLoop"])
        let selectiveWrites = await selective.writtenKeys()
        let gravity = await selective.current(.playerVideoGravity)
        precondition(selectiveWrites == [.uiThemeMusicLoop] && gravity == .string("fit"))
        checks += 1

        // Undo leaves a value alone when it changed again after the restore.
        let changed = FakeTransport()
        await changed.change(.playbackIntroSkipMode, .string("always"))
        let changedAdapter = SettingsBackupRemoteAdapter(transport: changed, journal: RemoteMemoryJournal())
        let changedFile = try await document(changedAdapter)
        await changed.change(.playbackIntroSkipMode, .string("never"))
        _ = await changedAdapter.apply(changedFile, selectedIDs: ["player.introSkip"])
        await changed.change(.playbackIntroSkipMode, .string("ask"))
        let changedUndo = await changedAdapter.undo()
        let afterUndo = await changed.current(.playbackIntroSkipMode)
        precondition(changedUndo.skipped == ["player.introSkip"] && afterUndo == .string("ask"))
        checks += 1

        // Values outside the contract are refused in preview and never written.
        let strict = FakeTransport()
        let strictAdapter = SettingsBackupRemoteAdapter(transport: strict, journal: RemoteMemoryJournal())
        let strictBase = try await document(strictAdapter)
        var invalidGroups = strictBase.groups
        invalidGroups["player"]?["player.speedHundredths"] = .int(127)
        invalidGroups["player"]?["player.nextUpSeconds"] = .int(500)
        invalidGroups["player"]?["player.orientation"] = .string("sideways")
        invalidGroups["streaming"]?["streaming.hdr"] = .int(1)
        invalidGroups["streaming"]?["streaming.dolbyVision"] = .string("~null")
        let invalid = try SettingsBackupCodec.decode(SettingsBackupCodec.makeUnifiedDocument(
            groups: invalidGroups, scope: strictBase.scope, app: app, now: Date()))
        let invalidPreview = await strictAdapter.preview(invalid)
        for id in ["player.speedHundredths", "player.nextUpSeconds", "player.orientation", "streaming.hdr", "streaming.dolbyVision"] {
            precondition(item(invalidPreview, id)?.status == .invalid("This value is not supported."), id)
        }
        await strict.clearWrites()
        let invalidReport = await strictAdapter.apply(invalid, selectedIDs: ["player.speedHundredths", "streaming.hdr"])
        let invalidWrites = await strict.writeCount()
        precondition(invalidWrites == 0 && invalidReport.skipped.count == 2)
        checks += 1

        // Model level: a Build 96 schema-2 file (three synced settings only) still previews and
        // restores; an unknown future synced ID is counted as skipped; the document has no secrets.
        let model96Transport = FakeTransport()
        let model = SettingsBackupModel(
            registry: LocalStore().registry(), journal: LocalMemoryJournal(), app: app,
            remote: SettingsBackupRemoteAdapter(transport: model96Transport, journal: RemoteMemoryJournal()))
        let scope = SettingsBackupScope(serverFingerprint: String(repeating: "a", count: 64),
                                        profileFingerprint: String(repeating: "b", count: 64))
        let build96 = try SettingsBackupCodec.makeUnifiedDocument(
            groups: ["streaming": ["streaming.resolution": .string("480p"), "streaming.audioLanguage": .string("en")],
                     "subtitles": ["subtitles.language": .string("zh")]],
            scope: scope, app: app, now: Date())
        await model.loadUnifiedImport(data: build96)
        precondition(model.preview?.unrecognizedSettings == 0 && model.selectedChangeCount == 2)
        await model.applyUnifiedSelected()
        let build96Quality = await model96Transport.current(.playbackPreferredQuality)
        precondition(build96Quality == .string("480p"))
        let future = try SettingsBackupCodec.makeUnifiedDocument(
            groups: ["player": ["player.futureSetting": .bool(true), "player.autoPlayNext": .bool(false)]],
            scope: scope, app: app, now: Date())
        await model.loadUnifiedImport(data: future)
        precondition(model.preview?.unrecognizedSettings == 1 && model.selectedChangeCount == 1)
        model.exportSelection = Set(SettingsBackupRemoteAdapter.groups)
        guard let exported = await model.exportUnifiedDocument() else { fatalError("model export failed") }
        let text = String(decoding: exported, as: UTF8.self)
        for secret in ["example.invalid", "https", "\"local\"", "\"profile\""] {
            precondition(!text.contains(secret), "document leaked \(secret)")
        }
        let decoded = try SettingsBackupCodec.decode(exported)
        precondition(decoded.groups["player"]?.count == 12 && decoded.groups["interface"]?.count == 9)
        precondition(decoded.groups["streaming"]?.count == 7 && decoded.groups["subtitles"]?.count == 7)
        checks += 1

        checks += try await batchTwoChecks()

        // A schema-1 file may not carry the new synced groups.
        let unsafe = try SettingsBackupCodec.makeDocument(
            groups: ["player": ["player.autoPlayNext": .bool(true)]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        do {
            _ = try SettingsBackupCodec.decode(unsafe)
            fatalError("schema-1 file carried a synced player setting")
        } catch SettingsBackupError.unsafeContent {}
        checks += 1

        return checks
    }

    static func batchTwoChecks() async throws -> Int {
        var checks = 0
        let profileKeys: [SettingKey] = [
            .catalogShowAdvisoryAge, .catalogHideUnwatchedEpisodeImages, .catalogHideUnwatchedEpisodeOverviews,
            .playerVideoSkipBackSeconds, .playerVideoSkipForwardSeconds, .playerAudiobookSkipBackSeconds,
            .playerAudiobookSkipForwardSeconds, .playbackSubtitleMode, .playbackShowForcedSubtitles,
            .catalogMetadataLanguage]
        // Exactly ten profile-scope settings, every one written at profile scope.
        precondition(profileKeys.count == 10)
        precondition(RemoteBackupDefinition.allCases.filter { $0.scope == .profile }.count == 11)

        // Subtitle override isolation: a device/series row hides the profile value. Export leaves
        // it out with a reason, preview refuses it, and no write ever happens to the profile row.
        for hider in [SettingScope.profileDevice, .profileSeries, .profileLibrary] {
            let transport = FakeTransport()
            await transport.change(.playbackSubtitleMode, .string("always"))
            let adapter = SettingsBackupRemoteAdapter(transport: transport, journal: RemoteMemoryJournal())
            let file = try await document(adapter)
            precondition(file.groups["subtitles"]?["subtitles.mode"] == .string("always"))
            await transport.setOverride(.playbackSubtitleMode, hider, .string("off"))
            let exported = try await adapter.export()
            precondition(exported.groups["subtitles"]?["subtitles.mode"] == nil)
            precondition(exported.omitted.contains { $0.hasPrefix("Subtitle behavior") && $0.contains("override") })
            precondition(exported.groups["subtitles"]?["subtitles.showForced"] == inherit)
            let preview = await adapter.preview(file)
            precondition(item(preview, "subtitles.mode")?.status
                == .unsupported(SettingsBackupRemoteError.overridden.localizedDescription))
            await transport.clearWrites()
            let report = await adapter.apply(file, selectedIDs: ["subtitles.mode", "subtitles.showForced"])
            let writes = await transport.writeCount()
            precondition(writes == 0 && report.skipped == ["subtitles.mode"] && report.failed.isEmpty)
            let shown = await transport.current(.playbackSubtitleMode)
            precondition(shown == .string("always"))
            await transport.setOverride(.playbackSubtitleMode, nil)
        }
        checks += 1

        // Skip intervals: only the contract's list is valid, for all four keys.
        for definition in [RemoteBackupDefinition.videoSkipBack, .videoSkipForward, .audiobookSkipBack, .audiobookSkipForward] {
            for seconds in [5, 10, 15, 30, 45, 60, 90] { precondition(definition.validate(.int(seconds))) }
            for bad in [0, 1, 7, 20, 89, 91, 120, -10] { precondition(!definition.validate(.int(bad)), "\(bad)") }
            precondition(!definition.validate(.bool(true)) && !definition.validate(.string("10")))
            precondition(!definition.validate(.string("~null")))
            precondition(definition.validate(inherit))
            precondition(definition.scope == .profile && definition.requiresCapability)
        }
        let strict = FakeTransport()
        let strictAdapter = SettingsBackupRemoteAdapter(transport: strict, journal: RemoteMemoryJournal())
        let base = try await document(strictAdapter)
        var bad = base.groups
        bad["player"]?["player.videoSkipBackSeconds"] = .int(7)
        bad["player"]?["player.audiobookSkipForwardSeconds"] = .int(120)
        bad["subtitles"]?["subtitles.mode"] = .string("sometimes")
        bad["subtitles"]?["subtitles.showForced"] = .string("on")
        bad["interface"]?["interface.advisoryAge"] = .string("~null")
        bad["subtitles"]?["subtitles.metadataLanguage"] = .string("not a language!")
        let invalid = try SettingsBackupCodec.decode(SettingsBackupCodec.makeUnifiedDocument(
            groups: bad, scope: base.scope, app: app, now: Date()))
        let invalidPreview = await strictAdapter.preview(invalid)
        let badIDs = ["player.videoSkipBackSeconds", "player.audiobookSkipForwardSeconds", "subtitles.mode",
                      "subtitles.showForced", "interface.advisoryAge", "subtitles.metadataLanguage"]
        for id in badIDs { precondition(item(invalidPreview, id)?.status == .invalid("This value is not supported."), id) }
        await strict.clearWrites()
        _ = await strictAdapter.apply(invalid, selectedIDs: Set(badIDs))
        let strictWrites = await strict.writeCount()
        precondition(strictWrites == 0)
        checks += 1

        // Older servers: seek intervals (rev 9), advisory age (10) and spoilers (17) are omitted
        // from the export and reported on restore; subtitle mode, forced subtitles and metadata
        // language (rev 1) still work.
        let full = FakeTransport()
        for key in profileKeys { await full.change(key, profileSample(key)) }
        let fullFile = try await document(SettingsBackupRemoteAdapter(transport: full, journal: RemoteMemoryJournal()))
        let old = FakeTransport()
        let gated: Set<SettingKey> = [
            .catalogShowAdvisoryAge, .catalogHideUnwatchedEpisodeImages, .catalogHideUnwatchedEpisodeOverviews,
            .playerVideoSkipBackSeconds, .playerVideoSkipForwardSeconds, .playerAudiobookSkipBackSeconds,
            .playerAudiobookSkipForwardSeconds]
        await old.setUnserved(gated)
        let oldAdapter = SettingsBackupRemoteAdapter(transport: old, journal: RemoteMemoryJournal())
        let oldExport = try await oldAdapter.export()
        precondition(oldExport.groups["subtitles"]?.count == 7)
        for id in ["interface.advisoryAge", "interface.hideEpisodeImages", "interface.hideEpisodeDescriptions"] {
            precondition(oldExport.groups["interface"]?[id] == nil, id)
        }
        precondition(oldExport.groups["player"]?["player.videoSkipBackSeconds"] == nil)
        precondition(oldExport.omitted.count == 7)
        let oldPreview = await oldAdapter.preview(fullFile)
        for id in ["interface.advisoryAge", "interface.hideEpisodeImages", "interface.hideEpisodeDescriptions",
                   "player.videoSkipBackSeconds", "player.videoSkipForwardSeconds",
                   "player.audiobookSkipBackSeconds", "player.audiobookSkipForwardSeconds"] {
            precondition(item(oldPreview, id)?.status == .unsupported("This server doesn't support this setting."), id)
        }
        precondition(item(oldPreview, "subtitles.mode")?.status == .willChange)
        let oldReport = await oldAdapter.apply(fullFile, selectedIDs: ["interface.advisoryAge", "subtitles.mode"])
        let oldWritten = await old.writtenKeys()
        precondition(oldReport.skipped == ["interface.advisoryAge"] && oldWritten == [.playbackSubtitleMode])
        checks += 1

        // Partial API failure across profile settings: confirmed writes are journalled, the failure
        // is reported, nothing after it is attempted, and recovery restores the earlier values.
        let source = FakeTransport()
        for key in profileKeys { await source.change(key, profileSample(key)) }
        let journal = RemoteMemoryJournal()
        let adapter = SettingsBackupRemoteAdapter(transport: source, journal: journal)
        let file = try await document(adapter)
        for key in profileKeys { await source.change(key, profileOther(key)) }
        await source.fail(.playbackShowForcedSubtitles)
        let ids = ["interface.advisoryAge", "subtitles.mode", "subtitles.showForced", "subtitles.metadataLanguage"]
        let report = await adapter.apply(file, selectedIDs: Set(ids))
        precondition(report.failed == ["subtitles.showForced"], "\(report.failed)")
        precondition(!report.applied.contains("subtitles.showForced") && adapter.needsRecovery)
        let untouched = await source.current(.playerVideoSkipBackSeconds)
        precondition(untouched == profileOther(.playerVideoSkipBackSeconds))
        await source.fail(nil)
        let recovered = await adapter.undo()
        precondition(recovered.failed.isEmpty && !adapter.undoAvailable)
        for key in [SettingKey.catalogShowAdvisoryAge, .playbackSubtitleMode, .catalogMetadataLanguage] {
            let value = await source.current(key)
            precondition(value == profileOther(key), key.rawValue)
        }
        checks += 1

        // Selective restore: one chosen profile setting changes, its neighbours do not.
        await source.clearWrites()
        let selective = await adapter.apply(file, selectedIDs: ["player.videoSkipForwardSeconds"])
        let selectiveWrites = await source.writtenKeys()
        let selectiveScopes = await source.writtenScopes()
        precondition(selective.applied == ["player.videoSkipForwardSeconds"])
        precondition(selectiveWrites == [.playerVideoSkipForwardSeconds] && selectiveScopes == [.profile])
        let undoSelective = await adapter.undo()
        precondition(undoSelective.applied == ["player.videoSkipForwardSeconds"])
        checks += 1

        // Build 96 schema-2 and schema-1 files still decode and need no batch 2 settings.
        let legacy2 = try SettingsBackupCodec.makeUnifiedDocument(
            groups: ["subtitles": ["subtitles.language": .string("zh")]], scope: base.scope, app: app, now: Date())
        let decoded2 = try SettingsBackupCodec.decode(legacy2)
        let legacyPreview = await adapter.preview(decoded2)
        precondition(legacyPreview.flatMap(\.items).count == 1)
        let legacy1 = try SettingsBackupCodec.makeDocument(
            groups: ["navigation": ["navigation.fourthTab": .string("sports")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        let decoded1 = try SettingsBackupCodec.decode(legacy1)
        precondition(decoded1.schemaVersion == 1)
        let schema1Unsafe = try SettingsBackupCodec.makeDocument(
            groups: ["subtitles": ["subtitles.mode": .string("off")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        do { _ = try SettingsBackupCodec.decode(schema1Unsafe); fatalError("schema 1 carried synced mode") }
        catch SettingsBackupError.unsafeContent {}
        checks += 1
        return checks
    }

    /// A value the saved backup holds, and a different one the destination holds before restore.
    static func profileSample(_ key: SettingKey) -> SettingJSONValue {
        switch key {
        case .playerVideoSkipBackSeconds: .int(45)
        case .playerVideoSkipForwardSeconds: .int(5)
        case .playerAudiobookSkipBackSeconds: .int(90)
        case .playerAudiobookSkipForwardSeconds: .int(60)
        case .playbackSubtitleMode: .string("always")
        case .catalogMetadataLanguage: .string("ja")
        case .catalogShowAdvisoryAge, .catalogHideUnwatchedEpisodeImages, .catalogHideUnwatchedEpisodeOverviews: .bool(true)
        default: .bool(false)
        }
    }
    static func profileOther(_ key: SettingKey) -> SettingJSONValue {
        switch key {
        case .playerVideoSkipBackSeconds, .playerAudiobookSkipBackSeconds: .int(10)
        case .playerVideoSkipForwardSeconds, .playerAudiobookSkipForwardSeconds: .int(30)
        case .playbackSubtitleMode: .string("off")
        case .catalogMetadataLanguage: .string("en")
        case .catalogShowAdvisoryAge, .catalogHideUnwatchedEpisodeImages, .catalogHideUnwatchedEpisodeOverviews: .bool(false)
        default: .bool(true)
        }
    }
}

/// Batch 3: the subtitle appearance record, the "this device only" switch and the sync offset.
@MainActor
private enum RemoteBatchThreeChecks {
    static let A = SettingKey.playbackSubtitleAppearance
    static let Y = SettingKey.playerSubtitleSyncMs
    static let DO = SubtitleDisplayBackup.deviceOnlyID
    static let AP = SubtitleDisplayBackup.appearanceID
    static let SY = SubtitleDisplayBackup.syncID
    static let all: Set<String> = [DO, AP, SY]
    static let app = SettingsBackupAppInfo(version: "1", build: "98", platform: "iOS", idiom: "phone")

    static func make(_ transport: FakeTransport) -> SettingsBackupRemoteAdapter {
        SettingsBackupRemoteAdapter(transport: transport, journal: RemoteMemoryJournal(), timeout: .seconds(1))
    }
    static func file(_ adapter: SettingsBackupRemoteAdapter) async throws -> IncomingBackup {
        try await RemoteBatchOneChecks.document(adapter)
    }
    static func item(_ groups: [RestorePreviewGroup], _ id: String) -> RestorePreviewItem {
        guard let found = RemoteBatchOneChecks.item(groups, id) else { fatalError("no preview item \(id)") }
        return found
    }

    static func run() async throws -> Int {
        var checks = 0

        // The three IDs are allowed by the document's safety filter and owned by the adapter.
        precondition(all.count == 3 && all.isSubset(of: SettingsBackupRemoteAdapter.settingIDs))
        precondition(all.allSatisfy { !SettingsBackupSafety.isSensitiveName($0) })
        checks += 1

        // 1. Complete record round trip at profile scope; the file is schema 3 and every field survives.
        do {
            let source = FakeTransport()
            await source.setRow(A, .profile, SubtitleFixtures.custom)
            let sourceAdapter = make(source)
            let incoming = try await file(sourceAdapter)
            precondition(incoming.schemaVersion == 3)
            guard case .record(let members)? = incoming.groups["subtitles"]?[AP] else { fatalError("no record") }
            precondition(members.count == 10 && members["fontColor"] == .string("#facc15")
                         && members["textOpacity"] == .int(80) && members["position"] == .string("top")
                         && members["textOutline"] == .bool(true) && members["backgroundOpacity"] == .int(40))
            precondition(incoming.groups["subtitles"]?[DO] == .bool(false))
            precondition(incoming.groups["subtitles"]?[SY] == RemoteBatchOneChecks.inherit)

            let dest = FakeTransport()
            await dest.setRow(A, .profile, SubtitleFixtures.other)
            let adapter = make(dest)
            let preview = await adapter.preview(incoming)
            precondition(item(preview, AP).status == .willChange && item(preview, DO).status == .unchanged
                         && item(preview, SY).status == .unchanged)
            await dest.clearWrites()
            let report = await adapter.apply(incoming, selectedIDs: all)
            precondition(report.applied == [AP] && report.failed.isEmpty, "\(report)")
            let restored = await dest.row(A, .profile)
            let writtenScopes = await dest.writtenScopes()
            precondition(restored == SubtitleFixtures.custom && writtenScopes == [.profile])
            let deviceRow = await dest.row(A, .profileDevice)
            precondition(deviceRow == nil)
            let undo = await adapter.undo()
            let undone = await dest.row(A, .profile)
            precondition(undo.applied == [AP] && undone == SubtitleFixtures.other && !adapter.undoAvailable)
        }
        checks += 1

        // 2. Device-only appearance: the device row is written and the profile row is never touched.
        do {
            let source = FakeTransport()
            await source.setRow(A, .profileDevice, SubtitleFixtures.custom)
            await source.setRow(A, .profile, SubtitleFixtures.other)   // hidden by the device row
            let incoming = try await file(make(source))
            precondition(incoming.groups["subtitles"]?[DO] == .bool(true))
            guard case .record? = incoming.groups["subtitles"]?[AP] else { fatalError("device record") }
            let dest = FakeTransport()
            let profileRow = SubtitleFixtures.json(["fontSize": .string("medium")])
            await dest.setRow(A, .profile, profileRow)
            let adapter = make(dest)
            let preview = await adapter.preview(incoming)
            precondition(item(preview, DO).status == .willChange && item(preview, AP).status == .willChange)
            precondition(item(preview, DO).current == "Off" && item(preview, DO).incoming == "On")
            await dest.clearWrites()
            let report = await adapter.apply(incoming, selectedIDs: all)
            precondition(report.applied == [DO, AP] && report.failed.isEmpty, "\(report)")
            let device = await dest.row(A, .profileDevice)
            let profile = await dest.row(A, .profile)
            let scopes = await dest.writtenScopes()
            precondition(device == SubtitleFixtures.custom && profile == profileRow && scopes == [.profileDevice])
            let undo = await adapter.undo()
            let afterDevice = await dest.row(A, .profileDevice)
            let afterProfile = await dest.row(A, .profile)
            precondition(undo.failed.isEmpty && afterDevice == nil && afterProfile == profileRow)
        }
        checks += 1

        // 3. Switching device → profile: the device row goes, the profile row takes the saved
        // appearance, and Undo restores both rows, including the profile row the device row hid.
        do {
            let source = FakeTransport()
            await source.setRow(A, .profile, SubtitleFixtures.custom)
            let incoming = try await file(make(source))
            let dest = FakeTransport()
            let hiddenProfile = SubtitleFixtures.json(["fontSize": .string("medium")])
            await dest.setRow(A, .profileDevice, SubtitleFixtures.other)
            await dest.setRow(A, .profile, hiddenProfile)
            let adapter = make(dest)
            let preview = await adapter.preview(incoming)
            precondition(item(preview, DO).current == "On" && item(preview, DO).incoming == "Off")
            await dest.clearWrites()
            let report = await adapter.apply(incoming, selectedIDs: all)
            precondition(report.applied == [DO, AP] && report.failed.isEmpty, "\(report)")
            let device = await dest.row(A, .profileDevice)
            let profile = await dest.row(A, .profile)
            let order = await dest.writtenScopes()
            precondition(device == nil && profile == SubtitleFixtures.custom && order == [.profileDevice, .profile])
            let undo = await adapter.undo()
            let restoredDevice = await dest.row(A, .profileDevice)
            let restoredProfile = await dest.row(A, .profile)
            precondition(undo.failed.isEmpty && restoredDevice == SubtitleFixtures.other && restoredProfile == hiddenProfile)
        }
        checks += 1

        // 4. Switching profile → device with only the switch selected: the device starts from what is
        // on screen, so nothing visible changes, and the profile row stays.
        do {
            let source = FakeTransport()
            await source.setRow(A, .profileDevice, SubtitleFixtures.custom)
            let incoming = try await file(make(source))
            let dest = FakeTransport()
            await dest.setRow(A, .profile, SubtitleFixtures.other)
            let adapter = make(dest)
            let report = await adapter.apply(incoming, selectedIDs: [DO])
            let device = await dest.row(A, .profileDevice)
            let profile = await dest.row(A, .profile)
            precondition(report.applied == [DO] && device == SubtitleFixtures.other && profile == SubtitleFixtures.other)
            let undo = await adapter.undo()
            let afterDevice = await dest.row(A, .profileDevice)
            precondition(undo.failed.isEmpty && afterDevice == nil)
        }
        checks += 1

        // 5. Explicit default, inherited and custom stay three different states.
        do {
            let explicit = FakeTransport()
            await explicit.setRow(A, .profile, SubtitleFixtures.json([:]))
            let explicitFile = try await file(make(explicit))
            guard case .record(let defaultMembers)? = explicitFile.groups["subtitles"]?[AP] else {
                fatalError("explicit default must be a record, not inherited")
            }
            precondition(defaultMembers == SubtitleDisplayBackup.defaults)
            let inheritedFile = try await file(make(FakeTransport()))
            precondition(inheritedFile.groups["subtitles"]?[AP] == RemoteBatchOneChecks.inherit)

            let dest = FakeTransport()
            let toExplicit = make(dest)
            let preview = await toExplicit.preview(explicitFile)
            precondition(item(preview, AP).status == .willChange && item(preview, AP).current == "Use inherited setting")
            _ = await toExplicit.apply(explicitFile, selectedIDs: [AP])
            let created = await dest.row(A, .profile)
            precondition(created == SubtitleFixtures.json([:]))
            _ = await toExplicit.undo()
            let removed = await dest.row(A, .profile)
            precondition(removed == nil)

            let custom = FakeTransport()
            await custom.setRow(A, .profile, SubtitleFixtures.custom)
            let toInherited = make(custom)
            _ = await toInherited.apply(inheritedFile, selectedIDs: [AP])
            let cleared = await custom.row(A, .profile)
            precondition(cleared == nil)
            _ = await toInherited.undo()
            let back = await custom.row(A, .profile)
            precondition(back == SubtitleFixtures.custom)
        }
        checks += 1

        // 6. Sync offsets: negative, zero (explicit, distinct from inherited), positive and the limits.
        for offset in [-750, 0, 1500, -10_000, 10_000] {
            let source = FakeTransport()
            await source.setRow(Y, .profile, .int(offset))
            let incoming = try await file(make(source))
            precondition(incoming.groups["subtitles"]?[SY] == .int(offset), "\(offset)")
            let dest = FakeTransport()
            if offset != 0 { await dest.setRow(Y, .profile, .int(250)) }
            let adapter = make(dest)
            let preview = await adapter.preview(incoming)
            precondition(item(preview, SY).status == .willChange)
            await dest.clearWrites()
            let report = await adapter.apply(incoming, selectedIDs: [SY])
            let row = await dest.row(Y, .profile)
            let scopes = await dest.writtenScopes()
            precondition(report.applied == [SY] && row == .int(offset) && scopes == [.profile], "\(offset)")
            let undo = await adapter.undo()
            let after = await dest.row(Y, .profile)
            precondition(undo.applied == [SY] && after == (offset == 0 ? nil : .int(250)), "\(offset)")
        }
        // Device scope while the device keeps its own appearance.
        do {
            let source = FakeTransport()
            await source.setRow(A, .profileDevice, SubtitleFixtures.custom)
            await source.setRow(Y, .profileDevice, .int(300))
            let incoming = try await file(make(source))
            let dest = FakeTransport()
            let adapter = make(dest)
            await dest.clearWrites()
            let report = await adapter.apply(incoming, selectedIDs: all)
            let scopes = await dest.writtenScopes()
            let deviceSync = await dest.row(Y, .profileDevice)
            let profileSync = await dest.row(Y, .profile)
            precondition(report.failed.isEmpty && deviceSync == .int(300) && profileSync == nil)
            precondition(scopes.allSatisfy { $0 == .profileDevice })
        }
        // A leftover device offset is removed so the profile's applies; the hidden profile offset is
        // recorded so Undo restores both.
        do {
            let source = FakeTransport()
            await source.setRow(Y, .profile, .int(-750))
            let incoming = try await file(make(source))
            let dest = FakeTransport()
            await dest.setRow(Y, .profileDevice, .int(111))
            await dest.setRow(Y, .profile, .int(40))
            let adapter = make(dest)
            let report = await adapter.apply(incoming, selectedIDs: [SY])
            let device = await dest.row(Y, .profileDevice)
            let profile = await dest.row(Y, .profile)
            precondition(report.applied == [SY] && device == nil && profile == .int(-750), "\(report)")
            _ = await adapter.undo()
            let restoredDevice = await dest.row(Y, .profileDevice)
            let restoredProfile = await dest.row(Y, .profile)
            precondition(restoredDevice == .int(111) && restoredProfile == .int(40))
        }
        // A server older than revision 19 stores the offset per device only.
        do {
            let source = FakeTransport()
            await source.setRow(Y, .profile, .int(-750))
            let incoming = try await file(make(source))
            let old = FakeTransport()
            await old.setRevision(18)
            let adapter = make(old)
            await old.clearWrites()
            let report = await adapter.apply(incoming, selectedIDs: [SY])
            let scopes = await old.writtenScopes()
            let device = await old.row(Y, .profileDevice)
            precondition(report.applied == [SY] && scopes == [.profileDevice] && device == .int(-750))
        }
        // Out-of-range offsets are invalid and never written.
        do {
            let base = try await file(make(FakeTransport()))
            var groups = base.groups
            groups["subtitles"]?[SY] = .int(10_001)
            let invalid = try SettingsBackupCodec.decode(SettingsBackupCodec.makeUnifiedDocument(
                groups: groups, scope: base.scope, app: app, now: Date()))
            let dest = FakeTransport()
            let adapter = make(dest)
            let preview = await adapter.preview(invalid)
            precondition(item(preview, SY).status == .invalid("This value is not supported."))
            await dest.clearWrites()
            let report = await adapter.apply(invalid, selectedIDs: [SY])
            let writes = await dest.writeCount()
            precondition(writes == 0 && report.skipped == [SY])
        }
        checks += 1

        // 7. Older server: text opacity needs revision 14. A saved non-default opacity is refused;
        // a default one is stored without the member.
        do {
            let source = FakeTransport()
            await source.setRow(A, .profile, SubtitleFixtures.custom)
            let custom = try await file(make(source))
            let old = FakeTransport()
            await old.setRevision(10)
            let adapter = make(old)
            let preview = await adapter.preview(custom)
            precondition(item(preview, AP).status == .unsupported("This server is too old to store the saved text opacity."))
            await old.clearWrites()
            let skipped = await adapter.apply(custom, selectedIDs: [AP])
            let none = await old.writeCount()
            precondition(none == 0 && skipped.skipped == [AP])

            let plain = FakeTransport()
            await plain.setRow(A, .profile, SubtitleFixtures.other)
            let plainFile = try await file(make(plain))
            let report = await adapter.apply(plainFile, selectedIDs: [AP])
            let stored = await old.row(A, .profile)
            guard case .object(let fields)? = stored else { fatalError("no stored appearance") }
            precondition(report.applied == [AP] && fields["textOpacity"] == nil && fields["position"] == .string("lower-third"))
        }
        checks += 1

        // 8. Partial API failure: the switch is confirmed, the appearance write fails, the sync offset
        // is skipped, and recovery puts the device row and the profile row back.
        do {
            let source = FakeTransport()
            await source.setRow(A, .profile, SubtitleFixtures.custom)
            await source.setRow(Y, .profile, .int(-750))
            let incoming = try await file(make(source))
            let dest = FakeTransport()
            let hidden = SubtitleFixtures.json(["fontSize": .string("medium")])
            await dest.setRow(A, .profileDevice, SubtitleFixtures.other)
            await dest.setRow(A, .profile, hidden)
            await dest.failWriting(A, .profile)
            let adapter = make(dest)
            let report = await adapter.apply(incoming, selectedIDs: all)
            precondition(report.applied == [DO] && report.failed == [AP] && report.skipped == [SY], "\(report)")
            precondition(adapter.needsRecovery)
            let device = await dest.row(A, .profileDevice)
            precondition(device == nil)   // the confirmed switch is reported as applied
            await dest.failWriting(nil)
            let undo = await adapter.undo()
            let restoredDevice = await dest.row(A, .profileDevice)
            let restoredProfile = await dest.row(A, .profile)
            let syncTouched = await dest.row(Y, .profile)
            precondition(undo.failed.isEmpty && restoredDevice == SubtitleFixtures.other
                         && restoredProfile == hidden && syncTouched == nil)
            precondition(!adapter.needsRecovery && !adapter.undoAvailable)
        }
        checks += 1

        // 9. Selective restore. Appearance alone; offset alone; a profile-inherited appearance cannot
        // be restored onto a device-only destination unless the switch is restored too.
        do {
            let source = FakeTransport()
            await source.setRow(A, .profile, SubtitleFixtures.custom)
            await source.setRow(Y, .profile, .int(-750))
            let incoming = try await file(make(source))
            let dest = FakeTransport()
            let adapter = make(dest)
            await dest.clearWrites()
            _ = await adapter.apply(incoming, selectedIDs: [SY])
            let onlySync = await dest.writtenKeys()
            precondition(onlySync == [Y])
            _ = await adapter.undo()
            await dest.clearWrites()
            _ = await adapter.apply(incoming, selectedIDs: [AP])
            let onlyAppearance = await dest.writtenKeys()
            precondition(onlyAppearance == [A])
            _ = await adapter.undo()

            let inherited = try await file(make(FakeTransport()))
            let deviceOnly = FakeTransport()
            await deviceOnly.setRow(A, .profileDevice, SubtitleFixtures.other)
            let blocked = make(deviceOnly)
            await deviceOnly.clearWrites()
            let report = await blocked.apply(inherited, selectedIDs: [AP])
            let writes = await deviceOnly.writeCount()
            precondition(report.skipped == [AP] && writes == 0)
            let withSwitch = await blocked.apply(inherited, selectedIDs: [DO, AP])
            let device = await deviceOnly.row(A, .profileDevice)
            precondition(withSwitch.failed.isEmpty && device == nil)
        }
        checks += 1

        // 10. Undo leaves a row alone that changed after the restore.
        do {
            let source = FakeTransport()
            await source.setRow(A, .profile, SubtitleFixtures.custom)
            let incoming = try await file(make(source))
            let dest = FakeTransport()
            let adapter = make(dest)
            _ = await adapter.apply(incoming, selectedIDs: [AP])
            await dest.setRow(A, .profile, SubtitleFixtures.other)
            let undo = await adapter.undo()
            let row = await dest.row(A, .profile)
            precondition(undo.skipped == [AP] && row == SubtitleFixtures.other)
        }
        checks += 1

        // 11. Identity mismatch: all three items are refused and nothing is written.
        do {
            let source = FakeTransport()
            await source.setRow(A, .profile, SubtitleFixtures.custom)
            await source.setRow(Y, .profile, .int(-750))
            let adapter = make(source)
            let incoming = try await file(adapter)
            await source.moveProfile()
            let preview = await adapter.preview(incoming)
            for id in all {
                precondition(item(preview, id).status
                    == .unsupported(SettingsBackupRemoteError.destinationMismatch.localizedDescription), id)
            }
            await source.clearWrites()
            let report = await adapter.apply(incoming, selectedIDs: all)
            let writes = await source.writeCount()
            precondition(writes == 0 && report.applied.isEmpty)
        }
        checks += 1

        // 12. Rows that cannot be transferred safely are reported, never guessed or overwritten.
        do {
            let unknown = FakeTransport()
            await unknown.setRow(A, .profile, .object(["fontSize": .string("large"), "fontWeight": .string("bold")]))
            let export = try await make(unknown).export()
            precondition(export.groups["subtitles"]?[AP] == nil && export.groups["subtitles"]?[DO] == nil)
            precondition(export.groups["subtitles"]?[SY] != nil)
            precondition(export.omitted.contains { $0.hasPrefix("Subtitle appearance") && $0.contains("can't be transferred") })

            let source = FakeTransport()
            await source.setRow(A, .profile, SubtitleFixtures.custom)
            let incoming = try await file(make(source))
            let adapter = make(unknown)
            let preview = await adapter.preview(incoming)
            precondition({ if case .unsupported = item(preview, AP).status { return true }; return false }())
            await unknown.clearWrites()
            _ = await adapter.apply(incoming, selectedIDs: [AP])
            let guarded = await unknown.writeCount()
            precondition(guarded == 0)

            let library = FakeTransport()
            await library.setOverride(A, .profileLibrary, SubtitleFixtures.other)
            let libraryAdapter = make(library)
            let overridden = try await libraryAdapter.export()
            precondition(overridden.omitted.contains { $0.contains("override") })
            let skippedReport = await libraryAdapter.apply(incoming, selectedIDs: all)
            let libraryWrites = await library.writeCount()
            precondition(libraryWrites == 0 && skippedReport.failed.isEmpty && !skippedReport.skipped.isEmpty)
        }
        checks += 1

        // 13. Through the model: one file, schema 3 only when it holds the record, and a full restore
        // and Undo of local, scalar and subtitle-display settings together.
        do {
            let transport = FakeTransport()
            let local = LocalStore()
            let model = SettingsBackupModel(
                registry: local.registry(), journal: LocalMemoryJournal(), app: app,
                remote: SettingsBackupRemoteAdapter(transport: transport, journal: RemoteMemoryJournal()))
            await transport.setRow(A, .profile, SubtitleFixtures.custom)
            await transport.setRow(Y, .profile, .int(-750))
            model.exportSelection = [.navigation, .streaming]
            guard let plain = await model.exportUnifiedDocument() else { fatalError("export") }
            let plainDoc = try SettingsBackupCodec.decode(plain)
            precondition(plainDoc.schemaVersion == 3 && plainDoc.groups["subtitles"] == nil)

            model.exportSelection = [.navigation, .streaming, .subtitles]
            guard let data = await model.exportUnifiedDocument() else { fatalError("export") }
            let doc = try SettingsBackupCodec.decode(data)
            precondition(doc.schemaVersion == 3)
            let text = String(decoding: data, as: UTF8.self)
            precondition(text.contains("\"minReaderVersion\" : 3"))
            for secret in ["example.invalid", "https", "\"local\""] { precondition(!text.contains(secret)) }

            local.fourthTab = "forYou"
            await transport.setRow(A, .profile, SubtitleFixtures.other)
            await transport.setRow(Y, .profile, .int(250))
            await model.loadUnifiedImport(data: data)
            precondition(model.preview?.skippedCount == 0)
            precondition(model.selectedChangeCount == 3)   // fourth tab, appearance and offset
            model.setImport(AP, enabled: false)
            await model.applyUnifiedSelected()
            let appearanceKept = await transport.row(A, .profile)
            let syncRestored = await transport.row(Y, .profile)
            precondition(local.fourthTab == "sports" && appearanceKept == SubtitleFixtures.other && syncRestored == .int(-750))
            await model.undoUnified()
            let syncBack = await transport.row(Y, .profile)
            precondition(local.fourthTab == "forYou" && syncBack == .int(250))
        }
        checks += 1

        // 14. Compatibility: a record is refused in a schema-1 or schema-2 file, and a Build 96/97
        // schema-2 file previews without touching the display unit.
        do {
            let scope = SettingsBackupScope(serverFingerprint: String(repeating: "a", count: 64),
                                            profileFingerprint: String(repeating: "b", count: 64))
            let members: [String: BackupValue] = ["fontSize": .string("large")]
            for version in [1, 2] {
                let bad = try SettingsBackupCodec.makeDocument(
                    groups: ["subtitles": ["subtitles.appearance": .record(members)]],
                    schemaVersion: version, minReaderVersion: 1, app: app, now: Date())
                do { _ = try SettingsBackupCodec.decode(bad); fatalError("schema \(version) carried a record") }
                catch SettingsBackupError.unsafeContent {}
            }
            let old = try SettingsBackupCodec.makeUnifiedDocument(
                groups: ["subtitles": ["subtitles.language": .string("zh"), "subtitles.mode": .string("off")]],
                scope: scope, app: app, now: Date())
            let decoded = try SettingsBackupCodec.decode(old)
            precondition(decoded.schemaVersion == 2)
            let adapter = make(FakeTransport())
            let preview = await adapter.preview(decoded)
            precondition(preview.flatMap(\.items).count == 2)
            precondition(preview.flatMap(\.items).allSatisfy { !all.contains($0.id) })
        }
        checks += 1
        return checks
    }
}

@MainActor
private enum RemoteBatchFourChecks {
    static let app = SettingsBackupAppInfo(version: "1", build: "96", platform: "iOS", idiom: "phone")
    static let cell = ScopedCompositeBackup.cellularID
    static let art = ScopedCompositeBackup.titleArtID
    static let scope = SettingsBackupScope(serverFingerprint: String(repeating: "a", count: 64),
                                           profileFingerprint: String(repeating: "b", count: 64))

    static func adapter(_ transport: FakeTransport, _ journal: RemoteMemoryJournal = RemoteMemoryJournal()) -> SettingsBackupRemoteAdapter {
        SettingsBackupRemoteAdapter(transport: transport, journal: journal, timeout: .seconds(1))
    }
    static func incoming(_ group: String, _ id: String, _ value: BackupValue) throws -> IncomingBackup {
        try SettingsBackupCodec.decode(SettingsBackupCodec.makeUnifiedDocument(
            groups: [group: [id: value]], scope: scope, app: app, now: Date()))
    }
    static func cellular(_ resolution: String, _ cap: BackupValue, _ at: String = "profile_device") -> BackupValue {
        .record(["scope": .string(at), "resolution": .string(resolution), "bitrateKbps": cap])
    }
    static func title(_ value: Bool, _ at: String) -> BackupValue {
        .record(["scope": .string(at), "enabled": .bool(value)])
    }

    static func run() async throws -> Int {
        var checks = 0
        // All UI presets are round-tripped as the two authoritative rows; nil cap is explicit unlimited.
        for (resolution, cap) in [("auto", SettingJSONValue.null), ("2160p", .null), ("1080p", .int(10000)),
                                  ("1080p", .int(6000)), ("1080p", .int(3000)), ("720p", .int(4000)),
                                  ("720p", .int(2000)), ("480p", .int(1500))] {
            let source = FakeTransport()
            await source.setRow(.playbackCellularPreferredQuality, .profileDevice, .string(resolution))
            await source.setRow(.playbackCellularMaxBitrateKbps, .profileDevice, cap)
            let exported = try await adapter(source).export()
            let expectedCap: BackupValue = cap == .null ? .string(RemoteBackupDefinition.null) : {
                if case .int(let value) = cap { return .int(value) }; return .int(-1)
            }()
            let saved = exported.groups["streaming"]?[cell]
            precondition(saved == cellular(resolution, expectedCap))
            let target = FakeTransport()
            let data = try incoming("streaming", cell, saved!)
            let restored = await adapter(target).apply(data, selectedIDs: [cell])
            let restoredQuality = await target.row(.playbackCellularPreferredQuality, .profileDevice)
            let restoredCap = await target.row(.playbackCellularMaxBitrateKbps, .profileDevice)
            precondition(restored.applied == [cell] && restoredQuality == .string(resolution) && restoredCap == cap)
        }
        checks += 1

        // Writes and verifies both cellular keys, and Undo restores their old values.
        do {
            let data = try incoming("streaming", cell, cellular("480p", .int(1500)))
            let target = FakeTransport()
            await target.setRow(.playbackCellularPreferredQuality, .profileDevice, .string("720p"))
            await target.setRow(.playbackCellularMaxBitrateKbps, .profileDevice, .int(2000))
            let journal = RemoteMemoryJournal(); let remote = adapter(target, journal)
            let preview = await remote.preview(data)
            precondition(RemoteBatchThreeChecks.item(preview, cell).status == .willChange)
            let report = await remote.apply(data, selectedIDs: [cell])
            let quality = await target.row(.playbackCellularPreferredQuality, .profileDevice)
            let cap = await target.row(.playbackCellularMaxBitrateKbps, .profileDevice)
            precondition(report.applied == [cell] && quality == .string("480p") && cap == .int(1500))
            let undone = await remote.undo()
            let oldQuality = await target.row(.playbackCellularPreferredQuality, .profileDevice)
            let oldCap = await target.row(.playbackCellularMaxBitrateKbps, .profileDevice)
            precondition(undone.failed.isEmpty && oldQuality == .string("720p") && oldCap == .int(2000))
        }
        checks += 1

        // Default/inherited differs from explicit null (unlimited); unsafe deletion of hidden rows is refused.
        do {
            let defaultData = try incoming("streaming", cell, cellular("720p", .int(2000), "default"))
            let defaultAdapter = adapter(FakeTransport())
            let unchanged = await defaultAdapter.preview(defaultData)
            precondition(RemoteBatchThreeChecks.item(unchanged, cell).status == .unchanged)
            let explicitNull = try incoming("streaming", cell, cellular("720p", .string(RemoteBackupDefinition.null), "profile_device"))
            let target = FakeTransport(); let result = await adapter(target).apply(explicitNull, selectedIDs: [cell])
            let savedNull = await target.row(.playbackCellularMaxBitrateKbps, .profileDevice)
            precondition(result.applied == [cell] && savedNull == .null)
            let profile = FakeTransport()
            await profile.setRow(.playbackCellularPreferredQuality, .profile, .string("1080p"))
            await profile.setRow(.playbackCellularMaxBitrateKbps, .profile, .int(6000))
            let profileSaved = try await adapter(profile).export().groups["streaming"]![cell]!
            precondition(profileSaved == cellular("1080p", .int(6000), "profile"))
            let profileRestore = try incoming("streaming", cell, profileSaved)
            let profileDestination = FakeTransport()
            let profileReport = await adapter(profileDestination).apply(profileRestore, selectedIDs: [cell])
            let profileQuality = await profileDestination.row(.playbackCellularPreferredQuality, .profile)
            let profileCap = await profileDestination.row(.playbackCellularMaxBitrateKbps, .profile)
            precondition(profileReport.applied == [cell] && profileQuality == .string("1080p") && profileCap == .int(6000))
            let unsafe = await adapter(profile).preview(defaultData)
            if case .unsupported(_) = RemoteBatchThreeChecks.item(unsafe, cell).status {} else { fatalError("unsafe default clear was offered") }
        }
        checks += 1

        // Profile title-art write preserves the existing device value; the inverse hidden-row transition is refused.
        do {
            let inheritedArt = try await adapter(FakeTransport()).export().groups["interface"]![art]!
            precondition(inheritedArt == title(true, "default"))
            let explicitDefault = FakeTransport(); await explicitDefault.setRow(.uiTitleArt, .profile, .bool(true))
            let profileDefault = try await adapter(explicitDefault).export().groups["interface"]![art]!
            precondition(profileDefault == title(true, "profile"))
            let data = try incoming("interface", art, title(false, "profile"))
            let target = FakeTransport(); await target.setRow(.uiTitleArt, .profileDevice, .bool(true))
            let journal = RemoteMemoryJournal(); let remote = adapter(target, journal)
            let report = await remote.apply(data, selectedIDs: [art])
            let profileValue = await target.row(.uiTitleArt, .profile)
            let deviceValue = await target.row(.uiTitleArt, .profileDevice)
            precondition(report.applied == [art] && profileValue == .bool(false) && deviceValue == .bool(true),
                         "title art report=\(report.applied)/\(report.failed)/\(report.skipped), rows=\(String(describing: profileValue))/\(String(describing: deviceValue))")
            let undo = await remote.undo()
            let restoredProfile = await target.row(.uiTitleArt, .profile)
            precondition(undo.failed.isEmpty && restoredProfile == nil)
            let profileTarget = FakeTransport(); await profileTarget.setRow(.uiTitleArt, .profile, .bool(true))
            let deviceData = try incoming("interface", art, title(false, "profile_device"))
            let unsafe = await adapter(profileTarget).preview(deviceData)
            if case .unsupported(_) = RemoteBatchThreeChecks.item(unsafe, art).status {} else { fatalError("hidden device art was overwritten") }
        }
        checks += 1

        // Partial second-row failure is journalled; recovery reverses first row. Identity mismatch writes zero rows.
        do {
            let data = try incoming("streaming", cell, cellular("480p", .int(1500)))
            let partial = FakeTransport()
            await partial.setRow(.playbackCellularPreferredQuality, .profileDevice, .string("720p"))
            await partial.setRow(.playbackCellularMaxBitrateKbps, .profileDevice, .int(2000))
            await partial.failWriting(.playbackCellularMaxBitrateKbps, .profileDevice)
            let journal = RemoteMemoryJournal(); let remote = adapter(partial, journal)
            let failure = await remote.apply(data, selectedIDs: [cell])
            precondition(failure.failed == [cell] && remote.needsRecovery)
            await partial.failWriting(nil)
            let recovery = await remote.undo()
            let restored = await partial.row(.playbackCellularPreferredQuality, .profileDevice)
            precondition(recovery.failed.isEmpty && restored == .string("720p"))
            let mismatch = FakeTransport(); await mismatch.moveProfile()
            let mismatched = adapter(mismatch); let before = await mismatch.writeCount()
            let mismatchReport = await mismatched.apply(data, selectedIDs: [cell])
            let after = await mismatch.writeCount()
            precondition(!mismatchReport.failed.isEmpty && before == after)
        }
        checks += 1

        // Older server capability and schema 1/2 readers remain unchanged.
        do {
            let data = try incoming("streaming", cell, cellular("480p", .int(1500), "profile_device"))
            let old = FakeTransport(); await old.setRevision(19)
            let preview = await adapter(old).preview(data)
            if case .unsupported(_) = RemoteBatchThreeChecks.item(preview, cell).status {} else { fatalError("old server advertised cellular setting") }
            let legacy = try SettingsBackupCodec.makeUnifiedDocument(
                groups: ["streaming": ["streaming.resolution": .string("720p")]], scope: scope, app: app, now: Date())
            let legacyDecoded = try SettingsBackupCodec.decode(legacy)
            precondition(legacyDecoded.schemaVersion == 2)
            let schema1 = try SettingsBackupCodec.makeDocument(
                groups: ["navigation": ["navigation.fourthTab": .string("sports")]],
                schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
            let schema1Decoded = try SettingsBackupCodec.decode(schema1)
            precondition(schema1Decoded.schemaVersion == 1)
        }
        checks += 1
        return checks
    }
}

@MainActor
private enum RemoteBatchFiveChecks {
    static func check(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
        precondition(condition, "Batch 5 check failed", file: file, line: line)
    }
    static let card = InterfaceRecordBackup.cardID
    static let menu = InterfaceRecordBackup.menuID
    static let shortcuts = InterfaceRecordBackup.shortcutsID
    static let app = SettingsBackupAppInfo(version: "1", build: "98", platform: "iOS", idiom: "phone")
    static let home: SettingJSONValue = .object(["type": .string("builtin"), "destination": .string("home")])
    static let movies: SettingJSONValue = .object(["type": .string("builtin"), "destination": .string("movies")])
    static let library: SettingJSONValue = .object(["type": .string("library"), "library_id": .int(1),
                                                     "label": .string("Movies")])
    static let scope = SettingsBackupScope(serverFingerprint: String(repeating: "a", count: 64),
                                           profileFingerprint: String(repeating: "b", count: 64))

    static func adapter(_ transport: FakeTransport, _ journal: RemoteMemoryJournal = .init()) -> SettingsBackupRemoteAdapter {
        SettingsBackupRemoteAdapter(transport: transport, journal: journal, timeout: .seconds(1))
    }
    static func file(_ adapter: SettingsBackupRemoteAdapter) async throws -> IncomingBackup {
        let result = try await adapter.export()
        return try SettingsBackupCodec.decode(SettingsBackupCodec.makeUnifiedDocument(
            groups: result.groups, scope: result.scope, app: app, now: Date()))
    }
    static func status(_ preview: [RestorePreviewGroup], _ id: String) -> RestoreItemStatus {
        guard let item = preview.flatMap(\.items).first(where: { $0.id == id }) else { fatalError("missing \(id)") }
        return item.status
    }
    static func menuWire(_ items: [SettingJSONValue]) -> SettingJSONValue { .object(["items": .array(items)]) }
    static func cardWire(_ size: String, _ caption: String) -> SettingJSONValue {
        .object(["poster_size": .string(size), "caption": .string(caption)])
    }

    static func run() async throws -> Int {
        var checks = 0
        // Card at all three scopes; explicit balanced differs from an inherited default.
        for ownerScope: SettingScopeIdentity in [.profile, .profileClient, .profileDevice] {
            let transport = FakeTransport()
            let journal = RemoteMemoryJournal()
            await transport.setRow(.uiCardPresentation, ownerScope, cardWire("large", "artwork"))
            let handler = adapter(transport, journal)
            let incoming = try await file(handler)
            check(incoming.schemaVersion == 3)
            await transport.setRow(.uiCardPresentation, ownerScope, cardWire("standard", "title_metadata"))
            check(status(await handler.preview(incoming), card) == .willChange)
            let result = await handler.apply(incoming, selectedIDs: [card])
            if result.applied != [card] || !result.failed.isEmpty {
                fatalError("card scope \(ownerScope): applied=\(result.applied) failed=\(result.failed) skipped=\(result.skipped)")
            }
            check(await transport.row(.uiCardPresentation, ownerScope) == cardWire("large", "artwork"))
            let undone = await handler.undo()
            check(undone.applied.contains(card))
            check(await transport.row(.uiCardPresentation, ownerScope) == cardWire("standard", "title_metadata"))
            checks += 1
        }
        do {
            let transport = FakeTransport(); let handler = adapter(transport)
            let inherited = try await file(handler)
            check(inherited.groups["interface"]?[card] == .record([
                "scope": .string("default"), "posterSize": .string("standard"), "caption": .string("title_metadata")]))
            await transport.setRow(.uiCardPresentation, .profileClient, cardWire("standard", "title_metadata"))
            let explicit = try await file(handler)
            check(explicit.groups["interface"]?[card] != inherited.groups["interface"]?[card])
            checks += 1
        }
        // A lower scope can be lifted to a more-specific one without touching the lower row.
        do {
            let transport = FakeTransport(); let handler = adapter(transport)
            await transport.setRow(.uiCardPresentation, .profileDevice, cardWire("compact", "title"))
            let target = try await file(handler)
            await transport.setRow(.uiCardPresentation, .profileDevice, nil)
            await transport.setRow(.uiCardPresentation, .profile, cardWire("large", "artwork"))
            check(status(await handler.preview(target), card) == .willChange)
            let applied = await handler.apply(target, selectedIDs: [card])
            check(applied.applied == [card])
            check(await transport.row(.uiCardPresentation, .profile) == cardWire("large", "artwork"))
            _ = await handler.undo()
            check(await transport.row(.uiCardPresentation, .profileDevice) == nil)
            check(await transport.row(.uiCardPresentation, .profile) == cardWire("large", "artwork"))
            let lower = try await file(handler)
            await transport.setRow(.uiCardPresentation, .profileDevice, cardWire("compact", "title"))
            if case .unsupported = status(await handler.preview(lower), card) {} else { fatalError("unsafe downward transition") }
            let writes = await transport.writeCount()
            check((await handler.apply(lower, selectedIDs: [card])).skipped == [card])
            check(await transport.writeCount() == writes)
            checks += 1
        }
        // Ordered primary menu with an authenticated, re-verified same-server library reference.
        do {
            let transport = FakeTransport(); let journal = RemoteMemoryJournal(); let handler = adapter(transport, journal)
            await transport.setRow(.navPrimaryMenu, .profileClient, menuWire([home, library, movies]))
            let saved = try await file(handler)
            check(saved.schemaVersion == 4)
            await transport.setRow(.navPrimaryMenu, .profileClient, menuWire([home, movies]))
            check(status(await handler.preview(saved), menu) == .willChange)
            check((await handler.apply(saved, selectedIDs: [menu])).applied == [menu])
            check(await transport.row(.navPrimaryMenu, .profileClient) == menuWire([home, library, movies]))
            check((await handler.undo()).applied.contains(menu))
            check(await transport.row(.navPrimaryMenu, .profileClient) == menuWire([home, movies]))
            checks += 1
        }
        // Restoring a menu must not erase a destination added after the backup was made.
        do {
            let transport = FakeTransport(); let handler = adapter(transport)
            await transport.setRow(.navPrimaryMenu, .profileClient, menuWire([home, library]))
            let saved = try await file(handler)
            await transport.setRow(.navPrimaryMenu, .profileClient, menuWire([home, movies]))
            if case .unsupported = status(await handler.preview(saved), menu) {} else {
                fatalError("unrelated menu destination would be overwritten")
            }
            let writes = await transport.writeCount()
            check((await handler.apply(saved, selectedIDs: [menu])).skipped == [menu])
            check(await transport.writeCount() == writes)
            checks += 1
        }
        // A same-server section is pinned by library ID plus section ID, title and type.
        do {
            let transport = FakeTransport(); let handler = adapter(transport)
            await transport.setSections(1, [.init(id: "recent", title: "Recently Added", type: "dynamic")])
            let section: SettingJSONValue = .object(["type": .string("section"), "library_id": .int(1),
                "section_id": .string("recent"), "label": .string("Recent")])
            await transport.setRow(.navPrimaryMenu, .profileClient, menuWire([home, section]))
            let saved = try await file(handler)
            await transport.setRow(.navPrimaryMenu, .profileClient, menuWire([home]))
            check((await handler.apply(saved, selectedIDs: [menu])).applied == [menu])
            await transport.setSections(1, [])
            if case .unsupported = status(await handler.preview(saved), menu) {} else { fatalError("missing section") }
            checks += 1
        }
        // Shortcuts use the atomic item endpoint; prefix additions preserve existing entries.
        do {
            let transport = FakeTransport(); let journal = RemoteMemoryJournal(); let handler = adapter(transport, journal)
            await transport.setRow(.navShortcuts, .profile, menuWire([library]))
            let saved = try await file(handler)
            await transport.setRow(.navShortcuts, .profile, menuWire([]))
            let shortcutResult = await handler.apply(saved, selectedIDs: [shortcuts])
            if shortcutResult.applied != [shortcuts] {
                fatalError("shortcut result: applied=\(shortcutResult.applied) failed=\(shortcutResult.failed) skipped=\(shortcutResult.skipped)")
            }
            check(await transport.row(.navShortcuts, .profile) == menuWire([library]))
            check((await handler.undo()).applied.contains(shortcuts))
            check(await transport.row(.navShortcuts, .profile) == menuWire([]))
            checks += 1
        }
        // Cross-server built-ins can be remapped (no reference), but names/types never prove a library identity.
        do {
            let source = FakeTransport(); await source.setRow(.navPrimaryMenu, .profileClient, menuWire([home, movies]))
            let builtins = try await file(adapter(source))
            let destination = FakeTransport(); await destination.setScope(.init(
                serverFingerprint: String(repeating: "c", count: 64), profileFingerprint: String(repeating: "d", count: 64)))
            let handler = adapter(destination)
            check(status(await handler.preview(builtins), menu) == .willChange)
            check((await handler.apply(builtins, selectedIDs: [menu])).applied == [menu])
            check(await destination.row(.navPrimaryMenu, .profileClient) == menuWire([home, movies]))
            await source.setRow(.navPrimaryMenu, .profileClient, menuWire([home, library]))
            let referenced = try await file(adapter(source))
            if case .unsupported = status(await handler.preview(referenced), menu) {} else { fatalError("cross-server library matched by name") }
            let count = await destination.writeCount()
            check((await handler.apply(referenced, selectedIDs: [menu])).skipped == [menu])
            check(await destination.writeCount() == count)
            checks += 1
        }
        // Profile mismatch, missing library and duplicate identity all refuse writes.
        do {
            let source = FakeTransport(); await source.setRow(.navPrimaryMenu, .profileClient, menuWire([home, library]))
            let saved = try await file(adapter(source))
            await source.moveProfile()
            let handler = adapter(source)
            if case .unsupported = status(await handler.preview(saved), menu) {} else { fatalError("profile mismatch") }
            let before = await source.writeCount()
            check((await handler.apply(saved, selectedIDs: [menu])).skipped == [menu])
            check(await source.writeCount() == before)
            let destination = FakeTransport(); let other = adapter(destination)
            await destination.setCatalog([])
            if case .unsupported = status(await other.preview(saved), menu) {} else { fatalError("missing library") }
            await destination.setCatalog([.init(id: 1, name: "Movies", type: "movie"),
                                          .init(id: 1, name: "Movies", type: "movie")])
            if case .unsupported = status(await other.preview(saved), menu) {} else { fatalError("ambiguous library") }
            checks += 1
        }
        // Malformed records, offline reads and selective restore do not produce unsafe writes.
        do {
            let transport = FakeTransport(); let handler = adapter(transport)
            await transport.setRow(.uiCardPresentation, .profileClient, cardWire("compact", "title"))
            await transport.setRow(.navPrimaryMenu, .profileClient, menuWire([home, movies]))
            let saved = try await file(handler)
            await transport.setRow(.uiCardPresentation, .profileClient, cardWire("standard", "title_metadata"))
            await transport.setRow(.navPrimaryMenu, .profileClient, menuWire([home]))
            check((await handler.apply(saved, selectedIDs: [card])).applied == [card])
            check(await transport.row(.navPrimaryMenu, .profileClient) == menuWire([home]))
            var malformed = saved.groups
            malformed["interface"]?[card] = .record(["scope": .string("profile_client")])
            let bad = IncomingBackup(schemaVersion: 4, createdAt: saved.createdAt, app: saved.app,
                                     groups: malformed, scope: saved.scope)
            if case .invalid = status(await handler.preview(bad), card) {} else { fatalError("invalid card") }
            await transport.setOffline(true)
            if case .unsupported = status(await handler.preview(saved), menu) {} else { fatalError("offline menu") }
            await transport.setOffline(false)
            checks += 1
        }
        // Failure after a confirmed card write leaves a journal that can reverse that write.
        do {
            let transport = FakeTransport(); let journal = RemoteMemoryJournal(); let handler = adapter(transport, journal)
            await transport.setRow(.uiCardPresentation, .profileClient, cardWire("compact", "title"))
            await transport.setRow(.navPrimaryMenu, .profileClient, menuWire([home, movies]))
            let saved = try await file(handler)
            await transport.setRow(.uiCardPresentation, .profileClient, cardWire("standard", "title_metadata"))
            await transport.setRow(.navPrimaryMenu, .profileClient, menuWire([home]))
            await transport.failWriting(.navPrimaryMenu, .profileClient)
            let result = await handler.apply(saved, selectedIDs: [card, menu])
            check(result.applied == [card] && result.failed == [menu] && handler.needsRecovery)
            await transport.failWriting(nil)
            check((await handler.undo()).applied.contains(card))
            check(await transport.row(.uiCardPresentation, .profileClient)
                == cardWire("standard", "title_metadata"))
            checks += 1
        }
        return checks
    }
}

@MainActor
private final class LocalStore {
    var fourthTab = "sports"
    func registry() -> SettingsBackupRegistry {
        SettingsBackupRegistry(settings: [BackupSetting(
            id: "navigation.fourthTab", group: .navigation, title: "Fourth tab",
            validate: { if case .string(let value) = $0 { return ["sports", "forYou"].contains(value) }; return false },
            read: { [self] in .string(fourthTab) },
            write: { [self] value in
                guard case .string(let raw) = value else { return }
                fourthTab = raw
            })], deviceIdiom: "phone")
    }
}

private final class LocalMemoryJournal: RestoreJournalStoring {
    var record: RestoreJournal?
    func load() throws -> RestoreJournal? { record }
    func save(_ journal: RestoreJournal) throws { record = journal }
    func clear() throws { record = nil }
}
#endif
