import CoreGraphics
import Foundation

/// Parser for Seekr's WebVTT sprite manifest.
///
/// Grammar: a `WEBVTT` header, then cues of `START --> END` followed by one
/// payload line — a signed sheet URL with `#xywh=x,y,w,h`. No cue identifiers
/// or settings.
enum SeekrVTT {
    static func parse(_ text: String) -> [SeekrCue] {
        var cues: [SeekrCue] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.contains("-->") {
                let parts = line.split(separator: "-->", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2,
                   let startMs = parseTime(String(parts[0]).trimmingCharacters(in: .whitespaces)),
                   let endMs = parseTime(String(parts[1]).trimmingCharacters(in: .whitespaces)) {
                    let payload = lines[(index + 1)...].first(where: { !$0.isEmpty })
                    if let payload, let tile = parseTile(payload) {
                        cues.append(
                            SeekrCue(
                                startMs: startMs,
                                endMs: endMs,
                                sheetURL: tile.url,
                                rect: tile.rect
                            )
                        )
                    }
                }
            }
            index += 1
        }
        cues.sort { $0.startMs < $1.startMs }
        return cues
    }

    private struct Tile {
        let url: URL
        let rect: CGRect
    }

    private static func parseTile(_ payload: String) -> Tile? {
        guard let hashIndex = payload.lastIndex(of: "#") else { return nil }
        let sheet = String(payload[..<hashIndex])
        let fragment = String(payload[payload.index(after: hashIndex)...])
        guard fragment.hasPrefix("xywh=") else { return nil }
        let coords = fragment.dropFirst(5).split(separator: ",")
        guard coords.count >= 4,
              let x = Int(coords[0].trimmingCharacters(in: .whitespaces)),
              let y = Int(coords[1].trimmingCharacters(in: .whitespaces)),
              let w = Int(coords[2].trimmingCharacters(in: .whitespaces)),
              let h = Int(coords[3].trimmingCharacters(in: .whitespaces)),
              w > 0, h > 0,
              let url = URL(string: sheet) else { return nil }
        return Tile(url: url, rect: CGRect(x: x, y: y, width: w, height: h))
    }

    /// WebVTT timestamps: `HH:MM:SS.mmm` or `MM:SS.mmm`.
    static func parseTime(_ time: String) -> Int64? {
        let trimmed = time.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":")
        switch parts.count {
        case 3:
            guard let hours = Int64(parts[0]),
                  let minutes = Int64(parts[1]),
                  let seconds = Double(parts[2]) else { return nil }
            return hours * 3_600_000 + minutes * 60_000 + Int64((seconds * 1_000).rounded(.towardZero))
        case 2:
            guard let minutes = Int64(parts[0]),
                  let seconds = Double(parts[1]) else { return nil }
            return minutes * 60_000 + Int64((seconds * 1_000).rounded(.towardZero))
        default:
            return nil
        }
    }
}
