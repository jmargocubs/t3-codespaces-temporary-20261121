import Compression
import CryptoKit
import Foundation

/// Encodes and decodes guide cache files. Every input is untrusted: framing, lengths, the payload
/// digest and each record are checked, and decompression stops at a hard size limit.
///
/// Version 2 (frozen; see `docs/livetv/epg-cache-format.md`). Integers are big-endian.
///
/// | Offset | Size | Field |
/// |---|---|---|
/// | 0 | 4 | Magic `KEPG` |
/// | 4 | 1 | Version, `2` |
/// | 5 | 3 | Reserved, zero |
/// | 8 | 4 | Header length, `156` |
/// | 12 | 16 | Provider ID (UUID bytes) |
/// | 28 | 16 | Content ID, random per write |
/// | 44 | 32 | Source fingerprint (opaque) |
/// | 76 | 8 | `fetchedAt`, IEEE 754 double, seconds since 1970 |
/// | 84 | 8 | Coverage start, whole seconds since 1970; `0` when there are no programmes |
/// | 92 | 8 | Coverage end, likewise |
/// | 100 | 4 | Programme count |
/// | 104 | 4 | Channel count |
/// | 108 | 8 | Compressed payload length; the file ends exactly after the payload |
/// | 116 | 8 | Decompressed payload length |
/// | 124 | 32 | SHA-256 of the compressed payload bytes only |
/// | 156 | n | Payload: one LZFSE stream of the JSON record, with no trailing bytes |
///
/// The payload's LZFSE block headers must end exactly at the end of the file and declare exactly the
/// decompressed length; the stream decoder alone cannot detect trailing data.
///
/// The digest detects corruption; it does not authenticate. Version 1 is `KEPG`, version `1`, then
/// the same LZFSE payload with no header; it is read for migration only, with structural checks
/// but without the version 2 size and length policies, which its writer never applied.
///
/// `maximumDecodedBytes` bounds the decompressed JSON, not peak memory: a load also holds the
/// mapped file, the decoded record and the index it builds.
///
/// Synchronous and CPU-bound: call it from a nonisolated async context, never the main actor.
enum EPGCacheFormat {
    static let headerLength = 156
    static let fingerprintLength = 32

    private static let magic = Data("KEPG".utf8)
    private static let version1: UInt8 = 1
    private static let version2: UInt8 = 2
    private static let digestLength = 32
    /// Year 9999; also keeps every timestamp exactly representable as a double.
    private static let latestSeconds: Int64 = 253_402_300_799

    struct Limits: Sendable {
        var maximumFileBytes = 48 * 1024 * 1024
        var maximumDecodedBytes = 64 * 1024 * 1024
        /// Matches `EPGLimits.maximumIndexedPrograms`.
        var maximumPrograms = 200_000
        /// Matches `EPGLimits.maximumTextLength`, counted in characters.
        var maximumTextLength = 600
        var maximumNames = 200_000
        var maximumIdentifierBytes = 4_096
    }

    struct Header: Equatable, Sendable {
        let providerID: UUID
        let contentID: UUID
        let sourceFingerprint: Data
        let fetchedAt: Date
        /// Nil when the guide has no programmes.
        let coverage: DateInterval?
        let programCount: Int
        let channelCount: Int
        let compressedLength: Int
        let decompressedLength: Int
        let payloadDigest: Data
    }

    // MARK: - Version 2

    /// Builds a whole version 2 file in memory through the same bounded writer the store streams to
    /// disk, so the two can never disagree.
    static func encode(_ index: EPGIndex, providerID: UUID, sourceFingerprint: Data, contentID: UUID = UUID(),
                       limits: Limits = Limits()) throws -> Data {
        let writer = try Writer(index, providerID: providerID, sourceFingerprint: sourceFingerprint,
                                contentID: contentID, limits: limits)
        var file = Data()
        _ = try writer.write(append: { file.append($0) },
                             writeHeader: { file.replaceSubrange(0..<headerLength, with: $0) })
        return file
    }

