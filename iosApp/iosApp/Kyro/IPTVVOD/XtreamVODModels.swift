#if os(iOS) || KYRO_VOD_HOST_TESTS
import Foundation

enum XtreamVODKind: String, Codable, CaseIterable, Sendable {
    case movie, series
    var title: String { self == .movie ? "Movies" : "Series" }
    var catalogAction: String { self == .movie ? "get_vod_streams" : "get_series" }
    var categoriesAction: String { self == .movie ? "get_vod_categories" : "get_series_categories" }
}

struct XtreamVODItem: Identifiable, Codable, Hashable, Sendable {
    let providerID: UUID
    let kind: XtreamVODKind
    let remoteID: Int
    let title: String
    let category: String
    let poster: String?
    let fileExtension: String?
    let summary: String?
    let genre: String?
    let rating: String?
    var id: String { "\(providerID.uuidString):\(kind.rawValue):\(remoteID)" }
}

/// Provider titles usually carry their year, e.g. "Heat (1995)" or "Heat - 1995". Silo cards show
/// a year under the title; IPTV cards read it from the title so both sources caption alike.
enum XtreamVODTitle {
    static func year(in title: String) -> Int? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 4 else { return nil }
        var tail = Substring(trimmed)
        let bracketed = tail.hasSuffix(")") || tail.hasSuffix("]")
        if bracketed { tail = tail.dropLast() }
        let digits = tail.suffix(4)
        guard digits.count == 4, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              let year = Int(digits), (1900...2100).contains(year) else { return nil }
        let head = tail.dropLast(4)
        // Only a set-apart year counts: "(1995)", "[1995]" or "- 1995". A bare trailing number
        // is part of the title ("Blade Runner 2049").
        if bracketed { return head.last == "(" || head.last == "[" ? year : nil }
        let separator = head.hasSuffix(" ") ? head.dropLast() : head
        return separator.hasSuffix("-") ? year : nil
    }
}

/// A provider category and how many titles it holds in the active catalog.
struct XtreamVODCategorySummary: Hashable, Sendable, Identifiable {
    let name: String
    let count: Int
    var id: String { name }

