import Foundation

/// Bounded raw-response cache shared by event summaries and team-news calls.
/// It honors ESPN's ETag and Cache-Control headers, coalesces identical work,
/// and can return a recent stale response when a refresh fails.
actor ESPNEventDetailResponseCache {
    static let maxResponseBytes = 2 * 1024 * 1024
    static let maxEntries = 24
    static let maxCachedBytes = 12 * 1024 * 1024

    private struct Entry: Sendable {
        let data: Data
        let etag: String?
        let storedAt: Date
        let freshFor: TimeInterval
    }

    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<Entry, Error>] = [:]

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func data(
        for request: URLRequest,
        key: String,
        fallbackFreshness: TimeInterval,
        transport: any ESPNTransport,
        ignoresServerFreshness: Bool = false
    ) async throws -> Data {
        let current = now()
        let stored = entries[key]
        if let stored, current.timeIntervalSince(stored.storedAt) < stored.freshFor {
            return stored.data
        }
        if let task = inFlight[key] {
            return try await task.value.data
        }

        var conditional = request
        if let etag = stored?.etag {
            conditional.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let task = Task<Entry, Error> {
            let (data, response) = try await transport.send(conditional)
            try Task.checkCancellation()
            // Build 65: TennisMyLife answers `max-age=0` for files it rewrites hourly or daily, which
            // turned every lookup into two downloads and spent its 12-per-10-minutes budget.
            let freshness = ignoresServerFreshness
                ? fallbackFreshness
                : Self.freshness(from: response, fallback: fallbackFreshness)
            switch response.statusCode {
            case 200...299:
                guard data.count <= Self.maxResponseBytes else {
                    throw KyroSportsEventDetailError.malformedResponse
                }
                return Entry(data: data, etag: response.value(forHTTPHeaderField: "ETag"),
                             storedAt: current, freshFor: freshness)
            case 304:
                guard let stored else { throw KyroSportsEventDetailError.malformedResponse }
                return Entry(data: stored.data, etag: stored.etag, storedAt: current,
                             freshFor: freshness)
            default:
                throw KyroSportsEventDetailError.unavailable
            }
        }
        inFlight[key] = task
        do {
            let entry = try await task.value
            inFlight[key] = nil
            entries[key] = entry
            evictIfNeeded(keeping: key)
            return entry.data
        } catch {
            inFlight[key] = nil
            if let stored, current.timeIntervalSince(stored.storedAt) < stored.freshFor + 3600 {
                return stored.data
            }
            if error is CancellationError { throw KyroSportsEventDetailError.cancelled }
            if let error = error as? KyroSportsEventDetailError { throw error }
            if let error = error as? KyroSportsDataError, error == .cancelled {
                throw KyroSportsEventDetailError.cancelled
            }
            throw KyroSportsEventDetailError.unavailable
        }
    }

    func removeAll() {
        entries.removeAll()
    }

    func cachedResponseCount() -> Int { entries.count }

    private func evictIfNeeded(keeping key: String) {
        var bytes = entries.values.reduce(0) { $0 + $1.data.count }
        while entries.count > Self.maxEntries || bytes > Self.maxCachedBytes {
            guard let oldest = entries.filter({ $0.key != key })
                .min(by: { $0.value.storedAt < $1.value.storedAt }) else { break }
            bytes -= oldest.value.data.count
            entries[oldest.key] = nil
        }
    }

    private static func freshness(from response: HTTPURLResponse, fallback: TimeInterval) -> TimeInterval {
        guard let value = response.value(forHTTPHeaderField: "Cache-Control") else { return fallback }
        for directive in value.split(separator: ",") {
            let parts = directive.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "max-age",
               let seconds = TimeInterval(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))) {
                return max(1, min(seconds, 12 * 3600))
            }
        }
        return fallback
    }
}

struct ESPNEventDetailClient: Sendable {
    private let baseURL: URL
    private let transport: any ESPNTransport
    private let cache: ESPNEventDetailResponseCache
    private let scoreboardClient: ESPNAPIClient
    private let timeout: TimeInterval

    init(
        baseURL: URL = URL(string: "https://site.api.espn.com")!,
        transport: any ESPNTransport = URLSessionESPNTransport(),
        cache: ESPNEventDetailResponseCache = ESPNEventDetailResponseCache(),
        timeout: TimeInterval = 12
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.cache = cache
        self.timeout = timeout
        self.scoreboardClient = ESPNAPIClient(baseURL: baseURL, transport: transport, timeout: timeout)
    }

    func fetchDetails(for game: KyroSportsGame) async throws -> KyroSportsEventDetails {
        if game.league == .atp || game.league == .wta {
            return try await fetchTennisDetails(for: game)
        }
        guard supportsDetails(for: game.league) else {
            throw KyroSportsEventDetailError.unsupportedLeague
        }
        let eventID = try await resolveEventID(for: game)
        let summary = try await fetchSummary(eventID: eventID, game: game)
        let teamIDs = try ESPNEventDetailMapping.validatedTeamIDs(
            summary: summary, eventID: eventID, game: game
        )

        var related = summary.news?.articles ?? []
        let teamNews = await withTaskGroup(of: [ESPNEventSummaryResponse.Article].self) { group in
            for teamID in teamIDs {
                group.addTask {
                    (try? await self.fetchNews(league: game.league, teamID: teamID,
                                              competitionKey: game.competitionKey)) ?? []
                }
            }
            var articles: [ESPNEventSummaryResponse.Article] = []
            for await result in group { articles.append(contentsOf: result) }
            return articles
        }
        related.append(contentsOf: teamNews)
        return try ESPNEventDetailMapping.details(
            summary: summary, additionalNews: related, eventID: eventID, game: game
        )
    }

    /// ESPN publishes no tennis match summary: the summary route answers HTTP 400 for match and
    /// tournament IDs (checked 2026-11-11), so tennis has no box score. Its league news does tag
    /// each story with the players' athlete IDs, which are the scoreboard's competitor IDs.
    private func fetchTennisDetails(for game: KyroSportsGame) async throws -> KyroSportsEventDetails {
        let playerIDs = ESPNEventDetailMapping.tennisPlayerIDs(for: game)
        guard !playerIDs.isEmpty else { throw KyroSportsEventDetailError.unsupportedLeague }
        let request = try makeRequest(league: game.league, competitionKey: nil, endpoint: "news", items: [
            URLQueryItem(name: "limit", value: "50")
        ])
        let data = try await cache.data(for: request, key: "news|\(game.league.rawValue)|league",
                                        fallbackFreshness: 15 * 60, transport: transport)
        let articles: [ESPNEventSummaryResponse.Article]
        do {
            articles = try JSONDecoder().decode(ESPNTeamNewsResponse.self, from: data).articles ?? []
        } catch {
            throw KyroSportsEventDetailError.malformedResponse
        }
        return ESPNEventDetailMapping.tennisDetails(articles: articles, playerIDs: playerIDs, game: game)
    }

