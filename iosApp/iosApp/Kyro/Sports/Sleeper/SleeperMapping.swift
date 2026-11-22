import Foundation

// Maps Sleeper's undocumented wire shapes into Kyro's provider-independent
// models. Every mapping is total: a field Kyro cannot use becomes nil, and a
// game missing identity is dropped rather than failing the whole response.

enum SleeperMapping {
    static let providerName = "sleeper"

    // MARK: Teams

    static func teams(from wire: [SleeperTeam], league: KyroSportLeague) -> [String: KyroSportsTeam] {
        var byAbbreviation: [String: KyroSportsTeam] = [:]
        for entry in wire {
            guard let abbreviation = entry.team?.uppercased(), !abbreviation.isEmpty else { continue }
            let metadata = entry.metadata
            let fullName = metadata?.fullName?.trimmingCharacters(in: .whitespaces)
            // Sleeper's `name` field is the nickname ("49ers") and `city` is the
            // location; `full_name` carries both. Prefer the split fields, then
            // fall back to splitting the full name, then to the abbreviation.
            let nickname: String
            let location: String?
            if let fullName, let city = metadata?.city, fullName.hasPrefix(city) {
                nickname = String(fullName.dropFirst(city.count)).trimmingCharacters(in: .whitespaces)
                location = city
            } else if let fullName, !fullName.isEmpty {
                nickname = fullName
                location = nil
            } else {
                nickname = abbreviation
                location = nil
            }

            byAbbreviation[abbreviation] = KyroSportsTeam(
                id: teamID(abbreviation: abbreviation, league: league),
                league: league,
                abbreviation: abbreviation,
                nickname: nickname,
                location: location,
                logoURL: logoURL(abbreviation: abbreviation, league: league),
                primaryColorHex: metadata?.color1,
                conference: metadata?.conference,
                division: metadata?.division
            )
        }
        return byAbbreviation
    }

    static func teamID(abbreviation: String, league: KyroSportLeague) -> String {
        "\(providerName).\(league.rawValue).\(abbreviation.uppercased())"
    }

    /// Sleeper's CDN serves team logos by lowercase abbreviation. Verified 200
    /// on 2026-11-06 for nfl, nba, nhl, mlb and cfb.
    static func logoURL(abbreviation: String, league: KyroSportLeague) -> URL? {
        let key = sleeperSportKey(for: league)
        let slug = abbreviation.lowercased()
        return URL(string: "https://sleepercdn.com/images/team_logos/\(key)/\(slug).png")
    }

    /// The sport key Sleeper's undocumented endpoints actually use. College
    /// football is `cfb`, not `ncaaf` (`/v1/state/ncaaf` returns `null`).
    static func sleeperSportKey(for league: KyroSportLeague) -> String {
        switch league {
        case .nfl: "nfl"
        case .nba: "nba"
        case .collegeFootball: "cfb"
        case .collegeBasketballMen, .collegeBasketballWomen: ""
        case .mlb: "mlb"
        case .nhl: "nhl"
        case .atp, .wta: ""
        case .soccer: ""
        }
    }

    // MARK: Status

    /// Map a Sleeper top-level `status` plus its metadata flags onto Kyro's
    /// lifecycle. A cancelled or postponed game is identified by metadata even
    /// when the top-level status still reads `pre_game`.
    static func status(
        rawStatus: String?,
        isInProgress: Bool?,
        hasStarted: Bool?,
        isOver: Bool?,
        canceled: Bool?
    ) -> KyroGameStatus {
        if canceled == true { return .canceled }
        if isOver == true { return .final }
        if isInProgress == true { return .live }

        switch rawStatus?.lowercased() {
        case "complete", "final", "closed", "post_game", "postgame":
            return .final
        case "in_progress", "inprogress", "live", "active":
            return .live
        case "pre_game", "pregame", "scheduled", "created", "pre":
            // `has_started` disambiguates a game whose status has not flipped.
            if hasStarted == true { return .live }
            return .scheduled
        case "postponed", "delayed":
            return .postponed
        case "suspended":
            return .suspended
        case "canceled", "cancelled":
            return .canceled
        case let other?:
            return .unknown(other)
        case nil:
            // No status at all: fall back to the flags we do have.
            if hasStarted == true { return .live }
            return .unknown("")
        }
    }

