#if os(iOS) || KYRO_VOD_HOST_TESTS
import Foundation
import SQLite3

// MARK: - Index rows and cursors

/// A position in the unified index. Every row has a unique cursor and the index orders rows by
/// (sortKey, matchKey, entryKey) with SQLite BINARY comparison, so keyset pages never skip or
/// repeat a row and stay valid when rows are inserted or removed elsewhere in the catalog.
struct UnifiedIndexCursor: Hashable, Sendable {
    let sortKey: String
    let matchKey: String
    let entryKey: String
}

/// One playable record from one source, as the unified index returns it. Source identity is
/// never rewritten: Silo rows keep their library and content ID, IPTV rows keep the full
/// provider-qualified `XtreamVODItem`.
struct UnifiedIndexRow: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        /// `payload` is the JSON-encoded Silo `BrowseItem` captured at sync time.
        case silo(libraryID: Int, contentID: String, payload: Data)
        case iptv(XtreamVODItem)
    }

    let cursor: UnifiedIndexCursor
    let title: String
    let year: Int?
    let poster: String?
    let source: Source

    var isSilo: Bool { if case .silo = source { return true } else { return false } }

    /// Silo libraries form one origin: two Silo records with the same title and year are
    /// ambiguous (for example two cuts), exactly as `UnifiedVODCatalog.aggregate` treats them.
    var origin: String {
        switch source {
        case .silo: return "silo"
        case .iptv(let item): return "iptv:\(item.providerID.uuidString)"
        }
    }

    var iptvItem: XtreamVODItem? { if case .iptv(let item) = source { return item } else { return nil } }
}

/// The Silo record for staging: the caller encodes its `BrowseItem` so the store (and its host
/// tests) never depends on the networking models.
struct UnifiedSiloRecord: Sendable {
    let contentID: String
    let title: String
    let year: Int?
    let poster: String?
    let payload: Data
}

/// What one browse grid shows: one media kind, the current Silo identity scope and its visible
/// libraries, and the enabled Xtream providers. An empty list disables that source.
struct UnifiedIndexScope: Hashable, Sendable {
    let kind: XtreamVODKind
    let siloScope: String?
    let siloLibraryIDs: [Int]
    let providerIDs: [UUID]
}

enum UnifiedPageDirection: Sendable {
    /// Rows strictly after the cursor (from the start when nil), ascending.
    case forward(after: UnifiedIndexCursor?)
    /// Rows strictly before the cursor, returned ascending.
    case backward(before: UnifiedIndexCursor)
}

struct UnifiedIndexPage: Sendable {
    let rows: [UnifiedIndexRow]
    /// No row exists beyond this page in its direction (at the time of the read).
    let reachedEdge: Bool
}

// MARK: - Store

extension XtreamVODCatalogStore {
    static let unifiedCatalogSchema = """
        CREATE TABLE IF NOT EXISTS unified_iptv_keys (
          provider TEXT NOT NULL, kind TEXT NOT NULL, generation TEXT NOT NULL, remote_id INTEGER NOT NULL,
          sort_key TEXT NOT NULL, match_key TEXT NOT NULL, entry_key TEXT NOT NULL,
          PRIMARY KEY(provider, kind, generation, remote_id)
        );
        CREATE INDEX IF NOT EXISTS unified_iptv_browse ON unified_iptv_keys(kind, sort_key, match_key, entry_key);
        CREATE TABLE IF NOT EXISTS unified_silo_items (
          scope TEXT NOT NULL, library_id INTEGER NOT NULL, kind TEXT NOT NULL, snapshot TEXT NOT NULL,
          content_id TEXT NOT NULL, title TEXT NOT NULL, year INTEGER, poster TEXT, payload BLOB NOT NULL,
          sort_key TEXT NOT NULL, match_key TEXT NOT NULL, entry_key TEXT NOT NULL,
          PRIMARY KEY(scope, library_id, kind, snapshot, content_id)
        );
        CREATE INDEX IF NOT EXISTS unified_silo_browse ON unified_silo_items(scope, kind, sort_key, match_key, entry_key);
        CREATE TABLE IF NOT EXISTS unified_silo_active (
          scope TEXT NOT NULL, library_id INTEGER NOT NULL, kind TEXT NOT NULL, snapshot TEXT NOT NULL,
          synced_at REAL NOT NULL, item_count INTEGER NOT NULL,
          PRIMARY KEY(scope, library_id, kind)
        );
        """

