import Foundation

/// Normalized keys used to match playlist channels to guide channels.
enum EPGChannelKey {
    /// Guide IDs compare after trimming and case folding; providers mix `BBCOne.uk` and `bbcone.uk`.
    static func guideID(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value.lowercased()
    }

    /// Display names fold case, diacritics and width, drop punctuation and spacing, and ignore
    /// quality tags, so "BBC One HD" and "bbc one" share a key.
    static func name(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                 locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let tokens = folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let kept = tokens.filter { !qualityTags.contains($0) }
        let result = (kept.isEmpty ? tokens : kept).joined()
        return result.isEmpty ? nil : result
    }

    private static let qualityTags: Set<String> = ["hd", "fhd", "uhd", "sd", "4k", "hevc", "h265"]
}

/// The guide channels a playlist can show. Generic XMLTV feeds often list far more channels than a
/// playlist carries, so filtering while parsing keeps memory proportional to the playlist.
struct EPGChannelFilter: Sendable, Equatable {
    private let guideIDs: Set<String>
    private let names: Set<String>

    init(guideIDs: [String?], names: [String]) {
        self.guideIDs = Set(guideIDs.compactMap(EPGChannelKey.guideID))
        self.names = Set(names.compactMap(EPGChannelKey.name))
    }

    func accepts(channelID: String, displayNames: [String]) -> Bool {
        if let key = EPGChannelKey.guideID(channelID), guideIDs.contains(key) { return true }
        return displayNames.contains { EPGChannelKey.name($0).map(names.contains) == true }
    }
}

/// Read API shared by the in-memory guide index and a future on-disk store (Stage B SQLite).
/// Call sites that only need lookups should depend on this protocol, not on storage details.
protocol EPGQuerying: Sendable {
    var fetchedAt: Date { get }
    var programCount: Int { get }
    var isShortGuideOnly: Bool { get }
    var coverageEnd: Date? { get }
    func channelKey(guideID: String?, name: String?) -> String?
    func nowNext(guideID: String?, name: String?, at date: Date) -> EPGNowNext
    func nowNext(channelKey: String, at date: Date) -> EPGNowNext
    func programs(channelKey: String, overlapping interval: DateInterval) -> [EPGProgram]
    /// Whether a lookup for this channel can be answered from memory right now. A disk-backed guide
    /// answers `false` until `prefetch` has loaded the channel; the in-memory index is always resident.
    func isResident(channelKey: String) -> Bool
    /// Loads channels into memory so later lookups never wait on disk. Call off the main actor.
    func prefetch(channelKeys: [String])
}

extension EPGQuerying {
    func isResident(channelKey: String) -> Bool { true }
    func prefetch(channelKeys: [String]) {}
}

/// An immutable, query-ready guide for one provider.
///
/// Each channel's programmes are sorted, deduplicated and non-overlapping, so programme end times
/// strictly increase and every lookup is a binary search.
struct EPGIndex: Sendable, EPGQuerying {
    struct Statistics: Equatable, Sendable {
        var malformed = 0
        var duplicates = 0
        var overlapsTrimmed = 0
        var outsideWindow = 0
        var overLimit = 0
        var truncated = false
        var incomplete = false
    }

    /// Canonical (`EPGTimestamp`), so it compares exactly with the same guide read from cache.
    let fetchedAt: Date
    /// Built only from Xtream short-guide listings, with no full guide underneath. It can be shown,
    /// but it never stands in for the full guide: it doesn't hide a cached one or make a refresh due.
    let isShortGuideOnly: Bool
    /// In-memory mode: every channel. SQLite mode: only channels replaced by a short-guide overlay,
    /// which take precedence over the stored listings.
    private(set) var programsByChannel: [String: [EPGProgram]]
    /// Normalized display name to normalized guide ID. Names shared by different guide channels are
    /// left out, so a name match never shows another channel's guide.
    let channelIDsByName: [String: String]
    private(set) var programCount: Int
    private(set) var coverageEnd: Date?
    private(set) var statistics: Statistics
    /// Set when the base listings live in a SQLite file instead of `programsByChannel`.
    let sqlite: EPGSQLiteIndex?

    static func empty(fetchedAt: Date) -> EPGIndex {
        EPGIndex(fetchedAt: fetchedAt, programsByChannel: [:], channelIDsByName: [:], statistics: Statistics())
    }

    /// A base for short-guide listings when no full guide is loaded.
    static func shortGuideBase(fetchedAt: Date) -> EPGIndex {
        EPGIndex(fetchedAt: fetchedAt, programsByChannel: [:], channelIDsByName: [:], statistics: Statistics(),
                 isShortGuideOnly: true)
    }

