import Foundation
import Observation
import CryptoKit

private enum LiveTVCatalogDownload: Sendable {
    case materialized(LiveTVCachedCatalog)
    #if os(iOS)
    case indexed(count: Int, categories: [String], hitChannelLimit: Bool)
    #endif
}

/// One memoized channel-to-guide match and the channel fields it was computed from.
struct LiveTVChannelKeyMemo {
    let guideID: String?
    let name: String
    let key: String?
}

@MainActor
@Observable
final class LiveTVService {
    static let shared = LiveTVService()

    private(set) var providers: [LiveTVProvider] = []
    private(set) var selectedProviderID: UUID?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// Soft notice for a successful import that hit the channel cap. Distinct from hard `errorMessage`
    /// failures such as an oversized playlist download.
    private(set) var catalogNotice: String?
    private(set) var guideMessage: String?
    private(set) var isGuideStale = false
    /// True while a guide download for the selected playlist is in progress.
    private(set) var isGuideLoading = false
    /// Changes whenever a full guide, provider, or source state changes, so views can drop
    /// derived layout. Single-channel short-guide publications use `guideChannelRevisions`.
    private(set) var guideRevision = 0
    /// Per-channel revisions let guide cells invalidate only the row whose short guide changed.
    /// IDs are provider-qualified, so switching providers cannot reuse a token accidentally.
    private(set) var guideChannelRevisions: [String: Int] = [:]
    /// Changes whenever a provider's guide index is installed, replaced or removed, including
    /// short-guide overlays, which leave `guideRevision` alone. Program search keys on it.
    private(set) var guideGenerations = EPGGuideGenerations()
    private(set) var favoriteChannelIDs = Set<String>()
    private(set) var recentlyWatchedRecords: [LiveTVRecentChannel] = []
    private(set) var channelCatalogRevision = 0
    private(set) var homeFavoriteChannels: [LiveTVChannel] = []
    private(set) var homeRecentChannels: [LiveTVChannel] = []
    private(set) var homeUpNext: [LiveTVUpNextItem] = []

    private var channelCatalogs: [UUID: [LiveTVChannel]] = [:]
    private var guideIndexes: [UUID: EPGIndex] = [:]
    private var categoryCatalogs: [UUID: [String]] = [:]
    /// Bumps whenever SQLite-backed guide listings finish loading, so channel rows read fresh data.
    private(set) var guideResidencyRevision = 0
    /// Channel → guide key for the installed guides. A channel without a guide-ID match is matched
    /// by its folded display name (12.8 µs per fold measured on an M2), and every guide row asked
    /// twice per build. Each entry remembers the guide ID and name it was computed from; the whole
    /// memo is dropped whenever any guide index is installed, replaced or removed.
    @ObservationIgnored private var channelKeyMemo: [String: LiveTVChannelKeyMemo] = [:]
    /// Newest requests load first; see `LiveTVGuideResidencyQueue`.
    @ObservationIgnored private var residencyPending = LiveTVGuideResidencyQueue()
    @ObservationIgnored private var residencyProviderID: UUID?
    @ObservationIgnored private var residencyGuideID: UUID?
    @ObservationIgnored private var residencyFailed = Set<String>()
    @ObservationIgnored private var residencyInFlight = Set<String>()
    @ObservationIgnored private var residencyTask: Task<Void, Never>?
    @ObservationIgnored private var pendingStartupTraces: [String: LiveTVStartupTrace] = [:]
#if DEBUG
    @ObservationIgnored var residencyPrefetchHookForTesting: (@Sendable (EPGIndex, [String]) async -> Void)?
#endif
    private static let warmGuideChannels = 96
    private static let residencyBatch = 64
    private var shortEPGInFlight = Set<String>()
    private var shortEPGFreshUntil: [String: Date] = [:]
    private let shortEPGNow: () -> Date
    private let defaults: UserDefaults
    private let secretStore: LiveTVSecretStore
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let epg: EPGService
    /// Backend selected when this service was created. Internal preference changes take effect on
    /// the next app launch, never midway through a guide session.
    var activeEPGStorageMode: EPGStorageMode { epg.storage }
    @ObservationIgnored private let channelSnapshotStore: LiveTVChannelSnapshotStore
    #if os(iOS)
    @ObservationIgnored private var channelStoreTask: Task<LiveTVChannelCatalogStore?, Never>?
    @ObservationIgnored private let channelStoreDirectory: URL?
    @ObservationIgnored private var favoriteStoreRevision = 0
    @ObservationIgnored private var favoriteStoreSyncedRevisions: [UUID: Int] = [:]
    @ObservationIgnored private var channelStoreFreshProviderIDs = Set<UUID>()
    #endif
    @ObservationIgnored private let recentHistoryStore: LiveTVRecentHistoryStore
    /// The one playlist download in flight. Removing its provider cancels it and clears this, so a
    /// late result can no longer be applied.
    @ObservationIgnored private var playlistRefresh: (providerID: UUID, token: UUID, task: Task<LiveTVCatalogDownload, Error>)?
    #if os(iOS)
    @ObservationIgnored private var catalogImportInProgress = false
    #endif
    /// Cached channel and guide restores, kept after they finish so each provider is read from disk once.
    @ObservationIgnored private var cacheRestores: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var guideCacheOrphanSweep: Task<Void, Never>?
    @ObservationIgnored private var homePreviewTask: Task<Void, Never>?
    @ObservationIgnored private var homePreviewWork: Task<LiveTVHomeChannelPreview.Result, Never>?
    @ObservationIgnored private var homePreviewGeneration = 0
    /// Provider whose previews are currently published; nil while they are empty.
    @ObservationIgnored private var homePreviewProviderID: UUID?
    @ObservationIgnored private var upNextTask: Task<Void, Never>?
    @ObservationIgnored private var upNextGeneration = 0
    /// Providers whose channels came from a playlist download in this process, so they can play.
    @ObservationIgnored private var liveCatalogs = Set<UUID>()

    /// Build 104: channels Sports can match and play. A restored SQLite generation keeps each
    /// channel's full stream URL, and Live TV already plays those rows before the session's
    /// download (`isPlayable` checks only the URL). Sports used to wait for that download and its
    /// 100K-row import (about 4.4 s on an M2 before any network time) on every cold launch: the
    /// rule "cached rows are not playable" dates from the JSON snapshot, which strips credentials.
    /// A finished download bumps the catalog revision, and Live Now re-matches against it.
    private func hasSportsMatchableCatalog(_ providerID: UUID) -> Bool {
        if liveCatalogs.contains(providerID) { return true }
        #if os(iOS)
        return channelStoreFreshProviderIDs.contains(providerID)
        #else
        return false
        #endif
    }
    @ObservationIgnored private var automaticRefreshAttempts: [UUID: Date] = [:]
    /// The one Live TV player session for the process, created on first playback. Views read it
    /// from here so a SwiftUI redraw never allocates a player or registers an audio claim.
    @ObservationIgnored private(set) lazy var playerSession: LiveTVPlayerSession = {
        let session = LiveTVPlayerSession.makeDefault()
        session.onPlayingReady = { [weak self] channelID, generation in
            self?.recordPlayingReady(channelID: channelID, generation: generation)
        }
        return session
    }()
    /// One full-screen player presentation and Picture in Picture hand-off, shared by the channel
    /// list and the guide.
    @ObservationIgnored let presentation = LiveTVPresentation(scheduler: LiveTVTaskScheduler())
    /// The pushed guide's filters and time position at the moment it chose a channel, read once by
    /// the watch screen's Guide tab. Never persisted.
    @ObservationIgnored var guideWatchHandoff: LiveTVGuideWatchHandoff?
    #if os(iOS)
    /// One-tap Sports Hub playback over the same session and presentation.
    @ObservationIgnored private(set) lazy var sportsPlayback: KyroSportsPlaybackCoordinator = {
        let coordinator = KyroSportsPlaybackCoordinator(scheduler: LiveTVTaskScheduler())
        coordinator.driver = self
        return coordinator
    }()
    /// Sports Hub Live Now: live events with strong local stream evidence. Metadata only; it
    /// never starts a stream. One per process so its match cache outlives a tab switch.
    @ObservationIgnored private(set) lazy var sportsLiveNow = KyroSportsLiveNowModel(source: self)
    @ObservationIgnored private var sportsPrepare: (token: UUID, finished: Bool)?
    @ObservationIgnored private var sportsPrewarm: Task<Void, Never>?
    /// True while the Sports Hub prewarm runs. Observed, so Live Now re-reads its availability
    /// when the prewarm ends, including when its catalog download failed.
    private(set) var isPrewarmingSports = false
    @ObservationIgnored private var sportsSearchTask: Task<Void, Never>?
    @ObservationIgnored private var isObservingSportsSession = false
    private static let sportsCatalogWaitSeconds: TimeInterval = 25
    #endif
    #if os(iOS)
    @ObservationIgnored private var pictureInPictureMonitor: LiveTVPictureInPictureMonitor?
    #endif

    private static let providersKey = "liveTV.providers.v1"
    private static let favoritesKey = "liveTV.favorites.v1"
    private static let maximumPlaylistBytes = LiveTVCatalogLimits.maximumPlaylistBytes
    private static let maximumChannels = LiveTVCatalogLimits.maximumChannels
    /// A downloaded playlist older than this is refreshed when Live TV opens.
    private static let playlistRefreshInterval: TimeInterval = 12 * 60 * 60
    /// Opening Live TV again within this time does not retry a download that just ran or failed.
    private static let automaticRetryInterval: TimeInterval = 5 * 60

    init(
        defaults: UserDefaults = .standard,
        secretStore: LiveTVSecretStore? = nil,
        session: URLSession? = nil,
        epg: EPGService? = nil,
        channelSnapshotStore: LiveTVChannelSnapshotStore = LiveTVChannelSnapshotStore(),
        channelStoreDirectory: URL? = nil,
        recentHistoryStore: LiveTVRecentHistoryStore? = nil,
        shortEPGNow: @escaping () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.secretStore = secretStore ?? KeychainLiveTVSecretStore()
        self.channelSnapshotStore = channelSnapshotStore
        #if os(iOS)
        self.channelStoreDirectory = channelStoreDirectory
        #endif
        self.recentHistoryStore = recentHistoryStore ?? LiveTVRecentHistoryStore(defaults: defaults)
        self.recentlyWatchedRecords = self.recentHistoryStore.read()
        self.shortEPGNow = shortEPGNow
        self.epg = epg ?? EPGService(
            cache: .makeDefault(),
            loader: session.map { URLSessionEPGFeedLoader(session: $0) } ?? URLSessionEPGFeedLoader.makeDefault(),
            storage: EPGStorageMode.current(defaults: defaults))
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            // A 40,000-channel playlist or Xtream list is 8–20 MB; 20 s total failed it on slower
            // connections. A stalled transfer still fails after 15 s without data.
            configuration.timeoutIntervalForResource = 60
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
        presentation.stopPlayback = { [weak self] in self?.endPlayback() }
        #if os(iOS)
        presentation.stopPictureInPicture = { PictureInPictureCoordinator.shared.stopPictureInPicture() }
        #endif
        favoriteChannelIDs = Set(defaults.stringArray(forKey: Self.favoritesKey) ?? [])
        if let data = defaults.data(forKey: Self.providersKey),
           let saved = try? JSONDecoder().decode([LiveTVProvider].self, from: data) {
            providers = saved
            selectedProviderID = saved.first?.id
        }
        if let selectedProviderID {
            // Cached-first startup reads a verified v2 guide. Legacy v1 migration stays off:
            // `EPGService.migrateLegacyCache(providerID:source:)` is the only switch, and nothing
            // in startup, restore, or refresh calls it.
            Task { [weak self] in await self?.restoreCachedState(for: selectedProviderID) }
        }
    }

    var channels: [LiveTVChannel] {
        guard let selectedProviderID else { return [] }
        // A successful iOS SQLite generation is the normal catalog. This array is retained only
        // for a legacy JSON migration or a failed-store fallback.
        return channelCatalogs[selectedProviderID] ?? []
    }

    /// Catalog size without requiring SwiftUI to read or retain the channel array.
    var selectedChannelCount: Int {
        guard let selectedProviderID else { return 0 }
        return providers.first(where: { $0.id == selectedProviderID })?.channelCount
            ?? channelCatalogs[selectedProviderID]?.count ?? 0
    }

    /// True once this provider's channels (cached or live) are in memory. Saved browsing state must
    /// wait for its own provider: `channelCatalogRevision` also changes when another provider loads.
    func hasCatalog(for providerID: UUID) -> Bool {
        #if os(iOS)
        channelStoreFreshProviderIDs.contains(providerID) || channelCatalogs[providerID] != nil
        #else
        channelCatalogs[providerID] != nil
        #endif
    }