    /// Largest first, then by name, so Recommended leads with the provider's main shelves and
    /// the order is stable between launches.
    static func ordered(_ summaries: [XtreamVODCategorySummary]) -> [XtreamVODCategorySummary] {
        summaries.sorted {
            $0.count != $1.count ? $0.count > $1.count
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// The categories Recommended draws as shelves: the largest few, skipping adult and
    /// placeholder groups that panels commonly include.
    static func shelfCategories(_ ordered: [XtreamVODCategorySummary], limit: Int = 8) -> [XtreamVODCategorySummary] {
        let excluded = ["xxx", "adult", "18+", "for adults"]
        return Array(ordered.lazy.filter { summary in
            let name = summary.name.lowercased()
            return summary.count > 0 && name != "other" && !excluded.contains { name.contains($0) }
        }.prefix(limit))
    }
}

struct XtreamVODEpisode: Identifiable, Hashable, Sendable {
    let remoteID: Int
    let season: Int
    let number: Int
    let title: String
    let fileExtension: String?
    let summary: String?
    var id: Int { remoteID }
}

struct XtreamVODDetail: Sendable {
    let summary: String?
    let genre: String?
    let rating: String?
    let duration: TimeInterval?
    let episodes: [XtreamVODEpisode]
    /// Detail-only external ID; never loaded for the whole catalog.
    var tmdbID: Int? = nil
    var releaseYear: Int? = nil
    var director: String? = nil
    var cast: String? = nil
    var writers: String? = nil
    var trailerURL: URL? = nil
}

struct XtreamVODImportCount: Equatable, Sendable {
    /// Source records examined so far. `accepted + malformed + duplicate == processed`.
    let processed: Int
    /// Source records the provider sent. `processed + overLimit == total` once an import ends.
    let total: Int
    let accepted: Int
    let malformed: Int
    let duplicate: Int
    /// Records left out because the catalog is larger than `XtreamVODCatalogLimits.maximumRecords`.
    var overLimit: Int = 0
    var fraction: Double? { total > 0 ? Double(min(processed + overLimit, total)) / Double(total) : nil }
}

/// Ceilings for one catalog import. Records are parsed one at a time from a temporary file, so
/// memory stays bounded by `maximumRecordBytes` plus one insert batch, whatever the catalog size.
/// The transfer cap bounds the temporary file; the record cap bounds the on-device database.
struct XtreamVODCatalogLimits: Equatable, Sendable {
    /// Largest catalog body Kyro downloads. Exceeding it fails the import without touching the
    /// previous catalog.
    var maximumDownloadBytes: Int
    /// Most titles kept per provider and kind. Larger catalogs import this many and report the rest.
    var maximumRecords: Int
    /// Largest single record. Bigger records are skipped and counted as malformed.
    var maximumRecordBytes: Int
    /// Free space kept in reserve beyond the expected download size.
    var reservedDiskBytes: Int

    /// Build 94 buffered the whole body in memory and stopped at 96 MiB or 100,000 movies, which
    /// large providers exceed. A typical movie record is 300–600 bytes and a series record
    /// 1–2 KB, so these ceilings fit catalogs several times the size seen on device.
    static func standard(for kind: XtreamVODKind) -> XtreamVODCatalogLimits {
        switch kind {
        case .movie:
            return .init(maximumDownloadBytes: 384 * 1_048_576, maximumRecords: 400_000,
                         maximumRecordBytes: 256 * 1024, reservedDiskBytes: 64 * 1_048_576)
        case .series:
            return .init(maximumDownloadBytes: 384 * 1_048_576, maximumRecords: 200_000,
                         maximumRecordBytes: 256 * 1024, reservedDiskBytes: 64 * 1_048_576)
        }
    }

    var maximumDownloadMegabytes: Int { maximumDownloadBytes / 1_048_576 }
}

enum XtreamVODImportStage: Equatable {
    case connecting, downloading(XtreamVODKind), importing(XtreamVODKind), ready, failed, cancelled
}

enum XtreamVODCatalogResult: Equatable {
    case notSelected, waiting, loading, ready, empty, unsupported, authentication, failed, cancelled
}

struct XtreamVODImportProgress: Equatable {
    let providerID: UUID
    var stage: XtreamVODImportStage = .connecting
    var movies = XtreamVODImportCount(processed: 0, total: 0, accepted: 0, malformed: 0, duplicate: 0)
    var series = XtreamVODImportCount(processed: 0, total: 0, accepted: 0, malformed: 0, duplicate: 0)
    var movieResult: XtreamVODCatalogResult = .notSelected
    var seriesResult: XtreamVODCatalogResult = .notSelected
    var message: String?
    var failure: XtreamVODError?
    /// The pipeline step that failed first, for sanitized diagnostics and the compact status line.
    var failedStage: XtreamVODPipelineStage?
}

/// Where in the VOD pipeline a refresh stopped. Logged without URLs or credentials.
enum XtreamVODPipelineStage: String, Equatable, Sendable {
    case configuration, storage, authentication, categories, download, parsing, persistence, promotion
}

/// Why a refresh call did or did not start, so every entry point can give visible feedback.
enum XtreamVODRefreshStart: Equatable {
    case started, alreadyRunning, providerMissing, noCatalogsSelected
}

enum XtreamVODError: Error, LocalizedError, Equatable {
    case invalidResponse, unavailable, authentication, unsupported, responseTooLarge, unsupportedFormat
    /// The on-device catalog database could not be created or written.
    case storage
    /// No HTTP response: offline, DNS, TLS, or timeout.
    case network
    /// A non-success HTTP status other than the authentication and unsupported codes.
    case httpStatus(Int)
    /// The saved provider has no usable server, username, or password.
    case configuration
    /// The provider answered but returned zero catalog records.
    case emptyCatalog
    /// The catalog body is larger than the transfer cap for its kind.
    case downloadLimit(megabytes: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The provider returned an invalid Movies or Series catalog. Your previous catalog is unchanged."
        case .unavailable: "The VOD provider is unavailable. Check the connection or credentials and retry."
        case .authentication: "VOD authentication failed. Check the provider credentials and retry."
        case .unsupported: "This provider does not support the requested VOD catalog endpoint."
        case .responseTooLarge: "The VOD catalog exceeds the supported download limit. Your previous catalog is unchanged."
        case .downloadLimit(let megabytes): "The catalog is larger than Kyro's \(megabytes) MB download limit. Your previous catalog is unchanged."
        case .unsupportedFormat: "This provider video format is not supported by the Kyro player."
        case .storage: "Kyro could not open its on-device VOD catalog. Free some device storage, then retry."
        case .network: "The provider could not be reached. Check the network connection, then retry."
        case .httpStatus(let code): "The provider returned HTTP \(code) for the VOD catalog. Retry later."
        case .configuration: "This provider is missing its server, username, or password. Edit the provider, then retry."
        case .emptyCatalog: "The provider returned no titles for this catalog."
        }
    }

    /// Stable, non-sensitive label for logs and diagnostics.
    var category: String {
        switch self {
        case .invalidResponse: "invalid_response"
        case .unavailable: "unavailable"
        case .authentication: "authentication"
        case .unsupported: "unsupported_endpoint"
        case .responseTooLarge, .downloadLimit: "response_too_large"
        case .unsupportedFormat: "unsupported_format"
        case .storage: "storage"
        case .network: "network"
        case .httpStatus: "http_status"
        case .configuration: "configuration"
        case .emptyCatalog: "empty_catalog"
        }
    }

    /// Maps the Live TV account-handshake errors onto VOD categories.
    static func from(_ error: Error) -> XtreamVODError? {
        if let vod = error as? XtreamVODError { return vod }
        switch error as? LiveTVError {
        case .authenticationFailed?, .accountExpired?: return .authentication
        case .invalidXtreamResponse?: return .invalidResponse
        case .invalidConfiguration?: return .configuration
        case .responseTooLarge?: return .responseTooLarge
        default: return nil
        }
    }
}

/// Flexible decoding is limited to the fields Kyro uses. Unknown provider fields are ignored.
struct XtreamVODRecord: Decodable, Sendable {
    let remoteID: Int?
    let title: String?
    let categoryID: String?
    let poster: String?
    let fileExtension: String?
    let summary: String?
    let genre: String?
    let rating: String?

