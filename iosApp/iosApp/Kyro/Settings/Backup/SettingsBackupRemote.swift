#if os(iOS) || KYRO_STANDALONE_TESTS
import CryptoKit
import Foundation

/// A captured authenticated destination. Only its one-way fingerprints leave this process.
struct SettingsBackupRemoteOwner: Sendable {
    let request: HTTPRequestIdentity
    let scope: SettingsBackupScope
}

struct BackupLibraryIdentity: Equatable, Sendable {
    let id: Int
    let name: String
    let type: String
}

struct BackupSectionIdentity: Equatable, Sendable {
    let id: String
    let title: String
    let type: String
}

struct BackupCollectionIdentity: Equatable, Sendable {
    let id: String
    let title: String
    let type: String
}

protocol SettingsBackupRemoteTransport: Sendable {
    func prepare() async throws
    func owner() async throws -> SettingsBackupRemoteOwner
    func read(_ keys: [SettingKey], owner: SettingsBackupRemoteOwner) async throws -> EffectiveSettingValuesResponse
    func put(_ key: SettingKey, scope: SettingScopeIdentity, value: SettingJSONValue,
             owner: SettingsBackupRemoteOwner) async throws
    func delete(_ key: SettingKey, scope: SettingScopeIdentity,
                owner: SettingsBackupRemoteOwner) async throws
    func refreshUI() async
    /// The server's settings-contract revision, which gates the text-opacity member of the subtitle
    /// appearance (14) and the profile-scoped subtitle offset (19).
    func manifestRevision(owner: SettingsBackupRemoteOwner) async throws -> Int
    func libraries(owner: SettingsBackupRemoteOwner) async throws -> [BackupLibraryIdentity]
    func sections(libraryID: Int, owner: SettingsBackupRemoteOwner) async throws -> [BackupSectionIdentity]
    func collections(libraryID: Int, owner: SettingsBackupRemoteOwner) async throws -> [BackupCollectionIdentity]
    func mutateShortcut(_ value: SettingJSONValue, present: Bool, owner: SettingsBackupRemoteOwner) async throws
}

extension SettingsBackupRemoteTransport {
    func manifestRevision(owner: SettingsBackupRemoteOwner) async throws -> Int { Int.max }
    func prepare() async throws {}
    func refreshUI() async {}
    func libraries(owner: SettingsBackupRemoteOwner) async throws -> [BackupLibraryIdentity] {
        throw SettingsBackupRemoteError.unsupportedValue
    }
    func sections(libraryID: Int, owner: SettingsBackupRemoteOwner) async throws -> [BackupSectionIdentity] {
        throw SettingsBackupRemoteError.unsupportedValue
    }
    func collections(libraryID: Int, owner: SettingsBackupRemoteOwner) async throws -> [BackupCollectionIdentity] {
        throw SettingsBackupRemoteError.unsupportedValue
    }
    func mutateShortcut(_ value: SettingJSONValue, present: Bool, owner: SettingsBackupRemoteOwner) async throws {
        throw SettingsBackupRemoteError.unsupportedValue
    }
}

enum SettingsBackupRemoteError: LocalizedError, Equatable {
    case noVerifiedServer
    case noProfile
    case destinationMismatch
    case unsupportedValue
    case timeout
    case changedOwner
    case unconfirmedWrite
    /// A narrower scope (this device, a library or a series) holds a value that hides the
    /// profile row, so the profile value can't be read, compared or safely replaced.
    case overridden
    case missingReference
    case ambiguousReference
    case unverifiedReference
    case unsafeScopeTransition
    case shortcutOrderConflict
    case existingMenuConflict

    var errorDescription: String? {
        switch self {
        case .noVerifiedServer: "Connect to a server with a verified identity before backing up synced settings."
        case .noProfile: "Select a profile before backing up or restoring synced settings."
        case .destinationMismatch: "This backup belongs to a different server or profile. Synced settings were skipped."
        case .unsupportedValue: "The server returned a value or scope this Kyro version cannot safely transfer."
        case .timeout: "The server did not respond in time. The change was not confirmed."
        case .changedOwner: "The active server or profile changed. Synced settings were not written."
        case .unconfirmedWrite: "The server did not confirm the restored value."
        case .overridden: "A device, library or series override hides this profile setting, so it was left alone."
        case .missingReference: "A saved library, section or collection is missing from this catalog. No menu entries were changed."
        case .ambiguousReference: "Multiple destination libraries match a saved reference. No menu entries were changed."
        case .unverifiedReference: "This catalog reference cannot be verified safely on the destination. No menu entries were changed."
        case .unsafeScopeTransition: "A hidden scoped value cannot be read safely; this scope change was skipped."
        case .shortcutOrderConflict: "Existing shortcut order or extra shortcuts cannot be replaced safely by the atomic shortcut API."
        case .existingMenuConflict: "The current menu has destinations absent from this backup. They were preserved; no menu entries were changed."
        }
    }
}

/// Production transport uses the same authenticated, owner-pinned API as the Settings screens.
#if os(iOS)
struct SiloSettingsBackupTransport: SettingsBackupRemoteTransport {
    let api: SiloAPI
    init(api: SiloAPI = .shared) { self.api = api }

    func prepare() async throws {
        await PlayerSettings.shared.flushPendingDeviceSettings()
        let hasPending = await MainActor.run { PlayerSettings.shared.hasUnsettledSettingsWrites }
        if hasPending { throw SettingsBackupRemoteError.unconfirmedWrite }
        await UICustomizationPreferences.shared.refresh(force: true)
        let uiPending = await MainActor.run {
            UICustomizationPreferences.shared.isSaving || UICustomizationPreferences.shared.hasHeldChanges
        }
        if uiPending { throw SettingsBackupRemoteError.unconfirmedWrite }
    }

    func refreshUI() async {
        _ = await PlayerSettings.shared.refreshFromServer()
        await ThemeMusicPreferences.shared.refresh()
        await AdvisoryAgePreferenceStore.shared.refresh()
        await EpisodeSpoilerPreferences.shared.refresh()
        await SeekIntervalPreferences.shared.refresh()
        await UICustomizationPreferences.shared.refresh(force: true)
    }

    func owner() async throws -> SettingsBackupRemoteOwner {
        let entry = await MainActor.run { ServerRegistry.shared.activeServer }
        guard let entry, let verified = entry.verifiedServerId, !verified.isEmpty else {
            throw SettingsBackupRemoteError.noVerifiedServer
        }
        guard let profile = await api.currentProfileId(), !profile.isEmpty else {
            throw SettingsBackupRemoteError.noProfile
        }
        let request = HTTPRequestIdentity(serverId: entry.id, serverURL: entry.url,
                                          profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        return SettingsBackupRemoteOwner(
            request: request,
            scope: SettingsBackupScope(
                serverFingerprint: Self.fingerprint("kyro-server-v2|\(verified)"),
                profileFingerprint: Self.fingerprint("kyro-profile-v2|\(verified)|\(profile)")))
    }

    func read(_ keys: [SettingKey], owner: SettingsBackupRemoteOwner) async throws -> EffectiveSettingValuesResponse {
        let capabilities = await api.getContractCapabilities(requestIdentity: owner.request)
        guard case .available(let contract) = capabilities else {
            throw SettingsBackupRemoteError.unsupportedValue
        }
        // A batch fails as a whole on a key the server does not define, so newer keys are left out
        // of the request; the adapter reports each missing row as unsupported by this server.
        let served = keys.filter(contract.supports)
        guard !served.isEmpty else { throw SettingsBackupRemoteError.unsupportedValue }
        return try await api.getEffectiveValues(keys: served, requestIdentity: owner.request)
    }

    func manifestRevision(owner: SettingsBackupRemoteOwner) async throws -> Int {
        let capabilities = await api.getContractCapabilities(requestIdentity: owner.request)
        guard case .available(let contract) = capabilities else { throw SettingsBackupRemoteError.unsupportedValue }
        return contract.manifestRevision
    }

    func libraries(owner: SettingsBackupRemoteOwner) async throws -> [BackupLibraryIdentity] {
        let result = try await api.libraries().libraries.map {
            BackupLibraryIdentity(id: $0.id, name: $0.name, type: $0.type)
        }
        guard (try await self.owner()).scope == owner.scope else { throw SettingsBackupRemoteError.changedOwner }
        return result
    }

    func sections(libraryID: Int, owner: SettingsBackupRemoteOwner) async throws -> [BackupSectionIdentity] {
        let result = try await api.librarySections(libraryId: libraryID).sections.map {
            BackupSectionIdentity(id: $0.id, title: $0.title, type: $0.sectionType)
        }
        guard (try await self.owner()).scope == owner.scope else { throw SettingsBackupRemoteError.changedOwner }
        return result
    }

    func collections(libraryID: Int, owner: SettingsBackupRemoteOwner) async throws -> [BackupCollectionIdentity] {
        let result = try await api.libraryCollections(libraryId: libraryID).collections.map {
            BackupCollectionIdentity(id: $0.id, title: $0.name, type: $0.collectionType ?? "")
        }
        guard (try await self.owner()).scope == owner.scope else { throw SettingsBackupRemoteError.changedOwner }
        return result
    }

    func mutateShortcut(_ value: SettingJSONValue, present: Bool, owner: SettingsBackupRemoteOwner) async throws {
        let data = try SettingsWireCoding.makeEncoder().encode(value)
        let item = try SettingsWireCoding.makeDecoder().decode(PrimaryMenuItem.self, from: data)
        try await api.putNavigationShortcutItem(item, present: present,
                                                profileId: owner.request.profileId, requestIdentity: owner.request)
    }

    func put(_ key: SettingKey, scope: SettingScopeIdentity, value: SettingJSONValue,
             owner: SettingsBackupRemoteOwner) async throws {
        _ = try await api.putValue(key: key, scope: scope, value: value,
                                   profileId: owner.request.profileId, requestIdentity: owner.request)
    }

    func delete(_ key: SettingKey, scope: SettingScopeIdentity,
                owner: SettingsBackupRemoteOwner) async throws {
        do {
            try await api.deleteValue(key: key, scope: scope,
                                      profileId: owner.request.profileId, requestIdentity: owner.request)
        } catch SettingsAPIError.noValueAtScope {
            // Already inherited at this scope.
        }
    }

    private static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif

/// How a remote setting's value is carried in a backup. Every kind is a backup scalar, so the
/// schema-2 envelope, its size limits and its safety filter apply unchanged.
enum RemoteBackupValueKind: Equatable {
    case resolution
    case languageTag
    case subtitleLanguage
    case bool
    /// One of the contract's enum members, with its shared label.
    case choice([(value: String, label: String)])
    /// An integer in a contract range. `nullable` lets JSON null ("No limit") be explicit.
    case integer(ClosedRange<Int>, nullable: Bool)
    /// An integer that must be one of the contract's listed values (the seek intervals).
    case intChoice([Int])
    /// A nullable language tag with no fixed list (`catalog.metadata_language`).
    case metadataLanguage
    /// `player.playback_speed` (0.25…3.0, step 0.05) as whole hundredths: 125 means 1.25×.
    /// A backup holds no floating-point values, so the grid is exact.
    case speedHundredths

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.resolution, .resolution), (.languageTag, .languageTag),
             (.subtitleLanguage, .subtitleLanguage), (.bool, .bool), (.speedHundredths, .speedHundredths),
             (.metadataLanguage, .metadataLanguage):
            return true
        case (.choice(let a), .choice(let b)): return a.map(\.value) == b.map(\.value)
        case (.integer(let a, let x), .integer(let b, let y)): return a == b && x == y
        case (.intChoice(let a), .intChoice(let b)): return a == b
        default: return false
        }
    }
}

/// The API-backed settings in the unified backup. Each one is a single scalar key with one
/// authoritative scope; it is read through the batched effective-settings API and written with
/// `putValue`/`deleteValue` at that scope. Settings whose scope can move (subtitle appearance and
/// timing), composite records and catalog-bound IDs are deliberately absent.
enum RemoteBackupDefinition: CaseIterable {
    case resolution, audioLanguage, subtitleLanguage
    // Batch 1: profile-device scalar playback and interface preferences.
    case maxBitrate, bufferingQuality, hdr, dolbyVision
    case introSkip, skipCredits, autoPlayNext, nextUpPrompt
    case playbackSpeed, videoSizing, orientation, seekCache
    case themeMusic, themeMusicLoop
    // Batch 2: profile-scope scalars.
    case advisoryAge, hideEpisodeImages, hideEpisodeDescriptions
    case videoSkipBack, videoSkipForward, audiobookSkipBack, audiobookSkipForward
    case subtitleMode, forcedSubtitles, metadataLanguage

    /// Stable, platform-neutral backup IDs. They must pass `SettingsBackupSafety.isSensitiveName`,
    /// so the seek cache uses `fastSeeking` rather than the word "cache".
    var id: String {
        switch self {
        case .resolution: "streaming.resolution"
        case .audioLanguage: "streaming.audioLanguage"
        case .subtitleLanguage: "subtitles.language"
        case .maxBitrate: "streaming.maxBitrate"
        case .bufferingQuality: "streaming.bufferingQuality"
        case .hdr: "streaming.hdr"
        case .dolbyVision: "streaming.dolbyVision"
        case .introSkip: "player.introSkip"
        case .skipCredits: "player.skipCredits"
        case .autoPlayNext: "player.autoPlayNext"
        case .nextUpPrompt: "player.nextUpSeconds"
        case .playbackSpeed: "player.speedHundredths"
        case .videoSizing: "player.videoSizing"
        case .orientation: "player.orientation"
        case .seekCache: "player.fastSeeking"
        case .themeMusic: "interface.themeMusic"
        case .themeMusicLoop: "interface.themeMusicLoop"
        case .advisoryAge: "interface.advisoryAge"
        case .hideEpisodeImages: "interface.hideEpisodeImages"
        case .hideEpisodeDescriptions: "interface.hideEpisodeDescriptions"
        case .videoSkipBack: "player.videoSkipBackSeconds"
        case .videoSkipForward: "player.videoSkipForwardSeconds"
        case .audiobookSkipBack: "player.audiobookSkipBackSeconds"
        case .audiobookSkipForward: "player.audiobookSkipForwardSeconds"
        case .subtitleMode: "subtitles.mode"
        case .forcedSubtitles: "subtitles.showForced"
        case .metadataLanguage: "subtitles.metadataLanguage"
        }
    }

