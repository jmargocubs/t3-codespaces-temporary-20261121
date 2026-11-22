import SwiftUI

/// Kyro's clear dark glass: native material tinted toward the C3 deep blue,
/// with a thin silver rim. Reduce Transparency swaps the material for an
/// opaque fill. iOS 18 APIs only.
private struct KyroGlassBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    var glow: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if reduceTransparency {
                        shape.fill(KyroTheme.glassOpaque)
                    } else {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(LinearGradient(colors: [KyroTheme.glassTint, Color.black.opacity(0.38)],
                                                  startPoint: .top, endPoint: .bottom))
                    }
                    shape.strokeBorder(KyroTheme.glassRim, lineWidth: 1)
                }
                .environment(\.colorScheme, .dark)
                .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                .shadow(color: KyroTheme.accent.opacity(glow ? 0.4 : 0.16), radius: 20)
            }
    }
}

extension View {
    func kyroGlass<S: InsettableShape>(_ shape: S, glow: Bool = false) -> some View {
        modifier(KyroGlassBackground(shape: shape, glow: glow))
    }
}
