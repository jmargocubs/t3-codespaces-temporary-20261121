import SwiftUI
#if os(iOS)
import UIKit
#endif

struct LiveTVChannelBrowserSection: Identifiable {
    let id: String
    let category: String
    var channels: [LiveTVChannel]
}

/// Build 82.1: when the channel browser may reuse a saved scroll snapshot.
enum LiveTVBrowserScrollPolicy {
    /// Categories selections always open at the first channel. Only an explicit Home re-entry of
    /// the same browser (All / Favorites / search) may resume a Home snapshot.
    static func shouldResumeSavedPosition(fromCategories: Bool, resumingSavedPosition: Bool) -> Bool {
        resumingSavedPosition && !fromCategories
    }

    /// List identity so SwiftUI drops a reused scroll offset when filters change.
    static func listIdentity(providerID: UUID?, category: String?, favoritesOnly: Bool,
                             searchQuery: String) -> String {
        let provider = providerID?.uuidString ?? "none"
        let cat = category ?? ""
        let favorites = favoritesOnly ? "1" : "0"
        return "\(provider)|\(cat)|\(favorites)|\(searchQuery)"
    }
}

/// Build 82: the browsing state behind Live TV Home's Categories page and channel browser.
///
/// Live TV Home lives inside the Live TV tab, beneath the shell's `NavigationStack`. Categories and
/// the channel browser are typed routes (`LiveTVHomeRoutes.Destination`) on that stack's own path,
/// resolved by `liveTVShellRoutes` where the shell registers its other destinations; Build 81
/// registered them inside the tab, where the shell cannot see them, and every push showed SwiftUI's
/// unresolved-destination placeholder. Home and the shell-level screens read and write this one
/// object, so a pushed screen never depends on `LiveTVView`'s private state.
///
/// One instance per `LiveTVService`. Playback, the channel catalog and the guide stay in the
/// service; this holds only filters, positions and Live TV's suffix of the shell path.
@MainActor
@Observable
final class LiveTVBrowseModel {
    let service: LiveTVService

    // MARK: Channel browser state

    var searchText = ""
    var selectedCategory: String?
    var favoritesOnly = false
    var isSearchPresented = false
    let searchModel = LiveTVChannelSearchModel()
    #if os(iOS)
    let pagedChannels = LiveTVPagedChannelModel()
    #endif
    var listPosition = ScrollPosition(idType: String.self)
    var isShowingSettings = false

    // MARK: Categories pages (Home's and the browser's filter picker stay independent)

    private(set) var homeCategoryPickerPosition: LiveTVGuideCategoryPickerID?
    @ObservationIgnored private var homeCategoryPickerState = LiveTVGuideCategoryPickerState()
    var isShowingBrowserCategories = false
    private(set) var browserCategoryPickerPosition: LiveTVGuideCategoryPickerID?
    @ObservationIgnored private var browserCategoryPickerState = LiveTVGuideCategoryPickerState()

    // MARK: Routes

    /// Which trailing entries of the shell path are Live TV's. The shell path is the truth; native
    /// Back and swipes change it first and `reconcile(rootDepth:)` follows.
    private(set) var routes = LiveTVHomeRoutes()
    /// Whether a shell stack hosts Live TV's routes. Without one the browser replaces Home in place.
    private(set) var hasShellPath = false
    @ObservationIgnored private var rootPath: Binding<NavigationPath>?

    // MARK: Saved browser positions

    @ObservationIgnored private var browsingContextToRestore: LiveTVBrowsingContext?
    @ObservationIgnored private var restoredContextProviderID: UUID?
    /// Per-provider browser snapshots. `LiveTVView` mirrors this into its scene storage.
    private(set) var savedBrowsingContexts = ""
    @ObservationIgnored private var hasAdoptedSavedContexts = false

    private static var models: [ObjectIdentifier: LiveTVBrowseModel] = [:]

    /// The model for a service. Production has one (`LiveTVService.shared`); debug fixtures pass
    /// their own service and get their own model.
    static func model(for service: LiveTVService) -> LiveTVBrowseModel {
        let key = ObjectIdentifier(service)
        if let model = models[key] { return model }
        let model = LiveTVBrowseModel(service: service)
        models[key] = model
        return model
    }

    private init(service: LiveTVService) {
        self.service = service
    }

    // MARK: Derived

    var showChannelBrowser: Bool { routes.showsBrowser }
    var isShowingCategories: Bool { routes.showsCategories }
    var browserOpenedFromCategories: Bool { routes.browserOpenedFromCategories }
    /// Categories or the browser is pushed over Home on the shell stack.
    var hasPushedRoutes: Bool { hasShellPath && !routes.path.isEmpty }
    var isBrowserPushed: Bool { hasShellPath && showChannelBrowser }