    private func supportsDetails(for league: KyroSportLeague) -> Bool {
        switch league {
        case .nfl, .nba, .collegeFootball, .collegeBasketballMen, .collegeBasketballWomen, .mlb, .nhl, .soccer: true
        case .atp, .wta: false
        }
    }

    private func resolveEventID(for game: KyroSportsGame) async throws -> String {
        if let id = game.provenance.first(where: { $0.provider == "espn" })?.rawID {
            return id
        }
        if game.id.provider == "espn" { return game.id.rawID }

        // Sleeper is an NFL cold-start fallback. Resolve it only through the
        // same ESPN scoreboard adapter and require one exact-team, close-time
        // match; ambiguous joins are rejected rather than showing another game.
        guard let start = game.startTime else { throw KyroSportsEventDetailError.eventNotMatched }
        let payload: ESPNScoreboardPayload
        do {
            payload = try await scoreboardClient.fetchScoreboard(
                league: game.league,
                dates: ESPNSportsProvider.espnDayString(for: start),
                policy: .today
            )
        } catch {
            throw KyroSportsEventDetailError.eventNotMatched
        }
        let targetTeams = Self.teamKey(game)
        let matches = payload.response.events.compactMap { ESPNMapping.game(from: $0, league: game.league) }
            .filter { candidate in
                guard Self.teamKey(candidate) == targetTeams,
                      let candidateStart = candidate.startTime else { return false }
                return abs(candidateStart.timeIntervalSince(start)) <= 30 * 60
            }
        guard matches.count == 1 else { throw KyroSportsEventDetailError.eventNotMatched }
        return matches[0].id.rawID
    }

    private func fetchSummary(eventID: String, game: KyroSportsGame) async throws -> ESPNEventSummaryResponse {
        let request = try makeRequest(league: game.league, competitionKey: game.competitionKey,
                                     endpoint: "summary", items: [
            URLQueryItem(name: "event", value: eventID)
        ])
        let fallback: TimeInterval = game.status.isLive ? 20 : (game.status.isFinal ? 12 * 3600 : 5 * 60)
        let data = try await cache.data(for: request, key: "summary|\(game.league.rawValue)|\(game.competitionKey ?? "default")|\(eventID)",
                                        fallbackFreshness: fallback, transport: transport)
        do {
            return try JSONDecoder().decode(ESPNEventSummaryResponse.self, from: data)
        } catch {
            throw KyroSportsEventDetailError.malformedResponse
        }
    }

    private func fetchNews(league: KyroSportLeague, teamID: String, competitionKey: String?) async throws
        -> [ESPNEventSummaryResponse.Article] {
        let request = try makeRequest(league: league, competitionKey: competitionKey, endpoint: "news", items: [
            URLQueryItem(name: "team", value: teamID),
            URLQueryItem(name: "limit", value: "20")
        ])
        let data = try await cache.data(for: request, key: "news|\(league.rawValue)|\(teamID)",
                                        fallbackFreshness: 15 * 60, transport: transport)
        do {
            return try JSONDecoder().decode(ESPNTeamNewsResponse.self, from: data).articles ?? []
        } catch {
            throw KyroSportsEventDetailError.malformedResponse
        }
    }

    private func makeRequest(league: KyroSportLeague, competitionKey: String?, endpoint: String, items: [URLQueryItem]) throws -> URLRequest {
        let scoreboardPath = ESPNMapping.path(for: league, competitionKey: competitionKey)
        let path = scoreboardPath.replacingOccurrences(of: "/scoreboard", with: "/\(endpoint)")
        guard let url = URL(string: path, relativeTo: baseURL),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw KyroSportsEventDetailError.malformedResponse
        }
        components.queryItems = items
        guard let finalURL = components.url else { throw KyroSportsEventDetailError.malformedResponse }
        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func teamKey(_ game: KyroSportsGame) -> Set<String> {
        Set([game.home.team.abbreviation, game.away.team.abbreviation]
            .map(KyroSportsReconciler.canonicalTeam))
    }
}

enum ESPNEventDetailMapping {
    static func validatedTeamIDs(
        summary: ESPNEventSummaryResponse,
        eventID: String,
        game: KyroSportsGame
    ) throws -> [String] {
        guard summary.header?.id == eventID,
              let competition = summary.header?.competitions?.first(where: { $0.id == eventID })
                ?? summary.header?.competitions?.first else {
            throw KyroSportsEventDetailError.eventNotMatched
        }
        let competitors = competition.competitors ?? []
        let received = Set(competitors.compactMap { $0.team?.abbreviation }
            .map(KyroSportsReconciler.canonicalTeam))
        let expected = Set([game.home.team.abbreviation, game.away.team.abbreviation]
            .map(KyroSportsReconciler.canonicalTeam))
        guard received.count == 2, received == expected else {
            throw KyroSportsEventDetailError.eventNotMatched
        }
        return competitors.compactMap { $0.team?.id ?? $0.id }
    }

