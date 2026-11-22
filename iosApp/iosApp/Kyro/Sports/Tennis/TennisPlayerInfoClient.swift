import Foundation

// Build 64: optional player context for a tennis match: tour ranking, country, head-to-head and the
// last five results. Source: theScore's public tennis JSON (api.thescore.com/{atp|wta}/...), probed
// 2026-11-12, no key, no login. Its match endpoint carries `team_N_standing`, `past_meetings_matches`
// and `team_N_last_matches`, so one request after the match is located supplies everything.
//
// This is historical context, not match statistics, and the UI says so. theScore has no serve
// statistics (checked: no box-score or stats resource exists for tennis matches). Surface-specific
// records are not offered because the source does not publish them.
//
// Requests per selected match, each cached and gated, never retried: the season's event list
// (~0.2 MB, 6 h), the event's match list (~0.1-0.5 MB, 10 min), the match itself (~30 KB, 30 min).
// Identity: the event must overlap the ESPN tournament name and contain the match date, and the
// match must name both ESPN players (full name or "J. Surname"), singles only, exactly once.

struct KyroTennisPlayerInfo: Equatable, Sendable {
    struct Player: Equatable, Sendable {
        let name: String
        let country: String?
        let rank: Int?
        let points: Int?
        let hand: String?
        let age: Int?
        /// Most recent first. `won` is from this player's point of view.
        let recent: [Result]
    }

    struct Result: Equatable, Sendable, Identifiable {
        let id: String
        let won: Bool
        let summary: String
        let event: String
        let date: Date?
    }

    let gameID: KyroGameID
    let providerName: String
    let home: Player
    let away: Player
    let homeHeadToHeadWins: Int
    let awayHeadToHeadWins: Int
    let meetings: Int
    /// Build 68: the tournament's playing surface and venue from the event the match was found in
    /// (theScore `ground_type`, `tournament_stadium`), nil when the event does not say.
    var surface: String? = nil
    var venue: String? = nil
}

protocol KyroTennisPlayerInfoProviding: Sendable {
    var flagKey: String { get }
    func isEligible(_ game: KyroSportsGame) -> Bool
    func playerInfo(for game: KyroSportsGame) async -> KyroTennisPlayerInfo?
}

// MARK: - Wire models (everything optional: the feed carries far more than is read)
//
// Build 65: decoding is lenient. One player with a mistyped field (an age as text, points as a
// decimal) used to fail the whole event's match list, so every match in it lost its Players card.
// A field that does not decode is now nil, and a list element that does not decode is skipped.

extension KeyedDecodingContainer {
    func theScoreLenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// An integer sent as a number, a decimal or text.
    func theScoreLenientInt(_ key: Key) -> Int? {
        if let value = theScoreLenient(Int.self, key) { return value }
        if let value = theScoreLenient(Double.self, key), value.isFinite { return Int(value) }
        if let text = theScoreLenient(String.self, key) { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    func theScoreLossyArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T]? {
        theScoreLenient(TheScoreLossyArray<T>.self, key)?.values
    }
}

/// Decodes the elements that decode and skips the rest.
struct TheScoreLossyArray<T: Decodable>: Decodable {
    let values: [T]

    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [T] = []
        while !container.isAtEnd {
            if let value = try? container.decode(T.self) {
                values.append(value)
            } else if (try? container.decode(Skip.self)) == nil {
                break
            }
        }
        self.values = values
    }
}

struct TheScoreEvent: Decodable, Sendable {
    let id: Int?
    let name: String?
    let start_date: String?
    let end_date: String?
    /// Build 68: `hardcourt_outdoor`, `hardcourt_indoor`, `red_clay`, `grass` (2026 ATP list).
    var ground_type: String? = nil
    var stadiumName: String? = nil
    var stadiumLocation: String? = nil

    private struct Stadium: Decodable {
        let name: String?
        let location: String?
    }