    #if os(iOS)
    /// The shared channel database opens on a utility executor. Failed opens are retried on the
    /// next request; they never block the main actor or replace a previously usable catalog.
    private func channelStore() async -> LiveTVChannelCatalogStore? {
        #if DEBUG
        // Most isolated XCTest services use a suite-local defaults object. Unless a test
        // explicitly injects a catalog directory, never write their fixtures into the app cache.
        if channelStoreDirectory == nil && defaults !== UserDefaults.standard { return nil }
        #endif
        if let channelStoreTask { return await channelStoreTask.value }
        let directory = channelStoreDirectory
        let task = Task.detached(priority: .utility) { try? LiveTVChannelCatalogStore(directory: directory) }
        channelStoreTask = task
        let store = await task.value
        if store == nil { channelStoreTask = nil }
        return store
    }

    /// Provider-scoped bounded query for the in-progress iOS UI migration. The actor keeps all
    /// SQL work off the main actor; callers discard results if the provider or revision changes.
    func channelPage(providerID: UUID, query: String = "", category: String? = nil,
                     favoritesOnly: Bool = false, offset: Int = 0, limit: Int = 100) async -> [LiveTVChannel] {
        guard providers.contains(where: { $0.id == providerID }) else { return [] }
        if channelStoreFreshProviderIDs.contains(providerID), let store = await channelStore(),
           await store.count(providerID: providerID) > 0 {
            guard await synchronizeFavoritesIfNeeded(providerID: providerID, store: store) else { return [] }
            return await store.page(providerID: providerID, query: query, category: category,
                                    favoritesOnly: favoritesOnly, offset: offset, limit: limit)
        }
        // Existing installations may have only the legacy JSON snapshot on first launch after
        // updating. Keep that bounded-to-40K compatibility path until the next successful import.
        let catalog = channelCatalogs[providerID] ?? []
        let favorites = favoriteChannelIDs
        return await Task.detached(priority: .userInitiated) {
            let filtered = LiveTVChannelFiltering.filter(catalog, query: query, category: category,
                                                         favoritesOnly: favoritesOnly, favoriteIDs: favorites)
            let start = min(max(0, offset), filtered.count)
            let end = min(start + min(max(limit, 1), 200), filtered.count)
            return Array(filtered[start..<end])
        }.value
    }

    func channelCount(providerID: UUID, query: String = "", category: String? = nil,
                      favoritesOnly: Bool = false) async -> Int {
        guard providers.contains(where: { $0.id == providerID }) else { return 0 }
        if channelStoreFreshProviderIDs.contains(providerID), let store = await channelStore(),
           await store.count(providerID: providerID) > 0 {
            guard await synchronizeFavoritesIfNeeded(providerID: providerID, store: store) else { return 0 }
            return await store.count(providerID: providerID, query: query, category: category,
                                     favoritesOnly: favoritesOnly)
        }
        let catalog = channelCatalogs[providerID] ?? []
        let favorites = favoriteChannelIDs
        return await Task.detached(priority: .utility) {
            LiveTVChannelFiltering.filter(catalog, query: query, category: category,
                                          favoritesOnly: favoritesOnly, favoriteIDs: favorites).count
        }.value
    }

    func channel(providerID: UUID, id: String) async -> LiveTVChannel? {
        guard providers.contains(where: { $0.id == providerID }) else { return nil }
        if channelStoreFreshProviderIDs.contains(providerID), let store = await channelStore() {
            return await store.channel(providerID: providerID, id: id)
        }
        return channelCatalogs[providerID]?.first { $0.id == id }
    }

    func channelOffset(providerID: UUID, channelID: String, query: String = "", category: String? = nil,
                       favoritesOnly: Bool = false) async -> Int? {
        guard providers.contains(where: { $0.id == providerID }) else { return nil }
        if channelStoreFreshProviderIDs.contains(providerID), let store = await channelStore() {
            return await store.offset(providerID: providerID, channelID: channelID, query: query,
                                      category: category, favoritesOnly: favoritesOnly)
        }
        let catalog = channelCatalogs[providerID] ?? []
        let filtered = LiveTVChannelFiltering.filter(catalog, query: query, category: category,
                                                     favoritesOnly: favoritesOnly,
                                                     favoriteIDs: favoriteChannelIDs)
        return filtered.firstIndex { $0.id == channelID }
    }

    func programSearchAssociations(providerID: UUID) async -> [EPGProgramChannel] {
        guard providers.contains(where: { $0.id == providerID }) else { return [] }
        if channelStoreFreshProviderIDs.contains(providerID), let store = await channelStore() {
            let associations = await store.programAssociations(providerID: providerID)
            return await Task.detached(priority: .utility) {
                associations.map {
                    EPGProgramChannel(id: $0.id, guideID: $0.guideID, name: $0.name, ordinal: $0.ordinal)
                }
            }
            .value
        }
        return (channelCatalogs[providerID] ?? []).enumerated().map {
            EPGProgramChannel(id: $0.element.id, guideID: $0.element.guideID,
                              name: $0.element.name, ordinal: $0.offset)
        }
    }

    func categoryDirectory(providerID: UUID) async -> LiveTVCategoryDirectory {
        guard providers.contains(where: { $0.id == providerID }) else { return .empty }
        if channelStoreFreshProviderIDs.contains(providerID), let store = await channelStore(),
           await store.count(providerID: providerID) > 0,
           await synchronizeFavoritesIfNeeded(providerID: providerID, store: store) {
            return await LiveTVCategoryDirectory.indexed(store.categorySummaries(providerID: providerID))
        }
        let categories = categoryCatalogs[providerID] ?? []
        let catalog = channelCatalogs[providerID] ?? []
        let favorites = favoriteChannelIDs
        return await Task.detached(priority: .utility) {
            LiveTVCategoryDirectory.build(categories: categories, channels: catalog,
                                          favoriteIDs: favorites)
        }.value
    }

    private func synchronizeFavoritesIfNeeded(providerID: UUID,
                                              store: LiveTVChannelCatalogStore) async -> Bool {
        guard favoriteStoreSyncedRevisions[providerID] != favoriteStoreRevision else { return true }
        let revision = favoriteStoreRevision
        let prefix = providerID.uuidString + ":"
        let scoped = Set(favoriteChannelIDs.filter { $0.hasPrefix(prefix) })
        do {
            try await store.replaceFavorites(scoped, providerID: providerID)
            if favoriteStoreRevision == revision { favoriteStoreSyncedRevisions[providerID] = revision }
        } catch { return false }
        return favoriteStoreSyncedRevisions[providerID] == favoriteStoreRevision
    }

    /// Sports Hub's manual picker uses the fresh indexed catalog rather than building 40K folded
    /// entries on sheet presentation. A failed SQLite write retains the established array path.
    func sportsManualChannels(matching query: String, providerID: UUID) async -> [LiveTVChannel] {
        guard selectedProviderID == providerID, hasSportsMatchableCatalog(providerID) else { return [] }
        if channelStoreFreshProviderIDs.contains(providerID), let store = await channelStore() {
            let results = await store.page(providerID: providerID, query: query, limit: 40)
            guard selectedProviderID == providerID, hasSportsMatchableCatalog(providerID) else { return [] }
            return results.filter { isPlayable($0) }
        }
        let catalog = channelCatalogs[providerID] ?? []
        let providerIDs = playableProviderIDs
        let folded = KyroSportsStreamMatcher.normalized(query)
        return await Task.detached(priority: .userInitiated) {
            Array(catalog.lazy.filter {
                LiveTVService.isPlayable($0) { providerIDs.contains($0) }
                    && KyroSportsStreamMatcher.normalized($0.name + " " + $0.category).contains(folded)
            }.prefix(40))
        }.value
    }

    var canSearchSportsManualChannels: Bool {
        selectedProviderID.map { hasSportsMatchableCatalog($0) } ?? false
    }
    #endif

    var favoriteChannels: [LiveTVChannel] { homeFavoriteChannels }

    /// Only history that resolves to the active provider's current catalog is shown.
    var recentlyWatchedChannels: [LiveTVChannel] {
        homeRecentChannels
    }

    var selectedProvider: LiveTVProvider? {
        providers.first { $0.id == selectedProviderID }
    }

    func selectProvider(_ id: UUID) {
        guard providers.contains(where: { $0.id == id }) else { return }
        #if os(iOS)
        if let previous = selectedProviderID, previous != id {
            // The SQLite generation remains playable and provider-scoped. Do not retain complete
            // Swift catalogs for every provider visited during this process lifetime.
            channelCatalogs[previous] = nil
            cacheRestores.removeValue(forKey: previous)?.cancel()
        }
        #endif
        selectedProviderID = id
        scheduleHomePreviewRebuild()
        errorMessage = nil
        catalogNotice = nil
        guideMessage = nil
        isGuideLoading = false
        updateGuideFreshness(for: id)
        Task { [weak self] in await self?.restoreCachedState(for: id) }
    }

    /// Shows the provider's cached channels and guide without touching the network. Concurrent
    /// callers share one disk read; the files are decoded off the main actor.
    func restoreCachedState(for providerID: UUID) async {
        if let restore = cacheRestores[providerID] { return await restore.value }
        guard providers.contains(where: { $0.id == providerID }) else { return }
        if let guideCacheOrphanSweep {
            await guideCacheOrphanSweep.value
        } else {
            let service = epg
            let knownProviderIDs = Set(providers.map(\.id))
            let sweep = Task { await service.removeOrphanedCacheFiles(keeping: knownProviderIDs) }
            guideCacheOrphanSweep = sweep
            await sweep.value
        }
        guard providers.contains(where: { $0.id == providerID }) else { return }
        if let restore = cacheRestores[providerID] { return await restore.value }
        let restore = Task { [weak self] in
            guard let self else { return }
            await self.loadCachedState(for: providerID)
        }
        cacheRestores[providerID] = restore
        await restore.value
    }

    private func loadCachedState(for providerID: UUID) async {
        let secrets = snapshotSecrets(providerID: providerID)
        let epgSource = loadSourceConfiguration(providerID: providerID).flatMap(Self.epgFeedSource)
        #if os(iOS)
        // Prefer the protected SQLite generation before touching the legacy JSON snapshot. This
        // avoids decoding and retaining a second full catalog when both formats exist after an
        // interrupted migration. JSON remains the recovery path only when SQLite is unavailable.
        if let store = await channelStore(), await store.count(providerID: providerID) > 0,
           providers.contains(where: { $0.id == providerID }) {
            categoryCatalogs[providerID] = await store.categories(providerID: providerID).map(\.name)
            channelStoreFreshProviderIDs.insert(providerID)
            await pruneRecentHistory(providerID: providerID, store: store)
            channelCatalogRevision &+= 1
            if selectedProviderID == providerID { scheduleHomePreviewRebuild() }
        }
        #endif
        if !hasCatalog(for: providerID),
           let cached = await channelSnapshotStore.loadCatalog(providerID: providerID, secrets: secrets),
           // A download may have finished, or the provider been removed, while the file was read.
           !hasCatalog(for: providerID), providers.contains(where: { $0.id == providerID }) {
            channelCatalogs[providerID] = cached.channels
            categoryCatalogs[providerID] = cached.categories
            #if os(iOS)
            await pruneRecentHistory(for: providerID, validChannels: cached.channels)
            #else
            pruneRecentHistory(for: providerID, validChannels: cached.channels)
            #endif
            channelCatalogRevision &+= 1
            if selectedProviderID == providerID { scheduleHomePreviewRebuild() }
        }
        // The guide cache is keyed by provider and only returned while still usable. Short-guide
        // listings alone never stand in for it.
        guard !showsFullGuide(providerID), let epgSource,
              let index = await epg.index(for: providerID, source: epgSource),
              !showsFullGuide(providerID), providers.contains(where: { $0.id == providerID }) else { return }
        setGuideIndex(index, for: providerID)
        invalidateAllGuideRows()
        warmGuideWindow(providerID)
        if selectedProviderID == providerID { updateGuideFreshness(for: providerID) }
    }

    /// Cached channels and guide first, then a playlist download only when one is due: no playable
    /// catalog yet this session, or the last download is old. Explicit refreshes skip this check.
    func prepareSelectedProvider(now: Date = .now) async {
        guard let providerID = selectedProviderID else { return }
        await restoreCachedState(for: providerID)
        guard selectedProviderID == providerID, needsAutomaticRefresh(providerID, now: now) else { return }
        automaticRefreshAttempts[providerID] = now
        await refresh(providerID: providerID)
    }

