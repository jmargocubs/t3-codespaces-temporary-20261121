import SwiftUI

/// Kyro's iPhone startup splash: the halo backdrop fades up from the black
/// launch screen, the KYRO wordmark settles in with one shimmer pass, and the
/// halo breathes once. It signals `onFinished` on the same contract as
/// `StartupSplashView`; the app keeps building underneath it.
///
/// Every animation runs once. Nothing repeats, so the splash stops drawing as
/// soon as its entrance settles.
struct KyroCinematicSplashView: View {
    /// Long enough to read the mark, short enough not to hold anyone up.
    static let displayDuration: Duration = .milliseconds(2200)
    static let reducedMotionDuration: Duration = .milliseconds(900)

    /// The approved preview centres the mark on the halo: 70.5% of the art's
    /// width (letters at 66%), at 46.3% of its height.
    static let wordmarkWidthFraction: CGFloat = 0.705
    static let wordmarkCenterFraction: CGFloat = 0.463

    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var backdropVisible = false
    @State private var wordmarkVisible = false
    @State private var shimmerProgress: CGFloat = 0
    @State private var bloom: Double = 0

    var body: some View {
        GeometryReader { proxy in
            let geometry = KyroBackdropGeometry(container: proxy.size)
            let wordmarkWidth = min(geometry.width(Self.wordmarkWidthFraction), proxy.size.width * 0.86)

            ZStack {
                Color.black

                KyroBackdrop()
                    .opacity(backdropVisible ? 1 : 0)

                KyroHaloBloom(geometry: geometry, intensity: bloom)

                KyroWordmark(shimmerProgress: shimmerProgress)
                    .frame(width: wordmarkWidth)
                    .scaleEffect(wordmarkVisible || reduceMotion ? 1 : 0.96)
                    .opacity(wordmarkVisible ? 1 : 0)
                    .position(x: proxy.size.width / 2, y: geometry.y(Self.wordmarkCenterFraction))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading Kyro")
        .task { await play() }
    }

    private func play() async {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) {
                backdropVisible = true
                wordmarkVisible = true
                shimmerProgress = 1
            }
            try? await Task.sleep(for: Self.reducedMotionDuration)
        } else {
            let start = ContinuousClock.now
            withAnimation(.easeOut(duration: 0.8)) { backdropVisible = true }
            withAnimation(.easeInOut(duration: 0.9).delay(0.2)) { bloom = 1 }
            withAnimation(.easeOut(duration: 0.7).delay(0.25)) { wordmarkVisible = true }
            withAnimation(.easeInOut(duration: 1.0).delay(0.6)) { shimmerProgress = 1 }
            // Exhale: the bloom settles to a soft glow rather than snapping off.
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.9)) { bloom = 0.35 }
            try? await Task.sleep(until: start + Self.displayDuration, clock: .continuous)
        }
        guard !Task.isCancelled else { return }
        onFinished()
    }
}
