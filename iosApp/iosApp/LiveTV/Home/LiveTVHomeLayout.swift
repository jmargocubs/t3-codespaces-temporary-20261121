import Foundation

/// One channel as a Home card. `artworkURL` is program artwork; it stays nil until the guide
/// carries real images, and every card falls back to the channel logo on a brand gradient.
struct LiveTVHomeCard: Identifiable, Equatable, Sendable {
    let channel: LiveTVChannel
    var artworkURL: URL? = nil

    var id: String { channel.id }
}

/// The Home rails, derived from the bounded provider-scoped preview (at most 10 recents and
/// 12 favorites). Building this never touches the full catalog.
struct LiveTVHomeSections: Equatable, Sendable {
    static let continueWatchingLimit = 3
    static let featuredLimit = 6

    /// Playable recents first, then playable favorites, without repeats.
    let featured: [LiveTVHomeCard]
    /// The most recent channels.
    let continueWatching: [LiveTVHomeCard]
    /// Older recents. Never repeats a Continue Watching channel.
    let recentlyWatched: [LiveTVHomeCard]
    let lineup: [LiveTVHomeCard]

    static let empty = LiveTVHomeSections(featured: [], continueWatching: [], recentlyWatched: [], lineup: [])

    init(featured: [LiveTVHomeCard], continueWatching: [LiveTVHomeCard],
         recentlyWatched: [LiveTVHomeCard], lineup: [LiveTVHomeCard]) {
        self.featured = featured
        self.continueWatching = continueWatching
        self.recentlyWatched = recentlyWatched
        self.lineup = lineup
    }

    /// `recents` is newest first. History order is kept as-is; the rails only split it.
    init(recents: [LiveTVChannel], favorites: [LiveTVChannel], isPlayable: (LiveTVChannel) -> Bool) {
        let recentRail = LiveTVHomeSelection.recents(from: recents)
        let split = min(Self.continueWatchingLimit, recentRail.count)
        var seen = Set<String>()
        var featured: [LiveTVHomeCard] = []
        for channel in recentRail + favorites where featured.count < Self.featuredLimit {
            guard seen.insert(channel.id).inserted, isPlayable(channel) else { continue }
            featured.append(LiveTVHomeCard(channel: channel))
        }
        self.init(featured: featured,
                  continueWatching: recentRail[..<split].map { LiveTVHomeCard(channel: $0) },
                  recentlyWatched: recentRail[split...].map { LiveTVHomeCard(channel: $0) },
                  lineup: LiveTVHomeSelection.lineup(from: favorites).map { LiveTVHomeCard(channel: $0) })
    }
}

/// A symbol for a provider category name, from simple keywords. This only picks an icon; it
/// does not group or rename categories.
enum LiveTVCategorySymbol {
    static let allChannels = "dot.radiowaves.left.and.right"
    static let fallback = "square.stack.3d.up.fill"

    /// Checked in order, so "Sports News" reads as sports.
    private static let rules: [(keywords: [String], symbol: String)] = [
        (["sport", "football", "soccer", "nfl", "nba", "nhl", "mlb", "golf", "tennis", "racing",
          "boxing", "ufc", "wwe", "espn", "cricket", "rugby"], "sportscourt.fill"),
        (["news"], "newspaper.fill"),
        (["movie", "cinema", "film"], "film.fill"),
        (["kid", "child", "cartoon", "family", "junior"], "figure.and.child.holdinghands"),
        (["music", "radio"], "music.note"),
        (["documentar", "nature", "science", "history", "discovery"], "globe.americas.fill"),
        (["comedy", "entertain", "series", "drama", "reality", "lifestyle"], "theatermasks.fill"),
        (["weather"], "cloud.sun.fill"),
        (["shop"], "bag.fill"),
        (["relig", "faith", "christian", "gospel"], "book.closed.fill"),
        (["food", "cook"], "fork.knife"),
        (["ppv", "pay per view", "event"], "ticket.fill"),
        (["local"], "mappin.and.ellipse"),
    ]

    /// Every symbol this can return.
    static var allSymbols: [String] { rules.map(\.symbol) + [allChannels, fallback] }

    static func symbol(for category: String) -> String {
        let name = category.lowercased()
        return rules.first { rule in rule.keywords.contains { name.contains($0) } }?.symbol ?? fallback
    }
}
