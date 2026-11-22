import Foundation
import SQLite3

/// Decides whether one programme text matches a query, exactly as `EPGProgramSearchIndex` does:
/// ASCII text with a query that may use the byte fast path is compared byte by byte with ASCII case
/// folding; every other text is checked with `localizedStandardContains` (`verifiedQuality`).
struct EPGProgramTextMatcher: Sendable {
    typealias MatchQuality = EPGProgramSearchIndex.MatchQuality

    /// The trimmed query Foundation matches.
    let query: String
    /// The folded query bytes when the ASCII fast path applies to ASCII texts.
    private let asciiNeedle: [UInt8]?

    /// Nil for a query shorter than `EPGProgramSearchIndex.minimumQueryLength` after trimming.
    init?(query rawQuery: String, matchingLocale: Locale) {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= EPGProgramSearchIndex.minimumQueryLength else { return nil }
        query = trimmed
        asciiNeedle = EPGProgramSearchIndex.usesASCIIFastPath(query: trimmed, matchingLocale: matchingLocale)
            ? trimmed.utf8.map(EPGProgramSearchIndex.asciiLowercased) : nil
    }

    /// A title's own quality, or `.subtitle` when only the subtitle matches. Title beats subtitle.
    func programQuality(title: String, subtitle: String?) -> MatchQuality? {
        var title = title
        if let quality = title.withUTF8({ quality(of: $0) }) { return quality }
        guard var subtitle else { return nil }
        return subtitle.withUTF8({ quality(of: $0) }) != nil ? .subtitle : nil
    }

    /// One text's match quality; `text` is UTF-8.
    func quality(of text: UnsafeBufferPointer<UInt8>) -> MatchQuality? {
        guard !text.isEmpty else { return nil }
        if let decided = byteQuality(of: text) { return decided }
        return foundationQuality(of: String(decoding: text, as: UTF8.self))
    }

    /// Whether `text` is decided by the byte fast path; otherwise it needs `foundationQuality`.
    func usesBytes(_ text: UnsafeBufferPointer<UInt8>) -> Bool {
        asciiNeedle != nil && !text.contains(where: { $0 >= 0x80 })
    }

    /// The fast-path decision for a text `usesBytes` accepts: `.some(nil)` is a decided non-match.
    /// Nil when the text needs Foundation.
    func byteQuality(of text: UnsafeBufferPointer<UInt8>) -> MatchQuality?? {
        guard let asciiNeedle, usesBytes(text) else { return nil }
        return .some(Self.asciiQuality(text, needle: asciiNeedle))
    }

    func foundationQuality(of text: String) -> MatchQuality? {
        autoreleasepool { EPGProgramSearchIndex.verifiedQuality(text: text as NSString, query: query) }
    }

    /// Best quality over every occurrence, as the in-memory byte scan ranks them: the start of the
    /// text, then after a non-word byte, then anywhere.
    private static func asciiQuality(_ text: UnsafeBufferPointer<UInt8>, needle: [UInt8]) -> MatchQuality? {
        let count = needle.count
        guard count > 0, count <= text.count else { return nil }
        return needle.withUnsafeBufferPointer { needle in
            let first = needle[0]
            var best: MatchQuality?
            var position = 0
            let last = text.count - count
            while position <= last {
                if EPGProgramSearchIndex.asciiLowercased(text[position]) == first {
                    var offset = 1
                    while offset < count, EPGProgramSearchIndex.asciiLowercased(text[position + offset]) == needle[offset] {
                        offset += 1
                    }
                    if offset == count {
                        if position == 0 { return .titlePrefix }
                        // Only position 0 can do better, and it is behind us.
                        if !EPGProgramSearchIndex.isASCIIWordByte(text[position - 1]) { return .titleWordPrefix }
                        best = .titleSubstring
                    }
                }
                position += 1
            }
            return best
        }
    }
}

