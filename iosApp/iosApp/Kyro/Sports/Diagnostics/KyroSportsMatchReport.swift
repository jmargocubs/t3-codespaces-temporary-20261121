#if KYRO_INTERNAL_EPG_STORAGE_TOGGLE
import CryptoKit
import Foundation

/// INTERNAL TEST builds only. A bounded, privacy-safe account of how Sports Hub matched one event:
/// what the guide search read, which channels were accepted or rejected and why, what the initial
/// list and the overflow hold, and how Universal Search's plain channel search compares.
///
/// It holds labels only: channel names and groups, guide channel keys and programme titles. It
/// never holds stream, logo or provider addresses, provider names, credentials or tokens; channel
/// IDs appear only as a short one-way hash. Text that looks like a link is removed.
struct KyroSportsMatchReport: Codable, Equatable, Sendable {
    static let formatVersion = 1
    static let maximumCandidates = 200
    static let maximumSearchExamplesPerQuery = 25
    static let maximumLabelLength = 96
    static let maximumBytes = 256 * 1024

    struct Event: Codable, Equatable, Sendable {
        let id: String
        let league: String
        let away: String
        let home: String
        let start: Date?
        let status: String
        let broadcast: String?
    }

    struct Catalog: Codable, Equatable, Sendable {
        let revision: Int
        let playableChannels: Int
    }

    struct Guide: Codable, Equatable, Sendable {
        let generation: Int
        /// "sqlite", "memory" or "none" (no guide loaded).
        let storageMode: String
        let isStale: Bool
        let rowBudget: Int
        let strongAnchors: [String]
        let weakAnchors: [String]
        let strongPassRows: Int
        let weakPassRows: Int
        let truncated: Bool
    }

    struct Summary: Codable, Equatable, Sendable {
        let accepted: Int
        let initial: Int
        let overflow: Int
        let omitted: Int
        let autoPlayCandidates: Int
        let networkChannels: Int
        let rejected: Int
        let nameCandidates: Int
        let matchMilliseconds: Int
    }

    enum Outcome: String, Codable, Sendable {
        /// In the initial list (`matches`).
        case initial
        /// In the expandable "More matches" list.
        case overflow
        /// Accepted, but beyond the overflow bound.
        case omitted
        case rejected
        /// Universal Search found it; Sports Hub never evaluated it (no team word, no guide row).
        case notConsidered
    }

    struct Candidate: Codable, Equatable, Sendable {
        /// First 12 hex digits of SHA-256 of the channel ID.
        let ref: String
        let name: String
        let group: String
        let guideKey: String?
        /// "guide", "channelName" or "guide+channelName".
        let source: String
        let outcome: Outcome
        /// 1-based position among all accepted matches by score.
        let rank: Int?
        let score: Int?
        let autoPlayEligible: Bool
        let autoPlayCandidate: Bool
        let programmeTitle: String?
        let programmeStart: Date?
        let rejection: KyroSportsStreamMatcher.Rejection?
        let evidence: [String]
    }

    struct SearchComparison: Codable, Equatable, Sendable {
        let query: String
        /// Playable channels whose name or group contains the query, as Universal Search's channel
        /// search matches it.
        let hits: Int
        /// Hits Sports Hub did not accept.
        let notAccepted: Int
        let examples: [SearchExample]
    }

    struct SearchExample: Codable, Equatable, Sendable {
        let ref: String
        let name: String
        let group: String
        let outcome: Outcome
        let rejection: KyroSportsStreamMatcher.Rejection?
    }

    let formatVersion: Int
    let createdAt: Date
    let event: Event
    let catalog: Catalog
    let guide: Guide
    let summary: Summary
    var candidates: [Candidate]
    var candidatesOmitted: Int
    let universalSearch: [SearchComparison]

    /// Pretty JSON, trimmed to `maximumBytes` by dropping the lowest-ranked candidates.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var report = self
        var data = try encoder.encode(report)
        while data.count > Self.maximumBytes, !report.candidates.isEmpty {
            let drop = Swift.max(1, report.candidates.count / 10)
            report.candidates.removeLast(drop)
            report.candidatesOmitted += drop
            data = try encoder.encode(report)
        }
        return data
    }

    // MARK: Privacy

    static func reference(forChannelID id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// Bounded label with anything link-like removed (`scheme://…`, `www.…`, `key=value` pairs).
    static func label(_ text: String?) -> String? {
        guard let text else { return nil }
        var value = text
        for pattern in [#"[A-Za-z][A-Za-z0-9+.-]*://\S+"#, #"\bwww\.\S+"#, #"\b[A-Za-z_]+=[^\s&]+"#] {
            value = value.replacingOccurrences(of: pattern, with: "[removed]", options: .regularExpression)
        }
        value = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return value.count > maximumLabelLength ? String(value.prefix(maximumLabelLength - 1)) + "…" : value
    }
}