    var group: SettingsBackupGroup {
        switch self {
        case .resolution, .audioLanguage, .maxBitrate, .bufferingQuality, .hdr, .dolbyVision: .streaming
        case .subtitleLanguage, .subtitleMode, .forcedSubtitles, .metadataLanguage: .subtitles
        case .introSkip, .skipCredits, .autoPlayNext, .nextUpPrompt, .playbackSpeed, .videoSizing,
             .orientation, .seekCache, .videoSkipBack, .videoSkipForward, .audiobookSkipBack,
             .audiobookSkipForward: .player
        case .themeMusic, .themeMusicLoop, .advisoryAge, .hideEpisodeImages,
             .hideEpisodeDescriptions: .interface
        }
    }

    var title: String {
        switch self {
        case .resolution: "Playback resolution"
        case .audioLanguage: "Audio language"
        case .subtitleLanguage: "Subtitle language"
        case .maxBitrate: "Maximum bitrate"
        case .bufferingQuality: "Lower quality when buffering"
        case .hdr: "HDR"
        case .dolbyVision: "Dolby Vision"
        case .introSkip: "Skip intros"
        case .skipCredits: "Skip credits"
        case .autoPlayNext: "Auto-play next episode"
        case .nextUpPrompt: "Show Next Up"
        case .playbackSpeed: "Playback speed"
        case .videoSizing: "Video sizing"
        case .orientation: "Player orientation"
        case .seekCache: "Seek cache"
        case .themeMusic: "Theme music"
        case .themeMusicLoop: "Loop theme music"
        case .advisoryAge: "Show advisory age"
        case .hideEpisodeImages: "Blur unwatched episode images"
        case .hideEpisodeDescriptions: "Hide unwatched episode descriptions"
        case .videoSkipBack: "Video skip back"
        case .videoSkipForward: "Video skip forward"
        case .audiobookSkipBack: "Audiobook skip back"
        case .audiobookSkipForward: "Audiobook skip forward"
        case .subtitleMode: "Subtitle behavior"
        case .forcedSubtitles: "Show forced subtitles"
        case .metadataLanguage: "Metadata language"
        }
    }

    var key: SettingKey {
        switch self {
        case .resolution: .playbackPreferredQuality
        case .audioLanguage: .playbackAudioLanguage
        case .subtitleLanguage: .playbackSubtitleLanguage
        case .maxBitrate: .playbackMaxBitrateKbps
        case .bufferingQuality: .playbackBufferingQualityMode
        case .hdr: .playerHdrEnabled
        case .dolbyVision: .playerDolbyVisionEnabled
        case .introSkip: .playbackIntroSkipMode
        case .skipCredits: .playbackAutoSkipCredits
        case .autoPlayNext: .playbackAutoPlayNext
        case .nextUpPrompt: .playbackNextUpPromptSeconds
        case .playbackSpeed: .playerPlaybackSpeed
        case .videoSizing: .playerVideoGravity
        case .orientation: .playerOrientationMode
        case .seekCache: .playerSeekCacheEnabled
        case .themeMusic: .uiThemeMusicEnabled
        case .themeMusicLoop: .uiThemeMusicLoop
        case .advisoryAge: .catalogShowAdvisoryAge
        case .hideEpisodeImages: .catalogHideUnwatchedEpisodeImages
        case .hideEpisodeDescriptions: .catalogHideUnwatchedEpisodeOverviews
        case .videoSkipBack: .playerVideoSkipBackSeconds
        case .videoSkipForward: .playerVideoSkipForwardSeconds
        case .audiobookSkipBack: .playerAudiobookSkipBackSeconds
        case .audiobookSkipForward: .playerAudiobookSkipForwardSeconds
        case .subtitleMode: .playbackSubtitleMode
        case .forcedSubtitles: .playbackShowForcedSubtitles
        case .metadataLanguage: .catalogMetadataLanguage
        }
    }

    /// Batch 1 and the audio/resolution settings are per device; subtitle and library-wide
    /// preferences (and the skip intervals) belong to the profile.
    var scope: SettingScopeIdentity {
        switch self {
        case .subtitleLanguage, .subtitleMode, .forcedSubtitles, .metadataLanguage, .advisoryAge,
             .hideEpisodeImages, .hideEpisodeDescriptions, .videoSkipBack, .videoSkipForward,
             .audiobookSkipBack, .audiobookSkipForward: .profile
        default: .profileDevice
        }
    }
    var expectedScope: SettingScope { scope.scope }

    /// Keys newer than the oldest supported server (`SettingKey.minimumServerRevision`). An older
    /// server does not serve them, so they are omitted from its export and skipped on its restore
    /// instead of failing the whole backup. A test pins this to `SettingKey.isNewerThanMinimumServer`.
    var requiresCapability: Bool {
        switch self {
        case .bufferingQuality, .themeMusic, .themeMusicLoop, .advisoryAge, .hideEpisodeImages,
             .hideEpisodeDescriptions, .videoSkipBack, .videoSkipForward, .audiobookSkipBack,
             .audiobookSkipForward: true
        default: false
        }
    }

    var kind: RemoteBackupValueKind {
        switch self {
        case .resolution: .resolution
        case .audioLanguage: .languageTag
        case .subtitleLanguage: .subtitleLanguage
        case .maxBitrate: .integer(100...200_000, nullable: true)
        case .nextUpPrompt: .integer(0...120, nullable: false)
        case .playbackSpeed: .speedHundredths
        case .hdr, .dolbyVision, .skipCredits, .autoPlayNext, .seekCache, .themeMusic, .themeMusicLoop,
             .advisoryAge, .hideEpisodeImages, .hideEpisodeDescriptions, .forcedSubtitles: .bool
        case .videoSkipBack, .videoSkipForward, .audiobookSkipBack, .audiobookSkipForward:
            .intChoice(Self.seekChoices)
        case .metadataLanguage: .metadataLanguage
        case .subtitleMode: .choice([("auto", "Auto"), ("always", "Always"), ("off", "Off")])
        // The contract's enum members and shared labels. Tests pin them to the production enums
        // (`BufferingQualityMode`, `IntroSkipMode`, `VideoGravity`, `PlayerOrientationMode`).
        case .bufferingQuality:
            .choice([("never", "Never"), ("ask", "Ask first"), ("always", "Automatically")])
        case .introSkip:
            .choice([("never", "Never"), ("ask", "Ask to skip"), ("always", "Skip automatically")])
        case .videoSizing:
            .choice([("fit", "Fit"), ("fill", "Fill"), ("stretch", "Stretch")])
        case .orientation:
            .choice([("landscapeLocked", "Landscape locked"), ("rotateFreely", "Rotate freely")])
        }
    }

    /// `SeekIntervalContract.choices`; a test pins the two together.
    static let seekChoices = [5, 10, 15, 30, 45, 60, 90]

    /// The reserved value distinguishes an inherited row from an explicit value.
    static let inherited = "~inherit"
    /// An explicit JSON null, for a key whose contract allows one.
    static let null = "~null"

    static func definition(id: String) -> RemoteBackupDefinition? { allCases.first { $0.id == id } }
    static var ids: Set<String> { Set(allCases.map(\.id)) }
    static var groups: [SettingsBackupGroup] {
        var seen: [SettingsBackupGroup] = []
        for definition in allCases where !seen.contains(definition.group) { seen.append(definition.group) }
        return seen
    }

    var allowsNull: Bool {
        switch kind {
        case .subtitleLanguage, .metadataLanguage: true
        case .integer(_, let nullable): nullable
        default: false
        }
    }

    func validate(_ value: BackupValue) -> Bool {
        if case .string(let raw) = value {
            if raw == Self.inherited { return true }
            if raw == Self.null { return allowsNull }
        }
        switch (kind, value) {
        case (.resolution, .string(let raw)): return SiloQualityPresets.resolutionChoices.contains(raw)
        case (.languageTag, .string(let raw)): return Self.isPortableLanguageTag(raw)
        case (.subtitleLanguage, .string(let raw)), (.metadataLanguage, .string(let raw)):
            return !raw.isEmpty && raw.count <= 32
                && raw.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0)
                    || (48...57).contains($0) || $0 == 45 }
        case (.bool, .bool): return true
        case (.choice(let options), .string(let raw)): return options.contains { $0.value == raw }
        case (.integer(let range, _), .int(let number)): return range.contains(number)
        case (.intChoice(let allowed), .int(let number)): return allowed.contains(number)
        case (.speedHundredths, .int(let number)): return (25...300).contains(number) && number % 5 == 0
        default: return false
        }
    }

    /// The authoritative value of the row this definition writes. A row from any other scope means
    /// the destination row is absent; for the profile-device settings that is "inherited".
    func snapshot(_ row: EffectiveSettingValue) throws -> BackupValue {
        guard row.key == key.rawValue else { throw SettingsBackupRemoteError.unsupportedValue }
        guard row.scope == expectedScope else {
            // A contract default, or an account/profile row under a device setting, is inherited.
            // For the profile-scoped setting, a higher-precedence row hides the profile row, which
            // therefore cannot be read or safely replaced.
            if row.scope == nil || expectedScope == .profileDevice || row.scope == .account {
                return .string(Self.inherited)
            }
            // A profile setting whose winning row is a device, client, library or series
            // override. That row belongs to someone else's scope; it is never read as the
            // profile value and never overwritten.
            if expectedScope == .profile, let other = row.scope, other != .profile {
                throw SettingsBackupRemoteError.overridden
            }
            throw SettingsBackupRemoteError.unsupportedValue
        }
        guard row.profileId == nil || !row.profileId!.isEmpty else {
            throw SettingsBackupRemoteError.unsupportedValue
        }
        let result: BackupValue
        switch (kind, row.storedValue ?? row.value) {
        case (.subtitleLanguage, .null), (.metadataLanguage, .null): result = .string(Self.null)
        // No audio preference on this device means no device override.
        case (.languageTag, .null): result = .string(Self.inherited)
        case (.integer(_, nullable: true), .null): result = .string(Self.null)
        case (.resolution, .string(let raw)), (.languageTag, .string(let raw)),
             (.subtitleLanguage, .string(let raw)), (.metadataLanguage, .string(let raw)),
             (.choice, .string(let raw)):
            result = .string(raw)
        case (.bool, .bool(let flag)): result = .bool(flag)
        case (.integer, let wire), (.intChoice, let wire):
            guard let number = wire.intValue else { throw SettingsBackupRemoteError.unsupportedValue }
            result = .int(number)
        case (.speedHundredths, let wire):
            guard let rate = wire.doubleValue, rate.isFinite else { throw SettingsBackupRemoteError.unsupportedValue }
            let hundredths = (rate * 100).rounded()
            // Off-grid values were never accepted by the server; refuse rather than round silently.
            guard abs(rate * 100 - hundredths) < 0.001 else { throw SettingsBackupRemoteError.unsupportedValue }
            result = .int(Int(hundredths))
        default: throw SettingsBackupRemoteError.unsupportedValue
        }
        guard validate(result) else { throw SettingsBackupRemoteError.unsupportedValue }
        return result
    }

    /// The JSON value to PUT, or nil to delete the destination row (inherit).
    func wireValue(_ value: BackupValue) throws -> SettingJSONValue? {
        guard validate(value) else { throw SettingsBackupRemoteError.unsupportedValue }
        switch value {
        case .string(Self.inherited): return nil
        case .string(Self.null): return .null
        case .string(let raw): return .string(raw)
        case .bool(let flag): return .bool(flag)
        case .int(let number):
            if kind == .speedHundredths { return .double(Double(number) / 100) }
            return .int(number)
        case .record, .array: throw SettingsBackupRemoteError.unsupportedValue
        }
    }

    func label(_ value: BackupValue) -> String {
        if case .string(let raw) = value {
            if raw == Self.inherited { return "Use inherited setting" }
            if raw == Self.null {
                return self == .maxBitrate ? "No limit" : self == .metadataLanguage ? "Library default" : "No preference"
            }
        }
        switch (kind, value) {
        case (.resolution, .string(let raw)): return SiloQualityPresets.resolutionLabel(raw)
        case (.languageTag, .string(let raw)): return raw == "x-silo-original" ? "Original language" : raw
        case (.intChoice, .int(let number)): return "\(number) seconds"
        case (.choice(let options), .string(let raw)): return options.first { $0.value == raw }?.label ?? raw
        case (.integer, .int(let number)):
            if self == .maxBitrate { return Self.bitrateLabel(number) }
            // The Playback screen's wording: "At end", "30 seconds before end", "1 minute before end".
            if self == .nextUpPrompt {
                if number == 0 { return "At end" }
                if number % 60 == 0 { return number == 60 ? "1 minute before end" : "\(number / 60) minutes before end" }
                return "\(number) seconds before end"
            }
            return String(number)
        case (.speedHundredths, .int(let number)):
            let rate = Double(number) / 100
            return rate == 1 ? "Normal (1×)" : String(format: "%g×", rate)
        default: return value.plainText
        }
    }

    private static func bitrateLabel(_ kbps: Int) -> String {
        kbps >= 1000 ? String(format: "%g Mbps", Double(kbps) / 1000) : "\(kbps) Kbps"
    }

    private static func isPortableLanguageTag(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= 64,
              raw.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 }) else { return false }
        guard raw != "x-silo-original" else { return true }
        let subtags = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard let language = subtags.first, (2...8).contains(language.count),
              language.allSatisfy({ $0.isASCII && $0.isLetter }),
              subtags.dropFirst().allSatisfy({ (1...8).contains($0.count) }) else { return false }
        return true
    }
}

