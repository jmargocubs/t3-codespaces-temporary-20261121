#if DEBUG
import SwiftUI

/// Debug builds only: `-kyroDebugLiveTVFixture` opens the real Live TV
/// screens over a fictional provider, so the floating navigation, header and
/// hero can be exercised on a simulator with no server and no IPTV
/// credentials. The playlist and guide are served in-process by a URL
/// protocol; nothing leaves the machine, and the fixture keeps its own
/// defaults suite and temporary files, apart from the user's Live TV data.
/// Nothing here exists in Release builds.
///
/// Optional arguments set the navigation up before the screen appears:
/// `-kyroDebugLiveTVNavReset`, `-kyroDebugLiveTVNavStyle classic|glassDock|thumbFan`,
/// `-kyroDebugGlobalNavigationReset`, `-kyroDebugFourthTab sports|forYou|favorites`,
/// `-kyroDebugLiveTVNavEdge left|right|top|bottom`,
/// `-kyroDebugLiveTVNavPosition 0…1`,
/// `-kyroDebugLiveTVNavIdle stayVisible|collapse|collapseAndFade`, `-kyroDebugLiveTVNavNoDrag`
/// and `-kyroDebugLiveTVNavExpanded`.
struct KyroDebugLiveTVFixtureRouteModifier: ViewModifier {
    static let launchArgument = "-kyroDebugLiveTVFixture"

    let isEnabled: Bool

    @State private var service: LiveTVService?
    @State private var didPresent = false

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: Binding(get: { service != nil }, set: { if !$0 { service = nil } })) {
                if let service {
                    Group {
                        if CommandLine.arguments.contains("-kyroDebugSearchFixture") {
                            KyroDebugSearchFixtureStack(service: service)
                        } else if KyroUnifiedNavigation.isActive {
                            KyroDebugUnifiedShell(service: service)
                        } else {
                            KyroDebugLiveTVFixtureStack(service: service)
                        }
                    }
                    .task {
                        // `-kyroDebugLiveTVNoFavorites` leaves the lineup empty, for the empty state.
                        guard !CommandLine.arguments.contains("-kyroDebugLiveTVNoFavorites"),
                              !CommandLine.arguments.contains("-kyroDebugSearchFixture") else { return }
                        await KyroDebugLiveTVFixture.seedFavorites(in: service)
                    }
                }
            }
            .onChange(of: isEnabled, initial: true) { _, enabled in
                guard enabled, !didPresent, CommandLine.arguments.contains(Self.launchArgument) else { return }
                didPresent = true
                KyroDebugLiveTVFixture.applyNavigationArguments(to: .shared)
                KyroDebugLiveTVFixture.applyGlobalNavigationArguments(to: .shared)
                service = KyroDebugLiveTVFixture.makeService()
            }
    }
}

private struct KyroDebugSearchFixtureStack: View {
    let service: LiveTVService
    @State private var router = AppRouter()
    /// Set from the first frame, so Search shows results instead of focusing its field (and keyboard).
    @State private var seededQuery = KyroDebugLiveTVFixture.value(after: "-kyroDebugSearchQuery")
        .map { AppRouter.SearchRequest(query: $0) }

    var body: some View {
        NavigationStack {
            SearchView(
                seededQuery: $seededQuery,
                liveTVService: service,
                programSearchEnabled: !CommandLine.arguments.contains("-kyroDebugSearchNoPrograms")
            )
            .environment(router)
            .tint(KyroTheme.shellTint)
            .overlay(alignment: .topLeading) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("kyroDebugSearchWatching")
                    .accessibilityLabel(service.presentation.activeChannel?.name ?? "none")
                    .allowsHitTesting(false)
            }
        }
        .task {
            // What Live TV does on appear: load the fixture playlist and guide. Search re-runs the
            // seeded query when the catalog and guide arrive.
            await service.prepareSelectedProvider()
            await removeProviderIfRequested()
        }
    }

    @MainActor
    private func removeProviderIfRequested() async {
        guard let seconds = KyroDebugLiveTVFixture.value(after: "-kyroDebugSearchRemoveProviderAfter")
                .flatMap(Double.init) else { return }
        try? await Task.sleep(for: .seconds(seconds))
        guard let providerID = service.selectedProviderID else { return }
        await service.removeProvider(providerID)
    }
}

