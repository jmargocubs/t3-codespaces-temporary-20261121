import SwiftUI

func libraryMatchesPrimaryMenuCategory(
    _ library: Library,
    category: PrimaryMenuBuiltin
) -> Bool {
    switch category {
    case .movies:
        return library.isMovieLibrary || library.isMixedLibrary
    case .series:
        return library.isSeriesLibrary || library.isMixedLibrary
    case .audiobooks:
        return library.isAudiobookLibrary
    case .home, .music, .forYou, .calendar:
        return false
    }
}

func primaryMenuParentCategory(
    for library: Library,
    among categories: [PrimaryMenuBuiltin]
) -> PrimaryMenuBuiltin? {
    guard !library.isMixedLibrary else { return nil }
    return categories.first {
        libraryMatchesPrimaryMenuCategory(library, category: $0)
    }
}

struct PinnedLibraryGroupedElement<Element> {
    let element: Element
    let parentCategory: PrimaryMenuBuiltin?

    var isNestedLibrary: Bool { parentCategory != nil }
}

private struct LibraryPageScrollControlsKey: EnvironmentKey {
    static let defaultValue: AnyView? = nil
}

extension EnvironmentValues {
    /// The source selector and Recommended / Library / Collections bar of the Movies or Series page
    /// this view is in. Read only by `LibraryPageScrollContainer`.
    var libraryPageScrollControls: AnyView? {
        get { self[LibraryPageScrollControlsKey.self] }
        set { self[LibraryPageScrollControlsKey.self] = newValue }
    }
}

/// The one scroll container of a Movies or Series page. Every tab of both sources (Silo's
/// Recommended, Library and Collections, and the IPTV provider's) draws in it, in every state
/// (loading, empty, error, loaded), so the source selector and the Recommended / Library /
/// Collections bar always lead the tab's content and scroll away with it. Nothing on the page is
/// pinned; under the unified shell `LibrariesTabView` reserves the Kyro header's height once, as
/// a top safe-area inset that this scroll view's content starts below and scrolls under.
///
/// Outside a library page (no controls in the environment) it is a plain vertical scroll view.
struct LibraryPageScrollContainer<Content: View>: View {
    var showsIndicators = true
    @ViewBuilder let content: () -> Content

    @Environment(\.libraryPageScrollControls) private var controls

    var body: some View {
        ScrollView(.vertical, showsIndicators: showsIndicators) {
            VStack(spacing: 0) {
                if let controls { controls }
                content()
                    // A container nested in this content never repeats the page controls.
                    .environment(\.libraryPageScrollControls, nil)
            }
        }
        .reportsPageChromeScroll()
    }
}

/// A tab's loading, empty or error state. On a Movies or Series page it sits under the page
/// controls in `LibraryPageScrollContainer`, so a state never hides the controls (an empty
/// Collections tab left no way back to Recommended); elsewhere it fills the screen as before.
struct LibraryPageStatus<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @Environment(\.libraryPageScrollControls) private var controls

    var body: some View {
        if controls != nil {
            LibraryPageScrollContainer {
                content()
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 320)
            }
        } else {
            content()
        }
    }
}

/// Orders navigation elements so pinned libraries sit directly beneath the
/// media-type category that contains them, while libraries without a visible
/// parent (mixed libraries, or categories the user hid) stay at root level.
/// Shared by the iPad sidebar and the interface-customization editor so the
/// two surfaces cannot drift apart.
func groupPinnedLibrariesUnderMediaTypes<Element>(
    _ elements: [Element],
    libraries: [Library],
    libraryID: (Element) -> Int?,
    mediaTypeCategory: (Element) -> PrimaryMenuBuiltin?
) -> [PinnedLibraryGroupedElement<Element>] {
    let librariesByID = Dictionary(
        uniqueKeysWithValues: libraries.map { ($0.id, $0) }
    )
    let visibleCategories = elements.compactMap(mediaTypeCategory)
    var parentByLibraryID: [Int: PrimaryMenuBuiltin] = [:]
    for element in elements {
        guard let libraryID = libraryID(element),
              let library = librariesByID[libraryID],
              let parent = primaryMenuParentCategory(
                  for: library,
                  among: visibleCategories
              )
        else { continue }
        parentByLibraryID[libraryID] = parent
    }

    var grouped: [PinnedLibraryGroupedElement<Element>] = []
    for element in elements {
        if let libraryID = libraryID(element) {
            if parentByLibraryID[libraryID] == nil {
                grouped.append(.init(element: element, parentCategory: nil))
            }
            continue
        }

        grouped.append(.init(element: element, parentCategory: nil))
        guard let category = mediaTypeCategory(element) else { continue }
        for child in elements {
            guard let childLibraryID = libraryID(child),
                  parentByLibraryID[childLibraryID] == category
            else { continue }
            grouped.append(.init(element: child, parentCategory: category))
        }
    }
    return grouped
}

