import SwiftUI
#if os(iOS)
import UIKit
#endif

/// What the Home draws, resolved by `LiveTVView` from the active provider. Plain data, so
/// fixtures can render the Home without a service.
struct LiveTVHomeModel {
    var providers: [LiveTVProvider] = []
    var selectedProviderID: UUID?
    var channelCount = 0
    var isLoading = false
    var contentState: LiveTVChannelListContentState = .setup
    /// Shown above the rails while cached channels keep the Home usable.
    var errorMessage: String?
    var sections: LiveTVHomeSections = .empty
    var upNext: [LiveTVUpNextItem] = []
    var categories: [String] = []
    var carouselEnabled = true

    var selectedProvider: LiveTVProvider? { providers.first { $0.id == selectedProviderID } }
}

/// Guide lookups for Home cards. Each card calls this inside its own body, so a guide change
/// re-renders only the cards that read it, never the whole Home.
struct LiveTVHomeEPG {
    let current: @MainActor (LiveTVChannel, Date) -> LiveTVProgram?

    static let none = LiveTVHomeEPG { _, _ in nil }
}

struct LiveTVHomeActions {
    var play: (LiveTVChannel) -> Void = { _ in }
    var toggleFavorite: (LiveTVChannel) -> Void = { _ in }
    var browse: (LiveTVBrowserFilters) -> Void = { _ in }
    var showAllCategories: () -> Void = {}
    var showGuide: () -> Void = {}
    var showSettings: () -> Void = {}
    var selectProvider: (UUID) -> Void = { _ in }
    var retry: () -> Void = {}
    var isFavorite: (LiveTVChannel) -> Bool = { _ in false }
    var loadPrograms: (LiveTVChannel) -> LiveTVProgramPair = { _ in LiveTVProgramPair(current: nil, next: nil) }
}

/// The three common destinations shown before any Live TV Home rails.
enum LiveTVHomeQuickDestination: CaseIterable, Hashable, Identifiable, Sendable {
    case guide
    case allChannels
    case favoriteChannels

    var id: Self { self }

    var title: String {
        switch self {
        case .guide: "Guide"
        case .allChannels: "All Channels"
        case .favoriteChannels: "Favorite Channels"
        }
    }

    var systemImage: String {
        switch self {
        case .guide: "calendar.day.timeline.left"
        case .allChannels: "rectangle.grid.2x2"
        case .favoriteChannels: "star.fill"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .guide: "liveTVHomeGuide"
        case .allChannels: "liveTVHomeAllChannels"
        case .favoriteChannels: "liveTVHomeFavoriteChannels"
        }
    }

    func activate(_ actions: LiveTVHomeActions) {
        switch self {
        case .guide: actions.showGuide()
        case .allChannels: actions.browse(.channels)
        case .favoriteChannels: actions.browse(.favorites)
        }
    }
}

enum LiveTVHomeMetrics {
    static let margin: CGFloat = 20
    static let sectionTop: CGFloat = 28
    static let railSpacing: CGFloat = 12
    static let heroRadius: CGFloat = 26
    /// The hero's artwork stage. Kyro's compact hero (Build 14) cut it from 170pt, and
    /// moved the LIVE badge onto it, so the whole card is about 28% shorter.
    static let heroStageHeight: CGFloat = 112
    static let heroWelcomeMinHeight: CGFloat = 176
    static let continueSize = CGSize(width: 280, height: 158)
    static let lineupSize = CGSize(width: 120, height: 76)
    static let recentSize = CGSize(width: 168, height: 104)
    static let categorySize = CGSize(width: 104, height: 92)
}

struct LiveTVHomeContent: View {
    let model: LiveTVHomeModel
    let epg: LiveTVHomeEPG
    let actions: LiveTVHomeActions
    /// Clear space at the top for the shell's header, which floats over this page.
    var topRunway: CGFloat = 0
    /// Where the scroll offset goes, so the shell's glass strip reacts to this page. Nil when
    /// the page has no shell header over it.
    var scrollState: PageChromeScrollState? = nil

    var body: some View {
        if let scrollState {
            scroll.reportsPageChromeScroll(to: scrollState)
        } else {
            scroll
        }
    }

