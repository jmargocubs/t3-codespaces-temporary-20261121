#if os(iOS)
import Foundation
import Observation

/// Browsing state for one provider's Movies or Series catalog under the shared Movies/Series page.
///
/// One instance per provider and kind lives for the process, so leaving the tab, switching to Silo
/// and back, or rebuilding the page keeps the selected page tab, search, category, loaded grid
/// pages and shelves. Build 99 kept this state in the page view, so every source switch rebuilt
/// it from SQLite and reset scroll.
@MainActor
@Observable
final class KyroIPTVBrowseModel {
    struct Shelf: Identifiable, Equatable {
        let id: String
        let title: String
        let items: [XtreamVODItem]
    }

    let providerID: UUID
    let kind: XtreamVODKind

    var tab: LibraryPageTab = .recommended
    var query = ""
    var category: String?

    private(set) var shelves: [Shelf] = []
    private(set) var continueWatching: [XtreamVODItem] = []
    private(set) var categories: [XtreamVODCategorySummary] = []
    private(set) var totalCount = 0
    private(set) var hasLoadedOverview = false

    private(set) var gridItems: [XtreamVODItem] = []
    private(set) var gridHasMore = true
    private(set) var gridIsLoading = false
    private(set) var gridHasLoaded = false

    @ObservationIgnored private var overviewRevision: Int?
    @ObservationIgnored private var personalRevision: Int?
    @ObservationIgnored private var gridKey: String?
    @ObservationIgnored private var gridGeneration = 0
    @ObservationIgnored private let service: XtreamVODService

    private static var instances: [String: KyroIPTVBrowseModel] = [:]

    static func model(providerID: UUID, kind: XtreamVODKind) -> KyroIPTVBrowseModel {
        let key = "\(providerID.uuidString):\(kind.rawValue)"
        if let existing = instances[key] { return existing }
        let created = KyroIPTVBrowseModel(providerID: providerID, kind: kind)
        instances[key] = created
        return created
    }

    init(providerID: UUID, kind: XtreamVODKind, service: XtreamVODService? = nil) {
        self.providerID = providerID
        self.kind = kind
        self.service = service ?? .shared
    }

    /// The grid's query and category, as the identity its pages belong to.
    var gridIdentity: String { "\(category ?? "")\u{1F}\(query.trimmingCharacters(in: .whitespacesAndNewlines))" }

    var hasCatalog: Bool { totalCount > 0 }

    /// Loads counts, categories and shelves once per promoted catalog, and Continue Watching once
    /// per watch-state change. Cheap to call on every appearance.
    func refreshOverviewIfNeeded() async {
        let catalog = service.catalogRevision
        if overviewRevision != catalog {
            overviewRevision = catalog
            let started = KyroPerformanceClock.now()
            defer { KyroPerformanceDiagnostics.record(.iptvOverview, milliseconds: (KyroPerformanceClock.now() - started) * 1000) }
            let count = await service.count(providerID: providerID, kind: kind)
            let summaries = await service.categorySummaries(providerID: providerID, kind: kind)
            var built: [Shelf] = []
            let newest = await service.newest(providerID: providerID, kind: kind, limit: 20)
            if !newest.isEmpty { built.append(.init(id: "newest", title: "Recently Added", items: newest)) }
            for summary in XtreamVODCategorySummary.shelfCategories(summaries) {
                let items = await service.newest(providerID: providerID, kind: kind, category: summary.name, limit: 20)
                if !items.isEmpty { built.append(.init(id: "category:\(summary.name)", title: summary.name, items: items)) }
            }
            guard overviewRevision == catalog else { return }
            totalCount = count
            categories = summaries
            shelves = built
            if let category, !summaries.contains(where: { $0.name == category }) { self.category = nil }
            gridKey = nil
        }
        let personal = service.revision
        if personalRevision != personal {
            personalRevision = personal
            continueWatching = await service.personalItems(providerID: providerID, kind: kind, favorites: false)
        }
        hasLoadedOverview = true
    }

    /// Reloads the grid when its query or category changed, keeping the visible page until the
    /// replacement arrives so the grid never flashes empty.
    func refreshGridIfNeeded() async {
        let key = "\(service.catalogRevision)\u{1F}\(gridIdentity)"
        guard gridKey != key else { return }
        gridKey = key
        gridGeneration &+= 1
        let generation = gridGeneration
        gridIsLoading = true
        let started = KyroPerformanceClock.now()
        let page = await service.page(providerID: providerID, kind: kind, query: query,
                                      category: category, offset: 0)
        KyroPerformanceDiagnostics.record(.iptvGridPage, milliseconds: (KyroPerformanceClock.now() - started) * 1000)
        guard generation == gridGeneration else { return }
        gridItems = page
        gridHasMore = page.count == 100
        gridIsLoading = false
        gridHasLoaded = true
    }

    func loadMoreGrid() async {
        guard gridHasMore, !gridIsLoading else { return }
        let generation = gridGeneration
        gridIsLoading = true
        let page = await service.page(providerID: providerID, kind: kind, query: query,
                                      category: category, offset: gridItems.count)
        guard generation == gridGeneration else { return }
        let known = Set(gridItems.map(\.id))
        gridItems.append(contentsOf: page.filter { !known.contains($0.id) })
        gridHasMore = page.count == 100
        gridIsLoading = false
    }

    /// Collections opens a category in Library, the way a Silo collection narrows a library.
    func showCategory(_ name: String?) {
        category = name
        tab = .library
    }
}
#endif
