import SwiftUI

/// The sheet keeps an event snapshot so changing filters never replaces it with another event.
struct KyroSportsEventSelection: Identifiable {
    let game: KyroSportsGame
    var id: KyroGameID { game.id }
}

enum KyroSportsEventPreviewPolicy {
    enum Mode: Equatable {
        case upcoming, live, completed, interrupted, unknown
    }

    static func mode(for status: KyroGameStatus) -> Mode {
        switch status {
        case .scheduled: .upcoming
        case .live: .live
        case .final: .completed
        case .postponed, .canceled, .suspended: .interrupted
        case .unknown: .unknown
        }
    }

    /// A sports-network name is never a scheduled broadcast. Require a fresh guide listing
    /// that names both participants and passed the existing event/time evidence checks.
    static func expectedBroadcasts(from result: KyroSportsStreamMatchResult) -> [KyroSportsStreamMatch] {
        result.matches.filter {
            guard case .guide = $0.source else { return false }
            return $0.program != nil && !$0.isStale && $0.isAutoPlayEligible
        }
    }

    static func liveStreams(from result: KyroSportsStreamMatchResult) -> [KyroSportsStreamMatch] {
        result.matches.filter(\.isAutoPlayEligible)
    }
}

private struct KyroSportsPreviewMatchKey: Equatable {
    let gameID: KyroGameID
    let signature: String
    let revision: KyroSportsLiveNowRevision?
    let mode: KyroSportsEventPreviewPolicy.Mode
}

/// Informational event details. Its only background operation is one cancelable, indexed,
/// local metadata match for a scheduled or live event. It never opens a player or a catalog.
struct KyroSportsEventPreview: View {
    let game: KyroSportsGame
    let service: LiveTVService
    let canWatch: Bool
    let watch: () -> Void
    /// Build 65: statistics and Players for a tennis singles match. Separate from the pinned event's
    /// store, so opening details never replaces what the Stats tab shows.
    var detailStore: KyroSportsEventDetailStore? = nil

    private var isTennis: Bool { game.league == .atp || game.league == .wta }

    @Environment(\.dismiss) private var dismiss
    @State private var matches: [KyroSportsStreamMatch] = []
    @State private var isChecking = false
    /// Build 68: Game, Stats and News for any event, playable or not. Kept across status changes,
    /// so a game that starts while the sheet is open stays on the tab the viewer chose.
    @State private var tab: KyroSportsWatchingTab = .game
    /// Build 70: kept here, not in the Stats content, which Game replaces; Stats → Game → Stats
    /// returns to the same team.
    @State private var boxScoreSelection = KyroSportsPlayerBoxScoreSelection()

    private var mode: KyroSportsEventPreviewPolicy.Mode {
        KyroSportsEventPreviewPolicy.mode(for: game.status)
    }

    private var matchKey: KyroSportsPreviewMatchKey {
        let revision: KyroSportsLiveNowRevision?
        if case .ready(let current) = service.liveNowAvailability { revision = current }
        else { revision = nil }
        return KyroSportsPreviewMatchKey(gameID: game.id,
                                         signature: KyroSportsPlaybackEligibility.signature(of: game),
                                         revision: revision, mode: mode)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if detailStore != nil {
                    KyroSportsWatchingTabBar(selection: $tab, tabs: KyroSportsEventDetailsLayout.tabs)
                }
                if let detailStore, tab == .stats || tab == .news {
                    // The pinned event's Stats and News, over Event Details' own store: season
                    // figures before the start, the box score once it begins.
                    KyroSportsWatchingContent(tab: tab, game: game, detailStore: detailStore, channelName: nil,
                                              hasOtherStreams: false, showOtherStreams: {},
                                              boxScoreSelection: $boxScoreSelection)
                } else {
                    overview
                }
            }
            .background(KyroTheme.background)
            // Build 66: pinned to the bottom edge, as the Guide's programme sheet pins Watch. At the
            // end of the scroll view it sat below the fold of the half-height sheet.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if mode == .live && canWatch {
                    Button(action: watch) {
                        Label("Watch Live", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: 640, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(KyroTheme.accent)
                    .accessibilityIdentifier("kyroSportsPreviewWatch")
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .background(KyroTheme.background)
                    .overlay(alignment: .top) { Divider() }
                }
            }
            .navigationTitle("Event Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        // Build 68: one pregame request when an upcoming event opens (ESPN's summary, or theScore
        // for a tennis singles match), whichever tab is showing. Nothing is fetched for events
        // the viewer only scrolls past, and a reopened event inside its freshness is not refetched.
        .task(id: KyroSportsEventDetailStore.LoadKey(game: game, tab: "eventDetails")) {
            guard let detailStore,
                  KyroSportsEventDetailsLayout.loadsPregame(league: game.league, status: game.status,
                                                            isSingles: game.isSingles) else { return }
            if isTennis {
                await detailStore.loadPlayerInfo(for: game)
            } else {
                await detailStore.load(for: game)
            }
        }
        .task(id: matchKey) {
            matches = []
            isChecking = false
            let key = matchKey
            guard (mode == .upcoming || mode == .live), let revision = key.revision else { return }
            isChecking = true
            let result = await service.liveNowMatches(for: game, now: .now)
            guard !Task.isCancelled, matchKey == key,
                  case .ready(let current) = service.liveNowAvailability,
                  current == revision else { return }
            if let result {
                matches = mode == .upcoming
                    ? KyroSportsEventPreviewPolicy.expectedBroadcasts(from: result)
                    : KyroSportsEventPreviewPolicy.liveStreams(from: result)
            }
            isChecking = false
        }
        .accessibilityIdentifier("kyroSportsEventPreview")
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                identity
                matchup
                eventFacts
                if mode == .upcoming || mode == .live { broadcasts }
                if mode == .completed || mode == .live { results }
                if mode == .upcoming { pregame }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }

