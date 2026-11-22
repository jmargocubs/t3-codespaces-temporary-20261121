import SwiftUI

/// The introduction's luminous glass symbols, drawn natively: frosted
/// panels with a halo-gradient rim and a static glow. The package ships no
/// standalone symbol artwork, so these recreate the reference mockups
/// rather than reuse them. Nothing here animates on its own.
struct KyroGlassSymbol: View {
    let symbol: KyroIntroduction.Symbol
    /// The symbol's width; heights follow from it.
    let size: CGFloat

    var body: some View {
        Group {
            switch symbol {
            case .clapperboard:
                KyroGlassClapperboard(width: size)
            case .television:
                KyroGlassTelevision(width: size * 0.95)
            case .layeredCards:
                KyroGlassLayeredCards(width: size * 1.85)
            }
        }
        .compositingGroup()
        .shadow(color: KyroBrand.blue.opacity(0.55), radius: size * 0.09, x: -size * 0.03)
        .shadow(color: KyroBrand.pink.opacity(0.40), radius: size * 0.09, x: size * 0.03)
    }
}

// MARK: - Glass material

/// A frosted panel with a halo rim: blue on the leading edge through pink to
/// orange on the trailing edge, plus a thin inner highlight.
private struct KyroGlassPanel<S: InsettableShape>: View {
    let shape: S
    var rimWidth: CGFloat = 3.5

