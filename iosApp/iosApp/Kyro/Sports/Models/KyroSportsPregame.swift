import Foundation

// Build 68: pregame context for a selected event. Everything here comes from the event's own ESPN
// summary (`site.api.espn.com/.../summary?event=`), checked 2026-11-13 for NBA, NHL, NFL, college
// football and the Premier League. Before the start, that response carries the teams' records,
// standings, last five games, season series, season leaders, injuries and, under `boxscore.teams`,
// SEASON averages. Build 67 drew those averages as the event's box score; they are now labelled as
// season statistics and never mixed with statistics from the game itself.

/// Which kind of statistics an event summary carries, read from the summary's own status rather
/// than the scoreboard's, so a summary cached a moment before the start is never shown as live.
enum KyroSportsStatisticsPhase: String, Equatable, Sendable {
    /// Not started: team statistics are season figures.
    case pregame
    /// In progress: statistics from this game.
    case live
    /// Completed: statistics from this game.
    case final
    /// Postponed, canceled or otherwise ended without completing: no statistics are shown.
    case interrupted
    /// The response did not say (older fixtures, other providers). Statistics keep their Build 67
    /// meaning: the selected event's box score.
    case unknown

    init(espnState: String?, completed: Bool?) {
        switch espnState?.lowercased() {
        case "pre": self = .pregame
        case "in": self = .live
        case "post": self = completed == false ? .interrupted : .final
        default: self = .unknown
        }
    }

    /// Team and player statistics in the response describe the selected game itself.
    var carriesEventStatistics: Bool {
        switch self {
        case .live, .final, .unknown: true
        case .pregame, .interrupted: false
        }
    }
}

struct KyroSportsPregameContext: Equatable, Sendable {
    struct Record: Equatable, Sendable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    /// One of a team's recent games, from that team's point of view.
    struct RecentGame: Equatable, Sendable, Identifiable {
        enum Outcome: String, Equatable, Sendable {
            case win = "W", loss = "L", draw = "D"
        }

        let id: String
        let date: Date?
        let outcome: Outcome?
        let teamScore: String?
        let opponentScore: String?
        let opponent: String
        let isHome: Bool
        /// Set only when the game was in another competition (a cup tie for a league side).
        let competition: String?

        /// `108–104`, team first; `2–2 (pens)` for a level score with a result.
        var scoreLine: String? {
            guard let teamScore, let opponentScore else { return nil }
            let level = teamScore == opponentScore && (outcome == .win || outcome == .loss)
            return "\(teamScore)–\(opponentScore)\(level ? " (pens)" : "")"
        }
    }

    struct Leader: Equatable, Sendable, Identifiable {
        /// The category key, shared by both teams (`pointsPerGame`).
        let id: String
        let category: String
        let athlete: String
        let value: String
    }

    struct Injury: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let position: String?
        let status: String
        let detail: String?
    }

    struct Team: Equatable, Sendable {
        let providerTeamID: String
        let abbreviation: String
        let records: [Record]
        /// Newest first.
        let recent: [RecentGame]
        let leaders: [Leader]
        let injuries: [Injury]
        /// Season figures from ESPN, in its order. Never statistics from the selected event.
        let seasonStatistics: [KyroSportsStatistic]
    }

    struct StandingsGroup: Equatable, Sendable, Identifiable {
        struct Row: Equatable, Sendable, Identifiable {
            let id: String
            let position: Int
            let team: String
            let isSelected: Bool
            let values: [String]
        }

        let id: String
        let title: String
        let columns: [String]
        /// Every row of a small group; only the selected teams' rows of a large one.
        let rows: [Row]
        let totalTeams: Int

        var isAbridged: Bool { rows.count < totalTeams }
    }

    struct Meeting: Equatable, Sendable, Identifiable {
        let id: String
        let date: Date?
        let away: String
        let home: String
        let awayScore: String?
        let homeScore: String?
        let winner: String?
    }

    struct Series: Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        let summary: String?
        /// Completed meetings, newest first. The selected event is never one of them.
        let meetings: [Meeting]
        /// Scheduled meetings other than the selected event.
        let upcoming: Int
    }

    let away: Team?
    let home: Team?
    let standings: [StandingsGroup]
    let series: [Series]
    let venue: String?

    var hasGameContent: Bool {
        let teams = [away, home].compactMap { $0 }
        return teams.contains { !$0.records.isEmpty || !$0.recent.isEmpty || !$0.injuries.isEmpty }
            || !standings.isEmpty || !series.isEmpty
    }

    var hasStatsContent: Bool {
        [away, home].compactMap { $0 }.contains { !$0.seasonStatistics.isEmpty || !$0.leaders.isEmpty }
    }

    var isEmpty: Bool { !hasGameContent && !hasStatsContent }
}

