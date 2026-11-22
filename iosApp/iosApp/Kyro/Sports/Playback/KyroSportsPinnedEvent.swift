import Foundation
import Observation

/// The event playing in the Sports Hub's pinned player, kept current whatever the feed shows.
///
/// Build 59 refreshed the pinned event only from the feed's own schedule. That schedule holds the
/// selected sport and day, so choosing WTA under an NBA stream froze the header at the score from
/// when the sport changed, and the strip above the video always showed the score from when the
/// stream started. Game, Stats and News were already keyed to the pinned event's ID.
enum KyroSportsPinnedEvent {
    /// The copy the hub shows: the feed's own copy when it lists the event (the feed polls it),
    /// else this event's last separate refresh, else the snapshot taken when playback started.
    static func resolve(
        pinned: KyroSportsGame,
        scheduleGames: [KyroSportsGame],
        refreshed: KyroSportsGame?
    ) -> KyroSportsGame {
        if let fromSchedule = scheduleGames.first(where: { $0.id == pinned.id }) { return fromSchedule }
        if let refreshed, refreshed.id == pinned.id { return pinned.updatingLiveState(from: refreshed) }
        return pinned
    }

    /// Restarts the separate refresh when the event changes or the feed starts or stops listing it.
    struct RefreshKey: Hashable {
        let gameID: KyroGameID
        let coveredBySchedule: Bool
    }
}

extension KyroSportsGame {
    /// This event with `fresh`'s live state: status, clock, score, periods, situation and winner.
    /// Identity, competition, round and venue stay as they were, so a refresh from a thinner feed
    /// cannot drop a soccer competition or a tennis round. A different event or a different pair
    /// of sides changes nothing.
    func updatingLiveState(from fresh: KyroSportsGame) -> KyroSportsGame {
        guard fresh.id == id, fresh.home.team.id == home.team.id, fresh.away.team.id == away.team.id else {
            return self
        }
        func side(_ current: KyroGameTeam, _ next: KyroGameTeam) -> KyroGameTeam {
            KyroGameTeam(team: current.team, score: next.score ?? current.score,
                         record: next.record ?? current.record, rank: current.rank ?? next.rank,
                         isWinner: next.isWinner ?? current.isWinner)
        }
        return KyroSportsGame(
            id: id, league: league, season: season, seasonType: seasonType, week: week,
            startTime: startTime, status: fresh.status, statusDetail: fresh.statusDetail,
            home: side(home, fresh.home), away: side(away, fresh.away),
            periods: fresh.periods.isEmpty ? periods : fresh.periods,
            venue: venue, broadcast: broadcast, note: note, situation: fresh.situation,
            provenance: provenance, tournament: tournament, round: round, isSingles: isSingles,
            isStartTimeTBD: isStartTimeTBD, competitionKey: competitionKey)
    }
}

/// Polls the pinned event's own ESPN scoreboard while the feed does not list it. One request per
/// `interval`, only while the event is scheduled or live and the hub is on screen; nothing runs while the
/// feed already covers the event, because the feed's poll refreshes it.
@MainActor
@Observable
final class KyroSportsPinnedEventRefresher {
    typealias Fetch = @Sendable (KyroSportsGame) async throws -> KyroSportsGame?

    static let interval: Duration = .seconds(20)

    private(set) var latest: KyroSportsGame?
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private(set) var fetchCount = 0

    init(fetch: @escaping Fetch = KyroSportsPinnedEventRefresher.espnFetch) {
        self.fetch = fetch
    }

    func keepCurrent(
        _ pinned: KyroSportsGame,
        coveredBySchedule: Bool,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async {
        if latest?.id != pinned.id { latest = nil }
        guard !coveredBySchedule else { return }
        var current = latest.map { pinned.updatingLiveState(from: $0) } ?? pinned
        while !Task.isCancelled, Self.isChanging(current) {
            fetchCount += 1
            KyroPerformanceDiagnostics.event("Sports pinned refresh", .sportsPinnedRefresh)
            if let fresh = try? await fetch(current), fresh.id == pinned.id {
                guard !Task.isCancelled else { return }
                if latest != fresh { latest = fresh }
                current = pinned.updatingLiveState(from: fresh)
            }
            guard Self.isChanging(current) else { return }
            do { try await sleep(Self.interval) } catch { return }
        }
    }

    /// Only a scheduled or live event can still change score or status.
    nonisolated static func isChanging(_ game: KyroSportsGame) -> Bool {
        game.status.isLive || game.status.isScheduled
    }

    private nonisolated static let espn = ESPNSportsProvider()

    /// The event's day on its own ESPN scoreboard (and competition, for soccer). Non-ESPN events
    /// return nil and keep their snapshot.
    nonisolated static func espnFetch(_ game: KyroSportsGame) async throws -> KyroSportsGame? {
        guard let start = game.startTime,
              let rawID = game.id.provider == ESPNMapping.providerName
                ? game.id.rawID
                : game.provenance.first(where: { $0.provider == ESPNMapping.providerName })?.rawID else {
            return nil
        }
        let payload = try await espn.client.fetchScoreboard(
            league: game.league, dates: ESPNSportsProvider.espnDayString(for: start),
            policy: .liveScoreboard, ignoreFreshness: true, competitionKey: game.competitionKey)
        let games = try espn.mapValidated(payload.response, league: game.league, competitionKey: game.competitionKey)
        return games.first { $0.id == game.id } ?? games.first { $0.id.rawID == rawID }
    }
}