    private var scroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: topRunway)
                status
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(Color.siloErrorInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal, LiveTVHomeMetrics.margin)
                        .padding(.top, 12)
                }
                if model.contentState == .ready { rails }
            }
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(LiveTVHomeBackground())
    }

    @ViewBuilder
    private var rails: some View {
        LiveTVHomeQuickAccess(actions: actions)
            .padding(.horizontal, LiveTVHomeMetrics.margin)
            .padding(.top, 12)

        if !isPhoneHome {
            Group {
                if !model.sections.featured.isEmpty {
                    LiveTVHeroCarousel(cards: model.sections.featured, epg: epg, isEnabled: model.carouselEnabled,
                                       isFavorite: actions.isFavorite, play: actions.play,
                                       toggleFavorite: actions.toggleFavorite, loadPrograms: actions.loadPrograms)
                } else {
                    LiveTVHeroWelcomeCard(browse: { actions.browse(.channels) })
                }
            }
            .padding(.horizontal, LiveTVHomeMetrics.margin)
            .padding(.top, 12)
        }

        if !model.sections.continueWatching.isEmpty {
            LiveTVHomeSectionHeader(title: "Continue Watching")
            LiveTVHomeRail(model.sections.continueWatching) { card in
                LiveTVContinueCard(card: card, epg: epg) { actions.play(card.channel) }
            }
        }

        LiveTVHomeSectionHeader(title: "Favorites",
                                action: model.sections.lineup.isEmpty
                                    ? nil : LiveTVHomeSectionAction(label: "View All") { actions.browse(.favorites) },
                                titleIdentifier: "liveTVHomeFavoritesHeader")
        if model.sections.lineup.isEmpty {
            LiveTVLineupEmptyCard { actions.browse(.channels) }
                .padding(.horizontal, LiveTVHomeMetrics.margin)
        } else {
            LiveTVHomeRail(model.sections.lineup, spacing: 10) { card in
                LiveTVLineupTile(card: card, play: { actions.play(card.channel) },
                                 remove: { actions.toggleFavorite(card.channel) })
            }
        }

        // The Home layout already splits history after Continue Watching. Draw the remaining
        // channels here instead of repeating the first three in a second rail.
        if !model.sections.recentlyWatched.isEmpty {
            LiveTVHomeSectionHeader(title: "Recently Watched")
            LiveTVHomeRail(model.sections.recentlyWatched) { card in
                LiveTVContinueCard(card: card, epg: epg) { actions.play(card.channel) }
            }
        }

        if !model.upNext.isEmpty {
            LiveTVHomeSectionHeader(title: "Up Next")
            LiveTVUpNextRail(items: model.upNext, isFavorite: actions.isFavorite,
                             toggleFavorite: actions.toggleFavorite, loadPrograms: actions.loadPrograms,
                             play: actions.play)
        }

        if !model.categories.isEmpty {
            LiveTVHomeSectionHeader(title: "Live TV Categories",
                                    action: LiveTVHomeSectionAction(label: "View All", perform: actions.showAllCategories))
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(LiveTVHomeSelection.categories(from: model.categories), id: \.self) { category in
                        LiveTVCategoryTile(title: category, symbol: LiveTVCategorySymbol.symbol(for: category)) {
                            actions.browse(.category(category))
                        }
                    }
                }
            }
            .contentMargins(.horizontal, LiveTVHomeMetrics.margin, for: .scrollContent)
            .scrollIndicators(.hidden)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }

    }

    private var isPhoneHome: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    @ViewBuilder
    private var status: some View {
        switch model.contentState {
        case .ready:
            EmptyView()
        case .loading:
            LiveTVHomeStatusCard {
                HStack(spacing: 12) {
                    ProgressView().tint(LiveTVAccent.primaryText)
                    Text("Loading channels…").foregroundStyle(Color.siloSecondaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            }
        case .failed(let error):
            LiveTVHomeStatusCard {
                ContentUnavailableView {
                    Label("Couldn’t Load Channels", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again", action: actions.retry).tint(LiveTVAccent.primaryText)
                }
            }
        case .setup:
            LiveTVHomeStatusCard {
                ContentUnavailableView {
                    Label("Set Up Live TV", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("Add an M3U playlist or Xtream Codes account to browse live channels.")
                } actions: {
                    Button("Add Playlist", action: actions.showSettings)
                        .buttonStyle(.borderedProminent)
                        .tint(LiveTVAccent.primary)
                }
            }
        case .noChannels:
            LiveTVHomeStatusCard {
                ContentUnavailableView("No Channels", systemImage: "tv",
                                       description: Text("Refresh the playlist or check its settings."))
            }
        }
    }
}

// MARK: - Header

/// One unified Live TV header: context-aware back, KYRO LIVE wordmark, and trailing actions.
/// The wordmark opts out of the iOS 26 toolbar glass so it reads as branding, not a button.
struct LiveTVHomeToolbar: ToolbarContent {
    let back: () -> Void
    let backLabel: String
    let search: () -> Void
    let guide: () -> Void
    let settings: () -> Void

    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItemGroup(placement: .topBarLeading) {
                backButton
                LiveTVBrandWordmark()
            }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItemGroup(placement: .topBarLeading) {
                backButton
                LiveTVBrandWordmark()
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(action: search) { Image(systemName: "magnifyingglass") }
                .accessibilityLabel("Search channels")
            Button(action: guide) { Image(systemName: "calendar.day.timeline.left") }
                .accessibilityLabel("TV Guide")
            Button(action: settings) { Image(systemName: "gearshape") }
                .accessibilityLabel("Live TV settings")
        }
    }

    private var backButton: some View {
        Button(action: back) {
            Image(systemName: "chevron.left")
                .font(.body.weight(.semibold))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.bordered)
        .tint(LiveTVAccent.primaryText)
        .accessibilityLabel(backLabel)
    }
}

/// The approved metallic KYRO wordmark with LIVE beside it in the C3 pink-red
/// (5.0:1 on black). No play glyph: the wordmark is the brand.
struct LiveTVBrandWordmark: View {
    /// The wordmark image carries its glow inside the frame; at this width the
    /// letters are about 19pt tall, sized for the 44pt toolbar row.
    static let wordmarkWidth: CGFloat = 86

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            #if os(iOS)
            Image(KyroBrand.wordmarkImageName)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: Self.wordmarkWidth)
            #else
            Text("KYRO")
                .font(.system(size: 22, weight: .black))
                .tracking(1.5)
                .foregroundStyle(.white)
            #endif
            Text("LIVE")
                .font(.system(size: 12, weight: .heavy))
                .tracking(1.6)
                .foregroundStyle(LiveTVAccent.live)
        }
        .fixedSize()
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Kyro Live")
        .accessibilityAddTraits(.isHeader)
    }
}

