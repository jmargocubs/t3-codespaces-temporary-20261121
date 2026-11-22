import Foundation
import KyroCatalog
import KyroSources

public struct JellyfinItem: Decodable, Sendable {
    public let name: String
    public let id: String
    public let itemType: String
    public let year: Int?
    public let providerIds: [String: String]?
    public let mediaSources: [MediaSource]?
    enum CodingKeys: String, CodingKey { case name = "Name", id = "Id", itemType = "Type", year = "ProductionYear", providerIds = "ProviderIds", mediaSources = "MediaSources" }
    public struct MediaSource: Decodable, Sendable {
        public let id: String?
        public let container: String?
        public let path: String?
        enum CodingKeys: String, CodingKey { case id = "Id", container = "Container", path = "Path" }
    }
}
public struct JellyfinEnvelope: Decodable, Sendable {
    public let items: [JellyfinItem]
    public let totalRecordCount: Int?
    enum CodingKeys: String, CodingKey { case items = "Items", totalRecordCount = "TotalRecordCount" }
}
public enum JellyfinParser {
    public static func parse(_ data: Data) throws -> [CanonicalMedia] {
        let decoder = JSONDecoder()
        let items: [JellyfinItem]
        if data.first(where: { ![9, 10, 13, 32].contains($0) }) == 91 { items = try decoder.decode([JellyfinItem].self, from: data) }
        else { items = try decoder.decode(JellyfinEnvelope.self, from: data).items }
        return items.filter { $0.itemType == "Movie" || $0.itemType == "Series" }.map { item in
            let ids = Dictionary(item.providerIds?.map { ($0.key.lowercased(), $0.value) } ?? [], uniquingKeysWith: { a, _ in a })
            let kind: MediaKind = item.itemType == "Series" ? .series : .movie
            let preferred = ["imdb", "tmdb", "tvdb"].first { !(ids[$0] ?? "").isEmpty }
            let key = preferred.map { CanonicalKey.external(kind: kind, namespace: $0, value: ids[$0]!) } ?? "jellyfin:" + item.id
            return CanonicalMedia(id: key, kind: kind, title: item.name, year: item.year, externalIDs: ids, provenance: ["title": MetadataProvenance(provider: "jellyfin", sourceItemID: item.id, importedAt: Date(timeIntervalSince1970: 0))], versions: (item.mediaSources ?? []).map { MediaVersion(sourceItemID: $0.id ?? item.id, container: $0.container) })
        }
    }
}
public struct JellyfinSource: MediaSourceAdapter {
    public let partition: SourcePartition
    public let capabilities: SourceCapabilities = [.movies, .playback]
    private let baseURL: URL
    private let token: String
    private let http: ResilientHTTPClient
    private let pageSize: Int
    public init(partition: SourcePartition, baseURL: URL, token: String, http: ResilientHTTPClient, pageSize: Int = 200) throws {
        guard (1...1_000).contains(pageSize) else { throw SourceError.invalidPage }
        self.partition = partition; self.baseURL = baseURL; self.token = token; self.http = http; self.pageSize = pageSize
    }
    public func fetchPage(token: SyncToken?) async throws -> SourceCatalogPage {
        guard let start = Int(token?.rawValue ?? "0"), start >= 0 else { throw SourceError.invalidPage }
        var url = URLComponents(url: baseURL.appendingPathComponent("Items"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "IncludeItemTypes", value: "Movie"), URLQueryItem(name: "Recursive", value: "true"), URLQueryItem(name: "Fields", value: "ProviderIds,MediaSources"), URLQueryItem(name: "StartIndex", value: String(start)), URLQueryItem(name: "Limit", value: String(pageSize))]
        let response = try await http.send(HTTPRequest(url: url.url!, headers: ["X-Emby-Token": self.token]), account: partition.account)
        let envelope = try JSONDecoder().decode(JellyfinEnvelope.self, from: response.body)
        let count = envelope.items.count
        let (next, overflow) = start.addingReportingOverflow(count)
        guard !overflow, count <= pageSize else { throw SourceError.invalidPage }
        let more = envelope.totalRecordCount.map { next < $0 } ?? (count == pageSize)
        guard !more || count > 0 else { throw SourceError.invalidPage }
        return SourceCatalogPage(items: try JellyfinParser.parse(response.body), nextToken: more ? SyncToken(String(next)) : nil)
    }
    public enum SourceError: Error { case invalidPage }
}
