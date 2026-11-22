#if os(iOS)
import XCTest
import UniformTypeIdentifiers
@testable import Silo

// Build 88: the real stores behind the backup registry, in an isolated defaults domain. These never
// read or write the app's own settings, the Keychain or the network.

@MainActor
private final class FakeLocalPlayback: LocalPlaybackPreferences {
    var bufferAhead: BufferAheadMode = .automatic
    var losslessAudioEnabled = false
    var backgroundPlaybackEnabled = false
    var deinterlaceMode: DeinterlacePreference = .automatic
    var deinterlaceFieldRate: DeinterlaceFieldRatePreference = .fullMotion
    var trueHDAtmosEnabled = true
    var subtitleMatchesSystemAppearance = false
}

@MainActor
final class SettingsBackupLiveRegistryTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults()
    private let app = SettingsBackupAppInfo(version: "1.0.0", build: "88", platform: "iOS", idiom: "phone")

    override func setUp() {
        super.setUp()
        suiteName = "kyro.settingsBackupTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private struct Rig {
        let registry: SettingsBackupRegistry
        let navigation: KyroGlobalNavigationStore
        let appNavigation: AppNavPreferences
        let liveTVNavigation: KyroLiveTVNavigationStore
        let launch: ProfileLaunchPreferences
        let downloads: DownloadSettings
        let playback: FakeLocalPlayback
    }

    private func makeRig(idiom: String = "phone", pip: Bool = true, watchPartyInitial: Bool = true) -> Rig {
        let navigation = KyroGlobalNavigationStore(defaults: defaults)
        let appNavigation = AppNavPreferences(
            defaults: SharedDefaults(suite: defaults, standard: defaults),
            storageKey: { "ios.nav.showAudiobooks.test" })
        let liveTVNavigation = KyroLiveTVNavigationStore(defaults: defaults)
        let launch = ProfileLaunchPreferences(defaults: SharedDefaults(suite: defaults, standard: defaults))
        let downloads = DownloadSettings(defaults: defaults)
        let playback = FakeLocalPlayback()
        var watchPartyEnabled = watchPartyInitial
        let registry = SettingsBackupLiveRegistry.make(.init(
            navigation: navigation, appNavigation: appNavigation,
            liveTVNavigation: liveTVNavigation, launch: launch,
            downloads: downloads, playback: playback,
            defaults: defaults, idiom: idiom, supportsPictureInPicture: pip,
            readWatchPartyEnabled: { watchPartyEnabled },
            writeWatchPartyEnabled: { watchPartyEnabled = $0 }))
        return Rig(registry: registry, navigation: navigation, appNavigation: appNavigation,
                   liveTVNavigation: liveTVNavigation,
                   launch: launch, downloads: downloads, playback: playback)
    }

    private func applyAll(_ data: Data, to rig: Rig, journal: RestoreJournalStoring = BackupMemoryJournal(),
                          groups: Set<SettingsBackupGroup> = Set(SettingsBackupGroup.allCases)) throws -> RestoreOutcome {
        let preview = SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(data), registry: rig.registry)
        return SettingsBackupApplier(registry: rig.registry, journal: journal).apply(preview: preview, selectedGroups: groups)
    }

    func testEverySettingIsOnTheExplicitLocalAllowlist() {
        let ids = Set(makeRig().registry.settings.map(\.id))
        XCTAssertEqual(ids, [
            "general.launchBehavior",
            "features.watchParty", "features.iptvVOD",
            "calendar.filter",
            "navigation.fourthTab", "navigation.showAudiobooks",
            "liveTV.categoryAppearance", "liveTV.categoryGrouping", "liveTV.guideStyle",
            "sports.dashboardMode.nfl", "sports.dashboardMode.nba", "sports.dashboardMode.collegeFootball",
            "sports.dashboardMode.mlb", "sports.dashboardMode.nhl", "sports.dashboardMode.atp",
            "sports.dashboardMode.wta", "sports.dashboardMode.soccer",
            "downloads.preferredFormat", "downloads.wifiOnly", "downloads.defaultDeleteWatched",
            "downloads.defaultMaxStorageGB", "downloads.sortOption", "downloads.keepWatched", "downloads.simultaneous",
            "playback.bufferAhead", "playback.losslessAudio", "pip.backgroundPlayback",
            "advancedAV.deinterlaceMode", "advancedAV.deinterlaceFieldRate", "advancedAV.trueHDAtmos",
            "subtitleDisplay.matchesSystem",
            "liveTVNav.style", "liveTVNav.startingEdge", "liveTVNav.idleBehavior", "liveTVNav.autoCollapse",
            "liveTVNav.haptics", "liveTVNav.thumbScrubbing", "liveTVNav.allowsDragging",
            "liveTVNav.destinationOrder", "liveTVNav.hiddenDestinations",
        ])
        for id in ids { XCTAssertFalse(SettingsBackupSafety.isSensitiveName(id), id) }
    }

    func testWatchPartyOptInRestoresExplicitOffAndOnAndCanUndo() throws {
        let rig = makeRig()
        let off = try SettingsBackupCodec.makeDocument(
            groups: ["features": ["features.watchParty": .bool(false)]],
            schemaVersion: 2, minReaderVersion: 1, app: app, now: Date())
        let preview = SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(off), registry: rig.registry)
        XCTAssertEqual(preview.groups.flatMap(\.items).map(\.id), ["features.watchParty"])
        let journal = BackupMemoryJournal()
        let applier = SettingsBackupApplier(registry: rig.registry, journal: journal)
        guard case .applied = applier.apply(preview: preview, selectedGroups: [.features]) else {
            return XCTFail("explicit off value was not applied")
        }
        let exportedOff = try SettingsBackupCodec.decode(SettingsBackupExporter.export(
            registry: rig.registry, groups: [.features], app: app))
        XCTAssertEqual(exportedOff.groups["features"]?["features.watchParty"], .bool(false))
        let undo = applier.undo()
        XCTAssertEqual(undo.reverted, ["features.watchParty"])

        let on = try SettingsBackupCodec.makeDocument(
            groups: ["features": ["features.watchParty": .bool(true)]],
            schemaVersion: 2, minReaderVersion: 1, app: app, now: Date())
        let offRig = makeRig(watchPartyInitial: false)
        guard case .applied = try applyAll(on, to: offRig, groups: [.features]) else {
            return XCTFail("on value was not applied")
        }
        let exportedOn = try SettingsBackupCodec.decode(SettingsBackupExporter.export(
            registry: offRig.registry, groups: [.features], app: app))
        XCTAssertEqual(exportedOn.groups["features"]?["features.watchParty"], .bool(true))
    }

    func testIPTVVODOptInBackupPreviewRestoreAndUndo() throws {
        let rig = makeRig()
        XCTAssertFalse(IPTVVODPreference.isEnabled(in: defaults))
        let data = try SettingsBackupCodec.makeDocument(
            groups: ["features": ["features.iptvVOD": .bool(true)]],
            schemaVersion: 2, minReaderVersion: 1, app: app, now: Date())
        let preview = SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(data), registry: rig.registry)
        XCTAssertEqual(preview.groups.flatMap(\.items).map(\.id), ["features.iptvVOD"])
        let applier = SettingsBackupApplier(registry: rig.registry, journal: BackupMemoryJournal())
        guard case .applied = applier.apply(preview: preview, selectedGroups: [.features]) else {
            return XCTFail("IPTV VOD opt-in was not restored")
        }
        XCTAssertTrue(IPTVVODPreference.isEnabled(in: defaults))
        let exported = try SettingsBackupCodec.decode(SettingsBackupExporter.export(
            registry: rig.registry, groups: [.features], app: app))
        XCTAssertEqual(exported.groups["features"]?["features.iptvVOD"], .bool(true))
        XCTAssertEqual(applier.undo().reverted, ["features.iptvVOD"])
        XCTAssertFalse(IPTVVODPreference.isEnabled(in: defaults))
    }

    func testPersistedLiveTVNavigationFieldsCannotOutgrowTheBackupRegistrySilently() {
        let mapping = [
            "style": "liveTVNav.style", "order": "liveTVNav.destinationOrder",
            "hidden": "liveTVNav.hiddenDestinations", "autoCollapse": "liveTVNav.autoCollapse",
            "idleBehavior": "liveTVNav.idleBehavior", "hapticsEnabled": "liveTVNav.haptics",
            "thumbScrubbing": "liveTVNav.thumbScrubbing", "allowsDragging": "liveTVNav.allowsDragging",
            "startingEdge": "liveTVNav.startingEdge",
        ]
        let ownerFields = KyroLiveTVNavigationPreferences.backupEligibleStoredFields
        XCTAssertEqual(ownerFields, Set(mapping.keys), "Classify each new persisted navigation field")
        let ids = Set(makeRig().registry.settings.map(\.id).filter { $0.hasPrefix("liveTVNav.") })
        XCTAssertEqual(ids, Set(mapping.values))
    }

    func testEveryRegisteredLocalPreferenceExportsComparesRestoresAndUndoes() throws {
        let registry = makeRig().registry
        let alternatives: [String: BackupValue] = [
            "general.launchBehavior": .string("afterOneHour"),
            "features.watchParty": .bool(false),
            "features.iptvVOD": .bool(true),
            "calendar.filter": .string("trending"),
            "navigation.fourthTab": .string("favorites"),
            "navigation.showAudiobooks": .bool(true),
            "liveTV.categoryAppearance": .string("Grid"),
            "liveTV.categoryGrouping": .string("Grouped"),
            "liveTV.guideStyle": .string("grid"),
            "downloads.preferredFormat": .string("5mbps"),
            "downloads.wifiOnly": .bool(false),
            "downloads.defaultDeleteWatched": .bool(true),
            "downloads.defaultMaxStorageGB": .int(50),
            "downloads.sortOption": .string("alphabetical"),
            "downloads.keepWatched": .bool(true),
            "downloads.simultaneous": .int(4),
            "playback.bufferAhead": .string("extended"),
            "playback.losslessAudio": .bool(true),
            "pip.backgroundPlayback": .bool(true),
            "advancedAV.deinterlaceMode": .string("software"),
            "advancedAV.deinterlaceFieldRate": .string("frame"),
            "advancedAV.trueHDAtmos": .bool(false),
            "subtitleDisplay.matchesSystem": .bool(true),
            "liveTVNav.style": .string("glassDock"),
            "liveTVNav.startingEdge": .string("left"),
            "liveTVNav.idleBehavior": .string("stayVisible"),
            "liveTVNav.autoCollapse": .bool(false),
            "liveTVNav.haptics": .bool(false),
            "liveTVNav.thumbScrubbing": .bool(false),
            "liveTVNav.allowsDragging": .bool(false),
            "liveTVNav.destinationOrder": .string("guide,home,favorites,channels,search"),
            "liveTVNav.hiddenDestinations": .string("search"),
        ]
        XCTAssertEqual(Set(registry.settings.map(\.id)), Set(alternatives.keys))
        for setting in registry.settings {
            let original = try XCTUnwrap(setting.read(), setting.id)
            let changed = try XCTUnwrap(alternatives[setting.id])
            XCTAssertNotEqual(original, changed, setting.id)
            try setting.write(changed)
            let saved = try SettingsBackupExporter.export(registry: registry, groups: [setting.group], app: app)
            XCTAssertEqual(try SettingsBackupCodec.decode(saved).groups[setting.group.rawValue]?[setting.id], changed, setting.id)
            try setting.write(original)
            let preview = SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(saved), registry: registry)
            XCTAssertEqual(preview.groups.flatMap(\.items).first { $0.id == setting.id }?.status, .willChange, setting.id)
            let applier = SettingsBackupApplier(registry: registry, journal: BackupMemoryJournal())
            guard case .applied = applier.apply(preview: preview, selectedGroups: [setting.group],
                                                selectedIDs: [setting.id]) else { return XCTFail(setting.id) }
            XCTAssertEqual(setting.read(), changed, setting.id)
            XCTAssertEqual(applier.undo().reverted, [setting.id], setting.id)
            XCTAssertEqual(setting.read(), original, setting.id)
        }
    }

    func testRoundTripThroughRealStores() throws {
        let source = makeRig()
        source.navigation.preferences.fourthTab = .favorites
        source.appNavigation.setShowAudiobooks(true)
        source.liveTVNavigation.preferences.style = .glassDock
        source.launch.behavior = .afterOneHour
        source.downloads.wifiOnly = false
        source.downloads.simultaneousDownloads = 4
        source.downloads.defaultMaxStorageGB = 50
        source.downloads.sortOption = .alphabetical
        source.playback.bufferAhead = .extended
        defaults.set(LiveTVEmbeddedGuideStyle.grid.rawValue, forKey: LiveTVEmbeddedGuideStyle.defaultsKey)
        var categories = LiveTVCategoryPreferences()
        categories.appearance = .grid
        categories.grouping = .grouped
        categories.save(providerID: nil, to: defaults)

        let data = try SettingsBackupExporter.export(
            registry: source.registry, groups: Set(SettingsBackupGroup.allCases), app: app)

        let freshDefaults = UserDefaults(suiteName: suiteName + ".destination")!
        defer { freshDefaults.removePersistentDomain(forName: suiteName + ".destination") }
        let navigation = KyroGlobalNavigationStore(defaults: freshDefaults)
        let appNavigation = AppNavPreferences(
            defaults: SharedDefaults(suite: freshDefaults, standard: freshDefaults),
            storageKey: { "ios.nav.showAudiobooks.test" })
        let liveTVNavigation = KyroLiveTVNavigationStore(defaults: freshDefaults)
        let launch = ProfileLaunchPreferences(defaults: SharedDefaults(suite: freshDefaults, standard: freshDefaults))
        let downloads = DownloadSettings(defaults: freshDefaults)
        let playback = FakeLocalPlayback()
        let destination = Rig(
            registry: SettingsBackupLiveRegistry.make(.init(
                navigation: navigation, appNavigation: appNavigation,
                liveTVNavigation: liveTVNavigation, launch: launch,
                downloads: downloads, playback: playback,
                defaults: freshDefaults, idiom: "phone", supportsPictureInPicture: true)),
            navigation: navigation, appNavigation: appNavigation,
            liveTVNavigation: liveTVNavigation, launch: launch,
            downloads: downloads, playback: playback)

        guard case .applied = try applyAll(data, to: destination) else { return XCTFail("not applied") }
        XCTAssertEqual(navigation.preferences.fourthTab, .favorites)
        XCTAssertTrue(appNavigation.showAudiobooks)
        XCTAssertEqual(liveTVNavigation.preferences.style, .glassDock)
        XCTAssertEqual(launch.behavior, .afterOneHour)
        XCTAssertFalse(downloads.wifiOnly)
        XCTAssertEqual(downloads.simultaneousDownloads, 4)
        XCTAssertEqual(downloads.defaultMaxStorageGB, 50)
        XCTAssertEqual(downloads.sortOption, .alphabetical)
        XCTAssertEqual(playback.bufferAhead, .extended)
        XCTAssertNil(freshDefaults.object(forKey: KyroSportsSupplementFlag.tennisNewsKey))
        XCTAssertEqual(freshDefaults.string(forKey: LiveTVEmbeddedGuideStyle.defaultsKey), "grid")
        let loaded = LiveTVCategoryPreferences.load(providerID: nil, from: freshDefaults)
        XCTAssertEqual(loaded.appearance, .grid)
        XCTAssertEqual(loaded.grouping, .grouped)
    }

    func testRestoreLeavesProviderDataAndTransientLiveTVStateAlone() throws {
        let providerID = UUID()
        var scoped = LiveTVCategoryPreferences()
        scoped.pinned = ["Sports"]
        scoped.hidden = ["Adult"]
        scoped.recent = ["News"]
        scoped.save(providerID: providerID, to: defaults)
        defaults.set(Data("providers".utf8), forKey: "liveTV.providers.v1")
        defaults.set(["channel-1"], forKey: "liveTV.favorites.v1")
        defaults.set("nfl", forKey: "kyro.sports.selectedLeague")
        let before = defaults.dictionaryRepresentation()
        let providerKey = "\(LiveTVCategoryPreferences.key).provider.\(providerID.uuidString)"

        let rig = makeRig()
        let incomingBackup = try SettingsBackupCodec.makeDocument(
            groups: ["liveTVCategories": ["liveTV.categoryAppearance": .string("Grid"), "liveTV.categoryGrouping": .string("Grouped")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        guard case .applied = try applyAll(incomingBackup, to: rig) else { return XCTFail("not applied") }

        let after = defaults.dictionaryRepresentation()
        XCTAssertEqual(after[providerKey] as? Data, before[providerKey] as? Data)
        XCTAssertEqual(after["liveTV.providers.v1"] as? Data, Data("providers".utf8))
        XCTAssertEqual(after["liveTV.favorites.v1"] as? [String], ["channel-1"])
        XCTAssertEqual(after["kyro.sports.selectedLeague"] as? String, "nfl")
        XCTAssertEqual(LiveTVCategoryPreferences.load(providerID: providerID, from: defaults).pinned, ["Sports"])
    }

    func testBackupDoesNotContainLiveTVProvidersCredentialsOrServerState() throws {
        defaults.set("https://example.invalid/playlist.m3u", forKey: "serverUrl")
        defaults.set("profile-1", forKey: "profileId")
        defaults.set(Data("providers".utf8), forKey: "liveTV.providers.v1")
        let data = try SettingsBackupExporter.export(
            registry: makeRig().registry, groups: Set(SettingsBackupGroup.allCases), app: app)
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["example.invalid", "profile-1", "providers", "serverUrl", "m3u"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    func testRestoreWritesNoServerSyncedPlayerKeys() throws {
        // Server-synced player choices stay out. The one allowed subtitle id is the device
        // caption-matching toggle, which writes local player state and does not enqueue a server write.
        let ids = makeRig().registry.settings.map(\.id)
        XCTAssertEqual(ids.filter { $0.lowercased().contains("subtitle") }, ["subtitleDisplay.matchesSystem"])
        for forbidden in ["quality", "speed", "orientation", "gravity", "hdr", "audioLanguage", "introSkip", "subtitleLanguage", "subtitleMode", "subtitleAppearance"] {
            XCTAssertFalse(ids.contains { $0.lowercased().contains(forbidden.lowercased()) }, forbidden)
        }
    }

    func testPictureInPictureSettingIsSkippedWhenUnsupported() throws {
        let source = makeRig()
        source.playback.backgroundPlaybackEnabled = true
        let data = try SettingsBackupExporter.export(registry: source.registry, groups: [.pictureInPicture], app: app)
        let destination = makeRig(pip: false)
        let preview = SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(data), registry: destination.registry)
        XCTAssertEqual(preview.totalChanges, 0)
    }

    func testDefaultExportIncludesSafeDeviceSpecificGroups() throws {
        let rig = makeRig()
        rig.playback.bufferAhead = .unlimited
        let data = try SettingsBackupExporter.export(registry: rig.registry, groups: SettingsBackupGroup.defaultSelection, app: app)
        XCTAssertNotNil(try SettingsBackupCodec.decode(data).groups["playbackOptions"])
        XCTAssertNotNil(try SettingsBackupCodec.decode(data).groups["navigationLayout"])
        XCTAssertEqual(try SettingsBackupCodec.decode(data).groups["sports"]?.count,
                       KyroSportLeague.allCases.count)
    }

    func testSportsModesRoundTripAutomaticSelectiveRestoreAndUndo() throws {
        let rig = makeRig()
        for (index, league) in KyroSportLeague.allCases.enumerated() {
            let mode = KyroSportsDashboardMode.allCases[index % KyroSportsDashboardMode.allCases.count]
            defaults.set(mode.rawValue, forKey: KyroSportsHubStore.modeKey(league))
        }
        let saved = try SettingsBackupExporter.export(registry: rig.registry, groups: [.sports], app: app)
        let incoming = try SettingsBackupCodec.decode(saved)
        XCTAssertEqual(incoming.groups["sports"]?.count, KyroSportLeague.allCases.count)
        for league in KyroSportLeague.allCases {
            defaults.removeObject(forKey: KyroSportsHubStore.modeKey(league))
        }
        let preview = SettingsBackupPlanner.preview(incoming, registry: rig.registry)
        XCTAssertEqual(preview.totalChanges, KyroSportLeague.allCases.count)
        let journal = BackupMemoryJournal()
        let applier = SettingsBackupApplier(registry: rig.registry, journal: journal)
        guard case .applied = applier.apply(preview: preview, selectedGroups: [.sports]) else {
            return XCTFail("Sports modes were not restored")
        }
        for league in KyroSportLeague.allCases {
            XCTAssertEqual(defaults.string(forKey: KyroSportsHubStore.modeKey(league)),
                           incoming.groups["sports"]?["sports.dashboardMode.\(league.rawValue)"]?.plainText)
        }
        XCTAssertEqual(applier.undo().reverted.count, KyroSportLeague.allCases.count)
        for league in KyroSportLeague.allCases {
            XCTAssertNil(defaults.object(forKey: KyroSportsHubStore.modeKey(league)))
        }

        let nflKey = KyroSportsHubStore.modeKey(.nfl)
        let automatic = try SettingsBackupCodec.makeDocument(
            groups: ["sports": ["sports.dashboardMode.nfl": .string("~automatic")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        defaults.set("results", forKey: nflKey)
        let autoPreview = SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(automatic), registry: rig.registry)
        guard case .applied = applier.apply(preview: autoPreview, selectedGroups: [.sports]) else {
            return XCTFail("Automatic mode was not restored")
        }
        XCTAssertNil(defaults.object(forKey: nflKey))
        XCTAssertEqual(applier.undo().reverted, ["sports.dashboardMode.nfl"])
        XCTAssertEqual(defaults.string(forKey: nflKey), "results")

        let invalid = try SettingsBackupCodec.makeDocument(
            groups: ["sports": ["sports.dashboardMode.nfl": .string("unknown")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        let invalidPreview = SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(invalid), registry: rig.registry)
        XCTAssertEqual(invalidPreview.totalChanges, 0)
        XCTAssertEqual(defaults.string(forKey: nflKey), "results")
    }

    func testDownloadsValuesOutsideTheStoreLimitsAreSkipped() throws {
        let rig = makeRig()
        let data = try SettingsBackupCodec.makeDocument(
            groups: ["downloads": ["downloads.simultaneous": .int(40), "downloads.defaultMaxStorageGB": .int(-1),
                                   "downloads.preferredFormat": .string("8k")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        let before = rig.downloads.simultaneousDownloads
        XCTAssertEqual(try applyAll(data, to: rig), .nothingToApply)
        XCTAssertEqual(rig.downloads.simultaneousDownloads, before)
    }

    func testFloatingNavigationUsesEditorStoreAndUndo() throws {
        let rig = makeRig()
        rig.liveTVNavigation.preferences.style = .thumbFan
        rig.liveTVNavigation.preferences.startingEdge = .left
        let data = try SettingsBackupExporter.export(registry: rig.registry, groups: [.navigationLayout], app: app)
        let saved = try SettingsBackupCodec.decode(data)
        XCTAssertEqual(saved.groups["navigationLayout"]?["liveTVNav.style"], .string("thumbFan"))
        XCTAssertNil(saved.groups["navigationLayout"]?["nav.style"])
        rig.liveTVNavigation.preferences.style = .classic
        rig.liveTVNavigation.preferences.startingEdge = .right
        let preview = SettingsBackupPlanner.preview(saved, registry: rig.registry)
        XCTAssertEqual(preview.totalChanges, 2)
        let journal = BackupMemoryJournal()
        let applier = SettingsBackupApplier(registry: rig.registry, journal: journal)
        guard case .applied = applier.apply(preview: preview, selectedGroups: [.navigationLayout],
                                            selectedIDs: ["liveTVNav.style"]) else { return XCTFail("not applied") }
        XCTAssertEqual(rig.liveTVNavigation.preferences.style, .thumbFan)
        XCTAssertEqual(rig.liveTVNavigation.preferences.startingEdge, .right)
        XCTAssertEqual(rig.navigation.preferences.style, .classic)
        let persisted = KyroLiveTVNavigationStore(defaults: defaults)
        XCTAssertEqual(persisted.preferences.style, .thumbFan)
        XCTAssertEqual(applier.undo().reverted, ["liveTVNav.style"])
        XCTAssertEqual(rig.liveTVNavigation.preferences.style, .classic)
    }

    func testDestinationOrderAndVisibilityRestoreSelectivelyAndUndo() throws {
        let rig = makeRig()
        rig.liveTVNavigation.preferences.move(fromOffsets: IndexSet(integer: 1), toOffset: 4)
        rig.liveTVNavigation.preferences.setVisible(false, for: .search)
        let data = try SettingsBackupExporter.export(registry: rig.registry, groups: [.navigationLayout], app: app)
        rig.liveTVNavigation.preferences.resetDestinations()
        let preview = SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(data), registry: rig.registry)
        XCTAssertEqual(preview.groups.flatMap(\.items).filter { $0.status == .willChange && $0.id.hasPrefix("liveTVNav.destination") }.count, 1)
        let applier = SettingsBackupApplier(registry: rig.registry, journal: BackupMemoryJournal())
        guard case .applied = applier.apply(preview: preview, selectedGroups: [.navigationLayout],
                                            selectedIDs: ["liveTVNav.destinationOrder", "liveTVNav.hiddenDestinations"]) else {
            return XCTFail("not applied")
        }
        XCTAssertFalse(rig.liveTVNavigation.preferences.isVisible(.search))
        XCTAssertEqual(KyroLiveTVNavigationStore(defaults: defaults).preferences.order, rig.liveTVNavigation.preferences.order)
        XCTAssertEqual(applier.undo().reverted.count, 2)
        XCTAssertTrue(rig.liveTVNavigation.preferences.isVisible(.search))
        XCTAssertEqual(rig.liveTVNavigation.preferences.order, KyroLiveTVDestination.defaultOrder)
    }

    func testBuild93LegacyFieldsImportButNeverTouchInternalFlagsOrWrongNavigationStore() throws {
        let rig = makeRig()
        let data = try SettingsBackupCodec.makeDocument(
            groups: ["sports": ["sports.tennisNews": .bool(false)],
                     "navigationLayout": ["nav.style": .string("glassDock")],
                     "navigation": ["navigation.fourthTab": .string("favorites")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        let preview = SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(data), registry: rig.registry)
        XCTAssertEqual(preview.unrecognizedSettings, 2)
        XCTAssertEqual(preview.skippedCount, 2)
        XCTAssertEqual(preview.totalChanges, 1)
        guard case .applied = SettingsBackupApplier(registry: rig.registry, journal: BackupMemoryJournal())
            .apply(preview: preview, selectedGroups: Set(SettingsBackupGroup.allCases)) else { return XCTFail("not applied") }
        XCTAssertEqual(rig.navigation.preferences.fourthTab, .favorites)
        XCTAssertEqual(rig.navigation.preferences.style, .classic)
        XCTAssertEqual(rig.liveTVNavigation.preferences.style, .classic)
        XCTAssertNil(defaults.object(forKey: KyroSportsSupplementFlag.tennisNewsKey))
    }

    func testCalendarFilterRestoresSelectivelyAndLeavesTheVisibleWeekAlone() throws {
        CalendarFilterPreference.save(.trending, to: defaults)
        let viewModel = CalendarViewModel(
            deviceTimeZone: { TimeZone(secondsFromGMT: 0)! },
            fetchWeek: { _, _, _, _ in CalendarResponse(events: []) },
            defaults: defaults)
        XCTAssertEqual(viewModel.filter, .trending)
        let week = viewModel.week
        viewModel.selectDay(week.startDate.addingTimeInterval(86_400))
        let selectedDay = viewModel.selectedDay
        let rig = makeRig()
        rig.navigation.preferences.fourthTab = .sports
        let before = defaults.persistentDomain(forName: suiteName) ?? [:]

        let incoming = try SettingsBackupCodec.makeDocument(
            groups: ["calendar": ["calendar.filter": .string("everything")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        let preview = SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(incoming), registry: rig.registry)
        XCTAssertEqual(preview.totalChanges, 1)
        XCTAssertEqual(preview.groups.flatMap(\.items).first { $0.id == "calendar.filter" }?.incoming, "All")
        let journal = BackupMemoryJournal()
        guard case .applied = SettingsBackupApplier(registry: rig.registry, journal: journal)
            .apply(preview: preview, selectedGroups: [.calendar]) else { return XCTFail("not applied") }

        XCTAssertEqual(CalendarFilterPreference.load(from: defaults), .everything)
        XCTAssertEqual(rig.navigation.preferences.fourthTab, .sports)
        viewModel.applyRestoredFilter()
        XCTAssertEqual(viewModel.filter, .everything)
        XCTAssertEqual(viewModel.week, week)
        XCTAssertEqual(viewModel.selectedDay, selectedDay)
        let after = defaults.persistentDomain(forName: suiteName) ?? [:]
        let changedKeys = Set(before.keys).union(after.keys).filter { before[$0] as? NSObject != after[$0] as? NSObject }
        XCTAssertEqual(changedKeys, Set([CalendarFilterPreference.defaultsKey]))

        let report = SettingsBackupApplier(registry: rig.registry, journal: journal).undo()
        XCTAssertEqual(report.reverted, ["calendar.filter"])
        XCTAssertEqual(CalendarFilterPreference.load(from: defaults), .trending)
        viewModel.applyRestoredFilter()
        XCTAssertEqual(viewModel.filter, .trending)
        XCTAssertEqual(viewModel.week, week)
        XCTAssertEqual(viewModel.selectedDay, selectedDay)

        let legacy = try SettingsBackupCodec.makeDocument(
            groups: ["sports": ["sports.tennisNews": .bool(false)],
                     "navigation": ["navigation.fourthTab": .string("favorites")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        let legacyPreview = SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(legacy), registry: rig.registry)
        XCTAssertEqual(legacyPreview.unrecognizedSettings, 1)
        XCTAssertEqual(legacyPreview.skippedCount, 1)
        guard case .applied = SettingsBackupApplier(registry: rig.registry, journal: BackupMemoryJournal())
            .apply(preview: legacyPreview, selectedGroups: Set(SettingsBackupGroup.allCases)) else { return XCTFail("not applied") }
        XCTAssertEqual(CalendarFilterPreference.load(from: defaults), .trending)
        XCTAssertEqual(rig.navigation.preferences.fourthTab, .favorites)
    }

    func testProfileSelectionBacksUpOnlyBehaviorAndUndoPreservesOtherLaunchState() throws {
        let rig = makeRig()
        rig.launch.behavior = .afterTwelveHours
        let data = try SettingsBackupExporter.export(registry: rig.registry, groups: [.general], app: app)
        let decoded = try SettingsBackupCodec.decode(data)
        XCTAssertEqual(decoded.groups["general"]?.count, 1)
        XCTAssertEqual(decoded.groups["general"]?["general.launchBehavior"], .string("afterTwelveHours"))
        rig.launch.behavior = .automatic
        let preview = SettingsBackupPlanner.preview(decoded, registry: rig.registry)
        XCTAssertEqual(preview.totalChanges, 1)
        let applier = SettingsBackupApplier(registry: rig.registry, journal: BackupMemoryJournal())
        guard case .applied = applier.apply(preview: preview, selectedGroups: [.general]) else { return XCTFail("not applied") }
        XCTAssertEqual(rig.launch.behavior, .afterTwelveHours)
        XCTAssertEqual(applier.undo().reverted, ["general.launchBehavior"])
        XCTAssertEqual(rig.launch.behavior, .automatic)
    }

    func testAudiobookVisibilityUsesScopedLocalOwnerAndUndo() throws {
        let rig = makeRig()
        rig.appNavigation.setShowAudiobooks(true)
        let data = try SettingsBackupExporter.export(registry: rig.registry, groups: [.navigation], app: app)
        XCTAssertEqual(try SettingsBackupCodec.decode(data).groups["navigation"]?["navigation.showAudiobooks"], .bool(true))
        rig.appNavigation.setShowAudiobooks(false)
        let preview = SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(data), registry: rig.registry)
        let applier = SettingsBackupApplier(registry: rig.registry, journal: BackupMemoryJournal())
        guard case .applied = applier.apply(preview: preview, selectedGroups: [.navigation],
                                            selectedIDs: ["navigation.showAudiobooks"]) else { return XCTFail("not applied") }
        XCTAssertTrue(rig.appNavigation.showAudiobooks)
        XCTAssertTrue(AppNavPreferences(
            defaults: SharedDefaults(suite: defaults, standard: defaults),
            storageKey: { "ios.nav.showAudiobooks.test" }).showAudiobooks)
        XCTAssertEqual(applier.undo().reverted, ["navigation.showAudiobooks"])
        XCTAssertFalse(rig.appNavigation.showAudiobooks)
    }

    func testSystemCaptionChoiceUsesRealPlayerSettingsWithoutServerWrite() throws {
        let settings = PlayerSettings(defaults: defaults, scopeIdentifier: { "backup-test" })
        let adapter = PlayerSettingsLocalPlayback(settings: settings)
        let rig = makeRig()
        let registry = SettingsBackupLiveRegistry.make(.init(
            navigation: rig.navigation, appNavigation: rig.appNavigation,
            liveTVNavigation: rig.liveTVNavigation, launch: rig.launch,
            downloads: rig.downloads, playback: adapter,
            defaults: defaults, idiom: "phone", supportsPictureInPicture: true))
        settings.setSubtitleMatchesSystemAppearance(true)
        let data = try SettingsBackupExporter.export(registry: registry, groups: [.subtitleDisplay], app: app)
        XCTAssertEqual(try SettingsBackupCodec.decode(data).groups["subtitleDisplay"]?["subtitleDisplay.matchesSystem"], .bool(true))
        settings.setSubtitleMatchesSystemAppearance(false)
        let preview = SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(data), registry: registry)
        let applier = SettingsBackupApplier(registry: registry, journal: BackupMemoryJournal())
        guard case .applied = applier.apply(preview: preview, selectedGroups: [.subtitleDisplay]) else { return XCTFail("not applied") }
        XCTAssertTrue(settings.subtitleMatchesSystemAppearance)
        XCTAssertTrue(PlayerSettings(defaults: defaults, scopeIdentifier: { "backup-test" }).subtitleMatchesSystemAppearance)
        XCTAssertEqual(applier.undo().reverted, ["subtitleDisplay.matchesSystem"])
        XCTAssertFalse(settings.subtitleMatchesSystemAppearance)
    }

    func testUnknownDownloadQualityIsNotExportedAsOriginalAndCanBeUndone() throws {
        let rig = makeRig()
        rig.downloads.preferredFormat = "future-format"
        let data = try SettingsBackupExporter.export(registry: rig.registry, groups: [.downloads], app: app)
        XCTAssertNil(try SettingsBackupCodec.decode(data).groups["downloads"]?["downloads.preferredFormat"])
        let incoming = try SettingsBackupCodec.makeDocument(
            groups: ["downloads": ["downloads.preferredFormat": .string("5mbps")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        let preview = SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(incoming), registry: rig.registry)
        XCTAssertEqual(preview.totalChanges, 1)
        let applier = SettingsBackupApplier(registry: rig.registry, journal: BackupMemoryJournal())
        guard case .applied = applier.apply(preview: preview, selectedGroups: [.downloads]) else { return XCTFail("not applied") }
        XCTAssertEqual(rig.downloads.preferredFormat, "5mbps")
        XCTAssertEqual(applier.undo().reverted, ["downloads.preferredFormat"])
        XCTAssertEqual(rig.downloads.preferredFormat, "future-format")
    }
    // MARK: Build 88.1: import / apply / Undo through real stores and a real restore-point file

    private func temporaryJournal() -> (FileRestoreJournalStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kyro-live-journal-\(UUID().uuidString)")
        return (FileRestoreJournalStore(url: directory.appendingPathComponent("restore-point.json")), directory)
    }

    func testImportApplyUndoTransitionsOnRealStoresSurviveReopeningTheScreen() throws {
        let (journal, directory) = temporaryJournal()
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = makeRig()
        source.navigation.preferences.fourthTab = .favorites
        source.downloads.wifiOnly = false
        source.downloads.sortOption = .alphabetical
        let data = try SettingsBackupExporter.export(registry: source.registry, groups: SettingsBackupGroup.defaultSelection, app: app)

        // A destination device with its own defaults domain.
        let name = suiteName + ".dest"
        let destDefaults = UserDefaults(suiteName: name)!
        defer { destDefaults.removePersistentDomain(forName: name) }
        let navigation = KyroGlobalNavigationStore(defaults: destDefaults)
        let appNavigation = AppNavPreferences(
            defaults: SharedDefaults(suite: destDefaults, standard: destDefaults),
            storageKey: { "ios.nav.showAudiobooks.test" })
        let liveTVNavigation = KyroLiveTVNavigationStore(defaults: destDefaults)
        let launch = ProfileLaunchPreferences(defaults: SharedDefaults(suite: destDefaults, standard: destDefaults))
        let downloads = DownloadSettings(defaults: destDefaults)
        let playback = FakeLocalPlayback()
        let registry = SettingsBackupLiveRegistry.make(.init(
            navigation: navigation, appNavigation: appNavigation,
            liveTVNavigation: liveTVNavigation, launch: launch,
            downloads: downloads, playback: playback,
            defaults: destDefaults, idiom: "phone", supportsPictureInPicture: true))
        let originalTab = navigation.preferences.fourthTab

        let center = NotificationCenter()
        var announcements = 0
        let token = center.addObserver(forName: .kyroSettingsDidRestore, object: nil, queue: nil) { _ in announcements += 1 }
        defer { center.removeObserver(token) }

        let model = SettingsBackupModel(registry: registry, journal: journal, app: app, notifications: center)
        model.loadImport(data: data)
        XCTAssertEqual(navigation.preferences.fourthTab, originalTab, "a preview changes nothing")
        model.applySelected()
        XCTAssertEqual(navigation.preferences.fourthTab, .favorites)
        XCTAssertFalse(downloads.wifiOnly)
        XCTAssertEqual(announcements, 1)

        // The screen is closed and opened again: a new model over the same file.
        let reopened = SettingsBackupModel(registry: registry, journal: journal, app: app, notifications: center)
        XCTAssertTrue(reopened.undoAvailable)
        reopened.undo()
        XCTAssertEqual(navigation.preferences.fourthTab, originalTab)
        XCTAssertTrue(downloads.wifiOnly)
        XCTAssertEqual(downloads.sortOption, .largestFirst)
        XCTAssertFalse(reopened.undoAvailable)
        XCTAssertNil(try journal.load())
    }

    func testUnselectedGroupsLeaveEveryOtherDefaultsKeyUntouched() throws {
        let source = makeRig()
        source.navigation.preferences.fourthTab = .favorites
        source.downloads.wifiOnly = false
        let data = try SettingsBackupExporter.export(registry: source.registry, groups: SettingsBackupGroup.defaultSelection, app: app)

        let name = suiteName + ".untouched"
        let destDefaults = UserDefaults(suiteName: name)!
        defer { destDefaults.removePersistentDomain(forName: name) }
        destDefaults.set("keep", forKey: "some.other.preference")
        let navigation = KyroGlobalNavigationStore(defaults: destDefaults)
        let appNavigation = AppNavPreferences(
            defaults: SharedDefaults(suite: destDefaults, standard: destDefaults),
            storageKey: { "ios.nav.showAudiobooks.test" })
        let liveTVNavigation = KyroLiveTVNavigationStore(defaults: destDefaults)
        let launch = ProfileLaunchPreferences(defaults: SharedDefaults(suite: destDefaults, standard: destDefaults))
        let downloads = DownloadSettings(defaults: destDefaults)
        let registry = SettingsBackupLiveRegistry.make(.init(
            navigation: navigation, appNavigation: appNavigation,
            liveTVNavigation: liveTVNavigation, launch: launch,
            downloads: downloads, playback: FakeLocalPlayback(),
            defaults: destDefaults, idiom: "phone", supportsPictureInPicture: true))
        let before = destDefaults.persistentDomain(forName: name) ?? [:]

        let preview = SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(data), registry: registry)
        let (journal, directory) = temporaryJournal()
        defer { try? FileManager.default.removeItem(at: directory) }
        guard case .applied = SettingsBackupApplier(registry: registry, journal: journal).apply(preview: preview, selectedGroups: [.downloads]) else {
            return XCTFail("not applied")
        }
        let after = destDefaults.persistentDomain(forName: name) ?? [:]
        let changed = Set(after.keys).union(before.keys).filter { (after[$0] as? NSObject) != (before[$0] as? NSObject) }
        XCTAssertEqual(changed, ["downloads.wifiOnly"])
        XCTAssertEqual(destDefaults.string(forKey: "some.other.preference"), "keep")
        XCTAssertEqual(navigation.preferences.fourthTab, KyroGlobalNavigationPreferences().fourthTab)
        XCTAssertFalse(downloads.wifiOnly)
    }

    func testAChangeMadeAfterARestoreSurvivesUndoOnRealStores() throws {
        let rig = makeRig()
        let incoming = try SettingsBackupCodec.makeDocument(
            groups: ["downloads": ["downloads.wifiOnly": .bool(false), "downloads.sortOption": .string("alphabetical")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        let (journal, directory) = temporaryJournal()
        defer { try? FileManager.default.removeItem(at: directory) }
        guard case .applied = try applyAll(incoming, to: rig, journal: journal) else { return XCTFail("not applied") }
        rig.downloads.sortOption = .recentlyAdded        // changed after the restore
        let report = SettingsBackupApplier(registry: rig.registry, journal: journal).undo()
        XCTAssertEqual(report.changedSince, ["downloads.sortOption"])
        XCTAssertEqual(rig.downloads.sortOption, .recentlyAdded)
        XCTAssertTrue(rig.downloads.wifiOnly)
    }

    func testInterruptedRestoreIsRecoveredFromARealRestorePointFile() throws {
        let rig = makeRig()
        let (journal, directory) = temporaryJournal()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The app stopped after the first write: the file says "applying".
        try journal.save(RestoreJournal(state: .applying, changes: [
            AppliedChange(id: "downloads.wifiOnly", previous: .bool(true), applied: .bool(false)),
            AppliedChange(id: "downloads.sortOption", previous: .string("largestFirst"), applied: .string("alphabetical")),
        ], date: Date()))
        rig.downloads.wifiOnly = false
        let applier = SettingsBackupApplier(registry: rig.registry, journal: FileRestoreJournalStore(url: directory.appendingPathComponent("restore-point.json")))
        XCTAssertTrue(applier.needsRecovery)
        let report = applier.recoverInterruptedRestore()
        XCTAssertEqual(report.reverted, ["downloads.wifiOnly"])
        XCTAssertEqual(report.unchanged, ["downloads.sortOption"])
        XCTAssertTrue(rig.downloads.wifiOnly)
        XCTAssertFalse(applier.needsRecovery)
        XCTAssertNil(try journal.load())
    }

    func testRestoredCategoryLayoutIsWhatTheCategoryScreenReloads() throws {
        // The category screen reloads appearance and grouping from this loader when it hears the
        // restore notification, so what it sees must be the restored value and nothing of the provider's.
        let providerID = UUID()
        var scoped = LiveTVCategoryPreferences()
        scoped.appearance = .list
        scoped.pinned = ["Sports"]
        scoped.save(providerID: providerID, to: defaults)

        let rig = makeRig()
        let incoming = try SettingsBackupCodec.makeDocument(
            groups: ["liveTVCategories": ["liveTV.categoryAppearance": .string("Grid")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        let (journal, directory) = temporaryJournal()
        defer { try? FileManager.default.removeItem(at: directory) }
        guard case .applied = try applyAll(incoming, to: rig, journal: journal) else { return XCTFail("not applied") }

        let reloaded = LiveTVCategoryPreferences.load(providerID: providerID, from: defaults)
        XCTAssertEqual(reloaded.appearance, .grid)
        XCTAssertEqual(reloaded.pinned, ["Sports"])
    }

    func testUnknownAndUnsupportedSettingsAreSkippedOnRealStores() throws {
        let rig = makeRig(pip: false)
        let incoming = try SettingsBackupCodec.makeDocument(
            groups: ["navigation": ["navigation.fourthTab": .string("forYou"), "navigation.hologram": .bool(true)],
                     "pictureInPicture": ["pip.backgroundPlayback": .bool(true)],
                     "someFutureGroup": ["x": .int(1)]],
            schemaVersion: 2, minReaderVersion: 1, app: app, now: Date())
        let preview = SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(incoming), registry: rig.registry)
        XCTAssertEqual(preview.unrecognizedGroups, 1)
        XCTAssertEqual(preview.unrecognizedSettings, 2)
        XCTAssertEqual(preview.skippedCount, 3)
        XCTAssertEqual(preview.totalChanges, 1)
        XCTAssertFalse(rig.playback.backgroundPlaybackEnabled)
    }
    // MARK: Build 88.2: the type the app registers (runs in the app's own bundle context)

    func testTheDeclaredTypeIsRegisteredInTheAppBundleAndConformsToJsonAndData() throws {
        let declarations = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
        XCTAssertTrue(declarations.contains { $0["UTTypeIdentifier"] as? String == SettingsBackupFileType.exportIdentifier })
        let type = SettingsBackupFileType.exportType
        XCTAssertTrue(type.conforms(to: .json))
        XCTAssertTrue(type.conforms(to: .data))
        XCTAssertEqual(type.preferredFilenameExtension, "kyrosettings")
        XCTAssertEqual(UTType(filenameExtension: "kyrosettings")?.identifier, SettingsBackupFileType.exportIdentifier)
    }

    func testAnExportedFileMatchesTheImporterTypes() throws {
        let type = SettingsBackupFileType.exportType
        XCTAssertTrue(SettingsBackupFileType.importerTypes.contains { type.conforms(to: $0) })
    }
}
#endif
