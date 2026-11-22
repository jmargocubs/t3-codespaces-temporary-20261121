import SwiftUI

/// The three introduction pages over the shared halo backdrop. The backdrop
/// never moves; each page's symbol and copy crossfade over it, rising in with
/// a short stagger. Buttons act on the first tap, mid-animation included.
///
/// The entrance waits for the startup splash to lift, so the first page's
/// reveal is seen rather than played underneath the splash.
struct KyroIntroductionView: View {
    /// Called once, by Skip or Get Started.
    let onFinish: () -> Void

    /// Positions in the backdrop artwork, read from the approved references.
    private enum Layout {
        static let wordmarkCenter: CGFloat = 0.155
        static let wordmarkWidth: CGFloat = 0.566
        static let symbolTop: CGFloat = 0.285
        static let symbolHeight: CGFloat = 0.172
        /// Below this height (iPhone SE class) the artwork is cropped top and
        /// bottom, which pushes art-anchored copy into the sunrise. There the
        /// symbol tucks up under the wordmark and shrinks instead.
        static let compactHeight: CGFloat = 760
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isStartupSplashVisible) private var isStartupSplashVisible
    @State private var pageIndex: Int
    @State private var hasEntered = false
    @State private var shimmerProgress: CGFloat = 0
    @State private var didFinish = false

    init(initialPage: Int = 0, onFinish: @escaping () -> Void) {
        let lastPage = KyroIntroduction.pages.count - 1
        _pageIndex = State(initialValue: min(max(initialPage, 0), lastPage))
        self.onFinish = onFinish
    }

    private var pages: [KyroIntroduction.Page] { KyroIntroduction.pages }
    private var page: KyroIntroduction.Page { pages[pageIndex] }
    private var isLastPage: Bool { pageIndex == pages.count - 1 }

    var body: some View {
        ZStack {
            KyroBackdrop()

            GeometryReader { proxy in
                let geometry = KyroBackdropGeometry(container: proxy.size)
                let wordmarkWidth = min(geometry.width(Layout.wordmarkWidth), 320)
                let wordmarkBottom = geometry.y(Layout.wordmarkCenter) + wordmarkWidth * KyroBrand.wordmarkAspect / 2
                let isCompact = proxy.size.height < Layout.compactHeight
                let symbolHeight = isCompact
                    ? proxy.size.height * 0.15
                    : min(geometry.renderedSize.height * Layout.symbolHeight, 180)
                let symbolTop = isCompact ? wordmarkBottom + 28 : max(geometry.y(Layout.symbolTop), 0)

                KyroWordmark(shimmerProgress: shimmerProgress)
                    .frame(width: wordmarkWidth)
                    .opacity(hasEntered ? 1 : 0)
                    .position(x: proxy.size.width / 2, y: geometry.y(Layout.wordmarkCenter))

                // Outgoing and incoming pages overlap during the crossfade.
                ZStack(alignment: .top) {
                    KyroIntroductionPageContent(
                        page: page,
                        symbolHeight: symbolHeight,
                        isActive: hasEntered
                    )
                    .id(page.id)
                    .transition(.opacity)
                }
                .frame(width: proxy.size.width)
                .padding(.top, symbolTop)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .ignoresSafeArea()

            controls
                .opacity(hasEntered ? 1 : 0)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .dynamicTypeSize(.xSmall ... .xxLarge)
        .contentShape(Rectangle())
        .gesture(swipe)
        .onAppear { enterIfReady() }
        .onChange(of: isStartupSplashVisible) { _, _ in enterIfReady() }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 0) {
            KyroPageDots(count: pages.count, current: pageIndex)
                .padding(.bottom, 22)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Page \(pageIndex + 1) of \(pages.count)")

            Button(action: advance) {
                HStack(spacing: 10) {
                    Text(isLastPage ? "Get Started" : "Next")
                        .contentTransition(.opacity)
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(KyroPrimaryButtonBackground())
                .contentShape(Capsule())
            }
            .buttonStyle(KyroPressStyle())
            .frame(maxWidth: 330)
            .padding(.horizontal, 48)
            .accessibilityIdentifier("kyroIntroPrimaryButton")

            // The last page has no Skip; its slot keeps the room so the
            // button above does not move between pages.
            ZStack {
                if !isLastPage {
                    Button(action: finish) {
                        Text("Skip")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(minWidth: 88, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("kyroIntroSkipButton")
                    .transition(.opacity)
                }
            }
            .frame(height: 44)
            .padding(.top, 6)
        }
        .padding(.bottom, 4)
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < -50, !isLastPage {
                    go(to: pageIndex + 1)
                } else if value.translation.width > 50, pageIndex > 0 {
                    go(to: pageIndex - 1)
                }
            }
    }

    // MARK: Actions

    private func enterIfReady() {
        guard !hasEntered, !isStartupSplashVisible else { return }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) { hasEntered = true }
            shimmerProgress = 1
        } else {
            withAnimation(.easeOut(duration: 0.5)) { hasEntered = true }
            withAnimation(.easeInOut(duration: 1.1).delay(0.2)) { shimmerProgress = 1 }
        }
    }

    private func advance() {
        if isLastPage {
            finish()
        } else {
            go(to: pageIndex + 1)
        }
    }

    private func go(to index: Int) {
        guard pages.indices.contains(index), index != pageIndex else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .easeInOut(duration: 0.5)) {
            pageIndex = index
        }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        onFinish()
    }
}

