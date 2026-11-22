import Compression
import CryptoKit
import XCTest
@testable import Silo

final class EPGCacheFormatTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000.25)
    private let provider = UUID()
    private let fingerprint = Data((0..<32).map { UInt8($0) })

    // MARK: - Round trip and layout

    func testVersion2RoundTripsAndPinsTheFrozenLayout() throws {
        let index = guide()
        let contentID = UUID()
        let file = try EPGCacheFormat.encode(index, providerID: provider, sourceFingerprint: fingerprint,
                                             contentID: contentID)

        XCTAssertEqual(Array(file.prefix(12)), Array("KEPG".utf8) + [2, 0, 0, 0, 0, 0, 0, 156])
        XCTAssertEqual(file[12..<28], provider.bytes)
        XCTAssertEqual(file[124..<156], Data(SHA256.hash(data: file.dropFirst(156))),
                       "the digest covers the compressed payload only")

        let (header, restored) = try EPGCacheFormat.decode(file, providerID: provider)
        XCTAssertEqual(restored.fetchedAt, now, "fractional fetch times survive")
        XCTAssertEqual(restored.programsByChannel, index.programsByChannel)
        XCTAssertEqual(restored.channelIDsByName, index.channelIDsByName)
        XCTAssertEqual(header.contentID, contentID)
        XCTAssertEqual(header.sourceFingerprint, fingerprint)
        XCTAssertEqual(header.programCount, 3)
        XCTAssertEqual(header.channelCount, 2)
        XCTAssertEqual(header.coverage, DateInterval(start: at(-30), end: at(120)))
        XCTAssertEqual(header.compressedLength, file.count - 156)

        let headerOnly = try EPGCacheFormat.header(of: file.prefix(156), fileSize: file.count)
        XCTAssertEqual(headerOnly, header, "freshness facts are readable without decompressing")
    }

    func testEmptyGuideRoundTripsWithoutCoverage() throws {
        let empty = EPGIndex.empty(fetchedAt: now)
        let file = try EPGCacheFormat.encode(empty, providerID: provider, sourceFingerprint: fingerprint)
        let (header, restored) = try EPGCacheFormat.decode(file, providerID: provider)
        XCTAssertNil(header.coverage)
        XCTAssertEqual(header.programCount, 0)
        XCTAssertEqual(restored.programCount, 0)
        XCTAssertEqual(restored.fetchedAt, now)
    }

    // MARK: - Framing

    func testMalformedFramingIsRejected() throws {
        let file = try validFile()
        assertDecode(Data(), throws: .truncated)
        assertDecode(Data("KEPX".utf8) + file.dropFirst(4), throws: .unrecognized)
        assertDecode(patched(file, at: 4, [3]), throws: .unsupportedVersion(3))
        assertDecode(patched(file, at: 5, [0, 1, 0]), throws: .malformedHeader, "reserved bytes must be zero")
        assertDecode(patched(file, at: 8, uint32(157)), throws: .malformedHeader)
        assertDecode(file.prefix(155), throws: .truncated)
        for cut in [156, 157, file.count - 1] {
            assertDecode(file.prefix(cut), throws: .lengthMismatch, "cut at \(cut)")
        }
        assertDecode(file + Data([0]), throws: .lengthMismatch, "bytes after the payload")
        assertDecode(file, provider: UUID(), throws: .wrongProvider)
    }

    func testHeaderFieldsAreBoundedBeforeAnyAllocation() throws {
        let file = try validFile()
        assertDecode(patched(file, at: 116, uint64(64 * 1024 * 1024 + 1)), throws: .tooLarge)
        assertDecode(patched(file, at: 116, uint64(0)), throws: .malformedHeader)
        assertDecode(patched(file, at: 100, uint32(200_001)), throws: .malformedHeader, "programme count")
        assertDecode(patched(file, at: 104, uint32(4)), throws: .malformedHeader, "more channels than programmes")
        assertDecode(patched(file, at: 84, uint64(UInt64(bitPattern: -1))), throws: .malformedHeader)
        assertDecode(patched(file, at: 84, uint64(2_000_000_000)), throws: .malformedHeader, "coverage ends before it starts")
        assertDecode(patched(file, at: 76, uint64(Double.nan.bitPattern)), throws: .malformedHeader)

        var limits = EPGCacheFormat.Limits()
        limits.maximumFileBytes = file.count - 1
        XCTAssertThrowsError(try EPGCacheFormat.header(of: file, fileSize: file.count, limits: limits)) {
            XCTAssertEqual($0 as? EPGCacheFormatError, .tooLarge)
        }
    }

    // MARK: - Integrity

    func testDigestIsVerifiedBeforeDecompression() throws {
        let file = try validFile()
        // A flipped payload byte that would otherwise fail decompression reports the digest instead.
        assertDecode(patched(file, at: file.count - 1, [file.last! ^ 0xFF]), throws: .digestMismatch)
        assertDecode(patched(file, at: 130, [file[130] ^ 0x01]), throws: .digestMismatch)
    }

    func testDeclaredLengthMustMatchTheStream() throws {
        let file = try validFile()
        let declared = Int(try EPGCacheFormat.header(of: file, fileSize: file.count).decompressedLength)
        assertDecode(patched(file, at: 116, uint64(UInt64(declared - 1))), throws: .lengthMismatch)
        assertDecode(patched(file, at: 116, uint64(UInt64(declared + 1))), throws: .lengthMismatch)
    }

    func testStreamingDecoderStopsAtTheDecodedLimit() throws {
        let bomb = try lzfse(Data(repeating: 0x20, count: 4 * 1024 * 1024))
        XCTAssertLessThan(bomb.count, 64 * 1024, "a small file that expands a lot")
        var limits = EPGCacheFormat.Limits()
        limits.maximumDecodedBytes = 1024 * 1024
        XCTAssertThrowsError(try EPGCacheFormat.decodeVersion1(Data("KEPG\u{1}".utf8) + bomb, limits: limits)) {
            XCTAssertEqual($0 as? EPGCacheFormatError, .tooLarge)
        }
        assertDecode(forged(payload: bomb, decodedLength: 4 * 1024 * 1024), limits: limits, throws: .tooLarge)

        // The decoder enforces the cap itself too, in case block headers understate their output.
        var output = Data()
        XCTAssertThrowsError(try streamDecode(bomb, into: &output, maximumBytes: limits.maximumDecodedBytes)) {
            XCTAssertEqual($0 as? EPGError, .responseTooLarge)
        }
        XCTAssertLessThanOrEqual(output.count, limits.maximumDecodedBytes, "output never passes the cap")
    }

    func testStreamingDecoderOffersOnlyTheRemainingAllowance() throws {
        // Sizes straddle the 256 KiB scratch buffer so the one-byte probe lands mid-chunk and on a boundary.
        for size in [1, 4_095, 262_144, 262_145, 600_001] {
            let input = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 % 253 + $0 / 9_973) })
            let stream = try lzfse(input)
            var exact = Data()
            XCTAssertNoThrow(try streamDecode(stream, into: &exact, maximumBytes: size), "exact limit, \(size)")
            XCTAssertEqual(exact, input)
            var short = Data()
            XCTAssertThrowsError(try streamDecode(stream, into: &short, maximumBytes: size - 1), "\(size)") {
                XCTAssertEqual($0 as? EPGError, .responseTooLarge)
            }
            XCTAssertLessThanOrEqual(short.count, size - 1, "the overflowing chunk is never appended")
        }
    }

    func testFramingWalkerMeasuresEveryBlockKindTheEncoderWrites() throws {
        var generator = SystemRandomNumberGenerator()
        let inputs = [
            Data("{\"small\":true}".utf8),                                               // LZVN block
            Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0 % 251 + $0 / 4_096) }), // LZFSE blocks
            Data((0..<70_000).map { _ in UInt8.random(in: 0...255, using: &generator) }), // stored raw
        ]
        for input in inputs {
            let stream = try lzfse(input)
            let framing = try XCTUnwrap(EPGCacheFormat.lzfseFraming(stream))
            XCTAssertEqual(framing.length, stream.count)
            XCTAssertEqual(framing.decodedBytes, input.count)
            XCTAssertEqual(EPGCacheFormat.lzfseFraming(stream + stream)?.length, stream.count,
                           "the first stream's end is found inside concatenated data")
            XCTAssertNil(EPGCacheFormat.lzfseFraming(stream.dropLast(4)), "no end-of-stream block")
        }
        XCTAssertNil(EPGCacheFormat.lzfseFraming(Data("bvx3".utf8) + Data(count: 800) + Data("bvx$".utf8)),
                     "unknown block kind")
        XCTAssertNil(EPGCacheFormat.lzfseFraming(Data("bvx-".utf8) + uint32LE(1_000) + Data(count: 10) + Data("bvx$".utf8)),
                     "a block that overruns the payload")
    }

    func testTruncatedTrailingAndConcatenatedStreamsAreRejected() throws {
        let json = try recordJSON()
        let stream = try lzfse(json)
        assertDecode(forged(payload: stream, decodedLength: json.count), throws: nil)
        assertDecode(forged(payload: stream.dropLast(4), decodedLength: json.count), throws: .corruptPayload,
                     "end-of-stream marker missing")
        assertDecode(forged(payload: stream.prefix(stream.count / 2), decodedLength: json.count),
                     throws: .corruptPayload)
        assertDecode(forged(payload: stream + Data([0]), decodedLength: json.count), throws: .corruptPayload,
                     "trailing byte after the stream")
        assertDecode(forged(payload: stream + stream, decodedLength: json.count), throws: .corruptPayload,
                     "a second concatenated stream")
        assertDecode(forged(payload: Data(repeating: 0xAB, count: 64), decodedLength: json.count),
                     throws: .corruptPayload)
    }

    func testReferenceVersion1BlocksAreMeasuredAndDecoded() throws {
        let stream = try XCTUnwrap(Data(base64Encoded: Self.bvx1Stream.joined()))
        XCTAssertEqual(Array(stream.prefix(4)), Array("bvx1".utf8))
        let framing = try XCTUnwrap(EPGCacheFormat.lzfseFraming(stream))
        XCTAssertEqual(framing.length, stream.count)
        XCTAssertEqual(framing.decodedBytes, Self.bvx1RecordBytes)

        var json = Data()
        try streamDecode(stream, into: &json, maximumBytes: Self.bvx1RecordBytes)
        XCTAssertEqual(SHA256.hash(data: json).hexString, Self.bvx1RecordSHA256, "Apple's decoder agrees with the reference")

        let index = try EPGCacheFormat.decodeVersion1(Data("KEPG\u{1}".utf8) + stream)
        XCTAssertEqual(index.programCount, 80)
        XCTAssertEqual(index.channelCount, 2)

        // Malformed boundaries around the 772-byte header and its declared payloads.
        XCTAssertNil(EPGCacheFormat.lzfseFraming(stream.prefix(771)), "header cut short")
        XCTAssertNil(EPGCacheFormat.lzfseFraming(stream.prefix(800) + Data("bvx$".utf8)), "payload cut short")
        XCTAssertNil(EPGCacheFormat.lzfseFraming(patched(stream, at: 20, uint32LE(0x00FF_FFFF))),
                     "literal payload overruns the stream")
        XCTAssertEqual(EPGCacheFormat.lzfseFraming(stream + Data([0]))?.length, stream.count)
        XCTAssertThrowsError(try EPGCacheFormat.decodeVersion1(Data("KEPG\u{1}".utf8) + stream + Data([0]))) {
            XCTAssertEqual($0 as? EPGCacheFormatError, .corruptPayload, "trailing byte")
        }
        assertDecode(forged(payload: stream, decodedLength: Self.bvx1RecordBytes + 1), throws: .lengthMismatch)
    }

    // MARK: - Records

    func testOverflowingTimesAreRejectedWithoutTrapping() throws {
        let starts: [Int64] = [Int64.max, Int64.max - 10, Int64.max - 3_600, Int64.min]
        for start in starts {
            let rows: [[String: Any]] = [["c": 0, "s": start, "d": 3_600, "t": "x"]]
            let json = try recordJSON(rows: rows)
            assertDecode(forged(payload: try lzfse(json), decodedLength: json.count), throws: .invalidRecord,
                         "start \(start)")
            XCTAssertThrowsError(try EPGCacheFormat.decodeVersion1(Data("KEPG\u{1}".utf8) + (try lzfse(json)))) {
                XCTAssertEqual($0 as? EPGCacheFormatError, .invalidRecord, "version 1 start \(start)")
            }
        }
        let late = EPGIndex(fetchedAt: now, programsByChannel: ["a.uk": [
            EPGProgram(channelID: "a.uk", start: Date(timeIntervalSince1970: 1e30),
                       end: Date(timeIntervalSince1970: 1e30 + 60), title: "x"),
        ]], channelIDsByName: [:], statistics: EPGIndex.Statistics())
        XCTAssertThrowsError(try EPGCacheFormat.encode(late, providerID: provider, sourceFingerprint: fingerprint)) {
            XCTAssertEqual($0 as? EPGCacheFormatError, .invalidRecord, "out-of-range dates are refused, not trapped")
        }
        XCTAssertThrowsError(try EPGCacheFormat.encodeVersion1(late)) {
            XCTAssertEqual($0 as? EPGCacheFormatError, .invalidRecord)
        }
    }

    func testInvalidRecordsAreRejected() throws {
        func rejects(_ rows: [[String: Any]], channels: [String] = ["a.uk"], names: [String: String] = [:],
                     _ message: String, line: UInt = #line) throws {
            let json = try recordJSON(rows: rows, channels: channels, names: names)
            assertDecode(forged(payload: try lzfse(json), decodedLength: json.count, programs: rows.count,
                                channels: channels.count, coverage: (1_800_000_000, 1_800_003_600)),
                         throws: .invalidRecord, message, line: line)
        }
        let start = 1_800_000_000
        try rejects([["c": 1, "s": start, "d": 3_600, "t": "x"]], "channel index out of range")
        try rejects([["c": 0, "s": start, "d": 0, "t": "x"]], "zero duration")
        try rejects([["c": 0, "s": -5, "d": 3_600, "t": "x"]], "negative start")
        try rejects([["c": 0, "s": start, "d": 3_600, "t": String(repeating: "é", count: 601)]], "title over limit")
        try rejects([["c": 0, "s": start, "d": 3_600, "t": "x", "ds": String(repeating: "x", count: 601)]],
                    "summary over limit")
        try rejects([["c": 0, "s": start, "d": 3_600, "t": "x"], ["c": 0, "s": start + 60, "d": 3_540, "t": "y"]],
                    "overlapping programmes")
        try rejects([["c": 0, "s": start, "d": 3_600, "t": "x"], ["c": 1, "s": start, "d": 3_600, "t": "x"]],
                    channels: ["a.uk", "a.uk"], "duplicate channels")
        try rejects([["c": 0, "s": start, "d": 3_600, "t": "x"]], channels: [" "], "blank channel ID")
        try rejects([["c": 0, "s": start, "d": 3_600]], "missing title")
    }

    func testHeaderMustAgreeWithTheDecodedRecord() throws {
        let rows: [[String: Any]] = [["c": 0, "s": 1_800_000_000, "d": 3_600, "t": "x"]]
        let json = try recordJSON(rows: rows)
        let payload = try lzfse(json)
        let valid = (start: Int64(1_800_000_000), end: Int64(1_800_003_600))
        assertDecode(forged(payload: payload, decodedLength: json.count, programs: 1, channels: 1, coverage: valid),
                     throws: nil)
        assertDecode(forged(payload: payload, decodedLength: json.count, programs: 2, channels: 1, coverage: valid),
                     throws: .mismatchedMetadata, "programme count")
        assertDecode(forged(payload: payload, decodedLength: json.count, programs: 1, channels: 1,
                            coverage: (valid.start, valid.end + 1)), throws: .mismatchedMetadata, "coverage end")
        assertDecode(forged(payload: payload, decodedLength: json.count, programs: 1, channels: 1, coverage: valid,
                            fetchedAt: now.addingTimeInterval(1)), throws: .mismatchedMetadata, "fetch time")
    }

    func testEncoderNeverWritesAFileTheReaderRejects() throws {
        var limits = EPGCacheFormat.Limits()
        limits.maximumPrograms = 2
        XCTAssertThrowsError(try EPGCacheFormat.encode(guide(), providerID: provider, sourceFingerprint: fingerprint,
                                                       limits: limits)) {
            XCTAssertEqual($0 as? EPGCacheFormatError, .tooLarge)
        }
        let long = EPGIndex(fetchedAt: now, programsByChannel: ["a.uk": [
            EPGProgram(channelID: "a.uk", start: at(0), end: at(60), title: String(repeating: "x", count: 601)),
        ]], channelIDsByName: [:], statistics: EPGIndex.Statistics())
        XCTAssertThrowsError(try EPGCacheFormat.encode(long, providerID: provider, sourceFingerprint: fingerprint)) {
            XCTAssertEqual($0 as? EPGCacheFormatError, .invalidRecord)
        }
        XCTAssertThrowsError(try EPGCacheFormat.encode(guide(), providerID: provider, sourceFingerprint: Data([1]))) {
            XCTAssertEqual($0 as? EPGCacheFormatError, .malformedHeader)
        }
    }

    // MARK: - Version 1

    func testVersion1KeepsRecordsTheMilestone1WriterAccepted() throws {
        // The Milestone 1 writer bounded none of these; only version 2 does.
        let longID = String(repeating: "c", count: 5_000) + ".uk"
        let rows: [[String: Any]] = [
            ["c": 0, "s": 1_800_000_000, "d": 3_600, "t": String(repeating: "t", count: 900)],
            ["c": 1, "s": 1_800_000_000, "d": 3_600, "t": "x"],
        ]
        let json = try recordJSON(rows: rows, channels: [longID, "b.uk"], names: [String(repeating: "n", count: 5_000): longID])
        let index = try EPGCacheFormat.decodeVersion1(Data("KEPG\u{1}".utf8) + (try lzfse(json)))
        XCTAssertEqual(index.programCount, 2)
        XCTAssertEqual(index.programsByChannel[longID]?.first?.title.count, 900)

        assertDecode(forged(payload: try lzfse(json), decodedLength: json.count, programs: 2, channels: 2),
                     throws: .invalidRecord, "version 2 applies the limits")
    }

    func testVersion1StillDecodesThroughTheBoundedReader() throws {
        let index = guide()
        let v1 = try EPGCacheFormat.encodeVersion1(index)
        XCTAssertEqual(Array(v1.prefix(5)), Array("KEPG".utf8) + [1])
        let restored = try EPGCacheFormat.decodeVersion1(v1)
        XCTAssertEqual(restored.programsByChannel, index.programsByChannel)
        XCTAssertEqual(restored.fetchedAt, now)

        XCTAssertThrowsError(try EPGCacheFormat.decodeVersion1(v1 + Data([0]))) {
            XCTAssertEqual($0 as? EPGCacheFormatError, .corruptPayload, "trailing bytes")
        }
        XCTAssertThrowsError(try EPGCacheFormat.decodeVersion1(try validFile())) {
            XCTAssertEqual($0 as? EPGCacheFormatError, .unsupportedVersion(2))
        }
        assertDecode(v1, throws: .unsupportedVersion(1))
    }

    // MARK: - Store

    func testStoreKeepsValidAndPossiblyValidLegacyFiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = EPGCacheStore(directory: directory)

        let reference = UUID()
        let referenceFile = cacheFile(directory, reference)
        try (Data("KEPG\u{1}".utf8) + Data(base64Encoded: Self.bvx1Stream.joined())!).write(to: referenceFile)
        XCTAssertEqual(store.load(providerID: reference)?.programCount, 80, "a reference bvx1 cache loads")
        XCTAssertTrue(FileManager.default.fileExists(atPath: referenceFile.path))

        let longID = String(repeating: "c", count: 5_000)
        let legacy = UUID()
        let legacyJSON = try recordJSON(channels: [longID])
        try (Data("KEPG\u{1}".utf8) + (try lzfse(legacyJSON))).write(to: cacheFile(directory, legacy))
        XCTAssertEqual(store.load(providerID: legacy)?.programCount, 1, "an identifier past the new limit still loads")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile(directory, legacy).path))

        var strict = store
        strict.formatLimits.maximumDecodedBytes = 64
        XCTAssertNil(strict.load(providerID: legacy))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile(directory, legacy).path),
                      "a file over only this build's decoded limit is kept")

        let corrupt = UUID()
        try (Data("KEPG\u{1}".utf8) + (try lzfse(legacyJSON)) + Data([0])).write(to: cacheFile(directory, corrupt))
        XCTAssertNil(store.load(providerID: corrupt))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile(directory, corrupt).path),
                       "a corrupt file is still deleted")
    }

    func testFailedReplacementKeepsThePreviousGuide() throws {
        let directory = temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EPGCacheStore(directory: directory)
        let providerID = UUID()
        try store.save(guide(), providerID: providerID)
        let original = try Data(contentsOf: cacheFile(directory, providerID))

        var tiny = store
        tiny.formatLimits.maximumFileBytes = 16
        XCTAssertThrowsError(try tiny.save(guide(), providerID: providerID)) {
            XCTAssertEqual($0 as? EPGCacheFormatError, .tooLarge)
        }
        XCTAssertEqual(try Data(contentsOf: cacheFile(directory, providerID)), original, "oversized replacement")

        let unwritable = EPGIndex(fetchedAt: now, programsByChannel: ["a.uk": [
            EPGProgram(channelID: "a.uk", start: at(0), end: at(0), title: "zero length"),
        ]], channelIDsByName: [:], statistics: EPGIndex.Statistics())
        XCTAssertThrowsError(try store.save(unwritable, providerID: providerID))
        XCTAssertEqual(try Data(contentsOf: cacheFile(directory, providerID)), original, "unencodable replacement")

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try store.save(EPGIndex.empty(fetchedAt: now), providerID: providerID))
        XCTAssertEqual(try Data(contentsOf: cacheFile(directory, providerID)), original, "failed atomic write")
        XCTAssertEqual(store.load(providerID: providerID)?.programsByChannel, guide().programsByChannel)
    }

    // MARK: - Helpers

    /// A reference-implementation LZFSE stream of one `bvx1` block (lzfse/lzfse@e634ca58): the
    /// encoder's `bvx2` output rewritten with the reference `lzfse_decode_v1` header conversion
    /// and checked with `lzfse_decode_buffer`. It decodes to a version 1 cache record of 80
    /// programmes on 2 channels.
    private static let bvx1RecordBytes = 8_149
    private static let bvx1RecordSHA256 = "23428ff3cc8be62441c0e846c46d3151d5112c918e3a8e9b23562467ce08006f"
    private static let bvx1Stream = [
        "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",
        "6QjQ4wU/YnZ4JA==",
    ]

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("KyroEPGFormat-\(UUID().uuidString)", isDirectory: true)
    }

    private func cacheFile(_ directory: URL, _ providerID: UUID) -> URL {
        directory.appendingPathComponent("\(providerID.uuidString).epgcache")
    }

    private func streamDecode(_ stream: Data, into output: inout Data, maximumBytes: Int) throws {
        try stream.withUnsafeBytes { raw in
            try EPGPayloadDecoder.decode(raw.bindMemory(to: UInt8.self), algorithm: COMPRESSION_LZFSE,
                                         into: &output, maximumBytes: maximumBytes, checksCancellation: false)
        }
    }

    private func at(_ minutes: Int) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(minutes * 60))
    }

    private func guide() -> EPGIndex {
        func program(_ channel: String, _ start: Int, _ end: Int, _ title: String) -> EPGProgram {
            EPGProgram(channelID: channel, start: at(start), end: at(end), title: title, subtitle: "Sub",
                       summary: "Summary", category: "News", episode: "S1 E2")
        }
        return EPGIndex(fetchedAt: now, programsByChannel: [
            "bbcone.uk": [program("BBCOne.uk", -30, 30, "Morning"), program("BBCOne.uk", 30, 120, "Noon")],
            "itv.uk": [program("itv.uk", 0, 60, "Café")],
        ], channelIDsByName: ["bbcone": "bbcone.uk"], statistics: EPGIndex.Statistics())
    }

    private func validFile() throws -> Data {
        try EPGCacheFormat.encode(guide(), providerID: provider, sourceFingerprint: fingerprint)
    }

    private func recordJSON(rows: [[String: Any]] = [["c": 0, "s": 1_800_000_000, "d": 3_600, "t": "x"]],
                            channels: [String] = ["a.uk"], names: [String: String] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "fetchedAt": now.timeIntervalSince1970, "channelIDs": channels, "names": names, "rows": rows,
        ] as [String: Any])
    }

    private func lzfse(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .lzfse) as Data
    }

    /// A version 2 file around an arbitrary payload, with a correct digest and payload length.
    private func forged(payload: Data, decodedLength: Int, programs: Int = 1, channels: Int = 1,
                        coverage: (start: Int64, end: Int64) = (1_800_000_000, 1_800_003_600),
                        fetchedAt: Date? = nil) -> Data {
        var file = Data("KEPG".utf8) + Data([2, 0, 0, 0]) + uint32(156) + provider.bytes + UUID().bytes + fingerprint
        file += uint64((fetchedAt ?? now).timeIntervalSince1970.bitPattern)
        file += uint64(UInt64(coverage.start)) + uint64(UInt64(coverage.end))
        file += uint32(UInt32(programs)) + uint32(UInt32(channels))
        file += uint64(UInt64(payload.count)) + uint64(UInt64(decodedLength))
        file += Data(SHA256.hash(data: payload))
        return file + payload
    }

    private func patched(_ file: Data, at offset: Int, _ bytes: [UInt8]) -> Data {
        var copy = file
        copy.replaceSubrange(offset..<offset + bytes.count, with: bytes)
        return copy
    }

    private func patched(_ file: Data, at offset: Int, _ bytes: Data) -> Data {
        patched(file, at: offset, Array(bytes))
    }

    private func uint32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    private func uint64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    private func uint32LE(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    private func assertDecode(_ file: Data, provider: UUID? = nil, limits: EPGCacheFormat.Limits = .init(),
                              throws expected: EPGCacheFormatError?, _ message: String = "",
                              file path: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try EPGCacheFormat.decode(file, providerID: provider ?? self.provider, limits: limits)
            if let expected { XCTFail("expected \(expected). \(message)", file: path, line: line) }
        } catch {
            XCTAssertEqual(error as? EPGCacheFormatError, expected, message, file: path, line: line)
        }
    }
}

private extension UUID {
    var bytes: Data { withUnsafeBytes(of: uuid) { Data($0) } }
}

private extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
