import Foundation

// Build 65: shared by the Stats tab and Event Details (KyroTennisMatchContext.swift).

/// Why a tennis match shows no statistics, in the words the screen uses.
struct KyroTennisStatsMessage: Equatable {
    let title: String
    let detail: String

    static func make(status: KyroGameStatus, outcome: KyroSportsSupplementOutcome?, isLoading: Bool) -> KyroTennisStatsMessage? {
        if isLoading {
            return .init(title: "Looking for match statistics…", detail: "Checking the WTA and TennisMyLife records for this match.")
        }
        guard status.isFinal else {
            if status == .live {
                return .init(title: "Match statistics not available yet",
                             detail: "Serve and return statistics are added once the match is completed. Set scores are in Game.")
            }
            return nil
        }
        switch outcome {
        case .available:
            return nil
        case .providerUnavailable:
            return .init(title: "Statistics sources unavailable",
                         detail: "The statistics sources could not be reached. Kyro tries again in about 10 minutes.")
        case .ambiguousMatch:
            return .init(title: "Match statistics not shown",
                         detail: "A record was found but could not be tied to this exact match, so no statistics are shown.")
        case .noAdditionalStatistics:
            return .init(title: "Match statistics unavailable",
                         detail: "The record for this match has no serve or return counts.")
        case .noVerifiedMatch, .notEligible, .cancelled, .none:
            return .init(title: "Match statistics unavailable",
                         detail: "No verified serve and return statistics for this match yet. Results usually appear within a few hours of the match; qualifying, Challenger, ITF and doubles matches are not covered.")
        }
    }
}
