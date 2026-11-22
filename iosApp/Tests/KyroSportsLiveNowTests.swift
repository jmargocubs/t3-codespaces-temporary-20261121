import Foundation
import XCTest
@testable import Silo

/// Build 39 Live Now: eligibility, strong versus generic evidence, no playback during population,
/// caching, invalidation, cancellation, bounded concurrency and 40,000-channel cost.
@MainActor
final class KyroSportsLiveNowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let providerID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    // MARK: Fixtures

    private func game(_ id: String, _ status: KyroGameStatus = .live, league: KyroSportLeague = .nba,
                      homeScore: Int? = 10, start: Date? = nil) -> KyroSportsGame {
        KyroSportsGame(id: KyroGameID(provider: "espn", league: league, rawID: id), league: league,
                       startTime: start ?? now.addingTimeInterval(-3600), status: status,
                       home: KyroGameTeam(team: .placeholder(abbreviation: "H\(id)", league: league), score: homeScore),
                       away: KyroGameTeam(team: .placeholder(abbreviation: "A\(id)", league: league), score: 7))
    }

    private func channel(_ id: String, _ name: String = "Channel") -> LiveTVChannel {
        LiveTVChannel(id: id, guideID: nil, name: name, streamURL: URL(string: "https://example.com/\(id).ts")!,
                      logoURL: nil, category: "Sports")
    }

    private func match(_ id: String, eligible: Bool, source: KyroSportsStreamMatch.Source = .channelName) -> KyroSportsStreamMatch {
        KyroSportsStreamMatch(id: id, channel: channel(id), program: nil, confidence: .medium, score: 60, reasons: [],
                              isStale: false, source: source, isAutoPlayEligible: eligible)
    }

    private func result(strong: [String] = [], weak: [String] = [], broadcasters: [String] = []) -> KyroSportsStreamMatchResult {
        let matches = strong.map { match($0, eligible: true) } + weak.map { match($0, eligible: false) }
        var result = KyroSportsStreamMatchResult(confidence: .medium, matches: matches, manualSearchQuery: "q",
                                                 guideWasStale: false, indexWasCancelled: false)
        result.autoPlayCandidates = matches.filter(\.isAutoPlayEligible)
        result.possibleBroadcasters = broadcasters.map { match($0, eligible: false, source: .broadcaster) }
        return result
    }

    private func revision(catalog: Int = 1, guide: Int = 1) -> KyroSportsLiveNowRevision {
        KyroSportsLiveNowRevision(providerID: providerID, catalogRevision: catalog, guideGeneration: guide)
    }

    private func makeModel(_ source: FakeLiveNowSource) -> KyroSportsLiveNowModel {
        KyroSportsLiveNowModel(source: source)
    }

    // MARK: Inclusion and exclusion

    func testLiveEventWithStrongEventMatchIsIncluded() async {
        let source = FakeLiveNowSource(availability: .ready(revision()))
        source.results["1"] = result(strong: ["dazn"])
        let model = makeModel(source)
        model.update(games: [game("1")], now: now)
        await model.settle()
        XCTAssertEqual(model.items.map(\.id.rawID), ["1"])
        XCTAssertEqual(model.items.first?.streamCount, 1)
        XCTAssertEqual(model.status, .ready)
        XCTAssertTrue(model.canPlay(game("1")))
    }

    func testGenericBroadcasterAndWeakEvidenceNeverQualify() async {
        let source = FakeLiveNowSource(availability: .ready(revision()))
        source.results["1"] = result(weak: ["lead"], broadcasters: ["espn", "fox"])
        let model = makeModel(source)
        model.update(games: [game("1")], now: now)
        await model.settle()
        XCTAssertTrue(model.items.isEmpty, "a network channel or a one-team guess is not a stream for this game")
        XCTAssertEqual(model.liveEventCount, 1)
        XCTAssertFalse(model.canPlay(game("1")))
        let empty = KyroSportsLiveNowEmptyContent(status: model.status, liveEventCount: model.liveEventCount, category: .all)
        // Build 68: one compact row that says the game is live and why it has no card.
        XCTAssertEqual(empty.title, "1 game is live · no matching channel")
        XCTAssertEqual(empty.message, "Follow the scores below, or open a game for details.")
    }

    func testStreamCountCountsStrongEventMatchesOnly() async {
        let source = FakeLiveNowSource(availability: .ready(revision()))
        source.results["1"] = result(strong: ["a", "b"], weak: ["c"], broadcasters: ["espn"])
        let model = makeModel(source)
        model.update(games: [game("1")], now: now)
        await model.settle()
        XCTAssertEqual(model.items.first?.streamCount, 2)
        XCTAssertEqual(model.streamCount(for: game("1")), 2)
    }

    func testLiveEventWithoutAnyMatchIsInformational() async {
        let source = FakeLiveNowSource(availability: .ready(revision()))
        let model = makeModel(source)
        model.update(games: [game("1")], now: now)
        await model.settle()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.streamCount(for: game("1")))
        XCTAssertFalse(model.canPlay(game("1")))
    }

    func testNonLiveEventsAreNeverMatchedOrPlayable() async {
        let source = FakeLiveNowSource(availability: .ready(revision()))
        let statuses: [KyroGameStatus] = [.scheduled, .final, .postponed, .canceled, .suspended, .unknown("delayed")]
        let games = statuses.enumerated().map { game("g\($0.offset)", $0.element) }
        games.forEach { source.results[$0.id.rawID] = result(strong: ["x"]) }
        let model = makeModel(source)
        model.update(games: games, now: now)
        await model.settle()
        XCTAssertTrue(source.calls.isEmpty, "Live Now never matches events that are not in progress")
        XCTAssertEqual(model.liveEventCount, 0)
        for game in games {
            XCTAssertFalse(model.canPlay(game), "\(game.status) must be informational")
            XCTAssertFalse(KyroSportsPlaybackPolicy.allowsAutomaticPlayback(game, now: now))
        }
    }

    func testEligibilityNeedsBothLiveStatusAndStrongEvidence() {
        let strong = KyroSportsLiveNowEvidence(result: result(strong: ["a"]), revision: revision(), computedAt: now, signature: "")
        let weak = KyroSportsLiveNowEvidence(result: result(weak: ["a"], broadcasters: ["b"]), revision: revision(),
                                             computedAt: now, signature: "")
        XCTAssertTrue(KyroSportsPlaybackEligibility.canStartPlayback(game("1"), evidence: strong))
        XCTAssertFalse(KyroSportsPlaybackEligibility.canStartPlayback(game("1"), evidence: weak))
        XCTAssertFalse(KyroSportsPlaybackEligibility.canStartPlayback(game("1"), evidence: nil))
        XCTAssertFalse(KyroSportsPlaybackEligibility.canStartPlayback(game("1", .scheduled), evidence: strong))
        XCTAssertFalse(KyroSportsPlaybackEligibility.canStartPlayback(game("1", .final), evidence: strong))
    }

    func testEndedGameLeavesLiveNowImmediately() async {
        let source = FakeLiveNowSource(availability: .ready(revision()))
        source.results["1"] = result(strong: ["a"])
        let model = makeModel(source)
        model.update(games: [game("1")], now: now)
        await model.settle()
        XCTAssertEqual(model.items.count, 1)
        model.update(games: [game("1", .final)], now: now)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.canPlay(game("1", .final)))
        XCTAssertNil(model.evidence(for: game("1").id))
    }

    // MARK: No playback during population

    func testPopulationNeverStartsOrPresentsPlayback() async {
        let source = FakeLiveNowSource(availability: .ready(revision()))
        (1...4).forEach { source.results["\($0)"] = result(strong: ["s\($0)a", "s\($0)b"]) }
        let driver = KyroSportsPlaybackTestDriver()
        let coordinator = KyroSportsPlaybackCoordinator(scheduler: KyroSportsPlaybackTestScheduler())
        coordinator.driver = driver
        let model = makeModel(source)
        model.update(games: (1...4).map { game("\($0)") }, now: now)
        await model.settle()
        model.update(games: (1...4).map { game("\($0)", homeScore: 14) }, now: now.addingTimeInterval(30))
        await model.settle()
        XCTAssertEqual(model.items.count, 4)
        XCTAssertTrue(driver.starts.isEmpty, "populating Live Now must not tune any stream")
        XCTAssertNil(driver.presented)
        XCTAssertEqual(driver.stops, 0)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    // MARK: Caching and invalidation

    func testScoreRefreshReusesCachedEvidenceAndShowsNewScore() async {
        let source = FakeLiveNowSource(availability: .ready(revision()))
        source.results["1"] = result(strong: ["a"])
        let model = makeModel(source)
        model.update(games: [game("1", homeScore: 10)], now: now)
        await model.settle()
        model.update(games: [game("1", homeScore: 17)], now: now.addingTimeInterval(20))
        await model.settle()
        XCTAssertEqual(source.calls, ["1"], "a score change is not a new match")
        XCTAssertEqual(model.items.first?.game.home.score, 17)
    }

    func testCatalogOrGuideChangeRematchesAndKeepsCardsVisibleMeanwhile() async {
        let source = FakeLiveNowSource(availability: .ready(revision()))
        source.results["1"] = result(strong: ["a"])
        let model = makeModel(source)
        model.update(games: [game("1")], now: now)
        await model.settle()

        source.gated = true
        source.availability = .ready(revision(catalog: 2))
        model.update(games: [game("1")], now: now)
        await source.waitForCalls(2)
        XCTAssertEqual(model.items.count, 1, "the card stays while the new catalog is matched")
        XCTAssertTrue(model.isResolving)
        source.results["1"] = result()
        source.release()
        await model.settle()
        XCTAssertTrue(model.items.isEmpty, "the new catalog has no stream for it")

        source.gated = false
        source.results["1"] = result(strong: ["b"])
        source.availability = .ready(revision(catalog: 2, guide: 2))
        model.update(games: [game("1")], now: now)
        await model.settle()
        XCTAssertEqual(source.calls.count, 3, "a new guide generation also re-matches")
        XCTAssertEqual(model.items.count, 1)
    }

    func testEvidenceExpiresAfterItsLifetime() async {
        let source = FakeLiveNowSource(availability: .ready(revision()))
        source.results["1"] = result(strong: ["a"])
        let model = makeModel(source)
        model.update(games: [game("1")], now: now)
        await model.settle()
        model.update(games: [game("1")], now: now.addingTimeInterval(KyroSportsLiveNowModel.evidenceLifetime - 1))
        await model.settle()
        XCTAssertEqual(source.calls.count, 1)
        model.update(games: [game("1")], now: now.addingTimeInterval(KyroSportsLiveNowModel.evidenceLifetime))
        await model.settle()
        XCTAssertEqual(source.calls.count, 2)
    }

    func testResultComputedAgainstAStaleCatalogIsDiscarded() async {
        let source = FakeLiveNowSource(availability: .ready(revision()))
        source.results["1"] = result(strong: ["old-channel"])
        source.gated = true
        let model = makeModel(source)
        model.update(games: [game("1")], now: now)
        await source.waitForCalls(1)
        // The catalog changes while the first match is still running.
        source.availability = .ready(revision(catalog: 2))
        source.release()
        await model.settle()
        XCTAssertNil(model.evidence(for: game("1").id), "evidence from the old catalog never lands")

        source.gated = false
        source.results["1"] = result(strong: ["new-channel"])
        model.update(games: [game("1")], now: now)
        await model.settle()
        XCTAssertEqual(model.evidence(for: game("1").id)?.strongChannelIDs, ["new-channel"])
        XCTAssertEqual(model.evidence(for: game("1").id)?.revision, revision(catalog: 2))
    }

    func testCancelStopsMatchingAndKeepsEarlierEvidence() async {
        let source = FakeLiveNowSource(availability: .ready(revision()))
        source.results["1"] = result(strong: ["a"])
        let model = makeModel(source)
        model.update(games: [game("1")], now: now)
        await model.settle()

        source.gated = true
        model.update(games: [game("1"), game("2")], now: now)
        await source.waitForCalls(2)
        model.cancel()
        XCTAssertFalse(model.isResolving)
        source.results["2"] = result(strong: ["b"])
        source.release()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(source.inFlight, 0)
        XCTAssertEqual(model.items.map(\.id.rawID), ["1"], "a cancelled pass applies nothing")
    }

    func testMidPassScoreRefreshDoesNotRestartMatching() async {
        let source = FakeLiveNowSource(availability: .ready(revision()))
        source.gated = true
        let model = makeModel(source)
        model.update(games: [game("1"), game("2")], now: now)
        await source.waitForCalls(2)
        model.update(games: [game("1", homeScore: 20), game("2", homeScore: 21)], now: now.addingTimeInterval(15))
        source.release()
        await model.settle()
        XCTAssertEqual(source.calls.sorted(), ["1", "2"])
    }

    // MARK: Availability

    func testNoProviderAndLoadingCatalogNeverMatch() async {
        let source = FakeLiveNowSource(availability: .noProvider)
        let model = makeModel(source)
        model.update(games: [game("1")], now: now)
        XCTAssertEqual(model.status, .noProvider)
        source.availability = .catalogLoading
        model.update(games: [game("1")], now: now)
        await model.settle()
        XCTAssertEqual(model.status, .checking)
        XCTAssertTrue(source.calls.isEmpty, "Live Now waits for the catalog; it never downloads one")
        let checking = KyroSportsLiveNowEmptyContent(status: .checking, liveEventCount: 1, category: .all)
        XCTAssertTrue(checking.showsProgress)
        let none = KyroSportsLiveNowEmptyContent(status: .noProvider, liveEventCount: 2, category: .nba)
        XCTAssertEqual(none.message, "Add a Live TV provider to watch games here.")
    }

    func testFailedChannelLoadSaysSoInsteadOfCheckingForever() async {
        let source = FakeLiveNowSource(availability: .catalogUnavailable)
        let model = makeModel(source)
        model.update(games: [game("1")], now: now)
        await model.settle()
        XCTAssertEqual(model.status, .channelsUnavailable)
        XCTAssertTrue(source.calls.isEmpty)
        let content = KyroSportsLiveNowEmptyContent(status: model.status, liveEventCount: 1, category: .all)
        XCTAssertFalse(content.showsProgress)
        XCTAssertEqual(content.message, "Your channels haven't loaded. Open Live TV to refresh them.")
    }

    func testSwitchingSportsAndBackReusesFreshEvidence() async {
        let source = FakeLiveNowSource(availability: .ready(revision()))
        source.results["nba"] = result(strong: ["a"])
        source.results["nhl"] = result(strong: ["b"])
        let model = makeModel(source)
        let nba = game("nba"), nhl = game("nhl", league: .nhl)
        model.update(games: [nba, nhl], now: now)
        await model.settle()
        model.update(games: [nhl], now: now.addingTimeInterval(10))
        XCTAssertEqual(model.items.map(\.id.rawID), ["nhl"])
        XCTAssertFalse(model.canPlay(nba), "an event outside the filter is not offered")
        model.update(games: [nba, nhl], now: now.addingTimeInterval(20))
        await model.settle()
        XCTAssertEqual(source.calls.sorted(), ["nba", "nhl"], "switching back does not match again")
        XCTAssertEqual(model.items.count, 2)
    }

    func testEmptyStateWithNothingLiveNeverClaimsAvailability() {
        let content = KyroSportsLiveNowEmptyContent(status: .ready, liveEventCount: 0, category: .nhl)
        XCTAssertEqual(content.title, "No NHL games are live right now")
        XCTAssertFalse(content.showsProgress)
        XCTAssertEqual(KyroSportsLiveNowEmptyContent(status: .checking, liveEventCount: 0, category: .all).title,
                       "No games are live right now")
    }

    // MARK: Concurrency

    func testMatchingIsBoundedToTwoEventsAtOnce() async {
        let source = FakeLiveNowSource(availability: .ready(revision()))
        source.gated = true
        let model = makeModel(source)
        let games = (1...6).map { game("\($0)") }
        games.forEach { source.results[$0.id.rawID] = result(strong: ["c\($0.id.rawID)"]) }
        model.update(games: games, now: now)
        await source.waitForCalls(2)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(source.calls.count, 2, "the third match waits for a free slot")
        for _ in 0..<2000 {
            if source.calls.count == 6, source.inFlight == 0 { break }
            source.release()
            await Task.yield()
        }
        await model.settle()
        XCTAssertLessThanOrEqual(source.maximumInFlight, KyroSportsLiveNowModel.maximumConcurrentMatches)
        XCTAssertEqual(model.items.count, 6)
    }

    // MARK: Build 41.1 stable height

    func testEveryLiveNowStateSharesOneHeight() {
        let content = KyroSportsLiveNowEmptyContent(status: .checking, liveEventCount: 1, category: .nba)
        XCTAssertEqual(KyroSportsLiveNowEmptyState(content: content).minimumHeight, KyroSportsLiveNowCard.minimumHeight,
                       "switching to a sport with nothing live must not shrink Live Now")
    }

    // MARK: Catalog preload

    func testPreloadThatEndsWithoutChannelsStopsChecking() async {
        let source = FakeLiveNowSource(availability: .catalogLoading)
        let model = makeModel(source)
        model.update(games: [game("1")], now: now)
        await model.settle()
        XCTAssertEqual(model.status, .checking)
        // The prewarm's download failed: nothing in the catalog changed, only the prewarm ended.
        source.availability = .catalogUnavailable
        model.update(games: [game("1")], now: now)
        await model.settle()
        XCTAssertEqual(model.status, .channelsUnavailable)
        XCTAssertTrue(source.calls.isEmpty)
    }

    func testPrewarmEndingAloneChangesTheLiveNowTrigger() {
        func trigger(prewarming: Bool) -> KyroSportsLiveNowTrigger {
            KyroSportsLiveNowTrigger(games: [game("1")], providerID: nil, isLoadingChannels: false,
                                     isPrewarmingChannels: prewarming, catalogRevision: 3, guideGeneration: 1)
        }
        XCTAssertNotEqual(trigger(prewarming: true), trigger(prewarming: false),
                          "Live Now re-reads when the prewarm ends, even with no new catalog")
    }

    // MARK: Stream picker

    func testStreamPickerPlayabilityCheckMatchesTheServiceGate() {
        let known = UUID(), unknown = UUID()
        func channel(_ provider: UUID?, _ url: String) -> LiveTVChannel {
            LiveTVChannel(id: provider.map { "\($0.uuidString):abc" } ?? "cached-row", guideID: nil, name: "Channel",
                          streamURL: URL(string: url)!, logoURL: nil, category: "Sports")
        }
        let isKnown: (UUID) -> Bool = { $0 == known }
        XCTAssertTrue(LiveTVService.isPlayable(channel(known, "https://example.com/a.m3u8"), isKnownProvider: isKnown))
        XCTAssertTrue(LiveTVService.isPlayable(channel(known, "HTTP://example.com/a.ts"), isKnownProvider: isKnown))
        XCTAssertFalse(LiveTVService.isPlayable(channel(known, "rtmp://example.com/a"), isKnownProvider: isKnown))
        XCTAssertFalse(LiveTVService.isPlayable(channel(unknown, "https://example.com/a"), isKnownProvider: isKnown))
        XCTAssertFalse(LiveTVService.isPlayable(channel(nil, "https://example.com/a"), isKnownProvider: isKnown))
    }

    func testStreamPickerFiltersFortyThousandChannelsOffTheMainActor() async {
        let provider = UUID()
        let channels = (0..<40_000).map { index in
            LiveTVChannel(id: "\(provider.uuidString):\(index)", guideID: nil, name: "Channel \(index)",
                          streamURL: URL(string: index % 4 == 0 ? "rtmp://example.com/\(index)" : "https://example.com/\(index).ts")!,
                          logoURL: nil, category: "Sports")
        }
        let ids: Set<UUID> = [provider]
        let playable = await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            return channels.filter { LiveTVService.isPlayable($0) { ids.contains($0) } }.count
        }.value
        XCTAssertEqual(playable, 30_000)
    }

    // MARK: 40,000 channels

    func testFortyThousandChannelCatalogMatchesWithoutScanningPerCard() async throws {
        var channels = (0..<40_000).map { index in
            LiveTVChannel(id: "c\(index)", guideID: nil, name: "USA | Entertainment \(index)",
                          streamURL: URL(string: "https://example.com/\(index).ts")!, logoURL: nil, category: "USA | General")
        }
        channels.append(LiveTVChannel(id: "dazn", guideID: nil, name: "DAZN UK: Michigan State @ Michigan",
                                      streamURL: URL(string: "https://example.com/dazn.ts")!, logoURL: nil, category: "UK | DAZN"))
        channels.append(LiveTVChannel(id: "cbssn", guideID: nil, name: "CBSSN",
                                      streamURL: URL(string: "https://example.com/cbssn.ts")!, logoURL: nil, category: "USA | Sports"))
        let source = IndexedLiveNowSource(channels: channels, revision: revision())
        let model = KyroSportsLiveNowModel(source: source)
        let msu = KyroSportsGame(id: KyroGameID(provider: "espn", league: .collegeFootball, rawID: "msu"),
                                 league: .collegeFootball, startTime: now, status: .live,
                                 home: KyroGameTeam(team: KyroSportsTeam(id: "130", league: .collegeFootball, abbreviation: "MICH",
                                                                         nickname: "Wolverines", location: "Michigan")),
                                 away: KyroGameTeam(team: KyroSportsTeam(id: "127", league: .collegeFootball, abbreviation: "MSU",
                                                                         nickname: "Spartans", location: "Michigan State")),
                                 broadcast: "FOX")
        let shsu = KyroSportsGame(id: KyroGameID(provider: "espn", league: .collegeFootball, rawID: "shsu"),
                                  league: .collegeFootball, startTime: now, status: .live,
                                  home: KyroGameTeam(team: KyroSportsTeam(id: "55", league: .collegeFootball, abbreviation: "JVST",
                                                                          nickname: "Gamecocks", location: "Jacksonville State")),
                                  away: KyroGameTeam(team: KyroSportsTeam(id: "2534", league: .collegeFootball, abbreviation: "SHSU",
                                                                          nickname: "Bearkats", location: "Sam Houston")),
                                  broadcast: "CBSSN")
        let others = (1...6).map { game("nba\($0)") }
        let started = Date()
        model.update(games: [msu, shsu] + others, now: now)
        await model.settle()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(model.items.map(\.id.rawID), ["msu"], "the broadcaster-only game stays informational")
        XCTAssertEqual(source.indexBuilds, 1, "one index for the whole catalog, shared by every card")
        XCTAssertEqual(source.diagnostics.count, 8)
        for diagnostics in source.diagnostics {
            XCTAssertEqual(diagnostics.catalogChannels, 40_002)
            XCTAssertLessThan(diagnostics.nameCandidates, 100, "a card reads index postings, never the full catalog")
        }
        XCTAssertLessThan(elapsed, 20, "8 live events against 40,000 channels (debug build)")
        let slowest = source.diagnostics.map(\.matchDuration).max() ?? 0
        print("KYRO-BENCH live-now events=8 channels=40002 total=\(String(format: "%.3f", elapsed))s "
              + "slowestMatch=\(String(format: "%.4f", slowest))s "
              + "maxNameCandidates=\(source.diagnostics.map(\.nameCandidates).max() ?? 0)")

        // A score refresh costs nothing more.
        model.update(games: [msu, shsu] + others, now: now.addingTimeInterval(20))
        await model.settle()
        XCTAssertEqual(source.diagnostics.count, 8)
    }
}