/// Program search over a SQLite-backed guide, without loading the guide into memory.
///
/// Built once per identity (provider, catalog revision, guide generation). It keeps only the
/// playlist mapping (guide channel key to the first playlist channel that maps to it) and a reference
/// to the published guide, which holds the file lease for as long as a search may read it.
///
/// Each search opens its own read-only connection to the immutable guide file, so it never holds
/// the connection lock that guide residency and event matching use. One bounded statement scans the
/// programmes that have not ended (at most `EPGLimits.maximumIndexedPrograms` rows), matches titles
/// and subtitles with `EPGProgramTextMatcher` through a SQL function, and lets SQLite keep only the
/// best `limit` rows (`ORDER BY … LIMIT`). Short-guide overlays replace their stored channel and are
/// matched in memory. Ranking and matching equal `EPGProgramSearchIndex` for the same guide.
struct EPGSQLiteProgramSearch: Sendable {
    typealias Identity = EPGProgramSearchIndex.Identity
    typealias Match = EPGProgramSearchIndex.Match
    typealias MatchQuality = EPGProgramSearchIndex.MatchQuality

    enum Outcome: Equatable, Sendable {
        case results([Match])
        /// The guide file could not be opened or read.
        case storageUnavailable
    }

    struct Slot: Sendable {
        let id: String
        let name: String
        let ordinal: Int
    }

    let identity: Identity
    /// Keeps the guide (and its file lease) alive while this source exists.
    private let guide: EPGIndex
    private let sqlite: EPGSQLiteGuide
    /// Guide channel key to its playlist channel, for every mapped key.
    private let slots: [String: Slot]
    /// Playlist ordinals of mapped channels whose listings are read from the file (not overlaid).
    private let storedOrdinals: [String: Int]

    private init?(identity: Identity, guide: EPGIndex, channels: [EPGProgramChannel]) {
        guard let sqlite = guide.sqlite?.guide else { return nil }
        self.identity = identity
        self.guide = guide
        self.sqlite = sqlite
        // First playlist channel per guide channel wins, as in the in-memory index.
        var slots: [String: Slot] = [:]
        for channel in channels {
            let ordinal = channel.ordinal
            if ordinal.isMultiple(of: 256), Task.isCancelled { return nil }
            guard let key = guide.channelKey(guideID: channel.guideID, name: channel.name),
                  slots[key] == nil else { continue }
            slots[key] = Slot(id: channel.id, name: channel.name, ordinal: ordinal)
        }
        var stored: [String: Int] = [:]
        stored.reserveCapacity(slots.count)
        for (key, slot) in slots where guide.programsByChannel[key] == nil && sqlite.channelKeys.contains(key) {
            stored[key] = slot.ordinal
        }
        self.slots = slots
        storedOrdinals = stored
    }

