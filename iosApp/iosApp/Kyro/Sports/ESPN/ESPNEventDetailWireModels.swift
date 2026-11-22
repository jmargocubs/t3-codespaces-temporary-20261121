import Foundation

/// The small, defensive subset of ESPN's event-summary and news payloads used
/// by Sports Hub. Optional fields keep one missing statistic from rejecting an
/// otherwise useful box score.
struct ESPNEventSummaryResponse: Decodable, Sendable {
    let header: Header?
    let boxscore: Boxscore?
    let article: Article?
    let news: News?
    let keyEvents: [KeyEvent]?
    let rosters: [Roster]?
    // Build 68: pregame blocks. Each is decoded leniently (a list element or block that does not
    // match is skipped), so a change in one of them never rejects the box score or the news.
    let gameInfo: ESPNLenient<GameInfo>?
    let lastFiveGames: ESPNLossyList<LastFive>?
    let seasonseries: ESPNLossyList<SeasonSeries>?
    let standings: ESPNLenient<Standings>?
    let leaders: ESPNLossyList<TeamLeaders>?
    let injuries: ESPNLossyList<TeamInjuries>?

    struct Header: Decodable, Sendable {
        let id: String?
        let competitions: [Competition]?
    }

    struct Competition: Decodable, Sendable {
        let id: String?
        let date: String?
        let competitors: [Competitor]?
        /// Build 68: the summary's own status, which decides what its statistics describe.
        let status: ESPNLenient<CompetitionStatus>?
    }

    struct CompetitionStatus: Decodable, Sendable {
        let type: StatusType?
    }

    struct StatusType: Decodable, Sendable {
        let state: String?
        let completed: Bool?
        let name: String?
    }

    struct Competitor: Decodable, Sendable {
        let id: String?
        let homeAway: String?
        let team: Team?
        /// Build 68: `total`, `home`, `road`, `vsconf` (and `points` for soccer) records.
        let record: ESPNLossyList<CompetitorRecord>?
    }

    struct CompetitorRecord: Decodable, Sendable {
        let type: String?
        let summary: String?
        let displayValue: String?
    }

    struct GameInfo: Decodable, Sendable {
        let venue: Venue?
    }

    struct Venue: Decodable, Sendable {
        let fullName: String?
        let address: VenueAddress?
    }

    struct VenueAddress: Decodable, Sendable {
        let city: String?
        let state: String?
        let country: String?
    }

    struct LastFive: Decodable, Sendable {
        let team: Team?
        let events: ESPNLossyList<LastFiveEvent>?
    }

    struct LastFiveEvent: Decodable, Sendable {
        let id: ESPNScalar?
        let gameDate: String?
        let gameResult: String?
        let atVs: String?
        let homeTeamId: ESPNScalar?
        let awayTeamId: ESPNScalar?
        let homeTeamScore: ESPNScalar?
        let awayTeamScore: ESPNScalar?
        let opponent: Team?
        let leagueName: String?
        let leagueAbbreviation: String?
    }

    struct SeasonSeries: Decodable, Sendable {
        let type: String?
        let title: String?
        let summary: String?
        let events: ESPNLossyList<SeriesEvent>?
    }

    struct SeriesEvent: Decodable, Sendable {
        let id: String?
        let date: String?
        let statusType: StatusType?
        let competitors: ESPNLossyList<SeriesCompetitor>?
    }

    struct SeriesCompetitor: Decodable, Sendable {
        let homeAway: String?
        let score: ESPNScalar?
        let winner: Bool?
        let team: Team?
    }

    struct Standings: Decodable, Sendable {
        let groups: ESPNLossyList<StandingsGroup>?
    }

    struct StandingsGroup: Decodable, Sendable {
        let header: String?
        let divisionHeader: String?
        let conferenceHeader: String?
        let standings: StandingsTable?
    }

    struct StandingsTable: Decodable, Sendable {
        let entries: ESPNLossyList<StandingsEntry>?
    }

    struct StandingsEntry: Decodable, Sendable {
        let team: String?
        let id: String?
        let stats: ESPNLossyList<StandingsStat>?
    }

    struct StandingsStat: Decodable, Sendable {
        let name: String?
        let abbreviation: String?
        let displayValue: String?
    }

    struct TeamLeaders: Decodable, Sendable {
        let team: Team?
        let leaders: ESPNLossyList<LeaderCategory>?
    }

    struct LeaderCategory: Decodable, Sendable {
        let name: String?
        let displayName: String?
        let leaders: ESPNLossyList<LeaderEntry>?
    }

    struct LeaderEntry: Decodable, Sendable {
        let displayValue: String?
        let athlete: Athlete?
    }

    struct TeamInjuries: Decodable, Sendable {
        let team: Team?
        let injuries: ESPNLossyList<InjuryEntry>?
    }