private func sharesPrimaryMenuCategory(_ lhs: Library, _ rhs: Library) -> Bool {
    // Mixed libraries participate in both authored Movies and Series roots,
    // but a pinned mixed-library root is its own scope. Treating its two
    // category memberships as sibling relationships would expose every movie
    // and series library from that direct root.
    if lhs.isMixedLibrary {
        return rhs.isMixedLibrary
    }
    let categories: [PrimaryMenuBuiltin] = [.movies, .series, .audiobooks]
    return categories.contains {
        libraryMatchesPrimaryMenuCategory(lhs, category: $0)
            && libraryMatchesPrimaryMenuCategory(rhs, category: $0)
    }
}

func visibleLibrariesForRoot(
    _ libraries: [Library],
    category: PrimaryMenuBuiltin?,
    fixedLibraryId: Int?,
    showAudiobooks: Bool
) -> [Library] {
    if let fixedLibraryId {
        // A direct library root still requires the exact library to be
        // accessible, but exposes sibling libraries of the same media type
        // so the top selector can switch between them like media-type roots.
        guard let fixed = libraries.first(where: { $0.id == fixedLibraryId }) else {
            return []
        }
        return libraries.filter {
            $0.id == fixed.id || sharesPrimaryMenuCategory(fixed, $0)
        }
    }
    guard let category else {
        return libraries.filter { showAudiobooks || !$0.isAudiobookLibrary }
    }
    return libraries.filter { libraryMatchesPrimaryMenuCategory($0, category: category) }
}

func resolvedLibraryIdForRoot(
    _ libraries: [Library],
    category: PrimaryMenuBuiltin?,
    fixedLibraryId: Int?,
    showAudiobooks: Bool,
    storedLibraryId: Int,
    currentSelectionId: Int? = nil
) -> Int? {
    let visible = visibleLibrariesForRoot(
        libraries,
        category: category,
        fixedLibraryId: fixedLibraryId,
        showAudiobooks: showAudiobooks
    )
    if let fixedLibraryId {
        // Keep an in-session switch to a sibling library, but always land on
        // the exact pinned library when entering the root fresh.
        if let current = currentSelectionId,
           visible.contains(where: { $0.id == current }) {
            return current
        }
        return visible.first(where: { $0.id == fixedLibraryId })?.id
    }
    if storedLibraryId != 0,
       let restored = visible.first(where: { $0.id == storedLibraryId }) {
        return restored.id
    }
    return visible.first?.id
}

private func libraryRootScopeID(
    category: PrimaryMenuBuiltin?,
    fixedLibraryId: Int?,
    authority: MainTabLibraryAuthority?
) -> String {
    let destination: String
    if let fixedLibraryId {
        destination = "library:\(fixedLibraryId)"
    } else if let category {
        destination = "category:\(category.rawValue)"
    } else {
        destination = "all"
    }
    return "\(authority?.serverId ?? "none"):\(authority?.profileId ?? "none"):\(destination)"
}

func librarySelectionStorageKey(
    category: PrimaryMenuBuiltin?,
    fixedLibraryId: Int?,
    authority: MainTabLibraryAuthority?
) -> String? {
    guard fixedLibraryId == nil else { return nil }
    guard category != nil else { return "librariesTabSelectedLibraryId" }
    guard authority != nil else { return nil }
    let scopeId = libraryRootScopeID(
        category: category,
        fixedLibraryId: nil,
        authority: authority
    )
    return "librariesTabSelectedLibraryId.\(scopeId)"
}

func storedLibrarySelectionId(
    for storageKey: String?,
    defaults: UserDefaults = .standard
) -> Int {
    guard let storageKey else { return 0 }
    if defaults.object(forKey: storageKey) != nil {
        return defaults.integer(forKey: storageKey)
    }
    // Seed new category-scoped selections from the legacy aggregate choice.
    // The first resolved selection is persisted under its own scoped key.
    return defaults.integer(forKey: "librariesTabSelectedLibraryId")
}

