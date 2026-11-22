#if os(iOS)
import SwiftUI

enum IOSSettingsOverviewGroup: String, CaseIterable {
    case preferences = "Preferences"
    case account = "Account"
    case support = "Support"
}

/// Presentation and search metadata only. Existing stores and destinations
/// continue to own every setting and action.
enum IOSSettingsOverviewCategory: String, CaseIterable, Identifiable {
    case playback, liveTV, appearanceNavigation, downloadsStorage
    case accountConnections
    case privacy, advancedDiagnostics, aboutKyro

    var id: String { rawValue }

    var group: IOSSettingsOverviewGroup {
        switch self {
        case .playback, .liveTV, .appearanceNavigation, .downloadsStorage: .preferences
        case .accountConnections: .account
        case .privacy, .advancedDiagnostics, .aboutKyro: .support
        }
    }

    var title: String {
        switch self {
        case .playback: "Playback"
        case .liveTV: "Live TV"
        case .appearanceNavigation: "Appearance & Navigation"
        case .downloadsStorage: "Downloads & Storage"
        case .accountConnections: "Account & Connections"
        case .privacy: "Privacy"
        case .advancedDiagnostics: "Advanced & Diagnostics"
        case .aboutKyro: "About Kyro"
        }
    }

    var searchTerms: [String] {
        switch self {
        case .playback:
            ["playback", "subtitles", "captions", "quality", "streaming quality", "audio", "audio & video", "video", "episodes", "episode behavior", "skipping", "spoilers", "spoiler protection", "player controls", "skip intervals", "advanced playback", "seek cache", "buffer", "buffer ahead", "deinterlacing", "lossless", "atmos", "hdr", "dolby vision", "bitrate", "cellular", "background playback", "connection speed"]
        case .liveTV:
            KyroLiveTVSettingsEntry.searchTerms
        case .appearanceNavigation:
            ["appearance & navigation", "appearance", "interface", "navigation", "menu", "cards", "posters", "theme music", "theme song", "features", "extra features", "experimental", "audiobooks", "watch party"]
        case .downloadsStorage:
            ["downloads & storage", "downloads", "offline", "quality", "cleanup", "storage"]
        case .accountConnections:
            ["account & connections", "account", "connections", "general", "profile", "startup", "server", "sign in", "tv", "sign out", "backup", "restore", "export settings", "import settings"]
        case .privacy:
            ["privacy", "privacy & support", "privacy policy", "crash reports", "crash reporting", "consent", "diagnostics sharing"]
        case .advancedDiagnostics:
            ["advanced & diagnostics", "advanced", "privacy & support", "support", "diagnostics", "playback health", "performance", "reports", "debug", "logging", "technical", "live tv diagnostics", "performance overlay", "playback log", "sports log", "copy log"]
        case .aboutKyro:
            ["about kyro", "about", "privacy & support", "version", "build", "acknowledgements", "source code", "replay introduction", "introduction", "open source", "licenses"]
        }
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return searchTerms.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    static func visible(downloadsEnabled: Bool) -> [Self] {
        allCases.filter { $0 != .downloadsStorage || downloadsEnabled }
    }
}

enum IOSSettingsOverviewSearch {
    static func categories(matching query: String, downloadsEnabled: Bool) -> [IOSSettingsOverviewCategory] {
        IOSSettingsOverviewCategory.visible(downloadsEnabled: downloadsEnabled).filter { $0.matches(query) }
    }
}

/// Downloads remain hidden until the active scope and capability are hydrated.
enum IOSSettingsOverviewDownloadsVisibility {
    static func isVisible(downloadsEnabled: Bool, capabilityHydrated: Bool) -> Bool {
        capabilityHydrated && downloadsEnabled
    }
}

/// Why Downloads & Storage is or is not in the overview. Visibility is
/// decided by the server's capability and nothing local: only a usable
/// capability (`DownloadCapability.isUsable`) shows the category.
enum IOSSettingsDownloadsAvailability: Equatable {
    /// The active scope has not been activated and asked yet.
    case loading
    case available
    case unavailable(Reason)

    enum Reason: String, Equatable {
        /// No signed-in server and profile.
        case noActiveScope
        /// The server never answered and nothing usable is cached.
        case capabilityUnknown
        /// The server reports the feature as disabled, unconfigured or unsupported.
        case serverDisabled
        /// The feature is on, but this account or profile may not use it.
        case notAllowed
    }

    enum Hydration: Equatable {
        case pending, noActiveScope, refreshed, refreshFailed
    }

    var isVisible: Bool { self == .available }

