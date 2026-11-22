import KyroFoundation
import KyroLedger
import KyroMatching
import KyroSourceJellyfin
import KyroSourceXtream
import XCTest

final class CoreTests: XCTestCase {
  func testClockOrderingAndMatching() {
    XCTAssertLessThan(
      HybridLogicalClock(physicalMilliseconds: 1, logical: 0, node: "a"),
      HybridLogicalClock(physicalMilliseconds: 1, logical: 0, node: "b"))
    XCTAssertFalse(
      MediaMatcher.canMatch(
        title: "Film (2024)", title: "Film 2024", sharedExternalID: false, conflictingIDs: false))
    XCTAssertFalse(
      MediaMatcher.canMatch(
        title: "Film", title: "Film", sharedExternalID: false, conflictingIDs: true))
  }
  func testSQLitePersistence() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".sqlite")
    let db = try SQLiteDatabase(path: url)
    try await db.execute("CREATE TABLE sample(value INTEGER)")
    try await db.execute("INSERT INTO sample VALUES(42)")
    let value = try await db.scalarInt("SELECT value FROM sample")
    XCTAssertEqual(value, 42)
  }
  func testFixtureParsers() throws {
    XCTAssertEqual(
      try JellyfinParser.parse(Data("[{\"Name\":\"X\",\"Id\":\"1\",\"Type\":\"Movie\"}]".utf8))
        .count, 1)
    XCTAssertEqual(try XtreamParser.parse(Data("[{\"stream_id\":1,\"name\":\"Y\"}]".utf8)).count, 1)
  }
}
