import Foundation

// Build 64: completed-match statistics for ATP singles (and a WTA fallback) from the public
// TennisMyLife data files, https://stats.tennismylife.org/data/.
//
// Probed 2026-11-12. The files are plain CSV in Jeff Sackmann's column layout:
//   - `ongoing_tourneys.csv` (ATP) / `wta_ongoing_tourneys.csv`: tournaments in progress, ~5 KB,
//     modified within the hour.
//   - `{year}.csv` (ATP) / `{year}_wta.csv`: the season so far, ~0.6 MB, modified daily.
// Coverage: tour-level main-draw singles (including Slams, Masters, 500/250, Davis Cup, Laver Cup,
// United Cup). Qualifying and Challenger matches are not in these files, so those fall through to
// "unavailable". ~98% of rows carry serve statistics.
//
// Access conditions: robots.txt allows /data/ (it disallows /api/, which is not used). The README
// asks for attribution and forbids commercial use; Kyro is a personal sideloaded app and names the
// source in the Stats tab. The data derives from CC BY-NC-SA material. Requests are conservative:
// at most two per event, cached (ETag / Cache-Control aware), one gate per adapter, no retries.
//
// Every statistic shown is one number recorded for the exact selected match: nothing is averaged
// from a season, and any figure that cannot be derived from recorded counts is left out.

struct TMLMatchRow: Equatable, Sendable {
    struct Side: Equatable, Sendable {
        var ace: Int?, df: Int?, svpt: Int?, firstIn: Int?, firstWon: Int?, secondWon: Int?
        var bpSaved: Int?, bpFaced: Int?
    }
    let tournament: String
    let tournamentStart: Date
    let surface: String
    let round: String
    let winner: String
    let loser: String
    let score: String
    let minutes: Int?
    let w: Side
    let l: Side
}

enum TMLCSV {
    /// Parses only rows whose `tourney_date` lies in `window`, so a whole-season file never turns
    /// into a whole-season array. Singles are the only thing in these files.
    static func rows(from data: Data, window: ClosedRange<Date>) -> [TMLMatchRow] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.split(whereSeparator: \.isNewline).makeIterator()
        guard let headerLine = lines.next() else { return [] }
        let header = fields(String(headerLine))
        var index: [String: Int] = [:]
        for (i, name) in header.enumerated() { index[name] = i }
        let required = ["tourney_name", "tourney_date", "winner_name", "loser_name", "score", "round"]
        guard required.allSatisfy({ index[$0] != nil }) else { return [] }

        var output: [TMLMatchRow] = []
        let dateIndex = index["tourney_date"] ?? 0
        while let line = lines.next() {
            // Cheap pre-check: read only the date column before splitting the whole row.
            if !line.contains("\"") {
                let head = line.split(separator: ",", maxSplits: dateIndex + 1, omittingEmptySubsequences: false)
                guard head.count > dateIndex, let start = date(String(head[dateIndex])), window.contains(start) else { continue }
            }
            let cells = fields(String(line))
            func cell(_ key: String) -> String { index[key].flatMap { $0 < cells.count ? cells[$0] : nil } ?? "" }
            func int(_ key: String) -> Int? { Int(cell(key)) }
            guard let start = date(cell("tourney_date")), window.contains(start) else { continue }
            func side(_ p: String) -> TMLMatchRow.Side {
                .init(ace: int(p + "ace"), df: int(p + "df"), svpt: int(p + "svpt"), firstIn: int(p + "1stIn"),
                      firstWon: int(p + "1stWon"), secondWon: int(p + "2ndWon"),
                      bpSaved: int(p + "bpSaved"), bpFaced: int(p + "bpFaced"))
            }
            output.append(TMLMatchRow(
                tournament: cell("tourney_name"), tournamentStart: start, surface: cell("surface"),
                round: cell("round"), winner: cell("winner_name"), loser: cell("loser_name"),
                score: cell("score"), minutes: int("minutes"), w: side("w_"), l: side("l_")))
        }
        return output
    }

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func date(_ yyyymmdd: String) -> Date? {
        guard yyyymmdd.count == 8, let value = Int(yyyymmdd) else { return nil }
        return calendar.date(from: DateComponents(year: value / 10_000, month: value / 100 % 100, day: value % 100))
    }

    /// Comma split with double-quote support (tournament names are the only text that could need it).
    static func fields(_ line: String) -> [String] {
        guard line.contains("\"") else { return line.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        var result: [String] = []
        var current = ""
        var quoted = false
        for character in line {
            if character == "\"" { quoted.toggle() }
            else if character == ",", !quoted { result.append(current); current = "" }
            else { current.append(character) }
        }
        result.append(current)
        return result
    }
}

