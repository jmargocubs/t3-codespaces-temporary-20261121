import Foundation

public struct StableID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
}
public typealias HouseholdID = StableID
public typealias KyroProfileID = StableID
public typealias DeviceID = StableID
public typealias ProviderAccountID = StableID

public struct HybridLogicalClock: Codable, Hashable, Sendable, Comparable {
    public let physicalMilliseconds: Int64
    public let logical: UInt32
    public let node: String
    public init(physicalMilliseconds: Int64, logical: UInt32, node: String) {
        self.physicalMilliseconds = physicalMilliseconds; self.logical = logical; self.node = node
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.physicalMilliseconds, lhs.logical, lhs.node) < (rhs.physicalMilliseconds, rhs.logical, rhs.node)
    }
    public func validated(nowMilliseconds: Int64, maximumFutureSkew: Int64 = 300_000) throws {
        guard physicalMilliseconds <= nowMilliseconds + maximumFutureSkew else { throw ClockError.futureTimestamp }
    }
    public enum ClockError: Error { case futureTimestamp }
}