    private func needsAutomaticRefresh(_ providerID: UUID, now: Date) -> Bool {
        guard playlistRefresh == nil else { return false }
        if let attempt = automaticRefreshAttempts[providerID],
           now.timeIntervalSince(attempt) < Self.automaticRetryInterval { return false }
        guard liveCatalogs.contains(providerID),
              let refreshed = providers.first(where: { $0.id == providerID })?.lastRefreshed else { return true }
        return now.timeIntervalSince(refreshed) > Self.playlistRefreshInterval
    }

    @discardableResult
    func saveConfiguration(name: String, playlistURL: String, xmltvURL: String?) throws -> UUID {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPlaylistURL = playlistURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanXMLTVURL = xmltvURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty,
              Self.isWebURL(cleanPlaylistURL),
              cleanXMLTVURL?.isEmpty != false || cleanXMLTVURL.map(Self.isWebURL) == true else {
            throw LiveTVError.invalidConfiguration
        }
        let configuration = LiveTVSourceConfiguration(
            playlistURL: cleanPlaylistURL,
            xmltvURL: cleanXMLTVURL?.nilIfEmpty
        )
        return try store(configuration, name: cleanName, kind: .m3u)
    }

    @discardableResult
    func saveXtreamConfiguration(name: String, serverURL: String, username: String, password: String) throws -> UUID {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanServer = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanUsername.isEmpty, !password.isEmpty else { throw LiveTVError.invalidConfiguration }
        _ = try XtreamURLBuilder.apiURL(server: cleanServer, username: cleanUsername, password: password)
        let configuration = LiveTVSourceConfiguration(
            playlistURL: nil, xmltvURL: nil, kind: .xtream,
            serverURL: cleanServer, username: cleanUsername, password: password
        )
        return try store(configuration, name: cleanName, kind: .xtream)
    }

    #if os(iOS)
    /// Credentials stay in the existing Keychain-backed provider record; VOD never persists them.
    func xtreamVODConfiguration(for providerID: UUID) -> LiveTVSourceConfiguration? {
        guard providers.contains(where: { $0.id == providerID && $0.kind == .xtream }),
              let serialized = secretStore.read(account: Self.secretAccount(providerID)),
              let data = serialized.data(using: .utf8),
              let source = try? JSONDecoder().decode(LiveTVSourceConfiguration.self, from: data),
              source.kind == .xtream else { return nil }
        return source
    }
    #endif

    private func store(_ configuration: LiveTVSourceConfiguration, name: String, kind: LiveTVProviderKind) throws -> UUID {
        let id = UUID()
        let encoded = try JSONEncoder().encode(configuration)
        guard let serialized = String(data: encoded, encoding: .utf8),
              secretStore.save(serialized, account: Self.secretAccount(id)) else {
            throw LiveTVError.keychainUnavailable
        }
        providers.append(LiveTVProvider(id: id, name: name, channelCount: 0, lastRefreshed: nil, kind: kind))
        selectedProviderID = id
        scheduleHomePreviewRebuild()
        persistProviders()
        return id
    }

    /// Forgets the provider at once, then deletes its files. Everything the UI reads (selection,
    /// channels, guide, status) is settled before the first suspension, so no view or late task can
    /// observe a selected provider that no longer exists.
    func removeProvider(_ id: UUID) async {
        forgetProvider(id)
        await deleteProviderFiles(id)
    }

    /// The synchronous half of removal: in-memory state, credentials and the selection.
    func forgetProvider(_ id: UUID) {
        presentation.providerRemoved(id, activeChannelID: playerSession.activeChannelID)
        if playlistRefresh?.providerID == id {
            playlistRefresh?.task.cancel()
            playlistRefresh = nil
            isLoading = false
        }
        cacheRestores.removeValue(forKey: id)?.cancel()
        liveCatalogs.remove(id)
        #if os(iOS)
        channelStoreFreshProviderIDs.remove(id)
        #endif
        automaticRefreshAttempts[id] = nil
        providers.removeAll { $0.id == id }
        channelCatalogs[id] = nil
        categoryCatalogs[id] = nil
        #if os(iOS)
        favoriteStoreSyncedRevisions[id] = nil
        #endif
        setGuideIndex(nil, for: id)
        if residencyProviderID == id {
            residencyTask?.cancel()
            residencyPending.removeAll()
            residencyInFlight.removeAll()
            residencyFailed.removeAll()
        }
        invalidateAllGuideRows()
        channelCatalogRevision &+= 1
        favoriteChannelIDs = favoriteChannelIDs.filter { !$0.hasPrefix("\(id.uuidString):") }
        defaults.set(favoriteChannelIDs.sorted(), forKey: Self.favoritesKey)
        recentlyWatchedRecords = LiveTVRecentHistory.pruning(recentlyWatchedRecords, providerID: id,
                                                             validChannelIDs: [])
        recentHistoryStore.save(recentlyWatchedRecords)
        shortEPGInFlight = shortEPGInFlight.filter { !$0.hasPrefix("\(id.uuidString):") }
        shortEPGFreshUntil = shortEPGFreshUntil.filter { !$0.key.hasPrefix("\(id.uuidString):") }
        _ = secretStore.remove(account: Self.secretAccount(id))
        let wasSelected = selectedProviderID == id
        if wasSelected { selectedProviderID = providers.first?.id }
        if wasSelected { scheduleHomePreviewRebuild() }
        persistProviders()
        // Status belongs to the selected provider; removing another one leaves it alone.
        guard wasSelected else { return }
        errorMessage = nil
        catalogNotice = nil
        guideMessage = nil
        isGuideLoading = false
        if let selectedProviderID { updateGuideFreshness(for: selectedProviderID) } else { isGuideStale = true }
    }

    /// The disk half of removal: the channel snapshot and the guide cache.
    func deleteProviderFiles(_ id: UUID) async {
        await channelSnapshotStore.remove(providerID: id)
        #if os(iOS)
        if let store = await channelStore() { try? await store.remove(providerID: id) }
        #endif
        await epg.remove(providerID: id)
        #if os(iOS)
        await XtreamVODService.shared.remove(providerID: id)
        #endif
    }

    func refreshSelectedProvider() async {
        guard let selectedProviderID else { return }
        await refresh(providerID: selectedProviderID)
    }

    func refresh(providerID: UUID) async {
        #if os(iOS)
        guard playlistRefresh == nil, !catalogImportInProgress else { return }
        catalogImportInProgress = true
        defer { catalogImportInProgress = false }
        defer { isLoading = false }
        #else
        guard playlistRefresh == nil else { return }
        #endif
        guard providers.contains(where: { $0.id == providerID }),
              let serialized = secretStore.read(account: Self.secretAccount(providerID)),
              let data = serialized.data(using: .utf8),
              let source = try? JSONDecoder().decode(LiveTVSourceConfiguration.self, from: data),
              (source.kind == .m3u ? source.playlistURL.map(Self.isWebURL) == true : source.serverURL.map(Self.isWebURL) == true) else {
            if selectedProviderID == providerID {
                errorMessage = "Add a valid playlist in Live TV settings to load channels."
            }
            return
        }

        // Build 104: time the whole refresh (download, import, verification) and mark the span,
        // so the performance report shows its cost and whether other screens slow down meanwhile.
        let refreshStarted = KyroPerformanceClock.now()
        KyroPerformanceDiagnostics.catalogRefresh(true)
        defer {
            KyroPerformanceDiagnostics.catalogRefresh(false)
            KyroPerformanceDiagnostics.record(.liveTVCatalogRefresh,
                                              milliseconds: (KyroPerformanceClock.now() - refreshStarted) * 1000)
        }
        let token = UUID()
        let work = Task { [weak self] () throws -> LiveTVCatalogDownload in
            guard let self else { throw CancellationError() }
            return try await self.downloadCatalog(source, providerID: providerID)
        }
        playlistRefresh = (providerID, token, work)
        isLoading = true
        if selectedProviderID == providerID {
            errorMessage = nil
            catalogNotice = nil
            guideMessage = nil
        }

        let result = await work.result
        // Removing the provider cancels this refresh and has already cleared the loading state.
        guard playlistRefresh?.token == token else { return }
        playlistRefresh = nil
        #if !os(iOS)
        isLoading = false
        #endif
        guard providers.contains(where: { $0.id == providerID }) else { return }

        let download: LiveTVCatalogDownload
        switch result {
        case .success(let catalog):
            download = catalog
        case .failure(let error as LiveTVError):
            if selectedProviderID == providerID { errorMessage = error.localizedDescription }
            return
        case .failure:
            if selectedProviderID == providerID {
                errorMessage = "The playlist could not be loaded. Check the provider settings and try again."
            }
            return
        }
        let loaded: LiveTVCachedCatalog?
        let importedCount: Int
        let importedCategories: [String]
        let hitChannelLimit: Bool
        var alreadyIndexed = false
        switch download {
        case .materialized(let catalog):
            loaded = catalog
            importedCount = catalog.channels.count
            importedCategories = catalog.categories
            hitChannelLimit = catalog.hitChannelLimit
        #if os(iOS)
        case .indexed(let count, let categories, let wasTruncated):
            guard let store = await channelStore(), await store.count(providerID: providerID) == count else {
                channelStoreFreshProviderIDs.remove(providerID)
                if selectedProviderID == providerID {
                    errorMessage = "The indexed channel catalog could not be verified after import."
                }
                return
            }
            loaded = nil
            importedCount = count
            importedCategories = categories
            hitChannelLimit = wasTruncated
            self.channelCatalogs[providerID] = nil
            alreadyIndexed = true
        #endif
        }
        #if os(iOS)
        guard !Task.isCancelled, providers.contains(where: { $0.id == providerID }),
              loadSourceConfiguration(providerID: providerID) == source else { return }
        if alreadyIndexed {
            channelStoreFreshProviderIDs.insert(providerID)
        } else if let loaded, let store = await channelStore() {
            // A cancelled or failed stage leaves its previous generation selected. Keep the
            // established in-memory/JSON path usable during this staged UI migration.
            if (try? await LiveTVChannelCatalogImporter.replace(loaded.channels, providerID: providerID, in: store)) != nil {
                channelStoreFreshProviderIDs.insert(providerID)
            } else {
                channelStoreFreshProviderIDs.remove(providerID)
            }
        } else {
            channelStoreFreshProviderIDs.remove(providerID)
        }
        guard !Task.isCancelled, providers.contains(where: { $0.id == providerID }),
              loadSourceConfiguration(providerID: providerID) == source else {
            channelStoreFreshProviderIDs.remove(providerID)
            if !providers.contains(where: { $0.id == providerID }), let store = await channelStore() {
                try? await store.remove(providerID: providerID)
            }
            return
        }
        #endif
        let previousChannels = channelCatalogs[providerID] ?? []
        #if os(iOS)
        guard !Task.isCancelled, providers.contains(where: { $0.id == providerID }),
              loadSourceConfiguration(providerID: providerID) == source else { return }
        #else
        let previousFilter = EPGChannelFilter(guideIDs: previousChannels.map(\.guideID), names: previousChannels.map(\.name))
        let updatedFilter = EPGChannelFilter(guideIDs: loaded?.channels.map(\.guideID) ?? [],
                                             names: loaded?.channels.map(\.name) ?? [])
        #endif
        #if os(iOS)
        let guideFilterChanged = hasCatalog(for: providerID)
        channelCatalogs[providerID] = alreadyIndexed ? nil : loaded?.channels
        #else
        let guideFilterChanged = !previousChannels.isEmpty && previousFilter != updatedFilter
        channelCatalogs[providerID] = loaded?.channels
        #endif
        categoryCatalogs[providerID] = importedCategories
        #if os(iOS)
        isLoading = false
        #endif
        #if os(iOS)
        if alreadyIndexed, let store = await channelStore() {
            await pruneRecentHistory(providerID: providerID, store: store)
        } else if let loaded {
            await pruneRecentHistory(for: providerID, validChannels: loaded.channels)
        }
        #else
        pruneRecentHistory(for: providerID, validChannels: loaded?.channels ?? [])
        #endif
        channelCatalogRevision &+= 1
        if selectedProviderID == providerID { scheduleHomePreviewRebuild() }
        liveCatalogs.insert(providerID)
        if let providerIndex = providers.firstIndex(where: { $0.id == providerID }) {
            providers[providerIndex].channelCount = importedCount
            providers[providerIndex].lastRefreshed = .now
            providers[providerIndex].catalogWasTruncated = hitChannelLimit
            persistProviders()
        }
        if selectedProviderID == providerID {
            catalogNotice = hitChannelLimit
                ? LiveTVCatalogNotice.channelLimitReached(limit: Self.maximumChannels)
                : nil
        }

        #if os(iOS)
        if channelStoreFreshProviderIDs.contains(providerID) {
            // The protected, non-purgeable SQLite generation is the offline snapshot. Remove the
            // legacy JSON only after promotion, eliminating a second full-catalog encode and file.
            await channelSnapshotStore.remove(providerID: providerID)
        } else if let loaded {
            await channelSnapshotStore.save(providerID: providerID, channels: loaded.channels,
                                            secrets: LiveTVSnapshotSecrets(source: source))
        }
        #else
        if let loaded {
            await channelSnapshotStore.save(providerID: providerID, channels: loaded.channels,
                                            secrets: LiveTVSnapshotSecrets(source: source))
        }
        #endif
        // The provider may have been removed while the snapshot was written; never leave it behind.
        guard providers.contains(where: { $0.id == providerID }) else {
            await channelSnapshotStore.remove(providerID: providerID)
            #if os(iOS)
            if let store = await channelStore() { try? await store.remove(providerID: providerID) }
            #endif
            return
        }
        // Channels are usable now; the guide fills in behind them.
        await refreshGuide(providerID: providerID, source: source, force: guideFilterChanged)
    }

