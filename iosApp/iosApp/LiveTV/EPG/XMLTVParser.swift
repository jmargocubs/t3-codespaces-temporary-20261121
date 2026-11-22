import Foundation

/// Streaming XMLTV parser.
///
/// Adapted from Telly's `XmltvParser`, `XmltvParserDelegate`, `XmltvElementReader` and
/// `XmltvEpisodeNum` (MIT, Copyright (c) 2026 John Corser,
/// johnpc/telly-apple@66c74301701822bed92bc245c7d887d9f78beb01). Kyro adds playlist-scoped
/// channel filtering, a retention window, programme and text limits, cooperative cancellation,
/// malformed-entry accounting, external-entity hardening, and a root-element check so an HTML
/// error page is not mistaken for an empty guide.
///
/// Synchronous and CPU-bound: call it from a nonisolated async context, never the main actor.
enum XMLTVParser {
    /// - Parameter onProgram: when set, each accepted programme goes to this sink instead of
    ///   `EPGDocument.programs`, so a large feed is never held as one programme array. A throwing
    ///   sink aborts the parse and rethrows.
    static func parse(_ data: Data, filter: EPGChannelFilter? = nil, window: DateInterval? = nil,
                      limits: EPGLimits = EPGLimits(),
                      onProgram: ((EPGProgram) throws -> Void)? = nil) throws -> EPGDocument {
        try Task.checkCancellation()
        let parser = XMLParser(data: data)
        let delegate = XMLTVParserDelegate(filter: filter, window: window, limits: limits, sink: onProgram)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        let completed = parser.parse()
        if let sinkError = delegate.sinkError { throw sinkError }
        if delegate.wasCancelled || Task.isCancelled { throw CancellationError() }
        guard delegate.sawRoot else { throw EPGError.malformedFeed }
        // A truncated or corrupt tail keeps whatever parsed cleanly before it.
        if !completed, !delegate.document.isTruncated,
           delegate.acceptedCount == 0, delegate.document.channels.isEmpty {
            throw EPGError.malformedFeed
        }
        if !completed, !delegate.document.isTruncated { delegate.markIncomplete() }
        return delegate.document
    }
}

private final class XMLTVParserDelegate: NSObject, XMLParserDelegate {
    private(set) var document = EPGDocument()
    private(set) var wasCancelled = false
    private(set) var sawRoot = false
    private(set) var acceptedCount = 0
    private(set) var sinkError: Error?
    private let sink: ((EPGProgram) throws -> Void)?

    private enum Kind { case channel, programme, skipped }
    private struct Context {
        let kind: Kind
        let attributes: [String: String]
        let depth: Int
        var children: [String: String] = [:]
        var displayNames: [String] = []
        var childTag: String?
        var childSystem: String?
        var text = ""
    }

    private let filter: EPGChannelFilter?
    private let window: DateInterval?
    private let limits: EPGLimits
    private var context: Context?
    private var depth = 0
    private var elementsSinceCancellationCheck = 0
    /// Normalized IDs the filter accepted from the feed's own `<channel>` list.
    private var acceptedChannelIDs = Set<String>()

    func markIncomplete() { document.isIncomplete = true }

