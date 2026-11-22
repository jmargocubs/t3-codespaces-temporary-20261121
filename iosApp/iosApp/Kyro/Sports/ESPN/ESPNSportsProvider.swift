import Foundation

/// ESPN is Kyro's primary NFL source. The same adapter decodes one-day
/// scoreboards for NBA, MLB, NHL, and FBS so those future screens do not need
/// to know ESPN's wire format. Tennis uses the same bounded/cached client but
/// its tournament hierarchy is flattened by `ESPNMapping.tennisGames`.
struct ESPNSportsProvider: KyroSportsProviding {
    let providerID = ESPNMapping.providerName

    let client: ESPNAPIClient
    let calendar: Calendar
    private let scheduleCache: ESPNNormalizedScheduleCache

    init(
        client: ESPNAPIClient = ESPNAPIClient(),
        calendar: Calendar = .current,
        scheduleCache: ESPNNormalizedScheduleCache = ESPNNormalizedScheduleCache()
    ) {
        self.client = client
        self.calendar = calendar
        self.scheduleCache = scheduleCache
    }

    func fetchNFLWindow(now: Date, force: Bool) async throws -> KyroSportsProviderOutput {
        let league = KyroSportLeague.nfl
        let startOfToday = calendar.startOfDay(for: now)
        let windowStart = calendar.date(
            byAdding: .day,
            value: -KyroSportsSectioning.recentDayCount,
            to: startOfToday
        ) ?? now.addingTimeInterval(-7 * 86_400)
        // Fetch farther than the visible NFL week so later weeks stay cached;
        // dashboard sectioning filters presentation to the current week.
        let windowEnd = calendar.date(
            byAdding: .day,
            value: KyroSportsSectioning.providerFetchUpcomingDayCount + 1,
            to: startOfToday
        ) ?? now.addingTimeInterval(15 * 86_400)

        var scheduleGames: [KyroSportsGame] = []
        var refreshError: KyroSportsDataError?
        for year in calendarYears(from: windowStart, through: windowEnd) {
            let mapped: [KyroSportsGame]
            if let cached = await scheduleCache.games(for: year, at: now) {
                mapped = cached
            } else {
                let payload = try await client.fetchScoreboard(
                    league: league,
                    dates: String(year),
                    policy: .schedule
                )
                mapped = try mapValidated(payload.response, league: league)
                await scheduleCache.store(mapped, for: year, at: now)
                if refreshError == nil { refreshError = payload.refreshError }
            }
            scheduleGames.append(contentsOf: mapped.filter { game in
                guard let start = game.startTime else { return false }
                return start >= windowStart && start < windowEnd
            })
        }

        let currentDayGames = scheduleGames.filter { game in
            game.startTime.map { calendar.isDate($0, inSameDayAs: now) } ?? false
        }

        do {
            let dayPayload = try await client.fetchScoreboard(
                league: league,
                dates: Self.espnDayString(for: now),
                policy: .liveScoreboard,
                ignoreFreshness: force
            )
            let dayGames = try mapValidated(dayPayload.response, league: league)
            if dayPayload.response.events.isEmpty, !currentDayGames.isEmpty {
                // A known game day with an unexpectedly empty live response is
                // not authoritative. Let the chain use Sleeper instead.
                throw KyroSportsDataError.malformedResponse
            }
            scheduleGames = overlay(dayGames, on: scheduleGames)
            if refreshError == nil { refreshError = dayPayload.refreshError }
        } catch let error as KyroSportsDataError {
            if error == .cancelled { throw error }
            // Without today's scoreboard, scheduled future rows are still
            // useful. A day containing an NFL game must fall back so live
            // status and scores never masquerade as current.
            if !currentDayGames.isEmpty { throw error }
            if refreshError == nil { refreshError = error }
        }

        let games = KyroSportsReconciler.deduplicated(scheduleGames)
        let closest = games.min { lhs, rhs in
            abs((lhs.startTime ?? .distantFuture).timeIntervalSince(now))
                < abs((rhs.startTime ?? .distantFuture).timeIntervalSince(now))
        }
        let season = closest?.season ?? SleeperSportsProvider.seasonYear(for: now, calendar: calendar)
        let week = closest?.week ?? 1
        return KyroSportsProviderOutput(
            provider: providerID,
            games: games,
            season: season,
            week: week,
            refreshError: refreshError
        )
    }