// MARK: - Test doubles

@MainActor
final class FakeLiveNowSource: KyroSportsLiveNowSource {
    var availability: KyroSportsLiveNowAvailability
    var results: [String: KyroSportsStreamMatchResult] = [:]
    var gated = false
    private(set) var calls: [String] = []
    private(set) var inFlight = 0
    private(set) var maximumInFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(availability: KyroSportsLiveNowAvailability) {
        self.availability = availability
    }

    var liveNowAvailability: KyroSportsLiveNowAvailability { availability }

    func liveNowMatches(for game: KyroSportsGame, now: Date) async -> KyroSportsStreamMatchResult? {
        calls.append(game.id.rawID)
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        if gated { await withCheckedContinuation { waiters.append($0) } }
        inFlight -= 1
        return results[game.id.rawID] ?? KyroSportsStreamMatchResult(
            confidence: .low, matches: [], manualSearchQuery: "", guideWasStale: false, indexWasCancelled: false)
    }

    func release() {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }

    func waitForCalls(_ count: Int) async {
        for _ in 0..<1000 where calls.count < count { await Task.yield() }
    }
}

/// A source over the real channel index and matcher, like `LiveTVService`'s, with no guide.
@MainActor
final class IndexedLiveNowSource: KyroSportsLiveNowSource {
    private let channels: [LiveTVChannel]
    private let revision: KyroSportsLiveNowRevision
    private var index: Task<KyroSportsChannelIndex?, Never>?
    private(set) var indexBuilds = 0
    private(set) var diagnostics: [KyroSportsStreamMatchDiagnostics] = []

    init(channels: [LiveTVChannel], revision: KyroSportsLiveNowRevision) {
        self.channels = channels
        self.revision = revision
    }

    var liveNowAvailability: KyroSportsLiveNowAvailability { .ready(revision) }

    func liveNowMatches(for game: KyroSportsGame, now: Date) async -> KyroSportsStreamMatchResult? {
        if index == nil {
            indexBuilds += 1
            let channels = channels
            index = Task.detached { KyroSportsChannelIndex.build(channels: channels) }
        }
        guard let built = await index?.value else { return nil }
        let request = KyroSportsStreamMatchRequest(game: game, now: now)
        let result = await Task.detached(priority: .utility) {
            KyroSportsStreamMatcher.match(request: request, index: built, guide: nil, guideKeys: nil)
        }.value
        diagnostics.append(result.diagnostics)
        return result
    }
}
