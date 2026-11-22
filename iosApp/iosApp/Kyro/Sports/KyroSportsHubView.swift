import SwiftUI
import Nuke
import NukeUI

// Phase S7: the Sports Hub for All Sports plus NFL, NBA, NHL, MLB, NCAA FBS,
// ATP and WTA.
// ESPN is primary (NFL falls back to Sleeper during an ESPN outage). Date
// browsing and compact cards sit on the S5 provider and static-glass list.

/// A Kyro-only fourth-tab root, shown inside the unified shell's tab bar.
struct KyroRootPageView: View {
    let page: KyroRootPage

    var body: some View {
        switch page {
        case .sports:
            KyroSportsHubView()
        case .favorites:
            KyroTabRootContainer(title: "Favorites") {
                FavoritesView(showsNavigationTitle: false)
            }
        }
    }
}

/// Hosts a page that normally lives in a navigation stack (it titles itself with the navigation
/// bar) as a tab root: it leaves the shell header's runway, adds the page title, and hides the bar.
private struct KyroTabRootContainer<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    @Environment(\.kyroShellHeader) private var shellHeader

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(KyroTheme.textPrimary)
                .padding(.horizontal, SiloTheme.padding)
                .padding(.top, SiloTheme.smallPadding)
                .padding(.bottom, SiloTheme.smallPadding)
                .accessibilityAddTraits(.isHeader)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: shellHeader?.runway ?? 0)
        }
        .siloPageBackground()
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// The Sports tab.
struct KyroSportsHubView: View {
    @Environment(\.kyroShellHeader) private var shellHeader
    @State private var fallbackScrollState = PageChromeScrollState()
    @State private var store = KyroSportsHubStore(preferences: .standard)
    @State private var eventDetailStore = KyroSportsEventDetailStore()
    /// Keeps the pinned event's score current while the feed shows another sport or day.
    @State private var pinnedRefresher = KyroSportsPinnedEventRefresher()
    @State private var refreshTask: Task<Void, Never>?
    @State private var selectionLoadTask: Task<Void, Never>?
    /// The event's stream screen: Find streams, or the fallback when one-tap playback found
    /// nothing that plays.
    @State private var discovery: KyroSportsStreamDiscovery?
    /// A stream picked on that screen, played once the sheet has finished closing so the player
    /// never races the sheet's dismissal.
    @State private var pendingChoice: KyroSportsStreamChoice?
    @State private var eventPreview: KyroSportsEventSelection?
    /// Build 65: Event Details' own lookups (statistics, Players), over the shared providers.
    @State private var previewDetailStore = KyroSportsEventDetailStore()
    @State private var pendingPreviewWatch: KyroSportsGame?
    @State private var watchingTab: KyroSportsWatchingTab = .feed
    /// Build 70: the pinned event's player box-score team, kept here so Stats → Feed → Stats keeps it.
    @State private var boxScoreSelection = KyroSportsPlayerBoxScoreSelection()
    @State private var isShowingOtherStreams = false
    /// The Feed's position while another tab covers it (Build 61). The tracker is not observed,
    /// so scrolling never invalidates the hub.
    @State private var feedPosition = ScrollPosition()
    @State private var feedDriver = KyroSportsFeedScrollDriver()
    @State private var feedCoordinator = KyroSportsFeedScrollCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    private let liveTV = LiveTVService.shared

    private var playback: KyroSportsPlaybackCoordinator { liveTV.sportsPlayback }
    private var liveNow: KyroSportsLiveNowModel { liveTV.sportsLiveNow }
    @State private var liveNowOpenedAt: Double?
    @State private var sportsHubOpenedAt: Double?

    /// Everything Live Now depends on: the live events (with scores), the provider, its catalog
    /// revision and its guide generation. A change re-reads cached evidence; only missing or
    /// stale events are matched again.
    private var liveNowTrigger: KyroSportsLiveNowTrigger {
        let providerID = liveTV.selectedProviderID
        return KyroSportsLiveNowTrigger(games: store.liveGames, providerID: providerID,
                                        isLoadingChannels: liveTV.isLoading,
                                        isPrewarmingChannels: liveTV.isPrewarmingSports,
                                        catalogRevision: liveTV.channelCatalogRevision,
                                        guideGeneration: providerID.map { liveTV.guideGeneration(for: $0) } ?? 0)
    }

    /// The event the one-tap flow is working on, for the Live Now card's connecting state.
    private var activeGameID: KyroGameID? {
        switch playback.phase {
        case .searching(let id): return id
        case .connecting: return playback.context?.game.id
        case .idle, .presented, .exhausted, .unavailable: return nil
        }
    }

    #if os(iOS)
    private var isInlinePlayerVisible: Bool {
        KyroSportsInlinePlayerMode.make(sports: playback.phase, presentation: liveTV.presentation.phase).isVisible
    }
    #endif

    /// Build 67: the event in the player above the Feed, from the tap on (searching, connecting,
    /// playing, or moved to full screen or Picture in Picture). One value for every phase, so the
    /// Feed reflows once when the player opens rather than again when the stream connects.
    private var pinnedGameID: KyroGameID? {
        #if os(iOS)
        guard isInlinePlayerVisible else { return nil }
        return activeGameID ?? selectedWatchingGame?.id
        #else
        return nil
        #endif
    }

    private var scrollState: PageChromeScrollState {
        shellHeader?.scrollState(for: .sports) ?? fallbackScrollState
    }

    private var selectedWatchingGame: KyroSportsGame? {
        guard let selected = playback.context?.game else { return nil }
        // The feed's copy when it lists the event; otherwise the pinned event's own refresh, so a
        // sport or day change in the feed never freezes the playing event's score or status.
        return KyroSportsPinnedEvent.resolve(pinned: selected, scheduleGames: store.liveGames + store.scheduleGames,
                                             refreshed: pinnedRefresher.latest)
    }

    private var pinnedRefreshKey: KyroSportsPinnedEvent.RefreshKey? {
        guard let selected = playback.context?.game else { return nil }
        return KyroSportsPinnedEvent.RefreshKey(
            gameID: selected.id,
            coveredBySchedule: (store.liveGames + store.scheduleGames).contains { $0.id == selected.id })
    }

    /// Tab taps freeze or restore the Feed in the same call as the tap, before the change renders,
    /// so a fling still coasting is stopped at the offset the tap saw (Build 62).
    private var watchingTabSelection: Binding<KyroSportsWatchingTab> {
        Binding(get: { watchingTab }, set: { newTab in
            if newTab != .feed, watchingTab == .feed { feedCoordinator.feedHidden() }
            if newTab == .feed, watchingTab != .feed { feedCoordinator.feedShown() }
            watchingTab = newTab
        })
    }

    /// The Feed is under Game, Stats or News only while an event is pinned above it.
    private var isFeedVisible: Bool {
        watchingTab == .feed || selectedWatchingGame == nil
    }

