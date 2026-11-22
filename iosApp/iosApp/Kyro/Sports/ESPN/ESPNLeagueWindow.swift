import Foundation

/// Source of a bounded schedule window or a single local day for a non-NFL
/// league. NFL keeps its own `KyroSportsProviding` path.
protocol KyroSportsLeagueProviding: Sendable {
    func fetchLeagueWindow(
        league: KyroSportLeague,
        now: Date,
        force: Bool
    ) async throws -> KyroSportsProviderOutput

    /// Scoreboard for one local calendar day. Default reuses the existing
    /// window fetch so test stubs keep a single seam.
    func fetchLeagueDay(
        league: KyroSportLeague,
        date: Date,
        now: Date,
        force: Bool
    ) async throws -> KyroSportsProviderOutput
}

extension KyroSportsLeagueProviding {
    func fetchLeagueDay(
        league: KyroSportLeague,
        date: Date,
        now: Date,
        force: Bool
    ) async throws -> KyroSportsProviderOutput {
        try await fetchLeagueWindow(league: league, now: now, force: force)
    }
}

/// Per-league ESPN request strategy, verified against the live endpoints.
///
/// - ESPN rejects `dates=yyyyMMdd-yyyyMMdd` ranges with HTTP 400, so NBA,
///   NHL and MLB load one scoreboard per ESPN day (US Eastern).
/// - The undated college-football scoreboard (`groups=80`) is the current
///   week as ESPN defines it, in one small response, so FBS uses it directly.
/// - A tennis `dates=yyyyMMdd` response lists every tournament active that
///   day with *all* of its matches (verified 2026-11-07: Paris Masters
///   returns 157 matches from Oct 31 to Nov 8). One request per selected day
///   is enough; an eight-day window would download the same draws eight times.
enum ESPNLeagueWindowStrategy: Equatable, Sendable {
    case dailyRequests
    case currentWeek
    case tournamentDay
    case soccerRegistry

    static func strategy(for league: KyroSportLeague) -> ESPNLeagueWindowStrategy {
        switch league {
        case .collegeFootball: .currentWeek
        case .collegeBasketballMen, .collegeBasketballWomen: .dailyRequests
        case .atp, .wta: .tournamentDay
        case .soccer: .soccerRegistry
        case .nfl, .nba, .nhl, .mlb: .dailyRequests
        }
    }
}

extension ESPNSportsProvider: KyroSportsLeagueProviding {
    static let maxConcurrentDayRequests = 3

    func fetchLeagueWindow(
        league: KyroSportLeague,
        now: Date,
        force: Bool = false
    ) async throws -> KyroSportsProviderOutput {
        switch ESPNLeagueWindowStrategy.strategy(for: league) {
        case .soccerRegistry:
            return try await fetchSoccerDay(league: league, date: now, now: now, force: force)
        case .currentWeek:
            if let output = try await fetchCurrentWeek(league: league, now: now, force: force) {
                return output
            }
            // No authoritative week metadata: use the bounded daily window.
            return try await fetchDailyWindow(league: league, now: now, force: force)
        case .dailyRequests:
            return try await fetchDailyWindow(league: league, now: now, force: force)
        case .tournamentDay:
            return try await fetchSingleDay(league: league, date: now, now: now, force: force)
        }
    }

    func fetchLeagueDay(
        league: KyroSportLeague,
        date: Date,
        now: Date,
        force: Bool
    ) async throws -> KyroSportsProviderOutput {
        switch ESPNLeagueWindowStrategy.strategy(for: league) {
        case .soccerRegistry:
            return try await fetchSoccerDay(league: league, date: date, now: now, force: force)
        case .currentWeek:
            if let output = try await fetchCurrentWeek(league: league, now: now, force: force) {
                return output
            }
            return try await fetchSingleDay(league: league, date: date, now: now, force: force)
        case .dailyRequests, .tournamentDay:
            return try await fetchSingleDay(league: league, date: date, now: now, force: force)
        }
    }