    static func details(
        summary: ESPNEventSummaryResponse,
        additionalNews: [ESPNEventSummaryResponse.Article],
        eventID: String,
        game: KyroSportsGame
    ) throws -> KyroSportsEventDetails {
        let selectedTeamIDs = Set(try validatedTeamIDs(summary: summary, eventID: eventID, game: game))
        let teamStats = (summary.boxscore?.teams ?? []).compactMap { item -> KyroSportsTeamBoxScore? in
            guard let team = item.team, let id = team.id, let abbreviation = nonempty(team.abbreviation) else {
                return nil
            }
            guard selectedTeamIDs.contains(id) else { return nil }
            let entries = item.statistics ?? []
            let statistics: [KyroSportsStatistic]
            if entries.contains(where: { $0.stats != nil }) {
                statistics = groupedTeamStatistics(entries)
            } else {
                statistics = entries.compactMap { statistic -> KyroSportsStatistic? in
                    guard let label = nonempty(statistic.label) ?? nonempty(statistic.name),
                          let value = nonempty(statistic.displayValue?.stringValue) else { return nil }
                    return KyroSportsStatistic(label: label, value: value)
                }
            }
            return KyroSportsTeamBoxScore(providerTeamID: id, abbreviation: abbreviation,
                                          displayName: nonempty(team.displayName) ?? abbreviation,
                                          homeAway: nonempty(item.homeAway), statistics: statistics)
        }
        let players = (summary.boxscore?.players ?? []).compactMap { item -> KyroSportsPlayerTeamBoxScore? in
            guard let team = item.team, let teamID = team.id,
                  selectedTeamIDs.contains(teamID),
                  let abbreviation = nonempty(team.abbreviation) else { return nil }
            let groups = (item.statistics ?? []).compactMap { group -> KyroSportsPlayerStatGroup? in
                let labels = group.labels ?? group.keys ?? []
                let lines = (group.athletes ?? []).compactMap { line -> KyroSportsPlayerStatLine? in
                    guard line.didNotPlay != true, let athlete = line.athlete,
                          let name = nonempty(athlete.displayName), !((line.stats ?? []).isEmpty) else { return nil }
                    return KyroSportsPlayerStatLine(
                        providerAthleteID: athlete.id ?? name,
                        displayName: name,
                        shortName: nonempty(athlete.shortName),
                        position: nonempty(athlete.position?.abbreviation)
                            ?? nonempty(athlete.position?.displayName),
                        starter: line.starter == true,
                        values: (line.stats ?? []).map(\.stringValue)
                    )
                }
                guard !lines.isEmpty else { return nil }
                let name = nonempty(group.displayName)
                    ?? (nonempty(group.name) ?? nonempty(group.type)).map(groupTitle) ?? "Players"
                return KyroSportsPlayerStatGroup(name: name, labels: labels, athletes: lines)
            }
            guard !groups.isEmpty else { return nil }
            return KyroSportsPlayerTeamBoxScore(providerTeamID: teamID, abbreviation: abbreviation,
                                                displayName: nonempty(team.displayName) ?? abbreviation,
                                                groups: groups)
        }

        // Soccer summaries expose full per-player match stats under rosters
        // instead of the generic boxscore.players shape used by US sports.
        // Keep only players with at least one meaningful value and never turn
        // a missing stat into a zero.
        let soccerPlayers = (summary.rosters ?? []).compactMap { roster -> KyroSportsPlayerTeamBoxScore? in
            guard let team = roster.team, let teamID = team.id,
                  selectedTeamIDs.contains(teamID), let abbreviation = nonempty(team.abbreviation) else { return nil }
            let statisticKeys = (roster.roster ?? []).flatMap { $0.stats ?? [] }
                .compactMap { statistic -> (String, String)? in
                    guard let key = nonempty(statistic.name),
                          let label = nonempty(statistic.displayName) ?? nonempty(statistic.name) else { return nil }
                    return (key, label)
                }
                .reduce(into: [(String, String)]()) { output, item in
                    if !output.contains(where: { $0.0 == item.0 }) { output.append(item) }
                }
            let athletes = (roster.roster ?? []).compactMap { player -> KyroSportsPlayerStatLine? in
                guard player.didNotPlay != true, let athlete = player.athlete,
                      let name = nonempty(athlete.displayName) else { return nil }
                let playerStats = player.stats ?? []
                guard playerStats.contains(where: { nonempty($0.displayValue) != nil }) else { return nil }
                let values = statisticKeys.map { item in
                    playerStats.first(where: { $0.name == item.0 }).flatMap { nonempty($0.displayValue) } ?? "–"
                }
                return KyroSportsPlayerStatLine(providerAthleteID: athlete.id ?? name,
                    displayName: name, shortName: nonempty(athlete.shortName),
                    position: nonempty(player.position?.abbreviation) ?? nonempty(player.position?.displayName),
                    starter: player.starter == true, values: values)
            }
            guard !athletes.isEmpty else { return nil }
            let labels = statisticKeys.map { $0.1 }
            return KyroSportsPlayerTeamBoxScore(providerTeamID: teamID, abbreviation: abbreviation,
                displayName: nonempty(team.displayName) ?? abbreviation,
                groups: [KyroSportsPlayerStatGroup(name: "Match statistics", labels: labels, athletes: athletes)])
        }
        // MLB summaries carry both shapes for the same players. Rosters fill in only when the
        // generic box score is missing, so no team is listed twice.
        let mergedPlayers = players.isEmpty ? soccerPlayers : players
        let matchEvents = (summary.keyEvents ?? []).compactMap { event -> KyroSportsMatchEvent? in
            guard let kind = nonempty(event.type?.text) else { return nil }
            let names = (event.athletesInvolved ?? []).compactMap { nonempty($0.displayName) }
            return KyroSportsMatchEvent(id: event.id ?? "\(kind)-\(event.clock?.displayValue ?? "")-\(event.team?.id ?? "")",
                                        clock: nonempty(event.clock?.displayValue), kind: kind,
                                        teamID: event.team?.id, playerNames: names)
        }

        var articles = additionalNews
        if let exact = summary.article { articles.insert(exact, at: 0) }
        let news = newsItems(from: articles, exactArticleID: summary.article?.id,
                             selectedTeamIDs: selectedTeamIDs, game: game)

        // Build 68: before the start ESPN fills `boxscore.teams` with season averages. They move
        // to the pregame context, labelled as season figures, and the event's box score stays
        // empty until the summary itself says the game has started.
        let phase = statisticsPhase(summary: summary, eventID: eventID)
        let carriesEventStatistics = phase.carriesEventStatistics
        var details = KyroSportsEventDetails(
            gameID: game.id, providerEventID: eventID,
            teamStatistics: carriesEventStatistics ? teamStats : [],
            playerBoxScores: carriesEventStatistics ? mergedPlayers : [],
            matchEvents: carriesEventStatistics ? matchEvents : [],
            news: news)
        details.statisticsPhase = phase
        if phase == .pregame {
            let context = pregameContext(summary: summary, eventID: eventID, selectedTeamIDs: selectedTeamIDs,
                                         seasonStatistics: teamStats, game: game)
            details.pregame = context.isEmpty ? nil : context
        }
        return details
    }

    static func statisticsPhase(summary: ESPNEventSummaryResponse, eventID: String) -> KyroSportsStatisticsPhase {
        let competitions = summary.header?.competitions ?? []
        let competition = competitions.first { $0.id == eventID } ?? competitions.first
        let type = competition?.status?.value?.type
        return KyroSportsStatisticsPhase(espnState: type?.state, completed: type?.completed)
    }

