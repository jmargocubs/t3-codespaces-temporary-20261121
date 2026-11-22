import Foundation

/// A local, provider-scoped match request. It deliberately contains no network
/// source or credentials: matching is only against the configured Live TV catalog.
struct KyroSportsStreamMatchRequest: Sendable {
    let game: KyroSportsGame
    let now: Date
    let eventWindow: TimeInterval

    init(game: KyroSportsGame, now: Date = .now, eventWindow: TimeInterval = 2 * 60 * 60) {
        self.game = game
        self.now = now
        self.eventWindow = max(15 * 60, eventWindow)
    }
}

enum KyroSportsStreamMatchConfidence: Int, Comparable, Sendable {
    case low = 0
    case medium = 1
    case high = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct KyroSportsStreamMatch: Identifiable, Equatable, Sendable {
    let id: String
    let channel: LiveTVChannel
    let program: EPGProgram?
    let confidence: KyroSportsStreamMatchConfidence
    let score: Int
    let reasons: [String]
    let isStale: Bool
    /// What identified the event on this channel.
    var source: Source = .guide
    /// Strong enough to try without asking: both participants identified, on time in a fresh
    /// guide or spelled out in the channel name. Playback still has to prove the stream works.
    var isAutoPlayEligible = false

    enum Source: Sendable {
        /// A guide programme names the event.
        case guide
        /// The channel's own name names the event (IPTV event channels, often without a guide).
        case channelName
        /// The viewer picked the channel from channel search.
        case manual
        /// A channel of the listed broadcaster. Never evidence that it carries this event.
        case broadcaster
    }

    var title: String { program?.title ?? channel.name }
}

/// Per-tap matching cost, for diagnostics and benchmarks. Never part of result equality.
struct KyroSportsStreamMatchDiagnostics: Equatable, Sendable {
    var catalogChannels = 0
    var guideRows = 0
    /// Guide rows read for full team names and other strong aliases (first pass).
    var strongGuideRows = 0
    /// Guide rows read for abbreviations and other weak aliases, from the budget left (second pass).
    var weakGuideRows = 0
    /// More guide programmes qualified than `KyroSportsStreamMatcher.maximumGuideRows` allowed.
    var guideRowsTruncated = false
    var nameCandidates = 0
    /// Every accepted event match, before the initial list and the overflow bound.
    var acceptedMatches = 0
    var matchDuration: TimeInterval = 0

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

struct KyroSportsStreamMatchResult: Equatable, Sendable {
    /// `.low` means no verified event match; `matches` is then empty and the
    /// sheet offers manual channel search only.
    let confidence: KyroSportsStreamMatchConfidence
    /// Event-specific candidates only. Never padded with generic channels. The initial list: at
    /// most `KyroSportsStreamMatcher.maximumMatches`, chosen so one network broadcast repeated on
    /// many affiliates cannot fill it (see `KyroSportsStreamMatcher.initialSelection`).
    let matches: [KyroSportsStreamMatch]
    /// Accepted event matches that did not fit `matches`, best first. Same evidence and labels as
    /// `matches`, never tried automatically, at most `KyroSportsStreamMatcher.maximumOverflowMatches`.
    var overflowMatches: [KyroSportsStreamMatch] = []
    /// Accepted matches beyond the overflow bound, counted but not kept.
    var omittedMatchCount = 0
    let manualSearchQuery: String
    let guideWasStale: Bool
    let indexWasCancelled: Bool
    /// Short names to seed manual channel search: teams or players, then the
    /// listed broadcaster. These are suggestions, not matches.
    var manualSearchSuggestions: [String] = []
    /// The event-specific matches strong enough to try automatically, best first, at most
    /// `KyroSportsStreamMatcher.maximumAutoPlayCandidates`. A subset of `matches`.
    var autoPlayCandidates: [KyroSportsStreamMatch] = []
    /// Channels of the listed broadcaster that no evidence ties to this event. Shown separately,
    /// never tried automatically.
    var possibleBroadcasters: [KyroSportsStreamMatch] = []
    var diagnostics = KyroSportsStreamMatchDiagnostics()
    /// Filled after automatic playback ran: which streams were tried and how they did.
    var attemptStatuses: [String: KyroSportsStreamStatus] = [:]
    /// The stream the viewer picked on the discovery screen did not play, so the screen can say
    /// so instead of describing an automatic "best stream" attempt.
    var choiceDidNotPlay = false

    var highConfidenceMatch: KyroSportsStreamMatch? {
        guard confidence == .high, matches.count == 1 else { return nil }
        return matches[0]
    }
}

/// Pure matching and scoring. Index construction happens off the main actor,
/// while this type remains usable in host tests without LiveTVService.
///
/// Evidence rules (Build 37):
/// - A candidate must name the event's participants. League, sport or a
///   generic sports channel is never enough on its own.
/// - Participant names match as whole-word phrases, not substrings, so
///   "Houston" cannot match inside "Sam Houston" and "Iowa" cannot match
///   "Iowa State".
/// - A title that pairs one participant with anyone else ("Jacksonville
///   State vs Liberty"), names a different contest, names a different
///   league, or is a replay, highlights, preview or high-school broadcast is
///   rejected outright.
/// - Time overlap supports a match; it never creates one.
/// - High confidence needs both participants, a matchup structure or two
///   strong names, a start within 30 minutes, and a fresh guide.
enum KyroSportsStreamMatcher {
    static let maximumMatches = 10
    /// Streams tried automatically for one tap before the discovery screen takes over.
    static let maximumAutoPlayCandidates = 3
    static let initialBroadcasters = 6
    /// The expanded list is still bounded; all matching work runs in the detached matcher.
    static let maximumBroadcasters = 64
    /// Accepted matches kept beyond the initial list, for the expandable "More matches" group.
    static let maximumOverflowMatches = 50
    /// Initial-list rows one repeated network broadcast may fill (same programme, network,
    /// language, listing quality and feed). Automatic-playback candidates are always kept.
    static let maximumInitialPerBroadcast = 3
    /// Initial-list rows kept for channels whose own name lists the event, when there are more
    /// accepted matches than fit.
    static let reservedEventChannelSlots = 3
    /// Guide rows one event match may read, across both retrieval passes.
    static let maximumGuideRows = 2_000

    // MARK: Entry points

    static func match(
        request: KyroSportsStreamMatchRequest,
        channels: [LiveTVChannel],
        guide: EPGIndex?,
        canPlay: @escaping @Sendable (LiveTVChannel) -> Bool = { _ in true }
    ) async -> KyroSportsStreamMatchResult {
        await Task.detached(priority: .userInitiated) {
            matchSynchronously(request: request, channels: channels, guide: guide, canPlay: canPlay)
        }.value
    }

    /// Builds a throwaway index. The app keeps one per catalog revision instead
    /// (`LiveTVService.sportsStreamMatches`); tests and benchmarks use this.
    static func matchSynchronously(
        request: KyroSportsStreamMatchRequest,
        channels: [LiveTVChannel],
        guide: EPGIndex?,
        canPlay: @escaping @Sendable (LiveTVChannel) -> Bool = { _ in true }
    ) -> KyroSportsStreamMatchResult {
        guard let index = KyroSportsChannelIndex.build(channels: channels.filter(canPlay)) else {
            return emptyResult(for: request, guide: guide, cancelled: true)
        }
        let keys = guide.flatMap { index.guideKeyMap(for: $0) }
        if guide != nil, keys == nil { return emptyResult(for: request, guide: guide, cancelled: true) }
        return match(request: request, index: index, guide: guide, guideKeys: keys)
    }