    var browserTitle: String {
        if !searchText.isEmpty { return "Search Results" }
        if favoritesOnly { return "Favorite Channels" }
        return selectedCategory ?? "Browse Channels"
    }

    var contentState: LiveTVChannelListContentState {
        LiveTVChannelListContentState.resolve(hasProviders: !service.providers.isEmpty,
                                              isLoading: service.isLoading,
                                              errorMessage: service.errorMessage,
                                              channelCount: service.selectedChannelCount)
    }

    var browserResultCount: Int {
        #if os(iOS)
        pagedChannels.resultCount
        #else
        searchModel.resultCount
        #endif
    }

    var browserIsSearching: Bool {
        #if os(iOS)
        pagedChannels.isLoading
        #else
        searchModel.isSearching
        #endif
    }

    var browserSections: [LiveTVChannelBrowserSection] {
        #if os(iOS)
        var result: [LiveTVChannelBrowserSection] = []
        for channel in pagedChannels.channels {
            if result.last?.category == channel.category {
                result[result.count - 1].channels.append(channel)
            } else {
                result.append(LiveTVChannelBrowserSection(id: channel.id, category: channel.category,
                                                          channels: [channel]))
            }
        }
        return result
        #else
        return searchModel.orderedCategories.compactMap { category in
            guard let channels = searchModel.groups[category], let first = channels.first else { return nil }
            return LiveTVChannelBrowserSection(id: first.id, category: category, channels: channels)
        }
        #endif
    }

    var browserMatches: [LiveTVChannel] {
        #if os(iOS)
        pagedChannels.channels
        #else
        searchModel.matches
        #endif
    }

    func loadMoreIfNeeded(after channel: LiveTVChannel) {
        #if os(iOS)
        pagedChannels.loadPageIfNeeded(around: channel, service: service)
        #endif
    }

    // MARK: Shell path

    /// Called by the shell modifier and by `LiveTVView`, both with the same shell path.
    func attach(rootPath: Binding<NavigationPath>) {
        self.rootPath = rootPath
        if !hasShellPath {
            hasShellPath = true
            LiveTVNavigationDiagnostics.shared.note("shell path attached depth=\(rootPath.wrappedValue.count)")
        }
        reconcile(rootDepth: rootPath.wrappedValue.count)
    }

    /// The shell path changed: system Back, an edge swipe, pop-to-root or another feature's push.
    /// Observes only; it never pops again in response.
    func reconcile(rootDepth: Int) {
        if routes.reconcile(rootDepth: rootDepth) { finishBrowserExit() }
    }

    /// The one place Live TV writes the shell path. A native pop not yet observed is folded in
    /// first, so an intent is never dropped or applied to a stale depth.
    private func changeRoutes(_ reason: String, _ change: (inout LiveTVHomeRoutes) -> Void) {
        guard let rootPath else {
            // No shell stack: the ledger alone decides the in-place browser.
            change(&routes)
            LiveTVNavigationDiagnostics.shared.note("\(reason) (no shell path; in place)")
            return
        }
        var root = rootPath.wrappedValue
        var next = routes
        next.perform(on: &root, reason: reason, change)
        routes = next
        rootPath.wrappedValue = root
    }

    // MARK: Home intents

    func openHomeCategoryPicker() {
        guard service.selectedProviderID != nil else { return }
        guard hasShellPath else {
            LiveTVNavigationDiagnostics.shared.note("Categories not opened: no shell path")
            return
        }
        // Build 82.1: a Home → Categories push is a fresh entry at the visual top. Restoring the
        // last mid-list row here scrolled search off-screen and collapsed the large title. Position
        // while Categories stays under Channels is kept by the page's @State and by
        // `rememberHomeCategoryPosition` when that page is recreated.
        homeCategoryPickerPosition = nil
        changeRoutes("Home opens Categories") { $0.openCategories(source: "Home View All") }
    }

    /// A choice on Home's Categories page pushes the browser over it.
    func chooseFromCategories(_ filters: LiveTVBrowserFilters) {
        LiveTVRouteTrace.log("select", route: "categories", owner: "home",
                             detail: "category=\(filters.category ?? (filters.favoritesOnly ? "Favorites" : "All"))")
        // Never resume a prior category's saved offset for a Categories selection — each choice is
        // a new list at its first channel. Home's own All/Favorites entry may still resume.
        enterBrowser(using: filters, resumingSavedPosition: false, fromCategories: true,
                     source: "categories selection")
    }