private struct LiveTVHomeSectionAction {
    let label: String
    let perform: () -> Void
}

private struct LiveTVHomeSectionHeader: View {
    let title: String
    var action: LiveTVHomeSectionAction? = nil
    /// Names the title for UI tests, which must tell Home's Favorites header from the
    /// destination row's Favorites segment.
    var titleIdentifier: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(titleIdentifier ?? "")
            Spacer(minLength: 8)
            if let action {
                Button(action: action.perform) {
                    HStack(spacing: 3) {
                        Text(action.label)
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LiveTVAccent.primaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(action.label) \(title)")
            }
        }
        .padding(.horizontal, LiveTVHomeMetrics.margin)
        .padding(.top, LiveTVHomeMetrics.sectionTop)
        .padding(.bottom, 12)
    }
}

private struct LiveTVHomeRail<Content: View>: View {
    let cards: [LiveTVHomeCard]
    let spacing: CGFloat
    let content: (LiveTVHomeCard) -> Content

    init(_ cards: [LiveTVHomeCard], spacing: CGFloat = LiveTVHomeMetrics.railSpacing,
         @ViewBuilder content: @escaping (LiveTVHomeCard) -> Content) {
        self.cards = cards
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: spacing) {
                ForEach(cards) { content($0) }
            }
        }
        .contentMargins(.horizontal, LiveTVHomeMetrics.margin, for: .scrollContent)
        .scrollIndicators(.hidden)
        // The cards have fixed artwork sizes, so their text stops growing at xxLarge.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

// MARK: - Hero

/// Up to six featured channels. Owns all rotation state, so advancing a page redraws only the
/// carousel, never the rest of Home.
///
/// Rotation runs from one task keyed on the current page and every pause input. Any page change,
/// automatic or by hand, restarts the seven-second wait exactly once; a pause cancels it.
private struct LiveTVHeroCarousel: View {
    let cards: [LiveTVHomeCard]
    let epg: LiveTVHomeEPG
    let isEnabled: Bool
    let isFavorite: (LiveTVChannel) -> Bool
    let play: (LiveTVChannel) -> Void
    let toggleFavorite: (LiveTVChannel) -> Void
    let loadPrograms: (LiveTVChannel) -> LiveTVProgramPair
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var selectedID: String?
    @State private var isUserScrolling = false
    @State private var isVisible = false
    @State private var info: LiveTVChannelInfo?
    @State private var pendingPlayback: LiveTVChannel?

