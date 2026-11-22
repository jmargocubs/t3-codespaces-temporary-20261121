import SwiftUI
import XCTest
@testable import Silo

@MainActor
private final class SettingsMemorySecretStore: LiveTVSecretStore {
    var values: [String: String] = [:]
    func read(account: String) -> String? { values[account] }
    func save(_ value: String, account: String) -> Bool { values[account] = value; return true }
    func remove(account: String) -> Bool { values.removeValue(forKey: account) != nil }
}

/// Live TV inside Silo's own Settings: one header profile menu, one Settings screen, one Live TV
/// subpage that reuses `LiveTVSettingsView`.
@MainActor
final class KyroSettingsIntegrationTests: XCTestCase {
    private func ephemeralDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suite = "KyroSettingsIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    private func makeService(_ defaults: UserDefaults, _ secrets: SettingsMemorySecretStore) -> LiveTVService {
        LiveTVService(defaults: defaults, secretStore: secrets,
                      epg: EPGService(cache: nil, loader: URLSessionEPGFeedLoader.makeDefault(),
                                      fingerprinter: .inMemory()))
    }

    // MARK: Profile menu -> Settings, from every tab

    func testSettingsOpensFromAllFiveTabsAndLeavesTheSelectedTabAlone() throws {
        let (defaults, cleanup) = try ephemeralDefaults()
        defer { cleanup() }
        for destination in KyroGlobalDestination.tabDestinations(fourthTab: .default) {
            let store = KyroGlobalNavigationStore(defaults: defaults)
            let router = AppRouter()
            store.selectedDestination = destination
            KyroShellHeader.openSettings(router: router)
            XCTAssertEqual(router.visiblePushedRoutes, [.settings], "Settings opens from \(destination)")
            XCTAssertEqual(store.selectedDestination, destination, "opening Settings never changes the tab")
            // Settings' own Back (or dismissal) returns to the tab it came from.
            router.goBack()
            XCTAssertTrue(router.visiblePushedRoutes.isEmpty)
            XCTAssertEqual(store.selectedDestination, destination, "back on \(destination)")
        }
    }

    func testSearchOpensTheExistingSiloSearchFromTheSharedHeader() {
        let router = AppRouter()
        KyroShellHeader.openSearch(router: router)
        XCTAssertEqual(router.visiblePushedRoutes, [.search])
    }

    func testTheProfileMenuHasNoLiveTVOrSettingsCopyOfItsOwnUnderTheUnifiedShell() {
        XCTAssertFalse(KyroLiveTVEntry.profileMenuOffersLiveTV(unifiedShell: true))
        XCTAssertTrue(KyroLiveTVEntry.profileMenuOffersLiveTV(unifiedShell: false), "legacy shell keeps its entry")
    }

    // MARK: Settings -> Live TV

    func testLiveTVIsOneLabelledSettingsEntryThatSearchFinds() {
        XCTAssertEqual(KyroLiveTVSettingsEntry.title, "Live TV")
        for query in ["", "live", "IPTV", "playlist", "M3U", "xtream", "epg", "guide", "provider"] {
            XCTAssertTrue(KyroLiveTVSettingsEntry.matches(query), "\"\(query)\" finds Live TV")
        }
        XCTAssertFalse(KyroLiveTVSettingsEntry.matches("subtitles"))
    }

    func testTheSettingsRowSaysWhichProviderIsActiveOrThatNoneIsSetUp() {
        let a = LiveTVProvider(id: UUID(), name: "Home IPTV", channelCount: 10, lastRefreshed: nil)
        let b = LiveTVProvider(id: UUID(), name: "Backup", channelCount: 5, lastRefreshed: nil)
        XCTAssertEqual(KyroLiveTVSettingsEntry.summary(providers: [], selectedProviderID: nil), "Not set up")
        XCTAssertEqual(KyroLiveTVSettingsEntry.summary(providers: [a], selectedProviderID: a.id), "Home IPTV")
        XCTAssertEqual(KyroLiveTVSettingsEntry.summary(providers: [a, b], selectedProviderID: b.id), "Backup +1")
        XCTAssertEqual(KyroLiveTVSettingsEntry.summary(providers: [a, b], selectedProviderID: nil), "Home IPTV +1")
    }

    func testAPushedLiveTVSubpageUsesTheSystemBackAndStaysAfterSavingAProvider() {
        XCTAssertFalse(LiveTVSettingsPresentation.pushed.showsDoneButton, "one Back button only")
        XCTAssertFalse(LiveTVSettingsPresentation.pushed.dismissesAfterSavingProvider,
                       "saving must not pop or dismiss Settings")
    }

    func testTheSheetKeepsItsDoneButtonAndClosesAfterSavingForFirstTimeSetupAndLegacyLiveTV() {
        XCTAssertTrue(LiveTVSettingsPresentation.sheet.showsDoneButton)
        XCTAssertTrue(LiveTVSettingsPresentation.sheet.dismissesAfterSavingProvider)
    }

    // MARK: Obsolete navigation picker

    func testTheNavigationStylePickerIsHiddenUnderTheUnifiedShellOnly() {
        XCTAssertFalse(KyroLiveTVNavigationSettingsPolicy.offersStylePicker(unifiedShellActive: true, isSupported: true),
                       "Glass Dock and Thumb Fan are not connected to the unified shell")
        XCTAssertTrue(KyroLiveTVNavigationSettingsPolicy.offersStylePicker(unifiedShellActive: false, isSupported: true),
                      "the legacy shell, where the picker works, keeps it")
        XCTAssertFalse(KyroLiveTVNavigationSettingsPolicy.offersStylePicker(unifiedShellActive: false, isSupported: false),
                       "not on iPad")
    }

    func testHidingThePickerLeavesSavedNavigationPreferencesUntouched() throws {
        let (defaults, cleanup) = try ephemeralDefaults()
        defer { cleanup() }
        var legacy = KyroLiveTVNavigationPreferences()
        legacy.style = .thumbFan
        defaults.set(try JSONEncoder().encode(legacy), forKey: KyroLiveTVNavigationStore.defaultsKey)
        _ = KyroLiveTVSettingsEntry.summary(providers: [], selectedProviderID: nil)
        let stored = try XCTUnwrap(defaults.data(forKey: KyroLiveTVNavigationStore.defaultsKey))
        XCTAssertEqual(try JSONDecoder().decode(KyroLiveTVNavigationPreferences.self, from: stored).style, .thumbFan)
        XCTAssertEqual(KyroLiveTVNavigationStore(defaults: defaults).preferences.style, .thumbFan)
    }

    // MARK: First-time setup and persistence

    func testAUserWithNoProviderCanSetOneUpThroughTheSameService() throws {
        let (defaults, cleanup) = try ephemeralDefaults()
        defer { cleanup() }
        let secrets = SettingsMemorySecretStore()
        let service = makeService(defaults, secrets)
        XCTAssertTrue(service.providers.isEmpty)
        XCTAssertEqual(KyroLiveTVSettingsEntry.summary(providers: service.providers,
                                                       selectedProviderID: service.selectedProviderID), "Not set up")

        let id = try service.saveConfiguration(name: "First", playlistURL: "https://example.test/a.m3u",
                                               xmltvURL: "https://example.test/a.xml")
        XCTAssertEqual(service.providers.map(\.id), [id])
        XCTAssertEqual(service.selectedProviderID, id, "the first provider becomes active")
        XCTAssertEqual(KyroLiveTVSettingsEntry.summary(providers: service.providers,
                                                       selectedProviderID: service.selectedProviderID), "First")

        _ = try service.saveXtreamConfiguration(name: "Second", serverURL: "https://xtream.example.test",
                                                username: "user", password: "secret")
        XCTAssertEqual(service.providers.count, 2, "Settings can add more providers")
    }

    func testProvidersFavoritesAndRecentsSurviveARelaunch() throws {
        let (defaults, cleanup) = try ephemeralDefaults()
        defer { cleanup() }
        let secrets = SettingsMemorySecretStore()
        let first = makeService(defaults, secrets)
        let id = try first.saveConfiguration(name: "Kept", playlistURL: "https://example.test/k.m3u", xmltvURL: nil)
        let channelID = "\(id.uuidString):news.one"
        defaults.set([channelID], forKey: "liveTV.favorites.v1")
        let recent = try XCTUnwrap(LiveTVRecentChannel(providerID: id, channelID: channelID))
        let history = LiveTVRecentHistoryStore(defaults: defaults)
        history.save([recent])
        history.flush()

        // A new service on the same stores is what the app builds on its next launch.
        let relaunched = makeService(defaults, secrets)
        XCTAssertEqual(relaunched.providers.map(\.id), [id])
        XCTAssertEqual(relaunched.providers.first?.name, "Kept")
        XCTAssertEqual(relaunched.selectedProviderID, id)
        XCTAssertEqual(relaunched.favoriteChannelIDs, [channelID], "favorites keep their key and format")
        XCTAssertEqual(relaunched.recentlyWatchedRecords, [recent], "recently watched keeps its key and format")
        XCTAssertNotNil(secrets.values["provider.\(id.uuidString)"], "the playlist address stays in the secret store")
    }

    func testSettingsDoesNotChangeTheStoredKeys() throws {
        let (defaults, cleanup) = try ephemeralDefaults()
        defer { cleanup() }
        let service = makeService(defaults, SettingsMemorySecretStore())
        _ = try service.saveConfiguration(name: "Keys", playlistURL: "https://example.test/k.m3u", xmltvURL: nil)
        XCTAssertNotNil(defaults.data(forKey: "liveTV.providers.v1"))
        XCTAssertEqual(KyroGlobalNavigationStore.defaultsKey, "kyro.navigation.global.v1")
        XCTAssertEqual(KyroLiveTVNavigationStore.defaultsKey, "kyro.liveTV.navigation.v1")
    }

    // MARK: Build 85 Settings overview

    func testSettingsOverviewUsesTheApprovedGroupsAndCategoriesInOrder() {
        XCTAssertEqual(
            IOSSettingsOverviewCategory.allCases.map(\.title),
            [
                "Playback",
                "Live TV",
                "Appearance & Navigation",
                "Downloads & Storage",
                "Account & Connections",
                "Privacy",
                "Advanced & Diagnostics",
                "About Kyro",
            ]
        )
        XCTAssertEqual(IOSSettingsOverviewGroup.allCases.map(\.rawValue), ["Preferences", "Account", "Support"])
        XCTAssertEqual(
            IOSSettingsOverviewCategory.allCases.map(\.group),
            [.preferences, .preferences, .preferences, .preferences, .account, .support, .support, .support]
        )
        XCTAssertEqual(IOSSettingsOverviewCategory.visible(downloadsEnabled: true), IOSSettingsOverviewCategory.allCases)
    }

    func testSettingsOverviewSearchKeepsLegacyAndNewAliasesReachable() {
        let queries = [
            "Interface", "Navigation", "Subtitles", "Quality", "Live TV", "EPG",
            "Diagnostics", "Playback Health", "Experimental", "Downloads", "Server",
            "Appearance & Navigation", "Account & Connections", "Privacy & Support",
            "Debug", "Audiobooks", "Watch Party", "About", "Replay Introduction",
        ]

        for query in queries {
            XCTAssertFalse(
                IOSSettingsOverviewSearch.categories(matching: query, downloadsEnabled: true).isEmpty,
                "Settings search alias should find a destination: \(query)"
            )
        }
    }

    func testSettingsOverviewHidesUnsupportedDownloadsWithoutChangingOtherCategories() {
        XCTAssertEqual(
            IOSSettingsOverviewCategory.visible(downloadsEnabled: false).map(\.title),
            [
                "Playback",
                "Live TV",
                "Appearance & Navigation",
                "Account & Connections",
                "Privacy",
                "Advanced & Diagnostics",
                "About Kyro",
            ]
        )
    }

    func testLegacyPrivacyAndSupportAliasFindsAllSplitDestinations() {
        XCTAssertEqual(
            IOSSettingsOverviewSearch.categories(matching: "Privacy & Support", downloadsEnabled: true),
            [.privacy, .advancedDiagnostics, .aboutKyro]
        )
    }

    func testFeatureAliasesRemainOwnedByAppearanceAndNavigation() {
        for query in ["Audiobooks", "Watch Party", "Experimental"] {
            XCTAssertEqual(
                IOSSettingsOverviewSearch.categories(matching: query, downloadsEnabled: true),
                [.appearanceNavigation]
            )
        }
    }

    func testSettingsOverviewShowsDownloadsAfterSupportedCapabilityHydrates() {
        XCTAssertFalse(IOSSettingsOverviewDownloadsVisibility.isVisible(downloadsEnabled: true, capabilityHydrated: false))
        XCTAssertTrue(IOSSettingsOverviewDownloadsVisibility.isVisible(downloadsEnabled: true, capabilityHydrated: true))
        XCTAssertTrue(IOSSettingsOverviewCategory.visible(downloadsEnabled: true).contains(.downloadsStorage))
    }

    func testSettingsOverviewKeepsDownloadsHiddenForUnsupportedCapability() {
        XCTAssertFalse(IOSSettingsOverviewDownloadsVisibility.isVisible(downloadsEnabled: false, capabilityHydrated: true))
        XCTAssertFalse(IOSSettingsOverviewCategory.visible(downloadsEnabled: false).contains(.downloadsStorage))
    }

    func testSettingsOverviewSearchMetadataIsPurePresentationData() throws {
        let (defaults, cleanup) = try ephemeralDefaults()
        defer { cleanup() }
        defaults.set(true, forKey: "sentinel")
        let before = defaults.dictionaryRepresentation()

        _ = IOSSettingsOverviewSearch.categories(matching: "Playback", downloadsEnabled: true)

        XCTAssertTrue((defaults.dictionaryRepresentation() as NSDictionary).isEqual(to: before))
    }

    // MARK: Build 85.3 Playback organization

    func testPlaybackGroupsAppearInTheApprovedOrder() {
        XCTAssertEqual(
            PlaybackSettingsLayout.Group.allCases.map(\.title),
            ["Streaming Quality", "Audio & Video", "Episode Behavior", "Player Controls", "Advanced Playback"]
        )
        XCTAssertEqual(PlaybackSettingsLayout.Group.streamingQuality.controls.first, "Resolution")
        XCTAssertEqual(PlaybackSettingsLayout.Group.advanced.controls.first, "Seek Cache")
    }

    func testEveryPreviousPlaybackControlIsStillPlacedExactlyOnce() {
        let previous = [
            "Resolution", "Maximum Bitrate", "Cellular Quality", "Buffering Quality", "Audio Language", "HDR",
            "Dolby Vision", "Background Playback", "Auto-Play Next Episode", "Show Next Up", "Skip Intros",
            "Skip Credits", "Seek Cache", "Buffer Ahead", "Lossless Multichannel Audio",
            "TrueHD Atmos and DTS:X", "Deinterlacing", "Deinterlacing Field Rate", "Skip Back", "Skip Forward",
        ]
        let placed = PlaybackSettingsLayout.Group.allCases.flatMap(\.controls)
        for control in previous {
            XCTAssertEqual(placed.filter { $0 == control }.count, 1, "\(control) should appear once")
        }
    }

    func testExpertControlsLiveOnlyUnderAdvancedPlayback() {
        let advanced = Set(PlaybackSettingsLayout.Group.advanced.controls)
        for title in ["Seek Cache", "Buffer Ahead", "Lossless Multichannel Audio", "TrueHD Atmos and DTS:X",
                      "Deinterlacing", "Deinterlacing Field Rate"] {
            XCTAssertTrue(advanced.contains(title))
            for group in PlaybackSettingsLayout.Group.allCases where group != .advanced {
                XCTAssertFalse(group.controls.contains(title))
            }
        }
    }

    func testPlaybackSearchFindsEverySectionAndStaysOffOtherCategories() {
        for query in ["Streaming Quality", "Audio & Video", "Episode Behavior", "Spoiler Protection",
                      "Player Controls", "Advanced Playback", "Seek Cache", "Deinterlacing", "HDR",
                      "Cellular", "Subtitles"] {
            XCTAssertEqual(
                IOSSettingsOverviewSearch.categories(matching: query, downloadsEnabled: true),
                [.playback],
                "\(query) should lead to Playback"
            )
        }
        XCTAssertEqual(
            IOSSettingsOverviewSearch.categories(matching: "Audiobooks", downloadsEnabled: true),
            [.appearanceNavigation]
        )
    }

    // MARK: Build 86.1 Downloads capability, Live TV diagnostics, row layout

    private func capability(state: String = "available", allowed: Bool = true, enabled: Bool = true,
                            downloadAllowed: Bool = true) throws -> DownloadCapability {
        let json = """
        {"state":"\(state)","allowed":\(allowed),"enabled":\(enabled),"downloadAllowed":\(downloadAllowed),
         "qualityPresets":[],"transcodeEnabled":false,"transcodeUserAllowed":true,"seasonDownload":false,
         "seriesMonitoring":false,"monitoringModes":[]}
        """
        return try JSONDecoder().decode(DownloadCapability.self, from: Data(json.utf8))
    }

    private final class DownloadsFake {
        var scopeActive = true
        var refreshSucceeds = true
        var cached: DownloadCapability?
        var served: DownloadCapability?
        var refreshCount = 0

        @MainActor func hydrator() -> IOSSettingsDownloadsHydrator {
            IOSSettingsDownloadsHydrator(
                activate: { self.scopeActive },
                refresh: {
                    self.refreshCount += 1
                    guard self.refreshSucceeds else { return false }
                    self.cached = self.served
                    return true
                },
                capability: { self.cached }
            )
        }
    }

    func testDownloadsStayHiddenAndLoadingUntilTheCapabilityIsHydrated() throws {
        let fake = DownloadsFake()
        fake.cached = try capability() // a usable answer from a previous scope
        let hydrator = fake.hydrator()
        XCTAssertEqual(hydrator.availability, .loading)
        XCTAssertFalse(hydrator.availability.isVisible)
    }

    func testSupportedCapabilityArrivingAsynchronouslyShowsDownloads() async throws {
        let fake = DownloadsFake()
        fake.served = try capability()
        let hydrator = fake.hydrator()
        XCTAssertFalse(hydrator.availability.isVisible)
        await hydrator.hydrate()
        XCTAssertEqual(hydrator.availability, .available)
        XCTAssertEqual(fake.refreshCount, 1)
    }

    func testDisabledServerHidesDownloadsWithTheServerReason() async throws {
        let fake = DownloadsFake()
        // The answer the physical iPhone stored during the Build 86 test.
        fake.served = try capability(state: "disabled", allowed: false, enabled: false, downloadAllowed: true)
        let hydrator = fake.hydrator()
        await hydrator.hydrate()
        XCTAssertEqual(hydrator.availability, .unavailable(.serverDisabled))
    }

    func testPermissionDeniedHidesDownloadsWithoutBlamingTheServer() async throws {
        let fake = DownloadsFake()
        fake.served = try capability(allowed: false)
        let hydrator = fake.hydrator()
        await hydrator.hydrate()
        XCTAssertEqual(hydrator.availability, .unavailable(.notAllowed))

        fake.served = try capability(downloadAllowed: false)
        await hydrator.hydrate()
        XCTAssertEqual(hydrator.availability, .unavailable(.notAllowed))
    }

    func testFailedRefreshWithNothingCachedIsUnknownAndRetriesOnReopening() async throws {
        let fake = DownloadsFake()
        fake.refreshSucceeds = false
        fake.served = try capability()
        let hydrator = fake.hydrator()
        await hydrator.hydrate()
        XCTAssertEqual(hydrator.availability, .unavailable(.capabilityUnknown))

        fake.refreshSucceeds = true // Settings reopened
        hydrator.reset()
        XCTAssertEqual(hydrator.availability, .loading)
        await hydrator.hydrate()
        XCTAssertEqual(hydrator.availability, .available)
    }

    func testFailedRefreshKeepsAConfirmedUsableCapabilityVisible() async throws {
        let fake = DownloadsFake()
        fake.cached = try capability()
        fake.refreshSucceeds = false
        let hydrator = fake.hydrator()
        await hydrator.hydrate()
        XCTAssertEqual(hydrator.availability, .available)
    }

    func testSigningOutOrSwitchingToNoScopeReportsNoActiveScope() async throws {
        let fake = DownloadsFake()
        fake.scopeActive = false
        fake.cached = try capability()
        let hydrator = fake.hydrator()
        await hydrator.hydrate()
        XCTAssertEqual(hydrator.availability, .unavailable(.noActiveScope))
        XCTAssertEqual(fake.refreshCount, 0, "no request without a server and profile")
    }

    func testServerOrProfileSwitchDropsThePreviousAnswerUntilTheNewScopeResponds() async throws {
        let fake = DownloadsFake()
        fake.served = try capability()
        let hydrator = fake.hydrator()
        await hydrator.hydrate()
        XCTAssertTrue(hydrator.availability.isVisible)

        hydrator.reset() // active server changed
        XCTAssertEqual(hydrator.availability, .loading)
        fake.served = try capability(state: "disabled", allowed: false, enabled: false)
        await hydrator.hydrate()
        XCTAssertEqual(hydrator.availability, .unavailable(.serverDisabled))
    }

    func testSupportedToUnsupportedTransitionHidesDownloadsOnTheNextRefresh() async throws {
        let fake = DownloadsFake()
        fake.served = try capability()
        let hydrator = fake.hydrator()
        await hydrator.hydrate()
        XCTAssertTrue(hydrator.availability.isVisible)

        fake.served = try capability(enabled: false)
        await hydrator.hydrate()
        XCTAssertFalse(hydrator.availability.isVisible)
    }

    func testReopeningSettingsAfterHydrationKeepsDownloadsWhileItRefreshes() async throws {
        let fake = DownloadsFake()
        fake.served = try capability()
        let hydrator = fake.hydrator()
        await hydrator.hydrate()
        // Returning from a child page re-reads state; it does not reset it.
        XCTAssertEqual(hydrator.hydration, .refreshed)
        XCTAssertTrue(hydrator.availability.isVisible)
        XCTAssertEqual(fake.refreshCount, 1, "no extra request for reading state")
    }

    func testLiveTVDiagnosticsLiveUnderAdvancedAndDiagnosticsSearch() {
        for query in ["Live TV Diagnostics", "Performance overlay", "Playback log", "Sports log", "Copy log"] {
            XCTAssertTrue(
                IOSSettingsOverviewSearch.categories(matching: query, downloadsEnabled: true)
                    .contains(.advancedDiagnostics),
                "\(query) should reach Advanced & Diagnostics"
            )
        }
        XCTAssertEqual(LiveTVDiagnosticsCopy.title, "Live TV Diagnostics")
        // The provider page's own search entry no longer advertises diagnostics.
        XCTAssertFalse(KyroLiveTVSettingsEntry.matches("performance overlay"))
        XCTAssertTrue(KyroLiveTVSettingsEntry.matches("playlist"))
    }

    func testLongValuesMoveBelowTheDescriptionAndShortOnesStayTrailing() {
        XCTAssertFalse(SettingsOverviewRowLayout.placesValueBelow(nil, isAccessibilitySize: false))
        XCTAssertFalse(SettingsOverviewRowLayout.placesValueBelow("", isAccessibilitySize: true))
        XCTAssertFalse(SettingsOverviewRowLayout.placesValueBelow("1080p", isAccessibilitySize: false))
        XCTAssertTrue(SettingsOverviewRowLayout.placesValueBelow("My IPTV Provider Name +2", isAccessibilitySize: false))
        XCTAssertTrue(SettingsOverviewRowLayout.placesValueBelow("1080p", isAccessibilitySize: true))
    }

    func testLiveTVSummaryKeepsTheFullProviderName() {
        let name = "An Extremely Long Provider Name For Testing"
        let provider = LiveTVProvider(id: UUID(), name: name, channelCount: 0, lastRefreshed: nil)
        XCTAssertEqual(KyroLiveTVSettingsEntry.summary(providers: [provider], selectedProviderID: provider.id), name)
    }
}
