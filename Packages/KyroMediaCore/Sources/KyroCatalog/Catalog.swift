import Foundation

public enum MediaKind: String, Codable, Sendable { case movie, series, season, episode }
public struct CanonicalMedia: Codable, Hashable, Sendable, Identifiable {
  public let id: String
  public let kind: MediaKind
  public let title: String
  public let year: Int?
  public let externalIDs: [String: String]
  public let edition: String?
  public let parentID: String?
  public let season: Int?
  public let episode: Int?
  public let provenance: [String: MetadataProvenance]
  public let versions: [MediaVersion]
  public init(
    id: String, kind: MediaKind, title: String, year: Int? = nil,
    externalIDs: [String: String] = [:], edition: String? = nil, parentID: String? = nil,
    season: Int? = nil, episode: Int? = nil, provenance: [String: MetadataProvenance] = [:],
    versions: [MediaVersion] = []
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.year = year
    self.externalIDs = externalIDs
    self.edition = edition
    self.parentID = parentID
    self.season = season
    self.episode = episode
    self.provenance = provenance
    self.versions = versions
  }
}

public struct MetadataProvenance: Codable, Hashable, Sendable {
  public let provider: String
  public let sourceItemID: String
  public let importedAt: Date
  public init(provider: String, sourceItemID: String, importedAt: Date) {
    self.provider = provider
    self.sourceItemID = sourceItemID
    self.importedAt = importedAt
  }
}
public struct MediaVersion: Codable, Hashable, Sendable {
  public let sourceItemID: String
  public let edition: String?
  public let container: String?
  public init(sourceItemID: String, edition: String? = nil, container: String? = nil) {
    self.sourceItemID = sourceItemID
    self.edition = edition
    self.container = container
  }
}
public enum CanonicalKey {
  public static func external(
    kind: MediaKind, namespace: String, value: String, edition: String? = nil
  ) -> String {
    func escaped(_ text: String) -> String {
      text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
    let base = "kyro:v1:\(kind.rawValue):\(escaped(namespace.lowercased())):\(escaped(value))"
    return edition.map { base + ":edition:" + escaped($0) } ?? base
  }
  public static func local(kind: MediaKind, id: UUID = UUID()) -> String {
    "kyro:v1:\(kind.rawValue):uuid:\(id.uuidString.lowercased())"
  }
}
