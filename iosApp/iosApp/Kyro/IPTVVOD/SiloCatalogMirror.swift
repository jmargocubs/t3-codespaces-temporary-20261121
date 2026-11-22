#if os(iOS) || KYRO_VOD_HOST_TESTS
import Foundation
import CryptoKit

/// Versioned, account-bound mirror namespace. A missing verified account fails closed; the
/// previous server/profile-only hashes can never alias this format after a restart.
enum UnifiedSiloScope {
    static func make(serverID: String, serverURL: String, accountID: String?, profileID: String?) -> String? {
        guard let accountID, !accountID.isEmpty, !serverID.isEmpty, !serverURL.isEmpty else { return nil }
        let fields = ["v2", serverID, serverURL, accountID, profileID ?? ""]
        let raw = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// One page of a Silo library walk, already reduced to index records. `scope` is the identity
/// the page was read for; a page for any other scope ends the sync without publishing it.
struct UnifiedSiloSyncPage<Cursor> {
    let records: [UnifiedSiloRecord]
    let next: Cursor?
    /// The server rejected the previous cursor and this is a fresh first page.
    let startsOver: Bool
    let scope: String
}

enum UnifiedSiloSyncOutcome: Equatable, Sendable {
    case synced(count: Int)
    case skippedFresh
    case failed
    case cancelled
    case identityChanged
}

/// Walks one Silo library into a private snapshot and publishes it only when the walk finished
/// for the same identity. The previous snapshot stays visible throughout and is replaced in one
/// transaction; any failure, cancellation or identity change discards the partial snapshot.
enum UnifiedSiloSyncEngine {
    /// A cursor rejected this many times in one sync fails it instead of looping.
    static let maximumRestarts = 2
    /// 4,000 pages of 60 bound one library at 240K titles.
    static let maximumPages = 4_000

    static func sync<Cursor>(
        store: XtreamVODCatalogStore, scope: String, libraryID: Int, kind: XtreamVODKind,
        freshness: TimeInterval?, now: @Sendable () -> Date = { Date() },
        isCurrent: @Sendable () async -> Bool,
        first: @Sendable () async throws -> UnifiedSiloSyncPage<Cursor>,
        next: @Sendable (Cursor) async throws -> UnifiedSiloSyncPage<Cursor>
    ) async -> UnifiedSiloSyncOutcome {
        if let freshness, let synced = await store.siloSyncedAt(scope: scope, libraryID: libraryID, kind: kind),
           now().timeIntervalSince(synced) < freshness {
            return .skippedFresh
        }
        var snapshot = UUID().uuidString
        var seen = Set<String>()
        var restarts = 0
        var pages = 0
        func discard() async {
            await store.discardSilo(scope: scope, libraryID: libraryID, kind: kind, snapshot: snapshot)
        }
        do {
            var page = try await first()
            while true {
                if Task.isCancelled { await discard(); return .cancelled }
                guard page.scope == scope, await isCurrent() else { await discard(); return .identityChanged }
                if page.startsOver {
                    // Restart into a new snapshot: rows read before the rejection may describe a
                    // list that no longer exists, so none of them is reused.
                    await discard()
                    restarts += 1
                    guard restarts <= maximumRestarts else { return .failed }
                    snapshot = UUID().uuidString
                    seen.removeAll()
                    pages = 0
                }
                let fresh = page.records.filter { seen.insert($0.contentID).inserted }
                try await store.stageSilo(fresh, scope: scope, libraryID: libraryID, kind: kind, snapshot: snapshot)
                pages += 1
                guard let cursor = page.next else { break }
                guard pages < maximumPages else { await discard(); return .failed }
                page = try await next(cursor)
            }
            if Task.isCancelled { await discard(); return .cancelled }
            guard await isCurrent() else { await discard(); return .identityChanged }
            try await store.promoteSilo(scope: scope, libraryID: libraryID, kind: kind, snapshot: snapshot,
                                        itemCount: seen.count, syncedAt: now())
            return .synced(count: seen.count)
        } catch {
            await discard()
            return error is CancellationError ? .cancelled : .failed
        }
    }
}
#endif

#if os(iOS)
import Observation

/// The iOS side of the Silo mirror: identity scope, the Silo API adapter, and invalidation on
/// every profile, account or server boundary (`AuthService.resetIdentityScopedStores`).
@MainActor
@Observable
final class SiloCatalogMirror {
    static let shared = SiloCatalogMirror()

    /// Bumps when mirrored rows were published or purged, so browse grids re-read.
    private(set) var revision = 0
    /// Libraries (by "kind:id") currently walking, for the grid's sync status.
    private(set) var syncingLibraries: Set<String> = []

    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var running: [String: Task<UnifiedSiloSyncOutcome, Never>] = [:]

    /// A completed library is re-walked at most this often unless the user pulls to refresh.
    nonisolated static let freshness: TimeInterval = 6 * 60 * 60
    /// The page size Silo's own browse grid already uses (`StartupContentPrefetcher`); the
    /// server's catalog maximum is not part of the client contract, so the mirror does not exceed it.
    nonisolated static let pageSize = 60

    /// Only a verified durable account can expose its Silo mirror. Temporary or legacy
    /// unverified credentials have no stable account namespace and therefore fail closed.
    func currentScope() async -> String? {
        guard let owner = await TokenStore.shared.captureDurableAccountAuth() else { return nil }
        return Self.scope(for: owner)
    }

    nonisolated private static func scope(for owner: CapturedDurableAccountAuth) -> String? {
        UnifiedSiloScope.make(serverID: owner.request.account.serverId,
                              serverURL: owner.request.account.serverURL,
                              accountID: owner.accountID, profileID: owner.request.profileId)
    }

    /// Called on every identity boundary. In-flight walks can no longer publish (their epoch is
    /// stale) and every mirrored row is deleted.
    func invalidateIdentity() {
        epoch &+= 1
        running.values.forEach { $0.cancel() }
        running.removeAll()
        syncingLibraries.removeAll()
        Task {
            if let store = await XtreamVODService.shared.unifiedStore() {
                try? await store.purgeSilo(keepingScope: nil)
            }
            self.revision &+= 1
        }
    }

    /// Walks each library that is stale (or every library when `force`), one at a time. Returns
    /// whether any library failed. Joining an in-flight walk never starts a second one.
    func sync(kind: XtreamVODKind, libraries: [Library], force: Bool) async -> Bool {
        guard let owner = await TokenStore.shared.captureDurableAccountAuth(),
              let scope = Self.scope(for: owner),
              let store = await XtreamVODService.shared.unifiedStore() else { return !libraries.isEmpty }
        let auth = owner.request
        let startedEpoch = epoch
        var failed = false
        for library in libraries {
            guard !Task.isCancelled, startedEpoch == epoch else { return failed }
            let key = "\(kind.rawValue):\(library.id)"
            let task = running[key] ?? startWalk(key: key, library: library, kind: kind, scope: scope,
                                                 owner: owner, store: store, force: force, epoch: startedEpoch)
            let outcome = await task.value
            switch outcome {
            case .synced: revision &+= 1
            case .failed: failed = true
            case .skippedFresh, .cancelled, .identityChanged: break
            }
        }
        return failed
    }

    private func startWalk(key: String, library: Library, kind: XtreamVODKind, scope: String,
                           owner: CapturedDurableAccountAuth, store: XtreamVODCatalogStore,
                           force: Bool, epoch startedEpoch: Int) -> Task<UnifiedSiloSyncOutcome, Never> {
        let auth = owner.request
        let libraryID = library.id
        let mediaScope: LibraryVideoScope? = library.isMixedLibrary ? (kind == .movie ? .movie : .series) : nil
        let isCurrent: @Sendable () async -> Bool = { [weak self] in
            guard await SiloAPI.shared.isCurrentOwner(auth) else { return false }
            guard let current = await TokenStore.shared.captureDurableAccountAuth(),
                  current.accountID == owner.accountID,
                  current.accountEpoch == owner.accountEpoch,
                  current.request.sameCredentialIdentity(as: auth) else { return false }
            return await MainActor.run { self?.epoch == startedEpoch }
        }
        let task = Task<UnifiedSiloSyncOutcome, Never> {
            await UnifiedSiloSyncEngine.sync(
                store: store, scope: scope, libraryID: libraryID, kind: kind,
                freshness: force ? nil : Self.freshness, isCurrent: isCurrent,
                first: {
                    var state = CatalogFilterState.none
                    state.sort = .title
                    state.order = .asc
                    let query = CatalogQueryBuilder.build(state, libraryId: libraryID, mediaType: .movie,
                                                          limit: Self.pageSize, includeType: false,
                                                          enforcedScope: mediaScope)
                    return Self.page(try await SiloAPI.shared.catalogPage(query), kind: kind,
                                     expectedAuth: auth, expectedScope: scope)
                },
                next: { continuation in
                    Self.page(try await SiloAPI.shared.nextCatalogPage(continuation), kind: kind,
                              expectedAuth: auth, expectedScope: scope)
                }
            )
        }
        running[key] = task
        syncingLibraries.insert(key)
        Task {
            _ = await task.value
            // A newer walk for the same key may already have replaced this one.
            if self.running[key] == task {
                self.running[key] = nil
                self.syncingLibraries.remove(key)
            }
        }
        return task
    }

    private nonisolated static func page(_ page: CatalogListPage, kind: XtreamVODKind,
                                         expectedAuth: CapturedOrdinaryRequestAuth,
                                         expectedScope: String) -> UnifiedSiloSyncPage<APIv2CatalogContinuation> {
        let encoder = JSONEncoder()
        let records = page.response.items.compactMap { item -> UnifiedSiloRecord? in
            // A Series grid never shows a movie and vice versa, even from a mixed library.
            guard (item.type == "series") == (kind == .series),
                  let payload = try? encoder.encode(item) else { return nil }
            return UnifiedSiloRecord(contentID: item.contentId, title: item.title, year: item.year,
                                     poster: item.posterUrl, payload: payload)
        }
        return UnifiedSiloSyncPage(records: records, next: page.continuation, startsOver: page.startsOver,
                                   scope: page.auth.sameCredentialIdentity(as: expectedAuth) ? expectedScope : "")
    }
}
#endif
