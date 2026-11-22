import Foundation
import Observation

// Build 39 (Phase S9): Live Now is where Sports Hub plays sports.
//
// An event appears in Live Now only when ESPN reports it in progress AND the local stream matcher
// found at least one strong event-specific channel or guide match for it (the same evidence the
// Build 38 one-tap flow tries automatically). Population is metadata only: nothing here owns a
// player, starts a stream or touches the network. A tap still proves a stream plays.

/// What a Live Now match was computed against. A new catalog or guide generation makes every
/// cached match stale.
struct KyroSportsLiveNowRevision: Hashable, Sendable {
    let providerID: UUID
    let catalogRevision: Int
    let guideGeneration: Int
}

/// Whether Live Now can look for streams right now.
enum KyroSportsLiveNowAvailability: Equatable, Sendable {
    /// No Live TV provider is set up.
    case noProvider
    /// The provider's playable catalog is downloading for this session.
    case catalogLoading
    /// No playable catalog this session and no download running (it failed or is not due).
    case catalogUnavailable
    case ready(KyroSportsLiveNowRevision)
}

/// The local matcher, as Live Now sees it. Deliberately no playback API: populating Live Now can
/// never start, test or present a stream.
@MainActor
protocol KyroSportsLiveNowSource: AnyObject {
    var liveNowAvailability: KyroSportsLiveNowAvailability { get }
    /// Event-to-stream candidates from the prebuilt channel index and guide. Nil when the work was
    /// cancelled or the catalog changed underneath it. Must not download anything.
    func liveNowMatches(for game: KyroSportsGame, now: Date) async -> KyroSportsStreamMatchResult?
}

/// The strong stream evidence found for one live event.
struct KyroSportsLiveNowEvidence: Equatable, Sendable {
    /// Channels strong enough to try automatically (`isAutoPlayEligible`), best first.
    let strongChannelIDs: [String]
    let revision: KyroSportsLiveNowRevision
    let computedAt: Date
    /// The event fields matching depends on, so a corrected start time or broadcast re-matches.
    let signature: String

    var qualifies: Bool { !strongChannelIDs.isEmpty }
    /// Shown on the card: strong event matches, never padded with broadcasters or guesses.
    var streamCount: Int { strongChannelIDs.count }

    init(result: KyroSportsStreamMatchResult, revision: KyroSportsLiveNowRevision, computedAt: Date, signature: String) {
        var seen = Set<String>()
        strongChannelIDs = result.matches.filter(\.isAutoPlayEligible).map(\.channel.id)
            .filter { seen.insert($0).inserted }
        self.revision = revision
        self.computedAt = computedAt
        self.signature = signature
    }
}

/// One Sports Hub playback rule for every entry point: Live Now cards, schedule cards, featured
/// cards and accessibility actions.
enum KyroSportsPlaybackEligibility {
    /// ESPN must report the event in progress. Upcoming, final, postponed, canceled, suspended
    /// and unknown events are informational.
    static func isInProgress(_ game: KyroSportsGame) -> Bool { game.status.isLive }

    /// A tap may start playback: the event is live and Live Now holds strong stream evidence.
    static func canStartPlayback(_ game: KyroSportsGame, evidence: KyroSportsLiveNowEvidence?) -> Bool {
        isInProgress(game) && (evidence?.qualifies ?? false)
    }

    static func signature(of game: KyroSportsGame) -> String {
        [game.home.team.id, game.away.team.id, game.home.team.fullName, game.away.team.fullName,
         game.startTime.map { String(Int($0.timeIntervalSince1970)) } ?? "-",
         game.isStartTimeTBD ? "tbd" : "", game.broadcast ?? ""].joined(separator: "|")
    }
}

/// Live Now: live events with strong stream evidence, kept current as scores, the catalog and the
/// guide change. One instance per process (owned by `LiveTVService`) so its cache outlives a tab
/// switch.
@MainActor
@Observable
final class KyroSportsLiveNowModel {
    struct Item: Identifiable, Equatable {
        /// The newest game value from the schedule, so scores stay live.
        let game: KyroSportsGame
        let streamCount: Int
        var id: KyroGameID { game.id }
    }

    enum Status: Equatable {
        case noProvider
        /// Waiting for the catalog download or the first matching pass.
        case checking
        /// The channel list did not load this session, so nothing can be matched.
        case channelsUnavailable
        case ready
    }

    /// Matches older than this are refreshed: guide programmes move as the event runs.
    static let evidenceLifetime: TimeInterval = 5 * 60
    /// Events matched at once. Each match is bounded by the channel index (no catalog scan), and
    /// this keeps a busy Saturday from flooding the cooperative pool.
    static let maximumConcurrentMatches = 2

