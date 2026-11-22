import Foundation
import OSLog

/// Talks to Seekr's control plane (`api.seekr.tv`) and signed sprite host.
///
/// Network failures and missing titles never throw into playback — they come
/// back as `SeekrLookupOutcome`. The API key is read from
/// `SeekrCredentials` and is never logged.
actor SeekrClient {
    static let shared = SeekrClient()

    static let defaultBaseURL = URL(string: "https://api.seekr.tv")!

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.cubbiestream.kyro",
        category: "SeekrClient"
    )

    private let baseURL: URL
    private let session: URLSession
    private let apiKeyProvider: @Sendable () -> String?

    /// Titles that returned 404 recently — do not hammer the API while scrubbing.
    private var unavailableUntil: [String: Date] = [:]
    /// Global rate-limit gate from the last 429.
    private var rateLimitedUntil: Date?
    /// Remember a bad key for this process so every scrub does not re-validate.
    private var keyRejected = false

    private static let unavailableTTL: TimeInterval = 6 * 60 * 60
    private static let signedURLMargin: TimeInterval = 5 * 60

    init(
        baseURL: URL = SeekrClient.defaultBaseURL,
        session: URLSession? = nil,
        apiKeyProvider: @escaping @Sendable () -> String? = { SeekrCredentials.apiKey() }
    ) {
        self.baseURL = baseURL
        self.apiKeyProvider = apiKeyProvider
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            config.httpAdditionalHeaders = [
                "Accept": "application/json",
                "User-Agent": "KyroSeekr/1.0"
            ]
            self.session = URLSession(configuration: config)
        }
    }

    /// Validates the configured key. Used by settings; not required before lookup.
    func validateKey() async -> Bool {
        guard let key = apiKeyProvider(), !key.isEmpty else { return false }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/keys/validate"))
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "X-API-Key")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let valid = json["valid"] as? Bool else {
                return false
            }
            keyRejected = !valid
            return valid
        } catch {
            Self.logger.info("Seekr key validation failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Looks up sprites and returns the parsed cue list plus metadata.
    func loadTrack(
        content: SeekrContent,
        durationMs: Int64
    ) async -> Result<SeekrTrack, SeekrLookupOutcome> {
        guard content.isValid else { return .failure(.unavailable) }
        guard durationMs > 0 else { return .failure(.unavailable) }
        if keyRejected { return .failure(.unauthorized) }
        if let until = rateLimitedUntil, until > Date() {
            return .failure(.rateLimited(retryAfterSeconds: Int(until.timeIntervalSinceNow)))
        }
        let cacheKey = content.cacheKey
        if let until = unavailableUntil[cacheKey], until > Date() {
            return .failure(.noPreviews)
        }

        switch await fetchLookup(content: content, durationMs: durationMs) {
        case let .found(lookup):
            guard let vtt = await fetchVTT(lookup.vttURL) else {
                return .failure(.unavailable)
            }
            let cues = SeekrVTT.parse(vtt)
            guard !cues.isEmpty else {
                unavailableUntil[cacheKey] = Date().addingTimeInterval(Self.unavailableTTL)
                return .failure(.noPreviews)
            }
            return .success(
                SeekrTrack(
                    contentKey: cacheKey,
                    cues: cues,
                    scale: lookup.scale,
                    sourceDurationMs: lookup.sourceDurationMs,
                    exact: lookup.exact,
                    loadedAt: Date(),
                    // Signed URLs last ~6 hours; refresh with margin.
                    expiresAt: Date().addingTimeInterval(6 * 60 * 60 - Self.signedURLMargin)
                )
            )
        case .noPreviews:
            unavailableUntil[cacheKey] = Date().addingTimeInterval(Self.unavailableTTL)
            return .failure(.noPreviews)
        case let outcome:
            return .failure(outcome)
        }
    }

    private func fetchLookup(content: SeekrContent, durationMs: Int64) async -> SeekrLookupOutcome {
        guard let key = apiKeyProvider(), !key.isEmpty else {
            return .unauthorized
        }
        guard var components = URLComponents(url: baseURL.appendingPathComponent("sprites"), resolvingAgainstBaseURL: false) else {
            return .unavailable
        }
        var items = [URLQueryItem(name: "duration_ms", value: String(durationMs))]
        switch content {
        case let .movie(tmdbId, imdbId):
            if let imdbId, !imdbId.isEmpty {
                items.append(URLQueryItem(name: "imdb_id", value: imdbId))
            }
            if let tmdbId {
                items.append(URLQueryItem(name: "tmdb_id", value: String(tmdbId)))
            }
        case let .episode(showTmdbId, showImdbId, season, episode):
            if let showTmdbId {
                items.append(URLQueryItem(name: "show_tmdb_id", value: String(showTmdbId)))
            }
            if let showImdbId, !showImdbId.isEmpty {
                items.append(URLQueryItem(name: "show_imdb_id", value: showImdbId))
            }
            items.append(URLQueryItem(name: "season", value: String(season)))
            items.append(URLQueryItem(name: "episode", value: String(episode)))
        }
        components.queryItems = items
        guard let url = components.url else { return .unavailable }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "X-API-Key")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailable }
            switch http.statusCode {
            case 200:
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let vttString = json["vtt_url"] as? String,
                      let vttURL = URL(string: vttString) else {
                    return .unavailable
                }
                let scale = (json["scale"] as? Double)
                    ?? (json["scale"] as? NSNumber)?.doubleValue
                    ?? 1.0
                let sourceDuration: Int64 = {
                    if let n = json["source_duration_ms"] as? Int64 { return n }
                    if let n = json["source_duration_ms"] as? Int { return Int64(n) }
                    if let n = json["source_duration_ms"] as? NSNumber { return n.int64Value }
                    return 0
                }()
                let exact = (json["exact"] as? Bool) ?? false
                return .found(
                    SeekrSpriteLookup(
                        vttURL: vttURL,
                        scale: scale,
                        sourceDurationMs: sourceDuration,
                        exact: exact
                    )
                )
            case 404:
                return .noPreviews
            case 401:
                keyRejected = true
                Self.logger.error("Seekr API key rejected.")
                return .unauthorized
            case 403:
                return .forbidden
            case 429:
                let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
                let delay = TimeInterval(retry ?? 60)
                rateLimitedUntil = Date().addingTimeInterval(delay)
                Self.logger.info("Seekr rate limited; retry after \(Int(delay), privacy: .public)s")
                return .rateLimited(retryAfterSeconds: retry)
            default:
                return .unavailable
            }
        } catch {
            Self.logger.info("Seekr lookup failed: \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }
    }

    /// Fetches the VTT. `st=1` asks Seekr to serve cue times already scaled
    /// onto the client timeline.
    private func fetchVTT(_ url: URL) async -> String? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        if !items.contains(where: { $0.name == "st" }) {
            items.append(URLQueryItem(name: "st", value: "1"))
        }
        components?.queryItems = items
        guard let finalURL = components?.url else { return nil }
        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        // Signed URL only — do not send the API key to the sprite host.
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            switch http.statusCode {
            case 200:
                return String(data: data, encoding: .utf8)
            case 403:
                Self.logger.info("Seekr VTT URL expired or forbidden.")
                return nil
            default:
                return nil
            }
        } catch {
            Self.logger.info("Seekr VTT fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Parsed Seekr track for one playback item.
struct SeekrTrack: Equatable, Sendable {
    let contentKey: String
    let cues: [SeekrCue]
    let scale: Double
    let sourceDurationMs: Int64
    let exact: Bool
    let loadedAt: Date
    let expiresAt: Date

    var isExpired: Bool { Date() >= expiresAt }

    /// Nearest cue to `positionMs` (after applying `offsetMs`). Prefer this
    /// over a floor/containing-cue lookup so mid-interval scrubs show the
    /// closer frame.
    func nearestCue(positionMs: Int64, offsetMs: Int64 = 0) -> SeekrCue? {
        guard !cues.isEmpty else { return nil }
        let target = positionMs + offsetMs
        var best = cues[0]
        var bestDistance = abs(best.startMs - target)
        for cue in cues.dropFirst() {
            let distance = abs(cue.startMs - target)
            if distance < bestDistance {
                best = cue
                bestDistance = distance
            } else if cue.startMs > target {
                // Cues are sorted; once we move past the target and distances
                // grow, further cues cannot be nearer.
                break
            }
        }
        return best
    }
}
