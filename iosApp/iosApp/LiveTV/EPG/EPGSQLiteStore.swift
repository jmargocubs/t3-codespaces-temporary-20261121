import Foundation
import SQLite3

/// Failures specific to the optional SQLite guide store. Every one of them is recoverable: the
/// caller falls back to the in-memory index and the v2 `.epgcache` path.
enum EPGSQLiteError: Error, Equatable, Sendable {
    case openFailed
    case statementFailed
    case incompatibleSchema
    case corrupt
    case mismatchedIdentity
}

/// Internal switch for SQLite guide storage. Off unless the owner enables it in the internal test
/// build. The production UI does not expose this preference.
///
/// Only builds compiled with `KYRO_INTERNAL_EPG_STORAGE_TOGGLE` read the preference. Every other
/// build uses the in-memory guide, even when an earlier internal build left the preference on,
/// because those builds have no switch to turn it off.
enum EPGStorageMode: Sendable, Equatable {
    case memory
    case sqlite

    static let defaultsKey = "kyro.internal.epg.sqliteStorage"

    /// Whether this build includes the internal SQLite switch.
    #if KYRO_INTERNAL_EPG_STORAGE_TOGGLE
    static let isInternalToggleCompiled = true
    #else
    static let isInternalToggleCompiled = false
    #endif

    static func current(defaults: UserDefaults = .standard) -> EPGStorageMode {
        resolve(preferenceEnabled: defaults.bool(forKey: defaultsKey), toggleCompiled: isInternalToggleCompiled)
    }

    static func resolve(preferenceEnabled: Bool, toggleCompiled: Bool) -> EPGStorageMode {
        toggleCompiled && preferenceEnabled ? .sqlite : .memory
    }
}

/// Thin owner of one `sqlite3` connection. All access is serialized by the owner's lock.
final class EPGSQLiteConnection: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()

    /// Opens an immutable, read-only view of a finished generation file. `immutable` skips locking
    /// and journal checks; published generation paths are never modified, renamed or unlinked while
    /// a connection holds a lease. Activation switches a separate text pointer instead.
    static func openReadOnly(_ url: URL) throws -> EPGSQLiteConnection {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw EPGSQLiteError.openFailed
        }
        components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        guard let uri = components.string else { throw EPGSQLiteError.openFailed }
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            sqlite3_close(db)
            throw EPGSQLiteError.openFailed
        }
        let connection = EPGSQLiteConnection(handle: db)
        // A small page cache: queries are single-channel range scans.
        try connection.execute("PRAGMA cache_size = -1024")
        return connection
    }

    static func create(_ url: URL) throws -> EPGSQLiteConnection {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            sqlite3_close(db)
            throw EPGSQLiteError.openFailed
        }
        return EPGSQLiteConnection(handle: db)
    }

    private init(handle: OpaquePointer) { self.handle = handle }

    deinit { sqlite3_close(handle) }

    func close() {
        lock.withLock {
            sqlite3_close(handle)
            handle = nil
        }
    }

    func execute(_ sql: String) throws {
        try lock.withLock {
            guard let handle, sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw EPGSQLiteError.statementFailed
            }
        }
    }

    /// Runs `body` with the connection locked. Statements prepared inside must be finalized inside.
    func withHandle<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try lock.withLock {
            guard let handle else { throw EPGSQLiteError.statementFailed }
            return try body(handle)
        }
    }
}

/// A prepared statement bound to one connection handle. Not thread-safe; use under `withHandle`.
struct EPGSQLiteStatement {
    private(set) var raw: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, raw != nil else {
            sqlite3_finalize(raw)
            throw EPGSQLiteError.statementFailed
        }
    }

    func finalize() { sqlite3_finalize(raw) }
    func reset() { sqlite3_reset(raw); sqlite3_clear_bindings(raw) }

    func bind(_ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(raw, index, value, -1, Self.transient) } else { sqlite3_bind_null(raw, index) }
    }

    func bind(_ index: Int32, _ value: Double) { sqlite3_bind_double(raw, index, value) }
    func bind(_ index: Int32, _ value: Int64) { sqlite3_bind_int64(raw, index, value) }
    func bind(_ index: Int32, blob value: Data) {
        _ = value.withUnsafeBytes { sqlite3_bind_blob(raw, index, $0.baseAddress, Int32(value.count), Self.transient) }
    }

    /// True while a row is available; false at the end. Throws on any other result.
    func step() throws -> Bool {
        switch sqlite3_step(raw) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw EPGSQLiteError.statementFailed
        }
    }

    func text(_ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(raw, column) else { return nil }
        return String(cString: pointer)
    }

    func double(_ column: Int32) -> Double { sqlite3_column_double(raw, column) }
    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(raw, column) }
    func blob(_ column: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(raw, column) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(raw, column)))
    }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(raw, column) == SQLITE_NULL }
}