    func rememberHomeCategoryPosition(_ position: LiveTVGuideCategoryPickerID?) {
        // Keep the live value too: if SwiftUI recreates Categories after Channels pops, appear
        // restores this mid-list row. `.allCategories` is stored but treated as top on appear.
        homeCategoryPickerPosition = position
        guard let providerID = service.selectedProviderID else { return }
        homeCategoryPickerState.remember(position, providerID: providerID, categories: service.categories)
    }

    /// Stable identity for the channel browser's list. Changing it forces SwiftUI to drop a reused
    /// scroll offset when the filters change (Build 82.1).
    var browserListIdentity: String {
        LiveTVBrowserScrollPolicy.listIdentity(
            providerID: service.selectedProviderID, category: selectedCategory,
            favoritesOnly: favoritesOnly, searchQuery: searchText)
    }

    /// Every entry point starts from its own filters. Re-entering from Home the exact browser the
    /// user left may resume its saved position; a Categories selection always starts at the top.
    func enterBrowser(using filters: LiveTVBrowserFilters, resumingSavedPosition: Bool = true,
                      fromCategories: Bool = false, source: String = "Home") {
        searchText = filters.query
        selectedCategory = filters.category
        favoritesOnly = filters.favoritesOnly
        changeRoutes("open channels from \(fromCategories ? "Categories" : "Home")") {
            $0.openBrowser(fromCategories: fromCategories, source: source,
                           providerID: service.selectedProviderID, category: filters.category)
        }
        resetBrowserListPosition()
        let mayResume = LiveTVBrowserScrollPolicy.shouldResumeSavedPosition(
            fromCategories: fromCategories, resumingSavedPosition: resumingSavedPosition)
        browsingContextToRestore = mayResume
            ? service.selectedProviderID.flatMap { storedBrowsingContext(for: $0)?.resumedBrowser(for: filters) }
            : nil
        reconcileBrowsingContext()
        updateSearch()
    }

    /// An intentional return to Home is persisted, so the browser does not reopen on the next visit.
    func returnHome(reason: String) {
        finishBrowserExit()
        changeRoutes(reason) { $0.closeBrowser(reason: reason) }
    }

    private func finishBrowserExit() {
        if let providerID = service.selectedProviderID {
            storeBrowsingContext(currentBrowsingContext(for: providerID).returningHome())
        }
        browsingContextToRestore = nil
        isSearchPresented = false
        searchText = ""
        selectedCategory = nil
        favoritesOnly = false
        resetBrowserListPosition()
    }

    /// Clears the shared list `ScrollPosition` so a new category cannot inherit another list's offset.
    private func resetBrowserListPosition() {
        listPosition = ScrollPosition(idType: String.self)
    }

    func selectProvider(_ providerID: UUID) {
        saveBrowsingContext(for: service.selectedProviderID)
        // A nested browser cannot retain its old provider's category when the catalog changes.
        // Return to its Categories parent; that page rebuilds for the new provider.
        if browserOpenedFromCategories && showChannelBrowser { returnHome(reason: "provider changed under Categories") }
        restoredContextProviderID = nil
        service.selectProvider(providerID)
    }

    // MARK: Service changes (observed by LiveTVView, as in Build 80)

    func catalogDidChange() {
        if browserOpenedFromCategories, let selectedCategory,
           let providerID = service.selectedProviderID, service.hasCatalog(for: providerID),
           !service.categories.contains(selectedCategory) {
            // A refreshed catalog removed the selected category. Leave the obsolete channel route
            // and show its Categories parent rather than silently browsing All.
            returnHome(reason: "catalog removed selected category")
        }
        reconcileBrowsingContext()
        reconcileCategoryPickers()
        updateSearch()
    }

    func providerDidChange(to providerID: UUID?) {
        restoreBrowsingContext(for: providerID)
        resetCategoryPickerPositions(for: providerID)
        updateSearch()
    }

    // MARK: Browser category filter (a pushed page of the browser; independent of Home's)

    func openBrowserCategoryPicker() {
        guard let providerID = service.selectedProviderID else { return }
        browserCategoryPickerPosition = browserCategoryPickerState.target(
            providerID: providerID, selectedCategory: selectedCategory, categories: service.categories)
        isShowingBrowserCategories = true
    }

