import SwiftUI

// Build 68: pregame sections for an upcoming event's Game and Stats tabs in Event Details. Every
// value is drawn as ESPN (or theScore, for tennis) gave it; nothing is computed into a new
// statistic, and every card says the figures come from before this game.

private extension View {
    func kyroPregameCard() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct KyroSportsPregameCardTitle: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .foregroundStyle(KyroTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(KyroTheme.textSecondary)
            }
        }
    }
}

/// W, L or D in a small tinted square. Colour is never the only signal: the letter is the result.
private struct KyroSportsOutcomeBadge: View {
    let outcome: KyroSportsPregameContext.RecentGame.Outcome?

    var body: some View {
        Text(outcome?.rawValue ?? "–")
            .font(.caption2.weight(.heavy))
            .foregroundStyle(color)
            .frame(width: 20, height: 20)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch outcome {
        case .win: .green
        case .loss: .red
        case .draw, nil: KyroTheme.textSecondary
        }
    }

    private var label: String {
        switch outcome {
        case .win: "Won"
        case .loss: "Lost"
        case .draw: "Drew"
        case nil: "Result unknown"
        }
    }
}

// MARK: - Game tab

struct KyroSportsPregameGameSections: View {
    let context: KyroSportsPregameContext
    let game: KyroSportsGame

    private var awayName: String { context.away?.abbreviation ?? game.away.team.abbreviation }
    private var homeName: String { context.home?.abbreviation ?? game.home.team.abbreviation }

    private var recordLabels: [String] {
        var labels: [String] = []
        for record in (context.away?.records ?? []) + (context.home?.records ?? []) where !labels.contains(record.label) {
            labels.append(record.label)
        }
        return labels
    }

    private var hasInjuries: Bool {
        !(context.away?.injuries.isEmpty ?? true) || !(context.home?.injuries.isEmpty ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !recordLabels.isEmpty { records }
            if !(context.away?.recent.isEmpty ?? true) || !(context.home?.recent.isEmpty ?? true) { recentForm }
            ForEach(context.series) { series($0) }
            ForEach(context.standings) { standings($0) }
            if hasInjuries { injuries }
            KyroSportsSourceNote(text: "Records, standings, recent results and injuries from ESPN, as of before this game.")
        }
        .accessibilityIdentifier("kyroSportsPregameGame")
    }

    private var records: some View {
        VStack(alignment: .leading, spacing: 10) {
            KyroSportsPregameCardTitle(title: "Records", detail: "This season")
            KyroSportsStatComparisonHeader(away: awayName, home: homeName, columnWidth: 76)
            ForEach(recordLabels, id: \.self) { label in
                KyroSportsStatComparisonRow(label: label,
                                            away: context.away?.records.first { $0.label == label }?.value ?? "–",
                                            home: context.home?.records.first { $0.label == label }?.value ?? "–",
                                            columnWidth: 76, showsBar: false)
                if label != recordLabels.last { Divider() }
            }
        }
        .kyroPregameCard()
    }

