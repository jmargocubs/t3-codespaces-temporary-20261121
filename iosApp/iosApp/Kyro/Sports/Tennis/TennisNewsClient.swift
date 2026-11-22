import Foundation

// Build 63: tennis player headlines for the News tab. ESPN's own tagged headlines stay first and
// untouched; these are additional, attributed links to the publisher's own page.
//
// Sources probed 2026-11-12, all keyless: WTA's content API (api.wtatennis.com/content/wta/news/en),
// BBC Sport tennis RSS and Guardian tennis RSS. atptour.com's feed answers HTTP 403 to automated
// clients and is not used. Only headline, description snippet, date and link are read: no article
// bodies and no images.

struct KyroSportsSupplementalNews: Equatable, Sendable {
    let gameID: KyroGameID
    let items: [KyroSportsNewsItem]
}

protocol KyroSportsNewsSupplementing: Sendable {
    var flagKey: String { get }
    func isEligible(_ game: KyroSportsGame) -> Bool
    func supplementalNews(for game: KyroSportsGame) async -> KyroSportsSupplementalNews?
}

struct TennisFeedEntry: Equatable, Sendable {
    let title: String
    let summary: String
    let url: URL
    let publishedAt: Date?
    let source: String
}

enum TennisFeedParsing {
    static func wtaEntries(from data: Data) -> [TennisFeedEntry] {
        struct Response: Decodable {
            struct Item: Decodable {
                let id: Int?
                let title: String?
                let description: String?
                let date: String?
                let titleUrlSegment: String?
            }
            let content: [Item]?
        }
        guard let items = try? JSONDecoder().decode(Response.self, from: data).content else { return [] }
        return items.compactMap { item in
            guard let id = item.id, let title = item.title, !title.isEmpty,
                  let segment = item.titleUrlSegment, !segment.isEmpty,
                  let url = URL(string: "https://www.wtatennis.com/news/\(id)/\(segment)") else { return nil }
            return TennisFeedEntry(title: title, summary: item.description ?? "", url: url,
                                   publishedAt: item.date.flatMap { ISO8601DateFormatter().date(from: $0) },
                                   source: "WTA")
        }
    }

    static func rssEntries(from data: Data, source: String) -> [TennisFeedEntry] {
        let delegate = RSSDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return [] }
        return delegate.items.compactMap { item in
            guard let title = item["title"], !title.isEmpty,
                  let link = item["link"], let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme == "https" else { return nil }
            return TennisFeedEntry(title: title, summary: stripTags(item["description"] ?? ""), url: url,
                                   publishedAt: item["pubDate"].flatMap(parseRFC822), source: source)
        }
    }

    static func stripTags(_ html: String) -> String {
        var output = html
        if output.contains("&lt;") {
            output = output.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        }
        output = output.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return output.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func parseRFC822(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value.trimmingCharacters(in: .whitespaces)) { return date }
        }
        return nil
    }

    private final class RSSDelegate: NSObject, XMLParserDelegate {
        var items: [[String: String]] = []
        private var current: [String: String]?
        private var field: String?
        private var buffer = ""
        private static let wanted: Set<String> = ["title", "link", "description", "pubDate"]

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "item" { current = [:] }
            else if current != nil, Self.wanted.contains(name) { field = name; buffer = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if field != nil { buffer += string } }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if field != nil, let text = String(data: CDATABlock, encoding: .utf8) { buffer += text }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "item", let finished = current { items.append(finished); current = nil }
            else if name == field, current != nil { current?[name] = buffer.trimmingCharacters(in: .whitespacesAndNewlines); field = nil }
        }
    }
}

enum TennisNewsMatcher {
    static let maxAge: TimeInterval = 14 * 86_400
    static let maxItems = 10
    static let maxTournamentItems = 3

    private static func words(_ text: String) -> String { " " + TheSportsDBEventMatcher.normalize(text) + " " }

    /// How an entry mentions a player: full name, or a surname of six or more letters (shorter
    /// surnames such as "Wang" collide too often for a headline on its own).
    private static func mentions(_ text: String, player: KyroSportsTeam) -> Bool {
        let full = TheSportsDBEventMatcher.normalize(player.nickname)
        guard !full.isEmpty else { return false }
        if text.contains(" " + full + " ") { return true }
        guard let surname = full.split(separator: " ").last, surname.count >= 6 else { return false }
        return text.contains(" " + surname + " ")
    }

    /// Phrases that identify a tournament in a headline: the full name, the name without its
    /// sponsor ("Rolex Paris Masters" -> "paris masters"), and a distinctive single word of six or
    /// more letters ("stockholm"). A bare "open" or "masters" never counts.
    static func tournamentPhrases(_ name: String?) -> [String] {
        guard let name else { return [] }
        let tokens = TheSportsDBEventMatcher.normalize(name).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        let generic: Set<String> = ["open", "masters", "atp", "wta", "tour", "finals", "championships", "international", "classic", "cup", "the", "of"]
        var phrases = Set<String>()
        if tokens.count >= 2 { phrases.insert(tokens.joined(separator: " ")) }
        for drop in 1...2 where tokens.count - drop >= 2 {
            phrases.insert(tokens.dropFirst(drop).joined(separator: " "))
        }
        if let city = tokens.last(where: { !generic.contains($0) }), city.count >= 6 { phrases.insert(city) }
        return phrases.filter { $0.count >= 6 }.sorted()
    }

    private static func mentionsTournament(_ text: String, phrases: [String]) -> Bool {
        phrases.contains { text.contains(" " + $0 + " ") }
    }

