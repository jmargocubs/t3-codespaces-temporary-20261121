#if DEBUG
import SwiftUI

/// Debug builds only: `-kyroDebugSettingsRoute` opens the real Settings
/// screen over whatever route the app is on, so Replay Introduction can be
/// exercised on a simulator with no signed-in server. Nothing here exists
/// in Release builds.
struct KyroDebugSettingsRouteModifier: ViewModifier {
    static let launchArgument = "-kyroDebugSettingsRoute"

    let router: AppRouter
    /// False while the startup splash covers the app.
    let isEnabled: Bool

    @State private var isPresented = false
    @State private var didPresent = false

    func body(content: Content) -> some View {
        content
            .modifier(KyroDebugLiveTVFixtureRouteModifier(isEnabled: isEnabled))
            .modifier(KyroDebugMediaShellRouteModifier(router: router, isEnabled: isEnabled))
            .fullScreenCover(isPresented: $isPresented) {
                NavigationStack {
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { isPresented = false }
                                    .accessibilityIdentifier("kyroDebugSettingsClose")
                            }
                        }
                }
                .environment(router)
            }
            .onChange(of: isEnabled, initial: true) { _, enabled in
                guard enabled, !didPresent,
                      CommandLine.arguments.contains(Self.launchArgument) else { return }
                didPresent = true
                KyroDebugLiveTVFixture.applyGlobalNavigationArguments(to: .shared)
                isPresented = true
            }
    }
}
#endif
