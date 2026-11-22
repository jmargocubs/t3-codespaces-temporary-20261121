#if os(iOS)
import AVKit
import Foundation
import UIKit

// The one place that names which device-local Kyro settings a backup may carry.
//
// Every entry reads and writes through the store that already owns the setting. Nothing here
// touches the server, the Keychain, a provider, a library ID or a profile identity, and a setting
// that is not listed cannot be exported or restored. Excluded on purpose: server-authoritative values,
// Live TV providers and their credentials, provider-specific pins and hidden categories, recent
// categories, favorites, the selected Sports league or screen, and internal flags,
// diagnostics, and authentication or pairing state.

/// The device-local player preferences a backup may carry, as their own setters. The synced player
/// settings (quality, speed, subtitles and so on) are deliberately absent: writing those enqueues a
/// server write.
@MainActor
protocol LocalPlaybackPreferences: AnyObject {
    var bufferAhead: BufferAheadMode { get set }
    var losslessAudioEnabled: Bool { get set }
    var backgroundPlaybackEnabled: Bool { get set }
    var deinterlaceMode: DeinterlacePreference { get set }
    var deinterlaceFieldRate: DeinterlaceFieldRatePreference { get set }
    var trueHDAtmosEnabled: Bool { get set }
    var subtitleMatchesSystemAppearance: Bool { get set }
}

@MainActor
final class PlayerSettingsLocalPlayback: LocalPlaybackPreferences {
    private let settings: PlayerSettings
    init(settings: PlayerSettings = .shared) { self.settings = settings }

    var bufferAhead: BufferAheadMode {
        get { settings.bufferAhead }
        set { settings.setBufferAhead(newValue) }
    }
    var losslessAudioEnabled: Bool {
        get { settings.losslessAudioEnabled }
        set { settings.setLosslessAudioEnabled(newValue) }
    }
    var backgroundPlaybackEnabled: Bool {
        get { settings.backgroundPlaybackEnabled }
        set { settings.setBackgroundPlaybackEnabled(newValue) }
    }
    var deinterlaceMode: DeinterlacePreference {
        get { settings.deinterlaceMode }
        set { settings.setDeinterlaceMode(newValue) }
    }
    var deinterlaceFieldRate: DeinterlaceFieldRatePreference {
        get { settings.deinterlaceFieldRate }
        set { settings.setDeinterlaceFieldRate(newValue) }
    }
    var trueHDAtmosEnabled: Bool {
        get { settings.trueHDAtmosEnabled }
        set { settings.setTrueHDAtmosEnabled(newValue) }
    }
    var subtitleMatchesSystemAppearance: Bool {
        get { settings.subtitleMatchesSystemAppearance }
        set { settings.setSubtitleMatchesSystemAppearance(newValue) }
    }
}

enum SettingsBackupLiveRegistry {
    struct Dependencies {
        var navigation: KyroGlobalNavigationStore
        var appNavigation: AppNavPreferences
        var liveTVNavigation: KyroLiveTVNavigationStore
        var launch: ProfileLaunchPreferences
        var downloads: DownloadSettings
        var playback: LocalPlaybackPreferences
        var defaults: UserDefaults
        var idiom: String
        var supportsPictureInPicture: Bool
        var readWatchPartyEnabled: @MainActor () -> Bool = { ExperimentalFeatures.shared.isEnabled(.watchParty) }
        var writeWatchPartyEnabled: @MainActor (Bool) -> Void = { ExperimentalFeature.watchParty.setEnabled($0) }
    }

    private struct InvalidValue: Error {}

