import Foundation
import Observation

struct UnifiedSiloIdentity: Equatable, Sendable {
    let serverID: String
    let accountID: String
    let profileID: String

    init(serverID: String, accountID: String, profileID: String) {
        self.serverID = serverID
        self.accountID = accountID
        self.profileID = profileID
    }

    init?(_ owner: SessionOwner?) {
        guard let owner else { return nil }
        self.init(serverID: owner.serverID, accountID: owner.accountID, profileID: owner.profileID)
    }
}

enum UnifiedSearchSourcePhase: Equatable, Sendable {
    case idle
    case debouncing
    case loading
    case loaded
    case failed
    case partialFailure
    case unavailable
}

struct UnifiedSearchSourceStatus: Equatable, Sendable {
    var phase: UnifiedSearchSourcePhase
    var resultCount: Int = 0
    var message: String? = nil

    static let idle = Self(phase: .idle)
}

enum UnifiedSearchFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case moviesAndTV
    case liveTV

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .moviesAndTV: "Movies & TV"
        case .liveTV: "Live TV"
        }
    }

    var showsMoviesAndTV: Bool { self != .liveTV }
    var showsLiveTV: Bool { self != .moviesAndTV }

    func seeAllFilter(for section: UnifiedSearchResultsSection) -> Self {
        switch section {
        case .moviesAndTV: .moviesAndTV
        case .liveTV, .programs: .liveTV
        }
    }
}

enum UnifiedSearchResultsSection: Sendable {
    case moviesAndTV
    case liveTV
    /// TV programs. Shown under All and under Live TV, always after channels, never mixed in.
    case programs

    static let combinedPreviewLimit = 6
    static let liveTVPageSize = 60

    static func hasAdditionalResults(total: Int, visible: Int) -> Bool {
        max(0, total) > max(0, visible)
    }

    static func nextVisibleLimit(current: Int, total: Int) -> Int {
        min(max(0, total), max(0, current) + liveTVPageSize)
    }
}

/// Metadata safe to publish from the IPTV source. Rows are resolved against the catalog snapshot
/// that produced them; stream/logo URLs and provider credentials are intentionally omitted.
struct UnifiedLiveTVSearchResult: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let category: String
    let ordinal: Int
    let logoURL: URL?
}

struct UnifiedSearchIPTVCatalogSnapshot: Sendable {
    let providerID: UUID?
    let catalogRevision: Int
    let hasProvider: Bool
    let isLoading: Bool
    let errorMessage: String?
    let channels: [LiveTVChannel]
    var channelCount: Int = 0

    var identity: LiveTVChannelSearchIndex.Identity? {
        providerID.map { LiveTVChannelSearchIndex.Identity(providerID: $0, catalogRevision: catalogRevision) }
    }
}

struct UnifiedSearchLiveTVSource {
    let search: @MainActor @Sendable (_ query: String, _ providerID: UUID, _ revision: Int) async
        -> (channels: [LiveTVChannel], total: Int)?
    let resolve: @MainActor @Sendable (_ channelID: String, _ providerID: UUID, _ revision: Int) async
        -> LiveTVChannel?
    let programAssociations: @MainActor @Sendable (_ providerID: UUID, _ revision: Int) async
        -> [EPGProgramChannel]?

    @MainActor static func live(service: LiveTVService) -> Self {
        #if os(iOS)
        return Self(search: { query, providerID, revision in
            guard service.selectedProviderID == providerID, service.channelCatalogRevision == revision else { return nil }
            async let page = service.channelPage(providerID: providerID, query: query, limit: 200)
            async let count = service.channelCount(providerID: providerID, query: query)
            let result = await (page, count)
            guard service.selectedProviderID == providerID, service.channelCatalogRevision == revision else { return nil }
            return (channels: result.0, total: result.1)
        }, resolve: { channelID, providerID, revision in
            guard service.selectedProviderID == providerID, service.channelCatalogRevision == revision else { return nil }
            let channel = await service.channel(providerID: providerID, id: channelID)
            guard service.selectedProviderID == providerID, service.channelCatalogRevision == revision else { return nil }
            return channel
        }, programAssociations: { providerID, revision in
            guard service.selectedProviderID == providerID, service.channelCatalogRevision == revision else { return nil }
            let result = await service.programSearchAssociations(providerID: providerID)
            guard service.selectedProviderID == providerID, service.channelCatalogRevision == revision else { return nil }
            return result
        })
        #else
        // The bounded provider catalog index currently exists on iOS only.
        // tvOS search keeps its existing Silo and guide paths and reports no
        // indexed IPTV results until that catalog surface is ported.
        return Self(
            search: { _, _, _ in nil },
            resolve: { _, _, _ in nil },
            programAssociations: { _, _ in nil }
        )
        #endif
    }
}

/// One TV program found by search. Like `UnifiedLiveTVSearchResult` it carries display metadata
/// only (no stream URL, credentials or full channel record); `resolveProgram(for:)` turns it into a
/// playable channel and guide entry at tap time.
struct UnifiedProgramSearchResult: Equatable, Sendable, Identifiable {
    let id: String
    let programID: String
    let channelID: String
    let channelKey: String
    let channelName: String
    let channelOrdinal: Int
    let logoURL: URL?
    let title: String
    let subtitle: String?
    let start: Date
    let end: Date
    /// Airing when the search ran. Views should re-derive with `isLive(at:)` as time passes.
    let wasLiveAtSearch: Bool

    func isLive(at date: Date) -> Bool { start <= date && date < end }
}