    // MARK: Soccer registry

    /// Fetch only the selected local day. A soccer refresh therefore touches
    /// one bounded request per verified competition, never a background sweep
    /// of every calendar or every league. The actor-backed ESPN client still
    /// supplies ETag/cache freshness and coalescing for repeated loads.
    private func fetchSoccerDay(
        league: KyroSportLeague,
        date: Date,
        now: Date,
        force: Bool
    ) async throws -> KyroSportsProviderOutput {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let day = Self.espnDayString(for: date)
        enum Result: Sendable {
            case success([KyroSportsGame], Int?, KyroSportsDataError?)
            case failure(KyroSportsDataError)
        }
        var results: [String: Result] = [:]
        var iterator = KyroSoccerCompetitionRegistry.verified.makeIterator()
        try await withThrowingTaskGroup(of: (String, Result).self) { group in
            func addNext() -> Bool {
                guard let competition = iterator.next() else { return false }
                group.addTask {
                    do {
                        let payload = try await self.client.fetchScoreboard(
                            league: league,
                            dates: day,
                            policy: date < now ? .completedDay : .today,
                            ignoreFreshness: force,
                            competitionKey: competition.key
                        )
                        let mapped = try self.mapValidated(payload.response, league: league,
                                                           competitionKey: competition.key,
                                                           competitionName: competition.name)
                        return (competition.key, .success(mapped, payload.response.leagues?.first?.season?.year,
                                                          payload.refreshError))
                    } catch let error as KyroSportsDataError {
                        return (competition.key, .failure(error))
                    } catch is CancellationError {
                        return (competition.key, .failure(.cancelled))
                    } catch {
                        return (competition.key, .failure(.offline))
                    }
                }
                return true
            }
            for _ in 0..<Self.maxConcurrentDayRequests { if !addNext() { break } }
            while let result = try await group.next() {
                results[result.0] = result.1
                if case .failure(.cancelled) = result.1 {
                    group.cancelAll()
                    throw KyroSportsDataError.cancelled
                }
                _ = addNext()
            }
        }
        var games: [KyroSportsGame] = []
        var firstFailure: KyroSportsDataError?
        var refreshError: KyroSportsDataError?
        var season: Int?
        for competition in KyroSoccerCompetitionRegistry.verified {
            switch results[competition.key] {
            case let .success(mapped, year, stale):
                games.append(contentsOf: mapped)
                season = season ?? year
                refreshError = refreshError ?? stale
            case let .failure(error):
                firstFailure = firstFailure ?? error
            case nil: break
            }
        }
        guard !games.isEmpty || firstFailure == nil else { throw firstFailure! }
        let windowed = KyroSportsReconciler.deduplicated(games.filter { game in
            guard let startTime = game.startTime else { return false }
            return startTime >= start && startTime < end
        })
        return KyroSportsProviderOutput(provider: providerID, games: windowed,
                                        season: season ?? calendar.component(.year, from: date),
                                        week: 0, refreshError: refreshError ?? firstFailure)
    }

    // MARK: Current week (FBS)

    private func fetchCurrentWeek(
        league: KyroSportLeague,
        now: Date,
        force: Bool
    ) async throws -> KyroSportsProviderOutput? {
        let payload = try await client.fetchScoreboard(
            league: league,
            dates: nil,
            policy: .currentWeek,
            ignoreFreshness: force
        )
        guard let week = payload.response.week?.number else { return nil }
        let games = KyroSportsReconciler.deduplicated(
            try mapValidated(payload.response, league: league)
        )
        let season = games.compactMap(\.season).first
            ?? payload.response.leagues?.first?.season?.year
            ?? calendar.component(.year, from: now)
        return KyroSportsProviderOutput(
            provider: providerID,
            games: games,
            season: season,
            week: week,
            refreshError: payload.refreshError
        )
    }

