#if os(iOS)
import SwiftUI

/// Build 110's interim access to a matched title's other sources: a compact row under the
/// existing Silo or IPTV detail. It only opens the alternate's own IPTV detail (pushed inside the
/// card, so Back returns here); it never chooses or starts playback. Build 111 replaces it with
/// the Sources picker.
struct KyroAlternateSourcesInset: ViewModifier {
    let alternates: [KyroIPTVDetailRequest]
    /// The card's bottom safe-area inset. The detail sheet paints through the home-indicator
    /// strip, so the row is lifted above it explicitly.
    var bottomInset: CGFloat = 0
    let onOpen: (KyroIPTVDetailRequest) -> Void

    func body(content: Content) -> some View {
        if alternates.isEmpty {
            content
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                bar
                    .padding(.horizontal, SiloTheme.padding)
                    .padding(.bottom, bottomInset + 8)
            }
        }
    }

    @ViewBuilder
    private var bar: some View {
        if alternates.count == 1, let only = alternates.first {
            Button { onOpen(only) } label: { label(text: "Also on IPTV · \(only.providerName)") }
                .buttonStyle(.plain)
                .accessibilityHint("Opens this title's IPTV details")
        } else {
            Menu {
                ForEach(alternates, id: \.pageIdentity) { request in
                    Button("IPTV · \(request.providerName)") { onOpen(request) }
                }
            } label: {
                label(text: "Also on \(alternates.count) IPTV sources")
            }
            .accessibilityHint("Choose an IPTV source to open its details")
        }
    }

    private func label(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
            Text(text).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
        }
        .font(.siloCaption)
        .foregroundColor(.siloOnSurface)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .contentShape(Capsule())
    }
}
#endif
