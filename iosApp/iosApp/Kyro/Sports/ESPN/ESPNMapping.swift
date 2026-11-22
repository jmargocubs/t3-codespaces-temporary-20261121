import Foundation

enum ESPNMapping {
    static let providerName = "espn"

    static func path(for league: KyroSportLeague) -> String {
        switch league {
        case .nfl: "/apis/site/v2/sports/football/nfl/scoreboard"
        case .nba: "/apis/site/v2/sports/basketball/nba/scoreboard"
        case .mlb: "/apis/site/v2/sports/baseball/mlb/scoreboard"
        case .nhl: "/apis/site/v2/sports/hockey/nhl/scoreboard"
        case .collegeFootball: "/apis/site/v2/sports/football/college-football/scoreboard"
        case .collegeBasketballMen: "/apis/site/v2/sports/basketball/mens-college-basketball/scoreboard"
        case .collegeBasketballWomen: "/apis/site/v2/sports/basketball/womens-college-basketball/scoreboard"
        case .atp: "/apis/site/v2/sports/tennis/atp/scoreboard"
        case .wta: "/apis/site/v2/sports/tennis/wta/scoreboard"
        case .soccer: "/apis/site/v2/sports/soccer/eng.1/scoreboard"
        }
    }

    static func path(for league: KyroSportLeague, competitionKey: String?) -> String {
        guard league == .soccer, let key = competitionKey, !key.isEmpty else {
            return path(for: league)
        }
        return "/apis/site/v2/sports/soccer/\(key)/scoreboard"
    }

    static func game(
        from event: ESPNScoreboardResponse.Event,
        league: KyroSportLeague,
        competitionKey: String? = nil,
        competitionName: String? = nil
    ) -> KyroSportsGame? {
        guard let competition = event.competitions?.first else { return nil }
        let rawID = nonempty(event.id) ?? nonempty(competition.id)
        guard let rawID else { return nil }

        let competitors = competition.competitors ?? []
        guard let homeWire = competitors.first(where: { $0.homeAway?.lowercased() == "home" }),
              let awayWire = competitors.first(where: { $0.homeAway?.lowercased() == "away" }),
              let homeTeam = team(from: homeWire, league: league),
              let awayTeam = team(from: awayWire, league: league) else {
            return nil
        }

        let wireStatus = competition.status ?? event.status
        let status = status(from: wireStatus)
        let seasonType = seasonType(from: event.season)
        let includesScore = status.isLive || status.isFinal || status == .postponed
        let home = KyroGameTeam(
            team: homeTeam,
            score: includesScore ? integer(from: homeWire.score?.stringValue) : nil,
            record: overallRecord(from: homeWire.records ?? []),
            rank: pollRank(from: homeWire.curatedRank) ?? collegeRank(homeWire.curatedRank, league: league)
        )
        let away = KyroGameTeam(
            team: awayTeam,
            score: includesScore ? integer(from: awayWire.score?.stringValue) : nil,
            record: overallRecord(from: awayWire.records ?? []),
            rank: pollRank(from: awayWire.curatedRank) ?? collegeRank(awayWire.curatedRank, league: league)
        )

        return KyroSportsGame(
            id: KyroGameID(provider: providerName, league: league, rawID: rawID),
            league: league,
            season: event.season?.year,
            seasonType: seasonType,
            week: event.week?.number,
            startTime: startDate(competition.date ?? event.date),
            status: status,
            statusDetail: statusDetail(from: wireStatus, status: status),
            home: home,
            away: away,
            periods: periods(
                league: league,
                seasonType: seasonType,
                home: homeWire.linescores ?? [],
                away: awayWire.linescores ?? [],
                status: status
            ),
            venue: nonempty(competition.venue?.fullName),
            broadcast: broadcast(from: competition.broadcasts ?? []),
            note: nonempty(competitionName) ?? nonempty(competition.altGameNote)
                ?? competition.notes?.lazy.compactMap { nonempty($0.headline) }.first,
            situation: situation(from: competition.situation, league: league, status: status),
            competitionKey: competitionKey
        )
    }

