import SwiftUI
#if os(iOS)
import UIKit
#endif

/// One cover policy for Home, browser, Favorites and the Guide. The presenter still owns the
/// cover; changing the channel never changes its identity or creates another playback session.
struct LiveTVChannelCover: ViewModifier {
    @Bindable var service: LiveTVService
    let presenter: LiveTVPresenter
    let isEnabled: Bool

    /// `isEnabled` gates the cover's binding, never the view tree. Build 79.1: an `if !isEnabled
    /// { content }` branch gave `content` a new identity whenever Home's browser was pushed or
    /// popped, and SwiftUI rebuilt every `navigationDestination` inside it. Popping the channel
    /// browser then also tore down the Categories destination beneath it, so Back went Home.
    func body(content: Content) -> some View {
        if usesWatchScreen {
            #if os(iOS)
            content.fullScreenCover(isPresented: Binding(
                get: { isEnabled && service.presentation.channel(for: presenter) != nil },
                set: { if !$0 && isEnabled { service.presentation.coverDismissed(from: presenter) } }
            )) {
                LiveTVWatchView(service: service)
            }
            #else
            content
            #endif
        } else {
            content.fullScreenCover(item: Binding(
                get: { isEnabled ? service.presentation.coverItem(for: presenter) : nil },
                set: { if $0 == nil && isEnabled { service.presentation.coverDismissed(from: presenter) } }
            )) { cover in
                LiveTVPlayerView(channel: cover.channel, channels: service.channels,
                                 session: service.playerSession, service: service)
            }
        }
    }

    private var usesWatchScreen: Bool {
        #if os(iOS)
        LiveTVWatchScreen.isEnabled(isPhone: UIDevice.current.userInterfaceIdiom == .phone)
        #else
        false
        #endif
    }
}

/// Live TV's names for Kyro's C3 roles. The values live in `KyroTheme`, which
/// the app shell and Kyro's navigation share.
enum LiveTVAccent {
    /// Electric blue: filled controls with white content.
    static let primary = KyroTheme.accent
    /// Electric-blue ink for text, icons and thin indicators on black.
    static let primaryText = KyroTheme.accentInk
    /// Deep blue for glass depth and glows.
    static let depth = KyroTheme.depth
    /// Pink-red, reserved for LIVE.
    static let live = KyroTheme.live
    /// Orange, a restrained accent (favorites).
    static let ember = KyroTheme.highlight
}

/// Live TV's page and row surfaces. On iPhone they are the Media Server's own
/// (Silo's charcoal page canvas and grouped-list rows), read rather than
/// copied, so Live TV follows any change to them. Apple TV and the Mac keep
/// Live TV's black.
enum LiveTVSurface {
    #if os(iOS)
    /// Flat page colour for opaque strips over scrolling content (pinned
    /// search, Guide headers), so they meet the page without a seam.
    static let canvas = Color.siloPageCanvas
    /// A list row, or a Guide channel cell, on the page.
    static let row = Color.siloGroupedCell
    /// A resting Home category tile.
    static let tile = Color.siloGroupedCell
    /// An ended Guide programme: a step below `row`, a step above the page.
    static let pastProgram = Color.siloSurfaceElevated
    /// An upcoming Guide programme.
    static let upcomingProgram = Color.siloGroupedCell
    #else
    static let canvas = Color.siloBackground
    static let row = Color.siloSurface
    static let tile = Color.siloSurfaceElevated
    static let pastProgram = Color.siloSurface.opacity(0.55)
    static let upcomingProgram = Color.siloSurfaceElevated
    #endif
}

extension View {
    /// The page behind a Live TV screen: the Media Server's page backdrop on
    /// iPhone, black elsewhere.
    @ViewBuilder
    func liveTVPageBackground() -> some View {
        #if os(iOS)
        siloPageBackground()
        #else
        background(Color.siloBackground)
        #endif
    }
}

#if os(iOS)
/// The channel browser's search field, pinned to the top of the list.
///
/// The browser used `.searchable`. It appears when the browser replaces Home
/// on the same page, and iOS 26 then puts the field in a bottom toolbar
/// whatever placement is asked for: a glass bar along the bottom under the
/// floating navigation, holding the bottom safe area and its touches, and
/// hidden by the Classic tab bar. The Guide, pushed with its search, keeps
/// the system drawer. Same text and the same presented state as before, so
/// the Search destination and the header's search button work unchanged.
struct LiveTVChannelSearchField: View {
    private static let edgeFade: CGFloat = 16

