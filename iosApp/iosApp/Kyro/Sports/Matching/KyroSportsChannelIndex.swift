import Foundation

/// A per-catalog lookup for Sports Hub event matching.
///
/// Built once off the main actor for a provider's playable channels and reused for every event
/// tap until the catalog changes, so a tap never folds or scans 40,000 channel names. It holds
/// channel values already in memory and whole-word postings; it never stores or logs a stream URL.
struct KyroSportsChannelIndex: Sendable {
    static let maximumCandidateChannels = 2_000
    let providerID: UUID?
    let catalogRevision: Int
    /// Playable channels only, in catalog order.
    let channels: [LiveTVChannel]
    /// Whole-word tokens of each channel's name and category, to channel offsets (ascending).
    private let postings: [String: [Int32]]
    private let offsetsByID: [String: Int32]
    /// Seconds spent building, for diagnostics and benchmarks.
    let buildDuration: TimeInterval

    var tokenCount: Int { postings.count }

    /// Returns nil when the building task is cancelled.
    static func build(channels: [LiveTVChannel], providerID: UUID? = nil, catalogRevision: Int = 0) -> KyroSportsChannelIndex? {
        let started = DispatchTime.now().uptimeNanoseconds
        var postings: [String: [Int32]] = [:]
        postings.reserveCapacity(min(channels.count * 2, 200_000))
        var offsetsByID: [String: Int32] = [:]
        offsetsByID.reserveCapacity(channels.count)
        for (offset, channel) in channels.enumerated() {
            if offset.isMultiple(of: 512), Task.isCancelled { return nil }
            offsetsByID[channel.id] = Int32(offset)
            let tokens = Set(KyroSportsStreamMatcher.phraseTokens(channel.name + " " + channel.category))
            for token in tokens {
                postings[token, default: []].append(Int32(offset))
            }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        return KyroSportsChannelIndex(providerID: providerID, catalogRevision: catalogRevision, channels: channels,
                                      postings: postings, offsetsByID: offsetsByID, buildDuration: elapsed)
    }

    func channel(id: String) -> LiveTVChannel? {
        offsetsByID[id].map { channels[Int($0)] }
    }

    /// Offsets of channels whose name or category contains any of `tokens` as a whole word.
    func offsets(containingAny tokens: [String]) -> [Int] {
        var result = Set<Int32>()
        for token in tokens {
            guard let list = postings[token] else { continue }
            result.formUnion(list)
        }
        return result.map(Int.init).sorted()
    }

    /// Playlist channels for each guide channel key of `guide`. Channels that share a guide ID
    /// (HD/SD/backup variants) all appear under one key. Build it once per guide generation.
    func guideKeyMap(for guide: EPGIndex) -> [String: [Int32]]? {
        var map: [String: [Int32]] = [:]
        for (offset, channel) in channels.enumerated() {
            if offset.isMultiple(of: 512), Task.isCancelled { return nil }
            guard let key = guide.channelKey(guideID: channel.guideID, name: channel.name) else { continue }
            map[key, default: []].append(Int32(offset))
        }
        return map
    }
}

/// Dates printed in event channel names ("NCAAF 03: Iowa @ Ohio State 11/08 12:00 PM ET"). A
/// date for another day means a stale or future event slot reusing the same matchup.
enum KyroSportsEventNameDate {
    enum Verdict: Equatable {
        case none
        case matches
        case conflicts
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    static func check(_ name: String, event start: Date?, calendar: Calendar = .current) -> Verdict {
        guard let start else { return .none }
        let candidates = dates(in: name, near: start, calendar: calendar)
        guard !candidates.isEmpty else { return .none }
        let day = calendar.startOfDay(for: start)
        for candidate in candidates {
            let days = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: candidate)).day ?? 99
            // Channel names use the provider's time zone (often US Eastern or UK).
            if abs(days) <= 1 { return .matches }
        }
        return .conflicts
    }

    /// Every plausible reading of a date in `name`: ISO, numeric (US and day-first) and month
    /// names. Years default to the event's year.
    static func dates(in name: String, near start: Date, calendar: Calendar) -> [Date] {
        let text = name.lowercased()
        let year = calendar.component(.year, from: start)
        var found: [Date] = []
        func add(year: Int, month: Int, day: Int) {
            guard (1...12).contains(month), (1...31).contains(day),
                  let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  calendar.component(.day, from: date) == day else { return }
            found.append(date)
        }
        func matches(_ pattern: String) -> [[String]] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.matches(in: text, range: range).map { match in
                (0..<match.numberOfRanges).map { index in
                    Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
                }
            }
        }
        for groups in matches(#"(?<!\d)(20\d\d)-(\d{1,2})-(\d{1,2})(?!\d)"#) {
            add(year: Int(groups[1]) ?? year, month: Int(groups[2]) ?? 0, day: Int(groups[3]) ?? 0)
        }
        // Numeric dates need a slash, or dots with a year ("08.11.26"); "7:00" is a time, "01" a
        // channel number and "5.1" an audio format.
        for groups in matches(#"(?<![\d:./])(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?(?![\d:/])"#)
            + matches(#"(?<![\d:.])(\d{1,2})\.(\d{1,2})\.(\d{2,4})(?![\d:.])"#) {
            let first = Int(groups[1]) ?? 0
            let second = Int(groups[2]) ?? 0
            var parsedYear = year
            if let value = Int(groups[3]) { parsedYear = value < 100 ? 2000 + value : value }
            add(year: parsedYear, month: first, day: second)
            add(year: parsedYear, month: second, day: first)
        }
        let monthPattern = "(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\.?"
        for groups in matches("\\b\(monthPattern)\\s+(\\d{1,2})(?:st|nd|rd|th)?\\b") {
            if let month = months.firstIndex(of: groups[1]) { add(year: year, month: month + 1, day: Int(groups[2]) ?? 0) }
        }
        for groups in matches("\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+\(monthPattern)\\b") {
            if let month = months.firstIndex(of: groups[2]) { add(year: year, month: month + 1, day: Int(groups[1]) ?? 0) }
        }
        return found
    }
}
