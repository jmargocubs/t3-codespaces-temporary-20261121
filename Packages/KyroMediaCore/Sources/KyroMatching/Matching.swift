import Foundation
import KyroCatalog
public enum MediaMatcher {
    public static func normalizedTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "(?i)\\b(4k|uhd|fhd|hd|sd|1080p|720p|2160p|hevc|x264|x265)\\b", with: "", options: .regularExpression)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
    }
    public static func canMatch(title lhs: String, title rhs: String, sharedExternalID: Bool, conflictingIDs: Bool) -> Bool {
        if conflictingIDs { return false }; if sharedExternalID { return true }
        return false
    }
    public static func matches(_ a: CanonicalMedia, _ b: CanonicalMedia) -> Bool {
        guard a.kind == b.kind, a.edition?.lowercased() == b.edition?.lowercased() else { return false }
        if let ay = a.year, let by = b.year, ay != by { return false }
        if a.kind == .episode, a.season != b.season || a.episode != b.episode { return false }
        let namespaces = Set(a.externalIDs.keys).intersection(b.externalIDs.keys)
        guard !namespaces.isEmpty else { return false }
        if namespaces.contains(where: { a.externalIDs[$0] != b.externalIDs[$0] }) { return false }
        return namespaces.contains { !(a.externalIDs[$0] ?? "").isEmpty && a.externalIDs[$0] == b.externalIDs[$0] }
    }
}
