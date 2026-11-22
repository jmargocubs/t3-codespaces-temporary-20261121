import Foundation
import Observation

/// Every root Kyro's global navigation can show. The tab bar always shows five:
/// Home, Movies, Series, the user's chosen fourth tab, and Live TV. Live TV's
/// Guide, Search, Favorites, and Channels remain contextual screens, not
/// global destinations.
enum KyroGlobalDestination: String, Codable, CaseIterable, Identifiable, Sendable {
    case home
    case movies
    case series
    case sports
    case forYou
    case favorites
    case liveTV

    var id: String { rawValue }

    /// The five tabs, in order, for a fourth-tab choice.
    static func tabDestinations(fourthTab: KyroFourthTab) -> [Self] {
        [.home, .movies, .series, fourthTab.destination, .liveTV]
    }
}

/// The user's choice for the tab between Series and Live TV. Sports by
/// default; whichever is not chosen stays reachable elsewhere (For You from
/// the profile menu and Favorites from its usual screens).
enum KyroFourthTab: String, Codable, CaseIterable, Identifiable, Sendable {
    case sports
    case forYou
    case favorites

    static let `default`: Self = .sports

    var id: String { rawValue }

    var destination: KyroGlobalDestination {
        switch self {
        case .sports: .sports
        case .forYou: .forYou
        case .favorites: .favorites
        }
    }

    var title: String {
        switch self {
        case .sports: "Sports"
        case .forYou: "For You"
        case .favorites: "Favorites"
        }
    }

    var systemImage: String {
        switch self {
        case .sports: "trophy"
        case .forYou: "sparkles"
        case .favorites: "heart"
        }
    }

    var selectedSystemImage: String {
        switch self {
        case .sports: "trophy.fill"
        case .forYou: "sparkles"
        case .favorites: "heart.fill"
        }
    }
}

/// Global navigation presentation. This choice applies to the whole app.
enum KyroNavigationPresentationStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case classic
    case glassDock
    case thumbFan

    var id: String { rawValue }

    var isFloating: Bool { self != .classic }
}