    static func emptyResult(for request: KyroSportsStreamMatchRequest, guide: EPGIndex?, cancelled: Bool) -> KyroSportsStreamMatchResult {
        KyroSportsStreamMatchResult(confidence: .low, matches: [], manualSearchQuery: query(for: request.game),
                                    guideWasStale: isStale(guide, now: request.now), indexWasCancelled: cancelled,
                                    manualSearchSuggestions: manualSuggestions(for: request.game))
    }

    private static func isStale(_ guide: EPGIndex?, now: Date) -> Bool {
        guide.map { !EPGRefreshPolicy().freshness(of: $0, now: now).isUsable } ?? true
    }

    /// Matches one event against a prebuilt catalog index. Reads only the guide programmes that
    /// overlap the event and may name a participant, plus the channels whose names contain a
    /// participant word: never every channel, never the network.
    static func match(
        request: KyroSportsStreamMatchRequest,
        index: KyroSportsChannelIndex,
        guide: EPGIndex?,
        guideKeys: [String: [Int32]]?
    ) -> KyroSportsStreamMatchResult {
        let started = DispatchTime.now().uptimeNanoseconds
        let game = request.game
        let stale = isStale(guide, now: request.now)
        let context = MatchContext(game: game)
        let suggestions = manualSuggestions(for: game)
        var diagnostics = KyroSportsStreamMatchDiagnostics(catalogChannels: index.channels.count)
        func finish(_ result: KyroSportsStreamMatchResult) -> KyroSportsStreamMatchResult {
            var result = result
            diagnostics.matchDuration = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            result.diagnostics = diagnostics
            return result
        }
        // A side without a usable name (a TBD bracket slot) cannot be matched.
        guard context.isMatchable else { return finish(emptyResult(for: request, guide: guide, cancelled: false)) }

        let interval = eventInterval(for: game, request: request)
        var best: [Int: KyroSportsStreamMatch] = [:]
        func offer(_ offset: Int, _ candidate: KyroSportsStreamMatch) {
            if candidate.score > (best[offset]?.score ?? -1) { best[offset] = candidate }
        }

        // 1. Guide programmes around the event that may name a participant.
        if let guide, let guideKeys {
            let read = guideRows(guide: guide, interval: interval, context: context)
            if read.cancelled || Task.isCancelled { return finish(emptyResult(for: request, guide: guide, cancelled: true)) }
            let rows = read.rows
            diagnostics.guideRows = rows.count
            diagnostics.strongGuideRows = read.strongRows
            diagnostics.weakGuideRows = read.weakRows
            diagnostics.guideRowsTruncated = read.truncated
            for (number, row) in rows.enumerated() {
                if number.isMultiple(of: 128), Task.isCancelled {
                    return finish(emptyResult(for: request, guide: guide, cancelled: true))
                }
                guard let offsets = guideKeys[row.key] else { continue }
                for offset in offsets {
                    let channel = index.channels[Int(offset)]
                    guard let candidate = evaluate(program: row.program, channel: channel, context: context,
                                                   stale: stale, now: request.now) else { continue }
                    offer(Int(offset), candidate)
                }
            }
        }

        // 2. Event channels: the matchup in the channel's own name, guide or not.
        let named = index.offsets(containingAny: context.anchors)
        diagnostics.nameCandidates = named.count
        for (number, offset) in named.enumerated() {
            if number.isMultiple(of: 256), Task.isCancelled {
                return finish(emptyResult(for: request, guide: guide, cancelled: true))
            }
            if let candidate = evaluate(channelName: index.channels[offset], context: context, stale: stale) {
                offer(offset, candidate)
            }
        }

        let ordered = best.values.sorted(by: rankedBefore)
        let broadcasters = possibleBroadcasters(index: index, context: context, excluding: Set(best.keys), stale: stale)
        if Task.isCancelled { return finish(emptyResult(for: request, guide: guide, cancelled: true)) }
        guard !ordered.isEmpty else {
            var empty = emptyResult(for: request, guide: guide, cancelled: false)
            empty.possibleBroadcasters = broadcasters
            return finish(empty)
        }

        // Auto-launch only one unambiguous programme on one channel. Shared
        // guide IDs (SD/HD/backup variants) or a second matching broadcast
        // become a picker.
        let highs = ordered.filter { $0.confidence == .high }
        let confidence: KyroSportsStreamMatchConfidence
        if !stale, ordered.count == 1, highs.count == 1 {
            confidence = .high
        } else {
            confidence = .medium
        }
        let adjusted = ordered.map { match -> KyroSportsStreamMatch in
            let level: KyroSportsStreamMatchConfidence = confidence == .high ? .high
                : (match.confidence == .high ? .medium : match.confidence)
            return KyroSportsStreamMatch(id: match.id, channel: match.channel, program: match.program,
                                         confidence: level, score: match.score, reasons: match.reasons,
                                         isStale: match.isStale, source: match.source,
                                         isAutoPlayEligible: match.isAutoPlayEligible)
        }
        // Automatic playback keeps its Build 44 ranking: the best eligible matches among the top
        // `maximumMatches` by score, whatever the initial list shows around them.
        let autoPlay = Array(adjusted.prefix(maximumMatches).filter(\.isAutoPlayEligible).prefix(maximumAutoPlayCandidates))
        let selection = initialSelection(adjusted, pinned: Set(autoPlay.map(\.channel.id)), context: context)
        diagnostics.acceptedMatches = adjusted.count
        var result = KyroSportsStreamMatchResult(confidence: confidence, matches: selection.initial,
                                                 manualSearchQuery: query(for: game), guideWasStale: stale,
                                                 indexWasCancelled: false, manualSearchSuggestions: suggestions)
        result.overflowMatches = Array(selection.overflow.prefix(maximumOverflowMatches))
        result.omittedMatchCount = Swift.max(0, selection.overflow.count - maximumOverflowMatches)
        result.autoPlayCandidates = autoPlay
        result.possibleBroadcasters = broadcasters
        return finish(result)
    }

    // MARK: Guide retrieval

    struct GuideRows {
        var rows: [(key: String, program: EPGProgram)] = []
        var strongRows = 0
        var weakRows = 0
        var truncated = false
        var cancelled = false
    }

    /// Two bounded passes over the guide window. Full team names and other strong aliases read
    /// first; abbreviations and city names ("chi", "tampa"), which also occur inside unrelated
    /// words, get only the budget left and skip rows the first pass already read. Coverage equals
    /// one pass over every anchor whenever neither pass is truncated.
    static func guideRows(guide: EPGIndex, interval: DateInterval, context: MatchContext,
                          budget: Int = maximumGuideRows) -> GuideRows {
        var read = GuideRows()
        let strong = context.strongAnchors
        if !strong.isEmpty {
            let first = guide.windowRows(overlapping: interval, anchors: strong, limit: budget)
            if first.cancelled { return GuideRows(cancelled: true) }
            read.rows = first.rows
            read.strongRows = first.rows.count
            read.truncated = first.truncated
        }
        let weak = context.weakAnchors
        guard !weak.isEmpty else { return read }
        let remaining = budget - read.rows.count
        guard remaining > 0 else {
            // The first pass used the whole budget; weak-only rows were never read.
            read.truncated = true
            return read
        }
        if Task.isCancelled { return GuideRows(cancelled: true) }
        let second = guide.windowRows(overlapping: interval, anchors: weak, excluding: strong, limit: remaining)
        if second.cancelled { return GuideRows(cancelled: true) }
        read.rows += second.rows
        read.weakRows = second.rows.count
        read.truncated = read.truncated || second.truncated
        return read
    }