    static func resolve(hydration: Hydration, capability: DownloadCapability?) -> Self {
        switch hydration {
        case .pending:
            return .loading
        case .noActiveScope:
            return .unavailable(.noActiveScope)
        case .refreshed, .refreshFailed:
            // A usable cached answer outlasts a failed refresh, so a bad
            // connection does not hide a category the server already confirmed.
            guard let capability else {
                return .unavailable(hydration == .refreshFailed ? .capabilityUnknown : .serverDisabled)
            }
            if capability.isUsable { return .available }
            return .unavailable(capability.state == "available" ? .notAllowed : .serverDisabled)
        }
    }
}

/// Activates the current scope and asks for its capability once per run. The
/// dependencies are closures so the transitions can be driven in tests.
@MainActor
@Observable
final class IOSSettingsDownloadsHydrator {
    private(set) var hydration: IOSSettingsDownloadsAvailability.Hydration = .pending
    private let activate: @MainActor () async -> Bool
    private let refresh: @MainActor () async -> Bool
    private let capability: @MainActor () -> DownloadCapability?

    init(
        activate: @escaping @MainActor () async -> Bool,
        refresh: @escaping @MainActor () async -> Bool,
        capability: @escaping @MainActor () -> DownloadCapability?
    ) {
        self.activate = activate
        self.refresh = refresh
        self.capability = capability
    }

    static var live: IOSSettingsDownloadsHydrator {
        IOSSettingsDownloadsHydrator(
            activate: { await DownloadManager.shared.activateScopeIfNeeded() },
            refresh: { await DownloadManager.shared.refreshCapability() },
            capability: { DownloadManager.shared.capability }
        )
    }

    var availability: IOSSettingsDownloadsAvailability {
        .resolve(hydration: hydration, capability: capability())
    }

    /// A server or profile change: the previous answer no longer applies.
    func reset() { hydration = .pending }

    func hydrate() async {
        guard await activate() else {
            hydration = .noActiveScope
            return
        }
        let refreshed = await refresh()
        guard !Task.isCancelled else { return }
        hydration = refreshed ? .refreshed : .refreshFailed
    }
}

struct IOSSettingsOverview: View {
    let viewModel: SettingsViewModel
    let diagnosticsModel: DiagnosticsViewModel
    let uiCustomization: UICustomizationPreferences
    @Binding var showSignOutConfirm: Bool

    @Environment(AppRouter.self) private var router
    @State private var searchText = ""
    @State private var downloads = IOSSettingsDownloadsHydrator.live

    private var downloadsEnabled: Bool { downloads.availability.isVisible }

    private var matchingCategories: [IOSSettingsOverviewCategory] {
        IOSSettingsOverviewSearch.categories(matching: searchText, downloadsEnabled: downloadsEnabled)
    }

    var body: some View {
        List {
            Section {
                SettingsAccountCard(
                    avatar: viewModel.activeProfile?.avatarEmoji,
                    avatarImageUrl: viewModel.activeProfile?.avatarImageUrl,
                    name: viewModel.displayName,
                    subtitle: viewModel.accountSubtitleLine,
                    isAdministrator: viewModel.userInfo?.isAdmin == true,
                    action: router.switchProfile
                )
            }

            SettingsSearchField(text: $searchText)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            if matchingCategories.isEmpty {
                ContentUnavailableView.search
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                    .listRowBackground(Color.clear)
            } else {
                preferencesSection
                accountSection
                supportSection
            }
        }
        .siloGroupedListStyle()
        .siloScrollContentBackgroundHidden()
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(Color.siloBackground.ignoresSafeArea())
        .navigationTitle("Settings")
        .siloNavigationTitleDisplayMode(.large)
        .siloToolbarColorSchemeDark()
        // Runs on each appearance and again when the active server changes, so
        // a failed refresh is retried on reopening and a switch drops the
        // previous server's answer.
        .task(id: ServerRegistry.shared.activeServerId) {
            downloads.reset()
            await downloads.hydrate()
        }
    }

    @ViewBuilder private var preferencesSection: some View {
        if hasMatches(in: .preferences) {
            Section(IOSSettingsOverviewGroup.preferences.rawValue) {
                if includes(.playback) {
                    NavigationLink { IOSPlaybackSettingsGroupView(viewModel: viewModel) } label: {
                        SettingsOverviewRow(title: "Playback", subtitle: "Quality, subtitles, audio, and episode behavior", systemImage: "play.fill", value: viewModel.preferredQualityLabel)
                    }
                }
                if includes(.liveTV) { KyroLiveTVSettingsRow() }
                if includes(.appearanceNavigation) {
                    NavigationLink { IOSAppearanceNavigationSettingsView(uiCustomization: uiCustomization) } label: {
                        SettingsOverviewRow(title: "Appearance & Navigation", subtitle: "Interface, navigation, and optional features", systemImage: "rectangle.3.group.fill")
                    }
                }
                if includes(.downloadsStorage) {
                    NavigationLink { DownloadsSettingsView() } label: {
                        SettingsOverviewRow(title: "Downloads & Storage", subtitle: "Offline quality, cleanup, and storage", systemImage: "arrow.down.circle.fill")
                    }
                }
            }
        }
    }