    private func downloadCatalog(_ source: LiveTVSourceConfiguration, providerID: UUID) async throws -> LiveTVCatalogDownload {
        #if os(iOS)
        if source.kind == .m3u, let playlistURL = source.playlistURL, let store = await channelStore() {
            let previousGeneration = await store.activeGeneration(providerID: providerID)
            let playlistData = try await fetch(playlistURL, maximumBytes: Self.maximumPlaylistBytes)
            let channelLimit = Self.maximumChannels
            let importing = Task.detached(priority: .utility) {
                try await LiveTVChannelCatalogImporter.stageM3U(
                    data: playlistData, providerID: providerID, in: store, limit: channelLimit
                )
            }
            let imported = try await withTaskCancellationHandler {
                try await importing.value
            } onCancel: {
                importing.cancel()
            }
            guard !Task.isCancelled, providers.contains(where: { $0.id == providerID }),
                  loadSourceConfiguration(providerID: providerID) == source else {
                try? await store.pruneOrphans()
                throw CancellationError()
            }
            try await store.promote(providerID: providerID, generation: imported.generation,
                                    expectedCount: imported.channelCount)
            guard !Task.isCancelled, providers.contains(where: { $0.id == providerID }),
                  loadSourceConfiguration(providerID: providerID) == source else {
                try? await store.restoreActiveGeneration(providerID: providerID,
                                                         generation: previousGeneration)
                try? await store.pruneOrphans()
                throw CancellationError()
            }
            try? await store.pruneOrphans()
            let categories = await store.categories(providerID: providerID).map(\.name)
            return .indexed(count: imported.channelCount, categories: categories,
                            hitChannelLimit: imported.hitChannelLimit)
        }
        if source.kind == .xtream, let store = await channelStore() {
            return try await downloadAndStageXtream(source, providerID: providerID, store: store)
        }
        #endif
        let loadedChannels: [LiveTVChannel]
        let hitChannelLimit: Bool
        if source.kind == .m3u, let playlistURL = source.playlistURL {
            let playlistData = try await fetch(playlistURL, maximumBytes: Self.maximumPlaylistBytes)
            let channelLimit = Self.maximumChannels
            let parsed = try await Task.detached(priority: .utility) {
                try LiveTVM3UParser.parseResult(data: playlistData, providerID: providerID, limit: channelLimit)
            }.value
            loadedChannels = parsed.channels
            hitChannelLimit = parsed.hitChannelLimit
        } else {
            let xtream = try await loadXtream(source, providerID: providerID)
            loadedChannels = xtream.channels
            hitChannelLimit = xtream.hitChannelLimit
        }
        guard !loadedChannels.isEmpty else { throw LiveTVError.noChannels }
        let categories = await Task.detached(priority: .utility) {
            LiveTVChannel.orderedCategories(of: loadedChannels)
        }.value
        return .materialized(LiveTVCachedCatalog(channels: loadedChannels, categories: categories,
                                                 hitChannelLimit: hitChannelLimit))
    }

    #if os(iOS)
    private func downloadAndStageXtream(_ source: LiveTVSourceConfiguration, providerID: UUID,
                                        store: LiveTVChannelCatalogStore) async throws -> LiveTVCatalogDownload {
        guard let server = source.serverURL, let username = source.username, let password = source.password else {
            throw LiveTVError.invalidConfiguration
        }
        let previousGeneration = await store.activeGeneration(providerID: providerID)
        let authURL = try XtreamURLBuilder.apiURL(server: server, username: username, password: password)
        let authData = try await fetch(authURL, maximumBytes: 1024 * 1024)
        let outputFormats = try XtreamResponseParser.account(from: authData)
        if let providerIndex = providers.firstIndex(where: { $0.id == providerID }) {
            providers[providerIndex].allowedOutputFormats = outputFormats
            persistProviders()
        }

        var categoryNames: [String: String] = [:]
        if let categoryURL = try? XtreamURLBuilder.apiURL(server: server, username: username, password: password,
                                                          action: "get_live_categories"),
           let categoryData = try? await fetch(categoryURL, maximumBytes: 4 * 1024 * 1024) {
            categoryNames = await Task.detached(priority: .utility) {
                guard let records = try? XtreamResponseParser.categories(from: categoryData) else { return [:] }
                return Dictionary(records.compactMap { record in
                    guard let id = record.categoryID, let name = record.categoryName,
                          !id.isEmpty, !name.isEmpty else { return nil }
                    return (id, name)
                }, uniquingKeysWith: { first, _ in first })
            }.value
        }

        let streamsURL = try XtreamURLBuilder.apiURL(server: server, username: username, password: password,
                                                     action: "get_live_streams")
        let streamsData = try await fetch(streamsURL, maximumBytes: Self.maximumPlaylistBytes)
        let channelLimit = Self.maximumChannels
        let importing = Task.detached(priority: .utility) {
            try await LiveTVChannelCatalogImporter.stageXtream(
                data: streamsData, providerID: providerID, in: store, server: server,
                username: username, password: password, outputFormats: outputFormats,
                categories: categoryNames, limit: channelLimit
            )
        }
        let imported = try await withTaskCancellationHandler {
            try await importing.value
        } onCancel: {
            importing.cancel()
        }
        guard !Task.isCancelled, providers.contains(where: { $0.id == providerID }),
              loadSourceConfiguration(providerID: providerID) == source else {
            try? await store.pruneOrphans()
            throw CancellationError()
        }
        try await store.promote(providerID: providerID, generation: imported.generation,
                                expectedCount: imported.channelCount)
        guard !Task.isCancelled, providers.contains(where: { $0.id == providerID }),
              loadSourceConfiguration(providerID: providerID) == source else {
            try? await store.restoreActiveGeneration(providerID: providerID, generation: previousGeneration)
            try? await store.pruneOrphans()
            throw CancellationError()
        }
        try? await store.pruneOrphans()
        let categories = await store.categories(providerID: providerID).map(\.name)
        return .indexed(count: imported.channelCount, categories: categories,
                        hitChannelLimit: imported.hitChannelLimit)
    }
    #endif

    /// Shows the cached guide immediately, then refreshes it when the policy says it is due.
    private func refreshGuide(providerID: UUID, source: LiveTVSourceConfiguration, force: Bool = false) async {
        guard providers.contains(where: { $0.id == providerID }) else { return }
        let refreshID = UUID()
        let refreshStartedAt = ProcessInfo.processInfo.systemUptime
        LiveTVStartupTrace.recordEPG("guide_refresh_started", operationID: refreshID,
                                     startedAt: refreshStartedAt,
                                     backend: activeEPGStorageMode == .sqlite ? "sqlite" : "memory")
        defer {
            LiveTVStartupTrace.recordEPG("guide_refresh_finished", operationID: refreshID,
                                         startedAt: refreshStartedAt,
                                         backend: activeEPGStorageMode == .sqlite ? "sqlite" : "memory")
        }
        let feed = Self.epgFeedSource(source)
        guard let feed else {
            setGuideIndex(nil, for: providerID)
            invalidateAllGuideRows()
            await epg.clear(providerID: providerID)
            guard providers.contains(where: { $0.id == providerID }) else { return }
            if selectedProviderID == providerID {
                guideMessage = nil
                updateGuideFreshness(for: providerID)
            }
            return
        }
        if selectedProviderID == providerID { isGuideLoading = true }
        defer { if selectedProviderID == providerID { isGuideLoading = false } }
        #if os(iOS)
        let filter = await epgChannelFilter(providerID: providerID)
        #else
        let channels = channelCatalogs[providerID] ?? []
        let filter = EPGChannelFilter(guideIDs: channels.map(\.guideID), names: channels.map(\.name))
        #endif
        let currentEPGSource = Self.epgFeedSource(source)
        if !showsFullGuide(providerID), let currentEPGSource {
            let cached = await epg.index(for: providerID, source: currentEPGSource)
            // Removal can finish while the source-verified cached read is queued on disk. Never
            // fall through and start a network refresh after that await.
            guard providers.contains(where: { $0.id == providerID }) else { return }
            if let cached, !showsFullGuide(providerID) {
                setGuideIndex(cached, for: providerID)
                invalidateAllGuideRows()
                warmGuideWindow(providerID)
                if selectedProviderID == providerID { updateGuideFreshness(for: providerID) }
            }
        }
        guard providers.contains(where: { $0.id == providerID }) else { return }
        do {
            let index = try await epg.refresh(providerID: providerID, source: feed, channels: filter, force: force)
            guard providers.contains(where: { $0.id == providerID }) else { return }
            setGuideIndex(index, for: providerID)
            invalidateAllGuideRows()
            warmGuideWindow(providerID)
            if selectedProviderID == providerID {
                guideMessage = EPGGuideStatus.message(for: index)
            }
        } catch is CancellationError {
            return
        } catch {
            // Keep a previously loaded guide; never print or surface a provider URL or transport error.
            if providers.contains(where: { $0.id == providerID }), selectedProviderID == providerID {
                guideMessage = "Guide data could not be refreshed."
            }
        }
        if providers.contains(where: { $0.id == providerID }), selectedProviderID == providerID {
            updateGuideFreshness(for: providerID)
        }
    }

    #if os(iOS)
    /// Builds only the normalized guide-ID/name filter payload. Stream URLs, artwork, categories,
    /// channel IDs, and full channel values stay on disk.
    private func epgChannelFilter(providerID: UUID) async -> EPGChannelFilter? {
        if channelStoreFreshProviderIDs.contains(providerID), let store = await channelStore(),
           let values = await store.epgAssociationValues(providerID: providerID) {
            return await Task.detached(priority: .utility) {
                EPGChannelFilter(guideIDs: values.guideIDs, names: values.names)
            }.value
        }
        let channels = channelCatalogs[providerID] ?? []
        guard !channels.isEmpty else { return nil }
        return await Task.detached(priority: .utility) {
            EPGChannelFilter(guideIDs: channels.map(\.guideID), names: channels.map(\.name))
        }.value
    }
    #endif

    var categories: [String] {
        guard let selectedProviderID else { return [] }
        return categoryCatalogs[selectedProviderID] ?? []
    }

    private func loadXtream(_ source: LiveTVSourceConfiguration, providerID: UUID) async throws -> (channels: [LiveTVChannel], hitChannelLimit: Bool) {
        guard let server = source.serverURL, let username = source.username, let password = source.password else {
            throw LiveTVError.invalidConfiguration
        }
        let authURL = try XtreamURLBuilder.apiURL(server: server, username: username, password: password)
        let authData = try await fetch(authURL, maximumBytes: 1024 * 1024)
        let outputFormats = try XtreamResponseParser.account(from: authData)
        if let providerIndex = providers.firstIndex(where: { $0.id == providerID }) {
            providers[providerIndex].allowedOutputFormats = outputFormats
            persistProviders()
        }

        var categoryNames: [String: String] = [:]
        if let categoryURL = try? XtreamURLBuilder.apiURL(server: server, username: username, password: password,
                                                           action: "get_live_categories"),
           let categoryData = try? await fetch(categoryURL, maximumBytes: 4 * 1024 * 1024) {
            categoryNames = await Task.detached(priority: .utility) {
                guard let records = try? XtreamResponseParser.categories(from: categoryData) else { return [:] }
                return Dictionary(records.compactMap { record in
                    guard let id = record.categoryID, let name = record.categoryName, !id.isEmpty, !name.isEmpty else { return nil }
                    return (id, name)
                }, uniquingKeysWith: { first, _ in first })
            }.value
        }

        let streamsURL = try XtreamURLBuilder.apiURL(server: server, username: username, password: password, action: "get_live_streams")
        let streamsData = try await fetch(streamsURL, maximumBytes: Self.maximumPlaylistBytes)
        let maxChannels = Self.maximumChannels
        let parsed = try await Task.detached(priority: .utility) {
            let records = try XtreamResponseParser.streams(from: streamsData)
            var channels: [LiveTVChannel] = []
            channels.reserveCapacity(min(records.count, maxChannels))
            var seen = Set<Int>()
            var accepted = 0
            var hitChannelLimit = false
            for record in records {
                if accepted >= maxChannels {
                    // More stream records remain after the cap; do not invent a total count.
                    hitChannelLimit = true
                    break
                }
                guard let streamID = record.streamID, streamID > 0, seen.insert(streamID).inserted,
                      let name = record.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
                let streamURL = try XtreamURLBuilder.streamURL(server: server, username: username, password: password,
                    streamID: streamID, extension: record.containerExtension, allowedOutputFormats: outputFormats)
                let digest = LiveTVM3UParser.hex(SHA256.hash(data: Data("\(providerID.uuidString)|xtream|\(streamID)".utf8)))
                channels.append(LiveTVChannel(id: "\(providerID.uuidString):\(digest)",
                    guideID: record.epgChannelID?.nilIfEmpty ?? String(streamID), name: name, streamURL: streamURL,
                    logoURL: record.streamIcon.flatMap(Self.webURL),
                    category: record.categoryID.flatMap { categoryNames[$0] } ?? "Other", streamID: streamID))
                accepted += 1
            }
            return (channels: channels, hitChannelLimit: hitChannelLimit)
        }.value
        guard !parsed.channels.isEmpty else { throw LiveTVError.noChannels }
        return (channels: parsed.channels, hitChannelLimit: parsed.hitChannelLimit)
    }