    // MARK: Initial list

    /// Splits ranked accepted matches into the initial list and the overflow, both in rank order.
    ///
    /// When everything fits, nothing changes. Otherwise, deterministically:
    /// 1. automatic-playback candidates (`pinned`) are always shown;
    /// 2. up to `reservedEventChannelSlots` channels whose name lists the event are shown;
    /// 3. the remaining slots fill by rank, but a repeated network broadcast (`broadcastGroup`)
    ///    takes at most `maximumInitialPerBroadcast` of them;
    /// 4. slots still empty fill by rank, so the list is never shorter than before.
    /// Overflow keeps every other accepted match with its evidence; nothing is downgraded.
    static func initialSelection(_ ranked: [KyroSportsStreamMatch], pinned: Set<String>,
                                 context: MatchContext) -> (initial: [KyroSportsStreamMatch], overflow: [KyroSportsStreamMatch]) {
        guard ranked.count > maximumMatches else { return (ranked, []) }
        var chosen = Set<String>()
        var perGroup: [String: Int] = [:]
        let groups = ranked.map { broadcastGroup($0, context: context) }
        func take(_ index: Int) {
            chosen.insert(ranked[index].channel.id)
            if let group = groups[index] { perGroup[group, default: 0] += 1 }
        }
        func open(_ index: Int) -> Bool { chosen.count < maximumMatches && !chosen.contains(ranked[index].channel.id) }
        for index in ranked.indices where pinned.contains(ranked[index].channel.id) && open(index) { take(index) }
        var reserved = 0
        for index in ranked.indices where reserved < reservedEventChannelSlots && ranked[index].source == .channelName && open(index) {
            take(index)
            reserved += 1
        }
        for index in ranked.indices where open(index) {
            if let group = groups[index], perGroup[group, default: 0] >= maximumInitialPerBroadcast { continue }
            take(index)
        }
        for index in ranked.indices where open(index) { take(index) }
        return (ranked.filter { chosen.contains($0.channel.id) }, ranked.filter { !chosen.contains($0.channel.id) })
    }

    /// The identity of one network broadcast as a channel carries it, or nil for a channel that
    /// stands on its own. Only guide matches on a known network's channels group, and only when
    /// the guide programme (title, subtitle, start and end), the language, the listing quality and
    /// any feed label (East, West, Alt…) all agree. Event channels, Game Pass slots, other
    /// languages and 4K/UHD/FHD/HD variants therefore never collapse into one another, and
    /// identical titles on unrelated channels are not assumed to be the same stream.
    static func broadcastGroup(_ match: KyroSportsStreamMatch, context: MatchContext) -> String? {
        guard match.source == .guide, let program = match.program else { return nil }
        let tokens = phraseTokens(match.channel.name + " " + match.channel.category)
        let nameTokens = phraseTokens(match.channel.name)
        let phrases = context.networkPhrases + allNetworkPhrases.filter { !context.networkPhrases.contains($0) }
        guard let network = phrases.first(where: { contains($0, in: nameTokens) }) else { return nil }
        let language = tokens.lazy.compactMap { languageTags[$0] }.first ?? "default"
        let feed = tokens.filter(feedTokens.contains).sorted().joined(separator: "+")
        let programme = normalized([program.title, program.subtitle].compactMap { $0 }.joined(separator: " | "))
        let start = Int(program.start.timeIntervalSinceReferenceDate / 60)
        let end = Int(program.end.timeIntervalSinceReferenceDate / 60)
        return [network.joined(separator: " "), language, String(listingQuality(phraseTokens(match.channel.name))),
                feed, programme, String(start), String(end)].joined(separator: "|")
    }

    /// Language words in channel names and groups ("ES | NFL", "NBC (Spanish)").
    static let languageTags: [String: String] = [
        "es": "es", "esp": "es", "spa": "es", "spanish": "es", "espanol": "es", "latino": "es", "latam": "es",
        "mx": "es", "fr": "fr", "french": "fr", "francais": "fr", "pt": "pt", "br": "pt", "portugues": "pt",
        "portuguese": "pt", "de": "de", "german": "de", "deutsch": "de", "it": "it", "italian": "it",
        "ar": "ar", "arabic": "ar", "sap": "sap"
    ]

    /// Labels that mark a distinct feed of the same network.
    static let feedTokens: Set<String> = [
        "east", "west", "pacific", "mountain", "central", "alt", "alternate", "backup", "feed", "home", "away", "plus"
    ]

    /// Every network phrase `networkPhrases` knows, so affiliates of an unlisted network group too.
    static let allNetworkPhrases: [[String]] = {
        var phrases: [[String]] = []
        for phrase in knownNetworks.values.flatMap({ $0 }) {
            let tokens = phraseTokens(phrase)
            if !tokens.isEmpty, !phrases.contains(tokens) { phrases.append(tokens) }
        }
        return phrases.sorted { $0.joined(separator: " ") < $1.joined(separator: " ") }
    }()

    /// Higher score first. Equal scores prefer a guide-confirmed slot, then the listed
    /// broadcaster's channel, then catalog identity, so the order never depends on hashing.
    static func rankedBefore(_ lhs: KyroSportsStreamMatch, _ rhs: KyroSportsStreamMatch) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.isAutoPlayEligible != rhs.isAutoPlayEligible { return lhs.isAutoPlayEligible }
        if (lhs.program != nil) != (rhs.program != nil) { return lhs.program != nil }
        return lhs.channel.id < rhs.channel.id
    }

    /// Channels of the listed broadcaster ("ESPN", "NBC", "Universo") that nothing ties to
    /// this event. A lead for manual choice only: a network name is never event evidence.
    static func possibleBroadcasters(index: KyroSportsChannelIndex, context: MatchContext,
                                     excluding matched: Set<Int>, stale: Bool) -> [KyroSportsStreamMatch] {
        guard !context.networkPhrases.isEmpty else { return [] }
        struct Lead {
            let offset: Int
            let national: Bool
            let quality: Int
            let length: Int
            let id: String
        }
        func precedes(_ lhs: Lead, _ rhs: Lead) -> Bool {
            if lhs.national != rhs.national { return lhs.national }
            if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
            if lhs.length != rhs.length { return lhs.length < rhs.length }
            return lhs.id < rhs.id
        }
        var top: [Lead] = []
        // Postings bound the search to network tokens. Keep only the best 64 rather than sorting
        // or retaining every affiliate in a large catalog.
        let offsets = index.offsets(containingAny: context.networkPhrases.compactMap(\.first))
        for (number, offset) in offsets.enumerated() {
            if number.isMultiple(of: 256), Task.isCancelled { return [] }
            guard !matched.contains(offset) else { continue }
            let channel = index.channels[offset]
            let tokens = phraseTokens(channel.name)
            guard context.networkPhrases.contains(where: { contains($0, in: tokens) }) else { continue }
            let lead = Lead(offset: offset, national: isNationalNetworkVariant(tokens, phrases: context.networkPhrases),
                            quality: listingQuality(tokens), length: channel.name.utf8.count, id: channel.id)
            if top.count == maximumBroadcasters, !precedes(lead, top[top.count - 1]) { continue }
            // Reject cheaply out-ranked affiliates before the more expensive conflict analysis.
            let evidence = analyze(channel.name + " | " + channel.category, context: context)
            guard !evidence.nonEvent, !evidence.leagueConflict else { continue }
            let position = top.firstIndex(where: { precedes(lead, $0) }) ?? top.count
            top.insert(lead, at: position)
            if top.count > maximumBroadcasters { top.removeLast() }
        }
        return top.map { lead in
            let channel = index.channels[lead.offset]
            return KyroSportsStreamMatch(id: "broadcaster|\(channel.id)", channel: channel, program: nil,
                                         confidence: .low, score: 0,
                                         reasons: ["Listed broadcaster; not confirmed to carry this event"],
                                         isStale: stale, source: .broadcaster)
        }
    }

