import Foundation

/// A place the floating Live TV navigation can take the user. Every case
/// maps to a screen that already exists in `LiveTVView`; the navigation
/// only reaches those screens, it never draws its own.
///
/// Adding a destination means adding a case, its title and symbol, and its
/// routing in `LiveTVView.navigate(to:)`. Saved preferences pick it up
/// automatically: `KyroLiveTVNavigationPreferences` appends any available
/// destination a saved order does not know yet.
enum KyroLiveTVDestination: String, Codable, CaseIterable, Identifiable, Sendable {
    case home
    case guide
    case favorites
    case channels
    case search
    /// Reserved for a Sports Hub. Hidden everywhere until that screen exists:
    /// flip `isAvailable` and add its route at the same time.
    case sportsHub

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .guide: "Guide"
        case .favorites: "Favorites"
        case .channels: "Channels"
        case .search: "Search"
        case .sportsHub: "Sports Hub"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .guide: "calendar"
        case .favorites: "star"
        case .channels: "square.grid.2x2"
        case .search: "magnifyingglass"
        case .sportsHub: "trophy"
        }
    }

    /// The filled symbol for the active destination, where SF Symbols has one.
    var activeSystemImage: String {
        switch self {
        case .home: "house.fill"
        case .guide: "calendar"
        case .favorites: "star.fill"
        case .channels: "square.grid.2x2.fill"
        case .search: "magnifyingglass"
        case .sportsHub: "trophy.fill"
        }
    }

    /// False until the destination has a real screen behind it.
    var isAvailable: Bool { self != .sportsHub }

    /// Home is the way back from everywhere, so it can never be hidden.
    var isRequired: Bool { self == .home }

    static let defaultOrder: [Self] = [.home, .guide, .favorites, .channels, .search]

    /// The destinations Live TV's row always offers under Kyro's unified shell. A fixed five,
    /// not the Classic bar's user-hideable order, so Favorites and Search are never hidden.
    static let navigationRow: [Self] = [.home, .guide, .favorites, .channels, .search]

    static var available: [Self] { allCases.filter(\.isAvailable) }
}

/// Which destination the current Live TV screen is. Derived from the state
/// `LiveTVView` already keeps, so the navigation never holds a second copy
/// of the route.
enum KyroLiveTVActiveDestination {
    static func resolve(showingGuide: Bool, showingBrowser: Bool, searching: Bool,
                        favoritesOnly: Bool) -> KyroLiveTVDestination {
        if showingGuide { return .guide }
        guard showingBrowser else { return .home }
        if searching { return .search }
        return favoritesOnly ? .favorites : .channels
    }
}