    init(filter: EPGChannelFilter?, window: DateInterval?, limits: EPGLimits,
         sink: ((EPGProgram) throws -> Void)? = nil) {
        self.sink = sink
        self.filter = filter
        self.window = window
        self.limits = limits
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        depth += 1
        elementsSinceCancellationCheck += 1
        if elementsSinceCancellationCheck >= 256 {
            elementsSinceCancellationCheck = 0
            if Task.isCancelled {
                wasCancelled = true
                parser.abortParsing()
                return
            }
        }
        if depth == 1 {
            sawRoot = name == "tv"
            if !sawRoot { parser.abortParsing() }
            return
        }
        if context == nil {
            switch name {
            case "channel":
                context = Context(kind: .channel, attributes: attributes, depth: depth)
            case "programme":
                context = Context(kind: acceptsProgramme(attributes) ? .programme : .skipped,
                                  attributes: attributes, depth: depth)
            default:
                break
            }
        } else if var current = context, current.kind != .skipped, depth == current.depth + 1 {
            current.childTag = name
            current.childSystem = attributes["system"]
            current.text = ""
            context = current
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard var current = context, current.kind != .skipped, current.childTag != nil,
              depth == current.depth + 1 else { return }
        append(string, to: &current.text)
        context = current
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        // A CDATA node can be as large as the whole document; decode only enough bytes to
        // supply the remaining capped text (four UTF-8 bytes per Unicode scalar).
        let remaining = max(0, limits.maximumTextLength - (context?.text.count ?? 0))
        guard remaining > 0 else { return }
        let string = String(decoding: block.prefix(remaining * 4), as: UTF8.self)
        self.parser(parser, foundCharacters: string)
    }

    private func append(_ string: String, to text: inout String) {
        let remaining = limits.maximumTextLength - text.count
        guard remaining > 0 else { return }
        text.append(contentsOf: string.prefix(remaining))
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        defer { depth -= 1 }
        guard var current = context else { return }
        if depth == current.depth + 1, name == current.childTag {
            store(&current, tag: name)
            current.childTag = nil
            current.text = ""
            context = current
        } else if depth == current.depth {
            finish(current, parser: parser)
            context = nil
        }
    }

    /// Records one child's value. The first occurrence wins, except display names, which are all
    /// kept for channel matching.
    private func store(_ current: inout Context, tag: String) {
        let value = clipped(current.text)
        guard let value else { return }
        if tag == "display-name" {
            current.displayNames.append(value)
            return
        }
        guard current.children[tag] == nil else { return }
        if tag == "episode-num" {
            current.children[tag] = XMLTVEpisodeNumber.display(system: current.childSystem, text: value)
        } else {
            current.children[tag] = value
        }
    }

    private func finish(_ current: Context, parser: XMLParser) {
        switch current.kind {
        case .channel:
            guard let id = current.attributes["id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty else { return }
            document.channels.append(EPGChannel(id: id, displayNames: current.displayNames))
            if filter?.accepts(channelID: id, displayNames: current.displayNames) == true {
                if let key = EPGChannelKey.guideID(id) { acceptedChannelIDs.insert(key) }
            }
        case .programme:
            guard let program = program(from: current) else {
                document.malformedCount += 1
                return
            }
            if let window, program.end <= window.start || program.start >= window.end { return }
            if let sink {
                do { try sink(program) } catch {
                    sinkError = error
                    parser.abortParsing()
                    return
                }
            } else {
                document.programs.append(program)
            }
            acceptedCount += 1
            if acceptedCount >= limits.maximumParsedPrograms {
                document.isTruncated = true
                parser.abortParsing()
            }
        case .skipped:
            break
        }
    }

    private func acceptsProgramme(_ attributes: [String: String]) -> Bool {
        guard let filter else { return true }
        // Unparseable programmes are still accepted here so they are counted as malformed.
        guard let channel = attributes["channel"]?.trimmingCharacters(in: .whitespacesAndNewlines) else { return true }
        return EPGChannelKey.guideID(channel).map(acceptedChannelIDs.contains) == true
            || filter.accepts(channelID: channel, displayNames: [])
    }

    private func program(from current: Context) -> EPGProgram? {
        guard let channelID = current.attributes["channel"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !channelID.isEmpty,
              let title = current.children["title"],
              let start = XMLTVTimestamp.parse(current.attributes["start"], fallbackTimeZone: limits.fallbackTimeZone),
              let end = XMLTVTimestamp.parse(current.attributes["stop"], fallbackTimeZone: limits.fallbackTimeZone),
              start < end else { return nil }
        return EPGProgram(channelID: channelID, start: start, end: end, title: title,
                          subtitle: current.children["sub-title"], summary: current.children["desc"],
                          category: current.children["category"], episode: current.children["episode-num"])
    }

    private func clipped(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return value.count > limits.maximumTextLength ? String(value.prefix(limits.maximumTextLength)) : value
    }
}

/// Converts an XMLTV `<episode-num>` into display form. `xmltv_ns` numbers are zero-based
/// "season.episode.part" with optional "index/total" fields, so `0.9.` renders as "S1 E10".
/// Other systems already carry display text and pass through unchanged.
enum XMLTVEpisodeNumber {
    static func display(system: String?, text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        guard system?.trimmingCharacters(in: .whitespacesAndNewlines) == "xmltv_ns" else { return value }
        let fields = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let season = oneBased(fields.count > 0 ? fields[0] : nil)
        let episode = oneBased(fields.count > 1 ? fields[1] : nil)
        let joined = [season.map { "S\($0)" }, episode.map { "E\($0)" }].compactMap { $0 }.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    private static func oneBased(_ field: String?) -> Int? {
        guard let head = field?.split(separator: "/", omittingEmptySubsequences: false).first
                .map({ String($0).trimmingCharacters(in: .whitespaces) }),
              let value = Int(head), value >= 0 else { return nil }
        return value + 1
    }
}