/// Mixed libraries inherit a category root's type; direct library roots expose a selector.
func mixedLibraryVideoScope(libraryType: String, category: PrimaryMenuBuiltin?, selection: LibraryVideoScope) -> LibraryVideoScope? {
    guard SiloMediaType.isMixedLibrary(libraryType) else { return nil }
    switch category {
    case .movies: return .movie
    case .series: return .series
    default: return selection
    }
}

struct LibraryVideoScopePicker: View {
    @Binding var selection: LibraryVideoScope

    var body: some View {
        Picker("Media type", selection: $selection) {
            Text("Movies").tag(LibraryVideoScope.movie)
            Text("Series").tag(LibraryVideoScope.series)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, SiloTheme.padding)
        .padding(.bottom, SiloTheme.smallPadding)
    }
}

/// A catalog that is not a Silo library, offered beside the Silo libraries of a Movies or Series
/// page (Kyro's IPTV VOD). The page keeps its one header, library selector and Recommended /
/// Library / Collections bar for both; only the tab content differs, and each source keeps its
/// own tab, scroll position and loaded pages.
struct LibraryAlternateSource {
    let id: String
    /// Shown in the selector while this source is active, e.g. the provider's name.
    let name: String
    /// The selector's second line, e.g. "IPTV · Movies".
    let selectorCaption: String
    /// The picker row's second line.
    let pickerCaption: String
    let systemImage: String
    let isSelected: Bool
    let tab: Binding<LibraryPageTab>
    let select: (Bool) -> Void
    let content: () -> AnyView
}

/// Shows one source's tab content while keeping the other mounted, so switching sources keeps
/// both scroll positions and loaded pages instead of rebuilding either page.
private struct LibrarySourceVisibility: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}

enum UnifiedBrowseChrome {
    /// Independent of the selected tab and active Silo library by design.
    static func title(for category: PrimaryMenuBuiltin?) -> String? {
        switch category {
        case .movies: "Movies"
        case .series: "Series"
        default: nil
        }
    }
}

/// Root of the Libraries tab.
///
/// Mirrors the Plex/Android flow: the tab lands directly on the active
/// library's 3-tab view (Recommended / Library / Collections) with a custom
/// top bar — library selector on the left, search/saved/profile actions
/// on the right.
struct LibrariesTabView: View {
    let category: PrimaryMenuBuiltin?
    let fixedLibraryId: Int?
    let libraryAuthority: MainTabLibraryAuthority?
    let onLibrariesLoaded: ((MainTabLibraryAuthority?, [Library]) -> Void)?
    let alternateSource: LibraryAlternateSource?
    let unifiedCatalog: (([Library]) -> AnyView)?

    @State private var libraries: [Library] = []
    /// Which source is shown and which alternate source's page stays mounted.
    @State private var sourceState = LibraryPageSourceState()
    @State private var selectedLibraryId: Int?
    @State private var selectedTab: LibraryPageTab = .recommended
    @State private var selectedVideoScope: LibraryVideoScope = .movie
    @State private var isLoading = true
    @State private var error: ErrorState?
    @State private var showPicker = false
    @State private var navPrefs = AppNavPreferences.shared

    /// Persist the last-selected library per authored root so visiting Series
    /// cannot replace the Movies or aggregate selection. Fixed-library roots
    /// have no persistence key because their destination already fixes the ID.
    private let selectionStorageKey: String?
    @State private var storedLibraryId: Int
    /// Scope the current `selectedLibraryId` belongs to. A direct-library
    /// root allows switching to sibling libraries in-session, but a fresh
    /// visit (or a reused view whose destination changed) must land on the
    /// exact pinned library again.
    @State private var appliedScopeID: String?

    @Environment(AppRouter.self) private var router
    #if os(iOS)
    @Environment(\.statusColumn) private var statusColumn
    #endif
    #if os(iOS)
    @Environment(\.kyroShellHeader) private var shellHeader
    @Environment(\.secondaryDestinationTitle) private var secondaryTitle
    #endif