    init(fetchedAt: Date, programsByChannel: [String: [EPGProgram]], channelIDsByName: [String: String],
         statistics: Statistics, isShortGuideOnly: Bool = false) {
        self.fetchedAt = EPGTimestamp.canonical(fetchedAt)
        self.isShortGuideOnly = isShortGuideOnly
        self.programsByChannel = programsByChannel
        self.channelIDsByName = channelIDsByName
        self.statistics = statistics
        sqlite = nil
        programCount = programsByChannel.values.reduce(0) { $0 + $1.count }
        coverageEnd = programsByChannel.values.compactMap(\.last?.end).max()
    }

    /// A guide whose listings are stored in SQLite. Overlays added later stay in memory.
    init(sqlite: EPGSQLiteIndex, statistics: Statistics = Statistics(), overlays: [String: [EPGProgram]] = [:],
         programCount: Int? = nil, coverageEnd: Date?? = nil) {
        fetchedAt = sqlite.fetchedAt
        isShortGuideOnly = false
        programsByChannel = overlays
        channelIDsByName = sqlite.guide.names
        self.statistics = statistics
        self.sqlite = sqlite
        self.programCount = programCount ?? sqlite.programCount
        self.coverageEnd = coverageEnd ?? sqlite.coverageEnd
    }

    /// Builds an index from a parsed feed. Synchronous and CPU-bound; call it off the main actor.
    init(document: EPGDocument, fetchedAt: Date, now: Date, limits: EPGLimits) throws {
        var statistics = Statistics(malformed: document.malformedCount, truncated: document.isTruncated,
                                    incomplete: document.isIncomplete)
        let window = Self.window(now: now, limits: limits)
        var grouped: [String: [EPGProgram]] = [:]
        for program in document.programs {
            guard let key = EPGChannelKey.guideID(program.channelID) else { continue }
            grouped[key, default: []].append(program)
        }
        try Task.checkCancellation()

        var normalized: [String: [EPGProgram]] = [:]
        normalized.reserveCapacity(grouped.count)
        var total = 0
        for (key, programs) in grouped {
            let list = Self.normalize(programs, window: window, now: now,
                                      limit: limits.maximumProgramsPerChannel, statistics: &statistics)
            guard !list.isEmpty else { continue }
            normalized[key] = list
            total += list.count
        }
        try Task.checkCancellation()

        if total > limits.maximumIndexedPrograms, !normalized.isEmpty {
            let perChannel = max(1, limits.maximumIndexedPrograms / normalized.count)
            for (key, list) in normalized where list.count > perChannel {
                normalized[key] = Self.nearest(list, to: now, limit: perChannel, statistics: &statistics)
            }
        }

        self.init(fetchedAt: fetchedAt, programsByChannel: normalized,
                  channelIDsByName: Self.nameMap(document.channels), statistics: statistics)
    }

    var channelCount: Int {
        guard let sqlite else { return programsByChannel.count }
        return sqlite.channelCount + programsByChannel.keys.filter { !sqlite.guide.channelKeys.contains($0) }.count
    }

    var isSQLiteBacked: Bool { sqlite != nil }

    private func hasChannel(_ key: String) -> Bool {
        programsByChannel[key] != nil || sqlite?.guide.channelKeys.contains(key) == true
    }

    /// The listings a lookup can use right now. In SQLite mode this never reads disk unless the
    /// index was opened `.readThrough`; nil means missing or not yet loaded.
    private func list(_ key: String) -> [EPGProgram]? {
        if let overlay = programsByChannel[key] { return overlay }
        return sqlite?.listings(channelKey: key)
    }

    func isResident(channelKey: String) -> Bool {
        programsByChannel[channelKey] != nil || (sqlite?.isResident(channelKey: channelKey) ?? true)
    }

    func prefetch(channelKeys: [String]) { sqlite?.prefetch(channelKeys: channelKeys) }

    /// The guide channel for a playlist channel: its guide ID first, then an unambiguous display name.
    func channelKey(guideID: String?, name: String?) -> String? {
        if let key = EPGChannelKey.guideID(guideID), hasChannel(key) { return key }
        if let nameKey = EPGChannelKey.name(name), let key = channelIDsByName[nameKey],
           hasChannel(key) { return key }
        return nil
    }

