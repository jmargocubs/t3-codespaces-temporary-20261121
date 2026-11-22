#if os(iOS) || KYRO_VOD_HOST_TESTS
import Foundation

/// Search/browse identity only. Provider records and their playable IDs remain untouched.
struct UnifiedVODEntry: Identifiable {
    enum Origin: Hashable { case silo, iptv(UUID) }
    enum Kind: Hashable { case movie, series }

    let id: String
    let origin: Origin
    let kind: Kind
    let title: String
    let year: Int?
    let imdbID: String?
    let tmdbID: String?
    let posterURL: String?
    let siloItem: BrowseItem?
    let iptvItem: XtreamVODItem?

    init(silo item: BrowseItem) {
        id = "silo:\(item.contentId)"
        origin = .silo
        kind = item.type == "series" ? .series : .movie
        title = item.title
        year = item.year
        imdbID = nil // BrowseItem does not carry external IDs; detail does.
        tmdbID = nil
        posterURL = item.posterUrl
        siloItem = item
        iptvItem = nil
    }

    init(iptv item: XtreamVODItem) {
        id = "iptv:\(item.id)"
        origin = .iptv(item.providerID)
        kind = item.kind == .series ? .series : .movie
        title = item.title
        year = XtreamVODTitle.year(in: item.title)
        imdbID = nil // Xtream catalog records currently have no verified external IDs.
        tmdbID = nil
        posterURL = item.poster
        siloItem = nil
        iptvItem = item
    }

    init(id: String, origin: Origin, kind: Kind, title: String, year: Int?,
         imdbID: String? = nil, tmdbID: String? = nil, posterURL: String? = nil) {
        self.id = id
        self.origin = origin
        self.kind = kind
        self.title = title
        self.year = year
        self.imdbID = imdbID
        self.tmdbID = tmdbID
        self.posterURL = posterURL
        siloItem = nil
        iptvItem = nil
    }

    var normalizedTitle: String {
        UnifiedCatalogKeys.normalizedTitle(title, year: year, locale: .current)
    }
}

/// The title keys the unified Movies/Series index stores. Search keeps `UnifiedVODEntry`'s
/// current-locale normalization; the persisted index uses a fixed (nil) locale so keys written
/// under one device language still compare equal after the language changes.
enum UnifiedCatalogKeys {
    static func normalizedTitle(_ title: String, year: Int?, locale: Locale? = nil) -> String {
        var value = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let year {
            for suffix in [" (\(year))", " [\(year)]", " - \(year)"] where value.hasSuffix(suffix) {
                value.removeLast(suffix.count)
                break
            }
        }
        return value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    /// Byte-ordered (SQLite BINARY) sort key: normalized title, then year. U+0001 sorts below a
    /// space, so "arrival" (any year) precedes "arrival ii". Titles with no letters or digits keep
    /// their folded raw text so they still sort deterministically.
    static func sortKey(title: String, year: Int?) -> String {
        let normalized = normalizedTitle(title, year: year)
        let base = normalized.isEmpty
            ? title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            : normalized
        return base + "\u{1}" + String(format: "%04d", min(max(year ?? 0, 0), 9999))
    }

    /// Non-empty only when a title is eligible for title+year matching (the policy
    /// `UnifiedVODCatalog.aggregate` applies to search results). Matching entries always share a
    /// sort key, so every match group is contiguous in index order.
    static func matchKey(title: String, year: Int?) -> String {
        guard let year else { return "" }
        let normalized = normalizedTitle(title, year: year)
        return normalized.isEmpty ? "" : normalized + "\u{1}" + String(year)
    }

    static func siloEntryKey(libraryID: Int, contentID: String) -> String { "s:\(libraryID):\(contentID)" }
    static func iptvEntryKey(providerID: UUID, remoteID: Int) -> String { "i:\(providerID.uuidString):\(remoteID)" }
}

struct UnifiedVODTitle: Identifiable {
    let entries: [UnifiedVODEntry]
    var id: String { entries.first?.id ?? "" }
    var kind: UnifiedVODEntry.Kind { entries[0].kind }
    var title: String { entries[0].title }
    var siloItem: BrowseItem? { entries.compactMap(\.siloItem).first }
    var iptvItems: [XtreamVODItem] { entries.compactMap(\.iptvItem) }
    /// The existing Silo detail is primary when present; IPTV-only cards keep their
    /// provider-qualified identity. Other entries remain available on the title.
    var primaryEntry: UnifiedVODEntry? {
        entries.first(where: { $0.origin == .silo }) ?? entries.first
    }
    /// Episodes are intentionally not fetched during title matching. The caller can supply the
    /// currently resolved keys for individual sources; an unknown source is never inferred to
    /// contain an episode merely because another source does.
    func sources(for episode: UnifiedVODEpisodeKey,
                 resolvedEpisodes: [String: Set<UnifiedVODEpisodeKey>]) -> [UnifiedVODEntry] {
        guard kind == .series else { return [] }
        return entries.filter { resolvedEpisodes[$0.id]?.contains(episode) == true }
    }
}

struct UnifiedVODEpisodeKey: Hashable {
    let season: Int
    let episode: Int
}

enum UnifiedVODCatalog {
    /// Discovery is supplementary: fail closed until both local catalogs have finished, then
    /// remove every result known playable in IPTV. The server already filters its own library.
    static func requestableResults(_ results: [RequestMediaResult], local: [UnifiedVODEntry],
                                   siloReady: Bool, vodReady: Bool) -> [RequestMediaResult] {
        guard siloReady, vodReady else { return [] }
        return results.filter { request in
            !local.contains { matchesRequest(request, entry: $0) }
        }
    }