    // MARK: Single local day

    private func fetchSingleDay(
        league: KyroSportLeague,
        date: Date,
        now: Date,
        force: Bool
    ) async throws -> KyroSportsProviderOutput {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        let days = Self.espnDays(covering: start, until: end)
        let todayESPN = Self.espnDayString(for: now)
        let selectedIsToday = calendar.isDate(date, inSameDayAs: now)

        enum DayResult: Sendable {
            case success([KyroSportsGame], KyroSportsDataError?, season: Int?)
            case failure(KyroSportsDataError)
        }

        var results: [String: DayResult] = [:]
        try await withThrowingTaskGroup(of: (String, DayResult).self) { group in
            for day in days {
                let policy: ESPNCachePolicy = day < todayESPN ? .completedDay
                    : day == todayESPN ? .today : .futureDay
                group.addTask {
                    do {
                        let payload = try await self.client.fetchScoreboard(
                            league: league,
                            dates: day,
                            policy: policy,
                            ignoreFreshness: force && selectedIsToday && day == todayESPN
                        )
                        let games = try self.mapValidated(payload.response, league: league)
                        let year = payload.response.leagues?.first?.season?.year
                        return (day, .success(games, payload.refreshError, season: year))
                    } catch let error as KyroSportsDataError {
                        return (day, .failure(error))
                    } catch is CancellationError {
                        return (day, .failure(.cancelled))
                    } catch {
                        return (day, .failure(.offline))
                    }
                }
            }
            while let (day, result) = try await group.next() {
                results[day] = result
                if case .failure(.cancelled) = result {
                    group.cancelAll()
                    throw KyroSportsDataError.cancelled
                }
            }
        }

        var games: [KyroSportsGame] = []
        var refreshError: KyroSportsDataError?
        var firstFailure: KyroSportsDataError?
        var leagueSeason: Int?
        var succeeded = 0
        for day in days {
            switch results[day] {
            case let .success(dayGames, staleError, season):
                succeeded += 1
                games.append(contentsOf: dayGames)
                if refreshError == nil { refreshError = staleError }
                leagueSeason = leagueSeason ?? season
            case let .failure(error):
                if firstFailure == nil { firstFailure = error }
            case nil:
                break
            }
        }
        if succeeded == 0, let firstFailure { throw firstFailure }
        if refreshError == nil { refreshError = firstFailure }

        // Tennis responses carry whole tournaments, so this filter is what
        // limits them to the selected day. Date-only slots carry a day anchor.
        let windowed = KyroSportsReconciler.deduplicated(games.filter { game in
            guard let startTime = game.startTime else { return false }
            return startTime >= start && startTime < end
        })
        return KyroSportsProviderOutput(
            provider: providerID,
            games: windowed,
            season: windowed.compactMap(\.season).first
                ?? leagueSeason
                ?? calendar.component(.year, from: date),
            week: 0,
            refreshError: refreshError
        )
    }

    // MARK: Daily window (NBA, NHL, MLB)