    private var ids: [String] { cards.map(\.id) }
    private var currentIndex: Int { selectedID.flatMap { ids.firstIndex(of: $0) } ?? 0 }
    private var shouldRotate: Bool {
        LiveTVHomeCarouselPolicy.shouldRotate(candidateCount: cards.count, enabled: isEnabled,
                                              visible: isVisible, interacting: isUserScrolling,
                                              infoPresented: info != nil,
                                              reduceMotion: reduceMotion, voiceOver: voiceOver)
    }

    var body: some View {
        VStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: LiveTVHomeMetrics.railSpacing) {
                    ForEach(cards) { card in
                        LiveTVHeroCard(card: card, epg: epg, play: { play(card.channel) },
                                       showInfo: { openInfo(card.channel) })
                            .containerRelativeFrame(.horizontal)
                            .frame(maxHeight: .infinity)
                            .id(card.id)
                    }
                }
                // Every page takes the tallest page's height, so swiping never changes the layout.
                .fixedSize(horizontal: false, vertical: true)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            .scrollPosition(id: $selectedID)
            .scrollIndicators(.hidden)
            .scrollDisabled(cards.count < 2)
            .onScrollPhaseChange { _, phase in
                isUserScrolling = LiveTVHomeCarouselPolicy.isUserScroll(phase)
            }

            if cards.count > 1 { pageDots }
        }
        .background(alignment: .top) {
            // One static glow behind the carousel instead of a shadow on every page.
            // Fades out before the frame's edges, so no seam shows.
            RadialGradient(colors: [LiveTVAccent.primary.opacity(0.22), .clear], center: .center,
                           startRadius: 0, endRadius: 250)
                .frame(width: 560, height: 520)
                .offset(y: -20)
                .allowsHitTesting(false)
        }
        .onScrollVisibilityChange(threshold: 0.5) { isVisible = $0 }
        .task(id: LiveTVHomeCarouselPolicy.TimerKey(rotating: shouldRotate, page: selectedID, ids: ids)) {
            guard shouldRotate else { return }
            do { try await Task.sleep(for: LiveTVHomeCarouselPolicy.interval) } catch { return }
            guard !Task.isCancelled, let next = LiveTVHomeCarouselPolicy.page(after: selectedID, in: ids) else { return }
            withAnimation(.smooth(duration: 0.6)) { selectedID = next }
        }
        .onChange(of: ids) { _, newIDs in
            selectedID = LiveTVHomeCarouselPolicy.selection(keeping: selectedID, in: newIDs)
        }
        .sheet(item: $info, onDismiss: {
            guard let channel = pendingPlayback else { return }
            pendingPlayback = nil
            play(channel)
        }) { info in
            LiveTVChannelInfoSheet(info: info, isFavorite: isFavorite(info.channel),
                                   toggleFavorite: { toggleFavorite(info.channel) },
                                   watchLive: { pendingPlayback = info.channel; self.info = nil })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 2) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                Button {
                    if reduceMotion { selectedID = id } else { withAnimation(.smooth(duration: 0.5)) { selectedID = id } }
                } label: {
                    Capsule().fill(index == currentIndex ? LiveTVAccent.primaryText : Color.white.opacity(0.28))
                        .frame(width: index == currentIndex ? 18 : 6, height: 6)
                        .frame(width: 26, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        // One adjustable control for VoiceOver instead of six tiny buttons.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Featured channels")
        .accessibilityValue("\(currentIndex + 1) of \(ids.count)")
        .accessibilityAdjustableAction { direction in
            let index = direction == .increment ? min(currentIndex + 1, ids.count - 1) : max(currentIndex - 1, 0)
            selectedID = ids[index]
        }
    }

    private func openInfo(_ channel: LiveTVChannel) {
        // Guide details are resolved only when the sheet opens.
        info = LiveTVChannelInfo(channel: channel, programs: loadPrograms(channel))
    }
}

/// One Channel Info presentation: the channel and the guide details read when it opened.
struct LiveTVChannelInfo: Identifiable {
    let channel: LiveTVChannel
    let programs: LiveTVProgramPair
    let highlightedProgram: LiveTVProgram?

    var id: String { channel.id }
    var summary: String? { LiveTVHomeChannelInfo.summary(programs.current?.summary) }
    var hasGuide: Bool { programs.current != nil || programs.next != nil || highlightedProgram != nil }

