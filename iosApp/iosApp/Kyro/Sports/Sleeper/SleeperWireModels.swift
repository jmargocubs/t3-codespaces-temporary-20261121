import Foundation

// Sleeper's `/schedule`, `/scores` and `/teams` endpoints are undocumented.
// Observed shapes (2026-11-06) are captured in `Tests/Fixtures/Sleeper`. Three
// defensive rules keep a schema change from taking down the hub:
//
// 1. Every field that is not load-bearing is optional.
// 2. A game missing both teams or an id is skipped, not thrown on.
// 3. Status and clock strings are mapped leniently; an unrecognised value
//    becomes `.unknown` instead of a decode error.
//
// Anything a Sleeper change could turn into a hard failure is confined to this
// file, so recovery is a one-file edit.
//
// `SleeperAPIClient` decodes with a plain `JSONDecoder` and no key strategy on
// purpose: the wire keys are snake_case and mixing in `.convertFromSnakeCase`
// would make explicit `CodingKeys` silently unmatch.

// MARK: - Teams

/// `GET /teams/nfl` — 32 objects.
struct SleeperTeam: Decodable, Sendable {
    let team: String?
    let sport: String?
    let metadata: Metadata?

    struct Metadata: Decodable, Sendable {
        let fullName: String?
        let city: String?
        let conference: String?
        let division: String?
        let color1: String?

        enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
            case city, conference, division, color1
        }
    }
}

// MARK: - Schedule

/// `GET /schedule/{sport}/regular/{season}` — flat list of games.
struct SleeperScheduleGame: Decodable, Sendable {
    let gameID: String?
    let week: Int?
    let date: String?
    let status: String?
    let home: String?
    let away: String?

    enum CodingKeys: String, CodingKey {
        case gameID = "game_id"
        case week, date, status, home, away
    }
}

// MARK: - Scores

/// `GET /scores/{sport}/regular/{season}/{week}` — games with scores.
///
/// Top level is an array. Scores, records, clock and per-period scoring all
/// live under `metadata`, which is absent on some entries.
struct SleeperScoreGame: Decodable, Sendable {
    let gameID: String?
    let week: Int?
    let date: String?
    let startTimeMillis: Double?
    let status: String?
    let metadata: Metadata?

    enum CodingKeys: String, CodingKey {
        case gameID = "game_id"
        case week, date, status, metadata
        case startTimeMillis = "start_time"
    }

    struct Metadata: Decodable, Sendable {
        let homeTeam: String?
        let awayTeam: String?
        let homeScore: Int?
        let awayScore: Int?
        let homeRecord: String?
        let awayRecord: String?
        let dateTime: String?
        let quarter: String?
        let timeRemaining: String?
        let hasStarted: Bool?
        let isInProgress: Bool?
        let isOver: Bool?
        let canceled: Bool?
        let channel: String?
        /// Sleeper nests the venue differently per sport; NFL has been null on
        /// scheduled games and populated on completed ones.
        let venue: Venue?
        let stadiumDetails: Stadium?

        // NFL quarter scoring. Keys are absent on non-NFL payloads.
        let homeScoreQuarter1: Int?
        let homeScoreQuarter2: Int?
        let homeScoreQuarter3: Int?
        let homeScoreQuarter4: Int?
        let awayScoreQuarter1: Int?
        let awayScoreQuarter2: Int?
        let awayScoreQuarter3: Int?
        let awayScoreQuarter4: Int?
        let homeScoreOvertime: Int?
        let awayScoreOvertime: Int?
        let isOvertime: Bool?

        enum CodingKeys: String, CodingKey {
            case homeTeam = "home_team"
            case awayTeam = "away_team"
            case homeScore = "home_score"
            case awayScore = "away_score"
            case homeRecord = "home_record"
            case awayRecord = "away_record"
            case dateTime = "date_time"
            case quarter
            case timeRemaining = "time_remaining"
            case hasStarted = "has_started"
            case isInProgress = "is_in_progress"
            case isOver = "is_over"
            case canceled, channel, venue
            case stadiumDetails = "stadium_details"
            case homeScoreQuarter1 = "home_score_quarter1"
            case homeScoreQuarter2 = "home_score_quarter2"
            case homeScoreQuarter3 = "home_score_quarter3"
            case homeScoreQuarter4 = "home_score_quarter4"
            case awayScoreQuarter1 = "away_score_quarter1"
            case awayScoreQuarter2 = "away_score_quarter2"
            case awayScoreQuarter3 = "away_score_quarter3"
            case awayScoreQuarter4 = "away_score_quarter4"
            case homeScoreOvertime = "home_score_overtime"
            case awayScoreOvertime = "away_score_overtime"
            case isOvertime = "is_overtime"
        }

        struct Venue: Decodable, Sendable {
            let name: String?
        }

        struct Stadium: Decodable, Sendable {
            let name: String?
        }
    }
}

// MARK: - State

/// `GET /v1/state/nfl` — the only one of these endpoints with official docs.
struct SleeperSportState: Decodable, Sendable {
    let week: Int?
    let season: String?
    let seasonType: String?
    let displayWeek: Int?
    let seasonStartDate: String?

    enum CodingKeys: String, CodingKey {
        case week, season
        case seasonType = "season_type"
        case displayWeek = "display_week"
        case seasonStartDate = "season_start_date"
    }
}