    private func fetchDailyWindow(
        league: KyroSportLeague,
        now: Date,
        force: Bool
    ) async throws -> KyroSportsProviderOutput {
        let startOfToday = calendar.startOfDay(for: now)
        let windowStart = calendar.date(byAdding: .day, value: -1, to: startOfToday)
            ?? startOfToday.addingTimeInterval(-86_400)
        let windowEnd = calendar.date(
            byAdding: .day,
            value: KyroSportsSectioning.otherLeagueUpcomingDayCount,
            to: startOfToday
        ) ?? startOfToday.addingTimeInterval(7 * 86_400)

        let days = Self.espnDays(covering: windowStart, until: windowEnd)
        let todayESPN = Self.espnDayString(for: now)

        enum DayResult: Sendable {
            case success([KyroSportsGame], KyroSportsDataError?, season: Int?)
            case failure(KyroSportsDataError)
        }

        var results: [String: DayResult] = [:]
        try await withThrowingTaskGroup(of: (String, DayResult).self) { group in
            var iterator = days.makeIterator()
            func addNext() -> Bool {
                guard let day = iterator.next() else { return false }
                let policy: ESPNCachePolicy = day < todayESPN ? .completedDay
                    : day == todayESPN ? .today : .futureDay
                group.addTask {
                    do {
                        let payload = try await self.client.fetchScoreboard(
                            league: league,
                            dates: day,
                            policy: policy,
                            ignoreFreshness: force && day == todayESPN
                        )
                        let games = try self.mapValidated(payload.response, league: league)
                        let year = payload.response.leagues?.first?.season?.year
                        return (day, .success(games, payload.refreshError, season: year))
                    } catch let error as KyroSportsDataError {
                        return (day, .failure(error))
                    } catch is CancellationError {
                        return (day, .failure(.cancelled))
                    } catch {
                        return (day, .failure(.offline))
                    }
                }
                return true
            }
            for _ in 0..<Self.maxConcurrentDayRequests { if !addNext() { break } }
            while let (day, result) = try await group.next() {
                results[day] = result
                if case .failure(.cancelled) = result {
                    group.cancelAll()
                    throw KyroSportsDataError.cancelled
                }
                _ = addNext()
            }
        }

        var games: [KyroSportsGame] = []
        var refreshError: KyroSportsDataError?
        var firstFailure: KyroSportsDataError?
        var leagueSeason: Int?
        var succeeded = 0
        for day in days {
            switch results[day] {
            case let .success(dayGames, staleError, season):
                succeeded += 1
                games.append(contentsOf: dayGames)
                if refreshError == nil { refreshError = staleError }
                leagueSeason = leagueSeason ?? season
            case let .failure(error):
                if firstFailure == nil { firstFailure = error }
            case nil:
                break
            }
        }
        if succeeded == 0, let firstFailure { throw firstFailure }
        // A failed day with other days served is a partial result: keep the
        // good days and flag the output as stale instead of hiding them.
        if refreshError == nil { refreshError = firstFailure }

        let windowed = KyroSportsReconciler.deduplicated(games.filter { game in
            guard let start = game.startTime else { return false }
            return start >= windowStart && start < windowEnd
        })
        return KyroSportsProviderOutput(
            provider: providerID,
            games: windowed,
            season: windowed.compactMap(\.season).first
                ?? leagueSeason
                ?? calendar.component(.year, from: now),
            week: 0,
            refreshError: refreshError
        )
    }

    /// ESPN scoreboard days (`yyyyMMdd`, US Eastern) that overlap a local
    /// interval. Stepping in each calendar's own days keeps 23- and 25-hour
    /// daylight-saving days from skipping or repeating a day.
    static func espnDays(covering start: Date, until end: Date) -> [String] {
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = TimeZone(identifier: "America/New_York") ?? TimeZone(secondsFromGMT: -5 * 3600)!
        guard end > start else { return [] }
        var days: [String] = []
        var cursor = eastern.startOfDay(for: start)
        let last = eastern.startOfDay(for: end.addingTimeInterval(-1))
        while cursor <= last {
            let day = espnDayString(for: cursor.addingTimeInterval(12 * 3600))
            if days.last != day { days.append(day) }
            guard let next = eastern.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }
}

/// Shared refresh cadence for a league window. Nothing calls this for an
/// inactive league: only a visible, selected league may poll.
enum KyroSportsRefreshPolicy {
    static func interval(for games: [KyroSportsGame], now: Date) -> TimeInterval? {
        if games.contains(where: { $0.status.isLive }) { return 20 }
        let startingSoon = games.contains { game in
            guard game.status.isScheduled, let start = game.startTime else { return false }
            let delta = start.timeIntervalSince(now)
            return delta <= 3600 && delta > -1800
        }
        return startingSoon ? 120 : nil
    }
}
