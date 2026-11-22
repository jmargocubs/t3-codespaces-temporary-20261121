import Foundation

/// Small per-scene restore data. It contains filters and opaque position IDs only; channel rows,
/// EPG data, URLs, and search results are always rebuilt from the active provider's catalog.
struct LiveTVBrowsingContext: Codable, Equatable, Sendable {
    static let maximumEncodedBytes = 4_096

    /// An explicit Home choice wins. Snapshots from builds that did not record visibility resume
    /// the browser whenever they carry any browser state.
    var shouldPresentBrowser: Bool {
        if let isBrowserVisible { return isBrowserVisible }
        return channelID != nil || offsetX != nil || offsetY != nil || category != nil || favoritesOnly || !searchQuery.isEmpty
    }
    static let maximumSearchCharacters = 128
    static let maximumCategoryCharacters = 128
    static let maximumChannelIDCharacters = 512

    let providerID: UUID
    var category: String?
    var favoritesOnly: Bool
    var searchQuery: String
    var channelID: String?
    var offsetX: Double?
    var offsetY: Double?
    /// False when the user went back to Home on purpose. Nil means an older build saved it.
    var isBrowserVisible: Bool?

    init(providerID: UUID, category: String?, favoritesOnly: Bool, searchQuery: String,
         channelID: String?, offsetX: Double?, offsetY: Double?, isBrowserVisible: Bool? = nil) {
        self.providerID = providerID
        self.category = Self.bounded(category, characters: Self.maximumCategoryCharacters)
        self.favoritesOnly = favoritesOnly
        self.searchQuery = Self.safeSearchQuery(searchQuery)
        self.channelID = Self.bounded(channelID, characters: Self.maximumChannelIDCharacters)
        self.offsetX = Self.safeOffset(offsetX)
        self.offsetY = Self.safeOffset(offsetY)
        self.isBrowserVisible = isBrowserVisible
    }

    /// The snapshot written when the user goes back to Home. Browse filters and position stay so
    /// the same browser can resume later; a search position means nothing once the query is
    /// cleared, so a search snapshot keeps only the Home choice.
    func returningHome() -> Self {
        guard searchQuery.isEmpty else {
            return Self(providerID: providerID, category: nil, favoritesOnly: false, searchQuery: "",
                        channelID: nil, offsetX: nil, offsetY: nil, isBrowserVisible: false)
        }
        return Self(providerID: providerID, category: category, favoritesOnly: favoritesOnly, searchQuery: "",
                    channelID: channelID, offsetX: offsetX, offsetY: offsetY, isBrowserVisible: false)
    }

    /// A Home snapshot's position, when the user re-enters exactly the browser it came from.
    func resumedBrowser(for filters: LiveTVBrowserFilters) -> Self? {
        guard isBrowserVisible == false, searchQuery == filters.query, category == filters.category,
              favoritesOnly == filters.favoritesOnly, channelID != nil || offsetY != nil else { return nil }
        return Self(providerID: providerID, category: category, favoritesOnly: favoritesOnly, searchQuery: searchQuery,
                    channelID: channelID, offsetX: offsetX, offsetY: offsetY, isBrowserVisible: true)
    }

    /// Validates against the snapshot's own provider catalog, or returns nil while that catalog is
    /// still loading. Validating against an empty or foreign catalog would discard a saved
    /// category and row that are still valid.
    func validatedWhenReady(selectedProviderID: UUID?, catalogIsLoaded: Bool,
                            categories: [String], channels: [LiveTVChannel]?) -> Self? {
        guard providerID == selectedProviderID, catalogIsLoaded else { return nil }
        return validated(categories: categories, channels: channels)
    }

    func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self), data.count <= Self.maximumEncodedBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decoded(_ string: String, for providerID: UUID) -> Self? {
        guard string.utf8.count <= maximumEncodedBytes,
              let data = string.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.providerID == providerID else { return nil }
        return Self(providerID: providerID, category: value.category, favoritesOnly: value.favoritesOnly,
                    searchQuery: value.searchQuery, channelID: value.channelID,
                    offsetX: value.offsetX, offsetY: value.offsetY, isBrowserVisible: value.isBrowserVisible)
    }

    /// Remove stale selections before applying the snapshot to a refreshed or changed catalog.
    func validated(categories: [String], channels: [LiveTVChannel]?) -> Self {
        let channelIDs = channels.map { Set($0.map(\.id)) }
        let validCategory = category.flatMap { categories.contains($0) ? $0 : nil }
        let validChannelID = channelID.flatMap {
            LiveTVRecentChannel.belongs($0, to: providerID) && (channelIDs?.contains($0) ?? true) ? $0 : nil
        }
        return Self(providerID: providerID, category: validCategory, favoritesOnly: favoritesOnly,
                    searchQuery: searchQuery, channelID: validChannelID, offsetX: offsetX, offsetY: offsetY,
                    isBrowserVisible: isBrowserVisible)
    }

    private static func bounded(_ value: String?, characters: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(characters))
    }

    private static func safeSearchQuery(_ query: String) -> String {
        let bounded = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumSearchCharacters))
        let lowercased = bounded.lowercased()
        // Channel search is ordinary text. Do not preserve pasted connection or credential material.
        let sensitiveMarkers = ["://", "token=", "password=", "username=", "authorization=", "bearer "]
        return sensitiveMarkers.contains(where: lowercased.contains) ? "" : bounded
    }

    private static func safeOffset(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return min(value, 10_000_000)
    }
}

