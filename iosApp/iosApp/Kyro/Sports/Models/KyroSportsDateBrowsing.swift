import Foundation

/// Hub filter chips, in the order the Sports tab shows them.
enum KyroSportsCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case all
    case nfl
    case nba
    case nhl
    case mlb
    case collegeFootball
    case collegeBasketballMen
    case collegeBasketballWomen
    case atp
    case wta
    case soccer

    var id: String { rawValue }

    /// Visual order: All | NFL | NCAA | NBA | NHL | MLB | ATP | WTA
    /// Menu and filter-chip options are immutable data; keep one lightweight array rather than
    /// allocating it during every Sports Hub body/menu reconstruction.
    static let filterOrder: [KyroSportsCategory] = {
        [.all, .nfl, .collegeFootball, .nba, .nhl, .mlb, .collegeBasketballMen, .collegeBasketballWomen, .soccer, .atp, .wta]
    }()

    var displayName: String {
        switch self {
        case .all: "All Sports"
        case .nfl: KyroSportLeague.nfl.displayName
        case .nba: KyroSportLeague.nba.displayName
        case .nhl: KyroSportLeague.nhl.displayName
        case .mlb: KyroSportLeague.mlb.displayName
        case .collegeFootball: KyroSportLeague.collegeFootball.displayName
        case .collegeBasketballMen: KyroSportLeague.collegeBasketballMen.displayName
        case .collegeBasketballWomen: KyroSportLeague.collegeBasketballWomen.displayName
        case .atp: KyroSportLeague.atp.displayName
        case .wta: KyroSportLeague.wta.displayName
        case .soccer: KyroSportLeague.soccer.displayName
        }
    }

    /// The sport selector's option names (Build 39).
    var menuName: String {
        switch self {
        case .atp: "ATP Tennis"
        case .wta: "WTA Tennis"
        case .soccer: "Soccer"
        default: displayName
        }
    }

    var shortName: String {
        switch self {
        case .all: "All"
        case .nfl: KyroSportLeague.nfl.shortName
        case .nba: KyroSportLeague.nba.shortName
        case .nhl: KyroSportLeague.nhl.shortName
        case .mlb: KyroSportLeague.mlb.shortName
        case .collegeFootball: KyroSportLeague.collegeFootball.shortName
        case .collegeBasketballMen: KyroSportLeague.collegeBasketballMen.shortName
        case .collegeBasketballWomen: KyroSportLeague.collegeBasketballWomen.shortName
        case .atp: KyroSportLeague.atp.shortName
        case .wta: KyroSportLeague.wta.shortName
        case .soccer: KyroSportLeague.soccer.shortName
        }
    }

    var symbolName: String {
        switch self {
        case .all: "sportscourt.fill"
        case .nfl: KyroSportLeague.nfl.symbolName
        case .nba: KyroSportLeague.nba.symbolName
        case .nhl: KyroSportLeague.nhl.symbolName
        case .mlb: KyroSportLeague.mlb.symbolName
        case .collegeFootball: KyroSportLeague.collegeFootball.symbolName
        case .collegeBasketballMen: KyroSportLeague.collegeBasketballMen.symbolName
        case .collegeBasketballWomen: KyroSportLeague.collegeBasketballWomen.symbolName
        case .atp: KyroSportLeague.atp.symbolName
        case .wta: KyroSportLeague.wta.symbolName
        case .soccer: KyroSportLeague.soccer.symbolName
        }
    }

    var leagues: [KyroSportLeague] {
        switch self {
        // Soccer is intentionally loaded through its own filter: its verified
        // registry spans dozens of routes and should never make the default
        // All Sports refresh fan out across every competition.
        case .all: KyroSportLeague.allCases.filter { $0 != .soccer }
        case .nfl: [.nfl]
        case .nba: [.nba]
        case .nhl: [.nhl]
        case .mlb: [.mlb]
        case .collegeFootball: [.collegeFootball]
        case .collegeBasketballMen: [.collegeBasketballMen]
        case .collegeBasketballWomen: [.collegeBasketballWomen]
        case .atp: [.atp]
        case .wta: [.wta]
        case .soccer: [.soccer]
        }
    }

    var league: KyroSportLeague? {
        switch self {
        case .all: nil
        case .nfl: .nfl
        case .nba: .nba
        case .nhl: .nhl
        case .mlb: .mlb
        case .collegeFootball: .collegeFootball
        case .collegeBasketballMen: .collegeBasketballMen
        case .collegeBasketballWomen: .collegeBasketballWomen
        case .atp: .atp
        case .wta: .wta
        case .soccer: .soccer
        }
    }

    init(league: KyroSportLeague) {
        switch league {
        case .nfl: self = .nfl
        case .nba: self = .nba
        case .nhl: self = .nhl
        case .mlb: self = .mlb
        case .collegeFootball: self = .collegeFootball
        case .collegeBasketballMen: self = .collegeBasketballMen
        case .collegeBasketballWomen: self = .collegeBasketballWomen
        case .atp: self = .atp
        case .wta: self = .wta
        case .soccer: self = .soccer
        }
    }
}