/// Pure rules for the pregame mapping, kept apart from the wire types so they can be tested.
enum KyroSportsPregameRules {
    /// Season lines ESPN mixes into its averages that are records, not quantities to compare.
    static let recordLikeStatistics: [String: String] = ["streak": "Streak", "last ten games": "Last 10"]

    /// `total` → `Overall (W-D-L)` for soccer, so a three-part record is never misread.
    static func recordLabel(type: String, league: KyroSportLeague) -> String? {
        switch type.lowercased() {
        case "total":
            switch league {
            case .soccer: return "Overall (W-D-L)"
            case .nhl: return "Overall (W-L-OT)"
            default: return "Overall"
            }
        case "home": return "Home"
        case "road", "away": return "Road"
        case "vsconf": return "Conference"
        case "vsdiv": return "Division"
        case "points": return league == .soccer ? "Points" : nil
        default: return nil
        }
    }

    /// The standings columns worth a narrow table, by ESPN statistic name, in reading order.
    static func standingsColumns(for league: KyroSportLeague) -> [(name: String, header: String)] {
        switch league {
        case .nba, .mlb: [("wins", "W"), ("losses", "L"), ("winPercent", "PCT"), ("gamesBehind", "GB")]
        case .nhl: [("wins", "W"), ("losses", "L"), ("otLosses", "OTL"), ("points", "PTS")]
        case .nfl: [("wins", "W"), ("losses", "L"), ("ties", "T"), ("winPercent", "PCT")]
        case .collegeFootball: [("vs. Conf.", "CONF"), ("overall", "OVR")]
        case .collegeBasketballMen, .collegeBasketballWomen: [("vs. Conf.", "CONF"), ("overall", "OVR")]
        case .soccer: [("gamesPlayed", "GP"), ("wins", "W"), ("ties", "D"), ("losses", "L"),
                       ("pointDifferential", "GD"), ("points", "PTS")]
        case .atp, .wta: []
        }
    }

    /// Groups with more teams than this show only the selected teams' rows.
    static let fullStandingsLimit = 8
    static let maxInjuriesPerTeam = 6
    static let maxMeetings = 5
}

/// Build 68: one story per article, whichever feed it came from. Two feeds can list the same story
/// under different IDs, with tracking parameters or an `http` link.
enum KyroSportsNewsDedup {
    static func key(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString.lowercased()
        }
        components.query = nil
        components.fragment = nil
        var host = (components.host ?? "").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return host + path.lowercased()
    }
}

/// Build 68: the scheduled start in the viewer's own time zone, as Event Details states it.
enum KyroSportsStartTimeText {
    /// `Today · 7:00 PM`, `Tomorrow · 1:00 PM`, `Sat, Nov 21 · 3:00 PM`, or `… · Time TBD`.
    static func line(start: Date, isTimeTBD: Bool, now: Date, calendar: Calendar = .current,
                     locale: Locale = .current) -> String {
        var calendar = calendar
        calendar.locale = locale
        let day: String
        if calendar.isDate(start, inSameDayAs: now) {
            day = "Today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
                  calendar.isDate(start, inSameDayAs: tomorrow) {
            day = "Tomorrow"
        } else {
            var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar,
                                         timeZone: calendar.timeZone)
                .weekday(.abbreviated).month(.abbreviated).day()
            if !calendar.isDate(start, equalTo: now, toGranularity: .year) { style = style.year() }
            day = start.formatted(style)
        }
        guard !isTimeTBD else { return "\(day) · Time TBD" }
        let time = start.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                                    calendar: calendar, timeZone: calendar.timeZone))
        return "\(day) · \(time)"
    }

    /// `Starts in 2 hr 15 min` within the next day; nil otherwise, after the start, or when the
    /// time is not set.
    static func countdown(start: Date, isTimeTBD: Bool, now: Date) -> String? {
        let seconds = start.timeIntervalSince(now)
        guard !isTimeTBD, seconds > 0, seconds < 24 * 3600 else { return nil }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "Starts in \(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "Starts in \(hours) hr" : "Starts in \(hours) hr \(rest) min"
    }
}

/// Build 68: theScore's `ground_type` as a viewer reads it. Unknown values are not guessed.
enum KyroTennisSurface {
    static func label(groundType: String?) -> String? {
        guard let raw = groundType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return nil
        }
        switch raw {
        case "hardcourt_outdoor": return "Hard court, outdoor"
        case "hardcourt_indoor": return "Hard court, indoor"
        case "red_clay", "clay": return "Clay"
        case "green_clay": return "Green clay"
        case "grass": return "Grass"
        case "carpet", "carpet_indoor": return "Carpet, indoor"
        default: return nil
        }
    }
}
