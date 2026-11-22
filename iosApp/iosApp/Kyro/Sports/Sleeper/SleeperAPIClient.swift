import Foundation

// Networking for Sleeper's free, keyless API. No backend, no credentials.
//
// Sleeper sends weak ETags and explicit `Cache-Control` on every endpoint
// (verified 2026-11-06: scores `s-maxage=10`, schedule `600`, state `60`). Kyro
// honours that two ways: it stores the ETag and revalidates with
// `If-None-Match`, and it keeps a stale copy so a failed or offline refresh
// still renders the last good page.

// MARK: - Errors

/// Compatibility name for the Sleeper transport and its existing tests. Page
/// state uses the provider-independent error declared in `KyroSportsProvider`.
typealias SleeperAPIError = KyroSportsDataError

// MARK: - Transport

/// The one seam tests replace. The live implementation is `URLSession`.
protocol SleeperTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionSleeperTransport: SleeperTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SleeperAPIError.malformedResponse
            }
            return (data, http)
        } catch is CancellationError {
            throw SleeperAPIError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw SleeperAPIError.cancelled
            case .timedOut:
                throw SleeperAPIError.timedOut
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                throw SleeperAPIError.offline
            default:
                throw SleeperAPIError.offline
            }
        }
    }
}

// MARK: - Cache

/// Per-endpoint freshness policy.
struct SleeperCachePolicy: Sendable {
    /// How long a stored response is fresh without asking Sleeper again.
    let maxAge: TimeInterval
    /// How long past `maxAge` a stored response may still be served when the
    /// refresh fails. Zero disables stale fallback.
    let staleIfErrorGrace: TimeInterval

    static let liveScores = SleeperCachePolicy(maxAge: 20, staleIfErrorGrace: 900)
    static let scores = SleeperCachePolicy(maxAge: 15 * 60, staleIfErrorGrace: 6 * 3600)
    static let schedule = SleeperCachePolicy(maxAge: 6 * 3600, staleIfErrorGrace: 24 * 3600)
    static let teams = SleeperCachePolicy(maxAge: 24 * 3600, staleIfErrorGrace: 7 * 24 * 3600)
    static let state = SleeperCachePolicy(maxAge: 60, staleIfErrorGrace: 600)
}

/// A response Kyro can render, plus where it came from.
struct SleeperPayload: Sendable {
    let data: Data
    /// Why the refresh failed when this body came from the store instead.
    /// `nil` means the body is current.
    let refreshError: SleeperAPIError?

    var isStale: Bool { refreshError != nil }
}

/// Process-wide store of raw Sleeper responses, keyed by URL path.
///
/// Deliberately stores bytes, not decoded models: a decoder change then takes
/// effect immediately on cached data instead of waiting for a refetch. Bodies
/// are small (the largest NFL payload is ~85 KB).
actor SleeperResponseCache {
    static let shared = SleeperResponseCache()

    private struct Entry {
        let data: Data
        let etag: String?
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]

    init() {}

    func entry(for key: String) -> (data: Data, etag: String?, storedAt: Date)? {
        guard let entry = entries[key] else { return nil }
        return (entry.data, entry.etag, entry.storedAt)
    }

    func store(_ data: Data, etag: String?, for key: String, at date: Date = Date()) {
        entries[key] = Entry(data: data, etag: etag, storedAt: date)
    }

    func removeAll() {
        entries.removeAll()
    }

    func remove(for key: String) {
        entries.removeValue(forKey: key)
    }

    /// Test hook: the number of stored responses.
    var count: Int { entries.count }
}

// MARK: - Client

/// Fetches and caches Sleeper responses. One instance is cheap; the cache it
/// talks to is shared.
struct SleeperAPIClient: Sendable {
    let baseURL: URL
    let transport: SleeperTransport
    let cache: SleeperResponseCache
    /// Injected so tests can control "now" when exercising cache freshness.
    let now: @Sendable () -> Date
    /// Per-request timeout. The hub's page load is not worth a long wait.
    let timeout: TimeInterval

    init(
        baseURL: URL = URL(string: "https://api.sleeper.app")!,
        transport: SleeperTransport = URLSessionSleeperTransport(),
        cache: SleeperResponseCache = .shared,
        timeout: TimeInterval = 12,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.cache = cache
        self.timeout = timeout
        self.now = now
    }

    // MARK: Endpoints

    func fetchTeams(
        league: KyroSportLeague,
        ignoreFreshness: Bool = false
    ) async throws -> [SleeperTeam] {
        let key = SleeperMapping.sleeperSportKey(for: league)
        let path = "/teams/\(key)"
        let data = try await payload(path: path, policy: .teams, ignoreFreshness: ignoreFreshness).data
        return try await decoded([SleeperTeam].self, from: data, cacheKey: path)
    }