    /// One tennis match node before mapping, with the draw it came from.
    struct TennisNode {
        let competition: ESPNScoreboardResponse.Competition
        let tournament: String?
        let drawSlug: String?
        let drawName: String?
    }

    /// Every match node in a tennis event. Live ESPN payloads put matches in
    /// `groupings[].competitions` (one grouping per draw); synthetic and
    /// older payloads used `competitions` or nested `groups`. All three are
    /// read; nesting is bounded by the payload itself.
    static func tennisNodes(from event: ESPNScoreboardResponse.Event) -> [TennisNode] {
        var nodes: [TennisNode] = []
        let eventTournament = nonempty(event.name) ?? nonempty(event.shortName)
        func append(_ competitions: [ESPNScoreboardResponse.Competition]?, tournament: String?,
                    slug: String?, draw: String?) {
            for competition in competitions ?? [] {
                if let nested = competition.competitions, !nested.isEmpty {
                    append(nested, tournament: tournament ?? competition.name ?? competition.shortName,
                           slug: slug, draw: draw)
                }
                if (competition.competitors?.count ?? 0) >= 2 {
                    nodes.append(TennisNode(competition: competition, tournament: tournament,
                                            drawSlug: slug, drawName: draw))
                }
            }
        }
        append(event.competitions, tournament: eventTournament, slug: nil, draw: nil)
        for grouping in event.groupings ?? [] {
            append(grouping.competitions, tournament: eventTournament,
                   slug: nonempty(grouping.grouping?.slug), draw: nonempty(grouping.grouping?.displayName))
        }
        func appendGroups(_ groups: [ESPNScoreboardResponse.Group]?) {
            for group in groups ?? [] {
                let tournament = eventTournament ?? nonempty(group.name) ?? nonempty(group.abbreviation)
                append(group.competitions, tournament: tournament, slug: nil, draw: nil)
                appendGroups(group.groups)
            }
        }
        appendGroups(event.groups)
        return nodes
    }

    /// Whether a draw belongs to `league`'s singles. `nil` means the draw
    /// labels do not say, and the caller falls back to weaker evidence.
    /// Grand Slams appear on both the ATP and WTA feeds with all five draws,
    /// so the draw, not the event name, decides the tour.
    static func tennisDrawIsSingles(slug: String?, name: String?, league: KyroSportLeague) -> Bool? {
        let text = normalized([slug, name].compactMap { $0 }.joined(separator: " "))
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        guard !text.isEmpty else { return nil }
        if text.contains("double") || text.contains("mixed") { return false }
        let women = text.contains("women") || text.contains("ladies") || text.contains("girls")
        let men = !women && (text.contains("men") || text.contains("boys"))
        if text.contains("boys") || text.contains("girls") || text.contains("junior")
            || text.contains("wheelchair") || text.contains("legend") {
            return false
        }
        if women { return league == .wta }
        if men { return league == .atp }
        return nil
    }

    /// Tennis scoreboards model a tournament as an event and put matches in
    /// per-draw groupings. Only the league's singles draw is mapped; doubles,
    /// mixed and the other tour's draws are skipped, and TBD-vs-TBD bracket
    /// slots are dropped. Event and round labels are kept as context.
    static func tennisGames(
        from event: ESPNScoreboardResponse.Event,
        league: KyroSportLeague
    ) -> [KyroSportsGame] {
        tennisMapping(from: event, league: league).games
    }

