#if os(iOS)
import Foundation
import XCTest
@testable import Silo

@MainActor
final class IPTVVODFoundationTests: XCTestCase {
    func testOptInDefaultsOffAndDoesNotEraseStoredCatalog() async throws {
        let suite = "IPTVVODFoundation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IPTVVODFoundation-\(UUID().uuidString)")
        let store = try XtreamVODCatalogStore(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = UUID()
        let item = XtreamVODItem(providerID: provider, kind: .movie, remoteID: 7,
                                title: "Example", category: "Films", poster: nil,
                                fileExtension: "mp4", summary: nil, genre: nil, rating: nil)
        try await store.stage([item], generation: "one")
        try await store.promote(providerID: provider, kind: .movie, generation: "one")
        let service = XtreamVODService(store: store, defaults: defaults)
        XCTAssertFalse(IPTVVODPreference.isEnabled(in: defaults))
        let disabled = await service.page(providerID: provider, kind: .movie)
        XCTAssertTrue(disabled.isEmpty)
        IPTVVODPreference.setEnabled(true, in: defaults)
        let enabled = await service.page(providerID: provider, kind: .movie)
        XCTAssertEqual(enabled.map(\.id), [item.id])
        IPTVVODPreference.setEnabled(false, in: defaults)
        let hidden = await service.page(providerID: provider, kind: .movie)
        XCTAssertTrue(hidden.isEmpty)
        let retainedCount = await store.count(providerID: provider, kind: .movie)
        XCTAssertEqual(retainedCount, 1)
        await store.close()
    }

    func testSnapshotPromotionAndProviderIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IPTVVODFoundation-\(UUID().uuidString)")
        let store = try XtreamVODCatalogStore(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = UUID(), second = UUID()
        func item(_ provider: UUID, _ remoteID: Int, _ title: String) -> XtreamVODItem {
            .init(providerID: provider, kind: .series, remoteID: remoteID, title: title,
                  category: "Other", poster: nil, fileExtension: nil, summary: nil, genre: nil, rating: nil)
        }
        try await store.stage([item(first, 1, "Old")], generation: "old")
        try await store.promote(providerID: first, kind: .series, generation: "old")
        try await store.stage([item(first, 2, "New")], generation: "new")
        try await store.stage([item(second, 1, "Other provider")], generation: "old")
        try await store.promote(providerID: second, kind: .series, generation: "old")
        let before = await store.page(providerID: first, kind: .series)
        XCTAssertEqual(before.map(\.title), ["Old"])
        await store.discard(providerID: first, kind: .series, generation: "new")
        let retainedCount = await store.count(providerID: first, kind: .series)
        XCTAssertEqual(retainedCount, 1)
        let other = await store.page(providerID: second, kind: .series)
        XCTAssertEqual(other.map(\.title), ["Other provider"])
        await store.close()
    }

    func testIndexedSearchDeduplicationAndCrashRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IPTVVODFoundation-\(UUID().uuidString)")
        let provider = UUID(), other = UUID()
        let store = try XtreamVODCatalogStore(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        func item(_ owner: UUID, _ id: Int, _ title: String) -> XtreamVODItem {
            .init(providerID: owner, kind: .movie, remoteID: id, title: title,
                  category: "Drama", poster: nil, fileExtension: "mp4", summary: nil,
                  genre: nil, rating: nil)
        }
        try await store.stage([item(provider, 1, "First Example"), item(provider, 1, "Final Example")], generation: "active")
        try await store.promote(providerID: provider, kind: .movie, generation: "active")
        try await store.stage([item(provider, 2, "Orphan Example")], generation: "interrupted")
        try await store.stage([item(other, 1, "Other Example")], generation: "active")
        try await store.promote(providerID: other, kind: .movie, generation: "active")
        let before = await store.page(providerID: provider, kind: .movie, query: "fin ex")
        let hidden = await store.page(providerID: provider, kind: .movie, query: "orphan")
        XCTAssertEqual(before.map(\.title), ["Final Example"])
        XCTAssertTrue(hidden.isEmpty)
        await store.close()
        let recovered = try XtreamVODCatalogStore(directory: root)
        try await recovered.pruneOrphanedGenerations()
        let retainedCount = await recovered.count(providerID: provider, kind: .movie)
        let retained = await recovered.page(providerID: provider, kind: .movie, query: "final")
        let removed = await recovered.page(providerID: provider, kind: .movie, query: "orphan")
        let isolated = await recovered.page(providerID: other, kind: .movie, query: "other")
        XCTAssertEqual(retainedCount, 1)
        XCTAssertEqual(retained.map(\.title), ["Final Example"])
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(isolated.count, 1)
        await recovered.close()
    }