    func nowNext(guideID: String?, name: String?, at date: Date) -> EPGNowNext {
        guard let key = channelKey(guideID: guideID, name: name) else { return .empty }
        return nowNext(channelKey: key, at: date)
    }

    func nowNext(channelKey: String, at date: Date) -> EPGNowNext {
        guard let list = list(channelKey) else { return .empty }
        return Self.nowNext(in: list, at: date)
    }

    static func nowNext(in list: [EPGProgram], at date: Date) -> EPGNowNext {
        let index = firstIndex(endingAfter: date, in: list)
        guard index < list.count else { return .empty }
        let candidate = list[index]
        guard candidate.start <= date else { return EPGNowNext(current: nil, next: candidate) }
        return EPGNowNext(current: candidate, next: index + 1 < list.count ? list[index + 1] : nil)
    }

    /// Programmes on one channel that overlap `interval`, in airing order.
    func programs(channelKey: String, overlapping interval: DateInterval) -> [EPGProgram] {
        guard let list = list(channelKey) else { return [] }
        return Self.programs(in: list, overlapping: interval)
    }

    /// Matching-only range lookup. Unlike ordinary guide-cell reads, a matcher
    /// must be able to inspect a SQLite-backed channel that is not resident yet.
    /// It reads one bounded channel from the immutable guide and never changes
    /// the normal cached-only residency policy.
    func matchingPrograms(channelKey: String, overlapping interval: DateInterval) -> [EPGProgram] {
        if let overlay = programsByChannel[channelKey] {
            return Self.programs(in: overlay, overlapping: interval)
        }
        if let sqlite {
            let list = sqlite.guide.loadFromDisk(channelKey)
            return Self.programs(in: list, overlapping: interval)
        }
        return programs(channelKey: channelKey, overlapping: interval)
    }

    /// Event matching: programmes on any guide channel that overlap `interval` and whose title,
    /// subtitle or summary opening may mention one of `anchors` (folded, lowercase words). One
    /// bounded pass over the guide instead of one lookup per playlist channel. SQLite-backed guides
    /// answer with a single query; short-guide overlays replace their stored channel.
    func windowPrograms(overlapping interval: DateInterval, anchors: [String],
                        limit: Int = 2_000) -> [(key: String, program: EPGProgram)] {
        windowRows(overlapping: interval, anchors: anchors, limit: limit).rows
    }

