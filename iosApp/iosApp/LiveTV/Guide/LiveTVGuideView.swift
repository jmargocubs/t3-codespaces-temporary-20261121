import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The full Live TV guide: a fixed channel column beside a horizontally scrolling time grid.
///
/// One two-axis scroll view hosts lazily built rows under a pinned time header. The channel
/// column and the titles of programmes already under way stay at the leading edge through
/// `visualEffect` offsets, so scrolling never writes view state.
struct LiveTVGuideView: View {
    @Bindable var service: LiveTVService
    #if os(iOS)
    /// Kyro's Live TV navigation around the grid, when Live TV provides it.
    var navigation: KyroLiveTVNavigationRoute?
    #endif
    /// Set when the guide is the watch screen's Guide tab. Channel taps then retune the playing
    /// session in place, and the guide presents no player of its own.
    var watch: LiveTVGuideWatchContext?
    @Environment(\.timeZone) private var timeZone
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedCategory: String?
    @State private var isShowingCategoryPicker = false
    @State private var categoryPickerPosition: LiveTVGuideCategoryPickerID?
    @State private var categoryPickerState = LiveTVGuideCategoryPickerState()
    @State private var favoritesOnly = false
    @State private var rows: [LiveTVChannel] = []
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var isSearchPending = false
    @State private var suppressNextSearchUpdate = false
    @State private var searchGeneration = 0
    @State private var searchModel = LiveTVChannelSearchModel()
    #if os(iOS)
    @State private var pagedChannels = LiveTVPagedChannelModel()
    #endif
    @State private var searchRestoration: LiveTVGuideSearchRestoration?
    @State private var browsingRestoration = LiveTVGuideBrowsingRestoration()
    @State private var restoredContextProviderID: UUID?
    @SceneStorage("liveTV.guideBrowsingContext.v1") private var savedBrowsingContext = ""
    @State private var timeline = LiveTVGuideTimeline(now: .now, timeZone: .current)
    @State private var cells = LiveTVGuideCellCache()
    @State private var position = ScrollPosition(idType: String.self)
    @State private var listPosition = ScrollPosition(idType: String.self)
    @State private var span = LiveTVGuideVisibleSpan(offsetX: 0, viewportWidth: 430, bucketWidth: 240)
    @State private var hasScrolledToNow = false
    @State private var detail: LiveTVGuideDetail?
    @State private var pendingTune: LiveTVChannel?
    /// The grid's real content offset, written on scroll without invalidating the view, so the
    /// pushed guide can hand its time position to the watch screen.
    @State private var scrollTracker = LiveTVGuideScrollTracker()
    /// Watch screen only: the playing channel's row still has to be scrolled into view, at this
    /// time offset. Set when the tab mounts and when the channel changes outside the guide.
    @State private var pendingReveal: LiveTVGuideReveal?
    /// Watch screen only: the channel this guide last tuned, so its own taps do not scroll.
    @State private var tunedFromGuideID: String?
    /// Watch screen list: memoized rows, live geometry and a pending reveal of the playing row.
    @State private var listEntries = LiveTVGuideListEntryCache()
    @State private var listTracker = LiveTVGuideListScrollTracker()
    @State private var listReveal: LiveTVGuideListRevealRequest?
    /// Open diagnostics intervals. A plain reference, so recording them never redraws the guide.
    @State private var perfMarks = LiveTVGuidePerformanceMarks()
    @FocusState private var isCompactSearchFocused: Bool
    /// Watch screen only. Absent or unknown values resolve to List.
    @AppStorage(LiveTVEmbeddedGuideStyle.defaultsKey) private var embeddedGuideStyleRaw = LiveTVEmbeddedGuideStyle.list.rawValue

    private var metrics: LiveTVGuideMetrics { .forWatchScreen(watch != nil) }

    private var embeddedStyle: LiveTVEmbeddedGuideStyle {
        LiveTVEmbeddedGuideStyle.resolve(stored: embeddedGuideStyleRaw)
    }