    // MARK: IPTV keys

    /// Writes the unified keys for one staged (not yet active) generation. The service calls this
    /// before `promote`, so a generation becomes browsable together with its keys and old/new
    /// generations of one provider are never mixed. Runs in one transaction on the store actor.
    func buildUnifiedKeys(providerID: UUID, kind: XtreamVODKind, generation: String) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let clear = try prepare("DELETE FROM unified_iptv_keys WHERE provider=? AND kind=? AND generation=?")
            bind(providerID.uuidString, at: 1, in: clear)
            bind(kind.rawValue, at: 2, in: clear)
            bind(generation, at: 3, in: clear)
            let cleared = sqlite3_step(clear)
            sqlite3_finalize(clear)
            guard cleared == SQLITE_DONE else { throw XtreamVODError.storage }
            let rows = try prepare("SELECT remote_id, title FROM vod_items WHERE provider=? AND kind=? AND generation=?")
            defer { sqlite3_finalize(rows) }
            bind(providerID.uuidString, at: 1, in: rows)
            bind(kind.rawValue, at: 2, in: rows)
            bind(generation, at: 3, in: rows)
            let insert = try prepare("""
                INSERT INTO unified_iptv_keys(provider,kind,generation,remote_id,sort_key,match_key,entry_key)
                VALUES(?,?,?,?,?,?,?)
                """)
            defer { sqlite3_finalize(insert) }
            var processed = 0
            var result = sqlite3_step(rows)
            while result == SQLITE_ROW {
                if processed.isMultiple(of: 1024) { try Task.checkCancellation() }
                processed += 1
                let remoteID = Int(sqlite3_column_int64(rows, 0))
                let title = sqlite3_column_text(rows, 1).map { String(cString: $0) } ?? ""
                let year = XtreamVODTitle.year(in: title)
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
                bind(providerID.uuidString, at: 1, in: insert)
                bind(kind.rawValue, at: 2, in: insert)
                bind(generation, at: 3, in: insert)
                sqlite3_bind_int64(insert, 4, sqlite3_int64(remoteID))
                bind(UnifiedCatalogKeys.sortKey(title: title, year: year), at: 5, in: insert)
                bind(UnifiedCatalogKeys.matchKey(title: title, year: year), at: 6, in: insert)
                bind(UnifiedCatalogKeys.iptvEntryKey(providerID: providerID, remoteID: remoteID), at: 7, in: insert)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw XtreamVODError.storage }
                result = sqlite3_step(rows)
            }
            guard result == SQLITE_DONE else { throw XtreamVODError.storage }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Active generations imported before Build 110 have no keys. Builds them once, one
    /// generation per transaction; returns how many generations were indexed.
    @discardableResult
    func ensureUnifiedKeys() throws -> Int {
        let missing = try prepare("""
            SELECT a.provider, a.kind, a.generation FROM vod_active a WHERE NOT EXISTS (
              SELECT 1 FROM unified_iptv_keys k
              WHERE k.provider=a.provider AND k.kind=a.kind AND k.generation=a.generation
            )
            """)
        var targets: [(UUID, XtreamVODKind, String)] = []
        while sqlite3_step(missing) == SQLITE_ROW {
            guard let provider = sqlite3_column_text(missing, 0).flatMap({ UUID(uuidString: String(cString: $0)) }),
                  let kind = sqlite3_column_text(missing, 1).flatMap({ XtreamVODKind(rawValue: String(cString: $0)) }),
                  let generation = sqlite3_column_text(missing, 2).map({ String(cString: $0) }) else { continue }
            targets.append((provider, kind, generation))
        }
        sqlite3_finalize(missing)
        for (provider, kind, generation) in targets {
            try buildUnifiedKeys(providerID: provider, kind: kind, generation: generation)
        }
        return targets.count
    }

    // MARK: Silo snapshots

    /// Adds one page to a snapshot that is not yet visible. Browsing reads only the snapshot
    /// recorded in `unified_silo_active`, so a partial sync is never published.
    func stageSilo(_ records: [UnifiedSiloRecord], scope: String, libraryID: Int, kind: XtreamVODKind,
                   snapshot: String) throws {
        guard !records.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("""
                INSERT INTO unified_silo_items(scope,library_id,kind,snapshot,content_id,title,year,poster,payload,sort_key,match_key,entry_key)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(scope,library_id,kind,snapshot,content_id) DO UPDATE SET
                  title=excluded.title, year=excluded.year, poster=excluded.poster, payload=excluded.payload,
                  sort_key=excluded.sort_key, match_key=excluded.match_key
                """)
            defer { sqlite3_finalize(statement) }
            for record in records {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(scope, at: 1, in: statement)
                sqlite3_bind_int64(statement, 2, sqlite3_int64(libraryID))
                bind(kind.rawValue, at: 3, in: statement)
                bind(snapshot, at: 4, in: statement)
                bind(record.contentID, at: 5, in: statement)
                bind(record.title, at: 6, in: statement)
                if let year = record.year { sqlite3_bind_int64(statement, 7, sqlite3_int64(year)) }
                else { sqlite3_bind_null(statement, 7) }
                bind(record.poster, at: 8, in: statement)
                _ = record.payload.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, 9, bytes.baseAddress, Int32(bytes.count), Self.transient)
                }
                bind(UnifiedCatalogKeys.sortKey(title: record.title, year: record.year), at: 10, in: statement)
                bind(UnifiedCatalogKeys.matchKey(title: record.title, year: record.year), at: 11, in: statement)
                bind(UnifiedCatalogKeys.siloEntryKey(libraryID: libraryID, contentID: record.contentID), at: 12, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw XtreamVODError.storage }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Makes a completed snapshot visible and deletes every other snapshot of that library in the
    /// same transaction: obsolete titles disappear only after a replacement finished.
    func promoteSilo(scope: String, libraryID: Int, kind: XtreamVODKind, snapshot: String,
                     itemCount: Int, syncedAt: Date) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let activate = try prepare("""
                INSERT OR REPLACE INTO unified_silo_active(scope,library_id,kind,snapshot,synced_at,item_count)
                VALUES(?,?,?,?,?,?)
                """)
            bind(scope, at: 1, in: activate)
            sqlite3_bind_int64(activate, 2, sqlite3_int64(libraryID))
            bind(kind.rawValue, at: 3, in: activate)
            bind(snapshot, at: 4, in: activate)
            sqlite3_bind_double(activate, 5, syncedAt.timeIntervalSince1970)
            sqlite3_bind_int64(activate, 6, sqlite3_int64(itemCount))
            let activated = sqlite3_step(activate)
            sqlite3_finalize(activate)
            guard activated == SQLITE_DONE else { throw XtreamVODError.storage }
            let retire = try prepare("DELETE FROM unified_silo_items WHERE scope=? AND library_id=? AND kind=? AND snapshot<>?")
            bind(scope, at: 1, in: retire)
            sqlite3_bind_int64(retire, 2, sqlite3_int64(libraryID))
            bind(kind.rawValue, at: 3, in: retire)
            bind(snapshot, at: 4, in: retire)
            let retired = sqlite3_step(retire)
            sqlite3_finalize(retire)
            guard retired == SQLITE_DONE else { throw XtreamVODError.storage }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Drops an unfinished snapshot. Never touches the active one.
    func discardSilo(scope: String, libraryID: Int, kind: XtreamVODKind, snapshot: String) {
        guard let statement = try? prepare("""
            DELETE FROM unified_silo_items WHERE scope=? AND library_id=? AND kind=? AND snapshot=?
              AND NOT EXISTS (SELECT 1 FROM unified_silo_active a WHERE a.scope=? AND a.library_id=?
                AND a.kind=? AND a.snapshot=?)
            """) else { return }
        defer { sqlite3_finalize(statement) }
        for offset in [Int32(0), 4] {
            bind(scope, at: 1 + offset, in: statement)
            sqlite3_bind_int64(statement, 2 + offset, sqlite3_int64(libraryID))
            bind(kind.rawValue, at: 3 + offset, in: statement)
            bind(snapshot, at: 4 + offset, in: statement)
        }
        sqlite3_step(statement)
    }

    /// When the last completed sync of a library finished, or nil when it has never completed.
    func siloSyncedAt(scope: String, libraryID: Int, kind: XtreamVODKind) -> Date? {
        guard let statement = try? prepare("""
            SELECT synced_at FROM unified_silo_active WHERE scope=? AND library_id=? AND kind=?
            """) else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(scope, at: 1, in: statement)
        sqlite3_bind_int64(statement, 2, sqlite3_int64(libraryID))
        bind(kind.rawValue, at: 3, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    /// Removes every mirrored Silo title outside `keepingScope` (all of them when nil): another
    /// profile's or server's catalog never stays on disk once the identity changed.
    func purgeSilo(keepingScope: String?) throws {
        for table in ["unified_silo_active", "unified_silo_items"] {
            let statement = try prepare(keepingScope == nil
                ? "DELETE FROM \(table)"
                : "DELETE FROM \(table) WHERE scope<>?")
            if let keepingScope { bind(keepingScope, at: 1, in: statement) }
            let result = sqlite3_step(statement)
            sqlite3_finalize(statement)
            guard result == SQLITE_DONE else { throw XtreamVODError.storage }
        }
    }

    /// Libraries this profile can no longer see are removed rather than hidden.
    func retainSiloLibraries(scope: String, kind: XtreamVODKind, libraryIDs: [Int]) throws {
        let list = libraryIDs.map(String.init).joined(separator: ",")
        let filter = list.isEmpty ? "" : " AND library_id NOT IN (\(list))"
        for table in ["unified_silo_active", "unified_silo_items"] {
            let statement = try prepare("DELETE FROM \(table) WHERE scope=? AND kind=?\(filter)")
            bind(scope, at: 1, in: statement)
            bind(kind.rawValue, at: 2, in: statement)
            let result = sqlite3_step(statement)
            sqlite3_finalize(statement)
            guard result == SQLITE_DONE else { throw XtreamVODError.storage }
        }
    }

    /// Stored rows (every scope, snapshot and generation), for diagnostics, tests and benchmarks.
    func unifiedRowCounts() -> (siloItems: Int, siloActive: Int, iptvKeys: Int) {
        func count(_ table: String) -> Int {
            guard let statement = try? prepare("SELECT COUNT(*) FROM \(table)") else { return -1 }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : -1
        }
        return (count("unified_silo_items"), count("unified_silo_active"), count("unified_iptv_keys"))
    }

    // MARK: Paging

    /// One keyset page, with the boundary match group completed so a page never splits a group
    /// (every member of a group shares its sort and match keys, so members are contiguous).
    func unifiedPage(_ scope: UnifiedIndexScope, direction: UnifiedPageDirection,
                     limit: Int = 100) -> UnifiedIndexPage {
        let limit = min(max(limit, 1), 500)
        let first = unifiedRows(scope, direction: direction, limit: limit)
        var rows = first
        // `rows` is ascending; the boundary to complete is the far end in the read direction.
        while true {
            switch direction {
            case .forward:
                guard let last = rows.last, !last.cursor.matchKey.isEmpty else { return .init(rows: rows, reachedEdge: first.count < limit) }
                let more = unifiedRows(scope, direction: .forward(after: last.cursor), limit: 32)
                let same = more.prefix { $0.cursor.sortKey == last.cursor.sortKey && $0.cursor.matchKey == last.cursor.matchKey }
                rows.append(contentsOf: same)
                if same.count < more.count || more.count < 32 { return .init(rows: rows, reachedEdge: first.count < limit && more.isEmpty) }
            case .backward:
                guard let head = rows.first, !head.cursor.matchKey.isEmpty else { return .init(rows: rows, reachedEdge: first.count < limit) }
                let more = unifiedRows(scope, direction: .backward(before: head.cursor), limit: 32)
                let same = more.reversed().prefix { $0.cursor.sortKey == head.cursor.sortKey && $0.cursor.matchKey == head.cursor.matchKey }
                rows.insert(contentsOf: same.reversed(), at: 0)
                if same.count < more.count || more.count < 32 { return .init(rows: rows, reachedEdge: first.count < limit && more.isEmpty) }
            }
        }
    }

    /// Raw keyset read across both sources. Each arm walks its own covering browse index and is
    /// bounded by `limit`; SQLite orders the at most 2×limit candidates. Only the active Silo
    /// snapshot of the current scope and only active IPTV generations are visible.
    func unifiedRows(_ scope: UnifiedIndexScope, direction: UnifiedPageDirection, limit: Int) -> [UnifiedIndexRow] {
        let includeSilo = scope.siloScope != nil && !scope.siloLibraryIDs.isEmpty
        let includeIPTV = !scope.providerIDs.isEmpty
        guard includeSilo || includeIPTV else { return [] }
        let cursor: UnifiedIndexCursor?
        let comparison: String
        let order: String
        switch direction {
        case .forward(let after): cursor = after; comparison = ">"; order = "ASC"
        case .backward(let before): cursor = before; comparison = "<"; order = "DESC"
        }
        func keyset(_ alias: String) -> String {
            cursor == nil ? "" : " AND (\(alias).sort_key,\(alias).match_key,\(alias).entry_key) \(comparison) (?,?,?)"
        }
        func ordering(_ prefix: String) -> String {
            "\(prefix)sort_key \(order), \(prefix)match_key \(order), \(prefix)entry_key \(order)"
        }
        let libraries = scope.siloLibraryIDs.map(String.init).joined(separator: ",")
        let providers = scope.providerIDs.map { "'\($0.uuidString)'" }.joined(separator: ",")
        var arms: [String] = []
        if includeSilo {
            arms.append("""
                SELECT * FROM (SELECT s.sort_key AS sort_key, s.match_key AS match_key, s.entry_key AS entry_key,
                  0 AS origin, s.content_id AS record, s.library_id AS owner, s.title AS title, s.year AS year,
                  s.poster AS poster, s.payload AS payload, NULL AS category, NULL AS ext, NULL AS summary,
                  NULL AS genre, NULL AS rating
                FROM unified_silo_items s JOIN unified_silo_active a
                  ON a.scope=s.scope AND a.library_id=s.library_id AND a.kind=s.kind AND a.snapshot=s.snapshot
                WHERE s.scope=?1 AND s.kind=?2 AND s.library_id IN (\(libraries))\(keyset("s"))
                ORDER BY \(ordering("s.")) LIMIT ?3)
                """)
        }
        if includeIPTV {
            arms.append("""
                SELECT * FROM (SELECT k.sort_key AS sort_key, k.match_key AS match_key, k.entry_key AS entry_key,
                  1 AS origin, i.remote_id AS record, k.provider AS owner, i.title AS title, NULL AS year,
                  i.poster AS poster, NULL AS payload, i.category AS category, i.ext AS ext, i.summary AS summary,
                  i.genre AS genre, i.rating AS rating
                FROM unified_iptv_keys k JOIN vod_active a
                  ON a.provider=k.provider AND a.kind=k.kind AND a.generation=k.generation
                JOIN vod_items i ON i.provider=k.provider AND i.kind=k.kind AND i.generation=k.generation
                  AND i.remote_id=k.remote_id
                WHERE k.kind=?2 AND k.provider IN (\(providers))\(keyset("k"))
                ORDER BY \(ordering("k.")) LIMIT ?3)
                """)
        }
        // Each arm binds the keyset at ?4..?6 (named reuse keeps the arms' parameters identical).
        let sql = arms.joined(separator: " UNION ALL ").replacingOccurrences(of: "(?,?,?)", with: "(?4,?5,?6)")
            + " ORDER BY \(ordering("")) LIMIT ?3"
        guard let statement = try? prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(scope.siloScope ?? "", at: 1, in: statement)
        bind(scope.kind.rawValue, at: 2, in: statement)
        sqlite3_bind_int(statement, 3, Int32(limit))
        if let cursor {
            bind(cursor.sortKey, at: 4, in: statement)
            bind(cursor.matchKey, at: 5, in: statement)
            bind(cursor.entryKey, at: 6, in: statement)
        }
        func text(_ index: Int32) -> String? {
            sqlite3_column_text(statement, index).map { String(cString: $0) }
        }
        var rows: [UnifiedIndexRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let rowCursor = UnifiedIndexCursor(sortKey: text(0) ?? "", matchKey: text(1) ?? "", entryKey: text(2) ?? "")
            let title = text(6) ?? "Untitled"
            if sqlite3_column_int(statement, 3) == 0 {
                let bytes = sqlite3_column_blob(statement, 9)
                let count = Int(sqlite3_column_bytes(statement, 9))
                let payload = bytes.map { Data(bytes: $0, count: count) } ?? Data()
                let year = sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 7))
                rows.append(.init(cursor: rowCursor, title: title, year: year, poster: text(8),
                                  source: .silo(libraryID: Int(sqlite3_column_int64(statement, 5)),
                                                contentID: text(4) ?? "", payload: payload)))
            } else {
                guard let provider = text(5).flatMap(UUID.init(uuidString:)) else { continue }
                let item = XtreamVODItem(providerID: provider, kind: scope.kind,
                                         remoteID: Int(sqlite3_column_int64(statement, 4)), title: title,
                                         category: text(10) ?? "Other", poster: text(8), fileExtension: text(11),
                                         summary: text(12), genre: text(13), rating: text(14))
                rows.append(.init(cursor: rowCursor, title: title, year: XtreamVODTitle.year(in: title),
                                  poster: text(8), source: .iptv(item)))
            }
        }
        if case .backward = direction { rows.reverse() }
        return rows
    }
}

