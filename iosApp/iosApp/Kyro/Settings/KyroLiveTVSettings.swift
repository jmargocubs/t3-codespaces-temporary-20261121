import SwiftUI

// Live TV's provider settings as one entry of Silo's own Settings screen. The settings view itself
// (`LiveTVSettingsView`) is reused as it is; this file only decides how it is presented, what the
// Settings row says, and which of its sections are worth showing under the unified shell.

/// The Live TV row in Settings.
enum KyroLiveTVSettingsEntry {
    static let title = "Live TV"
    static let subtitle = "IPTV providers, playlists and the program guide"
    static let systemImage = "dot.radiowaves.left.and.right"

    /// Words that find this row in the Settings search field.
    static let searchTerms = ["live tv", "iptv", "provider", "playlist", "m3u", "xtream", "epg", "xmltv", "guide", "channels"]

    static func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return searchTerms.contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    /// What the row shows at its trailing edge: the active provider, or that none is set up.
    static func summary(providers: [LiveTVProvider], selectedProviderID: UUID?) -> String {
        guard !providers.isEmpty else { return "Not set up" }
        let active = providers.first { $0.id == selectedProviderID } ?? providers[0]
        return providers.count > 1 ? "\(active.name) +\(providers.count - 1)" : active.name
    }
}

/// The old Live TV navigation-style picker (Classic, Glass Dock, Thumb Fan) only drives Live TV's own
/// floating navigation. Under the unified shell the app's tab bar owns navigation and the picker does
/// nothing, so it is not offered there. Saved preferences are kept untouched.
enum KyroLiveTVNavigationSettingsPolicy {
    static func offersStylePicker(unifiedShellActive: Bool, isSupported: Bool) -> Bool {
        isSupported && !unifiedShellActive
    }
}

#if os(iOS)
/// One labelled Live TV entry in the Settings overview. It pushes the existing Live TV settings as a
/// normal subpage of Settings.
struct KyroLiveTVSettingsRow: View {
    private let service = LiveTVService.shared

    var body: some View {
        NavigationLink {
            LiveTVSettingsView(service: service, presentation: .pushed)
        } label: {
            SettingsOverviewRow(
                title: KyroLiveTVSettingsEntry.title,
                subtitle: KyroLiveTVSettingsEntry.subtitle,
                systemImage: KyroLiveTVSettingsEntry.systemImage,
                value: KyroLiveTVSettingsEntry.summary(providers: service.providers,
                                                       selectedProviderID: service.selectedProviderID)
            )
        }
        .accessibilityIdentifier("kyroSettingsLiveTV")
    }
}

struct KyroLiveTVSettingsSection: View {
    var body: some View {
        Section { KyroLiveTVSettingsRow() }
    }
}
#endif
