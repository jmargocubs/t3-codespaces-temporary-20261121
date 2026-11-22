import SwiftUI

/// Where Kyro's Live TV entry points lead. Under the unified navigation
/// (the iPhone default, `KyroUnifiedNavigation`), Live TV is a tab and is
/// never pushed, so exactly one Live TV screen exists. Otherwise (iPad, or the
/// legacy opt-out) Live TV is pushed onto the main stack, as in Build 17.
@MainActor
enum KyroLiveTVEntry {
    /// The profile menu's Live TV item.
    static func open(router: AppRouter) {
        #if os(iOS)
        if KyroUnifiedNavigation.isActive {
            KyroGlobalNavigationStore.shared.selectedDestination = .liveTV
            return
        }
        #endif
        router.navigate(to: .liveTV)
    }

    /// Whether the profile menu lists Live TV. Under the unified shell Live TV is a tab of the
    /// app's own bar, so a menu item would be a second, duplicate way to the same screen.
    static var profileMenuOffersLiveTV: Bool {
        #if os(iOS)
        profileMenuOffersLiveTV(unifiedShell: KyroUnifiedNavigation.isActive)
        #else
        true
        #endif
    }

    static func profileMenuOffersLiveTV(unifiedShell: Bool) -> Bool { !unifiedShell }

    /// Picture in Picture needs a Live TV screen to put the player on.
    static func bringForward(router: AppRouter) {
        #if os(iOS)
        if KyroUnifiedNavigation.isActive {
            KyroUnifiedNavigation.bringLiveTVForward(router: router)
            return
        }
        #endif
        router.navigate(to: .liveTV)
    }
}
