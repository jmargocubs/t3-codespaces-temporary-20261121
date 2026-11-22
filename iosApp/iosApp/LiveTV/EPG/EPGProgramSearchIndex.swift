import Foundation

struct EPGProgramChannel: Sendable {
    let id: String
    let guideID: String?
    let name: String
    let ordinal: Int

    init(id: String, guideID: String?, name: String, ordinal: Int) {
        self.id = id
        self.guideID = guideID
        self.name = name
        self.ordinal = ordinal
    }
}

/// An immutable, provider-scoped search projection of the in-memory guide: program titles and
/// subtitles, each tied to the first playlist channel that maps to its guide channel.
///
/// It keeps interned text, compact postings and channel IDs/names only. It never retains
/// `LiveTVChannel` (stream and logo URLs), `EPGProgram` values or the `EPGIndex`, so an old guide is
/// freed as soon as the service replaces it. Matching follows `localizedStandardContains`, like the
/// channel search. A caller resolves returned channel IDs against the same catalog before playing.
struct EPGProgramSearchIndex: Sendable {
    struct Identity: Hashable, Sendable {
        let providerID: UUID
        let catalogRevision: Int
        let guideGeneration: Int
    }

    enum MatchQuality: Int, Comparable, Sendable {
        case titlePrefix = 0, titleWordPrefix, titleSubstring, subtitle
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Match: Equatable, Sendable {
        let programID: String
        let channelKey: String
        let channelID: String
        let channelName: String
        let channelOrdinal: Int
        let title: String
        let subtitle: String?
        let start: Date
        let end: Date
        let isLive: Bool
        let quality: MatchQuality
    }

    static let minimumQueryLength = 2
    static let defaultResultLimit = 300
    /// Internal tuning. `production` is deliberately conservative: Foundation matching shares the
    /// device with playback (Picture in Picture can be running) and the UI, and iPhone and Apple TV
    /// have two performance cores. Benchmarks pass their own value; nothing reads device models.
    struct Configuration: Equatable, Sendable {
        /// Most child tasks one search fans Foundation matching out to. At least 1.
        var foundationWorkerLimit: Int

        static let production = Configuration(
            foundationWorkerLimit: min(2, max(1, ProcessInfo.processInfo.activeProcessorCount - 1)))

        init(foundationWorkerLimit: Int) {
            self.foundationWorkerLimit = max(1, foundationWorkerLimit)
        }
    }

    let identity: Identity
    let configuration: Configuration
    let programCount: Int
    let uniqueTextCount: Int
    let estimatedStorageBytes: Int

    private struct Posting: Sendable {
        let titleText: Int32
        let subtitleText: Int32
        let channel: Int32
        /// The programme's raw guide channel ID, interned; it forms `EPGProgram.id`.
        let rawChannelID: Int32
        let start: TimeInterval
        let end: TimeInterval
    }

    private struct Channel: Sendable {
        let key: String
        let id: String
        let name: String
        let ordinal: Int
    }

    private struct Candidate {
        let posting: Int32
        let quality: UInt8
        let isLive: Bool
        let start: TimeInterval
        let ordinal: Int
    }

    /// Where each interned text lives: its Foundation block group (high bit set for non-ASCII) and
    /// position. The blocks are the only copy of the original text.
    private let textLocations: [UInt32]
    /// ASCII texts lowercased byte by byte, each followed by a NUL byte, searched with `memmem`.
    /// `asciiStarts[i]` is the byte offset of `asciiTextIDs[i]`. Nothing here depends on a locale:
    /// whether a query may use it is decided per query (see `usesASCIIFastPath`).
    private let asciiBytes: [UInt8]
    private let asciiStarts: [Int]
    private let asciiTextIDs: [Int32]
    /// The same ASCII texts for Foundation matching, used for a non-ASCII query or a Turkish/Azeri
    /// locale, and every non-ASCII text, which always uses Foundation.
    private let asciiFoundationTexts: FoundationTexts
    private let otherFoundationTexts: FoundationTexts
    private let foundationMatching: FoundationMatching

    /// How texts that need Foundation are scanned. Both decide every match with a per-text
    /// `localizedStandardContains`; `.perText` exists so tests can compare against it.
    enum FoundationMatching: Sendable {
        /// Foundation finds the first match in a block of texts; only the text it lands in is checked.
        case blocks
        /// Every text is checked on its own (the P1 behavior).
        case perText
    }
    private let postings: [Posting]
    private let channelSlots: [Channel]
    private let rawChannelIDs: [String]
    /// Postings per text, flattened: text `t` owns `textPostings[textPostingStarts[t] ..< textPostingStarts[t + 1]]`.
    /// One array instead of one per text saves an allocation per interned text.
    private let textPostingStarts: [Int32]
    private let textPostings: [Int32]