    struct InjuryEntry: Decodable, Sendable {
        let status: String?
        let athlete: Athlete?
        let details: InjuryDetails?
    }

    struct InjuryDetails: Decodable, Sendable {
        let type: String?
        let detail: String?
    }

    struct Team: Decodable, Sendable {
        let id: String?
        let abbreviation: String?
        let displayName: String?
        let shortDisplayName: String?
    }

    struct Boxscore: Decodable, Sendable {
        let teams: [TeamStatistics]?
        let players: [PlayerTeam]?
    }

    struct KeyEvent: Decodable, Sendable {
        let id: String?
        let type: EventType?
        let clock: EventClock?
        let team: EventTeam?
        let athletesInvolved: [EventAthlete]?
    }

    struct EventType: Decodable, Sendable { let text: String? }
    struct EventClock: Decodable, Sendable { let displayValue: String? }
    struct EventTeam: Decodable, Sendable { let id: String? }
    struct EventAthlete: Decodable, Sendable {
        let id: String?
        let displayName: String?
    }

    struct Roster: Decodable, Sendable {
        let team: Team?
        let roster: [RosterAthlete]?
    }

    struct RosterAthlete: Decodable, Sendable {
        let active: Bool?
        let starter: Bool?
        let didNotPlay: Bool?
        let athlete: Athlete?
        let position: Position?
        let stats: [RosterStatistic]?
    }

    struct RosterStatistic: Decodable, Sendable {
        let name: String?
        let displayName: String?
        let displayValue: String?
    }

    struct TeamStatistics: Decodable, Sendable {
        let team: Team?
        let homeAway: String?
        let statistics: [Statistic]?
    }

    struct Statistic: Decodable, Sendable {
        let name: String?
        let label: String?
        let displayName: String?
        let displayValue: ESPNScalar?
        /// MLB groups its team statistics (`batting`, `pitching`, `fielding`), each with its own
        /// list. Football, basketball, hockey and soccer use flat label/value entries.
        let stats: [NestedStatistic]?
    }

    struct NestedStatistic: Decodable, Sendable {
        let name: String?
        let abbreviation: String?
        let displayName: String?
        let displayValue: ESPNScalar?
    }

    struct PlayerTeam: Decodable, Sendable {
        let team: Team?
        let statistics: [PlayerStatGroup]?
    }

    struct PlayerStatGroup: Decodable, Sendable {
        let name: String?
        /// MLB names its player groups here (`batting`, `pitching`) and leaves `name` empty.
        let type: String?
        let displayName: String?
        let labels: [String]?
        let keys: [String]?
        let athletes: [PlayerLine]?
    }

    struct PlayerLine: Decodable, Sendable {
        let active: Bool?
        let athlete: Athlete?
        let starter: Bool?
        let didNotPlay: Bool?
        let stats: [ESPNScalar]?
    }

    struct Athlete: Decodable, Sendable {
        let id: String?
        let displayName: String?
        let shortName: String?
        let position: Position?
    }

    struct Position: Decodable, Sendable {
        let abbreviation: String?
        let displayName: String?
    }

    struct News: Decodable, Sendable {
        let articles: [Article]?
    }

    struct Article: Decodable, Sendable {
        let id: Int?
        /// `Preview`, `Recap`, `Story`, `Media`… Build 68 labels the event's own preview.
        let type: String?
        let headline: String?
        let published: String?
        let links: ArticleLinks?
        let categories: [Category]?
    }

    struct ArticleLinks: Decodable, Sendable {
        let web: WebLink?
    }

    struct WebLink: Decodable, Sendable {
        let href: String?
    }

    struct Category: Decodable, Sendable {
        let type: String?
        let team: CategoryTeam?
        /// Tennis articles are tagged with the players instead of teams.
        let athleteId: ESPNScalar?
    }

    struct CategoryTeam: Decodable, Sendable {
        // Header IDs are strings, but real article-category team IDs are numbers.
        let id: ESPNScalar?
    }
}

struct ESPNTeamNewsResponse: Decodable, Sendable {
    let articles: [ESPNEventSummaryResponse.Article]?
}


/// Build 68: a value that decodes when it can and is nil when its shape changed, instead of
/// failing the response around it.
struct ESPNLenient<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// Build 68: a list that keeps the elements that decode and skips the rest; anything that is not a
/// list decodes as empty.
struct ESPNLossyList<Element: Decodable & Sendable>: Decodable, Sendable {
    let values: [Element]

    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(_ values: [Element]) {
        self.values = values
    }

    init(from decoder: Decoder) throws {
        guard var container = try? decoder.unkeyedContainer() else {
            values = []
            return
        }
        var values: [Element] = []
        while !container.isAtEnd {
            if let value = try? container.decode(Element.self) {
                values.append(value)
            } else if (try? container.decode(Skip.self)) == nil {
                break
            }
        }
        self.values = values
    }
}