/// The two Batch-4 logical settings whose UI state spans more than one API row or scope.
enum ScopedCompositeBackup {
    static let cellularID = "streaming.cellularQuality"
    static let titleArtID = "interface.titleArt"
    static let cellularKeys: [SettingKey] = [.playbackCellularPreferredQuality, .playbackCellularMaxBitrateKbps]
    static let titleArtKey = SettingKey.uiTitleArt
    static let ids: Set<String> = [cellularID, titleArtID]
    static let revision = SettingKey.cellularQualityRevision

    static func cellular(_ rows: [SettingKey: EffectiveSettingValue]) throws -> BackupValue {
        guard let quality = rows[.playbackCellularPreferredQuality],
              let bitrate = rows[.playbackCellularMaxBitrateKbps],
              quality.scope == bitrate.scope,
              case .string(let resolution) = (quality.storedValue ?? quality.value),
              SiloQualityPresets.resolutionChoices.contains(resolution) else {
            throw SettingsBackupRemoteError.unsupportedValue
        }
        let cap: BackupValue
        let storedBitrate = bitrate.storedValue ?? bitrate.value
        if case .null = storedBitrate { cap = .string(RemoteBackupDefinition.null) }
        else if let number = storedBitrate.intValue, (100...200_000).contains(number) { cap = .int(number) }
        else { throw SettingsBackupRemoteError.unsupportedValue }
        return .record(["scope": .string(quality.scope?.rawValue ?? "default"),
                        "resolution": .string(resolution), "bitrateKbps": cap])
    }

    static func titleArt(_ rows: [SettingKey: EffectiveSettingValue]) throws -> BackupValue {
        guard let row = rows[titleArtKey], case .bool(let enabled) = (row.storedValue ?? row.value),
              row.scope == nil || row.scope == .profile || row.scope == .profileDevice else {
            throw SettingsBackupRemoteError.unsupportedValue
        }
        return .record(["scope": .string(row.scope?.rawValue ?? "default"), "enabled": .bool(enabled)])
    }

    static func scope(_ value: BackupValue, id: String) -> String? {
        guard case .record(let fields) = value, case .string(let scope)? = fields["scope"] else { return nil }
        guard id == cellularID ? ["default", "profile", "profile_device"].contains(scope)
              : ["default", "profile", "profile_device"].contains(scope) else { return nil }
        return scope
    }

    static func cellularFields(_ value: BackupValue) -> (scope: String, resolution: BackupValue, bitrate: BackupValue)? {
        guard case .record(let fields) = value, let scope = scope(value, id: cellularID),
              Set(fields.keys) == Set(["scope", "resolution", "bitrateKbps"]),
              case .string(let resolution)? = fields["resolution"],
              SiloQualityPresets.resolutionChoices.contains(resolution),
              let bitrate = fields["bitrateKbps"], validCap(bitrate) else { return nil }
        return (scope, .string(resolution), bitrate)
    }

    static func titleArtFields(_ value: BackupValue) -> (scope: String, enabled: BackupValue)? {
        guard case .record(let fields) = value, let scope = scope(value, id: titleArtID),
              Set(fields.keys) == Set(["scope", "enabled"]),
              let enabled = fields["enabled"], case .bool = enabled else { return nil }
        return (scope, enabled)
    }

    private static func validCap(_ value: BackupValue) -> Bool {
        if value == .string(RemoteBackupDefinition.null) { return true }
        if case .int(let number) = value { return (100...200_000).contains(number) }
        return false
    }

    static func label(_ id: String, _ value: BackupValue) -> String {
        if id == cellularID, let fields = cellularFields(value) {
            let cap = fields.bitrate == .string(RemoteBackupDefinition.null)
                ? "unlimited" : "\(fields.bitrate.plainText) Kbps"
            return "\(fields.resolution.plainText), \(cap) (\(fields.scope))"
        }
        if id == titleArtID, let fields = titleArtFields(value) {
            let enabled = fields.enabled == .bool(true) ? "On" : "Off"
            return "\(enabled) (\(fields.scope))"
        }
        return value.plainText
    }
}

/// The revision-5 interface records. Menu objects use schema 4; the card record remains schema 3.
/// Catalog references are captured with their visible identity, never replayed as bare IDs.
enum InterfaceRecordBackup {
    static let cardID = "interface.cardPresentation"
    static let menuID = "interface.primaryMenu"
    static let shortcutsID = "interface.shortcuts"
    static let orderedIDs = [cardID, menuID, shortcutsID]
    static let ids = Set(orderedIDs)
    static let keys: [SettingKey] = [.uiCardPresentation, .navPrimaryMenu, .navShortcuts]

    static func key(_ id: String) -> SettingKey? {
        switch id {
        case cardID: .uiCardPresentation
        case menuID: .navPrimaryMenu
        case shortcutsID: .navShortcuts
        default: nil
        }
    }

    static func title(_ id: String) -> String {
        switch id {
        case cardID: "Card presentation"
        case menuID: "Primary menu"
        case shortcutsID: "Navigation shortcuts"
        default: id
        }
    }

    static func validScope(_ scope: String, id: String) -> Bool {
        switch id {
        case cardID: ["default", "profile", "profile_client", "profile_device"].contains(scope)
        case menuID: ["default", "profile_client", "profile_device"].contains(scope)
        case shortcutsID: ["default", "profile"].contains(scope)
        default: false
        }
    }

    static func scope(_ value: BackupValue, id: String) -> String? {
        guard case .record(let fields) = value,
              case .string(let scope)? = fields["scope"], validScope(scope, id: id) else { return nil }
        return scope
    }

    static func card(_ row: EffectiveSettingValue) throws -> BackupValue {
        let scope = row.scope?.rawValue ?? "default"
        guard validScope(scope, id: cardID),
              case .object(let fields) = row.storedValue ?? row.value,
              Set(fields.keys) == Set(["poster_size", "caption"]),
              case .string(let size)? = fields["poster_size"],
              case .string(let caption)? = fields["caption"],
              ["compact", "standard", "large"].contains(size),
              ["title_metadata", "title", "artwork"].contains(caption) else {
            throw SettingsBackupRemoteError.unsupportedValue
        }
        return .record(["scope": .string(scope), "posterSize": .string(size), "caption": .string(caption)])
    }

    static func validCard(_ value: BackupValue) -> Bool {
        guard case .record(let fields) = value, Set(fields.keys) == Set(["scope", "posterSize", "caption"]),
              scope(value, id: cardID) != nil,
              case .string(let size)? = fields["posterSize"],
              case .string(let caption)? = fields["caption"] else { return false }
        return ["compact", "standard", "large"].contains(size)
            && ["title_metadata", "title", "artwork"].contains(caption)
    }

    static func validItems(_ value: BackupValue, id: String) -> Bool {
        guard case .record(let fields) = value, Set(fields.keys) == Set(["scope", "items"]),
              let scope = scope(value, id: id), let items = fields["items"] else { return false }
        if case .string(let marker) = items {
            return (id == menuID && marker == RemoteBackupDefinition.null && scope != "default")
                || (marker == RemoteBackupDefinition.inherited && scope == "default")
        }
        guard case .array(let entries) = items, entries.count <= 64 else { return false }
        if id == menuID && scope == "default" { return false }
        if id == shortcutsID && scope == "default" && !entries.isEmpty { return false }
        var identities = Set<String>()
        for entry in entries {
            guard case .record(let item) = entry, case .string(let kind)? = item["kind"] else { return false }
            let identity: String
            switch kind {
            case "builtin":
                guard id == menuID, Set(item.keys) == Set(["kind", "destination"]),
                      case .string(let destination)? = item["destination"],
                      ["home", "movies", "series", "music", "audiobooks", "for_you", "calendar"].contains(destination)
                else { return false }
                identity = "builtin:\(destination)"
            case "library", "section", "collection":
                guard case .int(let libraryID)? = item["libraryId"], libraryID > 0,
                      case .string(let libraryName)? = item["libraryName"], !libraryName.isEmpty,
                      case .string(let libraryType)? = item["libraryType"], !libraryType.isEmpty,
                      case .string(let label)? = item["label"], !label.isEmpty else { return false }
                var names = Set(["kind", "libraryId", "libraryName", "libraryType", "label"])
                if kind == "section" { names.formUnion(["sectionId", "sectionName", "sectionType"]) }
                if kind == "collection" { names.formUnion(["collectionId", "collectionName", "collectionType"]) }
                guard Set(item.keys) == names else { return false }
                if kind == "section" {
                    guard case .string(let sectionID)? = item["sectionId"], !sectionID.isEmpty,
                          case .string(let sectionName)? = item["sectionName"], !sectionName.isEmpty,
                          case .string? = item["sectionType"] else { return false }
                    identity = "section:\(libraryID):\(sectionID)"
                } else if kind == "collection" {
                    guard case .string(let collectionID)? = item["collectionId"], !collectionID.isEmpty,
                          case .string(let collectionName)? = item["collectionName"], !collectionName.isEmpty,
                          case .string? = item["collectionType"] else { return false }
                    identity = "collection:\(libraryID):\(collectionID)"
                } else { identity = "library:\(libraryID)" }
            default: return false
            }
            guard identities.insert(identity).inserted else { return false }
        }
        if id == menuID { return identities.contains("builtin:home") || (scope == "default" && entries.isEmpty) }
        return !entries.contains { if case .record(let fields) = $0 { return fields["kind"] == .string("builtin") }; return false }
    }

    static func label(_ value: BackupValue, id: String) -> String {
        if id == cardID, case .record(let fields) = value {
            return "\(fields["posterSize"]?.plainText ?? "?") posters, \(fields["caption"]?.plainText ?? "?") captions (\(fields["scope"]?.plainText ?? "?"))"
        }
        if case .record(let fields) = value {
            let scope = fields["scope"]?.plainText ?? "?"
            if case .array(let items)? = fields["items"] {
                let ordered = items.map { entry -> String in
                    guard case .record(let item) = entry else { return "Invalid destination" }
                    if item["kind"] == .string("builtin") { return item["destination"]?.plainText ?? "Built-in" }
                    return item["label"]?.plainText ?? "Catalog destination"
                }
                return ordered.isEmpty ? "No destinations (\(scope))"
                    : ordered.joined(separator: " → ") + " (\(scope))"
            }
            return "Inherited menu (\(scope))"
        }
        return value.plainText
    }
}

struct RemoteBackupChange: Codable, Equatable {
    let id: String
    let previous: BackupValue
    let applied: BackupValue
}

struct RemoteBackupJournal: Codable {
    let scope: SettingsBackupScope
    var changes: [RemoteBackupChange]
    var state: State
    /// Ordered row writes of the subtitle display unit. Absent in earlier journals.
    var subtitleSteps: [SubtitleStep]? = nil
    /// Ordered authoritative row writes for composite settings such as cellular quality and title art.
    var rowSteps: [ScopedBackupRowStep]? = nil
    enum State: String, Codable { case applying, applied }
}

/// A reversible, identity-pinned row mutation. `previousEffective` and `appliedEffective` guard
/// Undo against an intervening change while allowing a delete to reveal an inherited lower scope.
struct ScopedBackupRowStep: Codable, Equatable, Sendable {
    let item: String
    let key: String
    let scope: String
    let previousRow: BackupValue?
    let appliedRow: BackupValue?
    let previousEffective: BackupValue
    let previousEffectiveScope: String?
    let appliedEffective: BackupValue
}

protocol RemoteBackupJournalStoring: AnyObject {
    func load() throws -> RemoteBackupJournal?
    func save(_ journal: RemoteBackupJournal) throws
    func clear() throws
}

final class FileRemoteBackupJournal: RemoteBackupJournalStoring {
    private let url: URL
    init(url: URL) { self.url = url }
    static func standard() -> FileRemoteBackupJournal {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FileRemoteBackupJournal(url: base.appendingPathComponent("SettingsBackup/remote-restore-point.json"))
    }
    func load() throws -> RemoteBackupJournal? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count < SettingsBackupSafety.maxFileBytes else { throw SettingsBackupError.tooLarge }
        return try JSONDecoder().decode(RemoteBackupJournal.self, from: data)
    }
    func save(_ journal: RemoteBackupJournal) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try JSONEncoder().encode(journal).write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
        #endif
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

struct RemoteBackupApplyReport {
    var applied: [String] = []
    var failed: [String] = []
    var skipped: [String] = []
    var skipReasons: [String: String] = [:]
}

/// Only `RemoteBackupDefinition` settings are allowlisted. Other server settings remain unsupported
/// until their type, scope, refresh and Undo rules are individually verified.
@MainActor
final class SettingsBackupRemoteAdapter {
    private let transport: SettingsBackupRemoteTransport
    private let journal: RemoteBackupJournalStoring
    private let timeout: Duration

    init(transport: SettingsBackupRemoteTransport, journal: RemoteBackupJournalStoring,
         timeout: Duration = .seconds(12)) {
        self.transport = transport
        self.journal = journal
        self.timeout = timeout
    }

    /// Backup IDs and groups this adapter owns; the model routes them here instead of to the local
    /// registry.
    nonisolated static var settingIDs: Set<String> {
        RemoteBackupDefinition.ids.union(SubtitleDisplayBackup.ids).union(ScopedCompositeBackup.ids).union(InterfaceRecordBackup.ids)
    }
    nonisolated static var groups: [SettingsBackupGroup] {
        var result = RemoteBackupDefinition.groups
        if !result.contains(.interface) { result.append(.interface) }
        return result
    }

