import Foundation
public enum MediaKind: String, Codable, Sendable { case movie, series, season, episode }
public struct CanonicalMedia: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let kind: MediaKind
    public let title: String
    public let year: Int?
    public init(id: String, kind: MediaKind, title: String, year: Int? = nil) { self.id=id; self.kind=kind; self.title=title; self.year=year }
}
