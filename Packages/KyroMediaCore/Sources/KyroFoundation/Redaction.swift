import Foundation

/// Diagnostics intentionally discard all request header values and URL paths:
/// Xtream and other providers can place credentials in arbitrary path segments.
public enum DiagnosticRedactor {
    public static func url(_ url: URL) -> String {
        guard let scheme = url.scheme, let host = url.host else { return "[REDACTED URL]" }
        return "\(scheme)://\(host)/[REDACTED]"
    }
    public static func headers(_ headers: [String: String]) -> [String: String] {
        headers.mapValues { _ in "[REDACTED]" }
    }
    public static func token(_ token: String) -> String { "[REDACTED]" }
}
