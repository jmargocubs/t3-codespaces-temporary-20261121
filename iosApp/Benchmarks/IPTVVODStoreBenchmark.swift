// Compile together with the production XtreamVODModels, Scanner and CatalogStore using
// `swiftc -D KYRO_VOD_HOST_TESTS -lsqlite3 ...` (see docs/kyro-build-98.md).
import Foundation
import Darwin
import SQLite3

// Only the Live TV API dependencies of XtreamVODModels are stubbed. The store under benchmark
// is the production actor, not a reimplementation or a toy SQLite schema.
enum LiveTVError: Error {
    case authenticationFailed, accountExpired, invalidXtreamResponse, invalidConfiguration, responseTooLarge
}
enum XtreamURLBuilder {
    static func apiURL(server: String, username: String, password: String,
                       action: String? = nil) throws -> URL {
        guard let url = URL(string: server) else { throw LiveTVError.invalidConfiguration }
        return url
    }
}

@main
enum IPTVVODStoreBenchmark {
    static func milliseconds(_ start: ContinuousClock.Instant) -> Int {
        Int(start.duration(to: .now).components.seconds * 1_000
            + start.duration(to: .now).components.attoseconds / 1_000_000_000_000_000)
    }

    static func rssMegabytes() -> Int {
        var info = rusage()
        guard getrusage(RUSAGE_SELF, &info) == 0 else { return -1 }
        return Int(info.ru_maxrss) / 1_048_576
    }

    static func checkRecovery(root: URL) async throws {
        let directory = root.appendingPathComponent("recovery")
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        func item(_ provider: UUID, _ id: Int, _ title: String) -> XtreamVODItem {
            .init(providerID: provider, kind: .movie, remoteID: id, title: title,
                  category: "Drama", poster: nil, fileExtension: "mp4", summary: nil,
                  genre: nil, rating: nil)
        }
        let store = try XtreamVODCatalogStore(directory: directory)
        try await store.stage([item(first, 1, "Initial Example"), item(first, 1, "Final Example")], generation: "active")
        try await store.promote(providerID: first, kind: .movie, generation: "active")
        try await store.stage([item(first, 2, "Orphan Example")], generation: "interrupted")
        try await store.stage([item(second, 1, "Second Example")], generation: "active")
        try await store.promote(providerID: second, kind: .movie, generation: "active")
        await store.close()
        let reopened = try XtreamVODCatalogStore(directory: directory)
        try await reopened.pruneOrphanedGenerations()
        let firstMatches = await reopened.page(providerID: first, kind: .movie, query: "fin ex")
        let orphanMatches = await reopened.page(providerID: first, kind: .movie, query: "orphan")
        let secondMatches = await reopened.page(providerID: second, kind: .movie, query: "second")
        precondition(firstMatches.map(\.title) == ["Final Example"])
        precondition(orphanMatches.isEmpty && secondMatches.count == 1)
        let retainedCount = await reopened.count(providerID: first, kind: .movie)
        precondition(retainedCount == 1)
        await reopened.close()
        print("host_recovery,pass")
    }

