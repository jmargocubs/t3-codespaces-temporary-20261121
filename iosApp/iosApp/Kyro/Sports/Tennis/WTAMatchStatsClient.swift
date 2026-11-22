import Foundation

// Build 63: WTA match statistics for finished WTA singles matches.
//
// Source: api.wtatennis.com, the JSON service behind wtatennis.com. It is public and needs no key
// (probed 2026-11-12: tournaments, matches and per-match stats all answered 200; stats carry
// `Cache-Control: max-age=30` behind CloudFront). It is undocumented, so it can change without
// notice: the adapter is flag-guarded, budgeted, cached and fails to "unavailable".
//
// ATP has no equivalent here: atptour.com and its data host answer HTTP 403 to automated clients,
// and Kyro does not work around that.

struct WTATournamentsResponse: Decodable, Sendable {
    let content: [Tournament]?

    struct Tournament: Decodable, Sendable {
        let title: String?
        let year: Int?
        let tournamentGroup: Group?
        struct Group: Decodable, Sendable { let id: Int? }
    }
}

struct WTAMatchesResponse: Decodable, Sendable {
    let matches: [Match]?

    struct Match: Decodable, Sendable {
        let MatchID: String?
        let DrawMatchType: String?
        let MatchState: String?
        let PlayerNameFirstA: String?
        let PlayerNameLastA: String?
        let PlayerNameFirstB: String?
        let PlayerNameLastB: String?
        let PlayerNameFirstA2: String?
        // Set scores are oriented to players A and B. `ScoreString` is NOT: it reads winner-first
        // (checked on WTA Finals LS010, where A lost "6-2,6-4").
        let ScoreSet1A: LenientInt?, ScoreSet1B: LenientInt?
        let ScoreSet2A: LenientInt?, ScoreSet2B: LenientInt?
        let ScoreSet3A: LenientInt?, ScoreSet3B: LenientInt?
        let ScoreSet4A: LenientInt?, ScoreSet4B: LenientInt?
        let ScoreSet5A: LenientInt?, ScoreSet5B: LenientInt?

        /// Games per played set as (A, B); a set with a missing side ends the list.
        var sets: [(a: Int, b: Int)] {
            let pairs = [(ScoreSet1A, ScoreSet1B), (ScoreSet2A, ScoreSet2B), (ScoreSet3A, ScoreSet3B),
                         (ScoreSet4A, ScoreSet4B), (ScoreSet5A, ScoreSet5B)]
            var output: [(Int, Int)] = []
            for (a, b) in pairs {
                guard let a = a?.value, let b = b?.value else { break }
                output.append((a, b))
            }
            return output
        }
    }
}

/// Decodes `"6"`, `6` or `""` (empty/unplayed) without failing the whole match list.
struct LenientInt: Decodable, Sendable {
    let value: Int?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) { value = int }
        else if let string = try? container.decode(String.self) { value = Int(string) }
        else { value = nil }
    }
}

struct WTAMatchStat: Decodable, Sendable {
    let matchid: String?
    let setnum: Int?
    let acesa: Int?, acesb: Int?
    let dblflta: Int?, dblfltb: Int?
    let ptswon1stserva: Int?, ptswon1stservb: Int?
    let ptsplayed1stserva: Int?, ptsplayed1stservb: Int?
    let ptstotwonserva: Int?, ptstotwonservb: Int?
    let totservplayeda: Int?, totservplayedb: Int?
    let breakptsconva: Int?, breakptsconvb: Int?
    let breakptsplayeda: Int?, breakptsplayedb: Int?
    let totptswona: Int?, totptswonb: Int?
}

enum WTAMatchMatcher {
    static func isEligible(_ game: KyroSportsGame) -> Bool {
        game.league == .wta && game.isSingles && game.status.isFinal && game.startTime != nil
            && !(game.tournament ?? "").isEmpty
    }