/// Why the selected local day has no rows. Failures stay distinct from empty.
enum KyroSportsDateCoverage: Equatable, Sendable {
    case games
    case empty
    case unavailable
    case outsideFeed(KyroSportLeague)
    case failed(KyroSportsDataError)
    case offline
}

/// Horizontally swipeable local-day range. Past/future counts can grow later
/// without changing callers that already take the visible-day list.
enum KyroSportsBrowseCalendar {
    static let pastDayCount = 3
    static let futureDayCount = 7

    static func startOfDay(_ date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date)
    }

    static func visibleDays(
        now: Date,
        calendar: Calendar,
        pastDayCount: Int = pastDayCount,
        futureDayCount: Int = futureDayCount
    ) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (-pastDayCount...futureDayCount).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: today)
        }
    }

    static func isToday(_ day: Date, now: Date, calendar: Calendar) -> Bool {
        calendar.isDate(day, inSameDayAs: now)
    }
}

/// Date-local schedule assembly for All Sports and single-league chips.
enum KyroSportsDaySchedule {
    static let sectionOrder: [KyroSportLeague] = [.nfl, .collegeFootball, .collegeBasketballMen, .collegeBasketballWomen, .nba, .nhl, .mlb, .soccer, .atp, .wta]

    static func filtered(_ games: [KyroSportsGame], conference: String? = nil, top25Only: Bool = false) -> [KyroSportsGame] {
        games.filter { game in
            let teams = [game.home.team, game.away.team]
            if top25Only && ![game.home, game.away].contains(where: { ($0.rank ?? 0) > 0 && ($0.rank ?? 0) <= 25 }) { return false }
            guard let conference, !conference.isEmpty else { return true }
            return teams.contains { $0.conference?.localizedCaseInsensitiveCompare(conference) == .orderedSame }
        }
    }

    struct SportSection: Identifiable, Equatable, Sendable {
        let league: KyroSportLeague
        let games: [KyroSportsGame]
        var id: KyroSportLeague { league }
    }

    static func sportSections(from games: [KyroSportsGame]) -> [SportSection] {
        sectionOrder.compactMap { league in
            let members = games.filter { $0.league == league }.sorted(by: scheduleOrder)
            return members.isEmpty ? nil : SportSection(league: league, games: members)
        }
    }

    /// Games whose kickoff falls on the user's local calendar day.
    static func games(
        from games: [KyroSportsGame],
        on day: Date,
        calendar: Calendar,
        now: Date? = nil
    ) -> [KyroSportsGame] {
        // One day interval instead of a calendar comparison per game: `isDate(_:inSameDayAs:)`
        // cost about 3 µs a game, which made each All Sports aggregate milliseconds long.
        let interval = dayInterval(for: day, calendar: calendar)
        return games.filter { game in
            guard let start = game.startTime else { return false }
            return interval.contains(start)
        }
    }

