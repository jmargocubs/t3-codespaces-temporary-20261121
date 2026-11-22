import Foundation

// Provider-independent sports models for Kyro's Sports Hub. Nothing here names
// a data source: the ESPN and Sleeper adapters map into these types without
// touching the views. Phase S2A activates NFL only; ESPN decoding also covers
// the four placeholder leagues for their later UI phases.

// MARK: - Leagues

/// A league the Sports Hub can display, in the order the hub lists them.
enum KyroSportLeague: String, CaseIterable, Identifiable, Codable, Sendable {
    case nfl
    case nba
    case collegeFootball
    case collegeBasketballMen
    case collegeBasketballWomen
    case mlb
    case nhl
    case atp
    case wta
    /// ESPN soccer is a family of competitions. The concrete competition is
    /// carried by `KyroSportsGame.competitionKey` and the registry, so adding
    /// a league never requires another provider-wide enum case.
    case soccer

    var id: String { rawValue }

    /// The short name used in filters, headers and accessibility labels.
    var displayName: String {
        switch self {
        case .nfl: "NFL"
        case .nba: "NBA"
        case .collegeFootball: "NCAA Football"
        case .collegeBasketballMen: "NCAA Men’s Basketball"
        case .collegeBasketballWomen: "NCAA Women’s Basketball"
        case .mlb: "MLB"
        case .nhl: "NHL"
        case .atp: "ATP"
        case .wta: "WTA"
        case .soccer: "Soccer"
        }
    }

    /// The compact badge shown on a filter chip.
    var shortName: String {
        switch self {
        case .nfl: "NFL"
        case .nba: "NBA"
        case .collegeFootball: "NCAA"
        case .collegeBasketballMen: "NCAAM"
        case .collegeBasketballWomen: "NCAAW"
        case .mlb: "MLB"
        case .nhl: "NHL"
        case .atp: "ATP"
        case .wta: "WTA"
        case .soccer: "SOC"
        }
    }

    var symbolName: String {
        switch self {
        case .nfl, .collegeFootball: "football.fill"
        case .nba, .collegeBasketballMen, .collegeBasketballWomen: "basketball.fill"
        case .mlb: "baseball.fill"
        case .nhl: "hockey.puck.fill"
        case .atp, .wta: "tennisball.fill"
        case .soccer: "soccerball"
        }
    }

    /// Restrained section/preview accents. Kept as values so identity is testable without UI.
    var accentRGB: UInt32 {
        switch self {
        case .nfl: 0x428DFF
        case .collegeFootball: 0xA783E8
        case .collegeBasketballMen: 0xF4A55A
        case .collegeBasketballWomen: 0xED8EB6
        case .nba: 0xF4A55A
        case .nhl: 0x53BFB9
        case .mlb: 0xE87575
        case .atp: 0xB2D96C
        case .wta: 0xED8EB6
        case .soccer: 0x64C98A
        }
    }

    var seasonPhaseDescription: String {
        switch self {
        case .nfl: "Regular season"
        case .nba: "Regular season"
        case .collegeFootball: "Regular season"
        case .collegeBasketballMen, .collegeBasketballWomen: "Regular season & postseason"
        case .mlb: "Regular season"
        case .nhl: "Regular season"
        case .atp, .wta: "Tour"
        case .soccer: "Competition"
        }
    }

    /// Every league in the filter is wired to a provider path as of Phase S5.
    /// Kept as a property so a future league can ship dark behind the filter.
    var isAvailable: Bool { true }
}

// MARK: - Identifiers

/// A game identifier that stays stable across fetches and across providers.
///
/// The raw value is namespaced by provider and league so two sources can never
/// collide: `sleeper.nfl.202610902`. Views key rows and scroll positions by
/// this, so a decoder change that keeps the provider id keeps identity.
struct KyroGameID: Hashable, Codable, Sendable, CustomStringConvertible {
    let provider: String
    let league: KyroSportLeague
    let rawID: String

    init(provider: String, league: KyroSportLeague, rawID: String) {
        self.provider = provider
        self.league = league
        self.rawID = rawID
    }

    var description: String { "\(provider).\(league.rawValue).\(rawID)" }

    var stringValue: String { description }
}