/// Builds the report from the same index, guide and guide-key map the matcher used. Runs off the
/// main actor; returns nil when cancelled.
enum KyroSportsMatchReportBuilder {
    enum StorageMode: String, Sendable {
        case sqlite, memory, none
    }

    struct Input: Sendable {
        let request: KyroSportsStreamMatchRequest
        let index: KyroSportsChannelIndex
        let guide: EPGIndex?
        let guideKeys: [String: [Int32]]?
        let guideGeneration: Int
        let storageMode: StorageMode
        let createdAt: Date
    }

    private struct Seen {
        var accepted: KyroSportsStreamMatch?
        var rejection: KyroSportsStreamMatcher.Rejection?
        var rejectedProgramme: EPGProgram?
        var viaGuide = false
        var viaName = false
        var guideKey: String?
    }

    static func build(_ input: Input) -> KyroSportsMatchReport? {
        typealias Matcher = KyroSportsStreamMatcher
        let request = input.request
        let game = request.game
        let index = input.index
        let result = Matcher.match(request: request, index: index, guide: input.guide, guideKeys: input.guideKeys)
        guard !result.indexWasCancelled, !Task.isCancelled else { return nil }
        let context = Matcher.MatchContext(game: game)
        let stale = result.guideWasStale

        // The same evaluations the matcher ran, kept with their reasons.
        var seen: [Int: Seen] = [:]
        var read = Matcher.GuideRows()
        if context.isMatchable, let guide = input.guide, let keys = input.guideKeys {
            read = Matcher.guideRows(guide: guide, interval: Matcher.eventInterval(for: game, request: request), context: context)
            guard !read.cancelled else { return nil }
            for (number, row) in read.rows.enumerated() {
                if number.isMultiple(of: 128), Task.isCancelled { return nil }
                for offset in keys[row.key] ?? [] {
                    let position = Int(offset)
                    var entry = seen[position] ?? Seen()
                    entry.viaGuide = true
                    entry.guideKey = row.key
                    switch Matcher.assess(program: row.program, channel: index.channels[position], context: context,
                                          stale: stale, now: request.now) {
                    case .accepted(let match):
                        if match.score > (entry.accepted?.score ?? -1) { entry.accepted = match }
                    case .rejected(let reason):
                        if entry.rejection == nil {
                            entry.rejection = reason
                            entry.rejectedProgramme = row.program
                        }
                    }
                    seen[position] = entry
                }
            }
        }
        let named = context.isMatchable ? index.offsets(containingAny: context.anchors) : []
        for (number, offset) in named.enumerated() {
            if number.isMultiple(of: 256), Task.isCancelled { return nil }
            var entry = seen[offset] ?? Seen()
            entry.viaName = true
            switch Matcher.assess(channelName: index.channels[offset], context: context, stale: stale) {
            case .accepted(let match):
                if match.score > (entry.accepted?.score ?? -1) { entry.accepted = match }
            case .rejected(let reason):
                if entry.rejection == nil { entry.rejection = reason }
            }
            seen[offset] = entry
        }

        let initialIDs = Set(result.matches.map(\.channel.id))
        let overflowIDs = Set(result.overflowMatches.map(\.channel.id))
        let autoPlayIDs = Set(result.autoPlayCandidates.map(\.channel.id))
        let ranked = seen.compactMap { $0.value.accepted }.sorted(by: Matcher.rankedBefore)
        let rankByID = Dictionary(ranked.enumerated().map { ($1.channel.id, $0 + 1) }, uniquingKeysWith: { first, _ in first })
        func outcome(_ channelID: String) -> KyroSportsMatchReport.Outcome {
            if initialIDs.contains(channelID) { return .initial }
            if overflowIDs.contains(channelID) { return .overflow }
            return rankByID[channelID] != nil ? .omitted : .rejected
        }

        var accepted: [KyroSportsMatchReport.Candidate] = []
        var rejected: [KyroSportsMatchReport.Candidate] = []
        for (offset, entry) in seen {
            let channel = index.channels[offset]
            let source = [entry.viaGuide ? "guide" : nil, entry.viaName ? "channelName" : nil].compactMap { $0 }
                .joined(separator: "+")
            if let match = entry.accepted {
                accepted.append(.init(
                    ref: KyroSportsMatchReport.reference(forChannelID: channel.id),
                    name: KyroSportsMatchReport.label(channel.name) ?? "", group: KyroSportsMatchReport.label(channel.category) ?? "",
                    guideKey: KyroSportsMatchReport.label(entry.guideKey), source: source, outcome: outcome(channel.id),
                    rank: rankByID[channel.id], score: match.score, autoPlayEligible: match.isAutoPlayEligible,
                    autoPlayCandidate: autoPlayIDs.contains(channel.id),
                    programmeTitle: KyroSportsMatchReport.label(match.program?.title), programmeStart: match.program?.start,
                    rejection: nil, evidence: match.reasons.prefix(4).compactMap(KyroSportsMatchReport.label)))
            } else {
                rejected.append(.init(
                    ref: KyroSportsMatchReport.reference(forChannelID: channel.id),
                    name: KyroSportsMatchReport.label(channel.name) ?? "", group: KyroSportsMatchReport.label(channel.category) ?? "",
                    guideKey: KyroSportsMatchReport.label(entry.guideKey), source: source, outcome: .rejected,
                    rank: nil, score: nil, autoPlayEligible: false, autoPlayCandidate: false,
                    programmeTitle: KyroSportsMatchReport.label(entry.rejectedProgramme?.title),
                    programmeStart: entry.rejectedProgramme?.start, rejection: entry.rejection, evidence: []))
            }
        }
        accepted.sort { ($0.rank ?? .max, $0.ref) < ($1.rank ?? .max, $1.ref) }
        rejected.sort { ($0.name, $0.ref) < ($1.name, $1.ref) }
        let all = accepted + rejected
        let kept = Array(all.prefix(KyroSportsMatchReport.maximumCandidates))

        // Universal Search's channel search: the query folded and found anywhere in the name or group.
        let queries = Array(NSOrderedSet(array: [game.away.team.nickname, game.home.team.nickname,
                                                 game.away.team.fullName, game.home.team.fullName])
            .compactMap { $0 as? String }.filter { $0.count >= 2 })
        func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        }
        let folded = queries.map(fold)
        var hits = Array(repeating: [Int](), count: queries.count)
        for (offset, channel) in index.channels.enumerated() {
            if offset.isMultiple(of: 512), Task.isCancelled { return nil }
            let name = fold(channel.name)
            let group = fold(channel.category)
            for (position, query) in folded.enumerated() where name.contains(query) || group.contains(query) {
                hits[position].append(offset)
            }
        }
        let comparisons = queries.indices.map { position -> KyroSportsMatchReport.SearchComparison in
            let missing = hits[position].filter { seen[$0]?.accepted == nil }
            let examples = missing.prefix(KyroSportsMatchReport.maximumSearchExamplesPerQuery).map { offset in
                let channel = index.channels[offset]
                return KyroSportsMatchReport.SearchExample(
                    ref: KyroSportsMatchReport.reference(forChannelID: channel.id),
                    name: KyroSportsMatchReport.label(channel.name) ?? "",
                    group: KyroSportsMatchReport.label(channel.category) ?? "",
                    outcome: seen[offset] == nil ? .notConsidered : .rejected, rejection: seen[offset]?.rejection)
            }
            return .init(query: queries[position], hits: hits[position].count, notAccepted: missing.count, examples: examples)
        }