/// The app pushes Live TV onto the main navigation stack, whose root is the
/// Media Server's tab bar (`MainTabView`), so the fixture does the same: the
/// stack's back-swipe gestures and the shell's `SiloTabBar` sit around Live TV
/// exactly as on a device. `-kyroDebugLiveTVFixtureRoot` makes Live TV the
/// stack's root instead (the Build 14 arrangement).
private struct KyroDebugLiveTVFixtureStack: View {
    let service: LiveTVService
    // A `NavigationPath`, like the app's shell, so Live TV's typed Categories and channel routes
    // can share it with the fixture's `Int` routes.
    @State private var path = NavigationPath(CommandLine.arguments.contains("-kyroDebugLiveTVFixtureRoot") ? [] : [0])
    @State private var tab = AppTab.home.id

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if path.isEmpty && CommandLine.arguments.contains("-kyroDebugLiveTVFixtureRoot") {
                    LiveTVView(service: service)
                } else {
                    SiloTabBar(items: AppTab.visibleCases, selection: $tab, title: \.rawValue, icon: \.icon,
                               selectedIcon: \.selectedIcon) { _ in
                        Button("Open Live TV") { path = NavigationPath([0]) }
                            .accessibilityIdentifier("kyroDebugOpenLiveTV")
                    }
                    .tint(KyroTheme.shellTint)
                }
            }
            .navigationDestination(for: Int.self) { _ in
                LiveTVView(service: service).environment(\.liveTVRootPath, $path)
            }
            .liveTVShellRoutes(service: service, path: $path)
        }
    }
}

/// On iPhone by default (not with `-kyro.navigation.legacyShell YES`), exercises the five global
/// destinations, one selection store, and secondary More routes.
/// `-kyroDebugUnifiedMiniPlayer` attaches a stand-in to the tab bar's bottom
/// accessory, where `NowPlayingShelfAttachment` puts the real Now Playing
/// shelf. `-kyroDebugUnifiedStartOnLiveTV` opens on Live TV.
/// `-kyroDebugUnifiedSelectAfter SECONDS TAB` selects a Media tab later, as
/// `MainTabView` does for a deep link or Siri. `-kyroDebugUnifiedFavoriteWhileHidden`
/// and `-kyroDebugUnifiedRefreshWhileHidden` change Live TV's favorites or
/// reload its playlist while another tab shows.
private struct KyroDebugUnifiedShell: View {
    let service: LiveTVService
    @State private var path = NavigationPath()
    @State private var store = KyroGlobalNavigationStore.shared
    /// The shell's one header, as `MainTabView` hosts it: a real `KyroAppHeader` over the tab bar.
    @State private var router = AppRouter()
    @State private var scrollStates = KyroShellScrollStates()
    @State private var siloControl = SiloControlClient()

    private var items: [MainTabDestination] {
        store.tabDestinations
            .filter { $0 != .liveTV }
            .map(MainTabDestination.global)
    }

    private var selection: Binding<MainTabDestinationID> {
        Binding(
            get: { kyroGlobalDestinationID(store.selectedDestination) },
            set: { id in
                if let destination = kyroGlobalDestination(for: id) {
                    store.selectIfTab(destination)
                }
            }
        )
    }

    private var moreMenu: KyroMoreMenuContext {
        KyroMoreMenuContext(items: [
            KyroMoreMenuItem(id: "fixture-downloads", title: "Downloads", systemImage: "arrow.down.circle") {
                path.append(10)
            },
            KyroMoreMenuItem(id: "fixture-calendar", title: "Calendar", systemImage: "calendar") {
                path.append(11)
            },
        ])
    }