    /// Decodes the selected day's scoreboard for any supported league. The
    /// inactive league screens intentionally do not call this yet.
    func fetchScoreboard(
        league: KyroSportLeague,
        on date: Date,
        force: Bool = false
    ) async throws -> [KyroSportsGame] {
        let payload = try await client.fetchScoreboard(
            league: league,
            dates: Self.espnDayString(for: date),
            policy: .liveScoreboard,
            ignoreFreshness: force
        )
        return KyroSportsReconciler.deduplicated(
            try mapValidated(payload.response, league: league)
        )
    }

    func mapValidated(
        _ response: ESPNScoreboardResponse,
        league: KyroSportLeague,
        competitionKey: String? = nil,
        competitionName: String? = nil
    ) throws -> [KyroSportsGame] {
        if league == .atp || league == .wta {
            // A tennis day can legitimately map to nothing: a tournament with
            // no draws yet, doubles-only play, or only TBD bracket slots. Only
            // singles matches whose players cannot be read mean a bad payload.
            var games: [KyroSportsGame] = []
            var unreadable = 0
            for event in response.events {
                let result = ESPNMapping.tennisMapping(from: event, league: league)
                games += result.games
                unreadable += result.unreadable
            }
            if games.isEmpty, unreadable > 0 { throw KyroSportsDataError.malformedResponse }
            return games
        }
        let mapped = response.events.compactMap {
            ESPNMapping.game(from: $0, league: league, competitionKey: competitionKey,
                             competitionName: competitionName)
        }
        guard response.events.isEmpty || !mapped.isEmpty else {
            throw KyroSportsDataError.malformedResponse
        }
        return mapped
    }

    private func overlay(
        _ current: [KyroSportsGame],
        on schedule: [KyroSportsGame]
    ) -> [KyroSportsGame] {
        var byID: [String: KyroSportsGame] = [:]
        for game in schedule { byID[game.id.rawID] = game }
        for game in current { byID[game.id.rawID] = game }
        return Array(byID.values)
    }

    private func calendarYears(from start: Date, through end: Date) -> [Int] {
        let first = calendar.component(.year, from: start)
        let last = calendar.component(.year, from: end)
        return Array(min(first, last)...max(first, last))
    }

    /// ESPN's `dates=yyyyMMdd` scoreboard day follows the US sports calendar,
    /// not UTC. This keeps late primetime games on the expected ESPN day.
    static func espnDayString(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")
            ?? TimeZone(secondsFromGMT: -5 * 3600)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d%02d%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

/// Avoids remapping the full NFL calendar on every 20-second live tick. The
/// current-day payload is still decoded and overlaid each time its short cache
/// expires, while normalized schedule rows live for the same six-hour window
/// as the raw schedule response.
actor ESPNNormalizedScheduleCache {
    private struct Entry {
        let games: [KyroSportsGame]
        let storedAt: Date
    }

    private var entries: [Int: Entry] = [:]

    func games(for year: Int, at date: Date) -> [KyroSportsGame]? {
        guard let entry = entries[year],
              date.timeIntervalSince(entry.storedAt) < ESPNCachePolicy.schedule.maxAge(for: ESPNPayloadActivity(), at: date) else {
            return nil
        }
        return entry.games
    }

    func store(_ games: [KyroSportsGame], for year: Int, at date: Date) {
        entries[year] = Entry(games: games, storedAt: date)
    }
}