    func applyBrowserCategoryChoice(_ choice: LiveTVCategoryChoice) {
        let filters = LiveTVCategoryNavigation.browserFilters(for: choice)
        let changed = filters.category != selectedCategory || filters.favoritesOnly != favoritesOnly
        if changed {
            // Clear before `selectedCategory` changes: LiveTVView's onChange calls updateSearch,
            // which must not re-apply a prior category's pending scroll restore.
            browsingContextToRestore = nil
            resetBrowserListPosition()
        }
        selectedCategory = filters.category
        favoritesOnly = filters.favoritesOnly
        isShowingBrowserCategories = false
    }

    func rememberBrowserCategoryPosition(_ position: LiveTVGuideCategoryPickerID?) {
        browserCategoryPickerPosition = position
        guard let providerID = service.selectedProviderID else { return }
        browserCategoryPickerState.remember(position, providerID: providerID, categories: service.categories)
    }

    private func resetCategoryPickerPositions(for providerID: UUID?) {
        guard let providerID else {
            homeCategoryPickerPosition = nil
            browserCategoryPickerPosition = nil
            return
        }
        homeCategoryPickerPosition = homeCategoryPickerState.target(
            providerID: providerID, selectedCategory: nil, categories: service.categories)
        browserCategoryPickerPosition = browserCategoryPickerState.target(
            providerID: providerID, selectedCategory: selectedCategory, categories: service.categories)
    }

    private func reconcileCategoryPickers() {
        guard let providerID = service.selectedProviderID else { return }
        homeCategoryPickerState.reconcile(providerID: providerID, categories: service.categories)
        browserCategoryPickerState.reconcile(providerID: providerID, categories: service.categories)
        if isShowingCategories || isShowingBrowserCategories {
            resetCategoryPickerPositions(for: providerID)
        }
    }

    // MARK: Search

    func updateSearch() {
        #if os(iOS)
        pagedChannels.reset(service: service, providerID: service.selectedProviderID,
                            catalogRevision: service.channelCatalogRevision,
                            query: searchText, category: selectedCategory,
                            favoritesOnly: favoritesOnly)
        #else
        // Favorites shows one flat list in catalog order; every other screen groups by category.
        searchModel.update(channels: service.channels, query: searchText, category: selectedCategory,
                           favoritesOnly: favoritesOnly, favoriteIDs: service.favoriteChannelIDs,
                           includeGroups: !(favoritesOnly && searchText.isEmpty))
        #endif
        guard let context = browsingContextToRestore,
              context.providerID == service.selectedProviderID,
              let providerID = service.selectedProviderID else { return }
        Task { @MainActor in
            #if os(iOS)
            await pagedChannels.waitForCurrentQuery()
            if let channelID = context.channelID {
                _ = await pagedChannels.restoreAnchor(channelID: channelID, service: service)
            }
            #else
            await searchModel.waitForCurrentSearch()
            #endif
            guard browsingContextToRestore == context, service.selectedProviderID == providerID,
                  service.hasCatalog(for: providerID),
                  showChannelBrowser,
                  searchText == context.searchQuery, selectedCategory == context.category,
                  favoritesOnly == context.favoritesOnly else { return }
            let visibleLists = browserSections.map(\.channels) + [browserMatches]
            if let channelID = context.channelID,
               visibleLists.contains(where: { $0.contains(where: { $0.id == channelID }) }) {
                listPosition.scrollTo(id: channelID, anchor: .top)
            } else if let x = context.offsetX, let y = context.offsetY {
                listPosition.scrollTo(point: CGPoint(x: x, y: y))
            }
            browsingContextToRestore = nil
        }
    }

    // MARK: Browsing context persistence

    /// Adopts the scene's stored snapshots once, then hands back the model's current value for
    /// the scene to store. The model is the authority; scene storage only persists it.
    func syncSavedContexts(from stored: String) -> String {
        if !hasAdoptedSavedContexts {
            hasAdoptedSavedContexts = true
            if savedBrowsingContexts.isEmpty { savedBrowsingContexts = stored }
        }
        return savedBrowsingContexts
    }

