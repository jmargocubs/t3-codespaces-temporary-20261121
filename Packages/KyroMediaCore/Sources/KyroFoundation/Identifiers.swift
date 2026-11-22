import Foundation

public struct StableID<Domain: Sendable>: RawRepresentable, Hashable, Codable, Sendable,
  CustomStringConvertible
{
  public let rawValue: UUID
  public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
  public var description: String { rawValue.uuidString.lowercased() }
}

/// Serializes clock advancement for concurrent operations from one device.
public actor HybridClock {
  private var latest: HybridLogicalClock
  private let now: @Sendable () -> Int64
  public init(
    device: DeviceID,
    now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
  ) {
    latest = HybridLogicalClock(physicalMilliseconds: .min, logical: 0, node: device.description)
    self.now = now
  }
  public func tick(receiving remote: HybridLogicalClock? = nil) throws -> HybridLogicalClock {
    let advanced = try latest.advanced(nowMilliseconds: now(), receiving: remote)
    latest = advanced
    return advanced
  }
}
public enum HouseholdDomain: Sendable {}
public enum ProfileDomain: Sendable {}
public enum DeviceDomain: Sendable {}
public enum ProviderAccountDomain: Sendable {}
public typealias HouseholdID = StableID<HouseholdDomain>
public typealias KyroProfileID = StableID<ProfileDomain>
public typealias DeviceID = StableID<DeviceDomain>
public typealias ProviderAccountID = StableID<ProviderAccountDomain>

public struct HybridLogicalClock: Codable, Hashable, Sendable, Comparable {
  public let physicalMilliseconds: Int64
  public let logical: UInt32
  public let node: String
  public init(physicalMilliseconds: Int64, logical: UInt32, node: String) {
    self.physicalMilliseconds = physicalMilliseconds
    self.logical = logical
    self.node = node
  }
  public static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.physicalMilliseconds, lhs.logical, lhs.node) < (
      rhs.physicalMilliseconds, rhs.logical, rhs.node
    )
  }
  public func validated(nowMilliseconds: Int64, maximumFutureSkew: Int64 = 300_000) throws {
    guard maximumFutureSkew >= 0 else { throw ClockError.invalidSkew }
    let (limit, overflow) = nowMilliseconds.addingReportingOverflow(maximumFutureSkew)
    guard overflow || physicalMilliseconds <= limit else { throw ClockError.futureTimestamp }
  }
  /// A rollback of the wall clock preserves monotonic logical time. Untrusted
  /// future timestamps are rejected without advancing this clock.
  public func advanced(
    nowMilliseconds: Int64, receiving remote: Self? = nil, maximumFutureSkew: Int64 = 300_000
  ) throws -> Self {
    guard maximumFutureSkew >= 0 else { throw ClockError.invalidSkew }
    if let remote {
      try remote.validated(nowMilliseconds: nowMilliseconds, maximumFutureSkew: maximumFutureSkew)
    }
    let physical = max(
      nowMilliseconds, physicalMilliseconds, remote?.physicalMilliseconds ?? Int64.min)
    let counter: UInt32
    if physical == physicalMilliseconds, physical == remote?.physicalMilliseconds {
      counter = max(logical, remote!.logical)
    } else if physical == physicalMilliseconds {
      counter = logical
    } else if physical == remote?.physicalMilliseconds {
      counter = remote!.logical
    } else {
      return Self(physicalMilliseconds: physical, logical: 0, node: node)
    }
    let (incremented, overflow) = counter.addingReportingOverflow(1)
    guard !overflow else { throw ClockError.counterExhausted }
    return Self(physicalMilliseconds: physical, logical: incremented, node: node)
  }
  public enum ClockError: Error { case futureTimestamp, invalidSkew, counterExhausted }
}