    private var rim: LinearGradient {
        LinearGradient(
            colors: [KyroBrand.blue, KyroBrand.violet, KyroBrand.pink, KyroBrand.orange],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        shape
            .fill(
                LinearGradient(
                    colors: [.white.opacity(0.34), .white.opacity(0.12), KyroBrand.violet.opacity(0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .background(shape.fill(Color.black.opacity(0.30)))
            // Static bloom around the rim; drawn once, never animated.
            .background(
                shape
                    .stroke(rim, lineWidth: rimWidth * 3.5)
                    .blur(radius: rimWidth * 2.6)
            )
            .overlay(shape.strokeBorder(rim, lineWidth: rimWidth))
            .overlay(
                shape
                    .inset(by: rimWidth * 0.55)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 1.6)
                    .blur(radius: 0.4)
            )
    }
}

/// The glowing play triangle at the heart of each symbol.
private struct KyroGlassPlay: View {
    let height: CGFloat

    var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: height, weight: .bold))
            .foregroundStyle(
                LinearGradient(
                    colors: [.white, KyroBrand.pink.opacity(0.9), KyroBrand.violet],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .shadow(color: KyroBrand.pink.opacity(0.8), radius: height * 0.25)
    }
}

/// Diagonal clapper stripes, alternating solid and clear.
private struct KyroClapperStripes: Shape {
    var count = 5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step = rect.width / CGFloat(count)
        let lean = rect.height * 0.55
        for index in 0..<count where index.isMultiple(of: 2) == false {
            let x = rect.minX + CGFloat(index) * step
            path.move(to: CGPoint(x: x + lean, y: rect.minY))
            path.addLine(to: CGPoint(x: x + step + lean, y: rect.minY))
            path.addLine(to: CGPoint(x: x + step, y: rect.maxY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Screen 1: clapperboard

private struct KyroGlassClapperboard: View {
    let width: CGFloat

    var body: some View {
        let bodyHeight = width * 0.66
        let armHeight = width * 0.19
        VStack(spacing: width * 0.035) {
            clapperArm(height: armHeight)
                .rotationEffect(.degrees(-11), anchor: .bottomLeading)
                .offset(y: armHeight * 0.18)
            ZStack {
                KyroGlassPanel(shape: RoundedRectangle(cornerRadius: width * 0.11, style: .continuous))
                KyroGlassPlay(height: bodyHeight * 0.38)
                    .offset(x: width * 0.02)
            }
            .frame(width: width, height: bodyHeight)
        }
        .frame(width: width, height: bodyHeight + armHeight * 1.5)
        .accessibilityHidden(true)
    }

    private func clapperArm(height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: height * 0.32, style: .continuous)
        return ZStack {
            KyroGlassPanel(shape: shape, rimWidth: 2)
            KyroClapperStripes()
                .fill(.white.opacity(0.85))
                .padding(.horizontal, height * 0.25)
                .padding(.vertical, height * 0.2)
                .clipShape(shape)
        }
        .frame(width: width * 0.96, height: height)
    }
}

// MARK: - Screen 2: television

private struct KyroGlassTelevision: View {
    let width: CGFloat

    var body: some View {
        let screenHeight = width * 0.70
        let antenna = width * 0.27
        VStack(spacing: width * 0.07) {
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: width * 0.035, height: antenna)
                    .rotationEffect(.degrees(-32), anchor: .bottom)
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: width * 0.035, height: antenna)
                    .rotationEffect(.degrees(32), anchor: .bottom)
            }
            .frame(height: antenna * 0.85, alignment: .bottom)
            .padding(.bottom, -width * 0.07)

            ZStack(alignment: .topLeading) {
                KyroGlassPanel(shape: RoundedRectangle(cornerRadius: width * 0.13, style: .continuous))
                Circle()
                    .fill(KyroBrand.blue)
                    .frame(width: width * 0.045)
                    .shadow(color: KyroBrand.blue, radius: 4)
                    .padding(width * 0.08)
                KyroGlassPlay(height: screenHeight * 0.36)
                    .offset(x: width * 0.02)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: width, height: screenHeight)

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [KyroBrand.blue, KyroBrand.violet, KyroBrand.pink],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .overlay(Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 0.75))
                .frame(width: width * 0.62, height: width * 0.055)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Screen 3: layered cards

private struct KyroGlassLayeredCards: View {
    /// Width of the whole arrangement, orbit included.
    let width: CGFloat

    var body: some View {
        let card = width * 0.36
        let side = card * 0.78
        ZStack {
            orbit
                .frame(width: width, height: card * 0.42)
                .offset(y: card * 0.18)

            sideCard(systemImage: "tv", size: side)
                .rotationEffect(.degrees(-9))
                .offset(x: -card * 0.72, y: card * 0.06)
            sideCard(systemImage: "gearshape.fill", size: side)
                .rotationEffect(.degrees(9))
                .offset(x: card * 0.72, y: card * 0.06)

            frontCard(size: card)

            // The near half of the orbit passes in front of the cards.
            Ellipse()
                .trim(from: 0.06, to: 0.44)
                .stroke(orbitGradient, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: width, height: card * 0.42)
                .offset(y: card * 0.18)
                .shadow(color: KyroBrand.pink.opacity(0.8), radius: 4)
        }
        .frame(width: width, height: card * 1.25)
        .accessibilityHidden(true)
    }

    private var orbitGradient: LinearGradient {
        LinearGradient(
            colors: [KyroBrand.blue, KyroBrand.violet, KyroBrand.pink, KyroBrand.orange],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var orbit: some View {
        Ellipse()
            .stroke(orbitGradient, lineWidth: 2)
            .opacity(0.75)
            .shadow(color: KyroBrand.violet.opacity(0.8), radius: 5)
    }

    private func sideCard(systemImage: String, size: CGFloat) -> some View {
        ZStack {
            KyroGlassPanel(shape: RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
            Image(systemName: systemImage)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: KyroBrand.violet, radius: 5)
        }
        .frame(width: size * 0.92, height: size * 1.05)
    }

    private func frontCard(size: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.17, style: .continuous)
        return ZStack {
            KyroGlassPanel(shape: shape, rimWidth: 3)
            VStack(spacing: size * 0.08) {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                        .fill(.white.opacity(0.18))
                    KyroClapperStripes(count: 7)
                        .fill(.white.opacity(0.85))
                        .padding(.horizontal, size * 0.05)
                        .padding(.vertical, size * 0.035)
                }
                .frame(height: size * 0.16)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.06, style: .continuous))

                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.1, style: .continuous)
                        .strokeBorder(.white.opacity(0.45), lineWidth: 1.2)
                    KyroGlassPlay(height: size * 0.3)
                        .offset(x: size * 0.02)
                }
            }
            .padding(size * 0.12)
        }
        .frame(width: size * 1.05, height: size * 1.12)
    }
}