    var body: some View {
        NavigationStack(path: $path) {
            SiloTabBar(items: items, selection: selection, title: \.title, icon: \.icon,
                       selectedIcon: \.selectedIcon) { destination in
                if destination.id == .liveTV {
                    LiveTVView(service: service)
                } else if case .kyroRoot(let page) = destination.id {
                    KyroRootPageView(page: page)
                } else {
                    KyroDebugUnifiedMediaPage(title: destination.title) { path.append(1) }
                }
            }
            .environment(\.kyroShellHeader, KyroShellHeaderContext(
                scrollStates: scrollStates, runway: KyroShellHeader.runway(hasStatusColumn: false)))
            .navigationDestination(for: Int.self) { value in
                if value == 11 {
                    // Calendar's shape: a root page that hides the bar, pushed from More.
                    KyroDebugUnifiedMediaPage(title: "Calendar") { path.append(1) }
                        .environment(\.secondaryDestinationTitle, "Calendar")
                } else {
                    Text("Media Detail")
                        .font(.title2.weight(.semibold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(SiloPageBackdrop())
                        .navigationTitle("Media Detail")
                        .accessibilityIdentifier("kyroDebugMediaDetail")
                }
            }
            .modifier(KyroDebugMiniPlayerStandIn())
            .environment(\.kyroMoreMenu, moreMenu)
            .overlay(alignment: .top) {
                KyroAppHeader(router: router, scrollStates: scrollStates, store: store)
            }
            .liveTVShellRoutes(service: service, path: $path)
        }
        .environment(router)
        .environment(siloControl)
        .tint(KyroTheme.shellTint)
        .environment(\.kyroShellTab, .liveTV(store: store, service: service))
        .onAppear {
            if CommandLine.arguments.contains("-kyroDebugUnifiedStartOnLiveTV") { store.selectedDestination = .liveTV }
            // Opens the real Sports Hub tab (the fixture shell hosts `KyroRootPageView`).
            if CommandLine.arguments.contains("-kyroDebugUnifiedStartOnSports") { store.selectIfTab(.sports) }
        }
        .task { await selectLater() }
        .onChange(of: store.selectedDestination) { _, selected in
            guard selected != .liveTV else { return }
            Task { await changeLiveTVWhileHidden() }
        }
    }

    private func selectLater() async {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-kyroDebugUnifiedSelectAfter"), arguments.indices.contains(index + 2),
              let seconds = Double(arguments[index + 1]), let target = AppTab(rawValue: arguments[index + 2]) else { return }
        try? await Task.sleep(for: .seconds(seconds))
        switch target {
        case .home: store.selectedDestination = .home
        case .libraries: store.selectedDestination = .movies
        case .recommendations: store.selectIfTab(.forYou)
        default: break
        }
    }

    private func changeLiveTVWhileHidden() async {
        let arguments = CommandLine.arguments
        let favorite = arguments.contains("-kyroDebugUnifiedFavoriteWhileHidden")
        let refresh = arguments.contains("-kyroDebugUnifiedRefreshWhileHidden")
        guard favorite || refresh else { return }
        try? await Task.sleep(for: .seconds(1.5))
        guard store.selectedDestination != .liveTV else { return }
        if favorite, let channel = service.channels.first(where: { $0.name == "Golf Channel One" }) {
            service.toggleFavorite(channel)
        }
        if refresh { await service.refreshSelectedProvider() }
    }
}

private struct KyroDebugUnifiedMediaPage: View {
    let title: String
    let push: () -> Void
    @Environment(\.kyroShellHeader) private var shellHeader

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let shellHeader {
                    // The shell's header floats over the page; leave its runway, as Home does.
                    Color.clear.frame(height: shellHeader.runway)
                }
                HStack {
                    Text(title)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Color.siloOnSurface)
                    Spacer()
                    if shellHeader == nil { KyroMoreMenuButton() }
                }
                Button("Push Media Screen", action: push)
                    .accessibilityIdentifier("kyroDebugPushMedia")
                ForEach(0..<80, id: \.self) { row in
                    Text("\(title) row \(row)")
                        .foregroundStyle(Color.siloOnSurface)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .accessibilityIdentifier("kyroDebugMediaRow.\(row)")
                }
            }
            .padding(.horizontal, SiloTheme.padding)
        }
        .background(SiloPageBackdrop())
        .rootPageNavigationBar()
        .accessibilityIdentifier("kyroDebugMediaPage.\(title)")
    }
}

