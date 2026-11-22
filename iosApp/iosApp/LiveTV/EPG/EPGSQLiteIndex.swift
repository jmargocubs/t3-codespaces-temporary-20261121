import Foundation
import SQLite3

/// How a query behaves when a channel's listings are not in the resident window.
enum EPGSQLiteReadPolicy: Sendable, Equatable {
    /// Never touch disk: an unloaded channel reads as empty until `prefetch` has loaded it. This is
    /// what the app uses, so guide scrolling and channel switching never wait on SQLite.
    case cachedOnly
    /// Load the channel from disk on a miss. For background actors, tests and benchmarks.
    case readThrough
}

/// An open, finished guide file plus a bounded resident window of channel listings.
///
/// The file is immutable once built, so one read-only connection can serve every reader. Disk reads
/// happen only in `loadFromDisk` and `prefetch`; both take the connection lock, never the window lock
/// for the duration of a read, so a resident lookup on the main actor is never blocked by a disk read.
final class EPGSQLiteGuide: @unchecked Sendable {
    let url: URL
    let metadata: EPGSQLiteMetadata
    /// Channels that have listings. Kept in memory so `channelKey` never needs the database.
    let channelKeys: Set<String>
    let names: [String: String]
    let id = UUID()
    /// Builder-owned files are deleted only after the last connection closes, if publication fails.
    private let fileStateLock = NSLock()
    private var deletesFileOnRelease = false

    static let defaultResidentChannels = 768
    static let defaultResidentPrograms = 24_000

    private let connection: EPGSQLiteConnection
    private let lock = NSLock()
    private var resident: [String: (list: [EPGProgram], tick: UInt64)] = [:]
    private var residentPrograms = 0
    private var tick: UInt64 = 0
    private let maximumChannels: Int
    private let maximumPrograms: Int

    fileprivate init(url: URL, connection: EPGSQLiteConnection, metadata: EPGSQLiteMetadata,
                     channelKeys: Set<String>, names: [String: String],
                     maximumChannels: Int, maximumPrograms: Int) {
        self.url = url
        self.connection = connection
        self.metadata = metadata
        self.channelKeys = channelKeys
        self.names = names
        self.maximumChannels = maximumChannels
        self.maximumPrograms = maximumPrograms
        EPGSQLiteFileLeases.acquire(url)
    }

    /// Opens a promoted guide and trusts it only when it carries this provider's identity and source
    /// fingerprint. Cheap structural checks run here; the full integrity check runs after a build.
    /// A rejected file is left in place, exactly like a rejected v2 cache.
    static func open(_ url: URL, providerID: UUID, fingerprint: Data?,
                     maximumChannels: Int = defaultResidentChannels,
                     maximumPrograms: Int = defaultResidentPrograms) throws -> EPGSQLiteGuide {
        let connection = try EPGSQLiteConnection.openReadOnly(url)
        do {
            return try connection.withHandle { db in
                let metadata = try EPGSQLiteMetadata.read(from: db)
                guard metadata.providerID == providerID,
                      fingerprint == nil || metadata.sourceFingerprint == fingerprint else {
                    throw EPGSQLiteError.mismatchedIdentity
                }
                var keys = Set<String>()
                keys.reserveCapacity(metadata.channelCount)
                var total = 0
                let channels = try EPGSQLiteStatement(db, "SELECT channel_key, program_count FROM channels")
                defer { channels.finalize() }
                while try channels.step() {
                    guard let key = channels.text(0) else { throw EPGSQLiteError.corrupt }
                    keys.insert(key)
                    total += Int(channels.int64(1))
                }
                guard keys.count == metadata.channelCount, total == metadata.programCount else {
                    throw EPGSQLiteError.corrupt
                }
                var names: [String: String] = [:]
                let rows = try EPGSQLiteStatement(db, "SELECT name_key, channel_key FROM names")
                defer { rows.finalize() }
                while try rows.step() {
                    guard let name = rows.text(0), let key = rows.text(1), keys.contains(key) else {
                        throw EPGSQLiteError.corrupt
                    }
                    names[name] = key
                }
                return EPGSQLiteGuide(url: url, connection: connection, metadata: metadata, channelKeys: keys,
                                      names: names, maximumChannels: maximumChannels,
                                      maximumPrograms: maximumPrograms)
            }
        } catch {
            connection.close()
            throw error
        }
    }

