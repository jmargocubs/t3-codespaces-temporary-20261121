import Foundation

/// One guide programme with its interval normalized to UTC instants. Kyro owns this shape so the
/// XMLTV parser, Xtream adapter, cache and index agree independently of the Live TV view models.
struct EPGProgram: Codable, Hashable, Sendable {
    /// The provider's raw guide channel ID (XMLTV `channel` / Xtream `epg_channel_id`).
    let channelID: String
    let start: Date
    let end: Date
    let title: String
    var subtitle: String?
    var summary: String?
    var category: String?
    /// Display form, for example "S1 E10".
    var episode: String?

    /// Stable identity: a channel airs one programme per start instant.
    var id: String { Self.id(channelID: channelID, start: start) }

    /// The `id` of the programme on `channelID` starting at `start`, for callers that keep only
    /// those two values (program search).
    static func id(channelID: String, start: Date) -> String {
        "\(channelID):\(Int64(start.timeIntervalSince1970.rounded()))"
    }

    func isAiring(at date: Date) -> Bool { start <= date && date < end }
}

/// A `<channel>` entry from an XMLTV document, kept for display-name matching.
struct EPGChannel: Codable, Hashable, Sendable {
    let id: String
    var displayNames: [String]
}

/// Everything parsed from one feed before indexing.
struct EPGDocument: Sendable {
    var channels: [EPGChannel] = []
    var programs: [EPGProgram] = []
    /// Programmes dropped because a mandatory field or timestamp was unusable.
    var malformedCount = 0
    /// True when the parser stopped at its programme limit.
    var isTruncated = false
    /// True when a malformed XMLTV tail stopped parsing after usable entries were read.
    var isIncomplete = false
}

struct EPGNowNext: Equatable, Sendable {
    let current: EPGProgram?
    let next: EPGProgram?

    static let empty = EPGNowNext(current: nil, next: nil)
}

enum EPGError: Error, Equatable, Sendable {
    case invalidSource
    case providerRejected
    case responseTooLarge
    case unsupportedCompression
    case corruptCompressedData
    case malformedFeed
}

/// How usable a guide is. `stale` guides are shown while a refresh is due; `expired` guides are not.
enum EPGFreshness: Equatable, Sendable {
    case missing
    case fresh
    case stale
    case expired

    var isUsable: Bool { self == .fresh || self == .stale }
}

/// Decides when a guide needs refreshing. Pure so tests can drive it with fixed clocks.
struct EPGRefreshPolicy: Sendable {
    /// Age after which a refresh is due while the guide stays visible.
    var refreshInterval: TimeInterval = 12 * 60 * 60
    /// Age after which the guide is hidden. Matches the 36-hour limit Live TV already used.
    var maximumAge: TimeInterval = 36 * 60 * 60
    /// A guide ending sooner than this is due for a refresh even when recently fetched.
    var minimumLookahead: TimeInterval = 3 * 60 * 60
    var minimumRetryDelay: TimeInterval = 5 * 60
    var maximumRetryDelay: TimeInterval = 60 * 60

    func freshness(fetchedAt: Date?, coverageEnd: Date?, programCount: Int, now: Date) -> EPGFreshness {
        guard let fetchedAt else { return .missing }
        let age = now.timeIntervalSince(fetchedAt)
        if age > maximumAge { return .expired }
        // An empty feed has no coverage to judge; its age alone decides.
        if programCount > 0 {
            guard let coverageEnd, coverageEnd > now else { return .expired }
            if coverageEnd.timeIntervalSince(now) < minimumLookahead { return .stale }
        }
        // A clock moved backwards past the fetch still needs a refresh.
        return age > refreshInterval || age < -60 ? .stale : .fresh
    }

    func freshness(of index: EPGIndex, now: Date) -> EPGFreshness {
        freshness(fetchedAt: index.fetchedAt, coverageEnd: index.coverageEnd,
                  programCount: index.programCount, now: now)
    }

    /// Exponential backoff after consecutive failures, so a broken feed is not refetched on every visit.
    func retryDelay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let exponent = Double(min(failures - 1, 16))
        return min(maximumRetryDelay, minimumRetryDelay * pow(2, exponent))
    }
}

/// Size and time bounds for one provider's guide. Defaults keep a full guide within phone and
/// Apple TV memory; tests shrink them.
struct EPGLimits: Sendable {
    var maximumDownloadBytes = 48 * 1024 * 1024
    var maximumXMLBytes = 160 * 1024 * 1024
    /// Programmes the parser keeps before it stops reading a feed.
    var maximumParsedPrograms = 400_000
    var maximumIndexedPrograms = 200_000
    var maximumProgramsPerChannel = 250
    var maximumTextLength = 600
    var pastRetention: TimeInterval = 6 * 60 * 60
    var futureHorizon: TimeInterval = 7 * 24 * 60 * 60
    /// Applied only to timestamps that carry no UTC offset.
    var fallbackTimeZone = TimeZone(secondsFromGMT: 0)!
}

/// The one representation of a guide's fetch time.
///
/// The cache header, record and state file store fetch times as IEEE 754 seconds since 1970, while
/// `Date` holds seconds since 2001. A fractional `Date()` loses its lowest bit in that conversion
/// about half the time, so a guide read back would not equal the one written. `EPGIndex` therefore
/// canonicalizes its fetch time on construction to the value that survives the conversion. The
/// mapping is idempotent and keeps the 1970-based value unchanged, so in-memory guides, cache files
/// and state agree exactly; comparisons stay exact equality, never a tolerance.
enum EPGTimestamp {
    static func canonical(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970)
    }
}
