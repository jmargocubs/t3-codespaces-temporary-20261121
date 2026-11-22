import CSQLite
import Foundation

/// One writer; synchronous transaction bodies cannot interleave with actor jobs.
public actor SQLiteDatabase {
    private let connection: SQLiteConnection
    private let readers: [SQLiteReader]
    private var nextReader = 0
    public init(path: URL, readerCount: Int = 2) throws {
        guard (1...8).contains(readerCount) else { throw DatabaseError.invalidReaderCount }
        let connection = try SQLiteConnection(path: path, readOnly: false)
        try connection.execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON")
        guard try connection.text("PRAGMA journal_mode") == "wal" else { throw DatabaseError.walUnavailable }
        try connection.execute("CREATE TABLE IF NOT EXISTS kyro_migrations(version INTEGER PRIMARY KEY)")
        self.connection = connection
        readers = try (0..<readerCount).map { _ in try SQLiteReader(path: path) }
    }
    public func close() async throws {
        guard !connection.inTransaction else { throw DatabaseError.transactionActive }
        try connection.close()
        for reader in readers { try await reader.close() }
    }
    public func execute(_ sql: String) throws { try connection.execute(sql) }
    public func scalarInt(_ sql: String) throws -> Int64 { try connection.integer(sql) }
    public func scalarText(_ sql: String) throws -> String { try connection.text(sql) }
    public func readInt(_ sql: String) async throws -> Int64 {
        try connection.requireOpen()
        let reader = readers[nextReader]
        nextReader = (nextReader + 1) % readers.count
        return try await reader.integer(sql)
    }
    public func migrate(version: Int, sql: String) throws {
        guard version > 0 else { throw DatabaseError.invalidMigration }
        try transaction { database in
            let current = try database.scalarInt("SELECT coalesce(max(version), 0) FROM kyro_migrations")
            if version <= current { return }
            guard Int64(version) == current + 1 else { throw DatabaseError.invalidMigration }
            try database.execute(sql)
            try database.execute("INSERT INTO kyro_migrations VALUES(\(version))")
        }
    }
    public func transaction<T: Sendable>(_ body: @Sendable (isolated SQLiteDatabase) throws -> T) throws -> T {
        try Task.checkCancellation()
        guard !connection.inTransaction else { throw DatabaseError.transactionActive }
        try connection.control("BEGIN IMMEDIATE")
        do {
            let result = try body(self)
            try Task.checkCancellation()
            try connection.control("COMMIT")
            return result
        } catch {
            do { try connection.control("ROLLBACK") }
            catch { try? connection.close(); throw DatabaseError.rollbackFailed }
            throw error
        }
    }
    public enum DatabaseError: Error { case open, closed, statement(Int32), transactionActive, rollbackFailed, invalidMigration, invalidReaderCount, walUnavailable }
}

private actor SQLiteReader {
    private let connection: SQLiteConnection
    init(path: URL) throws { connection = try SQLiteConnection(path: path, readOnly: true) }
    func integer(_ sql: String) throws -> Int64 { try connection.integer(sql) }
    func close() throws { try connection.close() }
}

/// Non-Sendable owner confined to one actor. Pointers never escape; deinit also
/// closes partially initialized connections when configuration fails.
private final class SQLiteConnection {
    private var handle: OpaquePointer?
    var inTransaction: Bool { handle.map { sqlite3_get_autocommit($0) == 0 } ?? false }
    init(path: URL, readOnly: Bool) throws {
        var opened: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE
        let code = sqlite3_open_v2(path.path, &opened, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw SQLiteDatabase.DatabaseError.open
        }
        handle = opened
        sqlite3_busy_timeout(opened, 5_000)
        restrictTransactions()
    }
    deinit { if let handle { sqlite3_close_v2(handle) } }
    func requireOpen() throws { guard handle != nil else { throw SQLiteDatabase.DatabaseError.closed } }
    func close() throws {
        guard let handle else { return }
        guard sqlite3_close(handle) == SQLITE_OK else { throw SQLiteDatabase.DatabaseError.statement(SQLITE_BUSY) }
        self.handle = nil
    }
    private func restrictTransactions() {
        sqlite3_set_authorizer(handle, { _, action, _, _, _, _ in
            action == SQLITE_TRANSACTION || action == SQLITE_SAVEPOINT ? SQLITE_DENY : SQLITE_OK
        }, nil)
    }
    func control(_ sql: String) throws {
        try requireOpen()
        sqlite3_set_authorizer(handle, nil, nil)
        defer { restrictTransactions() }
        try execute(sql)
    }
    func execute(_ sql: String) throws {
        try requireOpen()
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw SQLiteDatabase.DatabaseError.statement(code) }
    }
    private func query<T>(_ sql: String, read: (OpaquePointer) -> T) throws -> T {
        try requireOpen()
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard code == SQLITE_OK, let statement else { throw SQLiteDatabase.DatabaseError.statement(code) }
        let journalQuery = sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "pragma journal_mode"
        guard journalQuery || sqlite3_stmt_readonly(statement) != 0 else { throw SQLiteDatabase.DatabaseError.statement(SQLITE_READONLY) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else { throw SQLiteDatabase.DatabaseError.statement(step) }
        return read(statement)
    }
    func integer(_ sql: String) throws -> Int64 { try query(sql) { sqlite3_column_int64($0, 0) } }
    func text(_ sql: String) throws -> String {
        try query(sql) { sqlite3_column_text($0, 0).map { String(cString: $0) } ?? "" }
    }
}