    deinit {
        connection.close()
        let shouldDelete = fileStateLock.withLock { deletesFileOnRelease }
        EPGSQLiteFileLeases.release(url)
        if shouldDelete { try? FileManager.default.removeItem(at: url) }
    }

    func markPublished() { fileStateLock.withLock { deletesFileOnRelease = false } }
    fileprivate func markUnpublished() { fileStateLock.withLock { deletesFileOnRelease = true } }

    var residentChannelCount: Int { lock.withLock { resident.count } }

    /// Resident listings, or nil when the channel is not loaded. Never reads disk.
    func residentList(_ key: String) -> [EPGProgram]? {
        lock.withLock {
            guard var entry = resident[key] else { return nil }
            tick &+= 1
            entry.tick = tick
            resident[key] = entry
            return entry.list
        }
    }

    func isResident(_ key: String) -> Bool { lock.withLock { resident[key] != nil } }

    /// One channel's normalized listings, read from disk without touching the resident window.
    func loadFromDisk(_ key: String) -> [EPGProgram] {
        guard channelKeys.contains(key) else { return [] }
        return (try? connection.withHandle { db in
            let statement = try EPGSQLiteStatement(db, EPGSQLiteSchema.selectChannel)
            defer { statement.finalize() }
            return try Self.readChannel(statement, key: key)
        }) ?? []
    }

    /// Loads channels into the resident window. Call it from a background task.
    func prefetch(_ keys: [String]) {
        let wanted = keys.filter { channelKeys.contains($0) && !isResident($0) }
        guard !wanted.isEmpty else { return }
        let loaded: [(String, [EPGProgram])] = (try? connection.withHandle { db in
            let statement = try EPGSQLiteStatement(db, EPGSQLiteSchema.selectChannel)
            defer { statement.finalize() }
            return try wanted.map { key in
                statement.reset()
                return (key, try Self.readChannel(statement, key: key))
            }
        }) ?? []
        lock.withLock {
            for (key, list) in loaded where resident[key] == nil {
                tick &+= 1
                resident[key] = (list, tick)
                residentPrograms += list.count
            }
            evictIfNeeded()
        }
    }

    /// The latest programme end among channels not in `excluded`. `excluded` is bounded by the
    /// short-guide overlay retention, so the scan reads at most that many extra rows.
    func coverageEnd(excluding excluded: Set<String>) -> Date? {
        try? connection.withHandle { db in
            let statement = try EPGSQLiteStatement(
                db, "SELECT channel_key, last_end FROM channels ORDER BY last_end DESC LIMIT ?1")
            defer { statement.finalize() }
            statement.bind(1, Int64(excluded.count + 1))
            while try statement.step() {
                if let key = statement.text(0), !excluded.contains(key) {
                    return Date(timeIntervalSinceReferenceDate: statement.double(1))
                }
            }
            return nil
        }
    }

    private func evictIfNeeded() {
        guard resident.count > maximumChannels || residentPrograms > maximumPrograms else { return }
        // Drop the least recently used quarter so eviction cost is amortized across many inserts.
        let ordered = resident.sorted { $0.value.tick < $1.value.tick }
        var index = 0
        while index < ordered.count,
              resident.count > maximumChannels * 3 / 4 || residentPrograms > maximumPrograms * 3 / 4 {
            let victim = ordered[index]
            resident[victim.key] = nil
            residentPrograms -= victim.value.list.count
            index += 1
        }
    }

