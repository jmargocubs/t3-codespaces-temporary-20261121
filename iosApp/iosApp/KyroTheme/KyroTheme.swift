import SwiftUI

/// Kyro's C3 "Cinematic Halo" palette as semantic roles. Live TV, Kyro's
/// floating navigation and glass, and the iPhone app shell all draw from
/// here, so Media Server and Live TV read as one app.
///
/// Kyro-owned and platform-neutral (it sits outside `Kyro/`, which only the
/// iOS target builds), because Live TV also compiles for tvOS and macOS.
/// The brand values match Silo's `siloBrand*` samples; they are not new
/// upstream tokens. Artwork, channel logos and provider branding are never
/// tinted with these, and the warning, error and success colours stay Silo's.
enum KyroTheme {
    // MARK: Brand values

    /// Electric blue: filled controls with white content (white on it 7.3:1).
    static let accent = Color(hex: "#0034FB")
    /// Electric blue lifted toward white for text, icons, tints and thin
    /// indicators on black (7.1:1 on black, 4.7:1 on #2C2C2E). `accent`
    /// itself is only 2.9:1 on black.
    static let accentInk = Color(hex: "#738FFD")
    /// Deep blue for glass depth and glows.
    static let depth = Color(hex: "#010D9F")
    /// Pink-red, reserved for LIVE.
    static let live = Color(hex: "#F50B4F")
    /// Orange, a restrained secondary highlight (favorites). Never navigation.
    static let highlight = Color(hex: "#FD7403")

    // MARK: Surfaces

    /// Cinematic black.
    static let background = Color(hex: "#000000")
    /// Opaque glass for Reduce Transparency: deep blue-black.
    static let glassOpaque = Color(hex: "#0A0E22")
    /// The blue cast laid over clear-glass material.
    static let glassTint = depth.opacity(0.42)
    /// Metallic silver rim shared by every Kyro glass edge.
    static let glassRim = LinearGradient(colors: [Color.white.opacity(0.42), Color.white.opacity(0.08),
                                                  accentInk.opacity(0.3)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)

    // MARK: Text

    /// Primary text and icons: white.
    static let textPrimary = Color.white
    /// Cool gray for secondary text (9.6:1 on black).
    static let textSecondary = Color(hex: "#A7B0C2")
    /// Metallic silver for brand marks and resting icons.
    static let silver = Color(hex: "#E4E8F0")

    // MARK: Selection

    /// Fill behind a selected chip or pill.
    static let selectedFill = accent.opacity(0.30)
    /// Border of a selected chip or pill.
    static let selectedBorder = accentInk.opacity(0.55)
    /// The active destination's gradient in Kyro's navigation.
    static let activeGradient = LinearGradient(colors: [accent, depth], startPoint: .top, endPoint: .bottom)

    /// The interactive tint for the app shell: electric-blue ink on iPhone and
    /// iPad, Silo's near-white elsewhere (Apple TV focus and the Mac keep theirs).
    static var shellTint: Color {
        #if os(iOS)
        accentInk
        #else
        Color.siloOnSurface
        #endif
    }
}