    var body: some View {
        ZStack {
            sportsFeed
                .opacity(isFeedVisible ? 1 : 0)
                .allowsHitTesting(isFeedVisible)
                .accessibilityHidden(!isFeedVisible)
            if let game = selectedWatchingGame, watchingTab != .feed {
                KyroSportsWatchingContent(tab: watchingTab, game: game, detailStore: eventDetailStore,
                                          channelName: liveTV.presentation.activeChannel?.name,
                                          hasOtherStreams: (playback.context?.alternatives.count ?? 0)
                                            + (playback.context?.overflow.count ?? 0)
                                            + (playback.context?.broadcasters.count ?? 0) > 1,
                                          showOtherStreams: { isShowingOtherStreams = true },
                                          boxScoreSelection: $boxScoreSelection)
            }
        }
        .siloScrollEdgeEffect()
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                Color.clear.frame(height: shellHeader?.runway ?? 0)
                #if os(iOS)
                // Build 46: the tapped event plays here, above the feed, which scrolls beneath it.
                KyroSportsInlinePlayer(service: liveTV, games: store.liveGames + store.scheduleGames,
                                       pinnedGame: selectedWatchingGame,
                                       isShowingOtherStreams: $isShowingOtherStreams)
                if isInlinePlayerVisible, selectedWatchingGame != nil {
                    KyroSportsWatchingTabBar(selection: watchingTabSelection)
                }
                #endif
            }
            // Game, Stats and News scroll beneath this inset. The Feed reports its scroll to the
            // shell header, which then draws its own backdrop; these tabs do not, so the space above
            // the player stayed transparent and their rows showed under KYRO and the status bar
            // (Build 59, NBA Stats). An opaque canvas behind the inset hides what scrolls under it.
            .background(alignment: .top) {
                if KyroSportsWatchingLayout.needsOpaqueInset(tab: watchingTab, hasPinnedEvent: selectedWatchingGame != nil) {
                    Color.siloPageCanvas.ignoresSafeArea(edges: .top)
                }
            }
        }
        .siloPageBackground()
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("kyroSportsHub")
        .refreshable { await store.refresh() }
        .task {
            sportsHubOpenedAt = KyroPerformanceClock.now()
            if !store.scheduleGames.isEmpty {
                recordSportsFirstEventIfReady()
            }
            // Build 104: time from opening the hub to Live Now's first answer (device report).
            liveNowOpenedAt = KyroPerformanceClock.now()
            // Live Now re-reads when the prewarm ends however it ended (`liveNowTrigger` observes
            // it), so a failed catalog download no longer leaves "Checking your channels…".
            liveTV.prewarmSportsMatching()
            updateLiveNow()
            await store.loadIfNeeded()
            startRefreshLoopIfNeeded()
        }
        .onChange(of: liveNowTrigger) { _, _ in updateLiveNow() }
        .onChange(of: liveNow.status, initial: true) { _, status in
            guard status != .checking, let opened = liveNowOpenedAt else { return }
            liveNowOpenedAt = nil
            KyroPerformanceDiagnostics.record(.sportsLiveNowReady, milliseconds: (KyroPerformanceClock.now() - opened) * 1000)
        }
        .onChange(of: store.scheduleGames.isEmpty) { _, isEmpty in
            if !isEmpty { recordSportsFirstEventIfReady() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kyroSettingsDidRestore)) { _ in
            store.reloadDashboardModesFromPreferences()
        }
        .onChange(of: isFeedVisible) { _, visible in feedVisibilityChanged(visible) }
        .task(id: pinnedRefreshKey) {
            guard let key = pinnedRefreshKey, let pinned = playback.context?.game, pinned.id == key.gameID else { return }
            await pinnedRefresher.keepCurrent(pinned, coveredBySchedule: key.coveredBySchedule)
        }
        .onChange(of: store.selectedCategory) { _, _ in
            feedCoordinator.contentReplaced()
            cancelRefreshLoop()
            loadSelection()
        }
        .onChange(of: store.selectedDay) { _, _ in
            feedCoordinator.contentReplaced()
            cancelRefreshLoop()
            loadSelection()
        }
        .onChange(of: store.refreshInterval) { _, _ in
            startRefreshLoopIfNeeded()
        }
        .onAppear { liveTV.presentation.inlineHostAppeared() }
        .onDisappear {
            cancelRefreshLoop()
            selectionLoadTask?.cancel()
            selectionLoadTask = nil
            liveNow.cancel()
            // A player covering the hub is not leaving it; an attempt still connecting is, and
            // an inline stream ends with the hub rather than play on with nothing to show it.
            if playback.isBusy { liveTV.cancelSportsPlayback() }
            liveTV.inlineHostWillDisappear()
            liveTV.presentation.inlineHostDisappeared()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                liveNow.cancel()
                if playback.isBusy { liveTV.cancelSportsPlayback() }
            } else if phase == .active {
                updateLiveNow()
            }
        }
        #if os(iOS)
        .animation(.easeInOut(duration: 0.25), value: isInlinePlayerVisible)
        #endif
        #if os(iOS)
        .modifier(KyroSportsShellPlayerFallback(service: liveTV))
        #endif
        .onChange(of: playback.phase) { _, phase in
            switch phase {
            case .exhausted(let game, let result):
                discovery = KyroSportsStreamDiscovery(game: game, result: result,
                                                      notice: KyroSportsStreamDiscovery.notice(for: game, result: result,
                                                                                               now: store.clockNow))
            case .unavailable(let game, let result, let message):
                discovery = KyroSportsStreamDiscovery(game: game, result: result, notice: message)
            case .idle, .searching, .connecting, .presented:
                break
            }
        }
        .sheet(item: $discovery, onDismiss: discoveryDismissed) { item in
            KyroSportsStreamMatchSheet(discovery: item, service: liveTV,
                                       choose: { match in
                                           guard let result = item.result else { return }
                                           pendingChoice = KyroSportsStreamChoice(match: match, game: item.game, result: result)
                                           discovery = nil
                                       },
                                       dismiss: { discovery = nil })
        }
        .sheet(item: $eventPreview, onDismiss: {
            if let game = pendingPreviewWatch {
                pendingPreviewWatch = nil
                watch(game)
            }
        }) { selection in
            let game = (store.liveGames + store.scheduleGames).first { $0.id == selection.id } ?? selection.game
            KyroSportsEventPreview(game: game, service: liveTV,
                                   canWatch: liveNow.canPlay(game),
                                   watch: { pendingPreviewWatch = game; eventPreview = nil },
                                   detailStore: previewDetailStore)
        }
    }

    private var sportsFeed: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: SiloTheme.padding) {
                // Build 67: the player and its tabs already say where you are.
                if pinnedGameID == nil {
                    KyroSportsHubHeading()
                }
                KyroSportsLiveNowSection(model: liveNow, category: store.selectedCategory,
                                         activeGameID: activeGameID, pinnedGameID: pinnedGameID,
                                         isLoadingScores: store.isLoadingSelectedDay) { watch($0) }
                KyroSportsScheduleHeader(selection: store.selectedCategory) { category in
                    guard category != store.selectedCategory else { return }
                    // Changing a sport preserves the feed's position and avoids an animated
                    // replacement of its rows while the selected stream keeps playing above.
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { store.selectCategory(category) }
                }
                .padding(.top, 6)
                KyroSportsDateStrip(days: store.browseDays, selectedDay: store.selectedDay,
                                    now: store.clockNow, calendar: store.browseCalendar) { day in
                    store.selectDay(day)
                }
                content
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, SiloTheme.padding)
            .padding(.top, SiloTheme.smallPadding)
            .padding(.bottom, SiloTheme.largePadding)
            #if canImport(UIKit)
            .background(KyroSportsFeedScrollResolver(driver: feedDriver))
            #endif
        }
        .scrollPosition($feedPosition)
        .onAppear {
            feedDriver.scrollToFallback = { y in
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { feedPosition.scrollTo(y: y) }
            }
            feedCoordinator.driver = feedDriver
        }
        .onScrollGeometryChange(for: KyroSportsFeedScrollGeometry.self) { geometry in
            KyroSportsFeedScrollGeometry(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                                         contentHeight: geometry.contentSize.height,
                                         viewportHeight: geometry.containerSize.height)
        } action: { [feedScroll = feedDriver.tracker] _, geometry in
            feedScroll.offset = geometry.offset
            feedScroll.contentHeight = geometry.contentHeight
            feedScroll.viewportHeight = geometry.viewportHeight
        }
        .reportsPageChromeScroll(to: scrollState)
    }

    /// Backstop for a change of `isFeedVisible` that did not come from a tab tap. Both calls are
    /// idempotent: the first hide keeps its offset, and a restore clears it.
    private func feedVisibilityChanged(_ visible: Bool) {
        if visible { feedCoordinator.feedShown() } else { feedCoordinator.feedHidden() }
    }

    /// One tap on a playable event: find its best stream, prove it plays, then play it inline.
    /// Every Sports Hub entry point comes through here, so one rule decides: the event is live
    /// and Live Now holds strong stream evidence for it. Anything else is informational.
    private func watch(_ game: KyroSportsGame) {
        guard liveNow.canPlay(game) else { return }
        // A second tap on the event already searching or connecting is not a new attempt.
        guard activeGameID != game.id else { return }
        liveTV.playSportsEvent(game, now: store.clockNow)
    }

    private func updateLiveNow() {
        liveNow.update(games: store.liveGames, now: store.clockNow)
    }

    private func discoveryDismissed() {
        if let choice = pendingChoice {
            pendingChoice = nil
            liveTV.playSportsStream(choice.match, for: choice.game, result: choice.result)
        } else {
            playback.acknowledgeFallback()
        }
    }

    /// Schedule cards always open details. Only Live Now retains direct one-tap playback.
    @ViewBuilder
    private func gameRow(_ game: KyroSportsGame, showsLeague: Bool = true) -> some View {
        let streams = liveNow.streamCount(for: game)
        let card = Group {
            if game.league == .atp || game.league == .wta {
                KyroSportsTennisMatchRow(game: game, showsLeague: showsLeague, playableStreams: streams)
                    .equatable()
            } else {
                KyroSportsGameRow(game: game, usesCompactLayout: true, showsLeague: showsLeague,
                                  playableStreams: streams)
                    .equatable()
            }
        }
        Button { eventPreview = KyroSportsEventSelection(game: game) } label: {
            card.contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows event details")
        .accessibilityIdentifier("kyroSportsDetails-\(game.id.stringValue)")
        .padding(.top, 10 - SiloTheme.padding)
    }

    // MARK: Sections

    @ViewBuilder
    private var content: some View {
        switch store.phase {
            case .idle, .loading:
                KyroSportsLoadingState(title: store.selectedCategory.displayName)
            case .offline:
                KyroSportsMessageState(
                    symbol: "wifi.slash",
                    title: "You're offline",
                    message: "Connect to the internet to load \(store.selectedCategory.displayName) scores and schedules.",
                    retry: { Task { await store.refresh() } },
                    isRetrying: store.isRefreshing
                )
            case .failed(let error):
                KyroSportsMessageState(
                    symbol: "exclamationmark.triangle",
                    title: "Scores unavailable",
                    message: error.userMessage,
                    retry: { Task { await store.refresh() } },
                    isRetrying: store.isRefreshing
                )
            case .loaded:
                if let notice = store.refreshNotice {
                    KyroSportsRefreshBanner(notice: notice, retry: { Task { await store.refresh() } })
                }
                switch store.scheduleCoverage {
                case .games:
                    // One lazy row per header and per card, so scrolling builds and recycles one
                    // card at a time. Each card carries its sport's accent instead of a rule
                    // running down a whole section.
                    ForEach(store.scheduleRows) { row in
                        switch row {
                        case .sportHeader(let league, let count):
                            KyroSportsSportHeader(league: league, gameCount: count)
                                .padding(.top, 8)
                        case .game(let game):
                            gameRow(game, showsLeague: false)
                        }
                    }
                case .unavailable where store.isLoadingSelectedDay:
                    // Another selected sport is still answering: loading, not "try again".
                    KyroSportsLoadingState(title: store.selectedCategory.displayName)
                case .empty, .unavailable, .outsideFeed, .failed, .offline:
                    let empty = store.noGamesState
                    KyroSportsMessageState(
                        symbol: empty.symbolName,
                        title: empty.title,
                        message: empty.message,
                        retry: { Task { await store.refresh() } },
                        isRetrying: store.isRefreshing
                    )
                }
        }
    }

    // MARK: Refresh loop

    /// A rapid sport/date switch must not leave an older selection's unstructured
    /// load running after the new one has been requested or after leaving the hub.
    private func loadSelection() {
        selectionLoadTask?.cancel()
        selectionLoadTask = Task { @MainActor in
            await store.loadIfNeeded()
            guard !Task.isCancelled else { return }
            startRefreshLoopIfNeeded()
        }
    }

    /// Start a single coalesced refresh loop when the page wants one. Each tick
    /// re-reads `refreshInterval`, so a game going final ends the loop and a
    /// game going live tightens it, without another timer.
    private func startRefreshLoopIfNeeded() {
        guard store.shouldPoll, refreshTask == nil else { return }
        refreshTask = Task { @MainActor in
            defer { refreshTask = nil }
            while !Task.isCancelled, let interval = store.refreshInterval {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await store.poll()
            }
        }
    }

    private func cancelRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func recordSportsFirstEventIfReady() {
        guard let opened = sportsHubOpenedAt else { return }
        sportsHubOpenedAt = nil
        KyroPerformanceDiagnostics.record(.sportsFirstVisibleEvent,
                                          milliseconds: (KyroPerformanceClock.now() - opened) * 1000)
    }
}