    /// Programmes overlapping `interval` on any channel whose title, subtitle or summary opening
    /// contains one of `anchors` (ASCII case-insensitive `LIKE`). One bounded query for event
    /// matching: it never touches the resident window and returns at most `limit` rows.
    /// `anchors` must be plain letter/number words, so they carry no `LIKE` wildcards.
    func windowPrograms(overlapping interval: DateInterval, anchors: [String], limit: Int) -> [(key: String, program: EPGProgram)] {
        windowRows(overlapping: interval, anchors: anchors, limit: limit).rows
    }

    /// `windowPrograms` with a deterministic budget. Rows are ordered by distance from the middle
    /// of `interval`, then guide key and start (the same order as the in-memory guide), and
    /// one extra row is read to tell a full budget from a truncated one. Rows that also mention
    /// one of `excluding` are skipped. The `ORDER BY` sorts only rows that already matched.
    func windowRows(overlapping interval: DateInterval, anchors: [String], excluding: [String] = [],
                    limit: Int) -> EPGWindowRows {
        func plain(_ values: [String]) -> [String] {
            Array(values.filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber } }.prefix(16))
        }
        let words = plain(anchors)
        let excluded = plain(excluding)
        guard !words.isEmpty, limit > 0 else { return EPGWindowRows() }
        let first = 5
        let clauses = words.indices.map { offset in
            let parameter = offset + first
            return "title LIKE ?\(parameter) OR subtitle LIKE ?\(parameter) OR substr(summary, 1, 280) LIKE ?\(parameter)"
        }
        // NULL subtitles or summaries must not turn the exclusion into NULL (which drops the row).
        let exclusions = excluded.indices.map { offset in
            let parameter = offset + first + words.count
            return "title LIKE ?\(parameter) OR coalesce(subtitle, '') LIKE ?\(parameter) "
                + "OR coalesce(substr(summary, 1, 280), '') LIKE ?\(parameter)"
        }
        let exclusion = exclusions.isEmpty ? "" : " AND NOT (\(exclusions.joined(separator: " OR ")))"
        let sql = """
        SELECT channel_key, channel_id, start_s, end_s, title, subtitle, summary, category, episode
        FROM programmes WHERE start_s < ?1 AND end_s > ?2 AND (\(clauses.joined(separator: " OR ")))\(exclusion)
        ORDER BY abs(start_s - ?3), channel_key, start_s LIMIT ?4
        """
        let center = interval.start.addingTimeInterval(interval.duration / 2)
        let read = try? connection.withHandle { db -> EPGWindowRows in
            let statement = try EPGSQLiteStatement(db, sql)
            defer { statement.finalize() }
            statement.bind(1, interval.end.timeIntervalSinceReferenceDate)
            statement.bind(2, interval.start.timeIntervalSinceReferenceDate)
            statement.bind(3, center.timeIntervalSinceReferenceDate)
            statement.bind(4, Int64(limit) + 1)
            for (offset, word) in (words + excluded).enumerated() { statement.bind(Int32(offset + first), "%\(word)%") }
            var window = EPGWindowRows()
            while try statement.step() {
                if window.rows.count.isMultiple(of: 256), Task.isCancelled { return EPGWindowRows(cancelled: true) }
                guard let key = statement.text(0) else { continue }
                guard window.rows.count < limit else {
                    window.truncated = true
                    break
                }
                window.rows.append((key, EPGProgram(
                    channelID: statement.text(1) ?? key,
                    start: Date(timeIntervalSinceReferenceDate: statement.double(2)),
                    end: Date(timeIntervalSinceReferenceDate: statement.double(3)),
                    title: statement.text(4) ?? "",
                    subtitle: statement.text(5), summary: statement.text(6),
                    category: statement.text(7), episode: statement.text(8))))
            }
            return window
        }
        return read ?? EPGWindowRows()
    }

    /// Steps `statement` (already prepared with `selectChannel`) for one channel.
    fileprivate static func readChannel(_ statement: EPGSQLiteStatement, key: String) throws -> [EPGProgram] {
        statement.bind(1, key)
        var list: [EPGProgram] = []
        while try statement.step() {
            list.append(EPGProgram(
                channelID: statement.text(0) ?? key,
                start: Date(timeIntervalSinceReferenceDate: statement.double(1)),
                end: Date(timeIntervalSinceReferenceDate: statement.double(2)),
                title: statement.text(3) ?? "",
                subtitle: statement.text(4), summary: statement.text(5),
                category: statement.text(6), episode: statement.text(7)))
        }
        return list
    }
}

