#if os(iOS) || KYRO_VOD_HOST_TESTS
import Foundation
import SQLite3

/// Provider-scoped, paged catalog. A refresh remains invisible until its generation is promoted.
actor XtreamVODCatalogStore {
    private var database: OpaquePointer?
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// The catalog is re-downloadable, so a purgeable cache is appropriate on iOS.
    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        (fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
            .appendingPathComponent("IPTVVOD", isDirectory: true)
    }

    init(directory: URL? = nil) throws {
        let root = directory ?? Self.defaultDirectory()
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { throw XtreamVODError.storage }
        let path = root.appendingPathComponent("catalog.sqlite").path
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw XtreamVODError.storage
        }
        let openedDatabase = database
        func initialize(_ sql: String) throws {
            guard sqlite3_exec(openedDatabase, sql, nil, nil, nil) == SQLITE_OK else { throw XtreamVODError.storage }
        }
        // NORMAL is durable across app crashes in WAL mode and keeps 100k-row imports fast. A power
        // loss can drop only the last commit; promotion is a single transaction, so the active
        // catalog is always a complete generation.
        try initialize("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA synchronous=NORMAL;")
        try initialize("""
            CREATE TABLE IF NOT EXISTS vod_items (
              provider TEXT NOT NULL, kind TEXT NOT NULL, generation TEXT NOT NULL, remote_id INTEGER NOT NULL,
              title TEXT NOT NULL, category TEXT NOT NULL, poster TEXT, ext TEXT, summary TEXT, genre TEXT, rating TEXT,
              PRIMARY KEY(provider, kind, generation, remote_id)
            );
            CREATE TABLE IF NOT EXISTS vod_active (
              provider TEXT NOT NULL, kind TEXT NOT NULL, generation TEXT NOT NULL,
              PRIMARY KEY(provider, kind)
            );
            CREATE INDEX IF NOT EXISTS vod_browse ON vod_items(provider, kind, generation, title COLLATE NOCASE);
            CREATE INDEX IF NOT EXISTS vod_category_browse ON vod_items(provider, kind, generation, category, title COLLATE NOCASE);
            CREATE TABLE IF NOT EXISTS vod_page_anchors (
              provider TEXT NOT NULL, kind TEXT NOT NULL, generation TEXT NOT NULL,
              ordinal INTEGER NOT NULL, title TEXT NOT NULL, remote_id INTEGER NOT NULL,
              PRIMARY KEY(provider, kind, generation, ordinal)
            );
            """)
        // External-content FTS keeps one indexed title per row. Triggers participate in the same
        // transaction as staging/promotion, so a crash cannot expose a partial search index.
        try initialize("""
            CREATE VIRTUAL TABLE IF NOT EXISTS vod_title_fts USING fts5(
              title, content='vod_items', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2'
            );
            CREATE TRIGGER IF NOT EXISTS vod_fts_insert AFTER INSERT ON vod_items BEGIN
              INSERT INTO vod_title_fts(rowid,title) VALUES(new.rowid,new.title);
            END;
            CREATE TRIGGER IF NOT EXISTS vod_fts_delete AFTER DELETE ON vod_items BEGIN
              INSERT INTO vod_title_fts(vod_title_fts,rowid,title) VALUES('delete',old.rowid,old.title);
            END;
            CREATE TRIGGER IF NOT EXISTS vod_fts_update AFTER UPDATE ON vod_items BEGIN
              INSERT INTO vod_title_fts(vod_title_fts,rowid,title) VALUES('delete',old.rowid,old.title);
              INSERT INTO vod_title_fts(rowid,title) VALUES(new.rowid,new.title);
            END;
            """)
        // Build 110 unified Movies/Series index. Additive tables only: vod_items, its FTS index
        // and triggers are untouched, so Universal Search reads exactly what it read before.
        try initialize(Self.unifiedCatalogSchema)
        var version: Int32 = 0
        var versionStatement: OpaquePointer?
        if sqlite3_prepare_v2(openedDatabase, "PRAGMA user_version", -1, &versionStatement, nil) == SQLITE_OK,
           sqlite3_step(versionStatement) == SQLITE_ROW {
            version = sqlite3_column_int(versionStatement, 0)
        }
        sqlite3_finalize(versionStatement)
        if version < 2 {
            try initialize("BEGIN IMMEDIATE")
            do {
                try initialize("INSERT INTO vod_title_fts(vod_title_fts) VALUES('rebuild')")
                try initialize("PRAGMA user_version=2")
                try initialize("COMMIT")
            } catch {
                try? initialize("ROLLBACK")
                throw error
            }
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    /// Close explicitly before test fixtures are removed; production stores close on deinit.
    func close() {
        if let database { sqlite3_close(database) }
        database = nil
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw XtreamVODError.storage }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw XtreamVODError.storage
        }
        return statement
    }

    func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) {
        if let value { sqlite3_bind_text(statement, index, value, -1, Self.transient) }
        else { sqlite3_bind_null(statement, index) }
    }

    func stage(_ items: [XtreamVODItem], generation: String) throws {
        guard !items.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("""
                INSERT INTO vod_items(provider,kind,generation,remote_id,title,category,poster,ext,summary,genre,rating)
                VALUES(?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(provider,kind,generation,remote_id) DO UPDATE SET
                  title=excluded.title, category=excluded.category, poster=excluded.poster,
                  ext=excluded.ext, summary=excluded.summary, genre=excluded.genre, rating=excluded.rating
                """)
            defer { sqlite3_finalize(statement) }
            for item in items {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(item.providerID.uuidString, at: 1, in: statement)
                bind(item.kind.rawValue, at: 2, in: statement)
                bind(generation, at: 3, in: statement)
                sqlite3_bind_int64(statement, 4, sqlite3_int64(item.remoteID))
                bind(item.title, at: 5, in: statement)
                bind(item.category, at: 6, in: statement)
                bind(item.poster, at: 7, in: statement)
                bind(item.fileExtension, at: 8, in: statement)
                bind(item.summary, at: 9, in: statement)
                bind(item.genre, at: 10, in: statement)
                bind(item.rating, at: 11, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw XtreamVODError.storage }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Sparse browse checkpoints bound deep OFFSET work to at most 1,023 rows. Build after the
    /// final stage batch and before promotion; a missing checkpoint safely falls back to OFFSET.
    func buildPageAnchors(providerID: UUID, kind: XtreamVODKind, generation: String) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let clear = try prepare("DELETE FROM vod_page_anchors WHERE provider=? AND kind=? AND generation=?")
            bind(providerID.uuidString, at: 1, in: clear)
            bind(kind.rawValue, at: 2, in: clear)
            bind(generation, at: 3, in: clear)
            let cleared = sqlite3_step(clear)
            sqlite3_finalize(clear)
            guard cleared == SQLITE_DONE else { throw XtreamVODError.storage }
            let rows = try prepare("""
                SELECT title, remote_id FROM vod_items WHERE provider=? AND kind=? AND generation=?
                ORDER BY title COLLATE NOCASE, remote_id
                """)
            defer { sqlite3_finalize(rows) }
            bind(providerID.uuidString, at: 1, in: rows)
            bind(kind.rawValue, at: 2, in: rows)
            bind(generation, at: 3, in: rows)
            let insert = try prepare("INSERT INTO vod_page_anchors(provider,kind,generation,ordinal,title,remote_id) VALUES(?,?,?,?,?,?)")
            defer { sqlite3_finalize(insert) }
            var ordinal = 0
            var result = sqlite3_step(rows)
            while result == SQLITE_ROW {
                if ordinal.isMultiple(of: 1024) {
                    try Task.checkCancellation()
                    guard let title = sqlite3_column_text(rows, 0) else { throw XtreamVODError.storage }
                    sqlite3_reset(insert)
                    sqlite3_clear_bindings(insert)
                    bind(providerID.uuidString, at: 1, in: insert)
                    bind(kind.rawValue, at: 2, in: insert)
                    bind(generation, at: 3, in: insert)
                    sqlite3_bind_int64(insert, 4, sqlite3_int64(ordinal))
                    bind(String(cString: title), at: 5, in: insert)
                    sqlite3_bind_int64(insert, 6, sqlite3_column_int64(rows, 1))
                    guard sqlite3_step(insert) == SQLITE_DONE else { throw XtreamVODError.storage }
                }
                ordinal += 1
                result = sqlite3_step(rows)
            }
            guard result == SQLITE_DONE else { throw XtreamVODError.storage }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func promote(providerID: UUID, kind: XtreamVODKind, generation: String) throws {
        try promoteAll(providerID: providerID, generations: [(kind, generation)])
    }

    func promoteAll(providerID: UUID, generations: [(XtreamVODKind, String)]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for (kind, generation) in generations {
                let statement = try prepare("INSERT OR REPLACE INTO vod_active(provider,kind,generation) VALUES(?,?,?)")
                bind(providerID.uuidString, at: 1, in: statement)
                bind(kind.rawValue, at: 2, in: statement)
                bind(generation, at: 3, in: statement)
                let result = sqlite3_step(statement)
                sqlite3_finalize(statement)
                guard result == SQLITE_DONE else { throw XtreamVODError.storage }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func discard(providerID: UUID, kind: XtreamVODKind, generation: String) {
        for table in ["vod_page_anchors", "unified_iptv_keys"] {
            guard let rows = try? prepare("DELETE FROM \(table) WHERE provider=? AND kind=? AND generation=?") else { continue }
            bind(providerID.uuidString, at: 1, in: rows)
            bind(kind.rawValue, at: 2, in: rows)
            bind(generation, at: 3, in: rows)
            sqlite3_step(rows)
            sqlite3_finalize(rows)
        }
        guard let statement = try? prepare("DELETE FROM vod_items WHERE provider=? AND kind=? AND generation=?") else { return }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, at: 1, in: statement)
        bind(kind.rawValue, at: 2, in: statement)
        bind(generation, at: 3, in: statement)
        sqlite3_step(statement)
    }

    func remove(providerID: UUID) {
        for table in ["vod_active", "vod_page_anchors", "unified_iptv_keys", "vod_items"] {
            guard let statement = try? prepare("DELETE FROM \(table) WHERE provider=?") else { continue }
            bind(providerID.uuidString, at: 1, in: statement)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
    }

    /// A process can die after staging but before promotion. Prune only inactive generations;
    /// active rows remain readable throughout recovery. Call before starting a new refresh.
    func pruneOrphanedGenerations() async throws {
        try execute("""
            DELETE FROM unified_iptv_keys WHERE NOT EXISTS (
              SELECT 1 FROM vod_active a WHERE a.provider=unified_iptv_keys.provider
                AND a.kind=unified_iptv_keys.kind AND a.generation=unified_iptv_keys.generation
            )
            """)
        try execute("""
            DELETE FROM vod_page_anchors WHERE NOT EXISTS (
              SELECT 1 FROM vod_active a WHERE a.provider=vod_page_anchors.provider
                AND a.kind=vod_page_anchors.kind AND a.generation=vod_page_anchors.generation
            )
            """)
        var cursor: sqlite3_int64 = 0
        while true {
            try Task.checkCancellation()
            let selection = try prepare("""
                SELECT i.rowid FROM vod_items i WHERE i.rowid>? AND NOT EXISTS (
                  SELECT 1 FROM vod_active a WHERE a.provider=i.provider
                    AND a.kind=i.kind AND a.generation=i.generation
                ) ORDER BY i.rowid LIMIT 1024
                """)
            sqlite3_bind_int64(selection, 1, cursor)
            var rowIDs: [sqlite3_int64] = []
            var result = sqlite3_step(selection)
            while result == SQLITE_ROW {
                rowIDs.append(sqlite3_column_int64(selection, 0))
                result = sqlite3_step(selection)
            }
            sqlite3_finalize(selection)
            guard result == SQLITE_DONE else { throw XtreamVODError.storage }
            guard let last = rowIDs.last else { return }
            cursor = last
            try execute("BEGIN IMMEDIATE")
            do {
                let deletion = try prepare("DELETE FROM vod_items WHERE rowid=?")
                defer { sqlite3_finalize(deletion) }
                for rowID in rowIDs {
                    sqlite3_reset(deletion)
                    sqlite3_bind_int64(deletion, 1, rowID)
                    guard sqlite3_step(deletion) == SQLITE_DONE else { throw XtreamVODError.storage }
                }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
            await Task.yield()
        }
    }

    private static func searchExpression(_ query: String) -> String? {
        let terms = query.unicodeScalars.split { !CharacterSet.alphanumerics.contains($0) }
            .map { String(String.UnicodeScalarView($0)) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        // Quote each token so user input never becomes FTS syntax. Prefix matching supports
        // type-ahead without the O(catalog) leading-wildcard LIKE scan.
        return terms.prefix(8).map { "\"\($0)\"*" }.joined(separator: " AND ")
    }

    private func pageAnchor(providerID: UUID, kind: XtreamVODKind, offset: Int) -> (Int, String, Int64)? {
        guard offset >= 1024, let statement = try? prepare("""
            SELECT p.ordinal,p.title,p.remote_id FROM vod_page_anchors p JOIN vod_active a
              ON p.provider=a.provider AND p.kind=a.kind AND p.generation=a.generation
            WHERE p.provider=? AND p.kind=? AND p.ordinal<=?
            ORDER BY p.ordinal DESC LIMIT 1
            """) else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, at: 1, in: statement)
        bind(kind.rawValue, at: 2, in: statement)
        sqlite3_bind_int64(statement, 3, sqlite3_int64(offset))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let rawTitle = sqlite3_column_text(statement, 1) else { return nil }
        return (Int(sqlite3_column_int64(statement, 0)), String(cString: rawTitle), sqlite3_column_int64(statement, 2))
    }

    func count(providerID: UUID, kind: XtreamVODKind) -> Int {
        guard let statement = try? prepare("""
            SELECT COUNT(*) FROM vod_items i JOIN vod_active a
              ON i.provider=a.provider AND i.kind=a.kind AND i.generation=a.generation
            WHERE i.provider=? AND i.kind=?
            """) else { return 0 }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, at: 1, in: statement)
        bind(kind.rawValue, at: 2, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    func categories(providerID: UUID, kind: XtreamVODKind) -> [String] {
        guard let statement = try? prepare("""
            SELECT DISTINCT i.category FROM vod_items i JOIN vod_active a
              ON i.provider=a.provider AND i.kind=a.kind AND i.generation=a.generation
            WHERE i.provider=? AND i.kind=? ORDER BY i.category COLLATE NOCASE
            """) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, at: 1, in: statement)
        bind(kind.rawValue, at: 2, in: statement)
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 0) { names.append(String(cString: raw)) }
        }
        return names
    }

    func page(providerID: UUID, kind: XtreamVODKind, query: String = "", category: String? = nil,
              offset: Int = 0, limit: Int = 100) -> [XtreamVODItem] {
        let statement: OpaquePointer
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let search = Self.searchExpression(trimmed)
        // Browsing (no query) walks the title index directly instead of testing every row.
        let categoryFilter = category == nil ? "" : " AND i.category=?"
        let searchJoin = search == nil ? "" : " JOIN vod_title_fts ON vod_title_fts.rowid=i.rowid"
        let filter = search == nil ? "" : " AND vod_title_fts MATCH ?"
        let anchor = search == nil && category == nil ? pageAnchor(providerID: providerID, kind: kind, offset: offset) : nil
        // The explicit title range lets SQLite seek into vod_browse; the tuple predicate handles
        // duplicate titles without skipping or repeating a channel at the checkpoint boundary.
        let anchorFilter = anchor == nil ? "" : " AND i.title COLLATE NOCASE >= ? AND (i.title COLLATE NOCASE, i.remote_id) >= (?,?)"
        do {
            statement = try prepare("""
                SELECT i.remote_id,i.title,i.category,i.poster,i.ext,i.summary,i.genre,i.rating
                FROM vod_items i JOIN vod_active a
                  ON i.provider=a.provider AND i.kind=a.kind AND i.generation=a.generation
                \(searchJoin)
                WHERE i.provider=? AND i.kind=?\(categoryFilter)\(filter)\(anchorFilter)
                ORDER BY i.title COLLATE NOCASE, i.remote_id LIMIT ? OFFSET ?
                """)
        } catch { return [] }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, at: 1, in: statement)
        bind(kind.rawValue, at: 2, in: statement)
        var next: Int32 = 3
        if let category {
            bind(category, at: next, in: statement)
            next += 1
        }
        if let search {
            bind(search, at: next, in: statement)
            next += 1
        }
        if let anchor {
            bind(anchor.1, at: next, in: statement)
            bind(anchor.1, at: next + 1, in: statement)
            sqlite3_bind_int64(statement, next + 2, anchor.2)
            next += 3
        }
        sqlite3_bind_int(statement, next, Int32(min(max(limit, 1), 100)))
        sqlite3_bind_int(statement, next + 1, Int32(max(0, offset - (anchor?.0 ?? 0))))
        func value(_ index: Int32) -> String? {
            guard let raw = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: raw)
        }
        var items: [XtreamVODItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            items.append(.init(providerID: providerID, kind: kind, remoteID: Int(sqlite3_column_int64(statement, 0)),
                               title: value(1) ?? "Untitled", category: value(2) ?? "Other",
                               poster: value(3), fileExtension: value(4), summary: value(5),
                               genre: value(6), rating: value(7)))
        }
        return items
    }

    /// Newest titles first. Xtream assigns stream and series IDs in the order a panel adds them,
    /// so a descending ID is the provider's own "recently added" order. Without a category this
    /// walks the primary-key index backwards; with one it sorts only that category's rows.
    func newest(providerID: UUID, kind: XtreamVODKind, category: String? = nil, limit: Int = 20) -> [XtreamVODItem] {
        let categoryFilter = category == nil ? "" : " AND i.category=?"
        guard let statement = try? prepare("""
            SELECT i.remote_id,i.title,i.category,i.poster,i.ext,i.summary,i.genre,i.rating
            FROM vod_items i JOIN vod_active a
              ON i.provider=a.provider AND i.kind=a.kind AND i.generation=a.generation
            WHERE i.provider=? AND i.kind=?\(categoryFilter)
            ORDER BY i.remote_id DESC LIMIT ?
            """) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, at: 1, in: statement)
        bind(kind.rawValue, at: 2, in: statement)
        var next: Int32 = 3
        if let category {
            bind(category, at: next, in: statement)
            next += 1
        }
        sqlite3_bind_int(statement, next, Int32(min(max(limit, 1), 100)))
        return readItems(statement, providerID: providerID, kind: kind)
    }

    /// Every category with its title count, largest first, in one grouped pass over the
    /// category index. Callers cache it per catalog revision.
    func categorySummaries(providerID: UUID, kind: XtreamVODKind) -> [XtreamVODCategorySummary] {
        guard let statement = try? prepare("""
            SELECT i.category, COUNT(*) FROM vod_items i JOIN vod_active a
              ON i.provider=a.provider AND i.kind=a.kind AND i.generation=a.generation
            WHERE i.provider=? AND i.kind=? GROUP BY i.category
            """) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, at: 1, in: statement)
        bind(kind.rawValue, at: 2, in: statement)
        var result: [XtreamVODCategorySummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            result.append(.init(name: String(cString: raw), count: Int(sqlite3_column_int64(statement, 1))))
        }
        return XtreamVODCategorySummary.ordered(result)
    }

    private func readItems(_ statement: OpaquePointer, providerID: UUID, kind: XtreamVODKind) -> [XtreamVODItem] {
        func value(_ index: Int32) -> String? {
            guard let raw = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: raw)
        }
        var items: [XtreamVODItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            items.append(.init(providerID: providerID, kind: kind, remoteID: Int(sqlite3_column_int64(statement, 0)),
                               title: value(1) ?? "Untitled", category: value(2) ?? "Other",
                               poster: value(3), fileExtension: value(4), summary: value(5),
                               genre: value(6), rating: value(7)))
        }
        return items
    }

    func item(providerID: UUID, kind: XtreamVODKind, remoteID: Int) -> XtreamVODItem? {
        guard let statement = try? prepare("""
            SELECT i.title,i.category,i.poster,i.ext,i.summary,i.genre,i.rating
            FROM vod_items i JOIN vod_active a
              ON i.provider=a.provider AND i.kind=a.kind AND i.generation=a.generation
            WHERE i.provider=? AND i.kind=? AND i.remote_id=? LIMIT 1
            """) else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, at: 1, in: statement)
        bind(kind.rawValue, at: 2, in: statement)
        sqlite3_bind_int64(statement, 3, sqlite3_int64(remoteID))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        func value(_ index: Int32) -> String? {
            guard let raw = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: raw)
        }
        return .init(providerID: providerID, kind: kind, remoteID: remoteID,
                     title: value(0) ?? "Untitled", category: value(1) ?? "Other",
                     poster: value(2), fileExtension: value(3), summary: value(4),
                     genre: value(5), rating: value(6))
    }
}
#endif