// MARK: - Cards

/// One poster in the unified grid: a confident match of several sources, or a single record.
struct UnifiedCatalogCard: Identifiable, Hashable, Sendable {
    let id: String
    /// Silo first, then IPTV in provider order. Never empty.
    let members: [UnifiedIndexRow]
    /// Index-order extremes of the members, used as keyset cursors.
    let firstCursor: UnifiedIndexCursor
    let lastCursor: UnifiedIndexCursor

    var primary: UnifiedIndexRow { members[0] }
    var title: String { primary.title }
    var year: Int? { members.lazy.compactMap(\.year).first }
    var poster: String? { members.lazy.compactMap(\.poster).first { !$0.isEmpty } }
    var iptvItems: [XtreamVODItem] { members.compactMap(\.iptvItem) }
    var hasSilo: Bool { primary.isSilo }
    /// Cards that came from one match group share it; a single unmatched record has none.
    var groupKey: String? {
        firstCursor.matchKey.isEmpty ? nil : firstCursor.sortKey + "\u{0}" + firstCursor.matchKey
    }
}

enum UnifiedCatalogGrouping {
    /// Groups ascending, group-complete rows into cards. A match group merges only when every
    /// member comes from a different origin (one Silo record at most, one per IPTV provider);
    /// otherwise every member stays its own card, as `UnifiedVODCatalog.aggregate` does.
    static func cards(from rows: [UnifiedIndexRow]) -> [UnifiedCatalogCard] {
        var cards: [UnifiedCatalogCard] = []
        var index = rows.startIndex
        while index < rows.endIndex {
            let row = rows[index]
            var end = index + 1
            if !row.cursor.matchKey.isEmpty {
                while end < rows.endIndex, rows[end].cursor.sortKey == row.cursor.sortKey,
                      rows[end].cursor.matchKey == row.cursor.matchKey { end += 1 }
            }
            let group = Array(rows[index..<end])
            if group.count > 1, Set(group.map(\.origin)).count == group.count {
                let members = group.filter(\.isSilo) + group.filter { !$0.isSilo }
                cards.append(.init(id: "m:" + row.cursor.matchKey, members: members,
                                   firstCursor: group[0].cursor, lastCursor: group[group.count - 1].cursor))
            } else {
                for member in group {
                    cards.append(.init(id: "e:" + member.cursor.entryKey, members: [member],
                                       firstCursor: member.cursor, lastCursor: member.cursor))
                }
            }
            index = end
        }
        return cards
    }
}