    // MARK: Periods

    /// Build the per-period table for an NFL game. Only quarters Sleeper
    /// actually reported are emitted, so a game in the second quarter does not
    /// draw Q3 and Q4 as blanks.
    static func nflPeriods(
        for metadata: SleeperScoreGame.Metadata?,
        status: KyroGameStatus
    ) -> [KyroGamePeriod] {
        guard let metadata else { return [] }
        // Sleeper pads unplayed quarters and overtime with zeros rather than
        // omitting them, so presence alone is not evidence a period was played.
        // A game that has not kicked off reports no periods at all.
        guard status.isLive || status.isFinal else { return [] }
        // (index, home, away). Sleeper's quarter keys are the source of the
        // score; `quarter_num`/`quarter` describe the clock, not the table.
        let quarters: [(String, String, Int?, Int?)] = [
            ("q1", "Q1", metadata.homeScoreQuarter1, metadata.awayScoreQuarter1),
            ("q2", "Q2", metadata.homeScoreQuarter2, metadata.awayScoreQuarter2),
            ("q3", "Q3", metadata.homeScoreQuarter3, metadata.awayScoreQuarter3),
            ("q4", "Q4", metadata.homeScoreQuarter4, metadata.awayScoreQuarter4)
        ]
        var periods = quarters
            .filter { $0.2 != nil || $0.3 != nil }
            .map { KyroGamePeriod(id: $0.0, label: $0.1, homeScore: $0.2, awayScore: $0.3) }

        // Sleeper sends `*_score_overtime: 0` on games that never reached OT,
        // so require an explicit overtime flag or a nonzero overtime score.
        let overtimePoints = (metadata.homeScoreOvertime ?? 0) + (metadata.awayScoreOvertime ?? 0)
        if metadata.isOvertime == true || overtimePoints > 0 {
            periods.append(KyroGamePeriod(
                id: "ot",
                label: "OT",
                homeScore: metadata.homeScoreOvertime,
                awayScore: metadata.awayScoreOvertime
            ))
        }
        return periods
    }

    /// The clock/period line, e.g. `Q3 4:32`, `Halftime`, `Final`.
    static func statusDetail(for metadata: SleeperScoreGame.Metadata?, status: KyroGameStatus) -> String? {
        guard let metadata else { return nil }
        let quarter = metadata.quarter?.trimmingCharacters(in: .whitespaces) ?? ""
        let clock = metadata.timeRemaining?.trimmingCharacters(in: .whitespaces) ?? ""

        switch status {
        case .final:
            return "Final"
        case .postponed:
            return "Postponed"
        case .canceled:
            return "Canceled"
        case .suspended:
            return "Suspended"
        case .live:
            // Sleeper reports `quarter` as "Q1".."Q4", "F", or "" and
            // `quarter_num` separately; the string is the display-ready one.
            if quarter.isEmpty { return "Live" }
            if clock.isEmpty || clock == "00:00" { return quarter }
            return "\(quarter) \(clock)"
        case .scheduled, .unknown:
            return nil
        }
    }

    // MARK: Games