    /// The shell's header context when it draws the header for this page: a Movies or Series
    /// tab under the unified shell. Nil for a library root pushed from More and everywhere the
    /// shell draws no header, where this page keeps its own top bar.
    private var hostedHeader: (runway: CGFloat, state: PageChromeScrollState)? {
        #if os(iOS)
        guard let destination = KyroShellHeader.destination(forCategory: category),
              let context = KyroShellHeader.hosted(shellHeader, secondaryTitle: secondaryTitle) else { return nil }
        return (context.runway, context.scrollState(for: destination))
        #else
        return nil
        #endif
    }

    init(
        category: PrimaryMenuBuiltin? = nil,
        fixedLibraryId: Int? = nil,
        libraryAuthority: MainTabLibraryAuthority? = nil,
        onLibrariesLoaded: ((MainTabLibraryAuthority?, [Library]) -> Void)? = nil,
        alternateSource: LibraryAlternateSource? = nil,
        unifiedCatalog: (([Library]) -> AnyView)? = nil
    ) {
        self.category = category
        self.fixedLibraryId = fixedLibraryId
        self.libraryAuthority = libraryAuthority
        self.onLibrariesLoaded = onLibrariesLoaded
        self.alternateSource = alternateSource
        self.unifiedCatalog = unifiedCatalog
        let storageKey = librarySelectionStorageKey(
            category: category,
            fixedLibraryId: fixedLibraryId,
            authority: libraryAuthority
        )
        selectionStorageKey = storageKey
        _storedLibraryId = State(initialValue: storedLibrarySelectionId(for: storageKey))
    }

    /// The alternate source is on screen: chosen, or the only catalog this page has.
    private var showsAlternate: Bool {
        LibraryPageSourceState.showsAlternate(
            isOffered: alternateSource != nil,
            isSelected: alternateSource?.isSelected == true,
            hasActiveLibrary: activeLibrary != nil,
            isLoadingLibraries: isLoading && libraries.isEmpty
        )
    }