// MARK: - Detail routing

/// Which existing detail a unified card opens, with every other source it carries. Silo is the
/// primary page whenever the card has a Silo record; otherwise the first IPTV source is.
/// Sources are only ever added to `alternates`, never dropped.
enum UnifiedDetailTarget: Equatable {
    case silo(contentID: String, libraryID: Int, payload: Data, alternates: [XtreamVODItem])
    case iptv(XtreamVODItem, alternates: [XtreamVODItem])

    init(card: UnifiedCatalogCard) {
        let iptv = card.iptvItems
        if case let .silo(libraryID, contentID, payload) = card.primary.source {
            self = .silo(contentID: contentID, libraryID: libraryID, payload: payload, alternates: iptv)
        } else {
            self = .iptv(iptv[0], alternates: Array(iptv.dropFirst()))
        }
    }
}

// MARK: - Bounded window

/// The cards the grid holds: a contiguous, group-complete slice of the index, at most
/// `maximumCards` long. Trimmed ends stay reachable through `hasMoreBefore`/`hasMoreAfter`;
/// the boundary group is always re-read, so a group that changed since it was loaded heals.
struct UnifiedCatalogWindow: Equatable {
    static let pageSize = 100
    static let maximumCards = 600

    private(set) var cards: [UnifiedCatalogCard] = []
    private(set) var hasMoreBefore = false
    private(set) var hasMoreAfter = false
    var maximumCards = UnifiedCatalogWindow.maximumCards
    /// The grid's column count. Trims and backward pages change the window's head by whole rows
    /// so the rows already on screen never reflow; cards held back are re-read on the next page.
    var rowGranularity = 1