    /// Tournament names compare after dropping a leading year and WTA's " - City, Country" suffix.
    static func tournamentKey(_ name: String) -> String {
        var base = name
        if let range = base.range(of: " - ") { base = String(base[..<range.lowerBound]) }
        var tokens = TheSportsDBEventMatcher.normalize(base).split(separator: " ").map(String.init)
        if let first = tokens.first, first.count == 4, Int(first) != nil { tokens.removeFirst() }
        return tokens.joined(separator: " ")
    }

    /// The single tournament whose name equals ESPN's. Several (or none) means no match.
    static func tournament(for game: KyroSportsGame, in list: [WTATournamentsResponse.Tournament])
        -> (id: Int, year: Int)? {
        guard let name = game.tournament else { return nil }
        let key = tournamentKey(name)
        guard !key.isEmpty else { return nil }
        let hits = list.compactMap { entry -> (Int, Int)? in
            guard let title = entry.title, tournamentKey(title) == key,
                  let id = entry.tournamentGroup?.id, let year = entry.year else { return nil }
            return (id, year)
        }
        return hits.count == 1 ? (hits[0].0, hits[0].1) : nil
    }

    enum Side: Equatable { case aIsHome, aIsAway }
    enum Result: Equatable {
        case matched(id: String, side: Side)
        case none
        case ambiguous
    }

    /// Both players (full name, or surname plus first initial), the oriented set scores and the
    /// finished state must all agree. Zero or several survivors never produce an id.
    static func match(game: KyroSportsGame, matches: [WTAMatchesResponse.Match]) -> Result {
        let espnSets = game.periods.filter(\.hasScore).compactMap { period -> (home: Int, away: Int)? in
            guard let home = period.homeScore, let away = period.awayScore else { return nil }
            return (home, away)
        }
        guard !espnSets.isEmpty else { return .none }
        var hits: [(String, Side)] = []
        for m in matches {
            guard m.DrawMatchType == "S", m.MatchState == "F", let id = m.MatchID, !id.isEmpty,
                  m.PlayerNameFirstA2 == nil || m.PlayerNameFirstA2 == "",
                  let first = m.PlayerNameFirstA, let last = m.PlayerNameLastA,
                  let firstB = m.PlayerNameFirstB, let lastB = m.PlayerNameLastB,
                  case let sets = m.sets, !sets.isEmpty else { continue }
            let a = (first, last), b = (firstB, lastB)
            let side: Side
            if samePlayer(a, game.home.team), samePlayer(b, game.away.team) {
                side = .aIsHome
            } else if samePlayer(a, game.away.team), samePlayer(b, game.home.team) {
                side = .aIsAway
            } else { continue }
            guard sets.count == espnSets.count else { continue }
            let agrees = zip(sets, espnSets).allSatisfy { wta, espn in
                side == .aIsHome ? (wta.a == espn.home && wta.b == espn.away)
                                 : (wta.a == espn.away && wta.b == espn.home)
            }
            if agrees { hits.append((id, side)) }
        }
        switch hits.count {
        case 0: return .none
        case 1: return .matched(id: hits[0].0, side: hits[0].1)
        default: return .ambiguous
        }
    }

    static func samePlayer(_ wta: (first: String, last: String), _ team: KyroSportsTeam) -> Bool {
        let full = TheSportsDBEventMatcher.normalize("\(wta.first) \(wta.last)")
        let espnNames = Set(([team.nickname] + team.alternateNames).map(TheSportsDBEventMatcher.normalize))
        if espnNames.contains(full) || TMLMatchMatcher.sameNameIgnoringOrder(full, espnNames) { return true }
        // "L. Noskova" style short names: surname must be identical and the initial must agree.
        let last = TheSportsDBEventMatcher.normalize(wta.last)
        let initial = TheSportsDBEventMatcher.normalize(wta.first).first
        return espnNames.contains { name in
            let tokens = name.split(separator: " ")
            guard tokens.count >= 2, let initialToken = tokens.first, initialToken.count == 1 else { return false }
            return tokens.dropFirst().joined(separator: " ") == last && initialToken.first == initial
        }
    }
}

