import Foundation

/// What one stream row shows in the Sports Hub stream picker and the player's Other Streams
/// sheet. Built from matcher output and this session's playback results; it keeps two facts
/// apart: whether event metadata names the game (evidence), and whether the stream started
/// (status). Neither one proves what the video shows.
struct KyroSportsStreamRowModel: Identifiable, Equatable {
    enum Status: Equatable {
        case nowPlaying
        case connecting
        /// Started playing earlier in this session.
        case played
        case didNotPlay
        /// Strong event evidence; not tried yet.
        case eventMatch
        /// Some event evidence; not tried yet.
        case possibleMatch
        /// Picked from channel search.
        case fromSearch
        /// A channel of the listed network with no event evidence.
        case unconfirmed
    }

    let id: String
    let channelID: String
    /// Trimmed, single-spaced name for display. Long names truncate in the view.
    let displayName: String
    /// The catalog name, for accessibility and the long-press menu.
    let fullName: String
    let logoURL: URL?
    let programmeTitle: String?
    let programmeStart: Date?
    let programmeEnd: Date?
    let status: Status
    /// One short reason, instead of the matcher's scoring notes.
    let evidence: String
    let isCurrent: Bool

    var statusLabel: String {
        switch status {
        case .nowPlaying: "Now playing"
        case .connecting: "Connecting"
        case .played: "Played"
        case .didNotPlay: "Didn't play"
        case .eventMatch: "Event match"
        case .possibleMatch: "Possible"
        case .fromSearch: "From search"
        case .unconfirmed: "Unconfirmed"
        }
    }

    /// Other Streams' tier: 0 started this session (or is starting), 1 untried, 2 failed.
    var switchingRank: Int {
        switch status {
        case .nowPlaying, .played, .connecting: 0
        case .eventMatch, .possibleMatch, .fromSearch, .unconfirmed: 1
        case .didNotPlay: 2
        }
    }

    /// Whether choosing the row does anything: the stream on screen only reacts when it failed.
    var isSelectable: Bool { !isCurrent || status == .didNotPlay }

    var accessibilityLabel: String {
        var parts = [fullName, statusLabel, evidence]
        if let programmeTitle { parts.insert("Showing \(programmeTitle)", at: 1) }
        return parts.joined(separator: ", ")
    }

    var accessibilityHint: String {
        if isCurrent { return status == .didNotPlay ? "Tries this stream again" : "Playing now" }
        return "Plays this stream"
    }

    init(match: KyroSportsStreamMatch, status playback: KyroSportsStreamStatus, isCurrent: Bool,
         currentProgramme: EPGProgram? = nil) {
        id = match.id
        channelID = match.channel.id
        fullName = match.channel.name
        displayName = Self.displayName(match.channel.name)
        logoURL = match.channel.logoURL
        // The matched listing first: it is the evidence. Otherwise what the guide says is on now.
        let programme = match.program ?? currentProgramme
        programmeTitle = programme.map { [$0.title, $0.subtitle].compactMap { $0 }.joined(separator: " · ") }
        programmeStart = programme?.start
        programmeEnd = programme?.end
        self.isCurrent = isCurrent
        evidence = Self.evidence(for: match)
        status = Self.status(match: match, playback: playback, isCurrent: isCurrent)
    }

    static func status(match: KyroSportsStreamMatch, playback: KyroSportsStreamStatus, isCurrent: Bool) -> Status {
        switch playback {
        case .connecting: return .connecting
        case .failed: return .didNotPlay
        case .verified: return isCurrent ? .nowPlaying : .played
        case .untested:
            if isCurrent { return .nowPlaying }
            switch match.source {
            case .manual: return .fromSearch
            case .broadcaster: return .unconfirmed
            case .guide, .channelName: return match.isAutoPlayEligible ? .eventMatch : .possibleMatch
            }
        }
    }

    static func evidence(for match: KyroSportsStreamMatch) -> String {
        switch match.source {
        case .guide: match.isAutoPlayEligible ? "Guide lists this game" : "Guide may list this game"
        case .channelName: "Channel name lists this game"
        case .manual: "Channel search; not matched to this game"
        case .broadcaster: "Network listed for this game"
        }
    }

