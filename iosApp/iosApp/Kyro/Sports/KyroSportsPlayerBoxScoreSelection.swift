import Foundation

/// Build 70: which team's player box score the Stats tab shows.
///
/// Build 66–69 drew both teams' complete box scores one after the other, so an NFL or college
/// football Stats tab ran to several screens. A two-team selector now shows one team at a time.
/// The screen that owns the tab bar keeps the choice (the hub, or Event Details), so it survives
/// Stats → Game → Stats. It is tied to an event: another event starts on its first team.
///
/// Build 71.1: the same value also keeps the Stats tab's Team Stats | Player Stats choice, so both
/// choices share one owner and one reset rule. A new event starts on Team Stats and its first team.
struct KyroSportsPlayerBoxScoreSelection: Equatable {
    enum Section: Hashable, CaseIterable {
        case team, players

        var title: String {
            switch self {
            case .team: return "Team Stats"
            case .players: return "Player Stats"
            }
        }
    }

    private(set) var gameID: KyroGameID?
    private(set) var teamID: String?
    private var storedSection: Section = .team

    mutating func select(_ teamID: String, for gameID: KyroGameID) {
        if self.gameID != gameID { storedSection = .team }
        self.gameID = gameID
        self.teamID = teamID
    }

    mutating func selectSection(_ section: Section, for gameID: KyroGameID) {
        if self.gameID != gameID { teamID = nil }
        self.gameID = gameID
        storedSection = section
    }

    /// Team Stats unless the viewer chose otherwise for this event.
    func section(for gameID: KyroGameID) -> Section {
        self.gameID == gameID ? storedSection : .team
    }

    /// The viewer's choice for this event while that team still has a box score; otherwise the
    /// first team, the away side, which is also the team Build 69 listed first.
    func resolvedTeamID(in teams: [KyroSportsPlayerTeamBoxScore], gameID: KyroGameID) -> String? {
        if self.gameID == gameID, let teamID, teams.contains(where: { $0.id == teamID }) { return teamID }
        return teams.first?.id
    }

    /// Selector order: away, then home, as the team comparison above reads (away | home). A team
    /// matching neither side keeps the provider's order after them, and a duplicate is dropped.
    static func orderedTeams(_ teams: [KyroSportsPlayerTeamBoxScore], game: KyroSportsGame) -> [KyroSportsPlayerTeamBoxScore] {
        var unique: [KyroSportsPlayerTeamBoxScore] = []
        for team in teams where !unique.contains(where: { $0.id == team.id }) { unique.append(team) }
        let away = unique.first { side(of: $0, in: game) == .away }
        let home = unique.first { side(of: $0, in: game) == .home && $0.id != away?.id }
        let sides = [away, home].compactMap { $0 }
        return sides + unique.filter { team in !sides.contains { $0.id == team.id } }
    }

    enum Side: Equatable { case away, home }

    /// Matched by the scoreboard abbreviation, the way the team comparison matches its columns.
    static func side(of team: KyroSportsPlayerTeamBoxScore, in game: KyroSportsGame) -> Side? {
        let abbreviation = KyroSportsReconciler.canonicalTeam(team.abbreviation)
        if abbreviation == KyroSportsReconciler.canonicalTeam(game.away.team.abbreviation) { return .away }
        if abbreviation == KyroSportsReconciler.canonicalTeam(game.home.team.abbreviation) { return .home }
        return nil
    }

    /// Longest title a segment shows before it falls back to the abbreviation.
    static let maximumTitleLength = 14

    /// Short segment titles: the school for college football ("Illinois", not "Fighting Illini"),
    /// the nickname elsewhere ("Knicks"), then ESPN's shorter names, then the abbreviation. Two
    /// equal titles (two "Tigers") both use abbreviations.
    static func segmentTitles(for teams: [KyroSportsPlayerTeamBoxScore], game: KyroSportsGame) -> [String: String] {
        var titles: [String: String] = [:]
        for team in teams {
            titles[team.id] = segmentTitle(for: team, game: game)
        }
        let values = teams.compactMap { titles[$0.id] }
        if Set(values).count < values.count {
            for team in teams { titles[team.id] = team.abbreviation }
        }
        return titles
    }

    static func segmentTitle(for team: KyroSportsPlayerTeamBoxScore, game: KyroSportsGame) -> String {
        var candidates: [String?] = []
        switch side(of: team, in: game) {
        case .away?, .home?:
            let sideTeam = side(of: team, in: game) == .away ? game.away.team : game.home.team
            let names = (game.league == .collegeFootball || game.league == .collegeBasketballMen || game.league == .collegeBasketballWomen)
                ? [sideTeam.location, sideTeam.nickname]
                : [sideTeam.nickname, sideTeam.location]
            candidates = names + sideTeam.alternateNames.sorted { $0.count < $1.count }.map(Optional.some)
        case nil:
            break
        }
        candidates.append(team.displayName)
        for candidate in candidates {
            guard let name = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            if name.count <= maximumTitleLength { return name }
        }
        return team.abbreviation
    }

    /// What VoiceOver reads for a segment: the team's full name.
    static func accessibilityName(for team: KyroSportsPlayerTeamBoxScore, game: KyroSportsGame) -> String {
        switch side(of: team, in: game) {
        case .away?: return game.away.team.fullName
        case .home?: return game.home.team.fullName
        case nil: return team.displayName
        }
    }
}