    private init?(identity: Identity, guide: EPGIndex, channels: [EPGProgramChannel], now: Date,
                  configuration: Configuration, foundationMatching: FoundationMatching) {
        guard !guide.isSQLiteBacked else { return nil }
        self.identity = identity
        self.configuration = configuration
        self.foundationMatching = foundationMatching

        // First playlist channel per guide channel wins; later duplicates (HD/SD variants) are dropped.
        var channelByKey: [String: Int] = [:]
        var builtChannels: [Channel] = []
        for channel in channels {
            let ordinal = channel.ordinal
            if ordinal.isMultiple(of: 256), Task.isCancelled { return nil }
            guard let key = guide.channelKey(guideID: channel.guideID, name: channel.name),
                  channelByKey[key] == nil else { continue }
            channelByKey[key] = builtChannels.count
            builtChannels.append(Channel(key: key, id: channel.id, name: channel.name, ordinal: ordinal))
        }

        var builtTexts: [String] = []
        var builtIsASCII: [Bool] = []
        var textIDs: [String: Int] = [:]
        var rawIDs: [String] = []
        var rawIDIndex: [String: Int32] = [:]
        var builtPostings: [Posting] = []
        func intern(_ value: String) -> Int {
            if let existing = textIDs[value] { return existing }
            let index = builtTexts.count
            textIDs[value] = index
            builtTexts.append(value)
            builtIsASCII.append(value.utf8.allSatisfy { $0 < 128 })
            return index
        }
        for (slot, channel) in builtChannels.enumerated() {
            if Task.isCancelled { return nil }
            guard let programs = guide.programsByChannel[channel.key] else { continue }
            for program in programs where program.end > now {
                let title = intern(program.title)
                let subtitle = program.subtitle.map(intern) ?? -1
                let raw: Int32
                if let existing = rawIDIndex[program.channelID] { raw = existing } else {
                    raw = Int32(rawIDs.count)
                    rawIDIndex[program.channelID] = raw
                    rawIDs.append(program.channelID)
                }
                builtPostings.append(Posting(titleText: Int32(title), subtitleText: Int32(subtitle),
                                             channel: Int32(slot), rawChannelID: raw,
                                             start: program.start.timeIntervalSince1970,
                                             end: program.end.timeIntervalSince1970))
            }
        }

        // Postings per text in posting order, as offsets into one flat array.
        var postingStarts = [Int32](repeating: 0, count: builtTexts.count + 1)
        for posting in builtPostings {
            postingStarts[Int(posting.titleText) + 1] += 1
            if posting.subtitleText >= 0, posting.subtitleText != posting.titleText {
                postingStarts[Int(posting.subtitleText) + 1] += 1
            }
        }
        for text in 0..<builtTexts.count { postingStarts[text + 1] += postingStarts[text] }
        var cursor = Array(postingStarts.dropLast())
        var flatPostings = [Int32](repeating: 0, count: Int(postingStarts.last ?? 0))
        for (index, posting) in builtPostings.enumerated() {
            if index.isMultiple(of: 4_096), Task.isCancelled { return nil }
            let title = Int(posting.titleText)
            flatPostings[Int(cursor[title])] = Int32(index)
            cursor[title] += 1
            if posting.subtitleText >= 0, posting.subtitleText != posting.titleText {
                let subtitle = Int(posting.subtitleText)
                flatPostings[Int(cursor[subtitle])] = Int32(index)
                cursor[subtitle] += 1
            }
        }

        var bytes: [UInt8] = []
        var starts: [Int] = []
        var asciiIDs: [Int32] = []
        var otherIDs: [Int32] = []
        for (id, text) in builtTexts.enumerated() {
            if id.isMultiple(of: 256), Task.isCancelled { return nil }
            if builtIsASCII[id] {
                starts.append(bytes.count)
                asciiIDs.append(Int32(id))
                bytes.append(contentsOf: text.utf8.map(Self.asciiLowercased))
                bytes.append(0)
            } else {
                otherIDs.append(Int32(id))
            }
        }

        guard let asciiFoundation = FoundationTexts(ids: asciiIDs, texts: builtTexts, isASCII: true),
              let otherFoundation = FoundationTexts(ids: otherIDs, texts: builtTexts, isASCII: false) else { return nil }
        var locations = [UInt32](repeating: 0, count: builtTexts.count)
        for (position, id) in asciiIDs.enumerated() { locations[Int(id)] = UInt32(position) }
        for (position, id) in otherIDs.enumerated() { locations[Int(id)] = Self.nonASCIILocation | UInt32(position) }

        textLocations = locations
        asciiBytes = bytes
        asciiStarts = starts
        asciiTextIDs = asciiIDs
        asciiFoundationTexts = asciiFoundation
        otherFoundationTexts = otherFoundation
        postings = builtPostings
        channelSlots = builtChannels
        rawChannelIDs = rawIDs
        textPostingStarts = postingStarts
        textPostings = flatPostings
        programCount = builtPostings.count
        uniqueTextCount = builtTexts.count

        // Deterministic payload estimate (text in blocks plus fixed strides), not allocator/RSS
        // overhead. Text bytes are counted in the Foundation blocks, their only copy.
        let textBytes = locations.count * MemoryLayout<UInt32>.stride
        let listBytes = (postingStarts.count + flatPostings.count) * MemoryLayout<Int32>.stride
        let channelBytes = builtChannels.reduce(MemoryLayout<Channel>.stride * builtChannels.count) {
            $0 + $1.key.utf8.count + $1.id.utf8.count + $1.name.utf8.count
        }
        estimatedStorageBytes = textBytes + listBytes + channelBytes + bytes.count
            + builtPostings.count * MemoryLayout<Posting>.stride
            + starts.count * 8 + asciiIDs.count * 4
            + asciiFoundation.estimatedBytes + otherFoundation.estimatedBytes
            + rawIDs.reduce(0) { $0 + $1.utf8.count + MemoryLayout<String>.stride }
    }