    /// Entries naming both players are `.matchup`; entries naming one are `.team` (player news);
    /// entries naming only the event's tournament are `.tournament`. Everything else, including
    /// tour-wide stories, is dropped. Duplicates across feeds collapse on normalised headline and
    /// on URL. At most `maxTournamentItems` tournament stories are kept so they cannot crowd out
    /// player news.
    static func items(from entries: [TennisFeedEntry], game: KyroSportsGame, now: Date) -> [KyroSportsNewsItem] {
        var seenTitles = Set<String>()
        var seenURLs = Set<URL>()
        var output: [KyroSportsNewsItem] = []
        let phrases = tournamentPhrases(game.tournament)
        for entry in entries {
            if let date = entry.publishedAt, now.timeIntervalSince(date) > maxAge { continue }
            let text = words(entry.title + " " + entry.summary)
            let home = mentions(text, player: game.home.team)
            let away = mentions(text, player: game.away.team)
            let relevance: KyroSportsNewsItem.Relevance
            if home && away { relevance = .matchup }
            else if home || away { relevance = .team }
            else if mentionsTournament(text, phrases: phrases) { relevance = .tournament }
            else { continue }
            let titleKey = TheSportsDBEventMatcher.normalize(entry.title)
            guard seenTitles.insert(titleKey).inserted, seenURLs.insert(entry.url).inserted else { continue }
            output.append(KyroSportsNewsItem(
                id: "\(entry.source)|\(entry.url.absoluteString)", headline: entry.title,
                publishedAt: entry.publishedAt, url: entry.url, source: entry.source, relevance: relevance))
        }
        output.sort {
            if $0.relevance != $1.relevance { return $0.relevance.rawValue > $1.relevance.rawValue }
            return ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast)
        }
        var tournamentCount = 0
        let capped = output.filter { item in
            guard item.relevance == .tournament else { return true }
            tournamentCount += 1
            return tournamentCount <= maxTournamentItems
        }
        return Array(capped.prefix(maxItems))
    }
}

struct TennisNewsClient: KyroSportsNewsSupplementing {
    var flagKey: String { KyroSportsSupplementFlag.tennisNewsKey }

    struct Feed: Sendable {
        let name: String
        let url: URL
        let isWTA: Bool
        /// WTA's own site only covers WTA players.
        let tourOnly: KyroSportLeague?
    }

    static let feeds: [Feed] = [
        Feed(name: "WTA", url: URL(string: "https://api.wtatennis.com/content/wta/news/en?page=0&pageSize=30")!,
             isWTA: true, tourOnly: .wta),
        Feed(name: "BBC Sport", url: URL(string: "https://feeds.bbci.co.uk/sport/tennis/rss.xml")!,
             isWTA: false, tourOnly: nil),
        Feed(name: "The Guardian", url: URL(string: "https://www.theguardian.com/sport/tennis/rss")!,
             isWTA: false, tourOnly: nil),
        Feed(name: "ESPN", url: URL(string: "https://www.espn.com/espn/rss/tennis/news")!,
             isWTA: false, tourOnly: nil),
        Feed(name: "Tennis365", url: URL(string: "https://www.tennis365.com/feed")!,
             isWTA: false, tourOnly: nil),
        Feed(name: "Tennis Majors", url: URL(string: "https://www.tennismajors.com/feed")!,
             isWTA: false, tourOnly: nil),
        Feed(name: "Tennis Now", url: URL(string: "https://www.tennisnow.com/feed")!,
             isWTA: false, tourOnly: nil),
    ]

    private let feeds: [Feed]
    private let transport: any ESPNTransport
    private let cache: ESPNEventDetailResponseCache
    private let now: @Sendable () -> Date

    init(
        feeds: [Feed] = TennisNewsClient.feeds,
        transport: any ESPNTransport = URLSessionESPNTransport(),
        gate: TheSportsDBRequestGate = TheSportsDBRequestGate(spacing: 0.2, limit: 40),
        cache: ESPNEventDetailResponseCache = ESPNEventDetailResponseCache(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.feeds = feeds
        self.transport = TheSportsDBGatedTransport(inner: transport, gate: gate)
        self.cache = cache
        self.now = now
    }

    func isEligible(_ game: KyroSportsGame) -> Bool {
        (game.league == .atp || game.league == .wta) && game.isSingles
    }

    /// At most seven cached feed requests (20 minute freshness unless the feed says longer), run
    /// together; a failing feed contributes nothing. Parsing happens off the caller's actor.
    func supplementalNews(for game: KyroSportsGame) async -> KyroSportsSupplementalNews? {
        guard isEligible(game) else { return nil }
        let applicable = feeds.filter { $0.tourOnly == nil || $0.tourOnly == game.league }
        let entries = await withTaskGroup(of: [TennisFeedEntry].self) { group in
            for feed in applicable {
                group.addTask { await self.entries(for: feed) }
            }
            var all: [TennisFeedEntry] = []
            for await batch in group { all.append(contentsOf: batch) }
            return all
        }
        guard !Task.isCancelled else { return nil }
        let items = TennisNewsMatcher.items(from: entries, game: game, now: now())
        return items.isEmpty ? nil : KyroSportsSupplementalNews(gameID: game.id, items: items)
    }

    private func entries(for feed: Feed) async -> [TennisFeedEntry] {
        var request = URLRequest(url: feed.url, timeoutInterval: 10)
        request.setValue(feed.isWTA ? "application/json" : "application/rss+xml, application/xml", forHTTPHeaderField: "Accept")
        guard let data = try? await cache.data(for: request, key: "news|\(feed.url.absoluteString)",
                                               fallbackFreshness: 20 * 60, transport: transport) else { return [] }
        return await Task.detached(priority: .utility) {
            feed.isWTA ? TennisFeedParsing.wtaEntries(from: data)
                       : TennisFeedParsing.rssEntries(from: data, source: feed.name)
        }.value
    }
}