    private enum CodingKeys: String, CodingKey {
        case streamID = "stream_id", seriesID = "series_id", name, categoryID = "category_id"
        case streamIcon = "stream_icon", cover, containerExtension = "container_extension"
        case plot, genre, rating
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        remoteID = Self.int(c, .streamID) ?? Self.int(c, .seriesID)
        title = try? c.decode(String.self, forKey: .name)
        categoryID = Self.string(c, .categoryID)
        poster = Self.string(c, .streamIcon) ?? Self.string(c, .cover)
        fileExtension = Self.string(c, .containerExtension)
        summary = Self.string(c, .plot)
        genre = Self.string(c, .genre)
        rating = Self.string(c, .rating)
    }

    private static func int(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        (try? c.decode(Int.self, forKey: key)) ?? (try? c.decode(String.self, forKey: key)).flatMap(Int.init)
    }
    private static func string(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        (try? c.decode(String.self, forKey: key)) ?? (try? c.decode(Int.self, forKey: key)).map(String.init)
    }
}

enum XtreamVODParser {
    /// Accepts the shapes Xtream panels return in practice: a JSON array; an empty body, `null`, or
    /// `{}` for an empty catalog; an object keyed by ID whose values are records; and arrays that
    /// contain stray `null` or scalar elements. An account object with `auth: 0` is an
    /// authentication failure; HTML or other non-JSON bodies are invalid responses.
    ///
    /// In-memory convenience over `XtreamVODCatalogScanner`, used for small bodies and tests. The
    /// import pipeline scans a downloaded file instead and never holds the whole catalog.
    static func records(_ data: Data, maximumRecordBytes: Int = 256 * 1024) throws -> [XtreamVODRecord] {
        var scanner = XtreamVODCatalogScanner(maximumMemberBytes: maximumRecordBytes)
        var records: [XtreamVODRecord] = []
        var sawAccount = false
        let decoder = JSONDecoder()
        _ = try data.withUnsafeBytes { raw in
            try scanner.consume(raw.bindMemory(to: UInt8.self)) { member in
                if member.key == "user_info" {
                    try rejectAccountObject(member.bytes)
                    sawAccount = true
                    return true
                }
                guard member.isObject, member.key != "server_info", let bytes = member.bytes,
                      let record = record(from: bytes, decoder: decoder) else { return true }
                records.append(record)
                return true
            }
        }
        try scanner.finish()
        // An account object (`user_info`) instead of a catalog is not a list of titles.
        return sawAccount ? [] : records
    }

    /// Decodes one record. A malformed element never discards the rest of the catalog.
    static func record(from bytes: [UInt8], decoder: JSONDecoder) -> XtreamVODRecord? {
        bytes.withUnsafeBufferPointer { buffer in
            try? decoder.decode(XtreamVODRecord.self, from: Data(buffer: buffer))
        }
    }

    /// An account object with `auth: 0` in place of a catalog means the credentials were rejected.
    static func rejectAccountObject(_ bytes: [UInt8]?) throws {
        guard let bytes,
              let user = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else { return }
        let auth = (user["auth"] as? NSNumber)?.intValue ?? (user["auth"] as? String).flatMap(Int.init)
        if auth == 0 { throw XtreamVODError.authentication }
    }