    /// Builds off the caller's actor. Nil only when cancelled or for a SQLite-backed guide.
    static func build(identity: Identity, guide: EPGIndex, channels: [EPGProgramChannel], now: Date,
                      configuration: Configuration = .production,
                      foundationMatching: FoundationMatching = .blocks) async -> Self? {
        let worker: Task<Self?, Never> = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return nil }
            return Self(identity: identity, guide: guide, channels: channels, now: now, configuration: configuration,
                        foundationMatching: foundationMatching)
        }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: {
            worker.cancel()
        })
    }

    static func build(identity: Identity, guide: EPGIndex, channels: [LiveTVChannel], now: Date,
                      configuration: Configuration = .production,
                      foundationMatching: FoundationMatching = .blocks) async -> Self? {
        let associations = channels.enumerated().map {
            EPGProgramChannel(id: $0.element.id, guideID: $0.element.guideID,
                              name: $0.element.name, ordinal: $0.offset)
        }
        return await build(identity: identity, guide: guide, channels: associations, now: now,
                           configuration: configuration, foundationMatching: foundationMatching)
    }

    /// Matches whose programme has not ended at `now`: live first, then upcoming by start time.
    /// Empty for a query under two characters; nil when cancelled.
    ///
    /// `matchingLocale` must be the locale Foundation matches in, which is the process's current
    /// locale; it is read per query, so a locale change never meets a stale decision.
    func search(query: String, now: Date, limit: Int = defaultResultLimit,
                matchingLocale: Locale = .current) async -> [Match]? {
        let worker = Task.detached(priority: .userInitiated) {
            await self.searchMatches(query: query, now: now, limit: limit, matchingLocale: matchingLocale)
        }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: {
            worker.cancel()
        })
    }

    /// Whether `query` may use the ASCII byte search under `matchingLocale`. For ASCII text and an
    /// ASCII query, `localizedStandardContains` equals ASCII case-insensitive substring search in
    /// every locale except Turkish and Azeri, whose dotted and dotless I change ASCII casing
    /// (checked across 40 locales, including ones with collation contractions such as cs, hu, da, cy).
    static func usesASCIIFastPath(query trimmed: String, matchingLocale: Locale) -> Bool {
        // NUL separates texts in the byte buffer, so a query holding one takes the Foundation path.
        trimmed.utf8.allSatisfy { $0 < 128 && $0 != 0 } && !needsLocaleSensitiveMatching(matchingLocale)
    }

    private func searchMatches(query: String, now: Date, limit: Int, matchingLocale: Locale) async -> [Match]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumQueryLength else { return [] }

        // Best quality per text, from the matcher that `localizedStandardContains` semantics allow.
        var textQuality: [(text: Int32, quality: MatchQuality)] = []
        let foundationGroups: [FoundationTexts]
        if Self.usesASCIIFastPath(query: trimmed, matchingLocale: matchingLocale) {
            guard scanASCII(trimmed.utf8.map(Self.asciiLowercased), into: &textQuality) else { return nil }
            foundationGroups = [otherFoundationTexts]
        } else {
            foundationGroups = [asciiFoundationTexts, otherFoundationTexts]
        }
        guard let foundationMatches = await foundationQualities(in: foundationGroups, query: trimmed) else { return nil }
        textQuality += foundationMatches

        // Expand to postings, keeping each posting's best quality (title beats subtitle).
        let nowSeconds = now.timeIntervalSince1970
        var best = [UInt8](repeating: .max, count: postings.count)
        var touched: [Int32] = []
        for (offset, match) in textQuality.enumerated() {
            if offset.isMultiple(of: 64), Task.isCancelled { return nil }
            let text = Int(match.text)
            for posting in textPostings[Int(textPostingStarts[text]) ..< Int(textPostingStarts[text + 1])] {
                let entry = postings[Int(posting)]
                guard entry.end > nowSeconds else { continue }
                let quality = entry.titleText == match.text ? match.quality : .subtitle
                let raw = UInt8(quality.rawValue)
                if best[Int(posting)] == .max { touched.append(posting) }
                if raw < best[Int(posting)] { best[Int(posting)] = raw }
            }
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(touched.count)
        for posting in touched {
            let entry = postings[Int(posting)]
            candidates.append(Candidate(posting: posting, quality: best[Int(posting)], isLive: entry.start <= nowSeconds,
                                        start: entry.start, ordinal: channelSlots[Int(entry.channel)].ordinal))
        }
        if Task.isCancelled { return nil }
        candidates.sort { lhs, rhs in
            if lhs.isLive != rhs.isLive { return lhs.isLive }
            if lhs.isLive {
                return (lhs.quality, lhs.ordinal, lhs.start, lhs.posting) < (rhs.quality, rhs.ordinal, rhs.start, rhs.posting)
            }
            return (lhs.start, lhs.quality, lhs.ordinal, lhs.posting) < (rhs.start, rhs.quality, rhs.ordinal, rhs.posting)
        }
        if Task.isCancelled { return nil }
        return candidates.prefix(max(0, limit)).map(makeMatch)
    }

    /// Byte search over folded ASCII texts. Equivalent to `localizedStandardContains` there: both
    /// sides are ASCII, and the locale is not one with special casing (Turkish/Azeri).
    private func scanASCII(_ query: [UInt8], into result: inout [(text: Int32, quality: MatchQuality)]) -> Bool {
        guard !query.isEmpty, !asciiBytes.isEmpty else { return true }
        var cancelled = false
        asciiBytes.withUnsafeBytes { buffer in
            query.withUnsafeBytes { needle in
                guard let base = buffer.baseAddress, let needleBase = needle.baseAddress else { return }
                var offset = 0
                var lastText = -1
                var lastQuality = MatchQuality.titleSubstring
                var hits = 0
                while offset < buffer.count,
                      let found = memmem(base + offset, buffer.count - offset, needleBase, needle.count) {
                    hits += 1
                    if hits.isMultiple(of: 256), Task.isCancelled { cancelled = true; return }
                    let position = UnsafeRawPointer(found) - base
                    let slot = Self.slot(containing: position, in: asciiStarts)
                    let start = asciiStarts[slot]
                    let quality: MatchQuality
                    if position == start {
                        quality = .titlePrefix
                    } else {
                        let previous = buffer[position - 1]
                        quality = Self.isASCIIWordByte(previous) ? .titleSubstring : .titleWordPrefix
                    }
                    if slot == lastText {
                        if quality < lastQuality { lastQuality = quality; result[result.count - 1].quality = quality }
                    } else {
                        lastText = slot
                        lastQuality = quality
                        result.append((asciiTextIDs[slot], quality))
                    }
                    offset = position + 1
                }
            }
        }
        return !cancelled
    }

    /// Foundation matching over `groups`, split across a few child tasks. Every reported text was
    /// confirmed on its own by `verifiedQuality`. Nil when cancelled.
    private func foundationQualities(in groups: [FoundationTexts],
                                     query: String) async -> [(text: Int32, quality: MatchQuality)]? {
        let jobs = groups.flatMap { group in (0..<group.blocks.count).map { (group, $0) } }
        guard !jobs.isEmpty else { return [] }
        let workers = min(configuration.foundationWorkerLimit, jobs.count)
        return await withTaskGroup(of: [(text: Int32, quality: MatchQuality)]?.self) { taskGroup in
            for worker in 0..<workers {
                taskGroup.addTask {
                    var found: [(text: Int32, quality: MatchQuality)] = []
                    var job = worker
                    while job < jobs.count {
                        if Task.isCancelled { return nil }
                        let (texts, block) = jobs[job]
                        // Substrings made while scanning are autoreleased; free them per block.
                        autoreleasepool {
                            switch foundationMatching {
                            case .blocks:
                                scan(block: block, of: texts, query: query, into: &found)
                            case .perText:
                                for position in texts.positions(inBlock: block) {
                                    if let quality = Self.verifiedQuality(text: texts.text(at: position), query: query) {
                                        found.append((texts.ids[position], quality))
                                    }
                                }
                            }
                        }
                        job += workers
                    }
                    return found
                }
            }
            var all: [(text: Int32, quality: MatchQuality)] = []
            for await part in taskGroup {
                guard let part else { taskGroup.cancelAll(); return nil }
                all += part
            }
            return Task.isCancelled ? nil : all
        }
    }

    /// Asks Foundation for the first match in the block, checks only the text it starts in, then
    /// continues after that text. A text with a match always contains the first match of the rest
    /// of the block from that text on (separators force grapheme breaks), so none are skipped; a
    /// match running across a separator fails the per-text check and is ignored.
    private func scan(block: Int, of group: FoundationTexts, query: String,
                      into found: inout [(text: Int32, quality: MatchQuality)]) {
        let string = group.blocks[block]
        let positions = group.positions(inBlock: block)
        var position = positions.lowerBound
        while position < positions.upperBound {
            let offset = Int(group.offsets[position])
            let rest = offset == 0 ? string : (string.substring(from: offset) as NSString)
            let range = rest.localizedStandardRange(of: query)
            guard range.location != NSNotFound else { return }
            let hit = offset + range.location
            var low = position
            var high = positions.upperBound
            while low < high {
                let middle = (low + high) / 2
                if Int(group.offsets[middle]) <= hit { low = middle + 1 } else { high = middle }
            }
            let hitPosition = max(position, low - 1)
            let id = group.ids[hitPosition]
            if let quality = Self.verifiedQuality(text: group.text(at: hitPosition), query: query) {
                found.append((id, quality))
            }
            position = hitPosition + 1
        }
    }

    /// `localizedStandardContains` on the text alone decides the match; the first-match position
    /// decides the quality.
    static func verifiedQuality(text: NSString, query: String) -> MatchQuality? {
        guard text.localizedStandardContains(query) else { return nil }
        let original = text as String
        var searchStart = original.startIndex
        var quality = MatchQuality.titleSubstring
        while searchStart < original.endIndex,
              let range = original[searchStart...].localizedStandardRange(of: query) {
            if range.lowerBound == original.startIndex { return .titlePrefix }
            if original[..<range.lowerBound].last.map(Self.isWord) != true { quality = .titleWordPrefix }
            if quality == .titleWordPrefix { break }
            searchStart = range.upperBound
        }
        return quality
    }

    private func makeMatch(_ candidate: Candidate) -> Match {
        let posting = postings[Int(candidate.posting)]
        let channel = channelSlots[Int(posting.channel)]
        let start = Date(timeIntervalSince1970: posting.start)
        return Match(programID: EPGProgram.id(channelID: rawChannelIDs[Int(posting.rawChannelID)], start: start),
                     channelKey: channel.key, channelID: channel.id, channelName: channel.name,
                     channelOrdinal: channel.ordinal, title: text(Int(posting.titleText)),
                     subtitle: posting.subtitleText >= 0 ? text(Int(posting.subtitleText)) : nil,
                     start: start, end: Date(timeIntervalSince1970: posting.end), isLive: candidate.isLive,
                     quality: MatchQuality(rawValue: Int(candidate.quality)) ?? .subtitle)
    }

    private static let nonASCIILocation: UInt32 = 1 << 31

    /// The original text for an interned ID, copied out of its block as a native Swift string.
    private func text(_ id: Int) -> String {
        let location = textLocations[id]
        let group = location & Self.nonASCIILocation == 0 ? asciiFoundationTexts : otherFoundationTexts
        return String(group.text(at: Int(location & ~Self.nonASCIILocation)) as String)
    }

    /// Last start offset at or before `position`.
    private static func slot(containing position: Int, in starts: [Int]) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= position { low = middle + 1 } else { high = middle }
        }
        return low - 1
    }

    private static func needsLocaleSensitiveMatching(_ locale: Locale) -> Bool {
        let language = locale.identifier.split { $0 == "_" || $0 == "-" }.first?.lowercased()
        return language == "tr" || language == "az"
    }

    /// ASCII case folding; equals Foundation's case-insensitive folding of ASCII outside tr/az.
    static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }

    static func isASCIIWordByte(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    }

    private static func isWord(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }


    /// Texts that need Foundation matching, in blocks of up to `blockSize` joined by "\n". A line
    /// feed is a grapheme-break control, so a text's boundaries inside a block are its own boundaries,
    /// with one exception: a text ending in CR forms one CR LF cluster with the separator. That
    /// cannot hide a match, because queries are trimmed of whitespace and newlines: a match ending
    /// at that CR would need a query ending in CR, and there is always a break before the CR.
    /// Immutable after init; NSString is thread-safe to read.
    private final class FoundationTexts: @unchecked Sendable {
        static let blockSize = 64
        static let separator = "\n"

        let blocks: [NSString]
        /// Interned text IDs in block order; block `b` holds positions `b * blockSize ..< ...`.
        let ids: [Int32]
        /// UTF-16 offset of each text inside its block.
        let offsets: [Int32]
        let estimatedBytes: Int

        init?(ids: [Int32], texts: [String], isASCII: Bool) {
            var blocks: [NSString] = []
            var offsets: [Int32] = []
            var bytes = 0
            blocks.reserveCapacity(ids.count / Self.blockSize + 1)
            offsets.reserveCapacity(ids.count)
            var start = 0
            while start < ids.count {
                if Task.isCancelled { return nil }
                let end = min(ids.count, start + Self.blockSize)
                // A Foundation-owned copy: matching a bridged Swift string converts it on every call.
                if isASCII {
                    // One byte per character; UTF-16 offsets equal byte offsets for ASCII.
                    var ascii: [UInt8] = []
                    for position in start..<end {
                        if position > start { ascii.append(10) }
                        offsets.append(Int32(ascii.count))
                        ascii.append(contentsOf: texts[Int(ids[position])].utf8)
                    }
                    guard let block = NSString(bytes: ascii, length: ascii.count,
                                               encoding: String.Encoding.ascii.rawValue) else { return nil }
                    blocks.append(block)
                    bytes += ascii.count + 64
                } else {
                    var joined = ""
                    var length = 0
                    for position in start..<end {
                        if position > start {
                            joined += Self.separator
                            length += 1
                        }
                        let text = texts[Int(ids[position])]
                        offsets.append(Int32(length))
                        joined += text
                        length += text.utf16.count
                    }
                    blocks.append(NSString(string: joined))
                    bytes += length * 2 + 64
                }
                start = end
            }
            self.blocks = blocks
            self.ids = ids
            self.offsets = offsets
            estimatedBytes = bytes + ids.count * 4 + offsets.count * 4
        }

        func positions(inBlock block: Int) -> Range<Int> {
            let start = block * Self.blockSize
            return start ..< min(ids.count, start + Self.blockSize)
        }

        /// The text at `position`, copied out of its block.
        func text(at position: Int) -> NSString {
            let block = position / Self.blockSize
            let start = Int(offsets[position])
            let end = position + 1 < positions(inBlock: block).upperBound
                ? Int(offsets[position + 1]) - 1
                : blocks[block].length
            return blocks[block].substring(with: NSRange(location: start, length: end - start)) as NSString
        }
    }
}

