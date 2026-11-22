import Foundation

/// Which catalog a Movies or Series page shows, and which it keeps mounted, when an alternate
/// source (Kyro's IPTV provider) is offered beside the page's Silo libraries.
///
/// Once shown, the alternate source's page stays mounted beside the Silo tab, so switching back
/// and forth keeps both scroll positions and loaded pages. It is dropped when the offered source
/// changes (another provider) or goes away (IPTV VOD turned off), so a page built for the old
/// provider never returns to the screen.
///
/// Detail navigation keeps no state here: posters of both sources open the app's detail card
/// through `AppRouter`, so switching sources can't strand a pushed page.
struct LibraryPageSourceState: Equatable {
    /// The alternate source on offer; nil while the page has only Silo libraries.
    private(set) var offeredAlternateID: String?
    /// The alternate source whose page is mounted.
    private(set) var mountedAlternateID: String?

    init() {}

    /// Whether the alternate source is on screen: chosen, or the only catalog this page has once
    /// its Silo libraries are known.
    static func showsAlternate(
        isOffered: Bool,
        isSelected: Bool,
        hasActiveLibrary: Bool,
        isLoadingLibraries: Bool
    ) -> Bool {
        guard isOffered else { return false }
        return isSelected || (!hasActiveLibrary && !isLoadingLibraries)
    }

    mutating func update(offeredAlternateID: String?, showsAlternate: Bool) {
        if offeredAlternateID != self.offeredAlternateID {
            self.offeredAlternateID = offeredAlternateID
            mountedAlternateID = nil
        }
        if showsAlternate, let offeredAlternateID {
            mountedAlternateID = offeredAlternateID
        }
    }

    func mountsAlternate(_ id: String) -> Bool {
        mountedAlternateID == id
    }
}
