import Foundation
import Observation

enum KyroLiveTVNavigationStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The Media Server's own bottom tab bar (`SiloTabBar`), with Live TV's destinations.
    case classic
    case glassDock
    case thumbFan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: "Classic"
        case .glassDock: "Adaptive Glass Dock"
        case .thumbFan: "Thumb Fan"
        }
    }

    var summary: String {
        switch self {
        case .classic: "The same tab bar as the rest of Kyro, along the bottom."
        case .glassDock: "A glass bar that opens along the edge it sits on."
        case .thumbFan: "A glass orb whose destinations fan out in an arc."
        }
    }

    /// The floating styles: a movable handle drawn over Live TV.
    var isFloating: Bool { self != .classic }
}

/// What the navigation does when it is left alone.
enum KyroLiveTVNavigationIdleBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case stayVisible
    case collapse
    case collapseAndFade

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stayVisible: "Stay Open"
        case .collapse: "Collapse"
        case .collapseAndFade: "Collapse and Fade"
        }
    }
}

/// A screen edge, named physically: the navigation sits where the user's
/// thumb put it, whatever the layout direction.
enum KyroNavigationEdge: String, Codable, CaseIterable, Identifiable, Sendable {
    case left
    case right
    case top
    case bottom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .top: "Top"
        case .bottom: "Bottom"
        }
    }

    /// Left and right edges hold a vertical rail; top and bottom a horizontal dock.
    var isVertical: Bool { self == .left || self == .right }
}

/// A saved position that does not depend on screen size: an edge, and how far
/// along that edge's usable length the handle sits (0 is the top or left end).
struct KyroNavigationAnchor: Codable, Equatable, Sendable {
    var edge: KyroNavigationEdge
    var position: Double

    init(edge: KyroNavigationEdge, position: Double) {
        self.edge = edge
        self.position = min(max(position.isFinite ? position : 0.5, 0), 1)
    }

    private enum CodingKeys: String, CodingKey { case edge, position }

    /// A damaged saved value is clamped back onto the edge, never trusted.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(edge: try values.decode(KyroNavigationEdge.self, forKey: .edge),
                  position: try values.decode(Double.self, forKey: .position))
    }

    /// Right and left edges start in the lower half, where a thumb reaches.
    static func `default`(for edge: KyroNavigationEdge) -> Self {
        Self(edge: edge, position: edge.isVertical ? 0.68 : 0.5)
    }
}

/// Everything the user can customize, saved on this device only. Decoding
/// tolerates missing and unknown values, so a newer or older build never
/// loses the user's choices.
struct KyroLiveTVNavigationPreferences: Codable, Equatable, Sendable {
    /// Classic for anyone without saved navigation. A saved style, from any
    /// build, is kept: Build 14 and 15 saved Glass Dock or Thumb Fan only.
    var style: KyroLiveTVNavigationStyle = .classic
    /// Every available destination, in the user's order. Hidden ones keep their place.
    private(set) var order: [KyroLiveTVDestination] = KyroLiveTVDestination.defaultOrder
    private(set) var hidden: Set<KyroLiveTVDestination> = []
    var autoCollapse = true
    var idleBehavior: KyroLiveTVNavigationIdleBehavior = .collapse
    var hapticsEnabled = true
    var thumbScrubbing = true
    var allowsDragging = true
    var startingEdge: KyroNavigationEdge = .right
    private var dockAnchor: KyroNavigationAnchor?
    private var fanAnchor: KyroNavigationAnchor?

    init() {}

    /// The destinations the navigation shows, in order. Never empty: Home is required.
    var visibleDestinations: [KyroLiveTVDestination] {
        order.filter { $0.isAvailable && !hidden.contains($0) }
    }

    func isVisible(_ destination: KyroLiveTVDestination) -> Bool {
        destination.isAvailable && !hidden.contains(destination)
    }