/// The part of an NFL season a provider says a game belongs to. Kyro requests
/// regular-season games today, but keeps the phase explicit so preseason and
/// postseason rows can never leak into that request by accident.
enum KyroSportsSeasonType: String, Codable, Equatable, Sendable {
    case preseason
    case regular
    case postseason
    case unknown
}

/// One provider record that contributed to a normalized game. Provider IDs
/// are diagnostics, not cross-provider identity: ESPN and Sleeper use unrelated
/// identifiers for the same event.
struct KyroGameProvenance: Hashable, Codable, Sendable {
    let provider: String
    let rawID: String
}

// MARK: - Status

/// Where a game sits in its lifecycle. Deliberately small: anything a provider
/// reports that Kyro does not model becomes `.unknown` rather than a decode
/// failure, so a new status string degrades one row instead of the page.
enum KyroGameStatus: Equatable, Sendable {
    case scheduled
    case live
    case final
    case postponed
    case canceled
    case suspended
    case unknown(String)

    var isLive: Bool { self == .live }
    var isFinal: Bool { self == .final }
    var isScheduled: Bool { self == .scheduled }
    var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    /// Whether the game should keep its row visible at the top of the hub.
    var isActive: Bool { self == .live }

    /// A short, human label for the status pill.
    var label: String {
        switch self {
        case .scheduled: "Scheduled"
        case .live: "Live"
        case .final: "Final"
        case .postponed: "Postponed"
        case .canceled: "Canceled"
        case .suspended: "Suspended"
        case .unknown: "Update pending"
        }
    }

}

// MARK: - Periods

/// One scoring period of a game, in the league's own shape: quarters for
/// football and basketball, periods for hockey, innings for baseball.
struct KyroGamePeriod: Identifiable, Equatable, Sendable {
    /// Stable per game, e.g. `q1`, `ot`, `p3`, `inning7`.
    let id: String
    /// The badge text, e.g. `Q1`, `OT`, `P3`, `7`.
    let label: String
    let homeScore: Int?
    let awayScore: Int?

    init(id: String, label: String, homeScore: Int?, awayScore: Int?) {
        self.id = id
        self.label = label
        self.homeScore = homeScore
        self.awayScore = awayScore
    }

    /// True when neither side reported a score for this period. Providers pad
    /// future periods with nulls and zeros; the hub hides empty ones.
    var hasScore: Bool { homeScore != nil || awayScore != nil }
}

// MARK: - Teams

/// A team as the hub needs it, independent of any provider's wire shape.
struct KyroSportsTeam: Identifiable, Equatable, Sendable {
    /// Provider-scoped identity, e.g. `sleeper.nfl.SF`.
    let id: String
    let league: KyroSportLeague
    let abbreviation: String
    let nickname: String
    let location: String?
    let logoURL: URL?
    /// The provider's logo variant for dark backgrounds, when it has one.
    let darkLogoURL: URL?
    let primaryColorHex: String?
    let alternateColorHex: String?
    let conference: String?
    let division: String?
    /// Country code when the provider supplies one: ISO alpha-2 (`ES`) from
    /// older payloads, or ESPN's three-letter flag code (`ESP`) from live tennis.
    let countryCode: String?
    /// The provider's flag image for `countryCode` (ESPN tennis). Never derived from the code.
    let flagURL: URL?
    /// Other names the provider uses for the team, e.g. ESPN's
    /// `shortDisplayName` "Jax State". Stream matching uses them as aliases.
    let alternateNames: [String]

    init(
        id: String,
        league: KyroSportLeague,
        abbreviation: String,
        nickname: String,
        location: String? = nil,
        logoURL: URL? = nil,
        darkLogoURL: URL? = nil,
        primaryColorHex: String? = nil,
        alternateColorHex: String? = nil,
        conference: String? = nil,
        division: String? = nil,
        countryCode: String? = nil,
        flagURL: URL? = nil,
        alternateNames: [String] = []
    ) {
        self.id = id
        self.league = league
        self.abbreviation = abbreviation
        self.nickname = nickname
        self.location = location
        self.logoURL = logoURL
        self.darkLogoURL = darkLogoURL
        self.primaryColorHex = primaryColorHex
        self.alternateColorHex = alternateColorHex
        self.conference = conference
        self.division = division
        self.countryCode = countryCode
        self.flagURL = flagURL
        self.alternateNames = alternateNames
    }

    /// The name to draw when the full name would wrap: "49ers", not
    /// "San Francisco 49ers".
    var shortName: String { nickname }