    var undoAvailable: Bool { (try? journal.load()) != nil }
    var needsRecovery: Bool { (try? journal.load())?.state == .applying }

    func refreshUI() async { await transport.refreshUI() }

    /// `omitted` lists settings left out of the file, each with the precise reason, so the UI can
    /// say what the backup does not contain.
    func export() async throws -> (scope: SettingsBackupScope, groups: [String: [String: BackupValue]],
                                   omitted: [String]) {
        try await timed { try await self.transport.prepare() }
        let owner = try await timed { try await self.transport.owner() }
        let rows = try await read(owner)
        var groups: [String: [String: BackupValue]] = [:]
        var omitted: [String] = []
        for definition in RemoteBackupDefinition.allCases {
            guard let row = rows[definition.key] else {
                // A key newer than this server is not part of its settings; anything else missing
                // means the read was incomplete, and an incomplete backup must not be written.
                if definition.requiresCapability {
                    omitted.append("\(definition.title) (this server doesn't support it)")
                    continue
                }
                throw SettingsBackupRemoteError.unsupportedValue
            }
            do {
                groups[definition.group.rawValue, default: [:]][definition.id] = try definition.snapshot(row)
            } catch SettingsBackupRemoteError.overridden {
                // The profile value is hidden by a narrower override. Exporting the override as the
                // profile value would restore the wrong thing, so the setting is left out.
                omitted.append("\(definition.title) (hidden by a device, library or series override)")
            }
        }
        let subtitle = SubtitleDisplayBackup.export(from: rows)
        for (id, value) in subtitle.values {
            groups[SettingsBackupGroup.subtitles.rawValue, default: [:]][id] = value
        }
        omitted += subtitle.omitted
        do {
            groups[SettingsBackupGroup.streaming.rawValue, default: [:]][ScopedCompositeBackup.cellularID] = try ScopedCompositeBackup.cellular(rows)
        } catch { omitted.append("Cellular streaming quality (the authoritative quality pair or scope could not be read safely)") }
        do {
            groups[SettingsBackupGroup.interface.rawValue, default: [:]][ScopedCompositeBackup.titleArtID] = try ScopedCompositeBackup.titleArt(rows)
        } catch { omitted.append("Title artwork preference (the authoritative value or scope could not be read safely)") }
        for id in InterfaceRecordBackup.orderedIDs {
            do {
                groups[SettingsBackupGroup.interface.rawValue, default: [:]][id] = try await interfaceSnapshot(id: id, rows: rows, owner: owner)
            } catch {
                omitted.append("\(InterfaceRecordBackup.title(id)) (\(error.localizedDescription))")
            }
        }
        return (owner.scope, groups, omitted)
    }

    func preview(_ incoming: IncomingBackup) async -> [RestorePreviewGroup] {
        let present = RemoteBackupDefinition.allCases.filter {
            incoming.groups[$0.group.rawValue]?[$0.id] != nil
        }
        let composites = ScopedCompositeBackup.ids.filter { id in
            let group = id == ScopedCompositeBackup.cellularID ? SettingsBackupGroup.streaming : .interface
            return incoming.groups[group.rawValue]?[id] != nil
        }.sorted()
        let subtitleValues = incoming.groups[SettingsBackupGroup.subtitles.rawValue] ?? [:]
        let subtitlePresent = SubtitleDisplayBackup.orderedIDs.filter { subtitleValues[$0] != nil }
        let interfacePresent = InterfaceRecordBackup.orderedIDs.filter {
            incoming.groups[SettingsBackupGroup.interface.rawValue]?[$0] != nil
        }
        guard !present.isEmpty || !subtitlePresent.isEmpty || !composites.isEmpty || !interfacePresent.isEmpty else { return [] }
        var reason: String?
        var current: [SettingKey: EffectiveSettingValue] = [:]
        var revision = Int.max
        var destination: SettingsBackupRemoteOwner?
        do {
            try await timed { try await self.transport.prepare() }
            let owner = try await timed { try await self.transport.owner() }
            destination = owner
            if owner.scope != incoming.scope && interfacePresent.isEmpty {
                throw SettingsBackupRemoteError.destinationMismatch
            }
            current = try await read(owner)
            if !subtitlePresent.isEmpty || !composites.isEmpty {
                revision = try await timed { try await self.transport.manifestRevision(owner: owner) }
            }
        } catch { reason = error.localizedDescription }
        let subtitleItems = subtitlePresent.map { id in
            SubtitleDisplayBackup.previewItem(id: id, incoming: subtitleValues[id]!, siblings: subtitleValues,
                                              rows: reason == nil && destination?.scope == incoming.scope ? current : nil,
                                              reason: reason ?? (destination?.scope == incoming.scope ? nil
                                                : SettingsBackupRemoteError.destinationMismatch.localizedDescription),
                                              revision: revision)
        }
        let compositeItems = composites.map { compositePreviewItem(id: $0, incoming: incoming,
            rows: reason == nil && destination?.scope == incoming.scope ? current : nil,
            reason: reason ?? (destination?.scope == incoming.scope ? nil : SettingsBackupRemoteError.destinationMismatch.localizedDescription),
            revision: revision) }
        var interfaceItems: [RestorePreviewItem] = []
        for id in interfacePresent {
            interfaceItems.append(await interfacePreview(id: id, incoming: incoming, rows: current,
                                                         owner: destination, reason: reason))
        }
        let allGroups = Self.groups
        return allGroups.compactMap { group in
            let items: [RestorePreviewItem] = present.filter { $0.group == group }.map { definition in
                let value = incoming.groups[group.rawValue]![definition.id]!
                let row = current[definition.key]
                let existing = row.flatMap { try? definition.snapshot($0) }
                var overridden = false
                if let row, existing == nil {
                    do { _ = try definition.snapshot(row) }
                    catch SettingsBackupRemoteError.overridden { overridden = true }
                    catch {}
                }
                let status: RestoreItemStatus
                if !definition.validate(value) { status = .invalid("This value is not supported.") }
                else if let reason { status = .unsupported(reason) }
                else if destination?.scope != incoming.scope {
                    status = .unsupported(SettingsBackupRemoteError.destinationMismatch.localizedDescription)
                }
                else if row == nil && definition.requiresCapability {
                    status = .unsupported("This server doesn't support this setting.")
                }
                else if row == nil { status = .unsupported("Kyro could not read the authoritative value.") }
                else if overridden {
                    status = .unsupported(SettingsBackupRemoteError.overridden.localizedDescription)
                }
                else if existing == nil {
                    status = .unsupported("The server's current value can't be compared or restored safely.")
                }
                else if existing == value { status = .unchanged }
                else { status = .willChange }
                return RestorePreviewItem(id: definition.id, group: group, title: definition.title,
                                          current: existing.map(definition.label), incoming: definition.label(value),
                                          status: status, incomingValue: value)
            }
            let all = group == .subtitles ? items + subtitleItems
                : items + compositeItems.filter { $0.group == group }
                    + (group == .interface ? interfaceItems : [])
            return all.isEmpty ? nil : RestorePreviewGroup(group: group, items: all, groupUnsupportedReason: nil)
        }
    }

    func apply(_ incoming: IncomingBackup, selectedIDs: Set<String>) async -> RemoteBackupApplyReport {
        let compositeIDs = selectedIDs.intersection(ScopedCompositeBackup.ids)
        let definitions = RemoteBackupDefinition.allCases.filter { selectedIDs.contains($0.id) }
        let subtitleIDs = selectedIDs.intersection(SubtitleDisplayBackup.ids)
        let interfaceIDs = selectedIDs.intersection(InterfaceRecordBackup.ids)
        guard !definitions.isEmpty || !subtitleIDs.isEmpty || !compositeIDs.isEmpty || !interfaceIDs.isEmpty else {
            return RemoteBackupApplyReport()
        }
        var report = RemoteBackupApplyReport()
        do {
            guard !needsRecovery else { throw SettingsBackupRemoteError.unconfirmedWrite }
            try await timed { try await self.transport.prepare() }
            let owner = try await timed { try await self.transport.owner() }
            guard owner.scope == incoming.scope || (!interfaceIDs.isEmpty && definitions.isEmpty
                && subtitleIDs.isEmpty && compositeIDs.isEmpty) else {
                throw SettingsBackupRemoteError.destinationMismatch
            }
            let current = try await read(owner)
            var changes: [RemoteBackupChange] = []
            for definition in definitions {
                guard let desired = incoming.groups[definition.group.rawValue]?[definition.id],
                      definition.validate(desired), let row = current[definition.key] else {
                    report.skipped.append(definition.id); continue
                }
                let previous: BackupValue
                do { previous = try definition.snapshot(row) }
                catch SettingsBackupRemoteError.overridden {
                    // Hidden by a narrower override: leave it alone and say so.
                    report.skipped.append(definition.id); continue
                }
                if previous != desired {
                    changes.append(RemoteBackupChange(id: definition.id, previous: previous, applied: desired))
                }
            }
            guard !changes.isEmpty || !subtitleIDs.isEmpty || !compositeIDs.isEmpty || !interfaceIDs.isEmpty else {
                return report
            }
            var record = RemoteBackupJournal(scope: owner.scope, changes: changes, state: .applying)
            var journalSaved = false
            if !changes.isEmpty { try journal.save(record); journalSaved = true }
            for change in changes {
                guard let definition = definitions.first(where: { $0.id == change.id }) else { continue }
                do {
                    try Task.checkCancellation()
                    try await write(definition, value: change.applied, owner: owner)
                    let confirmed = try await read(owner)
                    guard let row = confirmed[definition.key], try definition.snapshot(row) == change.applied else {
                        throw SettingsBackupRemoteError.unconfirmedWrite
                    }
                    report.applied.append(change.id)
                } catch {
                    report.failed.append(change.id)
                    break
                }
            }
            if !subtitleIDs.isEmpty {
                if report.failed.isEmpty {
                    await applySubtitleDisplay(incoming, selected: subtitleIDs, owner: owner, record: &record,
                                               journalSaved: &journalSaved, report: &report)
                } else {
                    // An earlier write failed, so nothing further is attempted.
                    report.skipped += subtitleIDs.sorted()
                }
            }
            if !compositeIDs.isEmpty {
                if report.failed.isEmpty {
                    await applyComposites(incoming, selected: compositeIDs, owner: owner, record: &record,
                                          journalSaved: &journalSaved, report: &report)
                } else { report.skipped += compositeIDs.sorted() }
            }
            if !interfaceIDs.isEmpty {
                if report.failed.isEmpty {
                    await applyInterfaceRecords(incoming, selected: interfaceIDs, owner: owner, record: &record,
                                                journalSaved: &journalSaved, report: &report)
                } else { report.skipped += interfaceIDs.sorted() }
            }
            if report.failed.isEmpty, journalSaved { record.state = .applied; try journal.save(record) }
        } catch {
            if report.failed.isEmpty {
                report.failed = definitions.map(\.id) + subtitleIDs.sorted() + compositeIDs.sorted() + interfaceIDs.sorted()
            }
        }
        return report
    }

    func undo() async -> RemoteBackupApplyReport {
        var report = RemoteBackupApplyReport()
        guard var record = try? journal.load() else { return report }
        do {
            let owner = try await timed { try await self.transport.owner() }
            guard owner.scope == record.scope else { throw SettingsBackupRemoteError.destinationMismatch }
            // Composite rows are the last writes in an apply; reverse them before subtitle rows.
            await undoCompositeRows(record: &record, owner: owner, report: &report)
            await undoSubtitleDisplay(record: &record, owner: owner, report: &report)
            var remaining: [RemoteBackupChange] = []
            for change in record.changes.reversed() {
                guard let definition = RemoteBackupDefinition.definition(id: change.id) else {
                    report.skipped.append(change.id); continue
                }
                do {
                    let current = try await read(owner)
                    guard let row = current[definition.key] else { throw SettingsBackupRemoteError.unsupportedValue }
                    let value = try definition.snapshot(row)
                    if value == change.previous { continue }
                    guard value == change.applied else { report.skipped.append(change.id); continue }
                    try await write(definition, value: change.previous, owner: owner)
                    let confirmed = try await read(owner)
                    guard let result = confirmed[definition.key], try definition.snapshot(result) == change.previous else {
                        throw SettingsBackupRemoteError.unconfirmedWrite
                    }
                    report.applied.append(change.id)
                } catch {
                    report.failed.append(change.id)
                    remaining.append(change)
                }
            }
            if remaining.isEmpty && (record.subtitleSteps ?? []).isEmpty && (record.rowSteps ?? []).isEmpty { try journal.clear() }
            else { record.changes = remaining.reversed(); try journal.save(record) }
        } catch {
            report.failed = record.changes.map(\.id) + (record.subtitleSteps ?? []).map(\.item)
                + (record.rowSteps ?? []).map(\.item)
        }
        return report
    }

    private func read(_ owner: SettingsBackupRemoteOwner) async throws -> [SettingKey: EffectiveSettingValue] {
        let response = try await timed {
            try await self.transport.read(
                RemoteBackupDefinition.allCases.map(\.key) + SubtitleDisplayBackup.keys
                    + ScopedCompositeBackup.cellularKeys + [ScopedCompositeBackup.titleArtKey]
                    + InterfaceRecordBackup.keys, owner: owner)
        }
        return response.byKey
    }

