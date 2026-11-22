import Foundation
import KyroFoundation

public struct LedgerOperation: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let profileID: KyroProfileID
    public let key: String
    public let value: String?
    public let clock: HybridLogicalClock
    public init(id: UUID = UUID(), profileID: KyroProfileID, key: String, value: String?, clock: HybridLogicalClock) { self.id=id; self.profileID=profileID; self.key=key; self.value=value; self.clock=clock }
}
public enum LedgerMerge {
    public static func merge(_ lhs: Set<LedgerOperation>, _ rhs: Set<LedgerOperation>) -> Set<LedgerOperation> { lhs.union(rhs) }
    public static func current(_ operations: Set<LedgerOperation>, key: String) -> LedgerOperation? { operations.filter { $0.key == key }.max { $0.clock < $1.clock } }
}