    /// The local calendar day containing `day`, as a half-open interval. Same answer as
    /// `Calendar.isDate(_:inSameDayAs:)`, including days that DST makes 23 or 25 hours long.
    static func dayInterval(for day: Date, calendar: Calendar) -> Range<Date> {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start).map { calendar.startOfDay(for: $0) }
            ?? start.addingTimeInterval(86_400)
        return start..<end
    }

    /// Merge league payloads, drop duplicates by league + provider game ID,
    /// then apply the same stable live-first ordering used by sport sections.
    static func aggregate(
        _ leagueGames: [[KyroSportsGame]],
        on day: Date,
        calendar: Calendar,
        now: Date? = nil
    ) -> [KyroSportsGame] {
        let merged = deduplicatedByLeagueAndProviderID(leagueGames.flatMap { $0 })
        return games(from: merged, on: day, calendar: calendar, now: now)
            .sorted(by: scheduleOrder)
    }

    static func deduplicatedByLeagueAndProviderID(_ games: [KyroSportsGame]) -> [KyroSportsGame] {
        var seen = Set<String>()
        var accepted: [KyroSportsGame] = []
        for game in games {
            let key = "\(game.league.rawValue)|\(game.id.provider)|\(game.id.rawID)"
            if seen.insert(key).inserted {
                accepted.append(game)
            }
        }
        return accepted
    }

    static func chronologicalOrder(_ lhs: KyroSportsGame, _ rhs: KyroSportsGame) -> Bool {
        let left = lhs.startTime ?? .distantFuture
        let right = rhs.startTime ?? .distantFuture
        if left != right { return left < right }
        if lhs.league.rawValue != rhs.league.rawValue {
            return lhs.league.rawValue < rhs.league.rawValue
        }
        return KyroSportsReconciler.deterministicOrder(lhs, rhs)
    }

    /// Display order is based only on normalized lifecycle and scheduled start,
    /// so score and clock polling cannot move a row. Interrupted games are an
    /// explicit group rather than masquerading as upcoming or final.
    static func scheduleOrder(_ lhs: KyroSportsGame, _ rhs: KyroSportsGame) -> Bool {
        let leftRank = scheduleRank(lhs.status)
        let rightRank = scheduleRank(rhs.status)
        if leftRank != rightRank { return leftRank < rightRank }

        let leftStart = lhs.startTime
        let rightStart = rhs.startTime
        if leftStart != rightStart {
            switch (leftStart, rightStart) {
            case let (left?, right?):
                return leftRank == 3 ? left > right : left < right
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                break
            }
        }
        return KyroSportsReconciler.deterministicOrder(lhs, rhs)
    }

    private static func scheduleRank(_ status: KyroGameStatus) -> Int {
        switch status {
        case .live: 0
        case .scheduled: 1
        case .postponed, .canceled, .suspended, .unknown: 2
        case .final: 3
        }
    }

    /// Featured event for the visible day: live first, then the next kickoff,
    /// then the most recently finished game. Never crosses an unrelated sport
    /// because `games` is already category-filtered.
    static func featuredEvent(from games: [KyroSportsGame], now: Date) -> KyroSportsGame? {
        let ordered = games.sorted(by: chronologicalOrder)
        if let live = ordered.first(where: { $0.status.isLive }) { return live }
        if let upcoming = ordered.first(where: { game in
            guard let start = game.startTime else { return false }
            return start >= now && (game.status.isScheduled || game.status.isUnknown)
        }) {
            return upcoming
        }
        return ordered.last(where: { $0.status.isFinal })
    }

    /// Football week feeds only cover their current slate. A selected day
    /// outside that span is unavailable, not an empty day inside the slate.
    static func footballCoverage(
        league: KyroSportLeague,
        day: Date,
        weekGames: [KyroSportsGame],
        calendar: Calendar
    ) -> KyroSportsDateCoverage? {
        guard league == .nfl || league == .collegeFootball else { return nil }
        let dayStart = calendar.startOfDay(for: day)
        let onDay = games(from: weekGames, on: dayStart, calendar: calendar)
        if !onDay.isEmpty { return .games }
        let feedDays = Set(weekGames.compactMap { game -> Date? in
            game.startTime.map { calendar.startOfDay(for: $0) }
        })
        guard let earliest = feedDays.min(), let latest = feedDays.max() else {
            return .empty
        }
        if dayStart < earliest || dayStart > latest {
            return .outsideFeed(league)
        }
        return .empty
    }

    static func emptyState(
        coverage: KyroSportsDateCoverage,
        category: KyroSportsCategory,
        day: Date,
        now: Date,
        calendar: Calendar
    ) -> KyroSportsDashboardEmptyState {
        let dayText = day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        switch coverage {
        case .games:
            return KyroSportsDashboardEmptyState(
                symbolName: "calendar",
                title: "No games to show",
                message: "There are no games on \(dayText)."
            )
        case .empty:
            if category == .mlb || category.league == .mlb {
                let month = calendar.component(.month, from: now)
                if month >= 11 || month <= 2 {
                    return KyroSportsDashboard.noGamesState(for: .mlb, now: now, calendar: calendar)
                }
            }
            let subject = category == .all ? "games" : "\(category.displayName) games"
            return KyroSportsDashboardEmptyState(
                symbolName: "calendar.badge.exclamationmark",
                title: "No games on this date",
                message: "There are no \(subject) on \(dayText)."
            )
        case .unavailable:
            return KyroSportsDashboardEmptyState(
                symbolName: "calendar.badge.exclamationmark",
                title: "Schedule unavailable",
                message: "The schedule for \(dayText) has not loaded yet. Try again."
            )
        case .outsideFeed(let league):
            return KyroSportsDashboardEmptyState(
                symbolName: "calendar.badge.exclamationmark",
                title: "Schedule not in this feed",
                message: "\(league.displayName) only publishes its current week here, and \(dayText) is outside that slate."
            )
        case .failed(let error):
            return KyroSportsDashboardEmptyState(
                symbolName: "exclamationmark.triangle",
                title: "Scores unavailable",
                message: error.userMessage
            )
        case .offline:
            return KyroSportsDashboardEmptyState(
                symbolName: "wifi.slash",
                title: "You're offline",
                message: "Connect to the internet to load scores and schedules."
            )
        }
    }
}