    private var pregameContext: KyroSportsPregameContext? {
        guard let details = detailStore?.details, details.gameID == game.id else { return nil }
        return details.pregame
    }

    private var tennisInfo: KyroTennisPlayerInfo? {
        guard let info = detailStore?.playerInfo, info.gameID == game.id else { return nil }
        return info
    }

    /// Build 68: what the matchup looks like before the start: records, form, meetings, standings
    /// and injuries (team sports), or rankings, head to head and surface (tennis singles).
    @ViewBuilder
    private var pregame: some View {
        if let detailStore {
            if isTennis {
                if let tennisInfo {
                    KyroTennisPregameSummary(info: tennisInfo)
                } else if detailStore.playerInfoLoadingGameID == game.id {
                    pregameLoading("Loading rankings and head to head…")
                } else if detailStore.playerInfoLookedUpGameID == game.id {
                    pregameNote("Rankings and head to head were not found for this match. theScore covers ATP and WTA tour singles, not doubles, Challenger, WTA 125 or ITF.")
                } else if !game.isSingles {
                    pregameNote("Rankings and head to head are listed for singles matches only.")
                }
            } else if let pregameContext, pregameContext.hasGameContent {
                KyroSportsPregameGameSections(context: pregameContext, game: game)
            } else if detailStore.details?.gameID == game.id {
                pregameNote("ESPN has not published records or standings for this event yet.")
            } else if case .failed(let error) = detailStore.phase {
                pregameNote(error == .eventNotMatched
                            ? "Kyro could not safely match ESPN's records to this event, so none are shown."
                            : "Records and standings could not be loaded. Pull down on Stats or News to try again.")
            } else if KyroSportsEventDetailsLayout.loadsPregame(league: game.league, status: game.status,
                                                                isSingles: game.isSingles) {
                pregameLoading("Loading records and standings…")
            }
        }
    }