    /// `unreadable` counts singles matches whose players could not be read,
    /// so the provider can tell "nothing scheduled" from "could not read".
    static func tennisMapping(
        from event: ESPNScoreboardResponse.Event,
        league: KyroSportLeague
    ) -> (games: [KyroSportsGame], unreadable: Int) {
        guard league == .atp || league == .wta else { return ([], 0) }
        var seen = Set<String>()
        var unreadable = 0
        var games: [KyroSportsGame] = []
        for node in tennisNodes(from: event) {
            let competition = node.competition
            let competitors = competition.competitors ?? []
            let typeText = normalized([competition.type?.text, competition.type?.slug]
                .compactMap { $0 }.joined(separator: " "))
            let drawDecision = tennisDrawIsSingles(slug: node.drawSlug, name: node.drawName, league: league)
                ?? tennisDrawIsSingles(slug: competition.type?.slug, name: competition.type?.text, league: league)
            if drawDecision == false { continue }
            if drawDecision == nil {
                // No draw label: fall back to the event/tournament names, and
                // to the doubles shape (ESPN doubles sides are rosters).
                let tourText = normalized([event.name, event.shortName, node.tournament, typeText]
                    .compactMap { $0 }.joined(separator: " "))
                let opposingTour = (league == .atp && tourText.contains("wta"))
                    || (league == .wta && tourText.contains("atp"))
                if opposingTour || typeText.contains("double") { continue }
            }
            guard competitors.count == 2,
                  competitors.allSatisfy({ $0.athlete != nil || $0.player != nil }) else { continue }

            let rawID = nonempty(competition.id) ?? {
                let ids = competitors.compactMap { nonempty($0.id) }
                return ids.isEmpty ? nil : ids.joined(separator: "-")
            }()
            guard let rawID, seen.insert(rawID).inserted else { continue }
            guard let away = tennisPlayer(from: competitors[0], league: league),
                  let home = tennisPlayer(from: competitors[1], league: league) else {
                unreadable += 1
                continue
            }
            if isTennisPlaceholder(competitors[0], away), isTennisPlaceholder(competitors[1], home) { continue }

            let wireStatus = competition.status
            let status = status(from: wireStatus)
            let timeValid = competition.timeValid ?? wireStatus?.timeValid ?? true
            let rawStart = startDate(competition.date ?? event.date)
            let start = timeValid ? rawStart : rawStart.map(scheduledDayAnchor)
            let detail: String?
            if status.isScheduled {
                // ESPN's scheduled text is US Eastern ("11/8 - 9:00 AM EST");
                // the row shows the local time instead.
                detail = timeValid ? nil : "Time TBD"
            } else {
                detail = nonempty(wireStatus?.type?.shortDetail) ?? nonempty(wireStatus?.type?.detail)
                    ?? nonempty(competition.notes?.compactMap { $0.headline }.first)
                    ?? statusDetail(from: wireStatus, status: status)
            }
            let round = nonempty(competition.round?.displayName) ?? nonempty(competition.name)
                ?? nonempty(competition.shortName)
            games.append(KyroSportsGame(
                id: KyroGameID(provider: providerName, league: league, rawID: rawID), league: league,
                season: event.season?.year, seasonType: .regular, week: nil, startTime: start,
                status: status, statusDetail: detail, home: home, away: away,
                periods: tennisPeriods(away: competitors[0].linescores ?? [], home: competitors[1].linescores ?? []),
                venue: nonempty(competition.venue?.fullName), broadcast: broadcast(from: competition.broadcasts ?? []),
                note: node.tournament, situation: nil, tournament: node.tournament, round: round,
                isSingles: true, isStartTimeTBD: !timeValid))
        }
        return (games, unreadable)
    }

    /// ESPN sends date-only tennis slots as midnight US Eastern
    /// (`2026-11-09T05:00Z`). Anchor them at noon UTC on that calendar day so
    /// every timezone from UTC-11 to UTC+11 files them under the same day.
    static func scheduledDayAnchor(_ date: Date) -> Date {
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = TimeZone(identifier: "America/New_York") ?? TimeZone(secondsFromGMT: -5 * 3600)!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var components = eastern.dateComponents([.year, .month, .day], from: date)
        components.hour = 12
        return utc.date(from: components) ?? date
    }