    // MARK: Build 68 pregame context

    static func pregameContext(
        summary: ESPNEventSummaryResponse,
        eventID: String,
        selectedTeamIDs: Set<String>,
        seasonStatistics: [KyroSportsTeamBoxScore],
        game: KyroSportsGame
    ) -> KyroSportsPregameContext {
        let competitions = summary.header?.competitions ?? []
        let competitors = (competitions.first { $0.id == eventID } ?? competitions.first)?.competitors ?? []
        func team(_ side: String) -> KyroSportsPregameContext.Team? {
            guard let competitor = competitors.first(where: { $0.homeAway?.lowercased() == side }),
                  let id = competitor.team?.id ?? competitor.id, selectedTeamIDs.contains(id) else { return nil }
            let abbreviation = nonempty(competitor.team?.abbreviation)
                ?? (side == "home" ? game.home.team.abbreviation : game.away.team.abbreviation)
            let season = seasonStatistics.first { $0.providerTeamID == id }?.statistics ?? []
            var records = (competitor.record?.values ?? []).compactMap { record -> KyroSportsPregameContext.Record? in
                guard let type = nonempty(record.type),
                      let label = KyroSportsPregameRules.recordLabel(type: type, league: game.league),
                      let value = nonempty(record.summary) ?? nonempty(record.displayValue) else { return nil }
                return .init(label: label, value: value)
            }
            // Streak and last ten arrive among the averages; they are records, not quantities.
            var averages: [KyroSportsStatistic] = []
            for statistic in season {
                if let label = KyroSportsPregameRules.recordLikeStatistics[statistic.label.lowercased()] {
                    if !records.contains(where: { $0.label == label }) { records.append(.init(label: label, value: statistic.value)) }
                } else {
                    averages.append(statistic)
                }
            }
            return KyroSportsPregameContext.Team(
                providerTeamID: id, abbreviation: abbreviation, records: records,
                recent: recentGames(summary: summary, teamID: id, game: game),
                leaders: leaders(summary: summary, teamID: id),
                injuries: injuries(summary: summary, teamID: id),
                seasonStatistics: averages)
        }
        let venue = summary.gameInfo?.value?.venue.flatMap { venue -> String? in
            guard let name = nonempty(venue.fullName) else { return nil }
            let place = [venue.address?.city, venue.address?.state ?? venue.address?.country]
                .compactMap(nonempty).joined(separator: ", ")
            return place.isEmpty ? name : "\(name), \(place)"
        }
        return KyroSportsPregameContext(
            away: team("away"), home: team("home"),
            standings: standings(summary: summary, selectedTeamIDs: selectedTeamIDs, league: game.league),
            series: series(summary: summary, eventID: eventID),
            venue: venue)
    }