enum TMLMatchMatcher {
    static func isEligible(_ game: KyroSportsGame) -> Bool {
        (game.league == .atp || game.league == .wta) && game.isSingles && game.status.isFinal && game.startTime != nil
    }

    /// A tournament's week starts on or before its first match; qualifying precedes it, so the file's
    /// week must begin between 17 days before and 1 day after the ESPN start time.
    static func window(for start: Date) -> ClosedRange<Date> {
        start.addingTimeInterval(-17 * 86_400)...start.addingTimeInterval(86_400)
    }

    /// ESPN round text -> the file's codes. Unknown wording (ESPN's "1st Round" depends on draw size)
    /// returns nil and is not used to accept or reject.
    static func roundCode(_ espn: String?) -> String? {
        guard let text = espn.map(TheSportsDBEventMatcher.normalize), !text.isEmpty else { return nil }
        if text.contains("qualif") { return "Q" }
        if text.contains("semi") { return "SF" }
        if text.contains("quarter") { return "QF" }
        if text.contains("round robin") || text.contains("group") { return "RR" }
        if text.contains("round of 128") { return "R128" }
        if text.contains("round of 64") { return "R64" }
        if text.contains("round of 32") { return "R32" }
        if text.contains("round of 16") { return "R16" }
        if text == "final" || text == "finals" { return "F" }
        return nil
    }

    /// Set scores written winner-first, "6-7(4)" tiebreaks reduced to games. Walkovers have none.
    static func sets(from score: String) -> [(winner: Int, loser: Int)] {
        score.split(separator: " ").compactMap { token in
            let parts = token.split(separator: "(", maxSplits: 1)[0].split(separator: "-")
            guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) else { return nil }
            return (a, b)
        }
    }

    /// Dataset names are full ("Juan Manuel Cerundolo"). ESPN may use the full name, or "J. Cerundolo".
    static func samePlayer(_ fullName: String, _ team: KyroSportsTeam) -> Bool {
        let full = TheSportsDBEventMatcher.normalize(fullName)
        guard !full.isEmpty else { return false }
        let espnNames = Set(([team.nickname] + team.alternateNames).map(TheSportsDBEventMatcher.normalize))
        if espnNames.contains(full) { return true }
        let tokens = full.split(separator: " ").map(String.init)
        if sameNameIgnoringOrder(full, espnNames) { return true }
        return espnNames.contains { name in
            let parts = name.split(separator: " ").map(String.init)
            guard parts.count >= 2, parts[0].count == 1, tokens.count > parts.count - 1 else { return false }
            let surname = Array(parts.dropFirst())
            return Array(tokens.suffix(surname.count)) == surname && tokens.first?.first == parts[0].first
        }
    }

    /// Family name first on one side ("Zhang Zhizhen" / "Zhizhen Zhang") and given names split
    /// differently ("Wang Xinyu" / "Xin Yu Wang"): equal once spaces are removed and the word order
    /// is rotated. Only an exact letter-for-letter rotation qualifies.
    static func sameNameIgnoringOrder(_ full: String, _ espnNames: Set<String>) -> Bool {
        let target = full.replacingOccurrences(of: " ", with: "")
        guard full.split(separator: " ").count >= 2 else { return false }
        return espnNames.contains { name in
            let words = name.split(separator: " ").map(String.init)
            guard words.count >= 2 else { return false }
            return (0..<words.count).contains { shift in
                (Array(words[shift...]) + Array(words[..<shift])).joined() == target
            }
        }
    }

    /// Shares a meaningful word, e.g. "Rolex Paris Masters" and "Paris Masters". Used only to choose
    /// between otherwise identical candidates, never to accept or reject a single one: ESPN and the
    /// dataset disagree too often ("French Open" / "Roland Garros", "Nitto ATP Finals" / "Tour Finals").
    static func tournamentsOverlap(_ espn: String?, _ other: String) -> Bool {
        let generic: Set<String> = ["open", "masters", "atp", "wta", "tour", "the", "of", "de", "international", "championships", "classic"]
        func words(_ s: String) -> Set<String> {
            Set(TheSportsDBEventMatcher.normalize(s).split(separator: " ").map(String.init).filter { $0.count > 2 && !generic.contains($0) })
        }
        guard let espn else { return false }
        return !words(espn).isDisjoint(with: words(other))
    }

    enum Result: Equatable {
        case matched(row: TMLMatchRow, winnerIsHome: Bool)
        case none
        case ambiguous
    }

    /// Both players, the oriented set scores, a finished (not walkover) result and the round (when
    /// ESPN's wording maps to one) must all agree. Zero or several survivors never yield a row.
    static func match(game: KyroSportsGame, rows: [TMLMatchRow]) -> Result {
        let espnSets = game.periods.filter(\.hasScore).compactMap { p -> (home: Int, away: Int)? in
            guard let h = p.homeScore, let a = p.awayScore else { return nil }
            return (h, a)
        }
        guard !espnSets.isEmpty else { return .none }
        let espnRound = roundCode(game.round)
        var hits: [(TMLMatchRow, Bool)] = []
        for row in rows {
            let homeWon: Bool
            if samePlayer(row.winner, game.home.team), samePlayer(row.loser, game.away.team) { homeWon = true }
            else if samePlayer(row.winner, game.away.team), samePlayer(row.loser, game.home.team) { homeWon = false }
            else { continue }
            if let espnRound, espnRound != row.round { continue }
            let sets = sets(from: row.score)
            // A retirement can leave the interrupted set only on ESPN's side: one extra trailing set
            // is allowed then, never otherwise.
            let retired = row.score.uppercased().contains("RET") || row.score.uppercased().contains("DEF")
            guard !sets.isEmpty, sets.count == espnSets.count || (retired && espnSets.count == sets.count + 1) else { continue }
            let agrees = zip(sets, espnSets).allSatisfy { file, espn in
                homeWon ? (file.winner == espn.home && file.loser == espn.away)
                        : (file.winner == espn.away && file.loser == espn.home)
            }
            if agrees { hits.append((row, homeWon)) }
        }
        if hits.count > 1 {
            let narrowed = hits.filter { tournamentsOverlap(game.tournament, $0.0.tournament) }
            if narrowed.count >= 1 { hits = narrowed }
        }
        switch hits.count {
        case 0: return .none
        case 1: return .matched(row: hits[0].0, winnerIsHome: hits[0].1)
        default: return .ambiguous
        }
    }
}

