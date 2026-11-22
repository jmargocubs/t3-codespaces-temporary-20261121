import Foundation
import KyroFoundation

public struct PlaybackProgress: Codable, Hashable, Sendable {
    public let position: Double
    public let duration: Double
    public init(position: Double, duration: Double) throws {
        guard position.isFinite, duration.isFinite, position >= 0, duration > 0, position <= duration else { throw LedgerError.invalidProgress }
        self.position = position; self.duration = duration
    }
}
public enum LedgerValue: Codable, Hashable, Sendable {
    case favorite(Bool), watchlist(Bool), watched(Bool)
    case progress(PlaybackProgress)
    case preference(name: String, value: String?)
    case collectionAdd(collection: String)
    case collectionRemove(collection: String, observed: Set<UUID>)
    var register: String {
        switch self {
        case .favorite: "favorite"
        case .watchlist: "watchlist"
        case .watched: "watched"
        case .progress: "progress"
        case .preference(let name, _): "preference:" + name
        case .collectionAdd(let name), .collectionRemove(let name, _): "collection:" + name
        }
    }
}
public struct LedgerOperation: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let profileID: KyroProfileID
    public let media: String
    public let value: LedgerValue
    public let clock: HybridLogicalClock
    public init(id: UUID = UUID(), profileID: KyroProfileID, media: String, value: LedgerValue, clock: HybridLogicalClock) {
        self.id = id; self.profileID = profileID; self.media = media; self.value = value; self.clock = clock
    }
    fileprivate var tieBreak: String {
        // Collection remove sets are unordered, so encode a sorted tag list explicitly.
        switch value {
        case .collectionRemove(let name, let tags): return name + tags.map(\.uuidString).sorted().joined()
        default:
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
        }
    }
}
public enum LedgerError: Error { case wrongProfile, invalidProgress }

public struct LedgerState: Codable, Sendable, Equatable {
    public private(set) var operations: Set<LedgerOperation> = []
    public init(operations: Set<LedgerOperation> = []) { self.operations = operations }
    public func merged(with other: Self) -> Self { Self(operations: operations.union(other.operations)) }
    public func latest(profile: KyroProfileID, media: String, register: String) -> LedgerOperation? {
        operations.filter { $0.profileID == profile && $0.media == media && $0.value.register == register }.max(by: Self.precedes)
    }
    private static func precedes(_ a: LedgerOperation, _ b: LedgerOperation) -> Bool {
        if a.clock != b.clock { return a.clock < b.clock }
        if a.id != b.id { return a.id.uuidString < b.id.uuidString }
        return a.tieBreak < b.tieBreak
    }
    public func favorites(profile: KyroProfileID) -> Set<String> { selected(profile: profile, register: "favorite", value: .favorite(true)) }
    public func watchlist(profile: KyroProfileID) -> Set<String> { selected(profile: profile, register: "watchlist", value: .watchlist(true)) }
    public func watched(profile: KyroProfileID) -> Set<String> { selected(profile: profile, register: "watched", value: .watched(true)) }
    private func selected(profile: KyroProfileID, register: String, value: LedgerValue) -> Set<String> {
        Set(operations.filter { $0.profileID == profile }.map(\.media)).filter { latest(profile: profile, media: $0, register: register)?.value == value }
    }
    public func continueWatching(profile: KyroProfileID) -> [LedgerOperation] {
        Set(operations.filter { $0.profileID == profile }.map(\.media)).compactMap { media in
            guard latest(profile: profile, media: media, register: "watched")?.value != .watched(true),
                  let operation = latest(profile: profile, media: media, register: "progress"),
                  case .progress(let progress) = operation.value,
                  progress.position > 0, progress.position < progress.duration * 0.95 else { return nil }
            return operation
        }.sorted { Self.precedes($1, $0) }
    }
    public func observedTags(profile: KyroProfileID, collection: String, media: String) -> Set<UUID> {
        var adds = Set<UUID>(), removed = Set<UUID>()
        for operation in operations where operation.profileID == profile && operation.media == media {
            switch operation.value {
            case .collectionAdd(let name) where name == collection: adds.insert(operation.id)
            case .collectionRemove(let name, let tags) where name == collection: removed.formUnion(tags)
            default: break
            }
        }
        return adds.subtracting(removed)
    }
    public func collection(profile: KyroProfileID, name: String) -> Set<String> {
        Set(operations.filter { $0.profileID == profile }.map(\.media)).filter { !observedTags(profile: profile, collection: name, media: $0).isEmpty }
    }
}

public struct LedgerStore: Sendable {
    private let database: SQLiteDatabase
    public let profile: KyroProfileID
    public init(database: SQLiteDatabase, profile: KyroProfileID) { self.database = database; self.profile = profile }
    public func state() async throws -> LedgerState { try await database.load(LedgerState.self, key: "ledger:" + profile.description) ?? LedgerState() }
    public func merge(_ incoming: LedgerState, nowMilliseconds: Int64) async throws {
        for operation in incoming.operations {
            guard operation.profileID == profile else { throw LedgerError.wrongProfile }
            try operation.clock.validated(nowMilliseconds: nowMilliseconds)
            if case .progress(let progress) = operation.value { _ = try PlaybackProgress(position: progress.position, duration: progress.duration) }
        }
        try await database.transaction { db in
            let key = "ledger:" + profile.description
            let current = try db.load(LedgerState.self, key: key) ?? LedgerState()
            try db.save(current.merged(with: incoming), key: key)
        }
    }
}