    var body: some View {
        let _ = KyroPerformanceDiagnostics.event("Guide body", .guideBody)
        chrome
            .modifier(LiveTVChannelCover(service: service, presenter: .guide, isEnabled: watch == nil))
            #if os(iOS)
            // The full TV Guide counts as on screen until a channel's watch screen covers it; the
            // watch screen's Guide tab reports itself. Reads nothing when diagnostics are off.
            .kyroGuidePerformanceScope("screen", isVisible: KyroPerformanceDiagnostics.isEnabled && watch == nil
                                        && service.presentation.channel(for: .guide) == nil)
            #endif
            .sheet(item: $detail, onDismiss: tunePending) { detail in
                LiveTVProgramDetailView(detail: detail) {
                    pendingTune = detail.channel
                    self.detail = nil
                }
            }
            // The full Guide pushes Categories. The watch screen's Guide is a tab under the player
            // inside Watch's own cover, so it presents a fixed full-height page instead: no
            // resizing detents, and Watch, playback and this Guide all stay where they are.
            .navigationDestination(isPresented: categoryPushBinding) { categoryPicker }
            .sheet(isPresented: categorySheetBinding) {
                NavigationStack {
                    categoryPicker
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
            }
            .onChange(of: watch?.activeChannelID) { _, channelID in
                // A channel chosen outside this tab (the full-screen picker) is revealed here;
                // one tapped in this tab is already on screen.
                guard watch != nil, let channelID, channelID != tunedFromGuideID else { return }
                pendingReveal = LiveTVGuideReveal(offsetX: Double(scrollTracker.offset.x))
                revealActiveChannelIfNeeded()
            }
            .onAppear {
                // The watch screen's guide sits inside the guide's own cover; only the pushed
                // guide is a screen that can present the player.
                if watch == nil { service.presentation.surfaceAppeared(.guide) }
                restoreBrowsingContext(for: service.selectedProviderID)
                if timeline.timeZone != timeZone { rebuildTimeline(at: .now) }
                rebuildRows()
            }
            .onChange(of: selectedCategory) {
                KyroPerformanceDiagnostics.end(perfMarks.categoryChange)
                perfMarks.categoryChange = KyroPerformanceDiagnostics.begin("Guide category change", .categoryChange)
                rebuildRows()
            }
            .onChange(of: favoritesOnly) { rebuildRows() }
            .onChange(of: service.favoriteChannelIDs) { if favoritesOnly || !searchText.isEmpty { rebuildRows() } }
            .onChange(of: service.channelCatalogRevision) {
                reconcileBrowsingContext()
                rebuildRows()
            }
            .onChange(of: searchText) {
                guard !suppressNextSearchUpdate else {
                    suppressNextSearchUpdate = false
                    return
                }
                updateSearch()
            }
            .onChange(of: service.selectedProviderID) { _, providerID in
                saveBrowsingContext(for: restoredContextProviderID)
                searchGeneration += 1
                searchModel.cancel()
                #if os(iOS)
                pagedChannels.cancel()
                #endif
                searchText = ""
                isSearchPending = false
                rows = []
                restoreBrowsingContext(for: providerID)
                guard let providerID else {
                    categoryPickerPosition = nil
                    return
                }
                categoryPickerPosition = categoryPickerState.target(
                    providerID: providerID, selectedCategory: selectedCategory, categories: service.categories)
            }
            .onChange(of: service.categories) { _, categories in
                reconcileBrowsingContext()
                guard let providerID = service.selectedProviderID else { return }
                categoryPickerState.reconcile(providerID: providerID, categories: categories)
                if isShowingCategoryPicker {
                    categoryPickerPosition = categoryPickerState.target(
                        providerID: providerID, selectedCategory: selectedCategory, categories: categories)
                }
            }
            .onChange(of: timeZone) { rebuildTimeline(at: .now) }
            .onChange(of: scenePhase) { _, phase in if phase == .background { saveBrowsingContext() } }
            .onDisappear {
                // The Guide can leave while the fixed search field owns first responder. Clear
                // both SwiftUI focus and UIKit's responder before the navigation transition.
                dismissSearchInput()
                saveBrowsingContext()
                searchGeneration += 1
                searchModel.cancel()
                #if os(iOS)
                pagedChannels.cancel()
                #endif
                isSearchPending = false
                if watch == nil { service.presentation.surfaceDisappeared(.guide) }
            }
    }

    /// The pushed guide keeps the navigation bar's title and toolbar. The watch
    /// screen's Guide tab has a player above it, so one compact filter bar replaces all three.
    @ViewBuilder
    private var chrome: some View {
        if watch != nil {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    compactBar
                }
                .liveTVPageBackground()
                .tint(LiveTVAccent.primaryText)
                #if os(iOS)
                .toolbar(.hidden, for: .navigationBar)
                #endif
        } else {
            content
                // Inside the navigation too, so Classic's tab shows the page rather than its own black.
                .liveTVPageBackground()
                #if os(iOS)
                // Around the grid only: the title, toolbar and search below stay on the page,
                // where they reach the navigation bar in every navigation style.
                .kyroLiveTVNavigation(navigation, active: .guide)
                #endif
                .liveTVPageBackground()
                .tint(LiveTVAccent.primaryText)
                .navigationTitle(selectedCategory ?? (favoritesOnly ? "Favorites" : "TV Guide"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                // A navigation-bar drawer can rebuild the two-axis guide while a query is being
                // edited. Keep search at a fixed height so the rows and scroll container remain
                // mounted and the time/channel offsets survive activation and dismissal.
                .safeAreaInset(edge: .top, spacing: 0) { mainSearchBar }
        }
    }

    /// The pushed Guide's search control stays at one height whether it is active or not. The
    /// navigation bar keeps its title and the category/favorite actions; search itself no longer
    /// changes the navigation-bar layout.
    private var mainSearchBar: some View {
        HStack(spacing: 8) {
            if isSearchPresented {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.siloSecondaryText)
                    TextField("Search channels", text: $searchText)
                        .focused($isCompactSearchFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .accessibilityIdentifier("liveTVGuideSearchField")
                    if !searchText.isEmpty {
                        Button {
                            clearSearchQuery()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.siloSecondaryText)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .font(.subheadline)
                .padding(.horizontal, 10)
                .frame(height: 44)
                .background(LiveTVSurface.row, in: Capsule())
                Button("Cancel") { closeSearch() }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("liveTVGuideSearchCancel")
            } else {
                Button { beginSearch() } label: {
                    Label("Search channels", systemImage: "magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(Color.siloSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(LiveTVSurface.row, in: Capsule())
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("liveTVGuideSearch")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(LiveTVSurface.canvas)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// The watch screen's one persistent control area. List/Grid moved into View so normal text
    /// sizes reclaim the former selector row. When labels do not fit, filters use two comfortable
    /// rows instead of compressing controls below their 44-point targets.
    private var compactBar: some View {
        Group {
            if isSearchPresented {
                HStack(spacing: 8) {
                    compactSearchField
                    Button("Cancel") { closeSearch() }
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("liveTVWatchGuideSearchCancel")
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    regularCompactControls
                    expandedCompactControls
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .frame(minHeight: 44)
        .background(LiveTVSurface.canvas)
        .overlay(alignment: .bottom) { Divider() }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isSearchPresented)
    }

    private var compactSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.siloSecondaryText)
            TextField("Search channels", text: $searchText)
                .focused($isCompactSearchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityIdentifier("liveTVWatchGuideSearchField")
            if !searchText.isEmpty {
                Button {
                    clearSearchQuery()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.siloSecondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.subheadline)
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(LiveTVSurface.row, in: Capsule())
    }

    private var regularCompactControls: some View {
        HStack(spacing: 8) {
            categoryControl
            favoritesControl
            Spacer(minLength: 0)
            guideViewMenu
            searchControl
            guidePositionControl
        }
    }

    private var expandedCompactControls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                categoryControl
                Spacer(minLength: 0)
                guideViewMenu
            }
            HStack(spacing: 8) {
                favoritesControl
                Spacer(minLength: 0)
                searchControl
                guidePositionControl
            }
        }
    }

    @ViewBuilder
    private var categoryControl: some View {
        if !service.categories.isEmpty {
            compactChip(title: selectedCategory ?? "All Categories",
                        symbol: "line.3.horizontal.decrease", isActive: selectedCategory != nil,
                        identifier: "liveTVWatchGuideCategory") {
                openCategoryPicker()
            }
            .accessibilityLabel(selectedCategory.map { "Category, \($0)" } ?? "Category, all")
            .accessibilityHint("Choose which channel category the guide shows")
        }
    }

    private var favoritesControl: some View {
        compactChip(title: "Favorites", symbol: favoritesOnly ? "star.fill" : "star",
                    isActive: favoritesOnly, identifier: "liveTVWatchGuideFavorites") {
            favoritesOnly.toggle()
        }
        .accessibilityLabel(favoritesOnly ? "Show all channels" : "Show favorite channels only")
        .accessibilityAddTraits(favoritesOnly ? .isSelected : [])
    }

    private var searchControl: some View {
        compactIconButton("magnifyingglass", label: "Search channels",
                          identifier: "liveTVWatchGuideSearch") {
            beginSearch()
        }
    }

    private var guideViewMenu: some View {
        Menu {
            Picker("Guide View", selection: Binding(
                get: { embeddedStyle },
                set: { selectGuideStyle($0) })) {
                    ForEach(LiveTVEmbeddedGuideStyle.allCases) { style in
                        Label(style.title, systemImage: style == .list ? "list.bullet" : "rectangle.grid.1x2")
                            .tag(style)
                    }
                }
        } label: {
            Label("View", systemImage: "rectangle.split.1x2")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.siloOnSurface)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(LiveTVSurface.row, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Guide view")
        .accessibilityValue(embeddedStyle.title)
        .accessibilityHint("Choose List or Grid")
        .accessibilityIdentifier("liveTVWatchGuideViewMenu")
    }

    @ViewBuilder
    private var guidePositionControl: some View {
        if embeddedStyle == .grid {
            Button("Now") { scrollToNow() }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 4)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityHint("Scrolls the grid to the current time")
                .accessibilityIdentifier("liveTVWatchGuideNow")
        } else {
            Button("Playing") { revealPlayingChannel() }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 4)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityHint("Reveals the playing channel when it is in these filters")
                .accessibilityIdentifier("liveTVWatchGuidePlaying")
        }
    }

    private func compactChip(title: String, symbol: String, isActive: Bool, identifier: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title).lineLimit(1)
            } icon: {
                Image(systemName: symbol)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(isActive ? Color.white : Color.siloOnSurface)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(isActive ? AnyShapeStyle(LiveTVAccent.primary) : AnyShapeStyle(LiveTVSurface.row), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func compactIconButton(_ symbol: String, label: String, identifier: String,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(width: 34, height: 34)
                .background(LiveTVSurface.row, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var content: some View {
        switch LiveTVGuideContentState.resolve(hasProviders: !service.providers.isEmpty, isLoading: service.isLoading,
                                               errorMessage: service.errorMessage, channelCount: service.selectedChannelCount,
                                               visibleCount: rows.count) {
        case .setup:
            ContentUnavailableView("Set Up Live TV", systemImage: "antenna.radiowaves.left.and.right",
                                   description: Text("Add a playlist in Live TV settings to see the guide."))
        case .loading:
            ProgressView("Loading channels…")
                .foregroundStyle(Color.siloSecondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t Load Channels", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await service.refreshSelectedProvider() } }
            }
        case .noChannels:
            ContentUnavailableView("No Channels", systemImage: "tv",
                                   description: Text("Refresh the playlist or check its settings."))
        case .noMatches:
            ZStack {
                // Keep a mounted view alive behind empty/search states so clearing a query
                // returns to the same place. The pushed guide only has the timeline.
                preservedGuide
                    .hidden()
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                if isSearchPending {
                    ProgressView("Searching channels…")
                        .foregroundStyle(Color.siloSecondaryText)
                } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView {
                        Label("No Channels Found", systemImage: "magnifyingglass")
                    } description: {
                        Text("Try a different name or category, or clear your search.")
                    } actions: {
                        Button("Clear Search") { clearSearchQuery() }
                    }
                } else {
                    ContentUnavailableView {
                        Label(favoritesOnly ? "No Favorites Here" : "No Channels", systemImage: favoritesOnly ? "star" : "tv")
                    } description: {
                        Text(favoritesOnly ? "Star channels in Live TV to see them in the guide."
                                           : "This category has no channels.")
                    } actions: {
                        Button("Show All Channels") {
                            favoritesOnly = false
                            selectedCategory = nil
                        }
                    }
                }
            }
        case .ready:
            VStack(spacing: 0) {
                if let banner = LiveTVGuideContentState.banner(errorMessage: service.errorMessage,
                                                               catalogNotice: service.catalogNotice,
                                                               guideMessage: service.guideMessage,
                                                               isGuideStale: service.isGuideStale,
                                                               isGuideLoading: service.isGuideLoading) {
                    let icon = service.errorMessage == nil && service.catalogNotice != nil
                        ? "info.circle" : "exclamationmark.circle"
                    Label(banner, systemImage: icon)
                        .font(.footnote)
                        .foregroundStyle(Color.siloSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(LiveTVSurface.row)
                }
                preservedGuide
            }
        }
    }

    /// The pushed guide is the timeline. The watch screen mounts only the selected representation.
    /// Keeping an invisible List and Grid alive doubled row layout and image work while playback
    /// and guide-residency updates were arriving. Their ScrollPosition values live in this parent,
    /// so switching remains stateful without rendering the hidden representation.
    @ViewBuilder
    private var preservedGuide: some View {
        if watch == nil {
            grid
        } else if embeddedStyle == .grid {
            grid
        } else {
            channelList
        }
    }

    /// Stores the view and mounts it. Category, favorites and search are not touched, and nothing
    /// is sent to the player.
    private func selectGuideStyle(_ style: LiveTVEmbeddedGuideStyle) {
        if style != embeddedStyle {
            perfMarks.styleSwitch = KyroPerformanceDiagnostics.begin("Guide style switch", .styleSwitch)
        }
        let next = LiveTVEmbeddedGuideBrowsing(
            style: embeddedStyle, category: selectedCategory, favoritesOnly: favoritesOnly, searchQuery: searchText
        ).selecting(style)
        embeddedGuideStyleRaw = next.style.rawValue
    }

    /// Vertical channels for the watch screen. Rows come from the same filtered catalog as the
    /// timeline, and a tap uses the same retune path.
    ///
    /// Each row's guide values come from `listEntries`, so a row the list has built this minute is
    /// a dictionary read. The playing row is revealed by scrolling to a point (see
    /// `LiveTVGuideListReveal`); Build 59's `ScrollViewReader.scrollTo(id)` built every row before
    /// it, and all 40,000 when the playing channel was not in the chosen category.
    private var channelList: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { channel in
                        let isPlaying = watch?.activeChannelID == channel.id
                        LiveTVEmbeddedGuideListRow(
                            channel: channel,
                            entry: listEntry(for: channel, now: now),
                            isPlaying: isPlaying,
                            isGuideLoading: service.isGuideLoading || service.isGuideChannelLoading(channel),
                            onTune: { tune(channel) }
                        )
                        .equatable()
                        .onAppear { loadMoreIfNeeded(after: channel) }
                        .background {
                            // Only the row being revealed measures itself, and only until it is centred.
                            if isPlaying, listReveal?.channelID == channel.id {
                                Color.clear.onGeometryChange(for: CGFloat.self) { proxy in
                                    proxy.frame(in: .named(Self.listContentSpace)).midY
                                } action: { midY in
                                    finishListReveal(channelID: channel.id, rowContentMidY: midY)
                                }
                            }
                        }
                    }
                }
                .coordinateSpace(name: Self.listContentSpace)
            }
            .scrollPosition($listPosition)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: LiveTVGuideListGeometry.self) { geometry in
                LiveTVGuideListGeometry(offsetY: geometry.contentOffset.y + geometry.contentInsets.top,
                                        contentHeight: geometry.contentSize.height,
                                        viewportHeight: geometry.containerSize.height)
            } action: { [listTracker] _, geometry in
                listTracker.offsetY = geometry.offsetY
                listTracker.contentHeight = geometry.contentHeight
                listTracker.viewportHeight = geometry.viewportHeight
            }
            .overlay {
                if isSearchPending {
                    ProgressView("Searching channels…")
                        .foregroundStyle(Color.siloSecondaryText)
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityLabel("Searching channels")
                }
            }
            .allowsHitTesting(!isSearchPending)
            .onAppear {
                markStyleSwitchFinished()
                requestListReveal(activeChannelID: watch?.activeChannelID)
            }
            .onChange(of: watch?.activeChannelID) { _, channelID in
                requestListReveal(activeChannelID: channelID)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("liveTVWatchGuideList")
    }

    private func listEntry(for channel: LiveTVChannel, now: Date) -> LiveTVEmbeddedGuideListEntry {
        KyroPerformanceDiagnostics.count(.listRowBuild)
        return listEntries.entry(for: channel, revision: service.guideRevision, isGuideStale: service.isGuideStale,
                                 now: now, channelRevision: service.guideChannelRevision(for: channel),
                                 cacheable: service.isGuideChannelSettled(channel)) {
            KyroPerformanceDiagnostics.count(.listEntryMiss)
            return LiveTVEmbeddedGuideListEntry.make(
                channel: channel,
                programs: service.guidePrograms(
                    for: channel,
                    overlapping: DateInterval(start: now, duration: LiveTVEmbeddedGuideListEntry.lookahead)),
                fallback: service.programPair(for: channel, at: now),
                now: now)
        }
    }

    /// Scrolls the playing channel's row near the middle when it is in the list. A channel this
    /// list tuned is already on screen, and one outside the current filters is not searched for.
    private func requestListReveal(activeChannelID: String?, force: Bool = false) {
        guard let activeChannelID, force || activeChannelID != tunedFromGuideID,
              let index = rows.firstIndex(where: { $0.id == activeChannelID }) else {
            listReveal = nil
            return
        }
        perfMarks.listReveal = KyroPerformanceDiagnostics.begin("Guide list reveal", .listReveal)
        listReveal = LiveTVGuideListRevealRequest(channelID: activeChannelID, attempt: 0)
        scrollListTowardReveal(index: index)
    }

    private func scrollListTowardReveal(index: Int) {
        // One turn later the list has its first geometry (content height and viewport).
        Task { @MainActor in
            await Task.yield()
            guard var request = listReveal, rows.indices.contains(index), rows[index].id == request.channelID else { return }
            listPosition.scrollTo(y: LiveTVGuideListReveal.estimatedOffset(
                index: index, rowCount: rows.count, contentHeight: listTracker.contentHeight,
                viewportHeight: listTracker.viewportHeight))
            request.attempt += 1
            listReveal = request
            // The lazy stack refines its height estimate once rows near the target are measured.
            // If the row has not reported its frame by then, estimate again from the new height.
            try? await Task.sleep(for: .milliseconds(150))
            guard let pending = listReveal, pending.channelID == request.channelID,
                  pending.attempt < LiveTVGuideListReveal.maximumAttempts else { return }
            scrollListTowardReveal(index: index)
        }
    }

    private static let listContentSpace = "liveTVWatchGuideListContent"

    private func finishListReveal(channelID: String, rowContentMidY: CGFloat) {
        guard listReveal?.channelID == channelID else { return }
        listReveal = nil
        if let offset = LiveTVGuideListReveal.correctedOffset(rowContentMidY: rowContentMidY, currentOffset: listTracker.offsetY,
                                                              contentHeight: listTracker.contentHeight,
                                                              viewportHeight: listTracker.viewportHeight) {
            listPosition.scrollTo(y: offset)
        }
        KyroPerformanceDiagnostics.end(perfMarks.listReveal)
        perfMarks.listReveal = nil
    }

    private func markStyleSwitchFinished() {
        KyroPerformanceDiagnostics.end(perfMarks.styleSwitch)
        perfMarks.styleSwitch = nil
    }

    private var grid: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(rows) { channel in
                            let _ = KyroPerformanceDiagnostics.count(.gridRowBuild)
                            LiveTVGuideRow(
                                channel: channel,
                                cells: cells.cells(for: channel, revision: service.guideRevision,
                                                   isGuideStale: service.isGuideStale, timeline: timeline,
                                                   channelRevision: service.guideChannelRevision(for: channel),
                                                   cacheable: service.isGuideChannelSettled(channel)) {
                                    service.guidePrograms(for: channel, overlapping: timeline.interval)
                                },
                                timeline: timeline,
                                span: span,
                                now: now,
                                isFavorite: service.isFavorite(channel),
                                isPlaying: watch?.activeChannelID == channel.id,
                                isGuideLoading: service.isGuideLoading || service.isGuideChannelLoading(channel),
                                metrics: metrics,
                                onTuneChannel: { tune(channel) },
                                onToggleFavorite: { service.toggleFavorite(channel) },
                                onSelect: { select($0, on: channel, at: now) }
                            )
                            .equatable()
                            .onAppear { loadMoreIfNeeded(after: channel) }
                        }
                    } header: {
                        LiveTVGuideTimeHeader(timeline: timeline, now: now, metrics: metrics)
                    }
                }
            }
            .scrollPosition($position)
            .scrollIndicators(.hidden)
            // Only whole-hour crossings change `span`, so scrolling itself does not update view state.
            .onScrollGeometryChange(for: LiveTVGuideVisibleSpan.self) { [bucketWidth = timeline.pointsPerMinute * 60] geometry in
                LiveTVGuideVisibleSpan(offsetX: geometry.contentOffset.x, viewportWidth: geometry.containerSize.width,
                                       bucketWidth: bucketWidth)
            } action: { _, newValue in
                span = newValue
            }
            .onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { [scrollTracker] _, offset in
                scrollTracker.offset = offset
            }
            .onAppear {
                markStyleSwitchFinished()
                guard !hasScrolledToNow else { return }
                hasScrolledToNow = true
                if pendingReveal != nil { return }
                if browsingRestoration.pendingContext?.offsetX != nil || browsingRestoration.pendingContext?.channelID != nil { return }
                position.scrollTo(x: timeline.scrollOffset(showing: now))
            }
            .onChange(of: now) {
                if timeline.needsRebuild(at: now) { rebuildTimeline(at: now) }
            }
            .overlay {
                if isSearchPending {
                    ProgressView("Searching channels…")
                        .foregroundStyle(Color.siloSecondaryText)
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityLabel("Searching channels")
                }
            }
            .allowsHitTesting(!isSearchPending)
        }
    }

    /// No leading item: the Guide is pushed, so the system Back (and the edge
    /// swipe) is its one way back to the Live TV screen it was opened from.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Now") { scrollToNow() }
            .accessibilityHint("Scrolls the guide to the current time")
            Button {
                favoritesOnly.toggle()
            } label: {
                Image(systemName: favoritesOnly ? "star.fill" : "star")
            }
            .accessibilityLabel(favoritesOnly ? "Show all channels" : "Show favorites only")
            if !service.categories.isEmpty {
                Button {
                    openCategoryPicker()
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle\(selectedCategory == nil ? "" : ".fill")")
                }
                .accessibilityLabel("Filter by category")
                .accessibilityHint("Choose which channel category the guide shows")
            }
        }
    }

    private var categoryPresentation: LiveTVCategoryNavigation.Presentation {
        LiveTVCategoryNavigation.guidePresentation(isWatchGuide: watch != nil)
    }

    private var categoryPushBinding: Binding<Bool> {
        Binding(get: { isShowingCategoryPicker && categoryPresentation == .push }, set: { if !$0 { isShowingCategoryPicker = false } })
    }

    private var categorySheetBinding: Binding<Bool> {
        Binding(get: { isShowingCategoryPicker && categoryPresentation == .fullHeightSheet }, set: { if !$0 { isShowingCategoryPicker = false } })
    }

    /// Only the chosen category reaches the Guide; scrolling the page writes no Guide state.
    private var categoryPicker: some View {
        LiveTVCategoryBrowserPage(
            providerID: service.selectedProviderID,
            title: "Categories",
            allTitle: "All Categories",
            mode: .filter(selected: selectedCategory),
            categories: service.categories,
            channels: service.channels,
            favoriteIDs: service.favoriteChannelIDs,
            catalogRevision: service.channelCatalogRevision,
            indexedDirectory: liveTVIndexedCategoryDirectory(service: service),
            initialPosition: categoryPickerPosition,
            select: { choice in
                selectedCategory = LiveTVCategoryNavigation.filterSelection(for: choice)
                isShowingCategoryPicker = false
            },
            rememberPosition: { position in
                categoryPickerPosition = position
                rememberCategoryPickerPosition()
            },
            cancel: categoryPresentation == .push ? nil : { isShowingCategoryPicker = false })
    }

    private func openCategoryPicker() {
        guard let providerID = service.selectedProviderID else { return }
        categoryPickerPosition = categoryPickerState.target(
            providerID: providerID, selectedCategory: selectedCategory, categories: service.categories)
        isShowingCategoryPicker = true
    }

    private func scrollToNow() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            position.scrollTo(x: timeline.scrollOffset(showing: .now))
        }
    }

    private func revealPlayingChannel() {
        requestListReveal(activeChannelID: watch?.activeChannelID, force: true)
    }

    private func rememberCategoryPickerPosition() {
        guard let providerID = service.selectedProviderID else { return }
        categoryPickerState.remember(categoryPickerPosition, providerID: providerID, categories: service.categories)
    }

    private func select(_ program: EPGProgram, on channel: LiveTVChannel, at now: Date) {
        switch LiveTVGuideAction(program, at: now) {
        case .tune: tune(channel)
        case .showDetails: detail = LiveTVGuideDetail(channel: channel, program: program)
        }
    }

    private func tunePending() {
        guard let channel = pendingTune else { return }
        pendingTune = nil
        tune(channel)
    }

    private func tune(_ channel: LiveTVChannel) {
        if let watch {
            tunedFromGuideID = channel.id
            watch.tune(channel)
        } else {
            // The watch screen's Guide tab opens on these filters and this time position.
            service.guideWatchHandoff = service.selectedProviderID.map {
                LiveTVGuideWatchHandoff(providerID: $0, category: selectedCategory, favoritesOnly: favoritesOnly,
                                        searchQuery: searchText,
                                        offsetX: scrollTracker.offset.x > 0 ? Double(scrollTracker.offset.x) : nil)
            }
            service.choose(channel, from: .guide)
        }
    }

    private func rebuildRows() {
        if let selectedCategory, let providerID = service.selectedProviderID, service.hasCatalog(for: providerID),
           !service.categories.contains(selectedCategory) { self.selectedCategory = nil }
        updateSearch()
    }

    private func updateSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchGeneration += 1
        let generation = searchGeneration
        let providerID = service.selectedProviderID
        let catalogRevision = service.channelCatalogRevision
        let category = selectedCategory
        let favoriteFilter = favoritesOnly
        let favoriteIDs = service.favoriteChannelIDs
        // Keep the previous rows mounted while the detached search runs. Replacing them with an
        // empty state would make SwiftUI tear down the visible guide and lose its two-axis
        // ScrollPosition. The pending overlay communicates that results are not final yet.
        isSearchPending = true
        #if os(iOS)
        pagedChannels.reset(service: service, providerID: providerID, catalogRevision: catalogRevision,
                            query: query, category: category, favoritesOnly: favoriteFilter)
        #else
        searchModel.update(channels: service.channels, query: query, category: category,
                           favoritesOnly: favoriteFilter, favoriteIDs: favoriteIDs, includeGroups: false)
        #endif
        Task { @MainActor in
            #if os(iOS)
            await pagedChannels.waitForCurrentQuery()
            if let channelID = browsingRestoration.pendingContext?.channelID {
                _ = await pagedChannels.restoreAnchor(channelID: channelID, service: service)
            }
            #else
            await searchModel.waitForCurrentSearch()
            #endif
            guard generation == searchGeneration, query == searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                  let providerID, providerID == service.selectedProviderID,
                  catalogRevision == service.channelCatalogRevision,
                  category == selectedCategory, favoriteFilter == favoritesOnly,
                  favoriteIDs == service.favoriteChannelIDs else { return }
            #if os(iOS)
            rows = pagedChannels.channels
            #else
            rows = searchModel.matches
            #endif
            isSearchPending = false
            KyroPerformanceDiagnostics.end(perfMarks.categoryChange)
            perfMarks.categoryChange = nil
            if watch != nil {
                revealActiveChannelIfNeeded()
            } else {
                restoreGuidePositionIfNeeded(providerID: providerID, context: browsingRestoration.pendingContext)
            }
        }
    }

    private func beginSearch() {
        if !isSearchPresented {
            searchRestoration = LiveTVGuideSearchRestoration(
                category: selectedCategory, favoritesOnly: favoritesOnly,
                offsetX: Double(scrollTracker.offset.x), offsetY: Double(scrollTracker.offset.y),
                query: searchText)
        }
        isSearchPresented = true
        isCompactSearchFocused = true
    }

    private func clearSearchQuery() {
        suppressNextSearchUpdate = !searchText.isEmpty
        searchText = ""
        restoreSearchContext()
    }

    private func closeSearch() {
        clearSearchQuery()
        isSearchPresented = false
        dismissSearchInput()
    }

    private func restoreSearchContext() {
        let restoration = searchRestoration
        searchRestoration = nil
        searchGeneration += 1
        searchModel.cancel()
        #if os(iOS)
        pagedChannels.cancel()
        #endif
        isSearchPending = false
        if let restoration {
            selectedCategory = restoration.category
            favoritesOnly = restoration.favoritesOnly
        }
        let filters = restoration?.dismissedFilters ?? .channels
        #if os(iOS)
        searchGeneration += 1
        let generation = searchGeneration
        pagedChannels.reset(service: service, providerID: service.selectedProviderID,
                            catalogRevision: service.channelCatalogRevision,
                            query: filters.query, category: filters.category,
                            favoritesOnly: filters.favoritesOnly)
        Task { @MainActor in
            await pagedChannels.waitForCurrentQuery()
            guard generation == searchGeneration else { return }
            rows = pagedChannels.channels
            if let restoration {
                position.scrollTo(x: CGFloat(restoration.offsetX), y: CGFloat(restoration.offsetY))
            }
        }
        #else
        rows = LiveTVChannelFiltering.filter(service.channels, query: filters.query,
                                             category: filters.category, favoritesOnly: filters.favoritesOnly,
                                             favoriteIDs: service.favoriteChannelIDs)
        if let restoration {
            position.scrollTo(x: CGFloat(restoration.offsetX), y: CGFloat(restoration.offsetY))
        }
        #endif
    }

    private func loadMoreIfNeeded(after channel: LiveTVChannel) {
        #if os(iOS)
        guard rows.first?.id == channel.id || rows.last?.id == channel.id else { return }
        pagedChannels.loadPageIfNeeded(around: channel, service: service)
        Task { @MainActor in
            await pagedChannels.waitForCurrentQuery()
            guard service.selectedProviderID != nil else { return }
            rows = pagedChannels.channels
        }
        #endif
    }

    private func dismissSearchInput() {
        isCompactSearchFocused = false
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil,
                                        from: nil, for: nil)
        #endif
    }

    private func restoreBrowsingContext(for providerID: UUID?) {
        guard let providerID, restoredContextProviderID != providerID else { return }
        if watch != nil { return applyWatchHandoff(for: providerID) }
        restoredContextProviderID = providerID
        selectedCategory = nil
        favoritesOnly = false
        searchText = ""
        isSearchPresented = false
        position = ScrollPosition(idType: String.self)
        hasScrolledToNow = false
        let context = LiveTVBrowsingContextCollection.decoded(savedBrowsingContext)?.context(for: providerID)
        browsingRestoration.begin(context: context, providerID: providerID)
        if let context = browsingRestoration.pendingContext {
            selectedCategory = context.category
            favoritesOnly = context.favoritesOnly
            searchText = context.searchQuery
        }
        reconcileBrowsingContext()
    }

    /// The watch screen's Guide tab opens on the pushed guide's filters and time position, not on
    /// the scene's saved context, and then reveals the playing channel's row.
    private func applyWatchHandoff(for providerID: UUID) {
        restoredContextProviderID = providerID
        browsingRestoration.begin(context: nil, providerID: providerID)
        let handoff = service.guideWatchHandoff
        let filters = handoff?.filters(for: providerID, categories: service.categories) ?? LiveTVBrowserFilters()
        selectedCategory = filters.category
        favoritesOnly = filters.favoritesOnly
        searchText = filters.query
        isSearchPresented = !filters.query.isEmpty
        position = ScrollPosition(idType: String.self)
        hasScrolledToNow = false
        pendingReveal = LiveTVGuideReveal(offsetX: handoff?.providerID == providerID ? handoff?.offsetX : nil)
    }

    /// Scrolls the playing channel's row into view once the rows that list it exist. One scroll
    /// call sets both axes: a second call would replace the first target rather than add to it.
    private func revealActiveChannelIfNeeded() {
        guard let reveal = pendingReveal, !rows.isEmpty else { return }
        pendingReveal = nil
        let x = reveal.offsetX.map { CGFloat($0) } ?? timeline.scrollOffset(showing: .now)
        if let y = LiveTVGuideWatchHandoff.revealOffsetY(channelID: watch?.activeChannelID, rowIDs: rows.map(\.id),
                                                         rowHeight: Double(metrics.rowHeight)) {
            position.scrollTo(x: x, y: CGFloat(y))
        } else {
            position.scrollTo(x: x)
        }
    }

    private func reconcileBrowsingContext() {
        guard let providerID = service.selectedProviderID,
              let pending = browsingRestoration.pendingContext else { return }
        #if os(iOS)
        let valid = pending.validatedWhenReady(selectedProviderID: providerID,
                                               catalogIsLoaded: service.hasCatalog(for: providerID),
                                               categories: service.categories, channels: nil)
        #else
        let valid = pending.validatedWhenReady(selectedProviderID: providerID,
                                               catalogIsLoaded: service.hasCatalog(for: providerID),
                                               categories: service.categories, channels: service.channels)
        #endif
        guard let valid else { return }
        browsingRestoration.updatePendingContext(valid)
        if selectedCategory != valid.category { selectedCategory = valid.category }
    }

    private func restoreGuidePositionIfNeeded(providerID: UUID, context: LiveTVBrowsingContext?) {
        guard service.hasCatalog(for: providerID), let context, context.providerID == providerID,
              browsingRestoration.pendingContext == context else { return }
        if let channelID = context.channelID,
           let y = LiveTVGuideWatchHandoff.revealOffsetY(channelID: channelID, rowIDs: rows.map(\.id),
                                                         rowHeight: Double(metrics.rowHeight), contextRows: 0) {
            // One call for both axes: scrolling to the row and then to x would keep only x.
            position.scrollTo(x: CGFloat(context.offsetX ?? Double(timeline.scrollOffset(showing: .now))), y: CGFloat(y))
        } else if let offsetX = context.offsetX, let offsetY = context.offsetY {
            position.scrollTo(x: offsetX, y: offsetY)
        } else {
            position.scrollTo(x: timeline.scrollOffset(showing: .now))
        }
        browsingRestoration.complete(context: context)
    }

    private func saveBrowsingContext() {
        saveBrowsingContext(for: service.selectedProviderID)
    }

    private func saveBrowsingContext(for providerID: UUID?) {
        // The watch screen's guide borrows the pushed guide's context; it never replaces it.
        guard watch == nil, let providerID else { return }
        let point = position.point
        let current = LiveTVBrowsingContext(providerID: providerID, category: selectedCategory,
                                            favoritesOnly: favoritesOnly, searchQuery: searchText,
                                            channelID: position.viewID(type: String.self),
                                            offsetX: point.map { Double($0.x) }, offsetY: point.map { Double($0.y) })
        guard let context = browsingRestoration.contextToSave(providerID: providerID,
                                                               restoredProviderID: restoredContextProviderID,
                                                               current: current) else { return }
        let collection = LiveTVBrowsingContextCollection.decoded(savedBrowsingContext) ?? LiveTVBrowsingContextCollection()
        if let encoded = collection.replacing(context).encoded() { savedBrowsingContext = encoded }
    }

    private func rebuildTimeline(at now: Date) {
        timeline = LiveTVGuideTimeline(now: now, timeZone: timeZone)
        position.scrollTo(x: timeline.scrollOffset(showing: now))
    }
}

