import Foundation
import KyroCatalog

public struct SourceCapabilities: OptionSet, Sendable, Codable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }
  public static let movies = Self(rawValue: 1), series = Self(rawValue: 2),
    playback = Self(rawValue: 4), deltaSync = Self(rawValue: 8), reportProgress = Self(rawValue: 16)
}
public struct SyncToken: Codable, Hashable, Sendable {
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
}
public struct SourceCatalogPage: Sendable {
  public let items: [CanonicalMedia]
  public let nextToken: SyncToken?
  public init(items: [CanonicalMedia], nextToken: SyncToken?) {
    self.items = items
    self.nextToken = nextToken
  }
}
public protocol MediaSourceAdapter: Sendable {
  var partition: SourcePartition { get }
  var capabilities: SourceCapabilities { get }
  func fetchPage(token: SyncToken?) async throws -> SourceCatalogPage
}
public struct SyncCoordinator: Sendable {
  public let catalog: CatalogStore
  public init(catalog: CatalogStore) { self.catalog = catalog }
  public func sync(_ source: any MediaSourceAdapter) async throws {
    let generation = try await catalog.begin(partition: source.partition)
    do {
      var token: SyncToken?
      var seen: Set<SyncToken> = []
      var count = 0
      repeat {
        try Task.checkCancellation()
        let page = try await source.fetchPage(token: token)
        try await catalog.append(page.items, to: generation)
        count += page.items.count
        token = page.nextToken
        if let token, !seen.insert(token).inserted { throw SyncError.repeatedToken }
      } while token != nil
      try await catalog.promote(generation, expectedCount: count)
    } catch {
      // Cleanup runs in a fresh task because the caller may be canceled.
      await Task.detached { try? await catalog.abort(generation) }.value
      throw error
    }
  }
  public enum SyncError: Error { case repeatedToken }
}
