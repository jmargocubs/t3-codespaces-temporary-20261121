#if os(iOS)
import Foundation
import Observation

/// The unified Movies or Series grid (Build 110): a bounded window over the local unified index
/// (`UnifiedCatalogIndex.swift`), which holds the active IPTV generations of the enabled
/// providers and the last completed Silo snapshot of this profile's visible libraries.
///
/// Ordering is catalog-wide alphabetical (normalized title, then year). Pages are keyset reads,
/// so the window can be trimmed at either end and re-read later without losing, skipping or
/// repeating a title. Browsing never fetches a provider catalog or episodes; the Silo mirror is
/// walked in the background only when stale or on pull to refresh.
@MainActor
@Observable
final class KyroUnifiedBrowseModel {
    private struct Inputs: Equatable {
        let kind: XtreamVODKind
        let libraries: [Library]
        let providerIDs: [UUID]

        var key: String { "\(kind.rawValue):\(libraries.map(\.id)):\(providerIDs)" }
        static func == (lhs: Inputs, rhs: Inputs) -> Bool { lhs.key == rhs.key }
    }

    private(set) var window = UnifiedCatalogWindow()
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var isIndexingIPTV = false
    private(set) var siloSyncFailed = false
    private(set) var storeUnavailable = false
    /// Decoded Silo cards of the current window, keyed by card ID.
    private(set) var siloItems: [String: BrowseItem] = [:]

    var cards: [UnifiedCatalogCard] { window.cards }
    var hasMoreBefore: Bool { window.hasMoreBefore }
    var hasMoreAfter: Bool { window.hasMoreAfter }

    /// The top visible card, reported by the grid's scroll position. Reloads keep it in place.
    @ObservationIgnored var anchorCardID: String?

    @ObservationIgnored private var inputs: Inputs?
    @ObservationIgnored private var scope: UnifiedIndexScope?
    @ObservationIgnored private var store: XtreamVODCatalogStore?
    /// Bumps on every configuration and every window replacement; a read that finishes under an
    /// older token never publishes.
    @ObservationIgnored private var token = 0
    /// Bumps only when the grid is reconfigured, so a superseded configuration stops.
    @ObservationIgnored private var configuration = 0
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private let decoder = JSONDecoder()

    func configure(kind: XtreamVODKind, libraries: [Library], providers: [LiveTVProvider],
                   vodEnabled: Bool) async {
        let providerIDs = vodEnabled ? providers.filter { $0.kind == .xtream }.map(\.id) : []
        let next = Inputs(kind: kind, libraries: libraries, providerIDs: providerIDs)
        guard next != inputs else { return }
        await apply(next)
    }

    private func apply(_ next: Inputs) async {
        let kind = next.kind, libraries = next.libraries, providerIDs = next.providerIDs
        inputs = next
        configuration &+= 1
        token &+= 1
        let current = configuration
        syncTask?.cancel()
        let granularity = window.rowGranularity
        window = UnifiedCatalogWindow()
        window.rowGranularity = granularity
        siloItems = [:]
        hasLoaded = false
        siloSyncFailed = false
        guard let store = await XtreamVODService.shared.unifiedStore() else {
            guard current == configuration else { return }
            storeUnavailable = true
            hasLoaded = true
            return
        }
        let siloScope = await SiloCatalogMirror.shared.currentScope()
        guard current == configuration, !Task.isCancelled else { return abandon(current) }
        storeUnavailable = false
        self.store = store
        // Also purge legacy server/profile-only scopes and unverified-account caches. A nil
        // scope is fail-closed: it cannot reveal any Silo rows, even after a crash/restart.
        try? await store.purgeSilo(keepingScope: siloScope)
        if let siloScope {
            // A library this profile can no longer see is deleted. An empty list is a
            // transient load, not a revocation.
            if !libraries.isEmpty {
                try? await store.retainSiloLibraries(scope: siloScope, kind: kind, libraryIDs: libraries.map(\.id))
            }
        }
        if !providerIDs.isEmpty {
            isIndexingIPTV = true
            _ = try? await store.ensureUnifiedKeys()
            isIndexingIPTV = false
        }
        guard current == configuration, !Task.isCancelled else { return abandon(current) }
        scope = UnifiedIndexScope(kind: kind, siloScope: siloScope, siloLibraryIDs: libraries.map(\.id),
                                  providerIDs: providerIDs)
        await loadFirst()
        guard current == configuration else { return }
        hasLoaded = true
        startSync(force: false)
    }

    /// Pull to refresh: re-walk every Silo library now and show the catalog from the start.
    /// IPTV catalogs keep their own explicit refresh; browsing never downloads one.
    func refresh() async {
        guard hasLoaded else { return }
        if storeUnavailable, let inputs {
            // The local catalog failed to open; pulling retries the whole configuration.
            await apply(inputs)
            return
        }
        await loadFirst()
        startSync(force: true)
    }