    @Binding var text: String
    @Binding var isActive: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.siloSecondaryText)
                    .accessibilityHidden(true)
                TextField("Search channels", text: $text)
                    .focused($isFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .foregroundStyle(Color.siloOnSurface)
                    .accessibilityIdentifier("liveTVChannelSearch")
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color.siloSecondaryText)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color.white.opacity(0.09), in: Capsule())
            if isActive {
                Button("Cancel") {
                    text = ""
                    isActive = false
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // Flat canvas over the scrolling rows, fading out below the strip so it meets
        // the page's soft wash without an edge.
        .background {
            LiveTVSurface.canvas
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: Self.edgeFade)
                    }
                }
                .padding(.bottom, -Self.edgeFade)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.2), value: isActive)
        .onChange(of: isActive, initial: true) { _, active in
            if isFocused != active { isFocused = active }
        }
        .onChange(of: isFocused) { _, focused in
            if focused != isActive { isActive = focused }
        }
    }
}
#endif

enum LiveTVNavigationBackDestination: Equatable {
    case home
    case exitLiveTV
}

/// Where Live TV draws the one control that leaves its current screen.
enum LiveTVBackPlacement: Equatable {
    /// Live TV Home as a tab root has nothing behind it, so it draws no Back.
    case none
    /// The channel browser as a tab root's pushed screen: the system navigation bar and its Back
    /// (and edge swipe), exactly as the Guide has.
    case system
    /// The navigation bar, where Live TV is pushed onto the app's stack.
    case toolbar
}

enum LiveTVNavigationPolicy {
    static func backDestination(showingBrowser: Bool) -> LiveTVNavigationBackDestination {
        showingBrowser ? .home : .exitLiveTV
    }

    static func backLabel(showingBrowser: Bool) -> String {
        showingBrowser ? "Back to Live TV Home" : "Back"
    }

    /// Home and the channel browser (Search, Favorites, Channels, a category) share one page.
    /// The Guide is pushed and uses the system Back alone, in every shell.
    static func homeBackPlacement(isTabRoot: Bool, showingBrowser: Bool) -> LiveTVBackPlacement {
        guard isTabRoot else { return .toolbar }
        return showingBrowser ? .system : .none
    }

    /// Under Kyro's unified shell the browser is a real screen pushed onto the app's stack, so the
    /// system's interactive edge swipe can pop it. Everywhere else it replaces Home's content.
    static func pushesBrowser(isTabRoot: Bool) -> Bool { isTabRoot }

    /// Whether the browser is on the stack now. Only the one `showChannelBrowser` flag decides.
    static func isBrowserPushed(isTabRoot: Bool, showingBrowser: Bool) -> Bool {
        pushesBrowser(isTabRoot: isTabRoot) && showingBrowser
    }

    /// The stack reported the pushed browser gone (the Back button, or a completed edge swipe).
    /// A canceled swipe reports nothing, and a report that arrives after Live TV already went Home
    /// (a programmatic exit) changes nothing, so Back never runs twice.
    static func shouldReturnHome(stackShowsBrowser: Bool, showingBrowser: Bool) -> Bool {
        !stackShowsBrowser && showingBrowser
    }

    /// A restored "browser was open" snapshot must not push a screen during launch, restoration or
    /// a tab switch. Where the browser is pushed it reopens only by the user's own action.
    static func restoresBrowserOnAppear(isTabRoot: Bool) -> Bool { !pushesBrowser(isTabRoot: isTabRoot) }
}

struct LiveTVView: View {
    @Bindable var service: LiveTVService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// The shell stack's path. Categories and the channel browser are typed routes on it, resolved
    /// where the shell registers its destinations (`liveTVShellRoutes`), never inside this tab.
    @Environment(\.liveTVRootPath) private var rootNavigationPath
    @State private var showingNavigationDiagnostics = false
    @State private var isShowingGuide = false
    @SceneStorage("liveTV.listBrowsingContext.v1") private var savedBrowsingContext = ""

    /// Build 82: the one owner of browsing state, shared with the shell-level Categories and
    /// channel-browser screens. Home here only reads it and sends intents.
    private var browse: LiveTVBrowseModel { LiveTVBrowseModel.model(for: service) }

    /// Set when Kyro's shell draws the one header, so Live TV draws none of its own.
    #if os(iOS)
    @Environment(\.kyroShellHeader) private var shellHeader
    #endif

    /// Kyro's unified navigation hosts Live TV as a tab, with nothing behind it to go back to.
    private var isTabRoot: Bool {
        #if os(iOS)
        KyroUnifiedNavigation.isActive
        #else
        false
        #endif
    }