    func refreshShortEPG(for channel: LiveTVChannel) async {
        guard let streamID = channel.streamID,
              let providerID = UUID(uuidString: String(channel.id.prefix(36))),
              !shortEPGInFlight.contains(channel.id) else { return }
        let guideID = channel.guideID ?? String(streamID)
        if (shortEPGFreshUntil[channel.id] ?? .distantPast) > shortEPGNow(),
           await epg.hasShortGuide(providerID: providerID, guideID: guideID) {
            return
        }
        guard
              let serialized = secretStore.read(account: Self.secretAccount(providerID)),
              let data = serialized.data(using: .utf8),
              let source = try? JSONDecoder().decode(LiveTVSourceConfiguration.self, from: data),
              source.kind == .xtream, let server = source.serverURL,
              let username = source.username, let password = source.password else { return }
        shortEPGInFlight.insert(channel.id)
        defer { shortEPGInFlight.remove(channel.id) }
        let shortRefreshID = UUID()
        let shortRefreshStartedAt = ProcessInfo.processInfo.systemUptime
        LiveTVStartupTrace.recordEPG("short_refresh_started", operationID: shortRefreshID,
                                     startedAt: shortRefreshStartedAt,
                                     backend: activeEPGStorageMode == .sqlite ? "sqlite" : "memory")
        defer {
            LiveTVStartupTrace.recordEPG("short_refresh_finished", operationID: shortRefreshID,
                                         startedAt: shortRefreshStartedAt,
                                         backend: activeEPGStorageMode == .sqlite ? "sqlite" : "memory")
        }
        // The ticket is issued before the request is sent. A full refresh, source change or removal
        // that happens while the request is in flight makes the response stale, and EPGService drops it.
        guard let epgSource = Self.epgFeedSource(source),
              let ticket = await epg.beginShortRequest(providerID: providerID, source: epgSource,
                                                       guideID: guideID) else {
            return
        }
        do {
            let url = try XtreamURLBuilder.apiURL(server: server, username: username, password: password,
                                                 action: "get_short_epg", streamID: streamID, limit: 10)
            let data = try await fetch(url, maximumBytes: 512 * 1024)
            try Task.checkCancellation()
            guard providers.contains(where: { $0.id == providerID }) else { return }
            let programs = try XtreamEPG.programs(from: data, guideID: guideID, limits: epg.limits)
            guard let publication = await epg.applyShortProgramsWithRetention(programs, guideID: guideID,
                                                                                ticket: ticket) else {
                // Superseded by a newer full guide, a newer response for this channel, a source
                // change, or cancelled before publication. A later selection may request it again.
                return
            }
            let index = publication.index
            shortEPGFreshUntil[channel.id] = shortEPGNow().addingTimeInterval(programs.isEmpty ? 5 * 60 : 15 * 60)
            if shortEPGFreshUntil.count > 256,
               let oldest = shortEPGFreshUntil.min(by: { $0.value < $1.value })?.key {
                shortEPGFreshUntil.removeValue(forKey: oldest)
            }
            guard providers.contains(where: { $0.id == providerID }) else { return }
            // A short-guide result that lost the race with cache load must not replace a full guide
            // already published here. Re-read so the short listings are applied on top of it.
            let published: EPGIndex
            if index.isShortGuideOnly, showsFullGuide(providerID) {
                guard let merged = await epg.index(for: providerID, source: epgSource),
                      !merged.isShortGuideOnly,
                      providers.contains(where: { $0.id == providerID }) else {
                    return
                }
                published = merged
            } else {
                published = index
            }
            setGuideIndex(published, for: providerID)
            for evictedGuideID in publication.evictedGuideIDs {
                #if os(iOS)
                if channelStoreFreshProviderIDs.contains(providerID), let store = await channelStore() {
                    for id in await store.channelIDs(providerID: providerID, guideID: evictedGuideID) {
                        guideChannelRevisions[id, default: 0] &+= 1
                    }
                    continue
                }
                #endif
                let evictedKey = EPGChannelKey.guideID(evictedGuideID)
                for evictedChannel in channelCatalogs[providerID] ?? []
                    where EPGChannelKey.guideID(evictedChannel.guideID) == evictedKey {
                    guideChannelRevisions[evictedChannel.id, default: 0] &+= 1
                }
            }
            guideChannelRevisions[channel.id, default: 0] &+= 1
            if selectedProviderID == providerID {
                // An empty short response is not evidence that the full guide has no listings.
                guideMessage = EPGGuideStatus.message(for: published)
                updateGuideFreshness(for: providerID)
            }
        } catch {
            // Bound retries for transport/parse failures; cancellation remains immediately retryable.
            if !(error is CancellationError), !Task.isCancelled {
                shortEPGFreshUntil[channel.id] = shortEPGNow().addingTimeInterval(2 * 60)
                if shortEPGFreshUntil.count > 256,
                   let oldest = shortEPGFreshUntil.min(by: { $0.value < $1.value })?.key {
                    shortEPGFreshUntil.removeValue(forKey: oldest)
                }
            }
            // The shared fetch reports a cancelled download as a provider error; the task's own
            // cancellation state is authoritative. Cancellation is not a failure to report.
            guard !(error is CancellationError), !Task.isCancelled else { return }
            if providers.contains(where: { $0.id == providerID }), selectedProviderID == providerID {
                guideMessage = "Guide data could not be refreshed."
            }
        }
    }

    /// Stops the live stream and releases its Picture in Picture binding. Nothing keeps playing.
    func endPlayback() {
        KyroLifecycleJournal.record("livetv", "end_playback", LiveTVPresentation.journalName(presentation.phase))
        playerSession.stop()
        #if os(iOS)
        PictureInPictureCoordinator.shared.endSession(owner: playerSession)
        #endif
    }

    /// Build 65: Sports Hub is leaving the view hierarchy. An inline stream that automatic Picture in
    /// Picture is showing is not headless: hand it to the window, exactly as the window's own button
    /// does, so the hub's disappearance cannot close a window the viewer is watching. Returns true
    /// when it did. A restore then brings the player back over the shell.
    @discardableResult
    func inlineHostWillDisappear() -> Bool {
        #if os(iOS)
        let engaged = PictureInPictureCoordinator.shared.ownsEngagedSession(playerSession)
        KyroLifecycleJournal.record("sports", "hub_disappear",
                                    "\(LiveTVPresentation.journalName(presentation.phase)) pip_engaged=\(engaged)")
        guard presentation.isInline, engaged else { return false }
        presentation.pictureInPictureStartedFromControl()
        return true
        #else
        return false
        #endif
    }

    /// Binds Picture in Picture to the session once a tune has created its engine, and starts
    /// watching the session for failures while the window owns it.
    func attachPictureInPicture() {
        #if os(iOS)
        playerSession.bindPictureInPicture(presentation: presentation)
        if pictureInPictureMonitor == nil {
            pictureInPictureMonitor = LiveTVPictureInPictureMonitor(session: playerSession, presentation: presentation) { [weak self] in
                guard let self else { return }
                self.playerSession.bindPictureInPicture(presentation: self.presentation)
            }
        }
        #endif
    }

    /// A channel was chosen in the list or the guide. Opens the player, or retunes the Picture in
    /// Picture window in place.
    func choose(_ channel: LiveTVChannel, from presenter: LiveTVPresenter) {
        let startupTrace = LiveTVStartupTrace(channelID: channel.id,
                                              backend: activeEPGStorageMode == .sqlite ? "sqlite" : "memory")
        startupTrace.record("channel_tap_received")
        guard isPlayable(channel) else { startupTrace.record("playback_failed"); rejectCachedPlayback(); return }
        startupTrace.record("stream_url_available_and_validated")
        Task { await refreshShortEPG(for: channel) }
        // Ordinary Live TV playback never carries a Sports Hub event's Other Streams.
        #if os(iOS)
        if sportsPlaybackIsActive { cancelSportsPlayback(); sportsPlayback.ordinaryPlaybackStarted() }
        #endif
        let selection = presentation.select(channel, from: presenter)
        if selection == .playInPlace {
            playerSession.play(channel, startupTrace: startupTrace)
        } else if selection == .present {
            pendingStartupTraces.values.forEach { $0.finish(.incomplete) }
            pendingStartupTraces = [channel.id: startupTrace]
        }
    }

    /// Called by the presented player task after SwiftUI creates the cover. This records the
    /// player request boundary rather than treating presentation as playback initialization.
    func playPresentedChannel(_ channel: LiveTVChannel) {
        let trace = pendingStartupTraces.removeValue(forKey: channel.id)
        playerSession.play(channel, startupTrace: trace)
    }

    /// Shared validation and session route for channel-picker retunes inside the player.
    @discardableResult
    func playFromPlayerPicker(_ channel: LiveTVChannel) -> Bool {
        let startupTrace = LiveTVStartupTrace(channelID: channel.id,
                                              backend: activeEPGStorageMode == .sqlite ? "sqlite" : "memory")
        startupTrace.record("channel_tap_received")
        guard isPlayable(channel) else { startupTrace.record("playback_failed"); rejectCachedPlayback(); return false }
        startupTrace.record("stream_url_available_and_validated")
        Task { await refreshShortEPG(for: channel) }
        errorMessage = nil
        presentation.playerChannelChanged(to: channel)
        playerSession.play(channel, startupTrace: startupTrace)
        return true
    }

    /// The playback gate, for surfaces that should only offer channels playback will accept.
    func canPlay(_ channel: LiveTVChannel) -> Bool { isPlayable(channel) }

    #if os(iOS)
    // MARK: Sports Hub streams

    /// Warms what an event tap needs: a downloaded (playable) catalog and its match index. Uses
    /// the same due-only refresh policy as opening Live TV, so it adds no extra downloads.
    func prewarmSportsMatching() {
        guard let providerID = selectedProviderID, sportsPrewarm == nil else { return }
        isPrewarmingSports = true
        sportsPrewarm = Task { [weak self] in
            guard let self else { return }
            defer {
                self.sportsPrewarm = nil
                self.isPrewarmingSports = false
            }
            await self.prepareSelectedProvider()
            guard self.selectedProviderID == providerID else { return }
            // Candidate retrieval is event-specific and bounded; prewarm only ensures the
            // provider's playable SQLite generation is ready.
        }
    }

    /// Local event-to-stream candidates against the selected provider. Reuses one channel index
    /// per catalog revision and one guide-key map per guide generation, and reads only guide
    /// programmes around the event; nothing here touches the network except the due-only
    /// playlist refresh that makes cached channels playable.
    func sportsStreamMatches(for game: KyroSportsGame, now: Date = .now) async -> KyroSportsStreamMatchResult {
        let request = KyroSportsStreamMatchRequest(game: game, now: now)
        guard let providerID = selectedProviderID else {
            return KyroSportsStreamMatcher.emptyResult(for: request, guide: nil, cancelled: false)
        }
        await awaitPlayableCatalog(providerID)
        guard !Task.isCancelled, selectedProviderID == providerID,
              let index = await sportsChannelIndex(for: providerID, game: game), !Task.isCancelled else {
            return KyroSportsStreamMatcher.emptyResult(for: request, guide: nil, cancelled: true)
        }
        let guide = guideIndexes[providerID]
        let keys = await guide.asyncFlatMap { await self.sportsGuideKeys(index: index, guide: $0, providerID: providerID) }
        return await Task.detached(priority: .userInitiated) {
            KyroSportsStreamMatcher.match(request: request, index: index, guide: guide, guideKeys: keys)
        }.value
    }