    /// A guide accepted for a version 2 write. Creating one applies every record check `decode`
    /// applies, before any byte is produced, so a write that starts can fail only on a size limit,
    /// an output error or cancellation, and never produces a file the reader rejects.
    ///
    /// `write` streams the payload instead of building it: rows are encoded `batchRows` at a time by
    /// a `JSONEncoder` with sorted keys, so every batch spells a row the same way, and the JSON is fed
    /// to one LZFSE stream whose state persists across batches and is finalized once. Channel IDs and
    /// names are batched the same way. Memory beyond the guide itself is one batch, its JSON and the
    /// compressor's fixed buffers; the decoded and file size limits are enforced as bytes are produced.
    struct Writer {
        static let batchRows = 512

        let providerID: UUID
        let sourceFingerprint: Data
        let contentID: UUID
        let limits: Limits
        private let index: EPGIndex
        private let channels: ChannelTable
        private let coverage: (start: Int64, end: Int64)?

        init(_ index: EPGIndex, providerID: UUID, sourceFingerprint: Data, contentID: UUID = UUID(),
             limits: Limits = Limits()) throws {
            guard sourceFingerprint.count == fingerprintLength else { throw EPGCacheFormatError.malformedHeader }
            let channels = ChannelTable(index)
            guard channels.programCount <= limits.maximumPrograms,
                  UInt32(exactly: channels.programCount) != nil else { throw EPGCacheFormatError.tooLarge }
            guard isValidFetchTime(index.fetchedAt.timeIntervalSince1970),
                  Record.metadataMeetsLimits(channelIDs: channels.ids, names: index.channelIDsByName,
                                             rowCount: channels.programCount, limits: limits) else {
                throw EPGCacheFormatError.invalidRecord
            }
            var coverage: (start: Int64, end: Int64)?
            try channels.forEachProgram(in: index) { program, position in
                let row = Record.row(program, channel: position)
                guard Record.isStructurallyValid(row, channelCount: channels.ids.count),
                      Record.fits(row, limits), let end = Record.end(row) else {
                    throw EPGCacheFormatError.invalidRecord
                }
                coverage = (min(coverage?.start ?? row.s, row.s), max(coverage?.end ?? end, end))
            }
            self.index = index
            self.channels = channels
            self.coverage = coverage
            self.providerID = providerID
            self.sourceFingerprint = sourceFingerprint
            self.contentID = contentID
            self.limits = limits
        }