    /// Listing text is a preference, not a measurement of the stream's resolution.
    private static func listingQuality(_ tokens: [String]) -> Int {
        if tokens.contains("4k") || tokens.contains(where: { $0.hasSuffix("4k") }) { return 5 }
        if tokens.contains("uhd") || tokens.contains(where: { $0.hasSuffix("uhd") }) { return 4 }
        if tokens.contains("fhd") || tokens.contains(where: { $0.hasSuffix("fhd") }) { return 3 }
        if tokens.contains("1080p") || tokens.contains(where: { $0.hasSuffix("1080p") }) { return 2 }
        if tokens.contains("hd") || tokens.contains(where: { $0.hasSuffix("hd") }) { return 1 }
        return 0
    }

    private static func isNationalNetworkVariant(_ tokens: [String], phrases: [[String]]) -> Bool {
        let suffixes: Set<String> = ["4k", "uhd", "fhd", "1080p", "hd", "us", "usa", "tv", "live", "east", "west", "national", "feed"]
        // Catalogs commonly prefix a country before the network ("USA | NBC UHD").
        let leadingRegions: Set<String> = ["us", "usa"]
        let nameTokens = tokens.first.map { leadingRegions.contains($0) } == true ? Array(tokens.dropFirst()) : tokens
        for phrase in phrases {
            if nameTokens == phrase { return true }
            if nameTokens.count >= phrase.count, Array(nameTokens.prefix(phrase.count)) == phrase,
               nameTokens.dropFirst(phrase.count).allSatisfy(suffixes.contains) { return true }
            // Providers also write NBC4K or UniversoHD without a separator.
            if phrase.count == 1, let first = nameTokens.first, first.hasPrefix(phrase[0]),
               suffixes.contains(String(first.dropFirst(phrase[0].count))),
               nameTokens.dropFirst().allSatisfy(suffixes.contains) { return true }
        }
        return false
    }

    // MARK: Context

    enum Strength: Int, Comparable {
        case weak = 1
        case strong = 2
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Alias: Hashable {
        let tokens: [String]
        let isStrong: Bool
        /// School and city names collide with longer names ("Iowa" in "Iowa
        /// State", "Houston" in "Sam Houston"). A guarded alias does not match
        /// when a qualifier word touches it.
        let guarded: Bool
    }

    struct Participant {
        let displayName: String
        let aliases: [Alias]
        /// Cheap substring prefilter: at least one must occur in a text before
        /// it is tokenized.
        let anchors: [String]
        /// One word of each strong alias that is not also a weak alias word ("bears" for
        /// "Chicago Bears", never "chicago" or "chi"). Every text that contains a strong alias
        /// contains one of these, so the first guide pass loses no strong evidence.
        var strongAnchors: [String] = []

        func strength(in tokens: [String]) -> Strength? {
            var best: Strength?
            for alias in aliases where KyroSportsStreamMatcher.occurs(alias, in: tokens) {
                if alias.isStrong { return .strong }
                best = .weak
            }
            return best
        }
    }

    struct MatchContext {
        let game: KyroSportsGame
        let home: Participant
        let away: Participant
        let ownLeagueTokens: Set<String>
        let otherLeaguePhrases: [[String]]
        let otherSportTokens: Set<String>
        let networkPhrases: [[String]]
        let anchors: [String]
        /// First-pass guide anchors: words of full names and other strong aliases.
        let strongAnchors: [String]
        /// Second-pass guide anchors: abbreviation and city words no strong anchor covers.
        let weakAnchors: [String]

        init(game: KyroSportsGame) {
            self.game = game
            home = KyroSportsStreamMatcher.participant(for: game.home.team, league: game.league)
            away = KyroSportsStreamMatcher.participant(for: game.away.team, league: game.league)
            ownLeagueTokens = KyroSportsStreamMatcher.leagueTokens(for: game.league)
            otherLeaguePhrases = KyroSportsStreamMatcher.otherLeaguePhrases(for: game.league)
            otherSportTokens = KyroSportsStreamMatcher.otherSportTokens(for: game.league)
            networkPhrases = KyroSportsStreamMatcher.networkPhrases(for: game.broadcast)
            anchors = Array(Set(home.anchors + away.anchors)).sorted()
            let strong = Set(home.strongAnchors + away.strongAnchors)
            strongAnchors = strong.sorted()
            weakAnchors = Set(anchors).subtracting(strong).sorted()
        }

        var isMatchable: Bool { !home.aliases.isEmpty && !away.aliases.isEmpty }

        func mayMention(_ normalizedText: String) -> Bool {
            anchors.contains { normalizedText.contains($0) }
        }
    }

    /// What one piece of text says about the event.
    struct Evidence {
        var home: Strength?
        var away: Strength?
        /// A "X vs Y" / "X at Y" segment pairs the two participants.
        var matchup = false
        /// The text pairs a participant with someone else, or names a
        /// different contest.
        var conflict = false
        /// Replay, highlights, preview, studio show or high-school broadcast.
        var nonEvent = false
        var leagueConflict = false
        var mentionsLeague = false
        var mentionsLive = false

        var bothSides: Bool { home != nil && away != nil }
        var anySide: Bool { home != nil || away != nil }
        var strongSides: Int { [home, away].filter { $0 == .strong }.count }
        var isRejected: Bool { conflict || nonEvent || leagueConflict }

        mutating func merge(_ other: Evidence) {
            home = max(home, other.home)
            away = max(away, other.away)
            matchup = matchup || other.matchup
            conflict = conflict || other.conflict
            nonEvent = nonEvent || other.nonEvent
            leagueConflict = leagueConflict || other.leagueConflict
            mentionsLeague = mentionsLeague || other.mentionsLeague
            mentionsLive = mentionsLive || other.mentionsLive
        }
    }

    // MARK: Programme scoring

    /// Why a candidate was not accepted. Stable codes for the internal Sports Match Report.
    enum Rejection: String, Codable, Sendable, CaseIterable {
        case noParticipant
        case oneParticipantNotEnough
        case namesTooWeak
        case otherContest
        case nonEvent
        case otherLeagueOrSport
        case outsideEventTime
        case channelContradictsGuide
        case groupNonEvent
        case groupOtherLeague
        case nameDateConflicts
    }

    enum Assessment {
        case accepted(KyroSportsStreamMatch)
        case rejected(Rejection)

        var match: KyroSportsStreamMatch? {
            if case .accepted(let match) = self { return match }
            return nil
        }
    }

    /// The first veto in `evidence`, most specific first.
    static func rejection(for evidence: Evidence) -> Rejection {
        if evidence.nonEvent { return .nonEvent }
        if evidence.leagueConflict { return .otherLeagueOrSport }
        if evidence.conflict { return .otherContest }
        return evidence.anySide ? .oneParticipantNotEnough : .noParticipant
    }