    /// A tap needs playable channels: the restored SQLite generation or this session's download.
    /// Without either, start the due refresh and wait, but only until the channels are in (never
    /// for the guide). Restoring the SQLite generation ends the wait in milliseconds.
    private func awaitPlayableCatalog(_ providerID: UUID) async {
        guard !hasSportsMatchableCatalog(providerID) else { return }
        let token = UUID()
        sportsPrepare = (token, false)
        Task { [weak self] in
            await self?.prepareSelectedProvider()
            if self?.sportsPrepare?.token == token { self?.sportsPrepare = (token, true) }
        }
        let deadline = Date().addingTimeInterval(Self.sportsCatalogWaitSeconds)
        // The refresh publishes channels before it downloads the guide; stop waiting then.
        while !hasSportsMatchableCatalog(providerID), Date() < deadline, !Task.isCancelled,
              sportsPrepare?.token == token, sportsPrepare?.finished == false {
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private func sportsChannelIndex(for providerID: UUID, game: KyroSportsGame) async -> KyroSportsChannelIndex? {
        let revision = channelCatalogRevision
        let isLive = hasSportsMatchableCatalog(providerID) && providers.contains(where: { $0.id == providerID })
        guard isLive else { return nil }
        var candidates: [LiveTVChannel] = []
        #if os(iOS)
        if channelStoreFreshProviderIDs.contains(providerID) {
            var seen = Set<String>()
            let phrases = KyroSportsStreamMatcher.candidateSearchTerms(for: game)
            for phrase in phrases where !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let page = await channelPage(providerID: providerID, query: phrase, limit: 200)
                for channel in page where seen.insert(channel.id).inserted { candidates.append(channel) }
                if candidates.count >= KyroSportsChannelIndex.maximumCandidateChannels { break }
            }
            candidates = Array(candidates.prefix(KyroSportsChannelIndex.maximumCandidateChannels))
            // Channels the guide says are airing the event (generic networks carry no team name).
            if let guide = guideIndexes[providerID], let store = await channelStore() {
                let request = KyroSportsStreamMatchRequest(game: game, now: .now)
                let keys = await Task.detached(priority: .userInitiated) {
                    KyroSportsStreamMatcher.guideCandidateKeys(guide: guide, request: request)
                }.value
                for channel in await store.channels(providerID: providerID, guideKeys: keys)
                where seen.insert(channel.id).inserted { candidates.append(channel) }
            }
        } else {
            candidates = channelCatalogs[providerID] ?? []
        }
        #else
        candidates = channelCatalogs[providerID] ?? []
        #endif
        let task = Task.detached(priority: .userInitiated) { () -> KyroSportsChannelIndex? in
            let playable = candidates.filter { ["http", "https"].contains($0.streamURL.scheme?.lowercased() ?? "") }
            return KyroSportsChannelIndex.build(channels: playable, providerID: providerID,
                                                catalogRevision: revision)
        }
        let value = await task.value
        guard selectedProviderID == providerID, channelCatalogRevision == revision else { return nil }
        return value
    }

    private func sportsGuideKeys(index: KyroSportsChannelIndex, guide: EPGIndex, providerID: UUID) async -> [String: [Int32]]? {
        let task = Task.detached(priority: .userInitiated) { index.guideKeyMap(for: guide) }
        return await task.value
    }

    #if KYRO_INTERNAL_EPG_STORAGE_TOGGLE
    /// INTERNAL TEST builds only: the Sports Match Report for one event, built from the same
    /// cached channel index, guide and guide-key map a tap uses, off the main actor. Nil when no
    /// playable catalog is loaded, or when the provider, catalog or guide changed while building.
    /// No download, no playback.
    func sportsMatchReport(for game: KyroSportsGame, now: Date = .now) async -> KyroSportsMatchReport? {
        guard let providerID = selectedProviderID, liveCatalogs.contains(providerID),
              let index = await sportsChannelIndex(for: providerID, game: game), !Task.isCancelled else { return nil }
        let generation = guideGenerations.generation(for: providerID)
        let guide = guideIndexes[providerID]
        let keys = await guide.asyncFlatMap { await self.sportsGuideKeys(index: index, guide: $0, providerID: providerID) }
        guard !Task.isCancelled, guide == nil || keys != nil, selectedProviderID == providerID,
              index.catalogRevision == channelCatalogRevision,
              guideGenerations.generation(for: providerID) == generation else { return nil }
        let mode: KyroSportsMatchReportBuilder.StorageMode = guide.map { $0.isSQLiteBacked ? .sqlite : .memory } ?? .none
        let input = KyroSportsMatchReportBuilder.Input(request: .init(game: game, now: now), index: index, guide: guide,
                                                       guideKeys: keys, guideGeneration: generation,
                                                       storageMode: mode, createdAt: now)
        let work = Task.detached(priority: .utility) { KyroSportsMatchReportBuilder.build(input) }
        let report = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled, selectedProviderID == providerID, index.catalogRevision == channelCatalogRevision,
              guideGenerations.generation(for: providerID) == generation else { return nil }
        return report
    }
    #endif

    /// Starts one-tap playback for an event: discovery, then automatic attempts through the one
    /// Live TV session. The coordinator's phase tells the Sports Hub what to show.
    func playSportsEvent(_ game: KyroSportsGame, now: Date = .now) {
        // Build 39: upcoming, final, postponed and canceled events never start discovery or
        // playback, whichever Sports Hub surface asked.
        guard KyroSportsPlaybackEligibility.isInProgress(game) else { return }
        let coordinator = sportsPlayback
        // Build 46: the event already playing inline keeps playing; a second tap is not a retune.
        guard !(coordinator.isPlaying(game.id) && presentation.isInline) else { return }
        let token = coordinator.beginSearching(game)
        sportsSearchTask?.cancel()
        sportsSearchTask = Task { [weak self] in
            guard let self else { return }
            guard await self.prepareSportsPlayback() else {
                let result = await self.sportsStreamMatches(for: game, now: now)
                guard !Task.isCancelled, token == coordinator.generation else { return }
                coordinator.startUnavailable(result, for: game, token: token,
                                             message: "Close Picture in Picture, then try again.")
                return
            }
            let result = await self.sportsStreamMatches(for: game, now: now)
            guard !Task.isCancelled, token == coordinator.generation else { return }
            coordinator.start(result, for: game, token: token,
                              allowsAutomaticPlayback: KyroSportsPlaybackPolicy.allowsAutomaticPlayback(game, now: now))
        }
    }

    /// Plays a stream the viewer picked on the event's discovery screen. The connecting banner
    /// shows while Live TV's Picture in Picture closes; if it will not close, the discovery screen
    /// returns with the reason instead of the pick silently doing nothing.
    func playSportsStream(_ match: KyroSportsStreamMatch, for game: KyroSportsGame, result: KyroSportsStreamMatchResult) {
        let coordinator = sportsPlayback
        let token = coordinator.beginSearching(game)
        sportsSearchTask?.cancel()
        sportsSearchTask = Task { [weak self] in
            guard let self else { return }
            let ready = await self.prepareSportsPlayback()
            guard !Task.isCancelled, token == coordinator.generation else { return }
            guard ready else {
                coordinator.startUnavailable(result, for: game, token: token,
                                             message: "Close Picture in Picture, then try again.")
                return
            }
            coordinator.playChosen(match, game: game, result: result)
        }
    }

    /// What the guide shows now on each channel, for stream rows without a matched listing. Reads
    /// at most 40 channels off the main actor; never touches the network.
    func sportsCurrentProgrammes(for channels: [LiveTVChannel], at date: Date = .now) async -> [String: EPGProgram] {
        guard let providerID = selectedProviderID, let guide = guideIndexes[providerID], !channels.isEmpty else { return [:] }
        let list = Array(channels.prefix(40))
        return await Task.detached(priority: .userInitiated) {
            var found: [String: EPGProgram] = [:]
            for channel in list {
                if Task.isCancelled { break }
                guard let key = guide.channelKey(guideID: channel.guideID, name: channel.name) else { continue }
                if !guide.isResident(channelKey: key) { guide.prefetch(channelKeys: [key]) }
                if let current = guide.nowNext(channelKey: key, at: date).current { found[channel.id] = current }
            }
            return found
        }.value
    }

    func cancelSportsPlayback() {
        sportsSearchTask?.cancel()
        sportsSearchTask = nil
        sportsPlayback.cancel()
    }

    /// Live TV's own Picture in Picture window must close before the session is retuned headless;
    /// otherwise the window would show the attempts. False when it does not close in time.
    /// An inline stream for another event ends first, so its audio never runs under the attempts
    /// and an event with nothing to try leaves no stream playing behind the discovery screen.
    private func prepareSportsPlayback() async -> Bool {
        observeSportsSessionIfNeeded()
        switch presentation.phase {
        case .idle:
            return true
        case .inline:
            presentation.releaseInline()
            endPlayback()
            return true
        case .presented, .restoring:
            return false
        case .pictureInPicture:
            presentation.stopPictureInPicture?()
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(100))
                if presentation.phase == .idle { return true }
            }
            return false
        }
    }

    /// Re-reads the session and presentation for the coordinator on every change.
    private func observeSportsSessionIfNeeded() {
        guard !isObservingSportsSession else { return }
        isObservingSportsSession = true
        observeSportsSession()
    }

    private func observeSportsSession() {
        withObservationTracking {
            _ = playerSession.state
            _ = playerSession.activeChannelID
            _ = presentation.phase
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sportsPlayback.sessionDidChange()
                if self.sportsPlayback.phase == .presented, self.presentation.phase == .idle {
                    self.sportsPlayback.playerClosed()
                }
                self.observeSportsSession()
            }
        }
    }
    #endif

    private func isPlayable(_ channel: LiveTVChannel) -> Bool {
        Self.isPlayable(channel) { id in providers.contains(where: { $0.id == id }) }
    }

    /// IDs of the configured providers, so a long channel list can be checked off the main actor.
    var playableProviderIDs: Set<UUID> { Set(providers.map(\.id)) }

    /// The playback gate as a pure check: a configured provider's channel with a web stream URL.
    nonisolated static func isPlayable(_ channel: LiveTVChannel, isKnownProvider: (UUID) -> Bool) -> Bool {
        guard let providerID = UUID(uuidString: String(channel.id.prefix(36))), isKnownProvider(providerID),
              let scheme = channel.streamURL.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func rejectCachedPlayback() {
        if selectedProviderID != nil { errorMessage = "Refresh the playlist to play this channel." }
    }

    func toggleFavorite(_ channel: LiveTVChannel) {
        if !favoriteChannelIDs.insert(channel.id).inserted { favoriteChannelIDs.remove(channel.id) }
        #if os(iOS)
        favoriteStoreRevision &+= 1
        #endif
        defaults.set(favoriteChannelIDs.sorted(), forKey: Self.favoritesKey)
        if UUID(uuidString: String(channel.id.prefix(36))) == selectedProviderID { scheduleHomePreviewRebuild() }
    }

    func isFavorite(_ channel: LiveTVChannel) -> Bool {
        favoriteChannelIDs.contains(channel.id)
    }

    /// Called only after the player session accepts a playing-ready transition for its current
    /// generation. The exact channel must still resolve in its provider's current catalog.
    private func recordPlayingReady(channelID: String, generation: Int) {
        let session = playerSession
        let providerID = UUID(uuidString: String(channelID.prefix(36)))
        #if os(iOS)
        Task { [weak self] in
            guard let self, let providerID else { return }
            let isValid: Bool
            if self.channelStoreFreshProviderIDs.contains(providerID), let store = await self.channelStore() {
                isValid = await store.contains(providerID: providerID, id: channelID)
            } else {
                isValid = self.channelCatalogs[providerID]?.contains(where: { $0.id == channelID }) == true
            }
            self.finishRecordingPlayingReady(channelID: channelID, generation: generation,
                                             providerID: providerID, isValid: isValid)
        }
        return
        #else
        let validChannelIDs = providerID.flatMap { channelCatalogs[$0] }.map { Set($0.map(\.id)) } ?? []
        guard let entry = LiveTVRecentHistory.playingReadyEntry(
                  channelID: channelID, generation: generation,
                  currentGeneration: session.controller.generation, activeChannelID: session.activeChannelID,
                  isPlaying: session.state == .playing,
                  providerIsPresent: providerID.map { id in providers.contains(where: { $0.id == id }) } ?? false,
                  validChannelIDs: validChannelIDs),
              recentlyWatchedRecords.first != entry else { return }
        recentlyWatchedRecords = LiveTVRecentHistory.inserting(entry, into: recentlyWatchedRecords)
        recentHistoryStore.save(recentlyWatchedRecords)
        if selectedProviderID == providerID { scheduleHomePreviewRebuild() }
        #endif
    }

    #if os(iOS)
    private func finishRecordingPlayingReady(channelID: String, generation: Int,
                                             providerID: UUID, isValid: Bool) {
        let session = playerSession
        guard let entry = LiveTVRecentHistory.playingReadyEntry(
                  channelID: channelID, generation: generation,
                  currentGeneration: session.controller.generation, activeChannelID: session.activeChannelID,
                  isPlaying: session.state == .playing,
                  providerIsPresent: providers.contains(where: { $0.id == providerID }),
                  validChannelIDs: isValid ? [channelID] : []),
              recentlyWatchedRecords.first != entry else { return }
        recentlyWatchedRecords = LiveTVRecentHistory.inserting(entry, into: recentlyWatchedRecords)
        recentHistoryStore.save(recentlyWatchedRecords)
        if selectedProviderID == providerID { scheduleHomePreviewRebuild() }
    }
    #endif

    #if os(iOS)
    private func pruneRecentHistory(for providerID: UUID, validChannels: [LiveTVChannel]) async {
        let records = recentlyWatchedRecords
        let updated = await Task.detached(priority: .utility) {
            let wanted = Set(records.filter { $0.providerID == providerID }.map(\.channelID))
            let validIDs = Set(validChannels.lazy.map(\.id).filter { wanted.contains($0) })
            return LiveTVRecentHistory.pruning(records, providerID: providerID, validChannelIDs: validIDs)
        }.value
        guard records == recentlyWatchedRecords, updated != recentlyWatchedRecords else { return }
        recentlyWatchedRecords = updated
        recentHistoryStore.save(updated)
    }

    private func pruneRecentHistory(providerID: UUID, store: LiveTVChannelCatalogStore) async {
        let records = recentlyWatchedRecords
        let wanted = records.filter { $0.providerID == providerID }.map(\.channelID)
        let valid = Set(await store.channels(providerID: providerID, ids: wanted,
                                             limit: LiveTVRecentHistory.capacity).map(\.id))
        let updated = LiveTVRecentHistory.pruning(records, providerID: providerID, validChannelIDs: valid)
        guard records == recentlyWatchedRecords, updated != recentlyWatchedRecords else { return }
        recentlyWatchedRecords = updated
        recentHistoryStore.save(updated)
    }
    #else
    private func pruneRecentHistory(for providerID: UUID, validChannels: [LiveTVChannel]) {
        let validIDs = Set(validChannels.map(\.id))
        let updated = LiveTVRecentHistory.pruning(recentlyWatchedRecords, providerID: providerID,
                                                  validChannelIDs: validIDs)
        guard updated != recentlyWatchedRecords else { return }
        recentlyWatchedRecords = updated
        recentHistoryStore.save(updated)
    }
    #endif

    /// Rebuild only when the active provider's catalog, favorites, or recents change. The scan
    /// runs off-main, retains only the bounded Home selections, and rejects stale generations.
    /// Same-provider rebuilds leave the current rails on screen until the replacement lands; a
    /// provider change or a missing catalog clears them at once.
    private func scheduleHomePreviewRebuild() {
        homePreviewGeneration &+= 1
        let generation = homePreviewGeneration
        homePreviewTask?.cancel()
        homePreviewWork?.cancel()
        guard let providerID = selectedProviderID, hasCatalog(for: providerID) else {
            publishHomePreview(.empty, providerID: nil)
            return
        }
        if homePreviewProviderID != providerID { publishHomePreview(.empty, providerID: nil) }
        let favoriteIDs = favoriteChannelIDs
        let records = recentlyWatchedRecords
        let fallbackCatalog = channelCatalogs[providerID]
        let work = Task { [weak self] () -> LiveTVHomeChannelPreview.Result in
            guard let self else { return .empty }
            #if os(iOS)
            if self.channelStoreFreshProviderIDs.contains(providerID), let store = await self.channelStore() {
                guard await self.synchronizeFavoritesIfNeeded(providerID: providerID, store: store) else { return .empty }
                let favorites = await store.page(providerID: providerID, favoritesOnly: true, limit: 12)
                let recentIDs = records.filter { $0.providerID == providerID }.map(\.channelID)
                let recents = await store.channels(providerID: providerID, ids: recentIDs, limit: 10)
                return .init(favorites: favorites, recents: recents)
            }
            #endif
            guard let fallbackCatalog else { return .empty }
            return await Task.detached(priority: .utility) {
                LiveTVHomeChannelPreview.resolve(catalog: fallbackCatalog, favoriteIDs: favoriteIDs,
                                                 recentRecords: records, providerID: providerID)
            }.value
        }
        homePreviewWork = work
        homePreviewTask = Task { [weak self] in
            let result = await work.value
            guard !Task.isCancelled, let self,
                  self.homePreviewGeneration == generation,
                  self.selectedProviderID == providerID,
                  self.hasCatalog(for: providerID) else { return }
            self.publishHomePreview(result, providerID: providerID)
        }
    }

    /// Both rails change in one main-actor turn, and unchanged rails are not reassigned, so views
    /// see one consistent update rather than an intermediate half-built state.
    private func publishHomePreview(_ result: LiveTVHomeChannelPreview.Result, providerID: UUID?) {
        homePreviewProviderID = providerID
        if homeFavoriteChannels != result.favorites { homeFavoriteChannels = result.favorites }
        if homeRecentChannels != result.recents { homeRecentChannels = result.recents }
        scheduleUpNextRebuild()
    }

#if DEBUG
    /// Test-only: waits for the Home preview rebuild scheduled most recently, if any.
    func homePreviewRebuildForTesting() async {
        await homePreviewTask?.value
    }
#endif

    /// Resolves only the active provider's bounded Home favorites. SQLite misses are prefetched
    /// inside the detached task, so guide disk reads never block the main actor.
    private func scheduleUpNextRebuild() {
        upNextGeneration &+= 1
        let generation = upNextGeneration
        upNextTask?.cancel()

        guard let providerID = selectedProviderID,
              !isGuideStale,
              let index = guideIndexes[providerID],
              !homeFavoriteChannels.isEmpty else {
            homeUpNext = []
            return
        }

        let favorites = homeFavoriteChannels
        let now = Date()
        let interval = DateInterval(start: now, end: now.addingTimeInterval(7 * 24 * 60 * 60))
        let task = Task.detached(priority: .utility) {
            var candidates: [LiveTVUpNextResolver.Candidate] = []
            candidates.reserveCapacity(favorites.count)
            for channel in favorites {
                guard let key = index.channelKey(guideID: channel.guideID, name: channel.name) else { continue }
                if !index.isResident(channelKey: key) { index.prefetch(channelKeys: [key]) }
                candidates.append(.init(channel: channel, programs: index.programs(channelKey: key, overlapping: interval)))
            }
            return LiveTVUpNextResolver.resolve(candidates: candidates, providerID: providerID, now: now)
        }
        upNextTask = Task { [weak self] in
            let result = await task.value
            guard !Task.isCancelled, let self,
                  self.upNextGeneration == generation,
                  self.selectedProviderID == providerID,
                  !self.isGuideStale else { return }
            self.homeUpNext = result
        }
    }

#if DEBUG
    func upNextRebuildForTesting() async {
        await upNextTask?.value
    }
#endif

    func programPair(for channel: LiveTVChannel, at date: Date = .now) -> LiveTVProgramPair {
        guard let providerID = UUID(uuidString: String(channel.id.prefix(36))) else {
            return LiveTVProgramPair(current: nil, next: nil)
        }
        guard let index = guideIndexes[providerID] else { return LiveTVProgramPair(current: nil, next: nil) }
        if index.isSQLiteBacked {
            _ = guideResidencyRevision
            requestResidencyIfNeeded(index, providerID: providerID, channel: channel)
        }
        guard let key = channelKey(for: channel, in: index) else { return LiveTVProgramPair(current: nil, next: nil) }
        let pair = index.nowNext(channelKey: key, at: date)
        return LiveTVProgramPair(current: pair.current.map(LiveTVProgram.init), next: pair.next.map(LiveTVProgram.init))
    }

    func guideChannelRevision(for channel: LiveTVChannel) -> Int {
        guideChannelRevisions[channel.id] ?? 0
    }

    /// True while a known SQLite channel is waiting for, or undergoing, its background load.
    /// This distinguishes a transient empty resident-window lookup from a genuinely empty guide.
    func isGuideChannelLoading(_ channel: LiveTVChannel) -> Bool {
        _ = guideResidencyRevision
        guard let providerID = UUID(uuidString: String(channel.id.prefix(36))),
              let index = guideIndexes[providerID], index.isSQLiteBacked,
              let key = channelKey(for: channel, in: index),
              !index.isResident(channelKey: key) else { return false }
        return !residencyFailed.contains(key) &&
            (residencyPending.contains(key) || residencyInFlight.contains(key))
    }

    /// True when this channel's guide row will not change until the guide itself does: its
    /// listings are loaded, it has no listings, or it has no guide at all. False while they could
    /// still arrive (queued, loading, or not yet asked for). Guide rows cache only settled values,
    /// so a row built before its listings loaded asks again on its next build (Build 61).
    func isGuideChannelSettled(_ channel: LiveTVChannel) -> Bool {
        guard let providerID = UUID(uuidString: String(channel.id.prefix(36))),
              let index = guideIndexes[providerID], index.isSQLiteBacked,
              let key = channelKey(for: channel, in: index) else { return true }
        return index.isResident(channelKey: key) || residencyFailed.contains(key)
    }

    /// Listings for one channel that overlap `interval`, in airing order. Empty when its guide is
    /// missing or no longer usable.
    func guidePrograms(for channel: LiveTVChannel, overlapping interval: DateInterval) -> [EPGProgram] {
        guard !isGuideStale,
              let providerID = UUID(uuidString: String(channel.id.prefix(36))),
              let index = guideIndexes[providerID],
              let key = channelKey(for: channel, in: index) else { return [] }
        if index.isSQLiteBacked, !index.isResident(channelKey: key) {
            queueResidency(index, providerID: providerID, key: key, channelID: channel.id)
        }
        return index.programs(channelKey: key, overlapping: interval)
    }

    // MARK: SQLite-backed guide residency
    //
    // A SQLite guide answers lookups from a bounded in-memory window and never reads disk on the
    // main actor. A channel outside the window reads as empty, is queued here, loaded on a background
    // task, and its row is then invalidated (the same targeted invalidation short guides use).

    /// The channel's key in `index`, memoized until the next guide publication.
    private func channelKey(for channel: LiveTVChannel, in index: EPGIndex) -> String? {
        if let memo = channelKeyMemo[channel.id], memo.guideID == channel.guideID, memo.name == channel.name {
            return memo.key
        }
        let key = index.channelKey(guideID: channel.guideID, name: channel.name)
        if channelKeyMemo.count >= LiveTVCatalogLimits.maximumChannels { channelKeyMemo.removeAll(keepingCapacity: true) }
        channelKeyMemo[channel.id] = LiveTVChannelKeyMemo(guideID: channel.guideID, name: channel.name, key: key)
        return key
    }

    private func requestResidencyIfNeeded(_ index: EPGIndex, providerID: UUID, channel: LiveTVChannel) {
        guard let key = channelKey(for: channel, in: index),
              !index.isResident(channelKey: key) else { return }
        queueResidency(index, providerID: providerID, key: key, channelID: channel.id)
    }

    private func queueResidency(_ index: EPGIndex, providerID: UUID, key: String, channelID: String) {
        guard let guideID = index.sqlite?.guide.id else { return }
        if residencyGuideID != guideID {
            residencyGuideID = guideID
            residencyFailed.removeAll()
            residencyPending.removeAll()
            residencyInFlight.removeAll()
        }
        guard !residencyFailed.contains(key) else { return }
        residencyProviderID = providerID
        // A full queue drops its oldest request, a row the viewer has most likely scrolled past.
        // That row is not marked failed, so it asks again when it is next built.
        residencyPending.request(key, channelID: channelID)
        guard residencyTask == nil else { return }
        residencyTask = Task { [weak self] in await self?.drainResidency() }
    }

    private func drainResidency() async {
        while !Task.isCancelled, !residencyPending.isEmpty {
            guard let providerID = residencyProviderID, let index = guideIndexes[providerID],
                  let guideID = index.sqlite?.guide.id, guideID == residencyGuideID else {
                residencyPending.removeAll()
                break
            }
            // Newest first: the rows on screen when a fling stops load before the ones it passed.
            let batch = residencyPending.takeNewest(Self.residencyBatch)
            residencyInFlight.formUnion(batch.map(\.key))
            let keys = batch.map(\.key)
            let prefetchID = UUID()
            let prefetchStartedAt = ProcessInfo.processInfo.systemUptime
            LiveTVStartupTrace.recordEPG("prefetch_started", operationID: prefetchID,
                                         startedAt: prefetchStartedAt, count: keys.count,
                                         backend: "sqlite")
#if DEBUG
            if let residencyPrefetchHookForTesting {
                await residencyPrefetchHookForTesting(index, keys)
            } else {
                await Task.detached(priority: .userInitiated) { index.prefetch(channelKeys: keys) }.value
            }
#else
            await Task.detached(priority: .userInitiated) { index.prefetch(channelKeys: keys) }.value
#endif
            LiveTVStartupTrace.recordEPG("prefetch_finished", operationID: prefetchID,
                                         startedAt: prefetchStartedAt, count: keys.count,
                                         backend: "sqlite")
            residencyInFlight.subtract(keys)
            guard !Task.isCancelled else {
                residencyPending.removeAll()
                residencyInFlight.removeAll()
                residencyTask = nil
                return
            }
            guard residencyProviderID == providerID, residencyGuideID == guideID,
                  guideIndexes[providerID]?.sqlite?.guide.id == guideID else { continue }
            for (key, channelIDs) in batch {
                if index.isResident(channelKey: key) {
                    for id in channelIDs { guideChannelRevisions[id, default: 0] &+= 1 }
                } else {
                    residencyFailed.insert(key)
                }
            }
            guideResidencyRevision &+= 1
            if selectedProviderID == providerID { scheduleUpNextRebuild() }
        }
        residencyTask = nil
    }

    /// Loads the first screenful of channels so a restored or refreshed SQLite guide paints complete.
    private func warmGuideWindow(_ providerID: UUID) {
        guard let index = guideIndexes[providerID], index.isSQLiteBacked else { return }
        #if os(iOS)
        Task { [weak self] in
            guard let self else { return }
            let channels = await self.channelPage(providerID: providerID, limit: Self.warmGuideChannels)
            guard self.guideIndexes[providerID]?.sqlite?.guide.id == index.sqlite?.guide.id else { return }
            for channel in channels { self.requestResidencyIfNeeded(index, providerID: providerID, channel: channel) }
        }
        #else
        for channel in (channelCatalogs[providerID] ?? []).prefix(Self.warmGuideChannels) {
            requestResidencyIfNeeded(index, providerID: providerID, channel: channel)
        }
        #endif
    }

#if DEBUG
    /// Narrow test seam: installs a guide into the service and leaves its real residency request,
    /// batching, de-duplication, revision and stale-result logic untouched.
    func installGuideForResidencyTesting(_ index: EPGIndex, providerID: UUID, channels: [LiveTVChannel],
                                         selectProvider: Bool = true) {
        if !providers.contains(where: { $0.id == providerID }) {
            providers.append(LiveTVProvider(id: providerID, name: "Residency test", channelCount: channels.count,
                                            lastRefreshed: nil, kind: .m3u))
        }
        if selectProvider { selectedProviderID = providerID; scheduleHomePreviewRebuild() }
        channelCatalogs[providerID] = channels
        setGuideIndex(index, for: providerID)
        isGuideStale = false
        residencyFailed.removeAll()
    }

    func waitForResidencyForTesting() async {
        while let task = residencyTask { await task.value }
    }

    var pendingResidencyCountForTesting: Int { residencyPending.count }
#endif

    private func fetch(_ address: String, maximumBytes: Int) async throws -> Data {
        guard let url = URL(string: address), Self.isWebURL(address) else {
            throw LiveTVError.invalidConfiguration
        }
        return try await fetch(url, maximumBytes: maximumBytes)
    }

    private func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
            throw LiveTVError.invalidConfiguration
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/x-mpegURL, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LiveTVError.providerRejected
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LiveTVError.providerRejected
        }
        if http.expectedContentLength > Int64(maximumBytes) || data.count > maximumBytes {
            throw LiveTVError.responseTooLarge
        }
        return data
    }

    private func persistProviders() {
        guard let data = try? JSONEncoder().encode(providers) else { return }
        defaults.set(data, forKey: Self.providersKey)
    }

    private func snapshotSecrets(providerID: UUID) -> LiveTVSnapshotSecrets {
        guard let source = loadSourceConfiguration(providerID: providerID) else { return LiveTVSnapshotSecrets() }
        return LiveTVSnapshotSecrets(source: source)
    }

    /// Phone-to-TV pairing: a saved provider as a transfer payload, read from the keychain-backed
    /// secret store. The caller seals it before it leaves the process and never logs it.
    func pairingPayload(for providerID: UUID) -> LiveTVPairingPayload? {
        guard let provider = providers.first(where: { $0.id == providerID }),
              let source = loadSourceConfiguration(providerID: providerID) else { return nil }
        return LiveTVPairingPayload(
            name: provider.name, kind: source.kind == .xtream ? .xtream : .m3u,
            playlistURL: source.playlistURL, xmltvURL: source.xmltvURL,
            serverURL: source.serverURL, username: source.username, password: source.password)
    }

    private func loadSourceConfiguration(providerID: UUID) -> LiveTVSourceConfiguration? {
        guard let serialized = secretStore.read(account: Self.secretAccount(providerID)),
              let data = serialized.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LiveTVSourceConfiguration.self, from: data)
    }

    private static func epgFeedSource(_ source: LiveTVSourceConfiguration) -> EPGFeedSource? {
        switch source.kind {
        case .m3u:
            return source.xmltvURL.flatMap(webURL).map(EPGFeedSource.xmltv)
        case .xtream:
            guard let server = source.serverURL, let username = source.username, let password = source.password else { return nil }
            return .xtream(server: server, username: username, password: password)
        }
    }

    /// Whether the provider shows a full guide, not just Xtream short-guide listings.
    private func showsFullGuide(_ providerID: UUID) -> Bool {
        guideIndexes[providerID].map { !$0.isShortGuideOnly } ?? false
    }

    /// The provider's current guide generation; see `guideGenerations`.
    func guideGeneration(for providerID: UUID) -> Int { guideGenerations.generation(for: providerID) }

    /// The provider's published guide index, for read-only consumers such as program search.
    func guideIndex(for providerID: UUID) -> EPGIndex? { guideIndexes[providerID] }

    /// The only writer of `guideIndexes`, so no install, replacement or removal can skip
    /// `guideGenerations`. Clearing a provider that has no guide changes nothing.
    private func setGuideIndex(_ index: EPGIndex?, for providerID: UUID) {
        guard index != nil || guideIndexes[providerID] != nil else { return }
        channelKeyMemo.removeAll(keepingCapacity: true)
        guideIndexes[providerID] = index
        guideGenerations.advance(providerID)
        KyroPerformanceDiagnostics.event("Guide publish", .guidePublication)
    }

    private func invalidateAllGuideRows() {
        guideRevision &+= 1
        guideChannelRevisions.removeAll(keepingCapacity: true)
    }

    private func updateGuideFreshness(for providerID: UUID) {
        guard selectedProviderID == providerID else { return }
        guard let index = guideIndexes[providerID] else {
            isGuideStale = true
            scheduleUpNextRebuild()
            return
        }
        isGuideStale = !epg.policy.freshness(of: index, now: .now).isUsable
        scheduleUpNextRebuild()
    }

    private static func secretAccount(_ id: UUID) -> String { "provider.\(id.uuidString)" }

    nonisolated private static func isWebURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return ["http", "https"].contains(components.scheme?.lowercased() ?? "")
            && components.host != nil
    }

    nonisolated private static func webURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value), ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil else { return nil }
        return components.url
    }
}

