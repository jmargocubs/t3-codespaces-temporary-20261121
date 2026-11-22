import SwiftUI

/// Settings → Navigation: the tab between Series and Live TV. Saved on this device only, with the
/// rest of Kyro's global navigation preferences.
enum KyroNavigationSettingsEntry {
    static let title = "Navigation"
    static let subtitle = "Choose the fourth tab"
    static let systemImage = "square.grid.3x1.below.line.grid.1x2"

    /// Words that find this row in the Settings search field.
    static let searchTerms = ["navigation", "tab", "tab bar", "sports", "for you", "favorites"]

    static func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return searchTerms.contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }
}

extension KyroFourthTab {
    var settingsSummary: String {
        switch self {
        case .sports: "Scores, schedules and your teams."
        case .forYou: "Personal recommendations. Also in the profile menu."
        case .favorites: "Everything you marked as a favorite."
        }
    }
}

#if os(iOS)
/// The Navigation row in the Settings overview.
struct KyroNavigationSettingsRow: View {
    @State private var store = KyroGlobalNavigationStore.shared

    var body: some View {
        NavigationLink {
            KyroNavigationSettingsView(store: store)
        } label: {
            SettingsOverviewRow(
                title: KyroNavigationSettingsEntry.title,
                subtitle: KyroNavigationSettingsEntry.subtitle,
                systemImage: KyroNavigationSettingsEntry.systemImage,
                value: store.preferences.fourthTab.title
            )
        }
        .accessibilityIdentifier("kyroSettingsNavigation")
    }
}

struct KyroNavigationSettingsSection: View {
    var body: some View {
        Section { KyroNavigationSettingsRow() }
    }
}

struct KyroNavigationSettingsView: View {
    @Bindable var store: KyroGlobalNavigationStore

    var body: some View {
        Form {
            Section {
                ForEach(KyroFourthTab.allCases) { choice in
                    Button {
                        store.preferences.fourthTab = choice
                    } label: {
                        row(for: choice)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(store.preferences.fourthTab == choice ? .isSelected : [])
                    .accessibilityIdentifier("kyroFourthTab-\(choice.rawValue)")
                }
            } header: {
                Text("Fourth Tab")
            } footer: {
                Text("Home, Movies, Series and Live TV are always in the tab bar. For You stays in the profile menu whichever tab you choose. Saved on this device.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.siloBackground.ignoresSafeArea())
        .navigationTitle(KyroNavigationSettingsEntry.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(for choice: KyroFourthTab) -> some View {
        HStack(spacing: 14) {
            Image(systemName: choice.systemImage)
                .font(.title3)
                .foregroundStyle(KyroTheme.accentInk)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(choice.title).foregroundStyle(KyroTheme.textPrimary)
                    if choice == .default {
                        Text("Default")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(KyroTheme.accentInk)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(KyroTheme.selectedFill, in: Capsule())
                    }
                }
                Text(choice.settingsSummary).font(.footnote).foregroundStyle(KyroTheme.textSecondary)
            }
            Spacer(minLength: 8)
            if store.preferences.fourthTab == choice {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(KyroTheme.accentInk)
            }
        }
        .contentShape(Rectangle())
    }
}
#endif
