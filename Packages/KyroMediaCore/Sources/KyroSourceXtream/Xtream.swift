import Foundation
import KyroCatalog
import KyroSources

public struct ProviderScalar: Codable, Sendable {
    public let value: String
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { value = text }
        else { value = String(try container.decode(Int64.self)) }
    }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(value) }
}
public struct XtreamVOD: Decodable, Sendable {
    public let stream_id: ProviderScalar
    public let name: String
    public let container_extension: String?
    public let tmdb: ProviderScalar?
}
public struct XtreamVODInfo: Decodable, Sendable {
    public let info: Info?
    public let movie_data: XtreamVOD
    public struct Info: Decodable, Sendable {
        public let tmdb_id: ProviderScalar?
        public let name: String?
        public let releasedate: String?
    }
}
public enum XtreamParser {
    public static func parse(_ data: Data) throws -> [CanonicalMedia] { try JSONDecoder().decode([XtreamVOD].self, from: data).map { canonical($0, tmdb: $0.tmdb?.value) } }
    public static func details(_ data: Data) throws -> CanonicalMedia {
        let response = try JSONDecoder().decode(XtreamVODInfo.self, from: data)
        return canonical(response.movie_data, tmdb: response.info?.tmdb_id?.value ?? response.movie_data.tmdb?.value)
    }
    private static func canonical(_ vod: XtreamVOD, tmdb: String?) -> CanonicalMedia {
        let tmdb = tmdb.flatMap { Int($0).map { $0 > 0 ? String($0) : "" } }.flatMap { $0.isEmpty ? nil : $0 }
        let id = tmdb.map { CanonicalKey.external(kind: .movie, namespace: "tmdb", value: $0) } ?? "xtream:" + vod.stream_id.value
        return CanonicalMedia(id: id, kind: .movie, title: vod.name, externalIDs: tmdb.map { ["tmdb": $0] } ?? [:], provenance: ["title": MetadataProvenance(provider: "xtream", sourceItemID: vod.stream_id.value, importedAt: Date(timeIntervalSince1970: 0))], versions: [MediaVersion(sourceItemID: vod.stream_id.value, container: vod.container_extension)])
    }
}
public struct XtreamSource: MediaSourceAdapter {
    public let partition: SourcePartition
    public let capabilities: SourceCapabilities = [.movies, .playback]
    private let baseURL: URL
    private let username: String
    private let password: String
    private let http: ResilientHTTPClient
    public init(partition: SourcePartition, baseURL: URL, username: String, password: String, http: ResilientHTTPClient) {
        self.partition = partition; self.baseURL = baseURL; self.username = username; self.password = password; self.http = http
    }
    public func fetchPage(token: SyncToken?) async throws -> SourceCatalogPage {
        guard token == nil else { throw SourceError.invalidToken }
        return SourceCatalogPage(items: try XtreamParser.parse(await request(action: "get_vod_streams")), nextToken: nil)
    }
    public func details(vodID: String) async throws -> CanonicalMedia {
        try XtreamParser.details(await request(action: "get_vod_info", vodID: vodID))
    }
    private func request(action: String, vodID: String? = nil) async throws -> Data {
        var url = URLComponents(url: baseURL.appendingPathComponent("player_api.php"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password), URLQueryItem(name: "action", value: action)]
        if let vodID { url.queryItems?.append(URLQueryItem(name: "vod_id", value: vodID)) }
        return try await http.send(HTTPRequest(url: url.url!), account: partition.account).body
    }
    public enum SourceError: Error { case invalidToken }
}