private struct KyroSportsTennisMatchRow: View, Equatable {
    let game: KyroSportsGame
    let showsLeague: Bool
    /// Strong streams when the match can be played from here; nil keeps the card informational.
    var playableStreams: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if showsLeague { Text(game.league.shortName).font(.caption2.bold()).foregroundStyle(KyroTheme.accentInk) }
                KyroSportsEventStatus(status: game.status, detail: game.statusLine)
                Spacer()
                if let start = game.startTime, game.status.isScheduled, !game.isStartTimeTBD {
                    Text(start, format: .dateTime.hour().minute()).font(.caption.weight(.semibold)).monospacedDigit()
                }
            }
            if let tournament = game.tournament ?? game.note {
                // Tournament identity in the tour's accent; ESPN's scoreboard has no tournament art.
                Text([tournament, game.round].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.weight(.semibold)).foregroundStyle(game.league.accentColor).lineLimit(2)
            }
            // Build 67: each player's games per set sit on that player's row, as on a tennis
            // scoreboard, instead of an "S1 6–4" strip under both names.
            KyroSportsTennisSetRows(game: game)
            if let playableStreams {
                KyroSportsWatchFooter(streamCount: playableStreams)
            }
        }
        .padding(.leading, KyroSportsEventCardChrome.contentLeadingInset).padding(.trailing, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kyroSportsEventCardChrome(league: game.league)
        .accessibilityIdentifier("kyroSportsTennisGame-\(game.id.rawID)")
    }
}

