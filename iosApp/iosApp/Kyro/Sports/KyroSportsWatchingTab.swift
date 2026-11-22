import Foundation

/// Feed stays mounted behind the other tabs so its scroll position and filters never reset.
enum KyroSportsWatchingTab: String, CaseIterable, Identifiable {
    case feed, game, stats, news

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

/// Layout rules for the pinned event's tabs that do not need a view to test.
enum KyroSportsWatchingLayout {
    /// Game, Stats and News draw under the hub's top inset (status bar, shell header, player and
    /// tab bar). Only the Feed reports its scroll to the shell header, so the other tabs need an
    /// opaque backing there or their rows show through the header.
    static func needsOpaqueInset(tab: KyroSportsWatchingTab, hasPinnedEvent: Bool) -> Bool {
        hasPinnedEvent && tab != .feed
    }
}

/// Build 68: rules for Event Details, which opens from any schedule card, with or without a stream.
enum KyroSportsEventDetailsLayout {
    /// The pinned event's tabs without the Feed, which Event Details covers.
    static let tabs: [KyroSportsWatchingTab] = [.game, .stats, .news]

    /// An upcoming event whose sources publish pregame context: ESPN's summary for team sports,
    /// theScore for tennis singles. Live and final events keep Build 67's loads (Stats and News).
    static func loadsPregame(league: KyroSportLeague, status: KyroGameStatus, isSingles: Bool) -> Bool {
        guard status.isScheduled else { return false }
        switch league {
        case .atp, .wta: return isSingles
        case .nfl, .nba, .nhl, .mlb, .collegeFootball, .collegeBasketballMen, .collegeBasketballWomen, .soccer: return true
        }
    }

    /// The competition, named once under the league: a tournament, or the soccer league.
    static func competitionName(tournament: String?, soccerCompetition: String?) -> String? {
        for name in [tournament, soccerCompetition] {
            if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        }
        return nil
    }

    /// A note that says something the header and round do not. ESPN's tennis notes repeat the
    /// tournament (Build 67 showed it three times in one sheet).
    static func distinctNote(_ note: String?, competition: String?, round: String?) -> String? {
        guard let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else { return nil }
        let folded = note.lowercased()
        for other in [competition, round].compactMap({ $0?.lowercased() }) where !other.isEmpty {
            if folded == other || other.contains(folded) { return nil }
        }
        return note
    }
}