    /// Rebuilds only the bounded result window on each incremental update. If a later entry makes
    /// a title/year ambiguous, all colliding entries stay separate instead of retaining a bad merge.
    static func aggregate(_ entries: [UnifiedVODEntry]) -> [UnifiedVODTitle] {
        var buckets: [String: [UnifiedVODEntry]] = [:]
        for entry in entries {
            let key: String
            if let tmdb = entry.tmdbID { key = "\(entry.kind):tmdb:\(tmdb)" }
            else if let imdb = entry.imdbID { key = "\(entry.kind):imdb:\(imdb)" }
            else if let year = entry.year, !entry.normalizedTitle.isEmpty {
                key = "\(entry.kind):title:\(entry.normalizedTitle):\(year)"
            } else { key = "record:\(entry.id)" }
            buckets[key, default: []].append(entry)
        }
        var consumed = Set<String>()
        var groups: [UnifiedVODTitle] = []
        for entry in entries where !consumed.contains(entry.id) {
            let key: String
            if let tmdb = entry.tmdbID { key = "\(entry.kind):tmdb:\(tmdb)" }
            else if let imdb = entry.imdbID { key = "\(entry.kind):imdb:\(imdb)" }
            else if let year = entry.year, !entry.normalizedTitle.isEmpty {
                key = "\(entry.kind):title:\(entry.normalizedTitle):\(year)"
            } else { key = "record:\(entry.id)" }
            let candidates = buckets[key] ?? [entry]
            let uniqueOrigins = Set(candidates.map(\.origin)).count == candidates.count
            let compatible = candidates.allSatisfy { left in
                candidates.allSatisfy { right in
                    !conflictingIdentifiers(left, right) &&
                    (left.id == right.id || sharedIdentifier(left, right) || safeTitleYear(left, right))
                }
            }
            let merged = uniqueOrigins && compatible ? candidates : [entry]
            groups.append(UnifiedVODTitle(entries: merged))
            merged.forEach { consumed.insert($0.id) }
        }
        return groups
    }

    static func matchesRequest(_ request: RequestMediaResult, entry: UnifiedVODEntry) -> Bool {
        guard request.mediaType == .movie || request.mediaType == .series else { return false }
        let expected: UnifiedVODEntry.Kind = request.mediaType == .series ? .series : .movie
        guard entry.kind == expected else { return false }
        if let tmdb = entry.tmdbID { return tmdb == String(request.tmdbId) }
        if let year = entry.year, let requestYear = request.year, year != requestYear { return false }
        let requestEntry = UnifiedVODEntry(id: "request", origin: .silo, kind: expected,
                                           title: request.title, year: request.year)
        return entry.normalizedTitle == requestEntry.normalizedTitle
    }

    private static func sharedIdentifier(_ a: UnifiedVODEntry, _ b: UnifiedVODEntry) -> Bool {
        (a.tmdbID != nil && a.tmdbID == b.tmdbID) || (a.imdbID != nil && a.imdbID == b.imdbID)
    }

    private static func conflictingIdentifiers(_ a: UnifiedVODEntry, _ b: UnifiedVODEntry) -> Bool {
        (a.tmdbID != nil && b.tmdbID != nil && a.tmdbID != b.tmdbID) ||
        (a.imdbID != nil && b.imdbID != nil && a.imdbID != b.imdbID)
    }

    private static func safeTitleYear(_ a: UnifiedVODEntry, _ b: UnifiedVODEntry) -> Bool {
        guard let year = a.year, year == b.year else { return false }
        return !a.normalizedTitle.isEmpty && a.normalizedTitle == b.normalizedTitle
    }
}

enum VODPlaybackPreference: String, CaseIterable { case automatic, askEveryTime }

/// Gives each local VOD query a monotonically increasing identity so a cancelled or
/// superseded asynchronous catalog read cannot publish into a newer search.
struct VODSearchRequestTracker {
    private(set) var generation = 0
    private(set) var activeQuery: String?

    mutating func begin(_ query: String) -> Int {
        generation &+= 1
        activeQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return generation
    }

    mutating func cancel() {
        generation &+= 1
        activeQuery = nil
    }

    func accepts(_ token: Int, query: String) -> Bool {
        token == generation && activeQuery == query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum VODPlaybackPolicy {
    /// A pre-start decision only. The existing coordinator remains authoritative once playback starts.
    static func order(preference: VODPlaybackPreference = .automatic,
                      sources: [UnifiedVODEntry], usableIDs: Set<String>? = nil,
                      failedIDs: Set<String> = [],
                      playbackStarted: Bool = false, manualSourceID: String? = nil) -> [UnifiedVODEntry] {
        guard !playbackStarted else { return [] }
        let available = sources.filter { !failedIDs.contains($0.id) && (usableIDs?.contains($0.id) ?? true) }
        if let manualSourceID { return available.filter { $0.id == manualSourceID } }
        guard preference == .automatic else { return [] }
        return available.sorted { left, right in
            if left.origin == .silo { return right.origin != .silo }
            if right.origin == .silo { return false }
            return left.id < right.id
        }
    }
}
#endif