enum WTAStatisticMapping {
    typealias Row = KyroSportsSupplementalStatistics.Row

    static func percent(_ part: Int?, of total: Int?) -> String? {
        guard let part, let total, total > 0, part >= 0, part <= total else { return nil }
        return "\(Int((Double(part) / Double(total) * 100).rounded()))%"
    }

    static func ratio(_ part: Int?, _ total: Int?) -> String? {
        guard let part, let total, total >= 0, part >= 0, part <= total else { return nil }
        return "\(part)/\(total)"
    }

    /// Provider side A/B -> Kyro home/away.
    private static func row(_ label: String, a: String?, b: String?, side: WTAMatchMatcher.Side) -> Row? {
        guard let a, let b else { return nil }
        return side == .aIsHome ? Row(label: label, home: a, away: b) : Row(label: label, home: b, away: a)
    }

    private static func count(_ value: Int?) -> String? { value.map(String.init) }

    static func matchRows(_ s: WTAMatchStat, side: WTAMatchMatcher.Side) -> [Row] {
        let secondPlayedA = diff(s.totservplayeda, s.ptsplayed1stserva).map { $0 - $1 }
        let secondPlayedB = diff(s.totservplayedb, s.ptsplayed1stservb).map { $0 - $1 }
        let secondWonA = diff(s.ptstotwonserva, s.ptswon1stserva).map { $0 - $1 }
        let secondWonB = diff(s.ptstotwonservb, s.ptswon1stservb).map { $0 - $1 }
        return [
            row("Aces", a: count(s.acesa), b: count(s.acesb), side: side),
            row("Double faults", a: count(s.dblflta), b: count(s.dblfltb), side: side),
            row("1st serve in", a: percent(s.ptsplayed1stserva, of: s.totservplayeda),
                b: percent(s.ptsplayed1stservb, of: s.totservplayedb), side: side),
            row("1st serve points won", a: percent(s.ptswon1stserva, of: s.ptsplayed1stserva),
                b: percent(s.ptswon1stservb, of: s.ptsplayed1stservb), side: side),
            row("2nd serve points won", a: percent(secondWonA, of: secondPlayedA),
                b: percent(secondWonB, of: secondPlayedB), side: side),
            row("Break points converted", a: ratio(s.breakptsconva, s.breakptsplayeda),
                b: ratio(s.breakptsconvb, s.breakptsplayedb), side: side),
            row("Total points won", a: count(s.totptswona), b: count(s.totptswonb), side: side),
        ].compactMap { $0 }
    }

    static func setRows(_ s: WTAMatchStat, side: WTAMatchMatcher.Side) -> [Row] {
        [
            row("Aces", a: count(s.acesa), b: count(s.acesb), side: side),
            row("Double faults", a: count(s.dblflta), b: count(s.dblfltb), side: side),
            row("Break points converted", a: ratio(s.breakptsconva, s.breakptsplayeda),
                b: ratio(s.breakptsconvb, s.breakptsplayedb), side: side),
        ].compactMap { $0 }
    }
}

private func diff(_ a: Int?, _ b: Int?) -> OptionalPair { OptionalPair(a: a, b: b) }

private struct OptionalPair {
    let a: Int?
    let b: Int?
    func map(_ transform: (Int, Int) -> Int) -> Int? {
        guard let a, let b else { return nil }
        return transform(a, b)
    }
}

struct WTAMatchStatsClient: KyroSportsSupplementProviding {
    var flagKey: String { KyroSportsSupplementFlag.wtaStatsKey }
    func isEligible(_ game: KyroSportsGame) -> Bool { WTAMatchMatcher.isEligible(game) }

    private let baseURL: URL
    private let transport: any ESPNTransport
    private let cache: ESPNEventDetailResponseCache
    private let timeout: TimeInterval