    /// The shell's header context while Live TV is its tab; nil when Live TV is pushed.
    private var hostedHeader: (runway: CGFloat, scrollState: PageChromeScrollState)? {
        #if os(iOS)
        guard isTabRoot, let shellHeader else { return nil }
        return (shellHeader.runway, shellHeader.scrollState(for: .liveTV))
        #else
        return nil
        #endif
    }

    private var backPlacement: LiveTVBackPlacement {
        LiveTVNavigationPolicy.homeBackPlacement(isTabRoot: isTabRoot, showingBrowser: browse.showChannelBrowser)
    }

    var body: some View {
        // A ZStack rather than a Group: Group would hand these appear/disappear handlers to each
        // branch, so switching between Home and the browser would cancel search and save state.
        ZStack {
            if browse.showChannelBrowser && rootNavigationPath == nil {
                LiveTVChannelBrowserScreen(service: service, browse: browse, isPushed: false)
            } else {
                LiveTVHomeContent(model: homeModel, epg: homeEPG, actions: homeActions,
                                  topRunway: hostedHeader?.runway ?? 0,
                                  scrollState: hostedHeader?.scrollState)
            }
        }
        // Inside the navigation too, so Classic's tab shows the page rather than its own black.
        .liveTVPageBackground()
        #if os(iOS)
        .kyroLiveTVNavigation(isEnabled: !service.providers.isEmpty, active: activeNavigationDestination,
                              navigate: navigate(to:))
        #endif
        .liveTVPageBackground()
        .tint(LiveTVAccent.primaryText)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            if backPlacement == .toolbar {
                LiveTVHomeToolbar(back: handleBack,
                                  backLabel: LiveTVNavigationPolicy.backLabel(showingBrowser: browse.showChannelBrowser),
                                  search: { performHeaderAction(.search) },
                                  guide: { performHeaderAction(.guide) },
                                  settings: { performHeaderAction(.settings) })
            }
        }
        .refreshable { await service.refreshSelectedProvider() }
        // Home presents Settings; once the browser is pushed it presents its own (a sheet from a
        // screen the browser covers would not appear).
        .sheet(isPresented: Binding(
            get: { browse.isShowingSettings && !browse.isBrowserPushed },
            set: { if !$0 { browse.isShowingSettings = false } })) {
            LiveTVSettingsSheet(service: service)
        }
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                if LiveTVNavigationDiagnostics.isAvailable {
                    Button("Navigation Diagnostics", systemImage: "stethoscope") { showingNavigationDiagnostics = true }
                }
            }
        }
        .sheet(isPresented: $showingNavigationDiagnostics) { LiveTVNavigationDiagnosticsView() }
        // The Guide stays a Boolean push from Home; it never shared the Categories routes.
        .navigationDestination(isPresented: $isShowingGuide) {
            #if os(iOS)
            LiveTVGuideView(service: service, navigation: KyroLiveTVNavigationRoute(
                isEnabled: !service.providers.isEmpty, navigate: navigate(to:)))
            #else
            LiveTVGuideView(service: service)
            #endif
        }
        .modifier(LiveTVChannelCover(service: service, presenter: .list,
                                     isEnabled: !browse.isBrowserPushed))
        .task(id: service.selectedProviderID) {
            prepareBrowse()
            await service.prepareSelectedProvider()
        }
        .onAppear {
            prepareBrowse()
            service.presentation.surfaceAppeared(.list)
        }
        .onDisappear {
            // A tab stays alive while another tab shows, and Home stays beneath its own pushed
            // Categories or browser. Saving or cancelling there re-renders the hidden list (and
            // would cancel the search the pushed browser just started); backgrounding still saves.
            guard !isTabRoot && !browse.hasPushedRoutes else {
                // Covered by its own pushed browser, which presents the player in its place; Live
                // TV is still the visible surface, so the presentation keeps counting it.
                if !browse.isBrowserPushed { service.presentation.surfaceDisappeared(.list) }
                return
            }
            browse.saveBrowsingContext()
            browse.searchModel.cancel()
            service.presentation.surfaceDisappeared(.list)
        }
        .onChange(of: browse.searchText) { _, query in
            if !query.isEmpty, !browse.showChannelBrowser {
                browse.enterBrowser(using: .search(query: query), resumingSavedPosition: false)
            }
            browse.updateSearch()
        }
        .onChange(of: browse.selectedCategory) { browse.updateSearch() }
        .onChange(of: browse.favoritesOnly) { browse.updateSearch() }
        .onChange(of: service.favoriteChannelIDs) { browse.updateSearch() }
        .onChange(of: service.channelCatalogRevision) { browse.catalogDidChange() }
        .onChange(of: service.selectedProviderID) { _, providerID in browse.providerDidChange(to: providerID) }
        .onChange(of: browse.savedBrowsingContexts) { _, contexts in
            if savedBrowsingContext != contexts { savedBrowsingContext = contexts }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { browse.saveBrowsingContext() } }
    }

    /// Scene storage is adopted once, the shell path attached (the shell modifier attaches the
    /// same one), then the provider's saved browser restored as in Build 80.
    private func prepareBrowse() {
        let contexts = browse.syncSavedContexts(from: savedBrowsingContext)
        if contexts != savedBrowsingContext { savedBrowsingContext = contexts }
        if let rootNavigationPath { browse.attach(rootPath: rootNavigationPath) }
        browse.restoreBrowsingContext(for: service.selectedProviderID)
        browse.updateSearch()
    }

    // MARK: Home

    /// Built from the bounded provider-scoped preview the service already keeps; no catalog scan.
    private var homeModel: LiveTVHomeModel {
        LiveTVHomeModel(
            providers: service.providers,
            selectedProviderID: service.selectedProviderID,
            channelCount: service.selectedChannelCount,
            isLoading: service.isLoading,
            contentState: browse.contentState,
            errorMessage: service.selectedChannelCount == 0 ? nil : LiveTVHomeErrorPresentation.message(service.errorMessage),
            sections: LiveTVHomeSections(recents: service.homeRecentChannels,
                                         favorites: service.homeFavoriteChannels,
                                         isPlayable: { service.canPlay($0) }),
            upNext: service.homeUpNext,
            categories: service.categories,
            carouselEnabled: !browse.showChannelBrowser && !browse.isShowingCategories && !browse.isShowingSettings
                && !isShowingGuide && scenePhase == .active && service.presentation.phase == .idle)
    }

    private var homeEPG: LiveTVHomeEPG {
        LiveTVHomeEPG { [service] channel, date in
            service.isGuideStale ? nil : service.programPair(for: channel, at: date).current
        }
    }

    private var homeActions: LiveTVHomeActions {
        let browse = browse
        return LiveTVHomeActions(
            play: { service.choose($0, from: .list) },
            toggleFavorite: { service.toggleFavorite($0) },
            browse: { browse.enterBrowser(using: $0) },
            showAllCategories: { browse.openHomeCategoryPicker() },
            showGuide: { performHeaderAction(.guide) },
            showSettings: { performHeaderAction(.settings) },
            selectProvider: { browse.selectProvider($0) },
            retry: { Task { await service.refreshSelectedProvider() } },
            isFavorite: { service.isFavorite($0) },
            loadPrograms: { channel in
                guard !service.isGuideStale else { return LiveTVProgramPair(current: nil, next: nil) }
                return service.programPair(for: channel)
            })
    }

    private func handleBack() {
        switch LiveTVNavigationPolicy.backDestination(showingBrowser: browse.showChannelBrowser) {
        case .home:
            browse.returnHome(reason: "toolbar Back")
        case .exitLiveTV:
            dismiss()
        }
    }

    private func performHeaderAction(_ action: LiveTVHomeHeaderAction) {
        let browse = browse
        action.activate(
            search: {
                browse.enterBrowser(using: .search(query: browse.searchText), resumingSavedPosition: false)
                // The field belongs to the browser List, which may only appear in this update.
                Task { @MainActor in browse.isSearchPresented = true }
            },
            guide: { isShowingGuide = true },
            settings: { browse.isShowingSettings = true })
    }