    var fullName: String {
        guard let location, !location.isEmpty else { return nickname }
        return "\(location) \(nickname)"
    }

    /// A team built from nothing but an abbreviation. Used when the team
    /// catalog is unavailable but a score payload still names both sides, so a
    /// row keeps its identity instead of disappearing.
    static func placeholder(abbreviation: String, league: KyroSportLeague) -> KyroSportsTeam {
        KyroSportsTeam(
            id: "\(league.providerPlaceholderPrefix).\(abbreviation)",
            league: league,
            abbreviation: abbreviation,
            nickname: abbreviation,
            logoURL: nil
        )
    }
}

private extension KyroSportLeague {
    /// Placeholder ids are namespaced like provider ids so they can never be
    /// mistaken for a real catalog entry.
    var providerPlaceholderPrefix: String { "placeholder.\(rawValue)" }
}

// MARK: - Game participation

/// One side of a game: the team, its score and its record.
struct KyroGameTeam: Equatable, Sendable {
    let team: KyroSportsTeam
    let score: Int?
    /// Season record at the time of the game, e.g. `6-2-0` or `6-2`.
    let record: String?
    /// Provider-reported poll rank at game time. Nil means unranked or that
    /// the league does not publish rankings in its scoreboard payload.
    let rank: Int?
    /// Provider-declared winner. Tennis needs it: a retirement or walkover
    /// is decided without a final set count.
    let isWinner: Bool?

    init(team: KyroSportsTeam, score: Int? = nil, record: String? = nil, rank: Int? = nil, isWinner: Bool? = nil) {
        self.team = team
        self.score = score
        self.record = record
        self.rank = rank
        self.isWinner = isWinner
    }

    /// The team name with its poll rank, e.g. `#5 Georgia Bulldogs`.
    var rankedName: String {
        guard let rank, rank > 0 else { return team.fullName }
        return "#\(rank) \(team.fullName)"
    }

    /// The record with a trailing `-0` tie column removed, matching how NFL
    /// and NBA sites display `6-2` rather than `6-2-0`.
    var displayRecord: String? {
        guard let record else { return nil }
        let trimmed = record.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "-")
        if parts.count == 3, parts[2] == "0" {
            return parts.prefix(2).joined(separator: "-")
        }
        return trimmed
    }
}

// MARK: - Game

/// One game, provider-independent.
struct KyroSportsGame: Identifiable, Equatable, Sendable {
    let id: KyroGameID
    let league: KyroSportLeague
    let season: Int?
    let seasonType: KyroSportsSeasonType
    let week: Int?
    let startTime: Date?
    let status: KyroGameStatus
    /// The provider's own short status line, e.g. `Q3 4:32`, `Final`, `2nd`.
    /// Nil when the provider gave nothing more specific than the status.
    let statusDetail: String?
    let home: KyroGameTeam
    let away: KyroGameTeam
    let periods: [KyroGamePeriod]
    let venue: String?
    let broadcast: String?
    /// Event headline such as a bowl or conference championship name.
    let note: String?
    /// Short live-state text the status line cannot carry, e.g. `2 outs`.
    let situation: String?
    let provenance: [KyroGameProvenance]
    /// Tennis-only tournament context. Team sports leave these nil.
    let tournament: String?
    let round: String?
    let isSingles: Bool
    /// True when the provider gave only the scheduled day. `startTime` then
    /// anchors the day (noon UTC) and must not be shown as a clock time.
    let isStartTimeTBD: Bool
    /// ESPN competition slug (for example `eng.1`) for soccer. It is nil for
    /// the existing single-league feeds.
    let competitionKey: String?

    init(
        id: KyroGameID,
        league: KyroSportLeague,
        season: Int? = nil,
        seasonType: KyroSportsSeasonType = .unknown,
        week: Int? = nil,
        startTime: Date?,
        status: KyroGameStatus,
        statusDetail: String? = nil,
        home: KyroGameTeam,
        away: KyroGameTeam,
        periods: [KyroGamePeriod] = [],
        venue: String? = nil,
        broadcast: String? = nil,
        note: String? = nil,
        situation: String? = nil,
        provenance: [KyroGameProvenance]? = nil,
        tournament: String? = nil,
        round: String? = nil,
        isSingles: Bool = false,
        isStartTimeTBD: Bool = false,
        competitionKey: String? = nil
    ) {
        self.id = id
        self.league = league
        self.season = season
        self.seasonType = seasonType
        self.week = week
        self.startTime = startTime
        self.status = status
        self.statusDetail = statusDetail
        self.home = home
        self.away = away
        self.periods = periods
        self.venue = venue
        self.broadcast = broadcast
        self.note = note
        self.situation = situation
        self.provenance = provenance ?? [KyroGameProvenance(provider: id.provider, rawID: id.rawID)]
        self.tournament = tournament
        self.round = round
        self.isSingles = isSingles
        self.isStartTimeTBD = isStartTimeTBD
        self.competitionKey = competitionKey
    }

