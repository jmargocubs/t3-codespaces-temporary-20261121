import Foundation

/// NFL fallback provider. It uses Sleeper's weekly score feed for both results
/// and schedules because that feed includes verified kickoff instants. The
/// date-only season schedule is never rendered as a kickoff.
struct SleeperSportsProvider: KyroSportsProviding {
    let providerID = SleeperMapping.providerName

    private let client: SleeperAPIClient
    private let calendar: Calendar
    private let seasonOverride: Int?

    init(
        client: SleeperAPIClient = SleeperAPIClient(),
        seasonOverride: Int? = nil,
        calendar: Calendar = .current
    ) {
        self.client = client
        self.seasonOverride = seasonOverride
        self.calendar = calendar
    }

    func fetchNFLWindow(now: Date, force: Bool) async throws -> KyroSportsProviderOutput {
        let league = KyroSportLeague.nfl
        let stateResult = try await client.fetchState(league: league)
        let state = stateResult.state
        let season = seasonOverride
            ?? state.season.flatMap(Int.init)
            ?? Self.seasonYear(for: now, calendar: calendar)
        let stateType = Self.seasonType(from: state.seasonType)
        guard stateType == .regular || (stateType == .unknown && seasonOverride != nil) else {
            throw KyroSportsDataError.unsupportedSeasonPhase(stateType)
        }
        let week = Self.requestWeek(
            state: state,
            seasonType: stateType,
            season: season,
            now: now,
            calendar: calendar
        )

        let teams = (try? await client.fetchTeams(league: league)) ?? []
        let teamsByAbbreviation = SleeperMapping.teams(from: teams, league: league)
        let weeks = Self.windowWeeks(around: week)

        var games: [KyroSportsGame] = []
        var currentWeekError: KyroSportsDataError?
        var refreshError = stateResult.refreshError
        var anyResponse = false

        for requestedWeek in weeks {
            do {
                let result = try await client.fetchScores(
                    league: league,
                    season: String(season),
                    week: requestedWeek,
                    liveWindow: requestedWeek == week,
                    ignoreFreshness: force && requestedWeek == week
                )
                anyResponse = true
                if requestedWeek == week, let error = result.refreshError {
                    currentWeekError = error
                }
                if let error = result.refreshError, refreshError == nil {
                    refreshError = error
                }
                games.append(contentsOf: result.games.compactMap {
                    SleeperMapping.game(
                        fromScore: $0,
                        league: league,
                        season: season,
                        seasonType: .regular,
                        teamsByAbbreviation: teamsByAbbreviation
                    )
                })
            } catch let error as KyroSportsDataError {
                if error == .cancelled { throw error }
                if requestedWeek == week { currentWeekError = error }
                if refreshError == nil { refreshError = error }
            }
        }

        guard anyResponse else { throw currentWeekError ?? .offline }
        if games.isEmpty, let currentWeekError {
            throw currentWeekError
        }
        return KyroSportsProviderOutput(
            provider: providerID,
            games: KyroSportsReconciler.deduplicated(games),
            season: season,
            week: week,
            refreshError: refreshError ?? currentWeekError
        )
    }

    /// NFL season years follow the year in which the season begins, not the
    /// calendar year containing January's Week 18 and playoffs.
    static func seasonYear(for date: Date, calendar: Calendar) -> Int {
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        return month >= 8 ? year : year - 1
    }

    static func seasonType(from rawValue: String?) -> KyroSportsSeasonType {
        switch rawValue?.lowercased() {
        case "pre", "preseason": .preseason
        case "regular", "reg": .regular
        case "post", "postseason": .postseason
        case nil: .unknown
        default: .unknown
        }
    }

    static func windowWeeks(around week: Int) -> [Int] {
        Array(max(1, week - 1)...min(18, week + 2))
    }

    private static func requestWeek(
        state: SleeperSportState?,
        seasonType: KyroSportsSeasonType,
        season: Int,
        now: Date,
        calendar: Calendar
    ) -> Int {
        if seasonType == .regular, let week = state?.week, (1...18).contains(week) {
            return week
        }
        if seasonType == .postseason { return 18 }
        if seasonType == .preseason { return 1 }

        // Emergency-only fallback when state is absent. The cached/live state
        // endpoint remains authoritative whenever it answers.
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = season
        components.month = 9
        components.day = 9
        let start = calendar.date(from: components) ?? now
        let days = max(0, calendar.dateComponents([.day], from: start, to: now).day ?? 0)
        return max(1, min(18, days / 7 + 1))
    }
}
