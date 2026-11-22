import Foundation
import Observation

/// Device-local Seekr scrub-preview preferences.
///
/// The enable toggle is global. Preview sync offsets are stored per title and
/// default to zero. Offsets are never derived from duration differences.
/// Isolation matches ``PlayerSettings``: UserDefaults-backed and callable from
/// ``SettingsViewModel`` without a whole-type `@MainActor` annotation.
@Observable
final class SeekrPreviewSettings {
    static let shared = SeekrPreviewSettings()

    static let enabledDefaultsKey = "kyro.seekr.previewsEnabled"
    /// Posted on the main queue when the global enable toggle changes.
    /// `userInfo["enabled"]` is a `Bool`.
    static let previewsEnabledDidChangeNotification = Notification.Name(
        "kyro.seekr.previewsEnabledDidChange"
    )
    private static let syncDefaultsPrefix = "kyro.seekr.syncOffsetMs."

    /// When false, Seekr is never contacted and existing playback is unchanged.
    private(set) var previewsEnabled: Bool {
        didSet {
            defaults.set(previewsEnabled, forKey: Self.enabledDefaultsKey)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.enabledDefaultsKey) == nil {
            // On when a key is present so first-run with local config works;
            // off otherwise so missing credentials do not trigger lookups.
            previewsEnabled = SeekrCredentials.apiKey() != nil
        } else {
            previewsEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        }
    }

    func setPreviewsEnabled(_ enabled: Bool) {
        guard previewsEnabled != enabled else { return }
        previewsEnabled = enabled
        NotificationCenter.default.post(
            name: Self.previewsEnabledDidChangeNotification,
            object: self,
            userInfo: ["enabled": enabled]
        )
    }

    /// Manual preview sync for one title, in milliseconds. Defaults to 0.
    func syncOffsetMs(forTitleKey titleKey: String) -> Int {
        let key = Self.syncDefaultsPrefix + titleKey
        guard defaults.object(forKey: key) != nil else { return 0 }
        return defaults.integer(forKey: key)
    }

    func setSyncOffsetMs(_ milliseconds: Int, forTitleKey titleKey: String) {
        let clamped = max(-120_000, min(milliseconds, 120_000))
        defaults.set(clamped, forKey: Self.syncDefaultsPrefix + titleKey)
    }

    func clearSyncOffset(forTitleKey titleKey: String) {
        defaults.removeObject(forKey: Self.syncDefaultsPrefix + titleKey)
    }
}