    /// The most specific line to show under the matchup: the provider's clock
    /// or period, else the status label.
    var statusLine: String {
        if let statusDetail, !statusDetail.isEmpty { return statusDetail }
        return status.label
    }

    /// True when both sides reported a score worth drawing.
    var hasScore: Bool { home.score != nil || away.score != nil }

    /// The winning side for a final game, if there is one.
    var winner: KyroGameTeam? {
        guard status.isFinal else { return nil }
        if home.isWinner == true, away.isWinner != true { return home }
        if away.isWinner == true, home.isWinner != true { return away }
        guard let homeScore = home.score, let awayScore = away.score,
              homeScore != awayScore else { return nil }
        return homeScore > awayScore ? home : away
    }

    var weekLabel: String? {
        guard league == .nfl, let week else { return nil }
        return "NFL Week \(week)"
    }
}

// MARK: - Sections

/// How the hub groups a day's games.
enum KyroSportsGameBucket: String, CaseIterable, Identifiable, Sendable {
    case liveNow
    case today
    /// Finished games from earlier days, so they never read as upcoming.
    case recent
    case upcoming
    /// Known scheduled games outside the visible dashboard window. Kept in the
    /// section model so later weeks remain available without listing them.
    case future

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liveNow: "Live Now"
        case .today: "Today"
        case .recent: "Recent Results"
        case .upcoming: "Upcoming Games"
        case .future: "Later Games"
        }
    }

    var symbolName: String {
        switch self {
        case .liveNow: "dot.radiowaves.left.and.right"
        case .today: "sportscourt.fill"
        case .recent: "checkmark.circle"
        case .upcoming: "calendar"
        case .future: "calendar.badge.plus"
        }
    }

    var isDateGrouped: Bool { self == .upcoming || self == .future }
}

// MARK: - Dashboard presentation

/// The three compact views of the same provider-independent game window.
/// Keeping this separate from the NFL provider lets later leagues reuse the
/// dashboard without inheriting ESPN or Sleeper details.
enum KyroSportsDashboardMode: String, CaseIterable, Identifiable, Sendable {
    case live
    case upcoming
    case results

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: "Live"
        case .upcoming: "Upcoming"
        case .results: "Results"
        }
    }

    var symbolName: String {
        switch self {
        case .live: "dot.radiowaves.left.and.right"
        case .upcoming: "calendar"
        case .results: "checkmark.circle"
        }
    }
}

/// Copy for the compact state shown when a selected dashboard mode has no
/// rows. The view and tests share this decision instead of duplicating it.
struct KyroSportsDashboardEmptyState: Equatable, Sendable {
    let symbolName: String
    let title: String
    let message: String
}

/// Provider-independent dashboard policy. It only rearranges already
/// normalized games; networking, reconciliation and date grouping stay in
/// their existing layers.
enum KyroSportsDashboard {
    static func featuredEvent(
        from sections: [KyroSportsGameSection],
        now: Date
    ) -> KyroSportsGame? {
        // Live first, then the next kickoff inside the visible schedule only.
        // Games parked in `.future` never become the hero while a current-week
        // or rolling-window matchup exists.
        let visibleSchedule = sections.filter { $0.bucket == .liveNow || $0.bucket == .today || $0.bucket == .upcoming }
        let visibleGames = uniqueGames(in: visibleSchedule)

        if let live = visibleGames
            .filter({ $0.status.isLive })
            .sorted(by: KyroSportsReconciler.deterministicOrder)
            .first {
            return live
        }

        if let upcoming = visibleGames
            .filter({ game in
                guard let start = game.startTime, start >= now else { return false }
                return game.status.isScheduled || game.status.isUnknown
            })
            .sorted(by: KyroSportsReconciler.deterministicOrder)
            .first {
            return upcoming
        }

        return uniqueGames(in: sections)
            .filter({ $0.status.isFinal })
            .sorted(by: mostRecentFirst)
            .first
    }