    var body: some View {
        Group {
            if activeLibrary != nil || showsAlternate || unifiedCatalog != nil {
                loadedContent(activeLibrary: activeLibrary)
            } else if let error, visibleLibraries.isEmpty {
                ErrorView(state: error, onRetry: { Task { await loadLibraries() } })
            } else if isLoading && visibleLibraries.isEmpty {
                Color.clear
            } else {
                EmptyStateView(
                    icon: "square.stack.3d.up",
                    title: "No libraries available",
                    subtitle: "Libraries visible to this profile will appear here."
                )
            }
        }
        // Under the unified shell the Kyro header floats over this page (an overlay, not a safe-area
        // inset). Reserve its height once, for every state, as a top safe-area inset: scroll content
        // starts below the header and scrolls under it, and nothing else on the page is pinned.
        .safeAreaPadding(.top, hostedHeader?.runway ?? 0)
        .siloPageBackground()
        #if !os(macOS)
        .rootPageNavigationBar()
        #endif
        .onChange(of: alternateSource?.id, initial: true) { _, _ in updateSourceState() }
        .onChange(of: showsAlternate) { _, _ in updateSourceState() }
        .task(id: libraryRootScopeID(
            category: category,
            fixedLibraryId: fixedLibraryId,
            authority: libraryAuthority
        )) {
            navPrefs.refresh()
            storedLibraryId = storedLibrarySelectionId(for: selectionStorageKey)
            // SwiftUI can preserve this view while a split-view selection
            // changes from one direct library root to another. Reconcile the
            // selection before awaiting I/O so the old library never renders
            // under the new destination.
            applyLibrarySelection()
            await loadLibraries()
        }
        .onChange(of: navPrefs.showAudiobooks) {
            applyLibrarySelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .userLibrariesDidRefresh)) {
            notification in
            guard let response = notification.object as? LibrariesResponse else { return }
            acceptRefreshedLibraries(response)
        }
        .sheet(isPresented: $showPicker) {
            LibraryPickerSheet(
                libraries: visibleLibraries,
                scopedCategory: pickerScopeCategory,
                selectedLibraryId: showsAlternate ? nil : selectedLibraryId,
                alternateSource: alternateSource,
                isAlternateSelected: showsAlternate,
                onSelect: { id in
                    alternateSource?.select(false)
                    selectedLibraryId = id
                    persistLibrarySelection(id)
                    showPicker = false
                    StartupContentPrefetcher.prefetchLibraryLanding(libraryId: id)
                },
                onSelectAlternate: {
                    alternateSource?.select(true)
                    showPicker = false
                }
            )
        }
    }

    private func updateSourceState() {
        sourceState.update(offeredAlternateID: alternateSource?.id, showsAlternate: showsAlternate)
    }

    @ViewBuilder
    private func loadedContent(activeLibrary: Library?) -> some View {
        // Each tab of each source draws in `LibraryPageScrollContainer`, which leads its content
        // with these controls, so they scroll with the posters. They carry no glass of their own:
        // only the shell's Kyro header is pinned, and it draws the scroll glass.
        ZStack {
            if selectedTab == .library, let unifiedCatalog {
                unifiedCatalog(visibleLibraries)
            }
            if selectedTab != .library, activeLibrary == nil, unifiedCatalog != nil {
                LibraryPageScrollContainer {
                    EmptyStateView(icon: "square.stack.3d.up",
                                   title: "No Silo libraries available",
                                   subtitle: "Recommended and Collections use Silo libraries.")
                        .frame(minHeight: 320)
                }
            }
            if let activeLibrary, selectedTab != .library || unifiedCatalog == nil {
                tabContent(activeLibrary: activeLibrary)
                    // Forces the whole tab subtree to reset when switching
                    // libraries, so stale content never flashes on screen.
                    .id("\(activeLibrary.id):\(videoScope(for: activeLibrary)?.rawValue ?? "all")")
                    .modifier(LibrarySourceVisibility(isVisible: !showsAlternate && !(selectedTab == .library && unifiedCatalog != nil)))
            }
            if let alternateSource, showsAlternate || sourceState.mountsAlternate(alternateSource.id) {
                alternateSource.content()
                    // Another provider is another page: nothing built for the previous provider
                    // (scroll position, grid state, search field) carries over.
                    .id(alternateSource.id)
                    .modifier(LibrarySourceVisibility(isVisible: showsAlternate))
            }
        }
            // Feeds the shell header's scroll glass. Off the shell nothing on this page is pinned,
            // so no page reads a scroll state.
            .environment(hostedHeader?.state)
            .environment(\.libraryPageScrollControls, AnyView(topChrome(activeLibrary: activeLibrary)))
    }

    @ViewBuilder
    private func tabContent(activeLibrary: Library) -> some View {
        switch selectedTab {
        case .recommended:
            LibraryRecommendedView(libraryId: activeLibrary.id, mediaScope: videoScope(for: activeLibrary))
        case .library:
            BrowseView(libraryId: activeLibrary.id, title: nil, showsSearchShortcut: false, libraryType: activeLibrary.type, mediaScope: videoScope(for: activeLibrary))
        case .collections:
            LibraryCollectionsView(libraryId: activeLibrary.id, mediaScope: videoScope(for: activeLibrary))
        }
    }

    @ViewBuilder
    private func topChrome(activeLibrary: Library?) -> some View {
        if centersHeader {
            // The title and tabs center as one block, the title lined up
            // with the first tab, while they fit side by side.
            ViewThatFits(in: .horizontal) {
                headerStack(activeLibrary: activeLibrary, scrollsTabs: false)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity)
                headerStack(activeLibrary: activeLibrary, scrollsTabs: true)
            }
        } else {
            headerStack(activeLibrary: activeLibrary, scrollsTabs: true)
        }
    }

    /// Unified Movies and Series keep one chrome identity across all three tabs. The selected
    /// Silo library is still used by Recommended and Collections, but is not a page heading.
    private func selectorLabel(activeLibrary: Library?) -> (title: String, caption: String) {
        if unifiedCatalog != nil, let title = UnifiedBrowseChrome.title(for: category) {
            return (title, "")
        }
        if showsAlternate, let alternateSource {
            return (alternateSource.name, alternateSource.selectorCaption)
        }
        if let activeLibrary {
            if unifiedCatalog != nil {
                return (activeLibrary.name, "Silo · \(LibrarySelectorButton.typeLabel(for: activeLibrary))")
            }
            return (activeLibrary.name, LibrarySelectorButton.typeLabel(for: activeLibrary))
        }
        return ("Libraries", "")
    }

    /// Each source keeps its own Recommended / Library / Collections choice.
    private var pageTabBinding: Binding<LibraryPageTab> {
        if showsAlternate, let alternateSource { return alternateSource.tab }
        return $selectedTab
    }

    private func headerStack(activeLibrary: Library?, scrollsTabs: Bool) -> some View {
        let label = selectorLabel(activeLibrary: activeLibrary)
        let stableUnifiedHeader = unifiedCatalog != nil && UnifiedBrowseChrome.title(for: category) != nil
        return VStack(alignment: .leading, spacing: 0) {
            if hostedHeader != nil {
                // The shell's Kyro header is the only pinned chrome. The selector is the first
                // row of the scroll content, starting just below the header's reserved inset.
                HStack(spacing: 12) {
                    LibrarySelectorButton(
                        title: label.title,
                        caption: label.caption,
                        canSwitch: canSwitchLibraries && (stableUnifiedHeader || selectedTab != .library),
                        onTap: { if stableUnifiedHeader || selectedTab != .library { showPicker = true } }
                    )
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, SiloTheme.padding)
                .padding(.bottom, SiloTheme.smallPadding)
            } else {
            LibrariesTopBar(
                title: label.title,
                caption: label.caption,
                canSwitch: canSwitchLibraries && (stableUnifiedHeader || selectedTab != .library),
                onLibraryTap: { if stableUnifiedHeader || selectedTab != .library { showPicker = true } },
                onSearch: { router.navigate(to: .search) },
                onOpenSettings: { router.navigate(to: .settings) },
                onOpenRequests: { router.navigate(to: .requestsHub) },
                onSwitchProfile: {
                    router.switchProfile()
                },
                onSwitchServer: { router.navigate(to: .serverList) },
                onSignOut: { router.signOutAndReset() }
            )
            .padding(.horizontal, SiloTheme.padding)
            .padding(.top, centersHeader ? SiloTheme.padding : SiloTheme.smallPadding)
            .padding(.bottom, SiloTheme.smallPadding)
            }

            if !showsAlternate, let activeLibrary,
               activeLibrary.isMixedLibrary && category != .movies && category != .series {
                LibraryVideoScopePicker(selection: $selectedVideoScope)
            }
            LibraryPageTabSelector(selectedTab: pageTabBinding, scrolls: scrollsTabs)
                // With the selector's own vertical inset, one standard gap above every tab's first
                // row. Tabs add no gap of their own above it.
                .padding(.bottom, SiloTheme.smallPadding)
        }
    }

    /// The iPhone Duo's cover screen moves the header actions into the
    /// status column, leaving the title and tabs alone in a rounded panel.
    private var centersHeader: Bool {
        #if os(iOS)
        statusColumn != nil
        #else
        false
        #endif
    }

    private func videoScope(for library: Library) -> LibraryVideoScope? {
        mixedLibraryVideoScope(libraryType: library.type, category: category, selection: selectedVideoScope)
    }

    private var activeLibrary: Library? {
        visibleLibraries.first(where: { $0.id == selectedLibraryId })
    }

    /// The media-type scope the picker opened under, if any. A direct-library
    /// root inherits the pinned library's type since its siblings share it.
    /// Mixed-library roots have their own scope rather than inheriting either
    /// Movies or Series.
    private var pickerScopeCategory: PrimaryMenuBuiltin? {
        if let category { return category }
        guard let fixedLibraryId,
              let fixed = libraries.first(where: { $0.id == fixedLibraryId }),
              !fixed.isMixedLibrary
        else { return nil }
        return [PrimaryMenuBuiltin.movies, .series, .audiobooks].first {
            libraryMatchesPrimaryMenuCategory(fixed, category: $0)
        }
    }

    /// The Mac lists every library in its sidebar, so the page title offers
    /// no picker there.
    private var canSwitchLibraries: Bool {
        #if os(macOS)
        false
        #else
        visibleLibraries.count > 1 || (alternateSource != nil && !visibleLibraries.isEmpty)
        #endif
    }

    private var visibleLibraries: [Library] {
        visibleLibrariesForRoot(
            libraries,
            category: category,
            fixedLibraryId: fixedLibraryId,
            showAudiobooks: navPrefs.showAudiobooks
        )
    }

    private func loadLibraries() async {
        // Hydrate from cache so a returning visit paints last-known
        // libraries instantly while the refresh runs.
        if libraries.isEmpty,
           let cached: LibrariesResponse = ResponseCache.shared.get(CacheKey.userLibraries) {
            libraries = cached.libraries
            applyLibrarySelection()
            onLibrariesLoaded?(libraryAuthority, cached.libraries)
        }
        if libraries.isEmpty {
            isLoading = true
        }
        error = nil
        do {
            let response = try await StartupContentPrefetcher.fetchUserLibraries()
            guard !Task.isCancelled else { return }
            acceptRefreshedLibraries(response)
        } catch {
            if libraries.isEmpty {
                self.error = ErrorState(error)
            }
        }
        isLoading = false
    }

    /// Apply library metadata refreshed elsewhere (for example Home pull to
    /// refresh) so retained tab instances cannot keep renamed or revoked
    /// libraries in their local state.
    private func acceptRefreshedLibraries(_ response: LibrariesResponse) {
        libraries = response.libraries
        error = nil
        isLoading = false
        applyLibrarySelection()
        onLibrariesLoaded?(libraryAuthority, response.libraries)
        if let selectedLibraryId {
            StartupContentPrefetcher.prefetchLibraryLanding(libraryId: selectedLibraryId)
        }
    }

    /// Preserve the stored selection if it still exists; otherwise fall
    /// back to the first available library.
    private func applyLibrarySelection() {
        let scopeID = libraryRootScopeID(
            category: category,
            fixedLibraryId: fixedLibraryId,
            authority: libraryAuthority
        )
        let resolved = resolvedLibraryIdForRoot(
            libraries,
            category: category,
            fixedLibraryId: fixedLibraryId,
            showAudiobooks: navPrefs.showAudiobooks,
            storedLibraryId: storedLibraryId,
            currentSelectionId: appliedScopeID == scopeID ? selectedLibraryId : nil
        )
        appliedScopeID = scopeID
        selectedLibraryId = resolved
        if let resolved { persistLibrarySelection(resolved) }
    }

    private func persistLibrarySelection(_ libraryId: Int) {
        if let selectionStorageKey {
            storedLibraryId = libraryId
            UserDefaults.standard.set(libraryId, forKey: selectionStorageKey)
        }
        mirrorSelectionToMediaTypeRoots(libraryId)
    }

    /// Landing on (or switching within) a direct-library root also records
    /// the selection for the matching media-type roots, so tapping "Movies"
    /// after visiting "4K Movies" lands on 4K Movies.
    private func mirrorSelectionToMediaTypeRoots(_ libraryId: Int) {
        guard fixedLibraryId != nil,
              libraryAuthority != nil,
              let library = libraries.first(where: { $0.id == libraryId })
        else { return }
        for mediaType in [PrimaryMenuBuiltin.movies, .series, .audiobooks]
        where libraryMatchesPrimaryMenuCategory(library, category: mediaType) {
            guard let key = librarySelectionStorageKey(
                category: mediaType,
                fixedLibraryId: nil,
                authority: libraryAuthority
            ) else { continue }
            UserDefaults.standard.set(libraryId, forKey: key)
        }
    }

}