    private func pregameLoading(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(text).font(.footnote).foregroundStyle(KyroTheme.textSecondary)
        }
    }

    private func pregameNote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(KyroTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The competition named once: the tournament (tennis, college bowls) or the soccer league.
    private var competitionName: String? {
        KyroSportsEventDetailsLayout.competitionName(tournament: game.tournament,
                                                     soccerCompetition: KyroSoccerCompetitionRegistry
                                                        .competition(for: game.competitionKey)?.name)
    }

    private var identity: some View {
        HStack(spacing: 12) {
            Image(systemName: game.league.symbolName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(game.league.accentColor)
                .frame(width: 48, height: 48)
                .background(game.league.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(game.league.displayName).font(.headline).foregroundStyle(KyroTheme.textPrimary)
                if let competitionName {
                    Text(competitionName).font(.subheadline).foregroundStyle(KyroTheme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            KyroSportsStatusPill(status: game.status, detail: game.statusLine)
        }
    }

    private var matchup: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Build 68: tennis notes repeat the tournament named above; only a distinct note shows.
            if let note = KyroSportsEventDetailsLayout.distinctNote(game.note, competition: competitionName,
                                                                    round: game.round) {
                Text(note).font(.subheadline.weight(.semibold)).foregroundStyle(game.league.accentColor)
            }
            Text("\(game.away.team.fullName) \(game.league == .atp || game.league == .wta ? "vs" : "at") \(game.home.team.fullName)")
                .font(.title.bold())
                .foregroundStyle(KyroTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 12) {
                side(game.away)
                Text("–").font(.title2).foregroundStyle(KyroTheme.textSecondary)
                side(game.home)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .kyroSportsCardChrome(RoundedRectangle(cornerRadius: 20))
    }

    private func side(_ team: KyroGameTeam) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            KyroSportsTeamLogo(team: team.team, size: 44)
            Text(team.team.nickname)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KyroTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let rank = team.rank { Text("No. \(rank)").font(.caption).foregroundStyle(KyroTheme.textSecondary) }
            if mode == .live || mode == .completed, let score = team.score {
                Text(String(score)).font(.title2.bold()).monospacedDigit().foregroundStyle(KyroTheme.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var eventFacts: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let start = game.startTime {
                // Build 68: the viewer's local time, with a countdown inside the next day.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(KyroSportsStartTimeText.line(start: start, isTimeTBD: game.isStartTimeTBD, now: context.date),
                              systemImage: "calendar")
                        if mode == .upcoming,
                           let countdown = KyroSportsStartTimeText.countdown(start: start, isTimeTBD: game.isStartTimeTBD,
                                                                            now: context.date) {
                            Text(countdown)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(game.league.accentColor)
                                .padding(.leading, 28)
                        }
                    }
                }
            } else {
                Label("Start time unavailable", systemImage: "calendar")
            }
            if let venue = (game.venue?.isEmpty == false ? game.venue : nil) ?? pregameContext?.venue ?? tennisInfo?.venue {
                Label(venue, systemImage: "mappin.and.ellipse")
            }
            if let round = game.round, !round.isEmpty, round != competitionName {
                Label(round, systemImage: "trophy")
            }
            if isTennis, let surface = tennisInfo?.surface {
                Label(surface, systemImage: "square.grid.3x3.fill")
            }
            if let situation = game.situation, mode == .live { Label(situation, systemImage: "sportscourt") }
            if mode == .interrupted || mode == .unknown {
                Text("Event status: \(game.status.label). Check the schedule for updates.")
                    .font(.subheadline).foregroundStyle(KyroTheme.textSecondary)
            }
        }
        .font(.subheadline)
        .foregroundStyle(KyroTheme.silver)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var broadcasts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(mode == .upcoming ? "Expected Broadcasts" : "Matched Streams")
                .font(.title3.bold()).foregroundStyle(KyroTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if isChecking {
                ProgressView("Checking your guide…")
            } else if matches.isEmpty {
                Text(mode == .upcoming
                     ? "No event-specific guide listing is available yet."
                     : "No strong event-specific stream is available right now.")
                    .font(.subheadline).foregroundStyle(KyroTheme.textSecondary)
            } else {
                ForEach(matches) { match in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "tv")
                            .foregroundStyle(game.league.accentColor)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(match.channel.name).font(.subheadline.weight(.semibold))
                                .foregroundStyle(KyroTheme.textPrimary).lineLimit(2)
                            if let program = match.program {
                                Text(program.title).font(.caption).foregroundStyle(KyroTheme.textSecondary)
                            }
                            Text(mode == .upcoming ? "Scheduled in guide · tentative" : "Event metadata match · stream not verified")
                                .font(.caption2).foregroundStyle(KyroTheme.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(mode == .completed ? "Result" : "Score & Status")
                .font(.title3.bold()).foregroundStyle(KyroTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("\(game.away.team.nickname) \(game.away.score.map(String.init) ?? "–") · \(game.home.team.nickname) \(game.home.score.map(String.init) ?? "–")")
                .font(.headline).monospacedDigit().foregroundStyle(KyroTheme.textPrimary)
            Text(game.statusLine).font(.subheadline).foregroundStyle(KyroTheme.textSecondary)
            if !game.periods.isEmpty {
                ForEach(game.periods) { period in
                    Text("\(period.label): \(period.awayScore.map(String.init) ?? "–")–\(period.homeScore.map(String.init) ?? "–")")
                        .font(.caption).monospacedDigit().foregroundStyle(KyroTheme.textSecondary)
                }
            }
        }
    }
}
