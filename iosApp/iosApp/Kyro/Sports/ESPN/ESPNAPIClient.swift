import Foundation

protocol ESPNTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionESPNTransport: ESPNTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw KyroSportsDataError.malformedResponse
            }
            return (data, http)
        } catch is CancellationError {
            throw KyroSportsDataError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw KyroSportsDataError.cancelled
            case .timedOut: throw KyroSportsDataError.timedOut
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                throw KyroSportsDataError.offline
            default: throw KyroSportsDataError.offline
            }
        }
    }
}

/// What a cached scoreboard says about how soon it can change. Computed once
/// when a response is stored so freshness checks stay cheap.
struct ESPNPayloadActivity: Equatable, Sendable {
    var hasLive = false
    var hasPending = false
    var soonestPendingStart: Date?

    init(hasLive: Bool = false, hasPending: Bool = false, soonestPendingStart: Date? = nil) {
        self.hasLive = hasLive
        self.hasPending = hasPending
        self.soonestPendingStart = soonestPendingStart
    }

    init(_ response: ESPNScoreboardResponse) {
        for event in response.events {
            if let groupings = event.groupings, !groupings.isEmpty {
                // Tennis: the event status describes the whole tournament
                // (often `Final` while matches are still to play), so scan
                // the matches themselves. Date-only slots are not imminent.
                for grouping in groupings {
                    for match in grouping.competitions ?? [] {
                        let date = match.timeValid == false ? nil : match.date
                        record(ESPNMapping.status(from: match.status), date: date)
                    }
                }
                continue
            }
            let competition = event.competitions?.first
            record(ESPNMapping.status(from: competition?.status ?? event.status),
                   date: competition?.date ?? event.date)
        }
    }

    private mutating func record(_ status: KyroGameStatus, date: String?) {
        if status.isLive { hasLive = true }
        guard status.isLive || status.isScheduled || status.isUnknown else { return }
        hasPending = true
        if status.isScheduled || status.isUnknown, let start = ESPNMapping.startDate(date) {
            soonestPendingStart = min(soonestPendingStart ?? start, start)
        }
    }
}

enum ESPNCachePolicy: Sendable {
    /// Full-year NFL schedule responses are roughly 3 MB. They are refreshed
    /// infrequently; the small current-day scoreboard overlays live changes.
    case schedule
    /// A selected day's scoreboard is the only response used for live polling.
    case liveScoreboard
    /// A future day that is only a schedule.
    case futureDay
    /// A day before today: long-lived once every game is final.
    case completedDay
    /// Today's scoreboard for non-NFL leagues: short while a game is live or
    /// about to start, long otherwise.
    case today
    /// The undated current-week college football scoreboard.
    case currentWeek

    func maxAge(for activity: ESPNPayloadActivity, at now: Date) -> TimeInterval {
        switch self {
        case .schedule: return 6 * 3600
        case .liveScoreboard: return 20
        case .futureDay: return 6 * 3600
        case .completedDay:
            if activity.hasLive { return 20 }
            return activity.hasPending ? 120 : 12 * 3600
        case .today, .currentWeek:
            if activity.hasLive { return 20 }
            if let start = activity.soonestPendingStart, start.timeIntervalSince(now) < 2 * 3600 {
                return 60
            }
            return activity.hasPending ? 10 * 60 : 3600
        }
    }

    var staleIfErrorGrace: TimeInterval {
        switch self {
        case .liveScoreboard, .today, .currentWeek: 15 * 60
        case .schedule, .futureDay, .completedDay: 24 * 3600
        }
    }
}

struct ESPNScoreboardPayload: Sendable {
    let response: ESPNScoreboardResponse
    let refreshError: KyroSportsDataError?
}