    private enum CodingKeys: String, CodingKey { case id, name, start_date, end_date, ground_type, tournament_stadium }
    init(id: Int?, name: String?, start_date: String?, end_date: String?, ground_type: String? = nil) {
        (self.id, self.name, self.start_date, self.end_date) = (id, name, start_date, end_date)
        self.ground_type = ground_type
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.theScoreLenientInt(.id)
        name = c.theScoreLenient(String.self, .name)
        start_date = c.theScoreLenient(String.self, .start_date)
        end_date = c.theScoreLenient(String.self, .end_date)
        ground_type = c.theScoreLenient(String.self, .ground_type)
        let stadium = c.theScoreLenient(Stadium.self, .tournament_stadium)
        stadiumName = stadium?.name
        stadiumLocation = stadium?.location
    }

    /// `Kungliga Tennishallen, Stockholm, Sweden`.
    var venue: String? {
        let parts = [stadiumName, stadiumLocation].compactMap { value -> String? in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

struct TheScorePlayer: Decodable, Sendable {
    let first_name: String?
    let last_name: String?
    let country: String?
    let plays: String?
    let age: Int?

    private enum CodingKeys: String, CodingKey { case first_name, last_name, country, plays, age }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        first_name = c.theScoreLenient(String.self, .first_name)
        last_name = c.theScoreLenient(String.self, .last_name)
        country = c.theScoreLenient(String.self, .country)
        plays = c.theScoreLenient(String.self, .plays)
        age = c.theScoreLenientInt(.age)
    }
}

struct TheScoreTeam: Decodable, Sendable {
    let id: Int?
    let player1: TheScorePlayer?

    private enum CodingKeys: String, CodingKey { case id, player1 }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.theScoreLenientInt(.id)
        player1 = c.theScoreLenient(TheScorePlayer.self, .player1)
    }
}

struct TheScoreStanding: Decodable, Sendable {
    let place: Int?
    let points: Int?

    private enum CodingKeys: String, CodingKey { case place, points }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        place = c.theScoreLenientInt(.place)
        points = c.theScoreLenientInt(.points)
    }
}

struct TheScoreWinnerRef: Decodable, Sendable {
    let id: Int?

    private enum CodingKeys: String, CodingKey { case id }
    init(from decoder: Decoder) throws {
        id = try decoder.container(keyedBy: CodingKeys.self).theScoreLenientInt(.id)
    }
}

struct TheScorePastMatch: Decodable, Sendable {
    let api_uri: String?
    let match_date: String?
    let winner: TheScoreWinnerRef?
    let result_text: String?
    let event_name: String?
    let round_name_abbreviation: String?

    private enum CodingKeys: String, CodingKey {
        case api_uri, match_date, winner, result_text, event_name, round_name_abbreviation
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        api_uri = c.theScoreLenient(String.self, .api_uri)
        match_date = c.theScoreLenient(String.self, .match_date)
        winner = c.theScoreLenient(TheScoreWinnerRef.self, .winner)
        result_text = c.theScoreLenient(String.self, .result_text)
        event_name = c.theScoreLenient(String.self, .event_name)
        round_name_abbreviation = c.theScoreLenient(String.self, .round_name_abbreviation)
    }
}

struct TheScoreMatch: Decodable, Sendable {
    let id: Int?
    let is_double: Bool?
    let match_date: String?
    let team_1: TheScoreTeam?
    let team_2: TheScoreTeam?
    let team_1_standing: TheScoreStanding?
    let team_2_standing: TheScoreStanding?
    let past_meetings_matches: [TheScorePastMatch]?
    let team_1_last_matches: [TheScorePastMatch]?
    let team_2_last_matches: [TheScorePastMatch]?

    private enum CodingKeys: String, CodingKey {
        case id, is_double, match_date, team_1, team_2, team_1_standing, team_2_standing
        case past_meetings_matches, team_1_last_matches, team_2_last_matches
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.theScoreLenientInt(.id)
        is_double = c.theScoreLenient(Bool.self, .is_double)
        match_date = c.theScoreLenient(String.self, .match_date)
        team_1 = c.theScoreLenient(TheScoreTeam.self, .team_1)
        team_2 = c.theScoreLenient(TheScoreTeam.self, .team_2)
        team_1_standing = c.theScoreLenient(TheScoreStanding.self, .team_1_standing)
        team_2_standing = c.theScoreLenient(TheScoreStanding.self, .team_2_standing)
        past_meetings_matches = c.theScoreLossyArray(TheScorePastMatch.self, .past_meetings_matches)
        team_1_last_matches = c.theScoreLossyArray(TheScorePastMatch.self, .team_1_last_matches)
        team_2_last_matches = c.theScoreLossyArray(TheScorePastMatch.self, .team_2_last_matches)
    }
}

