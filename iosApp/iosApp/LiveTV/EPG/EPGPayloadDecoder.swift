import Compression
import Foundation

/// Turns a downloaded guide into XML bytes, decompressing `guide.xml.gz` and `guide.xml.xz` feeds
/// with Apple's Compression framework so Kyro needs no third-party decompressor.
///
/// Telly's `CompressedXmltv` (MIT, johnpc/telly-apple@66c74301) sniffs the same magic bytes but
/// uses SWCompression and passes undecodable data through. Kyro fails clearly on a corrupt or
/// truncated archive and bounds the decompressed size so a small download cannot expand without
/// limit. Servers that send `Content-Encoding: gzip` are already decoded by `URLSession`.
///
/// Synchronous and CPU-bound: call it from a nonisolated async context, never the main actor.
enum EPGPayloadDecoder {
    private static let gzipMagic: [UInt8] = [0x1F, 0x8B]
    private static let xzMagic: [UInt8] = [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]
    private static let unsupportedMagic: [[UInt8]] = [[0x50, 0x4B, 0x03, 0x04], [0x42, 0x5A, 0x68]]  // zip, bzip2
    private static let chunkSize = 256 * 1024

    static func xmlData(from data: Data, maximumBytes: Int) throws -> Data {
        try Task.checkCancellation()
        if data.starts(with: gzipMagic) { return try gunzip(data, maximumBytes: maximumBytes) }
        if data.starts(with: xzMagic) {
            return try data.withUnsafeBytes { raw in
                var output = Data()
                try decode(raw.bindMemory(to: UInt8.self), algorithm: COMPRESSION_LZMA,
                           into: &output, maximumBytes: maximumBytes)
                return output
            }
        }
        if unsupportedMagic.contains(where: { data.starts(with: $0) }) { throw EPGError.unsupportedCompression }
        guard data.count <= maximumBytes else { throw EPGError.responseTooLarge }
        return data
    }

    /// Decodes every gzip member in turn, checking each member's stored length.
    ///
    /// Compression's deflate decoder stops at the final block but also consumes whatever follows
    /// it, so it cannot report where a member ends. The boundary is found instead from the decoded
    /// size: the next member's header must follow a trailer whose stored size matches.
    private static func gunzip(_ data: Data, maximumBytes: Int) throws -> Data {
        try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var output = Data()
            var offset = 0
            while true {
                let deflateStart = offset + (try gzipHeaderLength(bytes, at: offset))
                let memberStart = output.count
                try decode(UnsafeBufferPointer(rebasing: bytes[deflateStart...]), algorithm: COMPRESSION_ZLIB,
                           into: &output, maximumBytes: maximumBytes)
                let size = UInt32(truncatingIfNeeded: output.count - memberStart)
                if let next = nextMember(in: bytes, after: deflateStart, size: size) {
                    offset = next
                    continue
                }
                guard bytes.count - 8 >= deflateStart, storedSize(bytes, at: bytes.count - 4) == size else {
                    throw EPGError.corruptCompressedData
                }
                return output
            }
        }
    }

    /// Start of the member after one whose decoded size is `size`, if another member follows.
    private static func nextMember(in bytes: UnsafeBufferPointer<UInt8>, after start: Int, size: UInt32) -> Int? {
        var trailer = start
        while trailer + 11 <= bytes.count {
            if bytes[trailer + 8] == 0x1F, bytes[trailer + 9] == 0x8B, bytes[trailer + 10] == 8,
               storedSize(bytes, at: trailer + 4) == size {
                return trailer + 8
            }
            trailer += 1
        }
        return nil
    }

    private static func storedSize(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }

    /// Length of the RFC 1952 member header at `offset`.
    private static func gzipHeaderLength(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) throws -> Int {
        let count = bytes.count
        guard offset + 10 <= count, bytes[offset] == 0x1F, bytes[offset + 1] == 0x8B,
              bytes[offset + 2] == 8, bytes[offset + 3] & 0xE0 == 0 else { throw EPGError.corruptCompressedData }
        let flags = bytes[offset + 3]
        var position = offset + 10
        if flags & 0x04 != 0 {
            guard position + 2 <= count else { throw EPGError.corruptCompressedData }
            position += 2 + (Int(bytes[position]) | Int(bytes[position + 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while position < count, bytes[position] != 0 { position += 1 }
            position += 1
        }
        if flags & 0x02 != 0 { position += 2 }
        guard position < count else { throw EPGError.corruptCompressedData }
        return position - offset
    }

    /// Streams `input` through a decoder until the compressed stream ends, appending to `output`.
    ///
    /// Each call offers the decoder at most the remaining allowance plus one byte, so output past
    /// `maximumBytes` is detected by that one probe byte and never appended. The scratch buffer stays
    /// `chunkSize` bytes.
    static func decode(_ input: UnsafeBufferPointer<UInt8>, algorithm: compression_algorithm,
                       into output: inout Data, maximumBytes: Int, checksCancellation: Bool = true) throws {
        guard let source = input.baseAddress, !input.isEmpty else { throw EPGError.corruptCompressedData }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else {
            throw EPGError.corruptCompressedData
        }
        defer { compression_stream_destroy(stream) }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }
        stream.pointee.src_ptr = source
        stream.pointee.src_size = input.count
        var chunks = 0
        while true {
            let allowance = max(0, maximumBytes - output.count)
            let capacity = allowance < chunkSize ? allowance + 1 : chunkSize
            stream.pointee.dst_ptr = buffer
            stream.pointee.dst_size = capacity
            let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            let produced = capacity - stream.pointee.dst_size
            if produced > 0 {
                guard produced <= allowance else { throw EPGError.responseTooLarge }
                output.append(buffer, count: produced)
            }
            switch status {
            case COMPRESSION_STATUS_END:
                return
            case COMPRESSION_STATUS_OK:
                // No output and no input left means the archive ended early.
                guard produced > 0 || stream.pointee.src_size > 0 else { throw EPGError.corruptCompressedData }
            default:
                throw EPGError.corruptCompressedData
            }
            chunks += 1
            if checksCancellation, chunks % 16 == 0 { try Task.checkCancellation() }
        }
    }
}
