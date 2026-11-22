import SwiftUI

struct KyroSportsWatchingTabBar: View {
    @Binding var selection: KyroSportsWatchingTab
    /// Build 68: Event Details shows Game, Stats and News without the Feed.
    var tabs: [KyroSportsWatchingTab] = KyroSportsWatchingTab.allCases

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 7) {
                        Text(tab.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selection == tab ? KyroTheme.textPrimary : KyroTheme.textSecondary)
                        // Build 66: `accentInk`, not `accent`. The theme reserves `accent` (2.9:1 on
                        // black) for filled controls; a thin indicator needs the 7.1:1 ink.
                        Capsule()
                            .fill(selection == tab ? KyroTheme.accentInk : .clear)
                            .frame(height: 3)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .bottom)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
                .accessibilityIdentifier("kyroSportsWatchingTab.\(tab.rawValue)")
            }
        }
        .padding(.horizontal, SiloTheme.padding)
        .background(Color.siloPageCanvas)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct KyroSportsWatchingContent: View {
    let tab: KyroSportsWatchingTab
    let game: KyroSportsGame
    let detailStore: KyroSportsEventDetailStore
    let channelName: String?
    let hasOtherStreams: Bool
    let showOtherStreams: () -> Void
    /// Build 70: the team whose player box score Stats shows, owned by the screen with the tab bar.
    @Binding var boxScoreSelection: KyroSportsPlayerBoxScoreSelection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch tab {
                case .feed:
                    EmptyView()
                case .game:
                    gameDetails
                case .stats:
                    statsContent
                case .news:
                    newsContent
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, SiloTheme.padding)
            .padding(.top, 18)
            .padding(.bottom, SiloTheme.largePadding)
        }
        .scrollIndicators(.hidden)
        // Build 61: pulling down here refreshed the Feed's schedule (the hub's action) and left
        // the box score and headlines on screen as they were. This tab refreshes its own event.
        .refreshable {
            guard tab == .game || tab == .stats || tab == .news else { return }
            await detailStore.load(for: game, force: true)
        }
        .accessibilityIdentifier("kyroSportsWatchingContent.\(tab.rawValue)")
        .task(id: detailLoadKey) {
            guard tab == .game || tab == .stats || tab == .news else { return }
            await detailStore.keepCurrent(for: game)
        }
        .task(id: supplementLoadKey) {
            guard tab == .stats else { return }
            await detailStore.loadSupplement(for: game)
        }
        .task(id: NewsLoadKey(gameID: game.id, isNewsTab: tab == .news)) {
            guard tab == .news else { return }
            await detailStore.loadSupplementalNews(for: game)
        }
        .task(id: NewsLoadKey(gameID: game.id, isNewsTab: tab == .stats && isTennis)) {
            guard tab == .stats, isTennis else { return }
            await detailStore.loadPlayerInfo(for: game)
        }
    }

    /// Restarts the supplement request only for a different event or tab, or once ESPN's details
    /// for this event have arrived. The score and clock are not part of it.
    private var supplementLoadKey: SupplementLoadKey {
        SupplementLoadKey(gameID: game.id, isStatsTab: tab == .stats,
                          hasDetails: matchingDetails != nil, isFinal: game.status.isFinal)
    }

    private struct SupplementLoadKey: Hashable {
        let gameID: KyroGameID
        let isStatsTab: Bool
        let hasDetails: Bool
        let isFinal: Bool
    }

    private var matchingSupplement: KyroSportsSupplementalStatistics? {
        guard let supplement = detailStore.supplement, supplement.gameID == game.id else { return nil }
        return supplement
    }

    private var matchingPlayerInfo: KyroTennisPlayerInfo? {
        guard let info = detailStore.playerInfo, info.gameID == game.id else { return nil }
        return info
    }

    /// Supplemental headlines minus anything ESPN's own list already shows.
    private var matchingSupplementalNews: KyroSportsSupplementalNews? {
        guard let news = detailStore.supplementalNews, news.gameID == game.id else { return nil }
        let espnURLs = Set((matchingDetails?.news ?? []).map { KyroSportsNewsDedup.key(for: $0.url) })
        let items = news.items.filter { !espnURLs.contains(KyroSportsNewsDedup.key(for: $0.url)) }
        return items.isEmpty ? nil : KyroSportsSupplementalNews(gameID: news.gameID, items: items)
    }

    private func supplementalNewsSection(_ news: KyroSportsSupplementalNews) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Player and tournament headlines")
                .font(.headline)
                .foregroundStyle(KyroTheme.textPrimary)
            ForEach(news.items) { item in
                Link(destination: item.url) {
                    KyroSportsNewsRow(headline: item.headline,
                                      label: item.relevance == .matchup ? "BOTH PLAYERS"
                                        : (item.relevance == .tournament ? "TOURNAMENT" : "PLAYER"),
                                      accent: game.league.accentColor, source: item.source,
                                      published: item.publishedAt)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the article on \(item.source)")
            }
            sourceNote("Headlines name the players or the tournament but are not match reports. Links open the publisher's article.")
        }
    }

    private struct NewsLoadKey: Hashable {
        let gameID: KyroGameID
        let isNewsTab: Bool
    }

    /// The event, the tab and the kind of status. Build 59 also keyed on the clock and the score,
    /// so every scoreboard tick of a live game cancelled the running detail load and started
    /// another. A live event now refreshes on the store's own interval while the tab is open.
    private var detailLoadKey: KyroSportsEventDetailStore.LoadKey {
        KyroSportsEventDetailStore.LoadKey(game: game, tab: tab.rawValue)
    }

    private var isTennis: Bool { game.league == .atp || game.league == .wta }

    /// Build 65: says which kind of miss it was (not published yet, not tied to this match, or a
    /// source that could not be reached) instead of one fixed sentence.
    private var tennisStatsMessage: KyroTennisStatsMessage? {
        let lookup = detailStore.supplementLookup?.gameID == game.id ? detailStore.supplementLookup?.outcome : nil
        return KyroTennisStatsMessage.make(status: game.status, outcome: lookup,
                                           isLoading: detailStore.supplementLoadingGameID == game.id)
            ?? KyroTennisStatsMessage(title: "Match statistics not available yet",
                                      detail: "Serve and return statistics are added for completed matches only. Set scores are in Game.")
    }

    @ViewBuilder
    private var statsContent: some View {
        if isTennis {
            VStack(alignment: .leading, spacing: 22) {
                if let supplement = matchingSupplement {
                    KyroSportsSupplementalStatisticsView(supplement: supplement, game: game)
                } else if let message = tennisStatsMessage {
                    unavailable(title: message.title, symbol: "chart.bar.xaxis", detail: message.detail)
                }
                if let info = matchingPlayerInfo { KyroTennisPlayerInfoCard(info: info) }
            }
        } else if let details = matchingDetails, let pregame = details.pregame, pregame.hasStatsContent,
                  !details.hasStatistics {
            // Build 68: before the start, season figures, labelled as such. A game that has just
            // started keeps them until ESPN opens its box score, with a note saying so.
            VStack(alignment: .leading, spacing: 16) {
                if !game.status.isScheduled {
                    Label("ESPN has not opened this game's box score yet. The figures below are from before the start.",
                          systemImage: "clock")
                        .font(.footnote)
                        .foregroundStyle(KyroTheme.textSecondary)
                }
                KyroSportsPregameStatsSections(context: pregame, game: game)
            }
        } else if let details = matchingDetails, details.hasStatistics {
            let hasTeamStats = !details.teamStatistics.isEmpty
            let hasPlayerStats = details.playerBoxScores.contains { $0.groups.contains { !$0.athletes.isEmpty } }
            let section: KyroSportsPlayerBoxScoreSelection.Section = hasTeamStats && hasPlayerStats
                ? boxScoreSelection.section(for: game.id)
                : (hasTeamStats ? .team : .players)
            VStack(alignment: .leading, spacing: 22) {
                if hasTeamStats && hasPlayerStats {
                    statsSectionPicker(section)
                }
                if section == .team {
                    teamStatistics(details.teamStatistics)
                } else {
                    playerBoxScores(details.playerBoxScores)
                }
                sourceNote("Box score from ESPN for this event. Live statistics may update after the score does.")
                if let supplement = matchingSupplement {
                    KyroSportsSupplementalStatisticsView(supplement: supplement, game: game)
                }
            }
        } else if let supplement = matchingSupplement {
            VStack(alignment: .leading, spacing: 22) {
                KyroSportsSupplementalStatisticsView(supplement: supplement, game: game)
            }
        } else {
            detailState(
                emptyTitle: game.status.isScheduled ? "No season statistics yet" : "Box score unavailable",
                emptySymbol: "chart.bar.xaxis",
                emptyDetail: game.status.isScheduled
                    ? "ESPN has not published season figures for these teams. Statistics from the game appear here once it starts."
                    : "The provider returned this event without team or player statistics."
            )
        }
    }

    @ViewBuilder
    private var newsContent: some View {
        let hasESPNNews = !(matchingDetails?.news.isEmpty ?? true)
        if hasESPNNews || matchingSupplementalNews != nil {
            VStack(alignment: .leading, spacing: 22) {
                if hasESPNNews { espnNewsContent }
                if let news = matchingSupplementalNews { supplementalNewsSection(news) }
            }
        } else {
            espnNewsContent
        }
    }

    @ViewBuilder
    private var espnNewsContent: some View {
        if let details = matchingDetails, !details.news.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Related to this matchup")
                    .font(.headline)
                    .foregroundStyle(KyroTheme.textPrimary)
                ForEach(details.news) { item in
                    Link(destination: item.url) {
                        KyroSportsNewsRow(headline: item.headline,
                                          label: item.isPreview ? "PREVIEW" : (item.relevance == .event ? "GAME"
                                            : (item.relevance == .matchup ? "MATCHUP"
                                               : (item.relevance == .tournament ? "TOURNAMENT" : "TEAM"))),
                                          accent: game.league.accentColor, source: item.source,
                                          published: item.publishedAt)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the article on \(item.source)")
                }
                sourceNote("Headlines are matched using the event's verified ESPN team identifiers. Links open the publisher's article.")
            }
        } else {
            detailState(
                emptyTitle: "No related headlines found",
                emptySymbol: "newspaper",
                emptyDetail: isTennis
                    ? "Kyro did not find a current ESPN headline tagged to either player."
                    : "Kyro did not find a current headline tagged to either team in this event."
            )
        }
    }

    private var matchingDetails: KyroSportsEventDetails? {
        guard detailStore.details?.gameID == game.id else { return nil }
        return detailStore.details
    }

    @ViewBuilder
    private func detailState(emptyTitle: String, emptySymbol: String, emptyDetail: String) -> some View {
        switch KyroSportsEventDetailStore.displayPhase(phase: detailStore.phase, hasDetailsForEvent: matchingDetails != nil) {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading event details…")
                    .font(.subheadline)
                    .foregroundStyle(KyroTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        case .loaded:
            unavailable(title: emptyTitle, symbol: emptySymbol, detail: emptyDetail)
        case .failed(let error):
            if error == .unsupportedLeague {
                unavailable(
                    title: tab == .news ? "News unavailable from ESPN" : "Box score unavailable from ESPN",
                    symbol: tab == .news ? "newspaper" : "chart.bar.xaxis",
                    detail: "ESPN's public tennis feed provides scores and set results, but no event-detail endpoint for box scores or related articles."
                )
            } else {
                VStack(spacing: 14) {
                    ContentUnavailableView {
                        Label("Event details unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error.userMessage)
                    }
                    Button("Try Again") {
                        Task { await detailStore.load(for: game, force: true) }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, minHeight: 240)
            }
        }
    }

    /// Build 71.1: Team Stats | Player Stats. Changing it swaps content without animation so the
    /// scroll view does not animate a large height change under the viewer's finger.
    private func statsSectionPicker(_ section: KyroSportsPlayerBoxScoreSelection.Section) -> some View {
        Picker("Statistics", selection: Binding(
            get: { section },
            set: { newValue in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { boxScoreSelection.selectSection(newValue, for: game.id) }
            }
        )) {
            ForEach(KyroSportsPlayerBoxScoreSelection.Section.allCases, id: \.self) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("kyroSportsStatsSectionPicker")
    }

    private func teamStatistics(_ teams: [KyroSportsTeamBoxScore]) -> some View {
        let away = teams.first { KyroSportsReconciler.canonicalTeam($0.abbreviation)
            == KyroSportsReconciler.canonicalTeam(game.away.team.abbreviation) }
        let home = teams.first { KyroSportsReconciler.canonicalTeam($0.abbreviation)
            == KyroSportsReconciler.canonicalTeam(game.home.team.abbreviation) }
        let labels = orderedStatisticLabels(away: away, home: home)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Team statistics")
                .font(.headline)
            KyroSportsStatComparisonHeader(away: away?.abbreviation ?? game.away.team.abbreviation,
                                           home: home?.abbreviation ?? game.home.team.abbreviation,
                                           columnWidth: 58)
            ForEach(labels, id: \.self) { label in
                KyroSportsStatComparisonRow(label: label, away: statValue(label, in: away),
                                            home: statValue(label, in: home), columnWidth: 58)
                if label != labels.last { Divider() }
            }
        }
        .padding(14)
        .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Build 70: one team's players at a time, chosen above the tables. Every player of that team
    /// is listed; the other team's are a tap away rather than below them.
    @ViewBuilder
    private func playerBoxScores(_ teams: [KyroSportsPlayerTeamBoxScore]) -> some View {
        let ordered = KyroSportsPlayerBoxScoreSelection.orderedTeams(teams, game: game)
        let selectedID = boxScoreSelection.resolvedTeamID(in: ordered, gameID: game.id)
        if let team = ordered.first(where: { $0.id == selectedID }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Player statistics")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if ordered.count > 1 {
                    let titles = KyroSportsPlayerBoxScoreSelection.segmentTitles(for: ordered, game: game)
                    Picker("Team", selection: Binding(
                        get: { selectedID ?? team.id },
                        set: { boxScoreSelection.select($0, for: game.id) }
                    )) {
                        ForEach(ordered) { option in
                            Text(titles[option.id] ?? option.abbreviation)
                                .accessibilityLabel(KyroSportsPlayerBoxScoreSelection.accessibilityName(for: option, game: game))
                                .tag(option.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("kyroSportsBoxScoreTeamPicker")
                } else {
                    Text(team.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KyroTheme.textSecondary)
                }
                playerBoxScore(team)
            }
        }
    }

    private func playerBoxScore(_ team: KyroSportsPlayerTeamBoxScore) -> some View {
        let groups = team.groups.filter { !$0.athletes.isEmpty }
        let teamName = KyroSportsPlayerBoxScoreSelection.accessibilityName(for: team, game: game)
        return VStack(alignment: .leading, spacing: 12) {
            if groups.isEmpty {
                Text("ESPN has not published player statistics for \(teamName) yet.")
                    .font(.footnote)
                    .foregroundStyle(KyroTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(game.league.accentColor)
                        // The table no longer sits under the team's name, so say whose it is.
                        .accessibilityLabel("\(teamName), \(group.name)")
                        .accessibilityAddTraits(.isHeader)
                    KyroSportsBoxScoreTable(group: group)
                }
            }
        }
    }

    private func orderedStatisticLabels(
        away: KyroSportsTeamBoxScore?,
        home: KyroSportsTeamBoxScore?
    ) -> [String] {
        var labels: [String] = []
        for statistic in (away?.statistics ?? []) + (home?.statistics ?? []) where !labels.contains(statistic.label) {
            labels.append(statistic.label)
        }
        return labels
    }

    private func statValue(_ label: String, in team: KyroSportsTeamBoxScore?) -> String {
        team?.statistics.first { $0.label == label }?.value ?? "–"
    }

    private func sourceNote(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(KyroTheme.textSecondary)
    }

    /// Build 67: a scoreboard hero. Both scores sit beside their teams in the largest type on the
    /// page, with the clock or result between them, so the score reads at a glance; Build 66 put
    /// the status in a corner badge and the scores under each team's name.
    private var gameDetails: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Text(game.league.displayName.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(game.league.accentColor)
                    if let tournament = game.tournament {
                        Text(tournament).font(.caption.weight(.medium)).lineLimit(1)
                            .foregroundStyle(KyroTheme.textSecondary)
                    }
                    Spacer(minLength: 4)
                    if let broadcast = game.broadcast, !broadcast.isEmpty {
                        Text(broadcast).font(.caption.weight(.medium)).lineLimit(1)
                            .foregroundStyle(KyroTheme.textSecondary)
                    }
                }
                HStack(alignment: .center, spacing: 6) {
                    heroTeam(game.away)
                    heroScore(game.away)
                    heroStatus
                        .frame(minWidth: 76)
                    heroScore(game.home)
                    heroTeam(game.home)
                }
                if let round = game.round ?? game.note {
                    Text(round)
                        .font(.caption)
                        .foregroundStyle(KyroTheme.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                if let situation = game.situation {
                    Text(situation)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(KyroTheme.textSecondary)
                }
                if game.league == .soccer, let details = matchingDetails, !details.matchEvents.isEmpty {
                    soccerTimeline(details.matchEvents)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 12))

            let scoredPeriods = game.periods.filter(\.hasScore)
            if !scoredPeriods.isEmpty {
                KyroSportsLineScoreTable(game: game, periods: scoredPeriods)
            }

            VStack(alignment: .leading, spacing: 10) {
                if let venue = game.venue, !venue.isEmpty {
                    Label(venue, systemImage: "mappin.and.ellipse")
                }
                if let start = game.startTime {
                    Label(game.isStartTimeTBD ? start.formatted(date: .abbreviated, time: .omitted)
                          : start.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                }
                if let channelName {
                    Label("Watching on \(channelName)", systemImage: "tv")
                }
            }
            .font(.subheadline)
            .foregroundStyle(KyroTheme.textSecondary)

            if hasOtherStreams {
                Button(action: showOtherStreams) {
                    Label("Other Streams", systemImage: "sportscourt")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("kyroSportsGameOtherStreams")
            }
        }
        .foregroundStyle(KyroTheme.textPrimary)
    }

    private func soccerTimeline(_ events: [KyroSportsMatchEvent]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Match timeline")
                .font(.subheadline.weight(.semibold))
            ForEach(events) { event in
                HStack(alignment: .top, spacing: 10) {
                    Text(event.clock ?? "–")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .frame(width: 38, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.kind).font(.caption.weight(.semibold))
                        if !event.playerNames.isEmpty {
                            Text(event.playerNames.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(KyroTheme.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 12))
    }

    private func isLoser(_ side: KyroGameTeam) -> Bool {
        guard let winner = game.winner else { return false }
        return winner.team.id != side.team.id
    }

    private func heroTeam(_ side: KyroGameTeam) -> some View {
        VStack(spacing: 5) {
            KyroSportsTeamLogo(team: side.team, size: 44)
            Text(isTennis ? side.team.nickname : side.team.abbreviation)
                .font(.subheadline.weight(.bold))
                .lineLimit(isTennis ? 2 : 1)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
            if !isTennis {
                Text(side.team.fullName)
                    .font(.caption2)
                    .foregroundStyle(KyroTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(minHeight: 26, alignment: .top)
            }
            if let record = side.displayRecord {
                Text(record).font(.caption2).monospacedDigit().foregroundStyle(KyroTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func heroScore(_ side: KyroGameTeam) -> some View {
        if game.hasScore {
            Text(side.score.map(String.init) ?? "–")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isLoser(side) ? KyroTheme.silver : KyroTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityLabel("\(side.team.fullName) \(side.score.map(String.init) ?? "no score")")
        }
    }

    /// The live clock, the result, or the start time, between the scores.
    @ViewBuilder
    private var heroStatus: some View {
        VStack(spacing: 5) {
            if game.status.isLive {
                KyroSportsLiveBadge()
                if let detail = game.statusDetail, !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
            } else if game.status.isScheduled, let start = game.startTime, !game.isStartTimeTBD {
                Text(start, format: .dateTime.hour().minute())
                    .font(.headline)
                    .monospacedDigit()
                Text(start, format: .dateTime.month(.abbreviated).day())
                    .font(.caption2)
                    .foregroundStyle(KyroTheme.textSecondary)
            } else {
                Text(game.statusLine.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(KyroTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func unavailable(title: String, symbol: String, detail: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(detail)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }
}

/// Build 66: one player box-score group. The player column stays put and only the statistic
/// columns scroll sideways (the names used to scroll away with them). The two halves line up
/// because every row has the same fixed, text-size-scaled height: no geometry reading or
/// preference passing, so nothing here re-measures while the table scrolls.
struct KyroSportsBoxScoreTable: View {
    let group: KyroSportsPlayerStatGroup

    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 32
    @ScaledMetric(relativeTo: .caption2) private var headerHeight: CGFloat = 18
    @ScaledMetric(relativeTo: .caption) private var nameWidth: CGFloat = 116

    private let rowSpacing: CGFloat = 4

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: rowSpacing) {
                Text("PLAYER")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(KyroTheme.textSecondary)
                    .frame(height: headerHeight, alignment: .leading)
                ForEach(group.athletes) { athlete in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(athlete.shortName ?? athlete.displayName)
                            .font(.caption)
                            .lineLimit(1)
                        if let position = athlete.position {
                            Text(position).font(.caption2).foregroundStyle(KyroTheme.textSecondary).lineLimit(1)
                        }
                    }
                    .frame(height: rowHeight, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            // Leave room to explore statistics even at accessibility text sizes.
            .frame(width: min(nameWidth, 160), alignment: .leading)
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 12)
            .overlay(alignment: .trailing) {
                Rectangle().fill(Color.siloDivider).frame(width: 1)
            }
            ScrollView(.horizontal) {
                // A Grid, so a wide value ("10-15") widens its whole column, header included.
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: rowSpacing) {
                    GridRow {
                        ForEach(Array(group.labels.enumerated()), id: \.offset) { _, label in
                            Text(label)
                                .lineLimit(1)
                                .frame(minWidth: 34, alignment: .trailing)
                                .frame(height: headerHeight)
                        }
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(KyroTheme.textSecondary)
                    ForEach(group.athletes) { athlete in
                        GridRow {
                            ForEach(Array(group.labels.indices), id: \.self) { index in
                                Text(index < athlete.values.count ? athlete.values[index] : "–")
                                    .accessibilityLabel("\(athlete.displayName), \(group.labels[index]), \(index < athlete.values.count ? athlete.values[index] : "Not available")")
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .frame(minWidth: 34, alignment: .trailing)
                                    .frame(height: rowHeight)
                            }
                        }
                        .font(.caption)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
        }
        .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Build 67 shared pieces

/// The Game tab's line score: one row per side, a column per period and the total, scrolling
/// sideways when there are more periods than fit (extra innings). Build 66 drew one "P1 2 – 1"
/// chip per period, which made the two teams' columns hard to follow.
struct KyroSportsLineScoreTable: View {
    let game: KyroSportsGame
    let periods: [KyroGamePeriod]

    @ScaledMetric(relativeTo: .subheadline) private var columnWidth: CGFloat = 30
    @ScaledMetric(relativeTo: .subheadline) private var labelWidth: CGFloat = 64

    private var isTennis: Bool { game.league == .atp || game.league == .wta }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(game.league == .mlb ? "Innings" : (isTennis ? "Set scores" : "Scoring by period"))
                .font(.subheadline.weight(.semibold))
            ScrollView(.horizontal) {
                Grid(alignment: .center, horizontalSpacing: 0, verticalSpacing: 8) {
                    GridRow {
                        Color.clear.frame(width: labelWidth, height: 1)
                        ForEach(periods) { period in
                            Text(period.label.replacingOccurrences(of: "Set ", with: "S"))
                                .lineLimit(1)
                                .frame(minWidth: columnWidth)
                        }
                        if !isTennis {
                            Text("T").frame(minWidth: columnWidth + 6, alignment: .trailing)
                        }
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(KyroTheme.textSecondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    row(game.away, isAway: true)
                    row(game.home, isAway: false)
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func row(_ side: KyroGameTeam, isAway: Bool) -> some View {
        let winners = KyroSportsTennisSets.winners(of: periods, isFinal: game.status.isFinal)
        return GridRow {
            Text(name(side))
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: labelWidth, alignment: .leading)
            ForEach(Array(periods.enumerated()), id: \.element.id) { index, period in
                let value = isAway ? period.awayScore : period.homeScore
                let wonSet = isTennis && winners[index] == (isAway ? .away : .home)
                Text(value.map(String.init) ?? "–")
                    .font(.subheadline.weight(wonSet ? .bold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(isTennis && !wonSet && winners[index] != nil ? KyroTheme.textSecondary : KyroTheme.textPrimary)
                    .frame(minWidth: columnWidth)
            }
            if !isTennis {
                Text(side.score.map(String.init) ?? "–")
                    .font(.headline)
                    .monospacedDigit()
                    .frame(minWidth: columnWidth + 6, alignment: .trailing)
            }
        }
    }

    private func name(_ side: KyroGameTeam) -> String {
        guard isTennis else { return side.team.abbreviation }
        return side.team.nickname.split(separator: " ").last.map(String.init) ?? side.team.nickname
    }

    private var accessibilityLabel: String {
        let rows = periods.map { period in
            "\(period.label) \(game.away.team.abbreviation) \(period.awayScore.map(String.init) ?? "none"), "
                + "\(game.home.team.abbreviation) \(period.homeScore.map(String.init) ?? "none")"
        }
        return (["Scoring by period"] + rows).joined(separator: ". ")
    }
}

/// Team-comparison column heads, keyed to the colours of the comparison bars beneath each row.
struct KyroSportsStatComparisonHeader: View {
    let away: String
    let home: String
    let columnWidth: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Text(away).lineLimit(1).foregroundStyle(KyroSportsStatShareBar.awayColor)
                .frame(width: columnWidth, alignment: .leading)
            Text("STAT").foregroundStyle(KyroTheme.textSecondary).frame(maxWidth: .infinity)
            Text(home).lineLimit(1).foregroundStyle(KyroSportsStatShareBar.homeColor)
                .frame(width: columnWidth, alignment: .trailing)
        }
        .font(.caption2.weight(.bold))
    }
}

/// One statistic for both sides, with a thin bar showing each side's share when both values are
/// numbers. The bar shows proportion only, never which side is better.
struct KyroSportsStatComparisonRow: View {
    let label: String
    let away: String
    let home: String
    let columnWidth: CGFloat
    /// Build 68: off for records (`6-5`), which are not quantities to share out.
    var showsBar = true

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(away).frame(width: columnWidth, alignment: .leading)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(KyroTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Text(home).frame(width: columnWidth, alignment: .trailing)
            }
            .font(.subheadline.monospacedDigit().weight(.semibold))
            if showsBar, let shares = KyroSportsStatComparison.shares(away: away, home: home) {
                KyroSportsStatShareBar(awayShare: shares.away)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A static two-part bar: the away share from the leading edge, the home share from the trailing.
/// One Canvas draw, no layout of its own.
struct KyroSportsStatShareBar: View {
    static let awayColor = KyroTheme.accentInk
    static let homeColor = KyroTheme.silver

    let awayShare: Double

    var body: some View {
        Canvas { context, size in
            let gap: CGFloat = 3
            let usable = max(0, size.width - gap)
            let awayWidth = usable * min(max(awayShare, 0), 1)
            let radius = size.height / 2
            context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: awayWidth, height: size.height),
                              cornerRadius: radius),
                         with: .color(Self.awayColor.opacity(0.8)))
            context.fill(Path(roundedRect: CGRect(x: awayWidth + gap, y: 0, width: usable - awayWidth,
                                                  height: size.height), cornerRadius: radius),
                         with: .color(Self.homeColor.opacity(0.45)))
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// A headline row: the headline first, then what ties it to this event, the publisher and its age.
/// Build 66 led with the label row, so the headline started a line down.
struct KyroSportsNewsRow: View {
    let headline: String
    let label: String
    let accent: Color
    let source: String
    let published: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text(headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KyroTheme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                HStack(spacing: 6) {
                    Text(label)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(accent.opacity(0.14), in: Capsule())
                    Text(source)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(KyroTheme.textSecondary)
                    if let published {
                        Text("·").foregroundStyle(KyroTheme.textSecondary)
                        Text(published.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                            .font(.caption)
                            .foregroundStyle(KyroTheme.textSecondary)
                    }
                }
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(KyroTheme.textSecondary)
                .accessibilityHidden(true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