/// A cache sweep may only unlink a generation after every SQLite connection to that path has
/// closed. Generation files are never renamed, so a leased reader keeps a stable vnode.
enum EPGSQLiteFileLeases {
    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]

    static func acquire(_ url: URL) {
        lock.withLock { counts[url.standardizedFileURL.path, default: 0] += 1 }
    }

    static func release(_ url: URL) {
        lock.withLock {
            let path = url.standardizedFileURL.path
            let count = counts[path, default: 0] - 1
            if count <= 0 { counts[path] = nil } else { counts[path] = count }
        }
    }

    static func isLeased(_ url: URL) -> Bool {
        lock.withLock { counts[url.standardizedFileURL.path, default: 0] > 0 }
    }
}

/// A query-ready guide backed by SQLite. Conforms to `EPGQuerying` and returns exactly what the
/// in-memory `EPGIndex` returns for the same feed.
struct EPGSQLiteIndex: Sendable, EPGQuerying {
    let guide: EPGSQLiteGuide
    let fetchedAt: Date
    let programCount: Int
    let coverageEnd: Date?
    var readPolicy: EPGSQLiteReadPolicy
    var isShortGuideOnly: Bool { false }

    init(guide: EPGSQLiteGuide, readPolicy: EPGSQLiteReadPolicy = .cachedOnly) {
        self.guide = guide
        self.readPolicy = readPolicy
        fetchedAt = guide.metadata.fetchedAt
        programCount = guide.metadata.programCount
        coverageEnd = guide.metadata.coverageEnd
    }

    var channelCount: Int { guide.channelKeys.count }

    func channelKey(guideID: String?, name: String?) -> String? {
        if let key = EPGChannelKey.guideID(guideID), guide.channelKeys.contains(key) { return key }
        if let nameKey = EPGChannelKey.name(name), let key = guide.names[nameKey],
           guide.channelKeys.contains(key) { return key }
        return nil
    }

    func nowNext(guideID: String?, name: String?, at date: Date) -> EPGNowNext {
        guard let key = channelKey(guideID: guideID, name: name) else { return .empty }
        return nowNext(channelKey: key, at: date)
    }

    func nowNext(channelKey: String, at date: Date) -> EPGNowNext {
        guard let list = listings(channelKey: channelKey) else { return .empty }
        return EPGIndex.nowNext(in: list, at: date)
    }

    func programs(channelKey: String, overlapping interval: DateInterval) -> [EPGProgram] {
        guard let list = listings(channelKey: channelKey) else { return [] }
        return EPGIndex.programs(in: list, overlapping: interval)
    }

    func isResident(channelKey: String) -> Bool {
        !guide.channelKeys.contains(channelKey) || guide.isResident(channelKey)
    }

    func prefetch(channelKeys: [String]) { guide.prefetch(channelKeys) }

    /// The channel's normalized listings per the read policy; nil when absent or not yet loaded.
    func listings(channelKey key: String) -> [EPGProgram]? {
        guard guide.channelKeys.contains(key) else { return nil }
        if let resident = guide.residentList(key) { return resident }
        switch readPolicy {
        case .cachedOnly:
            return nil
        case .readThrough:
            guide.prefetch([key])
            return guide.residentList(key) ?? guide.loadFromDisk(key)
        }
    }
}

// MARK: - Building

struct EPGSQLiteBuildResult: Sendable {
    let index: EPGSQLiteIndex
    let statistics: EPGIndex.Statistics
}