/// Both players of a tennis card, one row each, with their games per set in fixed columns.
private struct KyroSportsTennisSetRows: View {
    let game: KyroSportsGame

    @ScaledMetric(relativeTo: .body) private var setWidth: CGFloat = 22

    var body: some View {
        let winners = KyroSportsTennisSets.winners(of: game.periods, isFinal: game.status.isFinal)
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 6) {
            row(game.away, side: .away, winners: winners)
            row(game.home, side: .home, winners: winners)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func row(_ player: KyroGameTeam, side: KyroSportsTennisSets.Winner,
                     winners: [KyroSportsTennisSets.Winner?]) -> some View {
        let isWinner = game.winner?.team.id == player.team.id
        let isLoser = game.winner != nil && !isWinner
        return GridRow {
            HStack(spacing: 8) {
                KyroSportsPlayerFlag(team: player.team)
                if let rank = player.rank {
                    Text("(\(rank))").font(.caption.weight(.semibold)).foregroundStyle(KyroTheme.textSecondary)
                        .monospacedDigit()
                }
                // Two lines so a doubles pairing ("A / B") is never cut to one name.
                Text(player.team.nickname)
                    .font(.subheadline.weight(isWinner ? .bold : .semibold))
                    .foregroundStyle(isLoser ? KyroTheme.silver : KyroTheme.textPrimary)
                    .lineLimit(2)
                if isWinner {
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(KyroTheme.accentInk)
                }
                Spacer(minLength: 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if game.periods.isEmpty {
                if let score = player.score {
                    Text(String(score)).font(.body.bold()).monospacedDigit()
                        .frame(width: setWidth, alignment: .trailing)
                }
            } else {
                ForEach(Array(game.periods.enumerated()), id: \.element.id) { index, set in
                    let games = side == .away ? set.awayScore : set.homeScore
                    let wonSet = winners[index] == side
                    let lostSet = winners[index] != nil && !wonSet
                    Text(games.map(String.init) ?? "–")
                        .font(.body.weight(wonSet ? .bold : .medium))
                        .monospacedDigit()
                        .foregroundStyle(lostSet ? KyroTheme.textSecondary : KyroTheme.textPrimary)
                        .frame(width: setWidth)
                }
            }
        }
    }

    private var accessibilityLabel: String {
        func name(_ side: KyroGameTeam) -> String {
            var parts = [side.team.fullName]
            if let rank = side.rank { parts.append("ranked \(rank)") }
            if game.winner?.team.id == side.team.id { parts.append("winner") }
            return parts.joined(separator: ", ")
        }
        let sets = game.periods.map { set in
            "\(set.label) \(set.awayScore.map(String.init) ?? "none") to \(set.homeScore.map(String.init) ?? "none")"
        }
        return ([name(game.away), name(game.home)] + sets).joined(separator: ". ")
    }
}

/// A tennis player's country: ESPN's own flag image when the payload carries one, otherwise the
/// code it sent (an alpha-2 code as an emoji flag, ESPN's three-letter code as text). The slot keeps
/// one width whether the image is loading, loaded or missing; nothing is inferred from a name.
private struct KyroSportsPlayerFlag: View {
    let team: KyroSportsTeam

    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .subheadline) private var flagHeight: CGFloat = 14

    var body: some View {
        Group {
            if let url = KyroSportsMatchupArtwork.flagURL(for: team),
               let request = KyroSportsArtworkRequest.flag(url: url, height: flagHeight, scale: displayScale) {
                LazyImage(request: request) { state in
                    if let image = state.image {
                        image.resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    } else {
                        code
                    }
                }
                .onDisappear(.cancel)
                .frame(width: flagHeight * 1.5, height: flagHeight)
            } else {
                code
            }
        }
        .frame(minWidth: 28, alignment: .leading)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var code: some View {
        if let code = team.countryCode, code.count == 2 {
            Text(code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value).map(String.init) }.joined())
                .font(.body)
        } else if let code = team.countryCode, code.count == 3 {
            Text(code.uppercased())
                .font(.caption2.weight(.bold)).monospaced()
                .foregroundStyle(KyroTheme.textSecondary)
        }
    }
}

/// An event's stream screen: what it may be (sheet item).
struct KyroSportsStreamDiscovery: Identifiable {
    let id = UUID()
    let game: KyroSportsGame
    /// Nil while Find streams is still matching.
    var result: KyroSportsStreamMatchResult?
    /// Why the screen opened instead of the player.
    var notice: String?

    static func notice(for game: KyroSportsGame, result: KyroSportsStreamMatchResult, now: Date) -> String? {
        if result.choiceDidNotPlay {
            return "The stream you chose didn't start. Choose another or search your channels."
        }
        let tried = result.attemptStatuses.values.filter { $0 == .failed }.count
        if tried > 0 {
            return tried == 1
                ? "The best stream for this game didn't start. Choose another or search your channels."
                : "Kyro tried \(tried) streams for this game and none started. Choose another or search your channels."
        }
        if !KyroSportsPlaybackPolicy.allowsAutomaticPlayback(game, now: now) {
            return "This game isn't live, so nothing was played."
        }
        if result.matches.isEmpty {
            return nil
        }
        return "No stream is clearly this game. Choose one below."
    }
}

struct KyroSportsStreamChoice {
    let match: KyroSportsStreamMatch
    let game: KyroSportsGame
    let result: KyroSportsStreamMatchResult
}

private struct KyroSportsStreamMatchSheet: View {
    let discovery: KyroSportsStreamDiscovery
    let service: LiveTVService
    let choose: (KyroSportsStreamMatch) -> Void
    let dismiss: () -> Void
    @State private var manualQuery = ""
    @State private var manualResults: [LiveTVChannel] = []
    @State private var currentProgrammes: [String: EPGProgram] = [:]