// MARK: - Top Bar

/// Plex-style top bar: library selector on the left, shared action icons
/// (search / profile) on the right.
private struct LibrariesTopBar: View {
    let title: String
    let caption: String
    let canSwitch: Bool
    let onLibraryTap: () -> Void
    let onSearch: () -> Void
    let onOpenSettings: () -> Void
    let onOpenRequests: () -> Void
    let onSwitchProfile: () -> Void
    let onSwitchServer: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SidebarToggleButton()

            LibrarySelectorButton(
                title: title,
                caption: caption,
                canSwitch: canSwitch,
                onTap: onLibraryTap
            )

            Spacer(minLength: 8)

            TabTopBarActions(
                onSearch: onSearch,
                onOpenSettings: onOpenSettings,
                onOpenRequests: onOpenRequests,
                onSwitchProfile: onSwitchProfile,
                onSwitchServer: onSwitchServer,
                onSignOut: onSignOut
            )
        }
        .clearsWindowControls()
    }
}

/// Compact library selector: library name with a small chevron, stacked above
/// a secondary label. Tap opens the picker sheet.
private struct LibrarySelectorButton: View {
    let title: String
    let caption: String
    let canSwitch: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.siloTitle)
                    .foregroundStyle(Color.siloOnSurface)
                        .lineLimit(1)
                    if canSwitch {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.siloOnSurface)
                    }
                }
                if !caption.isEmpty {
                    Text(caption)
                        .font(.siloCaption)
                        .foregroundStyle(Color.siloSecondaryText)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!canSwitch)
        .accessibilityIdentifier("librarySourceSelector")
    }

    static func typeLabel(for library: Library) -> String {
        if library.isAudiobookLibrary { return "Audiobooks" }
        if library.isMixedLibrary { return "Movies & Series" }
        if library.isSeriesLibrary { return "Series" }
        if library.type == "movies" { return "Movies" }
        if library.type == "music" { return "Music" }
        return "Library"
    }
}

