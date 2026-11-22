import Foundation
import KyroCatalog
import KyroSources
public struct JellyfinItem: Decodable, Sendable {
    public let name: String
    public let id: String
    public let itemType: String
    public let providerIds: [String: String]?
    public let mediaSources: [MediaSource]?
    enum CodingKeys: String, CodingKey { case name = "Name", id = "Id", itemType = "Type", providerIds = "ProviderIds", mediaSources = "MediaSources" }
    public struct MediaSource: Decodable, Sendable { public let id: String?; enum CodingKeys: String, CodingKey { case id = "Id" } }
}
public enum JellyfinParser {
    public static func parse(_ data: Data) throws -> [CanonicalMedia] {
        try JSONDecoder().decode([JellyfinItem].self, from: data).map {
            CanonicalMedia(id: "jellyfin:" + $0.id, kind: $0.itemType == "Series" ? .series : .movie, title: $0.name)
        }
    }
}