    @MainActor
    static var currentIdiom: String { UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone" }

    @MainActor
    static func standard() -> SettingsBackupRegistry {
        make(Dependencies(
            navigation: KyroGlobalNavigationStore.shared,
            appNavigation: AppNavPreferences.shared,
            liveTVNavigation: KyroLiveTVNavigationStore.shared,
            launch: ProfileLaunchPreferences.shared,
            downloads: DownloadSettings.shared,
            playback: PlayerSettingsLocalPlayback(),
            defaults: .standard,
            idiom: currentIdiom,
            supportsPictureInPicture: AVPictureInPictureController.isPictureInPictureSupported()))
    }

    @MainActor
    static func make(_ d: Dependencies) -> SettingsBackupRegistry {
        var settings: [BackupSetting] = []

        // Only the behavior is portable. The containing launch-state record also holds server IDs,
        // remembered profile IDs and PIN state; never serialize that record wholesale.
        settings.append(enumSetting(
            "general.launchBehavior", .general, "Profile selection",
            label: { (value: ProfileLaunchBehavior) in value.title },
            read: { d.launch.behavior }, write: { d.launch.behavior = $0 }))

        // The Calendar screen stores only this preset. The visible week and selected day are memory.
        settings.append(enumSetting(
            "calendar.filter", .calendar, "Calendar filter",
            label: { (filter: CalendarFilter) in filter.displayLabel },
            read: { CalendarFilterPreference.load(from: d.defaults) },
            write: { CalendarFilterPreference.save($0, to: d.defaults) }))

        // MARK: Navigation (portable)
        // Watch Party's opt-in is an explicit device-local user preference. Route writes through
        // the feature owner so disabling it also leaves any active session safely.
        settings.append(boolSetting(
            "features.watchParty", .features, "Watch Party",
            read: { d.readWatchPartyEnabled() }, write: { d.writeWatchPartyEnabled($0) }))

        // Only the portable opt-in travels. Provider IDs, credentials and VOD catalog data do not.
        settings.append(boolSetting(
            "features.iptvVOD", .features, "Enable IPTV VOD",
            read: { IPTVVODPreference.isEnabled(in: d.defaults) },
            write: { IPTVVODPreference.setEnabled($0, in: d.defaults) }))

        settings.append(enumSetting(
            "navigation.fourthTab", .navigation, "Fourth tab",
            label: { (tab: KyroFourthTab) in tab.title },
            read: { d.navigation.preferences.fourthTab },
            write: { d.navigation.preferences.fourthTab = $0 }))
        settings.append(boolSetting(
            "navigation.showAudiobooks", .navigation, "Show audiobooks",
            read: { d.appNavigation.showAudiobooks },
            write: { d.appNavigation.setShowAudiobooks($0) }))

        // MARK: Live TV categories (portable). Appearance and grouping only: pins, hidden and
        // recent categories are per provider and never leave the device.
        settings.append(enumSetting(
            "liveTV.categoryAppearance", .liveTVCategories, "Category layout",
            label: { (value: LiveTVCategoryAppearance) in value.rawValue },
            read: { LiveTVCategoryPreferences.load(providerID: nil, from: d.defaults).appearance },
            write: { value in
                var preferences = LiveTVCategoryPreferences.load(providerID: nil, from: d.defaults)
                preferences.appearance = value
                preferences.save(providerID: nil, to: d.defaults)
            }))
        settings.append(enumSetting(
            "liveTV.categoryGrouping", .liveTVCategories, "Category grouping",
            label: { (value: LiveTVCategoryGrouping) in value.rawValue },
            read: { LiveTVCategoryPreferences.load(providerID: nil, from: d.defaults).grouping },
            write: { value in
                var preferences = LiveTVCategoryPreferences.load(providerID: nil, from: d.defaults)
                preferences.grouping = value
                preferences.save(providerID: nil, to: d.defaults)
            }))

        // MARK: Guide layout (portable)
        settings.append(enumSetting(
            "liveTV.guideStyle", .guideLayout, "Watch screen guide",
            label: { (style: LiveTVEmbeddedGuideStyle) in style.title },
            read: { LiveTVEmbeddedGuideStyle.resolve(stored: d.defaults.string(forKey: LiveTVEmbeddedGuideStyle.defaultsKey)) },
            write: { d.defaults.set($0.rawValue, forKey: LiveTVEmbeddedGuideStyle.defaultsKey) }))

        // Sports dashboard modes are explicit per-league choices in UserDefaults. An absent key
        // means data-driven Automatic, so do not flatten it to today's effective mode.
        for league in KyroSportLeague.allCases {
            let key = KyroSportsHubStore.modeKey(league)
            settings.append(BackupSetting(
                id: "sports.dashboardMode.\(league.rawValue)", group: .sports,
                title: "\(league.displayName) dashboard",
                validate: { value in
                    guard case .string(let raw) = value else { return false }
                    return raw == "~automatic" || KyroSportsDashboardMode(rawValue: raw) != nil
                },
                read: { .string(d.defaults.string(forKey: key) ?? "~automatic") },
                write: { value in
                    guard case .string(let raw) = value else { throw InvalidValue() }
                    if raw == "~automatic" { d.defaults.removeObject(forKey: key) }
                    else if KyroSportsDashboardMode(rawValue: raw) != nil { d.defaults.set(raw, forKey: key) }
                    else { throw InvalidValue() }
                },
                label: { value in
                    guard case .string(let raw) = value else { return value.plainText }
                    return raw == "~automatic" ? "Automatic" : KyroSportsDashboardMode(rawValue: raw)?.title ?? raw
                }))
        }

        // MARK: Downloads (portable)
        settings.append(BackupSetting(
            id: "downloads.preferredFormat", group: .downloads, title: "Download quality",
            validate: { if case .string(let raw) = $0 { DownloadFormat(rawValue: raw) != nil } else { false } },
            // Keep the actual raw value for preview/Undo. Export skips a value this build does not
            // understand instead of silently turning it into Original.
            read: { .string(d.downloads.preferredFormat) },
            write: { value in
                guard case .string(let raw) = value else { throw InvalidValue() }
                d.downloads.preferredFormat = raw
            },
            label: { value in
                guard case .string(let raw) = value else { return value.plainText }
                return DownloadFormat(rawValue: raw)?.displayName ?? raw
            }))
        settings.append(boolSetting(
            "downloads.wifiOnly", .downloads, "Download on Wi-Fi only",
            read: { d.downloads.wifiOnly }, write: { d.downloads.wifiOnly = $0 }))
        settings.append(boolSetting(
            "downloads.defaultDeleteWatched", .downloads, "Delete after watching",
            read: { d.downloads.defaultDeleteWatched }, write: { d.downloads.defaultDeleteWatched = $0 }))
        settings.append(intSetting(
            "downloads.defaultMaxStorageGB", .downloads, "Storage limit", range: 0...1000,
            label: { $0 == 0 ? "Unlimited" : "\($0) GB" },
            read: { d.downloads.defaultMaxStorageGB }, write: { d.downloads.defaultMaxStorageGB = $0 }))
        settings.append(enumSetting(
            "downloads.sortOption", .downloads, "Downloads sort order",
            label: { (option: DownloadSortOption) in option.displayName },
            read: { d.downloads.sortOption },
            write: { d.downloads.sortOption = $0 }))
        settings.append(boolSetting(
            "downloads.keepWatched", .downloads, "Keep watched downloads",
            read: { d.downloads.keepWatchedDownloads }, write: { d.downloads.keepWatchedDownloads = $0 }))
        settings.append(intSetting(
            "downloads.simultaneous", .downloads, "Simultaneous downloads",
            range: 1...(DownloadSettings.simultaneousDownloadChoices.last ?? 4),
            read: { d.downloads.simultaneousDownloads }, write: { d.downloads.simultaneousDownloads = $0 }))

        // MARK: Playback options (device-specific)
        settings.append(enumSetting(
            "playback.bufferAhead", .playbackOptions, "Buffer ahead",
            label: { (mode: BufferAheadMode) in mode.label },
            read: { d.playback.bufferAhead }, write: { d.playback.bufferAhead = $0 }))
        settings.append(boolSetting(
            "playback.losslessAudio", .playbackOptions, "Lossless audio bridge",
            read: { d.playback.losslessAudioEnabled }, write: { d.playback.losslessAudioEnabled = $0 }))

        // MARK: Picture in Picture (device-specific)
        settings.append(boolSetting(
            "pip.backgroundPlayback", .pictureInPicture, "Keep playing in the background",
            unsupported: { d.supportsPictureInPicture ? nil : "Picture in Picture isn't available on this device." },
            read: { d.playback.backgroundPlaybackEnabled }, write: { d.playback.backgroundPlaybackEnabled = $0 }))

        // MARK: Advanced audio & video (device-specific)
        settings.append(enumSetting(
            "advancedAV.deinterlaceMode", .advancedAudioVideo, "Deinterlacing",
            label: { (mode: DeinterlacePreference) in mode.label },
            read: { d.playback.deinterlaceMode }, write: { d.playback.deinterlaceMode = $0 }))
        settings.append(enumSetting(
            "advancedAV.deinterlaceFieldRate", .advancedAudioVideo, "Deinterlace motion",
            label: { (rate: DeinterlaceFieldRatePreference) in rate.label },
            read: { d.playback.deinterlaceFieldRate }, write: { d.playback.deinterlaceFieldRate = $0 }))
        settings.append(boolSetting(
            "advancedAV.trueHDAtmos", .advancedAudioVideo, "TrueHD Atmos and DTS:X heights",
            read: { d.playback.trueHDAtmosEnabled }, write: { d.playback.trueHDAtmosEnabled = $0 }))

        // This toggle is genuinely device-local. The subtitle language, appearance record and
        // device-override scope are server-authoritative and deliberately not writable here.
        settings.append(boolSetting(
            "subtitleDisplay.matchesSystem", .subtitleDisplay, "Use device caption settings",
            read: { d.playback.subtitleMatchesSystemAppearance },
            write: { d.playback.subtitleMatchesSystemAppearance = $0 }))

        // MARK: Floating Live TV navigation (device-specific). Build 93's nav.* entries read a
        // dormant global record, not the editor's store. Their old IDs are deliberately omitted:
        // old files still decode and count them as skipped, but never write the wrong record.
        // Saved screen positions remain excluded because they are device coordinates.
        settings.append(enumSetting(
            "liveTVNav.style", .navigationLayout, "Navigation style",
            label: { (style: KyroLiveTVNavigationStyle) in style.title },
            read: { d.liveTVNavigation.preferences.style }, write: { d.liveTVNavigation.preferences.style = $0 }))
        settings.append(enumSetting(
            "liveTVNav.startingEdge", .navigationLayout, "Starting edge",
            label: { (edge: KyroNavigationEdge) in edge.title },
            read: { d.liveTVNavigation.preferences.startingEdge }, write: { d.liveTVNavigation.preferences.startingEdge = $0 }))
        settings.append(enumSetting(
            "liveTVNav.idleBehavior", .navigationLayout, "When idle",
            label: { (value: KyroLiveTVNavigationIdleBehavior) in value.title },
            read: { d.liveTVNavigation.preferences.idleBehavior }, write: { d.liveTVNavigation.preferences.idleBehavior = $0 }))
        settings.append(boolSetting(
            "liveTVNav.autoCollapse", .navigationLayout, "Collapse automatically",
            read: { d.liveTVNavigation.preferences.autoCollapse }, write: { d.liveTVNavigation.preferences.autoCollapse = $0 }))
        settings.append(boolSetting(
            "liveTVNav.haptics", .navigationLayout, "Haptics",
            read: { d.liveTVNavigation.preferences.hapticsEnabled }, write: { d.liveTVNavigation.preferences.hapticsEnabled = $0 }))
        settings.append(boolSetting(
            "liveTVNav.thumbScrubbing", .navigationLayout, "Thumb scrubbing",
            read: { d.liveTVNavigation.preferences.thumbScrubbing }, write: { d.liveTVNavigation.preferences.thumbScrubbing = $0 }))
        settings.append(boolSetting(
            "liveTVNav.allowsDragging", .navigationLayout, "Drag to reposition",
            read: { d.liveTVNavigation.preferences.allowsDragging }, write: { d.liveTVNavigation.preferences.allowsDragging = $0 }))
        settings.append(BackupSetting(
            id: "liveTVNav.destinationOrder", group: .navigationLayout, title: "Destination order",
            validate: { value in Self.destinationList(value, requiresCompleteOrder: true) != nil },
            read: { .string(d.liveTVNavigation.preferences.order.map(\.rawValue).joined(separator: ",")) },
            write: { value in
                guard let order = Self.destinationList(value, requiresCompleteOrder: true) else { throw InvalidValue() }
                d.liveTVNavigation.preferences.setDestinationOrder(order)
            },
            label: { value in Self.destinationList(value, requiresCompleteOrder: true)?
                .map(\.title).joined(separator: ", ") ?? value.plainText }))
        settings.append(BackupSetting(
            id: "liveTVNav.hiddenDestinations", group: .navigationLayout, title: "Hidden destinations",
            validate: { value in Self.destinationList(value, requiresCompleteOrder: false) != nil },
            read: { .string(KyroLiveTVDestination.available
                .filter { !d.liveTVNavigation.preferences.isVisible($0) }.map(\.rawValue).joined(separator: ",")) },
            write: { value in
                guard let hidden = Self.destinationList(value, requiresCompleteOrder: false) else { throw InvalidValue() }
                for destination in KyroLiveTVDestination.available {
                    d.liveTVNavigation.preferences.setVisible(!hidden.contains(destination), for: destination)
                }
            },
            label: { value in
                guard let hidden = Self.destinationList(value, requiresCompleteOrder: false) else { return value.plainText }
                return hidden.isEmpty ? "None" : hidden.map(\.title).joined(separator: ", ")
            }))

        return SettingsBackupRegistry(settings: settings, deviceIdiom: d.idiom)
    }

    // MARK: Builders

    private static func destinationList(_ value: BackupValue, requiresCompleteOrder: Bool) -> [KyroLiveTVDestination]? {
        guard case .string(let raw) = value else { return nil }
        let parts = raw.isEmpty ? [] : raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let destinations = parts.compactMap(KyroLiveTVDestination.init(rawValue:))
        guard destinations.count == parts.count,
              Set(destinations).count == destinations.count,
              destinations.allSatisfy(\.isAvailable) else { return nil }
        if requiresCompleteOrder {
            guard Set(destinations) == Set(KyroLiveTVDestination.available) else { return nil }
        } else if destinations.contains(.home) {
            return nil
        }
        return destinations
    }

    @MainActor
    private static func boolSetting(
        _ id: String, _ group: SettingsBackupGroup, _ title: String,
        unsupported: @escaping @MainActor () -> String? = { nil },
        read: @escaping @MainActor () -> Bool,
        write: @escaping @MainActor (Bool) -> Void
    ) -> BackupSetting {
        BackupSetting(
            id: id, group: group, title: title,
            validate: { if case .bool = $0 { true } else { false } },
            read: { .bool(read()) },
            write: { value in
                guard case .bool(let flag) = value else { throw InvalidValue() }
                write(flag)
            },
            unsupportedReason: unsupported,
            label: { if case .bool(let flag) = $0 { flag ? "On" : "Off" } else { $0.plainText } })
    }

    @MainActor
    private static func intSetting(
        _ id: String, _ group: SettingsBackupGroup, _ title: String, range: ClosedRange<Int>,
        label: @escaping @MainActor (Int) -> String = { String($0) },
        read: @escaping @MainActor () -> Int,
        write: @escaping @MainActor (Int) -> Void
    ) -> BackupSetting {
        BackupSetting(
            id: id, group: group, title: title,
            validate: { if case .int(let number) = $0 { range.contains(number) } else { false } },
            read: { .int(read()) },
            write: { value in
                guard case .int(let number) = value, range.contains(number) else { throw InvalidValue() }
                write(number)
            },
            label: { if case .int(let number) = $0 { label(number) } else { $0.plainText } })
    }

    @MainActor
    private static func enumSetting<E: RawRepresentable & CaseIterable>(
        _ id: String, _ group: SettingsBackupGroup, _ title: String,
        label: @escaping @MainActor (E) -> String,
        read: @escaping @MainActor () -> E,
        write: @escaping @MainActor (E) -> Void
    ) -> BackupSetting where E.RawValue == String {
        BackupSetting(
            id: id, group: group, title: title,
            validate: { if case .string(let raw) = $0 { E(rawValue: raw) != nil } else { false } },
            read: { .string(read().rawValue) },
            write: { value in
                guard case .string(let raw) = value, let parsed = E(rawValue: raw) else { throw InvalidValue() }
                write(parsed)
            },
            label: { value in
                if case .string(let raw) = value, let parsed = E(rawValue: raw) { label(parsed) } else { value.plainText }
            })
    }
}
#endif
