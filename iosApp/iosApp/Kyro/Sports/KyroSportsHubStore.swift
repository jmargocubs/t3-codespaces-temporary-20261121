import Foundation

// The hub's view model: loads a bounded, provider-normalized window for the
// selected league or a single local day for All Sports, then exposes
// render-ready sections plus explicit page state.
//
// Concurrency: `@MainActor` and `@Observable`, matching `AICapabilities` and
// `RequestsFeatureStore`. Networking and decoding run off the main actor in
// the client; date mapping, sorting and grouping are explicitly detached so
// the actor is reserved for small state assignments.
//
// Per-league state: every league owns an independent `LeagueState`. A response
// is written only into the league that requested it, and only while its load
// token is still current, so a slow NBA response can never appear under the
// NFL chip. Switching to a single league cancels other leagues' in-flight work.
//
// Polling is deliberately conservative. The hub refreshes scores only while
// the page is visible, only for games on the currently displayed schedule, at
// the interval `refreshInterval` returns. Inactive dates and leagues never poll.

@MainActor
@Observable
final class KyroSportsHubStore {
    // MARK: Page state

    enum Phase: Equatable {
        /// Nothing attempted yet.
        case idle
        /// First load in flight and nothing cached to draw.
        case loading
        /// Games are present.
        case loaded
        /// Load failed and there is nothing on screen.
        case failed(KyroSportsDataError)
        /// Device reports no network.
        case offline
    }

    /// Everything the page draws for one league.
    struct LeagueState: Equatable {
        var phase: Phase = .idle
        var games: [KyroSportsGame] = []
        var sections: [KyroSportsGameSection] = []
        var featuredEvent: KyroSportsGame?
        var mode: KyroSportsDashboardMode = .upcoming
        /// True once the mode is final for this league: either the user chose
        /// it or the first load picked a default. Later refreshes never
        /// override it.
        var hasResolvedMode = false
        /// True when the rendered games came from cache after a failed refresh.
        var isStale = false
        var lastRefreshError: KyroSportsDataError?
        var loadedAt: Date?
        var currentWeek: Int?
        var currentSeason: Int?
        /// Local days this league has already fetched, so date swipes skip
        /// warm cache entries.
        var loadedDays: [Date] = []
        /// Days whose fetch failed before any successful load of that day.
        /// Their emptiness is unknown, so they must never read as "no games".
        var failedDays: Set<Date> = []
    }

    /// How long a successful load stays fresh for league switches and tab
    /// re-entry. Explicit refreshes and the live poll bypass it.
    static let freshnessInterval: TimeInterval = 45

    private var states: [KyroSportLeague: LeagueState] = [:] {
        didSet { statesRevision &+= 1 }
    }
    /// Bumps on every write to `states`. Observed, so a view reading the cached schedule below
    /// still updates when any league's games change.
    private var statesRevision = 0

    var phase: Phase {
        if selectedCategory == .all { return aggregatedPhase }
        return state(for: selectedLeague).phase
    }
    var sections: [KyroSportsGameSection] { state(for: selectedLeague).sections }
    var selectedDashboardMode: KyroSportsDashboardMode { state(for: selectedLeague).mode }
    /// True when some rendered games came from cache after a failed refresh.
    /// A league that simply has no games, or one that never loaded, is not
    /// stale; `unavailableLeagues` reports the latter separately.
    var isShowingStaleData: Bool { !staleLeagues.isEmpty }
    /// Set when a refresh failed but earlier data is still on screen, so the
    /// page can show a quiet notice without blanking.
    var lastRefreshError: KyroSportsDataError? {
        selectedCategory.leagues.compactMap { state(for: $0).lastRefreshError }.first
    }

    /// True while a user-initiated refresh runs. The notice and retry buttons
    /// show progress and ignore further taps until it finishes.
    private(set) var isRefreshing = false
    /// True when the latest user-initiated refresh left at least one selected
    /// league stale or unavailable. Cleared when a refresh fully succeeds.
    private(set) var lastRefreshFailed = false