    /// A game from a `/scores` entry. Returns nil when the entry lacks an id or
    /// either team, because such a row cannot be keyed or titled.
    static func game(
        fromScore entry: SleeperScoreGame,
        league: KyroSportLeague,
        season: Int? = nil,
        seasonType: KyroSportsSeasonType = .regular,
        teamsByAbbreviation: [String: KyroSportsTeam]
    ) -> KyroSportsGame? {
        guard let rawID = entry.gameID, !rawID.isEmpty else { return nil }
        let metadata = entry.metadata
        guard let homeAbbreviation = metadata?.homeTeam?.uppercased(),
              let awayAbbreviation = metadata?.awayTeam?.uppercased(),
              !homeAbbreviation.isEmpty, !awayAbbreviation.isEmpty else { return nil }

        let status = status(
            rawStatus: entry.status,
            isInProgress: metadata?.isInProgress,
            hasStarted: metadata?.hasStarted,
            isOver: metadata?.isOver,
            canceled: metadata?.canceled
        )

        let home = KyroGameTeam(
            team: teamsByAbbreviation[homeAbbreviation]
                ?? .placeholder(abbreviation: homeAbbreviation, league: league),
            score: metadata?.homeScore,
            record: metadata?.homeRecord
        )
        let away = KyroGameTeam(
            team: teamsByAbbreviation[awayAbbreviation]
                ?? .placeholder(abbreviation: awayAbbreviation, league: league),
            score: metadata?.awayScore,
            record: metadata?.awayRecord
        )

        return KyroSportsGame(
            id: KyroGameID(provider: providerName, league: league, rawID: rawID),
            league: league,
            season: season,
            seasonType: seasonType,
            week: entry.week,
            startTime: startDate(isoString: metadata?.dateTime, millis: entry.startTimeMillis, day: entry.date),
            status: status,
            statusDetail: statusDetail(for: metadata, status: status),
            home: home,
            away: away,
            periods: periods(for: league, metadata: metadata, status: status),
            venue: metadata?.stadiumDetails?.name ?? metadata?.venue?.name,
            broadcast: metadata?.channel
        )
    }

    /// A game from a `/schedule` entry, which carries identity and kickoff but
    /// no score. Used for the upcoming list and to fill weeks whose scores are
    /// unavailable.
    static func game(
        fromSchedule entry: SleeperScheduleGame,
        league: KyroSportLeague,
        season: Int? = nil,
        seasonType: KyroSportsSeasonType = .regular,
        teamsByAbbreviation: [String: KyroSportsTeam]
    ) -> KyroSportsGame? {
        guard let rawID = entry.gameID, !rawID.isEmpty else { return nil }
        guard let homeAbbreviation = entry.home?.uppercased(),
              let awayAbbreviation = entry.away?.uppercased(),
              !homeAbbreviation.isEmpty, !awayAbbreviation.isEmpty else { return nil }

        return KyroSportsGame(
            id: KyroGameID(provider: providerName, league: league, rawID: rawID),
            league: league,
            season: season,
            seasonType: seasonType,
            week: entry.week,
            // The season schedule has a date label, not a kickoff instant.
            // Midnight UTC would invent a time and shift the game to the
            // previous local calendar day across North America.
            startTime: nil,
            status: status(rawStatus: entry.status, isInProgress: nil, hasStarted: nil,
                           isOver: nil, canceled: nil),
            statusDetail: nil,
            home: KyroGameTeam(
                team: teamsByAbbreviation[homeAbbreviation]
                    ?? .placeholder(abbreviation: homeAbbreviation, league: league)
            ),
            away: KyroGameTeam(
                team: teamsByAbbreviation[awayAbbreviation]
                    ?? .placeholder(abbreviation: awayAbbreviation, league: league)
            ),
            periods: []
        )
    }

    private static func periods(
        for league: KyroSportLeague,
        metadata: SleeperScoreGame.Metadata?,
        status: KyroGameStatus
    ) -> [KyroGamePeriod] {
        // Only NFL period scoring is implemented in S2A. Other leagues return
        // an empty table rather than a guess.
        league == .nfl ? nflPeriods(for: metadata, status: status) : []
    }

    // MARK: Dates

    /// Sleeper score records report a kickoff as ISO-8601 and epoch millis.
    /// A date-only field is a calendar label, not a kickoff instant, so it is
    /// intentionally ignored rather than converted to a manufactured midnight.
    static func startDate(isoString: String?, millis: Double?, day: String?) -> Date? {
        if let isoString, let date = parseISO(isoString) { return date }
        if let millis, millis > 0 {
            return Date(timeIntervalSince1970: millis / 1000)
        }
        _ = day
        return nil
    }

    private static func parseISO(_ string: String) -> Date? {
        if let date = isoFormatter.date(from: string) { return date }
        if let date = isoFormatterNoSeconds.date(from: string) { return date }
        return nil
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let isoFormatterNoSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

}