    static func defaultMode(for sections: [KyroSportsGameSection]) -> KyroSportsDashboardMode {
        sections.contains(where: { $0.bucket == .liveNow && !$0.games.isEmpty }) ? .live : .upcoming
    }

    static func visibleSections(
        from sections: [KyroSportsGameSection],
        mode: KyroSportsDashboardMode
    ) -> [KyroSportsGameSection] {
        sections.filter { section in
            switch mode {
            case .live:
                section.bucket == .liveNow
            case .upcoming:
                section.bucket == .today || section.bucket == .upcoming
            case .results:
                section.bucket == .recent
            }
        }
    }

    static func emptyState(
        for mode: KyroSportsDashboardMode,
        in sections: [KyroSportsGameSection]
    ) -> KyroSportsDashboardEmptyState? {
        guard visibleSections(from: sections, mode: mode).isEmpty else {
            return nil
        }
        switch mode {
        case .live:
            return KyroSportsDashboardEmptyState(
                symbolName: "dot.radiowaves.left.and.right",
                title: "No games are live",
                message: "Live scores will appear here when a game begins."
            )
        case .upcoming:
            return KyroSportsDashboardEmptyState(
                symbolName: "calendar",
                title: "No upcoming games",
                message: "There are no scheduled games in the current window."
            )
        case .results:
            return KyroSportsDashboardEmptyState(
                symbolName: "checkmark.circle",
                title: "No recent results",
                message: "Final scores from the last seven days will appear here."
            )
        }
    }

    /// Copy for a loaded league with no games at all in its window.
    static func noGamesState(
        for league: KyroSportLeague,
        now: Date,
        calendar: Calendar = .current
    ) -> KyroSportsDashboardEmptyState {
        if league == .mlb {
            // MLB's regular season runs roughly late March to early October and
            // the postseason ends by early November.
            let month = calendar.component(.month, from: now)
            if month >= 11 || month <= 2 {
                return KyroSportsDashboardEmptyState(
                    symbolName: "baseball.fill",
                    title: "MLB is in its offseason",
                    message: "Scores and schedules return when spring training and the new season begin."
                )
            }
        }
        return KyroSportsDashboardEmptyState(
            symbolName: "calendar.badge.exclamationmark",
            title: "No games to show",
            message: "There are no \(league.displayName) games in the current window."
        )
    }

    /// True when sectioning retained later-week / beyond-window games that the
    /// dashboard intentionally does not list.
    static func hasFutureGames(in sections: [KyroSportsGameSection]) -> Bool {
        sections.contains { $0.bucket == .future && !$0.games.isEmpty }
    }

    private static func uniqueGames(in sections: [KyroSportsGameSection]) -> [KyroSportsGame] {
        var seen = Set<KyroGameID>()
        return sections.flatMap(\.games).filter { seen.insert($0.id).inserted }
    }

    private static func mostRecentFirst(_ lhs: KyroSportsGame, _ rhs: KyroSportsGame) -> Bool {
        let leftDate = lhs.startTime ?? .distantPast
        let rightDate = rhs.startTime ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }
        return KyroSportsReconciler.deterministicOrder(lhs, rhs)
    }
}

/// A titled group of games ready to render.
struct KyroSportsGameSection: Identifiable, Equatable, Sendable {
    let bucket: KyroSportsGameBucket
    /// Start of the local calendar day for a date-grouped section. Today/live
    /// and recent-result sections leave this nil; Upcoming uses one section per
    /// real local date so the UI never derives dates from provider strings.
    let localDay: Date?
    let isFirstInBucket: Bool
    let games: [KyroSportsGame]

    init(
        bucket: KyroSportsGameBucket,
        localDay: Date? = nil,
        isFirstInBucket: Bool = true,
        games: [KyroSportsGame]
    ) {
        self.bucket = bucket
        self.localDay = localDay
        self.isFirstInBucket = isFirstInBucket
        self.games = games
    }

    var id: String {
        guard let localDay else { return bucket.rawValue }
        return "\(bucket.rawValue).\(Int(localDay.timeIntervalSince1970))"
    }
}