    static func checkLegacyMigration(root: URL) async throws {
        let directory = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var database: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("catalog.sqlite").path, &database) == SQLITE_OK else {
            throw XtreamVODError.storage
        }
        let provider = "00000000-0000-0000-0000-000000000001"
        let sql = """
            CREATE TABLE vod_items(provider TEXT NOT NULL, kind TEXT NOT NULL, generation TEXT NOT NULL,
              remote_id INTEGER NOT NULL, title TEXT NOT NULL, category TEXT NOT NULL, poster TEXT,
              ext TEXT, summary TEXT, genre TEXT, rating TEXT,
              PRIMARY KEY(provider,kind,generation,remote_id));
            CREATE TABLE vod_active(provider TEXT NOT NULL, kind TEXT NOT NULL, generation TEXT NOT NULL,
              PRIMARY KEY(provider,kind));
            INSERT INTO vod_items(provider,kind,generation,remote_id,title,category)
              VALUES('\(provider)','movie','legacy',9,'Legacy Existing Title','Drama');
            INSERT INTO vod_active VALUES('\(provider)','movie','legacy');
            """
        let created = sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
        sqlite3_close(database)
        precondition(created)
        let store = try XtreamVODCatalogStore(directory: directory)
        let matches = await store.page(providerID: UUID(uuidString: provider)!, kind: .movie, query: "legacy exist")
        precondition(matches.count == 1 && matches[0].remoteID == 9)
        await store.close()
        print("host_legacy_migration,pass")
    }

    static func checkAnchorBoundaries(root: URL) async throws {
        let store = try XtreamVODCatalogStore(directory: root.appendingPathComponent("anchors"))
        let provider = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        for base in stride(from: 0, to: 2_200, by: 1_024) {
            let items = (base..<min(base + 1_024, 2_200)).map { index in
                XtreamVODItem(providerID: provider, kind: .movie, remoteID: index + 1,
                               title: "Same Title", category: "Drama", poster: nil,
                               fileExtension: "mp4", summary: nil, genre: nil, rating: nil)
            }
            try await store.stage(items, generation: "active")
        }
        try await store.buildPageAnchors(providerID: provider, kind: .movie, generation: "active")
        try await store.promote(providerID: provider, kind: .movie, generation: "active")
        let boundary = await store.page(providerID: provider, kind: .movie, offset: 1_023)
        let tail = await store.page(providerID: provider, kind: .movie, offset: 2_100)
        precondition(boundary.map(\.remoteID) == Array(1_024...1_123))
        precondition(tail.map(\.remoteID) == Array(2_101...2_200))
        await store.close()
        print("host_anchor_boundaries,pass")
    }

    static func run(kind: XtreamVODKind, count: Int, root: URL) async throws {
        let directory = root.appendingPathComponent("\(kind.rawValue)-\(count)")
        let store = try XtreamVODCatalogStore(directory: directory)
        let provider = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let other = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let generation = "benchmark"
        let importStart = ContinuousClock.now
        for base in stride(from: 0, to: count, by: 1_024) {
            let batch = (base..<min(base + 1_024, count)).map { index in
                XtreamVODItem(providerID: provider, kind: kind, remoteID: index + 1,
                               title: String(format: "Title %07d Benchmark", index),
                               category: "Category \(index % 40)", poster: nil,
                               fileExtension: "mp4", summary: nil, genre: nil, rating: nil)
            }
            try await store.stage(batch, generation: generation)
        }
        try await store.buildPageAnchors(providerID: provider, kind: kind, generation: generation)
        try await store.promote(providerID: provider, kind: kind, generation: generation)
        let importMS = milliseconds(importStart)
        let searchStart = ContinuousClock.now
        let matches = await store.page(providerID: provider, kind: kind, query: "Title 0001234")
        let searchMS = milliseconds(searchStart)
        let categoryStart = ContinuousClock.now
        let category = await store.page(providerID: provider, kind: kind, category: "Category 17", offset: 200)
        let categoryMS = milliseconds(categoryStart)
        let pageStart = ContinuousClock.now
        let page = await store.page(providerID: provider, kind: kind, offset: 200)
        let pageMS = milliseconds(pageStart)
        let deepPageStart = ContinuousClock.now
        let deepPage = await store.page(providerID: provider, kind: kind, offset: count - 100)
        let deepPageMS = milliseconds(deepPageStart)
        // Build 104: Recommended's overview, the queries `KyroIPTVBrowseModel.refreshOverviewIfNeeded`
        // runs once per promoted catalog: count, category summaries, Recently Added and up to eight
        // category shelves.
        let overviewStart = ContinuousClock.now
        _ = await store.count(providerID: provider, kind: kind)
        let summaries = XtreamVODCategorySummary.ordered(await store.categorySummaries(providerID: provider, kind: kind))
        let summariesMS = milliseconds(overviewStart)
        _ = await store.newest(providerID: provider, kind: kind, limit: 20)
        for summary in XtreamVODCategorySummary.shelfCategories(summaries) {
            _ = await store.newest(providerID: provider, kind: kind, category: summary.name, limit: 20)
        }
        let overviewMS = milliseconds(overviewStart)
        let stored = await store.count(providerID: provider, kind: kind)
        let isolated = await store.count(providerID: other, kind: kind)
        precondition(stored == count && isolated == 0 && page.count == 100
                     && category.count == 100 && deepPage.count == 100)
        if count > 1_234 { precondition(matches.count == 1 && matches[0].remoteID == 1_235) }
        await store.close()
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("catalog.sqlite").path)
        let bytes = (attributes[.size] as? NSNumber)?.intValue ?? -1
        print("\(kind.rawValue),\(count),\(importMS),\(searchMS),\(categoryMS),\(pageMS),\(deepPageMS),\(summariesMS),\(overviewMS),\(bytes),\(rssMegabytes())")
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: iptv-vod-benchmark TEMP_DIRECTORY\n", stderr)
            exit(2)
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try await checkLegacyMigration(root: root)
        try await checkRecovery(root: root)
        try await checkAnchorBoundaries(root: root)
        print("kind,count,import_ms,search_ms,category_ms,page_ms,deep_page_ms,overview_summaries_ms,overview_total_ms,sqlite_bytes,process_peak_rss_mb")
        for count in [100_000, 200_000, 400_000] { try await run(kind: .movie, count: count, root: root) }
        for count in [50_000, 100_000, 200_000] { try await run(kind: .series, count: count, root: root) }
    }
}