    init(
        baseURL: URL = URL(string: "https://api.wtatennis.com/tennis")!,
        transport: any ESPNTransport = URLSessionESPNTransport(),
        gate: TheSportsDBRequestGate = TheSportsDBRequestGate(spacing: 0.5, limit: 30),
        cache: ESPNEventDetailResponseCache = ESPNEventDetailResponseCache(),
        timeout: TimeInterval = 10
    ) {
        self.baseURL = baseURL
        self.transport = TheSportsDBGatedTransport(inner: transport, gate: gate)
        self.cache = cache
        self.timeout = timeout
    }

    /// At most three cached requests: tournaments for the match's week, that tournament's matches,
    /// and the matched match's statistics. Nothing is retried.
    func supplementalStatistics(for game: KyroSportsGame, existingLabels: [String]) async -> KyroSportsSupplementOutcome {
        guard WTAMatchMatcher.isEligible(game), let start = game.startTime else { return .notEligible }
        do {
            let from = TheSportsDBEventMatcher.utcDay(start.addingTimeInterval(-3 * 86_400))
            let to = TheSportsDBEventMatcher.utcDay(start.addingTimeInterval(3 * 86_400))
            let listData = try await fetch(path: "tournaments/", key: "t|\(from)|\(to)", freshness: 6 * 3600, query: [
                ("page", "0"), ("pageSize", "40"), ("from", from), ("to", to), ("excludeLevels", "ITF"),
            ])
            let list = (try? JSONDecoder().decode(WTATournamentsResponse.self, from: listData))?.content ?? []
            guard let tournament = WTAMatchMatcher.tournament(for: game, in: list) else { return .noVerifiedMatch }
            try Task.checkCancellation()
            let matchesData = try await fetch(path: "tournaments/\(tournament.id)/\(tournament.year)/matches",
                                              key: "m|\(tournament.id)|\(tournament.year)", freshness: 10 * 60, query: [])
            let matches = (try? JSONDecoder().decode(WTAMatchesResponse.self, from: matchesData))?.matches ?? []
            switch WTAMatchMatcher.match(game: game, matches: matches) {
            case .none: return .noVerifiedMatch
            case .ambiguous: return .ambiguousMatch
            case .matched(let id, let side):
                try Task.checkCancellation()
                let statsData = try await fetch(path: "tournaments/\(tournament.id)/\(tournament.year)/matches/\(id)/stats",
                                                key: "s|\(tournament.id)|\(id)", freshness: 6 * 3600, query: [])
                let stats = ((try? JSONDecoder().decode([WTAMatchStat].self, from: statsData)) ?? [])
                    .filter { $0.matchid == id }
                guard let total = stats.first(where: { $0.setnum == 0 }) else { return .noAdditionalStatistics }
                let rows = WTAStatisticMapping.matchRows(total, side: side)
                guard !rows.isEmpty else { return .noAdditionalStatistics }
                let sections = stats.compactMap { stat -> KyroSportsSupplementalStatistics.Section? in
                    guard let n = stat.setnum, (1...5).contains(n) else { return nil }
                    let setRows = WTAStatisticMapping.setRows(stat, side: side)
                    return setRows.isEmpty ? nil : .init(title: "Set \(n)", rows: setRows)
                }.sorted { $0.title < $1.title }
                return .available(.init(
                    gameID: game.id, providerName: "WTA", providerEventID: id,
                    note: "Match statistics published by the WTA. Percentages are calculated from the WTA's point counts.",
                    rows: rows, sections: sections))
            }
        } catch is CancellationError {
            return .cancelled
        } catch let error as KyroSportsEventDetailError where error == .cancelled {
            return .cancelled
        } catch {
            return .providerUnavailable
        }
    }

    private func fetch(path: String, key: String, freshness: TimeInterval, query: [(String, String)]) async throws -> Data {
        guard var components = URLComponents(string: baseURL.absoluteString + "/" + path) else {
            throw KyroSportsEventDetailError.malformedResponse
        }
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        guard let url = components.url else { throw KyroSportsEventDetailError.malformedResponse }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await cache.data(for: request, key: "wta|\(key)", fallbackFreshness: freshness, transport: transport)
    }
}