    /// Selected leagues whose on-screen data for the selected day is cached
    /// output from before a failed refresh.
    var staleLeagues: [KyroSportLeague] {
        selectedCategory.leagues.filter { health(of: $0) == .stale }
    }

    /// Selected leagues with nothing trustworthy for the selected day: never
    /// loaded, or this day's fetch failed. In All Sports the other leagues
    /// still render.
    var unavailableLeagues: [KyroSportLeague] {
        selectedCategory.leagues.filter { health(of: $0) == .unavailable }
    }

    /// The single status line above the schedule, or nil when everything on
    /// screen is current. It names the affected leagues so one failing sport
    /// cannot masquerade as a page-wide problem.
    var refreshNotice: KyroSportsRefreshNotice? {
        let stale = staleLeagues
        // With no games on screen the full-page message already explains a
        // failed league; the banner names failures only beside real games.
        let unavailable = selectedCategory == .all && !scheduleGames.isEmpty ? unavailableLeagues : []
        if isRefreshing {
            return KyroSportsRefreshNotice(kind: .refreshing, title: "Refreshing scores…", detail: nil)
        }
        guard !stale.isEmpty || !unavailable.isEmpty else { return nil }
        let error = (stale + unavailable).lazy.compactMap { self.failure(of: $0) }.first
        var parts: [String] = []
        if !stale.isEmpty { parts.append("Couldn't update \(Self.names(stale)); showing earlier scores.") }
        if !unavailable.isEmpty {
            parts.append("\(Self.names(unavailable)) \(unavailable.count == 1 ? "isn't" : "aren't") available right now.")
        }
        let title = (lastRefreshFailed ? "Refresh failed. " : "") + parts.joined(separator: " ")
        let detail = error.map(\.userMessage).flatMap { $0.isEmpty ? nil : $0 }
        return KyroSportsRefreshNotice(kind: stale.isEmpty ? .unavailable : .stale, title: title, detail: detail)
    }

    private enum LeagueHealth { case current, stale, unavailable }

    private func health(of league: KyroSportLeague) -> LeagueHealth {
        let current = state(for: league)
        let day = calendar.startOfDay(for: selectedDay)
        switch current.phase {
        case .failed, .offline: return .unavailable
        case .idle, .loading: return .current
        case .loaded:
            if current.failedDays.contains(day) { return .unavailable }
            return current.isStale || current.lastRefreshError != nil ? .stale : .current
        }
    }

    private func failure(of league: KyroSportLeague) -> KyroSportsDataError? {
        let current = state(for: league)
        switch current.phase {
        case .failed(let error): return error
        case .offline: return .offline
        default: return current.lastRefreshError
        }
    }