    func fetchSchedule(league: KyroSportLeague, season: String) async throws -> [SleeperScheduleGame] {
        let key = SleeperMapping.sleeperSportKey(for: league)
        let path = "/schedule/\(key)/regular/\(season)"
        let data = try await payload(
            path: path,
            policy: .schedule
        ).data
        return try await decoded([SleeperScheduleGame].self, from: data, cacheKey: path)
    }

    /// Scores for one week. Uses the shorter live policy because this is the
    /// only endpoint the hub polls while games are running.
    ///
    /// Returns the refresh error when the body was served stale, so the hub can
    /// show its "saved scores" notice instead of implying the numbers are current.
    func fetchScores(
        league: KyroSportLeague,
        season: String,
        week: Int,
        liveWindow: Bool = true,
        ignoreFreshness: Bool = false
    ) async throws -> (games: [SleeperScoreGame], refreshError: SleeperAPIError?) {
        let key = SleeperMapping.sleeperSportKey(for: league)
        let path = "/scores/\(key)/regular/\(season)/\(week)"
        let payload = try await payload(
            path: path,
            policy: liveWindow ? .liveScores : .scores,
            ignoreFreshness: ignoreFreshness
        )
        return (
            try await decoded([SleeperScoreGame].self, from: payload.data, cacheKey: path),
            payload.refreshError
        )
    }

    /// `GET /v1/state/{sport}` — the only documented endpoint here.
    func fetchState(
        league: KyroSportLeague,
        ignoreFreshness: Bool = false
    ) async throws -> (state: SleeperSportState, refreshError: SleeperAPIError?) {
        let key = SleeperMapping.sleeperSportKey(for: league)
        let path = "/v1/state/\(key)"
        let payload = try await payload(path: path, policy: .state, ignoreFreshness: ignoreFreshness)
        return (
            try await decoded(SleeperSportState.self, from: payload.data, cacheKey: path),
            payload.refreshError
        )
    }

    // MARK: Request

    /// Fresh-cache hit → return it. Otherwise revalidate with the stored ETag;
    /// `304` refreshes the timestamp without re-reading the body. On any
    /// failure, serve a stale copy when the policy allows it.
    ///
    /// - Parameter ignoreFreshness: pull-to-refresh bypasses the fresh-cache
    ///   short circuit but still revalidates with the ETag, so an unchanged
    ///   payload costs one `304`, not a full body.
    private func payload(
        path: String,
        policy: SleeperCachePolicy,
        ignoreFreshness: Bool = false
    ) async throws -> SleeperPayload {
        try Task.checkCancellation()

        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw SleeperAPIError.malformedResponse
        }

        let cacheKey = path
        let stored = await cache.entry(for: cacheKey)
        let currentDate = now()

        if !ignoreFreshness, let stored,
           currentDate.timeIntervalSince(stored.storedAt) < policy.maxAge {
            return SleeperPayload(data: stored.data, refreshError: nil)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag = stored?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await transport.send(request)
            try Task.checkCancellation()

            switch response.statusCode {
            case 200...299:
                let etag = response.value(forHTTPHeaderField: "ETag")
                await cache.store(data, etag: etag, for: cacheKey, at: now())
                return SleeperPayload(data: data, refreshError: nil)
            case 304:
                // Not modified: keep the body, reset its freshness clock.
                if let stored {
                    await cache.store(stored.data, etag: stored.etag, for: cacheKey, at: now())
                    return SleeperPayload(data: stored.data, refreshError: nil)
                }
                throw SleeperAPIError.malformedResponse
            default:
                throw SleeperAPIError.httpStatus(response.statusCode)
            }
        } catch {
            if let stale = staleFallback(stored: stored, policy: policy, at: currentDate, error: error) {
                return stale
            }
            throw normalize(error)
        }
    }

    private func staleFallback(
        stored: (data: Data, etag: String?, storedAt: Date)?,
        policy: SleeperCachePolicy,
        at currentDate: Date,
        error: Error
    ) -> SleeperPayload? {
        // A cancelled task is the caller's intent, never a reason to show data.
        if case SleeperAPIError.cancelled = normalize(error) { return nil }
        guard let stored, policy.staleIfErrorGrace > 0 else { return nil }
        let age = currentDate.timeIntervalSince(stored.storedAt)
        guard age < policy.maxAge + policy.staleIfErrorGrace else { return nil }
        return SleeperPayload(data: stored.data, refreshError: normalize(error))
    }

    private func normalize(_ error: Error) -> SleeperAPIError {
        if let error = error as? SleeperAPIError { return error }
        if error is CancellationError { return .cancelled }
        if error is DecodingError { return .malformedResponse }
        return .offline
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SleeperAPIError.malformedResponse
        }
    }

    /// A malformed 2xx must not become a fresh poison entry. Evict it so the
    /// next refresh reaches the network instead of replaying the bad bytes.
    private func decoded<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        cacheKey: String
    ) async throws -> T {
        do {
            return try decode(type, from: data)
        } catch {
            await cache.remove(for: cacheKey)
            throw error
        }
    }
}