    static func recentGames(summary: ESPNEventSummaryResponse, teamID: String,
                            game: KyroSportsGame) -> [KyroSportsPregameContext.RecentGame] {
        guard let entry = (summary.lastFiveGames?.values ?? []).first(where: { $0.team?.id == teamID }) else { return [] }
        let selectedCompetition = [game.tournament, KyroSoccerCompetitionRegistry.competition(for: game.competitionKey)?.name]
            .compactMap { $0?.lowercased() }
        let games = (entry.events?.values ?? []).compactMap { event -> KyroSportsPregameContext.RecentGame? in
            guard let opponent = nonempty(event.opponent?.abbreviation) ?? nonempty(event.opponent?.displayName) else {
                return nil
            }
            let homeID = event.homeTeamId?.stringValue
            let awayID = event.awayTeamId?.stringValue
            let isHome: Bool
            if homeID == teamID { isHome = true }
            else if awayID == teamID { isHome = false }
            else { isHome = event.atVs?.lowercased() == "vs" }
            let home = nonempty(event.homeTeamScore?.stringValue)
            let away = nonempty(event.awayTeamScore?.stringValue)
            let outcome = nonempty(event.gameResult).flatMap { KyroSportsPregameContext.RecentGame.Outcome(rawValue: $0.uppercased()) }
            // Soccer sides play cups and European ties between league games: those are named, a
            // game in the selected competition is not.
            let competition = [nonempty(event.leagueAbbreviation), nonempty(event.leagueName)].compactMap { $0 }
            let isOtherCompetition = game.league == .soccer && !selectedCompetition.isEmpty && !competition.isEmpty
                && !competition.contains { name in
                    let name = name.lowercased()
                    return selectedCompetition.contains { $0 == name || $0.contains(name) || name.contains($0) }
                }
            return .init(id: event.id?.stringValue ?? "\(opponent)-\(event.gameDate ?? "")",
                         date: parseDate(event.gameDate), outcome: outcome,
                         teamScore: isHome ? home : away, opponentScore: isHome ? away : home,
                         opponent: opponent, isHome: isHome,
                         competition: isOtherCompetition ? competition.first : nil)
        }
        return games.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    static func leaders(summary: ESPNEventSummaryResponse, teamID: String) -> [KyroSportsPregameContext.Leader] {
        guard let entry = (summary.leaders?.values ?? []).first(where: { $0.team?.id == teamID }) else { return [] }
        return (entry.leaders?.values ?? []).compactMap { category -> KyroSportsPregameContext.Leader? in
            guard let key = nonempty(category.name) ?? nonempty(category.displayName),
                  let title = nonempty(category.displayName) ?? nonempty(category.name),
                  let top = category.leaders?.values.first,
                  let athlete = nonempty(top.athlete?.displayName) ?? nonempty(top.athlete?.shortName),
                  let value = nonempty(top.displayValue) else { return nil }
            return .init(id: key, category: title, athlete: athlete, value: value)
        }
    }

    static func injuries(summary: ESPNEventSummaryResponse, teamID: String) -> [KyroSportsPregameContext.Injury] {
        guard let entry = (summary.injuries?.values ?? []).first(where: { $0.team?.id == teamID }) else { return [] }
        return (entry.injuries?.values ?? []).compactMap { injury -> KyroSportsPregameContext.Injury? in
            guard let name = nonempty(injury.athlete?.displayName), let status = nonempty(injury.status) else { return nil }
            let detail = [injury.details?.type, injury.details?.detail].compactMap(nonempty).joined(separator: " ")
            return .init(id: injury.athlete?.id ?? name, name: name,
                         position: nonempty(injury.athlete?.position?.abbreviation),
                         status: status, detail: detail.isEmpty ? nil : detail)
        }
    }

    static func standings(summary: ESPNEventSummaryResponse, selectedTeamIDs: Set<String>,
                          league: KyroSportLeague) -> [KyroSportsPregameContext.StandingsGroup] {
        let preferred = KyroSportsPregameRules.standingsColumns(for: league)
        return (summary.standings?.value?.groups?.values ?? []).enumerated().compactMap { index, group in
            let entries = group.standings?.entries?.values ?? []
            guard !entries.isEmpty, entries.contains(where: { $0.id.map(selectedTeamIDs.contains) == true }) else {
                return nil
            }
            // The preferred columns that this group actually has; otherwise ESPN's first four.
            let available = Set(entries.flatMap { ($0.stats?.values ?? []).compactMap(\.name) })
            var columns = preferred.filter { available.contains($0.name) }
            if columns.isEmpty {
                columns = (entries.first?.stats?.values ?? []).prefix(4).compactMap { stat in
                    guard let name = nonempty(stat.name) else { return nil }
                    return (name, nonempty(stat.abbreviation) ?? name)
                }
            }
            guard !columns.isEmpty else { return nil }
            let rows = entries.enumerated().map { offset, entry -> KyroSportsPregameContext.StandingsGroup.Row in
                let stats = entry.stats?.values ?? []
                let values = columns.map { column in
                    stats.first { $0.name == column.name }.flatMap { nonempty($0.displayValue) } ?? "–"
                }
                return .init(id: entry.id ?? "\(offset)", position: offset + 1,
                             team: nonempty(entry.team) ?? "–",
                             isSelected: entry.id.map(selectedTeamIDs.contains) ?? false, values: values)
            }
            let shown = rows.count > KyroSportsPregameRules.fullStandingsLimit ? rows.filter(\.isSelected) : rows
            let title = nonempty(group.divisionHeader) ?? nonempty(group.conferenceHeader)
                ?? nonempty(group.header).map(standingsTitle) ?? "Standings"
            return .init(id: "\(index)-\(title)", title: title, columns: columns.map(\.header),
                         rows: shown, totalTeams: rows.count)
        }
    }

    /// `2026-27 Atlantic Standings` → `Atlantic`; `English Premier League Standings` → the league.
    static func standingsTitle(_ header: String) -> String {
        var words = header.split(separator: " ").map(String.init)
        if words.last?.lowercased() == "standings" { words.removeLast() }
        if let first = words.first, first.first?.isNumber == true { words.removeFirst() }
        let title = words.joined(separator: " ")
        return title.isEmpty ? header : title
    }

    static func series(summary: ESPNEventSummaryResponse, eventID: String) -> [KyroSportsPregameContext.Series] {
        (summary.seasonseries?.values ?? []).enumerated().compactMap { index, series in
            let events = (series.events?.values ?? []).filter { $0.id != eventID }
            let completed = events.filter { $0.statusType?.completed == true }
            let meetings = completed.compactMap { event -> KyroSportsPregameContext.Meeting? in
                let competitors = event.competitors?.values ?? []
                guard let home = competitors.first(where: { $0.homeAway == "home" }),
                      let away = competitors.first(where: { $0.homeAway == "away" }),
                      let homeName = nonempty(home.team?.abbreviation), let awayName = nonempty(away.team?.abbreviation) else {
                    return nil
                }
                let winner = home.winner == true ? homeName : (away.winner == true ? awayName : nil)
                return .init(id: event.id ?? "\(awayName)-\(homeName)-\(event.date ?? "")", date: parseDate(event.date),
                             away: awayName, home: homeName,
                             awayScore: nonempty(away.score?.stringValue), homeScore: nonempty(home.score?.stringValue),
                             winner: winner)
            }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            let upcoming = events.filter { $0.statusType?.state?.lowercased() == "pre" }.count
            let summaryText = nonempty(series.summary)
            guard !meetings.isEmpty || summaryText != nil else { return nil }
            return .init(id: "\(index)-\(series.type ?? "")", title: nonempty(series.title) ?? "Previous meetings",
                         summary: summaryText, meetings: Array(meetings.prefix(KyroSportsPregameRules.maxMeetings)),
                         upcoming: upcoming)
        }
    }

    private static func newsItems(
        from articles: [ESPNEventSummaryResponse.Article],
        exactArticleID: Int?,
        selectedTeamIDs: Set<String>,
        game: KyroSportsGame
    ) -> [KyroSportsNewsItem] {
        var seen = Set<String>()
        var output: [KyroSportsNewsItem] = []
        for article in articles {
            guard let headline = nonempty(article.headline),
                  let url = safeWebURL(article.links?.web?.href) else { continue }
            let id = article.id.map(String.init) ?? url.absoluteString
            let categoryTeamIDs = Set((article.categories ?? []).compactMap { $0.team?.id?.stringValue })
            guard let relevance = relevance(articleID: article.id, exactArticleID: exactArticleID,
                                            taggedIDs: categoryTeamIDs, selectedIDs: selectedTeamIDs,
                                            headline: headline, game: game) else { continue }
            // Insert only after relevance is proven. The same article can arrive first without
            // categories and later with verified team tags. Build 68: also one entry per
            // canonical URL, since team feeds can list one story under two IDs.
            guard !seen.contains(id), seen.insert(KyroSportsNewsDedup.key(for: url)).inserted else { continue }
            seen.insert(id)
            var item = KyroSportsNewsItem(
                id: id, headline: headline, publishedAt: parseDate(article.published),
                url: url, source: "ESPN", relevance: relevance
            )
            item.isPreview = relevance == .event && article.type?.lowercased() == "preview"
            output.append(item)
        }
        return ranked(output)
    }

    /// Exact event story first, then matchup, then single-side stories; newest first within each.
    private static func ranked(_ items: [KyroSportsNewsItem]) -> [KyroSportsNewsItem] {
        items.sorted {
            if $0.relevance != $1.relevance { return $0.relevance.rawValue > $1.relevance.rawValue }
            return ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast)
        }.prefix(12).map { $0 }
    }

    /// One relevance rule for team and tennis news. A story tagged with more than eight teams or
    /// players (power rankings, odds tables, award watches) is league-wide: it is kept only when
    /// its headline names a selected side, and then as a single-side story, never a matchup.
    static func relevance(
        articleID: Int?,
        exactArticleID: Int?,
        taggedIDs: Set<String>,
        selectedIDs: Set<String>,
        headline: String,
        game: KyroSportsGame
    ) -> KyroSportsNewsItem.Relevance? {
        if let articleID, articleID == exactArticleID { return .event }
        let matched = taggedIDs.intersection(selectedIDs)
        guard !matched.isEmpty else { return nil }
        if taggedIDs.count > 8 {
            return headlineMatchesSelectedTeam(headline, game: game) ? .team : nil
        }
        if selectedIDs.count == 2, matched.count == 2 { return .matchup }
        return .team
    }