/// One page's symbol and copy. Each element fades and rises in on its own
/// short delay once the page is shown.
private struct KyroIntroductionPageContent: View {
    let page: KyroIntroduction.Page
    let symbolHeight: CGFloat
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var isRevealed: Bool { isActive && appeared }

    var body: some View {
        VStack(spacing: 0) {
            KyroGlassSymbol(symbol: page.symbol, size: symbolHeight)
                .frame(height: symbolHeight)
                .modifier(KyroReveal(isRevealed: isRevealed, delay: 0, rise: 18, reduceMotion: reduceMotion))

            Text(page.headline)
                .font(.system(size: 34, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 10)
                .padding(.top, 16)
                .modifier(KyroReveal(isRevealed: isRevealed, delay: 0.1, rise: 10, reduceMotion: reduceMotion))
                .accessibilityAddTraits(.isHeader)

            Text(page.message)
                .font(.system(size: 16))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .foregroundStyle(.white.opacity(0.82))
                .shadow(color: .black.opacity(0.6), radius: 8)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .modifier(KyroReveal(isRevealed: isRevealed, delay: 0.2, rise: 8, reduceMotion: reduceMotion))
        }
        .padding(.horizontal, 32)
        // A soft, static shade behind the copy keeps it legible where it
        // nears the sunrise.
        .background(alignment: .bottom) {
            Ellipse()
                .fill(.black.opacity(0.45))
                .frame(height: 170)
                .blur(radius: 36)
                .padding(.horizontal, 8)
                .opacity(isRevealed ? 1 : 0)
                .animation(.easeOut(duration: 0.4), value: isRevealed)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onAppear { appeared = true }
    }
}

/// Fades an element in and lifts it into place. Reduce Motion keeps the
/// fade only.
private struct KyroReveal: ViewModifier {
    let isRevealed: Bool
    let delay: Double
    let rise: CGFloat
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isRevealed ? 1 : 0)
            .offset(y: isRevealed || reduceMotion ? 0 : rise)
            .animation(
                reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.55).delay(delay),
                value: isRevealed
            )
    }
}

private struct KyroPageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<count, id: \.self) { index in
                let isCurrent = index == current
                Circle()
                    .fill(isCurrent ? KyroBrand.blue : .white.opacity(0.32))
                    .frame(width: 8, height: 8)
                    .overlay {
                        if isCurrent {
                            Circle()
                                .strokeBorder(.white.opacity(0.7), lineWidth: 1)
                                .frame(width: 12, height: 12)
                        }
                    }
                    .shadow(color: isCurrent ? KyroBrand.blue : .clear, radius: 6)
            }
        }
        .frame(height: 14)
    }
}

private struct KyroPrimaryButtonBackground: View {
    var body: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.24, green: 0.48, blue: 1.0),
                        Color(red: 0.10, green: 0.30, blue: 0.96),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.75), .white.opacity(0.15)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1.2
                )
            )
            .shadow(color: KyroBrand.blue.opacity(0.7), radius: 16)
    }
}

/// Presses register on touch-down with a brief dip; the action is never
/// delayed by it.
private struct KyroPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