    private(set) var items: [Item] = []
    private(set) var status: Status = .checking
    /// Events ESPN reports in progress for the current filter, matched or not.
    private(set) var liveEventCount = 0
    private(set) var isResolving = false

    @ObservationIgnored private weak var source: (any KyroSportsLiveNowSource)?
    @ObservationIgnored private var evidence: [KyroGameID: KyroSportsLiveNowEvidence] = [:]
    @ObservationIgnored private var liveGames: [KyroSportsGame] = []
    @ObservationIgnored private var lastNow = Date()
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    @ObservationIgnored private var pending: Set<KyroGameID> = []
    @ObservationIgnored private var pendingRevision: KyroSportsLiveNowRevision?
    @ObservationIgnored private var generation = 0
    /// Matching calls made, for tests and diagnostics.
    @ObservationIgnored private(set) var matchCalls = 0

    init(source: (any KyroSportsLiveNowSource)?) {
        self.source = source
    }

    /// Evidence for a game, current or kept from the previous catalog until re-matched.
    func evidence(for id: KyroGameID) -> KyroSportsLiveNowEvidence? { evidence[id] }

    /// The single playback gate the Sports Hub uses for every entry point. Reads the observed
    /// `items`, so a card becomes playable or informational as soon as Live Now changes.
    func canPlay(_ game: KyroSportsGame) -> Bool {
        KyroSportsPlaybackEligibility.isInProgress(game) && items.contains { $0.id == game.id }
            && KyroSportsPlaybackEligibility.canStartPlayback(game, evidence: evidence[game.id])
    }

    /// Strong streams known for a playable game, for schedule and featured cards.
    func streamCount(for game: KyroSportsGame) -> Int? {
        canPlay(game) ? evidence[game.id]?.streamCount : nil
    }

    /// The schedule, catalog or guide changed. Cheap when nothing needs re-matching: cached
    /// evidence for the same revision and event is reused, and only missing or stale events are
    /// matched.
    func update(games: [KyroSportsGame], now: Date) {
        lastNow = now
        var seen = Set<KyroGameID>()
        liveGames = games.filter { KyroSportsPlaybackEligibility.isInProgress($0) && seen.insert($0.id).inserted }
        if liveEventCount != liveGames.count { liveEventCount = liveGames.count }
        // Ended events leave immediately and their evidence goes with them. Evidence for events
        // outside the current sport filter is kept while fresh, so switching back is instant.
        let ended = Set(games.filter { !KyroSportsPlaybackEligibility.isInProgress($0) }.map(\.id))
        evidence = evidence.filter { id, known in
            seen.contains(id) || (!ended.contains(id) && now.timeIntervalSince(known.computedAt) < Self.evidenceLifetime)
        }

        guard let source else { return finish(status: .noProvider) }
        let revision: KyroSportsLiveNowRevision
        switch source.liveNowAvailability {
        case .noProvider:
            cancelResolution()
            evidence = [:]
            return finish(status: .noProvider)
        case .catalogLoading:
            // Keep what was found before; the download bumps the catalog revision when done.
            cancelResolution()
            return finish(status: evidence.isEmpty && !liveGames.isEmpty ? .checking : .ready)
        case .catalogUnavailable:
            cancelResolution()
            return finish(status: .channelsUnavailable)
        case .ready(let current):
            revision = current
        }

        let due = Set(liveGames.filter { needsMatching($0, revision: revision, now: now) }.map(\.id))
        // A pass already matching these events against this revision is left to finish, so a
        // score refresh mid-pass never restarts it.
        let covered = resolveTask != nil && pendingRevision == revision && due.isSubset(of: pending)
        if !due.isEmpty, !covered {
            startResolution(due, revision: revision)
        }
        let unresolved = liveGames.contains { evidence[$0.id] == nil }
        finish(status: unresolved && isResolving ? .checking : .ready)
    }

    /// The Sports Hub went away or the app left the foreground. Cached evidence stays.
    func cancel() {
        cancelResolution()
        rebuildItems()
    }

    /// Waits for the matching pass in flight. For tests.
    func settle() async {
        while let task = resolveTask {
            await task.value
            if resolveTask == task { break }
        }
    }

    // MARK: Private

    private func needsMatching(_ game: KyroSportsGame, revision: KyroSportsLiveNowRevision, now: Date) -> Bool {
        guard let known = evidence[game.id] else { return true }
        return known.revision != revision
            || known.signature != KyroSportsPlaybackEligibility.signature(of: game)
            || now.timeIntervalSince(known.computedAt) >= Self.evidenceLifetime
    }

    private func startResolution(_ ids: Set<KyroGameID>, revision: KyroSportsLiveNowRevision) {
        resolveTask?.cancel()
        generation &+= 1
        let token = generation
        pending = ids
        pendingRevision = revision
        isResolving = true
        let games = liveGames.filter { ids.contains($0.id) }
        let now = lastNow
        resolveTask = Task { [weak self] in
            await self?.resolve(games, revision: revision, now: now, token: token)
            guard let self, self.generation == token else { return }
            self.resolveTask = nil
            self.pending = []
            self.pendingRevision = nil
            self.isResolving = false
            self.finish(status: .ready)
        }
    }

