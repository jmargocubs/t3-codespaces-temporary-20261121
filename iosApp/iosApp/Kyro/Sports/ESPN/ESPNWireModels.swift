import Foundation

/// The subset of ESPN's public scoreboard JSON that Kyro consumes. These
/// wire types stay inside the ESPN adapter so an undocumented field change
/// cannot leak into the shared sports models or SwiftUI.
struct ESPNScoreboardResponse: Decodable, Sendable {
    let leagues: [League]?
    let events: [Event]
    let topWeek: Week?

    private enum CodingKeys: String, CodingKey {
        case leagues, events
        case topWeek = "week"
    }

    struct League: Decodable, Sendable {
        let season: Season?
    }

    /// Top-level scoreboard week. Present on college-football responses and
    /// authoritative for which week a default (undated) request represents.
    var week: Week? { topWeek }

    struct Event: Decodable, Sendable {
        let id: String?
        let date: String?
        let name: String?
        let shortName: String?
        let season: Season?
        let week: Week?
        let status: Status?
        let competitions: [Competition]?
        let groups: [Group]?
        /// Tennis: one entry per draw (`mens-singles`, `womens-doubles`, …),
        /// each holding that draw's matches. Team sports omit it.
        let groupings: [Grouping]?
    }

    /// A tennis draw and its matches, as ESPN's tennis scoreboards send them.
    struct Grouping: Decodable, Sendable {
        let grouping: GroupingInfo?
        let competitions: [Competition]?
    }

    struct GroupingInfo: Decodable, Sendable {
        let id: String?
        let slug: String?
        let displayName: String?
    }

    struct Group: Decodable, Sendable {
        let id: String?
        let name: String?
        let abbreviation: String?
        let competitions: [Competition]?
        let groups: [Group]?
    }

    /// `type` is an integer on events but an object (`{"id","type","name"}`)
    /// on the league-level season in live payloads. Decoding both shapes keeps
    /// one unexpected shape from rejecting a whole scoreboard.
    struct Season: Decodable, Sendable {
        let year: Int?
        let type: Int?
        let slug: String?

