import Foundation
import XCTest
import KyroFoundation
import KyroCatalog
import KyroMatching

@MainActor final class CatalogTests: XCTestCase {
    private func database() throws -> SQLiteDatabase {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return try SQLiteDatabase(path: folder.appendingPathComponent("catalog.sqlite"))
    }
    func testThreeHundredTwentyLabeledMatchingPairs() {
        var falseMerges = 0, eligible = 0, recalled = 0, count = 0
        for n in 0..<40 {
            let base = CanonicalMedia(id: "a\(n)", kind: .movie, title: "Film \(n)", year: 1980 + n, externalIDs: ["tmdb": "\(n)"])
            let cases: [(CanonicalMedia, Bool)] = [
                (CanonicalMedia(id: "b\(n)", kind: .movie, title: "Film \(n)", year: 1980 + n, externalIDs: ["tmdb": "\(n)"]), true),
                (CanonicalMedia(id: "c\(n)", kind: .movie, title: "Film \(n) 4K HEVC", externalIDs: ["tmdb": "\(n)"]), true),
                (CanonicalMedia(id: "d\(n)", kind: .movie, title: "Film \(n)", year: 2025 + n, externalIDs: ["tmdb": "remake\(n)"]), false),
                (CanonicalMedia(id: "e\(n)", kind: .movie, title: "Film \(n)", externalIDs: ["tmdb": "conflict\(n)"]), false),
                (CanonicalMedia(id: "f\(n)", kind: .movie, title: "Film \(n)", externalIDs: ["tmdb": "\(n)"], edition: "director"), false),
                (CanonicalMedia(id: "g\(n)", kind: .movie, title: "Film \(n)"), false),
                (CanonicalMedia(id: "h\(n)", kind: .series, title: "Film \(n)", externalIDs: ["tmdb": "\(n)"]), false),
                (CanonicalMedia(id: "i\(n)", kind: .movie, title: "Unrelated \(n)", externalIDs: ["imdb": "tt\(n)"]), false)
            ]
            for (candidate, label) in cases {
                count += 1
                let matched = MediaMatcher.matches(base, candidate)
                if !label && matched { falseMerges += 1 }
                if label { eligible += 1; if matched { recalled += 1 } }
                XCTAssertEqual(matched, label, "Pair \(n): \(candidate.id)")
            }
        }
        XCTAssertGreaterThanOrEqual(count, 300)
        XCTAssertEqual(falseMerges, 0)
        XCTAssertGreaterThanOrEqual(Double(recalled) / Double(eligible), 0.95)
        print("Matching: \(count) labeled synthetic pairs; false merges \(falseMerges); eligible recall \(recalled)/\(eligible)")
        XCTAssertEqual(MediaMatcher.normalizedTitle("Film 4K HEVC"), MediaMatcher.normalizedTitle("Film"))
        let a = CanonicalMedia(id: "a", kind: .movie, title: "A", externalIDs: ["tmdb": "1", "imdb": "tt1"])
        let b = CanonicalMedia(id: "b", kind: .movie, title: "A", externalIDs: ["tmdb": "1", "imdb": "tt2"])
        XCTAssertFalse(MediaMatcher.matches(a, b))
    }
    func testFiftyThousandTitleForwardAndReversePagination() async throws {
        let start = Date()
        let db = try database(), partition = SourcePartition(account: .init(), library: "movies")
        let catalog = try await CatalogStore.open(database: db)
        let generation = try await catalog.begin(partition: partition)
        for batch in 0..<100 {
            let items = (0..<500).map { offset in
                let n = batch * 500 + offset
                return CanonicalMedia(id: String(format: "id%05d", n), kind: .movie, title: String(format: "Title %05d", n / 2))
            }
            try await catalog.append(items, to: generation)
        }
        try await catalog.promote(generation, expectedCount: 50_000)
        var forward: [String] = [], reverse: [String] = []
        var cursor: CatalogCursor?
        repeat {
            let page = try await catalog.page(partition: partition, after: cursor, limit: 1_000)
            forward.append(contentsOf: page.items.map(\.id)); cursor = page.cursor
        } while cursor != nil
        cursor = nil
        repeat {
            let page = try await catalog.page(partition: partition, after: cursor, reverse: true, limit: 1_000)
            reverse.append(contentsOf: page.items.map(\.id)); cursor = page.cursor
        } while cursor != nil
        XCTAssertEqual(forward.count, 50_000)
        XCTAssertEqual(Set(forward).count, 50_000)
        XCTAssertEqual(reverse, forward.reversed())
        let matches = try await catalog.search("Title 00001", partition: partition)
        XCTAssertEqual(matches.count, 2)
        print("50,000-title import plus forward/reverse pagination: \(Date().timeIntervalSince(start)) seconds")
        try await db.close()
    }
    func testFailedAndCancelledGenerationsNeverPublish() async throws {
        let db = try database(), partition = SourcePartition(account: .init(), library: "movies")
        let catalog = try await CatalogStore.open(database: db)
        let first = try await catalog.begin(partition: partition)
        let original = CanonicalMedia(id: "original", kind: .movie, title: "Original")
        try await catalog.append([original], to: first)
        try await catalog.promote(first, expectedCount: 1)
        let failed = try await catalog.begin(partition: partition)
        do { try await catalog.append([original, original], to: failed); XCTFail("Duplicate import") } catch {}
        do { try await catalog.promote(failed, expectedCount: 2); XCTFail("Partial generation") } catch {}
        let canceled = try await catalog.begin(partition: partition)
        try await catalog.append([CanonicalMedia(id: "new", kind: .movie, title: "New")], to: canceled)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await catalog.promote(canceled, expectedCount: 1)
        }
        do { try await task.value; XCTFail("Canceled promotion") } catch is CancellationError {}
        let page = try await catalog.page(partition: partition)
        XCTAssertEqual(page.items.map(\.id), ["original"])
        try await catalog.abort(failed); try await catalog.abort(canceled)
        let other = SourcePartition(account: .init(), library: "movies")
        let isolated = try await catalog.page(partition: other)
        XCTAssertTrue(isolated.items.isEmpty)
        try await db.close()
    }
    func testPortableKeysAliasesOverridesAndMetadataRoundtrip() async throws {
        XCTAssertEqual(CanonicalKey.external(kind: .movie, namespace: "IMDB", value: "tt123"), "kyro:v1:movie:imdb:tt123")
        XCTAssertNotEqual(CanonicalKey.external(kind: .movie, namespace: "imdb", value: "tt123"), CanonicalKey.external(kind: .movie, namespace: "imdb", value: "tt123", edition: "director"))
        let db = try database(), catalog = try await CatalogStore.open(database: db)
        try await catalog.setAlias("old", canonical: "new")
        try await catalog.setAlias("older", canonical: "old")
        let resolved = try await catalog.resolveAlias("older")
        XCTAssertEqual(resolved, "new")
        do { try await catalog.setAlias("new", canonical: "older"); XCTFail("Alias cycle") } catch {}
        try await catalog.setOverride(.separate, lhs: "a", rhs: "b")
        let override = try await catalog.matchingOverride(lhs: "b", rhs: "a")
        XCTAssertEqual(override, .separate)
        let media = CanonicalMedia(id: "episode", kind: .episode, title: "Pilot", parentID: "series", season: 1, episode: 1, provenance: ["title": MetadataProvenance(provider: "synthetic", sourceItemID: "one", importedAt: Date(timeIntervalSince1970: 1))], versions: [MediaVersion(sourceItemID: "one", edition: "broadcast", container: "mkv")])
        XCTAssertEqual(try JSONDecoder().decode(CanonicalMedia.self, from: JSONEncoder().encode(media)), media)
        try await db.close()
    }
}