/// Streams a feed into a new SQLite file without ever holding the programmes as one array.
///
/// 1. The XMLTV parser hands each accepted programme to a bounded-batch insert into a temporary
///    `raw` table (on disk, small page cache).
/// 2. One ordered pass over `raw` normalizes each channel with `EPGIndex`'s own rules and writes the
///    final tables, so duplicates, overlaps, the 250-per-channel bound and the window match the
///    in-memory index exactly.
/// 3. If the total exceeds the indexed-programme cap, over-limit channels are trimmed with the same
///    `nearest` rule.
/// 4. The file is closed, flushed, reopened read-only and integrity checked. On any failure the
///    partial file is deleted and the error is thrown; nothing that was already published changes.
enum EPGSQLiteBuilder {
    static let batchSize = 4_096

    static func build(xml: Data, filter: EPGChannelFilter?, limits: EPGLimits, fetchedAt: Date,
                      providerID: UUID, fingerprint: Data, destination: URL,
                      readPolicy: EPGSQLiteReadPolicy = .cachedOnly) throws -> EPGSQLiteBuildResult {
        try? FileManager.default.removeItem(at: destination)
        do {
            let (metadata, statistics) = try write(xml: xml, filter: filter, limits: limits, fetchedAt: fetchedAt,
                                                   providerID: providerID, fingerprint: fingerprint,
                                                   destination: destination)
            try flush(destination)
            let guide = try verifiedOpen(destination, expected: metadata)
            return EPGSQLiteBuildResult(index: EPGSQLiteIndex(guide: guide, readPolicy: readPolicy),
                                        statistics: statistics)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func write(xml: Data, filter: EPGChannelFilter?, limits: EPGLimits, fetchedAt: Date,
                              providerID: UUID, fingerprint: Data,
                              destination: URL) throws -> (EPGSQLiteMetadata, EPGIndex.Statistics) {
        let connection = try EPGSQLiteConnection.create(destination)
        defer { connection.close() }
        try connection.execute("""
        PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF; PRAGMA locking_mode = EXCLUSIVE;
        PRAGMA temp_store = FILE; PRAGMA cache_size = -8192;
        PRAGMA application_id = \(EPGSQLiteSchema.applicationID); PRAGMA user_version = \(EPGSQLiteSchema.version)
        """)
        return try connection.withHandle { db in
            func run(_ sql: String) throws {
                guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw EPGSQLiteError.statementFailed }
            }
            let window = DateInterval(start: fetchedAt.addingTimeInterval(-limits.pastRetention),
                                      end: fetchedAt.addingTimeInterval(limits.futureHorizon))
            try run(EPGSQLiteSchema.create)
            try run("""
            CREATE TEMP TABLE raw(seq INTEGER PRIMARY KEY, ckey TEXT NOT NULL, cid TEXT NOT NULL,
                start REAL NOT NULL, end REAL NOT NULL, title TEXT NOT NULL,
                sub TEXT, summ TEXT, cat TEXT, ep TEXT)
            """)

            // 1. Streaming ingest.
            let insertRaw = try EPGSQLiteStatement(
                db, "INSERT INTO raw(ckey, cid, start, end, title, sub, summ, cat, ep) VALUES(?,?,?,?,?,?,?,?,?)")
            defer { insertRaw.finalize() }
            try run("BEGIN")
            var pending = 0
            let document = try XMLTVParser.parse(xml, filter: filter, window: window, limits: limits) { program in
                guard let key = EPGChannelKey.guideID(program.channelID) else { return }
                insertRaw.bind(1, key)
                insertRaw.bind(2, program.channelID)
                insertRaw.bind(3, program.start.timeIntervalSinceReferenceDate)
                insertRaw.bind(4, program.end.timeIntervalSinceReferenceDate)
                insertRaw.bind(5, program.title)
                insertRaw.bind(6, program.subtitle)
                insertRaw.bind(7, program.summary)
                insertRaw.bind(8, program.category)
                insertRaw.bind(9, program.episode)
                _ = try insertRaw.step()
                insertRaw.reset()
                pending += 1
                if pending >= batchSize {
                    pending = 0
                    try run("COMMIT")
                    try Task.checkCancellation()
                    try run("BEGIN")
                }
            }
            try run("COMMIT")
            try run("CREATE INDEX raw_order ON raw(ckey, start, seq)")
            try Task.checkCancellation()

            // 2. Ordered normalize-and-write pass.
            var statistics = EPGIndex.Statistics(malformed: document.malformedCount, truncated: document.isTruncated,
                                                 incomplete: document.isIncomplete)
            let insertProgram = try EPGSQLiteStatement(
                db, "INSERT INTO programmes(channel_key, start_s, end_s, channel_id, title, subtitle, summary, category, episode) VALUES(?,?,?,?,?,?,?,?,?)")
            let insertChannel = try EPGSQLiteStatement(
                db, "INSERT INTO channels(channel_key, program_count, last_end) VALUES(?,?,?)")
            defer { insertProgram.finalize(); insertChannel.finalize() }
            let scan = try EPGSQLiteStatement(
                db, "SELECT ckey, cid, start, end, title, sub, summ, cat, ep FROM raw ORDER BY ckey, start, seq")
            defer { scan.finalize() }

            var keys = Set<String>()
            var total = 0
            var groupKey: String?
            var group: [EPGProgram] = []
            try run("BEGIN")
            var written = 0

            func flushGroup() throws {
                guard let key = groupKey else { return }
                defer { group.removeAll(keepingCapacity: true) }
                let list = EPGIndex.normalize(group, window: window, now: fetchedAt,
                                              limit: limits.maximumProgramsPerChannel, statistics: &statistics)
                guard let last = list.last else { return }
                for program in list {
                    insertProgram.bind(1, key)
                    insertProgram.bind(2, program.start.timeIntervalSinceReferenceDate)
                    insertProgram.bind(3, program.end.timeIntervalSinceReferenceDate)
                    insertProgram.bind(4, program.channelID == key ? nil : program.channelID)
                    insertProgram.bind(5, program.title)
                    insertProgram.bind(6, program.subtitle)
                    insertProgram.bind(7, program.summary)
                    insertProgram.bind(8, program.category)
                    insertProgram.bind(9, program.episode)
                    _ = try insertProgram.step()
                    insertProgram.reset()
                }
                insertChannel.bind(1, key)
                insertChannel.bind(2, Int64(list.count))
                insertChannel.bind(3, last.end.timeIntervalSinceReferenceDate)
                _ = try insertChannel.step()
                insertChannel.reset()
                keys.insert(key)
                total += list.count
                written += list.count
                if written >= batchSize {
                    written = 0
                    try run("COMMIT")
                    try Task.checkCancellation()
                    try run("BEGIN")
                }
            }

            while try scan.step() {
                guard let key = scan.text(0) else { throw EPGSQLiteError.corrupt }
                if key != groupKey {
                    try flushGroup()
                    groupKey = key
                }
                group.append(EPGProgram(
                    channelID: scan.text(1) ?? key,
                    start: Date(timeIntervalSinceReferenceDate: scan.double(2)),
                    end: Date(timeIntervalSinceReferenceDate: scan.double(3)),
                    title: scan.text(4) ?? "", subtitle: scan.text(5), summary: scan.text(6),
                    category: scan.text(7), episode: scan.text(8)))
            }
            try flushGroup()
            try run("COMMIT")

            // 3. Global programme cap, trimmed per channel with the in-memory rule.
            if total > limits.maximumIndexedPrograms, !keys.isEmpty {
                let perChannel = max(1, limits.maximumIndexedPrograms / keys.count)
                let over = try EPGSQLiteStatement(db, "SELECT channel_key FROM channels WHERE program_count > ?1")
                over.bind(1, Int64(perChannel))
                var overKeys: [String] = []
                while try over.step() { if let key = over.text(0) { overKeys.append(key) } }
                over.finalize()
                let select = try EPGSQLiteStatement(db, EPGSQLiteSchema.selectChannel)
                let delete = try EPGSQLiteStatement(
                    db, "DELETE FROM programmes WHERE channel_key = ?1 AND (start_s < ?2 OR start_s > ?3)")
                let update = try EPGSQLiteStatement(
                    db, "UPDATE channels SET program_count = ?2, last_end = ?3 WHERE channel_key = ?1")
                defer { select.finalize(); delete.finalize(); update.finalize() }
                try run("BEGIN")
                for key in overKeys {
                    select.reset()
                    let list = try EPGSQLiteGuide.readChannel(select, key: key)
                    let kept = EPGIndex.nearest(list, to: fetchedAt, limit: perChannel, statistics: &statistics)
                    guard let first = kept.first, let last = kept.last else { continue }
                    delete.reset()
                    delete.bind(1, key)
                    delete.bind(2, first.start.timeIntervalSinceReferenceDate)
                    delete.bind(3, last.start.timeIntervalSinceReferenceDate)
                    _ = try delete.step()
                    update.reset()
                    update.bind(1, key)
                    update.bind(2, Int64(kept.count))
                    update.bind(3, last.end.timeIntervalSinceReferenceDate)
                    _ = try update.step()
                    total -= list.count - kept.count
                }
                try run("COMMIT")
            }
            try Task.checkCancellation()

            // 4. Names (only for channels that have listings, ambiguity decided on the full feed), meta.
            let insertName = try EPGSQLiteStatement(db, "INSERT INTO names(name_key, channel_key) VALUES(?,?)")
            defer { insertName.finalize() }
            try run("BEGIN")
            for (name, key) in EPGIndex.nameMap(document.channels) where keys.contains(key) {
                insertName.reset()
                insertName.bind(1, name)
                insertName.bind(2, key)
                _ = try insertName.step()
            }
            let coverage = try EPGSQLiteStatement(db, "SELECT max(last_end) FROM channels")
            defer { coverage.finalize() }
            var coverageEnd: Date?
            if try coverage.step(), !coverage.isNull(0) {
                coverageEnd = Date(timeIntervalSinceReferenceDate: coverage.double(0))
            }
            let metadata = EPGSQLiteMetadata(providerID: providerID, sourceFingerprint: fingerprint,
                                             contentID: UUID(), fetchedAt: EPGTimestamp.canonical(fetchedAt),
                                             programCount: total, channelCount: keys.count, coverageEnd: coverageEnd)
            let insertMeta = try EPGSQLiteStatement(db, "INSERT INTO meta(key, value) VALUES(?,?)")
            defer { insertMeta.finalize() }
            for (key, value) in metadata.rows() {
                insertMeta.reset()
                insertMeta.bind(1, key)
                switch value {
                case .int(let v): insertMeta.bind(2, v)
                case .double(let v): insertMeta.bind(2, v)
                case .text(let v): insertMeta.bind(2, v)
                case .blob(let v): insertMeta.bind(2, blob: v)
                case .null: sqlite3_bind_null(insertMeta.raw, 2)
                }
                _ = try insertMeta.step()
            }
            try run("COMMIT")
            return (metadata, statistics)
        }
    }

    private static func flush(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    /// Reopens the finished file read-only and checks structure and counts before it is trusted.
    private static func verifiedOpen(_ url: URL, expected: EPGSQLiteMetadata) throws -> EPGSQLiteGuide {
        let guide = try EPGSQLiteGuide.open(url, providerID: expected.providerID, fingerprint: expected.sourceFingerprint)
        guard guide.metadata == expected else { throw EPGSQLiteError.corrupt }
        guide.markUnpublished()
        let probe = try EPGSQLiteConnection.openReadOnly(url)
        defer { probe.close() }
        try probe.withHandle { db in
            let rows = try EPGSQLiteStatement(db, "SELECT count(*) FROM programmes")
            defer { rows.finalize() }
            guard try rows.step(), Int(rows.int64(0)) == expected.programCount else { throw EPGSQLiteError.corrupt }
            let check = try EPGSQLiteStatement(db, "PRAGMA quick_check(1)")
            defer { check.finalize() }
            guard try check.step(), check.text(0) == "ok" else { throw EPGSQLiteError.corrupt }
        }
        return guide
    }
}