enum TheScoreTennisMapping {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    static func date(_ value: String?) -> Date? { value.flatMap { formatter.date(from: $0) } }

    static func fullName(_ player: TheScorePlayer?) -> String {
        [player?.first_name, player?.last_name].compactMap { $0 }.joined(separator: " ")
    }

    /// Events running on the match day. When exactly one also shares a word with ESPN's tournament
    /// name it is the only candidate; otherwise sponsors differ ("Bybit Stockholm Open" is "BNP
    /// Paribas Nordic Open" here), so every event running that week, at most four, is searched for
    /// the two players. Identity still comes from the players, never from the event alone.
    static func candidateEvents(for game: KyroSportsGame, in events: [TheScoreEvent]) -> [TheScoreEvent] {
        guard let start = game.startTime else { return [] }
        let running = events.filter { event in
            guard let from = date(event.start_date), let to = date(event.end_date) else { return false }
            return start >= from.addingTimeInterval(-3 * 86_400) && start <= to.addingTimeInterval(86_400)
        }
        let named = running.filter { $0.name.map { TMLMatchMatcher.tournamentsOverlap(game.tournament, $0) } ?? false }
        if named.count == 1 { return named }
        return Array(running.prefix(4))
    }

    /// Singles match naming both ESPN players, exactly once. Returns the provider id.
    static func matchID(for game: KyroSportsGame, in matches: [TheScoreMatch]) -> (id: Int, homeIsTeam1: Bool)? {
        var hits: [(Int, Bool)] = []
        for m in matches where m.is_double != true {
            guard let id = m.id else { continue }
            let one = fullName(m.team_1?.player1), two = fullName(m.team_2?.player1)
            if TMLMatchMatcher.samePlayer(one, game.home.team), TMLMatchMatcher.samePlayer(two, game.away.team) { hits.append((id, true)) }
            else if TMLMatchMatcher.samePlayer(one, game.away.team), TMLMatchMatcher.samePlayer(two, game.home.team) { hits.append((id, false)) }
        }
        return hits.count == 1 ? (hits[0].0, hits[0].1) : nil
    }

    static func info(game: KyroSportsGame, match: TheScoreMatch, homeIsTeam1: Bool) -> KyroTennisPlayerInfo? {
        guard let t1 = match.team_1, let t2 = match.team_2, let id1 = t1.id, let id2 = t2.id else { return nil }
        let currentID = match.id
        func player(_ team: TheScoreTeam, id: Int, standing: TheScoreStanding?, last: [TheScorePastMatch]?) -> KyroTennisPlayerInfo.Player {
            let results = (last ?? []).compactMap { past -> KyroTennisPlayerInfo.Result? in
                guard let winner = past.winner?.id, let uri = past.api_uri,
                      uri != "/atp/matches/\(currentID ?? -1)", uri != "/wta/matches/\(currentID ?? -1)" else { return nil }
                return .init(id: uri, won: winner == id, summary: past.result_text ?? "",
                             event: [past.event_name, past.round_name_abbreviation].compactMap { $0 }.joined(separator: " · "),
                             date: date(past.match_date))
            }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            return .init(name: fullName(team.player1), country: team.player1?.country,
                         rank: standing?.place, points: standing?.points, hand: team.player1?.plays,
                         age: team.player1?.age, recent: Array(results.prefix(5)))
        }
        let p1 = player(t1, id: id1, standing: match.team_1_standing, last: match.team_1_last_matches)
        let p2 = player(t2, id: id2, standing: match.team_2_standing, last: match.team_2_last_matches)
        var wins1 = 0, wins2 = 0, total = 0
        for past in match.past_meetings_matches ?? [] {
            guard let winner = past.winner?.id, past.api_uri.map({ $0 != "/atp/matches/\(currentID ?? -1)" && $0 != "/wta/matches/\(currentID ?? -1)" }) ?? true else { continue }
            if winner == id1 { wins1 += 1; total += 1 } else if winner == id2 { wins2 += 1; total += 1 }
        }
        return .init(gameID: game.id, providerName: "theScore",
                     home: homeIsTeam1 ? p1 : p2, away: homeIsTeam1 ? p2 : p1,
                     homeHeadToHeadWins: homeIsTeam1 ? wins1 : wins2, awayHeadToHeadWins: homeIsTeam1 ? wins2 : wins1,
                     meetings: total)
    }
}