/// Programme cells per channel for the current guide revision and window, built once per row.
/// Not observed: it only memoizes values derived from observed service state.
@MainActor
final class LiveTVGuideCellCache {
    /// A portrait iPhone 16 Plus shows roughly thirteen 64-point rows. Keeping seven
    /// viewportfuls preserves nearby backtracking without retaining every row visited.
    static let capacity = 96

    private struct Key: Equatable {
        let revision: Int
        let isGuideStale: Bool
        let timeline: LiveTVGuideTimeline
    }

    private struct Entry {
        let cells: [LiveTVGuideCell]
        let channelRevision: Int
    }

    private var key: Key?
    private var storage: [String: Entry] = [:]
    /// Most-recently-used channel IDs first. The cache is intentionally small, so an array keeps
    /// bookkeeping cheaper and more predictable than a linked-list allocation per row.
    private var recency: [String] = []

    private(set) var hitCount = 0
    private(set) var missCount = 0
    private(set) var evictionCount = 0
    private(set) var targetedInvalidationCount = 0
    private(set) var globalInvalidationCount = 0

    var entryCount: Int { storage.count }

    /// `cacheable`: false while the channel's listings could still arrive (Build 61). Such cells are
    /// built on every read and never stored, so the row asks for its listings again.
    func cells(for channel: LiveTVChannel, revision: Int, isGuideStale: Bool, timeline: LiveTVGuideTimeline,
               channelRevision: Int = 0, cacheable: Bool = true,
               programs: () -> [EPGProgram]) -> [LiveTVGuideCell] {
        let key = Key(revision: revision, isGuideStale: isGuideStale, timeline: timeline)
        if key != self.key {
            if self.key != nil { globalInvalidationCount += 1 }
            self.key = key
            storage.removeAll(keepingCapacity: true)
            recency.removeAll(keepingCapacity: true)
        }
        if cacheable, let cached = storage[channel.id], cached.channelRevision == channelRevision {
            hitCount += 1
            touch(channel.id)
            return cached.cells
        }
        if storage[channel.id] != nil { targetedInvalidationCount += 1 }
        missCount += 1
        let built = LiveTVGuideCell.cells(for: programs(), in: timeline)
        guard cacheable else {
            if storage.removeValue(forKey: channel.id) != nil, let index = recency.firstIndex(of: channel.id) {
                recency.remove(at: index)
            }
            return built
        }
        storage[channel.id] = Entry(cells: built, channelRevision: channelRevision)
        touch(channel.id)
        if storage.count > Self.capacity, let evicted = recency.popLast() {
            storage.removeValue(forKey: evicted)
            evictionCount += 1
        }
        return built
    }

