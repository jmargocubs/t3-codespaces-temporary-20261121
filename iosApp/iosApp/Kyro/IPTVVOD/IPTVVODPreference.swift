#if os(iOS)
import Foundation

/// Device-local opt-in. Absence deliberately means OFF for existing installations.
enum IPTVVODPreference {
    static let key = "kyro.iptvvod.enabled"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    @MainActor
    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
        if !enabled { XtreamVODService.shared.cancel() }
    }
}
#endif