// MARK: - Library Picker Sheet

/// Sheet listing all libraries available to the active profile. Used for
/// switching the active library from the Libraries tab.
private struct LibraryPickerSheet: View {
    let libraries: [Library]
    let scopedCategory: PrimaryMenuBuiltin?
    let selectedLibraryId: Int?
    var alternateSource: LibraryAlternateSource? = nil
    var isAlternateSelected = false
    let onSelect: (Int) -> Void
    var onSelectAlternate: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(tvOS)
        // tvOS does not support medium detents or presentation drags; render
        // as a full-screen focus-friendly list instead.
        content
        #else
        NavigationStack {
            content
                .toolbar {
                    #if os(macOS)
                    ToolbarItem {
                        Button("Done") { dismiss() }
                    }
                    #else
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                    #endif
                }
        }
        #if !os(macOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        #endif
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if alternateSource != nil, !libraries.isEmpty {
                    pickerSectionTitle("Silo")
                }
                ForEach(libraries) { library in
                    LibraryPickerRow(
                        library: library,
                        scopedCategory: scopedCategory,
                        isSelected: library.id == selectedLibraryId,
                        onTap: { onSelect(library.id) }
                    )
                }
                if let alternateSource {
                    pickerSectionTitle("IPTV")
                        .padding(.top, libraries.isEmpty ? 0 : SiloTheme.smallPadding)
                    Button(action: onSelectAlternate) {
                        LibraryPickerRowLabel(
                            systemImage: alternateSource.systemImage,
                            title: alternateSource.name,
                            caption: alternateSource.pickerCaption,
                            isSelected: isAlternateSelected
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("librarySourceRow.\(alternateSource.id)")
                }
            }
            .padding(.horizontal, SiloTheme.padding)
            .padding(.vertical, SiloTheme.padding)
        }
        .siloSheetBackground()
        .navigationTitle(alternateSource == nil ? "Libraries" : "Sources")
    }

    private func pickerSectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.siloCaption.weight(.semibold))
            .tracking(1)
            .foregroundStyle(Color.siloSecondaryText)
            .padding(.horizontal, 4)
    }
}