    static func evaluate(
        program: EPGProgram,
        channel: LiveTVChannel,
        context: MatchContext,
        stale: Bool,
        now: Date
    ) -> KyroSportsStreamMatch? {
        assess(program: program, channel: channel, context: context, stale: stale, now: now).match
    }

    static func assess(
        program: EPGProgram,
        channel: LiveTVChannel,
        context: MatchContext,
        stale: Bool,
        now: Date
    ) -> Assessment {
        let headline = normalized([program.title, program.subtitle].compactMap { $0 }.joined(separator: " | "))
        var evidence = Evidence()
        var fromSummary = false
        let headlineMentions = context.mayMention(headline)
        func analyzeHeadline() {
            evidence = analyze(program.title, context: context)
            if let subtitle = program.subtitle { evidence.merge(analyze(subtitle, context: context)) }
        }
        if headlineMentions { analyzeHeadline() }
        // A generic headline ("College Football") may carry the matchup in
        // the description. That is weaker evidence and never auto-launches,
        // and a headline naming another contest or a replay ("Iowa vs.
        // Northwestern (Replay)") vetoes whatever the description says.
        if !evidence.bothSides, !evidence.isRejected, let summary = program.summary,
           isGenericSportsHeadline(headline, context: context) {
            if !headlineMentions { analyzeHeadline() }
            guard !evidence.isRejected else { return .rejected(rejection(for: evidence)) }
            let lead = String(summary.prefix(280))
            if context.mayMention(normalized(lead)) {
                let summaryEvidence = analyze(lead, context: context)
                if summaryEvidence.bothSides, !summaryEvidence.isRejected {
                    evidence.merge(summaryEvidence)
                    fromSummary = true
                }
            }
        }
        guard evidence.anySide, !evidence.isRejected else { return .rejected(rejection(for: evidence)) }
        guard let timing = timing(of: program, game: context.game, now: now) else { return .rejected(.outsideEventTime) }
        // The channel itself can contradict its guide: a "Liberty @ Jacksonville State" event
        // channel, a replay feed, or a basketball group borrowing a football guide ID.
        let channelEvidence = channelContextEvidence(channel, context: context)
        guard !channelEvidence.isRejected else { return .rejected(.channelContradictsGuide) }

        let channelText = normalized(channel.name + " " + channel.category)
        let channelTokens = phraseTokensNormalized(channelText)
        let categoryTokens = Set(phraseTokens(program.category ?? ""))
        let leagueEvidence = evidence.mentionsLeague
            || !context.ownLeagueTokens.isDisjoint(with: categoryTokens)
            || !context.ownLeagueTokens.isDisjoint(with: channelTokens)
        let onListedNetwork = context.networkPhrases.contains { contains($0, in: channelTokens) }

        var reasons: [String] = []
        var score: Int
        var confidence: KyroSportsStreamMatchConfidence

        if evidence.bothSides {
            score = 60 + evidence.strongSides * 8 + (evidence.matchup ? 10 : 0)
            reasons.append(fromSummary
                ? "Both \(context.participantNoun) named in the programme description"
                : "Both \(context.participantNoun) named in the guide title")
            let identified = evidence.strongSides >= 1 && (evidence.matchup || evidence.strongSides == 2)
            confidence = identified && timing.isTight && !fromSummary ? .high : .medium
        } else {
            // One participant only. Plausible solely when the title is
            // clearly about this sport, starts on time, and names nobody else.
            let named = evidence.home != nil ? context.home : context.away
            guard [evidence.home, evidence.away].contains(.strong), timing.isTight, leagueEvidence,
                  !evidence.matchup else { return .rejected(.oneParticipantNotEnough) }
            score = 35
            confidence = .medium
            reasons.append("Only \(named.displayName) is named in the guide title")
        }
        reasons.append(timing.reason)
        if timing.isTight { score += 10 }
        if leagueEvidence { score += 5 }
        if onListedNetwork {
            score += 5
            reasons.append("Channel matches the listed broadcaster")
        }
        if evidence.mentionsLive { score += 3 }
        if stale {
            confidence = min(confidence, .medium)
            reasons.append("Guide is out of date; check before watching")
        }
        return .accepted(KyroSportsStreamMatch(id: "\(channel.id)|\(program.id)", channel: channel, program: program,
                                               confidence: confidence, score: score, reasons: reasons, isStale: stale,
                                               source: .guide,
                                               isAutoPlayEligible: confidence == .high && evidence.bothSides))
    }

    /// What the channel's own name and group say, for vetoes and support only.
    static func channelContextEvidence(_ channel: LiveTVChannel, context: MatchContext) -> Evidence {
        analyze(channel.name + " | " + channel.category, context: context)
    }

    /// A channel whose name pairs both participants: an IPTV event channel such as
    /// "DAZN UK: Michigan State @ Michigan" or "NCAAF 03: SHSU @ JXST". The name identifies the
    /// event even without a guide. The group ("USA | NCAAF") supports discovery but never proves
    /// a match; a group or date for another sport, league or day vetoes it.
    static func evaluate(channelName channel: LiveTVChannel, context: MatchContext, stale: Bool) -> KyroSportsStreamMatch? {
        assess(channelName: channel, context: context, stale: stale).match
    }

    static func assess(channelName channel: LiveTVChannel, context: MatchContext, stale: Bool) -> Assessment {
        guard context.mayMention(normalized(channel.name)) else { return .rejected(.noParticipant) }
        let evidence = analyze(channel.name, context: context)
        guard evidence.bothSides, !evidence.isRejected else { return .rejected(rejection(for: evidence)) }
        guard evidence.strongSides >= 1 else { return .rejected(.namesTooWeak) }
        let group = analyze(channel.category, context: context)
        guard !group.nonEvent else { return .rejected(.groupNonEvent) }
        guard !group.leagueConflict else { return .rejected(.groupOtherLeague) }
        let date = KyroSportsEventNameDate.check(channel.name, event: context.game.isStartTimeTBD ? nil : context.game.startTime)
        guard date != .conflicts else { return .rejected(.nameDateConflicts) }

        var score = 50 + evidence.strongSides * 4 + (evidence.matchup ? 5 : 0)
        var reasons = ["Channel name names both \(context.participantNoun)"]
        let leagueEvidence = evidence.mentionsLeague || group.mentionsLeague
        if group.mentionsLeague, !evidence.mentionsLeague {
            reasons.append("Listed under \(channel.category)")
        }
        if leagueEvidence { score += 5 }
        switch date {
        case .matches:
            score += 5
            reasons.append("Channel name date matches the event")
        case .none, .conflicts:
            reasons.append("No guide time to confirm the event")
        }
        if context.networkPhrases.contains(where: { contains($0, in: phraseTokens(channel.name)) }) {
            score += 3
            reasons.append("Channel matches the listed broadcaster")
        }
        // Both names strong, or a clear "X vs Y" with one strong name in a channel of this
        // sport. One strong name and a weak abbreviation ("MSU @ Michigan") is a lead only.
        let eligible = evidence.strongSides == 2 || (evidence.matchup && leagueEvidence)
        return .accepted(KyroSportsStreamMatch(
            id: channel.id, channel: channel, program: nil, confidence: .medium, score: score,
            reasons: reasons, isStale: stale, source: .channelName, isAutoPlayEligible: eligible))
    }

    // MARK: Text analysis