    private static func isTennisPlaceholder(
        _ competitor: ESPNScoreboardResponse.Competitor,
        _ side: KyroGameTeam
    ) -> Bool {
        if competitor.id?.hasPrefix("-") == true { return true }
        return side.team.nickname.uppercased() == "TBD"
    }

    private static func tennisPlayer(
        from competitor: ESPNScoreboardResponse.Competitor,
        league: KyroSportLeague
    ) -> KyroGameTeam? {
        let athlete = competitor.athlete ?? competitor.player
        let name = nonempty(athlete?.displayName) ?? nonempty(athlete?.fullName)
            ?? nonempty(athlete?.shortName) ?? nonempty(competitor.team?.displayName)
            ?? nonempty(competitor.team?.name)
        guard let name else { return nil }
        let id = nonempty(athlete?.id) ?? nonempty(competitor.id) ?? name
        let abbreviation = nonempty(athlete?.abbreviation)?.uppercased() ?? String(name.prefix(3)).uppercased()
        let country = athlete?.country ?? competitor.country
        let countryCode = nonempty(country?.code) ?? nonempty(country?.abbreviation)
            ?? nonempty(athlete?.flag?.code) ?? nonempty(competitor.flag?.code)
        let flagURL = athlete?.flag?.imageURL ?? competitor.flag?.imageURL
        let shortName = nonempty(athlete?.shortName)
        let team = KyroSportsTeam(id: "\(providerName).\(league.rawValue).\(id)", league: league,
                                  abbreviation: abbreviation, nickname: name, countryCode: countryCode,
                                  flagURL: flagURL, alternateNames: shortName.map { [$0] } ?? [])
        let rank = competitor.curatedRank?.current.flatMap { (1...5000).contains($0) ? $0 : nil }
        return KyroGameTeam(team: team, score: integer(from: competitor.score?.stringValue),
                            rank: rank, isWinner: competitor.winner)
    }