    static func displayName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// The picker's groups: strong event matches first, then weaker event evidence, then accepted
/// matches beyond the initial list (shown collapsed, same evidence labels), then network channels
/// nothing ties to the event (shown collapsed). Generic channels never appear.
struct KyroSportsStreamSection: Identifiable, Equatable {
    enum Kind: String, Equatable {
        /// Other Streams only: the stream on screen, in a group of its own at the top.
        case nowPlaying
        case eventMatches
        case possibleMatches
        case moreMatches
        case networkChannels
    }

    let kind: Kind
    let rows: [KyroSportsStreamRowModel]
    var id: String { kind.rawValue }

    var title: String {
        switch kind {
        case .nowPlaying: "Now playing"
        case .eventMatches: "Matches this game"
        case .possibleMatches: "Possible matches"
        case .moreMatches: "More matches"
        case .networkChannels: "Network channels"
        }
    }

    /// Collapsed groups (more matches, network channels) open by themselves only when one of their
    /// streams is playing or was tried.
    var isCollapsible: Bool { kind == .moreMatches || kind == .networkChannels }

    var startsExpanded: Bool {
        !isCollapsible || rows.contains { $0.isCurrent || $0.status == .played || $0.status == .didNotPlay }
    }

    /// Only the bounded broadcaster list is searched; the compact picker shows six rows.
    func visibleNetworkRows(showAll: Bool, query: String = "") -> [KyroSportsStreamRowModel] {
        guard kind == .networkChannels else { return rows }
        guard showAll else { return Array(rows.prefix(KyroSportsStreamMatcher.initialBroadcasters)) }
        let terms = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !terms.isEmpty else { return rows }
        return rows.filter {
            $0.fullName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(terms)
        }
    }

    /// Other Streams' order for switching away from the stream on screen: that stream alone at the
    /// top, then the usual groups with streams that played this session ahead of untried ones and
    /// streams that failed last. Order within each tier is the matcher's. Only the list changes;
    /// automatic playback and fallback keep the matcher's own order.
    static func prioritizedForSwitching(_ sections: [KyroSportsStreamSection]) -> [KyroSportsStreamSection] {
        let current = sections.flatMap(\.rows).filter(\.isCurrent)
        let others = sections.compactMap { section -> KyroSportsStreamSection? in
            let rows = section.rows.filter { !$0.isCurrent }
                .enumerated()
                .sorted { ($0.element.switchingRank, $0.offset) < ($1.element.switchingRank, $1.offset) }
                .map(\.element)
            return rows.isEmpty ? nil : KyroSportsStreamSection(kind: section.kind, rows: rows)
        }
        guard !current.isEmpty else { return others }
        return [KyroSportsStreamSection(kind: .nowPlaying, rows: current)] + others
    }

    /// `overflow` is the matcher's bounded list of accepted matches beyond `matches`. A channel
    /// appears once, in the first group that lists it.
    static func make(
        matches: [KyroSportsStreamMatch],
        overflow: [KyroSportsStreamMatch] = [],
        broadcasters: [KyroSportsStreamMatch],
        status: (String) -> KyroSportsStreamStatus,
        currentChannelID: String?,
        currentProgrammes: [String: EPGProgram] = [:]
    ) -> [KyroSportsStreamSection] {
        var seen = Set<String>()
        func row(_ match: KyroSportsStreamMatch) -> KyroSportsStreamRowModel? {
            guard seen.insert(match.channel.id).inserted else { return nil }
            return KyroSportsStreamRowModel(match: match, status: status(match.channel.id),
                                            isCurrent: match.channel.id == currentChannelID,
                                            currentProgramme: currentProgrammes[match.channel.id])
        }
        let strong = matches.filter { $0.isAutoPlayEligible && $0.source != .manual }.compactMap(row)
        let possible = matches.filter { !$0.isAutoPlayEligible || $0.source == .manual }.compactMap(row)
        let more = overflow.prefix(KyroSportsStreamMatcher.maximumOverflowMatches).compactMap(row)
        let network = broadcasters.compactMap(row)
        return [
            KyroSportsStreamSection(kind: .eventMatches, rows: strong),
            KyroSportsStreamSection(kind: .possibleMatches, rows: possible),
            KyroSportsStreamSection(kind: .moreMatches, rows: more),
            KyroSportsStreamSection(kind: .networkChannels, rows: network),
        ].filter { !$0.rows.isEmpty }
    }
}