    static func analyze(_ text: String, context: MatchContext) -> Evidence {
        var evidence = Evidence()
        let segments = segments(of: text)
        let allTokens = segments.flatMap { $0 }
        for segment in segments {
            evidence.home = max(evidence.home, context.home.strength(in: segment))
            evidence.away = max(evidence.away, context.away.strength(in: segment))
            if segment == ["r"] || segment == ["rpt"] { evidence.nonEvent = true }
            for index in segment.indices where isSeparator(segment[index]) {
                guard index > segment.startIndex, index < segment.endIndex - 1 else { continue }
                let left = Array(segment[..<index])
                let right = Array(segment[(index + 1)...])
                let leftHome = context.home.strength(in: left) != nil
                let leftAway = context.away.strength(in: left) != nil
                let rightHome = context.home.strength(in: right) != nil
                let rightAway = context.away.strength(in: right) != nil
                let anyHit = leftHome || leftAway || rightHome || rightAway
                // "at" is ordinary English ("Football at Night") unless it
                // touches a participant.
                if segment[index] == "at", !anyHit { continue }
                // "Michigan State vs Michigan @ 12:00 PM ET": "at" before a time
                // or date is a kickoff annotation, not a second contest.
                if segment[index] == "at", right.first?.first?.isNumber == true { continue }
                let pairs = (leftHome && rightAway) || (leftAway && rightHome)
                // "x" is only a separator in "Team x Team" listings; elsewhere it is
                // part of a name, so it never signals a conflict.
                if segment[index] == "x" {
                    if pairs { evidence.matchup = true }
                    continue
                }
                if pairs {
                    evidence.matchup = true
                } else {
                    evidence.conflict = true
                }
            }
        }
        if allTokens.contains(where: nonEventTokens.contains)
            || nonEventPhrases.contains(where: { contains($0, in: allTokens) }) {
            evidence.nonEvent = true
        }
        evidence.mentionsLeague = !context.ownLeagueTokens.isDisjoint(with: allTokens)
        // Same schools, different sport ("College Basketball: Sam Houston vs
        // Jax State") is always a different event.
        if !context.otherSportTokens.isDisjoint(with: allTokens) {
            evidence.leagueConflict = true
        } else if !evidence.mentionsLeague,
                  context.otherLeaguePhrases.contains(where: { contains($0, in: allTokens) }) {
            evidence.leagueConflict = true
        }
        evidence.mentionsLive = allTokens.contains("live")
        return evidence
    }

    private static func isSeparator(_ token: String) -> Bool {
        token == "vs" || token == "v" || token == "versus" || token == "at" || token == "x"
    }