/// Owns the current program search index. It builds lazily on the first query for an identity
/// (provider, catalog revision, guide generation), reuses it while the identity is unchanged, and
/// returns a result only while its query, identity and index are all still current.
/// A SQLite-backed guide is searched on disk through `EPGSQLiteProgramSearch` instead, under the
/// same identity, generation and cancellation rules; its listings are never loaded into memory.
///
/// The locale is not part of the identity: the index holds nothing locale-dependent, and the
/// matching locale is read again for every query, so a locale change needs no rebuild.
actor EPGProgramSearchIndexStore {
    static let shared = EPGProgramSearchIndexStore()

    private let configuration: EPGProgramSearchIndex.Configuration
    private let matchingLocale: @Sendable () -> Locale

    /// `matchingLocale` must return the locale Foundation matches in; tests inject one.
    init(configuration: EPGProgramSearchIndex.Configuration = .production,
         matchingLocale: @escaping @Sendable () -> Locale = { .current }) {
        self.configuration = configuration
        self.matchingLocale = matchingLocale
    }

    struct Input: Sendable {
        let identity: EPGProgramSearchIndex.Identity
        let guide: EPGIndex?
        let channels: [EPGProgramChannel]

        init(identity: EPGProgramSearchIndex.Identity, guide: EPGIndex?, channels: [LiveTVChannel]) {
            self.identity = identity
            self.guide = guide
            self.channels = channels.enumerated().map {
                EPGProgramChannel(id: $0.element.id, guideID: $0.element.guideID,
                                  name: $0.element.name, ordinal: $0.offset)
            }
        }

        init(identity: EPGProgramSearchIndex.Identity, guide: EPGIndex?,
             associations: [EPGProgramChannel]) {
            self.identity = identity
            self.guide = guide
            channels = associations
        }
    }
    enum Outcome: Equatable, Sendable {
        case results([EPGProgramSearchIndex.Match]), queryTooShort, noGuide, unsupportedStorage
    }
    private var identity: EPGProgramSearchIndex.Identity?
    private var index: EPGProgramSearchIndex?
    private var catalogGeneration = 0
    private var queryGeneration = 0
    private var buildWorker: Task<EPGProgramSearchIndex?, Never>?
    private var searchWorker: Task<[EPGProgramSearchIndex.Match]?, Never>?
    private var sqliteSource: EPGSQLiteProgramSearch?
    private var sqliteBuildWorker: Task<EPGSQLiteProgramSearch?, Never>?
    private var sqliteSearchWorker: Task<EPGSQLiteProgramSearch.Outcome?, Never>?
    #if DEBUG
    private var buildCount = 0
    private var lastMatchingLocaleIdentifier: String?
    private var searchCount = 0
    var buildCountForTesting: Int { buildCount }
    /// Calls to `search`, including ones that end as too short or unavailable.
    var searchCountForTesting: Int { searchCount }
    var lastMatchingLocaleIdentifierForTesting: String? { lastMatchingLocaleIdentifier }
    #endif
    var currentIdentity: EPGProgramSearchIndex.Identity? { identity }

    func search(query: String, input: Input, now: Date = .now,
                limit: Int = EPGProgramSearchIndex.defaultResultLimit) async -> Outcome? {
        #if DEBUG
        searchCount += 1
        #endif
        queryGeneration += 1
        let generation = queryGeneration
        searchWorker?.cancel(); searchWorker = nil
        sqliteSearchWorker?.cancel(); sqliteSearchWorker = nil
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= EPGProgramSearchIndex.minimumQueryLength else { return .queryTooShort }
        let expected = input.identity
        if identity != expected {
            catalogGeneration += 1
            buildWorker?.cancel(); buildWorker = nil
            sqliteBuildWorker?.cancel(); sqliteBuildWorker = nil
            index = nil; sqliteSource = nil; identity = expected
        }
        let catalog = catalogGeneration
        guard let guide = input.guide else { return .noGuide }
        if guide.isSQLiteBacked {
            return await searchSQLite(query: query, input: input, guide: guide, now: now, limit: limit,
                                      generation: generation, catalog: catalog)
        }
        let source: EPGProgramSearchIndex
        if let index, index.identity == expected { source = index }
        else {
            let worker: Task<EPGProgramSearchIndex?, Never>
            if let buildWorker { worker = buildWorker } else {
                #if DEBUG
                buildCount += 1
                #endif
                let configuration = configuration
                worker = Task {
                    await EPGProgramSearchIndex.build(identity: expected, guide: guide, channels: input.channels, now: now,
                                                      configuration: configuration)
                }
                buildWorker = worker
            }
            // The build is shared by every query for this identity, so a cancelled query (the user
            // typed another letter) only stops waiting. Only an identity change or `invalidate`
            // cancels the build itself.
            let built = await Self.waitWithoutCancelling(worker)
            guard catalog == catalogGeneration, identity == expected else { return nil }
            if let built, built.identity == expected {
                if index?.identity != expected { index = built }
                if buildWorker == worker { buildWorker = nil }
            } else if !Task.isCancelled {
                // The build ended without an index; drop it so the next query can start another.
                if buildWorker == worker { buildWorker = nil }
                return nil
            }
            guard !Task.isCancelled, let built else { return nil }
            source = built
        }
        // Several queries can wake from one shared build; only the newest is worth searching.
        guard generation == queryGeneration else { return nil }
        let locale = matchingLocale()
        #if DEBUG
        lastMatchingLocaleIdentifier = locale.identifier
        #endif
        searchWorker?.cancel()
        let worker = Task { await source.search(query: query, now: now, limit: limit, matchingLocale: locale) }
        searchWorker = worker
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: {
            worker.cancel()
        })
        guard !Task.isCancelled, generation == queryGeneration, catalog == catalogGeneration,
              identity == expected, index?.identity == expected, let result else { return nil }
        searchWorker = nil
        return .results(result)
    }

    /// The SQLite counterpart of the in-memory path above: a per-identity source prepared once and
    /// shared by every query for that identity, then one bounded on-disk search per query.
    private func searchSQLite(query: String, input: Input, guide: EPGIndex, now: Date, limit: Int,
                              generation: Int, catalog: Int) async -> Outcome? {
        let expected = input.identity
        let source: EPGSQLiteProgramSearch
        if let sqliteSource, sqliteSource.identity == expected { source = sqliteSource }
        else {
            let worker: Task<EPGSQLiteProgramSearch?, Never>
            if let sqliteBuildWorker { worker = sqliteBuildWorker } else {
                #if DEBUG
                buildCount += 1
                #endif
                worker = Task {
                    await EPGSQLiteProgramSearch.prepare(identity: expected, guide: guide, channels: input.channels)
                }
                sqliteBuildWorker = worker
            }
            // Shared like the in-memory build: a cancelled query only stops waiting.
            let built = await Self.waitWithoutCancelling(worker)
            guard catalog == catalogGeneration, identity == expected else { return nil }
            if let built, built.identity == expected {
                if sqliteSource?.identity != expected { sqliteSource = built }
                if sqliteBuildWorker == worker { sqliteBuildWorker = nil }
            } else if !Task.isCancelled {
                if sqliteBuildWorker == worker { sqliteBuildWorker = nil }
                return nil
            }
            guard !Task.isCancelled, let built else { return nil }
            source = built
        }
        guard generation == queryGeneration else { return nil }
        let locale = matchingLocale()
        #if DEBUG
        lastMatchingLocaleIdentifier = locale.identifier
        #endif
        sqliteSearchWorker?.cancel()
        let worker = Task { await source.search(query: query, now: now, limit: limit, matchingLocale: locale) }
        sqliteSearchWorker = worker
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: {
            worker.cancel()
        })
        guard !Task.isCancelled, generation == queryGeneration, catalog == catalogGeneration,
              identity == expected, sqliteSource?.identity == expected, let result else { return nil }
        sqliteSearchWorker = nil
        switch result {
        case .results(let matches): return .results(matches)
        case .storageUnavailable: return .unsupportedStorage
        }
    }

    func invalidate(providerID: UUID? = nil) {
        guard providerID == nil || identity?.providerID == providerID else { return }
        catalogGeneration += 1; queryGeneration += 1
        buildWorker?.cancel(); searchWorker?.cancel()
        sqliteBuildWorker?.cancel(); sqliteSearchWorker?.cancel()
        buildWorker = nil; searchWorker = nil; identity = nil; index = nil
        sqliteBuildWorker = nil; sqliteSearchWorker = nil; sqliteSource = nil
    }

    /// The task's value, or nil as soon as the caller is cancelled. Never cancels `task`.
    private static func waitWithoutCancelling<Value: Sendable>(_ task: Task<Value?, Never>) async -> Value? {
        let wait = SharedWait<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                wait.install(continuation)
                Task.detached { wait.finish(await task.value) }
            }
        } onCancel: {
            wait.finish(nil)
        }
    }

    /// Resumes one continuation exactly once, with whichever of the value or the caller's
    /// cancellation arrives first; the order of `install` and `finish` does not matter.
    private final class SharedWait<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value?, Never>?
        private var isFinished = false
        private var value: Value?

        func install(_ continuation: CheckedContinuation<Value?, Never>) {
            lock.lock()
            guard isFinished else {
                self.continuation = continuation
                lock.unlock()
                return
            }
            let value = value
            lock.unlock()
            continuation.resume(returning: value)
        }

        func finish(_ result: Value?) {
            lock.lock()
            guard !isFinished else { lock.unlock(); return }
            isFinished = true
            value = result
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }
}