// MARK: - Schedule rows (Build 41)

/// One row of the Sports Hub schedule. All Sports interleaves a header for each sport with that
/// sport's games, so the lazy list builds and recycles one card at a time. Build 40 nested each
/// sport's games in one tall stack, which built a whole sport (every card and logo) at once.
enum KyroSportsScheduleRow: Identifiable, Equatable, Sendable {
    case sportHeader(KyroSportLeague, gameCount: Int)
    case game(KyroSportsGame)

    /// Stable across refreshes and sport switches: a game keeps its row identity whichever
    /// filter shows it, and a header is keyed by its sport only.
    var id: String {
        switch self {
        case .sportHeader(let league, _): "sport|\(league.rawValue)"
        case .game(let game): "game|\(game.id.stringValue)"
        }
    }

    var isSportHeader: Bool {
        if case .sportHeader = self { return true }
        return false
    }
}

enum KyroSportsScheduleLayout {
    /// The rows for a schedule already in display order (`KyroSportsDaySchedule.aggregate`).
    /// Grouping keeps that order inside each sport, so nothing is sorted twice.
    static func rows(for schedule: [KyroSportsGame], groupedBySport: Bool) -> [KyroSportsScheduleRow] {
        guard groupedBySport else { return schedule.map(KyroSportsScheduleRow.game) }
        var byLeague: [KyroSportLeague: [KyroSportsGame]] = [:]
        for game in schedule { byLeague[game.league, default: []].append(game) }
        return KyroSportsDaySchedule.sectionOrder.flatMap { league -> [KyroSportsScheduleRow] in
            guard let games = byLeague[league], !games.isEmpty else { return [] }
            return [.sportHeader(league, gameCount: games.count)] + games.map(KyroSportsScheduleRow.game)
        }
    }
}