    private func touch(_ channelID: String) {
        if let index = recency.firstIndex(of: channelID) { recency.remove(at: index) }
        recency.insert(channelID, at: 0)
    }
}

/// The watch screen's hold on its Guide tab: which channel is playing, and how a tap retunes it.
struct LiveTVGuideWatchContext {
    let activeChannelID: String?
    let tune: (LiveTVChannel) -> Void
}

/// A pending scroll that brings the playing channel's row into view at a time offset.
struct LiveTVGuideReveal: Equatable {
    /// Nil shows the current time.
    let offsetX: Double?
}

/// Open diagnostics intervals for the guide. A plain reference: recording one never redraws.
final class LiveTVGuidePerformanceMarks {
    var styleSwitch: KyroPerformanceInterval?
    var categoryChange: KyroPerformanceInterval?
    var listReveal: KyroPerformanceInterval?
}

struct LiveTVGuideListGeometry: Equatable {
    let offsetY: CGFloat
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
}

/// The guide's live content offset. A plain reference, so writing it while scrolling does not
/// re-render the grid; it is read only when the guide hands its position on.
final class LiveTVGuideScrollTracker {
    var offset: CGPoint = .zero
}

struct LiveTVGuideDetail: Identifiable {
    let channel: LiveTVChannel
    let program: EPGProgram
    var id: String { "\(channel.id)|\(program.id)" }
}

