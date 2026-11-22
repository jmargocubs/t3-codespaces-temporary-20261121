import Foundation
import KyroCatalog
public struct XtreamVOD: Decodable, Sendable { public let stream_id: Int; public let name: String }
public enum XtreamParser {
    public static func parse(_ data: Data) throws -> [CanonicalMedia] {
        try JSONDecoder().decode([XtreamVOD].self, from: data).map {
            CanonicalMedia(id: "xtream:\($0.stream_id)", kind: .movie, title: $0.name)
        }
    }
}