    /// MLB reports team statistics in groups. These are the box-score lines a viewer expects,
    /// in reading order; anything ESPN leaves out is skipped rather than shown as zero.
    private static let groupedTeamStatisticOrder: [(group: String, name: String, label: String)] = [
        ("batting", "runs", "Runs"),
        ("batting", "hits", "Hits"),
        ("batting", "homeRuns", "Home Runs"),
        ("batting", "RBIs", "RBI"),
        ("batting", "walks", "Walks"),
        ("batting", "strikeouts", "Strikeouts"),
        ("batting", "stolenBases", "Stolen Bases"),
        ("batting", "runnersLeftOnBase", "Left on Base"),
        ("batting", "avg", "Batting Average"),
        ("batting", "OPS", "OPS"),
        ("pitching", "ERA", "ERA"),
        ("pitching", "pitches", "Pitches"),
        ("pitching", "strikeouts", "Pitching Strikeouts"),
        ("fielding", "errors", "Errors"),
    ]

    static func groupedTeamStatistics(_ groups: [ESPNEventSummaryResponse.Statistic]) -> [KyroSportsStatistic] {
        groupedTeamStatisticOrder.compactMap { item in
            guard let group = groups.first(where: { $0.name?.lowercased() == item.group }),
                  let statistic = group.stats?.first(where: { $0.name == item.name }),
                  let value = nonempty(statistic.displayValue?.stringValue) else { return nil }
            return KyroSportsStatistic(label: item.label, value: value)
        }
    }

