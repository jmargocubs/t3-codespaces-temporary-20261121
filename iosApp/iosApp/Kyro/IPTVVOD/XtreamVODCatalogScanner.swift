#if os(iOS) || KYRO_VOD_HOST_TESTS
import Foundation

/// Splits an Xtream catalog body into its top-level members without building the whole document.
///
/// Xtream `get_vod_streams` and `get_series` return one JSON value for the entire catalog: an
/// array of records, or an object keyed by ID whose values are records. Build 94 decoded that
/// value in one piece, which forced the 96 MiB and 100,000-record caps. The scanner walks the
/// bytes once, tracking only string, escape, and nesting state, and hands each member value to
/// its caller as a small byte array. Memory is bounded by `maximumMemberBytes`.
///
/// Accepted shapes: an array; an object keyed by ID; an empty body, `null`, or `{}`; a leading
/// UTF-8 byte-order mark; and stray scalar or `null` elements, which are skipped and not counted.
/// HTML, other non-JSON bodies, and truncated documents are invalid responses.
struct XtreamVODCatalogScanner {
    enum Shape: Equatable, Sendable { case unknown, array, object, null }

    /// One top-level member. Only object members are catalog records.
    struct Member: Equatable, Sendable {
        /// The member's JSON bytes, or `nil` when it was not captured: too large, or the scanner
        /// was asked to capture only account members.
        let bytes: [UInt8]?
        /// The member's key when the catalog is a keyed object.
        let key: String?
        let isObject: Bool
        /// The member exceeded `maximumMemberBytes`.
        let isOversized: Bool
    }

    enum Capture: Sendable {
        /// Capture every member value (import pass).
        case all
        /// Capture only `user_info` members, so an account rejection is still detected (count pass).
        case accountOnly
    }

    let maximumMemberBytes: Int
    let capture: Capture
    private(set) var shape: Shape = .unknown
    /// The top-level value was closed, or the body was empty or `null`.
    private(set) var isComplete = false
    /// The caller stopped the scan before the end of the document.
    private(set) var stopped = false

    private enum Phase {
        case start, nullLiteral, expectMember, expectKey, key, colon, expectMemberValue
        case compound, stringScalar, bareScalar, trailing
    }

    private var phase: Phase = .start
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var buffer: [UInt8] = []
    private var memberLength = 0
    private var oversized = false
    private var capturing = false
    private var memberIsObject = false
    private var keyBytes: [UInt8] = []
    private var currentKey: String?
    private var literal: [UInt8] = []

    init(maximumMemberBytes: Int, capture: Capture = .all) {
        self.maximumMemberBytes = max(1, maximumMemberBytes)
        self.capture = capture
    }

    /// Feeds the next chunk. `emit` returns `false` to stop scanning early (the record cap).
    /// Returns `false` once scanning stopped.
    @discardableResult
    mutating func consume(_ chunk: UnsafeBufferPointer<UInt8>, emit: (Member) throws -> Bool) throws -> Bool {
        guard !stopped else { return false }
        var index = 0
        let count = chunk.count
        while index < count {
            let byte = chunk[index]
            switch phase {
            case .start:
                if Self.isWhitespaceOrBOM(byte) { break }
                switch byte {
                case UInt8(ascii: "["): shape = .array; phase = .expectMember
                case UInt8(ascii: "{"): shape = .object; phase = .expectKey
                case UInt8(ascii: "n"): shape = .null; phase = .nullLiteral; literal = [byte]
                default: throw XtreamVODError.invalidResponse
                }
            case .nullLiteral:
                literal.append(byte)
                if literal.count == 4 {
                    guard literal == Array("null".utf8) else { throw XtreamVODError.invalidResponse }
                    isComplete = true
                    phase = .trailing
                }
            case .expectMember:
                if Self.isWhitespace(byte) || byte == UInt8(ascii: ",") { break }
                if byte == UInt8(ascii: "]") { isComplete = true; phase = .trailing; break }
                currentKey = nil
                beginMember(byte)
            case .expectKey:
                if Self.isWhitespace(byte) || byte == UInt8(ascii: ",") { break }
                if byte == UInt8(ascii: "}") { isComplete = true; phase = .trailing; break }
                guard byte == UInt8(ascii: "\"") else { throw XtreamVODError.invalidResponse }
                keyBytes.removeAll(keepingCapacity: true)
                escaped = false
                phase = .key
            case .key:
                if escaped {
                    escaped = false
                    appendKeyByte(byte)
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                    appendKeyByte(byte)
                } else if byte == UInt8(ascii: "\"") {
                    currentKey = String(decoding: keyBytes, as: UTF8.self)
                    phase = .colon
                } else {
                    appendKeyByte(byte)
                }
            case .colon:
                if Self.isWhitespace(byte) { break }
                guard byte == UInt8(ascii: ":") else { throw XtreamVODError.invalidResponse }
                phase = .expectMemberValue
            case .expectMemberValue:
                if Self.isWhitespace(byte) { break }
                beginMember(byte)
            case .compound:
                index = try scanCompound(chunk, from: index, emit: emit)
                if stopped { return false }
                continue
            case .stringScalar:
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { finishScalar() }
            case .bareScalar:
                if Self.isWhitespace(byte) || byte == UInt8(ascii: ",") || byte == UInt8(ascii: "]")
                    || byte == UInt8(ascii: "}") {
                    finishScalar()
                    continue // the delimiter belongs to the container
                }
            case .trailing:
                return true
            }
            index += 1
        }
        return true
    }