    /// A boundary group at least this large is not re-read, so an extreme duplicate run can never
    /// stall paging by re-reading itself (it is passed by its last cursor instead).
    static let maximumRereadRows = 50

    /// Where the next forward read starts. A boundary match group is re-read from its start.
    var forwardCursor: UnifiedIndexCursor? {
        guard let last = cards.last else { return nil }
        if let key = last.groupKey,
           cards.reversed().prefix(while: { $0.groupKey == key }).reduce(0, { $0 + $1.members.count }) < Self.maximumRereadRows {
            return .init(sortKey: last.firstCursor.sortKey, matchKey: last.firstCursor.matchKey, entryKey: "")
        }
        return last.lastCursor
    }

    /// Where the next backward read starts; "~" sorts after every "i:"/"s:" entry key.
    var backwardCursor: UnifiedIndexCursor? {
        guard let first = cards.first else { return nil }
        if let key = first.groupKey,
           cards.prefix(while: { $0.groupKey == key }).reduce(0, { $0 + $1.members.count }) < Self.maximumRereadRows {
            return .init(sortKey: first.firstCursor.sortKey, matchKey: first.firstCursor.matchKey, entryKey: "~")
        }
        return first.firstCursor
    }

    private func rereadsForward() -> Bool {
        guard let last = cards.last, let cursor = forwardCursor else { return false }
        return cursor != last.lastCursor
    }

