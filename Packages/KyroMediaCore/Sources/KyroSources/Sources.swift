import Foundation
import KyroCatalog
public struct SourceCapabilities: OptionSet, Sendable { public let rawValue: UInt16; public init(rawValue: UInt16) { self.rawValue=rawValue }; public static let movies=Self(rawValue:1), series=Self(rawValue:2), playback=Self(rawValue:4) }
public struct SourceCatalogPage: Sendable { public let items: [CanonicalMedia]; public let nextToken: String?; public init(items:[CanonicalMedia], nextToken:String?) { self.items=items; self.nextToken=nextToken } }
public protocol MediaSourceAdapter: Sendable { func fetchPage(token: String?) async throws -> SourceCatalogPage }