struct TheScoreTennisInfoClient: KyroTennisPlayerInfoProviding {
    var flagKey: String { KyroSportsSupplementFlag.tennisPlayerInfoKey }

    private let baseURL: URL
    private let transport: any ESPNTransport
    private let cache: ESPNEventDetailResponseCache

    init(
        baseURL: URL = URL(string: "https://api.thescore.com")!,
        transport: any ESPNTransport = URLSessionESPNTransport(),
        gate: TheSportsDBRequestGate = TheSportsDBRequestGate(spacing: 0.5, limit: 30),
        cache: ESPNEventDetailResponseCache = ESPNEventDetailResponseCache()
    ) {
        self.baseURL = baseURL
        self.transport = TheSportsDBGatedTransport(inner: transport, gate: gate)
        self.cache = cache
    }

    func isEligible(_ game: KyroSportsGame) -> Bool {
        (game.league == .atp || game.league == .wta) && game.isSingles && game.startTime != nil
    }

    func playerInfo(for game: KyroSportsGame) async -> KyroTennisPlayerInfo? {
        guard isEligible(game) else { return nil }
        let tour = game.league == .wta ? "wta" : "atp"
        do {
            let eventsData = try await fetch("\(tour)/events", key: "events|\(tour)", freshness: 6 * 3600)
            let events = await Task.detached(priority: .utility) { (try? JSONDecoder().decode(TheScoreLossyArray<TheScoreEvent>.self, from: eventsData))?.values ?? [] }.value
            var located: (Int, Bool)?
            var locatedEvent: TheScoreEvent?
            for event in TheScoreTennisMapping.candidateEvents(for: game, in: events) {
                guard let eventID = event.id else { continue }
                try Task.checkCancellation()
                let listData = try await fetch("\(tour)/events/\(eventID)/matches", key: "matches|\(tour)|\(eventID)", freshness: 10 * 60)
                located = await Task.detached(priority: .utility) { () -> (Int, Bool)? in
                    let list = (try? JSONDecoder().decode(TheScoreLossyArray<TheScoreMatch>.self, from: listData))?.values ?? []
                    return TheScoreTennisMapping.matchID(for: game, in: list)
                }.value
                if located != nil { locatedEvent = event; break }
            }
            guard let (matchID, homeIsTeam1) = located else { return nil }
            try Task.checkCancellation()
            let matchData = try await fetch("\(tour)/matches/\(matchID)", key: "match|\(tour)|\(matchID)", freshness: 30 * 60)
            let surface = KyroTennisSurface.label(groundType: locatedEvent?.ground_type)
            let venue = locatedEvent?.venue
            return await Task.detached(priority: .utility) { () -> KyroTennisPlayerInfo? in
                guard let match = try? JSONDecoder().decode(TheScoreMatch.self, from: matchData), match.id == matchID else { return nil }
                var info = TheScoreTennisMapping.info(game: game, match: match, homeIsTeam1: homeIsTeam1)
                info?.surface = surface
                info?.venue = venue
                return info
            }.value
        } catch {
            return nil
        }
    }

    private func fetch(_ path: String, key: String, freshness: TimeInterval) async throws -> Data {
        guard let url = URL(string: baseURL.absoluteString + "/" + path) else { throw KyroSportsEventDetailError.malformedResponse }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await cache.data(for: request, key: "thescore|\(key)", fallbackFreshness: freshness, transport: transport)
    }
}
