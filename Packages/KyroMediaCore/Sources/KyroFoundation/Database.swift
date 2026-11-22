import CSQLite
import Foundation
public actor SQLiteDatabase {
    private var handle: OpaquePointer?
    public init(path: URL) throws {
        var opened: OpaquePointer?
        guard sqlite3_open_v2(path.path, &opened, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let opened else { throw DatabaseError.open }
        handle = opened
        try Self.execute(opened, "PRAGMA journal_mode=WAL")
        try Self.execute(opened, "CREATE TABLE IF NOT EXISTS kyro_migrations(version INTEGER PRIMARY KEY)")
    }
    isolated deinit { if let handle { sqlite3_close_v2(handle) } }
    public func close() throws {
        guard let handle else { return }
        guard sqlite3_close(handle) == SQLITE_OK else { throw DatabaseError.statement("Connection busy") }
        self.handle = nil
    }
    public func migrate(version: Int, sql: String) throws {
        guard version > 0 else { throw DatabaseError.statement("Invalid migration version") }
        try transaction { database in
            let applied = try database.scalarInt("SELECT count(*) FROM kyro_migrations WHERE version=\(version)")
            if applied == 0 {
                try database.execute(sql)
                try database.execute("INSERT INTO kyro_migrations VALUES(\(version))")
            }
        }
    }
    public func execute(_ sql: String) throws {
        guard let handle else { throw DatabaseError.closed }
        try Self.execute(handle, sql)
    }
    private static func execute(_ handle: OpaquePointer?, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let error = message.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(message); throw DatabaseError.statement(error)
        }
    }
    public func scalarInt(_ sql: String) throws -> Int64 {
        guard let handle else { throw DatabaseError.closed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw DatabaseError.statement(String(cString: sqlite3_errmsg(handle))) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw DatabaseError.statement("No row") }
        return sqlite3_column_int64(statement, 0)

    }
    public func transaction<T: Sendable>(_ body: @Sendable (isolated SQLiteDatabase) throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(self); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    public enum DatabaseError: Error { case open, closed, statement(String) }
}