/// The selected provider's guide as program search sees it. `EPGIndex` holds no URLs.
struct UnifiedSearchGuideSnapshot: Sendable {
    let guideGeneration: Int
    let guide: EPGIndex?
    let isGuideLoading: Bool
    let isGuideStale: Bool

    static let none = UnifiedSearchGuideSnapshot(guideGeneration: 0, guide: nil, isGuideLoading: false, isGuideStale: false)
}

/// Program search wiring. The coordinator searches programs only when given one; Search passes
/// `.live` once it can show program results.
struct UnifiedSearchProgramSource {
    let store: EPGProgramSearchIndexStore
    let guideSnapshot: @MainActor (UUID) -> UnifiedSearchGuideSnapshot

    @MainActor static func live(service: LiveTVService) -> UnifiedSearchProgramSource {
        UnifiedSearchProgramSource(store: .shared) { service.unifiedSearchGuideSnapshot(providerID: $0) }
    }

    @MainActor static var live: UnifiedSearchProgramSource {
        .live(service: .shared)
    }
}

@MainActor
protocol UnifiedSearchSiloServing: AnyObject {
    var titleResults: [BrowseItem] { get }
    var peopleResults: [Person] { get }
    var requestResults: [RequestMediaResult] { get }
    var isLoading: Bool { get }
    var hasSearched: Bool { get }
    var errorMessage: String? { get }

    func performSearch(query: String) async
    func loadMore() async
    func cancelForQueryChange()
    func resetForIdentityChange()
}

/// Adapter around the existing catalog, people, episode, and request-search models. It does not
/// issue a second catalog request; the existing SearchViewModel remains the Silo API owner.
@MainActor
final class UnifiedSearchSiloAdapter: UnifiedSearchSiloServing {
    let searchModel: SearchViewModel
    let requestSearchModel: RequestSearchSectionViewModel

    init(searchModel: SearchViewModel,
         requestSearchModel: RequestSearchSectionViewModel) {
        self.searchModel = searchModel
        self.requestSearchModel = requestSearchModel
    }

    var titleResults: [BrowseItem] { searchModel.results }
    var peopleResults: [Person] { searchModel.people }
    var requestResults: [RequestMediaResult] { requestSearchModel.results }
    var isLoading: Bool {
        searchModel.isSearching || searchModel.isSearchingPeople || requestSearchModel.isLoading
    }
    var hasSearched: Bool { searchModel.hasSearched }
    var errorMessage: String? { searchModel.error?.message }

    func performSearch(query: String) async {
        async let catalog: Void = searchModel.performCoordinatedSearch(query: query)
        async let discovery: Void = requestSearchModel.performCoordinatedSearch(query)
        _ = await (catalog, discovery)
        await searchModel.waitForCoordinatedPeopleSearch()
    }

    func loadMore() async { await searchModel.loadMore() }

    func cancelForQueryChange() {
        searchModel.cancelCoordinatedSearch()
        requestSearchModel.resetForCoordinatedIdentityChange()
    }

    func resetForIdentityChange() {
        searchModel.resetForCoordinatedIdentityChange()
        requestSearchModel.resetForCoordinatedIdentityChange()
    }
}

extension LiveTVService {
    func unifiedSearchCatalogSnapshot() -> UnifiedSearchIPTVCatalogSnapshot {
        UnifiedSearchIPTVCatalogSnapshot(
            providerID: selectedProviderID,
            catalogRevision: channelCatalogRevision,
            hasProvider: !providers.isEmpty,
            isLoading: isLoading,
            errorMessage: errorMessage,
            channels: channels,
            channelCount: selectedChannelCount
        )
    }

    /// Guide state for program search. Loading and staleness describe the selected provider only.
    func unifiedSearchGuideSnapshot(providerID: UUID) -> UnifiedSearchGuideSnapshot {
        let isSelected = selectedProviderID == providerID
        return UnifiedSearchGuideSnapshot(guideGeneration: guideGeneration(for: providerID),
                                          guide: guideIndex(for: providerID),
                                          isGuideLoading: isSelected && isGuideLoading,
                                          isGuideStale: isSelected && isGuideStale)
    }
}

/// Owns the shared query debounce and independent source lifecycles. Results/status are transient;
/// this type has no persistence and does not combine channel rows with Silo catalog rows.
@MainActor
@Observable
final class UnifiedSearchCoordinator {
    private(set) var query = ""
    private(set) var siloState: UnifiedSearchSourceStatus = .idle
    private(set) var liveTVState: UnifiedSearchSourceStatus = .idle
    private(set) var liveTVResults: [UnifiedLiveTVSearchResult] = []
    /// TV programs from the selected provider's guide, in memory or SQLite-backed. Stays `.idle` with
    /// no results when the coordinator was created without a program source.
    private(set) var programState: UnifiedSearchSourceStatus = .idle
    private(set) var programResults: [UnifiedProgramSearchResult] = []

    let silo: any UnifiedSearchSiloServing

    @ObservationIgnored private let indexStore: LiveTVChannelSearchIndexStore
    @ObservationIgnored private let catalogSnapshot: @MainActor () -> UnifiedSearchIPTVCatalogSnapshot
    @ObservationIgnored private let liveTVSource: UnifiedSearchLiveTVSource?
    @ObservationIgnored private let siloIdentityProvider: @MainActor () -> UnifiedSiloIdentity?
    @ObservationIgnored private let debounceDuration: Duration
    @ObservationIgnored private let waitForDebounce: @MainActor (Duration) async -> Void