    /// Builds off the caller's actor. Nil when cancelled or for a guide that is not SQLite-backed.
    static func prepare(identity: Identity, guide: EPGIndex, channels: [EPGProgramChannel]) async -> Self? {
        let worker: Task<Self?, Never> = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return nil }
            return Self(identity: identity, guide: guide, channels: channels)
        }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: {
            worker.cancel()
        })
    }

    static func prepare(identity: Identity, guide: EPGIndex, channels: [LiveTVChannel]) async -> Self? {
        let associations = channels.enumerated().map {
            EPGProgramChannel(id: $0.element.id, guideID: $0.element.guideID,
                              name: $0.element.name, ordinal: $0.offset)
        }
        return await prepare(identity: identity, guide: guide, channels: associations)
    }

    var mappedChannelCount: Int { slots.count }

    /// Matches whose programme has not ended at `now`: live first, then upcoming by start time.
    /// Empty for a query under two characters; nil when cancelled.
    func search(query: String, now: Date, limit: Int = EPGProgramSearchIndex.defaultResultLimit,
                matchingLocale: Locale = .current) async -> Outcome? {
        let worker = Task.detached(priority: .userInitiated) {
            self.searchMatches(query: query, now: now, limit: limit, matchingLocale: matchingLocale)
        }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: {
            worker.cancel()
        })
    }

    private struct Candidate {
        let key: String
        let rawChannelID: String
        let title: String
        let subtitle: String?
        let start: Date
        let end: Date
        let quality: MatchQuality
        let ordinal: Int
        let isLive: Bool
    }

    /// Ranks exactly as `EPGProgramSearchIndex`: live programmes by quality, then playlist order;
    /// upcoming ones by start time, then quality, then playlist order. A channel airs one programme
    /// per start instant and each guide channel has one ordinal, so the order is total.
    private static func ranksBefore(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.isLive != rhs.isLive { return lhs.isLive }
        if lhs.isLive {
            return (lhs.quality, lhs.ordinal, lhs.start) < (rhs.quality, rhs.ordinal, rhs.start)
        }
        return (lhs.start, lhs.quality, lhs.ordinal) < (rhs.start, rhs.quality, rhs.ordinal)
    }

    /// The same order in SQL. `?1` is `now`; live means `start_s <= now`.
    private static let rankedSQL = """
    SELECT channel_key, start_s, end_s, channel_id, title, subtitle, q, ord FROM (
        SELECT channel_key, start_s, end_s, channel_id, title, subtitle,
               kyro_program_ordinal(channel_key) AS ord, kyro_program_quality(title, subtitle) AS q
        FROM programmes WHERE end_s > ?1)
    WHERE ord IS NOT NULL AND q IS NOT NULL
    ORDER BY start_s > ?1,
             CASE WHEN start_s <= ?1 THEN q END, CASE WHEN start_s <= ?1 THEN ord END,
             start_s, q, ord
    LIMIT ?2
    """

    private func searchMatches(query: String, now: Date, limit: Int, matchingLocale: Locale) -> Outcome? {
        guard let matcher = EPGProgramTextMatcher(query: query, matchingLocale: matchingLocale), limit > 0 else {
            return .results([])
        }
        var candidates: [Candidate] = []

        // Short-guide overlays replace their stored channel; they are small and already in memory.
        for (key, list) in guide.programsByChannel {
            if Task.isCancelled { return nil }
            guard let slot = slots[key] else { continue }
            for program in list where program.end > now {
                guard let quality = matcher.programQuality(title: program.title, subtitle: program.subtitle) else { continue }
                candidates.append(Candidate(key: key, rawChannelID: program.channelID, title: program.title,
                                            subtitle: program.subtitle, start: program.start, end: program.end,
                                            quality: quality, ordinal: slot.ordinal, isLive: program.start <= now))
            }
        }

        if !storedOrdinals.isEmpty {
            guard let stored = storedMatches(matcher: matcher, now: now, limit: limit) else {
                return Task.isCancelled ? nil : .storageUnavailable
            }
            candidates += stored
        }
        if Task.isCancelled { return nil }
        candidates.sort(by: Self.ranksBefore)
        let matches = candidates.prefix(limit).compactMap { candidate -> Match? in
            guard let slot = slots[candidate.key] else { return nil }
            return Match(programID: EPGProgram.id(channelID: candidate.rawChannelID, start: candidate.start),
                         channelKey: candidate.key, channelID: slot.id, channelName: slot.name,
                         channelOrdinal: slot.ordinal, title: candidate.title, subtitle: candidate.subtitle,
                         start: candidate.start, end: candidate.end, isLive: candidate.isLive,
                         quality: candidate.quality)
        }
        return Task.isCancelled ? nil : .results(matches)
    }

    /// The best `limit` stored matches, or nil when cancelled or the file can't be read.
    private func storedMatches(matcher: EPGProgramTextMatcher, now: Date, limit: Int) -> [Candidate]? {
        let url = sqlite.url
        // The published guide holds a lease on its file while `self` is alive; this connection takes
        // its own for its lifetime, so a cache sweep never unlinks the file under it.
        EPGSQLiteFileLeases.acquire(url)
        defer { EPGSQLiteFileLeases.release(url) }
        guard FileManager.default.fileExists(atPath: url.path),
              let connection = try? EPGSQLiteConnection.openReadOnly(url) else { return nil }
        defer { connection.close() }

        let functions = SQLFunctions(matcher: matcher, ordinals: storedOrdinals)
        return withExtendedLifetime(functions) {
            try? connection.withHandle { db -> [Candidate]? in
                guard functions.register(on: db) else { return nil }
                // Cancellation interrupts the scan between rows, not only between returned matches.
                sqlite3_progress_handler(db, 2_048, { _ in Task.isCancelled ? 1 : 0 }, nil)
                defer { sqlite3_progress_handler(db, 0, nil, nil) }
                let statement = try EPGSQLiteStatement(db, Self.rankedSQL)
                defer { statement.finalize() }
                statement.bind(1, now.timeIntervalSinceReferenceDate)
                statement.bind(2, Int64(clamping: limit))
                var rows: [Candidate] = []
                while try statement.step() {
                    guard let key = statement.text(0),
                          let quality = MatchQuality(rawValue: Int(statement.int64(6))) else { continue }
                    let start = Date(timeIntervalSinceReferenceDate: statement.double(1))
                    rows.append(Candidate(key: key, rawChannelID: statement.text(3) ?? key,
                                          title: statement.text(4) ?? "", subtitle: statement.text(5),
                                          start: start, end: Date(timeIntervalSinceReferenceDate: statement.double(2)),
                                          quality: quality, ordinal: Int(statement.int64(7)), isLive: start <= now))
                }
                return Task.isCancelled ? nil : rows
            }
        }
    }

    /// The two SQL functions the ranked statement calls, registered on this search's own connection.
    /// Called on the thread that steps the statement, one row at a time.
    private final class SQLFunctions {
        let matcher: EPGProgramTextMatcher
        let ordinals: [String: Int]
        /// Rows arrive in primary-key order, grouped by channel, so the last key almost always repeats.
        private var lastKey: [UInt8] = []
        private var lastOrdinal: Int?
        /// Foundation decisions for this query, by text. Guides repeat titles heavily; the in-memory
        /// index gets the same saving by interning. Bounded so a guide of unique texts stays bounded.
        private var foundationCache: [String: MatchQuality?] = [:]
        static let foundationCacheLimit = 32_768

        init(matcher: EPGProgramTextMatcher, ordinals: [String: Int]) {
            self.matcher = matcher
            self.ordinals = ordinals
        }

        func register(on db: OpaquePointer) -> Bool {
            let context = Unmanaged.passUnretained(self).toOpaque()
            let flags = SQLITE_UTF8 | SQLITE_DETERMINISTIC
            let quality = sqlite3_create_function_v2(db, "kyro_program_quality", 2, flags, context, { context, count, values in
                guard let context, count == 2, let values else { return sqlite3_result_null(context) }
                let functions = Unmanaged<SQLFunctions>.fromOpaque(sqlite3_user_data(context)).takeUnretainedValue()
                guard let title = SQLFunctions.utf8(values[0]) else { return sqlite3_result_null(context) }
                let subtitle = SQLFunctions.utf8(values[1])
                if let match = functions.programQuality(title: title, subtitle: subtitle) {
                    sqlite3_result_int64(context, Int64(match.rawValue))
                } else {
                    sqlite3_result_null(context)
                }
            }, nil, nil, nil)
            let ordinal = sqlite3_create_function_v2(db, "kyro_program_ordinal", 1, flags, context, { context, count, values in
                guard let context, count == 1, let values else { return sqlite3_result_null(context) }
                let functions = Unmanaged<SQLFunctions>.fromOpaque(sqlite3_user_data(context)).takeUnretainedValue()
                guard let key = SQLFunctions.utf8(values[0]), let ordinal = functions.ordinal(for: key) else {
                    return sqlite3_result_null(context)
                }
                sqlite3_result_int64(context, Int64(ordinal))
            }, nil, nil, nil)
            return quality == SQLITE_OK && ordinal == SQLITE_OK
        }

        /// `EPGProgramTextMatcher.programQuality`, with Foundation decisions memoized per text.
        private func programQuality(title: UnsafeBufferPointer<UInt8>,
                                    subtitle: UnsafeBufferPointer<UInt8>?) -> MatchQuality? {
            if let quality = quality(of: title) { return quality }
            if let subtitle, quality(of: subtitle) != nil { return .subtitle }
            return nil
        }

        private func quality(of text: UnsafeBufferPointer<UInt8>) -> MatchQuality? {
            guard !text.isEmpty else { return nil }
            if let decided = matcher.byteQuality(of: text) { return decided }
            let string = String(decoding: text, as: UTF8.self)
            if let cached = foundationCache[string] { return cached }
            let quality = matcher.foundationQuality(of: string)
            if foundationCache.count < Self.foundationCacheLimit { foundationCache[string] = quality }
            return quality
        }

        private func ordinal(for key: UnsafeBufferPointer<UInt8>) -> Int? {
            if key.elementsEqual(lastKey) { return lastOrdinal }
            lastKey = Array(key)
            lastOrdinal = ordinals[String(decoding: key, as: UTF8.self)]
            return lastOrdinal
        }

        /// A text argument's UTF-8 bytes, valid until the function returns. Nil for SQL NULL.
        private static func utf8(_ value: OpaquePointer?) -> UnsafeBufferPointer<UInt8>? {
            guard let value, sqlite3_value_type(value) != SQLITE_NULL,
                  let pointer = sqlite3_value_text(value) else { return nil }
            return UnsafeBufferPointer(start: pointer, count: Int(sqlite3_value_bytes(value)))
        }
    }
}
