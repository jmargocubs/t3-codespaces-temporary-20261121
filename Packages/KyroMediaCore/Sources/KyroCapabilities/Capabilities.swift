import Foundation
import KyroFoundation

public enum CapabilityState: String, Codable, Sendable { case available, unavailable, unknown, unsupported, requiresAuthentication, requiresGrant }
public struct Capability: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let state: CapabilityState
    public let account: ProviderAccountID?
    public let reason: String?
    public init(id: String, state: CapabilityState, account: ProviderAccountID? = nil, reason: String? = nil) { self.id = id; self.state = state; self.account = account; self.reason = reason }
}
public protocol CapabilityProvider: Sendable { func capabilities(for profile: KyroProfileID) async -> [Capability] }
public struct CapabilityRequirements: Sendable {
    public let supported: Bool
    public let authenticated: Bool
    public let granted: Bool
    public let reachable: Bool?
    public init(supported: Bool, authenticated: Bool, granted: Bool, reachable: Bool?) { self.supported = supported; self.authenticated = authenticated; self.granted = granted; self.reachable = reachable }
    public var state: CapabilityState {
        if !supported { return .unsupported }
        if !authenticated { return .requiresAuthentication }
        if !granted { return .requiresGrant }
        guard let reachable else { return .unknown }
        return reachable ? .available : .unavailable
    }
}
public struct ProfileCapabilityProvider: CapabilityProvider {
    private let values: [KyroProfileID: [Capability]]
    public init(values: [KyroProfileID: [Capability]]) { self.values = values }
    public func capabilities(for profile: KyroProfileID) -> [Capability] { values[profile] ?? [] }
}
