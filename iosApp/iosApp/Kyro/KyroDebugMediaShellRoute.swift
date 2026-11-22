#if DEBUG
import SwiftUI

/// Debug builds only: `-kyroDebugMediaShell` presents the Media Server shell's
/// styling with no server, so its C3 palette can be compared with Live TV on
/// a simulator. It is a harness, not Home: the rows are placeholder artwork,
/// but the colours come from the shipping sources — the `TabView` with the
/// shell's `KyroTheme.shellTint`, `AppTab`'s titles and icons, the real
/// `TabTopBarActions` header and wordmark, the Skyline selected and resting
/// pill tokens, and `DefaultArtwork`. `-kyroDebugMediaShellLegacy` swaps in
/// the Build 14 values (near-white tint, white selected pill) for a
/// before-and-after on the same screen. Nothing here exists in Release builds.
struct KyroDebugMediaShellRouteModifier: ViewModifier {
    static let launchArgument = "-kyroDebugMediaShell"

    let router: AppRouter
    let isEnabled: Bool

    @State private var isPresented = false
    @State private var didPresent = false

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $isPresented) {
                KyroDebugMediaShell()
                    .environment(router)
                    .environment(SiloControlClient())
            }
            .onChange(of: isEnabled, initial: true) { _, enabled in
                guard enabled, !didPresent, CommandLine.arguments.contains(Self.launchArgument) else { return }
                didPresent = true
                isPresented = true
            }
    }
}

private enum KyroDebugMediaShellPalette {
    static let isLegacy = CommandLine.arguments.contains("-kyroDebugMediaShellLegacy")
    static var tint: Color { isLegacy ? Color.siloOnSurface : KyroTheme.shellTint }
    static var selectedFill: Color { isLegacy ? Color.white.opacity(0.14) : Color.siloChromeSelectedFill }
    static var selectedBorder: Color { isLegacy ? Color.white.opacity(0.10) : Color.siloChromeSelectedBorder }
}

private struct KyroDebugMediaShell: View {
    @State private var selection = AppTab.home.id

    var body: some View {
        // The shell's own bar, as `MainTabView` builds it.
        SiloTabBar(items: AppTab.visibleCases + [.downloads], selection: $selection, title: \.rawValue,
                   icon: \.icon, selectedIcon: \.selectedIcon) { _ in
            KyroDebugMediaHome()
        }
        // The same tint `MainTabView` applies.
        .tint(KyroDebugMediaShellPalette.tint)
        .preferredColorScheme(.dark)
    }
}

private struct KyroDebugMediaHome: View {
    @State private var filter = "All"
    private let filters = ["All", "Movies", "Shows", "Unwatched"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    AppWordmarkView(placement: .compactHeader)
                    Spacer(minLength: 8)
                    TabTopBarActions(onSearch: {}, onOpenSettings: {}, onOpenRequests: {},
                                     onSwitchProfile: {}, onSwitchServer: {}, onSignOut: {})
                }
                .padding(.horizontal, SiloTheme.padding)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(filters, id: \.self) { name in
                            let isSelected = filter == name
                            Button(name) { filter = name }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.siloOnSurface)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(isSelected ? KyroDebugMediaShellPalette.selectedFill
                                                                      : Color.siloChromeRestingFill))
                                .overlay(Capsule().stroke(isSelected ? KyroDebugMediaShellPalette.selectedBorder
                                                                     : Color.siloChromeRestingBorder, lineWidth: 1))
                                .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, SiloTheme.padding)
                }

                row("Continue Watching", wide: true)
                row("Recently Added", wide: false)
                row("Because You Watched", wide: false)

                Button("See All Movies") {}
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, SiloTheme.padding)
            }
            .padding(.vertical, 12)
        }
        .background(Color.siloBackground)
        .accessibilityIdentifier("kyroDebugMediaHome")
    }

    private func row(_ title: String, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.siloOnSurface)
                .padding(.horizontal, SiloTheme.padding)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(0..<6, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 6) {
                            DefaultArtwork(symbol: wide ? "tv" : "film")
                                .frame(width: wide ? 220 : 116, height: wide ? 124 : 174)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(alignment: .bottom) {
                                    if wide {
                                        Capsule().fill(Color.siloOnSurface.opacity(0.25)).frame(height: 3)
                                            .overlay(alignment: .leading) {
                                                Capsule().fill(Color.siloOnSurface)
                                                    .frame(width: CGFloat(40 + index * 22), height: 3)
                                            }
                                            .padding(10)
                                    }
                                }
                            Text("Title \(index + 1)")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.siloOnSurface)
                            Text("2024 · Drama")
                                .font(.caption)
                                .foregroundStyle(Color.siloSecondaryText)
                        }
                    }
                }
                .padding(.horizontal, SiloTheme.padding)
            }
        }
    }
}
#endif
