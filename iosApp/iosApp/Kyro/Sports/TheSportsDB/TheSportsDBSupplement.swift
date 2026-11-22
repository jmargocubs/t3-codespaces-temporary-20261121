import Foundation

// Build 63: a small, flag-guarded supplement for finished soccer matches.
//
// ESPN stays the primary provider. TheSportsDB's free v1 tier returns at most five rows per
// statistics response, so its rows are shown only as "additional selected statistics" for a match
// verified field by field, never as a box score or a timeline. Timelines and lineups are not
// requested at all: a five-row slice of either would misrepresent the match.
//
// Provider facts (probed 2026-11-12): public key `123`, 30 requests per minute, Cloudflare error
// 1015 when exceeded, `Cache-Control: max-age=14400`. Terms/attribution page was unreachable (502),
// so the UI names the provider on every row group and the feature stays behind a flag.

// MARK: - Feature flag

enum KyroSportsSupplementFlag {
    static let defaultsKey = "kyro.sports.theSportsDBSupplement.enabled"

    /// On by default. Set the key to `false` (or flip this default) to disable the provider
    /// without touching the ESPN path.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        isEnabled(key: defaultsKey, defaults: defaults)
    }

    /// Every supplement adapter has its own key and defaults to on.
    static func isEnabled(key: String, defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    static let wtaStatsKey = "kyro.sports.wtaMatchStats.enabled"
    static let tennisNewsKey = "kyro.sports.tennisNews.enabled"
    static let tmlStatsKey = "kyro.sports.tennisMyLifeStats.enabled"
    static let tennisPlayerInfoKey = "kyro.sports.tennisPlayerInfo.enabled"
}

// MARK: - Models

struct KyroSportsSupplementalStatistics: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        let label: String
        let home: String
        let away: String
        /// Optional grouping heading ("Serve", "Return"...) shown above consecutive rows.
        var group: String? = nil
        var id: String { label }
    }

    /// Per-set rows (tennis). `title` is e.g. "Set 1".
    struct Section: Identifiable, Equatable, Sendable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    let gameID: KyroGameID
    let providerName: String
    let providerEventID: String
    let note: String
    let rows: [Row]
    let sections: [Section]
    /// One-line facts that are not per-player, such as "Match time 1h 58m".
    let facts: [String]

    init(gameID: KyroGameID, providerName: String = "TheSportsDB", providerEventID: String,
         note: String = "A short selection of match statistics, not a full box score.",
         rows: [Row], sections: [Section] = [], facts: [String] = []) {
        self.facts = facts
        self.gameID = gameID
        self.providerName = providerName
        self.providerEventID = providerEventID
        self.note = note
        self.rows = rows
        self.sections = sections
    }
}

/// An isolated statistics source for the Stats tab. Each one has its own feature-flag key, request
/// budget and cache, so it can be disabled or replaced without touching ESPN or playback.
protocol KyroSportsSupplementProviding: Sendable {
    var flagKey: String { get }
    func isEligible(_ game: KyroSportsGame) -> Bool
    func supplementalStatistics(for game: KyroSportsGame, existingLabels: [String]) async -> KyroSportsSupplementOutcome
}

enum KyroSportsSupplementOutcome: Equatable, Sendable {
    case available(KyroSportsSupplementalStatistics)
    case notEligible
    case noVerifiedMatch
    case ambiguousMatch
    case noAdditionalStatistics
    case providerUnavailable
    case cancelled
}

// MARK: - Wire models

struct TheSportsDBDayResponse: Decodable, Sendable {
    let events: [Event]?

    struct Event: Decodable, Sendable {
        let idEvent: String?
        let idLeague: String?
        let strHomeTeam: String?
        let strAwayTeam: String?
        let strTimestamp: String?
        let strStatus: String?
        let strPostponed: String?
        let intHomeScore: String?
        let intAwayScore: String?
    }
}

struct TheSportsDBStatsResponse: Decodable, Sendable {
    let eventstats: [Stat]?

    struct Stat: Decodable, Sendable {
        let idEvent: String?
        let strStat: String?
        let intHome: String?
        let intAway: String?
    }
}

// MARK: - Request budget