#if os(iOS)
    // MARK: Kyro floating navigation

    private var activeNavigationDestination: KyroLiveTVDestination {
        KyroLiveTVActiveDestination.resolve(showingGuide: isShowingGuide, showingBrowser: browse.showChannelBrowser,
                                            searching: browse.isSearchPresented || !browse.searchText.isEmpty,
                                            favoritesOnly: browse.favoritesOnly)
    }

    /// Reaches the screens Live TV already has, through the same paths as the header and Home.
    private func navigate(to destination: KyroLiveTVDestination) {
        let browse = browse
        let leavingGuide = isShowingGuide && destination != .guide
        switch destination {
        case .home:
            isShowingGuide = false
            if browse.showChannelBrowser { browse.returnHome(reason: "Live TV navigation Home") }
        case .guide:
            isShowingGuide = true
        case .favorites:
            isShowingGuide = false
            browse.isSearchPresented = false
            browse.enterBrowser(using: .favorites)
        case .channels:
            isShowingGuide = false
            browse.isSearchPresented = false
            browse.enterBrowser(using: .channels)
        case .search:
            isShowingGuide = false
            browse.enterBrowser(using: .search(query: browse.searchText), resumingSavedPosition: false)
            Task { @MainActor in
                // The search field belongs to the browser List; after leaving the Guide it
                // exists only once the pop has finished.
                if leavingGuide { try? await Task.sleep(for: .milliseconds(450)) }
                browse.isSearchPresented = true
            }
        case .sportsHub:
            // Never offered until a Sports Hub exists (`KyroLiveTVDestination.isAvailable`).
            break
        }
    }
