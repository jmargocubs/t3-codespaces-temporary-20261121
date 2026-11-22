import Foundation
import KyroFoundation

public struct SourcePartition: Codable, Hashable, Sendable {
    public let account: ProviderAccountID
    public let library: String
    public init(account: ProviderAccountID, library: String) { self.account = account; self.library = library }
    public var key: String { account.description + ":" + library }
}
public struct CatalogGeneration: Codable, Hashable, Sendable {
    public let id: UUID
    public let partition: SourcePartition
}
public struct CatalogCursor: Codable, Sendable {
    public let generation: UUID
    public let title: String
    public let id: String
}
public struct CatalogPage: Sendable {
    public let items: [CanonicalMedia]
    public let cursor: CatalogCursor?
}
public enum MatchingOverride: String, Codable, Sendable { case merge, separate }

public struct CatalogStore: Sendable {
    private let database: SQLiteDatabase
    public static func open(database: SQLiteDatabase) async throws -> Self {
        try await database.execute("""
            CREATE TABLE IF NOT EXISTS catalog_generations(id TEXT PRIMARY KEY, partition TEXT NOT NULL, state TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS catalog_active(partition TEXT PRIMARY KEY, generation TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS catalog_items(generation TEXT NOT NULL, id TEXT NOT NULL, title TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(generation,id));
            CREATE INDEX IF NOT EXISTS catalog_page ON catalog_items(generation,title,id);
            CREATE VIRTUAL TABLE IF NOT EXISTS catalog_fts USING fts5(generation UNINDEXED, id UNINDEXED, title);
            """)
        return Self(database: database)
    }
    public func begin(partition: SourcePartition) async throws -> CatalogGeneration {
        let generation = CatalogGeneration(id: UUID(), partition: partition)
        try await database.execute("INSERT INTO catalog_generations VALUES(\(literal(generation.id.uuidString)),\(literal(partition.key)),'staging')")
        return generation
    }
    public func append(_ items: [CanonicalMedia], to generation: CatalogGeneration) async throws {
        try await database.transaction { db in
            try ensureStaging(generation, db)
            for item in items {
                try Task.checkCancellation()
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let payload = try encoder.encode(item).base64EncodedString()
                try db.execute("INSERT INTO catalog_items VALUES(\(literal(generation.id.uuidString)),\(literal(item.id)),\(literal(item.title.lowercased())),\(literal(payload)))")
                try db.execute("INSERT INTO catalog_fts VALUES(\(literal(generation.id.uuidString)),\(literal(item.id)),\(literal(item.title)))")
            }
        }
    }
    public func promote(_ generation: CatalogGeneration, expectedCount: Int) async throws {
        try await database.transaction { db in
            try ensureStaging(generation, db)
            guard expectedCount >= 0, try db.scalarInt("SELECT count(*) FROM catalog_items WHERE generation=\(literal(generation.id.uuidString))") == Int64(expectedCount) else { throw CatalogError.incomplete }
            try db.execute("INSERT INTO catalog_active VALUES(\(literal(generation.partition.key)),\(literal(generation.id.uuidString))) ON CONFLICT(partition) DO UPDATE SET generation=excluded.generation")
            try db.execute("UPDATE catalog_generations SET state='published' WHERE id=\(literal(generation.id.uuidString))")
        }
    }
    public func abort(_ generation: CatalogGeneration) async throws {
        try await database.transaction { db in
            try ensureStaging(generation, db)
            let id = literal(generation.id.uuidString)
            try db.execute("DELETE FROM catalog_fts WHERE generation=\(id); DELETE FROM catalog_items WHERE generation=\(id); DELETE FROM catalog_generations WHERE id=\(id)")
        }
    }
    private func ensureStaging(_ generation: CatalogGeneration, _ db: isolated SQLiteDatabase) throws {
        let count = try db.scalarInt("SELECT count(*) FROM catalog_generations WHERE id=\(literal(generation.id.uuidString)) AND partition=\(literal(generation.partition.key)) AND state='staging'")
        guard count == 1 else { throw CatalogError.invalidGeneration }
    }
    public func page(partition: SourcePartition, after cursor: CatalogCursor? = nil, reverse: Bool = false, limit: Int = 200) async throws -> CatalogPage {
        guard (1...1_000).contains(limit) else { throw CatalogError.invalidLimit }
        return try await database.transaction { db in
            let active = try db.scalarText("SELECT coalesce((SELECT generation FROM catalog_active WHERE partition=\(literal(partition.key))), '')")
            guard let generationID = UUID(uuidString: active) else { return CatalogPage(items: [], cursor: nil) }
            if let cursor, cursor.generation != generationID { throw CatalogError.staleCursor }
            let compare = reverse ? "<" : ">", direction = reverse ? "DESC" : "ASC"
            let seek = cursor.map { " AND (title,id) \(compare) (\(literal($0.title)),\(literal($0.id)))" } ?? ""
            let rows = try db.textRows("SELECT payload FROM catalog_items WHERE generation=\(literal(active))\(seek) ORDER BY title \(direction),id \(direction) LIMIT \(limit)")
            let items = try rows.map { try decode($0) }
            let next = items.last.map { CatalogCursor(generation: generationID, title: $0.title.lowercased(), id: $0.id) }
            return CatalogPage(items: items, cursor: next)
        }
    }
    public func search(_ query: String, partition: SourcePartition, limit: Int = 50) async throws -> [CanonicalMedia] {
        guard (1...1_000).contains(limit) else { throw CatalogError.invalidLimit }
        let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let rows = try await database.textRows("SELECT i.payload FROM catalog_items i JOIN catalog_fts f ON f.generation=i.generation AND f.id=i.id JOIN catalog_active a ON a.generation=i.generation WHERE a.partition=\(literal(partition.key)) AND catalog_fts MATCH \(literal(phrase)) ORDER BY i.title,i.id LIMIT \(limit)")
        return try rows.map { try decode($0) }
    }
    public func setAlias(_ alias: String, canonical: String) async throws {
        try await database.transaction { db in
            var aliases = try db.load([String: String].self, key: "catalog-aliases") ?? [:]
            aliases[alias] = canonical
            var seen: Set<String> = [alias], current = canonical
            while let next = aliases[current] {
                guard seen.insert(current).inserted else { throw CatalogError.aliasCycle }
                current = next
            }
            guard !seen.contains(current) else { throw CatalogError.aliasCycle }
            try db.save(aliases, key: "catalog-aliases")
        }
    }
    public func resolveAlias(_ alias: String) async throws -> String {
        let aliases = try await database.load([String: String].self, key: "catalog-aliases") ?? [:]
        var current = alias, visited: Set<String> = []
        while let next = aliases[current] {
            guard visited.insert(current).inserted else { throw CatalogError.aliasCycle }
            current = next
        }
        return current
    }
    public func setOverride(_ value: MatchingOverride, lhs: String, rhs: String) async throws {
        try await database.save(value, key: overrideKey(lhs, rhs))
    }
    public func matchingOverride(lhs: String, rhs: String) async throws -> MatchingOverride? {
        try await database.load(MatchingOverride.self, key: overrideKey(lhs, rhs))
    }
    private func overrideKey(_ lhs: String, _ rhs: String) -> String {
        "match:" + [lhs, rhs].sorted().map { "\($0.utf8.count):" + $0 }.joined()
    }
    private func literal(_ text: String) -> String { SQLiteDatabase.literal(text) }
    private func decode(_ payload: String) throws -> CanonicalMedia {
        guard let data = Data(base64Encoded: payload) else { throw CatalogError.corrupt }
        return try JSONDecoder().decode(CanonicalMedia.self, from: data)
    }
    public enum CatalogError: Error { case incomplete, invalidGeneration, invalidLimit, staleCursor, aliasCycle, corrupt }
}