    private var game: KyroSportsGame { discovery.game }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    KyroSportsStreamEventHeader(game: game, notice: discovery.notice)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                if let result = discovery.result {
                    if result.matches.isEmpty {
                        Section {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("No channel is clearly showing this game.")
                                    .font(.subheadline.weight(.semibold))
                                Text(result.guideWasStale
                                     ? "Your guide is out of date. Refresh Live TV, or search your channels below."
                                     : "Search your channels below if you know where it airs.")
                                    .font(.caption)
                                    .foregroundStyle(KyroTheme.textSecondary)
                            }
                            .listRowBackground(Color.white.opacity(0.05))
                        }
                    }
                    KyroSportsStreamSectionsView(
                        sections: KyroSportsStreamSection.make(
                            matches: result.matches, overflow: result.overflowMatches,
                            broadcasters: result.possibleBroadcasters,
                            status: { result.attemptStatuses[$0] ?? .untested }, currentChannelID: nil,
                            currentProgrammes: currentProgrammes),
                        select: { channelID in
                            if let match = (result.matches + result.overflowMatches + result.possibleBroadcasters)
                                .first(where: { $0.channel.id == channelID }) { choose(match) }
                        }
                    )
                    searchSection(result)
                    #if KYRO_INTERNAL_EPG_STORAGE_TOGGLE
                    KyroSportsMatchReportSlot(game: game)
                    #endif
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking through your channels…").foregroundStyle(KyroTheme.textSecondary)
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                }
            }
            .scrollContentBackground(.hidden)
            .background(KyroTheme.background)
            .navigationTitle("Choose a Stream")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: dismiss) } }
            .task(id: discovery.result?.matches.count ?? -1) {
                guard let result = discovery.result else { return }
                let unlisted = (result.matches + result.overflowMatches + result.possibleBroadcasters)
                    .filter { $0.program == nil }.map(\.channel)
                currentProgrammes = await service.sportsCurrentProgrammes(for: unlisted)
            }
            .task(id: "\(service.selectedProviderID?.uuidString ?? "none")|\(service.channelCatalogRevision)|\(manualQuery)") {
                let folded = KyroSportsStreamMatcher.normalized(manualQuery).trimmingCharacters(in: .whitespaces)
                guard !folded.isEmpty else {
                    manualResults = []
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                guard let providerID = service.selectedProviderID else { manualResults = []; return }
                let found = await service.sportsManualChannels(matching: folded, providerID: providerID)
                guard !Task.isCancelled, service.selectedProviderID == providerID else { return }
                manualResults = found
            }
        }
    }

    /// Manual search stays available whenever automatic matching found nothing that played.
    @ViewBuilder
    private func searchSection(_ result: KyroSportsStreamMatchResult) -> some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(KyroTheme.textSecondary)
                    .accessibilityHidden(true)
                TextField("Search channels", text: $manualQuery)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .listRowBackground(Color.white.opacity(0.05))
            if manualQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                if !result.manualSearchSuggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(result.manualSearchSuggestions, id: \.self) { suggestion in
                                // Build 66: the capsule and a 44-point target are inside the label,
                                // so the whole chip (not only its text) takes the tap.
                                Button { manualQuery = suggestion } label: {
                                    Text(suggestion)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(KyroTheme.accentInk)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background { Capsule().fill(KyroTheme.selectedFill.opacity(0.6)) }
                                        .overlay { Capsule().strokeBorder(KyroTheme.selectedBorder, lineWidth: 1) }
                                        .frame(minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Search for \(suggestion)")
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
            } else if manualResults.isEmpty, service.canSearchSportsManualChannels {
                Text("No channels match “\(manualQuery)”.")
                    .foregroundStyle(KyroTheme.textSecondary)
                    .listRowBackground(Color.white.opacity(0.05))
            }
            ForEach(manualResults) { channel in
                let match = KyroSportsStreamMatch(id: channel.id, channel: channel, program: nil,
                                                  confidence: .low, score: 0,
                                                  reasons: ["Chosen from channel search"], isStale: true,
                                                  source: .manual)
                KyroSportsStreamRow(model: KyroSportsStreamRowModel(match: match, status: result.attemptStatuses[channel.id] ?? .untested,
                                                                    isCurrent: false)) {
                    choose(match)
                }
            }
        } header: {
            Text("Search channels")
        } footer: {
            Text("Search matches channel names only. “Played” means a stream started; Kyro can't check what it shows.")
        }
    }
}

#if os(iOS)
/// Sports Hub presents its player on the shell presenter. The unified iPhone shell hosts that
/// cover over every tab; the earlier navigation (iPad, legacy opt-out) has no shell cover, so the
/// hub hosts it there. Exactly one host exists either way.
private struct KyroSportsShellPlayerFallback: ViewModifier {
    @Bindable var service: LiveTVService

    func body(content: Content) -> some View {
        if KyroUnifiedNavigation.isActive {
            content
        } else {
            content.fullScreenCover(item: Binding(
                get: { service.presentation.coverItem(for: .shell) },
                set: { if $0 == nil { service.presentation.coverDismissed(from: .shell) } }
            )) { cover in
                LiveTVPlayerView(channel: cover.channel, channels: service.channels, session: service.playerSession,
                                 service: service,
                                 naturalRotation: service.presentation.isInlineExpandedByRotation)
            }
        }
    }
}
#endif

/// The searching/connecting status the inline player shows, or nil when nothing is in flight.
struct KyroSportsConnectingStatus: Equatable {
    let title: String
    let detail: String?
    /// "Stream 2 of 3" when more than one stream may be tried.
    let attempt: String?

    init?(phase: KyroSportsPlaybackCoordinator.Phase, games: [KyroSportsGame]) {
        switch phase {
        case .searching(let id):
            let game = games.first { $0.id == id }
            title = "Finding a stream"
            detail = game?.inlineMatchupTitle
            attempt = nil
        case .connecting(let name, let attempt, let total):
            // Build 67: the channel on its own (up to two lines). Build 66 put it in the title
            // ("Connecting to CA Prime Sportsnet Pacific FHD V2"), which cut it off.
            title = "Connecting"
            detail = LiveTVChannel.displayName(name)
            self.attempt = total > 1 ? "Stream \(attempt) of \(total)" : nil
        case .idle, .presented, .exhausted, .unavailable:
            return nil
        }
    }
}

// MARK: - Schedule header and sport selector

/// What Live Now re-reads on change.
struct KyroSportsLiveNowTrigger: Equatable {
    let games: [KyroSportsGame]
    let providerID: UUID?
    let isLoadingChannels: Bool
    /// The Sports Hub prewarm can end without changing the catalog (its download failed or was
    /// not due); Live Now must re-read then.
    let isPrewarmingChannels: Bool
    let catalogRevision: Int
    let guideGeneration: Int
}

