import Foundation
import XCTest
@testable import Silo

/// Cache behaviour for the Sleeper client: freshness short-circuits, ETag
/// revalidation, `304` handling, and stale fallback. A controllable clock and a
/// stub transport make each state reachable without waiting or hitting the
/// network.
final class KyroSportsCacheTests: XCTestCase {

    private let scorePath = "/scores/nfl/regular/2026/9"
    private let body = Data(#"[{"game_id":"g1","status":"pre_game","metadata":{"home_team":"KC","away_team":"DEN"}}]"#.utf8)

    /// A clock the test advances by hand.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            value = value.addingTimeInterval(seconds)
        }
    }

    private func makeClient(
        transport: StubSleeperTransport,
        cache: SleeperResponseCache,
        clock: Clock
    ) -> SleeperAPIClient {
        SleeperAPIClient(
            transport: transport,
            cache: cache,
            timeout: 5,
            now: { clock.now() }
        )
    }

    private let start = Date(timeIntervalSince1970: 1_791_396_000)

    // MARK: - Freshness

    func testFreshCacheHitDoesNotTouchTheNetwork() async throws {
        let transport = StubSleeperTransport()
        transport.set(.init(data: body, etag: "\"v1\""), forPath: scorePath)
        let cache = SleeperResponseCache()
        let clock = Clock(start)
        let client = makeClient(transport: transport, cache: cache, clock: clock)

        _ = try await client.fetchScores(league: .nfl, season: "2026", week: 9)
        XCTAssertEqual(transport.requestCount(), 1)

        clock.advance(5) // still inside the 20s live-scores window
        _ = try await client.fetchScores(league: .nfl, season: "2026", week: 9)
        XCTAssertEqual(transport.requestCount(), 1, "a fresh response is reused without a request")
    }

    func testExpiredCacheRevalidatesWithETag() async throws {
        let transport = StubSleeperTransport()
        transport.set(.init(data: body, etag: "\"v1\""), forPath: scorePath)
        let cache = SleeperResponseCache()
        let clock = Clock(start)
        let client = makeClient(transport: transport, cache: cache, clock: clock)

        _ = try await client.fetchScores(league: .nfl, season: "2026", week: 9)
        clock.advance(60) // past the 20s maxAge

        transport.set(.init(data: Data(), status: 304), forPath: scorePath)
        let scores = try await client.fetchScores(league: .nfl, season: "2026", week: 9).games

        XCTAssertEqual(transport.requestCount(), 2)
        XCTAssertEqual(transport.lastRequest()?.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
        XCTAssertEqual(scores.count, 1, "a 304 keeps the stored body")
    }

    func test304RefreshesFreshnessClock() async throws {
        let transport = StubSleeperTransport()
        transport.set(.init(data: body, etag: "\"v1\""), forPath: scorePath)
        let cache = SleeperResponseCache()
        let clock = Clock(start)
        let client = makeClient(transport: transport, cache: cache, clock: clock)

        _ = try await client.fetchScores(league: .nfl, season: "2026", week: 9)
        clock.advance(60)
        transport.set(.init(data: Data(), status: 304), forPath: scorePath)
        _ = try await client.fetchScores(league: .nfl, season: "2026", week: 9)
        XCTAssertEqual(transport.requestCount(), 2)

        // The 304 reset the stored timestamp, so this is a fresh hit again.
        clock.advance(5)
        _ = try await client.fetchScores(league: .nfl, season: "2026", week: 9)
        XCTAssertEqual(transport.requestCount(), 2)
    }

    func testNewETagReplacesStoredBody() async throws {
        let transport = StubSleeperTransport()
        transport.set(.init(data: body, etag: "\"v1\""), forPath: scorePath)
        let cache = SleeperResponseCache()
        let clock = Clock(start)
        let client = makeClient(transport: transport, cache: cache, clock: clock)
        _ = try await client.fetchScores(league: .nfl, season: "2026", week: 9)

        clock.advance(60)
        let updated = Data(#"[{"game_id":"g1","status":"complete","metadata":{"home_team":"KC","away_team":"DEN","home_score":21,"away_score":17}}]"#.utf8)
        transport.set(.init(data: updated, etag: "\"v2\""), forPath: scorePath)
        let scores = try await client.fetchScores(league: .nfl, season: "2026", week: 9).games

        XCTAssertEqual(scores.first?.metadata?.homeScore, 21)
        let stored = await cache.entry(for: scorePath)
        XCTAssertEqual(stored?.etag, "\"v2\"")
        XCTAssertEqual(stored?.data, updated)
    }

    func testMalformedSuccessBodyIsEvictedInsteadOfPoisoningFreshCache() async throws {
        let transport = StubSleeperTransport()
        transport.set(.init(data: Data("not-json".utf8), etag: "\"bad\""), forPath: scorePath)
        let cache = SleeperResponseCache()
        let clock = Clock(start)
        let client = makeClient(transport: transport, cache: cache, clock: clock)

        do {
            _ = try await client.fetchScores(league: .nfl, season: "2026", week: 9)
            XCTFail("expected malformed response")
        } catch {
            XCTAssertEqual(error as? SleeperAPIError, .malformedResponse)
        }
        let badEntry = await cache.entry(for: scorePath)
        XCTAssertNil(badEntry)

        transport.set(.init(data: body, etag: "\"good\""), forPath: scorePath)
        let games = try await client.fetchScores(league: .nfl, season: "2026", week: 9).games
        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(transport.requestCount(), 2, "the retry reaches the network immediately")
    }

    // MARK: - Stale fallback

    func testNetworkFailureInsideGraceServesStaleData() async throws {
        let transport = StubSleeperTransport()
        transport.set(.init(data: body, etag: "\"v1\""), forPath: scorePath)
        let cache = SleeperResponseCache()
        let clock = Clock(start)
        let client = makeClient(transport: transport, cache: cache, clock: clock)
        _ = try await client.fetchScores(league: .nfl, season: "2026", week: 9)

        clock.advance(120) // expired but well inside maxAge + 900s grace
        transport.setFailure(SleeperAPIError.offline)

        let scores = try await client.fetchScores(league: .nfl, season: "2026", week: 9).games
        XCTAssertEqual(scores.count, 1, "the hub keeps rendering the last good scores")
    }

    func testNetworkFailurePastGraceThrows() async throws {
        let transport = StubSleeperTransport()
        transport.set(.init(data: body, etag: "\"v1\""), forPath: scorePath)
        let cache = SleeperResponseCache()
        let clock = Clock(start)
        let client = makeClient(transport: transport, cache: cache, clock: clock)
        _ = try await client.fetchScores(league: .nfl, season: "2026", week: 9)

        clock.advance(20 + 900 + 1) // past maxAge + staleIfErrorGrace
        transport.setFailure(SleeperAPIError.offline)

        do {
            _ = try await client.fetchScores(league: .nfl, season: "2026", week: 9)
            XCTFail("expected the error to surface once the grace window closed")
        } catch {
            XCTAssertEqual(error as? SleeperAPIError, .offline)
        }
    }

    func testNoCacheFailureThrowsImmediately() async {
        let transport = StubSleeperTransport()
        transport.setFailure(SleeperAPIError.offline)
        let cache = SleeperResponseCache()
        let clock = Clock(start)
        let client = makeClient(transport: transport, cache: cache, clock: clock)

        do {
            _ = try await client.fetchScores(league: .nfl, season: "2026", week: 9)
            XCTFail("expected an offline error")
        } catch {
            XCTAssertEqual(error as? SleeperAPIError, .offline)
        }
    }

    func testCancellationIsNeverAnsweredFromCache() async throws {
        let transport = StubSleeperTransport()
        transport.set(.init(data: body, etag: "\"v1\""), forPath: scorePath)
        let cache = SleeperResponseCache()
        let clock = Clock(start)
        let client = makeClient(transport: transport, cache: cache, clock: clock)
        _ = try await client.fetchScores(league: .nfl, season: "2026", week: 9)

        clock.advance(120)
        transport.setFailure(SleeperAPIError.cancelled)

        do {
            _ = try await client.fetchScores(league: .nfl, season: "2026", week: 9)
            XCTFail("cancellation must propagate, not fall back to cache")
        } catch {
            XCTAssertEqual(error as? SleeperAPIError, .cancelled)
        }
    }

    // MARK: - Separation

    func testDifferentWeeksUseDifferentCacheKeys() async throws {
        let transport = StubSleeperTransport()
        transport.set(.init(data: body, etag: "\"v1\""), forPath: scorePath)
        transport.set(.init(data: Data("[]".utf8), etag: "\"w10\""),
                       forPath: "/scores/nfl/regular/2026/10")
        let cache = SleeperResponseCache()
        let clock = Clock(start)
        let client = makeClient(transport: transport, cache: cache, clock: clock)

        let week9 = try await client.fetchScores(league: .nfl, season: "2026", week: 9).games
        let week10 = try await client.fetchScores(league: .nfl, season: "2026", week: 10).games

        XCTAssertEqual(week9.count, 1)
        XCTAssertTrue(week10.isEmpty)
        XCTAssertEqual(transport.requestCount(), 2)
    }

    func testLeagueSportKeysUseCFBForCollegeFootball() {
        XCTAssertEqual(SleeperMapping.sleeperSportKey(for: .nfl), "nfl")
        XCTAssertEqual(SleeperMapping.sleeperSportKey(for: .nba), "nba")
        XCTAssertEqual(SleeperMapping.sleeperSportKey(for: .nhl), "nhl")
        XCTAssertEqual(SleeperMapping.sleeperSportKey(for: .mlb), "mlb")
        XCTAssertEqual(SleeperMapping.sleeperSportKey(for: .collegeFootball), "cfb",
                       "NCAACF is /cfb; /ncaaf returns null")
    }
}