    func testPlaybackURLAndNamespacedIDs() throws {
        let provider = UUID()
        let movie = XtreamVODItem(providerID: provider, kind: .movie, remoteID: 42,
                                   title: "Movie", category: "Other", poster: nil,
                                   fileExtension: "mp4", summary: nil, genre: nil, rating: nil)
        let series = XtreamVODItem(providerID: provider, kind: .series, remoteID: 42,
                                    title: "Series", category: "Other", poster: nil,
                                    fileExtension: nil, summary: nil, genre: nil, rating: nil)
        XCTAssertNotEqual(movie.id, series.id)
        let url = try XtreamURLBuilder.vodPlaybackURL(server: "https://vod.example", username: "user",
                                                       password: "test password", kind: .movie,
                                                       itemID: 42, fileExtension: "mp4")
        XCTAssertEqual(url.path, "/movie/user/test password/42.mp4")
        XCTAssertThrowsError(try XtreamURLBuilder.vodPlaybackURL(server: "https://vod.example",
                                                                username: "user", password: "pass",
                                                                kind: .series, itemID: 42,
                                                                fileExtension: "exe"))
        for container in ["mkv", "ts", "avi", "webm"] {
            let compatible = try XtreamURLBuilder.vodPlaybackURL(
                server: "https://vod.example/base", username: "user", password: "pass",
                kind: .series, itemID: 99, fileExtension: container.uppercased()
            )
            XCTAssertEqual(compatible.pathExtension, container)
            XCTAssertTrue(compatible.path.hasPrefix("/base/series/user/"))
        }
        XCTAssertThrowsError(try XtreamURLBuilder.vodPlaybackURL(
            server: "https://vod.example", username: "user", password: "pass",
            kind: .movie, itemID: 42, fileExtension: "mkv/extra"
        ))
    }

    func testStreamingImportCancellationKeepsActiveGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IPTVVODFoundation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try XtreamVODCatalogStore(directory: root)
        let provider = UUID()
        let old = XtreamVODItem(providerID: provider, kind: .movie, remoteID: 1,
                                 title: "Old", category: "Other", poster: nil,
                                 fileExtension: "mp4", summary: nil, genre: nil, rating: nil)
        try await store.stage([old], generation: "active")
        try await store.promote(providerID: provider, kind: .movie, generation: "active")

        let file = root.appendingPathComponent("catalog.json")
        try Data(#"[{"stream_id":2,"name":"New","container_extension":"mp4"}]"#.utf8).write(to: file)
        let limits = XtreamVODCatalogLimits.standard(for: .movie)
        let importer = XtreamVODCatalogImporter(providerID: provider, kind: .movie, generation: "replacement",
                                                categories: [:], secrets: .init(), username: "u",
                                                password: "p", limits: limits)
        let gate = AsyncStream<Void>.makeStream()
        let cancelled = Task.detached {
            for await _ in gate.stream { break }
            try Task.checkCancellation()
            return try await importer.run(file: file, total: 1, store: store, progress: { _ in })
        }
        cancelled.cancel()
        gate.continuation.finish()
        do {
            _ = try await cancelled.value
            XCTFail("The importer should stop before promoting a cancelled generation")
        } catch is CancellationError { }
        let active = await store.page(providerID: provider, kind: .movie)
        XCTAssertEqual(active.map(\.title), ["Old"])
        await store.close()
    }
}
#endif