/// "Scores & Schedule" with the sport selector beside it (or under it at large text sizes).
private struct KyroSportsScheduleHeader: View {
    let selection: KyroSportsCategory
    let action: (KyroSportsCategory) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                title
                Spacer(minLength: 8)
                KyroSportsSportMenu(selection: selection, action: action)
            }
            VStack(alignment: .leading, spacing: 8) {
                title
                KyroSportsSportMenu(selection: selection, action: action)
            }
        }
    }

    private var title: some View {
        Text("Scores & Schedule")
            .font(.title3.bold())
            .foregroundStyle(KyroTheme.textPrimary)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A compact dropdown in place of the Build 38 chip row. Opening it changes nothing; picking a
/// sport goes through the store's saved selection like the chips did.
private struct KyroSportsSportMenu: View {
    let selection: KyroSportsCategory
    let action: (KyroSportsCategory) -> Void

    var body: some View {
        Menu {
            Picker("Sport", selection: Binding(get: { selection }, set: { action($0) })) {
                ForEach(KyroSportsCategory.filterOrder) { category in
                    Label(category.menuName, systemImage: category.symbolName)
                        .tag(category)
                        .accessibilityIdentifier("kyroSportsCategory-\(category.rawValue)")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selection.symbolName)
                    .font(.caption)
                    .accessibilityHidden(true)
                Text(selection.menuName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(KyroTheme.accentInk)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background { Capsule().fill(KyroTheme.selectedFill) }
            .overlay { Capsule().strokeBorder(KyroTheme.selectedBorder, lineWidth: 1) }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Sport")
        .accessibilityValue(selection.menuName)
        .accessibilityHint("Chooses which sport to show")
        .accessibilityIdentifier("kyroSportsCategoryFilter")
    }
}

/// A live schedule card previews first; its footer reports evidence without implying one-tap play.
private struct KyroSportsWatchFooter: View {
    let streamCount: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tv").font(.system(size: 10, weight: .bold))
            Text("Live streams available")
            Text("·").foregroundStyle(KyroTheme.textSecondary)
            Text(KyroSportsLiveNowCard.streamCountText(streamCount))
                .foregroundStyle(KyroTheme.textSecondary)
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(KyroTheme.accentInk)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Status at the head of a schedule card. An event ESPN reports in progress gets a red LIVE badge
/// beside its clock; everything else keeps the status pill. Stream availability plays no part.
private struct KyroSportsEventStatus: View {
    let status: KyroGameStatus
    let detail: String

    var body: some View {
        if KyroSportsEventCardStyle.showsLiveBadge(for: status) {
            HStack(spacing: 6) {
                KyroSportsLiveBadge()
                // Build 67: the clock is the line's news, one size up from the badge.
                Text(detail)
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(KyroTheme.textPrimary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Live, \(detail)")
        } else {
            KyroSportsStatusPill(status: status, detail: detail)
        }
    }
}

/// Solid red LIVE label: a static capsule, no animation.
struct KyroSportsLiveBadge: View {
    var body: some View {
        Text("LIVE")
            .font(.caption2.weight(.heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background { Capsule().fill(KyroTheme.live) }
            .accessibilityLabel("Live")
    }
}

// MARK: - Date strip

private struct KyroSportsDateStrip: View {
    let days: [Date]
    let selectedDay: Date
    let now: Date
    let calendar: Calendar
    let action: (Date) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !calendar.isDate(selectedDay, inSameDayAs: now) {
                HStack {
                    Spacer()
                    Button {
                        action(calendar.startOfDay(for: now))
                    } label: {
                        Label("Today", systemImage: "arrow.uturn.backward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(KyroTheme.accentInk)
                            .padding(.horizontal, 8)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("kyroSportsReturnToToday")
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(days, id: \.self) { day in
                        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
                        let isToday = calendar.isDate(day, inSameDayAs: now)
                        Button {
                            action(day)
                        } label: {
                            // Build 67: two lines. "Today" takes the weekday's place instead of a
                            // third line that every other day left blank.
                            VStack(spacing: 2) {
                                Group {
                                    if isToday {
                                        Text("Today").font(.caption2.weight(.heavy))
                                    } else {
                                        Text(day, format: .dateTime.weekday(.abbreviated))
                                            .font(.caption2.weight(.semibold))
                                    }
                                }
                                .lineLimit(1)
                                Text(day, format: .dateTime.day())
                                    .font(.headline.weight(.bold))
                                    .monospacedDigit()
                            }
                            .frame(minWidth: 52)
                            .padding(.vertical, 7)
                            .foregroundStyle(isSelected ? KyroTheme.accentInk : KyroTheme.textSecondary)
                            .background {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(isSelected ? KyroTheme.selectedFill : Color.white.opacity(0.06))
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? KyroTheme.selectedBorder
                                            : isToday ? KyroTheme.accent.opacity(0.45) : Color.white.opacity(0.10),
                                        lineWidth: isToday && !isSelected ? 1.5 : 1
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(accessibilityLabel(for: day, isToday: isToday, isSelected: isSelected))
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                        .accessibilityIdentifier("kyroSportsDate-\(Int(day.timeIntervalSince1970))")
                    }
                }
                .padding(.horizontal, 1)
                .scrollTargetLayout()
            }
            .scrollClipDisabled()
            .scrollTargetBehavior(.viewAligned)
            .accessibilityIdentifier("kyroSportsDateStrip")
        }
    }

    private func accessibilityLabel(for day: Date, isToday: Bool, isSelected: Bool) -> String {
        var parts = [day.formatted(.dateTime.weekday(.wide).month(.wide).day())]
        if isToday { parts.append("Today") }
        if isSelected { parts.append("selected") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Sections and rows

/// The Sports tab's own title, in place of the Build 40 featured hero.
private struct KyroSportsHubHeading: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trophy.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(KyroTheme.accentInk)
                .accessibilityHidden(true)
            Text("Sports")
                .font(.title2.bold())
                .foregroundStyle(KyroTheme.textPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("kyroSportsHeading")
    }
}

private struct KyroSportsSportHeader: View {
    let league: KyroSportLeague
    let gameCount: Int

    var body: some View {
        // Build 67: a group label under "Scores & Schedule" rather than a second page title
        // (title2 with a 42-point tile out-ranked the section it sits in).
        HStack(spacing: 10) {
            Image(systemName: league.symbolName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(league.accentColor)
                .frame(width: 30, height: 30)
                .background(league.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            Text(league.displayName)
                .font(.headline)
                .foregroundStyle(KyroTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(gameCount) \(gameCount == 1 ? "game" : "games")")
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(KyroTheme.textSecondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("kyroSportsSportSection-\(league.rawValue)")
    }
}

extension KyroSportLeague {
    /// The sport's accent: its section header icon and its event cards' outline and edge.
    var accentColor: Color {
        let rgb = KyroSportsEventCardStyle.accentRGB(for: self)
        return Color(red: Double((rgb >> 16) & 0xFF) / 255,
                     green: Double((rgb >> 8) & 0xFF) / 255,
                     blue: Double(rgb & 0xFF) / 255)
    }
}

private struct KyroSportsSectionHeader: View {
    let section: KyroSportsGameSection

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: section.bucket.symbolName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(section.bucket == .liveNow ? KyroTheme.live : KyroTheme.accentInk)
            if !section.bucket.isDateGrouped || section.isFirstInBucket {
                Text(section.bucket.title)
                    .font(.headline)
                    .foregroundStyle(KyroTheme.textPrimary)
            }
            if section.bucket == .liveNow {
                KyroLiveDot()
            }
            Spacer(minLength: 0)
            if let day = section.localDay {
                Text(day, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(section.isFirstInBucket ? .subheadline.weight(.semibold) : .headline)
                    .foregroundStyle(section.isFirstInBucket ? KyroTheme.silver : KyroTheme.textPrimary)
            }
        }
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("kyroSportsSection-\(section.id)")
    }
}

private struct KyroSportsGameRow: View, Equatable {
    let game: KyroSportsGame
    let usesCompactLayout: Bool
    var showsLeague: Bool = true
    /// Strong streams when the game can be played from here; nil keeps the card informational.
    var playableStreams: Int?

    /// Build 67 scoreboard card: one row per team (logo, name, record), the line score beside it
    /// and the total in the largest type on the card, or the start time for a game not yet played.
    /// Build 66's side-by-side columns plus a separate line-score table drew the score twice and
    /// took about 190 points; this is about 125 with the same facts. Static shapes and colours only.
    var body: some View {
        let artwork = KyroSportsMatchupArtwork(game: game)
        VStack(alignment: .leading, spacing: 8) {
            if hasHeader { header }
            if let context = contextLine {
                Text(context)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(KyroTheme.textSecondary)
                    .lineLimit(2)
            }
            KyroSportsScoreboardRows(game: game, artwork: artwork)
            if let playableStreams {
                KyroSportsWatchFooter(streamCount: playableStreams)
            }
        }
        .padding(.leading, KyroSportsEventCardChrome.contentLeadingInset)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kyroSportsEventCardChrome(league: game.league, backdrop: artwork.backdrop)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kyroSportsGame-\(game.id.rawID)")
    }

    /// Bowl or championship name and live situation (e.g. MLB outs), joined.
    private var contextLine: String? {
        let parts = [game.note, game.situation].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A game not yet played shows its start time in the scoreboard, so its status pill would
    /// repeat it; postponed and cancelled games still say so.
    private var showsStatus: Bool { !game.status.isScheduled }

    private var broadcast: String? {
        guard let broadcast = game.broadcast, !broadcast.isEmpty else { return nil }
        return broadcast
    }

    private var hasHeader: Bool {
        showsLeague || showsStatus || game.weekLabel != nil || broadcast != nil
    }

    private var header: some View {
        HStack(spacing: 8) {
            if showsLeague {
                Text(game.league.shortName)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(KyroTheme.accentInk)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background {
                        Capsule().fill(KyroTheme.selectedFill)
                    }
                    .overlay {
                        Capsule().strokeBorder(KyroTheme.selectedBorder, lineWidth: 1)
                    }
                    .accessibilityLabel(game.league.displayName)
            }
            if showsStatus {
                KyroSportsEventStatus(status: game.status, detail: compactStatus)
            }
            if let weekLabel = game.weekLabel {
                Text(weekLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(KyroTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let broadcast {
                Text(broadcast)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(KyroTheme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private var compactStatus: String {
        if game.status.isLive, let situation = game.situation, !situation.isEmpty {
            return "\(game.statusLine) · \(situation)"
        }
        return game.statusLine
    }
}

/// A schedule card's two team rows. Scored games line up period columns and the total in a grid;
/// games not yet played put the start time beside both rows.
private struct KyroSportsScoreboardRows: View {
    let game: KyroSportsGame
    let artwork: KyroSportsMatchupArtwork

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var logoSize: CGFloat = 26
    @ScaledMetric(relativeTo: .caption) private var periodWidth: CGFloat = 24
    @ScaledMetric(relativeTo: .title3) private var totalWidth: CGFloat = 40

    var body: some View {
        Group {
            if game.hasScore {
                scored
            } else {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        teamCell(game.away, logo: artwork.awayLogoURL)
                        teamCell(game.home, logo: artwork.homeLogoURL)
                    }
                    Spacer(minLength: 6)
                    startTime
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var periods: [KyroGamePeriod] {
        KyroSportsCardPeriods.shows(game.periods, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
            ? game.periods : []
    }

    private var scored: some View {
        let periods = periods
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 6) {
            if !periods.isEmpty {
                GridRow {
                    Color.clear.frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    ForEach(periods) { period in
                        Text(period.label).lineLimit(1).minimumScaleFactor(0.7).frame(width: periodWidth)
                    }
                    Text("T").frame(width: totalWidth, alignment: .trailing)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(KyroTheme.textSecondary)
            }
            row(game.away, logo: artwork.awayLogoURL, periods: periods)
            row(game.home, logo: artwork.homeLogoURL, periods: periods)
        }
    }

    private func row(_ side: KyroGameTeam, logo: URL?, periods: [KyroGamePeriod]) -> some View {
        GridRow {
            teamCell(side, logo: logo)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(periods) { period in
                Text(periodScore(period, for: side))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(KyroTheme.silver)
                    .frame(width: periodWidth)
            }
            Text(side.score.map(String.init) ?? "–")
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(isLoser(side) ? KyroTheme.silver : KyroTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: totalWidth, alignment: .trailing)
        }
    }

    /// Logo, name and record. The record goes first when the row is short of room, then the name
    /// shrinks a little; it never wraps, so both rows keep one height.
    private func teamCell(_ side: KyroGameTeam, logo: URL?) -> some View {
        let name = Text(KyroSportsMatchupArtwork.columnName(for: side))
            .font(.body.weight(isWinner(side) ? .bold : .semibold))
            .foregroundStyle(isLoser(side) ? KyroTheme.silver : KyroTheme.textPrimary)
        return HStack(spacing: 10) {
            KyroSportsTeamLogo(team: side.team, size: logoSize, url: logo)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    name.lineLimit(1)
                    if let record = side.displayRecord {
                        Text(record)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(KyroTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                name.lineLimit(1)
                name.lineLimit(1).minimumScaleFactor(0.75)
            }
        }
    }

    @ViewBuilder
    private var startTime: some View {
        if game.isStartTimeTBD || game.startTime == nil {
            Text("TBD")
                .font(.title3.weight(.bold))
                .foregroundStyle(KyroTheme.textPrimary)
        } else if let start = game.startTime {
            Text(start, format: .dateTime.hour().minute())
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(KyroTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func isWinner(_ side: KyroGameTeam) -> Bool {
        game.winner?.team.id == side.team.id
    }

    private func isLoser(_ side: KyroGameTeam) -> Bool {
        guard let winner = game.winner else { return false }
        return winner.team.id != side.team.id
    }

    private func periodScore(_ period: KyroGamePeriod, for side: KyroGameTeam) -> String {
        let value = side.team.id == game.home.team.id ? period.homeScore : period.awayScore
        return value.map(String.init) ?? "–"
    }

    private var accessibilityLabel: String {
        func describe(_ side: KyroGameTeam) -> String {
            var parts = [side.team.fullName]
            if let rank = side.rank, rank > 0 { parts.append("ranked number \(rank)") }
            if let record = side.displayRecord { parts.append("record \(record)") }
            if game.hasScore, let score = side.score { parts.append("score \(score)") }
            if isWinner(side) { parts.append("winner") }
            return parts.joined(separator: ", ")
        }
        var parts = [describe(game.away), describe(game.home)]
        if !game.hasScore, let start = game.startTime, !game.isStartTimeTBD {
            parts.append("starts \(start.formatted(date: .omitted, time: .shortened))")
        }
        let periods = periods
        if !periods.isEmpty {
            parts.append("Scoring by period")
            parts += periods.map { period in
                "\(period.label) \(game.away.team.abbreviation) \(period.awayScore.map(String.init) ?? "0"), "
                    + "\(game.home.team.abbreviation) \(period.homeScore.map(String.init) ?? "0")"
            }
        }
        return parts.joined(separator: ". ")
    }
}

struct KyroSportsTeamLogo: View {
    let team: KyroSportsTeam
    var size: CGFloat = 22
    /// Defaults to the team's dark-background logo, then its standard one.
    var url: URL?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let request {
                // The shared artwork pipeline downsamples at decode time and
                // keeps decoded logos in memory. SwiftUI.AsyncImage decoded
                // each CDN source at its original size and offered no shared
                // decoded-image cache for rows returning to the viewport.
                LazyImage(request: request) { state in
                    if let image = state.image {
                        image.resizable().scaledToFit()
                    } else {
                        fallback
                    }
                }
                .priority(.high)
                .onDisappear(.cancel)
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var request: ImageRequest? {
        guard let url = url ?? KyroSportsMatchupArtwork.logoURL(for: team) else { return nil }
        return KyroSportsArtworkRequest.logo(url: url, pointSize: size, scale: displayScale)
    }

    /// Missing, broken or still-loading artwork: the abbreviation in the same frame, so nothing moves.
    private var fallback: some View {
        RoundedRectangle(cornerRadius: min(7, size * 0.3), style: .continuous)
            .fill(Color.white.opacity(0.10))
            .overlay {
                Text(team.abbreviation)
                    .font(.system(size: max(9, size * 0.26), weight: .bold))
                    .foregroundStyle(KyroTheme.textSecondary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(2)
            }
    }
}

/// Requests for Sports Hub artwork. Every logo and flag goes through the shared pipeline: ImageIO
/// decodes it at the drawn pixel size off the main thread, the decoded image stays in the memory
/// cache and the download in the disk cache, so scrolling back never downloads or decodes again.
enum KyroSportsArtworkRequest {
    static func logo(url: URL, pointSize: CGFloat, scale: CGFloat) -> ImageRequest? {
        PosterImageCache.displayRequest(url: url, pointSize: CGSize(width: pointSize, height: pointSize),
                                        scale: scale, priority: .high)
    }

    /// Flags are drawn about 3:2.
    static func flag(url: URL, height: CGFloat, scale: CGFloat) -> ImageRequest? {
        PosterImageCache.displayRequest(url: url, pointSize: CGSize(width: height * 1.5, height: height),
                                        scale: scale, priority: .normal)
    }
}

struct KyroSportsStatusPill: View {
    let status: KyroGameStatus
    let detail: String

    private var tint: Color {
        switch status {
        case .live: KyroTheme.live
        case .final: KyroTheme.textSecondary
        case .canceled, .postponed, .suspended: KyroTheme.highlight
        case .scheduled, .unknown: KyroTheme.accentInk
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if status.isLive {
                Circle()
                    .fill(KyroTheme.live)
                    .frame(width: 6, height: 6)
            }
            Text(detail)
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(status.isLive ? .white : tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule().fill(status.isLive ? KyroTheme.live : tint.opacity(0.14))
        }
        .overlay {
            Capsule().strokeBorder(tint.opacity(status.isLive ? 0 : 0.35), lineWidth: 1)
        }
    }
}

// MARK: - Live dot

struct KyroLiveDot: View {
    // Static on purpose: a repeating animation would redraw every frame while scrolling.
    var body: some View {
        Circle()
            .fill(KyroTheme.live)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

// MARK: - States

private struct KyroSportsLoadingState: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(KyroTheme.accentInk)
            Text("Loading \(title)…")
                .font(.footnote)
                .foregroundStyle(KyroTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityIdentifier("kyroSportsLoading")
    }
}

private struct KyroSportsMessageState: View {
    let symbol: String
    let title: String
    let message: String
    let retry: (() -> Void)?
    var isRetrying = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(KyroTheme.textSecondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .foregroundStyle(KyroTheme.textPrimary)
            Text(message)
                .font(.footnote)
                .foregroundStyle(KyroTheme.textSecondary)
                .multilineTextAlignment(.center)
            if isRetrying {
                ProgressView()
                    .padding(.top, 2)
                    .accessibilityLabel("Refreshing")
            } else if let retry {
                Button(action: retry) {
                    Text("Try Again")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KyroTheme.accentInk)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 16)
        .kyroSportsCardChrome(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("kyroSportsMessage")
    }
}

private struct KyroSportsDashboardEmptyStateView: View {
    let state: KyroSportsDashboardEmptyState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.symbolName)
                .font(.title3)
                .foregroundStyle(KyroTheme.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KyroTheme.textPrimary)
                Text(state.message)
                    .font(.caption)
                    .foregroundStyle(KyroTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kyroSportsCardChrome(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("kyroSportsDashboardEmpty")
    }
}

/// One status line above the schedule: refreshing, stale cached games, or
/// leagues that could not load. Built from `KyroSportsHubStore.refreshNotice`.
private struct KyroSportsRefreshBanner: View {
    let notice: KyroSportsRefreshNotice
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if notice.kind == .refreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: notice.kind == .stale ? "clock.arrow.circlepath" : "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(KyroTheme.highlight)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.caption)
                    .foregroundStyle(KyroTheme.textSecondary)
                if let detail = notice.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(KyroTheme.textSecondary.opacity(0.8))
                }
            }
            Spacer(minLength: 4)
            if notice.kind != .refreshing {
                Button(action: retry) {
                    Text("Refresh")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(KyroTheme.accentInk)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(KyroTheme.highlight.opacity(0.10))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("kyroSportsStaleNotice")
    }
}

// MARK: - Card chrome

extension View {
    /// Static chrome for Sports Hub surfaces that are not schedule events: Live Now, states,
    /// event details.
    func kyroSportsCardChrome<S: InsettableShape>(_ shape: S) -> some View {
        modifier(KyroSportsCardChrome(shape: shape))
    }

    /// A schedule event card: its sport's outline and leading edge over either the teams' own
    /// colours or, without them, the dark-blue league card.
    func kyroSportsEventCardChrome(league: KyroSportLeague,
                                   backdrop: KyroSportsMatchupArtwork.Backdrop = .league) -> some View {
        modifier(KyroSportsEventCardChrome(accent: league.accentColor, backdrop: backdrop))
    }
}

/// The tinted base every Sports card shares. `kyroGlass` would sample and blur the backdrop
/// through a material for every scrolling card; the backdrop here is the near-uniform page canvas,
/// so a fixed base colour with the same tint reads the same.
private struct KyroSportsCardFill<S: InsettableShape>: View {
    let shape: S

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Stand-in for `.ultraThinMaterial` over the iOS page canvas (#111111 with a faint white wash).
    static var staticBase: Color { Color(red: 0.086, green: 0.086, blue: 0.094) }

    var body: some View {
        if reduceTransparency {
            shape.fill(KyroTheme.glassOpaque)
        } else {
            ZStack {
                shape.fill(Self.staticBase)
                shape.fill(LinearGradient(colors: [KyroTheme.glassTint, Color.black.opacity(0.38)],
                                          startPoint: .top, endPoint: .bottom))
            }
        }
    }
}

/// Build 41: no shadows. Build 40 drew two blurred shadows (radius 16 and 20) under every card,
/// which the render server blurs again for every visible card on every scroll frame; on the
/// near-black canvas they were barely visible.
private struct KyroSportsCardChrome<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        content.background {
            KyroSportsCardFill(shape: shape)
                .overlay { shape.strokeBorder(KyroTheme.glassRim, lineWidth: 1) }
        }
    }
}

/// League identity for a schedule card: a restrained outline and a stronger bar inside the
/// leading edge, both in the sport's accent (the colour of its section header). Static shapes and
/// colours only, so the card is drawn once and moved while scrolling.
struct KyroSportsEventCardChrome: ViewModifier {
    /// Leading padding for card content, clearing the accent bar.
    static let contentLeadingInset: CGFloat = 16
    static let outlineOpacity: Double = 0.4
    static let edgeOpacity: Double = 0.9

    /// How strongly a team's colour shows on its half. Low enough that white text stays legible.
    static let teamColorOpacity: Double = 0.32

    let accent: Color
    var backdrop: KyroSportsMatchupArtwork.Backdrop = .league

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return content.background {
            ZStack(alignment: .leading) {
                switch backdrop {
                case .league:
                    KyroSportsCardFill(shape: shape)
                case .teams(let away, let home):
                    // Build 67: the teams are stacked (away above home), so their colours run top
                    // to bottom behind their own rows: one two-stop fill, then the league tint
                    // from the leading edge so the score column stays calm.
                    shape.fill(KyroSportsCardFill<RoundedRectangle>.staticBase)
                    shape.fill(LinearGradient(colors: [Color(away).opacity(Self.teamColorOpacity),
                                                       Color(home).opacity(Self.teamColorOpacity)],
                                              startPoint: .top, endPoint: .bottom))
                    shape.fill(LinearGradient(colors: [Color.clear, Color.black.opacity(0.30)],
                                              startPoint: .leading, endPoint: .trailing))
                }
                shape.strokeBorder(accent.opacity(Self.outlineOpacity), lineWidth: 1)
                Capsule()
                    .fill(accent.opacity(Self.edgeOpacity))
                    .frame(width: 3)
                    .padding(.vertical, 10)
                    .padding(.leading, 5)
            }
            .accessibilityHidden(true)
        }
    }
}

private extension Color {
    init(_ rgb: KyroSportsRGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