/// Scene-scoped snapshots for a small number of providers. This keeps provider switching from
/// borrowing another provider's search/filter/scroll state without accumulating an unbounded map.
struct LiveTVBrowsingContextCollection: Codable, Equatable, Sendable {
    static let providerCapacity = 8
    static let maximumEncodedBytes = 32_768

    private(set) var contexts: [LiveTVBrowsingContext] = []

    func context(for providerID: UUID) -> LiveTVBrowsingContext? {
        contexts.first { $0.providerID == providerID }
    }

    func replacing(_ context: LiveTVBrowsingContext) -> Self {
        var result = Self(contexts: [context] + contexts.filter { $0.providerID != context.providerID })
        result.contexts = Array(result.contexts.prefix(Self.providerCapacity))
        return result
    }

    func encoded() -> String? {
        var bounded = self
        while let data = try? JSONEncoder().encode(bounded), data.count > Self.maximumEncodedBytes,
              !bounded.contexts.isEmpty {
            bounded.contexts.removeLast()
        }
        guard let data = try? JSONEncoder().encode(bounded), data.count <= Self.maximumEncodedBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decoded(_ string: String) -> Self? {
        guard string.utf8.count <= maximumEncodedBytes,
              let data = string.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        var seen = Set<UUID>()
        let normalized = decoded.contexts.map {
            LiveTVBrowsingContext(providerID: $0.providerID, category: $0.category,
                                  favoritesOnly: $0.favoritesOnly, searchQuery: $0.searchQuery,
                                  channelID: $0.channelID, offsetX: $0.offsetX, offsetY: $0.offsetY,
                                  isBrowserVisible: $0.isBrowserVisible)
        }
        let unique = normalized.filter { seen.insert($0.providerID).inserted }
        return Self(contexts: Array(unique.prefix(providerCapacity)))
    }
}

/// What the pushed guide hands the watch screen's Guide tab when it chooses a channel: the same
/// category, favorites filter, search and time position. The embedded guide starts from it instead
/// of the scene's saved context, which may be from an earlier visit, and never writes that saved
/// context, so the pushed guide underneath keeps its own.
struct LiveTVGuideWatchHandoff: Equatable, Sendable {
    let providerID: UUID
    let category: String?
    let favoritesOnly: Bool
    let searchQuery: String
    /// Horizontal scroll offset of the time grid, nil to show the current time.
    let offsetX: Double?

    init(providerID: UUID, category: String?, favoritesOnly: Bool, searchQuery: String, offsetX: Double?) {
        self.providerID = providerID
        self.category = category
        self.favoritesOnly = favoritesOnly
        self.searchQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        self.offsetX = offsetX.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    /// The filters the embedded guide applies for `providerID`, with a category the catalog no
    /// longer lists dropped. Nil when the handoff belongs to another provider.
    func filters(for providerID: UUID, categories: [String]) -> LiveTVBrowserFilters? {
        guard providerID == self.providerID else { return nil }
        let validCategory = category.flatMap { categories.isEmpty || categories.contains($0) ? $0 : nil }
        return LiveTVBrowserFilters(query: searchQuery, category: validCategory, favoritesOnly: favoritesOnly)
    }

    /// The vertical offset that reveals `channelID`'s row under the pinned time header, with
    /// `contextRows` rows above it so the row does not sit against the header. Nil when the
    /// channel is not among the rows.
    static func revealOffsetY(channelID: String?, rowIDs: [String], rowHeight: Double,
                              contextRows: Int = 1) -> Double? {
        guard let channelID, let index = rowIDs.firstIndex(of: channelID) else { return nil }
        return Double(max(0, index - contextRows)) * rowHeight
    }
}

/// Tracks the guide's unresolved restore snapshot until the guide has actually issued its
/// scroll restoration. Saves made while that restore is pending must keep the original opaque
/// row and offsets rather than persisting the freshly initialized ScrollPosition.
struct LiveTVGuideBrowsingRestoration: Equatable {
    private(set) var pendingContext: LiveTVBrowsingContext?

    mutating func begin(context: LiveTVBrowsingContext?, providerID: UUID?) {
        pendingContext = context.flatMap { $0.providerID == providerID ? $0 : nil }
    }

    mutating func updatePendingContext(_ context: LiveTVBrowsingContext) {
        guard pendingContext?.providerID == context.providerID else { return }
        pendingContext = context
    }

    func contextToSave(providerID: UUID?, restoredProviderID: UUID?, current: LiveTVBrowsingContext)
        -> LiveTVBrowsingContext? {
        guard let providerID else { return nil }
        if let pendingContext, pendingContext.providerID == providerID { return pendingContext }
        guard restoredProviderID == providerID, current.providerID == providerID else { return nil }
        return current
    }

    mutating func complete(context: LiveTVBrowsingContext) {
        guard pendingContext == context else { return }
        pendingContext = nil
    }
}