    private func write(_ definition: RemoteBackupDefinition, value: BackupValue,
                       owner: SettingsBackupRemoteOwner) async throws {
        let currentOwner = try await timed { try await self.transport.owner() }
        guard currentOwner.scope == owner.scope, currentOwner.request == owner.request else {
            throw SettingsBackupRemoteError.changedOwner
        }
        if let wire = try definition.wireValue(value) {
            try await timed { try await self.transport.put(definition.key, scope: definition.scope,
                                                           value: wire, owner: owner) }
        } else {
            try await timed { try await self.transport.delete(definition.key, scope: definition.scope,
                                                              owner: owner) }
        }
    }

    private func timed<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: self.timeout)
                throw SettingsBackupRemoteError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw SettingsBackupRemoteError.timeout }
            return result
        }
    }
}

// MARK: - Interface records and catalog identity

extension SettingsBackupRemoteAdapter {
    private func interfaceSnapshot(id: String, rows: [SettingKey: EffectiveSettingValue],
                                   owner: SettingsBackupRemoteOwner) async throws -> BackupValue {
        guard let key = InterfaceRecordBackup.key(id), let row = rows[key], row.key == key.rawValue else {
            throw SettingsBackupRemoteError.unsupportedValue
        }
        let scope = row.scope?.rawValue ?? "default"
        guard InterfaceRecordBackup.validScope(scope, id: id) else { throw SettingsBackupRemoteError.overridden }
        return try await interfaceExpected(id: id, stored: row.storedValue ?? row.value,
                                           scope: scope, owner: owner)
    }

    private func interfaceExpected(id: String, stored: SettingJSONValue, scope: String,
                                   owner: SettingsBackupRemoteOwner) async throws -> BackupValue {
        if id == InterfaceRecordBackup.cardID {
            guard case .object(let fields) = stored, Set(fields.keys) == ["poster_size", "caption"],
                  case .string(let size)? = fields["poster_size"],
                  case .string(let caption)? = fields["caption"] else {
                throw SettingsBackupRemoteError.unsupportedValue
            }
            let result = BackupValue.record(["scope": .string(scope), "posterSize": .string(size),
                                             "caption": .string(caption)])
            guard InterfaceRecordBackup.validCard(result) else { throw SettingsBackupRemoteError.unsupportedValue }
            return result
        }
        if id == InterfaceRecordBackup.menuID, case .null = stored {
            return .record(["scope": .string(scope), "items": .string(scope == "default"
                ? RemoteBackupDefinition.inherited : RemoteBackupDefinition.null)])
        }
        if id == InterfaceRecordBackup.shortcutsID, scope == "default" {
            guard case .object(let fields) = stored, case .array(let items)? = fields["items"], items.isEmpty else {
                throw SettingsBackupRemoteError.unsupportedValue
            }
            return .record(["scope": .string("default"), "items": .string(RemoteBackupDefinition.inherited)])
        }
        guard case .object(let fields) = stored, Set(fields.keys) == ["items"],
              case .array(let items)? = fields["items"], items.count <= 64 else {
            throw SettingsBackupRemoteError.unsupportedValue
        }
        let libraries = items.isEmpty ? [] : try await timed { try await self.transport.libraries(owner: owner) }
        var saved: [BackupValue] = []
        for item in items {
            saved.append(try await captureMenuItem(item, libraries: libraries, owner: owner))
        }
        let value = BackupValue.record(["scope": .string(scope), "items": .array(saved)])
        guard InterfaceRecordBackup.validItems(value, id: id) else { throw SettingsBackupRemoteError.unsupportedValue }
        return value
    }

    private func captureMenuItem(_ value: SettingJSONValue, libraries: [BackupLibraryIdentity],
                                 owner: SettingsBackupRemoteOwner) async throws -> BackupValue {
        guard case .object(let fields) = value, case .string(let kind)? = fields["type"] else {
            throw SettingsBackupRemoteError.unsupportedValue
        }
        if kind == "builtin" {
            guard Set(fields.keys) == ["type", "destination"],
                  case .string(let destination)? = fields["destination"] else {
                throw SettingsBackupRemoteError.unsupportedValue
            }
            return .record(["kind": .string(kind), "destination": .string(destination)])
        }
        guard ["library", "section", "collection"].contains(kind),
              let libraryID = fields["library_id"]?.intValue,
              let library = libraries.first(where: { $0.id == libraryID }),
              libraries.filter({ $0.id == libraryID }).count == 1,
              case .string(let label)? = fields["label"] else {
            throw SettingsBackupRemoteError.unverifiedReference
        }
        var item: [String: BackupValue] = ["kind": .string(kind), "libraryId": .int(libraryID),
            "libraryName": .string(library.name), "libraryType": .string(library.type), "label": .string(label)]
        switch kind {
        case "library":
            guard Set(fields.keys) == ["type", "library_id", "label"] else {
                throw SettingsBackupRemoteError.unsupportedValue
            }
        case "section":
            guard Set(fields.keys) == ["type", "library_id", "section_id", "label"],
                  case .string(let sectionID)? = fields["section_id"] else {
                throw SettingsBackupRemoteError.unsupportedValue
            }
            let sections = try await timed { try await self.transport.sections(libraryID: libraryID, owner: owner) }
            guard let section = sections.first(where: { $0.id == sectionID }),
                  sections.filter({ $0.id == sectionID }).count == 1 else {
                throw SettingsBackupRemoteError.unverifiedReference
            }
            item["sectionId"] = .string(sectionID)
            item["sectionName"] = .string(section.title)
            item["sectionType"] = .string(section.type)
        case "collection":
            guard Set(fields.keys) == ["type", "library_id", "collection_id", "label"],
                  case .string(let collectionID)? = fields["collection_id"] else {
                throw SettingsBackupRemoteError.unverifiedReference
            }
            let collections = try await timed { try await self.transport.collections(libraryID: libraryID, owner: owner) }
            guard let collection = collections.first(where: { $0.id == collectionID }),
                  collections.filter({ $0.id == collectionID }).count == 1 else {
                throw SettingsBackupRemoteError.unverifiedReference
            }
            item["collectionId"] = .string(collectionID)
            item["collectionName"] = .string(collection.title)
            item["collectionType"] = .string(collection.type)
        default: break
        }
        return .record(item)
    }

    private func resolveMenuItem(_ value: BackupValue, libraries: [BackupLibraryIdentity],
                                 owner: SettingsBackupRemoteOwner, sameServer: Bool) async throws -> SettingJSONValue {
        guard case .record(let fields) = value, case .string(let kind)? = fields["kind"] else {
            throw SettingsBackupRemoteError.unsupportedValue
        }
        if kind == "builtin" {
            guard case .string(let destination)? = fields["destination"] else {
                throw SettingsBackupRemoteError.unsupportedValue
            }
            return .object(["type": .string(kind), "destination": .string(destination)])
        }
        guard case .int(let sourceID)? = fields["libraryId"],
              case .string(let name)? = fields["libraryName"],
              case .string(let type)? = fields["libraryType"],
              case .string(let label)? = fields["label"] else {
            throw SettingsBackupRemoteError.unsupportedValue
        }
        // The catalog API exposes no cross-server stable library key or content fingerprint.
        // A matching human-readable name and media type (often just "Movies") is not proof of
        // identity. Cross-server built-ins are portable, but catalog references are not.
        guard sameServer else { throw SettingsBackupRemoteError.unverifiedReference }
        let matches = libraries.filter { $0.name == name && $0.type == type && $0.id == sourceID }
        guard let library = matches.first else { throw SettingsBackupRemoteError.missingReference }
        guard matches.count == 1 else { throw SettingsBackupRemoteError.ambiguousReference }
        var item: [String: SettingJSONValue] = ["type": .string(kind), "library_id": .int(library.id),
            "label": .string(label)]
        if kind == "section" {
            guard case .string(let sourceSection)? = fields["sectionId"],
                  case .string(let title)? = fields["sectionName"],
                  case .string(let sectionType)? = fields["sectionType"] else {
                throw SettingsBackupRemoteError.unsupportedValue
            }
            // Section IDs are server-local; unlike libraries they have no portable contract ID.
            guard sameServer else { throw SettingsBackupRemoteError.unverifiedReference }
            let sections = try await timed { try await self.transport.sections(libraryID: library.id, owner: owner) }
            guard sections.filter({ $0.id == sourceSection && $0.title == title && $0.type == sectionType }).count == 1
            else { throw SettingsBackupRemoteError.missingReference }
            item["section_id"] = .string(sourceSection)
        } else if kind == "collection" {
            guard case .string(let sourceCollection)? = fields["collectionId"],
                  case .string(let title)? = fields["collectionName"],
                  case .string(let collectionType)? = fields["collectionType"] else {
                throw SettingsBackupRemoteError.unsupportedValue
            }
            guard sameServer else { throw SettingsBackupRemoteError.unverifiedReference }
            let collections = try await timed { try await self.transport.collections(libraryID: library.id, owner: owner) }
            guard collections.filter({ $0.id == sourceCollection && $0.title == title && $0.type == collectionType }).count == 1
            else { throw SettingsBackupRemoteError.missingReference }
            item["collection_id"] = .string(sourceCollection)
        }
        return .object(item)
    }

    private func resolvedInterfaceWire(id: String, value: BackupValue, owner: SettingsBackupRemoteOwner,
                                       sameServer: Bool) async throws -> SettingJSONValue? {
        guard case .record(let fields) = value, let scope = InterfaceRecordBackup.scope(value, id: id) else {
            throw SettingsBackupRemoteError.unsupportedValue
        }
        if scope == "default" { return nil }
        if id == InterfaceRecordBackup.cardID {
            guard InterfaceRecordBackup.validCard(value),
                  case .string(let size)? = fields["posterSize"],
                  case .string(let caption)? = fields["caption"] else {
                throw SettingsBackupRemoteError.unsupportedValue
            }
            return .object(["poster_size": .string(size), "caption": .string(caption)])
        }
        guard InterfaceRecordBackup.validItems(value, id: id), let items = fields["items"] else {
            throw SettingsBackupRemoteError.unsupportedValue
        }
        if items == .string(RemoteBackupDefinition.null) { return .null }
        guard case .array(let entries) = items else { throw SettingsBackupRemoteError.unsupportedValue }
        let libraries = entries.isEmpty ? [] : try await timed { try await self.transport.libraries(owner: owner) }
        var resolved: [SettingJSONValue] = []
        for entry in entries {
            resolved.append(try await resolveMenuItem(entry, libraries: libraries, owner: owner, sameServer: sameServer))
        }
        return .object(["items": .array(resolved)])
    }

    private func interfaceScopeSafe(current: String, desired: String, id: String) -> Bool {
        if current == desired { return true }
        if desired == "default" { return false }
        let order = id == InterfaceRecordBackup.cardID
            ? ["default", "profile", "profile_client", "profile_device"]
            : id == InterfaceRecordBackup.menuID ? ["default", "profile_client", "profile_device"]
                : ["default", "profile"]
        guard let before = order.firstIndex(of: current), let after = order.firstIndex(of: desired) else { return false }
        return after > before // A higher-precedence row is provably absent while a lower row wins.
    }

    private func preservesExistingMenu(_ current: BackupValue, desired: BackupValue) -> Bool {
        guard case .record(let currentFields) = current,
              case .array(let existing)? = currentFields["items"] else { return true }
        guard case .record(let desiredFields) = desired,
              case .array(let incoming)? = desiredFields["items"] else { return false }
        return existing.allSatisfy { incoming.contains($0) }
    }

    private func interfacePreview(id: String, incoming: IncomingBackup,
                                  rows: [SettingKey: EffectiveSettingValue], owner: SettingsBackupRemoteOwner?,
                                  reason: String?) async -> RestorePreviewItem {
        let value = incoming.groups[SettingsBackupGroup.interface.rawValue]![id]!
        var current: BackupValue?
        var status: RestoreItemStatus = .unsupported(reason ?? "The authoritative value is unavailable.")
        if let owner, let key = InterfaceRecordBackup.key(id), rows[key] != nil {
            current = try? await interfaceSnapshot(id: id, rows: rows, owner: owner)
            do {
                guard (id == InterfaceRecordBackup.cardID ? InterfaceRecordBackup.validCard(value)
                    : InterfaceRecordBackup.validItems(value, id: id)) else {
                    status = .invalid("The structured value is malformed or unsupported.")
                    throw SettingsBackupRemoteError.unsupportedValue
                }
                guard reason == nil else { throw SettingsBackupRemoteError.unsupportedValue }
                let sameServer = owner.scope.serverFingerprint == incoming.scope?.serverFingerprint
                if id == InterfaceRecordBackup.cardID && owner.scope != incoming.scope {
                    throw SettingsBackupRemoteError.destinationMismatch
                }
                if sameServer && owner.scope.profileFingerprint != incoming.scope?.profileFingerprint {
                    throw SettingsBackupRemoteError.destinationMismatch
                }
                guard let current else { throw SettingsBackupRemoteError.unsupportedValue }
                let desiredScope = InterfaceRecordBackup.scope(value, id: id)!
                let currentScope = InterfaceRecordBackup.scope(current, id: id)!
                if id == InterfaceRecordBackup.menuID && !preservesExistingMenu(current, desired: value) {
                    throw SettingsBackupRemoteError.existingMenuConflict
                }
                guard interfaceScopeSafe(current: currentScope, desired: desiredScope, id: id) else {
                    throw SettingsBackupRemoteError.unsafeScopeTransition
                }
                let wire = try await resolvedInterfaceWire(id: id, value: value, owner: owner, sameServer: sameServer)
                if id == InterfaceRecordBackup.shortcutsID, case .object(let fields)? = wire,
                   case .array(let wanted)? = fields["items"], let row = rows[key],
                   case .object(let existing) = row.storedValue ?? row.value,
                   case .array(let have)? = existing["items"],
                   !wanted.starts(with: have) {
                    throw SettingsBackupRemoteError.shortcutOrderConflict
                }
                status = current == value ? .unchanged : .willChange
            } catch {
                if case .invalid = status {} else { status = .unsupported(error.localizedDescription) }
            }
        }
        return RestorePreviewItem(id: id, group: .interface, title: InterfaceRecordBackup.title(id),
                                  current: current.map { InterfaceRecordBackup.label($0, id: id) },
                                  incoming: InterfaceRecordBackup.label(value, id: id), status: status,
                                  incomingValue: value)
    }