    @ObservationIgnored private var queryGeneration = 0
    @ObservationIgnored private var siloGeneration = 0
    @ObservationIgnored private var liveTVGeneration = 0
    @ObservationIgnored private var siloIdentity: UnifiedSiloIdentity?
    @ObservationIgnored private var observedCatalogIdentity: LiveTVChannelSearchIndex.Identity?
    @ObservationIgnored private var observedHasProvider = false
    @ObservationIgnored private var indexedCatalogIdentity: LiveTVChannelSearchIndex.Identity?
    @ObservationIgnored private var buildingCatalogIdentity: LiveTVChannelSearchIndex.Identity?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var siloTask: Task<Void, Never>?
    @ObservationIgnored private var liveTVTask: Task<Void, Never>?
    @ObservationIgnored private var indexBuildTask: Task<Bool, Never>?
    @ObservationIgnored private var resumeAfterDismissal = false

    @ObservationIgnored private let programs: UnifiedSearchProgramSource?
    @ObservationIgnored private var programGeneration = 0
    @ObservationIgnored private var programTask: Task<Void, Never>?
    /// The program source state the current program search and results belong to.
    @ObservationIgnored private var observedProgramSource: ProgramSourceKey?
    /// The identity `programResults` were published under; tap-time resolution requires it.
    @ObservationIgnored private var publishedProgramIdentity: EPGProgramSearchIndex.Identity?

    init(
        silo: any UnifiedSearchSiloServing,
        indexStore: LiveTVChannelSearchIndexStore = .shared,
        catalogSnapshot: @escaping @MainActor () -> UnifiedSearchIPTVCatalogSnapshot = {
            LiveTVService.shared.unifiedSearchCatalogSnapshot()
        },
        liveTVSource: UnifiedSearchLiveTVSource? = nil,
        siloIdentityProvider: @escaping @MainActor () -> UnifiedSiloIdentity? = {
            UnifiedSiloIdentity(SessionOwner.current())
        },
        programs: UnifiedSearchProgramSource? = nil,
        debounceDuration: Duration = .milliseconds(300),
        waitForDebounce: @escaping @MainActor (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.silo = silo
        self.indexStore = indexStore
        self.catalogSnapshot = catalogSnapshot
        self.liveTVSource = liveTVSource
        self.siloIdentityProvider = siloIdentityProvider
        self.programs = programs
        self.debounceDuration = debounceDuration
        self.waitForDebounce = waitForDebounce
        siloIdentity = siloIdentityProvider()
        if siloIdentity == nil {
            siloState = UnifiedSearchSourceStatus(phase: .unavailable, message: "Sign in to search Silo.")
        }
        let initialCatalog = catalogSnapshot()
        observedCatalogIdentity = initialCatalog.identity
        observedHasProvider = initialCatalog.hasProvider
        updateLiveTVAvailability(initialCatalog)
        observedProgramSource = programSourceKey(initialCatalog)
        updateProgramAvailability(initialCatalog)
    }

    /// Call for every text edit. Both sources are cancelled/cleared immediately; one debounce then
    /// fans the query out to Silo and IPTV. This replaces the two existing per-screen debounce
    /// waits during Phase 3 integration.
    func onQueryChanged(_ newQuery: String) {
        query = newQuery
        synchronizeSiloIdentity(restartSearch: false)
        queryGeneration &+= 1
        siloGeneration &+= 1
        liveTVGeneration &+= 1
        let generation = queryGeneration
        debounceTask?.cancel()
        siloTask?.cancel()
        liveTVTask?.cancel()
        silo.cancelForQueryChange()
        liveTVResults = []
        clearProgramSearch()

        guard !newQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            debounceTask = nil
            siloState = siloIdentity == nil
                ? UnifiedSearchSourceStatus(phase: .unavailable, message: "Sign in to search Silo.")
                : .idle
            let catalog = catalogSnapshot()
            updateLiveTVAvailability(catalog)
            updateProgramAvailability(catalog)
            return
        }

        siloState = siloIdentity == nil
            ? UnifiedSearchSourceStatus(phase: .unavailable, message: "Sign in to search Silo.")
            : UnifiedSearchSourceStatus(phase: .debouncing)
        liveTVState = UnifiedSearchSourceStatus(phase: .debouncing)
        if programs != nil { programState = UnifiedSearchSourceStatus(phase: .debouncing) }
        debounceTask = Task { [weak self] in
            guard let self else { return }
            await waitForDebounce(debounceDuration)
            guard !Task.isCancelled, generation == queryGeneration else { return }
            debounceTask = nil
            startSearch(query: newQuery, generation: generation)
        }
    }