    /// Call after the last chunk. A document that ends before its closing bracket is invalid, so
    /// a cut-off transfer can never be mistaken for a smaller catalog.
    mutating func finish() throws {
        if stopped { return }
        switch phase {
        case .start:
            shape = .null // empty body
            isComplete = true
        case .trailing:
            break
        default:
            throw XtreamVODError.invalidResponse
        }
    }

    // MARK: - Members

    private mutating func beginMember(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            memberIsObject = byte == UInt8(ascii: "{")
            depth = 1
            inString = false
            escaped = false
            oversized = false
            memberLength = 1
            capturing = shouldCapture
            buffer.removeAll(keepingCapacity: true)
            if capturing { buffer.append(byte) }
            phase = .compound
        case UInt8(ascii: "\""):
            escaped = false
            phase = .stringScalar
        default:
            phase = .bareScalar
        }
    }

    private var shouldCapture: Bool {
        switch capture {
        case .all: return true
        case .accountOnly: return currentKey == "user_info"
        }
    }

    private mutating func finishScalar() {
        phase = shape == .object ? .expectKey : .expectMember
    }

    /// Scans compound-member bytes from `start`, copying runs in bulk. Returns the next index.
    private mutating func scanCompound(_ chunk: UnsafeBufferPointer<UInt8>, from start: Int,
                                       emit: (Member) throws -> Bool) throws -> Int {
        var index = start
        let count = chunk.count
        while index < count {
            let byte = chunk[index]
            if inString {
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
            } else {
                switch byte {
                case UInt8(ascii: "\""):
                    inString = true
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 {
                        appendRun(chunk, from: start, through: index)
                        let member = Member(bytes: capturing && !oversized ? buffer : nil, key: currentKey,
                                            isObject: memberIsObject, isOversized: oversized)
                        buffer.removeAll(keepingCapacity: !oversized)
                        phase = shape == .object ? .expectKey : .expectMember
                        if try !emit(member) { stopped = true }
                        return index + 1
                    }
                default:
                    break
                }
            }
            index += 1
        }
        appendRun(chunk, from: start, through: count - 1)
        return count
    }

    private mutating func appendRun(_ chunk: UnsafeBufferPointer<UInt8>, from start: Int, through end: Int) {
        guard end >= start else { return }
        let length = end - start + 1
        memberLength += length
        if !oversized && memberLength > maximumMemberBytes {
            oversized = true
            buffer.removeAll(keepingCapacity: false)
        }
        if capturing && !oversized {
            buffer.append(contentsOf: UnsafeBufferPointer(rebasing: chunk[start...end]))
        }
    }

    private mutating func appendKeyByte(_ byte: UInt8) {
        // Keys are IDs or field names; a bounded copy is enough to recognise `user_info`.
        if keyBytes.count < 64 { keyBytes.append(byte) }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }

    private static func isWhitespaceOrBOM(_ byte: UInt8) -> Bool {
        isWhitespace(byte) || byte == 0xEF || byte == 0xBB || byte == 0xBF
    }
}

/// Reads a catalog file in fixed-size chunks and feeds them to a scanner.
enum XtreamVODCatalogFile {
    static let chunkBytes = 1 << 20

    /// Counts object records and detects account rejections without capturing record bytes.
    static func countRecords(at file: URL, limits: XtreamVODCatalogLimits) throws -> Int {
        var scanner = XtreamVODCatalogScanner(maximumMemberBytes: limits.maximumRecordBytes, capture: .accountOnly)
        var records = 0
        try forEachChunk(of: file) { chunk in
            try scanner.consume(chunk) { member in
                if member.key == "user_info" {
                    try XtreamVODParser.rejectAccountObject(member.bytes)
                    return true
                }
                if member.isObject && member.key != "server_info" { records += 1 }
                return true
            }
        }
        try scanner.finish()
        return records
    }

    /// Calls `body` with each chunk; `body` returns `false` to stop reading.
    static func forEachChunk(of file: URL, _ body: (UnsafeBufferPointer<UInt8>) throws -> Bool) throws {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: file) } catch { throw XtreamVODError.storage }
        defer { try? handle.close() }
        while true {
            try Task.checkCancellation()
            let data: Data
            do { data = try handle.read(upToCount: chunkBytes) ?? Data() } catch { throw XtreamVODError.storage }
            if data.isEmpty { return }
            let keepGoing = try data.withUnsafeBytes { raw in
                try body(raw.bindMemory(to: UInt8.self))
            }
            if !keepGoing { return }
        }
    }
}
#endif