    private static func names(_ leagues: [KyroSportLeague]) -> String {
        let names = leagues.map(\.shortName)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and " + names.last!
        }
    }

    var selectedLeague: KyroSportLeague = .nfl {
        didSet {
            guard oldValue != selectedLeague else { return }
            preferences?.set(selectedLeague.rawValue, forKey: Self.selectedLeagueKey)
            let mapped = KyroSportsCategory(league: selectedLeague)
            if selectedCategory != mapped {
                selectedCategory = mapped
            } else if selectedCategory.league != nil {
                cancelWork(except: selectedCategory.leagues)
            }
        }
    }

    var selectedCategory: KyroSportsCategory = .all {
        didSet {
            guard oldValue != selectedCategory else { return }
            preferences?.set(selectedCategory.rawValue, forKey: Self.selectedCategoryKey)
            if let league = selectedCategory.league, selectedLeague != league {
                selectedLeague = league
            }
            if selectedCategory.league != nil {
                cancelWork(except: selectedCategory.leagues)
            }
            lastRefreshFailed = false
            browseGeneration += 1
        }
    }

    var selectedDay: Date

    var availableLeagues: [KyroSportLeague] { KyroSportLeague.allCases }

    var browseDays: [Date] {
        KyroSportsBrowseCalendar.visibleDays(now: now(), calendar: calendar)
    }

    /// Local calendar and clock the date strip must share with schedule filtering.
    var browseCalendar: Calendar { calendar }
    var clockNow: Date { now() }

    var scheduleGames: [KyroSportsGame] { schedule().games }

    /// Events ESPN reports in progress for the selected sport, whatever day is being browsed.
    /// Only the selected sport's leagues keep refreshing, so Live Now follows the same filter.
    var liveGames: [KyroSportsGame] { schedule().live }

    /// The schedule as list rows: a header per sport in All Sports, games only for one sport.
    var scheduleRows: [KyroSportsScheduleRow] { schedule().rows }

    /// Derived schedule for one state revision, category and day. The hub body reads these
    /// several times per update (coverage, notice, rows, Live Now, the connecting banner); Build 40
    /// re-merged, re-filtered and re-sorted every league's games on each read.
    private struct ScheduleSnapshot {
        struct Key: Equatable {
            let revision: Int
            let category: KyroSportsCategory
            let day: Date
        }
        let key: Key
        let games: [KyroSportsGame]
        let live: [KyroSportsGame]
        let rows: [KyroSportsScheduleRow]
    }

    @ObservationIgnored private var scheduleCache: ScheduleSnapshot?
    /// How many times the derived schedule was rebuilt. Ordinary view updates must reuse it.
    @ObservationIgnored private(set) var scheduleComputationCount = 0

    private func schedule() -> ScheduleSnapshot {
        // Reading these observed values registers the dependency even on a cache hit.
        let key = ScheduleSnapshot.Key(revision: statesRevision, category: selectedCategory, day: selectedDay)
        if let cached = scheduleCache, cached.key == key { return cached }
        scheduleComputationCount += 1
        let pools = selectedCategory.leagues.map { leagueGames($0) }
        let games = KyroSportsDaySchedule.aggregate(pools, on: selectedDay, calendar: calendar, now: now())
        let live = KyroSportsDaySchedule.deduplicatedByLeagueAndProviderID(pools.flatMap { $0.filter(\.status.isLive) })
            .sorted(by: KyroSportsDaySchedule.scheduleOrder)
        let snapshot = ScheduleSnapshot(key: key, games: games, live: live,
                                        rows: KyroSportsScheduleLayout.rows(for: games, groupedBySport: selectedCategory == .all))
        scheduleCache = snapshot
        return snapshot
    }

    var scheduleCoverage: KyroSportsDateCoverage {
        switch phase {
        case .offline: return .offline
        case .failed(let error): return .failed(error)
        case .idle, .loading: return .unavailable
        case .loaded:
            if !scheduleGames.isEmpty { return .games }
            let day = calendar.startOfDay(for: selectedDay)
            let leagues = selectedCategory.leagues
            // An empty day is only trustworthy if every selected league
            // actually loaded it. A league whose fetch failed may have games,
            // so say why instead of "No games" (S6 rule).
            let unavailable = leagues.filter { health(of: $0) == .unavailable }
            if !unavailable.isEmpty {
                let errors = unavailable.compactMap { failure(of: $0) }
                if !errors.isEmpty, errors.allSatisfy({ $0 == .offline }) { return .offline }
                return .failed(errors.first ?? .offline)
            }
            let usable = leagues
            if usable.contains(where: { !state(for: $0).loadedDays.contains(day) }) { return .unavailable }
            if selectedCategory.leagues.count == 1, let league = selectedCategory.league,
               league == .nfl || league == .collegeFootball {
                return KyroSportsDaySchedule.footballCoverage(
                    league: league,
                    day: selectedDay,
                    weekGames: leagueGames(league),
                    calendar: calendar
                ) ?? .empty
            }
            return .empty
        }
    }

    var visibleSections: [KyroSportsGameSection] {
        KyroSportsDashboard.visibleSections(
            from: sections,
            mode: selectedDashboardMode
        )
    }

    var dashboardEmptyState: KyroSportsDashboardEmptyState? {
        KyroSportsDashboard.emptyState(
            for: selectedDashboardMode,
            in: sections
        )
    }

    /// Shown instead of the dashboard when the league has no games at all.
    var noGamesState: KyroSportsDashboardEmptyState {
        KyroSportsDaySchedule.emptyState(
            coverage: scheduleCoverage == .games ? .empty : scheduleCoverage,
            category: selectedCategory,
            day: selectedDay,
            now: now(),
            calendar: calendar
        )
    }

    // MARK: Dependencies

    private let providerChain: KyroSportsProviderChain
    private let leagueProvider: (any KyroSportsLeagueProviding)?
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let preferences: UserDefaults?
    @ObservationIgnored private var loadCounter = 0
    @ObservationIgnored private var browseGeneration = 0
    @ObservationIgnored private var inFlight: [KyroSportLeague: InFlightLoad] = [:]

    /// Sports fetching a day they have never loaded. Observed, so the page can say "loading"
    /// instead of "not loaded yet, try again" while the first answer is on its way (Build 61:
    /// the recording showed that message for a second on every cold start). Live polls of a
    /// loaded day never touch it.
    private(set) var firstDayLoads: Set<LeagueDay> = []

    struct LeagueDay: Hashable {
        let league: KyroSportLeague
        let day: Date
    }

    /// True while a selected sport is still fetching the selected day for the first time.
    var isLoadingSelectedDay: Bool {
        let day = calendar.startOfDay(for: selectedDay)
        return selectedCategory.leagues.contains { firstDayLoads.contains(LeagueDay(league: $0, day: day)) }
    }

    private struct InFlightLoad {
        let token: Int
        let day: Date
        let generation: Int
        let task: Task<Void, Never>
    }

    private static let selectedLeagueKey = "kyro.sports.selectedLeague"
    private static let selectedCategoryKey = "kyro.sports.selectedCategory"
    static func modeKey(_ league: KyroSportLeague) -> String {
        "kyro.sports.mode.\(league.rawValue)"
    }

    /// Re-read persisted choices after a settings restore or Undo. Without an explicit choice,
    /// the dashboard uses its current data-driven mode rather than a fixed backup value.
    func reloadDashboardModesFromPreferences() {
        guard let preferences else { return }
        for league in KyroSportLeague.allCases {
            let explicit = preferences.string(forKey: Self.modeKey(league))
                .flatMap(KyroSportsDashboardMode.init(rawValue:))
            update(league) { state in
                state.mode = explicit ?? KyroSportsDashboard.defaultMode(for: state.sections)
                state.hasResolvedMode = explicit != nil || !state.sections.isEmpty
            }
        }
    }

    init(
        espnClient: ESPNAPIClient = ESPNAPIClient(),
        sleeperClient: SleeperAPIClient = SleeperAPIClient(),
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        preferences: UserDefaults? = nil
    ) {
        let espn = ESPNSportsProvider(client: espnClient, calendar: calendar)
        self.providerChain = KyroSportsProviderChain(providers: [
            espn,
            SleeperSportsProvider(client: sleeperClient, calendar: calendar)
        ])
        self.leagueProvider = espn
        self.calendar = calendar
        self.now = now
        self.preferences = preferences
        self.selectedDay = calendar.startOfDay(for: now())
        restorePreferences()
    }

    /// Sleeper-only initializer retained for isolated fallback tests.
    init(
        client: SleeperAPIClient,
        season: String? = nil,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        preferences: UserDefaults? = nil
    ) {
        self.providerChain = KyroSportsProviderChain(providers: [
            SleeperSportsProvider(
                client: client,
                seasonOverride: season.flatMap(Int.init),
                calendar: calendar
            )
        ])
        self.leagueProvider = nil
        self.calendar = calendar
        self.now = now
        self.preferences = preferences
        self.selectedDay = calendar.startOfDay(for: now())
        restorePreferences()
    }

    /// - Parameter leagueProvider: source for NBA, NHL, MLB and FBS windows.
    ///   NFL always goes through `providers`.
    init(
        providers: [any KyroSportsProviding],
        leagueProvider: (any KyroSportsLeagueProviding)? = nil,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        preferences: UserDefaults? = nil
    ) {
        self.providerChain = KyroSportsProviderChain(providers: providers)
        self.leagueProvider = leagueProvider
        self.calendar = calendar
        self.now = now
        self.preferences = preferences
        self.selectedDay = calendar.startOfDay(for: now())
        restorePreferences()
    }

    private func restorePreferences() {
        guard let preferences else { return }
        for league in KyroSportLeague.allCases {
            if let raw = preferences.string(forKey: Self.modeKey(league)),
               let mode = KyroSportsDashboardMode(rawValue: raw) {
                states[league] = LeagueState(mode: mode, hasResolvedMode: true)
            }
        }
        if let raw = preferences.string(forKey: Self.selectedCategoryKey),
           let category = KyroSportsCategory(rawValue: raw) {
            selectedCategory = category
            if let league = category.league {
                selectedLeague = league
            }
        }
    }

    // MARK: Per-league state

    private func state(for league: KyroSportLeague) -> LeagueState {
        states[league] ?? LeagueState()
    }

    private func leagueGames(_ league: KyroSportLeague) -> [KyroSportsGame] {
        let current = state(for: league)
        if !current.games.isEmpty { return current.games }
        return current.sections.flatMap(\.games)
    }

    private var aggregatedPhase: Phase {
        let phases = selectedCategory.leagues.map { state(for: $0).phase }
        if phases.contains(where: { $0 == .loaded }) { return .loaded }
        if phases.contains(.loading) { return .loading }
        if phases.contains(.offline) { return .offline }
        if let failed = phases.compactMap({ phase -> KyroSportsDataError? in
            if case .failed(let error) = phase { return error }
            return nil
        }).first {
            return .failed(failed)
        }
        if phases.contains(.idle) { return inFlight.isEmpty ? .idle : .loading }
        return .loading
    }

    /// Observation reports writes, not semantic changes. Assign only when the
    /// league's state actually changed so unchanged live responses do not
    /// invalidate every visible card.
    private func update(_ league: KyroSportLeague, _ change: (inout LeagueState) -> Void) {
        var copy = state(for: league)
        change(&copy)
        if states[league] != copy { states[league] = copy }
    }

    // MARK: Loading

    func selectDashboardMode(_ mode: KyroSportsDashboardMode) {
        let league = selectedLeague
        guard state(for: league).mode != mode || !state(for: league).hasResolvedMode else { return }
        update(league) {
            $0.mode = mode
            $0.hasResolvedMode = true
        }
        preferences?.set(mode.rawValue, forKey: Self.modeKey(league))
    }

    func selectCategory(_ category: KyroSportsCategory) {
        selectedCategory = category
    }

    func selectDay(_ date: Date) {
        let day = calendar.startOfDay(for: date)
        guard day != selectedDay else { return }
        selectedDay = day
        lastRefreshFailed = false
        browseGeneration += 1
    }

    /// Load the selected category only if it has nothing fresh for the
    /// selected day. League switches, date swipes and tab re-entry use this
    /// so flipping chips does not re-download a warm cache.
    func loadIfNeeded() async {
        let day = calendar.startOfDay(for: selectedDay)
        let leaguesNeedingLoad = selectedCategory.leagues.filter { league in
            let current = state(for: league)
            let dayKnown = current.loadedDays.contains(day)
            if current.phase == .offline {
                return !dayKnown
            }
            if case .failed = current.phase {
                return !dayKnown
            }
            let fresh = current.phase == .loaded
                && !current.isStale
                && current.loadedAt.map { now().timeIntervalSince($0) < Self.freshnessInterval } == true
            return !(fresh && dayKnown)
        }
        guard !leaguesNeedingLoad.isEmpty else { return }
        // A single missing or expired league must not refetch every warm league
        // when returning to All Sports or changing the selected day.
        await load(leagues: leaguesNeedingLoad, force: false)
    }

    /// User-initiated refresh: the stale notice's button, retry buttons and
    /// pull to refresh. Overlapping taps are ignored while one runs, and the
    /// outcome is recorded so the notice can say the refresh failed.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastRefreshFailed = false
        await load(force: true)
        isRefreshing = false
        lastRefreshFailed = !staleLeagues.isEmpty || !unavailableLeagues.isEmpty
    }

    /// Load or refresh the hub for the selected category and day.
    ///
    /// Requests for the same league coalesce onto the running one. The league,
    /// day and browse generation are captured at call time, so a later switch
    /// cannot redirect the result.
    ///
    /// - Parameter force: bypasses the cached section data and refetches, used
    ///   by pull-to-refresh and by the live poll.
    func load(force: Bool = false) async {
        await load(leagues: selectedCategory.leagues, force: force)
    }

    /// Refreshes only sports whose visible schedule is live or close enough to start that the
    /// refresh policy asks for polling. All Sports previously fanned every tick out to every
    /// provider route when one event was live. Besides unnecessary traffic, those state
    /// publications invalidated the dashboard and competed with Guide and player transitions.
    func poll() async {
        let games = scheduleGames
        let current = now()
        let leagues = Self.pollingLeagues(in: selectedCategory.leagues, games: games, now: current)
        guard !leagues.isEmpty else { return }
        await load(leagues: leagues, force: true)
    }

    static func pollingLeagues(
        in candidates: [KyroSportLeague],
        games: [KyroSportsGame],
        now: Date
    ) -> [KyroSportLeague] {
        candidates.filter { league in
            KyroSportsRefreshPolicy.interval(for: games.filter { $0.league == league }, now: now) != nil
        }
    }

    private func load(leagues: [KyroSportLeague], force: Bool) async {
        let day = calendar.startOfDay(for: selectedDay)
        let category = selectedCategory
        let generation = browseGeneration
        await withTaskGroup(of: Void.self) { group in
            for league in leagues {
                group.addTask { @MainActor in
                    await self.loadLeague(
                        league,
                        day: day,
                        category: category,
                        generation: generation,
                        force: force
                    )
                }
            }
        }
    }

    private func loadLeague(
        _ league: KyroSportLeague,
        day: Date,
        category: KyroSportsCategory,
        generation: Int,
        force: Bool
    ) async {
        if let running = inFlight[league] {
            if running.day == day {
                await running.task.value
                return
            }
            running.task.cancel()
            inFlight[league] = nil
        }
        let firstLoad = LeagueDay(league: league, day: day)
        let isFirstLoad = !state(for: league).loadedDays.contains(day)
        if isFirstLoad { firstDayLoads.insert(firstLoad) }
        defer { if isFirstLoad { firstDayLoads.remove(firstLoad) } }
        loadCounter += 1
        let token = loadCounter
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.perform(
                league: league,
                day: day,
                category: category,
                generation: generation,
                force: force,
                token: token
            )
        }
        inFlight[league] = InFlightLoad(token: token, day: day, generation: generation, task: task)
        await task.value
    }

    private func isCurrent(_ league: KyroSportLeague, token: Int, generation: Int, day: Date) -> Bool {
        guard inFlight[league]?.token == token, !Task.isCancelled else { return false }
        return browseGeneration == generation
            && calendar.isDate(selectedDay, inSameDayAs: day)
            && selectedCategory.leagues.contains(league)
    }

    private func perform(
        league: KyroSportLeague,
        day: Date,
        category: KyroSportsCategory,
        generation: Int,
        force: Bool,
        token: Int
    ) async {
        defer {
            if inFlight[league]?.token == token { inFlight[league] = nil }
        }
        if state(for: league).phase != .loaded {
            update(league) { $0.phase = .loading }
        }

        do {
            let groupingDate = now()
            let dayFetch = shouldFetchSingleDay(league: league, day: day, category: category)
            let result: KyroSportsProviderOutput
            let providerInterval = KyroPerformanceDiagnostics.begin("Sports provider fetch", .sportsProviderFetch)
            if league == .nfl {
                result = try await providerChain.fetchNFLWindow(now: groupingDate, force: force)
            } else if let leagueProvider {
                if dayFetch {
                    result = try await leagueProvider.fetchLeagueDay(
                        league: league,
                        date: day,
                        now: groupingDate,
                        force: force
                    )
                } else {
                    result = try await leagueProvider.fetchLeagueWindow(
                        league: league,
                        now: groupingDate,
                        force: force
                    )
                }
            } else {
                throw KyroSportsDataError.malformedResponse
            }
            KyroPerformanceDiagnostics.end(providerInterval)
            guard isCurrent(league, token: token, generation: generation, day: day) else {
                return abandon(league, token: token)
            }

            let incoming = result.games
            let merged: [KyroSportsGame]
            if dayFetch, !state(for: league).games.isEmpty {
                // Incoming first: deduplication keeps the first copy, and the fresh one must win
                // or a live poll never updates a game it already has (All Sports, tennis and other
                // days all use day fetches). Games from other loaded days stay.
                merged = KyroSportsDaySchedule.deduplicatedByLeagueAndProviderID(
                    incoming + state(for: league).games
                )
            } else {
                merged = incoming
            }
            let groupingCalendar = calendar
            let scheduleContext = KyroSportsScheduleContext(
                league: league,
                currentWeek: (league == .nfl || league == .collegeFootball) ? result.week : nil,
                currentSeason: result.season
            )
            let groupingInterval = KyroPerformanceDiagnostics.begin("Sports event grouping", .sportsGrouping)
            let grouped = try await sportsDetachedValue {
                KyroSportsSectioning.sections(
                    from: merged,
                    now: groupingDate,
                    calendar: groupingCalendar,
                    context: scheduleContext
                )
            }
            KyroPerformanceDiagnostics.end(groupingInterval)
            guard isCurrent(league, token: token, generation: generation, day: day) else {
                return abandon(league, token: token)
            }

            let featured = KyroSportsDashboard.featuredEvent(from: grouped, now: groupingDate)
            let initialMode = KyroSportsDashboard.defaultMode(for: grouped)
            var loadedDays = state(for: league).loadedDays
            if !loadedDays.contains(day) { loadedDays.append(day) }
            var failedDays = state(for: league).failedDays
            failedDays.remove(day)
            if !dayFetch {
                let before = Set(loadedDays)
                loadedDays = markedWindowDays(
                    league: league,
                    games: merged,
                    selectedDay: day,
                    now: groupingDate,
                    existing: loadedDays
                )
                failedDays.subtract(Set(loadedDays).subtracting(before))
            }
            update(league) {
                $0.games = merged
                $0.sections = grouped
                $0.featuredEvent = featured
                if !$0.hasResolvedMode {
                    $0.mode = initialMode
                    $0.hasResolvedMode = true
                }
                $0.phase = .loaded
                $0.isStale = result.isStale
                $0.lastRefreshError = result.refreshError
                $0.loadedAt = groupingDate
                $0.currentWeek = scheduleContext.currentWeek
                $0.currentSeason = scheduleContext.currentSeason
                $0.loadedDays = loadedDays
                $0.failedDays = failedDays
            }
        } catch {
            guard isCurrent(league, token: token, generation: generation, day: day) else {
                return abandon(league, token: token)
            }
            let apiError = error as? KyroSportsDataError ?? .offline
            if apiError == .cancelled { return abandon(league, token: token) }
            update(league) {
                // A day that never loaded stays unknown, not empty. Cached
                // games from an earlier successful load of it remain stale.
                if !$0.loadedDays.contains(day) || $0.failedDays.contains(day) {
                    $0.failedDays.insert(day)
                }
                if !$0.loadedDays.contains(day) { $0.loadedDays.append(day) }
                if $0.games.isEmpty && $0.sections.isEmpty && $0.phase != .loaded {
                    $0.phase = apiError == .offline ? .offline : .failed(apiError)
                } else {
                    $0.lastRefreshError = apiError
                    $0.isStale = true
                }
            }
        }
    }

    private func shouldFetchSingleDay(
        league: KyroSportLeague,
        day: Date,
        category: KyroSportsCategory
    ) -> Bool {
        if league == .nfl { return false }
        // Each ESPN tennis day already carries whole tournaments.
        if league == .atp || league == .wta { return true }
        if category == .all { return true }
        return !calendar.isDate(day, inSameDayAs: now())
    }

    /// A window response covers a contiguous local range. Only those days are
    /// marked loaded, so a date outside the window still fetches instead of
    /// presenting an empty slate from a neighboring payload.
    private func markedWindowDays(
        league: KyroSportLeague,
        games: [KyroSportsGame],
        selectedDay: Date,
        now: Date,
        existing: [Date]
    ) -> [Date] {
        var loadedDays = existing
        func mark(_ day: Date) {
            let start = calendar.startOfDay(for: day)
            if !loadedDays.contains(start) { loadedDays.append(start) }
        }
        mark(selectedDay)
        if league == .nfl || league == .collegeFootball {
            let feedDays = Set(games.compactMap { game -> Date? in
                game.startTime.map { calendar.startOfDay(for: $0) }
            })
            if let earliest = feedDays.min(), let latest = feedDays.max() {
                for extra in KyroSportsBrowseCalendar.visibleDays(now: now, calendar: calendar)
                where extra >= earliest && extra <= latest {
                    mark(extra)
                }
            }
            return loadedDays
        }
        let startOfToday = calendar.startOfDay(for: now)
        let windowStart = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let windowEnd = calendar.date(
            byAdding: .day,
            value: KyroSportsSectioning.otherLeagueUpcomingDayCount,
            to: startOfToday
        ) ?? startOfToday
        for extra in KyroSportsBrowseCalendar.visibleDays(now: now, calendar: calendar)
        where extra >= windowStart && extra < windowEnd {
            mark(extra)
        }
        return loadedDays
    }

    /// A superseded or cancelled load leaves no trace except returning a
    /// spinner-only state to idle so the next visit starts a fresh load.
    private func abandon(_ league: KyroSportLeague, token: Int) {
        guard inFlight[league] == nil || inFlight[league]?.token == token else { return }
        if state(for: league).phase == .loading {
            update(league) { $0.phase = .idle }
        }
    }

    private func cancelWork(except keep: [KyroSportLeague]) {
        for (league, entry) in inFlight where !keep.contains(league) {
            entry.task.cancel()
            inFlight[league] = nil
            if state(for: league).phase == .loading {
                update(league) { $0.phase = .idle }
            }
        }
    }

    // MARK: Polling

    /// True when the page should keep a refresh timer running. Evaluated for
    /// the currently displayed schedule only.
    var shouldPoll: Bool { refreshInterval != nil }

    /// Seconds until the next score refresh. Live games refresh fast; a game
    /// within an hour of its start refreshes slowly so the status flips
    /// promptly without hammering the provider.
    var refreshInterval: TimeInterval? {
        KyroSportsRefreshPolicy.interval(
            for: scheduleGames,
            now: now()
        )
    }
}

/// A detached transform must not outlive a cancelled page load. Detached tasks
/// do not inherit cancellation, so bridge it explicitly and check on both
/// sides of the short synchronous transform.
private func sportsDetachedValue<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
) async throws -> Value {
    let task = Task.detached(priority: .userInitiated) {
        try Task.checkCancellation()
        let value = try operation()
        try Task.checkCancellation()
        return value
    }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

/// The status line above the Sports schedule.
struct KyroSportsRefreshNotice: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case refreshing
        /// Cached games are on screen after a failed refresh.
        case stale
        /// Some selected leagues have nothing for this day; others render.
        case unavailable
    }

    let kind: Kind
    let title: String
    let detail: String?
}
