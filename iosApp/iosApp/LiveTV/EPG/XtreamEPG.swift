import Foundation

/// Xtream Codes guide endpoints and the short-EPG response.
enum XtreamEPG {
    /// The panel's full XMLTV export for the account (`xmltv.php`), keeping the server's scheme,
    /// port and base path.
    static func xmltvURL(server: String, username: String, password: String) throws -> URL {
        guard var components = URLComponents(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil, !username.isEmpty else { throw EPGError.invalidSource }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([basePath, "xmltv.php"].filter { !$0.isEmpty }.joined(separator: "/"))
        // `queryItems` leaves `&`, `+` and `=` unescaped, which would split a credential.
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let user = username.addingPercentEncoding(withAllowedCharacters: unreserved),
              let secret = password.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw EPGError.invalidSource
        }
        components.percentEncodedQuery = "username=\(user)&password=\(secret)"
        components.fragment = nil
        guard let url = components.url else { throw EPGError.invalidSource }
        return url
    }

    /// Programmes from a `get_short_epg` or `get_simple_data_table` response.
    ///
    /// Panels return the list as `epg_listings` (some forks use `epg_list`), base64-encode titles
    /// and descriptions, and send timestamps as strings or numbers. Only the Unix timestamps are
    /// used: the `start`/`end` strings are in the panel's undisclosed local zone.
    static func programs(from data: Data, guideID: String, limits: EPGLimits = EPGLimits()) throws -> [EPGProgram] {
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) } catch { throw EPGError.malformedFeed }
        if let list = root as? [Any], list.isEmpty { return [] }
        guard let object = root as? [String: Any] else { throw EPGError.malformedFeed }
        guard let entries = (object["epg_listings"] ?? object["epg_list"]) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let title = text(entry["title"], limit: limits.maximumTextLength),
                  let start = timestamp(entry["start_timestamp"]),
                  let end = timestamp(entry["stop_timestamp"] ?? entry["end_timestamp"]),
                  start < end else { return nil }
            return EPGProgram(channelID: guideID, start: Date(timeIntervalSince1970: start),
                              end: Date(timeIntervalSince1970: end), title: title,
                              summary: text(entry["description"], limit: limits.maximumTextLength))
        }
    }

    /// Base64 text when the value decodes to clean UTF-8, otherwise the value as sent.
    static func text(_ value: Any?, limit: Int) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let decoded = Data(base64Encoded: raw)
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { text -> String? in
                let hasControl = text.unicodeScalars.contains {
                    $0.properties.generalCategory == .control && !["\n", "\r", "\t"].contains($0)
                }
                return text.isEmpty || hasControl ? nil : text
            }
        let result = decoded ?? raw
        return result.count > limit ? String(result.prefix(limit)) : result
    }

    private static func timestamp(_ value: Any?) -> TimeInterval? {
        let seconds: TimeInterval?
        switch value {
        case let number as NSNumber: seconds = number.doubleValue
        case let string as String: seconds = TimeInterval(string.trimmingCharacters(in: .whitespaces))
        default: seconds = nil
        }
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }
}