    private var recentForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            KyroSportsPregameCardTitle(title: "Last 5 games", detail: "Newest first")
            ForEach([context.away, context.home].compactMap { $0 }, id: \.providerTeamID) { team in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(team.abbreviation)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(KyroTheme.textPrimary)
                        Spacer(minLength: 4)
                        HStack(spacing: 3) {
                            ForEach(team.recent) { KyroSportsOutcomeBadge(outcome: $0.outcome) }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    ForEach(team.recent) { recentRow($0) }
                }
                if team.providerTeamID != context.home?.providerTeamID, context.home != nil { Divider() }
            }
        }
        .kyroPregameCard()
    }

    private func recentRow(_ result: KyroSportsPregameContext.RecentGame) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(result.date.map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? "–")
                .foregroundStyle(KyroTheme.textSecondary)
                .frame(minWidth: 46, alignment: .leading)
            Text("\(result.isHome ? "vs" : "@") \(result.opponent)")
                .foregroundStyle(KyroTheme.textPrimary)
                .lineLimit(1)
            if let competition = result.competition {
                Text(competition)
                    .font(.caption2)
                    .foregroundStyle(KyroTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(result.outcome?.rawValue ?? "")
                .fontWeight(.bold)
                .foregroundStyle(result.outcome == .win ? Color.green : (result.outcome == .loss ? Color.red : KyroTheme.textSecondary))
            Text(result.scoreLine ?? "–")
                .monospacedDigit()
                .foregroundStyle(KyroTheme.textPrimary)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private func series(_ series: KyroSportsPregameContext.Series) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            KyroSportsPregameCardTitle(title: series.title == "Regular Season Series" ? "Season series" : series.title,
                                       detail: series.summary)
            ForEach(series.meetings) { meeting in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(meeting.date.map { $0.formatted(.dateTime.month(.abbreviated).day().year()) } ?? "–")
                        .foregroundStyle(KyroTheme.textSecondary)
                        .frame(minWidth: 82, alignment: .leading)
                    Spacer(minLength: 4)
                    side(meeting.away, score: meeting.awayScore, winner: meeting.winner)
                    Text("–").foregroundStyle(KyroTheme.textSecondary)
                    side(meeting.home, score: meeting.homeScore, winner: meeting.winner)
                }
                .font(.caption)
                .monospacedDigit()
                .accessibilityElement(children: .combine)
            }
            if series.meetings.isEmpty {
                Text("No completed meetings listed.")
                    .font(.caption)
                    .foregroundStyle(KyroTheme.textSecondary)
            }
            if series.upcoming > 0 {
                Text(series.upcoming == 1 ? "1 more meeting scheduled." : "\(series.upcoming) more meetings scheduled.")
                    .font(.caption2)
                    .foregroundStyle(KyroTheme.textSecondary)
            }
        }
        .kyroPregameCard()
    }

    private func side(_ name: String, score: String?, winner: String?) -> some View {
        Text("\(name) \(score ?? "–")")
            .fontWeight(winner == name ? .bold : .regular)
            .foregroundStyle(winner == nil || winner == name ? KyroTheme.textPrimary : KyroTheme.textSecondary)
    }

    private func standings(_ group: KyroSportsPregameContext.StandingsGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            KyroSportsPregameCardTitle(title: "Standings · \(group.title)",
                                       detail: group.isAbridged ? "Showing \(group.rows.count) of \(group.totalTeams) teams, in ESPN's order" : nil)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                GridRow {
                    Text("#")
                    Text("TEAM").frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Array(group.columns.enumerated()), id: \.offset) { _, column in
                        Text(column).gridColumnAlignment(.trailing)
                    }
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(KyroTheme.textSecondary)
                // A GridRow applies its modifiers to each cell, so the selected teams are marked in
                // their own cells (accent position, bold name) rather than with a row background.
                ForEach(group.rows) { row in
                    GridRow {
                        Text("\(row.position)")
                            .fontWeight(row.isSelected ? .bold : .regular)
                            .foregroundStyle(row.isSelected ? game.league.accentColor : KyroTheme.textSecondary)
                        Text(row.team)
                            .lineLimit(1)
                            .fontWeight(row.isSelected ? .bold : .regular)
                            .foregroundStyle(row.isSelected ? KyroTheme.textPrimary : KyroTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel(row.isSelected ? "\(row.team), in this game" : row.team)
                        ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                            Text(value)
                                .monospacedDigit()
                                .fontWeight(row.isSelected ? .semibold : .regular)
                                .foregroundStyle(row.isSelected ? KyroTheme.textPrimary : KyroTheme.textSecondary)
                        }
                    }
                    .font(.caption)
                }
            }
        }
        .kyroPregameCard()
    }

    private var injuries: some View {
        VStack(alignment: .leading, spacing: 12) {
            KyroSportsPregameCardTitle(title: "Injury report", detail: "As listed by ESPN; status can change before the start")
            ForEach([context.away, context.home].compactMap { $0 }, id: \.providerTeamID) { team in
                VStack(alignment: .leading, spacing: 6) {
                    Text(team.abbreviation)
                        .font(.subheadline.weight(.bold))
                    if team.injuries.isEmpty {
                        Text("None listed").font(.caption).foregroundStyle(KyroTheme.textSecondary)
                    }
                    ForEach(team.injuries.prefix(KyroSportsPregameRules.maxInjuriesPerTeam)) { injury in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text([injury.name, injury.position].compactMap { $0 }.joined(separator: " · "))
                                .foregroundStyle(KyroTheme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text([injury.status, injury.detail].compactMap { $0 }.joined(separator: " · "))
                                .foregroundStyle(KyroTheme.textSecondary)
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .accessibilityElement(children: .combine)
                    }
                    if team.injuries.count > KyroSportsPregameRules.maxInjuriesPerTeam {
                        Text("+\(team.injuries.count - KyroSportsPregameRules.maxInjuriesPerTeam) more")
                            .font(.caption2)
                            .foregroundStyle(KyroTheme.textSecondary)
                    }
                }
            }
        }
        .kyroPregameCard()
    }
}

// MARK: - Stats tab

struct KyroSportsPregameStatsSections: View {
    let context: KyroSportsPregameContext
    let game: KyroSportsGame