/// ESPN transport, validated decoding, caching, ETag revalidation, and
/// duplicate-request coalescing. The actor keeps concurrent page loads from
/// starting the same request twice; response bytes are decoded before they can
/// enter the cache. Memory is bounded by entry count and total response bytes.
actor ESPNAPIClient {
    static let maxResponseBytes = 8 * 1024 * 1024
    static let maxCachedEntries = 64
    static let maxCachedBytes = 24 * 1024 * 1024

    private struct Entry: Sendable {
        let response: ESPNScoreboardResponse
        let etag: String?
        let storedAt: Date
        let activity: ESPNPayloadActivity
        let bytes: Int
    }

    private struct NetworkResult: Sendable {
        let response: ESPNScoreboardResponse
        let etag: String?
        let bytes: Int
    }

    private struct InFlight {
        let id: UUID
        let task: Task<NetworkResult, Error>
        var waiters: Int
    }

    private let baseURL: URL
    private let transport: any ESPNTransport
    private let timeout: TimeInterval
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: InFlight] = [:]

    init(
        baseURL: URL = URL(string: "https://site.api.espn.com")!,
        transport: any ESPNTransport = URLSessionESPNTransport(),
        timeout: TimeInterval = 12,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.timeout = timeout
        self.now = now
    }

    /// - Parameter dates: `yyyyMMdd` (ESPN's US-Eastern scoreboard day) or a
    ///   season year. `nil` requests the provider's current scoreboard, which
    ///   for college football is the authoritative current week. ESPN rejects
    ///   `yyyyMMdd-yyyyMMdd` ranges with HTTP 400, so callers fetch per day.
    func fetchScoreboard(
        league: KyroSportLeague,
        dates: String?,
        policy: ESPNCachePolicy,
        ignoreFreshness: Bool = false,
        competitionKey: String? = nil
    ) async throws -> ESPNScoreboardPayload {
        let key = cacheKey(league: league, dates: dates, competitionKey: competitionKey)
        let currentDate = now()
        let stored = entries[key]
        if !ignoreFreshness, let stored,
           currentDate.timeIntervalSince(stored.storedAt) < policy.maxAge(for: stored.activity, at: currentDate) {
            return ESPNScoreboardPayload(response: stored.response, refreshError: nil)
        }

        let id: UUID
        let task: Task<NetworkResult, Error>
        if var existing = inFlight[key] {
            existing.waiters += 1
            inFlight[key] = existing
            id = existing.id
            task = existing.task
        } else {
            let request = try makeRequest(league: league, dates: dates, etag: stored?.etag,
                                         competitionKey: competitionKey)
            let transport = transport
            let newTask = Task<NetworkResult, Error> {
                let (data, response) = try await transport.send(request)
                try Task.checkCancellation()
                switch response.statusCode {
                case 200...299:
                    guard data.count <= ESPNAPIClient.maxResponseBytes else {
                        throw KyroSportsDataError.malformedResponse
                    }
                    let decoded: ESPNScoreboardResponse
                    do {
                        decoded = try JSONDecoder().decode(ESPNScoreboardResponse.self, from: data)
                    } catch {
                        throw KyroSportsDataError.malformedResponse
                    }
                    return NetworkResult(
                        response: decoded,
                        etag: response.value(forHTTPHeaderField: "ETag"),
                        bytes: data.count
                    )
                case 304:
                    guard let stored else { throw KyroSportsDataError.malformedResponse }
                    return NetworkResult(response: stored.response, etag: stored.etag, bytes: stored.bytes)
                default:
                    throw KyroSportsDataError.httpStatus(response.statusCode)
                }
            }
            id = UUID()
            task = newTask
            inFlight[key] = InFlight(id: id, task: newTask, waiters: 1)
        }

        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                // The shared request is cancelled only when no caller is left.
                Task { await self.abandon(key: key, id: id) }
            }
            finish(key: key, id: id)
            store(result, for: key)
            return ESPNScoreboardPayload(response: result.response, refreshError: nil)
        } catch {
            finish(key: key, id: id)
            if let stale = stalePayload(stored, policy: policy, at: currentDate, error: error) {
                return stale
            }
            throw normalize(error)
        }
    }

    /// Drops the in-flight record once its last waiter returns.
    private func finish(key: String, id: UUID) {
        guard var record = inFlight[key], record.id == id else { return }
        record.waiters -= 1
        if record.waiters <= 0 { inFlight[key] = nil } else { inFlight[key] = record }
    }

    /// A cancelled caller leaves; the last one out cancels the network task.
    private func abandon(key: String, id: UUID) {
        guard var record = inFlight[key], record.id == id else { return }
        record.waiters -= 1
        if record.waiters <= 0 {
            record.task.cancel()
            inFlight[key] = nil
        } else {
            inFlight[key] = record
        }
    }

    private func store(_ result: NetworkResult, for key: String) {
        entries[key] = Entry(
            response: result.response,
            etag: result.etag,
            storedAt: now(),
            activity: ESPNPayloadActivity(result.response),
            bytes: result.bytes
        )
        evictIfNeeded(keeping: key)
    }

    private func evictIfNeeded(keeping key: String) {
        var total = entries.values.reduce(0) { $0 + $1.bytes }
        while entries.count > Self.maxCachedEntries || total > Self.maxCachedBytes {
            guard let oldest = entries
                .filter({ $0.key != key })
                .min(by: { $0.value.storedAt < $1.value.storedAt }) else { break }
            total -= oldest.value.bytes
            entries[oldest.key] = nil
        }
    }

    func removeAllCachedResponses() {
        entries.removeAll()
    }

    func cachedResponseCount() -> Int { entries.count }

    private func makeRequest(
        league: KyroSportLeague,
        dates: String?,
        etag: String?,
        competitionKey: String?
    ) throws -> URLRequest {
        guard let endpoint = URL(string: ESPNMapping.path(for: league, competitionKey: competitionKey), relativeTo: baseURL),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: true) else {
            throw KyroSportsDataError.malformedResponse
        }
        var items: [URLQueryItem] = []
        if let dates { items.append(URLQueryItem(name: "dates", value: dates)) }
        items.append(URLQueryItem(name: "limit", value: (league == .collegeFootball || league == .collegeBasketballMen || league == .collegeBasketballWomen) ? "500" : "1000"))
        if league == .collegeFootball {
            // ESPN group 80 is FBS. Keeping it explicit avoids mixing FCS and
            // lower-division games into the future NCAA screen.
            items.append(URLQueryItem(name: "groups", value: "80"))
        }
        if league == .collegeBasketballMen || league == .collegeBasketballWomen {
            // ESPN group 50 is Division I. Query IDs are source-owned metadata and
            // are not assumptions about tournament type or conference.
            items.append(URLQueryItem(name: "groups", value: "50"))
        }
        components.queryItems = items
        guard let url = components.url else { throw KyroSportsDataError.malformedResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return request
    }

    private func cacheKey(league: KyroSportLeague, dates: String?, competitionKey: String?) -> String {
        "\(league.rawValue)|\(competitionKey ?? "default")|\(dates ?? "current")"
    }

    private func stalePayload(
        _ stored: Entry?,
        policy: ESPNCachePolicy,
        at currentDate: Date,
        error: Error
    ) -> ESPNScoreboardPayload? {
        let normalized = normalize(error)
        guard normalized != .cancelled, let stored else { return nil }
        let age = currentDate.timeIntervalSince(stored.storedAt)
        guard age < policy.maxAge(for: stored.activity, at: currentDate) + policy.staleIfErrorGrace else {
            return nil
        }
        return ESPNScoreboardPayload(response: stored.response, refreshError: normalized)
    }

    private func normalize(_ error: Error) -> KyroSportsDataError {
        if let error = error as? KyroSportsDataError { return error }
        if error is CancellationError { return .cancelled }
        return .offline
    }
}