    @ViewBuilder private var accountSection: some View {
        if includes(.accountConnections) {
            Section(IOSSettingsOverviewGroup.account.rawValue) {
                NavigationLink { IOSAccountConnectionsSettingsView(viewModel: viewModel, showSignOutConfirm: $showSignOutConfirm) } label: {
                    SettingsOverviewRow(title: "Account & Connections", subtitle: "Profile, sign-in, server, and connected devices", systemImage: "person.crop.circle.badge.checkmark", value: viewModel.serverDisplayName)
                }
            }
        }
    }

    @ViewBuilder private var supportSection: some View {
        if hasMatches(in: .support) {
            Section(IOSSettingsOverviewGroup.support.rawValue) {
                if includes(.privacy) {
                    NavigationLink { IOSPrivacySettingsView(model: diagnosticsModel, profile: viewModel.activeProfile) } label: {
                        SettingsOverviewRow(title: "Privacy", subtitle: "Privacy policy and diagnostics-sharing consent", systemImage: "hand.raised.fill")
                    }
                }
                if includes(.advancedDiagnostics) {
                    NavigationLink { IOSAdvancedDiagnosticsSettingsView(model: diagnosticsModel, profile: viewModel.activeProfile) } label: {
                        SettingsOverviewRow(title: "Advanced & Diagnostics", subtitle: "Playback health, reports, and technical logging", systemImage: "stethoscope")
                    }
                }
                if includes(.aboutKyro) {
                    NavigationLink { IOSAboutKyroSettingsView() } label: {
                        SettingsOverviewRow(title: "About Kyro", subtitle: "Version, acknowledgements, and source code", systemImage: "info.circle.fill", value: SettingsViewModel.versionString)
                    }
                }
            }
        }
    }

    private func includes(_ category: IOSSettingsOverviewCategory) -> Bool { matchingCategories.contains(category) }
    private func hasMatches(in group: IOSSettingsOverviewGroup) -> Bool { matchingCategories.contains { $0.group == group } }
}

private struct IOSPlaybackSettingsGroupView: View {
    let viewModel: SettingsViewModel
    var body: some View {
        List {
            Section {
                NavigationLink { PlaybackSettingsView(viewModel: viewModel) } label: {
                    SettingsOverviewRow(title: "Playback", subtitle: "Quality, language, audio, and episode behavior", systemImage: "play.fill", value: viewModel.preferredQualityLabel)
                }
                NavigationLink { SubtitleSettingsView(viewModel: viewModel) } label: {
                    SettingsOverviewRow(title: "Subtitles", subtitle: "Language, behavior, and appearance", systemImage: "captions.bubble.fill", value: viewModel.subtitleLanguageName)
                }
            }
        }
        .settingsListChrome()
        .navigationTitle("Playback")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
    }
}

private struct IOSAppearanceNavigationSettingsView: View {
    let uiCustomization: UICustomizationPreferences
    @State private var navPrefs = AppNavPreferences.shared
    @State private var experimental = ExperimentalFeatures.shared

    var body: some View {
        List {
            Section("Appearance & Navigation") {
                NavigationLink { InterfaceCustomizationView() } label: {
                    SettingsOverviewRow(title: "Interface", subtitle: "Cards, posters, title pages, and menu presentation", systemImage: "rectangle.3.group.fill", value: uiCustomization.cardPresentation.preset?.title ?? "Custom")
                }
                if KyroUnifiedNavigation.isActive { KyroNavigationSettingsRow() }
            }
            Section {
                SettingsOverviewToggleRow(
                    title: "Show Audiobooks",
                    subtitle: "Add Audiobooks to the main navigation",
                    systemImage: "book.closed.fill",
                    isOn: Binding(get: { navPrefs.showAudiobooks }, set: { navPrefs.setShowAudiobooks($0) })
                )
                ForEach(ExperimentalFeature.allCases) { feature in
                    SettingsOverviewToggleRow(
                        title: feature.title,
                        subtitle: "Experimental · \(feature.subtitle)",
                        systemImage: feature.systemImage,
                        isOn: Binding(get: { experimental.isEnabled(feature) }, set: { feature.setEnabled($0) })
                    )
                }
            } header: {
                Text("Features")
            } footer: {
                Text("Experimental features may change and are stored only on this device.")
            }
        }
        .settingsListChrome()
        .navigationTitle("Appearance & Navigation")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
        .onAppear(perform: navPrefs.refresh)
    }
}

private struct IOSAccountConnectionsSettingsView: View {
    let viewModel: SettingsViewModel
    @Binding var showSignOutConfirm: Bool
    @Environment(AppRouter.self) private var router
    @State private var launchPreferences = ProfileLaunchPreferences.shared
    @State private var showsSignInTV = false
    @State private var accountSignIn = AccountSignInModel.live()

