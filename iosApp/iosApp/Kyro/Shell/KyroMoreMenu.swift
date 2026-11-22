import SwiftUI

/// A secondary Silo root exposed from Kyro's shared application header.
/// Actions push a distinct Route; they never mutate global tab selection.
struct KyroMoreMenuItem: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let action: () -> Void
}

struct KyroMoreMenuContext {
    let items: [KyroMoreMenuItem]
}

extension EnvironmentValues {
    @Entry var kyroMoreMenu: KyroMoreMenuContext? = nil
}

/// An adaptive, non-persistent menu control. It vanishes outside an
/// authenticated shell that supplied supported secondary destinations.
struct KyroMoreMenuButton: View {
    @Environment(\.kyroMoreMenu) private var context

    var body: some View {
        if let context, !context.items.isEmpty {
            Menu {
                ForEach(context.items) { item in
                    Button(action: item.action) {
                        Label(item.title, systemImage: item.systemImage)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.siloOnSurface)
                    .frame(width: SiloTheme.topBarIconHitSize, height: SiloTheme.topBarIconHitSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More destinations")
            .accessibilityIdentifier("kyroMoreMenu")
        }
    }
}

/// Which secondary roots More offers. More lists purposeful extras, not a second copy of the
/// shell: it hides a destination the Movies or Series tab already presents, and it never
/// lists Collections as a destination of its own. Collections is a library feature, reached
/// through each Movies and Series library's Recommended / Library / Collections chips.
///
/// Decisions use the resolved destination identity and the library's type, not the display
/// name, with one narrow exception described at `isCollectionsNamedLibraryInsideACategory`.
enum KyroMoreEligibility {
    static func isEligible(_ destination: MainTabDestination, among libraries: [Library]) -> Bool {
        switch destination.id {
        case .liveTV, .kyroRoot:
            // Tabs of the shell, with no secondary route to open.
            return false
        case .app, .libraryCategory:
            return true
        case .library(let id):
            guard let library = libraries.first(where: { $0.id == id }) else { return true }
            if isCollectionTypedLibrary(library) { return false }
            if isCollectionsNamedLibraryInsideACategory(library, title: destination.title, among: libraries) {
                return false
            }
            return !isSoleLibraryOfItsCategories(library, among: libraries)
        }
    }

    /// A library whose own type says it is a collections surface. Supported library types
    /// never include one, so this holds for a type the server adds later.
    static func isCollectionTypedLibrary(_ library: Library) -> Bool {
        let type = library.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return type.contains("collection") || type == "boxset" || type == "boxsets"
    }

    /// The Movies and Series tabs already show every library of their category and switch
    /// between them. A library that is the only one in each tab it belongs to is that tab
    /// exactly, so listing it in More only repeats the tab. With sibling libraries (a Kids
    /// movie library next to Movies) it stays: it is a shortcut the tab doesn't give.
    static func isSoleLibraryOfItsCategories(_ library: Library, among libraries: [Library]) -> Bool {
        let inMovies = libraryMatchesPrimaryMenuCategory(library, category: .movies)
        let inSeries = libraryMatchesPrimaryMenuCategory(library, category: .series)
        guard inMovies || inSeries else { return false }
        func count(_ category: PrimaryMenuBuiltin) -> Int {
            libraries.filter { libraryMatchesPrimaryMenuCategory($0, category: category) }.count
        }
        return (!inMovies || count(.movies) == 1) && (!inSeries || count(.series) == 1)
    }

    /// The server's menu can pin a Movies or Series library under the name "Collections".
    /// Inside a Movies or Series tab that library is reachable, and its Collections chip is
    /// the intended home. The name alone never removes anything: it must also resolve into
    /// a category tab, so an unrelated library keeps its place.
    static func isCollectionsNamedLibraryInsideACategory(_ library: Library, title: String,
                                                          among libraries: [Library]) -> Bool {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.caseInsensitiveCompare("Collections") == .orderedSame else { return false }
        return libraryMatchesPrimaryMenuCategory(library, category: .movies)
            || libraryMatchesPrimaryMenuCategory(library, category: .series)
    }
}