enum TMLStatisticMapping {
    typealias Row = KyroSportsSupplementalStatistics.Row

    private static func pct(_ part: Int?, _ total: Int?) -> String? {
        guard let part, let total, total > 0, part >= 0, part <= total else { return nil }
        return "\(Int((Double(part) / Double(total) * 100).rounded()))%"
    }

    private static func ratio(_ part: Int?, _ total: Int?) -> String? {
        guard let part, let total, total >= 0, part >= 0, part <= total else { return nil }
        return "\(part)/\(total)"
    }

    private static func sub(_ a: Int?, _ b: Int?) -> Int? {
        guard let a, let b, a >= b else { return nil }
        return a - b
    }

    private static func plus(_ a: Int?, _ b: Int?) -> Int? {
        guard let a, let b else { return nil }
        return a + b
    }

    private static func count(_ v: Int?) -> String? { v.flatMap { $0 >= 0 ? String($0) : nil } }

    /// Statistics are recorded per winner/loser; `rows` turns them into home/away columns.
    /// Derived figures use only recorded counts (return points = opponent service points - the
    /// points the opponent won on serve; breaks converted = opponent's break points faced - saved).
    static func rows(_ row: TMLMatchRow, winnerIsHome: Bool) -> [Row] {
        let home = winnerIsHome ? row.w : row.l
        let away = winnerIsHome ? row.l : row.w

        func line(_ group: String, _ label: String, _ f: (TMLMatchRow.Side, TMLMatchRow.Side) -> String?) -> Row? {
            guard let h = f(home, away), let a = f(away, home) else { return nil }
            return Row(label: label, home: h, away: a, group: group)
        }
        func serveWon(_ s: TMLMatchRow.Side) -> Int? { plus(s.firstWon, s.secondWon) }
        func returnWon(_ own: TMLMatchRow.Side, _ opp: TMLMatchRow.Side) -> Int? { sub(opp.svpt, serveWon(opp)) }

        return [
            line("Serve", "Aces") { s, _ in count(s.ace) },
            line("Serve", "Double faults") { s, _ in count(s.df) },
            line("Serve", "1st serve in") { s, _ in pct(s.firstIn, s.svpt) },
            line("Serve", "1st serve points won") { s, _ in pct(s.firstWon, s.firstIn) },
            line("Serve", "2nd serve points won") { s, _ in
                pct(s.secondWon, sub(s.svpt, s.firstIn))
            },
            line("Serve", "Service points won") { s, _ in pct(serveWon(s), s.svpt) },
            line("Return", "Return points won") { s, opp in pct(returnWon(s, opp), opp.svpt) },
            line("Break points", "Break points converted") { s, opp in ratio(sub(opp.bpFaced, opp.bpSaved), opp.bpFaced) },
            line("Break points", "Break points saved") { s, _ in ratio(s.bpSaved, s.bpFaced) },
            line("Overall", "Total points won") { s, opp in count(plus(serveWon(s), returnWon(s, opp))) },
        ].compactMap { $0 }
    }