    var body: some View {
        List {
            Section("Account") {
                NavigationLink { GeneralSettingsView() } label: {
                    SettingsOverviewRow(title: "General", subtitle: "Profile selection and app startup", systemImage: "person.crop.circle.badge.checkmark", value: launchPreferences.behavior.title)
                }
                NavigationLink { SettingsBackupView() } label: {
                    SettingsOverviewRow(title: "Backup & Restore", subtitle: "Export or import this device's preferences", systemImage: "externaldrive.badge.checkmark")
                }
                .accessibilityIdentifier("settings.backupRestore")
                if accountSignIn.showsEntry {
                    NavigationLink { AccountSignInView(model: accountSignIn) } label: {
                        SettingsOverviewRow(title: "Sign-in", subtitle: "Connect or disconnect your sign-in provider", systemImage: "person.badge.key.fill", value: accountSignIn.identities.first?.providerName)
                    }
                    .accessibilityIdentifier("settings.accountSignIn")
                }
            }
            Section("Connections") {
                Button { router.navigate(to: .serverList) } label: {
                    SettingsOverviewRow(title: "Server", subtitle: "Manage this device's Silo connection", systemImage: "server.rack", value: viewModel.serverDisplayName, showsChevron: true)
                }
                .buttonStyle(.plain)
                Button { showsSignInTV = true } label: {
                    SettingsOverviewRow(title: "Sign in a TV", subtitle: "Approve a TV's sign-in code with this account", systemImage: "tv", showsChevron: true)
                }
                .buttonStyle(.plain)
            }
            Section {
                Button("Sign Out", role: .destructive) { showSignOutConfirm = true }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(Color.red)
            }
        }
        .settingsListChrome()
        .navigationTitle("Account & Connections")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
        .task { await accountSignIn.load() }
        .sheet(isPresented: $showsSignInTV) {
            SignInTVView(onSwitchAccount: { server, link, choosingAccount in
                showsSignInTV = false
                router.switchAccount(forTVApproval: link, on: server, choosingAccount: choosingAccount)
            }, onClose: { showsSignInTV = false })
        }
    }
}

private struct IOSPrivacySettingsView: View {
    @Bindable var model: DiagnosticsViewModel
    let profile: UserProfile?
    @State private var selectedMode: DiagnosticsConsentChoice = .ask
    @State private var selectedDestination: DiagnosticsDestinationChoice = .hosted
    @State private var showAlwaysConfirmation = false
    @State private var showNeverConfirmation = false

    var body: some View {
        List {
            Section("Privacy") {
                Link(destination: SiloLegalLinks.privacyPolicy) {
                    SettingsOverviewRow(title: "Privacy Policy", subtitle: "Learn how Silo handles your information", systemImage: "hand.raised.fill", showsChevron: true)
                }
            }
            if model.shouldShowSettings { diagnosticsSharingSection }
        }
        .settingsListChrome()
        .navigationTitle("Privacy")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
        .task {
            await model.load(profile: profile)
            selectedMode = model.consentMode
            selectedDestination = model.selectedDestination
        }
        .onChange(of: model.consentMode) { _, mode in selectedMode = mode }
        .onChange(of: model.selectedDestination) { _, destination in selectedDestination = destination }
    }

