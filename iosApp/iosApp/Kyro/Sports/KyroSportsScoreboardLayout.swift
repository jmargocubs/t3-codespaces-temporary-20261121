import Foundation

// Build 67: layout rules for the Sports Hub's scoreboards that need no view, so they are testable
// on the host without a simulator.

/// How Live Now lays out its cards.
enum KyroSportsLiveNowLayout {
    /// The cards Live Now shows. While an event is pinned in the player above the Feed, that event
    /// is already on screen with its score, so its card would only repeat it.
    static func visibleItems(_ items: [KyroSportsLiveNowModel.Item],
                             pinnedGameID: KyroGameID?) -> [KyroSportsLiveNowModel.Item] {
        guard let pinnedGameID else { return items }
        return items.filter { $0.id != pinnedGameID }
    }

    /// Whether the section is drawn at all. Without a pinned event it always is: its height stays
    /// the same whether it shows cards, a check in progress or nothing live, so switching sports
    /// never moves Scores & Schedule. With one, an empty section would only repeat the player.
    static func showsSection(visibleItemCount: Int, hasPinnedEvent: Bool) -> Bool {
        !hasPinnedEvent || visibleItemCount > 0
    }

    /// Cards across the row: as many as there are, up to three (two at large text sizes, one at
    /// accessibility sizes). Build 66 always divided the row by three, so a single live event sat
    /// in a third of the width with the rest of the row empty.
    static func columns(itemCount: Int, isAccessibilitySize: Bool, isExtraLarge: Bool) -> Int {
        if isAccessibilitySize { return 1 }
        let maximum = isExtraLarge ? 2 : 3
        return max(1, min(itemCount, maximum))
    }
}

/// Which period columns a schedule card shows beside the team rows.
enum KyroSportsCardPeriods {
    /// A card has room for this many period columns beside the team names. A longer line score
    /// (baseball's innings) stays on the Game tab.
    static let maximumColumns = 6

    static func shows(_ periods: [KyroGamePeriod], isAccessibilitySize: Bool) -> Bool {
        !isAccessibilitySize && !periods.isEmpty && periods.count <= maximumColumns
            && periods.contains(where: \.hasScore)
    }
}

/// Tennis set columns: which player won each set, for emphasis. A set still being played (the last
/// one of a live match) has no winner yet.
enum KyroSportsTennisSets {
    enum Winner: Equatable { case away, home }

    static func winners(of periods: [KyroGamePeriod], isFinal: Bool) -> [Winner?] {
        periods.enumerated().map { index, set in
            let isInProgress = !isFinal && index == periods.count - 1
            guard !isInProgress, let away = set.awayScore, let home = set.homeScore, away != home else { return nil }
            return away > home ? .away : .home
        }
    }
}

/// Splits a pair of box-score values into shares for a comparison bar. Purely visual: it never says
/// which side is better, since for some statistics (turnovers, double faults) less is better.
enum KyroSportsStatComparison {
    /// Each side's share of the pair, or nil when either value is not a plain number or both are 0.
    static func shares(away: String, home: String) -> (away: Double, home: Double)? {
        guard let a = number(in: away), let h = number(in: home), a >= 0, h >= 0, a + h > 0 else { return nil }
        return (a / (a + h), h / (a + h))
    }

    /// The number a value leads with: `62%` → 62, `38-85` → 38, `7/12 (58%)` → 58 (the rate, not
    /// the count). Clock values (`28:14`) and text are not compared.
    static func number(in value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(":") else { return nil }
        if let open = trimmed.firstIndex(of: "("), let close = trimmed[open...].firstIndex(of: "%") {
            return Double(trimmed[trimmed.index(after: open)..<close].trimmingCharacters(in: .whitespaces))
        }
        var digits = ""
        for character in trimmed {
            if character.isNumber || (character == "." && !digits.contains(".") && !digits.isEmpty) {
                digits.append(character)
            } else if digits.isEmpty, character != "+" {
                return nil
            } else if !digits.isEmpty {
                break
            }
        }
        return Double(digits)
    }
}
