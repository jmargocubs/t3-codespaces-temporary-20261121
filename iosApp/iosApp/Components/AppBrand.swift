import SwiftUI

/// The app's own name, as users read it. The iPhone and iPad app is Kyro;
/// Apple TV and Mac keep their existing wording for now.
///
/// This is the app's identity only. The backend is still Silo Server, so
/// server terminology ("Silo server", "Silo password"), network contracts,
/// device names sent to the server and internal identifiers never use it.
enum AppBrand {
    #if os(iOS)
    static let name = KyroAppIdentity.current.displayName
    #else
    static let name = "Silo"
    #endif
}

/// The app's wordmark wherever a screen identifies the app. On iPhone and
/// iPad it is the approved C3 metallic KYRO mark; Apple TV and Mac keep the
/// Silo wordmark and its sizes unchanged.
struct AppWordmarkView: View {
    enum Placement {
        /// The Home header, sharing a 44pt row with icon buttons.
        case compactHeader
        /// First-run and account screens' top bar.
        case topBar
        /// Centred above a loading spinner.
        case loading
    }

    let placement: Placement

    var body: some View {
        #if os(iOS)
        // The C3 image carries its glow inside the frame: letters fill about
        // 94% of its width and 78% of its height. Widths are chosen for letter
        // height (about 20, 25 and 33pt), close to the old mark's weight.
        Image(KyroBrand.wordmarkImageName)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: kyroWidth)
            .accessibilityLabel(AppBrand.name)
        #else
        SiloWordmarkView(width: siloWidth)
        #endif
    }

    #if os(iOS)
    private var kyroWidth: CGFloat {
        switch placement {
        case .compactHeader: 94
        case .topBar: 118
        case .loading: 156
        }
    }
    #else
    private var siloWidth: CGFloat {
        switch placement {
        case .compactHeader: 72
        case .topBar: 92
        case .loading: 132
        }
    }
    #endif
}