    /// Matches `games` in batches of `maximumConcurrentMatches`. Each batch's results land
    /// before the next starts, so the first live events appear without waiting for the rest.
    private func resolve(_ games: [KyroSportsGame], revision: KyroSportsLiveNowRevision, now: Date, token: Int) async {
        guard let source else { return }
        var start = 0
        while start < games.count {
            let batch = Array(games[start..<min(start + Self.maximumConcurrentMatches, games.count)])
            start += batch.count
            matchCalls += batch.count
            // The group body touches no model state, so it compiles the same whatever isolation
            // the toolchain infers for it.
            let results = await withTaskGroup(of: (KyroSportsGame, KyroSportsStreamMatchResult?).self) { group in
                for game in batch {
                    group.addTask { @MainActor [weak source] in (game, await source?.liveNowMatches(for: game, now: now)) }
                }
                var collected: [(KyroSportsGame, KyroSportsStreamMatchResult?)] = []
                for await item in group { collected.append(item) }
                return collected
            }
            for (game, result) in results {
                guard !Task.isCancelled, generation == token else { return }
                apply(result, for: game, revision: revision, now: now)
            }
        }
    }

    private func apply(_ result: KyroSportsStreamMatchResult?, for game: KyroSportsGame,
                       revision: KyroSportsLiveNowRevision, now: Date) {
        // A cancelled pass, or one computed against a catalog or guide that has since changed,
        // never replaces evidence: the next update re-matches against the new revision.
        guard let result, !result.indexWasCancelled,
              case .ready(let current)? = source?.liveNowAvailability, current == revision,
              liveGames.contains(where: { $0.id == game.id }) else { return }
        evidence[game.id] = KyroSportsLiveNowEvidence(result: result, revision: revision, computedAt: now,
                                                      signature: KyroSportsPlaybackEligibility.signature(of: game))
        rebuildItems()
    }

    private func cancelResolution() {
        resolveTask?.cancel()
        resolveTask = nil
        generation &+= 1
        pending = []
        pendingRevision = nil
        isResolving = false
    }

    private func finish(status newStatus: Status) {
        if status != newStatus { status = newStatus }
        rebuildItems()
    }

    private func rebuildItems() {
        let next = liveGames.compactMap { game -> Item? in
            guard let known = evidence[game.id], known.qualifies else { return nil }
            return Item(game: game, streamCount: known.streamCount)
        }
        if next != items { items = next }
    }
}

/// What Live Now says when it has no cards. Never claims availability it has not found.
struct KyroSportsLiveNowEmptyContent: Equatable {
    let symbol: String
    let title: String
    let message: String?
    let showsProgress: Bool

    /// `isLoadingScores`: the selected sports have not answered yet, so "nothing is live" would be
    /// a guess.
    init(status: KyroSportsLiveNowModel.Status, liveEventCount: Int, category: KyroSportsCategory,
         isLoadingScores: Bool = false) {
        let sport = category == .all ? "" : "\(category.shortName) "
        if liveEventCount == 0, isLoadingScores {
            symbol = "sportscourt"
            title = "Loading live \(sport)games…"
            message = nil
            showsProgress = true
            return
        }
        if liveEventCount == 0 {
            symbol = "sportscourt"
            title = "No \(sport)games are live right now"
            message = "Live games with a matching channel appear here."
            showsProgress = false
            return
        }
        switch status {
        case .noProvider:
            symbol = "antenna.radiowaves.left.and.right"
            title = liveEventCount == 1 ? "1 game is live" : "\(liveEventCount) games are live"
            message = "Add a Live TV provider to watch games here."
            showsProgress = false
        case .channelsUnavailable:
            symbol = "exclamationmark.arrow.triangle.2.circlepath"
            title = liveEventCount == 1 ? "1 game is live" : "\(liveEventCount) games are live"
            message = "Your channels haven't loaded. Open Live TV to refresh them."
            showsProgress = false
        case .checking:
            symbol = "antenna.radiowaves.left.and.right"
            title = "Checking your channels…"
            message = liveEventCount == 1 ? "1 game is live." : "\(liveEventCount) games are live."
            showsProgress = true
        case .ready:
            // Build 68: live, but nothing playable. Says so in one row; the scores are below.
            symbol = "tv.slash"
            title = liveEventCount == 1 ? "1 game is live · no matching channel"
                : "\(liveEventCount) games are live · no matching channels"
            message = "Follow the scores below, or open a game for details."
            showsProgress = false
        }
    }
}
