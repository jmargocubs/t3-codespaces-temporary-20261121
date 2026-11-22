import Foundation
import KyroFoundation
import XCTest

@MainActor final class StorageBoundaryTests: XCTestCase {
  func testConcurrentClockTicksAreUniqueAndOrdered() async throws {
    let clock = HybridClock(device: .init(), now: { 100 })
    let values = try await withThrowingTaskGroup(of: HybridLogicalClock.self) { group in
      for _ in 0..<100 { group.addTask { try await clock.tick() } }
      var values: [HybridLogicalClock] = []
      for try await value in group { values.append(value) }
      return values.sorted()
    }
    XCTAssertEqual(Set(values).count, 100)
    XCTAssertEqual(values.first?.logical, 0)
    XCTAssertEqual(values.last?.logical, 99)
  }
  func testPreCancelledTransactionCannotWrite() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let db = try SQLiteDatabase(path: folder.appendingPathComponent("core.sqlite"))
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await db.transaction { try $0.execute("CREATE TABLE should_not_exist(value INTEGER)") }
    }
    do {
      try await task.value
      XCTFail("Canceled write")
    } catch is CancellationError {}
    let count = try await db.scalarInt(
      "SELECT count(*) FROM sqlite_master WHERE name='should_not_exist'")
    XCTAssertEqual(count, 0)
    try await db.close()
  }
}