/// On-disk layout, one file per provider (`<uuid>.guide.sqlite`).
///
/// ```
/// meta(key TEXT PRIMARY KEY, value)            -- schema, identity, counts, fetch time
/// channels(channel_key TEXT PRIMARY KEY,       -- normalized guide ID, only channels with listings
///          program_count INTEGER, last_end REAL) WITHOUT ROWID   + index channels_last_end(last_end)
/// names(name_key TEXT PRIMARY KEY, channel_key TEXT) WITHOUT ROWID   -- unambiguous names only
/// programmes(channel_key, start_s REAL, end_s REAL, channel_id TEXT NULL,
///            title, subtitle, summary, category, episode,
///            PRIMARY KEY(channel_key, start_s)) WITHOUT ROWID
/// ```
///
/// Times are `timeIntervalSinceReferenceDate`, so a `Date` round-trips exactly. `channel_id` holds
/// the provider's raw spelling only when it differs from `channel_key`. Programmes are stored
/// already normalized (sorted, deduplicated, non-overlapping, bounded), so reads are plain range
/// scans on the primary key and results match `EPGIndex` exactly.
enum EPGSQLiteSchema {
    static let version = 1
    static let applicationID: Int32 = 0x4B45_5047 // "KEPG"

    static let create = """
    CREATE TABLE meta(key TEXT PRIMARY KEY, value) WITHOUT ROWID;
    CREATE TABLE channels(channel_key TEXT PRIMARY KEY, program_count INTEGER NOT NULL, last_end REAL NOT NULL) WITHOUT ROWID;
    CREATE INDEX channels_last_end ON channels(last_end);
    CREATE TABLE names(name_key TEXT PRIMARY KEY, channel_key TEXT NOT NULL) WITHOUT ROWID;
    CREATE TABLE programmes(
        channel_key TEXT NOT NULL, start_s REAL NOT NULL, end_s REAL NOT NULL, channel_id TEXT,
        title TEXT NOT NULL, subtitle TEXT, summary TEXT, category TEXT, episode TEXT,
        PRIMARY KEY(channel_key, start_s)) WITHOUT ROWID;
    """

    static let selectChannel = """
    SELECT channel_id, start_s, end_s, title, subtitle, summary, category, episode
    FROM programmes WHERE channel_key = ?1 ORDER BY start_s
    """
}

/// Identity and counts stored in `meta`. Compared with the cache state before a guide is trusted.
struct EPGSQLiteMetadata: Equatable, Sendable {
    var providerID: UUID
    var sourceFingerprint: Data
    var contentID: UUID
    var fetchedAt: Date
    var programCount: Int
    var channelCount: Int
    var coverageEnd: Date?

    func rows() -> [(String, SQLiteValue)] {
        [("schema", .int(Int64(EPGSQLiteSchema.version))),
         ("provider_id", .text(providerID.uuidString)),
         ("source_fingerprint", .blob(sourceFingerprint)),
         ("content_id", .text(contentID.uuidString)),
         ("fetched_at", .double(fetchedAt.timeIntervalSince1970)),
         ("program_count", .int(Int64(programCount))),
         ("channel_count", .int(Int64(channelCount))),
         ("coverage_end", coverageEnd.map { .double($0.timeIntervalSinceReferenceDate) } ?? .null)]
    }

    enum SQLiteValue { case int(Int64), double(Double), text(String), blob(Data), null }

    static func read(from db: OpaquePointer) throws -> EPGSQLiteMetadata {
        let statement = try EPGSQLiteStatement(db, "SELECT key, value FROM meta")
        defer { statement.finalize() }
        var ints: [String: Int64] = [:], doubles: [String: Double] = [:]
        var texts: [String: String] = [:], blobs: [String: Data] = [:]
        while try statement.step() {
            guard let key = statement.text(0) else { continue }
            switch sqlite3_column_type(statement.raw, 1) {
            case SQLITE_INTEGER: ints[key] = statement.int64(1)
            case SQLITE_FLOAT: doubles[key] = statement.double(1)
            case SQLITE_TEXT: texts[key] = statement.text(1)
            case SQLITE_BLOB: blobs[key] = statement.blob(1)
            default: break
            }
        }
        guard let schema = ints["schema"] else { throw EPGSQLiteError.corrupt }
        guard schema == Int64(EPGSQLiteSchema.version) else { throw EPGSQLiteError.incompatibleSchema }
        guard let provider = texts["provider_id"].flatMap(UUID.init(uuidString:)),
              let content = texts["content_id"].flatMap(UUID.init(uuidString:)),
              let fingerprint = blobs["source_fingerprint"],
              let fetched = doubles["fetched_at"], fetched.isFinite,
              let programs = ints["program_count"], programs >= 0,
              let channels = ints["channel_count"], channels >= 0 else { throw EPGSQLiteError.corrupt }
        return EPGSQLiteMetadata(providerID: provider, sourceFingerprint: fingerprint, contentID: content,
                                 fetchedAt: EPGTimestamp.canonical(Date(timeIntervalSince1970: fetched)),
                                 programCount: Int(programs), channelCount: Int(channels),
                                 coverageEnd: doubles["coverage_end"].map(Date.init(timeIntervalSinceReferenceDate:)))
    }
}
