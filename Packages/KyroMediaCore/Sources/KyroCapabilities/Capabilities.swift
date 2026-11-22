import Foundation
public enum CapabilityState: String, Codable, Sendable { case available, unavailable, unknown }
public struct Capability: Codable, Sendable, Identifiable { public let id: String; public let state: CapabilityState; public init(id:String,state:CapabilityState){self.id=id;self.state=state} }
public protocol CapabilityProvider: Sendable { func capabilities() async -> [Capability] }
