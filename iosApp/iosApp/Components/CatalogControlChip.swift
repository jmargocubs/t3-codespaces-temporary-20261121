import SwiftUI

/// The glass capsule used for a catalog grid's Sort, Filter, Shuffle and category controls.
/// Moved out of `BrowseView` unchanged so the IPTV catalog's controls are the same component.
struct CatalogControlChip: View {
    let icon: String
    let text: String
    var trailing: String? = nil
    var badge: Int? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(.siloBody)
            if let trailing {
                Text(trailing)
                    .font(.siloCaption)
                    .foregroundColor(.siloSecondaryText)
            }
            if let badge, badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.siloBackground)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.siloOnSurface))
            }
        }
        .foregroundColor(.siloOnSurface)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .siloGlass(in: .capsule)
    }
}