    fileprivate func applyInterfaceRecords(_ incoming: IncomingBackup, selected: Set<String>,
                                           owner: SettingsBackupRemoteOwner, record: inout RemoteBackupJournal,
                                           journalSaved: inout Bool, report: inout RemoteBackupApplyReport) async {
        for id in InterfaceRecordBackup.orderedIDs where selected.contains(id) {
            var attemptedWrite = false
            do {
                try Task.checkCancellation()
                let sameServer = owner.scope.serverFingerprint == incoming.scope?.serverFingerprint
                guard !(sameServer && owner.scope.profileFingerprint != incoming.scope?.profileFingerprint),
                      id != InterfaceRecordBackup.cardID || owner.scope == incoming.scope else {
                    report.skipped.append(id)
                    report.skipReasons[id] = SettingsBackupRemoteError.destinationMismatch.localizedDescription
                    continue
                }
                guard let value = incoming.groups[SettingsBackupGroup.interface.rawValue]?[id],
                      id == InterfaceRecordBackup.cardID ? InterfaceRecordBackup.validCard(value)
                        : InterfaceRecordBackup.validItems(value, id: id),
                      let key = InterfaceRecordBackup.key(id),
                      let targetScope = InterfaceRecordBackup.scope(value, id: id) else {
                    report.skipped.append(id)
                    report.skipReasons[id] = "The saved structured value is invalid."
                    continue
                }
                let rows = try await read(owner)
                let before = try await interfaceSnapshot(id: id, rows: rows, owner: owner)
                if id == InterfaceRecordBackup.menuID && !preservesExistingMenu(before, desired: value) {
                    report.skipped.append(id)
                    report.skipReasons[id] = SettingsBackupRemoteError.existingMenuConflict.localizedDescription
                    continue
                }
                guard let currentScope = InterfaceRecordBackup.scope(before, id: id),
                      interfaceScopeSafe(current: currentScope, desired: targetScope, id: id) else {
                    report.skipped.append(id)
                    report.skipReasons[id] = SettingsBackupRemoteError.unsafeScopeTransition.localizedDescription
                    continue
                }
                let wire = try await resolvedInterfaceWire(id: id, value: value, owner: owner, sameServer: sameServer)
                if targetScope == "default" { continue }
                guard let wire else { throw SettingsBackupRemoteError.unsupportedValue }
                let expected = try await interfaceExpected(id: id, stored: wire, scope: targetScope, owner: owner)
                if before == expected { continue }
                let scope: SettingScopeIdentity
                switch targetScope {
                case "profile": scope = .profile
                case "profile_client": scope = .profileClient
                case "profile_device": scope = .profileDevice
                default: throw SettingsBackupRemoteError.unsupportedValue
                }
                if id == InterfaceRecordBackup.shortcutsID {
                    guard case .object(let fields) = wire, case .array(let wanted)? = fields["items"],
                          let row = rows[key], case .object(let currentFields) = row.storedValue ?? row.value,
                          case .array(let have)? = currentFields["items"], wanted.starts(with: have) else {
                        report.skipped.append(id)
                        report.skipReasons[id] = SettingsBackupRemoteError.shortcutOrderConflict.localizedDescription
                        continue
                    }
                    var prefix = have
                    for item in wanted.dropFirst(have.count) {
                        let next = prefix + [item]
                        let after = try await interfaceExpected(id: id,
                            stored: .object(["items": .array(next)]), scope: "profile", owner: owner)
                        let prior = try await interfaceExpected(id: id,
                            stored: .object(["items": .array(prefix)]), scope: "profile", owner: owner)
                        let priorEffective = prefix.isEmpty && currentScope == "default" ? before : prior
                        record.rowSteps = (record.rowSteps ?? []) + [ScopedBackupRowStep(
                            item: id, key: key.rawValue, scope: "profile",
                            previousRow: currentScope == "default" && prefix.isEmpty ? nil : prior,
                            appliedRow: after, previousEffective: priorEffective,
                            previousEffectiveScope: currentScope == "default" && prefix.isEmpty ? nil : "profile",
                            appliedEffective: after)]
                        try journal.save(record); journalSaved = true
                        let currentOwner = try await timed { try await self.transport.owner() }
                        guard currentOwner.scope == owner.scope, currentOwner.request == owner.request else {
                            throw SettingsBackupRemoteError.changedOwner
                        }
                        attemptedWrite = true
                        try await timed { try await self.transport.mutateShortcut(item, present: true, owner: owner) }
                        let confirmed = try await interfaceSnapshot(id: id, rows: try await read(owner), owner: owner)
                        guard confirmed == after else { throw SettingsBackupRemoteError.unconfirmedWrite }
                        prefix = next
                    }
                    if prefix.count > have.count { report.applied.append(id) }
                    continue
                }
                record.rowSteps = (record.rowSteps ?? []) + [ScopedBackupRowStep(
                    item: id, key: key.rawValue, scope: targetScope,
                    previousRow: currentScope == targetScope ? before : nil,
                    appliedRow: expected, previousEffective: before,
                    previousEffectiveScope: currentScope == "default" ? nil : currentScope,
                    appliedEffective: expected)]
                try journal.save(record); journalSaved = true
                let currentOwner = try await timed { try await self.transport.owner() }
                guard currentOwner.scope == owner.scope, currentOwner.request == owner.request else {
                    throw SettingsBackupRemoteError.changedOwner
                }
                attemptedWrite = true
                try await timed { try await self.transport.put(key, scope: scope, value: wire, owner: owner) }
                let confirmed = try await interfaceSnapshot(id: id, rows: try await read(owner), owner: owner)
                guard confirmed == expected else { throw SettingsBackupRemoteError.unconfirmedWrite }
                report.applied.append(id)
            } catch {
                if !attemptedWrite, let remote = error as? SettingsBackupRemoteError,
                   [.destinationMismatch, .unsupportedValue, .overridden, .missingReference,
                    .ambiguousReference, .unverifiedReference, .unsafeScopeTransition,
                    .shortcutOrderConflict, .existingMenuConflict].contains(remote) {
                    report.skipped.append(id)
                    report.skipReasons[id] = remote.localizedDescription
                } else {
                    report.failed.append(id)
                    break
                }
            }
        }
    }

    fileprivate func undoInterfaceStep(_ step: ScopedBackupRowStep, owner: SettingsBackupRemoteOwner) async throws -> Bool {
        guard let key = SettingKey(rawValue: step.key), InterfaceRecordBackup.keys.contains(key),
              let id = InterfaceRecordBackup.orderedIDs.first(where: { InterfaceRecordBackup.key($0) == key }) else {
            throw SettingsBackupRemoteError.unsupportedValue
        }
        let current = try await interfaceSnapshot(id: id, rows: try await read(owner), owner: owner)
        if current == step.previousEffective { return true }
        guard current == step.appliedEffective else { return false }
        let currentOwner = try await timed { try await self.transport.owner() }
        guard currentOwner.scope == owner.scope, currentOwner.request == owner.request else {
            throw SettingsBackupRemoteError.changedOwner
        }
        if id == InterfaceRecordBackup.shortcutsID {
            guard case .record(let fields) = step.appliedEffective,
                  case .array(let items)? = fields["items"], let last = items.last,
                  case .record = last else { throw SettingsBackupRemoteError.unsupportedValue }
            let wire = try await resolvedInterfaceWire(id: id,
                value: .record(["scope": .string("profile"), "items": .array([last])]),
                owner: owner, sameServer: true)
            guard case .object(let object)? = wire, case .array(let values)? = object["items"],
                  let item = values.first else { throw SettingsBackupRemoteError.unsupportedValue }
            try await timed { try await self.transport.mutateShortcut(item, present: false, owner: owner) }
            if step.previousEffectiveScope == nil {
                try await timed { try await self.transport.delete(key, scope: .profile, owner: owner) }
            }
        } else if let previous = step.previousRow {
            guard let wire = try await resolvedInterfaceWire(id: id, value: previous, owner: owner,
                                                             sameServer: true) else {
                throw SettingsBackupRemoteError.unsupportedValue
            }
            let scope: SettingScopeIdentity = step.scope == "profile" ? .profile
                : step.scope == "profile_client" ? .profileClient : .profileDevice
            try await timed { try await self.transport.put(key, scope: scope, value: wire, owner: owner) }
        } else {
            let scope: SettingScopeIdentity = step.scope == "profile" ? .profile
                : step.scope == "profile_client" ? .profileClient : .profileDevice
            try await timed { try await self.transport.delete(key, scope: scope, owner: owner) }
        }
        let restored = try await interfaceSnapshot(id: id, rows: try await read(owner), owner: owner)
        guard restored == step.previousEffective else { throw SettingsBackupRemoteError.unconfirmedWrite }
        return true
    }
}

// MARK: - Subtitle display: appearance record, "this device only" switch, sync offset

enum SubtitleRowSlot: String, Codable, Sendable {
    case appearanceDevice, appearanceProfile, syncDevice, syncProfile
}

/// One ordered row write, journalled before it is sent so an interrupted restore can be reversed.
struct SubtitleStep: Codable, Equatable, Sendable {
    let item: String
    let slot: SubtitleRowSlot
    /// The row before the write; nil means no row.
    let previous: BackupValue?
    /// The row after the write; nil means the row was deleted.
    let applied: BackupValue?
}

/// What the authoritative API shows for the three subtitle items. The effective endpoint returns
/// only the winning row, so a profile row is "hidden" while a device row exists.
struct SubtitleObserved: Equatable {
    var appearanceDevice: BackupValue?
    var appearanceProfile: BackupValue?
    var appearanceProfileHidden = false
    var visibleAppearance: [String: BackupValue] = SubtitleDisplayBackup.defaults
    var syncDevice: BackupValue?
    var syncProfile: BackupValue?
    var syncProfileHidden = false

    /// `known` is false for a profile row that a device row currently hides.
    func slot(_ slot: SubtitleRowSlot) -> (known: Bool, value: BackupValue?) {
        switch slot {
        case .appearanceDevice: (true, appearanceDevice)
        case .appearanceProfile: (!appearanceProfileHidden, appearanceProfile)
        case .syncDevice: (true, syncDevice)
        case .syncProfile: (!syncProfileHidden, syncProfile)
        }
    }

    var isDeviceOnly: Bool { appearanceDevice != nil }
}

/// The three subtitle settings are one unit. "This device only" is not a stored value: it means
/// `playback.subtitle_appearance` has a `profile_device` row. The appearance and the sync offset
/// live at that row's scope, so they are read, compared and written together, in a fixed order.
enum SubtitleDisplayBackup {
    static let deviceOnlyID = "subtitles.appearanceDeviceOnly"
    static let appearanceID = "subtitles.appearance"
    static let syncID = "subtitles.syncOffsetMs"
    static let orderedIDs = [deviceOnlyID, appearanceID, syncID]
    static let ids = Set(orderedIDs)
    static let appearanceKey = SettingKey.playbackSubtitleAppearance
    static let syncKey = SettingKey.playerSubtitleSyncMs
    static let keys = [appearanceKey, syncKey]

    static let syncRange = -10_000...10_000
    /// `player.subtitle_sync_ms` may be a profile value from this contract revision.
    static let profileSyncRevision = 19
    /// `textOpacity` joined the appearance object in this revision; an older server rejects it.
    static let textOpacityRevision = 14

    static let titles = [deviceOnlyID: "Subtitle appearance: this device only",
                         appearanceID: "Subtitle appearance", syncID: "Subtitle sync offset"]

    /// The contract defaults. A record is always stored complete, so a value the server filled in
    /// and a value the person chose read back the same.
    static let defaults: [String: BackupValue] = [
        "fontSize": .string("large"), "fontFamily": .string("sans-serif"),
        "fontColor": .string("#ffffff"), "backgroundColor": .string("#000000"),
        "backgroundStyle": .string("box"), "backgroundOpacity": .int(75), "textOpacity": .int(100),
        "textOutline": .bool(false), "textOutlineColor": .string("#000000"), "position": .string("bottom"),
    ]
    /// Pinned to the `Subtitle*Preset` enums by a test.
    static let fontSizes = ["small", "medium", "large", "xlarge", "xxlarge"]
    static let backgroundStyles = ["box", "shadow", "outline", "none"]
    static let positions = ["bottom", "lower-third", "top"]

    // MARK: Validation

    private static func hex(_ raw: String) -> String? {
        let body = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard body.count == 6, body.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { return nil }
        return "#" + body.lowercased()
    }

