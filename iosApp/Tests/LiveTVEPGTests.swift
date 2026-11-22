import Compression
import Foundation
import XCTest
@testable import Silo

final class LiveTVEPGTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_268_800)  // 2026-01-01T12:00:00Z

    // MARK: - XMLTV

    func testXMLTVParsesChannelsProgrammesAndDetails() throws {
        let xml = #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE tv SYSTEM "xmltv.dtd">
        <tv generator-info-name="test">
          <channel id="news.one"><display-name>News One HD</display-name><display-name>N1</display-name><icon src="https://x/logo.png"/></channel>
          <programme channel="news.one" start="20260101110000 +0000" stop="20260101123000 +0000">
            <title lang="en">Tom &amp; Jerry</title><title lang="fr">Ignored</title>
            <sub-title><![CDATA[Part <One>]]></sub-title>
            <desc>Daily headlines.</desc>
            <category>News</category>
            <episode-num system="xmltv_ns">0.9.</episode-num>
          </programme>
        </tv>
        """#
        let document = try XMLTVParser.parse(Data(xml.utf8))
        XCTAssertEqual(document.channels, [EPGChannel(id: "news.one", displayNames: ["News One HD", "N1"])])
        let program = try XCTUnwrap(document.programs.first)
        XCTAssertEqual(program.title, "Tom & Jerry")
        XCTAssertEqual(program.subtitle, "Part <One>")
        XCTAssertEqual(program.summary, "Daily headlines.")
        XCTAssertEqual(program.category, "News")
        XCTAssertEqual(program.episode, "S1 E10")
        XCTAssertEqual(program.end.timeIntervalSince(program.start), 5_400)
        XCTAssertEqual(XMLTVEpisodeNumber.display(system: "onscreen", text: " Ep 4 "), "Ep 4")
        XCTAssertNil(XMLTVEpisodeNumber.display(system: "xmltv_ns", text: ".."))
    }

    func testMalformedFeedsFailWhileTruncatedFeedsKeepTheirParsedPrefix() throws {
        XCTAssertThrowsError(try XMLTVParser.parse(Data("<html><body>502 Bad Gateway</body></html>".utf8))) {
            XCTAssertEqual($0 as? EPGError, .malformedFeed)
        }
        XCTAssertThrowsError(try XMLTVParser.parse(Data("not xml at all".utf8)))
        XCTAssertEqual(try XMLTVParser.parse(Data("<tv></tv>".utf8)).programs, [])

        let truncated = feed([("a", -60, 60, "Kept"), ("a", 0, 60, "Also kept")]).dropLast(40)
        let document = try XMLTVParser.parse(Data(truncated.utf8))
        XCTAssertEqual(document.programs.map(\.title), ["Kept"])
        XCTAssertTrue(document.isIncomplete)
        let index = try EPGIndex(document: document, fetchedAt: now, now: now, limits: EPGLimits())
        XCTAssertTrue(index.statistics.incomplete)
        XCTAssertEqual(EPGGuideStatus.message(for: index), "Guide feed was incomplete; some listings may be missing.")
    }

    func testMalformedAndMissingFieldsAreCountedAndSkipped() throws {
        let xml = """
        <tv>
          <programme channel="a" start="20260101110000 +0000" stop="20260101120000 +0000"><title>Good</title></programme>
          <programme channel="a" start="20260101120000 +0000" stop="20260101120000 +0000"><title>Zero length</title></programme>
          <programme channel="a" start="20260101130000 +0000" stop="20260101120000 +0000"><title>Backwards</title></programme>
          <programme channel="a" start="garbage" stop="20260101120000 +0000"><title>Bad start</title></programme>
          <programme channel="a" start="20260101130000 +0000" stop="20260101140000 +0000"><title>   </title></programme>
          <programme start="20260101130000 +0000" stop="20260101140000 +0000"><title>No channel</title></programme>
        </tv>
        """
        let document = try XMLTVParser.parse(Data(xml.utf8))
        XCTAssertEqual(document.programs.map(\.title), ["Good"])
        XCTAssertEqual(document.malformedCount, 5)
    }

    // MARK: - Compression

    func testRealGzipFeedWithFilenameHeaderDecodes() throws {
        // `gzip -9 -N named.xml`: the header carries FNAME, so header parsing is exercised.
        let fixture = try XCTUnwrap(Data(base64Encoded: "H4sICHLG3moCA25hbWVkLnhtbABVjzELgzAQhXd/RchaNIlD6XCJWzuVLu3SLWiwAXMJMUjrr2+kIvaG43gfd+8dNG83kMnE0XqUVFScEoOt7yz2kj7u5/JEG1VAmhS0L41oBmI7Sfu58miogs6OYdCfErUz6vIkNzTA/kRg66KCEH0ftXOGrNJ2iIxJxyRpzesjF1wIvhQ5LH2BPuyY2DEFyaYhW882kKuPmIMD+2nANsM85xeKLxNMlM3vAAAA"))
        let xml = try EPGPayloadDecoder.xmlData(from: fixture, maximumBytes: 1_024)
        let document = try XMLTVParser.parse(xml)
        XCTAssertEqual(document.programs.map(\.title), ["Gzip Morning"])
    }

    func testMultiMemberGzipAndXzFeedsDecode() throws {
        let first = Data("<tv><programme channel=\"a\" start=\"20260101110000 +0000\" ".utf8)
        let second = Data("stop=\"20260101120000 +0000\"><title>Joined</title></programme></tv>".utf8)
        let gzip = try gzipMember(first) + gzipMember(second)
        XCTAssertEqual(try EPGPayloadDecoder.xmlData(from: gzip, maximumBytes: 4_096), first + second)
        // Identical members (`cat a.gz a.gz`) must not stop decoding after the first one.
        XCTAssertEqual(try EPGPayloadDecoder.xmlData(from: try gzipMember(first) + gzipMember(first), maximumBytes: 4_096),
                       first + first)

        let plain = Data(feed([("a", 0, 30, "From xz")]).utf8)
        let xz = try encode(plain, algorithm: COMPRESSION_LZMA)
        XCTAssertEqual(Array(xz.prefix(6)), [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])
        let decoded = try EPGPayloadDecoder.xmlData(from: xz, maximumBytes: 65_536)
        XCTAssertEqual(try XMLTVParser.parse(decoded).programs.map(\.title), ["From xz"])

        XCTAssertEqual(try EPGPayloadDecoder.xmlData(from: plain, maximumBytes: 65_536), plain)
    }

    func testCorruptTruncatedOversizedAndUnsupportedArchivesFailClearly() throws {
        let member = try gzipMember(Data(repeating: UInt8(ascii: "a"), count: 100_000))
        XCTAssertThrowsError(try EPGPayloadDecoder.xmlData(from: member.prefix(member.count / 2), maximumBytes: 1 << 20)) {
            XCTAssertEqual($0 as? EPGError, .corruptCompressedData)
        }
        var wrongSize = member
        wrongSize[wrongSize.count - 4] ^= 0xFF
        XCTAssertThrowsError(try EPGPayloadDecoder.xmlData(from: wrongSize, maximumBytes: 1 << 20)) {
            XCTAssertEqual($0 as? EPGError, .corruptCompressedData)
        }
        // A tiny download that expands past the limit is refused, not buffered.
        XCTAssertThrowsError(try EPGPayloadDecoder.xmlData(from: member, maximumBytes: 10_000)) {
            XCTAssertEqual($0 as? EPGError, .responseTooLarge)
        }
        XCTAssertThrowsError(try EPGPayloadDecoder.xmlData(from: Data([0x50, 0x4B, 0x03, 0x04, 0]), maximumBytes: 100)) {
            XCTAssertEqual($0 as? EPGError, .unsupportedCompression)
        }
        XCTAssertThrowsError(try EPGPayloadDecoder.xmlData(from: Data(count: 101), maximumBytes: 100)) {
            XCTAssertEqual($0 as? EPGError, .responseTooLarge)
        }
    }

    func testNetworkLoaderStopsAtActualLimitAndHonorsExactLimit() async throws {
        for contentLength in [nil, "1"] {
            let counter = AcceptedByteCounter()
            StreamingURLProtocol.install(chunks: [Data(repeating: 1, count: 4), Data(repeating: 2, count: 4),
                                                  Data(repeating: 3, count: 4), Data(repeating: 4, count: 4)],
                                         contentLength: contentLength, delay: 10_000_000)
            do {
                _ = try await makeStreamingLoader(counter: counter).load(URL(string: "https://epg.test/guide")!, maximumBytes: 10)
                XCTFail("oversized response should fail")
            } catch {
                XCTAssertEqual(error as? EPGError, .responseTooLarge)
            }
            XCTAssertLessThan(counter.value, 16,
                              "must stop accepting body bytes (Content-Length: \(contentLength ?? "absent"))")
            try await waitUntil { StreamingURLProtocol.wasStopped }
        }

        StreamingURLProtocol.install(chunks: [Data("1234".utf8), Data("5678".utf8)], contentLength: "8")
        let counter = AcceptedByteCounter()
        let data = try await makeStreamingLoader(counter: counter).load(URL(string: "https://epg.test/guide")!, maximumBytes: 8)
        XCTAssertEqual(data, Data("12345678".utf8))
        XCTAssertEqual(counter.value, 8)
    }

    func testGuideDownloadDoesNotSendConditionalValidators() async throws {
        StreamingURLProtocol.install(chunks: [Data("<tv></tv>".utf8)], contentLength: "9")
        _ = try await makeStreamingLoader(counter: AcceptedByteCounter())
            .load(URL(string: "https://epg.test/guide.xml?token=private")!, maximumBytes: 100)
        let names = Set(StreamingURLProtocol.requestHeaderNames.map { $0.lowercased() })
        XCTAssertFalse(names.contains("if-none-match"))
        XCTAssertFalse(names.contains("if-modified-since"))
        XCTAssertFalse(names.contains("etag"))
        XCTAssertEqual(StreamingURLProtocol.cachePolicy, .reloadIgnoringLocalCacheData)
        let rendered = StreamingURLProtocol.requestHeaderNames.joined(separator: " ")
        XCTAssertFalse(rendered.lowercased().contains("private"))
    }

    /// The provider case: `Content-Encoding: gzip`, a compressed Content-Length under the download
    /// cap, and URLSession delivering the decoded XML, which is larger than the download cap.
    func testTransportDecodedXMLUsesTheExpandedCapLikeTheProviderResponse() async throws {
        let xml = Data(feed((0..<40).map { ("news.one", $0 * 30, 30, "P\($0)") }).utf8)
        XCTAssertGreaterThan(xml.count, 2_000)
        let chunks = stride(from: 0, to: xml.count, by: 512).map { xml.subdata(in: $0 ..< min($0 + 512, xml.count)) }
        for coding in ["gzip", "GZIP", "br", "deflate", "x-gzip, identity"] {
            StreamingURLProtocol.install(chunks: chunks, contentLength: "400", headers: ["Content-Encoding": coding])
            let data = try await makeStreamingLoader().load(URL(string: "https://epg.test/guide")!,
                                                            maximumBytes: 1_000, maximumDecodedBytes: 100_000)
            XCTAssertEqual(data, xml, coding)
            let document = try XMLTVParser.parse(EPGPayloadDecoder.xmlData(from: data, maximumBytes: 100_000))
            XCTAssertEqual(document.programs.count, 40)
        }
        // A byte-order mark and whitespace before the root are still XML; an all-whitespace first
        // chunk defers the decision.
        StreamingURLProtocol.install(chunks: [Data([0xEF, 0xBB, 0xBF, 0x0A, 0x20]), xml], contentLength: nil,
                                     headers: ["Content-Encoding": "gzip"])
        let prefixed = try await makeStreamingLoader().load(URL(string: "https://epg.test/guide")!,
                                                            maximumBytes: 1_000, maximumDecodedBytes: 100_000)
        XCTAssertEqual(prefixed.count, xml.count + 5)
    }

    func testDecodedXMLStillStopsAtTheExpandedCapWithoutContentLength() async throws {
        let counter = AcceptedByteCounter()
        StreamingURLProtocol.install(chunks: [Data("<tv>".utf8)] + Array(repeating: Data(repeating: 0x20, count: 400), count: 20),
                                     contentLength: nil, delay: 5_000_000, headers: ["Content-Encoding": "gzip"])
        await XCTAssertThrowsAsync(try await makeStreamingLoader(counter: counter).load(
            URL(string: "https://epg.test/guide")!, maximumBytes: 100, maximumDecodedBytes: 2_000)) {
            XCTAssertEqual($0 as? EPGError, .responseTooLarge)
        }
        XCTAssertLessThanOrEqual(counter.value, 2_000)
        XCTAssertLessThan(StreamingURLProtocol.sentChunks, 21, "the request stops before the whole body is sent")
        try await waitUntil { StreamingURLProtocol.wasStopped }
    }

    func testOnlyDecodedXMLGetsTheExpandedCap() async throws {
        let oversizedXML = [Data("<tv>".utf8), Data(repeating: 0x20, count: 1_500)]
        let gzipFile = [Data([0x1F, 0x8B, 0x08, 0x00]), Data(repeating: 0, count: 1_500)]
        let cases: [(name: String, chunks: [Data], headers: [String: String], length: String?)] = [
            ("plain XML, no content coding", oversizedXML, [:], nil),
            ("identity coding", oversizedXML, ["Content-Encoding": "identity"], nil),
            ("coding URLSession does not decode", oversizedXML, ["Content-Encoding": "compress"], nil),
            ("partly undecodable codings", oversizedXML, ["Content-Encoding": "gzip, compress"], nil),
            ("gzip file inside a gzip transfer", gzipFile, ["Content-Encoding": "gzip"], nil),
            ("compressed transfer larger than the download cap", oversizedXML, ["Content-Encoding": "gzip"], "1001"),
        ]
        for item in cases {
            StreamingURLProtocol.install(chunks: item.chunks, contentLength: item.length, headers: item.headers)
            await XCTAssertThrowsAsync(try await makeStreamingLoader().load(
                URL(string: "https://epg.test/guide")!, maximumBytes: 1_000, maximumDecodedBytes: 100_000)) {
                XCTAssertEqual($0 as? EPGError, .responseTooLarge, item.name)
            }
        }
    }

    func testWhitespaceHeavyResponseKeepsTheDownloadCapUntilXMLStarts() async throws {
        let blanks = Array(repeating: Data(repeating: 0x20, count: 100), count: 6)
        let xml = Data(feed([("news.one", 0, 60, "Now")]).utf8)
        // Whitespace first, then XML: the expanded cap applies once `<` arrives.
        StreamingURLProtocol.install(chunks: blanks + [xml, Data(repeating: 0x20, count: 3_000)], contentLength: nil,
                                     headers: ["Content-Encoding": "gzip"])
        let data = try await makeStreamingLoader().load(URL(string: "https://epg.test/guide")!,
                                                        maximumBytes: 1_000, maximumDecodedBytes: 100_000)
        XCTAssertEqual(data.count, 600 + xml.count + 3_000)

        // Endless whitespace never reaches XML, so it stops at the download cap, not the expanded one.
        let counter = AcceptedByteCounter()
        StreamingURLProtocol.install(chunks: Array(repeating: Data(repeating: 0x0A, count: 100), count: 200),
                                     contentLength: nil, delay: 2_000_000, headers: ["Content-Encoding": "gzip"])
        await XCTAssertThrowsAsync(try await makeStreamingLoader(counter: counter).load(
            URL(string: "https://epg.test/guide")!, maximumBytes: 1_000, maximumDecodedBytes: 100_000)) {
            XCTAssertEqual($0 as? EPGError, .responseTooLarge)
        }
        XCTAssertLessThanOrEqual(counter.value, 1_000)
        XCTAssertLessThan(StreamingURLProtocol.sentChunks, 20)
        try await waitUntil { StreamingURLProtocol.wasStopped }
    }

    func testServiceAllowsDecodedXMLUpToTheXMLCap() async throws {
        let loader = LimitRecordingLoader(payload: Data(feed([("news.one", 0, 60, "Now")]).utf8))
        var limits = EPGLimits()
        limits.maximumDownloadBytes = 1_000
        limits.maximumXMLBytes = 9_000
        let service = EPGService(cache: nil, loader: loader, fingerprinter: .inMemory(), limits: limits, now: { [now] in now })
        _ = try await service.refresh(providerID: UUID(), source: source)
        XCTAssertEqual(loader.limits, [1_000, 9_000])
    }

    func testNetworkLoaderCancellationStopsUnderlyingRequest() async throws {
        StreamingURLProtocol.install(chunks: Array(repeating: Data(repeating: 1, count: 1), count: 100),
                                     contentLength: nil, delay: 20_000_000)
        let task = Task {
            try await makeStreamingLoader().load(URL(string: "https://epg.test/guide")!, maximumBytes: 200)
        }
        try await waitUntil { StreamingURLProtocol.sentChunks > 0 }
        task.cancel()
        await XCTAssertThrowsAsync(try await task.value) { XCTAssertTrue($0 is CancellationError) }
        try await waitUntil { StreamingURLProtocol.wasStopped }
        XCTAssertLessThan(StreamingURLProtocol.sentChunks, 100)
    }

    func testXMLTVTextIsCappedWhileAccumulatingCharactersAndCDATA() throws {
        var limits = EPGLimits()
        limits.maximumTextLength = 8
        let xml = "<tv><programme channel=\"a\" start=\"20260101110000 +0000\" stop=\"20260101120000 +0000\"><title>\(String(repeating: "x", count: 100_000))</title><desc><![CDATA[\(String(repeating: "y", count: 100_000))]]></desc></programme></tv>"
        let program = try XCTUnwrap(XMLTVParser.parse(Data(xml.utf8), limits: limits).programs.first)
        XCTAssertEqual(program.title, String(repeating: "x", count: 8))
        XCTAssertEqual(program.summary, String(repeating: "y", count: 8))
    }

    private func makeStreamingLoader(counter: AcceptedByteCounter? = nil) -> URLSessionEPGFeedLoader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingURLProtocol.self]
        let onAcceptedBytes: (@Sendable (Int) -> Void)? = counter.map { counter in
            { @Sendable count in counter.set(count) }
        }
        return URLSessionEPGFeedLoader(session: URLSession(configuration: configuration),
                                       onAcceptedBytes: onAcceptedBytes)
    }

    // MARK: - Time

    func testTimestampsNormalizeOffsetsToUTCAndRejectInvalidFields() {
        let utc = TimeZone(secondsFromGMT: 0)!
        func parse(_ raw: String) -> String? {
            XMLTVTimestamp.parse(raw, fallbackTimeZone: utc).map { ISO8601DateFormatter().string(from: $0) }
        }
        XCTAssertEqual(parse("20261025013000 +0200"), "2026-10-24T23:30:00Z")
        XCTAssertEqual(parse("20261025013000 +02:00"), "2026-10-24T23:30:00Z")
        XCTAssertEqual(parse("20261025013000+0200"), "2026-10-24T23:30:00Z")
        XCTAssertEqual(parse("202610250130 -0530"), "2026-10-25T07:00:00Z")
        XCTAssertEqual(parse("20261025013000 Z"), "2026-10-25T01:30:00Z")
        XCTAssertEqual(parse("20261025013000 GMT"), "2026-10-25T01:30:00Z")
        XCTAssertEqual(parse(" 20261025013000 "), "2026-10-25T01:30:00Z")
        XCTAssertEqual(parse("20240229120000 +0000"), "2024-02-29T12:00:00Z")
        for invalid in ["20261325013000 +0000", "20260230120000 +0000", "20261025240000 +0000",
                        "20261025016000 +0000", "2026102501300 +0000", "20261025013000 +2500",
                        "20261025013000 EST", "20261025013000 +02", "", "tomorrow"] {
            XCTAssertNil(parse(invalid), invalid)
        }
        XCTAssertNil(XMLTVTimestamp.parse(nil, fallbackTimeZone: utc))
    }

    func testOffsetlessTimesUseTheFallbackZoneAcrossDaylightSaving() throws {
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let london = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        func parse(_ raw: String, _ zone: TimeZone) -> String? {
            XMLTVTimestamp.parse(raw, fallbackTimeZone: zone).map { ISO8601DateFormatter().string(from: $0) }
        }
        XCTAssertEqual(parse("20260701120000", newYork), "2026-07-01T16:00:00Z")
        XCTAssertEqual(parse("20261201120000", newYork), "2026-12-01T17:00:00Z")
        // Skipped hour moves forward by the gap: 02:30 becomes 03:30 EDT.
        XCTAssertEqual(parse("20260308023000", newYork), "2026-03-08T07:30:00Z")
        // Repeated hour resolves to its first occurrence (EDT).
        XCTAssertEqual(parse("20261101013000", newYork), "2026-11-01T05:30:00Z")
        XCTAssertEqual(parse("20260329013000", london), "2026-03-29T01:30:00Z")
        XCTAssertEqual(parse("20261025013000", london), "2026-10-25T00:30:00Z")
        // An explicit offset always wins over the fallback zone.
        XCTAssertEqual(parse("20261101013000 -0500", newYork), "2026-11-01T06:30:00Z")
    }

    func testProgrammeSpanningAFallBackTransitionKeepsItsRealDuration() throws {
        let xml = """
        <tv><programme channel="a" start="20261101013000 -0400" stop="20261101013000 -0500"><title>Overnight</title></programme></tv>
        """
        let program = try XCTUnwrap(XMLTVParser.parse(Data(xml.utf8)).programs.first)
        XCTAssertEqual(program.end.timeIntervalSince(program.start), 3_600)
    }

    // MARK: - Index

    func testDuplicatesAndOverlapsNormalizeDeterministically() throws {
        let document = try XMLTVParser.parse(Data(feed([
            ("A", 30, 60, "Later"),
            ("a", -60, 120, "Runs long"),
            ("a", -60, 60, "Duplicate start"),
            ("a", 90, 30, "End"),
        ]).utf8))
        let index = try EPGIndex(document: document, fetchedAt: now, now: now, limits: EPGLimits())
        let list = index.programs(channelKey: "a", overlapping: DateInterval(start: now.addingTimeInterval(-7_200), duration: 14_400))
        XCTAssertEqual(list.map(\.title), ["Runs long", "Later", "End"])
        XCTAssertEqual(list[0].end, now.addingTimeInterval(1_800), "overlap is trimmed to the next start")
        XCTAssertEqual(index.statistics.duplicates, 1)
        XCTAssertEqual(index.statistics.overlapsTrimmed, 1)
        for (earlier, later) in zip(list, list.dropFirst()) { XCTAssertLessThanOrEqual(earlier.end, later.start) }
    }

    func testCurrentAndUpcomingLookupHandlesBoundariesAndGaps() throws {
        let document = try XMLTVParser.parse(Data(feed([
            ("a", -30, 30, "Before"), ("a", 0, 60, "At noon"), ("a", 120, 60, "After gap"),
        ]).utf8))
        let index = try EPGIndex(document: document, fetchedAt: now, now: now, limits: EPGLimits())
        XCTAssertEqual(index.nowNext(channelKey: "a", at: now).current?.title, "At noon", "start is inclusive")
        XCTAssertEqual(index.nowNext(channelKey: "a", at: now).next?.title, "After gap")
        XCTAssertEqual(index.nowNext(channelKey: "a", at: now.addingTimeInterval(-1)).current?.title, "Before")
        let inGap = index.nowNext(channelKey: "a", at: now.addingTimeInterval(3_600))
        XCTAssertNil(inGap.current, "end is exclusive")
        XCTAssertEqual(inGap.next?.title, "After gap")
        XCTAssertEqual(index.nowNext(channelKey: "a", at: now.addingTimeInterval(20_000)), .empty)
        XCTAssertEqual(index.nowNext(channelKey: "missing", at: now), .empty)
        XCTAssertEqual(index.coverageEnd, now.addingTimeInterval(10_800))
    }

    func testChannelMatchingPrefersGuideIDThenAnUnambiguousName() throws {
        let xml = """
        <tv>
          <channel id="BBC1.uk"><display-name>BBC One HD</display-name></channel>
          <channel id="sky.news"><display-name>Sky News</display-name></channel>
          <channel id="sport.1"><display-name>Sport</display-name></channel>
          <channel id="sport.2"><display-name>SPORT</display-name></channel>
        \(programmes([("BBC1.uk", 0, 60, "Bulletin"), ("sky.news", 0, 60, "Headlines"),
                      ("sport.1", 0, 60, "Match"), ("sport.2", 0, 60, "Other match")]))
        </tv>
        """
        let index = try EPGIndex(document: XMLTVParser.parse(Data(xml.utf8)), fetchedAt: now, now: now, limits: EPGLimits())
        XCTAssertEqual(index.channelKey(guideID: " bbc1.UK ", name: nil), "bbc1.uk")
        XCTAssertEqual(index.channelKey(guideID: "sky.news", name: "BBC One"), "sky.news", "guide ID wins over name")
        XCTAssertEqual(index.channelKey(guideID: "unknown", name: "Bbc One"), "bbc1.uk", "name fallback ignores case and HD")
        XCTAssertEqual(index.channelKey(guideID: nil, name: "Sky  News FHD"), "sky.news")
        XCTAssertNil(index.channelKey(guideID: nil, name: "Sport"), "a name shared by two guide channels never matches")
        XCTAssertNil(index.channelKey(guideID: nil, name: nil))
        XCTAssertEqual(index.nowNext(guideID: nil, name: "BBC ONE", at: now).current?.title, "Bulletin")
    }

    func testFilterKeepsOnlyListingsThePlaylistCanShow() throws {
        let xml = """
        <tv>
          <channel id="Named.Only"><display-name>Film Four</display-name></channel>
        \(programmes([("kept.id", 0, 60, "By ID"), ("named.only", 0, 60, "By name"), ("dropped", 0, 60, "Dropped")]))
        </tv>
        """
        let filter = EPGChannelFilter(guideIDs: ["KEPT.id", nil], names: ["Film 4", "film four"])
        let document = try XMLTVParser.parse(Data(xml.utf8), filter: filter)
        XCTAssertEqual(document.programs.map(\.title), ["By ID", "By name"])
    }

    func testPlaylistGuideFilterIgnoresCosmeticAndCategoryChangesButTracksIDOrName() {
        let original = EPGChannelFilter(guideIDs: [" News.One "], names: ["News One HD"])
        XCTAssertEqual(original, EPGChannelFilter(guideIDs: ["news.one"], names: ["news one"]))
        XCTAssertNotEqual(original, EPGChannelFilter(guideIDs: ["news.two"], names: ["News One HD"]))
        XCTAssertNotEqual(original, EPGChannelFilter(guideIDs: ["news.one"], names: ["Other Name"]))
    }

    func testOutdatedAndFarFutureProgrammesAreDroppedAndLimitsBoundTheIndex() throws {
        var limits = EPGLimits()
        limits.pastRetention = 3_600
        limits.futureHorizon = 7_200
        let document = try XMLTVParser.parse(Data(feed([
            ("a", -300, 60, "Long gone"), ("a", -90, 60, "Recent"), ("a", 0, 60, "Now"), ("a", 600, 60, "Too far"),
        ]).utf8))
        let index = try EPGIndex(document: document, fetchedAt: now, now: now, limits: limits)
        XCTAssertEqual(index.programs(channelKey: "a", overlapping: DateInterval(start: .distantPast, end: .distantFuture)).map(\.title),
                       ["Recent", "Now"])
        XCTAssertEqual(index.statistics.outsideWindow, 2)

        var tight = EPGLimits()
        tight.maximumProgramsPerChannel = 4
        let many = try XMLTVParser.parse(Data(feed((-10..<40).map { ("a", $0 * 30, 30, "P\($0)") }).utf8))
        let bounded = try EPGIndex(document: many, fetchedAt: now, now: now, limits: tight)
        XCTAssertEqual(bounded.programCount, 4)
        XCTAssertEqual(bounded.nowNext(channelKey: "a", at: now).current?.title, "P0", "the airing programme survives trimming")
    }

    // MARK: - Large catalogs

    func testLargeCatalogParsesIndexesAndLooksUpEveryChannel() throws {
        let channelCount = 5_000
        var xml = "<tv>\n"
        xml.reserveCapacity(channelCount * 24 * 160)
        for channel in 0..<channelCount {
            xml += "<channel id=\"ch\(channel)\"><display-name>Channel \(channel)</display-name></channel>\n"
        }
        for channel in 0..<channelCount {
            xml += programmes((0..<24).map { ("ch\(channel)", ($0 - 4) * 30, 30, "Show \($0)") })
        }
        xml += "</tv>"
        let document = try XMLTVParser.parse(Data(xml.utf8))
        XCTAssertEqual(document.programs.count, channelCount * 24)

        let index = try EPGIndex(document: document, fetchedAt: now, now: now, limits: EPGLimits())
        XCTAssertEqual(index.channelCount, channelCount)
        for channel in stride(from: 0, to: channelCount, by: 97) {
            let pair = index.nowNext(guideID: "CH\(channel)", name: nil, at: now.addingTimeInterval(60))
            XCTAssertEqual(pair.current?.title, "Show 4")
            XCTAssertEqual(pair.next?.title, "Show 5")
        }

        var capped = EPGLimits()
        capped.maximumIndexedPrograms = 50_000
        let bounded = try EPGIndex(document: document, fetchedAt: now, now: now, limits: capped)
        XCTAssertLessThanOrEqual(bounded.programCount, 50_000)
        XCTAssertEqual(bounded.nowNext(channelKey: "ch4999", at: now).current?.title, "Show 4")

        var parseCap = EPGLimits()
        parseCap.maximumParsedPrograms = 1_000
        let truncated = try XMLTVParser.parse(Data(xml.utf8), limits: parseCap)
        XCTAssertEqual(truncated.programs.count, 1_000)
        XCTAssertTrue(truncated.isTruncated)
    }

    func testParsingAndDecodingStopWhenTheTaskIsCancelled() async throws {
        let xml = Data(feed((0..<2_000).map { ("a", $0 * 30, 30, "P\($0)") }).utf8)
        let compressed = try gzipMember(xml)
        let task = Task { () -> (parse: Error?, decode: Error?) in
            while !Task.isCancelled { await Task.yield() }
            let parse: Error?
            do { _ = try XMLTVParser.parse(xml); parse = nil } catch { parse = error }
            let decode: Error?
            do { _ = try EPGPayloadDecoder.xmlData(from: compressed, maximumBytes: 1 << 24); decode = nil } catch { decode = error }
            return (parse, decode)
        }
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.parse is CancellationError)
        XCTAssertTrue(result.decode is CancellationError)
    }

    // MARK: - Xtream

    func testXtreamShortEPGDecodesBase64TitlesAndEitherTimestampForm() throws {
        let json = """
        {"epg_listings":[
          {"id":"1","title":"TW9ybmluZyBOZXdz","description":"VG9wIHN0b3JpZXM=","start":"2026-01-01 05:00:00",
           "start_timestamp":"1767261600","stop_timestamp":"1767265200"},
          {"title":"Plain Title","start_timestamp":1767265200,"stop_timestamp":1767268800},
          {"title":"","start_timestamp":"1767268800","stop_timestamp":"1767272400"},
          {"title":"QmFk","start_timestamp":"1767272400","stop_timestamp":"1767272400"},
          {"title":"Tm8gZW5k","start_timestamp":"1767272400"}
        ]}
        """
        let programs = try XtreamEPG.programs(from: Data(json.utf8), guideID: "news.one")
        XCTAssertEqual(programs.map(\.title), ["Morning News", "Plain Title"])
        XCTAssertEqual(programs[0].summary, "Top stories")
        XCTAssertEqual(programs[0].start, Date(timeIntervalSince1970: 1_767_261_600))
        XCTAssertEqual(programs.map(\.channelID), ["news.one", "news.one"])

        XCTAssertEqual(try XtreamEPG.programs(from: Data(#"{"epg_list":[{"title":"QQ==","start_timestamp":1,"stop_timestamp":2}]}"#.utf8),
                                              guideID: "x").map(\.title), ["A"])
        XCTAssertEqual(try XtreamEPG.programs(from: Data("[]".utf8), guideID: "x"), [])
        XCTAssertEqual(try XtreamEPG.programs(from: Data(#"{"user_info":{}}"#.utf8), guideID: "x"), [])
        XCTAssertThrowsError(try XtreamEPG.programs(from: Data("<html>".utf8), guideID: "x"))
    }

    func testXtreamGuideURLKeepsTheServerPathAndEncodesCredentials() throws {
        let url = try XtreamEPG.xmltvURL(server: " https://panel.example:8443/base/ ", username: "a b", password: "p&w+=")
        XCTAssertEqual(url.absoluteString, "https://panel.example:8443/base/xmltv.php?username=a%20b&password=p%26w%2B%3D")
        XCTAssertEqual(try EPGFeedSource.xtream(server: "http://h", username: "u", password: "p").feedURL().absoluteString,
                       "http://h/xmltv.php?username=u&password=p")
        XCTAssertThrowsError(try XtreamEPG.xmltvURL(server: "ftp://h", username: "u", password: "p"))
        XCTAssertThrowsError(try EPGFeedSource.xmltv(URL(fileURLWithPath: "/tmp/guide.xml")).feedURL())
    }

    func testShortEPGReplacesOnlyTheHoursItCovers() throws {
        let document = try XMLTVParser.parse(Data(feed([("a", -60, 60, "Old earlier"), ("a", 0, 60, "Old now"),
                                                        ("a", 60, 60, "Old next"), ("a", 180, 60, "Old later")]).utf8))
        let index = try EPGIndex(document: document, fetchedAt: now, now: now, limits: EPGLimits())
        let fresh = [EPGProgram(channelID: "A", start: now, end: now.addingTimeInterval(5_400), title: "New now")]
        let updated = index.replacingPrograms(fresh, guideID: "A", now: now, limits: EPGLimits())
        let titles = updated.programs(channelKey: "a", overlapping: DateInterval(start: .distantPast, end: .distantFuture)).map(\.title)
        XCTAssertEqual(titles, ["Old earlier", "New now", "Old later"])
    }

    // MARK: - Freshness and cache

    func testRefreshPolicyReportsFreshStaleExpiredAndBacksOff() {
        let policy = EPGRefreshPolicy()
        func state(age: TimeInterval, coverage: TimeInterval?, count: Int = 10) -> EPGFreshness {
            policy.freshness(fetchedAt: now.addingTimeInterval(-age), coverageEnd: coverage.map(now.addingTimeInterval),
                             programCount: count, now: now)
        }
        XCTAssertEqual(state(age: 3_600, coverage: 36_000), .fresh)
        XCTAssertEqual(state(age: 13 * 3_600, coverage: 36_000), .stale)
        XCTAssertEqual(state(age: 3_600, coverage: 3_000), .stale, "running out of listings")
        XCTAssertEqual(state(age: 3_600, coverage: -60), .expired, "listings already over")
        XCTAssertEqual(state(age: 37 * 3_600, coverage: 36_000), .expired)
        XCTAssertEqual(state(age: -7_200, coverage: 36_000), .stale, "clock moved backwards")
        XCTAssertEqual(state(age: 60, coverage: nil, count: 0), .fresh, "an empty feed is judged by age")
        XCTAssertEqual(policy.freshness(fetchedAt: nil, coverageEnd: nil, programCount: 0, now: now), .missing)
        XCTAssertEqual(policy.retryDelay(afterFailures: 0), 0)
        XCTAssertEqual(policy.retryDelay(afterFailures: 1), 300)
        XCTAssertEqual(policy.retryDelay(afterFailures: 2), 600)
        XCTAssertEqual(policy.retryDelay(afterFailures: 30), 3_600)
    }

    func testCacheRoundTripsBoundsItselfAndDiscardsCorruptFiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var cache = EPGCacheStore(directory: directory)
        cache.maximumEntries = 2
        let document = try XMLTVParser.parse(Data("""
        <tv><channel id="Mixed.Case"><display-name>Mixed</display-name></channel>
        \(programmes([("Mixed.Case", 0, 60, "Cached")]))</tv>
        """.utf8))
        let index = try EPGIndex(document: document, fetchedAt: now, now: now, limits: EPGLimits())

        let first = UUID(), second = UUID(), third = UUID()
        try cache.save(index, providerID: first)
        let restored = try XCTUnwrap(cache.load(providerID: first))
        XCTAssertEqual(restored.fetchedAt, now)
        XCTAssertEqual(restored.programsByChannel, index.programsByChannel)
        XCTAssertEqual(restored.nowNext(guideID: nil, name: "MIXED", at: now).current?.id, "Mixed.Case:\(Int(now.timeIntervalSince1970))")

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, ["\(first.uuidString).epgcache"], "named by provider only, never by feed URL")

        try cache.save(index, providerID: second)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)],
                                             ofItemAtPath: directory.appendingPathComponent("\(first.uuidString).epgcache").path)
        try cache.save(index, providerID: third)
        // Legacy v1 files count toward the limit but are never evicted by it on their own; see
        // testEvictionNeverDeletesLegacyV1OnItsOwn in EPGCacheStateTests.
        XCTAssertNotNil(cache.load(providerID: first), "legacy v1 is preserved past the entry limit")
        XCTAssertNotNil(cache.load(providerID: third))

        let corrupt = directory.appendingPathComponent("\(second.uuidString).epgcache")
        try Data("KEPG\u{1}garbage".utf8).write(to: corrupt)
        XCTAssertNil(cache.load(providerID: second))
        XCTAssertFalse(FileManager.default.fileExists(atPath: corrupt.path), "corrupt entries are deleted")
        XCTAssertNil(cache.load(providerID: UUID()))
    }

    // MARK: - Service

    func testFreshCachedGuideIsServedWithoutDownloading() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = GateLoader(payload: Data(serviceFeed.utf8), released: true)
        let provider = UUID()
        let fingerprinter = EPGSourceFingerprinter.inMemory()
        let writer = EPGService(cache: EPGCacheStore(directory: directory), loader: loader, fingerprinter: fingerprinter, now: { [now] in now })
        _ = try await writer.refresh(providerID: provider, source: source)
        try await waitUntil { FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(provider.uuidString).v2.epgcache").path) }

        let offline = GateLoader(payload: Data(), released: true, failure: EPGError.providerRejected)
        let reader = EPGService(cache: EPGCacheStore(directory: directory), loader: offline, fingerprinter: fingerprinter, now: { [now] in now.addingTimeInterval(600) })
        let index = try await reader.refresh(providerID: provider, source: source)
        XCTAssertEqual(index.nowNext(guideID: "news.one", name: nil, at: now).current?.title, "Current")
        XCTAssertEqual(offline.calls, 0)
    }

    func testShortGuideAloneNeverHidesTheCachedFullGuide() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = UUID(), fingerprinter = EPGSourceFingerprinter.inMemory()
        let writer = EPGService(cache: EPGCacheStore(directory: directory), loader: GateLoader(payload: Data(serviceFeed.utf8), released: true),
                                fingerprinter: fingerprinter, now: { [now] in now })
        _ = try await writer.refresh(providerID: provider, source: source)
        try await waitUntil { FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(provider.uuidString).v2.epgcache").path) }

        let offline = GateLoader(payload: Data(), released: true, failure: EPGError.providerRejected)
        let reader = EPGService(cache: EPGCacheStore(directory: directory), loader: offline, fingerprinter: fingerprinter,
                                now: { [now] in now.addingTimeInterval(600) })
        let short = await reader.replacePrograms(shortListing, guideID: "sports.two", providerID: provider, source: source)
        let partial = try XCTUnwrap(short)
        XCTAssertTrue(partial.isShortGuideOnly)
        XCTAssertEqual(partial.nowNext(guideID: "sports.two", name: nil, at: now.addingTimeInterval(600)).current?.title, "Short now",
                       "short-guide listings stay playable on their own")

        let restored = await reader.index(for: provider, source: source)
        let guide = try XCTUnwrap(restored, "the cached full guide still loads")
        XCTAssertFalse(guide.isShortGuideOnly)
        XCTAssertEqual(guide.nowNext(guideID: "news.one", name: nil, at: now).current?.title, "Current")
        XCTAssertEqual(guide.nowNext(guideID: "sports.two", name: nil, at: now.addingTimeInterval(600)).current?.title, "Short now",
                       "newer short-guide listings are reapplied over the cached guide")
        XCTAssertEqual(offline.calls, 0)
    }

    func testShortGuideAloneNeverSatisfiesFullGuideFreshness() async throws {
        // Without a cache, a refresh after short-guide listings still downloads the full guide.
        let loader = GateLoader(payload: Data(serviceFeed.utf8), released: true)
        let service = EPGService(cache: nil, loader: loader, fingerprinter: .inMemory(), now: { [now] in now })
        let provider = UUID()
        _ = await service.replacePrograms(shortListing, guideID: "sports.two", providerID: provider, source: source)
        let shortFreshness = await service.freshness(for: provider)
        XCTAssertEqual(shortFreshness, .missing, "short-guide listings do not count as a full guide")
        let shortOnlyLookup = await service.index(for: provider)
        XCTAssertNil(shortOnlyLookup, "a source-less lookup does not publish short listings as the guide")
        let refreshed = try await service.refresh(providerID: provider, source: source)
        XCTAssertEqual(loader.calls, 1, "a short-guide-only index does not make the full guide fresh")
        XCTAssertFalse(refreshed.isShortGuideOnly)
        XCTAssertEqual(refreshed.nowNext(guideID: "news.one", name: nil, at: now).current?.title, "Current")

        // Over a full guide, short-guide listings update it in place and it stays fresh.
        let updated = await service.replacePrograms(shortListing, guideID: "sports.two", providerID: provider, source: source)
        XCTAssertEqual(updated?.isShortGuideOnly, false)
        XCTAssertEqual(updated?.nowNext(guideID: "news.one", name: nil, at: now).current?.title, "Current")
        _ = try await service.refresh(providerID: provider, source: source)
        XCTAssertEqual(loader.calls, 1)

        // While backing off, a short-guide-only index is not returned as the full guide.
        let failing = GateLoader(payload: Data(), released: true, failure: EPGError.providerRejected)
        let backingOff = EPGService(cache: nil, loader: failing, fingerprinter: .inMemory(), now: { [now] in now })
        await XCTAssertThrowsAsync(try await backingOff.refresh(providerID: provider, source: source))
        _ = await backingOff.replacePrograms(shortListing, guideID: "sports.two", providerID: provider, source: source)
        await XCTAssertThrowsAsync(try await backingOff.refresh(providerID: provider, source: source)) {
            XCTAssertEqual($0 as? EPGError, .providerRejected)
        }
        XCTAssertEqual(failing.calls, 1)
    }

    func testShortGuideRetentionBoundsDistinctChannelsAndRefetchesEvictedOverlay() async throws {
        let service = EPGService(cache: nil, loader: GateLoader(payload: Data(), released: true),
                                  fingerprinter: .inMemory(), now: { [now] in now })
        let provider = UUID()
        let source = EPGFeedSource.xtream(server: "https://panel.example", username: "user", password: "pass")
        let total = EPGService.shortGuideRetentionCapacity + 44
        for index in 0..<total {
            let guideID = "channel.\(index)"
            _ = await service.replacePrograms([
                EPGProgram(channelID: guideID, start: now, end: now.addingTimeInterval(60), title: "Show \(index)")
            ], guideID: guideID, providerID: provider, source: source)
        }

        let stats = await service.shortGuideRetentionStats(providerID: provider)
        XCTAssertEqual(stats.overlayCount, EPGService.shortGuideRetentionCapacity)
        XCTAssertEqual(stats.programmeCount, EPGService.shortGuideRetentionCapacity)
        let oldestRetained = await service.hasShortGuide(providerID: provider, guideID: "channel.0")
        let newestRetained = await service.hasShortGuide(providerID: provider, guideID: "channel.\(total - 1)")
        XCTAssertFalse(oldestRetained, "the oldest overlay is evicted")
        XCTAssertTrue(newestRetained)

        _ = await service.replacePrograms([
            EPGProgram(channelID: "channel.0", start: now, end: now.addingTimeInterval(60), title: "Refetched")
        ], guideID: "channel.0", providerID: provider, source: source)
        let refetched = await service.hasShortGuide(providerID: provider, guideID: "channel.0")
        let refetchedStats = await service.shortGuideRetentionStats(providerID: provider)
        XCTAssertTrue(refetched, "an evicted overlay can be published again")
        XCTAssertEqual(refetchedStats.overlayCount, EPGService.shortGuideRetentionCapacity)
    }

    func testShortGuideRetentionKeepsRepeatedAndEmptyResultsBounded() async throws {
        let service = EPGService(cache: nil, loader: GateLoader(payload: Data(), released: true),
                                  fingerprinter: .inMemory(), now: { [now] in now })
        let provider = UUID()
        let source = EPGFeedSource.xtream(server: "https://panel.example", username: "user", password: "pass")
        for index in 0..<500 {
            _ = await service.replacePrograms([], guideID: "empty.\(index)", providerID: provider, source: source)
        }
        let emptyStats = await service.shortGuideRetentionStats(providerID: provider)
        XCTAssertEqual(emptyStats.overlayCount, EPGService.shortGuideRetentionCapacity)
        XCTAssertEqual(emptyStats.programmeCount, 0)

        for index in 0..<500 {
            _ = await service.replacePrograms([
                EPGProgram(channelID: "same", start: now, end: now.addingTimeInterval(60), title: "Update \(index)")
            ], guideID: "same", providerID: provider, source: source)
        }
        let repeatedStats = await service.shortGuideRetentionStats(providerID: provider)
        XCTAssertEqual(repeatedStats.overlayCount, EPGService.shortGuideRetentionCapacity,
                       "the repeated channel is retained within the bounded empty-result window")
        XCTAssertEqual(repeatedStats.programmeCount, 1)
    }

    func testShortGuideRetentionIsProviderIsolatedAndRemovalClearsOnlyThatProvider() async throws {
        let service = EPGService(cache: nil, loader: GateLoader(payload: Data(), released: true),
                                  fingerprinter: .inMemory(), now: { [now] in now })
        let first = UUID(), second = UUID()
        let source = EPGFeedSource.xtream(server: "https://panel.example", username: "user", password: "pass")
        _ = await service.replacePrograms([
            EPGProgram(channelID: "shared", start: now, end: now.addingTimeInterval(60), title: "First")
        ], guideID: "shared", providerID: first, source: source)
        _ = await service.replacePrograms([
            EPGProgram(channelID: "shared", start: now, end: now.addingTimeInterval(60), title: "Second")
        ], guideID: "shared", providerID: second, source: source)

        let firstStats = await service.shortGuideRetentionStats(providerID: first)
        let secondStats = await service.shortGuideRetentionStats(providerID: second)
        XCTAssertEqual(firstStats.overlayCount, 1)
        XCTAssertEqual(secondStats.overlayCount, 1)
        await service.remove(providerID: first)
        let removedStats = await service.shortGuideRetentionStats(providerID: first)
        let keptStats = await service.shortGuideRetentionStats(providerID: second)
        XCTAssertEqual(removedStats.overlayCount, 0)
        XCTAssertEqual(keptStats.overlayCount, 1)
    }

    func testFailedRefreshBacksOffUnlessForced() async throws {
        let loader = GateLoader(payload: Data(), released: true, failure: EPGError.providerRejected)
        let service = EPGService(cache: nil, loader: loader, fingerprinter: .inMemory(), now: { [now] in now })
        let provider = UUID()
        await XCTAssertThrowsAsync(try await service.refresh(providerID: provider, source: source))
        await XCTAssertThrowsAsync(try await service.refresh(providerID: provider, source: source))
        XCTAssertEqual(loader.calls, 1, "a failing feed is not refetched during backoff")
        await XCTAssertThrowsAsync(try await service.refresh(providerID: provider, source: source, force: true))
        XCTAssertEqual(loader.calls, 2)
        let freshness = await service.freshness(for: provider)
        XCTAssertEqual(freshness, .missing)
    }

    func testConcurrentRefreshesShareOneDownload() async throws {
        let loader = GateLoader(payload: Data(serviceFeed.utf8))
        let service = EPGService(cache: nil, loader: loader, fingerprinter: .inMemory(), now: { [now] in now })
        let provider = UUID()
        let source = source
        let tasks = (0..<5).map { _ in Task { try await service.refresh(providerID: provider, source: source) } }
        try await waitUntil { await service.waiterCount(for: provider) == 5 }
        loader.release()
        var fetchDates = Set<Date>()
        for task in tasks { fetchDates.insert(try await task.value.fetchedAt) }
        XCTAssertEqual(loader.calls, 1)
        XCTAssertEqual(fetchDates, [now])
    }

    func testCancellingTheOnlyWaiterCancelsTheDownloadAndKeepsTheLastGuide() async throws {
        let clock = TestClock(now)
        let loader = GateLoader(payload: Data(serviceFeed.utf8), released: true)
        let service = EPGService(cache: nil, loader: loader, fingerprinter: .inMemory(), now: { clock.date })
        let provider = UUID()
        let source = source
        let first = try await service.refresh(providerID: provider, source: source)

        clock.date = now.addingTimeInterval(13 * 3_600)  // stale but still usable
        loader.hold()
        let task = Task { try await service.refresh(providerID: provider, source: source) }
        try await waitUntil { loader.calls == 2 }
        task.cancel()
        await XCTAssertThrowsAsync(try await task.value) { XCTAssertTrue($0 is CancellationError) }
        try await waitUntil { loader.cancellations == 1 }
        let kept = await service.index(for: provider)
        XCTAssertEqual(kept?.fetchedAt, first.fetchedAt)
    }

    func testCancellingOneWaiterLeavesTheSharedRefreshRunning() async throws {
        let loader = GateLoader(payload: Data(serviceFeed.utf8))
        let service = EPGService(cache: nil, loader: loader, fingerprinter: .inMemory(), now: { [now] in now })
        let provider = UUID()
        let source = source
        let cancelled = Task { try await service.refresh(providerID: provider, source: source) }
        let kept = Task { try await service.refresh(providerID: provider, source: source) }
        try await waitUntil { await service.waiterCount(for: provider) == 2 }
        cancelled.cancel()
        await XCTAssertThrowsAsync(try await cancelled.value) { XCTAssertTrue($0 is CancellationError) }
        loader.release()
        let index = try await kept.value
        XCTAssertEqual(index.nowNext(guideID: "news.one", name: nil, at: now).next?.title, "Next")
        XCTAssertEqual(loader.calls, 1)
        XCTAssertEqual(loader.cancellations, 0)
    }

    func testRemovingAProviderDiscardsItsRefreshAndCache() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = GateLoader(payload: Data(serviceFeed.utf8))
        let service = EPGService(cache: EPGCacheStore(directory: directory), loader: loader, fingerprinter: .inMemory(), now: { [now] in now })
        let provider = UUID()
        let source = source
        let task = Task { try await service.refresh(providerID: provider, source: source) }
        try await waitUntil { loader.calls == 1 }
        await service.remove(providerID: provider)
        await XCTAssertThrowsAsync(try await task.value) { XCTAssertTrue($0 is CancellationError) }
        loader.release()
        try await Task.sleep(nanoseconds: 50_000_000)
        let index = await service.index(for: provider)
        XCTAssertNil(index)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [], [])
    }

    // MARK: - Helpers

    private var source: EPGFeedSource { .xmltv(URL(string: "https://guide.example/epg.xml.gz")!) }

    private var shortListing: [EPGProgram] {
        [EPGProgram(channelID: "sports.two", start: now, end: now.addingTimeInterval(3_600), title: "Short now")]
    }

    private var serviceFeed: String {
        feed([("news.one", -60, 90, "Current"), ("news.one", 30, 60, "Next"), ("news.one", 90, 1_200, "Later")])
    }

    /// An XMLTV document whose programmes start `minutes` from `now`.
    private func feed(_ items: [(channel: String, minutes: Int, duration: Int, title: String)]) -> String {
        "<tv>\n\(programmes(items))</tv>"
    }

    private func programmes(_ items: [(channel: String, minutes: Int, duration: Int, title: String)]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss '+0000'"
        return items.map { item in
            let start = now.addingTimeInterval(TimeInterval(item.minutes * 60))
            let end = start.addingTimeInterval(TimeInterval(item.duration * 60))
            return "<programme channel=\"\(item.channel)\" start=\"\(formatter.string(from: start))\" stop=\"\(formatter.string(from: end))\"><title>\(item.title)</title></programme>\n"
        }.joined()
    }

    private func encode(_ data: Data, algorithm: compression_algorithm) throws -> Data {
        let capacity = data.count + 64 * 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, algorithm)
            }
        }
        guard written > 0 else { throw EPGError.corruptCompressedData }
        return output.prefix(written)
    }

    /// One gzip member: header, raw deflate, then CRC (unchecked by the decoder) and size.
    private func gzipMember(_ data: Data) throws -> Data {
        var member = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
        member += try encode(data, algorithm: COMPRESSION_ZLIB)
        member += Data(repeating: 0, count: 4)
        let size = UInt32(truncatingIfNeeded: data.count)
        member += Data((0..<4).map { UInt8(truncatingIfNeeded: size >> (8 * $0)) })
        return member
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("KyroEPGTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            guard Date() < deadline else {
                XCTFail("condition not reached within \(timeout)s")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

private func XCTAssertThrowsAsync<T>(_ expression: @autoclosure () async throws -> T,
                                     file: StaticString = #filePath, line: UInt = #line,
                                     _ handler: (Error) -> Void = { _ in }) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    var date: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class LimitRecordingLoader: EPGFeedLoading, @unchecked Sendable {
    private let lock = NSLock()
    private let payload: Data
    private var recorded: [Int] = []
    init(payload: Data) { self.payload = payload }
    var limits: [Int] { lock.withLock { recorded } }

    func load(_ url: URL, maximumBytes: Int) async throws -> Data {
        XCTFail("the service must pass the decoded-XML cap")
        return payload
    }

    func load(_ url: URL, maximumBytes: Int, maximumDecodedBytes: Int) async throws -> Data {
        lock.withLock { recorded = [maximumBytes, maximumDecodedBytes] }
        return payload
    }
}

/// A feed loader that holds each download until released and records calls and cancellations.
private final class GateLoader: EPGFeedLoading, @unchecked Sendable {
    private let lock = NSLock()
    private let payload: Data
    private let failure: Error?
    private var isReleased: Bool
    private var callCount = 0
    private var cancellationCount = 0

    init(payload: Data, released: Bool = false, failure: Error? = nil) {
        self.payload = payload
        self.failure = failure
        isReleased = released
    }

    var calls: Int { lock.withLock { callCount } }
    var cancellations: Int { lock.withLock { cancellationCount } }
    func release() { lock.withLock { isReleased = true } }
    func hold() { lock.withLock { isReleased = false } }

    func load(_ url: URL, maximumBytes: Int) async throws -> Data {
        lock.withLock { callCount += 1 }
        do {
            while !lock.withLock({ isReleased }) { try await Task.sleep(nanoseconds: 1_000_000) }
        } catch {
            lock.withLock { cancellationCount += 1 }
            throw error
        }
        if let failure { throw failure }
        return payload
    }
}

private final class AcceptedByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var accepted = 0
    var value: Int { lock.withLock { accepted } }
    func set(_ count: Int) { lock.withLock { accepted = count } }
}

private final class StreamingURLProtocol: URLProtocol {
    private struct Plan {
        let chunks: [Data]
        let contentLength: String?
        let delay: UInt64
        var headers: [String: String] = [:]
    }
    private static let lock = NSLock()
    private static var plan = Plan(chunks: [], contentLength: nil, delay: 0)
    private static var sent = 0
    private static var stopped = false
    private static var headerNames: [String] = []
    private static var policy: URLRequest.CachePolicy = .useProtocolCachePolicy
    private let stateLock = NSLock()
    private var isStopped = false

    static var sentChunks: Int { lock.withLock { sent } }
    static var wasStopped: Bool { lock.withLock { stopped } }
    static var requestHeaderNames: [String] { lock.withLock { headerNames } }
    static var cachePolicy: URLRequest.CachePolicy { lock.withLock { policy } }

    static func install(chunks: [Data], contentLength: String?, delay: UInt64 = 0, headers: [String: String] = [:]) {
        lock.withLock {
            plan = Plan(chunks: chunks, contentLength: contentLength, delay: delay, headers: headers)
            sent = 0
            stopped = false
            headerNames = []
            policy = .useProtocolCachePolicy
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "epg.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let plan = Self.lock.withLock { () -> Plan in
            Self.headerNames = request.allHTTPHeaderFields?.keys.map { $0 } ?? []
            Self.policy = request.cachePolicy
            return Self.plan
        }
        var headers = plan.headers
        if let length = plan.contentLength { headers["Content-Length"] = length }
        guard let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().async { [self] in
            for chunk in plan.chunks {
                if plan.delay > 0 { Thread.sleep(forTimeInterval: Double(plan.delay) / 1_000_000_000) }
                guard !stateLock.withLock({ isStopped }) else { return }
                Self.lock.withLock { Self.sent += 1 }
                client?.urlProtocol(self, didLoad: chunk)
            }
            guard !stateLock.withLock({ isStopped }) else { return }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stateLock.withLock { isStopped = true }
        Self.lock.withLock { Self.stopped = true }
    }
}