    static func detail(_ data: Data, kind: XtreamVODKind) throws -> XtreamVODDetail {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XtreamVODError.invalidResponse
        }
        let info = root["info"] as? [String: Any] ?? [:]
        let duration = (info["duration_secs"] as? NSNumber)?.doubleValue
            ?? (info["duration_secs"] as? String).flatMap(Double.init)
        var episodes: [XtreamVODEpisode] = []
        if kind == .series, let seasons = root["episodes"] as? [String: Any] {
            for (seasonKey, value) in seasons {
                guard let season = Int(seasonKey), let rows = value as? [[String: Any]] else { continue }
                for row in rows {
                    let id = (row["id"] as? Int) ?? (row["id"] as? String).flatMap(Int.init)
                    guard let id, id > 0 else { continue }
                    let number = (row["episode_num"] as? Int) ?? (row["episode_num"] as? String).flatMap(Int.init) ?? 0
                    let episodeInfo = row["info"] as? [String: Any] ?? [:]
                    episodes.append(.init(remoteID: id, season: season, number: number,
                                          title: clean(row["title"] as? String) ?? "Episode \(number)",
                                          fileExtension: clean(row["container_extension"] as? String),
                                          summary: clean(episodeInfo["plot"] as? String)))
                }
            }
            episodes.sort { ($0.season, $0.number, $0.remoteID) < ($1.season, $1.number, $1.remoteID) }
        }
        var result = XtreamVODDetail(summary: clean(info["plot"] as? String), genre: clean(info["genre"] as? String),
                     rating: (info["rating"] as? String) ?? (info["rating"] as? NSNumber)?.stringValue,
                     duration: duration, episodes: episodes)
        result.tmdbID = (info["tmdb_id"] as? NSNumber)?.intValue
            ?? (info["tmdb_id"] as? String).flatMap(Int.init)
            ?? (info["tmdb"] as? NSNumber)?.intValue
            ?? (info["tmdb"] as? String).flatMap(Int.init)
        if let date = clean((info["releasedate"] as? String) ?? (info["release_date"] as? String)),
           date.count >= 4 {
            result.releaseYear = Int(date.prefix(4))
        }
        result.director = clean(info["director"] as? String)
        result.cast = clean((info["cast"] as? String) ?? (info["actors"] as? String), limit: 1024)
        result.writers = clean((info["writers"] as? String) ?? (info["writer"] as? String))
        result.trailerURL = verifiedTrailerURL(info["youtube_trailer"] as? String)
        return result
    }

    static func verifiedTrailerURL(_ raw: String?) -> URL? {
        guard let raw = clean(raw, limit: 256) else { return nil }
        let url: URL?
        if raw.count == 11, raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) {
            url = URL(string: "https://www.youtube.com/watch?v=\(raw)")
        } else {
            url = URL(string: raw)
        }
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(),
              ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"].contains(host) else { return nil }
        return url
    }

    static func clean(_ value: String?, limit: Int = 512) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return String(value.prefix(limit))
    }

    /// Never persist query-bearing artwork URLs or URLs embedding provider credentials.
    static func safeArtwork(_ raw: String?, username: String, password: String) -> String? {
        guard let raw, raw.utf8.count <= 2048,
              let url = URLComponents(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.query == nil, url.user == nil, url.password == nil,
              url.fragment == nil, !raw.contains(username), !raw.contains(password),
              !(raw.removingPercentEncoding ?? raw).contains(username),
              !(raw.removingPercentEncoding ?? raw).contains(password) else { return nil }
        return raw
    }
}

extension XtreamURLBuilder {
    static func vodAPIURL(server: String, username: String, password: String, action: String,
                          itemID: Int? = nil) throws -> URL {
        var url = try apiURL(server: server, username: username, password: password, action: action)
        if let itemID {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems?.append(URLQueryItem(name: action == "get_vod_info" ? "vod_id" : "series_id", value: String(itemID)))
            guard let built = components.url else { throw LiveTVError.invalidConfiguration }
            url = built
        }
        return url
    }

    static func vodPlaybackURL(server: String, username: String, password: String,
                               kind: XtreamVODKind, itemID: Int, fileExtension: String?) throws -> URL {
        // Xtream panels commonly return Matroska and MPEG-TS containers as well as MP4/HLS.
        // Aether (the app's normal playback engine) probes the response; don't reject a source
        // based on AVPlayer's much smaller extension allowlist before it gets that chance.
        guard itemID > 0, let ext = fileExtension?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !ext.isEmpty, ext.count <= 12,
            ext.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) else {
            throw XtreamVODError.unsupportedFormat
        }
        guard var components = URLComponents(string: server), ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil else { throw LiveTVError.invalidConfiguration }
        let base = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let user = username.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let pass = password.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        components.percentEncodedPath = "/" + [base, kind == .movie ? "movie" : "series", user, pass,
                                                  "\(itemID).\(ext)"].filter { !$0.isEmpty }.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw LiveTVError.invalidConfiguration }
        return url
    }
}
#endif