    /// Hiding a required destination is refused, so a configuration can never
    /// leave the user without a way back.
    mutating func setVisible(_ visible: Bool, for destination: KyroLiveTVDestination) {
        if visible {
            hidden.remove(destination)
        } else if !destination.isRequired {
            hidden.insert(destination)
        }
    }

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var reordered = order
        let moving = source.sorted().filter { reordered.indices.contains($0) }.map { reordered[$0] }
        let insertion = destination - source.filter { $0 < destination }.count
        for index in source.sorted(by: >) where reordered.indices.contains(index) { reordered.remove(at: index) }
        reordered.insert(contentsOf: moving, at: min(max(insertion, 0), reordered.count))
        order = reordered
    }

    /// Used by an explicitly validated settings restore. The editor still uses `move`; keeping
    /// this operation on the owning model lets an Undo restore the exact prior order.
    mutating func setDestinationOrder(_ destinations: [KyroLiveTVDestination]) {
        guard destinations.count == KyroLiveTVDestination.available.count,
              Set(destinations) == Set(KyroLiveTVDestination.available) else { return }
        order = destinations
    }

    mutating func resetDestinations() {
        order = KyroLiveTVDestination.defaultOrder
        hidden = []
    }

    /// Each floating style keeps its own position. Classic has none.
    func anchor(for style: KyroLiveTVNavigationStyle) -> KyroNavigationAnchor {
        let saved: KyroNavigationAnchor? = switch style {
        case .glassDock: dockAnchor
        case .thumbFan: fanAnchor
        case .classic: nil
        }
        return saved ?? .default(for: startingEdge)
    }

    mutating func setAnchor(_ anchor: KyroNavigationAnchor, for style: KyroLiveTVNavigationStyle) {
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

    // MARK: Coding

    enum CodingKeys: String, CodingKey, CaseIterable {
        case style, order, hidden, autoCollapse, idleBehavior, hapticsEnabled, thumbScrubbing,
             allowsDragging, startingEdge, dockAnchor, fanAnchor
    }

    /// Persisted user choices. The two saved handle positions are excluded because they describe
    /// one screen's geometry. Backup tests compare this list with the production registry.
    static var backupEligibleStoredFields: Set<String> {
        Set(CodingKeys.allCases.map(\.rawValue)).subtracting(["dockAnchor", "fanAnchor"])
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? { try? values.decodeIfPresent(T.self, forKey: key) }
        let defaults = Self()
        style = value(.style) ?? defaults.style
        let savedOrder: [String] = value(.order) ?? []
        order = Self.normalizedOrder(savedOrder.compactMap(KyroLiveTVDestination.init(rawValue:)))
        let savedHidden: [String] = value(.hidden) ?? []
        hidden = Set(savedHidden.compactMap(KyroLiveTVDestination.init(rawValue:)).filter { !$0.isRequired })
        autoCollapse = value(.autoCollapse) ?? defaults.autoCollapse
        idleBehavior = value(.idleBehavior) ?? defaults.idleBehavior
        hapticsEnabled = value(.hapticsEnabled) ?? defaults.hapticsEnabled
        thumbScrubbing = value(.thumbScrubbing) ?? defaults.thumbScrubbing
        allowsDragging = value(.allowsDragging) ?? defaults.allowsDragging
        startingEdge = value(.startingEdge) ?? defaults.startingEdge
        dockAnchor = value(.dockAnchor)
        fanAnchor = value(.fanAnchor)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(style, forKey: .style)
        try values.encode(order.map(\.rawValue), forKey: .order)
        try values.encode(hidden.map(\.rawValue).sorted(), forKey: .hidden)
        try values.encode(autoCollapse, forKey: .autoCollapse)
        try values.encode(idleBehavior, forKey: .idleBehavior)
        try values.encode(hapticsEnabled, forKey: .hapticsEnabled)
        try values.encode(thumbScrubbing, forKey: .thumbScrubbing)
        try values.encode(allowsDragging, forKey: .allowsDragging)
        try values.encode(startingEdge, forKey: .startingEdge)
        try values.encodeIfPresent(dockAnchor, forKey: .dockAnchor)
        try values.encodeIfPresent(fanAnchor, forKey: .fanAnchor)
    }

    /// Saved order first, without repeats or unavailable destinations, then any
    /// available destination the saved order did not know about.
    static func normalizedOrder(_ saved: [KyroLiveTVDestination]) -> [KyroLiveTVDestination] {
        var seen = Set<KyroLiveTVDestination>()
        let kept = saved.filter { $0.isAvailable && seen.insert($0).inserted }
        let missing = (KyroLiveTVDestination.defaultOrder + KyroLiveTVDestination.available)
            .filter { seen.insert($0).inserted }
        return kept + missing
    }
}

/// The one authoritative navigation state. Both styles, every Live TV screen
/// and the settings read this store; only the preferences are saved.
@MainActor
@Observable
final class KyroLiveTVNavigationStore {
    static let shared = KyroLiveTVNavigationStore()
    static let defaultsKey = "kyro.liveTV.navigation.v1"

    var preferences: KyroLiveTVNavigationPreferences {
        didSet { if preferences != oldValue { save() } }
    }

    /// Session state, never saved: the navigation always starts collapsed.
    var isExpanded = false
    /// Session state, never saved: what the last touch on the handle did.
    var lastHandleTrace: KyroNavigationHandleTrace?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(KyroLiveTVNavigationPreferences.self, from: data) {
            preferences = saved
        } else {
            preferences = KyroLiveTVNavigationPreferences()
        }
    }

    func resetAll() {
        preferences = KyroLiveTVNavigationPreferences()
        isExpanded = false
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