/// Device-local global navigation preferences. Version 1 has no per-destination
/// visibility or ordering; only the fourth tab is chosen. A missing
/// `fourthTab` (saved before it existed) or an unsupported retired value reads
/// as the default, so no schema bump is needed. The schema version is also
/// stored in the preference key.
struct KyroGlobalNavigationPreferences: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    private(set) var schemaVersion = currentSchemaVersion
    var style: KyroNavigationPresentationStyle = .classic
    var autoCollapse = true
    var idleBehavior: KyroLiveTVNavigationIdleBehavior = .collapse
    var hapticsEnabled = true
    var thumbScrubbing = true
    var allowsDragging = true
    var startingEdge: KyroNavigationEdge = .right
    var fourthTab: KyroFourthTab = .default
    private var dockAnchor: KyroNavigationAnchor?
    private var fanAnchor: KyroNavigationAnchor?

    init() {}

    /// The existing gesture presentation consumes an anchor for either
    /// floating style; Classic has no saved position.
    func anchor(for style: KyroNavigationPresentationStyle) -> KyroNavigationAnchor {
        let saved: KyroNavigationAnchor? = switch style {
        case .glassDock: dockAnchor
        case .thumbFan: fanAnchor
        case .classic: nil
        }
        return saved ?? .default(for: startingEdge)
    }

    mutating func setAnchor(_ anchor: KyroNavigationAnchor, for style: KyroNavigationPresentationStyle) {
        switch style {
        case .glassDock: dockAnchor = anchor
        case .thumbFan: fanAnchor = anchor
        case .classic: break
        }
    }

    mutating func resetPositions() {
        dockAnchor = nil
        fanAnchor = nil
    }

    /// Copies only preferences compatible with global navigation. The old
    /// Live TV destination order and hidden set are intentionally ignored.
    init(migrating legacy: KyroLiveTVNavigationPreferences) {
        self.init()
        style = KyroNavigationPresentationStyle(rawValue: legacy.style.rawValue) ?? .classic
        autoCollapse = legacy.autoCollapse
        idleBehavior = legacy.idleBehavior
        hapticsEnabled = legacy.hapticsEnabled
        thumbScrubbing = legacy.thumbScrubbing
        allowsDragging = legacy.allowsDragging
        startingEdge = legacy.startingEdge

        // Keep both positions even when Classic is currently selected: a
        // user may switch back to either floating presentation later.
        setAnchor(legacy.anchor(for: .glassDock), for: .glassDock)
        setAnchor(legacy.anchor(for: .thumbFan), for: .thumbFan)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, style, autoCollapse, idleBehavior, hapticsEnabled,
             thumbScrubbing, allowsDragging, startingEdge, fourthTab, dockAnchor, fanAnchor
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? {
            try? values.decodeIfPresent(T.self, forKey: key)
        }
        let defaults = Self()
        let decodedVersion: Int = value(.schemaVersion) ?? Self.currentSchemaVersion
        schemaVersion = decodedVersion == Self.currentSchemaVersion
            ? decodedVersion
            : Self.currentSchemaVersion
        style = value(.style) ?? defaults.style
        autoCollapse = value(.autoCollapse) ?? defaults.autoCollapse
        idleBehavior = value(.idleBehavior) ?? defaults.idleBehavior
        hapticsEnabled = value(.hapticsEnabled) ?? defaults.hapticsEnabled
        thumbScrubbing = value(.thumbScrubbing) ?? defaults.thumbScrubbing
        allowsDragging = value(.allowsDragging) ?? defaults.allowsDragging
        startingEdge = value(.startingEdge) ?? defaults.startingEdge
        fourthTab = value(.fourthTab) ?? defaults.fourthTab
        dockAnchor = value(.dockAnchor)
        fanAnchor = value(.fanAnchor)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try values.encode(style, forKey: .style)
        try values.encode(autoCollapse, forKey: .autoCollapse)
        try values.encode(idleBehavior, forKey: .idleBehavior)
        try values.encode(hapticsEnabled, forKey: .hapticsEnabled)
        try values.encode(thumbScrubbing, forKey: .thumbScrubbing)
        try values.encode(allowsDragging, forKey: .allowsDragging)
        try values.encode(startingEdge, forKey: .startingEdge)
        try values.encode(fourthTab, forKey: .fourthTab)
        try values.encodeIfPresent(dockAnchor, forKey: .dockAnchor)
        try values.encodeIfPresent(fanAnchor, forKey: .fanAnchor)
    }
}

/// Sole owner of the selected global destination and global preferences.
/// Selection is session state; preferences persist locally between launches.
@MainActor
@Observable
final class KyroGlobalNavigationStore {
    static let shared = KyroGlobalNavigationStore()
    static let defaultsKey = "kyro.navigation.global.v1"
    static let legacyLiveTVDefaultsKey = KyroLiveTVNavigationStore.defaultsKey

    var selectedDestination: KyroGlobalDestination = .home

    var preferences: KyroGlobalNavigationPreferences {
        didSet {
            guard preferences != oldValue else { return }
            savePreferences()
            // The old fourth tab left the bar: keep the user on that slot.
            if !tabDestinations.contains(selectedDestination) {
                selectedDestination = preferences.fourthTab.destination
            }
        }
    }

    /// The five tabs the bar shows now.
    var tabDestinations: [KyroGlobalDestination] {
        KyroGlobalDestination.tabDestinations(fourthTab: preferences.fourthTab)
    }

    /// Selects a destination only if it is one of the visible tabs.
    @discardableResult
    func selectIfTab(_ destination: KyroGlobalDestination) -> Bool {
        guard tabDestinations.contains(destination) else { return false }
        selectedDestination = destination
        return true
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(KyroGlobalNavigationPreferences.self, from: data) {
            preferences = saved
        } else if let data = defaults.data(forKey: Self.legacyLiveTVDefaultsKey),
                  let legacy = try? JSONDecoder().decode(KyroLiveTVNavigationPreferences.self, from: data) {
            preferences = KyroGlobalNavigationPreferences(migrating: legacy)
            savePreferences()
        } else {
            preferences = KyroGlobalNavigationPreferences()
        }
    }

    private func savePreferences() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