    private var diagnosticsSharingSection: some View {
        Section {
            Picker("Send Reports To", selection: $selectedDestination) {
                Text("Silo Diagnostics").tag(DiagnosticsDestinationChoice.hosted)
                Text("My Silo Server").tag(DiagnosticsDestinationChoice.selfHosted)
            }
            .onChange(of: selectedDestination) { oldValue, newValue in
                guard oldValue != newValue, newValue != model.selectedDestination else { return }
                Task { await model.setDestination(newValue) }
            }

            Picker("Crash Reports", selection: $selectedMode) {
                Text("Ask").tag(DiagnosticsConsentChoice.ask)
                if model.allowsAlwaysSend { Text("Always").tag(DiagnosticsConsentChoice.always) }
                Text("Never").tag(DiagnosticsConsentChoice.never)
            }
            .disabled(!model.canChangeConsent)
            .onChange(of: selectedMode) { oldValue, newValue in
                guard oldValue != newValue, newValue != model.consentMode else { return }
                requestModeChange(newValue)
            }
            .confirmationDialog("Always Send Crash Reports?", isPresented: $showAlwaysConfirmation, titleVisibility: .visible) {
                Button("Always Send") { Task { await model.setConsentMode(.always) } }
                Button("Cancel", role: .cancel, action: cancelModeChange)
            } message: {
                Text("Any pending reports and future crash or hang reports for this server account will be sent automatically. You can change this at any time.")
            }
            .alert("Turn Off Crash Reports?", isPresented: $showNeverConfirmation) {
                Button("Turn Off and Delete", role: .destructive) { Task { await model.setConsentMode(.never) } }
                Button("Cancel", role: .cancel, action: cancelModeChange)
            } message: {
                if model.selectedDestination == .hosted {
                    Text("Pending local reports will be deleted. Reports already received by Silo Diagnostics will also be queued for deletion. The in-memory basic log will continue running and is never sent without an explicit action.")
                } else {
                    Text("Pending reports for this server account will be deleted. The in-memory basic log will continue running and is never sent without an explicit action.")
                }
            }
        } header: {
            Text("Diagnostics Sharing")
        } footer: {
            if model.selectedDestination == .hosted {
                Text(model.hostedPrivacyDisclosure)
            } else {
                Text("Crash report consent is tied to this server account. Technical logging is a separate device setting under Advanced & Diagnostics.")
            }
        }
    }

    private func requestModeChange(_ mode: DiagnosticsConsentChoice) {
        switch mode {
        case .ask: Task { await model.setConsentMode(.ask) }
        case .always: showAlwaysConfirmation = true
        case .never: showNeverConfirmation = true
        }
    }

    private func cancelModeChange() { selectedMode = model.consentMode }
}

private struct IOSAdvancedDiagnosticsSettingsView: View {
    @Bindable var model: DiagnosticsViewModel
    let profile: UserProfile?

    var body: some View {
        List {
            Section("Troubleshooting") {
                if model.shouldShowSettings {
                    NavigationLink { DiagnosticsSettingsView(model: model, profile: profile) } label: {
                        SettingsOverviewRow(title: "Diagnostics", subtitle: "Capture, review, and send support reports", systemImage: "stethoscope", value: model.featureState.title)
                    }
                }
                NavigationLink { PlaybackHealthView() } label: {
                    SettingsOverviewRow(title: "Playback Health", subtitle: "Local startup history and timing", systemImage: "waveform.path.ecg")
                }
                NavigationLink { LiveTVDiagnosticsSettingsView(service: LiveTVService.shared) } label: {
                    SettingsOverviewRow(title: LiveTVDiagnosticsCopy.title, subtitle: LiveTVDiagnosticsCopy.rowSubtitle, systemImage: "tv")
                }
            }
        }
        .settingsListChrome()
        .navigationTitle("Advanced & Diagnostics")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
        .task { await model.load(profile: profile) }
    }
}

private struct IOSAboutKyroSettingsView: View {
    @State private var showsKyroIntroduction = false

    var body: some View {
        List {
            Section("About Kyro") {
                SettingsOverviewRow(title: "Version", subtitle: "Installed Kyro app version and build", systemImage: "info.circle.fill", value: SettingsViewModel.versionString)
                NavigationLink { AcknowledgementsView() } label: {
                    SettingsOverviewRow(title: "Acknowledgements", subtitle: "Services Kyro uses and open source licenses", systemImage: "curlybraces")
                }
                Link(destination: SiloLegalLinks.sourceCode) {
                    SettingsOverviewRow(title: "Source Code", subtitle: "Get Silo's source code under the AGPL", systemImage: "chevron.left.forwardslash.chevron.right", showsChevron: true)
                }
                if KyroBrand.usesCinematicStartup {
                    Button { showsKyroIntroduction = true } label: {
                        SettingsOverviewRow(title: "Replay Introduction", subtitle: "See Kyro's three-screen introduction again", systemImage: "sparkles.rectangle.stack.fill", showsChevron: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.replayIntroduction")
                }
            }
        }
        .settingsListChrome()
        .navigationTitle("About Kyro")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
        .fullScreenCover(isPresented: $showsKyroIntroduction) {
            // Replay remains independent of first-launch completion state.
            KyroIntroductionView(initialPage: 0) { showsKyroIntroduction = false }
        }
    }
}
#endif
