import CoreGraphics
import Foundation

/// Identifies the title Seekr should resolve for scrub previews.
enum SeekrContent: Equatable, Sendable {
    /// A film. Provide at least one of `tmdbId` / `imdbId`.
    case movie(tmdbId: Int?, imdbId: String?)
    /// One episode. Provide at least one show id plus season and episode.
    case episode(showTmdbId: Int?, showImdbId: String?, season: Int, episode: Int)

    var isValid: Bool {
        switch self {
        case let .movie(tmdbId, imdbId):
            return tmdbId != nil || (imdbId?.isEmpty == false)
        case let .episode(showTmdbId, showImdbId, season, episode):
            return (showTmdbId != nil || (showImdbId?.isEmpty == false))
                && season >= 0 && episode > 0
        }
    }

    /// Stable cache / unavailable-title key that never includes credentials.
    var cacheKey: String {
        switch self {
        case let .movie(tmdbId, imdbId):
            if let tmdbId { return "movie:tmdb:\(tmdbId)" }
            return "movie:imdb:\(imdbId ?? "")"
        case let .episode(showTmdbId, showImdbId, season, episode):
            let show = showTmdbId.map { "tmdb:\($0)" } ?? "imdb:\(showImdbId ?? "")"
            return "episode:\(show):s\(season):e\(episode)"
        }
    }
}

/// Successful `/sprites` lookup metadata (before the VTT is fetched).
struct SeekrSpriteLookup: Equatable, Sendable {
    let vttURL: URL
    let scale: Double
    let sourceDurationMs: Int64
    let exact: Bool
}

/// One WebVTT cue: a time window and a tile inside a signed sprite sheet.
struct SeekrCue: Equatable, Sendable {
    let startMs: Int64
    let endMs: Int64
    let sheetURL: URL
    let rect: CGRect

    var startSeconds: Double { Double(startMs) / 1_000 }
    var endSeconds: Double { Double(endMs) / 1_000 }
}

/// Outcomes that must not crash playback. Missing previews are normal.
enum SeekrLookupOutcome: Error, Equatable, Sendable {
    case found(SeekrSpriteLookup)
    case noPreviews
    case unauthorized
    case forbidden
    case rateLimited(retryAfterSeconds: Int?)
    case unavailable
}

enum SeekrClientError: Error, Equatable {
    case invalidContent
    case missingAPIKey
    case invalidResponse
}
