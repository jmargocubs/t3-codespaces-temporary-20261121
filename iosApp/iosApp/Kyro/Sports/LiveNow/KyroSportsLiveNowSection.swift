import SwiftUI

/// Live Now: compact, horizontally swipeable cards for live events Kyro can play. A tap runs the
/// Build 38 one-tap flow; nothing here starts a stream on its own.
struct KyroSportsLiveNowSection: View {
    let model: KyroSportsLiveNowModel
    let category: KyroSportsCategory
    /// The event the one-tap flow is searching or connecting for, if any.
    let activeGameID: KyroGameID?
    /// Build 67: the event in the player above the Feed. Its card is left out (the player already
    /// shows it), and the section becomes "Also Live", or goes away when nothing else is live.
    var pinnedGameID: KyroGameID? = nil
    /// The selected sports are still on their first load, so an empty Live Now is not yet known.
    var isLoadingScores = false
    let play: (KyroSportsGame) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// One height for every Live Now state (cards, checking, nothing live), scaled with text size.
    /// Live Now follows the sport filter, so without it the section grew or shrank on each sport
    /// switch and moved Scores & Schedule below it.
    @ScaledMetric(relativeTo: .subheadline) private var contentHeight = KyroSportsLiveNowCard.minimumHeight
    /// Build 68: one height for every message (nothing live, live but nothing playable, checking),
    /// so changing between them never moves the schedule. Build 67 reserved a full card row for a
    /// one-line message, which the Build 67 recording showed as a large empty box.
    @ScaledMetric(relativeTo: .subheadline) private var messageHeight = KyroSportsLiveNowEmptyState.compactHeight

    private var items: [KyroSportsLiveNowModel.Item] {
        KyroSportsLiveNowLayout.visibleItems(model.items, pinnedGameID: pinnedGameID)
    }

    var body: some View {
        let items = items
        if KyroSportsLiveNowLayout.showsSection(visibleItemCount: items.count, hasPinnedEvent: pinnedGameID != nil) {
            VStack(alignment: .leading, spacing: 10) {
                header(hasItems: !items.isEmpty)
                if items.isEmpty {
                    KyroSportsLiveNowEmptyState(content: .init(status: model.status, liveEventCount: model.liveEventCount,
                                                               category: category, isLoadingScores: isLoadingScores),
                                                minimumHeight: messageHeight)
                } else {
                    cards(items)
                }
            }
            .accessibilityIdentifier("kyroSportsLiveNow")
        }
    }

