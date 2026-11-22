import SwiftUI

/// Tabs displayed in the main authenticated experience.
///
/// `switchProfile` / `switchServer` are tvOS-only sidebar action items — a
/// proxy binding in `TVMainTabView` intercepts them and triggers the
/// corresponding router action instead of ever making them the active tab,
/// so they behave like shortcuts rather than real destinations.
enum AppTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case search = "Search"
    case libraries = "Libraries"
    case recommendations = "For You"
    case calendar = "Calendar"
    case downloads = "Downloads"
    /// macOS sidebar row only, shown while the server has Requests enabled.
    case requests = "Requests"
    case settings = "Settings"
    case switchProfile = "Profile"
    case switchServer = "Server"

    var id: String { rawValue }

    /// Tabs that should actually be displayed for the current platform.
    /// iOS/iPadOS excludes Search — the phone/tablet shell surfaces search
    /// inline on Home/Libraries/Browse via a magnifying-glass affordance, so
    /// a dedicated bottom-tab would duplicate the entry point. tvOS keeps
    /// Search as a top-level tab because the 10-foot UI has no top-bar
    /// search icon and focus-driven navigation benefits from a direct route.
    /// Profile / Server switchers are tvOS-only sidebar shortcuts.
    ///
    /// iOS/iPadOS/macOS also exclude Settings — it's reached from the
    /// top-bar profile menu (`TabTopBarActions`) rather than a tab, so the
    /// bottom bar / sidebar stays focused on content destinations. tvOS
    /// keeps Settings as a top-level item for its 10-foot navigation.
    static var visibleCases: [AppTab] {
        #if os(tvOS)
        return [.home, .libraries, .search, .recommendations, .settings, .switchProfile, .switchServer]
        #else
        // Downloads is appended dynamically by `MainTabView` only when the
        // server advertises the capability, so it stays hidden when the
        // feature is off rather than showing an empty tab.
        return [.home, .libraries, .recommendations, .calendar]
        #endif
    }

    /// SF Symbol name for the unselected state.
    var icon: String {
        switch self {
        case .home: return "house"
        case .libraries: return "rectangle.stack"
        case .search: return "magnifyingglass"
        case .recommendations: return "sparkles"
        case .calendar: return "calendar"
        case .downloads: return "arrow.down.circle"
        case .requests: return "paperplane"
        case .settings: return "gearshape"
        case .switchProfile: return "person.crop.circle"
        case .switchServer: return "server.rack"
        }
    }

    /// SF Symbol name for the selected (filled) state.
    var selectedIcon: String {
        switch self {
        case .home: return "house.fill"
        case .libraries: return "rectangle.stack.fill"
        case .search: return "magnifyingglass"
        case .recommendations: return "sparkles"
        case .calendar: return "calendar"
        case .downloads: return "arrow.down.circle.fill"
        case .requests: return "paperplane.fill"
        case .settings: return "gearshape.fill"
        case .switchProfile: return "person.crop.circle.fill"
        case .switchServer: return "server.rack"
        }
    }
}

extension EnvironmentValues {
    /// Set when a Silo root (Calendar, Downloads, a library) is pushed from
    /// Kyro's More menu instead of shown as a tab: the title its navigation
    /// bar shows. Nil for a root shown as a tab or in the sidebar.
    @Entry var secondaryDestinationTitle: String? = nil
}

extension View {
    /// A root page draws its own header and hides the navigation bar. Pushed
    /// from More it keeps the bar, so the system Back and the edge swipe
    /// return to the tab it was opened from.
    func rootPageNavigationBar() -> some View {
        modifier(RootPageNavigationBar())
    }
}

private struct RootPageNavigationBar: ViewModifier {
    @Environment(\.secondaryDestinationTitle) private var secondaryTitle

    func body(content: Content) -> some View {
        #if os(macOS)
        content
        #else
        if let secondaryTitle {
            content
                .navigationTitle(secondaryTitle)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar(.visible, for: .navigationBar)
        } else {
            content.toolbar(.hidden, for: .navigationBar)
        }
        #endif
    }
}
