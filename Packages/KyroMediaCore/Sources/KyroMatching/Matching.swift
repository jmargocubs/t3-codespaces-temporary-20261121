import KyroCatalog
public enum MediaMatcher {
    public static func normalizedTitle(_ title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    public static func canMatch(title lhs: String, title rhs: String, sharedExternalID: Bool, conflictingIDs: Bool) -> Bool {
        if conflictingIDs { return false }; if sharedExternalID { return true }
        return normalizedTitle(lhs) == normalizedTitle(rhs)
    }
}