    /// Splits on title punctuation (`:`, `|`, parentheses, dashes, commas) so
    /// "College Football: Sam Houston at Jacksonville State (Live)" yields a
    /// matchup segment without the prefix or suffix.
    static func segments(of text: String) -> [[String]] {
        // Poll ranks ("(15) Michigan State", "#3 Michigan") would split or pad a
        // matchup segment.
        let folded = normalized(text)
            .replacingOccurrences(of: #"\(\s*#?\d{1,2}\s*\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"#\d{1,2}\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "@", with: " at ")
        let breaks: Set<Character> = [":", "|", "(", ")", "[", "]", "{", "}", "\u{2013}", "\u{2014}", ",", "/", "\u{2022}", ";", "!", "?"]
        var parts: [String] = []
        var current = ""
        for character in folded {
            if breaks.contains(character) {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
            .flatMap { $0.components(separatedBy: " - ") }
            .map(phraseTokensNormalized)
            .filter { !$0.isEmpty }
    }

    private static func isGenericSportsHeadline(_ headline: String, context: MatchContext) -> Bool {
        let tokens = Set(phraseTokensNormalized(headline))
        return !context.ownLeagueTokens.isDisjoint(with: tokens)
    }

    private static let nonEventTokens: Set<String> = [
        "replay", "replays", "rebroadcast", "encore", "highlights", "highlight", "recap", "preview",
        "previews", "pregame", "postgame", "countdown", "rewind", "reair", "condensed", "analysis", "debate"
    ]

    private static let nonEventPhrases: [[String]] = [
        ["pre", "game"], ["post", "game"], ["high", "school"], ["hs", "football"], ["in", "60"], ["all", "22"],
        ["game", "of", "the", "week", "replay"], ["full", "game", "replay"]
    ]

    // MARK: Phrase matching

    static func occurs(_ alias: Alias, in tokens: [String]) -> Bool {
        let count = alias.tokens.count
        guard count > 0, tokens.count >= count else { return false }
        var index = 0
        while index + count <= tokens.count {
            if tokens[index] == alias.tokens[0], Array(tokens[index..<(index + count)]) == alias.tokens,
               !(alias.guarded && isQualified(tokens, start: index, end: index + count)) {
                return true
            }
            index += 1
        }
        return false
    }

    static func contains(_ phrase: [String], in tokens: [String]) -> Bool {
        occurs(Alias(tokens: phrase, isStrong: true, guarded: false), in: tokens)
    }

    private static let qualifierPrefixes: Set<String> = [
        "sam", "san", "north", "south", "east", "west", "northern", "southern", "eastern", "western",
        "central", "middle", "new", "little", "coastal", "ut", "uc", "ul", "uw", "fort", "upper", "lower"
    ]

    private static let qualifierSuffixes: Set<String> = [
        "state", "st", "tech", "southern", "christian", "baptist", "international", "atlantic", "poly",
        "methodist", "wesleyan", "lutheran", "pacific"
    ]

    /// "Iowa" followed by "State", "Houston" preceded by "Sam", "Texas"
    /// followed by "A&M": the word belongs to a different school.
    private static func isQualified(_ tokens: [String], start: Int, end: Int) -> Bool {
        if start > 0, qualifierPrefixes.contains(tokens[start - 1]) { return true }
        guard end < tokens.count else { return false }
        if qualifierSuffixes.contains(tokens[end]) { return true }
        if tokens[end] == "a", end + 1 < tokens.count, tokens[end + 1] == "and" || tokens[end + 1] == "m" { return true }
        return false
    }

    // MARK: Aliases

    static func participant(for team: KyroSportsTeam, league: KyroSportLeague) -> Participant {
        var aliases: [Alias] = []
        func add(_ text: String?, strong: Bool, guarded: Bool) {
            guard let text else { return }
            let tokens = phraseTokens(text)
            guard !tokens.isEmpty, !tokens.allSatisfy(ignorableAliasTokens.contains) else { return }
            // One- or two-letter lone words ("LA", "SF") are too ambiguous.
            if tokens.count == 1, tokens[0].count < 3 { return }
            if let existing = aliases.firstIndex(where: { $0.tokens == tokens }) {
                let current = aliases[existing]
                aliases[existing] = Alias(tokens: tokens, isStrong: current.isStrong || strong,
                                          guarded: current.guarded && guarded)
                return
            }
            aliases.append(Alias(tokens: tokens, isStrong: strong, guarded: guarded))
        }

        let full = team.fullName
        if normalized(full).trimmingCharacters(in: .whitespaces) == "tbd" {
            return Participant(displayName: full, aliases: [], anchors: [])
        }
        switch league {
        case .atp, .wta:
            add(full, strong: true, guarded: false)
            for name in team.alternateNames { add(name, strong: true, guarded: false) }
            // Guides usually print surnames: "Alcaraz v Shelton".
            if let surname = phraseTokens(full).last, surname.count >= 3 {
                add(surname, strong: true, guarded: false)
            }
        case .soccer:
            add(full, strong: true, guarded: false)
            add(team.nickname, strong: true, guarded: false)
            add(team.location, strong: true, guarded: false)
            for name in team.alternateNames { add(name, strong: true, guarded: false) }
            add(team.abbreviation, strong: team.abbreviation.count >= 3, guarded: false)
        case .collegeFootball, .collegeBasketballMen, .collegeBasketballWomen:
            add(full, strong: true, guarded: false)
            add(team.location, strong: true, guarded: true)
            for name in team.alternateNames { add(name, strong: true, guarded: true) }
            if let location = team.location {
                let tokens = phraseTokens(location)
                if tokens.last == "state", tokens.count > 1 {
                    add((tokens.dropLast() + ["st"]).joined(separator: " "), strong: true, guarded: true)
                }
            }
            // Mascots repeat across schools (Gamecocks, Tigers, Bulldogs).
            add(team.nickname, strong: false, guarded: true)
            add(team.abbreviation, strong: team.abbreviation.count >= 4, guarded: false)
        case .nfl, .nba, .nhl, .mlb:
            add(full, strong: true, guarded: false)
            add(team.nickname, strong: true, guarded: false)
            for name in team.alternateNames { add(name, strong: true, guarded: false) }
            // City names are shared by every team in a market.
            add(team.location, strong: false, guarded: false)
            add(team.abbreviation, strong: false, guarded: false)
        }
        for key in [full, team.location].compactMap({ $0 }) {
            for extra in curatedAliases[phraseTokens(key).joined(separator: " ")] ?? [] {
                add(extra, strong: true, guarded: false)
            }
        }
        // The most distinctive word of each alias: "jax" for "Jax State", never "state", so a
        // guide query or name lookup does not pull every "State" programme and channel.
        let anchors = Set(aliases.compactMap { alias in
            let distinctive = alias.tokens.filter { !genericAnchorTokens.contains($0) }
            return (distinctive.isEmpty ? alias.tokens : distinctive).max(by: { $0.count < $1.count })
        }).sorted()
        // First-pass words avoid weak-alias words, which are shared ("Chicago") or short enough to
        // occur inside unrelated words ("chi" in "children"). Falls back to the usual word only
        // when a strong alias consists of nothing else.
        let weakWords = Set(aliases.filter { !$0.isStrong }.flatMap(\.tokens))
        let strongAnchors = Set(aliases.filter(\.isStrong).compactMap { alias -> String? in
            let distinctive = alias.tokens.filter { !genericAnchorTokens.contains($0) }
            let pool = distinctive.isEmpty ? alias.tokens : distinctive
            let preferred = pool.filter { !weakWords.contains($0) }
            return (preferred.isEmpty ? pool : preferred).max(by: { $0.count < $1.count })
        }).sorted()
        let display = (league == .collegeFootball || league == .collegeBasketballMen || league == .collegeBasketballWomen) ? (team.location ?? team.nickname) : team.nickname
        return Participant(displayName: display, aliases: aliases, anchors: anchors, strongAnchors: strongAnchors)
    }

    private static let ignorableAliasTokens: Set<String> = ["the", "of", "university", "fc", "club", "team"]

    private static let genericAnchorTokens: Set<String> = [
        "state", "st", "university", "college", "city", "north", "south", "east", "west", "new", "san", "los",
        "las", "saint", "the", "of", "fc", "and", "a", "m", "tech", "central", "northern", "southern", "eastern",
        "western"
    ]

    /// Names guides use that the provider does not send. Keyed by normalized
    /// full name or location.
    static let curatedAliases: [String: [String]] = [
        "sam houston": ["sam houston state", "sam houston st", "shsu"],
        "jacksonville state": ["jax state", "jax st", "jacksonville st", "jxst", "jvst"],
        "new york giants": ["ny giants"], "new york jets": ["ny jets"],
        "san francisco 49ers": ["sf 49ers", "niners"],
        "los angeles rams": ["la rams"], "los angeles chargers": ["la chargers"],
        "los angeles lakers": ["la lakers"], "los angeles clippers": ["la clippers"],
        "new york knicks": ["ny knicks"], "philadelphia 76ers": ["sixers"],
        "los angeles dodgers": ["la dodgers"], "los angeles angels": ["la angels"],
        "new york yankees": ["ny yankees"], "new york mets": ["ny mets"],
        "los angeles kings": ["la kings"], "new york rangers": ["ny rangers"],
        "new york islanders": ["ny islanders"], "tampa bay buccaneers": ["bucs"]
    ]

    static func leagueTokens(for league: KyroSportLeague) -> Set<String> {
        switch league {
        case .nfl: ["nfl", "football"]
        case .collegeFootball: ["ncaa", "ncaaf", "college", "cfb", "football", "fbs", "fcs"]
        case .collegeBasketballMen: ["ncaa", "ncaam", "college", "basketball", "march madness"]
        case .collegeBasketballWomen: ["ncaa", "ncaaw", "college", "basketball", "march madness"]
        case .nba: ["nba", "basketball"]
        case .nhl: ["nhl", "hockey"]
        case .mlb: ["mlb", "baseball"]
        case .atp: ["atp", "tennis"]
        case .wta: ["wta", "tennis"]
        case .soccer: ["soccer", "football", "futbol", "football club", "fc"]
        }
    }

    /// Words that put a programme in a different competition. Ignored when
    /// the programme also names this league.
    static func otherLeaguePhrases(for league: KyroSportLeague) -> [[String]] {
        let all: [KyroSportLeague: [[String]]] = [
            .nfl: [["ncaa"], ["ncaaf"], ["college"], ["cfb"], ["ufl"], ["cfl"], ["nba"], ["nhl"], ["mlb"]],
            .collegeFootball: [["nfl"], ["ufl"], ["cfl"], ["nba"], ["nhl"], ["mlb"], ["basketball"], ["hockey"],
                               ["soccer"], ["volleyball"], ["ncaab"], ["ncaaw"], ["ncaawb"], ["cbb"], ["wbb"],
                               ["mbb"]],
            .nba: [["wnba"], ["ncaa"], ["ncaab"], ["college"], ["g", "league"], ["nfl"], ["nhl"], ["mlb"]],
            .collegeBasketballMen: [["nba"], ["wnba"], ["ncaaw"], ["ncaawb"], ["wbb"], ["women", "college"], ["nfl"], ["nhl"], ["mlb"]],
            .collegeBasketballWomen: [["nba"], ["wnba"], ["ncaam"], ["mbb"], ["men", "college"], ["nfl"], ["nhl"], ["mlb"]],
            .nhl: [["ahl"], ["echl"], ["ohl"], ["whl"], ["ncaa"], ["college"], ["nfl"], ["nba"], ["mlb"]],
            .mlb: [["milb"], ["ncaa"], ["college"], ["nfl"], ["nba"], ["nhl"]],
            .atp: [["wta"], ["women"], ["womens"], ["doubles"]],
            .wta: [["atp"], ["men"], ["mens"], ["doubles"]],
            .soccer: [["nfl"], ["nba"], ["nhl"], ["mlb"], ["ncaa"], ["college football"], ["futsal"]]
        ]
        return all[league] ?? []
    }

    static func otherSportTokens(for league: KyroSportLeague) -> Set<String> {
        let football: Set<String> = ["basketball", "hockey", "baseball", "softball", "soccer", "volleyball",
                                     "lacrosse", "wrestling", "tennis", "golf"]
        switch league {
        case .nfl, .collegeFootball: return football
        case .collegeBasketballMen, .collegeBasketballWomen: return ["football", "hockey", "baseball", "soccer", "tennis"]
        case .nba: return ["football", "hockey", "baseball", "soccer", "volleyball", "tennis"]
        case .nhl: return ["football", "basketball", "baseball", "soccer", "tennis"]
        case .mlb: return ["football", "basketball", "hockey", "softball", "soccer", "tennis"]
        case .atp, .wta: return ["football", "basketball", "hockey", "baseball", "soccer", "padel", "pickleball"]
        case .soccer: return ["football", "basketball", "hockey", "baseball", "tennis", "golf", "rugby"]
        }
    }

    /// Channel-name phrases for the ESPN broadcaster label. Ranking support
    /// only; a network never makes a match by itself.
    static func networkPhrases(for broadcast: String?) -> [[String]] {
        guard let broadcast else { return [] }
        var phrases: [[String]] = []
        for part in broadcast.split(whereSeparator: { "/,&".contains($0) }) {
            let key = phraseTokens(String(part)).joined(separator: " ")
            guard !key.isEmpty else { continue }
            for phrase in knownNetworks[key] ?? [key] {
                let tokens = phraseTokens(phrase)
                if !tokens.isEmpty, !phrases.contains(tokens) { phrases.append(tokens) }
            }
        }
        return phrases
    }

    /// ESPN broadcaster labels to the channel-name phrases that carry them.
    static let knownNetworks: [String: [String]] = [
        "cbssn": ["cbs sports network", "cbssn", "cbs sports net"],
        "espn": ["espn"], "espn2": ["espn2", "espn 2"], "espnu": ["espnu"],
        "espnews": ["espnews"], "fs1": ["fs1", "fox sports 1"], "fs2": ["fs2", "fox sports 2"],
        "secn": ["sec network", "secn"], "accn": ["acc network", "accn"],
        "btn": ["big ten network", "btn"], "nfl net": ["nfl network"], "nba tv": ["nba tv"],
        "nhl net": ["nhl network"], "mlb net": ["mlb network"], "tnt": ["tnt"], "trutv": ["trutv"],
        "tennis channel": ["tennis channel"], "abc": ["abc"], "cbs": ["cbs"],
        "nbc": ["nbc", "nbc4k", "nbcuhd", "nbcfhd", "nbc1080p", "nbchd"],
        "universo": ["universo", "universo4k", "universouhd", "universofhd", "universo1080p", "universohd"],
        "fox": ["fox"]
    ]

    // MARK: Time

    struct Timing {
        let isTight: Bool
        let reason: String
    }

    /// Time supports a candidate; it never creates one. A programme must
    /// overlap the event start, and may not begin more than 90 minutes after
    /// it (that is a later replay slot).
    static func timing(of program: EPGProgram, game: KyroSportsGame, now: Date) -> Timing? {
        guard let start = game.startTime, !game.isStartTimeTBD else {
            guard program.isAiring(at: now) else { return nil }
            return Timing(isTight: game.status.isLive, reason: "Programme is airing now")
        }
        guard program.end > start.addingTimeInterval(-15 * 60),
              program.start < start.addingTimeInterval(90 * 60) else { return nil }
        let offset = program.start.timeIntervalSince(start)
        let minutes = Int(abs(offset) / 60)
        let coversStart = program.start <= start && program.end >= start.addingTimeInterval(60 * 60)
            && offset >= -60 * 60
        if abs(offset) <= 30 * 60 {
            return Timing(isTight: true, reason: minutes == 0
                          ? "Guide start matches the scheduled start"
                          : "Guide start is \(minutes) min from the scheduled start")
        }
        if coversStart {
            return Timing(isTight: true, reason: "Guide slot covers the scheduled start")
        }
        return Timing(isTight: false, reason: "Guide time is \(minutes) min from the scheduled start")
    }

    static func eventInterval(for game: KyroSportsGame, request: KyroSportsStreamMatchRequest) -> DateInterval {
        let center = game.isStartTimeTBD ? request.now : (game.startTime ?? request.now)
        return DateInterval(start: center.addingTimeInterval(-request.eventWindow), end: center.addingTimeInterval(request.eventWindow))
    }

    // MARK: Manual search

    static func query(for game: KyroSportsGame) -> String {
        "\(game.away.team.fullName) \(game.home.team.fullName)"
    }

    static func manualSuggestions(for game: KyroSportsGame) -> [String] {
        var values: [String] = []
        func add(_ value: String?) {
            guard let value, !value.isEmpty, value.uppercased() != "TBD", !values.contains(value) else { return }
            values.append(value)
        }
        for side in [game.away, game.home] {
            switch game.league {
            case .collegeFootball, .collegeBasketballMen, .collegeBasketballWomen: add(side.team.location ?? side.team.nickname)
            case .atp, .wta: add(side.team.nickname.split(separator: " ").last.map(String.init))
            default: add(side.team.nickname)
            }
        }
        for network in (game.broadcast ?? "").split(separator: "/") {
            add(network.trimmingCharacters(in: .whitespaces))
        }
        return values
    }

    /// Indexed candidate retrieval terms for the disk-backed Live TV catalog. Include provider
    /// abbreviations and alternate spellings because event channels often use only forms such as
    /// `SHSU @ JXST`; the full matcher still decides whether any retrieved row is a real match.
    static func candidateSearchTerms(for game: KyroSportsGame) -> [String] {
        var values: [String] = []
        func add(_ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, value.uppercased() != "TBD", !values.contains(value) else { return }
            values.append(value)
        }
        for value in manualSuggestions(for: game) { add(value) }
        for side in [game.away, game.home] {
            add(side.team.fullName)
            add(side.team.location)
            add(side.team.nickname)
            add(side.team.abbreviation)
            for alternate in side.team.alternateNames { add(alternate) }
            let participant = participant(for: side.team, league: game.league)
            for alias in participant.aliases { add(alias.tokens.joined(separator: " ")) }
            for anchor in participant.anchors { add(anchor) }
        }
        return values
    }

    /// Guide channel keys with a programme around the event that may name a participant. These
    /// are normalized guide IDs, so the indexed catalog can retrieve exactly the airing channels.
    static func guideCandidateKeys(guide: EPGIndex, request: KyroSportsStreamMatchRequest) -> [String] {
        let context = MatchContext(game: request.game)
        guard context.isMatchable else { return [] }
        let read = guideRows(guide: guide, interval: eventInterval(for: request.game, request: request), context: context)
        guard !read.cancelled else { return [] }
        var seen = Set<String>()
        return read.rows.compactMap { seen.insert($0.key).inserted ? $0.key : nil }
    }

    // MARK: Normalization

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
    }

    /// Whole-word tokens, keeping one-letter words so "Texas A&M" and
    /// "C. Alcaraz" keep their shape.
    static func phraseTokens(_ value: String) -> [String] {
        phraseTokensNormalized(normalized(value))
    }

    static func phraseTokensNormalized(_ value: String) -> [String] {
        value.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func tokens(_ value: String) -> [String] {
        phraseTokens(value).filter { $0.count > 1 }
    }
}

private extension KyroSportsStreamMatcher.MatchContext {
    var participantNoun: String {
        game.league == .atp || game.league == .wta ? "players" : "teams"
    }
}

private func max(_ lhs: KyroSportsStreamMatcher.Strength?, _ rhs: KyroSportsStreamMatcher.Strength?) -> KyroSportsStreamMatcher.Strength? {
    switch (lhs, rhs) {
    case let (left?, right?): return Swift.max(left, right)
    case let (left?, nil): return left
    case let (nil, right?): return right
    case (nil, nil): return nil
    }
}