    private static func family(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 40, trimmed.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 45 || $0 == 95 || $0 == 32 }) else { return nil }
        return trimmed
    }

    /// A complete, canonical record, or nil when any member is unknown or out of range.
    static func normalized(_ members: [String: BackupValue]) -> [String: BackupValue]? {
        var result = defaults
        for (name, value) in members {
            guard defaults[name] != nil else { return nil }
            switch (name, value) {
            case ("fontSize", .string(let raw)) where fontSizes.contains(raw): result[name] = value
            case ("backgroundStyle", .string(let raw)) where backgroundStyles.contains(raw): result[name] = value
            case ("position", .string(let raw)) where positions.contains(raw): result[name] = value
            case ("fontFamily", .string(let raw)):
                guard let clean = family(raw) else { return nil }
                result[name] = .string(clean)
            case ("fontColor", .string(let raw)), ("backgroundColor", .string(let raw)),
                 ("textOutlineColor", .string(let raw)):
                guard let clean = hex(raw) else { return nil }
                result[name] = .string(clean)
            case ("backgroundOpacity", .int(let number)) where (0...100).contains(number): result[name] = value
            case ("textOpacity", .int(let number)) where (1...100).contains(number): result[name] = value
            case ("textOutline", .bool): result[name] = value
            default: return nil
            }
        }
        return result
    }

    /// A server value as a canonical record. Members this Kyro doesn't know make it untransferable.
    static func record(from json: SettingJSONValue) throws -> [String: BackupValue] {
        guard case .object(let fields) = json else { throw SettingsBackupRemoteError.unsupportedValue }
        var members: [String: BackupValue] = [:]
        for (name, field) in fields {
            switch field {
            case .bool(let flag): members[name] = .bool(flag)
            case .string(let text): members[name] = .string(text)
            default:
                guard let number = field.intValue else { throw SettingsBackupRemoteError.unsupportedValue }
                members[name] = .int(number)
            }
        }
        guard let clean = normalized(members) else { throw SettingsBackupRemoteError.unsupportedValue }
        return clean
    }

    static func syncValue(from json: SettingJSONValue) throws -> BackupValue {
        guard let number = json.intValue, syncRange.contains(number) else {
            throw SettingsBackupRemoteError.unsupportedValue
        }
        return .int(number)
    }

    /// The write for one appearance row. A server older than revision 14 does not store the text
    /// opacity, so the member is dropped; `isStorable` already refused a non-default value.
    static func wire(_ value: BackupValue, revision: Int) -> SettingJSONValue? {
        switch value {
        case .int(let number): return .int(number)
        case .record(let members):
            var fields: [String: SettingJSONValue] = [:]
            for (name, member) in members {
                if name == "textOpacity" && revision < textOpacityRevision { continue }
                switch member {
                case .bool(let flag): fields[name] = .bool(flag)
                case .int(let number): fields[name] = .int(number)
                case .string(let text): fields[name] = .string(text)
                case .record, .array: return nil
                }
            }
            return .object(fields)
        default: return nil
        }
    }

    /// Whether this server can store `value` exactly.
    static func isStorable(_ value: BackupValue, revision: Int) -> Bool {
        guard case .record(let members) = value, revision < textOpacityRevision else { return true }
        return members["textOpacity"] == .int(100)
    }

    /// The incoming value of one item, validated and normalized; nil when it is not supported.
    static func validated(id: String, _ value: BackupValue, all: [String: BackupValue]) -> BackupValue? {
        switch (id, value) {
        case (deviceOnlyID, .bool(let on)):
            // A device-only appearance is a device row, which must carry its appearance.
            if on, all[appearanceID] == .string(RemoteBackupDefinition.inherited) { return nil }
            return value
        case (appearanceID, .string(RemoteBackupDefinition.inherited)):
            return all[deviceOnlyID] == .bool(true) ? nil : value
        case (appearanceID, .record(let members)): return normalized(members).map(BackupValue.record)
        case (syncID, .string(RemoteBackupDefinition.inherited)): return value
        case (syncID, .int(let number)): return syncRange.contains(number) ? value : nil
        default: return nil
        }
    }

    // MARK: Observation

    private enum Winner { case device, profile, none }

    private static func winner(_ row: EffectiveSettingValue) throws -> Winner {
        guard let scope = row.scope else { return .none }
        if scope == .profileDevice { return .device }
        if scope == .profile { return .profile }
        if scope == .account { return .none }
        // A client, library or series row decides here; it is not this profile's or device's row.
        throw SettingsBackupRemoteError.overridden
    }

    static func observeAppearance(_ row: EffectiveSettingValue, into result: inout SubtitleObserved) throws {
        guard row.key == appearanceKey.rawValue else { throw SettingsBackupRemoteError.unsupportedValue }
        let place = try winner(row)
        result.visibleAppearance = (try? record(from: row.value)) ?? defaults
        guard place != .none else { return }
        let stored = BackupValue.record(try record(from: row.storedValue ?? row.value))
        if place == .device { result.appearanceDevice = stored; result.appearanceProfileHidden = true }
        else { result.appearanceProfile = stored }
    }

    static func observeSync(_ row: EffectiveSettingValue, into result: inout SubtitleObserved) throws {
        guard row.key == syncKey.rawValue else { throw SettingsBackupRemoteError.unsupportedValue }
        let place = try winner(row)
        guard place != .none else { return }
        let stored = try syncValue(from: row.storedValue ?? row.value)
        if place == .device { result.syncDevice = stored; result.syncProfileHidden = true }
        else { result.syncProfile = stored }
    }

    static func observe(_ rows: [SettingKey: EffectiveSettingValue]) throws -> SubtitleObserved {
        guard let appearance = rows[appearanceKey], let sync = rows[syncKey] else {
            throw SettingsBackupRemoteError.unsupportedValue
        }
        var result = SubtitleObserved()
        try observeAppearance(appearance, into: &result)
        try observeSync(sync, into: &result)
        return result
    }

    // MARK: Backup values

    static func backupValues(_ observed: SubtitleObserved) -> (deviceOnly: BackupValue, appearance: BackupValue, sync: BackupValue) {
        (.bool(observed.isDeviceOnly),
         observed.appearanceDevice ?? observed.appearanceProfile ?? .string(RemoteBackupDefinition.inherited),
         observed.syncDevice ?? observed.syncProfile ?? .string(RemoteBackupDefinition.inherited))
    }

    /// Items the server's rows can supply. A row that can't be transferred safely is left out of the
    /// export with its reason instead of failing the whole backup.
    static func export(from rows: [SettingKey: EffectiveSettingValue]) -> (values: [String: BackupValue], omitted: [String]) {
        var values: [String: BackupValue] = [:]
        var omitted: [String] = []
        var observed = SubtitleObserved()
        func note(_ ids: [String], _ error: Error) {
            let why = (error as? SettingsBackupRemoteError) == .overridden
                ? "hidden by a library or series override" : "its stored value can't be transferred safely"
            omitted += ids.map { "\(titles[$0] ?? $0) (\(why))" }
        }
        if let row = rows[appearanceKey] {
            do {
                try observeAppearance(row, into: &observed)
                let current = backupValues(observed)
                values[deviceOnlyID] = current.deviceOnly
                values[appearanceID] = current.appearance
            } catch { note([deviceOnlyID, appearanceID], error) }
        } else { omitted += [deviceOnlyID, appearanceID].map { "\(titles[$0]!) (this server doesn't support it)" } }
        if let row = rows[syncKey] {
            do {
                try observeSync(row, into: &observed)
                values[syncID] = backupValues(observed).sync
            } catch { note([syncID], error) }
        } else { omitted.append("\(titles[syncID]!) (this server doesn't support it)") }
        return (values, omitted)
    }

    // MARK: Preview

    static func label(id: String, _ value: BackupValue) -> String {
        switch value {
        case .string(RemoteBackupDefinition.inherited): return "Use inherited setting"
        case .bool(let on): return on ? "On" : "Off"
        case .int(let number): return number == 0 ? "0 ms" : "\(number > 0 ? "+" : "")\(number) ms"
        case .record(let members):
            func text(_ name: String) -> String { if case .string(let raw)? = members[name] { raw } else { "" } }
            func number(_ name: String) -> Int { if case .int(let raw)? = members[name] { raw } else { 0 } }
            let outline = members["textOutline"] == .bool(true) ? "outline" : "no outline"
            return "\(text("fontSize")) \(text("fontFamily")), \(text("fontColor")) at \(number("textOpacity"))%, "
                + "\(text("backgroundStyle")) \(number("backgroundOpacity"))% on \(text("backgroundColor")), "
                + "\(outline) \(text("textOutlineColor")), \(text("position"))"
        default: return value.plainText
        }
    }

    static func previewItem(id: String, incoming: BackupValue, siblings: [String: BackupValue],
                            rows: [SettingKey: EffectiveSettingValue]?, reason: String?,
                            revision: Int) -> RestorePreviewItem {
        func item(_ current: BackupValue?, _ status: RestoreItemStatus, _ shown: BackupValue) -> RestorePreviewItem {
            RestorePreviewItem(id: id, group: .subtitles, title: titles[id] ?? id,
                               current: current.map { label(id: id, $0) }, incoming: label(id: id, shown),
                               status: status, incomingValue: incoming)
        }
        guard let clean = validated(id: id, incoming, all: siblings) else {
            return item(nil, .invalid("This value is not supported."), incoming)
        }
        if let reason { return item(nil, .unsupported(reason), clean) }
        guard let rows else { return item(nil, .unsupported("Kyro could not read the authoritative value."), clean) }
        if !isStorable(clean, revision: revision) {
            return item(nil, .unsupported("This server is too old to store the saved text opacity."), clean)
        }
        var observed = SubtitleObserved()
        do {
            if id == syncID {
                guard let row = rows[syncKey] else { throw SettingsBackupRemoteError.unsupportedValue }
                try observeSync(row, into: &observed)
            } else {
                guard let row = rows[appearanceKey] else { throw SettingsBackupRemoteError.unsupportedValue }
                try observeAppearance(row, into: &observed)
            }
        } catch {
            return item(nil, .unsupported(error.localizedDescription), clean)
        }
        let current = backupValues(observed)
        let existing = id == deviceOnlyID ? current.deviceOnly : id == appearanceID ? current.appearance : current.sync
        return item(existing, existing == clean ? .unchanged : .willChange, clean)
    }
}

extension SettingsBackupRemoteAdapter {
    private struct CompositeMutation {
        let id: String
        let key: SettingKey
        let scope: SettingScopeIdentity
        let previousRow: BackupValue?
        let appliedRow: BackupValue?
        let previousEffective: BackupValue
        let previousEffectiveScope: String?
        let appliedEffective: BackupValue
    }

    private func compositePreviewItem(id: String, incoming: IncomingBackup,
                                      rows: [SettingKey: EffectiveSettingValue]?, reason: String?,
                                      revision: Int) -> RestorePreviewItem {
        let group: SettingsBackupGroup = id == ScopedCompositeBackup.cellularID ? .streaming : .interface
        let value = incoming.groups[group.rawValue]?[id] ?? .string("invalid")
        let rowSnapshot = try? compositeSnapshot(id: id, rows: rows ?? [:])
        var status: RestoreItemStatus
        var reasonText = reason
        if rowSnapshot == nil, reasonText == nil { reasonText = "The authoritative value is unavailable or not safely comparable." }
        if id == ScopedCompositeBackup.cellularID, revision < ScopedCompositeBackup.revision {
            reasonText = "This server does not support cellular quality settings."
        } else if id == ScopedCompositeBackup.titleArtID, revision < SettingKey.uiTitleArt.introducedIn {
            reasonText = "This server does not support title artwork settings."
        }
        if reasonText == nil, let current = rowSnapshot,
           let safe = compositeCanApply(id: id, desired: value, current: current) {
            status = current == value ? .unchanged : (safe ? .willChange : .unsupported(compositeScopeReason(id: id)))
        } else if reasonText == nil {
            status = .invalid("This value or scope is not supported.")
        } else {
            status = .unsupported(reasonText!)
        }
        let title = id == ScopedCompositeBackup.cellularID ? "Cellular streaming quality" : "Title artwork preference"
        return RestorePreviewItem(id: id, group: group, title: title,
                                  current: rowSnapshot.map { ScopedCompositeBackup.label(id, $0) },
                                  incoming: ScopedCompositeBackup.label(id, value), status: status,
                                  incomingValue: value)
    }

    private func compositeSnapshot(id: String, rows: [SettingKey: EffectiveSettingValue]) throws -> BackupValue {
        if id == ScopedCompositeBackup.cellularID { return try ScopedCompositeBackup.cellular(rows) }
        return try ScopedCompositeBackup.titleArt(rows)
    }

    /// A scope transition is safe only when the effective API proves that writing the target row
    /// won't destroy an unread hidden row. The API exposes only the winning row, not raw scoped rows.
    private func compositeCanApply(id: String, desired: BackupValue, current: BackupValue) -> Bool? {
        guard let wantedScope = ScopedCompositeBackup.scope(desired, id: id),
              let currentScope = ScopedCompositeBackup.scope(current, id: id) else { return nil }
        if wantedScope == "default" { return currentScope == "default" }
        if id == ScopedCompositeBackup.cellularID {
            // Device rows have higher precedence. A profile restore cannot safely replace a
            // currently visible device pair because the profile pair beneath it is unreadable.
            if wantedScope == "profile", currentScope == "profile_device" { return false }
            return true
        }
        // Title art resolves profile before device. Moving a profile-owned value down to device
        // would require clearing a visible profile row while preserving an unread device row.
        if wantedScope == "profile_device", currentScope == "profile" { return false }
        return true
    }

    private func compositeScopeReason(id: String) -> String {
        id == ScopedCompositeBackup.cellularID
            ? "A hidden profile value can't be read safely while a device override is active."
            : "A hidden device value can't be read safely while the profile-wide title-art value is active."
    }