/// Guide geometry. The pushed guide uses `regular`; the watch screen's Guide tab, which shares the
/// screen with the player above it, uses `compact` so more channels fit beneath the video.
struct LiveTVGuideMetrics: Equatable, Sendable {
    let channelColumnWidth: CGFloat
    let rowHeight: CGFloat
    let headerHeight: CGFloat
    let logoSize: CGSize

    static let regular = Self(channelColumnWidth: 116, rowHeight: 64, headerHeight: 36,
                              logoSize: CGSize(width: 36, height: 30))
    static let compact = Self(channelColumnWidth: 100, rowHeight: 54, headerHeight: 28,
                              logoSize: CGSize(width: 30, height: 24))

    static func forWatchScreen(_ isWatchScreen: Bool) -> Self { isWatchScreen ? .compact : .regular }
}

private extension View {
    /// Keeps the view at the scroll view's leading edge plus `inset`, moving at most `maximum`.
    func pinnedToScrollLeading(inset: CGFloat = 0, maximum: CGFloat = .greatestFiniteMagnitude) -> some View {
        visualEffect { content, proxy in
            content.offset(x: min(max(0, inset - proxy.frame(in: .scrollView).minX), max(0, maximum)))
        }
    }
}

private struct LiveTVGuideTimeHeader: View {
    let timeline: LiveTVGuideTimeline
    let now: Date
    let metrics: LiveTVGuideMetrics

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(timeline.ticks) { tick in
                    let x = timeline.x(for: tick.date)
                    Rectangle()
                        .fill(Color.siloSecondaryText.opacity(tick.isHour ? 0.35 : 0.18))
                        .frame(width: 1, height: tick.isHour ? 12 : 7)
                        .offset(x: x, y: metrics.headerHeight - (tick.isHour ? 12 : 7))
                    Text(tick.date, format: .dateTime.hour().minute())
                        .font(.caption.weight(tick.isHour ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(tick.isHour ? Color.siloOnSurface : Color.siloSecondaryText)
                        .fixedSize()
                        .offset(x: x + 5, y: (metrics.headerHeight - 18) / 2)
                }
                Capsule()
                    .fill(LiveTVAccent.primaryText)
                    .frame(width: 8, height: 8)
                    .offset(x: timeline.x(for: now) - 4, y: metrics.headerHeight - 8)
                    .accessibilityHidden(true)
            }
            .frame(width: timeline.width, height: metrics.headerHeight, alignment: .topLeading)
            .padding(.leading, metrics.channelColumnWidth)

            Text(now, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                .font(.caption.weight(.semibold))
                .foregroundStyle(LiveTVAccent.primaryText)
                .frame(width: metrics.channelColumnWidth, height: metrics.headerHeight)
                .background(LiveTVSurface.canvas)
                .pinnedToScrollLeading()
                .zIndex(1)
        }
        .background(LiveTVSurface.canvas)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline")
    }
}