    init(channel: LiveTVChannel, programs: LiveTVProgramPair, highlightedProgram: LiveTVProgram? = nil) {
        self.channel = channel
        self.programs = programs
        self.highlightedProgram = highlightedProgram
    }
}

struct LiveTVChannelInfoSheet: View {
    let info: LiveTVChannelInfo
    let toggleFavorite: () -> Void
    let watchLive: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var inLineup: Bool

    init(info: LiveTVChannelInfo, isFavorite: Bool, toggleFavorite: @escaping () -> Void,
         watchLive: @escaping () -> Void) {
        self.info = info
        self.toggleFavorite = toggleFavorite
        self.watchLive = watchLive
        _inLineup = State(initialValue: isFavorite)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        ZStack {
                            LiveTVBrandSurface(channel: info.channel)
                            LiveTVLogoMark(channel: info.channel, size: CGSize(width: 76, height: 50))
                        }
                        .frame(width: 96, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(info.channel.name).font(.title3.bold()).foregroundStyle(.white)
                            Text(info.channel.category.isEmpty ? "Live TV" : info.channel.category)
                                .font(.subheadline).foregroundStyle(Color.siloSecondaryText)
                        }
                    }
                    .accessibilityElement(children: .combine)

                    if info.hasGuide {
                        if let current = info.programs.current {
                            programRow(label: "Now", program: current, summary: info.summary)
                        }
                        if let highlighted = info.highlightedProgram {
                            programRow(label: "Up Next", program: highlighted,
                                      summary: LiveTVHomeChannelInfo.summary(highlighted.summary))
                        } else if let next = info.programs.next {
                            programRow(label: "Up Next", program: next, summary: nil)
                        }
                    } else {
                        Label("No guide information for this channel right now.", systemImage: "calendar.badge.exclamationmark")
                            .font(.subheadline)
                            .foregroundStyle(Color.siloSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    VStack(spacing: 10) {
                        Button(action: watchLive) {
                            Label("Watch Live", systemImage: "play.fill")
                                .font(.body.weight(.bold))
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(LiveTVAccent.primary)
                        Button {
                            inLineup.toggle()
                            toggleFavorite()
                        } label: {
                            Label(inLineup ? "Remove from Favorites" : "Add to Favorites",
                                  systemImage: inLineup ? "star.slash" : "star")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }
                    .padding(.top, 4)
                }
                .padding(22)
            }
            .safeAreaPadding(.bottom, 16)
            .background(LiveTVHomeBackground())
            .navigationTitle("Channel Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func programRow(label: String, program: LiveTVProgram, summary: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(.caption.bold()).foregroundStyle(LiveTVAccent.primaryText)
            Text(program.title).font(.headline).foregroundStyle(.white)
            Text(LiveTVHomeText.timeRange(program)).font(.caption).foregroundStyle(Color.siloSecondaryText)
            if let summary {
                Text(summary).font(.subheadline).foregroundStyle(.white.opacity(0.78))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LiveTVHeroCard: View {
    let card: LiveTVHomeCard
    let epg: LiveTVHomeEPG
    let play: () -> Void
    let showInfo: () -> Void
    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = 24

    var body: some View {
        TimelineView(.everyMinute) { context in
            let program = epg.current(card.channel, context.date)
            VStack(alignment: .leading, spacing: 0) {
                LiveTVHeroStage(card: card)
                    .frame(maxWidth: .infinity)
                    .frame(height: LiveTVHomeMetrics.heroStageHeight)
                    .overlay(alignment: .topLeading) {
                        // A dark backing keeps the badge legible over bright artwork.
                        LiveTVLiveBadge(text: "LIVE NOW")
                            .background(Color.black.opacity(0.45), in: Capsule())
                            .padding(14)
                    }
                VStack(alignment: .leading, spacing: 0) {
                    Text(program?.title ?? card.channel.name)
                        .font(.system(size: titleSize, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(LiveTVHomeText.meta(channel: card.channel, program: program, includesChannel: program != nil))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                        .padding(.top, 3)
                    Spacer(minLength: 12)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { watchButton; infoButton }
                        VStack(alignment: .leading, spacing: 10) { watchButton; infoButton }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                ZStack {
                    LiveTVBrandSurface(channel: card.channel)
                    LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.85), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: LiveTVHomeMetrics.heroRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LiveTVHomeMetrics.heroRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        }
    }

    private var watchButton: some View {
        Button(action: play) {
            Label("Watch Live", systemImage: "play.fill")
                .font(.callout.weight(.bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .background(.white.opacity(0.94), in: Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Watch \(card.channel.name) live")
    }

    private var infoButton: some View {
        Button(action: showInfo) {
            Label("Channel Info", systemImage: "info.circle")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(Color.white.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Channel info for \(card.channel.name)")
    }
}

/// The top of a hero: program artwork when the guide supplies it, otherwise the channel logo
/// at full size with a soft glow in its brand color.
private struct LiveTVHeroStage: View {
    let card: LiveTVHomeCard

    var body: some View {
        if let artworkURL = card.artworkURL {
            AsyncImageView(url: artworkURL.absoluteString, contentMode: .fill, placeholderSymbol: nil)
                .accessibilityHidden(true)
        } else {
            ZStack {
                RadialGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.04), .clear],
                               center: .center, startRadius: 0, endRadius: 150)
                LiveTVLogoMark(channel: card.channel, size: CGSize(width: 176, height: 84))
                    .padding(.top, 6)
            }
        }
    }
}

enum LiveTVHomeChannelInfo {
    static func summary(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

enum LiveTVHomeCarouselPolicy {
    static let interval: Duration = .seconds(7)

    /// Identity of the rotation task. Changing any part restarts the wait from zero.
    struct TimerKey: Hashable {
        let rotating: Bool
        let page: String?
        let ids: [String]
    }

    static func shouldRotate(candidateCount: Int, enabled: Bool, visible: Bool, interacting: Bool,
                             infoPresented: Bool, reduceMotion: Bool, voiceOver: Bool) -> Bool {
        candidateCount > 1 && enabled && visible && !interacting && !infoPresented && !reduceMotion && !voiceOver
    }

    /// A finger on the carousel, or its fling settling. A programmatic page animation is not one.
    static func isUserScroll(_ phase: ScrollPhase) -> Bool {
        switch phase {
        case .tracking, .interacting, .decelerating: true
        default: false
        }
    }

    /// The page after `current`, wrapping to the first. Nil when there is nothing to advance to.
    static func page(after current: String?, in ids: [String]) -> String? {
        guard ids.count > 1 else { return nil }
        let index = current.flatMap { ids.firstIndex(of: $0) } ?? 0
        return ids[(index + 1) % ids.count]
    }

    /// Keeps the page the user is on when it is still featured; otherwise starts over at the first.
    /// A provider switch replaces every ID, so it always starts over.
    static func selection(keeping current: String?, in ids: [String]) -> String? {
        if let current, ids.contains(current) { return current }
        return ids.first
    }
}

/// Compact at normal sizes; at accessibility sizes the same destinations become full-width rows
/// rather than squeezing three long labels into unusable targets.
private struct LiveTVHomeQuickAccess: View {
    let actions: LiveTVHomeActions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    ForEach(LiveTVHomeQuickDestination.allCases) { destination in
                        button(destination, compact: false)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(LiveTVHomeQuickDestination.allCases) { destination in
                        button(destination, compact: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live TV destinations")
    }

    private func button(_ destination: LiveTVHomeQuickDestination, compact: Bool) -> some View {
        Button { destination.activate(actions) } label: {
            Group {
                if compact {
                    VStack(spacing: 7) {
                        Image(systemName: destination.systemImage)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(LiveTVAccent.primaryText)
                        Text(destination.title)
                            .font(.caption.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 66)
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: destination.systemImage)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(LiveTVAccent.primaryText)
                            .frame(width: 24)
                        Text(destination.title)
                            .font(.body.weight(.semibold))
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 52)
                }
            }
            .foregroundStyle(.white)
            .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(destination.title)
        .accessibilityHint("Opens \(destination.title) in Live TV")
        .accessibilityIdentifier(destination.accessibilityIdentifier)
    }
}

private struct LiveTVHeroWelcomeCard: View {
    let browse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(LiveTVAccent.primaryText)
            Text("Your live channels")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.top, 10)
            Text("Channels you watch and star show up here.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 4)
            HStack(spacing: 10) {
                Button(action: browse) {
                    Text("Browse Channels")
                        .font(.body.weight(.bold)).foregroundStyle(.black)
                        .padding(.horizontal, 20).frame(minHeight: 46)
                        .background(.white.opacity(0.94), in: Capsule())
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: LiveTVHomeMetrics.heroWelcomeMinHeight, alignment: .bottomLeading)
        .background(
            LinearGradient(colors: [LiveTVAccent.primary.opacity(0.6), Color(hex: "#050A30"), Color(hex: "#08080B")],
                           startPoint: .topTrailing, endPoint: .bottomLeading),
            in: RoundedRectangle(cornerRadius: LiveTVHomeMetrics.heroRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LiveTVHomeMetrics.heroRadius, style: .continuous)
            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }
}

// MARK: - Cards

/// Program artwork when a card has it, otherwise the channel logo on its brand gradient.
private struct LiveTVCardBackdrop: View {
    let card: LiveTVHomeCard
    let logoSize: CGSize
    var logoAlignment: Alignment = .center
    var logoPadding: CGFloat = 22

    var body: some View {
        if let artworkURL = card.artworkURL {
            AsyncImageView(url: artworkURL.absoluteString, contentMode: .fill, placeholderSymbol: nil)
        } else {
            ZStack(alignment: logoAlignment) {
                LiveTVBrandSurface(channel: card.channel)
                LiveTVLogoMark(channel: card.channel, size: logoSize)
                    .padding(logoPadding)
            }
        }
    }
}

private struct LiveTVContinueCard: View {
    let card: LiveTVHomeCard
    let epg: LiveTVHomeEPG
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            TimelineView(.everyMinute) { context in
                let program = epg.current(card.channel, context.date)
                ZStack(alignment: .bottom) {
                    LiveTVCardBackdrop(card: card, logoSize: CGSize(width: 96, height: 56), logoAlignment: .top,
                                       logoPadding: 20)
                    LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.85), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .bottom, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(program?.title ?? card.channel.name)
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(program.map { "Live · \(LiveTVHomeText.timeRange($0))" } ?? "Live · \(card.channel.category)")
                                    .font(.footnote)
                                    .foregroundStyle(.white.opacity(0.7))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "play.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.black)
                                .frame(width: 32, height: 32)
                                .background(.white.opacity(0.92), in: Circle())
                        }
                        // Time elapsed in the airing program, from the guide. Not a resume point.
                        if let program {
                            LiveTVProgramProgress(fraction: LiveTVHomeText.elapsedFraction(program, at: context.date))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
                .frame(width: LiveTVHomeMetrics.continueSize.width, height: LiveTVHomeMetrics.continueSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(LiveTVHomeText.accessibility(channel: card.channel, program: program))
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Plays the channel")
    }
}

private struct LiveTVLineupTile: View {
    let card: LiveTVHomeCard
    let play: () -> Void
    let remove: () -> Void

    var body: some View {
        Button(action: play) {
            ZStack {
                LiveTVBrandSurface(channel: card.channel, angle: .top)
                if card.channel.logoURL != nil {
                    LiveTVLogoMark(channel: card.channel, size: CGSize(width: 84, height: 44))
                } else {
                    Text(card.channel.name)
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 10)
                }
            }
            .frame(width: LiveTVHomeMetrics.lineupSize.width, height: LiveTVHomeMetrics.lineupSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.06)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(card.channel.name)")
        .contextMenu {
            Button("Play", systemImage: "play.fill", action: play)
            Button("Remove from Favorites", systemImage: "star.slash", role: .destructive, action: remove)
        }
    }
}

private struct LiveTVLineupEmptyCard: View {
    let browse: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "star.fill")
                .font(.title3)
                .foregroundStyle(LiveTVAccent.ember)
                .frame(width: 48, height: 48)
                .background(LiveTVAccent.ember.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("Add your Favorites").font(.headline).foregroundStyle(.white)
                Text("Tap the star on a channel to keep it one tap away.")
                    .font(.footnote).foregroundStyle(Color.siloSecondaryText)
            }
            Spacer(minLength: 8)
            Button("Browse", action: browse)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(LiveTVAccent.primaryText)
        }
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

private struct LiveTVUpNextRail: View {
    let items: [LiveTVUpNextItem]
    let isFavorite: (LiveTVChannel) -> Bool
    let toggleFavorite: (LiveTVChannel) -> Void
    let loadPrograms: (LiveTVChannel) -> LiveTVProgramPair
    let play: (LiveTVChannel) -> Void
    @State private var info: LiveTVChannelInfo?

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: LiveTVHomeMetrics.railSpacing) {
                ForEach(items) { item in
                    LiveTVUpNextCard(item: item) {
                        info = LiveTVChannelInfo(channel: item.channel,
                                                 programs: loadPrograms(item.channel),
                                                 highlightedProgram: LiveTVProgram(item.program))
                    }
                }
            }
        }
        .contentMargins(.horizontal, LiveTVHomeMetrics.margin, for: .scrollContent)
        .scrollIndicators(.hidden)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .sheet(item: $info) { info in
            LiveTVChannelInfoSheet(info: info, isFavorite: isFavorite(info.channel),
                                   toggleFavorite: { toggleFavorite(info.channel) },
                                   watchLive: { play(info.channel) })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct LiveTVUpNextCard: View {
    let item: LiveTVUpNextItem
    let showInfo: () -> Void

    var body: some View {
        Button(action: showInfo) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    LiveTVBrandSurface(channel: item.channel, angle: .topTrailing)
                    LiveTVLogoMark(channel: item.channel, size: CGSize(width: 112, height: 62))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    LinearGradient(stops: [.init(color: .clear, location: 0.3),
                                           .init(color: .black.opacity(0.75), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                    Text(item.channel.name)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .padding(12)
                }
                .frame(width: 214, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))

                Text(item.program.title.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.top, 9)
                Text("Starts \(item.program.start.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(LiveTVAccent.primaryText)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
            .frame(width: 214, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Up next on \(item.channel.name): \(item.program.title), starts \(item.program.start.formatted(date: .omitted, time: .shortened))")
        .accessibilityHint("Opens channel info")
    }
}

private struct LiveTVCategoryTile: View {
    let title: String
    let symbol: String
    var isHighlighted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isHighlighted ? .white : LiveTVAccent.primaryText)
                    .frame(height: 28)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 8)
            .frame(width: LiveTVHomeMetrics.categorySize.width, height: LiveTVHomeMetrics.categorySize.height)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isHighlighted
                          ? AnyShapeStyle(LinearGradient(colors: [LiveTVAccent.primary.opacity(0.75), LiveTVAccent.depth.opacity(0.6)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(LiveTVSurface.tile))
            }
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isHighlighted ? LiveTVAccent.primaryText.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isHighlighted ? title : "Category: \(title)")
    }
}

// MARK: - Small parts

private struct LiveTVLiveBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(LiveTVAccent.live).frame(width: 7, height: 7)
            Text(text).font(.caption2.weight(.heavy)).tracking(0.6).foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(LiveTVAccent.live.opacity(0.2), in: Capsule())
        .overlay(Capsule().strokeBorder(LiveTVAccent.live.opacity(0.75), lineWidth: 1))
    }
}

private struct LiveTVProgramProgress: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(LiveTVAccent.primaryText).frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

private struct LiveTVHomeStatusCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .padding(.horizontal, LiveTVHomeMetrics.margin)
            .padding(.top, 16)
    }
}

/// On iPhone, the Media Server's charcoal page; elsewhere, black with one static blue glow.
/// Nothing here animates or samples images.
struct LiveTVHomeBackground: View {
    var body: some View {
        #if os(iOS)
        SiloPageBackdrop()
        #else
        ZStack(alignment: .top) {
            Color.black
            RadialGradient(colors: [LiveTVAccent.primary.opacity(0.26), LiveTVAccent.depth.opacity(0.2), .clear],
                           center: UnitPoint(x: 0.85, y: 0), startRadius: 0, endRadius: 420)
                .frame(height: 560)
        }
        .ignoresSafeArea()
        #endif
    }
}

enum LiveTVHomeText {
    /// Times only. An interval style adds full dates when a program crosses midnight.
    static func timeRange(_ program: LiveTVProgram) -> String {
        "\(program.startsAt.formatted(date: .omitted, time: .shortened)) – \(program.endsAt.formatted(date: .omitted, time: .shortened))"
    }

    static func meta(channel: LiveTVChannel, program: LiveTVProgram?, includesChannel: Bool) -> String {
        var parts = includesChannel ? [channel.name] : []
        parts.append(channel.category)
        if let program { parts.append(timeRange(program)) }
        return parts.joined(separator: " · ")
    }

    static func elapsedFraction(_ program: LiveTVProgram, at date: Date) -> Double {
        let total = program.endsAt.timeIntervalSince(program.startsAt)
        guard total > 0 else { return 0 }
        return min(max(date.timeIntervalSince(program.startsAt) / total, 0), 1)
    }

    static func accessibility(channel: LiveTVChannel, program: LiveTVProgram?) -> String {
        guard let program else { return "\(channel.name), live" }
        return "\(channel.name), live now: \(program.title), \(timeRange(program))"
    }
}