    /// The index changed (a Silo snapshot or IPTV generation was published or removed). Rebuild
    /// the window around the top visible card so the grid does not jump.
    func indexDidChange() async {
        guard hasLoaded, let inputs, let scope, let store else { return }
        if await SiloCatalogMirror.shared.currentScope() != scope.siloScope {
            // The identity changed under this grid: start over for the new one.
            await apply(inputs)
            return
        }
        let anchor = anchorCardID.flatMap { id in window.cards.first { $0.id == id } }
        guard let anchor, window.hasMoreBefore || anchor.id != window.cards.first?.id else {
            await loadFirst()
            return
        }
        token &+= 1
        let current = token
        isLoading = true
        let boundary = anchor.groupKey == nil
            ? anchor.firstCursor
            : UnifiedIndexCursor(sortKey: anchor.firstCursor.sortKey, matchKey: anchor.firstCursor.matchKey, entryKey: "")
        let before = await store.unifiedPage(scope, direction: .backward(before: boundary), limit: 50)
        let after = await store.unifiedPage(scope, direction: .forward(after: before.rows.last?.cursor),
                                            limit: UnifiedCatalogWindow.pageSize)
        guard current == token else { return }
        var next = window
        next.replace(with: UnifiedIndexPage(rows: before.rows + after.rows, reachedEdge: after.reachedEdge),
                     hasMoreBefore: !before.reachedEdge)
        publish(next)
        isLoading = false
    }

    func loadMore() async {
        guard hasLoaded, window.hasMoreAfter, !isLoading, let scope, let store else { return }
        let current = token
        isLoading = true
        let page = await store.unifiedPage(scope, direction: .forward(after: window.forwardCursor),
                                           limit: UnifiedCatalogWindow.pageSize)
        guard current == token else { return }
        var next = window
        next.appendForward(page)
        publish(next)
        isLoading = false
    }

    func loadPrevious() async {
        guard hasLoaded, window.hasMoreBefore, !isLoading, let scope, let store,
              let cursor = window.backwardCursor else { return }
        let current = token
        isLoading = true
        let page = await store.unifiedPage(scope, direction: .backward(before: cursor),
                                           limit: UnifiedCatalogWindow.pageSize)
        guard current == token else { return }
        var next = window
        next.prependBackward(page)
        publish(next)
        isLoading = false
    }

    func siloItem(for card: UnifiedCatalogCard) -> BrowseItem? { siloItems[card.id] }

    /// The grid's column count, so window edits keep whole rows (see `rowGranularity`).
    func setColumns(_ columns: Int) {
        guard columns > 0, window.rowGranularity != columns else { return }
        window.rowGranularity = columns
    }

    var isSyncingSilo: Bool {
        guard let kind = inputs?.kind else { return false }
        return SiloCatalogMirror.shared.syncingLibraries.contains { $0.hasPrefix(kind.rawValue + ":") }
    }

    // MARK: Private

    private func loadFirst() async {
        guard let scope, let store else { return }
        token &+= 1
        let current = token
        isLoading = true
        let page = await store.unifiedPage(scope, direction: .forward(after: nil), limit: UnifiedCatalogWindow.pageSize)
        guard current == token else { return }
        var next = UnifiedCatalogWindow()
        next.rowGranularity = window.rowGranularity
        next.replace(with: page, hasMoreBefore: false)
        anchorCardID = nil
        publish(next)
        isLoading = false
    }

    private func publish(_ next: UnifiedCatalogWindow) {
        var decoded: [String: BrowseItem] = [:]
        for card in next.cards {
            guard case let .silo(_, _, payload) = card.primary.source else { continue }
            decoded[card.id] = siloItems[card.id] ?? (try? decoder.decode(BrowseItem.self, from: payload))
        }
        siloItems = decoded
        window = next
    }

    private func startSync(force: Bool) {
        guard let inputs, !inputs.libraries.isEmpty, scope?.siloScope != nil else { return }
        syncTask?.cancel()
        let current = configuration
        syncTask = Task { [weak self] in
            let failed = await SiloCatalogMirror.shared.sync(kind: inputs.kind, libraries: inputs.libraries, force: force)
            guard let self, !Task.isCancelled, self.configuration == current else { return }
            self.siloSyncFailed = failed
        }
    }

    /// A configuration abandoned by cancellation is retried by the next `configure` call.
    private func abandon(_ current: Int) {
        if current == configuration {
            inputs = nil
            isLoading = false
            isIndexingIPTV = false
        }
    }
}
#endif