/// One channel in the watch screen's list: logo, full name, what is on, how far through it,
/// and the next listing. The whole row retunes the watch screen's session.
private struct LiveTVEmbeddedGuideListRow: View, Equatable {
    let channel: LiveTVChannel
    let entry: LiveTVEmbeddedGuideListEntry
    let isPlaying: Bool
    let isGuideLoading: Bool
    let onTune: () -> Void

    /// `onTune` is left out: it always tunes this row's channel through the same guide.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.channel == rhs.channel && lhs.entry == rhs.entry && lhs.isPlaying == rhs.isPlaying
            && lhs.isGuideLoading == rhs.isGuideLoading
    }

    var body: some View {
        Button(action: onTune) {
            HStack(alignment: .top, spacing: 10) {
                LiveTVChannelLogo(channel: channel, size: CGSize(width: 44, height: 36))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isPlaying ? LiveTVAccent.primaryText : Color.siloOnSurface)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let title = entry.currentTitle {
                        Text(title)
                            .font(.footnote)
                            .foregroundStyle(Color.siloOnSurface)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        progress
                    } else {
                        Text(isGuideLoading ? "Loading guide…" : "No guide information")
                            .font(.footnote)
                            .foregroundStyle(Color.siloSecondaryText)
                    }
                    if let upcoming = entry.upcomingTitle {
                        Text(upcomingLabel(upcoming))
                            .font(.caption)
                            .foregroundStyle(Color.siloSecondaryText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background { if isPlaying { LiveTVAccent.primary.opacity(0.16) } }
            .overlay(alignment: .leading) {
                if isPlaying { Rectangle().fill(LiveTVAccent.primaryText).frame(width: 3) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Divider().opacity(0.45) }
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Plays this channel")
        .accessibilityAddTraits(isPlaying ? .isSelected : [])
        .accessibilityIdentifier("liveTVWatchGuideListRow.\(channel.id)")
    }

    private var progress: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(LiveTVAccent.primaryText)
                    .frame(width: max(4, proxy.size.width * (entry.progress ?? 0)))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }

    private func upcomingLabel(_ title: String) -> String {
        guard let start = entry.upcomingStart else { return "Up next · \(title)" }
        return "Up next · \(start.formatted(date: .omitted, time: .shortened)) \(title)"
    }

    private var accessibilityText: String {
        var parts = [isPlaying ? "\(channel.name), playing now" : channel.name]
        if let title = entry.currentTitle { parts.append(title) }
        if let upcoming = entry.upcomingTitle { parts.append("Up next, \(upcoming)") }
        return parts.joined(separator: ", ")
    }
}

private struct LiveTVGuideRow: View, Equatable {
    let channel: LiveTVChannel
    let cells: [LiveTVGuideCell]
    let timeline: LiveTVGuideTimeline
    let span: LiveTVGuideVisibleSpan
    let now: Date
    let isFavorite: Bool
    /// The watch screen's guide marks the channel its player is showing.
    let isPlaying: Bool
    let isGuideLoading: Bool
    let metrics: LiveTVGuideMetrics
    let onTuneChannel: () -> Void
    let onToggleFavorite: () -> Void
    let onSelect: (EPGProgram) -> Void

    /// The closures are left out: they always act on this row's channel through the same guide.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.channel == rhs.channel && lhs.cells == rhs.cells && lhs.timeline == rhs.timeline
            && lhs.span == rhs.span && lhs.now == rhs.now && lhs.isFavorite == rhs.isFavorite
            && lhs.isPlaying == rhs.isPlaying && lhs.isGuideLoading == rhs.isGuideLoading
            && lhs.metrics == rhs.metrics
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                if cells.isEmpty {
                    Text(isGuideLoading ? "Loading guide…" : "No guide information")
                        .font(.footnote)
                        .foregroundStyle(Color.siloSecondaryText)
                        .padding(.horizontal, 12)
                        .frame(height: metrics.rowHeight)
                        .pinnedToScrollLeading(inset: metrics.channelColumnWidth)
                } else {
                    ForEach(cells.filter(span.renders)) { cell in
                        LiveTVGuideProgramCell(cell: cell, now: now, pinsTitle: span.pinsTitle(of: cell),
                                               metrics: metrics) {
                            onSelect(cell.program)
                        }
                        .frame(width: cell.width, height: metrics.rowHeight)
                        .offset(x: cell.x)
                    }
                }
                Rectangle()
                    .fill(LiveTVAccent.primaryText)
                    .frame(width: 2, height: metrics.rowHeight)
                    .offset(x: timeline.x(for: now) - 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(width: timeline.width, height: metrics.rowHeight, alignment: .topLeading)
            .padding(.leading, metrics.channelColumnWidth)

            channelCell
                .pinnedToScrollLeading()
                .zIndex(1)
        }
        // The playing channel's whole row carries a faint accent wash, so it reads as current at a
        // glance even when its channel cell is scrolled past the programme the eye is on.
        .background { if isPlaying { LiveTVAccent.primary.opacity(0.12) } }
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private var channelCell: some View {
        Button(action: onTuneChannel) {
            HStack(spacing: 8) {
                LiveTVChannelLogo(channel: channel, size: metrics.logoSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isPlaying ? LiveTVAccent.primaryText : Color.siloOnSurface)
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        if isPlaying {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundStyle(LiveTVAccent.primaryText)
                        }
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .foregroundStyle(LiveTVAccent.ember)
                        }
                    }
                    .font(.caption2)
                    .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(width: metrics.channelColumnWidth, height: metrics.rowHeight)
            .background {
                // The cell is opaque (programmes scroll under it), so the playing tint sits on top.
                ZStack {
                    LiveTVSurface.row
                    if isPlaying { LiveTVAccent.primary.opacity(0.22) }
                }
            }
            .overlay(alignment: .leading) {
                if isPlaying {
                    Rectangle().fill(LiveTVAccent.primaryText).frame(width: 3)
                }
            }
            .overlay(alignment: .trailing) { Divider() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onTuneChannel) {
                Label(isPlaying ? "Playing Now" : "Watch", systemImage: isPlaying ? "speaker.wave.2.fill" : "play.fill")
            }
            Button(action: onToggleFavorite) {
                Label(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.slash" : "star")
            }
        }
        .accessibilityLabel(isPlaying ? "\(channel.name), playing now" : "Watch \(channel.name)")
        .accessibilityHint(isFavorite ? "Favorite channel" : "")
        .accessibilityAddTraits(isPlaying ? .isSelected : [])
    }
}

private struct LiveTVGuideProgramCell: View {
    let cell: LiveTVGuideCell
    let now: Date
    /// Only a programme that can straddle the viewport's leading edge needs its title to slide;
    /// every other cell skips the per-frame scroll-geometry effect.
    let pinsTitle: Bool
    let metrics: LiveTVGuideMetrics
    let action: () -> Void

    private var state: LiveTVGuideProgramState { LiveTVGuideProgramState(cell.program, at: now) }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(background)
                if state == .current {
                    progress
                }
                if cell.width >= 28 {
                    titleBlock
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                if state == .current {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(LiveTVAccent.primaryText.opacity(0.7), lineWidth: 1)
                }
            }
            .padding(2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(state == .current ? "Plays this channel" : "Shows program details")
    }

    @ViewBuilder
    private var titleBlock: some View {
        if pinsTitle {
            titleText.pinnedToScrollLeading(inset: metrics.channelColumnWidth, maximum: cell.width - 96)
        } else {
            titleText
        }
    }

    private var titleText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(cell.program.title)
                .font(.subheadline.weight(state == .current ? .semibold : .regular))
                .foregroundStyle(state == .past ? Color.siloSecondaryText : Color.siloOnSurface)
            Text("\(cell.program.start, format: .dateTime.hour().minute()) – \(cell.program.end, format: .dateTime.hour().minute())")
        }
        .font(.caption2)
        .monospacedDigit()
        .foregroundStyle(Color.siloSecondaryText)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var background: Color {
        switch state {
        case .past: LiveTVSurface.pastProgram
        case .current: LiveTVAccent.primary.opacity(0.34)
        case .upcoming: LiveTVSurface.upcomingProgram
        }
    }

    private var progress: some View {
        GeometryReader { proxy in
            let total = cell.program.end.timeIntervalSince(cell.program.start)
            let elapsed = now.timeIntervalSince(cell.program.start)
            Capsule()
                .fill(LiveTVAccent.primaryText)
                .frame(width: proxy.size.width * CGFloat(min(max(elapsed / max(total, 1), 0), 1)), height: 3)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 3)
        .allowsHitTesting(false)
    }

    private var accessibilityText: String {
        let status = switch state {
        case .past: "Ended"
        case .current: "On now"
        case .upcoming: "Upcoming"
        }
        let start = cell.program.start.formatted(date: .omitted, time: .shortened)
        let end = cell.program.end.formatted(date: .omitted, time: .shortened)
        return "\(cell.program.title), \(start) to \(end), \(status)"
    }
}

/// Details for a programme that is not airing. Watching is an explicit choice, never automatic.
struct LiveTVProgramDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let detail: LiveTVGuideDetail
    let onWatch: () -> Void

    var body: some View {
        NavigationStack {
            TimelineView(.everyMinute) { context in
                let state = LiveTVGuideProgramState(detail.program, at: context.date)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            LiveTVChannelLogo(channel: detail.channel, size: CGSize(width: 44, height: 36))
                            Text(detail.channel.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.siloSecondaryText)
                        }
                        Text(detail.program.title)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Color.siloOnSurface)
                        if let subtitle = detail.program.subtitle {
                            Text(subtitle).font(.headline).foregroundStyle(Color.siloOnSurface)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(detail.program.start, format: .dateTime.weekday(.wide).day().month(.wide))
                            Text("\(detail.program.start, format: .dateTime.hour().minute()) – \(detail.program.end, format: .dateTime.hour().minute())")
                            Text(statusText(state, now: context.date))
                                .foregroundStyle(LiveTVAccent.primaryText)
                        }
                        .font(.subheadline)
                        .foregroundStyle(Color.siloSecondaryText)
                        let tags = [detail.program.episode, detail.program.category].compactMap { $0 }
                        if !tags.isEmpty {
                            HStack(spacing: 8) {
                                ForEach(tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.siloSurfaceElevated, in: Capsule())
                                }
                            }
                        }
                        if let summary = detail.program.summary {
                            Text(summary).font(.body).foregroundStyle(Color.siloOnSurface)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
                .safeAreaInset(edge: .bottom) {
                    Button(action: onWatch) {
                        Label(state == .current ? "Watch Now" : "Watch \(detail.channel.name) Now", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LiveTVAccent.primary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }
            }
            .background(Color.siloBackground)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .tint(LiveTVAccent.primaryText)
    }

    private func statusText(_ state: LiveTVGuideProgramState, now: Date) -> String {
        switch state {
        case .past: return "Ended"
        case .current: return "On now"
        case .upcoming:
            let minutes = Int((detail.program.start.timeIntervalSince(now) / 60).rounded(.up))
            if minutes < 60 { return "Starts in \(minutes) min" }
            return "Starts \(detail.program.start.formatted(.relative(presentation: .named)))"
        }
    }
}