    func restoreBrowsingContext(for providerID: UUID?) {
        guard let providerID, restoredContextProviderID != providerID else { return }
        restoredContextProviderID = providerID
        selectedCategory = nil
        favoritesOnly = false
        searchText = ""
        listPosition = ScrollPosition(idType: String.self)
        // A Home snapshot leaves Home showing with clean filters; its position waits in storage
        // until the user re-enters the same browser.
        if let context = storedBrowsingContext(for: providerID), context.shouldPresentBrowser,
           !LiveTVNavigationPolicy.restoresBrowserOnAppear(isTabRoot: hasShellPath) {
            // The browser is pushed, so it never opens by itself. Keep the snapshot as a Home
            // choice: re-entering the same browser still resumes its position.
            storeBrowsingContext(context.returningHome())
            browsingContextToRestore = nil
            changeRoutes("restore Home") { $0.closeBrowser(reason: "restore: pushed browser never reopens itself") }
        } else if let context = storedBrowsingContext(for: providerID), context.shouldPresentBrowser {
            browsingContextToRestore = context
            selectedCategory = context.category
            favoritesOnly = context.favoritesOnly
            searchText = context.searchQuery
            changeRoutes("restore saved browser") { $0.openBrowser(fromCategories: false, source: "restore saved browser") }
        } else {
            browsingContextToRestore = nil
            changeRoutes("restore Home snapshot") { $0.closeBrowser(reason: "restore: Home snapshot") }
        }
        reconcileBrowsingContext()
    }

    private func reconcileBrowsingContext() {
        guard let providerID = service.selectedProviderID,
              let pending = browsingContextToRestore else { return }
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
        browsingContextToRestore = valid
        if selectedCategory != valid.category { selectedCategory = valid.category }
    }

    private func storedBrowsingContext(for providerID: UUID) -> LiveTVBrowsingContext? {
        LiveTVBrowsingContextCollection.decoded(savedBrowsingContexts)?.context(for: providerID)
    }

    func saveBrowsingContext() {
        saveBrowsingContext(for: service.selectedProviderID)
    }

    private func saveBrowsingContext(for providerID: UUID?) {
        guard showChannelBrowser, let providerID else { return }
        storeBrowsingContext(currentBrowsingContext(for: providerID))
    }

    /// The browser as it stands. A restore that has not run yet (its catalog is still loading)
    /// keeps its saved position, so leaving early does not overwrite it with an empty one.
    private func currentBrowsingContext(for providerID: UUID) -> LiveTVBrowsingContext {
        if let pending = browsingContextToRestore, pending.providerID == providerID,
           pending.category == selectedCategory, pending.favoritesOnly == favoritesOnly,
           pending.searchQuery == searchText {
            var context = pending
            context.isBrowserVisible = showChannelBrowser
            return context
        }
        let point = listPosition.point
        return LiveTVBrowsingContext(providerID: providerID, category: selectedCategory,
                                     favoritesOnly: favoritesOnly, searchQuery: searchText,
                                     channelID: listPosition.viewID(type: String.self),
                                     offsetX: point.map { Double($0.x) }, offsetY: point.map { Double($0.y) },
                                     isBrowserVisible: showChannelBrowser)
    }

    private func storeBrowsingContext(_ context: LiveTVBrowsingContext) {
        let collection = LiveTVBrowsingContextCollection.decoded(savedBrowsingContexts) ?? LiveTVBrowsingContextCollection()
        if let encoded = collection.replacing(context).encoded() { savedBrowsingContexts = encoded }
    }
}

// MARK: - Shell registration

/// Registers Live TV Home's typed routes on a shell `NavigationStack`, next to the shell's own
/// `navigationDestination(for: Route.self)`. Apply it to the stack's root content, never inside a
/// tab: a `TabView` child's registrations are invisible to a stack that wraps the `TabView`.
struct LiveTVShellRoutes: ViewModifier {
    let service: LiveTVService
    let path: Binding<NavigationPath>

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: LiveTVHomeRoutes.Destination.self) { route in
                LiveTVRouteDestination(route: route, service: service)
            }
            .environment(\.liveTVRootPath, path)
            .onAppear { LiveTVBrowseModel.model(for: service).attach(rootPath: path) }
            .onChange(of: path.wrappedValue.count) { _, depth in
                LiveTVBrowseModel.model(for: service).reconcile(rootDepth: depth)
            }
    }
}

extension View {
    /// See `LiveTVShellRoutes`. One call per shell stack that can host Live TV.
    func liveTVShellRoutes(service: LiveTVService, path: Binding<NavigationPath>) -> some View {
        modifier(LiveTVShellRoutes(service: service, path: path))
    }
}

/// The screen each Live TV route shows. Exhaustive, so a new route cannot ship without a screen.
enum LiveTVRouteScreen: Equatable {
    case categories
    case channelBrowser

    static func screen(for route: LiveTVHomeRoutes.Destination) -> LiveTVRouteScreen {
        switch route {
        case .categories: .categories
        case .channels: .channelBrowser
        }
    }
}

/// The shell-level destination for a Live TV route.
struct LiveTVRouteDestination: View {
    let route: LiveTVHomeRoutes.Destination
    let service: LiveTVService

