import SwiftUI
import UIKit

/// Kyro's C3 "Cinematic Halo" identity for iPhone: the approved portrait
/// backdrop, the metallic KYRO wordmark, and the halo colours the glass
/// symbols and controls draw with.
///
/// The artwork is raster (`KyroBrand.xcassets`): the backdrop is an
/// upscaled 1320×2868 image and the wordmark an RGBA image with its glow in
/// the alpha channel. The colours are sampled to sit with the halo; they are
/// not Silo design tokens.
enum KyroBrand {
    static let backdropImageName = "KyroSplashBackground"
    static let wordmarkImageName = "KyroWordmark"

    /// Pixel size of the approved backdrop. Layout is placed in its
    /// coordinates so text and symbols stay locked to the halo on every
    /// iPhone, whatever the crop.
    static let backdropPixelSize = CGSize(width: 1320, height: 2868)
    /// Wordmark image aspect (1825×498, glow padding included).
    static let wordmarkAspect: CGFloat = 498.0 / 1825.0

    static let blue = Color(red: 0.18, green: 0.36, blue: 1.0)
    static let violet = Color(red: 0.54, green: 0.24, blue: 1.0)
    static let pink = Color(red: 1.0, green: 0.25, blue: 0.64)
    static let orange = Color(red: 1.0, green: 0.48, blue: 0.10)

    /// The halo sweep, blue on the left through to orange on the right.
    static let haloGradient = LinearGradient(
        colors: [blue, violet, pink, orange],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// The cinematic splash and the introduction are drawn for the
    /// approved portrait iPhone artwork. iPad, Apple TV and Mac keep the
    /// existing Silo startup.
    @MainActor
    static var usesCinematicStartup: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }
}

/// Maps points in the backdrop artwork to the screen, matching the
/// aspect-fill crop `KyroBackdrop` draws with.
struct KyroBackdropGeometry {
    let container: CGSize

    private var scale: CGFloat {
        let art = KyroBrand.backdropPixelSize
        guard art.width > 0, art.height > 0 else { return 1 }
        return max(container.width / art.width, container.height / art.height)
    }

    /// The artwork's rendered size on screen.
    var renderedSize: CGSize {
        CGSize(
            width: KyroBrand.backdropPixelSize.width * scale,
            height: KyroBrand.backdropPixelSize.height * scale
        )
    }

    /// Screen y for a fraction of the artwork's height.
    func y(_ fraction: CGFloat) -> CGFloat {
        let overflow = (renderedSize.height - container.height) / 2
        return fraction * renderedSize.height - overflow
    }

    /// Screen length for a fraction of the artwork's width.
    func width(_ fraction: CGFloat) -> CGFloat {
        fraction * renderedSize.width
    }
}

/// The approved backdrop, aspect-filled edge to edge. It is static: the
/// splash and every introduction page share it, so it never moves.
struct KyroBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            Image(KyroBrand.backdropImageName)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The metallic KYRO wordmark, with an optional single shimmer pass. The
/// shimmer is a soft highlight masked to the letters that crosses once
/// when `shimmerProgress` animates from 0 to 1, then rests off the mark.
struct KyroWordmark: View {
    var shimmerProgress: CGFloat = 1

    var body: some View {
        Image(KyroBrand.wordmarkImageName)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let band = proxy.size.width * 0.35
                    LinearGradient(
                        colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: band)
                    .rotationEffect(.degrees(18))
                    .offset(x: -band + (proxy.size.width + band) * shimmerProgress)
                    .blendMode(.plusLighter)
                }
                .mask {
                    Image(KyroBrand.wordmarkImageName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
                .allowsHitTesting(false)
            }
            .accessibilityLabel("Kyro")
    }
}

/// A soft bloom over the halo's rim, for the splash's single breath.
struct KyroHaloBloom: View {
    let geometry: KyroBackdropGeometry
    var intensity: Double

    var body: some View {
        RadialGradient(
            colors: [
                KyroBrand.violet.opacity(0.32 * intensity),
                KyroBrand.blue.opacity(0.14 * intensity),
                .clear,
            ],
            center: UnitPoint(x: 0.5, y: geometry.y(0.40) / max(geometry.container.height, 1)),
            startRadius: 0,
            endRadius: geometry.width(0.62)
        )
        .blendMode(.plusLighter)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
