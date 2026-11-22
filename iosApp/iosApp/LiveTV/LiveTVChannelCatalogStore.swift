#if os(iOS) || KYRO_CHANNEL_HOST_TESTS
import Foundation
import SQLite3

/// Disk-backed provider catalog foundation. A generation is invisible until `promote` verifies
/// its contiguous ordinals and atomically switches `channel_active`. Callers fetch bounded pages
/// or individual IDs; no query returns an entire catalog of `LiveTVChannel` values.
actor LiveTVChannelCatalogStore {
    struct EPGAssociationValues: Sendable {
        let guideIDs: [String?]
        let names: [String]
    }

    struct ProgramAssociation: Sendable {
        let id: String
        let guideID: String?
        let name: String
        let ordinal: Int
    }
    enum StoreError: Error { case storage, invalidGeneration, invalidIdentity }
    struct CategorySummary: Sendable {
        let name: String
        let channelCount: Int
        let favoriteCount: Int
        let artworkChannel: LiveTVChannel?
    }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var database: OpaquePointer?

    static func defaultDirectory() -> URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
            .appendingPathComponent("Silo/LiveTV/ChannelCatalog", isDirectory: true)
    }

    init(directory: URL? = nil) throws {
        let root = directory ?? Self.defaultDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        // M3U stream addresses may embed provider credentials. Keep the last-known-good catalog
        // outside purgeable Caches, explicitly exclude it from backup, and protect the database,
        // WAL and SHM files until the device has been unlocked once after boot.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedRoot = root
        try protectedRoot.setResourceValues(values)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: root.path)
        #endif
        guard sqlite3_open_v2(root.appendingPathComponent("channels.sqlite").path, &database,
                              SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw StoreError.storage
        }
        let db = database
        func initialize(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.storage }
        }
        try initialize("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000;")
        try initialize("""
            CREATE TABLE IF NOT EXISTS channel_items (
              provider TEXT NOT NULL, generation TEXT NOT NULL, ordinal INTEGER NOT NULL,
              id TEXT NOT NULL, guide_id TEXT, name TEXT NOT NULL, category TEXT NOT NULL,
              stream_url TEXT NOT NULL, logo_url TEXT, stream_id INTEGER,
              PRIMARY KEY(provider,generation,id), UNIQUE(provider,generation,ordinal)
            );
            CREATE TABLE IF NOT EXISTS channel_active (
              provider TEXT PRIMARY KEY, generation TEXT NOT NULL, channel_count INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS channel_favorites (
              provider TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY(provider,id)
            );
            CREATE INDEX IF NOT EXISTS channel_order ON channel_items(provider,generation,ordinal);
            CREATE INDEX IF NOT EXISTS channel_category ON channel_items(provider,generation,category,ordinal);
            CREATE INDEX IF NOT EXISTS channel_guide ON channel_items(provider,generation,guide_id,ordinal);
            CREATE VIRTUAL TABLE IF NOT EXISTS channel_search USING fts5(
              name, category, content='channel_items', content_rowid='rowid',
              tokenize='unicode61 remove_diacritics 2'
            );
            CREATE TRIGGER IF NOT EXISTS channel_fts_insert AFTER INSERT ON channel_items BEGIN
              INSERT INTO channel_search(rowid,name,category) VALUES(new.rowid,new.name,new.category);
            END;
            CREATE TRIGGER IF NOT EXISTS channel_fts_delete AFTER DELETE ON channel_items BEGIN
              INSERT INTO channel_search(channel_search,rowid,name,category)
                VALUES('delete',old.rowid,old.name,old.category);
            END;
            """)
        Self.hardenFiles(in: root)
    }

    /// Protection is set on the directory, and again on each SQLite file once it exists, so the
    /// database, WAL and SHM never rely on class inheritance alone.
    static func hardenFiles(in root: URL) {
        #if os(iOS)
        for name in ["channels.sqlite", "channels.sqlite-wal", "channels.sqlite-shm"] {
            var url = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                   ofItemAtPath: url.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        #endif
    }

    deinit { if let database { sqlite3_close(database) } }
    func close() { if let database { sqlite3_close(database) }; database = nil }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.storage }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.storage
        }
        return statement
    }
    private func bind(_ text: String?, _ index: Int32, _ statement: OpaquePointer) {
        if let text { sqlite3_bind_text(statement, index, text, -1, Self.transient) }
        else { sqlite3_bind_null(statement, index) }
    }

    /// The caller assigns contiguous source ordinals before batching. Parsers must deduplicate
    /// IDs first; ignored duplicates leave ordinal gaps and make promotion fail safely.
    func stage(_ channels: [LiveTVChannel], providerID: UUID, generation: String,
               startingOrdinal: Int) throws -> Int {
        guard !channels.isEmpty else { return 0 }
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("""
                INSERT OR IGNORE INTO channel_items
                  (provider,generation,ordinal,id,guide_id,name,category,stream_url,logo_url,stream_id)
                VALUES(?,?,?,?,?,?,?,?,?,?)
                """)
            defer { sqlite3_finalize(statement) }
            var inserted = 0
            for (offset, channel) in channels.enumerated() {
                if offset.isMultiple(of: 256) { try Task.checkCancellation() }
                guard channel.id.hasPrefix(providerID.uuidString + ":"),
                      ["http", "https"].contains(channel.streamURL.scheme?.lowercased() ?? "") else {
                    throw StoreError.invalidIdentity
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(providerID.uuidString, 1, statement)
                bind(generation, 2, statement)
                sqlite3_bind_int64(statement, 3, sqlite3_int64(startingOrdinal + offset))
                bind(channel.id, 4, statement)
                bind(channel.guideID, 5, statement)
                bind(channel.name, 6, statement)
                bind(channel.category, 7, statement)
                bind(channel.streamURL.absoluteString, 8, statement)
                bind(channel.logoURL?.absoluteString, 9, statement)
                if let streamID = channel.streamID { sqlite3_bind_int64(statement, 10, sqlite3_int64(streamID)) }
                else { sqlite3_bind_null(statement, 10) }
                guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.storage }
                inserted += Int(sqlite3_changes(database))
            }
            try execute("COMMIT")
            return inserted
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Refuses incomplete or non-contiguous imports. Promotion never deletes the old generation
    /// in its transaction; the reader-visible switch stays short even at 100,000 rows.
    func promote(providerID: UUID, generation: String, expectedCount: Int) throws {
        try Task.checkCancellation()
        guard expectedCount > 0 else { throw StoreError.invalidGeneration }
        try execute("BEGIN IMMEDIATE")
        do {
            let check = try prepare("""
                SELECT COUNT(*),MIN(ordinal),MAX(ordinal) FROM channel_items
                WHERE provider=? AND generation=?
                """)
            bind(providerID.uuidString, 1, check)
            bind(generation, 2, check)
            let valid = sqlite3_step(check) == SQLITE_ROW
                && sqlite3_column_int64(check, 0) == expectedCount
                && sqlite3_column_int64(check, 1) == 0
                && sqlite3_column_int64(check, 2) == expectedCount - 1
            sqlite3_finalize(check)
            guard valid else { throw StoreError.invalidGeneration }
            let statement = try prepare("""
                INSERT INTO channel_active(provider,generation,channel_count) VALUES(?,?,?)
                ON CONFLICT(provider) DO UPDATE SET generation=excluded.generation,
                  channel_count=excluded.channel_count
                """)
            bind(providerID.uuidString, 1, statement)
            bind(generation, 2, statement)
            sqlite3_bind_int64(statement, 3, sqlite3_int64(expectedCount))
            let result = sqlite3_step(statement)
            sqlite3_finalize(statement)
            guard result == SQLITE_DONE else { throw StoreError.storage }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func activeGeneration(providerID: UUID) -> String? {
        guard let statement = try? prepare("SELECT generation FROM channel_active WHERE provider=?") else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, 1, statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: raw)
    }

    /// Restores the generation that was active before a source changed during promotion. The old
    /// rows are intentionally retained until the caller performs its post-promotion validation.
    func restoreActiveGeneration(providerID: UUID, generation: String?) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            if let generation {
                let count = try prepare("SELECT COUNT(*) FROM channel_items WHERE provider=? AND generation=?")
                bind(providerID.uuidString, 1, count)
                bind(generation, 2, count)
                guard sqlite3_step(count) == SQLITE_ROW else {
                    sqlite3_finalize(count)
                    throw StoreError.invalidGeneration
                }
                let channelCount = Int(sqlite3_column_int64(count, 0))
                sqlite3_finalize(count)
                guard channelCount > 0 else { throw StoreError.invalidGeneration }
                let statement = try prepare("""
                    INSERT INTO channel_active(provider,generation,channel_count) VALUES(?,?,?)
                    ON CONFLICT(provider) DO UPDATE SET generation=excluded.generation,
                      channel_count=excluded.channel_count
                    """)
                bind(providerID.uuidString, 1, statement)
                bind(generation, 2, statement)
                sqlite3_bind_int64(statement, 3, sqlite3_int64(channelCount))
                let result = sqlite3_step(statement)
                sqlite3_finalize(statement)
                guard result == SQLITE_DONE else { throw StoreError.storage }
            } else {
                let statement = try prepare("DELETE FROM channel_active WHERE provider=?")
                bind(providerID.uuidString, 1, statement)
                let result = sqlite3_step(statement)
                sqlite3_finalize(statement)
                guard result == SQLITE_DONE else { throw StoreError.storage }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func count(providerID: UUID) -> Int {
        guard let statement = try? prepare("SELECT channel_count FROM channel_active WHERE provider=?") else { return 0 }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, 1, statement)
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    /// Count for the same indexed predicate as `page`. UI state can describe the complete
    /// result without materializing it, and pagination can stop after the final bounded page.
    func count(providerID: UUID, query: String, category: String?, favoritesOnly: Bool) -> Int {
        let search = Self.expression(query)
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, search == nil { return 0 }
        let favoriteJoin = favoritesOnly ? " JOIN channel_favorites f ON f.provider=i.provider AND f.id=i.id" : ""
        let categoryFilter = category == nil ? "" : " AND i.category=?"
        let searchFilter = search == nil ? "" : " AND i.rowid IN (SELECT rowid FROM channel_search WHERE channel_search MATCH ?)"
        guard let statement = try? prepare("""
            SELECT COUNT(*) FROM channel_items i JOIN channel_active a
              ON i.provider=a.provider AND i.generation=a.generation
            \(favoriteJoin)
            WHERE i.provider=?\(categoryFilter)\(searchFilter)
            """) else { return 0 }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, 1, statement)
        var next: Int32 = 2
        if let category { bind(category, next, statement); next += 1 }
        if let search { bind(search, next, statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Transitional 40K offline bridge. All pages run in one actor turn, so promotion cannot
    /// splice two generations into one restore. A read transaction also pins a WAL snapshot
    /// against another store connection promoting and pruning. Do not use this for a future
    /// 100K UI catalog.
    func offlineCatalog(providerID: UUID, maximumChannels: Int) -> [LiveTVChannel]? {
        guard (try? execute("BEGIN")) != nil else { return nil }
        defer { try? execute("ROLLBACK") }
        let expected = count(providerID: providerID)
        guard expected > 0, expected <= maximumChannels else { return nil }
        var channels: [LiveTVChannel] = []
        channels.reserveCapacity(expected)
        var offset = 0
        while offset < expected {
            guard !Task.isCancelled else { return nil }
            let batch = page(providerID: providerID, offset: offset, limit: 200)
            guard !batch.isEmpty else { return nil }
            channels.append(contentsOf: batch)
            offset += batch.count
        }
        guard channels.count == expected, (try? execute("COMMIT")) != nil else { return nil }
        return channels
    }

    func setFavorite(_ favorite: Bool, channelID: String, providerID: UUID) throws {
        guard channelID.hasPrefix(providerID.uuidString + ":") else { throw StoreError.invalidIdentity }
        let statement = try prepare(favorite
            ? "INSERT OR IGNORE INTO channel_favorites(provider,id) VALUES(?,?)"
            : "DELETE FROM channel_favorites WHERE provider=? AND id=?")
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, 1, statement)
        bind(channelID, 2, statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.storage }
    }

    /// Reconciles the existing UserDefaults favorites source of truth with the indexed table.
    /// Cancellation rolls back the entire provider replacement; no partial favorite list leaks.
    func replaceFavorites(_ ids: Set<String>, providerID: UUID) throws {
        let prefix = providerID.uuidString + ":"
        guard ids.allSatisfy({ $0.hasPrefix(prefix) }) else { throw StoreError.invalidIdentity }
        try execute("BEGIN IMMEDIATE")
        do {
            let removal = try prepare("DELETE FROM channel_favorites WHERE provider=?")
            bind(providerID.uuidString, 1, removal)
            let removed = sqlite3_step(removal)
            sqlite3_finalize(removal)
            guard removed == SQLITE_DONE else { throw StoreError.storage }
            let insertion = try prepare("INSERT INTO channel_favorites(provider,id) VALUES(?,?)")
            defer { sqlite3_finalize(insertion) }
            for (index, id) in ids.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                sqlite3_reset(insertion)
                sqlite3_clear_bindings(insertion)
                bind(providerID.uuidString, 1, insertion)
                bind(id, 2, insertion)
                guard sqlite3_step(insertion) == SQLITE_DONE else { throw StoreError.storage }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private static func expression(_ query: String) -> String? {
        let terms = query.unicodeScalars.split { !CharacterSet.alphanumerics.contains($0) }
            .map { String(String.UnicodeScalarView($0)) }
        guard !terms.isEmpty else { return nil }
        let bounded = Array(terms.prefix(8))
        // Prefix-expanding a ubiquitous token such as "Channel" traverses its entire posting
        // list even when a later token is selective. Only the trailing, in-progress token needs
        // prefix matching for typeahead; preceding words are exact terms.
        return bounded.enumerated().map { index, term in
            "\"\(term)\"" + (index == bounded.count - 1 ? "*" : "")
        }.joined(separator: " AND ")
    }

    /// Unfiltered pages seek directly to their ordinal; category/favorites pages use their
    /// respective indexes. A supplied `afterOrdinal` supports constant-memory keyset scrolling.
    func page(providerID: UUID, query: String = "", category: String? = nil,
              favoritesOnly: Bool = false, offset: Int = 0, afterOrdinal: Int? = nil,
              limit: Int = 100) -> [LiveTVChannel] {
        let search = Self.expression(query)
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, search == nil { return [] }
        let favoriteJoin = favoritesOnly ? " JOIN channel_favorites f ON f.provider=i.provider AND f.id=i.id" : ""
        let categoryFilter = category == nil ? "" : " AND i.category=?"
        // An ordinary FTS JOIN lets SQLite choose the ordinal index first, then probe the FTS
        // virtual table once per channel (seconds at 100K). The rowid subquery computes the
        // bounded match set once before applying provider/generation and ordinal order.
        let searchFilter = search == nil ? "" : " AND i.rowid IN (SELECT rowid FROM channel_search WHERE channel_search MATCH ?)"
        let ordinalFilter = afterOrdinal == nil && category == nil && search == nil && !favoritesOnly
            ? " AND i.ordinal>=?" : (afterOrdinal == nil ? "" : " AND i.ordinal>?")
        guard let statement = try? prepare("""
            SELECT i.id,i.guide_id,i.name,i.category,i.stream_url,i.logo_url,i.stream_id
            FROM channel_items i JOIN channel_active a
              ON i.provider=a.provider AND i.generation=a.generation
            \(favoriteJoin)
            WHERE i.provider=?\(categoryFilter)\(searchFilter)\(ordinalFilter)
            ORDER BY i.ordinal LIMIT ? OFFSET ?
            """) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, 1, statement)
        var next: Int32 = 2
        if let category { bind(category, next, statement); next += 1 }
        if let search { bind(search, next, statement); next += 1 }
        if let afterOrdinal {
            sqlite3_bind_int64(statement, next, sqlite3_int64(afterOrdinal))
            next += 1
        } else if category == nil && search == nil && !favoritesOnly {
            sqlite3_bind_int64(statement, next, sqlite3_int64(max(0, offset)))
            next += 1
        }
        sqlite3_bind_int(statement, next, Int32(min(max(limit, 1), 200)))
        sqlite3_bind_int(statement, next + 1,
                         Int32(afterOrdinal == nil && (category != nil || search != nil || favoritesOnly) ? max(0, offset) : 0))
        var channels: [LiveTVChannel] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func value(_ column: Int32) -> String? {
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            }
            guard let id = value(0), let name = value(2), let category = value(3),
                  let rawURL = value(4), let streamURL = URL(string: rawURL) else { continue }
            channels.append(LiveTVChannel(id: id, guideID: value(1), name: name, streamURL: streamURL,
                                          logoURL: value(5).flatMap(URL.init(string:)), category: category,
                                          streamID: sqlite3_column_type(statement, 6) == SQLITE_NULL
                                              ? nil : Int(sqlite3_column_int64(statement, 6))))
        }
        return channels
    }

    func channel(providerID: UUID, id: String) -> LiveTVChannel? {
        guard id.hasPrefix(providerID.uuidString + ":") else { return nil }
        guard let statement = try? prepare("""
            SELECT i.guide_id,i.name,i.category,i.stream_url,i.logo_url,i.stream_id
            FROM channel_items i JOIN channel_active a
              ON i.provider=a.provider AND i.generation=a.generation
            WHERE i.provider=? AND i.id=? LIMIT 1
            """) else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, 1, statement)
        bind(id, 2, statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        func value(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        guard let name = value(1), let category = value(2),
              let rawURL = value(3), let streamURL = URL(string: rawURL) else { return nil }
        return LiveTVChannel(id: id, guideID: value(0), name: name, streamURL: streamURL,
                             logoURL: value(4).flatMap(URL.init(string:)), category: category,
                             streamID: sqlite3_column_type(statement, 5) == SQLITE_NULL
                                 ? nil : Int(sqlite3_column_int64(statement, 5)))
    }

    func contains(providerID: UUID, id: String) -> Bool {
        guard id.hasPrefix(providerID.uuidString + ":"), let statement = try? prepare("""
            SELECT 1 FROM channel_items i JOIN channel_active a
              ON i.provider=a.provider AND i.generation=a.generation
            WHERE i.provider=? AND i.id=? LIMIT 1
            """) else { return false }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, 1, statement)
        bind(id, 2, statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Resolves a small identity set without scanning or materializing the catalog. Results retain
    /// caller order, which preserves recently-watched ordering; missing or stale IDs are omitted.
    func channels(providerID: UUID, ids: [String], limit: Int = 200) -> [LiveTVChannel] {
        let bounded = Array(ids.prefix(min(max(limit, 1), 200)))
        guard !bounded.isEmpty else { return [] }
        var resolved: [String: LiveTVChannel] = [:]
        resolved.reserveCapacity(bounded.count)
        for id in bounded {
            if let channel = channel(providerID: providerID, id: id) { resolved[id] = channel }
        }
        return bounded.compactMap { resolved[$0] }
    }

    /// Compact guide association snapshot built directly from SQLite rows. This avoids retaining
    /// stream URLs, artwork URLs, categories, IDs, or full channel values merely to filter XMLTV.
    func epgAssociationValues(providerID: UUID) -> EPGAssociationValues? {
        guard let statement = try? prepare("""
            SELECT i.guide_id,i.name FROM channel_items i JOIN channel_active a
              ON i.provider=a.provider AND i.generation=a.generation
            WHERE i.provider=? ORDER BY i.ordinal
            """) else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, 1, statement)
        var guideIDs: [String?] = []
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guideIDs.append(sqlite3_column_text(statement, 0).map { String(cString: $0) })
            guard let raw = sqlite3_column_text(statement, 1) else { continue }
            names.append(String(cString: raw))
        }
        return names.isEmpty ? nil : EPGAssociationValues(guideIDs: guideIDs, names: names)
    }

    func programAssociations(providerID: UUID) -> [ProgramAssociation] {
        guard let statement = try? prepare("""
            SELECT i.id,i.guide_id,i.name,i.ordinal FROM channel_items i JOIN channel_active a
              ON i.provider=a.provider AND i.generation=a.generation
            WHERE i.provider=? ORDER BY i.ordinal
            """) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, 1, statement)
        var result: [ProgramAssociation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawID = sqlite3_column_text(statement, 0),
                  let rawName = sqlite3_column_text(statement, 2) else { continue }
            result.append(.init(id: String(cString: rawID),
                                guideID: sqlite3_column_text(statement, 1).map { String(cString: $0) },
                                name: String(cString: rawName),
                                ordinal: Int(sqlite3_column_int64(statement, 3))))
        }
        return result
    }

    /// Offset of a stable channel anchor in the same predicate/order used by `page`.
    func offset(providerID: UUID, channelID: String, query: String = "", category: String? = nil,
                favoritesOnly: Bool = false) -> Int? {
        guard channelID.hasPrefix(providerID.uuidString + ":") else { return nil }
        let search = Self.expression(query)
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, search == nil { return nil }
        let favoriteJoin = favoritesOnly ? " JOIN channel_favorites f ON f.provider=i.provider AND f.id=i.id" : ""
        let categoryFilter = category == nil ? "" : " AND i.category=?"
        let searchFilter = search == nil ? "" : " AND i.rowid IN (SELECT rowid FROM channel_search WHERE channel_search MATCH ?)"
        guard let target = try? prepare("""
            SELECT i.ordinal FROM channel_items i JOIN channel_active a
              ON i.provider=a.provider AND i.generation=a.generation
            \(favoriteJoin)
            WHERE i.provider=? AND i.id=?\(categoryFilter)\(searchFilter) LIMIT 1
            """) else { return nil }
        bind(providerID.uuidString, 1, target)
        bind(channelID, 2, target)
        var next: Int32 = 3
        if let category { bind(category, next, target); next += 1 }
        if let search { bind(search, next, target) }
        guard sqlite3_step(target) == SQLITE_ROW else { sqlite3_finalize(target); return nil }
        let ordinal = Int(sqlite3_column_int64(target, 0))
        sqlite3_finalize(target)

        guard let count = try? prepare("""
            SELECT COUNT(*) FROM channel_items i JOIN channel_active a
              ON i.provider=a.provider AND i.generation=a.generation
            \(favoriteJoin)
            WHERE i.provider=? AND i.ordinal<?\(categoryFilter)\(searchFilter)
            """) else { return nil }
        defer { sqlite3_finalize(count) }
        bind(providerID.uuidString, 1, count)
        sqlite3_bind_int64(count, 2, sqlite3_int64(ordinal))
        next = 3
        if let category { bind(category, next, count); next += 1 }
        if let search { bind(search, next, count) }
        return sqlite3_step(count) == SQLITE_ROW ? Int(sqlite3_column_int64(count, 0)) : nil
    }

    /// A guide ID may legitimately map to several provider channels. Keep the lookup bounded
    /// and provider/generation-scoped rather than building a process-wide EPG association map.
    func channelIDs(providerID: UUID, guideID: String, limit: Int = 200) -> [String] {
        guard let statement = try? prepare("""
            SELECT i.id FROM channel_items i JOIN channel_active a
              ON i.provider=a.provider AND i.generation=a.generation
            WHERE i.provider=? AND i.guide_id=? ORDER BY i.ordinal LIMIT ?
            """) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, 1, statement)
        bind(guideID, 2, statement)
        sqlite3_bind_int(statement, 3, Int32(min(max(limit, 1), 200)))
        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 0) { ids.append(String(cString: raw)) }
        }
        return ids
    }

    /// Channels whose normalized guide ID (trimmed, lower-cased: `EPGChannelKey.guideID`) is in
    /// `keys`. Bounded by `limit`; used by Sports matching to retrieve the channels airing an event
    /// that the guide names, which channel-name search cannot find (a game on a generic "ESPN").
    func channels(providerID: UUID, guideKeys: [String], limit: Int = 400) -> [LiveTVChannel] {
        let keys = Array(Set(guideKeys)).prefix(500)
        guard !keys.isEmpty else { return [] }
        var result: [LiveTVChannel] = []
        let bound = min(max(limit, 1), 1_000)
        var start = keys.startIndex
        while start < keys.endIndex, result.count < bound {
            let end = keys.index(start, offsetBy: 100, limitedBy: keys.endIndex) ?? keys.endIndex
            let chunk = Array(keys[start..<end])
            start = end
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            guard let statement = try? prepare("""
                SELECT i.id,i.guide_id,i.name,i.category,i.stream_url,i.logo_url,i.stream_id
                FROM channel_items i JOIN channel_active a
                  ON i.provider=a.provider AND i.generation=a.generation
                WHERE i.provider=? AND lower(trim(i.guide_id)) IN (\(marks))
                ORDER BY i.ordinal LIMIT ?
                """) else { continue }
            defer { sqlite3_finalize(statement) }
            bind(providerID.uuidString, 1, statement)
            for (offset, key) in chunk.enumerated() { bind(key, Int32(offset + 2), statement) }
            sqlite3_bind_int(statement, Int32(chunk.count + 2), Int32(bound - result.count))
            while sqlite3_step(statement) == SQLITE_ROW {
                func value(_ column: Int32) -> String? {
                    sqlite3_column_text(statement, column).map { String(cString: $0) }
                }
                guard let id = value(0), let name = value(2), let category = value(3),
                      let rawURL = value(4), let streamURL = URL(string: rawURL) else { continue }
                result.append(LiveTVChannel(id: id, guideID: value(1), name: name, streamURL: streamURL,
                                            logoURL: value(5).flatMap(URL.init(string:)), category: category,
                                            streamID: sqlite3_column_type(statement, 6) == SQLITE_NULL
                                                ? nil : Int(sqlite3_column_int64(statement, 6))))
            }
        }
        return result
    }

    func categories(providerID: UUID) -> [(name: String, count: Int)] {
        guard let statement = try? prepare("""
            SELECT i.category,COUNT(*),MIN(i.ordinal) FROM channel_items i JOIN channel_active a
              ON i.provider=a.provider AND i.generation=a.generation
            WHERE i.provider=? GROUP BY i.category ORDER BY MIN(i.ordinal)
            """) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, 1, statement)
        var result: [(String, Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 0) {
                result.append((String(cString: raw), Int(sqlite3_column_int64(statement, 1))))
            }
        }
        return result
    }

    /// One bounded row per category, including the first logo in provider order and favorite
    /// counts. The Categories screen never needs to scan the channel catalog in Swift.
    func categorySummaries(providerID: UUID) -> [CategorySummary] {
        guard let statement = try? prepare("""
            WITH grouped AS (
              SELECT i.category AS category, COUNT(*) AS channel_count,
                     SUM(CASE WHEN f.id IS NULL THEN 0 ELSE 1 END) AS favorite_count,
                     MIN(i.ordinal) AS first_ordinal,
                     MIN(CASE WHEN i.logo_url IS NULL THEN NULL ELSE i.ordinal END) AS artwork_ordinal
              FROM channel_items i JOIN channel_active a
                ON i.provider=a.provider AND i.generation=a.generation
              LEFT JOIN channel_favorites f ON f.provider=i.provider AND f.id=i.id
              WHERE i.provider=? GROUP BY i.category
            )
            SELECT g.category,g.channel_count,g.favorite_count,
                   i.id,i.guide_id,i.name,i.stream_url,i.logo_url,i.stream_id
            FROM grouped g
            LEFT JOIN channel_items i ON i.provider=? AND i.generation=(
              SELECT generation FROM channel_active WHERE provider=?
            ) AND i.ordinal=g.artwork_ordinal
            ORDER BY g.first_ordinal
            """) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, 1, statement)
        bind(providerID.uuidString, 2, statement)
        bind(providerID.uuidString, 3, statement)
        var result: [CategorySummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func value(_ column: Int32) -> String? {
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            }
            guard let name = value(0) else { continue }
            var artwork: LiveTVChannel?
            if let id = value(3), let channelName = value(5), let rawURL = value(6),
               let streamURL = URL(string: rawURL) {
                artwork = LiveTVChannel(id: id, guideID: value(4), name: channelName,
                                        streamURL: streamURL, logoURL: value(7).flatMap(URL.init(string:)),
                                        category: name,
                                        streamID: sqlite3_column_type(statement, 8) == SQLITE_NULL
                                            ? nil : Int(sqlite3_column_int64(statement, 8)))
            }
            result.append(CategorySummary(name: name,
                                          channelCount: Int(sqlite3_column_int64(statement, 1)),
                                          favoriteCount: Int(sqlite3_column_int64(statement, 2)),
                                          artworkChannel: artwork))
        }
        return result
    }

    /// Removes only generations not referenced by `channel_active`, including crash orphans.
    /// Each transaction deletes at most 1,024 rows, then yields to reader requests.
    func pruneOrphans() async throws {
        var cursor: sqlite3_int64 = 0
        while true {
            try Task.checkCancellation()
            let selection = try prepare("""
                SELECT i.rowid FROM channel_items i WHERE i.rowid>? AND NOT EXISTS (
                  SELECT 1 FROM channel_active a WHERE a.provider=i.provider
                    AND a.generation=i.generation
                ) ORDER BY i.rowid LIMIT 1024
                """)
            sqlite3_bind_int64(selection, 1, cursor)
            var ids: [sqlite3_int64] = []
            var result = sqlite3_step(selection)
            while result == SQLITE_ROW {
                ids.append(sqlite3_column_int64(selection, 0))
                result = sqlite3_step(selection)
            }
            sqlite3_finalize(selection)
            guard result == SQLITE_DONE else { throw StoreError.storage }
            guard let last = ids.last else { return }
            cursor = last
            try execute("BEGIN IMMEDIATE")
            do {
                let deletion = try prepare("DELETE FROM channel_items WHERE rowid=?")
                defer { sqlite3_finalize(deletion) }
                for id in ids {
                    sqlite3_reset(deletion)
                    sqlite3_bind_int64(deletion, 1, id)
                    guard sqlite3_step(deletion) == SQLITE_DONE else { throw StoreError.storage }
                }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
            await Task.yield()
        }
    }

    func remove(providerID: UUID) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for table in ["channel_active", "channel_favorites", "channel_items"] {
                let statement = try prepare("DELETE FROM \(table) WHERE provider=?")
                bind(providerID.uuidString, 1, statement)
                let result = sqlite3_step(statement)
                sqlite3_finalize(statement)
                guard result == SQLITE_DONE else { throw StoreError.storage }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
#endif