    var body: some View {
        let browse = LiveTVBrowseModel.model(for: service)
        Group {
            switch LiveTVRouteScreen.screen(for: route) {
            case .categories:
                LiveTVHomeCategoriesScreen(service: service, browse: browse)
            case .channelBrowser:
                LiveTVChannelBrowserScreen(service: service, browse: browse, isPushed: true)
            }
        }
        .onAppear {
            // Its absence after a "push" line means the route did not resolve to a screen.
            LiveTVNavigationDiagnostics.shared.note("destination resolved \(route.traceName)")
        }
    }
}

// MARK: - Screens (Build 80's views, reading the shared model)

/// Home's Categories page. A choice pushes the channel browser over it.
struct LiveTVHomeCategoriesScreen: View {
    @Bindable var service: LiveTVService
    let browse: LiveTVBrowseModel

    var body: some View {
        LiveTVCategoryBrowserPage(
            providerID: service.selectedProviderID,
            title: "Categories",
            allTitle: "All Channels",
            mode: .browse,
            categories: service.categories,
            channels: service.channels,
            favoriteIDs: service.favoriteChannelIDs,
            catalogRevision: service.channelCatalogRevision,
            indexedDirectory: liveTVIndexedCategoryDirectory(service: service),
            showsFavorites: true,
            initialPosition: browse.homeCategoryPickerPosition,
            select: { browse.chooseFromCategories(LiveTVCategoryNavigation.homeFilters(for: $0)) },
            rememberPosition: { browse.rememberHomeCategoryPosition($0) })
            .navigationBarBackButtonHidden(false)
            .onAppear {
                LiveTVNavigationDiagnostics.shared.record("Categories appeared", before: browse.routes.path,
                                                          after: browse.routes.path)
            }
            .onDisappear {
                LiveTVNavigationDiagnostics.shared.record(
                    browse.routes.showsCategories && !browse.routes.showsBrowser
                        ? "Categories hidden while still routed (presentation or tab change)"
                        : "Categories disappeared; no route mutation",
                    before: browse.routes.path, after: browse.routes.path)
            }
    }
}

/// The channel browser: Search, Favorites, Channels or a category. Pushed on the shell stack, or
/// in place of Home where there is no shell stack.
struct LiveTVChannelBrowserScreen: View {
    @Bindable var service: LiveTVService
    @Bindable var browse: LiveTVBrowseModel
    let isPushed: Bool

    var body: some View {
        if isPushed {
            pushedBrowser
        } else {
            browserPage
        }
    }

    /// The pushed screen: the browser under the system navigation bar. Back, a completed swipe and
    /// a canceled swipe all go through the stack, never a second custom control.
    private var pushedBrowser: some View {
        browserPage
            .navigationBarBackButtonHidden(false)
            .liveTVPageBackground()
            .tint(LiveTVAccent.primaryText)
            .navigationTitle(browse.browserTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if browse.favoritesOnly && browse.searchText.isEmpty {
                    ToolbarItem(placement: .principal) {
                        Text(browse.browserTitle)
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("liveTVFavoritesTitle")
                    }
                }
            }
            .refreshable { await service.refreshSelectedProvider() }
            .sheet(isPresented: Binding(
                get: { browse.isShowingSettings && browse.isBrowserPushed },
                set: { if !$0 { browse.isShowingSettings = false } })) {
                LiveTVSettingsSheet(service: service)
            }
            .modifier(LiveTVChannelCover(service: service, presenter: .list,
                                         isEnabled: browse.isBrowserPushed))
            .onAppear {
                service.presentation.surfaceAppeared(.list)
                LiveTVNavigationDiagnostics.shared.record("Channels appeared / playback returned",
                                                          before: browse.routes.path, after: browse.routes.path)
            }
            .onDisappear {
                LiveTVNavigationDiagnostics.shared.record("Channels disappeared; no route mutation",
                                                          before: browse.routes.path, after: browse.routes.path)
            }
    }

    @ViewBuilder
    private var browserPage: some View {
        if browse.favoritesOnly && browse.searchText.isEmpty {
            favoritesList
        } else {
            browserList
        }
    }

