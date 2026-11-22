#if os(iOS)
import SwiftUI

/// A titled horizontal poster rail drawn with `MediaRow`'s iOS header and strip metrics: the
/// same headline font, safe-area gutter, card spacing, top alignment, settle behaviour and
/// phone rail bounds.
///
/// `MediaRow` is bound to Silo's `SectionItem` and opens Silo's item detail for every card, so
/// catalogs that are not Silo items (the IPTV provider catalog) draw their `MediaCard`s in this
/// rail instead of copying the styling.
struct PosterShelf<Item: Identifiable, Card: View>: View {
    let title: String
    let items: [Item]
    var onSeeAll: (() -> Void)? = nil
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: SiloTheme.smallPadding) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.siloHeadline)
                    .foregroundColor(.siloOnSurface)
                    .lineLimit(1)
                Spacer()
                if let onSeeAll {
                    Button("See All", action: onSeeAll)
                        .font(.siloCaption)
                        .foregroundColor(.siloOnSurface.opacity(0.6))
                }
            }
            .padding(.horizontal, SiloTheme.safePadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: HorizontalMediaRailLayout.cardAlignment, spacing: SiloTheme.spacing) {
                    ForEach(items) { item in
                        card(item)
                    }
                }
                .scrollTargetLayout()
                .phoneMediaRailBounds()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentMargins(.horizontal, SiloTheme.safePadding, for: .scrollContent)
            .mediaRailScrolling()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
