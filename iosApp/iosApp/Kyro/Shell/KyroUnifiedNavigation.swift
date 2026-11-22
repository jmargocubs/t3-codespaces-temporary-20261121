import SwiftUI
import UIKit

/// Kyro's unified Classic shell: Live TV as a tab of the Media Server's own
/// tab bar. The default on iPhone since Build 27; iPad keeps the earlier
/// navigation, where Live TV is pushed over the Media Server tabs.
///
/// Read once at launch. The earlier navigation stays available for debugging
/// and tests through the `kyro.navigation.legacyShell` default
/// (`-kyro.navigation.legacyShell YES` on the command line, or the Debug
/// switch below). The Build 26 setting `kyro.unifiedNavigation.enabled` is no
/// longer read, so a `false` left by an earlier test build cannot bring the
/// earlier navigation back.
enum KyroUnifiedNavigation {
    /// Opt-out: true shows the earlier navigation on iPhone.
    static let legacyShellKey = "kyro.navigation.legacyShell"

    @MainActor
    static let isActive: Bool = resolveIsActive(isPhone: UIDevice.current.userInterfaceIdiom == .phone,
                                                defaults: .standard)

    /// Whether the unified shell runs, for a device idiom and settings.
    /// `KYRO_UNIFIED_NAV_FORCE_ON` is the Build 26 validation recipe; it is no
    /// longer needed, still accepted, and ignores the opt-out.
    static func resolveIsActive(isPhone: Bool, defaults: UserDefaults) -> Bool {
        #if KYRO_UNIFIED_NAV_FORCE_ON
        return isPhone
        #else
        return isPhone && !defaults.bool(forKey: legacyShellKey)
        #endif
    }

    /// Native iPhone tab bars display four ordinary items and place the fifth
    /// here. The four media roots remain in their original order.
    static let tabBarCapacity = 5

    static func liveTVIndex(itemCount: Int) -> Int {
        let count = max(itemCount, 0)
        return count + 1 <= tabBarCapacity ? count : tabBarCapacity - 2
    }

    /// Live TV can be shown as a tab only from the shell's root: a pushed
    /// screen or a presented one sits over every tab.
    static func canSelectLiveTVTab(pathIsEmpty: Bool, isPresentingOverShell: Bool) -> Bool {
        pathIsEmpty && !isPresentingOverShell
    }

    /// Picture in Picture asked for Live TV and none of its screens is up.
    /// From the shell root select the one global Live TV destination. Elsewhere
    /// present over the current screen and leave its stack untouched.
    @MainActor
    static func bringLiveTVForward(router: AppRouter, store: KyroGlobalNavigationStore? = nil,
                                   presentation: LiveTVPresentation? = nil) {
        let store = store ?? KyroGlobalNavigationStore.shared
        let presentation = presentation ?? LiveTVService.shared.presentation
        if canSelectLiveTVTab(pathIsEmpty: router.path.isEmpty,
                              isPresentingOverShell: router.presentedItemDetail != nil
                                  || router.presentedPlayer != nil) {
            store.selectedDestination = .liveTV
        } else {
            presentation.presentOverCurrentScreen()
        }
    }
}

#if DEBUG || KYRO_UNIFIED_NAV_TOGGLE
/// Device testing only: switches between the unified navigation and the
/// earlier one for the next launch. Compiled into Debug builds and into
/// Release builds made with
/// `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) KYRO_UNIFIED_NAV_TOGGLE'`
/// on the command line; the project never sets it, so shipping builds have no
/// switch and always use the unified navigation on iPhone. On unless the
/// tester turns it off.
struct KyroUnifiedNavigationTestSection: View {
    @AppStorage(KyroUnifiedNavigation.legacyShellKey) private var usesLegacyShell = false

    private var isEnabled: Binding<Bool> {
        Binding(get: { !usesLegacyShell }, set: { usesLegacyShell = !$0 })
    }

    var body: some View {
        Section {
            Toggle("Live TV as a Tab", isOn: isEnabled)
                .accessibilityIdentifier("kyroUnifiedNavigationToggle")
            if isEnabled.wrappedValue != KyroUnifiedNavigation.isActive && UIDevice.current.userInterfaceIdiom == .phone {
                Label("Close and reopen Kyro to apply.", systemImage: "arrow.clockwise")
                    .font(.footnote)
                    .foregroundStyle(KyroTheme.accentInk)
            }
        } header: {
            Text("Testing")
        } footer: {
            Text("Test build only. Turn off to use the earlier navigation on iPhone, where Live TV opens over the Media Server tabs. Takes effect the next time Kyro opens.")
        }
    }
}
#endif

/// SiloTabBar adapter for the fifth native slot. `isSelected` is derived from
/// the global enum; it does not store a competing Live TV boolean.
struct KyroShellTab {
    let title: String
    let systemImage: String
    let isSelected: Binding<Bool>
    let content: () -> AnyView

    @MainActor
    static func liveTV(store: KyroGlobalNavigationStore, service: LiveTVService) -> KyroShellTab {
        KyroShellTab(
            title: "Live TV",
            systemImage: "dot.radiowaves.left.and.right",
            isSelected: Binding(
                get: { store.selectedDestination == .liveTV },
                set: { if $0 { store.selectedDestination = .liveTV } }
            ),
            content: { AnyView(LiveTVView(service: service)) }
        )
    }
}

extension EnvironmentValues {
    @Entry var kyroShellTab: KyroShellTab? = nil
}

extension View {
    /// Around `MainTabView` on iPhone. Without the flag it changes nothing.
    @ViewBuilder
    func kyroUnifiedNavigation() -> some View {
        if KyroUnifiedNavigation.isActive {
            modifier(KyroUnifiedNavigationShell(service: .shared))
        } else {
            self
        }
    }
}

private struct KyroUnifiedNavigationShell: ViewModifier {
    @Bindable var service: LiveTVService

    func body(content: Content) -> some View {
        content
            .environment(\.kyroShellTab, .liveTV(store: .shared, service: service))
            .fullScreenCover(isPresented: Binding(
                get: { service.presentation.channel(for: .shell) != nil },
                set: { if !$0 { service.presentation.coverDismissed(from: .shell) } }
            )) {
                if service.presentation.isFullScreenFromInline,
                   let channel = service.presentation.channel(for: .shell) {
                    // Sports Hub's existing full-screen expansion remains a direct landscape cover.
                    LiveTVPlayerView(channel: channel, channels: service.channels,
                                     session: service.playerSession, service: service,
                                     naturalRotation: service.presentation.isInlineExpandedByRotation)
                } else {
                    // A channel chosen from shell Search uses the same iPhone watch screen as
                    // Home and Guide. Its one surface follows the same presentation ownership.
                    LiveTVWatchView(service: service)
                }
            }
    }
}