    /// `kickReturns` → `Kick Returns`, `forwards` → `Forwards`.
    static func groupTitle(_ raw: String) -> String {
        var words: [String] = []
        var current = ""
        for character in raw {
            if character.isUppercase, !current.isEmpty {
                words.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// ESPN athlete IDs of the two players, from Kyro's provider-scoped team IDs
    /// (`espn.wta.6970`). TBD slots and non-ESPN identities give nothing.
    static func tennisPlayerIDs(for game: KyroSportsGame) -> Set<String> {
        guard game.league == .atp || game.league == .wta else { return [] }
        let prefix = "\(ESPNMapping.providerName).\(game.league.rawValue)."
        return Set([game.home.team, game.away.team].compactMap { team -> String? in
            guard team.id.hasPrefix(prefix) else { return nil }
            let id = String(team.id.dropFirst(prefix.count))
            return !id.isEmpty && id.allSatisfy(\.isNumber) ? id : nil
        })
    }

    /// Tennis has headlines only. A story must be tagged with one of the selected players' IDs.
    static func tennisDetails(
        articles: [ESPNEventSummaryResponse.Article],
        playerIDs: Set<String>,
        game: KyroSportsGame
    ) -> KyroSportsEventDetails {
        var seen = Set<String>()
        var output: [KyroSportsNewsItem] = []
        for article in articles {
            guard let headline = nonempty(article.headline),
                  let url = safeWebURL(article.links?.web?.href) else { continue }
            let tagged = Set((article.categories ?? []).compactMap { $0.athleteId?.stringValue })
            guard let relevance = relevance(articleID: article.id, exactArticleID: nil, taggedIDs: tagged,
                                            selectedIDs: playerIDs, headline: headline, game: game) else { continue }
            let id = article.id.map(String.init) ?? url.absoluteString
            guard seen.insert(id).inserted else { continue }
            output.append(KyroSportsNewsItem(id: id, headline: headline, publishedAt: parseDate(article.published),
                                             url: url, source: "ESPN", relevance: relevance))
        }
        return KyroSportsEventDetails(gameID: game.id, providerEventID: game.id.rawID, teamStatistics: [],
                                      playerBoxScores: [], matchEvents: [], news: ranked(output))
    }

    private static func headlineMatchesSelectedTeam(_ headline: String, game: KyroSportsGame) -> Bool {
        let folded = headline.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return [game.home.team.nickname, game.home.team.fullName,
                game.away.team.nickname, game.away.team.fullName]
            .filter { $0.count >= 3 }
            .contains { folded.localizedCaseInsensitiveContains($0) }
    }

    private static func safeWebURL(_ value: String?) -> URL? {
        guard let value, var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        if scheme == "http" { components.scheme = "https" }
        return components.url
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// Build 65: one instance of each supplement provider for the whole app. Every store (the pinned
/// event's tabs, Event Details) then shares one response cache and one request budget per source,
/// and a Sports Hub that is rebuilt does not start with empty caches.
enum KyroSportsSharedProviders {
    static let supplements: [any KyroSportsSupplementProviding] = [TheSportsDBClient(), WTAMatchStatsClient(), TMLMatchStatsClient()]
    static let news: any KyroSportsNewsSupplementing = TennisNewsClient()
    static let playerInfo: any KyroTennisPlayerInfoProviding = TheScoreTennisInfoClient()
}

@MainActor
@Observable
final class KyroSportsEventDetailStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(KyroSportsEventDetailError)
    }

    private(set) var phase: Phase = .idle
    private(set) var details: KyroSportsEventDetails?
    private var loadedAt: Date?
    /// Build 68: scheduled (0), live (1) or final (2) when `details` loaded, so a game that starts
    /// is reloaded at once instead of keeping its pregame answer until it goes stale.
    private var loadedStatusKind: Int?
    /// Build 68: the last few events' answers, so going back to an event (or reopening it) inside
    /// its freshness window does not request it again. Keyed by stable event identity.
    private var recent: [KyroGameID: (details: KyroSportsEventDetails, at: Date, statusKind: Int)] = [:]
    static let recentLimit = 6
    private var loadToken = UUID()
    private let client: ESPNEventDetailClient
    private let now: @Sendable () -> Date

    /// Build 63: flag-guarded supplements. Kept apart from `details` so an ESPN load, refresh or
    /// failure never touches them (and vice versa).
    private(set) var supplement: KyroSportsSupplementalStatistics?
    private(set) var supplementalNews: KyroSportsSupplementalNews?
    private var supplementOutcomes: [KyroGameID: (outcome: KyroSportsSupplementOutcome, at: Date)] = [:]
    private var newsOutcomes: [KyroGameID: (news: KyroSportsSupplementalNews?, at: Date)] = [:]
    private var supplementToken = UUID()
    private var newsToken = UUID()
    /// Build 64: historical player context (ranking, head-to-head, recent form) for tennis.
    private(set) var playerInfo: KyroTennisPlayerInfo?
    private var playerInfoOutcomes: [KyroGameID: (info: KyroTennisPlayerInfo?, at: Date)] = [:]
    private var playerInfoToken = UUID()
    private let playerInfoProvider: (any KyroTennisPlayerInfoProviding)?
    private let supplementProviders: [any KyroSportsSupplementProviding]
    private let newsProvider: (any KyroSportsNewsSupplementing)?
    private let flagEnabled: @Sendable (String) -> Bool

    /// Build 65: what the last statistics lookup concluded for an event, so the screen can say why
    /// none are shown (not yet published, not covered, or a source that could not be reached).
    struct SupplementLookup: Equatable {
        let gameID: KyroGameID
        let outcome: KyroSportsSupplementOutcome
    }
    private(set) var supplementLookup: SupplementLookup?
    private(set) var supplementLoadingGameID: KyroGameID?
    /// The event whose player lookup finished (with or without a result).
    private(set) var playerInfoLookedUpGameID: KyroGameID?
    private(set) var playerInfoLoadingGameID: KyroGameID?

    /// How long a lookup result is reused. Finding nothing for a match that finished recently is
    /// rechecked after 20 minutes, because both datasets publish results hours after the match
    /// (Build 64 kept "nothing yet" for 6 hours).
    static func supplementTTL(_ outcome: KyroSportsSupplementOutcome, game: KyroSportsGame, now: Date) -> TimeInterval {
        switch outcome {
        case .providerUnavailable: return 10 * 60
        case .noVerifiedMatch, .ambiguousMatch:
            if let start = game.startTime, now.timeIntervalSince(start) < 36 * 3600 { return 20 * 60 }
            return 6 * 3600
        default: return 6 * 3600
        }
    }

    static func journalLabel(_ outcome: KyroSportsSupplementOutcome) -> String {
        switch outcome {
        case .available(let stats): "available rows=\(stats.rows.count)"
        case .notEligible: "not_eligible"
        case .noVerifiedMatch: "no_verified_match"
        case .ambiguousMatch: "ambiguous"
        case .noAdditionalStatistics: "no_additional_statistics"
        case .providerUnavailable: "provider_unavailable"
        case .cancelled: "cancelled"
        }
    }

    init(client: ESPNEventDetailClient = ESPNEventDetailClient(),
         supplementProviders: [any KyroSportsSupplementProviding] = KyroSportsSharedProviders.supplements,
         newsProvider: (any KyroSportsNewsSupplementing)? = KyroSportsSharedProviders.news,
         playerInfoProvider: (any KyroTennisPlayerInfoProviding)? = KyroSportsSharedProviders.playerInfo,
         flagEnabled: @escaping @Sendable (String) -> Bool = { KyroSportsSupplementFlag.isEnabled(key: $0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.supplementProviders = supplementProviders
        self.newsProvider = newsProvider
        self.playerInfoProvider = playerInfoProvider
        self.flagEnabled = flagEnabled
        self.now = now
    }

    /// Fetches statistics from the one adapter that is enabled and eligible for the selected
    /// event, once ESPN's details for it are on screen (tennis has no ESPN details, so its
    /// `unsupportedLeague` placeholder counts). Outcomes, including "no verified match", are
    /// remembered per event, so tab switches, refreshes and rapid event changes never repeat a
    /// provider request.
    func loadSupplement(for game: KyroSportsGame) async {
        if supplement?.gameID != game.id { supplement = nil }
        if supplementLookup?.gameID != game.id { supplementLookup = nil }
        let providers = supplementProviders.filter { flagEnabled($0.flagKey) && $0.isEligible(game) }
        guard !providers.isEmpty, hasBaseDetails(for: game) else { return }
        if let known = supplementOutcomes[game.id] {
            if now().timeIntervalSince(known.at) < Self.supplementTTL(known.outcome, game: game, now: now()) {
                if case .available(let stats) = known.outcome { supplement = stats }
                supplementLookup = SupplementLookup(gameID: game.id, outcome: known.outcome)
                return
            }
        }
        let token = UUID()
        supplementToken = token
        supplementLoadingGameID = game.id
        defer { if supplementToken == token { supplementLoadingGameID = nil } }
        let labels = details?.gameID == game.id ? (details?.teamStatistics.flatMap { $0.statistics.map(\.label) } ?? []) : []
        // Build 64: adapters are tried in order and the first one with verified statistics wins
        // (WTA's own feed first, then the TennisMyLife dataset). Each adapter keeps its own budget.
        // The most informative miss is kept: "unavailable" only when no source answered at all.
        var outcome = KyroSportsSupplementOutcome.noVerifiedMatch
        var misses: [KyroSportsSupplementOutcome] = []
        for provider in providers {
            var result = await provider.supplementalStatistics(for: game, existingLabels: labels)
            // Statistics are published only for the event they were requested for.
            if case .available(let stats) = result, stats.gameID != game.id { result = .noVerifiedMatch }
            KyroLifecycleJournal.record("sports", "stats_lookup",
                                        "\(String(describing: type(of: provider))) league=\(game.league.rawValue) status=\(game.status) -> \(Self.journalLabel(result))")
            outcome = result
            if case .available = result { break }
            if result == .cancelled || supplementToken != token { break }
            misses.append(result)
        }
        guard supplementToken == token, outcome != .cancelled else { return }
        if case .available = outcome {} else { outcome = Self.combinedMiss(misses) }
        if supplementOutcomes.count >= 32 { supplementOutcomes.removeAll() }
        supplementOutcomes[game.id] = (outcome, now())
        if case .available(let stats) = outcome { supplement = stats }
        supplementLookup = SupplementLookup(gameID: game.id, outcome: outcome)
    }

    /// Ambiguous first (a candidate was found and deliberately not shown). Then "could not reach":
    /// one unreachable source may still have the match, so the short retry must win over another
    /// source's "not found".
    static func combinedMiss(_ misses: [KyroSportsSupplementOutcome]) -> KyroSportsSupplementOutcome {
        if misses.contains(.ambiguousMatch) { return .ambiguousMatch }
        if misses.contains(.providerUnavailable) { return .providerUnavailable }
        if misses.contains(.noAdditionalStatistics) { return .noAdditionalStatistics }
        if misses.contains(.noVerifiedMatch) { return .noVerifiedMatch }
        return misses.last ?? .noVerifiedMatch
    }

    /// Ranking, head-to-head and recent form for the selected tennis match (Stats tab only). Missing
    /// information is remembered for 30 minutes, found information for 6 hours; neither is polled.
    func loadPlayerInfo(for game: KyroSportsGame) async {
        if playerInfo?.gameID != game.id { playerInfo = nil }
        if playerInfoLookedUpGameID != game.id { playerInfoLookedUpGameID = nil }
        guard let provider = playerInfoProvider, flagEnabled(provider.flagKey), provider.isEligible(game) else { return }
        if let known = playerInfoOutcomes[game.id],
           now().timeIntervalSince(known.at) < (known.info == nil ? 30 * 60 : 6 * 3600) {
            playerInfo = known.info
            playerInfoLookedUpGameID = game.id
            return
        }
        let token = UUID()
        playerInfoToken = token
        playerInfoLoadingGameID = game.id
        defer { if playerInfoToken == token { playerInfoLoadingGameID = nil } }
        let result = await provider.playerInfo(for: game)
        guard playerInfoToken == token, !Task.isCancelled else { return }
        KyroLifecycleJournal.record("sports", "player_info_lookup",
                                    "league=\(game.league.rawValue) status=\(game.status) -> \(result.map { "found rank=\($0.away.rank != nil)/\($0.home.rank != nil) recent=\($0.away.recent.count)/\($0.home.recent.count)" } ?? "none")")
        if playerInfoOutcomes.count >= 32 { playerInfoOutcomes.removeAll() }
        playerInfoOutcomes[game.id] = (result, now())
        playerInfo = result
        playerInfoLookedUpGameID = game.id
    }

    /// Player headlines from tennis sources, for the News tab of the selected tennis event only.
    func loadSupplementalNews(for game: KyroSportsGame) async {
        if supplementalNews?.gameID != game.id { supplementalNews = nil }
        guard let provider = newsProvider, flagEnabled(provider.flagKey), provider.isEligible(game) else { return }
        if let known = newsOutcomes[game.id], now().timeIntervalSince(known.at) < 20 * 60 {
            supplementalNews = known.news
            return
        }
        let token = UUID()
        newsToken = token
        let result = await provider.supplementalNews(for: game)
        guard newsToken == token, !Task.isCancelled else { return }
        if newsOutcomes.count >= 32 { newsOutcomes.removeAll() }
        newsOutcomes[game.id] = (result, now())
        supplementalNews = result
    }

    private func hasBaseDetails(for game: KyroSportsGame) -> Bool {
        if game.league == .atp || game.league == .wta { return true }
        return details?.gameID == game.id
    }

    func load(for game: KyroSportsGame, force: Bool = false) async {
        let statusKind = Self.statusKind(game.status)
        if !force, details?.gameID == game.id, let loadedAt, loadedStatusKind == statusKind,
           now().timeIntervalSince(loadedAt) < freshness(for: game) {
            return
        }
        if !force, let memo = recent[game.id], memo.statusKind == statusKind,
           now().timeIntervalSince(memo.at) < freshness(for: game) {
            loadToken = UUID()
            details = memo.details
            loadedAt = memo.at
            loadedStatusKind = statusKind
            phase = .loaded
            return
        }
        let token = UUID()
        loadToken = token
        if details?.gameID != game.id { details = nil }
        phase = .loading
        KyroPerformanceDiagnostics.event("Sports detail load", .sportsDetailLoad)
        let interval = KyroPerformanceDiagnostics.begin("Sports detail load", .sportsDetailLoad)
        defer { KyroPerformanceDiagnostics.end(interval) }
        do {
            let result = try await client.fetchDetails(for: game)
            guard loadToken == token else { return }
            let at = now()
            details = result
            loadedAt = at
            loadedStatusKind = statusKind
            phase = .loaded
            remember(result, at: at, statusKind: statusKind)
        } catch let error as KyroSportsEventDetailError {
            guard loadToken == token else { return }
            // A cancelled request with nothing loaded must not leave a spinner that no later
            // event will clear; the next visible task retries it.
            phase = error == .cancelled ? (details == nil ? .idle : .loaded) : .failed(error)
        } catch {
            guard loadToken == token else { return }
            phase = .failed(.unavailable)
        }
    }

    private func remember(_ result: KyroSportsEventDetails, at: Date, statusKind: Int) {
        recent[result.gameID] = (result, at, statusKind)
        while recent.count > Self.recentLimit,
              let oldest = recent.min(by: { $0.value.at < $1.value.at })?.key {
            recent[oldest] = nil
        }
    }

    nonisolated static func statusKind(_ status: KyroGameStatus) -> Int {
        status.isLive ? 1 : (status.isFinal ? 2 : 0)
    }

    private func freshness(for game: KyroSportsGame) -> TimeInterval {
        if game.status.isLive { return 20 }
        if game.status.isFinal { return 60 * 60 }
        return 5 * 60
    }

    /// What restarts the Game/Stats/News detail task: the event, the tab, and a change between
    /// scheduled, live and final. The clock and score are deliberately absent.
    struct LoadKey: Hashable {
        let gameID: KyroGameID
        let tab: String
        let statusKind: Int

        init(game: KyroSportsGame, tab: String) {
            gameID = game.id
            self.tab = tab
            statusKind = KyroSportsEventDetailStore.statusKind(game.status)
        }
    }

    static let liveRefreshInterval: Duration = .seconds(30)

    /// Loads the event once and, while it is live, again every `liveRefreshInterval` until the
    /// calling task is cancelled (the tab or the event changed, or the hub left the screen).
    func keepCurrent(for game: KyroSportsGame, sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async {
        await load(for: game)
        guard game.status.isLive else { return }
        while !Task.isCancelled {
            do { try await sleep(Self.liveRefreshInterval) } catch { return }
            guard !Task.isCancelled else { return }
            await load(for: game)
        }
    }

    /// What the empty area of a Game/Stats/News section shows. Once this event's details have
    /// loaded, a later failed or in-flight refresh keeps the loaded answer instead of replacing it
    /// with an error or a spinner.
    static func displayPhase(phase: Phase, hasDetailsForEvent: Bool) -> Phase {
        guard hasDetailsForEvent else { return phase }
        if case .failed(.unsupportedLeague) = phase { return phase }
        return .loaded
    }
}