    /// `windowPrograms` with a deterministic budget: when more than `limit` programmes qualify, the
    /// ones starting nearest the middle of `interval` are kept (then guide key, then start), and
    /// `truncated` says so. Programmes that also mention any of `excluding` are skipped, so a
    /// second, weaker pass never spends budget on rows an earlier pass already read.
    func windowRows(overlapping interval: DateInterval, anchors: [String], excluding: [String] = [],
                    limit: Int = 2_000) -> EPGWindowRows {
        let words = Array(Set(anchors.filter { !$0.isEmpty })).sorted()
        guard !words.isEmpty, limit > 0 else { return EPGWindowRows() }
        let excluded = Array(Set(excluding.filter { !$0.isEmpty })).sorted()
        let center = interval.start.addingTimeInterval(interval.duration / 2)
        let scanner = EPGAnchorScanner(words: words)
        let excluder = excluded.isEmpty ? nil : EPGAnchorScanner(words: excluded)
        func mentions(_ program: EPGProgram, _ scanner: EPGAnchorScanner) -> Bool {
            scanner.mayMention(program.title) || scanner.mayMention(program.subtitle)
                || scanner.mayMention(program.summary, prefix: 280)
        }
        var window = EPGWindowRows()
        typealias Candidate = (distance: TimeInterval, key: String, program: EPGProgram)
        func precedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            if lhs.key != rhs.key { return lhs.key < rhs.key }
            return lhs.program.start < rhs.program.start
        }
        var kept: [Candidate] = []
        // The worst row kept once the budget has overflowed. Anything after it can never be kept,
        // so it is skipped before the (more expensive) text scan.
        var cutoff: Candidate?
        // Keep at most twice the budget between trims, so a noisy anchor never holds every
        // matching programme of a large in-memory guide.
        func trim() {
            kept.sort(by: precedes)
            guard kept.count > limit else { return }
            kept.removeLast(kept.count - limit)
            window.truncated = true
            cutoff = kept.last
        }
        for (number, entry) in programsByChannel.enumerated() {
            if number.isMultiple(of: 256), Task.isCancelled { return EPGWindowRows(cancelled: true) }
            for program in Self.programs(in: entry.value, overlapping: interval) {
                let candidate = (abs(program.start.timeIntervalSince(center)), entry.key, program)
                if let cutoff, !precedes(candidate, cutoff) { continue }
                guard mentions(program, scanner) else { continue }
                if let excluder, mentions(program, excluder) { continue }
                kept.append(candidate)
                if kept.count >= limit * 2 { trim() }
            }
        }
        if let sqlite {
            let overlays = Set(programsByChannel.keys)
            let stored = sqlite.guide.windowRows(overlapping: interval, anchors: words, excluding: excluded, limit: limit)
            if stored.cancelled { return EPGWindowRows(cancelled: true) }
            window.truncated = window.truncated || stored.truncated
            kept += stored.rows.filter { !overlays.contains($0.key) }
                .map { (abs($0.program.start.timeIntervalSince(center)), $0.key, $0.program) }
        }
        trim()
        window.rows = kept.map { ($0.key, $0.program) }
        return window
    }

    static func programs(in list: [EPGProgram], overlapping interval: DateInterval) -> [EPGProgram] {
        var result: [EPGProgram] = []
        var index = firstIndex(endingAfter: interval.start, in: list)
        while index < list.count, list[index].start < interval.end {
            result.append(list[index])
            index += 1
        }
        return result
    }

    /// Replaces one channel's listings within the span the new programmes cover, keeping the rest.
    /// Used for Xtream short EPG, which is newer than the bulk feed for the hours it covers.
    func replacingPrograms(_ programs: [EPGProgram], guideID: String, now: Date, limits: EPGLimits) -> EPGIndex {
        guard let key = EPGChannelKey.guideID(guideID) else { return self }
        var statistics = self.statistics
        let incoming = Self.normalize(programs, window: Self.window(now: now, limits: limits), now: now,
                                      limit: limits.maximumProgramsPerChannel, statistics: &statistics)
        guard let first = incoming.first, let last = incoming.last else { return self }
        if let sqlite {
            // Runs on the EPG actor, never the main actor, so reading the base listings from disk is fine.
            let existing = programsByChannel[key] ?? sqlite.guide.loadFromDisk(key)
            let kept = existing.filter { $0.end <= first.start || $0.start >= last.end }
            let replacement = Self.normalize(incoming + kept, window: Self.window(now: now, limits: limits),
                                             now: now, limit: limits.maximumProgramsPerChannel,
                                             statistics: &statistics)
            var overlays = programsByChannel
            overlays[key] = replacement
            // Exact coverage: stored channels not overlaid, plus every overlay's last programme.
            let base = sqlite.guide.coverageEnd(excluding: Set(overlays.keys))
            let coverage = ([base] + overlays.values.map { $0.last?.end }).compactMap { $0 }.max()
            return EPGIndex(sqlite: sqlite, statistics: statistics, overlays: overlays,
                            programCount: programCount - existing.count + replacement.count,
                            coverageEnd: .some(coverage))
        }
        let kept = (programsByChannel[key] ?? []).filter { $0.end <= first.start || $0.start >= last.end }
        var merged = programsByChannel
        merged[key] = Self.normalize(incoming + kept, window: Self.window(now: now, limits: limits), now: now,
                                     limit: limits.maximumProgramsPerChannel, statistics: &statistics)
        return EPGIndex(fetchedAt: fetchedAt, programsByChannel: merged, channelIDsByName: channelIDsByName,
                        statistics: statistics, isShortGuideOnly: isShortGuideOnly)
    }

    /// Removes a short-guide-only channel when its overlay is evicted. Full guides never call
    /// this: their base listings must remain available after an overlay expires.
    func removingPrograms(guideID: String) -> EPGIndex {
        guard isShortGuideOnly, sqlite == nil, let key = EPGChannelKey.guideID(guideID), programsByChannel[key] != nil else {
            return self
        }
        var remaining = programsByChannel
        remaining.removeValue(forKey: key)
        return EPGIndex(fetchedAt: fetchedAt, programsByChannel: remaining,
                        channelIDsByName: channelIDsByName, statistics: statistics,
                        isShortGuideOnly: true)
    }

    // MARK: - Building

    private static func window(now: Date, limits: EPGLimits) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-limits.pastRetention),
                     end: now.addingTimeInterval(limits.futureHorizon))
    }

    /// Sorts one channel, keeps the first programme at each start instant, trims a programme that
    /// runs into the next one, and bounds the list around `now`. Deterministic for a given input.
    static func normalize(_ programs: [EPGProgram], window: DateInterval, now: Date, limit: Int,
                                  statistics: inout Statistics) -> [EPGProgram] {
        let ordered = programs.enumerated()
            .filter { item in
                let inside = item.element.end > window.start && item.element.start < window.end
                if !inside { statistics.outsideWindow += 1 }
                return inside
            }
            .sorted { $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start }
            .map(\.element)
        var result: [EPGProgram] = []
        result.reserveCapacity(ordered.count)
        for program in ordered {
            if let previous = result.last {
                if program.start == previous.start {
                    statistics.duplicates += 1
                    continue
                }
                if program.start < previous.end {
                    statistics.overlapsTrimmed += 1
                    result[result.count - 1] = previous.ending(at: program.start)
                }
            }
            result.append(program)
        }
        return nearest(result, to: now, limit: limit, statistics: &statistics)
    }

    /// At most `limit` programmes, mostly upcoming, with a little history before `now`.
    static func nearest(_ list: [EPGProgram], to now: Date, limit: Int,
                                statistics: inout Statistics) -> [EPGProgram] {
        guard list.count > limit else { return list }
        let current = firstIndex(endingAfter: now, in: list)
        let start = max(0, min(current - limit / 8, list.count - limit))
        statistics.overLimit += list.count - limit
        return Array(list[start ..< start + limit])
    }

    static func firstIndex(endingAfter date: Date, in list: [EPGProgram]) -> Int {
        var low = 0
        var high = list.count
        while low < high {
            let middle = (low + high) / 2
            if list[middle].end <= date { low = middle + 1 } else { high = middle }
        }
        return low
    }

    static func nameMap(_ channels: [EPGChannel]) -> [String: String] {
        var map: [String: String] = [:]
        var ambiguous = Set<String>()
        for channel in channels {
            guard let key = EPGChannelKey.guideID(channel.id) else { continue }
            for name in Set(channel.displayNames.compactMap(EPGChannelKey.name)) where !ambiguous.contains(name) {
                if let existing = map[name], existing != key {
                    map[name] = nil
                    ambiguous.insert(name)
                } else {
                    map[name] = key
                }
            }
        }
        return map
    }
}