#endif
}

/// A channel's logo, or a TV placeholder when it has none.
struct LiveTVChannelLogo: View {
    let channel: LiveTVChannel
    let size: CGSize
    /// `.clear` draws logos straight onto a colored card, with no tile behind a missing one.
    var placeholderStyle: ImagePlaceholderStyle = .surface

    var body: some View {
        if let logoURL = channel.logoURL {
            AsyncImageView(url: logoURL.absoluteString, targetSize: size, contentMode: .fit,
                           placeholderStyle: placeholderStyle, placeholderSymbol: "tv")
                .frame(width: size.width, height: size.height)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "tv")
                .font(placeholderStyle == .clear ? .largeTitle : .title3)
                .foregroundStyle(placeholderStyle == .clear ? Color.white.opacity(0.85) : LiveTVAccent.primaryText)
                .frame(width: size.width, height: size.height)
                .background(placeholderStyle == .clear ? Color.clear : Color.siloSurfaceElevated,
                            in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
        }
    }
}

/// How the shared Live TV provider settings view is presented.
enum LiveTVSettingsPresentation: Equatable {
    /// In its own sheet and navigation stack; closes after a provider is saved.
    case sheet
    /// A Settings subpage with system Back; stays open after a provider is saved.
    case pushed

    var showsDoneButton: Bool { self == .sheet }
    var dismissesAfterSavingProvider: Bool { self == .sheet }
}

struct LiveTVSettingsView: View {
    @Bindable var service: LiveTVService
    #if os(iOS)
    @AppStorage(IPTVVODPreference.key) private var iptvVODEnabled = false
    #endif
    /// A sheet (Live TV's own setup) or a subpage of Settings. See `LiveTVSettingsPresentation`.
    var presentation: LiveTVSettingsPresentation = .sheet
    @Environment(\.dismiss) private var dismiss
    @State private var providerName = "My Playlist"
    @State private var playlistURL = ""
    @State private var xmltvURL = ""
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var providerKind: LiveTVProviderKind = .m3u
    @State private var errorMessage: String?
    @State private var providerToRemove: LiveTVProvider?
    // Performance overlay, the playback log and the internal test toggles
    // live in Settings → Advanced & Diagnostics → Live TV Diagnostics.