    private func header(hasItems: Bool) -> some View {
        HStack(spacing: 8) {
            Text(pinnedGameID == nil ? "Live Now" : "Also Live")
                .font(.title3.bold())
                .foregroundStyle(KyroTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            KyroLiveDot()
            Spacer(minLength: 0)
            if model.isResolving, hasItems {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking your channels")
            }
        }
    }

    private func cards(_ items: [KyroSportsLiveNowModel.Item]) -> some View {
        let columns = KyroSportsLiveNowLayout.columns(itemCount: items.count,
                                                      isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                                                      isExtraLarge: dynamicTypeSize >= .xxLarge)
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 8) {
                ForEach(items) { item in
                    let isActive = activeGameID == item.id
                    Button { play(item.game) } label: {
                        KyroSportsLiveNowCard(item: item, isConnecting: isActive, isWide: columns == 1,
                                              minimumHeight: contentHeight)
                    }
                    .buttonStyle(KyroSportsLiveNowCardStyle(isActive: isActive))
                    .containerRelativeFrame(.horizontal, count: columns, spacing: 8)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(KyroSportsLiveNowCard.accessibilityLabel(for: item))
                    .accessibilityHint("Plays the best stream for this game")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("kyroSportsLiveNow-\(item.game.id.stringValue)")
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
    }
}

/// One live event: league and clock, both sides with scores, and how many strong streams exist.
/// Build 67: a card alone in its row (`isWide`) uses the width for larger logos, full names and a
/// scoreboard-sized score, at the same height, so the section never resizes.
struct KyroSportsLiveNowCard: View {
    /// Live Now's content height at the default text size, shared with its message states.
    static let minimumHeight: CGFloat = 118

    let item: KyroSportsLiveNowModel.Item
    let isConnecting: Bool
    var isWide = false
    var minimumHeight: CGFloat = KyroSportsLiveNowCard.minimumHeight

    @ScaledMetric(relativeTo: .headline) private var wideLogo: CGFloat = 26

    private var game: KyroSportsGame { item.game }
    private var isTennis: Bool { game.league == .atp || game.league == .wta }

    var body: some View {
        VStack(alignment: .leading, spacing: isWide ? 6 : 7) {
            HStack(spacing: 5) {
                Text(game.league.shortName)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(KyroTheme.accentInk)
                Spacer(minLength: 2)
                HStack(spacing: 4) {
                    Circle().fill(KyroTheme.live).frame(width: 6, height: 6)
                    Text(game.statusLine)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .font((isWide ? Font.caption : .caption2).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(KyroTheme.textPrimary)
            }
            side(game.away, sets: setScores(away: true))
            side(game.home, sets: setScores(away: false))
            Spacer(minLength: 0)
            footer
        }
        .padding(isWide ? 12 : 10)
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .topLeading)
    }

    private func side(_ side: KyroGameTeam, sets: String?) -> some View {
        HStack(spacing: isWide ? 10 : 6) {
            if !isTennis {
                KyroSportsTeamLogo(team: side.team, size: isWide ? wideLogo : 18)
            }
            ViewThatFits(in: .horizontal) {
                Text(name(side)).lineLimit(1)
                Text(isTennis ? name(side) : side.team.abbreviation).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(isWide ? .headline : .subheadline.weight(.semibold))
            .foregroundStyle(isWide ? KyroTheme.textPrimary : KyroTheme.silver)
            Spacer(minLength: 2)
            if let sets {
                Text(sets).font((isWide ? Font.subheadline : .caption).weight(.semibold)).monospacedDigit()
                    .foregroundStyle(KyroTheme.textPrimary).lineLimit(1)
            } else if let score = side.score {
                Text(String(score))
                    .font(isWide ? .title2.weight(.bold) : .headline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(KyroTheme.textPrimary)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 5) {
            if isConnecting {
                ProgressView().controlSize(.mini)
                Text("Connecting")
            } else {
                Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                if isWide {
                    Text("Watch")
                    Text("·").foregroundStyle(KyroTheme.textSecondary)
                    Text(KyroSportsLiveNowCard.streamCountText(item.streamCount))
                        .foregroundStyle(KyroTheme.textSecondary)
                } else {
                    Text(KyroSportsLiveNowCard.streamCountText(item.streamCount))
                }
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(KyroTheme.accentInk)
        .lineLimit(1)
    }

    /// Tennis players by surname (full name when the card has the row to itself); teams by
    /// nickname, falling back to the abbreviation.
    private func name(_ side: KyroGameTeam) -> String {
        if isTennis {
            if isWide { return side.team.nickname }
            return side.team.nickname.split(separator: " ").last.map(String.init) ?? side.team.nickname
        }
        if isWide { return KyroSportsMatchupArtwork.columnName(for: side) }
        return side.team.nickname
    }

    /// Tennis has no running score: each player's games per set, e.g. `6 3 2`.
    private func setScores(away: Bool) -> String? {
        guard isTennis, !game.periods.isEmpty else { return nil }
        return game.periods.map { set in
            (away ? set.awayScore : set.homeScore).map(String.init) ?? "–"
        }.joined(separator: " ")
    }

    static func streamCountText(_ count: Int) -> String {
        count == 1 ? "1 stream" : "\(count) streams"
    }

    static func accessibilityLabel(for item: KyroSportsLiveNowModel.Item) -> String {
        let game = item.game
        let isTennis = game.league == .atp || game.league == .wta
        func side(_ side: KyroGameTeam) -> String {
            guard let score = side.score, !isTennis else { return side.team.fullName }
            return "\(side.team.fullName) \(score)"
        }
        return [side(game.away), side(game.home), game.league.displayName, "live", game.statusLine,
                streamCountText(item.streamCount)].joined(separator: ", ")
    }
}

/// Static card chrome with Kyro's electric-blue selection while pressed or connecting.
struct KyroSportsLiveNowCardStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        let highlighted = isActive || configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return configuration.label
            .background {
                if highlighted { shape.fill(KyroTheme.selectedFill) }
            }
            .kyroSportsCardChrome(shape)
            .overlay {
                shape.strokeBorder(highlighted ? KyroTheme.selectedBorder : KyroTheme.live.opacity(0.35),
                                   lineWidth: highlighted ? 1.5 : 1)
            }
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct KyroSportsLiveNowEmptyState: View {
    /// Build 68: a two-line message row at the default text size.
    static let compactHeight: CGFloat = 58

    let content: KyroSportsLiveNowEmptyContent
    /// One height for every message, so switching sports or states never resizes the section.
    var minimumHeight: CGFloat = KyroSportsLiveNowEmptyState.compactHeight

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if content.showsProgress {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: content.symbol)
                        .font(.body)
                        .foregroundStyle(KyroTheme.textSecondary)
                }
            }
            .frame(width: 24)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KyroTheme.textPrimary)
                if let message = content.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(KyroTheme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
        .kyroSportsCardChrome(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("kyroSportsLiveNowEmpty")
    }
}