@MainActor
protocol LiveTVSecretStore {
    func read(account: String) -> String?
    func save(_ value: String, account: String) -> Bool
    func remove(account: String) -> Bool
}

@MainActor
struct KeychainLiveTVSecretStore: LiveTVSecretStore {
    private let keychain = SharedKeychain(service: KyroAppIdentity.current.liveTVKeychainService)

    func read(account: String) -> String? { keychain.get(account) }
    func save(_ value: String, account: String) -> Bool { keychain.set(value, for: account) }
    func remove(account: String) -> Bool { keychain.delete(account) }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

#if os(iOS)
// MARK: - Sports Hub playback driver

extension LiveTVService: KyroSportsPlaybackDriving {
    /// Whether a Sports Hub event owns the current or pending playback.
    var sportsPlaybackIsActive: Bool {
        sportsPlayback.isBusy || sportsPlayback.context != nil
    }

    var sportsPlaybackState: LiveTVPlaybackState { playerSession.state }
    var sportsPlaybackChannelID: String? { playerSession.activeChannelID }
    var sportsPlaybackFailureIsTerminal: Bool {
        playerSession.state == .failed && playerSession.errorMessage == LiveTVPlaybackFailure.otherVideoActive.message
    }

    func sportsResolve(_ channel: LiveTVChannel) -> LiveTVChannel? {
        guard let providerID = selectedProviderID,
              LiveTVRecentChannel.belongs(channel.id, to: providerID), canPlay(channel) else { return nil }
        return channel
    }