    private func compositeMutations(id: String, desired: BackupValue,
                                    rows: [SettingKey: EffectiveSettingValue]) throws -> [CompositeMutation]? {
        let current = try compositeSnapshot(id: id, rows: rows)
        guard let targetScope = ScopedCompositeBackup.scope(desired, id: id),
              let canApply = compositeCanApply(id: id, desired: desired, current: current), canApply else { return nil }
        if targetScope == "default" { return [] }
        let identity: SettingScopeIdentity = targetScope == "profile" ? .profile : .profileDevice
        let keys: [(SettingKey, BackupValue)]
        if id == ScopedCompositeBackup.cellularID {
            guard let fields = ScopedCompositeBackup.cellularFields(desired) else { throw SettingsBackupRemoteError.unsupportedValue }
            let cap: BackupValue = fields.bitrate
            keys = [(.playbackCellularPreferredQuality, fields.resolution), (.playbackCellularMaxBitrateKbps, cap)]
        } else {
            guard let fields = ScopedCompositeBackup.titleArtFields(desired) else { throw SettingsBackupRemoteError.unsupportedValue }
            keys = [(ScopedCompositeBackup.titleArtKey, fields.enabled)]
        }
        var mutations: [CompositeMutation] = []
        for (key, value) in keys {
            guard let row = rows[key], let previousEffective = compositeRowValue(row) else {
                throw SettingsBackupRemoteError.unsupportedValue
            }
            let previousRow = row.scope?.rawValue == targetScope ? previousEffective : nil
            if previousRow == value { continue }
            mutations.append(CompositeMutation(id: id, key: key, scope: identity,
                previousRow: previousRow, appliedRow: value, previousEffective: previousEffective,
                previousEffectiveScope: row.scope?.rawValue, appliedEffective: value))
        }
        return mutations
    }

    private func compositeRowValue(_ row: EffectiveSettingValue) -> BackupValue? {
        switch row.storedValue ?? row.value {
        case .bool(let value): .bool(value)
        case .int(let value): .int(value)
        case .string(let value): .string(value)
        case .null: .string(RemoteBackupDefinition.null)
        default: nil
        }
    }

    private func wire(_ value: BackupValue?) -> SettingJSONValue? {
        guard let value else { return nil }
        if value == .string(RemoteBackupDefinition.null) { return .null }
        switch value {
        case .bool(let flag): return SettingJSONValue.bool(flag)
        case .int(let number): return SettingJSONValue.int(number)
        case .string(let text): return SettingJSONValue.string(text)
        case .record, .array: return nil
        }
    }

    private func applyComposites(_ incoming: IncomingBackup, selected: Set<String>, owner: SettingsBackupRemoteOwner,
                                 record: inout RemoteBackupJournal, journalSaved: inout Bool,
                                 report: inout RemoteBackupApplyReport) async {
        for id in [ScopedCompositeBackup.cellularID, ScopedCompositeBackup.titleArtID] where selected.contains(id) {
            let group: SettingsBackupGroup = id == ScopedCompositeBackup.cellularID ? .streaming : .interface
            guard let desired = incoming.groups[group.rawValue]?[id],
                  id == ScopedCompositeBackup.cellularID ? ScopedCompositeBackup.cellularFields(desired) != nil
                    : ScopedCompositeBackup.titleArtFields(desired) != nil else {
                report.skipped.append(id); continue
            }
            do {
                let revision = try await timed { try await self.transport.manifestRevision(owner: owner) }
                if (id == ScopedCompositeBackup.cellularID && revision < ScopedCompositeBackup.revision)
                    || (id == ScopedCompositeBackup.titleArtID && revision < SettingKey.uiTitleArt.introducedIn) {
                    report.skipped.append(id); continue
                }
                let currentRows = try await read(owner)
                guard let mutations = try compositeMutations(id: id, desired: desired, rows: currentRows) else {
                    report.skipped.append(id); continue
                }
                guard !mutations.isEmpty else { continue }
                var changed = false
                for mutation in mutations {
                    record.rowSteps = (record.rowSteps ?? []) + [ScopedBackupRowStep(
                        item: id, key: mutation.key.rawValue, scope: mutation.scope.scope.rawValue,
                        previousRow: mutation.previousRow, appliedRow: mutation.appliedRow,
                        previousEffective: mutation.previousEffective,
                        previousEffectiveScope: mutation.previousEffectiveScope,
                        appliedEffective: mutation.appliedEffective)]
                    try journal.save(record); journalSaved = true
                    try Task.checkCancellation()
                    guard let wireValue = wire(mutation.appliedRow) else { throw SettingsBackupRemoteError.unsupportedValue }
                    try await timed { try await self.transport.put(mutation.key, scope: mutation.scope, value: wireValue, owner: owner) }
                    let confirmed = try await read(owner)
                    guard let row = confirmed[mutation.key], row.scope?.rawValue == mutation.scope.scope.rawValue,
                          compositeRowValue(row) == mutation.appliedEffective else {
                        throw SettingsBackupRemoteError.unconfirmedWrite
                    }
                    changed = true
                }
                if changed { report.applied.append(id) }
            } catch {
                report.failed.append(id)
                break
            }
        }
    }

    private func undoCompositeRows(record: inout RemoteBackupJournal, owner: SettingsBackupRemoteOwner,
                                   report: inout RemoteBackupApplyReport) async {
        guard let steps = record.rowSteps, !steps.isEmpty else { return }
        var remaining: [ScopedBackupRowStep] = []
        for step in steps.reversed() {
            do {
                guard let key = SettingKey(rawValue: step.key) else { report.skipped.append(step.item); continue }
                if InterfaceRecordBackup.keys.contains(key) {
                    if try await undoInterfaceStep(step, owner: owner) {
                        if !report.applied.contains(step.item) { report.applied.append(step.item) }
                    } else { report.skipped.append(step.item); remaining.append(step) }
                    continue
                }
                let scope: SettingScopeIdentity = step.scope == "profile" ? .profile
                    : step.scope == "profile_client" ? .profileClient : .profileDevice
                let rows = try await read(owner)
                guard let current = rows[key], current.scope?.rawValue == step.scope,
                      compositeRowValue(current) == step.appliedEffective else {
                    report.skipped.append(step.item); continue
                }
                if let prior = step.previousRow, let value = wire(prior) {
                    try await timed { try await self.transport.put(key, scope: scope, value: value, owner: owner) }
                } else {
                    try await timed { try await self.transport.delete(key, scope: scope, owner: owner) }
                }
                let restored = try await read(owner)[key]
                guard restored?.scope?.rawValue == step.previousEffectiveScope,
                      restored.flatMap(compositeRowValue) == step.previousEffective else {
                    throw SettingsBackupRemoteError.unconfirmedWrite
                }
                if !report.applied.contains(step.item) { report.applied.append(step.item) }
            } catch {
                report.failed.append(step.item); remaining.append(step)
            }
        }
        record.rowSteps = remaining.reversed()
    }

    private func subtitleRows(_ owner: SettingsBackupRemoteOwner) async throws -> SubtitleObserved {
        try SubtitleDisplayBackup.observe(try await read(owner))
    }

    private func writeSubtitleSlot(_ slot: SubtitleRowSlot, value: BackupValue?, owner: SettingsBackupRemoteOwner,
                                   revision: Int) async throws {
        let currentOwner = try await timed { try await self.transport.owner() }
        guard currentOwner.scope == owner.scope, currentOwner.request == owner.request else {
            throw SettingsBackupRemoteError.changedOwner
        }
        let key: SettingKey = (slot == .appearanceDevice || slot == .appearanceProfile)
            ? SubtitleDisplayBackup.appearanceKey : SubtitleDisplayBackup.syncKey
        let scope: SettingScopeIdentity = (slot == .appearanceDevice || slot == .syncDevice) ? .profileDevice : .profile
        if let value {
            guard let wire = SubtitleDisplayBackup.wire(value, revision: revision) else {
                throw SettingsBackupRemoteError.unsupportedValue
            }
            try await timed { try await self.transport.put(key, scope: scope, value: wire, owner: owner) }
        } else {
            try await timed { try await self.transport.delete(key, scope: scope, owner: owner) }
        }
    }

    /// Restores the selected subtitle items in a fixed order: the scope switch, then the appearance
    /// at the resulting scope, then the offset. Every row write is journalled first and confirmed by
    /// a fresh read; the first failure stops the sequence, and the remaining items are reported as
    /// skipped. Rows the backup doesn't concern are never written.
    fileprivate func applySubtitleDisplay(
        _ incoming: IncomingBackup, selected: Set<String>, owner: SettingsBackupRemoteOwner,
        record: inout RemoteBackupJournal, journalSaved: inout Bool, report: inout RemoteBackupApplyReport
    ) async {
        let all = incoming.groups[SettingsBackupGroup.subtitles.rawValue] ?? [:]
        var wanted: [String: BackupValue] = [:]
        for id in SubtitleDisplayBackup.orderedIDs where selected.contains(id) {
            if let value = all[id], let clean = SubtitleDisplayBackup.validated(id: id, value, all: all) { wanted[id] = clean }
            else { report.skipped.append(id) }
        }
        guard !wanted.isEmpty else { return }
        var current = ""
        var changed: Set<String> = []
        do {
            let revision = try await timed { try await self.transport.manifestRevision(owner: owner) }
            for (id, value) in wanted where !SubtitleDisplayBackup.isStorable(value, revision: revision) {
                report.skipped.append(id); wanted[id] = nil
            }
            var observed = try await subtitleRows(owner)

            func perform(_ item: String, _ slot: SubtitleRowSlot, to value: BackupValue?) async throws {
                let step = SubtitleStep(item: item, slot: slot, previous: observed.slot(slot).value, applied: value)
                record.subtitleSteps = (record.subtitleSteps ?? []) + [step]
                try journal.save(record)
                journalSaved = true
                try Task.checkCancellation()
                try await writeSubtitleSlot(slot, value: value, owner: owner, revision: revision)
                observed = try await subtitleRows(owner)
                let after = observed.slot(slot)
                guard after.known, after.value == value else { throw SettingsBackupRemoteError.unconfirmedWrite }
                changed.insert(item)
            }

            var wantsDevice = observed.isDeviceOnly
            if let value = wanted[SubtitleDisplayBackup.deviceOnlyID], case .bool(let on) = value {
                current = SubtitleDisplayBackup.deviceOnlyID
                wantsDevice = on
                if on != observed.isDeviceOnly {
                    if on {
                        // Like the Settings switch: the device starts from what is on screen now.
                        let copy: BackupValue
                        let savedAppearance = wanted[SubtitleDisplayBackup.appearanceID]
                        if let saved = savedAppearance, saved.isRecord { copy = saved }
                        else { copy = .record(observed.visibleAppearance) }
                        try await perform(current, .appearanceDevice, to: copy)
                        // The device row now holds the saved appearance, so that item is restored too.
                        if savedAppearance == copy { changed.insert(SubtitleDisplayBackup.appearanceID) }
                    } else {
                        try await perform(current, .appearanceDevice, to: nil)
                    }
                }
            }
            if let value = wanted[SubtitleDisplayBackup.appearanceID] {
                current = SubtitleDisplayBackup.appearanceID
                if wantsDevice {
                    if value.isRecord {
                        if observed.appearanceDevice != value { try await perform(current, .appearanceDevice, to: value) }
                    } else { report.skipped.append(current) }   // a device row can't be "inherited"
                } else if value.isRecord {
                    if observed.appearanceProfile != value { try await perform(current, .appearanceProfile, to: value) }
                } else if observed.appearanceProfile != nil {
                    try await perform(current, .appearanceProfile, to: nil)
                }
            }
            if let value = wanted[SubtitleDisplayBackup.syncID] {
                current = SubtitleDisplayBackup.syncID
                let target: BackupValue? = value.isRecord || value == .string(RemoteBackupDefinition.inherited) ? nil : value
                if !wantsDevice && revision >= SubtitleDisplayBackup.profileSyncRevision {
                    // A leftover device offset would hide the profile's, so it goes first.
                    if observed.syncDevice != nil { try await perform(current, .syncDevice, to: nil) }
                    if observed.syncProfile != target { try await perform(current, .syncProfile, to: target) }
                } else if observed.syncDevice != target {
                    try await perform(current, .syncDevice, to: target)
                }
            }
            report.applied += SubtitleDisplayBackup.orderedIDs.filter { changed.contains($0) }
        } catch SettingsBackupRemoteError.overridden where current.isEmpty {
            // A library or series row hides the profile or device row: nothing was written.
            report.skipped += wanted.keys.sorted()
        } catch {
            // Items already confirmed stay applied (and journalled for Undo); the one in flight failed.
            report.applied += SubtitleDisplayBackup.orderedIDs.filter { changed.contains($0) && $0 != current }
            if current.isEmpty {
                report.failed += wanted.keys.sorted()
            } else {
                report.failed.append(current)
                let order = SubtitleDisplayBackup.orderedIDs
                if let at = order.firstIndex(of: current) {
                    report.skipped += order[(at + 1)...].filter { wanted[$0] != nil }
                }
            }
        }
    }

    /// Reverses journalled subtitle rows, newest first. A row someone changed since the restore is
    /// left alone; a row hidden by a device row can't be checked, so it is left alone too.
    fileprivate func undoSubtitleDisplay(
        record: inout RemoteBackupJournal, owner: SettingsBackupRemoteOwner, report: inout RemoteBackupApplyReport
    ) async {
        guard let steps = record.subtitleSteps, !steps.isEmpty else { return }
        var remaining: [SubtitleStep] = []
        var revision = Int.max
        revision = (try? await timed { try await self.transport.manifestRevision(owner: owner) }) ?? Int.max
        for step in steps.reversed() {
            do {
                let observed = try await subtitleRows(owner)
                let now = observed.slot(step.slot)
                guard now.known else { report.skipped.append(step.item); continue }
                if now.value == step.previous { continue }
                guard now.value == step.applied else { report.skipped.append(step.item); continue }
                try await writeSubtitleSlot(step.slot, value: step.previous, owner: owner, revision: revision)
                let after = try await subtitleRows(owner).slot(step.slot)
                guard after.known, after.value == step.previous else { throw SettingsBackupRemoteError.unconfirmedWrite }
                if !report.applied.contains(step.item) { report.applied.append(step.item) }
            } catch {
                report.failed.append(step.item)
                remaining.append(step)
            }
        }
        record.subtitleSteps = remaining.reversed()
    }
}
#endif