/// Event-card identity. One accent per sport, the same one its section header uses, and a LIVE
/// badge that follows the event's status only. Stream availability never adds or removes LIVE.
enum KyroSportsEventCardStyle {
    static func accentRGB(for league: KyroSportLeague) -> UInt32 { league.accentRGB }

    static func showsLiveBadge(for status: KyroGameStatus) -> Bool { status.isLive }
}

// MARK: - Matchup artwork (Build 41.1)

/// An sRGB colour read from provider metadata, such as ESPN's team `color` (`"00338d"`).
struct KyroSportsRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }

    /// Six hex digits, with or without `#`. Anything else is not a colour.
    init?(hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, text.allSatisfy(\.isHexDigit), let value = UInt32(text, radix: 16) else { return nil }
        self.init(rgb: value)
    }

    /// WCAG relative luminance, 0 (black) to 1 (white).
    var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

/// What a schedule card draws for its matchup, from provider metadata only. Nothing is guessed:
/// a team without a usable colour gets a neutral side, and a matchup with no team colours at all
/// keeps the Build 41 league card.
struct KyroSportsMatchupArtwork: Equatable, Sendable {
    enum Backdrop: Equatable, Sendable {
        /// Away colour behind the away row (top), home behind the home row (bottom).
        case teams(away: KyroSportsRGB, home: KyroSportsRGB)
        /// The dark-blue card with the sport's accent.
        case league
    }

    let backdrop: Backdrop
    let awayLogoURL: URL?
    let homeLogoURL: URL?

    /// The colour for a side whose team has none worth drawing: a quiet slate, not a team colour.
    static let neutralSide = KyroSportsRGB(rgb: 0x3A3F4B)

    /// Colours this dark or this light either vanish into the card or wash it out.
    /// The floor keeps navy (Patriots `002a5c`, about 0.024) and drops near-black (Bruins `231f20`).
    static let usableLuminance: ClosedRange<Double> = 0.02...0.75

    init(game: KyroSportsGame) {
        let away = Self.cardColor(for: game.away.team)
        let home = Self.cardColor(for: game.home.team)
        if away == nil, home == nil {
            backdrop = .league
        } else {
            backdrop = .teams(away: away ?? Self.neutralSide, home: home ?? Self.neutralSide)
        }
        awayLogoURL = Self.logoURL(for: game.away.team)
        homeLogoURL = Self.logoURL(for: game.home.team)
    }

    /// ESPN's dark-background logo first, then its standard logo. Web URLs only.
    static func logoURL(for team: KyroSportsTeam) -> URL? {
        [team.darkLogoURL, team.logoURL].lazy.compactMap { $0 }.first(where: isWebURL)
    }

    /// The team's primary colour, or its alternate when the primary is near black or near white.
    static func cardColor(for team: KyroSportsTeam) -> KyroSportsRGB? {
        [team.primaryColorHex, team.alternateColorHex].lazy
            .compactMap(KyroSportsRGB.init(hex:))
            .first { usableLuminance.contains($0.luminance) }
    }

    /// The short name a matchup column shows: the school for college teams ("Ohio State"), the
    /// nickname for pro teams ("Browns"), with a rank when there is one.
    static func columnName(for side: KyroGameTeam) -> String {
        let team = side.team
        let base: String
        if team.league == .collegeFootball, let location = team.location, !location.isEmpty {
            base = location
        } else {
            base = team.nickname
        }
        guard let rank = side.rank, rank > 0 else { return base }
        return "#\(rank) \(base)"
    }

    /// The provider's flag image for a tennis player. Never derived from a country code.
    static func flagURL(for team: KyroSportsTeam) -> URL? {
        team.flagURL.flatMap { isWebURL($0) ? $0 : nil }
    }

    private static func isWebURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}