enum EPGGuideStatus {
    static func message(for index: EPGIndex) -> String? {
        if index.statistics.incomplete { return "Guide feed was incomplete; some listings may be missing." }
        return index.programCount == 0 ? "No guide listings are available yet." : nil
    }
}

private extension EPGProgram {
    func ending(at date: Date) -> EPGProgram {
        EPGProgram(channelID: channelID, start: start, end: date, title: title, subtitle: subtitle,
                   summary: summary, category: category, episode: episode)
    }
}

/// Case-insensitive word prefilter for guide text. ASCII text (nearly every guide) is scanned
/// byte by byte; anything else is folded like the matcher folds it, so no programme is missed.
/// One bounded, anchored guide read for event matching. Rows are ordered nearest start to the
/// middle of the window first, then by guide key and start, in memory and in SQLite alike, so a
/// full budget always keeps the same rows whatever order the guide stores them in.
struct EPGWindowRows: Sendable {
    var rows: [(key: String, program: EPGProgram)] = []
    /// More programmes qualified than the budget allowed; the rest were not read.
    var truncated = false
    /// The calling task was cancelled; `rows` is empty.
    var cancelled = false
}

struct EPGAnchorScanner {
    private let words: [String]
    private let asciiWords: [[UInt8]]

    init(words: [String]) {
        self.words = words
        asciiWords = words.map { Array($0.utf8) }
    }

    func mayMention(_ text: String?, prefix: Int = .max) -> Bool {
        guard let text, !text.isEmpty else { return false }
        var bytes = Array(text.utf8.prefix(prefix))
        if bytes.contains(where: { $0 >= 0x80 }) {
            let folded = String(text.prefix(prefix))
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .lowercased()
            return words.contains { folded.contains($0) }
        }
        for index in bytes.indices where bytes[index] >= 0x41 && bytes[index] <= 0x5A { bytes[index] |= 0x20 }
        return asciiWords.contains { Self.contains($0, in: bytes) }
    }

    private static func contains(_ needle: [UInt8], in haystack: [UInt8]) -> Bool {
        guard let first = needle.first, needle.count <= haystack.count else { return needle.isEmpty }
        var index = 0
        let last = haystack.count - needle.count
        while index <= last {
            if haystack[index] == first {
                var offset = 1
                while offset < needle.count, haystack[index + offset] == needle[offset] { offset += 1 }
                if offset == needle.count { return true }
            }
            index += 1
        }
        return false
    }
}
