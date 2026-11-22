import SwiftUI

// Live TV's chrome when it is a tab of the app's own bar (Kyro's unified navigation). The shell
// draws the one Kyro header (`KyroAppHeader`) over the tab content. The channel browser (Search
// results, Favorites, Channels, a category) is a real pushed screen on the app's stack, like the
// Guide: it uses the system navigation bar and Back, so the interactive edge swipe works.

extension View {
    /// The channel browser's search field, pinned under the navigation bar so the list scrolls
    /// beneath it.
    func liveTVBrowserSearchField<Field: View>(@ViewBuilder _ field: () -> Field) -> some View {
        safeAreaInset(edge: .top, spacing: 0, content: field)
    }
}