/// Request gate shared in shape by every supplement adapter (each owns its own instance). Keeps TheSportsDB well under its 30 requests/minute free limit: requests are spaced at
/// least `minSpacing` apart, capped per rolling window, and a provider rate-limit answer starts a
/// cooldown during which no request is sent. There are no retries.
actor TheSportsDBRequestGate {
    static let minSpacing: TimeInterval = 3
    static let windowSeconds: TimeInterval = 600
    static let windowLimit = 30
    static let cooldown: TimeInterval = 300

    private let spacing: TimeInterval
    private let limit: Int

    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var nextSlot: Date = .distantPast
    private var cooldownUntil: Date = .distantPast
    private var sent: [Date] = []

    init(
        spacing: TimeInterval = TheSportsDBRequestGate.minSpacing,
        limit: Int = TheSportsDBRequestGate.windowLimit,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.spacing = spacing
        self.limit = limit
        self.now = now
        self.sleep = sleep
    }

    func admit() async throws {
        let current = now()
        if current < cooldownUntil { throw KyroSportsDataError.httpStatus(429) }
        sent.removeAll { current.timeIntervalSince($0) > Self.windowSeconds }
        if sent.count >= limit { throw KyroSportsDataError.httpStatus(429) }
        let slot = max(current, nextSlot)
        nextSlot = slot.addingTimeInterval(spacing)
        sent.append(slot)
        let wait = slot.timeIntervalSince(current)
        if wait > 0 { try await sleep(wait) }
    }

    func tripCooldown() {
        cooldownUntil = now().addingTimeInterval(Self.cooldown)
    }

    var isCoolingDown: Bool { now() < cooldownUntil }
}

struct TheSportsDBGatedTransport: ESPNTransport {
    let inner: any ESPNTransport
    let gate: TheSportsDBRequestGate

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await gate.admit()
        let (data, response) = try await inner.send(request)
        // Cloudflare answers a rate-limited client with "error code: 1015" (seen on a 200/429).
        let limited = response.statusCode == 429
            || data.prefix(16).starts(with: Data("error code: 1015".utf8))
        if limited {
            await gate.tripCooldown()
            throw KyroSportsDataError.httpStatus(429)
        }
        return (data, response)
    }
}

// MARK: - Exact event matching

enum TheSportsDBEventMatcher {
    /// ESPN soccer competition slug -> TheSportsDB league id. Only leagues whose finished matches
    /// returned statistics on 2026-11-08 are listed. MLS and the rest are deliberately absent.
    static let verifiedLeagueIDs: [String: String] = [
        "eng.1": "4328",
        "esp.1": "4335",
        "ger.1": "4331",
        "ita.1": "4332",
        "fra.1": "4334",
    ]

    static let kickoffTolerance: TimeInterval = 15 * 60
    private static let finalStatuses: Set<String> = ["ft", "aet", "pen", "match finished"]
    private static let noiseTokens: Set<String> = ["fc", "cf", "afc", "ac", "as", "sc", "ssc", "the", "calcio"]

    enum Result: Equatable {
        case matched(String)
        case none
        case ambiguous
    }

    static func leagueID(for game: KyroSportsGame) -> String? {
        guard game.league == .soccer, let key = game.competitionKey else { return nil }
        return verifiedLeagueIDs[key]
    }

    static func isEligible(_ game: KyroSportsGame) -> Bool {
        leagueID(for: game) != nil && game.status.isFinal && !game.isStartTimeTBD && game.startTime != nil
    }

    /// Every field must agree: league, status, postponement, kickoff within 15 minutes, home and
    /// away names (equality after normalisation against ESPN's name variants, in the same
    /// orientation) and the final score. Zero or several survivors never produce an id.
    static func match(game: KyroSportsGame, events: [TheSportsDBDayResponse.Event]) -> Result {
        guard let leagueID = leagueID(for: game), let start = game.startTime else { return .none }
        let homeNames = nameSet(game.home.team)
        let awayNames = nameSet(game.away.team)
        let survivors = events.filter { event in
            guard event.idEvent?.isEmpty == false,
                  event.idLeague == leagueID,
                  finalStatuses.contains((event.strStatus ?? "").lowercased()),
                  (event.strPostponed ?? "no").lowercased() != "yes",
                  let kickoff = parseTimestamp(event.strTimestamp),
                  abs(kickoff.timeIntervalSince(start)) <= kickoffTolerance,
                  let home = event.strHomeTeam, homeNames.contains(normalize(home)),
                  let away = event.strAwayTeam, awayNames.contains(normalize(away)),
                  let homeScore = event.intHomeScore.flatMap(Int.init),
                  let awayScore = event.intAwayScore.flatMap(Int.init) else { return false }
            if let espnHome = game.home.score, espnHome != homeScore { return false }
            if let espnAway = game.away.score, espnAway != awayScore { return false }
            return true
        }
        switch survivors.count {
        case 0: return .none
        case 1: return .matched(survivors[0].idEvent ?? "")
        default: return .ambiguous
        }
    }

    static func nameSet(_ team: KyroSportsTeam) -> Set<String> {
        var names = [team.fullName, team.nickname]
        if let location = team.location { names.append(location) }
        names.append(contentsOf: team.alternateNames)
        return Set(names.map(normalize).filter { !$0.isEmpty })
    }

    static func normalize(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
        let tokens = folded.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : " " }.joined()
            .split(separator: " ").map(String.init)
            .filter { !noiseTokens.contains($0) }
        return tokens.joined(separator: " ")
    }

    static func parseTimestamp(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: value)
    }

    static func utcDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Statistic mapping