        private enum CodingKeys: String, CodingKey { case year, type, slug }
        private struct TypeObject: Decodable { let type: Int? }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            year = try? container.decode(Int.self, forKey: .year)
            slug = try? container.decode(String.self, forKey: .slug)
            if let value = try? container.decode(Int.self, forKey: .type) {
                type = value
            } else {
                type = (try? container.decode(TypeObject.self, forKey: .type))?.type
            }
        }
    }

    struct Week: Decodable, Sendable {
        let number: Int?
    }

    struct Competition: Decodable, Sendable {
        let id: String?
        let date: String?
        let status: Status?
        let competitors: [Competitor]?
        let venue: Venue?
        let broadcasts: [Broadcast]?
        let notes: [Note]?
        let altGameNote: String?
        let situation: Situation?
        let name: String?
        let shortName: String?
        let type: CompetitionType?
        let competitions: [Competition]?
        let group: String?
        /// Tennis sends this on the match, not inside `status`. `false` means
        /// `date` only names the scheduled day, not a start time.
        let timeValid: Bool?
        /// Tennis round, e.g. `Quarterfinal` or `Qualifying 1st Round`.
        let round: Round?
    }

    struct Round: Decodable, Sendable {
        let id: String?
        let displayName: String?
    }

    struct CompetitionType: Decodable, Sendable {
        let id: String?
        let text: String?
        let abbreviation: String?
        let slug: String?
    }

    struct Note: Decodable, Sendable {
        let headline: String?
    }

    /// Live baseball state. Other leagues omit it or send unrelated keys.
    struct Situation: Decodable, Sendable {
        let outs: Int?
    }

    struct Status: Decodable, Sendable {
        let clock: Double?
        let displayClock: String?
        let period: Int?
        let type: StatusType?
        /// Synthetic and older payloads put it here; live tennis uses
        /// `Competition.timeValid`. `var` keeps it optional in the memberwise init.
        var timeValid: Bool?
    }

    struct StatusType: Decodable, Sendable {
        let id: String?
        let name: String?
        let state: String?
        let completed: Bool?
        let description: String?
        let detail: String?
        let shortDetail: String?
    }

    struct Competitor: Decodable, Sendable {
        let id: String?
        let homeAway: String?
        let team: Team?
        let score: ESPNScalar?
        let records: [Record]?
        let linescores: [LineScore]?
        let curatedRank: Rank?
        let athlete: Athlete?
        let player: Athlete?
        let country: Country?
        let flag: ESPNFlag?
        /// Tennis marks the winner explicitly, which matters for retirements
        /// and walkovers where the set grid does not decide it.
        let winner: Bool?
    }

    struct Athlete: Decodable, Sendable {
        let id: String?
        let displayName: String?
        let fullName: String?
        let shortName: String?
        let abbreviation: String?
        let flag: ESPNFlag?
        let country: Country?
    }

    struct Country: Decodable, Sendable {
        let code: String?
        let name: String?
        let abbreviation: String?
    }

    struct Team: Decodable, Sendable {
        let id: String?
        let location: String?
        let name: String?
        let abbreviation: String?
        let displayName: String?
        let shortDisplayName: String?
        let color: String?
        let alternateColor: String?
        let logo: String?
        /// ESPN's variant of `logo` drawn for dark backgrounds.
        let logoDark: String?
        let groups: [TeamGroup]?
        let standingSummary: String?
    }

    struct TeamGroup: Decodable, Sendable {
        let id: String?
        let name: String?
        let abbreviation: String?
    }

    struct Record: Decodable, Sendable {
        let name: String?
        let type: String?
        let summary: String?
    }

    struct LineScore: Decodable, Sendable {
        let value: Double?
        let displayValue: String?
        let period: Int?
    }

    struct Rank: Decodable, Sendable {
        let current: Int?
    }

    struct Venue: Decodable, Sendable {
        let fullName: String?
    }

    struct Broadcast: Decodable, Sendable {
        let names: [String]?
    }
}

/// Live ESPN tennis sends `flag` as an object,
/// `{"href": ".../countries/500/esp.png", "alt": "Spain"}`; synthetic and older
/// payloads use a bare code string. Accept both, and never let an unexpected
/// flag shape reject a whole scoreboard (it did in Build 36).
struct ESPNFlag: Decodable, Sendable {
    let code: String?
    let name: String?
    /// ESPN's own flag image, when the payload carries one (`href`). Only web URLs are kept.
    let imageURL: URL?

    private enum CodingKeys: String, CodingKey { case href, alt }

    init(code: String?, name: String? = nil, imageURL: URL? = nil) {
        self.code = code
        self.name = name
        self.imageURL = imageURL
    }

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            code = value.isEmpty ? nil : value
            name = nil
            imageURL = nil
            return
        }
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            code = nil
            name = nil
            imageURL = nil
            return
        }
        name = try? container.decode(String.self, forKey: .alt)
        let href = try? container.decode(String.self, forKey: .href)
        code = href.flatMap(Self.code(fromFlagURL:))
        imageURL = href.flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
    }

    /// `https://a.espncdn.com/i/teamlogos/countries/500/esp.png` → `ESP`.
    static func code(fromFlagURL value: String) -> String? {
        guard let last = value.split(separator: "/").last else { return nil }
        let stem = last.split(separator: ".").first.map(String.init) ?? ""
        guard (2...3).contains(stem.count), stem.allSatisfy(\.isLetter) else { return nil }
        return stem.uppercased()
    }
}

/// ESPN normally encodes scores as strings, but older and league-specific
/// payloads sometimes use a JSON number. Accept both without weakening the
/// rest of the response validation.
struct ESPNScalar: Decodable, Sendable {
    let stringValue: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            stringValue = value
        } else if let value = try? container.decode(Int.self) {
            stringValue = String(value)
        } else if let value = try? container.decode(Double.self) {
            stringValue = String(value)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected a string or numeric ESPN scalar"
                )
            )
        }
    }
}