    static func duration(minutes: Int?) -> String? {
        guard let minutes, minutes >= 15, minutes < 1_000 else { return nil }
        return minutes >= 60 ? "Match time \(minutes / 60)h \(String(format: "%02d", minutes % 60))m" : "Match time \(minutes)m"
    }
}

struct TMLMatchStatsClient: KyroSportsSupplementProviding {
    var flagKey: String { KyroSportsSupplementFlag.tmlStatsKey }
    func isEligible(_ game: KyroSportsGame) -> Bool { TMLMatchMatcher.isEligible(game) }

    private let baseURL: URL
    private let transport: any ESPNTransport
    private let cache: ESPNEventDetailResponseCache
    private let now: @Sendable () -> Date

    init(
        baseURL: URL = URL(string: "https://stats.tennismylife.org/data")!,
        transport: any ESPNTransport = URLSessionESPNTransport(),
        gate: TheSportsDBRequestGate = TheSportsDBRequestGate(spacing: 1.0, limit: 12),
        cache: ESPNEventDetailResponseCache = ESPNEventDetailResponseCache(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseURL = baseURL
        self.transport = TheSportsDBGatedTransport(inner: transport, gate: gate)
        self.cache = cache
        self.now = now
    }

    /// At most two cached requests: the small "ongoing tournaments" file, then the season file only
    /// if the match is not in it. Parsing keeps only rows near the match date, off the caller's actor.
    func supplementalStatistics(for game: KyroSportsGame, existingLabels: [String]) async -> KyroSportsSupplementOutcome {
        guard TMLMatchMatcher.isEligible(game), let start = game.startTime else { return .notEligible }
        let isWTA = game.league == .wta
        let window = TMLMatchMatcher.window(for: start)
        let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: start).year ?? 0
        let files: [(name: String, freshness: TimeInterval)] = [
            (isWTA ? "wta_ongoing_tourneys.csv" : "ongoing_tourneys.csv", 15 * 60),
            (isWTA ? "\(year)_wta.csv" : "\(year).csv", 6 * 3600),
        ]
        var sawFile = false
        var ambiguous = false
        for file in files {
            do {
                let data = try await fetch(file.name, freshness: file.freshness)
                sawFile = true
                try Task.checkCancellation()
                let rows = await Task.detached(priority: .utility) { TMLCSV.rows(from: data, window: window) }.value
                switch TMLMatchMatcher.match(game: game, rows: rows) {
                case .matched(let row, let winnerIsHome):
                    let stats = TMLStatisticMapping.rows(row, winnerIsHome: winnerIsHome)
                    guard !stats.isEmpty else { return .noAdditionalStatistics }
                    let facts = [TMLStatisticMapping.duration(minutes: row.minutes),
                                 row.surface.isEmpty ? nil : "Surface: \(row.surface)"].compactMap { $0 }
                    return .available(.init(
                        gameID: game.id, providerName: "TennisMyLife", providerEventID: "\(row.tournament)|\(row.round)",
                        note: "Recorded for this match by TennisMyLife (stats.tennismylife.org). Return points and break points converted are derived from the opponent's recorded service counts.",
                        rows: stats, facts: facts))
                case .ambiguous: ambiguous = true
                case .none: continue
                }
            } catch is CancellationError {
                return .cancelled
            } catch let error as KyroSportsEventDetailError where error == .cancelled {
                return .cancelled
            } catch {
                continue
            }
        }
        if ambiguous { return .ambiguousMatch }
        return sawFile ? .noVerifiedMatch : .providerUnavailable
    }

    private func fetch(_ name: String, freshness: TimeInterval) async throws -> Data {
        guard let url = URL(string: baseURL.absoluteString + "/" + name) else { throw KyroSportsEventDetailError.malformedResponse }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("text/csv", forHTTPHeaderField: "Accept")
        return try await cache.data(for: request, key: "tml|\(name)", fallbackFreshness: freshness, transport: transport,
                                    ignoresServerFreshness: true)
    }
}