enum TheSportsDBStatisticMapping {
    /// Provider labels Kyro knows how to name. Anything else is dropped rather than shown raw.
    private static let labels: [String: String] = [
        "expected_goals": "Expected goals (xG)",
        "passes accurate": "Accurate passes",
        "shots insidebox": "Shots inside box",
        "shots outsidebox": "Shots outside box",
        "blocked shots": "Blocked shots",
        "free kicks": "Free kicks",
    ]

    /// Rows ESPN does not already show, with plain numeric values only. `existingLabels` are the
    /// ESPN team-statistic labels, so an ESPN value is never replaced or duplicated.
    static func rows(from stats: [TheSportsDBStatsResponse.Stat], existingLabels: [String])
        -> [KyroSportsSupplementalStatistics.Row] {
        let existing = Set(existingLabels.map { $0.lowercased() })
        var seen = Set<String>()
        return stats.compactMap { stat in
            guard let raw = stat.strStat?.lowercased(), let label = labels[raw],
                  !existing.contains(label.lowercased()), !seen.contains(label),
                  let home = numeric(stat.intHome), let away = numeric(stat.intAway) else { return nil }
            seen.insert(label)
            return .init(label: label, home: home, away: away)
        }
    }

    private static func numeric(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty,
              Double(value) != nil else { return nil }
        return value
    }
}

// MARK: - Client

struct TheSportsDBClient: KyroSportsSupplementProviding {
    var flagKey: String { KyroSportsSupplementFlag.defaultsKey }
    func isEligible(_ game: KyroSportsGame) -> Bool { TheSportsDBEventMatcher.isEligible(game) }

    private let baseURL: URL
    private let transport: any ESPNTransport
    private let cache: ESPNEventDetailResponseCache
    private let timeout: TimeInterval

    init(
        baseURL: URL = URL(string: "https://www.thesportsdb.com/api/v1/json/123")!,
        transport: any ESPNTransport = URLSessionESPNTransport(),
        gate: TheSportsDBRequestGate = TheSportsDBRequestGate(),
        cache: ESPNEventDetailResponseCache = ESPNEventDetailResponseCache(),
        timeout: TimeInterval = 10
    ) {
        self.baseURL = baseURL
        self.transport = TheSportsDBGatedTransport(inner: transport, gate: gate)
        self.cache = cache
        self.timeout = timeout
    }

    /// At most two requests: the league's day listing, then the matched event's statistics. Each is
    /// cached (provider Cache-Control honoured) and coalesced. Nothing here is retried.
    func supplementalStatistics(for game: KyroSportsGame, existingLabels: [String]) async -> KyroSportsSupplementOutcome {
        guard TheSportsDBEventMatcher.isEligible(game),
              let leagueID = TheSportsDBEventMatcher.leagueID(for: game),
              let start = game.startTime else { return .notEligible }
        do {
            let day = TheSportsDBEventMatcher.utcDay(start)
            let dayData = try await fetch(path: "eventsday.php", query: [("d", day), ("l", leagueID)],
                                          key: "day|\(leagueID)|\(day)", freshness: 4 * 3600)
            let events = (try? JSONDecoder().decode(TheSportsDBDayResponse.self, from: dayData))?.events ?? []
            switch TheSportsDBEventMatcher.match(game: game, events: events) {
            case .none: return .noVerifiedMatch
            case .ambiguous: return .ambiguousMatch
            case .matched(let eventID):
                try Task.checkCancellation()
                let statsData = try await fetch(path: "lookupeventstats.php", query: [("id", eventID)],
                                                key: "stats|\(eventID)", freshness: 12 * 3600)
                let stats = (try? JSONDecoder().decode(TheSportsDBStatsResponse.self, from: statsData))?.eventstats ?? []
                // Statistics must belong to the matched event; mismatched rows are discarded.
                let own = stats.filter { $0.idEvent == eventID }
                let rows = TheSportsDBStatisticMapping.rows(from: own, existingLabels: existingLabels)
                guard !rows.isEmpty else { return .noAdditionalStatistics }
                return .available(.init(gameID: game.id, providerEventID: eventID, rows: rows))
            }
        } catch is CancellationError {
            return .cancelled
        } catch let error as KyroSportsEventDetailError where error == .cancelled {
            return .cancelled
        } catch {
            return .providerUnavailable
        }
    }

    private func fetch(path: String, query: [(String, String)], key: String, freshness: TimeInterval) async throws -> Data {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw KyroSportsEventDetailError.malformedResponse
        }
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components.url else { throw KyroSportsEventDetailError.malformedResponse }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await cache.data(for: request, key: "tsdb|\(key)", fallbackFreshness: freshness, transport: transport)
    }
}