    private var awayName: String { context.away?.abbreviation ?? game.away.team.abbreviation }
    private var homeName: String { context.home?.abbreviation ?? game.home.team.abbreviation }

    private var statisticLabels: [String] {
        var labels: [String] = []
        for statistic in (context.away?.seasonStatistics ?? []) + (context.home?.seasonStatistics ?? [])
        where !labels.contains(statistic.label) {
            labels.append(statistic.label)
        }
        return labels
    }

    private var leaderCategories: [(id: String, title: String)] {
        var categories: [(id: String, title: String)] = []
        for leader in (context.away?.leaders ?? []) + (context.home?.leaders ?? [])
        where !categories.contains(where: { $0.id == leader.id }) {
            categories.append((leader.id, leader.category))
        }
        return categories
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !statisticLabels.isEmpty { season }
            if !leaderCategories.isEmpty { leaders }
            KyroSportsSourceNote(text: "Season figures from ESPN, before this game. Statistics from the game itself appear here once it starts.")
        }
        .accessibilityIdentifier("kyroSportsPregameStats")
    }

    private var season: some View {
        let labels = statisticLabels
        return VStack(alignment: .leading, spacing: 10) {
            KyroSportsPregameCardTitle(title: "Season statistics", detail: "Season to date · not from this game")
            KyroSportsStatComparisonHeader(away: awayName, home: homeName, columnWidth: 58)
            ForEach(labels, id: \.self) { label in
                KyroSportsStatComparisonRow(label: label,
                                            away: context.away?.seasonStatistics.first { $0.label == label }?.value ?? "–",
                                            home: context.home?.seasonStatistics.first { $0.label == label }?.value ?? "–",
                                            columnWidth: 58)
                if label != labels.last { Divider() }
            }
        }
        .kyroPregameCard()
    }

    private var leaders: some View {
        let categories = leaderCategories
        return VStack(alignment: .leading, spacing: 12) {
            KyroSportsPregameCardTitle(title: "Season leaders", detail: "Each team's leader this season")
            ForEach(categories, id: \.id) { category in
                VStack(alignment: .leading, spacing: 6) {
                    Text(category.title.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(game.league.accentColor)
                    HStack(alignment: .top, spacing: 12) {
                        leader(context.away?.leaders.first { $0.id == category.id }, team: awayName, alignment: .leading)
                        leader(context.home?.leaders.first { $0.id == category.id }, team: homeName, alignment: .trailing)
                    }
                }
                if category.id != categories.last?.id { Divider() }
            }
        }
        .kyroPregameCard()
    }

    private func leader(_ leader: KyroSportsPregameContext.Leader?, team: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(leader?.athlete ?? "–")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KyroTheme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
            Text(leader.map { "\(team) · \($0.value)" } ?? team)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(KyroTheme.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Tennis

/// Ranking, surface, venue and head to head for an upcoming singles match, from theScore. The full
/// Players card (recent results) is on the Stats tab.
struct KyroTennisPregameSummary: View {
    let info: KyroTennisPlayerInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KyroSportsPregameCardTitle(title: "Matchup")
            HStack(alignment: .top, spacing: 12) {
                player(info.away, alignment: .leading)
                player(info.home, alignment: .trailing)
            }
            Divider()
            HStack {
                Text("\(info.awayHeadToHeadWins)").frame(minWidth: 30, alignment: .leading)
                Text(info.meetings > 0 ? "HEAD TO HEAD" : "FIRST MEETING")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(KyroTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                Text("\(info.homeHeadToHeadWins)").frame(minWidth: 30, alignment: .trailing)
            }
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .opacity(info.meetings > 0 ? 1 : 0.6)
            .accessibilityElement(children: .combine)
            if info.surface != nil || info.venue != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let surface = info.surface { Label(surface, systemImage: "square.grid.3x3.fill") }
                    if let venue = info.venue { Label(venue, systemImage: "mappin.and.ellipse") }
                }
                .font(.caption)
                .foregroundStyle(KyroTheme.textSecondary)
            }
            KyroSportsSourceNote(text: "Rankings, head to head and surface from \(info.providerName), before this match.")
        }
        .kyroPregameCard()
        .accessibilityIdentifier("kyroTennisPregameSummary")
    }

    private func player(_ player: KyroTennisPlayerInfo.Player, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(player.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
            Text(player.rank.map { "Rank #\($0)" } ?? "No ranking listed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(player.rank == nil ? KyroTheme.textSecondary : KyroTheme.textPrimary)
            if let country = player.country, !country.isEmpty {
                Text(country).font(.caption2).foregroundStyle(KyroTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
        .accessibilityElement(children: .combine)
    }
}
