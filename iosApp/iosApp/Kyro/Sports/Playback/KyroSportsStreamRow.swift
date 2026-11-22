import SwiftUI
import Nuke
import NukeUI

/// One stream in the Sports Hub stream picker and the player's Other Streams sheet.
struct KyroSportsStreamRow: View {
    let model: KyroSportsStreamRowModel
    var showsEvidence = true
    let select: () -> Void

    var body: some View {
        Button(action: { if model.isSelectable { select() } }) {
            HStack(alignment: .center, spacing: 12) {
                KyroSportsChannelLogo(url: model.logoURL, name: model.displayName)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KyroTheme.textPrimary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    if model.programmeTitle != nil || hasProgrammeInterval {
                        VStack(alignment: .leading, spacing: 1) {
                            if let title = model.programmeTitle {
                                Text(title)
                                    .lineLimit(2)
                                    .truncationMode(.tail)
                            }
                            if let start = model.programmeStart, let end = model.programmeEnd, start < end {
                                Text(start..<end, format: .interval.hour().minute())
                                    .monospacedDigit()
                                    .lineLimit(1)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(KyroTheme.silver)
                    }
                    if showsEvidence {
                        Text(model.evidence)
                            .font(.caption2)
                            .foregroundStyle(KyroTheme.textSecondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                KyroSportsStreamStatusLabel(status: model.status, label: model.statusLabel)
            }
            .frame(minHeight: 44)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(rowBackground)
        .contextMenu {
            Text(model.fullName)
            Button {
                #if os(iOS)
                UIPasteboard.general.string = model.fullName
                #endif
            } label: {
                Label("Copy Channel Name", systemImage: "doc.on.doc")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityHint(model.accessibilityHint)
        .accessibilityAddTraits(model.isCurrent ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("kyroSportsStream-\(model.channelID)")
    }

    private var hasProgrammeInterval: Bool {
        guard let start = model.programmeStart, let end = model.programmeEnd else { return false }
        return start < end
    }

    /// The stream on screen carries Kyro's electric-blue selection.
    @ViewBuilder
    private var rowBackground: some View {
        if model.isCurrent {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(KyroTheme.selectedFill)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(KyroTheme.selectedBorder, lineWidth: 1)
                }
        } else {
            Color.white.opacity(0.05)
        }
    }
}

/// A compact status capsule. Playback results (Played, Didn't play) and match evidence (Event
/// match, Possible) use different tints so one is never read as the other.
struct KyroSportsStreamStatusLabel: View {
    let status: KyroSportsStreamRowModel.Status
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            switch status {
            case .connecting:
                ProgressView().controlSize(.mini)
            case .nowPlaying:
                Image(systemName: "play.fill").font(.system(size: 8, weight: .bold))
            case .played:
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
            case .didNotPlay:
                Image(systemName: "exclamationmark").font(.system(size: 8, weight: .bold))
            case .eventMatch, .possibleMatch, .fromSearch, .unconfirmed:
                EmptyView()
            }
            Text(label)
                .font(.caption2.weight(.bold))
                .lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(foreground)
        .background { Capsule().fill(fill) }
        .overlay { Capsule().strokeBorder(border, lineWidth: 1) }
        .accessibilityHidden(true)
    }

    private var foreground: Color {
        switch status {
        case .nowPlaying: .white
        case .connecting, .fromSearch, .unconfirmed: KyroTheme.textSecondary
        case .played, .eventMatch: KyroTheme.accentInk
        case .didNotPlay: KyroTheme.live
        case .possibleMatch: KyroTheme.highlight
        }
    }

    private var fill: Color {
        switch status {
        case .nowPlaying: KyroTheme.accent
        case .didNotPlay: KyroTheme.live.opacity(0.12)
        case .eventMatch: KyroTheme.selectedFill.opacity(0.6)
        default: Color.white.opacity(0.04)
        }
    }

    private var border: Color {
        switch status {
        case .nowPlaying: .clear
        case .didNotPlay: KyroTheme.live.opacity(0.4)
        case .possibleMatch: KyroTheme.highlight.opacity(0.4)
        case .played, .eventMatch: KyroTheme.selectedBorder
        default: Color.white.opacity(0.12)
        }
    }
}

/// The picker's grouped rows, shared by the stream picker and Other Streams. Network channels
/// with no event evidence stay collapsed until asked for.
struct KyroSportsStreamSectionsView: View {
    let sections: [KyroSportsStreamSection]
    var showsEvidence = true
    let select: (String) -> Void
    @State private var expandedNetwork: Bool?
    @State private var expandedMore: Bool?
    @State private var showAllNetwork = false
    @State private var networkQuery = ""

    var body: some View {
        ForEach(sections) { section in
            Section {
                if section.kind == .moreMatches {
                    // Bounded by the matcher (`maximumOverflowMatches`); List rows render lazily.
                    DisclosureGroup(isExpanded: Binding(
                        get: { expandedMore ?? section.startsExpanded },
                        set: { expandedMore = $0 }
                    )) {
                        rows(section)
                    } label: {
                        Text("\(section.rows.count) more stream\(section.rows.count == 1 ? "" : "s") that list this game")
                            .font(.subheadline)
                            .foregroundStyle(KyroTheme.textSecondary)
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                    .accessibilityIdentifier("kyroSportsMoreMatches")
                } else if section.kind == .networkChannels {
                    DisclosureGroup(isExpanded: Binding(
                        get: { expandedNetwork ?? section.startsExpanded },
                        set: { expandedNetwork = $0 }
                    )) {
                        if showAllNetwork {
                            HStack(spacing: 8) {
                                Image(systemName: "magnifyingglass")
                                    .foregroundStyle(KyroTheme.textSecondary)
                                TextField("Search network channels", text: $networkQuery)
                                    .autocorrectionDisabled()
                                    #if os(iOS)
                                    .textInputAutocapitalization(.never)
                                    #endif
                            }
                        }
                        ForEach(section.visibleNetworkRows(showAll: showAllNetwork, query: networkQuery)) { row in
                            KyroSportsStreamRow(model: row, showsEvidence: showsEvidence) { select(row.channelID) }
                        }
                        if section.rows.count > KyroSportsStreamMatcher.initialBroadcasters {
                            Button(showAllNetwork ? "Show Fewer" : "See All") {
                                showAllNetwork.toggle()
                                networkQuery = ""
                            }
                            .font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("kyroSportsNetworkSeeAll")
                        }
                    } label: {
                        Text("\(section.rows.count == KyroSportsStreamMatcher.maximumBroadcasters ? "Up to " : "")\(section.rows.count) channel\(section.rows.count == 1 ? "" : "s") from the listed network")
                            .font(.subheadline)
                            .foregroundStyle(KyroTheme.textSecondary)
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                } else {
                    rows(section)
                }
            } header: {
                Text(section.title)
            } footer: {
                if section.kind == .networkChannels {
                    Text("Nothing shows these channels carry this game.")
                } else if section.kind == .moreMatches {
                    Text(showsEvidence
                         ? "Each row shows its evidence, as above. Kyro doesn't try these automatically."
                         : "Additional matches are not tried automatically.")
                }
            }
        }
    }

    private func rows(_ section: KyroSportsStreamSection) -> some View {
        ForEach(section.rows) { row in
            KyroSportsStreamRow(model: row, showsEvidence: showsEvidence) { select(row.channelID) }
        }
    }
}

/// A channel logo, or the channel's initials when it has none.
struct KyroSportsChannelLogo: View {
    let url: URL?
    let name: String
    var size: CGFloat = 36
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.08))
            if let request {
                LazyImage(request: request) { state in
                    if let image = state.image {
                        image.resizable().scaledToFit().padding(4)
                    } else {
                        initials
                    }
                }
                .onDisappear(.cancel)
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    private var request: ImageRequest? {
        guard let url else { return nil }
        return PosterImageCache.displayRequest(url: url, pointSize: CGSize(width: size, height: size),
                                               scale: displayScale)
    }

    private var initials: some View {
        Text(String(name.filter { $0.isLetter || $0.isNumber }.prefix(3)).uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(KyroTheme.textSecondary)
    }
}