    /// Explicit identity synchronization hook for the Search view lifecycle. It also runs
    /// before dispatch and before publishing any Silo result, so an identity switch during I/O is
    /// rejected even if the UI has not yet delivered its change notification.
    func synchronizeSiloIdentity(restartSearch: Bool = true) {
        let nextIdentity = siloIdentityProvider()
        guard nextIdentity != siloIdentity else { return }
        siloIdentity = nextIdentity
        siloGeneration &+= 1
        siloTask?.cancel()
        siloTask = nil
        silo.resetForIdentityChange()
        if let nextIdentity {
            siloState = .idle
            if restartSearch, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                launchSiloSearch(query: query, queryToken: queryGeneration,
                                 identity: nextIdentity, siloToken: siloGeneration)
            }
        } else {
            siloState = UnifiedSearchSourceStatus(phase: .unavailable, message: "Sign in to search Silo.")
        }
    }

    var isSiloIdentityCurrent: Bool { siloIdentity == siloIdentityProvider() }

    func isLiveTVCatalogCurrent(providerID: UUID?, revision: Int) -> Bool {
        observedCatalogIdentity == providerID.map {
            LiveTVChannelSearchIndex.Identity(providerID: $0, catalogRevision: revision)
        }
    }

    /// Stops source work when Search leaves the active navigation surface. Completed results stay
    /// available when a detail presentation returns; an interrupted search is restarted on reentry.
    func cancelForDismissal() {
        let wasPending = [siloState.phase, liveTVState.phase, programState.phase].contains { phase in
            phase == .loading || phase == .debouncing
        }
        guard wasPending else { return }
        resumeAfterDismissal = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        queryGeneration &+= 1
        siloGeneration &+= 1
        liveTVGeneration &+= 1
        debounceTask?.cancel()
        siloTask?.cancel()
        liveTVTask?.cancel()
        indexBuildTask?.cancel()
        debounceTask = nil
        siloTask = nil
        liveTVTask = nil
        indexBuildTask = nil
        buildingCatalogIdentity = nil
        silo.cancelForQueryChange()
        liveTVResults = []
        clearProgramSearch()
        siloState = siloIdentity == nil
            ? UnifiedSearchSourceStatus(phase: .unavailable, message: "Sign in to search Silo.")
            : .idle
        let catalog = catalogSnapshot()
        updateLiveTVAvailability(catalog)
        updateProgramAvailability(catalog)
    }

    func resumeAfterDismissalIfNeeded() {
        guard resumeAfterDismissal else { return }
        resumeAfterDismissal = false
        onQueryChanged(query)
    }

    /// Resolves a displayed safe row to a fresh channel record only at tap time. The full record
    /// (including its stream URL) remains a local result of this method, never stored in search state.
    func resolveChannel(for result: UnifiedLiveTVSearchResult) async -> LiveTVChannel? {
        guard liveTVResults.contains(where: { $0.id == result.id }) else { return nil }
        let snapshot = catalogSnapshot()
        guard let identity = snapshot.identity, identity == observedCatalogIdentity,
              let providerID = snapshot.providerID else { return nil }
        if let liveTVSource {
            let resolved = await liveTVSource.resolve(result.id, providerID, identity.catalogRevision)
            guard !Task.isCancelled, catalogSnapshot().identity == identity,
                  liveTVResults.contains(where: { $0.id == result.id }) else { return nil }
            return resolved
        }
        let channels = snapshot.channels
        let worker = Task.detached(priority: .userInitiated) { () -> LiveTVChannel? in
            for (offset, channel) in channels.enumerated() {
                if offset.isMultiple(of: 256), Task.isCancelled { return nil }
                guard channel.id == result.id,
                      LiveTVRecentChannel.belongs(channel.id, to: providerID) else { continue }
                return channel
            }
            return nil
        }
        let resolved = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, catalogSnapshot().identity == identity,
              liveTVResults.contains(where: { $0.id == result.id }) else { return nil }
        return resolved
    }

    /// Call when the active IPTV provider/catalog or its guide changes (guide generation, loading or
    /// staleness). A same-identity snapshot reuses the existing indexes. A changed source cancels its
    /// old query, rebuilds once, then searches the still-current query without a second debounce.
    func catalogDidChange() async {
        programSourceDidChange()
        await channelCatalogDidChange()
    }

    private func channelCatalogDidChange() async {
        let snapshot = catalogSnapshot()
        guard snapshot.identity != observedCatalogIdentity || snapshot.hasProvider != observedHasProvider else {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updateLiveTVAvailability(snapshot)
            }
            return
        }
        let previousIdentity = observedCatalogIdentity
        observedCatalogIdentity = snapshot.identity
        observedHasProvider = snapshot.hasProvider
        liveTVGeneration &+= 1
        let token = liveTVGeneration
        liveTVTask?.cancel()
        liveTVTask = nil
        if buildingCatalogIdentity != snapshot.identity {
            indexBuildTask?.cancel()
            indexBuildTask = nil
            buildingCatalogIdentity = nil
        }
        if previousIdentity != snapshot.identity {
            indexedCatalogIdentity = nil
            await indexStore.invalidate(providerID: previousIdentity?.providerID)
        }
        liveTVResults = []
        updateLiveTVAvailability(snapshot)

        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let queryToken = queryGeneration
            let currentQuery = query
            liveTVTask = Task { [weak self] in
                guard let self else { return }
                await runLiveTVSearch(query: currentQuery, queryToken: queryToken,
                                      liveToken: token, expected: snapshot.identity)
            }
        }
    }

    /// Optional retry entry point for source-local retry buttons.
    func retrySilo() {
        synchronizeSiloIdentity(restartSearch: false)
        guard let siloIdentity,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        siloGeneration &+= 1
        launchSiloSearch(query: query, queryToken: queryGeneration,
                         identity: siloIdentity, siloToken: siloGeneration)
    }

    func retryLiveTV() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        liveTVGeneration &+= 1
        let snapshot = catalogSnapshot()
        observedCatalogIdentity = snapshot.identity
        observedHasProvider = snapshot.hasProvider
        liveTVTask?.cancel()
        let token = liveTVGeneration
        liveTVTask = Task { [weak self] in
            guard let self else { return }
            await runLiveTVSearch(query: query, queryToken: queryGeneration,
                                  liveToken: token, expected: snapshot.identity)
        }
    }

    func retryPrograms() {
        guard programs != nil, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        clearProgramSearch()
        observedProgramSource = programSourceKey(catalogSnapshot())
        launchProgramSearch(query: query, queryToken: queryGeneration)
    }

    /// Resolves a displayed program to its channel (with stream URL) and guide entry at tap time,
    /// against the current catalog and guide. Nil if the result is no longer displayed, or the
    /// provider, catalog, guide or guide freshness changed since it was found.
    func resolveProgram(for result: UnifiedProgramSearchResult) async -> (channel: LiveTVChannel, program: EPGProgram)? {
        guard programs != nil, programResults.contains(where: { $0.id == result.id }),
              let published = publishedProgramIdentity else { return nil }
        let catalog = catalogSnapshot()
        guard let key = programSourceKey(catalog), key.identity == published, key.isReady,
              let guide = programGuide(catalog)?.guide else { return nil }
        let providerID = published.providerID
        if let liveTVSource {
            guard let channel = await liveTVSource.resolve(result.channelID, providerID,
                                                           published.catalogRevision),
                  guide.channelKey(guideID: channel.guideID, name: channel.name) == result.channelKey else { return nil }
            let window = DateInterval(start: result.start, end: max(result.end, result.start.addingTimeInterval(1)))
            let program = await Task.detached(priority: .userInitiated) {
                guide.matchingPrograms(channelKey: result.channelKey, overlapping: window)
                    .first(where: { $0.id == result.programID })
            }.value
            guard !Task.isCancelled, programSourceKey(catalogSnapshot()) == key,
                  publishedProgramIdentity == published,
                  programResults.contains(where: { $0.id == result.id }), let program else { return nil }
            return (channel, program)
        }
        let channels = catalog.channels
        let worker = Task.detached(priority: .userInitiated) { () -> (channel: LiveTVChannel, program: EPGProgram)? in
            var found: LiveTVChannel?
            for (offset, channel) in channels.enumerated() {
                if offset.isMultiple(of: 256), Task.isCancelled { return nil }
                if channel.id == result.channelID, LiveTVRecentChannel.belongs(channel.id, to: providerID) {
                    found = channel
                    break
                }
            }
            guard let channel = found,
                  guide.channelKey(guideID: channel.guideID, name: channel.name) == result.channelKey else { return nil }
            let window = DateInterval(start: result.start, end: max(result.end, result.start.addingTimeInterval(1)))
            // Off-main: a SQLite-backed guide reads this one channel from disk when it is not resident.
            guard let program = guide.matchingPrograms(channelKey: result.channelKey, overlapping: window)
                .first(where: { $0.id == result.programID }) else { return nil }
            return (channel, program)
        }
        let resolved = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, programSourceKey(catalogSnapshot()) == key,
              publishedProgramIdentity == published,
              programResults.contains(where: { $0.id == result.id }) else { return nil }
        return resolved
    }

    /// Keeps the catalog source's existing continuation/paging behavior available to the
    /// Movies & TV section. Paging never starts another request for the current query while a new
    /// query or Silo identity is pending.
    func loadMoreSilo() async {
        guard let identity = siloIdentity,
              identity == siloIdentityProvider(),
              !silo.isLoading else { return }
        let queryToken = queryGeneration
        let siloToken = siloGeneration
        await silo.loadMore()
        guard queryToken == queryGeneration, siloToken == siloGeneration,
              identity == siloIdentityProvider(), identity == siloIdentity else { return }
        refreshSiloStatus()
    }

    private func startSearch(query: String, generation: Int) {
        synchronizeSiloIdentity(restartSearch: false)
        guard generation == queryGeneration else { return }
        let snapshot = catalogSnapshot()
        if snapshot.identity != observedCatalogIdentity {
            observedCatalogIdentity = snapshot.identity
            observedHasProvider = snapshot.hasProvider
            liveTVGeneration &+= 1
        }
        let liveToken = liveTVGeneration
        if let siloIdentity {
            launchSiloSearch(query: query, queryToken: generation,
                             identity: siloIdentity, siloToken: siloGeneration)
        } else {
            siloState = UnifiedSearchSourceStatus(phase: .unavailable, message: "Sign in to search Silo.")
        }
        liveTVTask?.cancel()
        liveTVState = UnifiedSearchSourceStatus(phase: .loading)
        liveTVTask = Task { [weak self] in
            guard let self else { return }
            await runLiveTVSearch(query: query, queryToken: generation,
                                  liveToken: liveToken, expected: snapshot.identity)
        }
        launchProgramSearch(query: query, queryToken: generation)
    }

    private func launchSiloSearch(query: String, queryToken: Int,
                                  identity: UnifiedSiloIdentity, siloToken: Int) {
        siloTask?.cancel()
        siloState = UnifiedSearchSourceStatus(phase: .loading)
        siloTask = Task { [weak self] in
            guard let self else { return }
            await silo.performSearch(query: query)
            guard !Task.isCancelled, queryToken == queryGeneration,
                  siloToken == siloGeneration, identity == siloIdentity,
                  identity == siloIdentityProvider() else {
                synchronizeSiloIdentity(restartSearch: true)
                return
            }
            refreshSiloStatus()
        }
    }

    private func refreshSiloStatus() {
        let count = silo.titleResults.count + silo.peopleResults.count + silo.requestResults.count
        if silo.isLoading {
            siloState = UnifiedSearchSourceStatus(phase: .loading, resultCount: count)
        } else if let message = silo.errorMessage {
            siloState = UnifiedSearchSourceStatus(phase: count > 0 ? .partialFailure : .failed,
                                                  resultCount: count, message: message)
        } else if silo.hasSearched || count > 0 {
            siloState = UnifiedSearchSourceStatus(phase: .loaded, resultCount: count)
        } else {
            siloState = .idle
        }
    }

    private func runLiveTVSearch(query: String, queryToken: Int, liveToken: Int,
                                 expected: LiveTVChannelSearchIndex.Identity?) async {
        guard queryToken == queryGeneration, liveToken == liveTVGeneration else { return }
        let snapshot = catalogSnapshot()
        guard snapshot.identity == expected else {
            rejectChangedCatalog(snapshot, queryToken: queryToken)
            return
        }
        guard let expected, let providerID = snapshot.providerID else {
            updateLiveTVAvailability(snapshot)
            return
        }
        guard snapshot.channelCount > 0 || !snapshot.channels.isEmpty else {
            updateLiveTVAvailability(snapshot)
            return
        }

        liveTVState = UnifiedSearchSourceStatus(phase: .loading)
        if let liveTVSource {
            guard let found = await liveTVSource.search(query, providerID, expected.catalogRevision),
                  !Task.isCancelled, queryToken == queryGeneration, liveToken == liveTVGeneration,
                  catalogSnapshot().identity == expected else { return }
            liveTVResults = found.channels.enumerated().map { ordinal, channel in
                UnifiedLiveTVSearchResult(id: channel.id, name: channel.name, category: channel.category,
                                          ordinal: ordinal, logoURL: Self.safeLogoURL(channel.logoURL))
            }
            liveTVState = UnifiedSearchSourceStatus(phase: .loaded, resultCount: found.total)
            return
        }
        guard await installIndex(for: snapshot, identity: expected),
              !Task.isCancelled, queryToken == queryGeneration,
              liveToken == liveTVGeneration else { return }
        let matches = await indexStore.search(query: query, providerID: providerID,
                                              catalogRevision: expected.catalogRevision)
        guard !Task.isCancelled, queryToken == queryGeneration,
              liveToken == liveTVGeneration else { return }
        let current = catalogSnapshot()
        guard current.identity == expected else {
            rejectChangedCatalog(current, queryToken: queryToken)
            return
        }
        guard let matches else {
            liveTVState = UnifiedSearchSourceStatus(phase: .failed,
                                                   message: "Live TV search was canceled or became outdated.")
            return
        }

        // Validate IDs against the same provider/catalog snapshot off-main. The snapshot holds
        // full channel records only for this task; only safe display metadata crosses back.
        let resolutionWorker = Task.detached(priority: .userInitiated) {
            () -> [UnifiedLiveTVSearchResult]? in
            var channelsByID: [String: LiveTVChannel] = [:]
            channelsByID.reserveCapacity(current.channels.count)
            for (offset, channel) in current.channels.enumerated() {
                if offset.isMultiple(of: 256), Task.isCancelled { return nil }
                guard LiveTVRecentChannel.belongs(channel.id, to: providerID) else { continue }
                if channelsByID[channel.id] == nil { channelsByID[channel.id] = channel }
            }
            var resolved: [UnifiedLiveTVSearchResult] = []
            resolved.reserveCapacity(matches.count)
            for (offset, match) in matches.enumerated() {
                if offset.isMultiple(of: 256), Task.isCancelled { return nil }
                guard let channel = channelsByID[match.channelID] else { continue }
                resolved.append(UnifiedLiveTVSearchResult(id: channel.id, name: channel.name,
                                                          category: channel.category,
                                                          ordinal: match.ordinal,
                                                          logoURL: Self.safeLogoURL(channel.logoURL)))
            }
            return Task.isCancelled ? nil : resolved
        }
        let resolved = await withTaskCancellationHandler {
            await resolutionWorker.value
        } onCancel: {
            resolutionWorker.cancel()
        }
        guard !Task.isCancelled, queryToken == queryGeneration,
              liveToken == liveTVGeneration, let resolved else { return }
        guard resolved.count == matches.count else {
            liveTVResults = []
            liveTVState = UnifiedSearchSourceStatus(phase: .failed,
                                                   message: "The Live TV catalog changed; search again.")
            return
        }
        liveTVResults = resolved
        liveTVState = UnifiedSearchSourceStatus(phase: .loaded, resultCount: resolved.count)
    }

    private func installIndex(for snapshot: UnifiedSearchIPTVCatalogSnapshot,
                              identity: LiveTVChannelSearchIndex.Identity) async -> Bool {
        if indexedCatalogIdentity == identity { return true }
        if buildingCatalogIdentity == identity, let indexBuildTask {
            return await indexBuildTask.value && indexedCatalogIdentity == identity
        }
        indexBuildTask?.cancel()
        buildingCatalogIdentity = identity
        let worker = Task { [indexStore] in
            await indexStore.replaceCatalog(providerID: identity.providerID,
                                            catalogRevision: identity.catalogRevision,
                                            channels: snapshot.channels)
        }
        indexBuildTask = worker
        let built = await worker.value
        guard built, !Task.isCancelled, catalogSnapshot().identity == identity,
              buildingCatalogIdentity == identity else { return false }
        indexedCatalogIdentity = identity
        buildingCatalogIdentity = nil
        indexBuildTask = nil
        return true
    }

    private func rejectChangedCatalog(_ snapshot: UnifiedSearchIPTVCatalogSnapshot,
                                      queryToken: Int) {
        guard queryToken == queryGeneration else { return }
        observedCatalogIdentity = snapshot.identity
        observedHasProvider = snapshot.hasProvider
        liveTVGeneration &+= 1
        liveTVResults = []
        updateLiveTVAvailability(snapshot)
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let token = liveTVGeneration
            liveTVTask = Task { [weak self] in
                guard let self else { return }
                await runLiveTVSearch(query: query, queryToken: queryToken,
                                      liveToken: token, expected: snapshot.identity)
            }
        }
    }

    private func updateLiveTVAvailability(_ snapshot: UnifiedSearchIPTVCatalogSnapshot) {
        if !snapshot.hasProvider {
            liveTVState = UnifiedSearchSourceStatus(phase: .unavailable,
                                                   message: "No Live TV provider is configured.")
        } else if let error = snapshot.errorMessage, snapshot.channelCount == 0 && snapshot.channels.isEmpty {
            liveTVState = UnifiedSearchSourceStatus(phase: .failed, message: error)
        } else if snapshot.isLoading && snapshot.channelCount == 0 && snapshot.channels.isEmpty {
            liveTVState = UnifiedSearchSourceStatus(phase: .loading)
        } else {
            liveTVState = UnifiedSearchSourceStatus(phase: .loaded, resultCount: 0)
        }
    }

    // MARK: - TV programs

    /// What a program search depends on. Any difference means old program work is stale.
    private struct ProgramSourceKey: Equatable {
        let identity: EPGProgramSearchIndex.Identity
        let hasGuide: Bool
        /// Loading only while no guide is installed: a refresh of a guide that is still shown
        /// changes nothing until it publishes (and so changes the guide generation).
        let isGuideLoading: Bool
        let isGuideStale: Bool
        /// A storage switch replaces the guide; kept so the key also differs if that ever reuses a generation.
        let isSQLiteBacked: Bool
        let hasChannels: Bool

        var isReady: Bool { hasGuide && !isGuideStale && hasChannels }
    }

    private func programGuide(_ catalog: UnifiedSearchIPTVCatalogSnapshot) -> UnifiedSearchGuideSnapshot? {
        guard let programs, let providerID = catalog.providerID else { return nil }
        return programs.guideSnapshot(providerID)
    }

    private func programSourceKey(_ catalog: UnifiedSearchIPTVCatalogSnapshot) -> ProgramSourceKey? {
        guard let providerID = catalog.providerID, let guide = programGuide(catalog) else { return nil }
        return ProgramSourceKey(
            identity: .init(providerID: providerID, catalogRevision: catalog.catalogRevision,
                            guideGeneration: guide.guideGeneration),
            hasGuide: guide.guide != nil, isGuideLoading: guide.guide == nil && guide.isGuideLoading,
            isGuideStale: guide.isGuideStale,
                            isSQLiteBacked: guide.guide?.isSQLiteBacked ?? false,
                            hasChannels: catalog.channelCount > 0 || !catalog.channels.isEmpty)
    }

    /// Cancels program work and drops its results; any late completion fails its token check.
    private func clearProgramSearch() {
        programGeneration &+= 1
        programTask?.cancel()
        programTask = nil
        programResults = []
        publishedProgramIdentity = nil
    }

    /// Starts a program search against the source as it is now; a change before it publishes is
    /// caught by `runProgramSearch`'s checks before and after the store call.
    private func launchProgramSearch(query: String, queryToken: Int) {
        guard programs != nil else { return }
        programTask?.cancel()
        observedProgramSource = programSourceKey(catalogSnapshot())
        let token = programGeneration
        let expected = observedProgramSource
        programState = UnifiedSearchSourceStatus(phase: .loading)
        programTask = Task { [weak self] in
            guard let self else { return }
            await runProgramSearch(query: query, queryToken: queryToken, programToken: token, expected: expected)
        }
    }

    /// Called from `catalogDidChange`. A changed program source (provider, catalog revision, guide
    /// generation, loading, staleness or storage) cancels old work and searches again.
    private func programSourceDidChange() {
        guard programs != nil else { return }
        let catalog = catalogSnapshot()
        let key = programSourceKey(catalog)
        guard key != observedProgramSource else { return }
        observedProgramSource = key
        clearProgramSearch()
        updateProgramAvailability(catalog)
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, debounceTask == nil {
            launchProgramSearch(query: query, queryToken: queryGeneration)
        }
    }

    private func runProgramSearch(query: String, queryToken: Int, programToken: Int,
                                  expected: ProgramSourceKey?) async {
        guard let programs, queryToken == queryGeneration, programToken == programGeneration else { return }
        let catalog = catalogSnapshot()
        let key = programSourceKey(catalog)
        guard key == expected else {
            rejectChangedProgramSource(queryToken: queryToken)
            return
        }
        guard let key, key.isReady, let guide = programGuide(catalog)?.guide else {
            updateProgramAvailability(catalog)
            return
        }

        programState = UnifiedSearchSourceStatus(phase: .loading)
        let input: EPGProgramSearchIndexStore.Input
        if let liveTVSource {
            guard let associations = await liveTVSource.programAssociations(
                key.identity.providerID, key.identity.catalogRevision
            ) else { return }
            input = .init(identity: key.identity, guide: guide, associations: associations)
        } else {
            input = .init(identity: key.identity, guide: guide, channels: catalog.channels)
        }
        let outcome = await programs.store.search(query: query, input: input)
        guard !Task.isCancelled, queryToken == queryGeneration, programToken == programGeneration else { return }
        let current = catalogSnapshot()
        guard programSourceKey(current) == key else {
            rejectChangedProgramSource(queryToken: queryToken)
            return
        }

        let matches: [EPGProgramSearchIndex.Match]
        switch outcome {
        case .results(let found):
            matches = found
        case .queryTooShort:
            programState = .idle
            return
        case .noGuide:
            programState = UnifiedSearchSourceStatus(phase: .unavailable, message: "No TV guide is available.")
            return
        case .unsupportedStorage:
            // The SQLite guide file could not be opened or read.
            programState = UnifiedSearchSourceStatus(phase: .unavailable,
                                                     message: "TV program search isn't available for this guide.")
            return
        case nil:
            programState = UnifiedSearchSourceStatus(phase: .failed,
                                                     message: "TV program search was canceled or became outdated.")
            return
        }

        // Attach logos from the same catalog snapshot off-main. Only safe metadata crosses back.
        let providerID = key.identity.providerID
        let searchedAt = Date()
        if let liveTVSource {
            var resolved: [UnifiedProgramSearchResult] = []
            resolved.reserveCapacity(matches.count)
            for match in matches {
                guard let channel = await liveTVSource.resolve(match.channelID, providerID,
                                                               key.identity.catalogRevision) else { continue }
                resolved.append(UnifiedProgramSearchResult(
                    id: "\(match.channelID)|\(match.programID)", programID: match.programID,
                    channelID: match.channelID, channelKey: match.channelKey, channelName: match.channelName,
                    channelOrdinal: match.channelOrdinal, logoURL: Self.safeLogoURL(channel.logoURL),
                    title: match.title, subtitle: match.subtitle, start: match.start, end: match.end,
                    wasLiveAtSearch: match.start <= searchedAt && searchedAt < match.end))
            }
            guard !Task.isCancelled, queryToken == queryGeneration, programToken == programGeneration,
                  programSourceKey(catalogSnapshot()) == key else { return }
            programResults = resolved
            publishedProgramIdentity = key.identity
            programState = UnifiedSearchSourceStatus(phase: .loaded, resultCount: resolved.count)
            return
        }
        let worker = Task.detached(priority: .userInitiated) { () -> [UnifiedProgramSearchResult]? in
            var logos: [String: URL?] = [:]
            logos.reserveCapacity(matches.count)
            let wanted = Set(matches.map(\.channelID))
            for (offset, channel) in current.channels.enumerated() {
                if offset.isMultiple(of: 256), Task.isCancelled { return nil }
                guard wanted.contains(channel.id), logos[channel.id] == nil,
                      LiveTVRecentChannel.belongs(channel.id, to: providerID) else { continue }
                logos[channel.id] = Self.safeLogoURL(channel.logoURL)
            }
            var resolved: [UnifiedProgramSearchResult] = []
            resolved.reserveCapacity(matches.count)
            for match in matches {
                guard let logo = logos[match.channelID] else { continue }
                resolved.append(UnifiedProgramSearchResult(
                    id: "\(match.channelID)|\(match.programID)", programID: match.programID,
                    channelID: match.channelID, channelKey: match.channelKey, channelName: match.channelName,
                    channelOrdinal: match.channelOrdinal, logoURL: logo, title: match.title, subtitle: match.subtitle,
                    start: match.start, end: match.end, wasLiveAtSearch: match.start <= searchedAt && searchedAt < match.end))
            }
            return Task.isCancelled ? nil : resolved
        }
        let resolved = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, queryToken == queryGeneration, programToken == programGeneration,
              let resolved else { return }
        guard programSourceKey(catalogSnapshot()) == key else {
            rejectChangedProgramSource(queryToken: queryToken)
            return
        }
        guard resolved.count == matches.count else {
            programResults = []
            programState = UnifiedSearchSourceStatus(phase: .failed, message: "The Live TV catalog changed; search again.")
            return
        }
        programResults = resolved
        publishedProgramIdentity = key.identity
        programState = UnifiedSearchSourceStatus(phase: .loaded, resultCount: resolved.count)
    }

    /// The source changed under a running search: adopt the new state and search it once.
    private func rejectChangedProgramSource(queryToken: Int) {
        guard queryToken == queryGeneration else { return }
        let catalog = catalogSnapshot()
        observedProgramSource = programSourceKey(catalog)
        clearProgramSearch()
        updateProgramAvailability(catalog)
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            launchProgramSearch(query: query, queryToken: queryToken)
        }
    }

    private func updateProgramAvailability(_ catalog: UnifiedSearchIPTVCatalogSnapshot) {
        guard programs != nil else {
            programState = .idle
            return
        }
        guard catalog.hasProvider, let key = programSourceKey(catalog) else {
            programState = UnifiedSearchSourceStatus(phase: .unavailable, message: "No Live TV provider is configured.")
            return
        }
        if !key.hasChannels {
            if let error = catalog.errorMessage {
                programState = UnifiedSearchSourceStatus(phase: .failed, message: error)
            } else if catalog.isLoading {
                programState = UnifiedSearchSourceStatus(phase: .loading)
            } else {
                programState = UnifiedSearchSourceStatus(phase: .loaded, resultCount: 0)
            }
        } else if !key.hasGuide {
            programState = key.isGuideLoading
                ? UnifiedSearchSourceStatus(phase: .loading, message: "Loading the TV guide…")
                : UnifiedSearchSourceStatus(phase: .unavailable, message: "No TV guide is available.")
        } else if key.isGuideStale {
            programState = UnifiedSearchSourceStatus(phase: .unavailable, message: "The TV guide is out of date.")
        } else {
            programState = UnifiedSearchSourceStatus(phase: .loaded, resultCount: 0)
        }
    }

    nonisolated private static func safeLogoURL(_ url: URL?) -> URL? {
        guard let url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return nil
        }
        // Strip embedded userinfo and likely credential/signature query values before keeping a
        // logo URL in transient UI state. Plain paths and benign query values remain usable.
        components.user = nil
        components.password = nil
        let credentialMarkers = ["token", "auth", "key", "password", "secret", "credential", "signature", "sig"]
        if let queryItems = components.queryItems,
           queryItems.contains(where: { item in
               let key = item.name.lowercased()
               return credentialMarkers.contains(where: { key.contains($0) })
           }) {
            components.queryItems = nil
        }
        components.fragment = nil
        return components.url
    }
}
