import Foundation

/// Which Kyro application this build is, and every local-storage name that must differ between
/// the two.
///
/// Stable Kyro and Kyro Labs run side by side on one device, usually signed by the same
/// team. Sandbox containers already differ by bundle ID, but three stores are shared whenever
/// two apps use the same names: the App Group container, the Keychain access group, and the
/// Keychain service and account names inside it. This type is the one place those names are
/// chosen, so Labs cannot read, overwrite, migrate or delete stable Kyro's tokens, provider
/// secrets, preferences or caches by accident.
///
/// Foundation only, so Top Shelf, the Notification Service and standalone host tests compile it.
/// The build selects the variant through the `KyroAppVariant` Info.plist key
/// (`Signing/KyroVariant.xcconfig`). A missing or unknown value means `stable`, which keeps
/// every existing process (Top Shelf, tests, tvOS) on Build 110's exact names.
struct KyroAppIdentity: Equatable, Sendable {
    enum Variant: String, Sendable, CaseIterable {
        case stable
        case labs
    }

    let variant: Variant
    /// What the app calls itself in text.
    let displayName: String
    let bundleID: String
    /// App Group container and its `UserDefaults` suite.
    let appGroup: String
    /// The Keychain access group without the team prefix (`$(AppIdentifierPrefix)` precedes it).
    let keychainGroupSuffix: String
    /// Keychain service every account item lives under.
    let keychainService: String
    /// Every account item name begins with this.
    let keychainAccountPrefix: String
    /// Keychain service holding IPTV provider secrets.
    let liveTVKeychainService: String
    /// Keychain service of the EPG fingerprint key.
    let epgKeyKeychainService: String
    /// The `scheme://` this app registers and generates for its own deep links.
    let urlScheme: String
    /// Schemes (besides `urlScheme`) this app accepts as its own.
    let legacyURLSchemes: [String]
    /// Pre-rename Keychain service and account prefix, moved to the current names on first
    /// read. `nil` means no migration: Labs never touched those items and must not move them.
    let legacyKeychainService: String?
    let legacyKeychainAccountPrefix: String?

    static let stable = KyroAppIdentity(
        variant: .stable,
        displayName: "Kyro",
        bundleID: "com.cubbiestream.kyro",
        appGroup: "group.com.cubbiestream.kyro",
        keychainGroupSuffix: "com.cubbiestream.kyro.shared",
        keychainService: "com.cubbiestream.kyro",
        keychainAccountPrefix: "com.cubbiestream.kyro.",
        liveTVKeychainService: "com.cubbiestream.kyro.livetv",
        epgKeyKeychainService: "com.cubbiestream.kyro.livetv.epg-source-key",
        urlScheme: "kyro",
        legacyURLSchemes: ["silo"],
        legacyKeychainService: "com.continuum.app",
        legacyKeychainAccountPrefix: "com.continuum."
    )

    static let labs = KyroAppIdentity(
        variant: .labs,
        displayName: "Kyro Labs",
        bundleID: "com.cubbiestream.kyro.labs",
        appGroup: "group.com.cubbiestream.kyrolabs",
        keychainGroupSuffix: "com.cubbiestream.kyrolabs.shared",
        keychainService: "com.cubbiestream.kyrolabs",
        keychainAccountPrefix: "com.cubbiestream.kyrolabs.",
        liveTVKeychainService: "com.cubbiestream.kyrolabs.livetv",
        epgKeyKeychainService: "com.cubbiestream.kyrolabs.livetv.epg-source-key",
        urlScheme: "kyrolabs",
        legacyURLSchemes: [],
        legacyKeychainService: nil,
        legacyKeychainAccountPrefix: nil
    )

    static func identity(forVariant raw: String?) -> KyroAppIdentity {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value.flatMap(Variant.init(rawValue:)) {
        case .labs: return .labs
        case .stable, nil: return .stable
        }
    }

    /// This process's identity, from the `KyroAppVariant` Info.plist key.
    static let current: KyroAppIdentity = identity(
        forVariant: Bundle.main.object(forInfoDictionaryKey: "KyroAppVariant") as? String
    )

    var isLabs: Bool { variant == .labs }

    /// Names that name local storage or routing. Used by tests to prove no value is shared.
    var isolatedNames: [String: String] {
        [
            "bundleID": bundleID,
            "appGroup": appGroup,
            "keychainGroupSuffix": keychainGroupSuffix,
            "keychainService": keychainService,
            "keychainAccountPrefix": keychainAccountPrefix,
            "liveTVKeychainService": liveTVKeychainService,
            "epgKeyKeychainService": epgKeyKeychainService,
            "urlScheme": urlScheme,
        ]
    }
}