    var body: some View {
        Form {
            Section("Provider & Catalog") {
                if let provider = service.selectedProvider {
                    LabeledContent("Active provider", value: provider.name)
                    LabeledContent("Imported channels", value: provider.channelCount.formatted())
                    LabeledContent("Import limit", value: "\(LiveTVChannelSnapshotStore.maximumChannels.formatted()) channels")
                    if let notice = service.catalogNotice {
                        Label(notice, systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(Color.siloSecondaryText)
                    }
                    LabeledContent("Catalog status", value: LiveTVCatalogStatus(truncated: provider.catalogWasTruncated).rawValue)
                    Button {
                        Task { await service.refreshSelectedProvider() }
                    } label: {
                        HStack {
                            Label("Refresh Playlist", systemImage: "arrow.clockwise")
                            Spacer()
                            if service.isLoading { ProgressView() }
                        }
                    }
                    .disabled(service.isLoading)
                } else {
                    Text("Add a provider to view catalog details.").foregroundStyle(Color.siloSecondaryText)
                }
            }

#if os(iOS)
            Section {
                Toggle("Show IPTV Movies & Series", isOn: $iptvVODEnabled)
                    .onChange(of: iptvVODEnabled) { _, enabled in
                        IPTVVODPreference.setEnabled(enabled)
                    }
                    .accessibilityIdentifier("kyroIPTVVODToggle")
                if iptvVODEnabled {
                    if let provider = service.selectedProvider, provider.kind == .xtream {
                        KyroIPTVCatalogStatusView(provider: provider, emphasis: .settings)
                    } else {
                        Text("Select an Xtream Codes provider above. Movies and Series come from Xtream providers only.")
                            .font(.footnote).foregroundStyle(Color.siloSecondaryText)
                    }
                }
            } header: {
                Text("IPTV Movies & Series")
            } footer: {
                Text(iptvVODEnabled
                     ? "Turning this off hides IPTV titles and keeps the imported catalogs, your provider and Live TV."
                     : "Off by default. When on, your Xtream provider appears in the library selector of the Movies and Series tabs, beside your Silo libraries.")
            }
            if KyroLiveTVNavigationSettingsPolicy.offersStylePicker(
                unifiedShellActive: KyroUnifiedNavigation.isActive, isSupported: KyroLiveTVNavigation.isSupported) {
                Section("Navigation") {
                    NavigationLink {
                        KyroLiveTVNavigationSettingsView(store: .shared)
                    } label: {
                        LabeledContent {
                            Text(KyroLiveTVNavigationStore.shared.preferences.style.title)
                        } label: {
                            Label("Navigation", systemImage: "hand.point.up.left")
                        }
                    }
                    .accessibilityIdentifier("kyroLiveTVNavigationSettingsLink")
                }
            }
#endif

            Section("Providers") {
                if service.providers.isEmpty {
                    Text("No providers configured.")
                        .foregroundStyle(Color.siloSecondaryText)
                }
                ForEach(service.providers) { provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(provider.name)
                            Text("\(provider.kind == .m3u ? "M3U" : "Xtream") · \(provider.channelCount.formatted()) channels")
                                .font(.caption).foregroundStyle(Color.siloSecondaryText)
                        }
                        Spacer()
                        if provider.id == service.selectedProviderID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(LiveTVAccent.primaryText)
                        }
                        Button(role: .destructive) { providerToRemove = provider } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(provider.name)")
                    }
                }
                #if os(iOS)
                KyroSendToAppleTVRow(service: service)
                #endif
            }

            Section("Add IPTV Provider") {
                Picker("Provider type", selection: $providerKind) {
                    Text("M3U Playlist").tag(LiveTVProviderKind.m3u)
                    Text("Xtream Codes").tag(LiveTVProviderKind.xtream)
                }
                .pickerStyle(.segmented)
                TextField("Provider name", text: $providerName)
                    .textContentType(.name)
                if providerKind == .m3u {
                    TextField("Playlist URL (HTTP or HTTPS)", text: $playlistURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("XMLTV guide URL (optional)", text: $xmltvURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Text("Playlist and guide addresses are stored in Keychain.")
                } else {
                    TextField("Server URL (HTTP or HTTPS, optional port)", text: $serverURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Credentials are stored in Keychain and sent only to this provider. HTTP connections are not encrypted.")
                }
                Text("Provider settings are fetched only when added or when you refresh Live TV.")
                    .font(.footnote)
                    .foregroundStyle(Color.siloSecondaryText)
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(Color.siloErrorInk)
                }
                Button("Save Provider") { saveProvider() }
                    .disabled(providerKind == .m3u
                              ? playlistURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              : serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || username.isEmpty || password.isEmpty)
            }

        }
        .scrollContentBackground(.hidden)
        .background(Color.siloBackground)
        .navigationTitle("Live TV Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if presentation.showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .confirmationDialog(
            "Remove \(providerToRemove?.name ?? "provider")?",
            isPresented: Binding(
                get: { providerToRemove != nil },
                set: { if !$0 { providerToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Provider", role: .destructive) {
                if let providerToRemove { Task { await service.removeProvider(providerToRemove.id) } }
                providerToRemove = nil
            }
        }
    }

    private func saveProvider() {
        do {
            if providerKind == .m3u {
                _ = try service.saveConfiguration(name: providerName, playlistURL: playlistURL, xmltvURL: xmltvURL)
            } else {
                _ = try service.saveXtreamConfiguration(name: providerName, serverURL: serverURL,
                                                       username: username, password: password)
            }
            if presentation.dismissesAfterSavingProvider {
                dismiss()
            } else {
                // A subpage of Settings stays put, with the new provider now in its list.
                errorMessage = nil
                providerName = "My Playlist"
                playlistURL = ""; xmltvURL = ""; serverURL = ""; username = ""; password = ""
            }
        } catch let error as LiveTVError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "The provider could not be saved."
        }
    }
}