        /// Writes the file in order through `append`: a zeroed header, then the payload. Once the
        /// payload is complete, `writeHeader` must overwrite the first `headerLength` bytes with the
        /// real header. Returns that header. `isCurrent` is checked between batches; when it turns
        /// false the write throws `CancellationError` and the caller discards the partial output.
        func write(batchRows: Int = Self.batchRows, isCurrent: () -> Bool = { true },
                   append: (Data) throws -> Void, writeHeader: (Data) throws -> Void) throws -> Header {
            let batchRows = max(1, batchRows)
            func checkCurrent() throws { guard isCurrent() else { throw CancellationError() } }
            try checkCurrent()
            try append(Data(count: headerLength))

            let compressor = try LZFSEStreamEncoder()
            var compressedLength = 0
            var decodedLength = 0
            var digest = SHA256()
            func emit(_ bytes: Data) throws {
                compressedLength += bytes.count
                guard headerLength + compressedLength <= limits.maximumFileBytes else {
                    throw EPGCacheFormatError.tooLarge
                }
                digest.update(data: bytes)
                try append(bytes)
            }
            func payload(_ text: String) throws { try payload(Data(text.utf8)) }
            func payload(_ json: Data) throws {
                decodedLength += json.count
                guard decodedLength <= limits.maximumDecodedBytes else { throw EPGCacheFormatError.tooLarge }
                try compressor.append(json, output: emit)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            /// Appends the members of an encoded array or object without its brackets, preceded by a
            /// comma unless it is the first non-empty batch of its container.
            func members<Value: Encodable>(_ value: Value, continuing: inout Bool) throws {
                let json = try encoder.encode(value)
                guard json.count > 2 else { return }
                if continuing { try payload(",") }
                try payload(json.dropFirst().dropLast())
                continuing = true
            }

            // Keys in sorted order, matching the rows' own sorted keys.
            try payload(#"{"channelIDs":["#)
            var continuing = false
            for start in stride(from: 0, to: channels.ids.count, by: batchRows) {
                try members(Array(channels.ids[start..<min(start + batchRows, channels.ids.count)]),
                            continuing: &continuing)
            }
            try payload(#"],"fetchedAt":"#)
            continuing = false
            try members([index.fetchedAt.timeIntervalSince1970], continuing: &continuing)
            try payload(#","names":{"#)
            let nameKeys = index.channelIDsByName.keys.sorted()
            continuing = false
            for start in stride(from: 0, to: nameKeys.count, by: batchRows) {
                try checkCurrent()
                var batch: [String: String] = [:]
                for key in nameKeys[start..<min(start + batchRows, nameKeys.count)] {
                    batch[key] = index.channelIDsByName[key]
                }
                try members(batch, continuing: &continuing)
            }
            try payload(#"},"rows":["#)
            continuing = false
            var rows: [Record.Row] = []
            rows.reserveCapacity(batchRows)
            try channels.forEachProgram(in: index) { program, position in
                rows.append(Record.row(program, channel: position))
                guard rows.count == batchRows else { return }
                try checkCurrent()
                try members(rows, continuing: &continuing)
                rows.removeAll(keepingCapacity: true)
            }
            try members(rows, continuing: &continuing)
            try payload("]}")
            try checkCurrent()
            try compressor.finish(output: emit)

            let header = Header(
                providerID: providerID, contentID: contentID, sourceFingerprint: sourceFingerprint,
                fetchedAt: Date(timeIntervalSince1970: index.fetchedAt.timeIntervalSince1970),
                coverage: coverage.map {
                    DateInterval(start: Date(timeIntervalSince1970: TimeInterval($0.start)),
                                 end: Date(timeIntervalSince1970: TimeInterval($0.end)))
                },
                programCount: channels.programCount, channelCount: channels.ids.count,
                compressedLength: compressedLength, decompressedLength: decodedLength,
                payloadDigest: Data(digest.finalize()))
            try writeHeader(headerBytes(header))
            return header
        }

        private func headerBytes(_ header: Header) -> Data {
            var file = Data(capacity: headerLength)
            file.append(magic)
            file.append(contentsOf: [version2, 0, 0, 0])
            file.appendBigEndian(UInt32(headerLength))
            file.append(header.providerID.data)
            file.append(header.contentID.data)
            file.append(header.sourceFingerprint)
            file.appendBigEndian(index.fetchedAt.timeIntervalSince1970.bitPattern)
            file.appendBigEndian(UInt64(bitPattern: coverage?.start ?? 0))
            file.appendBigEndian(UInt64(bitPattern: coverage?.end ?? 0))
            file.appendBigEndian(UInt32(header.programCount))
            file.appendBigEndian(UInt32(header.channelCount))
            file.appendBigEndian(UInt64(header.compressedLength))
            file.appendBigEndian(UInt64(header.decompressedLength))
            file.append(header.payloadDigest)
            assert(file.count == headerLength)
            return file
        }
    }

    /// Reads and validates the header alone. `prefix` holds at least the file's first
    /// `headerLength` bytes; `fileSize` is the size of the whole file.
    static func header(of prefix: Data, fileSize: Int, limits: Limits = Limits()) throws -> Header {
        let bytes = Data(prefix.prefix(headerLength))
        guard bytes.count >= magic.count + 1, bytes.prefix(magic.count) == magic else {
            throw bytes.count < magic.count + 1 ? EPGCacheFormatError.truncated : EPGCacheFormatError.unrecognized
        }
        let version = bytes[magic.count]
        guard version == version2 else { throw EPGCacheFormatError.unsupportedVersion(version) }
        guard bytes.count == headerLength, fileSize >= headerLength else { throw EPGCacheFormatError.truncated }
        guard fileSize <= limits.maximumFileBytes else { throw EPGCacheFormatError.tooLarge }

        var reader = ByteReader(bytes, offset: 5)
        guard reader.bytes(3).allSatisfy({ $0 == 0 }), reader.uint32() == UInt32(headerLength) else {
            throw EPGCacheFormatError.malformedHeader
        }
        let providerID = UUID(data: reader.bytes(16))
        let contentID = UUID(data: reader.bytes(16))
        let fingerprint = reader.bytes(fingerprintLength)
        let fetchedAt = Double(bitPattern: reader.uint64())
        let coverageStart = Int64(bitPattern: reader.uint64())
        let coverageEnd = Int64(bitPattern: reader.uint64())
        let programCount = Int(reader.uint32())
        let channelCount = Int(reader.uint32())
        let compressedLength = reader.uint64()
        let decompressedLength = reader.uint64()
        let digest = reader.bytes(digestLength)

        guard isValidFetchTime(fetchedAt),
              programCount <= limits.maximumPrograms,
              channelCount <= programCount, (programCount == 0) == (channelCount == 0) else {
            throw EPGCacheFormatError.malformedHeader
        }
        let coverage: DateInterval?
        if programCount == 0 {
            guard coverageStart == 0, coverageEnd == 0 else { throw EPGCacheFormatError.malformedHeader }
            coverage = nil
        } else {
            guard isValidSeconds(coverageStart), isValidSeconds(coverageEnd), coverageStart < coverageEnd else {
                throw EPGCacheFormatError.malformedHeader
            }
            coverage = DateInterval(start: Date(timeIntervalSince1970: TimeInterval(coverageStart)),
                                    end: Date(timeIntervalSince1970: TimeInterval(coverageEnd)))
        }
        guard compressedLength > 0, compressedLength == UInt64(fileSize - headerLength) else {
            throw EPGCacheFormatError.lengthMismatch
        }
        guard decompressedLength > 0 else { throw EPGCacheFormatError.malformedHeader }
        guard decompressedLength <= UInt64(limits.maximumDecodedBytes) else { throw EPGCacheFormatError.tooLarge }

        return Header(providerID: providerID, contentID: contentID, sourceFingerprint: fingerprint,
                      fetchedAt: Date(timeIntervalSince1970: fetchedAt), coverage: coverage,
                      programCount: programCount, channelCount: channelCount,
                      compressedLength: Int(compressedLength), decompressedLength: Int(decompressedLength),
                      payloadDigest: digest)
    }

    /// Validates the whole file, then decodes it. The digest is checked before decompression, and
    /// the decoded record must agree with every header field.
    static func decode(_ file: Data, providerID: UUID,
                       limits: Limits = Limits()) throws -> (header: Header, index: EPGIndex) {
        let fileHeader = try header(of: file, fileSize: file.count, limits: limits)
        guard fileHeader.providerID == providerID else { throw EPGCacheFormatError.wrongProvider }
        let payload = file.dropFirst(headerLength)
        guard constantTimeEqual(Data(SHA256.hash(data: payload)), fileHeader.payloadDigest) else {
            throw EPGCacheFormatError.digestMismatch
        }
        let record = try decodePayload(payload, declaredLength: fileHeader.decompressedLength, limits: limits)
        guard record.meetsLimits(limits) else { throw EPGCacheFormatError.invalidRecord }
        guard Date(timeIntervalSince1970: record.fetchedAt) == fileHeader.fetchedAt,
              record.rows.count == fileHeader.programCount, record.channelIDs.count == fileHeader.channelCount,
              record.coverage?.start == fileHeader.coverage.map({ Int64($0.start.timeIntervalSince1970) }),
              record.coverage?.end == fileHeader.coverage.map({ Int64($0.end.timeIntervalSince1970) }) else {
            throw EPGCacheFormatError.mismatchedMetadata
        }
        guard let index = record.index() else { throw EPGCacheFormatError.invalidRecord }
        return (fileHeader, index)
    }

    /// True when `file` is byte-for-byte the file whose fully validated header is `verified`: its
    /// header is valid and identical, including the random content ID and the payload digest, and
    /// its payload still hashes to that digest. Lets a caller rely on an earlier full `decode` of
    /// the same file without decompressing or decoding it again. Never a substitute for `decode`
    /// on a file that was not fully validated.
    static func isUnchanged(_ file: Data, since verified: Header, limits: Limits = Limits()) -> Bool {
        guard let current = try? header(of: file, fileSize: file.count, limits: limits), current == verified else {
            return false
        }
        return constantTimeEqual(Data(SHA256.hash(data: file.dropFirst(headerLength))), current.payloadDigest)
    }

    // MARK: - Version 1

    /// Writes version 1 as the Milestone 1 writer did; until migration lands the store still uses it.
    static func encodeVersion1(_ index: EPGIndex, limits: Limits = Limits()) throws -> Data {
        let record = Record(index)
        guard record.isStructurallyValid else { throw EPGCacheFormatError.invalidRecord }
        let (_, compressed) = try encodePayload(record, limits: limits)
        var file = magic
        file.append(version1)
        file.append(compressed)
        guard file.count <= limits.maximumFileBytes else { throw EPGCacheFormatError.tooLarge }
        return file
    }

    /// Decodes a version 1 file. It declares no lengths, so its block headers and the decoded-size
    /// limit bound it. `tooLarge` means the file may be valid but exceeds this build's limits.
    static func decodeVersion1(_ file: Data, limits: Limits = Limits()) throws -> EPGIndex {
        guard file.count <= limits.maximumFileBytes else { throw EPGCacheFormatError.tooLarge }
        guard file.count > magic.count + 1 else { throw EPGCacheFormatError.truncated }
        guard file.prefix(magic.count) == magic else { throw EPGCacheFormatError.unrecognized }
        let version = file[file.startIndex + magic.count]
        guard version == version1 else { throw EPGCacheFormatError.unsupportedVersion(version) }
        let record = try decodePayload(file.dropFirst(magic.count + 1), declaredLength: nil, limits: limits)
        guard let index = record.index() else { throw EPGCacheFormatError.invalidRecord }
        return index
    }

    // MARK: - Payload

    /// Version 1's one-shot payload. Callers validate the record first.
    private static func encodePayload(_ record: Record, limits: Limits) throws -> (json: Data, compressed: Data) {
        let json = try JSONEncoder().encode(record)
        guard json.count <= limits.maximumDecodedBytes else { throw EPGCacheFormatError.tooLarge }
        return (json, try (json as NSData).compressed(using: .lzfse) as Data)
    }

    /// Streams the payload through a bounded LZFSE decoder into a buffer of exactly the size its
    /// block headers declare, which is checked against the limit before anything is allocated. The
    /// decoder itself also stops at that size. The buffer is released when this returns, before the
    /// caller builds the index. Not cancellable, so a cancelled caller cannot make a valid file look
    /// corrupt. Returns a structurally valid record; policy limits are the caller's choice.
    private static func decodePayload(_ payload: Data, declaredLength: Int?, limits: Limits) throws -> Record {
        guard let framing = lzfseFraming(payload), framing.length == payload.count else {
            throw EPGCacheFormatError.corruptPayload
        }
        guard framing.decodedBytes <= limits.maximumDecodedBytes else { throw EPGCacheFormatError.tooLarge }
        if let declaredLength, framing.decodedBytes != declaredLength { throw EPGCacheFormatError.lengthMismatch }
        guard framing.decodedBytes > 0 else { throw EPGCacheFormatError.corruptPayload }
        var json = Data()
        json.reserveCapacity(framing.decodedBytes)
        do {
            try payload.withUnsafeBytes { raw in
                try EPGPayloadDecoder.decode(raw.bindMemory(to: UInt8.self), algorithm: COMPRESSION_LZFSE,
                                             into: &json, maximumBytes: framing.decodedBytes,
                                             checksCancellation: false)
            }
        } catch EPGError.responseTooLarge {
            throw EPGCacheFormatError.corruptPayload  // blocks produced more than they declared
        } catch EPGError.corruptCompressedData {
            throw EPGCacheFormatError.corruptPayload
        }
        guard json.count == framing.decodedBytes else { throw EPGCacheFormatError.corruptPayload }
        guard let record = try? JSONDecoder().decode(Record.self, from: json),
              record.isStructurallyValid else { throw EPGCacheFormatError.invalidRecord }
        return record
    }

    /// Walks LZFSE block headers without decoding, returning the length of the first stream and the
    /// size its blocks declare. Apple's stream decoder stops at the end-of-stream block but consumes
    /// whatever follows it, so trailing or concatenated data is found here instead. Block layouts
    /// follow the LZFSE reference implementation (`lzfse_internal.h`, lzfse/lzfse@e634ca58); an
    /// unknown or overrunning block returns nil.
    static func lzfseFraming(_ payload: Data) -> (length: Int, decodedBytes: Int)? {
        payload.withUnsafeBytes { raw -> (length: Int, decodedBytes: Int)? in
            func little(_ offset: Int, _ width: Int) -> UInt64? {
                guard offset >= 0, offset + width <= raw.count else { return nil }
                return (0..<width).reduce(UInt64(0)) { $0 | UInt64(raw[offset + $1]) << (8 * UInt64($1)) }
            }
            var offset = 0
            var decodedBytes = 0
            while let magic = little(offset, 4) {
                let blockLength: UInt64
                switch magic {
                case 0x2478_7662:  // "bvx$": end of stream
                    return (offset + 4, decodedBytes)
                case 0x2D78_7662:  // "bvx-": raw size, then the raw bytes
                    guard let rawBytes = little(offset + 4, 4) else { return nil }
                    blockLength = 8 + rawBytes
                case 0x6E78_7662:  // "bvxn": LZVN; raw size, payload size, then the payload
                    guard let payloadBytes = little(offset + 8, 4) else { return nil }
                    blockLength = 12 + payloadBytes
                case 0x3178_7662:  // "bvx1": the C header struct, 772 bytes with padding, then the payloads
                    guard let literalBytes = little(offset + 20, 4), let commandBytes = little(offset + 24, 4) else {
                        return nil
                    }
                    blockLength = 772 + literalBytes + commandBytes
                case 0x3278_7662:  // "bvx2": header size and payload sizes are packed bit fields
                    guard let fields0 = little(offset + 8, 8), let fields1 = little(offset + 16, 8),
                          let fields2 = little(offset + 24, 8) else { return nil }
                    let headerBytes = fields2 & 0xFFFF_FFFF
                    guard headerBytes >= 32 else { return nil }
                    let literalBytes = (fields0 >> 20) & 0xF_FFFF
                    let commandBytes = (fields1 >> 40) & 0xF_FFFF
                    blockLength = headerBytes + literalBytes + commandBytes
                default:
                    return nil
                }
                guard let rawBytes = little(offset + 4, 4), blockLength <= UInt64(raw.count - offset) else {
                    return nil
                }
                offset += Int(blockLength)
                decodedBytes += Int(rawBytes)
                // Larger than any cache could be; also keeps the sum far from overflow.
                guard decodedBytes <= Int(UInt32.max) else { return nil }
            }
            return nil
        }
    }

    private static func isValidSeconds(_ value: Int64) -> Bool { (0...latestSeconds).contains(value) }

    private static func isValidFetchTime(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= Double(latestSeconds)
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Compact JSON form shared by both versions: channel IDs are stored once, times as whole seconds.
    private struct Record: Codable {
        struct Row: Codable {
            let c: Int
            let s: Int64
            let d: Int32
            let t: String
            let st: String?
            let ds: String?
            let g: String?
            let e: String?
        }

        let fetchedAt: Double
        let channelIDs: [String]
        let names: [String: String]
        let rows: [Row]

        init(_ index: EPGIndex) {
            let channels = ChannelTable(index)
            var rows: [Row] = []
            rows.reserveCapacity(channels.programCount)
            channels.forEachProgram(in: index) { program, position in
                rows.append(Self.row(program, channel: position))
            }
            fetchedAt = index.fetchedAt.timeIntervalSince1970
            channelIDs = channels.ids
            names = index.channelIDsByName
            self.rows = rows
        }

        static func row(_ program: EPGProgram, channel: Int) -> Row {
            let start = seconds(program.start)
            return Row(c: channel, s: start, d: Int32(clamping: seconds(program.end) - start), t: program.title,
                       st: program.subtitle, ds: program.summary, g: program.category, e: program.episode)
        }

        /// Whole seconds since 1970, clamped just outside the valid range so validation rejects it
        /// instead of the conversion trapping.
        private static func seconds(_ date: Date) -> Int64 {
            let value = date.timeIntervalSince1970.rounded()
            guard value.isFinite else { return -1 }
            return Int64(min(max(value, -1), Double(latestSeconds) + 1))
        }

        /// End of a row in whole seconds, or nil if the addition overflows.
        static func end(_ row: Row) -> Int64? {
            let (end, overflow) = row.s.addingReportingOverflow(Int64(row.d))
            return overflow ? nil : end
        }

        /// Earliest start and latest end in whole seconds; nil without programmes or on overflow.
        var coverage: (start: Int64, end: Int64)? {
            var range: (start: Int64, end: Int64)?
            for row in rows {
                guard let end = Self.end(row) else { return nil }
                range = (min(range?.start ?? row.s, row.s), max(range?.end ?? end, end))
            }
            return range
        }

        /// Checks every version needs before an index is built: times and indexes in range.
        var isStructurallyValid: Bool {
            guard isValidFetchTime(fetchedAt) else { return false }
            return rows.allSatisfy { Self.isStructurallyValid($0, channelCount: channelIDs.count) }
        }

        static func isStructurallyValid(_ row: Row, channelCount: Int) -> Bool {
            guard (0..<channelCount).contains(row.c), row.d > 0, isValidSeconds(row.s),
                  let end = end(row) else { return false }
            return isValidSeconds(end)
        }

        /// Version 2 policy: bounds every count and string, which the Milestone 1 writer did not.
        func meetsLimits(_ limits: Limits) -> Bool {
            Self.metadataMeetsLimits(channelIDs: channelIDs, names: names, rowCount: rows.count, limits: limits)
                && rows.allSatisfy { Self.fits($0, limits) }
        }

        static func metadataMeetsLimits(channelIDs: [String], names: [String: String], rowCount: Int,
                                        limits: Limits) -> Bool {
            rowCount <= limits.maximumPrograms
                && channelIDs.count <= rowCount && names.count <= limits.maximumNames
                && Set(channelIDs).count == channelIDs.count
                && channelIDs.allSatisfy({ $0.utf8.count <= limits.maximumIdentifierBytes })
                && names.allSatisfy({ $0.key.utf8.count <= limits.maximumIdentifierBytes
                                      && $0.value.utf8.count <= limits.maximumIdentifierBytes })
        }

        static func fits(_ row: Row, _ limits: Limits) -> Bool {
            func fits(_ text: String?) -> Bool { (text?.count ?? 0) <= limits.maximumTextLength }
            return fits(row.t) && fits(row.st) && fits(row.ds) && fits(row.g) && fits(row.e)
        }

        func index() -> EPGIndex? {
            var grouped: [String: [EPGProgram]] = [:]
            for row in rows {
                guard channelIDs.indices.contains(row.c), row.d > 0,
                      let key = EPGChannelKey.guideID(channelIDs[row.c]) else { return nil }
                let start = Date(timeIntervalSince1970: TimeInterval(row.s))
                grouped[key, default: []].append(EPGProgram(
                    channelID: channelIDs[row.c], start: start, end: start.addingTimeInterval(TimeInterval(row.d)),
                    title: row.t, subtitle: row.st, summary: row.ds, category: row.g, episode: row.e))
            }
            // Rows were written in airing order per channel; reject a file that is not.
            for list in grouped.values where zip(list, list.dropFirst()).contains(where: { $0.end > $1.start }) {
                return nil
            }
            return EPGIndex(fetchedAt: Date(timeIntervalSince1970: fetchedAt), programsByChannel: grouped,
                            channelIDsByName: names, statistics: EPGIndex.Statistics())
        }
    }
}

extension EPGCacheFormat {
    /// The record's channel list: guide keys in sorted order, each programme's channel ID numbered
    /// by first appearance. Rows refer to channels by that number, and are written in this order.
    fileprivate struct ChannelTable {
        let keys: [String]
        let ids: [String]
        let positions: [String: Int]
        let programCount: Int

        init(_ index: EPGIndex) {
            var ids: [String] = []
            var positions: [String: Int] = [:]
            var count = 0
            let keys = index.programsByChannel.keys.sorted()
            for key in keys {
                for program in index.programsByChannel[key] ?? [] where positions[program.channelID] == nil {
                    positions[program.channelID] = ids.count
                    ids.append(program.channelID)
                }
                count += index.programsByChannel[key]?.count ?? 0
            }
            self.keys = keys
            self.ids = ids
            self.positions = positions
            programCount = count
        }

        func forEachProgram(in index: EPGIndex, _ body: (EPGProgram, Int) throws -> Void) rethrows {
            for key in keys {
                for program in index.programsByChannel[key] ?? [] {
                    // Every channel ID was numbered from this same index.
                    try body(program, positions[program.channelID]!)
                }
            }
        }
    }
}

/// One LZFSE stream compressed incrementally. The stream state persists across `append` calls and
/// is finalized once, so the output is a single stream of the concatenated input, never a series
/// of restarted ones. Output is handed on through a fixed scratch buffer as it is produced.
private final class LZFSEStreamEncoder {
    private static let chunkSize = 64 * 1024
    private let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
    private var isOpen = false

    init() throws {
        guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK else {
            throw EPGCacheFormatError.compressionFailed
        }
        isOpen = true
    }

    deinit {
        if isOpen { compression_stream_destroy(stream) }
        stream.deallocate()
        buffer.deallocate()
    }

    func append(_ input: Data, output: (Data) throws -> Void) throws {
        guard isOpen else { throw EPGCacheFormatError.compressionFailed }
        try input.withUnsafeBytes { raw in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress, !raw.isEmpty else { return }
            stream.pointee.src_ptr = source
            stream.pointee.src_size = raw.count
            while stream.pointee.src_size > 0 {
                let remaining = stream.pointee.src_size
                let produced = try process(flags: 0, output: output)
                // Each call consumes input or produces output; neither means the encoder is stuck.
                guard produced > 0 || stream.pointee.src_size < remaining else {
                    throw EPGCacheFormatError.compressionFailed
                }
            }
        }
    }

    func finish(output: (Data) throws -> Void) throws {
        guard isOpen else { throw EPGCacheFormatError.compressionFailed }
        stream.pointee.src_ptr = UnsafePointer(buffer)
        stream.pointee.src_size = 0
        while true {
            let (produced, status) = try step(flags: Int32(COMPRESSION_STREAM_FINALIZE.rawValue), output: output)
            if status == COMPRESSION_STATUS_END { break }
            guard produced > 0 else { throw EPGCacheFormatError.compressionFailed }
        }
        compression_stream_destroy(stream)
        isOpen = false
    }

    private func process(flags: Int32, output: (Data) throws -> Void) throws -> Int {
        let (produced, status) = try step(flags: flags, output: output)
        guard status == COMPRESSION_STATUS_OK else { throw EPGCacheFormatError.compressionFailed }
        return produced
    }

    private func step(flags: Int32, output: (Data) throws -> Void) throws -> (Int, compression_status) {
        stream.pointee.dst_ptr = buffer
        stream.pointee.dst_size = Self.chunkSize
        let status = compression_stream_process(stream, flags)
        guard status != COMPRESSION_STATUS_ERROR else { throw EPGCacheFormatError.compressionFailed }
        let produced = Self.chunkSize - stream.pointee.dst_size
        if produced > 0 { try output(Data(bytes: buffer, count: produced)) }
        return (produced, status)
    }
}

enum EPGCacheFormatError: Error, Equatable, Sendable {
    case truncated
    case unrecognized
    case unsupportedVersion(UInt8)
    case malformedHeader
    case lengthMismatch
    case tooLarge
    case wrongProvider
    case digestMismatch
    case corruptPayload
    case invalidRecord
    case mismatchedMetadata
    /// The compressor failed while writing; nothing about the guide is wrong.
    case compressionFailed
}

/// Sequential big-endian reads over a buffer whose length the caller has already checked.
private struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data, offset: Int) {
        self.data = data
        self.offset = data.startIndex + offset
    }

    mutating func bytes(_ count: Int) -> Data {
        defer { offset += count }
        return Data(data[offset..<offset + count])
    }

    mutating func uint32() -> UInt32 { bytes(4).reduce(0) { $0 << 8 | UInt32($1) } }
    mutating func uint64() -> UInt64 { bytes(8).reduce(0) { $0 << 8 | UInt64($1) } }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

private extension UUID {
    init(data: Data) {
        var bytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        Swift.withUnsafeMutableBytes(of: &bytes) { $0.copyBytes(from: data.prefix(16)) }
        self.init(uuid: bytes)
    }

    var data: Data { Swift.withUnsafeBytes(of: uuid) { Data($0) } }
}