    private var browserList: some View {
        List {
            Section {
                if !isPushed {
                    HStack {
                        Spacer()
                        Text(browse.browserTitle).font(.headline).foregroundStyle(Color.siloOnSurface)
                    }
                }
                providerMenu
            }
            // Sits on the page itself, so the page shows through.
            #if os(iOS)
            .listRowBackground(Color.clear)
            #else
            .listRowBackground(Color.siloBackground)
            #endif
            browserStatus
            if !service.providers.isEmpty {
                Section {
                    Button { browse.openBrowserCategoryPicker() } label: {
                        HStack(spacing: 10) {
                            Label(browse.selectedCategory ?? "All Categories", systemImage: "line.3.horizontal.decrease")
                                .foregroundStyle(LiveTVAccent.primaryText)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.siloSecondaryText)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Category")
                    .accessibilityValue(browse.selectedCategory ?? "All Categories")
                    .accessibilityHint("Chooses which channel category to browse")
                    .accessibilityIdentifier("liveTVBrowserCategory")
                    .listRowBackground(LiveTVSurface.row)
                }
                if browse.browserIsSearching && browse.browserResultCount == 0 {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Loading channels…").foregroundStyle(Color.siloSecondaryText)
                        }
                        .listRowBackground(LiveTVSurface.row)
                    }
                } else if browse.browserResultCount == 0 {
                    Section { ContentUnavailableView.search(text: browse.searchText).listRowBackground(LiveTVSurface.row) }
                } else {
                    ForEach(browse.browserSections) { section in
                        Section(section.category) {
                            ForEach(section.channels) { channel in
                                channelRow(channel)
                                    .onAppear { browse.loadMoreIfNeeded(after: channel) }
                            }
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .scrollPosition($browse.listPosition)
        // Build 82.1: changing category / favorites / search must not keep another list's offset.
        .id(browse.browserListIdentity)
        #if os(iOS)
        .liveTVBrowserSearchField {
            LiveTVChannelSearchField(text: $browse.searchText, isActive: $browse.isSearchPresented)
        }
        #elseif os(tvOS)
        .safeAreaInset(edge: .top, spacing: 0) {
            if browse.isSearchPresented {
                TextField("Search channels", text: $browse.searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 64)
                    .padding(.vertical, 12)
            }
        }
        #endif
        // A pushed page of the browser: choosing applies the filter and pops back; Back or a swipe
        // changes nothing. Declared on this screen, which is itself on the stack.
        .navigationDestination(isPresented: $browse.isShowingBrowserCategories) { browserCategoriesPage }
    }

    private var browserCategoriesPage: some View {
        LiveTVCategoryBrowserPage(
            providerID: service.selectedProviderID,
            title: "Categories",
            allTitle: "All Categories",
            mode: .filter(selected: browse.selectedCategory),
            categories: service.categories,
            channels: service.channels,
            favoriteIDs: service.favoriteChannelIDs,
            catalogRevision: service.channelCatalogRevision,
            indexedDirectory: liveTVIndexedCategoryDirectory(service: service),
            initialPosition: browse.browserCategoryPickerPosition,
            select: { browse.applyBrowserCategoryChoice($0) },
            rememberPosition: { browse.rememberBrowserCategoryPosition($0) })
    }

    /// Provider switching, shown only when more than one provider is configured.
    @ViewBuilder
    private var providerMenu: some View {
        if service.providers.count > 1, let provider = service.selectedProvider {
            Menu {
                ForEach(service.providers) { option in
                    Button { browse.selectProvider(option.id) } label: {
                        if option.id == provider.id {
                            Label(option.name, systemImage: "checkmark")
                        } else { Text(option.name) }
                    }
                }
            } label: {
                Label("Provider: \(provider.name)", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.subheadline)
            }
            .accessibilityLabel("Live TV provider: \(provider.name). Switch provider")
        }
    }

    // MARK: Favorites

    private var favoritesState: LiveTVFavoritesState {
        LiveTVFavoritesState.resolve(contentState: browse.contentState, visibleCount: browse.browserResultCount,
                                     isSearching: browse.browserIsSearching)
    }

    /// The Favorites destination: the starred channels of the active provider, each with what is
    /// on now and next, in catalog order. Tapping plays; the star (or a swipe) removes.
    private var favoritesList: some View {
        List {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    if !isPushed {
                        Text("Favorite Channels")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Color.siloOnSurface)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("liveTVFavoritesTitle")
                    }
                    Spacer()
                    if case .populated(let count) = favoritesState {
                        Text(count == 1 ? "1 channel" : "\(count) channels")
                            .font(.subheadline)
                            .foregroundStyle(Color.siloSecondaryText)
                    }
                }
                #if os(iOS)
                .listRowSeparator(.hidden)
                #endif
                providerMenu
            }
            #if os(iOS)
            .listRowBackground(Color.clear)
            #else
            .listRowBackground(Color.siloBackground)
            #endif
            browserStatus
            switch favoritesState {
            case .unavailable:
                EmptyView()
            case .loading:
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading Favorites…").foregroundStyle(Color.siloSecondaryText)
                    }
                    .listRowBackground(LiveTVSurface.row)
                }
            case .empty:
                Section {
                    ContentUnavailableView {
                        Label("No Favorites Yet", systemImage: "star")
                    } description: {
                        Text(LiveTVFavoritesState.emptyDescription)
                    } actions: {
                        // Stays on this screen and keeps its owner: no extra push or pop.
                        Button("Browse Channels") {
                            browse.enterBrowser(using: .channels, fromCategories: browse.browserOpenedFromCategories)
                        }
                        .tint(LiveTVAccent.primaryText)
                    }
                    .accessibilityIdentifier("liveTVFavoritesEmpty")
                    .listRowBackground(Color.clear)
                }
            case .populated:
                Section {
                    ForEach(browse.browserMatches) { channel in
                        channelRow(channel)
                            .onAppear { browse.loadMoreIfNeeded(after: channel) }
                    }
                }
                .accessibilityIdentifier("liveTVFavoritesList")
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .scrollPosition($browse.listPosition)
        .id(browse.browserListIdentity)
    }

    @ViewBuilder
    private var browserStatus: some View {
        if case .loading = browse.contentState {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading channels…").foregroundStyle(Color.siloSecondaryText)
                }
                .listRowBackground(LiveTVSurface.row)
            }
        } else if case .failed(let error) = browse.contentState {
            Section {
                ContentUnavailableView {
                    Label("Couldn’t Load Channels", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await service.refreshSelectedProvider() } }
                        .tint(LiveTVAccent.primaryText)
                }
                .listRowBackground(LiveTVSurface.row)
            }
        } else if case .setup = browse.contentState {
            Section {
                ContentUnavailableView {
                    Label("Set Up Live TV", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("Add an M3U playlist or Xtream Codes account to browse live channels.")
                } actions: {
                    Button("Add Playlist") { browse.isShowingSettings = true }
                        .buttonStyle(.borderedProminent)
                        .tint(LiveTVAccent.primary)
                }
                .listRowBackground(LiveTVSurface.row)
            }
        } else if case .noChannels = browse.contentState {
            Section {
                ContentUnavailableView(
                    "No Channels",
                    systemImage: "tv",
                    description: Text("Refresh the playlist or check its settings.")
                )
                .listRowBackground(LiveTVSurface.row)
            }
        }
        if service.selectedChannelCount > 0, let error = LiveTVHomeErrorPresentation.message(service.errorMessage) {
            Section {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(Color.siloErrorInk)
                    .listRowBackground(LiveTVSurface.row)
            }
        }
    }

    private func channelRow(_ channel: LiveTVChannel) -> some View {
        HStack(spacing: 12) {
            Button {
                service.choose(channel, from: .list)
            } label: {
                HStack(spacing: 12) {
                    LiveTVChannelLogo(channel: channel, size: CGSize(width: 50, height: 42))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(channel.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.siloOnSurface)
                            .lineLimit(1)
                        if !service.isGuideStale {
                            let pair = service.programPair(for: channel)
                            if let current = pair.current {
                                Text("Now · \(current.title)")
                                    .font(.caption)
                                    .foregroundStyle(Color.siloSecondaryText)
                                    .lineLimit(1)
                            }
                            if let next = pair.next {
                                Text("Next · \(next.title)")
                                    .font(.caption2)
                                    .foregroundStyle(Color.siloSecondaryText.opacity(0.8))
                                    .lineLimit(1)
                            }
                        } else if service.guideMessage != nil || service.isGuideStale {
                            Text("Program guide unavailable")
                                .font(.caption)
                                .foregroundStyle(Color.siloSecondaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "play.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(LiveTVAccent.primaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(channel.name)")

            Button {
                service.toggleFavorite(channel)
            } label: {
                Image(systemName: service.isFavorite(channel) ? "star.fill" : "star")
                    .foregroundStyle(service.isFavorite(channel) ? LiveTVAccent.ember : Color.siloSecondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(service.isFavorite(channel) ? "Remove \(channel.name) from Favorites" : "Add \(channel.name) to Favorites")
        }
        .listRowBackground(LiveTVSurface.row)
    }
}

/// Live TV's own provider settings, in a sheet with its own stack (Home or the pushed browser).
struct LiveTVSettingsSheet: View {
    @Bindable var service: LiveTVService

    var body: some View {
        NavigationStack {
            LiveTVSettingsView(service: service)
        }
        .tint(LiveTVAccent.primaryText)
    }
}
