import Foundation
import XCTest
import KyroFoundation

final class PersistenceTests: XCTestCase {
    func testReopenMigrationRollbackAndClose() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = try SQLiteDatabase(path: url)
        try await db.migrate(version: 1, sql: "CREATE TABLE records(value INTEGER)")
        try await db.migrate(version: 1, sql: "INVALID SQL")
        try await db.transaction { try $0.execute("INSERT INTO records VALUES(7)") }
        do {
            try await db.transaction { connection in
                try connection.execute("INSERT INTO records VALUES(8)")
                throw NSError(domain: "rollback", code: 1)
            }
            XCTFail("Expected rollback")
        } catch {}
        try await db.close()
        try await db.close()
        do { try await db.execute("SELECT 1"); XCTFail("Closed connection accepted SQL") } catch {}
        let reopened = try SQLiteDatabase(path: url)
        let count = try await reopened.scalarInt("SELECT count(*) FROM records")
        let migrations = try await reopened.scalarInt("SELECT count(*) FROM kyro_migrations")
        XCTAssertEqual(count, 1)
        XCTAssertEqual(migrations, 1)
        try await reopened.close()
    }
}