private struct KyroDebugMiniPlayerStandIn: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.1, *), CommandLine.arguments.contains("-kyroDebugUnifiedMiniPlayer") {
            content.tabViewBottomAccessory {
                Label("Now Playing stand-in", systemImage: "play.fill")
                    .accessibilityIdentifier("kyroDebugMiniPlayer")
            }
        } else {
            content
        }
    }
}

enum KyroDebugLiveTVFixture {
    static let host = "fixture.kyro.invalid"

    @MainActor
    static func makeService() -> LiveTVService? {
        let suite = "kyro.debug.liveTVFixture"
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        defaults.removePersistentDomain(forName: suite)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KyroLiveTVFixture", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KyroFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let epg = EPGService(cache: EPGCacheStore(directory: directory.appendingPathComponent("guide", isDirectory: true)),
                             loader: URLSessionEPGFeedLoader(session: session))
        let service = LiveTVService(defaults: defaults, secretStore: KyroFixtureSecretStore(), session: session, epg: epg,
                                    channelSnapshotStore: LiveTVChannelSnapshotStore(
                                        directory: directory.appendingPathComponent("channels", isDirectory: true)))
        _ = try? service.saveConfiguration(name: "Kyro Fixture", playlistURL: "https://\(host)/playlist.m3u",
                                           xmltvURL: "https://\(host)/guide.xml")
        return service
    }

    /// Stars a few channels once the playlist has loaded, so Home shows a hero and Favorites.
    @MainActor
    static func seedFavorites(in service: LiveTVService) async {
        for _ in 0..<100 where service.channels.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let names = ["Arena Sports", "Metro 24 News", "Classic Cinema", "Nature World", "Prime Drama"]
        for name in names {
            guard let channel = service.channels.first(where: { $0.name == name }),
                  !service.isFavorite(channel) else { continue }
            service.toggleFavorite(channel)
        }
    }

    static func value(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    @MainActor
    static func applyNavigationArguments(to store: KyroLiveTVNavigationStore) {
        let arguments = CommandLine.arguments
        if arguments.contains("-kyroDebugLiveTVNavReset") { store.resetAll() }
        if let style = value(after: "-kyroDebugLiveTVNavStyle").flatMap(KyroLiveTVNavigationStyle.init(rawValue:)) {
            store.preferences.style = style
        }
        if let edge = value(after: "-kyroDebugLiveTVNavEdge").flatMap(KyroNavigationEdge.init(rawValue:)) {
            let position = value(after: "-kyroDebugLiveTVNavPosition").flatMap(Double.init)
                ?? KyroNavigationAnchor.default(for: edge).position
            store.preferences.setAnchor(KyroNavigationAnchor(edge: edge, position: position),
                                        for: store.preferences.style)
        }
        if let idle = value(after: "-kyroDebugLiveTVNavIdle").flatMap(KyroLiveTVNavigationIdleBehavior.init(rawValue:)) {
            store.preferences.idleBehavior = idle
        }
        if arguments.contains("-kyroDebugLiveTVNavNoDrag") { store.preferences.allowsDragging = false }
        if arguments.contains("-kyroDebugLiveTVNavExpanded") {
            store.preferences.idleBehavior = .stayVisible
            store.isExpanded = true
        }
    }

    @MainActor
    static func applyGlobalNavigationArguments(to store: KyroGlobalNavigationStore) {
        let arguments = CommandLine.arguments
        if arguments.contains("-kyroDebugGlobalNavigationReset") {
            store.preferences.fourthTab = .default
            store.selectedDestination = .home
        }
        if let fourthTab = value(after: "-kyroDebugFourthTab").flatMap(KyroFourthTab.init(rawValue:)) {
            store.preferences.fourthTab = fourthTab
            store.selectedDestination = .home
        }
    }

    static let channels: [(name: String, category: String, shows: [String])] = [
        ("Arena Sports", "Sports", ["Championship Live", "Post-Game Analysis"]),
        ("Metro 24 News", "News", ["Evening Report", "World Tonight"]),
        ("Classic Cinema", "Movies", ["Feature Presentation", "Director's Cut"]),
        ("Nature World", "Documentary", ["Wild Coasts", "Ocean Deep"]),
        ("Prime Drama", "Entertainment", ["City Lights", "After Hours"]),
        ("Cartoon Hub", "Kids", ["Morning Toons", "Adventure Club"]),
        ("Tunes TV", "Music", ["Top 40 Countdown", "Live Sessions"]),
        ("Golf Channel One", "Sports", ["Final Round", "Swing Clinic"]),
        ("City Weather", "Weather", ["Forecast Now", "Storm Watch"]),
        ("Global Business", "News", ["Market Close", "Tech Tomorrow"]),
        ("Comedy Max", "Entertainment", ["Stand-Up Hour", "Sitcom Classics"]),
        ("History Vault", "Documentary", ["Ancient Empires", "Lost Cities"]),
        ("Racing Live", "Sports", ["Grand Prix Qualifying", "Pit Lane"]),
        ("Family Movies", "Movies", ["Weekend Matinee", "Holiday Special"]),
        ("Cooking Studio", "Lifestyle", ["Kitchen Basics", "Chef's Table"]),
        ("Science Now", "Documentary", ["Space Frontiers", "Inside the Lab"]),
        ("Retro Hits", "Music", ["80s Video Vault", "Unplugged"]),
        ("Kids Junior", "Kids", ["Story Time", "Puzzle Pals"]),
        ("Tennis Center", "Sports", ["Quarterfinal", "Match Point"]),
        ("Local 7", "Local", ["Community Hour", "Late News"]),
    ]

    static var playlist: String {
        var lines = ["#EXTM3U"]
        for (index, channel) in channels.enumerated() {
            lines.append(#"#EXTINF:-1 tvg-id="fixture.\#(index)" group-title="\#(channel.category)",\#(channel.name)"#)
            lines.append("https://\(host)/stream/\(index).m3u8")
        }
        return lines.joined(separator: "\n")
    }

    static func guide(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss '+0000'"
        // Programmes on the half hour, from an hour ago to six hours ahead.
        let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 1800).rounded(.down) * 1800 - 3600)
        var xml = "<tv>"
        for (index, channel) in channels.enumerated() {
            xml += #"<channel id="fixture.\#(index)"><display-name>\#(channel.name)</display-name></channel>"#
        }
        for (index, channel) in channels.enumerated() {
            for slot in 0..<14 {
                let begin = start.addingTimeInterval(Double(slot) * 1800)
                let title = channel.shows[slot % channel.shows.count]
                xml += #"<programme channel="fixture.\#(index)" start="\#(formatter.string(from: begin))" "#
                    + #"stop="\#(formatter.string(from: begin.addingTimeInterval(1800)))">"#
                    + "<title>\(title)</title><desc>Fictional fixture programme for simulator testing.</desc></programme>"
            }
        }
        return xml + "</tv>"
    }
}

private final class KyroFixtureSecretStore: LiveTVSecretStore {
    private var values: [String: String] = [:]
    func read(account: String) -> String? { values[account] }
    func save(_ value: String, account: String) -> Bool { values[account] = value; return true }
    func remove(account: String) -> Bool { values[account] = nil; return true }
}

private final class KyroFixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.kyro.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body: String
        switch url.lastPathComponent {
        case "playlist.m3u": body = KyroDebugLiveTVFixture.playlist
        case "guide.xml":
            guard !CommandLine.arguments.contains("-kyroDebugSearchNoGuide") else {
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }
            body = KyroDebugLiveTVFixture.guide()
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let data = Data(body.utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(data.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
