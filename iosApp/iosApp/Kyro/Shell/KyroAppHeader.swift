import SwiftUI

// Kyro's one application header. Under the unified shell (iPhone) the shell draws it once, as an
// overlay on the tab bar's content, instead of every tab drawing its own copy. Pages learn that
// through `\.kyroShellHeader` and then skip their inline header, leaving a runway for it.
//
// The context types are not iOS-only so the shared pages compile on every platform; the view is.

/// Scroll state for each global destination. A page reports its scroll offset to its
/// own destination's state and the shell's header reads the selected one, so the glass strip
/// reacts to the page on screen and each tab keeps the offset it was left at.
@MainActor
final class KyroShellScrollStates {
    private var states: [KyroGlobalDestination: PageChromeScrollState] = [:]

    func state(for destination: KyroGlobalDestination) -> PageChromeScrollState {
        if let existing = states[destination] { return existing }
        let created = PageChromeScrollState()
        states[destination] = created
        return created
    }
}

/// What a tab page needs to know when the shell hosts the header. Absent in every other
/// arrangement (legacy shell, iPad, Mac, tvOS, pages pushed from More), where pages draw their own.
struct KyroShellHeaderContext {
    let scrollStates: KyroShellScrollStates
    /// Height the header occupies below the status bar. Pages leave this much clear at the top.
    let runway: CGFloat

    @MainActor
    func scrollState(for destination: KyroGlobalDestination) -> PageChromeScrollState {
        scrollStates.state(for: destination)
    }
}

enum KyroShellHeader {
    /// The Home header's own metrics: the icon row's 44 pt with `smallPadding` below and
    /// `smallPadding` above (a little more beside the iPhone Duo's status column, as Home had it).
    static func runway(hasStatusColumn: Bool) -> CGFloat {
        topInset(hasStatusColumn: hasStatusColumn) + SiloTheme.topBarIconHitSize + SiloTheme.smallPadding
    }

    static func topInset(hasStatusColumn: Bool) -> CGFloat {
        SiloTheme.smallPadding + (hasStatusColumn ? 6 : 0)
    }

    /// A page pushed from More carries `secondaryDestinationTitle` and keeps its own bar, whatever
    /// the environment says, so a pushed page never loses its header to the shell.
    static func hosted(_ context: KyroShellHeaderContext?, secondaryTitle: String?) -> KyroShellHeaderContext? {
        secondaryTitle == nil ? context : nil
    }

    /// The profile menu's For You. It selects the For You tab when that is the fourth tab, and
    /// otherwise pushes For You onto the app's stack like a More destination, so Back returns to
    /// the tab the user came from.
    @MainActor
    static func openForYou(router: AppRouter, store: KyroGlobalNavigationStore) {
        if store.tabDestinations.contains(.forYou) {
            router.popToRoot()
            store.selectedDestination = .forYou
        } else {
            router.navigate(to: .secondaryDestination(.app(.recommendations)))
        }
    }

    /// The header's Search and the profile menu's Settings. Both push onto the app's one stack and
    /// leave the selected tab alone, so Back (or Settings' own dismissal) returns to the tab the user
    /// came from, whichever of the five it was.
    @MainActor
    static func openSearch(router: AppRouter) { router.navigate(to: .search) }

    @MainActor
    static func openSettings(router: AppRouter) { router.navigate(to: .settings) }

    /// The global destination a Movies or Series page stands for; nil for any other library root.
    static func destination(forCategory category: PrimaryMenuBuiltin?) -> KyroGlobalDestination? {
        switch category {
        case .movies: .movies
        case .series: .series
        default: nil
        }
    }
}

extension EnvironmentValues {
    @Entry var kyroShellHeader: KyroShellHeaderContext? = nil
}

#if os(iOS)
/// The shared header: the KYRO wordmark at the leading edge and, trailing, the same action cluster
/// every root page showed (More, Search, remote control, profile menu). Search still opens Silo's
/// Search and the profile menu still opens Silo's Settings.
struct KyroAppHeader: View {
    let router: AppRouter
    let scrollStates: KyroShellScrollStates
    let store: KyroGlobalNavigationStore

    @Environment(\.statusColumn) private var statusColumn

    var body: some View {
        let destination = store.selectedDestination
        let state = scrollStates.state(for: destination)
        HStack(alignment: .center, spacing: 12) {
            AppWordmarkView(placement: .compactHeader)
                .frame(height: SiloTheme.topBarIconHitSize)
                .pageChromeBacking(
                    scrollState: state,
                    outset: EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
                )
                .padding(.leading, statusColumn == nil ? 0 : 8)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            TabTopBarActions(
                onSearch: { KyroShellHeader.openSearch(router: router) },
                onOpenSettings: { KyroShellHeader.openSettings(router: router) },
                onOpenRequests: { router.navigate(to: .requestsHub) },
                onOpenForYou: { KyroShellHeader.openForYou(router: router, store: store) },
                onSwitchProfile: { router.switchProfile() },
                onSwitchServer: { router.navigate(to: .serverList) },
                onSignOut: { router.signOutAndReset() }
            )
        }
        .padding(.horizontal, SiloTheme.padding)
        .padding(.top, KyroShellHeader.topInset(hasStatusColumn: statusColumn != nil))
        .padding(.bottom, SiloTheme.smallPadding)
        .background {
            // The scroll-driven glass is fully transparent at the top of a page and native
            // material can still reveal bright poster colors during a fast fling. Keep a
            // constant, translucent canvas behind the wordmark and actions on every tab.
            Color.siloPageCanvas.opacity(0.78)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
            // The header is the only pinned chrome on every tab, Movies and Series included (their
            // source selector and page chips scroll with the posters), so it always draws the glass.
            PageChromeGlass(scrollState: state)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kyroAppHeader")
    }
}
#endif
