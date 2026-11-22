#if os(iOS)
import SwiftUI

/// Movies and Series share one catalog. Recommended and Collections remain Silo-scoped;
/// their existing library selector and behavior are intentionally unchanged.
struct KyroMediaSourceRoot: View {
    let category: PrimaryMenuBuiltin
    let libraryAuthority: MainTabLibraryAuthority?
    let onLibrariesLoaded: ((MainTabLibraryAuthority?, [Library]) -> Void)?

    var body: some View {
        LibrariesTabView(
            category: category,
            libraryAuthority: libraryAuthority,
            onLibrariesLoaded: onLibrariesLoaded,
            unifiedCatalog: { libraries in
                AnyView(KyroUnifiedBrowseView(
                    kind: category == .movies ? .movie : .series,
                    libraries: libraries
                ))
            }
        )
    }
}
#endif
