import Foundation
import KyroFoundation
import XCTest

@MainActor
final class FoundationTests: XCTestCase {
  private func location() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: folder) }
    return folder.appendingPathComponent("core.sqlite")
  }

  func testConcurrentWritersAndBoundedReaders() async throws {
    let db = try SQLiteDatabase(path: location(), readerCount: 2)
    try await db.execute("CREATE TABLE counter(value INTEGER); INSERT INTO counter VALUES(0)")
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<100 {
        group.addTask {
          try await db.transaction { connection in
            let value = try connection.scalarInt("SELECT value FROM counter")
            try connection.execute("UPDATE counter SET value=\(value + 1)")
          }
          let value = try await db.readInt("SELECT value FROM counter")
          guard (1...100).contains(value) else { throw TestError.invalidCount }
        }
      }
      try await group.waitForAll()
    }
    let final = try await db.readInt("SELECT value FROM counter")
    XCTAssertEqual(final, 100)
    try await db.close()
  }

  func testWALAndIndependentReadVisibility() async throws {
    let url = try location()
    let db = try SQLiteDatabase(path: url)
    let mode = try await db.scalarText("PRAGMA journal_mode")
    XCTAssertEqual(mode, "wal")
    try await db.execute("CREATE TABLE records(value INTEGER)")
    let reader = try SQLiteDatabase(path: url)
    try await db.execute("INSERT INTO records VALUES(7)")
    let visible = try await reader.readInt("SELECT value FROM records")
    XCTAssertEqual(visible, 7)
    try await reader.close()
    try await db.execute("CREATE VIRTUAL TABLE search USING fts5(title)")
    try await db.execute("INSERT INTO search VALUES('Kyro foundation')")
    let matches = try await db.readInt(
      "SELECT count(*) FROM search WHERE search MATCH 'foundation'")
    XCTAssertEqual(matches, 1)
    try await db.close()
  }

  func testMigrationFailureRecoversAtomically() async throws {
    let db = try SQLiteDatabase(path: location())
    do {
      try await db.migrate(version: 1, sql: "CREATE TABLE incomplete(value INTEGER); INVALID SQL")
      XCTFail("Expected migration error")
    } catch {}
    let versions = try await db.scalarInt("SELECT count(*) FROM kyro_migrations")
    let tables = try await db.scalarInt(
      "SELECT count(*) FROM sqlite_master WHERE name='incomplete'")
    XCTAssertEqual(versions, 0)
    XCTAssertEqual(tables, 0)
    try await db.migrate(version: 1, sql: "CREATE TABLE complete(value INTEGER)")
    do {
      try await db.migrate(version: 3, sql: "CREATE TABLE gap(value INTEGER)")
      XCTFail("Version gap")
    } catch {}
    try await db.close()
  }

  func testCancellationRollsBackBeforeCommit() async throws {
    let db = try SQLiteDatabase(path: location())
    try await db.execute("CREATE TABLE records(value INTEGER)")
    let task = Task {
      try await db.transaction { connection in
        try connection.execute("INSERT INTO records VALUES(1)")
        withUnsafeCurrentTask { $0?.cancel() }
      }
    }
    do {
      try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    let count = try await db.scalarInt("SELECT count(*) FROM records")
    XCTAssertEqual(count, 0)
    try await db.transaction { try $0.execute("INSERT INTO records VALUES(2)") }
    try await db.close()
  }

  func testLifecycleErrorsAndTransactionOwnership() async throws {
    let url = try location()
    for _ in 0..<20 {
      let db = try SQLiteDatabase(path: url)
      do {
        _ = try await db.scalarInt("SELECT * FROM missing")
        XCTFail("Bad query")
      } catch {}
      do {
        try await db.execute("BEGIN")
        XCTFail("Raw transaction accepted")
      } catch {}
      do {
        try await db.transaction { try $0.transaction { _ in () } }
        XCTFail("Nested transaction")
      } catch {}
      try await db.transaction {
        try $0.execute("CREATE TABLE IF NOT EXISTS reusable(value INTEGER)")
      }
      try await db.close()
      try await db.close()
      do {
        _ = try await db.readInt("SELECT 1")
        XCTFail("Read after close")
      } catch {}
    }
    do {
      _ = try SQLiteDatabase(path: url, readerCount: 0)
      XCTFail("Invalid pool")
    } catch {}
    do {
      _ = try SQLiteDatabase(path: url.appendingPathComponent("missing"))
      XCTFail("Invalid location")
    } catch {}
  }

  func testClockAdvanceReceiveRollbackOverflowAndSkew() throws {
    let initial = HybridLogicalClock(physicalMilliseconds: 100, logical: 0, node: "a")
    let local = try initial.advanced(nowMilliseconds: 90)
    XCTAssertGreaterThan(local, initial)
    XCTAssertEqual(local.logical, 1)
    let remote = HybridLogicalClock(physicalMilliseconds: 101, logical: 4, node: "b")
    let received = try local.advanced(nowMilliseconds: 99, receiving: remote)
    XCTAssertGreaterThan(received, remote)
    XCTAssertEqual(received.node, "a")
    XCTAssertEqual(try received.advanced(nowMilliseconds: 102).logical, 0)
    XCTAssertThrowsError(
      try initial.advanced(nowMilliseconds: 0, receiving: remote, maximumFutureSkew: 10))
    XCTAssertThrowsError(try initial.validated(nowMilliseconds: 0, maximumFutureSkew: -1))
    XCTAssertThrowsError(
      try HybridLogicalClock(physicalMilliseconds: 1, logical: .max, node: "a").advanced(
        nowMilliseconds: 1))
    try initial.validated(nowMilliseconds: .max, maximumFutureSkew: .max)
  }

  func testIdentityRoundTripAndRedaction() throws {
    let profile = KyroProfileID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    XCTAssertEqual(
      try JSONDecoder().decode(KyroProfileID.self, from: JSONEncoder().encode(profile)), profile)
    XCTAssertEqual(profile.description, "00000000-0000-0000-0000-000000000001")
    let url = URL(
      string: "https://user:secret@example.invalid/movie/user/password/file?token=secret")!
    XCTAssertEqual(DiagnosticRedactor.url(url), "https://example.invalid/[REDACTED]")
    XCTAssertEqual(
      DiagnosticRedactor.headers(["Authorization": "Bearer secret"])["Authorization"], "[REDACTED]")
  }
  func testForbiddenDependencies() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let sources = root.appendingPathComponent("Sources")
    let forbidden = ["SiloAPI", "AuthService", "TokenStore", "SwiftUI", "UIKit", "AetherEngine"]
    let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      let source = try String(contentsOf: url, encoding: .utf8)
      for symbol in forbidden {
        XCTAssertFalse(
          source.contains(symbol), "Forbidden dependency in \(url.lastPathComponent): \(symbol)")
      }
    }
  }
  enum TestError: Error { case invalidCount }
}
