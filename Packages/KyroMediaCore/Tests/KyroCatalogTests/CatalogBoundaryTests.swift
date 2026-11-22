import Foundation
import KyroCatalog
import KyroFoundation
import XCTest

@MainActor final class CatalogBoundaryTests: XCTestCase {
  func testCursorCannotMixPublishedGenerations() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let db = try SQLiteDatabase(path: folder.appendingPathComponent("catalog.sqlite"))
    let store = try await CatalogStore.open(database: db)
    let partition = SourcePartition(account: .init(), library: "movies")
    let first = try await store.begin(partition: partition)
    try await store.append([CanonicalMedia(id: "old", kind: .movie, title: "Old")], to: first)
    try await store.promote(first, expectedCount: 1)
    let cursor = try await store.page(partition: partition).cursor
    let second = try await store.begin(partition: partition)
    try await store.append([CanonicalMedia(id: "new", kind: .movie, title: "New")], to: second)
    try await store.promote(second, expectedCount: 1)
    do {
      _ = try await store.page(partition: partition, after: cursor)
      XCTFail("Stale cursor accepted")
    } catch CatalogStore.CatalogError.staleCursor {}
    try await db.close()
  }
}