    private static func tennisPeriods(
        away: [ESPNScoreboardResponse.LineScore],
        home: [ESPNScoreboardResponse.LineScore]
    ) -> [KyroGamePeriod] {
        let count = max(away.count, home.count)
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            let a = index < away.count ? integer(from: away[index].value, display: away[index].displayValue) : nil
            let h = index < home.count ? integer(from: home[index].value, display: home[index].displayValue) : nil
            return KyroGamePeriod(id: "set\(index + 1)", label: "Set \(index + 1)", homeScore: h, awayScore: a)
        }
    }

    static func status(from wire: ESPNScoreboardResponse.Status?) -> KyroGameStatus {
        guard let type = wire?.type else { return .unknown("") }
        let name = type.name?.uppercased() ?? ""
        let description = type.description?.uppercased() ?? ""
        let state = type.state?.lowercased()

        if name.contains("CANCEL") || description.contains("CANCEL") { return .canceled }
        if name.contains("POSTPON") || description.contains("POSTPON") { return .postponed }
        if name.contains("SUSPEND") || description.contains("SUSPEND") { return .suspended }
        if type.completed == true || state == "post" || name.contains("FINAL") { return .final }
        if state == "in" || name.contains("IN_PROGRESS") { return .live }
        if state == "pre" || name.contains("SCHEDULED") { return .scheduled }
        return .unknown(type.name ?? type.description ?? "")
    }

    static func seasonType(from season: ESPNScoreboardResponse.Season?) -> KyroSportsSeasonType {
        switch season?.type {
        case 1: .preseason
        case 2: .regular
        case 3: .postseason
        default:
            switch season?.slug?.lowercased() {
            case "preseason": .preseason
            case "regular-season", "regular": .regular
            case "post-season", "postseason": .postseason
            default: .unknown
            }
        }
    }

    static func startDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = isoFormatter.date(from: value) { return date }
        if let date = isoFormatterWithFractionalSeconds.date(from: value) { return date }
        // ESPN's own format omits seconds: `2026-11-07T17:00Z`.
        return minutePrecisionFormatter.date(from: value)
    }

    private static let minutePrecisionFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mmXXXXX"
        return formatter
    }()

    private static func team(
        from competitor: ESPNScoreboardResponse.Competitor,
        league: KyroSportLeague
    ) -> KyroSportsTeam? {
        guard let wire = competitor.team,
              let providerID = nonempty(wire.id) ?? nonempty(competitor.id),
              let abbreviation = nonempty(wire.abbreviation)?.uppercased() else {
            return nil
        }
        let location = nonempty(wire.location)
        let nickname = nonempty(wire.name)
            ?? nonempty(wire.shortDisplayName)
            ?? nonempty(wire.displayName)
            ?? abbreviation
        // ESPN's own alternate names ("Jax State", "Sam Houston") feed stream
        // matching; the canonical location + nickname is already modelled.
        var alternates: [String] = []
        for name in [wire.displayName, wire.shortDisplayName].compactMap(nonempty)
        where !alternates.contains(name) {
            alternates.append(name)
        }
        return KyroSportsTeam(
            id: "\(providerName).\(league.rawValue).\(providerID)",
            league: league,
            abbreviation: abbreviation,
            nickname: nickname,
            location: location,
            logoURL: nonempty(wire.logo).flatMap(URL.init(string:)),
            darkLogoURL: nonempty(wire.logoDark).flatMap(URL.init(string:)),
            primaryColorHex: nonempty(wire.color),
            alternateColorHex: nonempty(wire.alternateColor),
            conference: wire.groups?.first.flatMap { nonempty($0.name) }
                ?? collegeConference(wire.standingSummary, league: league),
            alternateNames: alternates
        )
    }

    private static func collegeRank(_ rank: ESPNScoreboardResponse.Rank?, league: KyroSportLeague) -> Int? {
        guard league == .collegeBasketballMen || league == .collegeBasketballWomen,
              let value = rank?.current, (1...25).contains(value) else { return nil }
        return value
    }

    private static func collegeConference(_ summary: String?, league: KyroSportLeague) -> String? {
        guard league == .collegeBasketballMen || league == .collegeBasketballWomen,
              let summary, let range = summary.range(of: #"(?i)\bin\s+(.+)$"#, options: .regularExpression) else { return nil }
        let value = String(summary[range]).replacingOccurrences(of: #"(?i)^in\s+"#, with: "", options: .regularExpression)
        return nonempty(value)
    }

    private static func statusDetail(
        from wire: ESPNScoreboardResponse.Status?,
        status: KyroGameStatus
    ) -> String? {
        switch status {
        case .scheduled: return nil
        case .canceled: return "Canceled"
        case .postponed: return "Postponed"
        case .suspended: return "Suspended"
        case .live:
            return nonempty(wire?.type?.shortDetail)
                ?? nonempty(wire?.type?.detail)
                ?? clockDetail(from: wire)
                ?? "Live"
        case .final:
            return nonempty(wire?.type?.shortDetail)
                ?? nonempty(wire?.type?.detail)
                ?? "Final"
        case .unknown:
            return nonempty(wire?.type?.shortDetail) ?? nonempty(wire?.type?.description)
        }
    }

    private static func clockDetail(from status: ESPNScoreboardResponse.Status?) -> String? {
        guard let period = status?.period else { return nonempty(status?.displayClock) }
        let clock = nonempty(status?.displayClock)
        return clock.map { "P\(period) \($0)" } ?? "P\(period)"
    }

    private static func periods(
        league: KyroSportLeague,
        seasonType: KyroSportsSeasonType,
        home: [ESPNScoreboardResponse.LineScore],
        away: [ESPNScoreboardResponse.LineScore],
        status: KyroGameStatus
    ) -> [KyroGamePeriod] {
        guard status.isLive || status.isFinal || status == .postponed else { return [] }
        var homeByPeriod: [Int: Int?] = [:]
        for line in home {
            guard let period = line.period else { continue }
            homeByPeriod[period] = integer(from: line.value, display: line.displayValue)
        }
        var awayByPeriod: [Int: Int?] = [:]
        for line in away {
            guard let period = line.period else { continue }
            awayByPeriod[period] = integer(from: line.value, display: line.displayValue)
        }
        return Set(homeByPeriod.keys).union(awayByPeriod.keys).sorted().map { period in
            KyroGamePeriod(
                id: periodID(league: league, seasonType: seasonType, period: period),
                label: periodLabel(league: league, seasonType: seasonType, period: period),
                homeScore: homeByPeriod[period] ?? nil,
                awayScore: awayByPeriod[period] ?? nil
            )
        }
    }

    /// NHL regular-season overtime is period 4 and the shootout is period 5.
    /// Playoff overtimes continue as 2OT, 3OT… and have no shootout.
    private static func nhlSuffix(period: Int, seasonType: KyroSportsSeasonType) -> (id: String, label: String) {
        if period <= 3 { return ("p\(period)", "P\(period)") }
        if seasonType == .postseason {
            let number = period - 3
            return number == 1 ? ("ot", "OT") : ("ot\(number)", "\(number)OT")
        }
        return period == 4 ? ("ot", "OT") : ("so", "SO")
    }

    private static func periodID(league: KyroSportLeague, seasonType: KyroSportsSeasonType, period: Int) -> String {
        switch league {
        case .mlb: "inning\(period)"
        case .nhl: nhlSuffix(period: period, seasonType: seasonType).id
        case .nfl, .nba, .collegeFootball, .collegeBasketballMen, .collegeBasketballWomen: period <= 4 ? "q\(period)" : "ot\(period - 4)"
        case .atp, .wta: "set\(period)"
        case .soccer: "half\(period)"
        }
    }

    private static func periodLabel(league: KyroSportLeague, seasonType: KyroSportsSeasonType, period: Int) -> String {
        switch league {
        case .mlb: return String(period)
        case .nhl: return nhlSuffix(period: period, seasonType: seasonType).label
        case .nfl, .collegeFootball, .nba, .collegeBasketballMen, .collegeBasketballWomen:
            return period <= 4 ? "Q\(period)" : period == 5 ? "OT" : "\(period - 4)OT"
        case .atp, .wta: return "Set \(period)"
        case .soccer: return period == 1 ? "1H" : period == 2 ? "2H" : "ET\(period - 2)"
        }
    }

    private static func situation(
        from wire: ESPNScoreboardResponse.Situation?,
        league: KyroSportLeague,
        status: KyroGameStatus
    ) -> String? {
        guard league == .mlb, status.isLive, let outs = wire?.outs, (0...3).contains(outs) else {
            return nil
        }
        return outs == 1 ? "1 out" : "\(outs) outs"
    }

    private static func overallRecord(from records: [ESPNScoreboardResponse.Record]) -> String? {
        records.first {
            let type = $0.type?.lowercased()
            let name = $0.name?.lowercased()
            return type == "total" || type == "ytd" || name == "overall" || name == "ytd"
        }.flatMap { nonempty($0.summary) }
    }

    private static func pollRank(from rank: ESPNScoreboardResponse.Rank?) -> Int? {
        guard let current = rank?.current, (1...25).contains(current) else { return nil }
        return current
    }

    private static func broadcast(from broadcasts: [ESPNScoreboardResponse.Broadcast]) -> String? {
        broadcasts.lazy.compactMap { broadcast in
            let names = (broadcast.names ?? []).compactMap(nonempty)
            return names.isEmpty ? nil : names.joined(separator: ", ")
        }.first
    }

    private static func integer(from value: String?) -> Int? {
        guard let value, let number = Double(value), number.isFinite,
              number.rounded() == number else { return nil }
        return Int(number)
    }

    private static func integer(from value: Double?, display: String?) -> Int? {
        if let value, value.isFinite, value.rounded() == value { return Int(value) }
        return integer(from: display)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let isoFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