        let event = KyroSportsMatchReport.Event(
            id: game.id.description, league: game.league.rawValue,
            away: game.away.team.fullName, home: game.home.team.fullName,
            start: game.isStartTimeTBD ? nil : game.startTime, status: String(describing: game.status),
            broadcast: KyroSportsMatchReport.label(game.broadcast))
        let guideSummary = KyroSportsMatchReport.Guide(
            generation: input.guideGeneration, storageMode: input.storageMode.rawValue, isStale: stale,
            rowBudget: Matcher.maximumGuideRows, strongAnchors: context.strongAnchors, weakAnchors: context.weakAnchors,
            strongPassRows: read.strongRows, weakPassRows: read.weakRows, truncated: read.truncated)
        let summary = KyroSportsMatchReport.Summary(
            accepted: ranked.count, initial: result.matches.count, overflow: result.overflowMatches.count,
            omitted: result.omittedMatchCount, autoPlayCandidates: result.autoPlayCandidates.count,
            networkChannels: result.possibleBroadcasters.count, rejected: rejected.count,
            nameCandidates: result.diagnostics.nameCandidates,
            matchMilliseconds: Int((result.diagnostics.matchDuration * 1000).rounded()))
        return KyroSportsMatchReport(
            formatVersion: KyroSportsMatchReport.formatVersion, createdAt: input.createdAt, event: event,
            catalog: .init(revision: index.catalogRevision, playableChannels: index.channels.count),
            guide: guideSummary, summary: summary, candidates: kept,
            candidatesOmitted: all.count - kept.count, universalSearch: comparisons)
    }
}
#endif