    private func rereadsBackward() -> Bool {
        guard let first = cards.first, let cursor = backwardCursor else { return false }
        return cursor != first.firstCursor
    }

    mutating func replace(with page: UnifiedIndexPage, hasMoreBefore: Bool) {
        cards = UnifiedCatalogGrouping.cards(from: page.rows)
        self.hasMoreBefore = hasMoreBefore
        hasMoreAfter = !page.reachedEdge
        trimFront()
    }

    mutating func appendForward(_ page: UnifiedIndexPage) {
        let incoming = UnifiedCatalogGrouping.cards(from: page.rows)
        if rereadsForward(), let key = cards.last?.groupKey {
            while cards.last?.groupKey == key { cards.removeLast() }
        }
        var known = Set(cards.map(\.id))
        cards.append(contentsOf: incoming.filter { known.insert($0.id).inserted })
        hasMoreAfter = !page.reachedEdge
        trimFront()
    }

    mutating func prependBackward(_ page: UnifiedIndexPage) {
        let incoming = UnifiedCatalogGrouping.cards(from: page.rows)
        var removed = 0
        if rereadsBackward(), let key = cards.first?.groupKey {
            while cards.first?.groupKey == key { cards.removeFirst(); removed += 1 }
        }
        var known = Set(cards.map(\.id))
        var added = incoming.filter { known.insert($0.id).inserted }
        let granularity = max(rowGranularity, 1)
        // Short of the catalog start, shift the kept cards by whole rows only. The held-back
        // cards precede everything kept, so the next backward read (from the new first card)
        // returns them; the re-read boundary group sits at the end of `added` and is never held.
        let excess = ((added.count - removed) % granularity + granularity) % granularity
        if !page.reachedEdge, excess > 0, added.count - excess >= removed, added.count - excess > 0 {
            added.removeFirst(excess)
        }
        cards.insert(contentsOf: added, at: 0)
        hasMoreBefore = !page.reachedEdge || added.count < incoming.count
        if cards.count > maximumCards {
            cards.removeLast(cards.count - maximumCards)
            hasMoreAfter = true
        }
    }

    private mutating func trimFront() {
        guard cards.count > maximumCards else { return }
        let granularity = max(rowGranularity, 1)
        let excess = cards.count - maximumCards
        let rows = (excess + granularity - 1) / granularity
        cards.removeFirst(min(rows * granularity, cards.count - 1))
        hasMoreBefore = true
    }
}
#endif