    /// Picture in Picture is bound by the player once it is on screen, never here, so a stream
    /// still being tested can never end up in an automatic Picture in Picture window.
    func sportsStartPlayback(_ channel: LiveTVChannel) {
        playerSession.play(channel, startupTrace: LiveTVStartupTrace(
            channelID: channel.id, backend: activeEPGStorageMode == .sqlite ? "sqlite" : "memory"))
    }

    /// Build 46: the verified stream plays in Sports Hub's inline player. Expanding it presents
    /// the full-screen player over the shell, so no Live TV tab is selected first.
    func sportsPresentPlayer(_ channel: LiveTVChannel) {
        errorMessage = nil
        Task { await refreshShortEPG(for: channel) }
        if !presentation.showInline(channel) {
            // Only reachable if a cover or Picture in Picture took over between the attempt and
            // its success; the stream then opens full screen as before.
            _ = presentation.select(channel, from: .shell)
        }
    }

    /// The inline player's Stop. The event context ends with it.
    func stopSportsInlinePlayback() {
        presentation.closeInline()
    }

    func sportsRetunePresentedPlayer(_ channel: LiveTVChannel) -> Bool {
        playFromPlayerPicker(channel)
    }

    func sportsStopPlayback() {
        endPlayback()
    }
}

// MARK: - Sports Hub Live Now source

extension LiveTVService: KyroSportsLiveNowSource {
    var liveNowAvailability: KyroSportsLiveNowAvailability {
        guard let providerID = selectedProviderID, providers.contains(where: { $0.id == providerID }) else {
            return .noProvider
        }
        // The restored SQLite generation or this session's download (Sports Hub prewarm runs the
        // due-only refresh). Live Now itself never starts one.
        guard hasSportsMatchableCatalog(providerID) else {
            return isLoading || playlistRefresh != nil || isPrewarmingSports ? .catalogLoading : .catalogUnavailable
        }
        return .ready(KyroSportsLiveNowRevision(providerID: providerID, catalogRevision: channelCatalogRevision,
                                                guideGeneration: guideGenerations.generation(for: providerID)))
    }

    /// The same local matcher as a tap, against the cached channel index and guide-key map, at
    /// utility priority. No playlist wait, no download, no playback.
    func liveNowMatches(for game: KyroSportsGame, now: Date) async -> KyroSportsStreamMatchResult? {
        let started = KyroPerformanceClock.now()
        defer { KyroPerformanceDiagnostics.record(.sportsEventMatch, milliseconds: (KyroPerformanceClock.now() - started) * 1000) }
        guard case .ready(let revision) = liveNowAvailability,
              let index = await sportsChannelIndex(for: revision.providerID, game: game), !Task.isCancelled,
              index.catalogRevision == revision.catalogRevision else { return nil }
        let guide = guideIndexes[revision.providerID]
        let keys = await guide.asyncFlatMap { await self.sportsGuideKeys(index: index, guide: $0, providerID: revision.providerID) }
        guard !Task.isCancelled, guide == nil || keys != nil else { return nil }
        let request = KyroSportsStreamMatchRequest(game: game, now: now)
        let work = Task.detached(priority: .utility) {
            KyroSportsStreamMatcher.match(request: request, index: index, guide: guide, guideKeys: keys)
        }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        return Task.isCancelled || result.indexWasCancelled ? nil : result
    }
}

private extension Optional {
    func asyncFlatMap<U>(_ transform: (Wrapped) async -> U?) async -> U? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}
#endif