private struct LibraryPickerRow: View {
    let library: Library
    let scopedCategory: PrimaryMenuBuiltin?
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            LibraryPickerRowLabel(systemImage: iconName, title: library.name,
                                  caption: typeLabel, isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        if library.isAudiobookLibrary { return "book.closed.fill" }
        if library.isMixedLibrary { return "square.stack.3d.up.fill" }
        if library.isSeriesLibrary { return "tv.fill" }
        if library.type == "movies" { return "film.fill" }
        if library.type == "music" { return "music.note" }
        return "square.stack.3d.up.fill"
    }

    /// Nil when the caption would just repeat the media-type scope the picker
    /// opened under — every non-mixed library there shares that type. Mixed
    /// libraries keep their caption since they stand out from the scope.
    private var typeLabel: String? {
        if scopedCategory != nil && !library.isMixedLibrary { return nil }
        if library.isAudiobookLibrary { return "Audiobooks library" }
        if library.isMixedLibrary { return "Movies & Series library" }
        if library.isSeriesLibrary { return "TV library" }
        if library.type == "movies" { return "Movies library" }
        if library.type == "music" { return "Music library" }
        return "Library"
    }
}

/// One picker row's look, shared by Silo libraries and the alternate (IPTV) source.
private struct LibraryPickerRowLabel: View {
    let systemImage: String
    let title: String
    let caption: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.siloOnSurface.opacity(0.12))
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.siloOnSurface)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.siloHeadline)
                    .foregroundColor(.siloOnSurface)
                if let caption {
                    Text(caption)
                        .font(.siloCaption)
                        .foregroundColor(.siloSecondaryText)
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.siloOnSurface)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: SiloTheme.cornerRadius)
                .fill(isSelected ? Color.siloOnSurface.opacity(0.24) : Color.siloSurfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: SiloTheme.cornerRadius)
                        .stroke(Color.siloOutline, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}
