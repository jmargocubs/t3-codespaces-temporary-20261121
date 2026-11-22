#if os(iOS) || KYRO_VOD_HOST_TESTS
import Foundation
import XCTest
#if !KYRO_VOD_HOST_TESTS
@testable import Silo
#endif

/// Build 100 IPTV VOD checks that run on the Mac without a simulator
/// (`swiftc -D KYRO_VOD_HOST_TESTS`, see docs/kyro-development/build-100-iptv-vod.md) and in the
/// iOS test target.
final class IPTVVODPlaybackAndBrowseTests: XCTestCase {

    // MARK: Playback failure classification

    func testEngineFailuresMapToActionableReasons() {
        typealias D = ExternalPlaybackDiagnostics
        XCTAssertEqual(D.reason(kind: "sourceOpenFailed", domain: NSURLErrorDomain,
                                code: NSURLErrorAppTransportSecurityRequiresSecureConnection),
                       .insecureConnectionBlocked)
        XCTAssertEqual(D.reason(kind: "sourceRefused", domain: nil, code: 403), .accessRefused)
        XCTAssertEqual(D.reason(kind: "sourceRefused", domain: nil, code: 401), .accessRefused)
        XCTAssertEqual(D.reason(kind: "sourceRefused", domain: nil, code: 404), .notFound)
        XCTAssertEqual(D.reason(kind: "sourceRefused", domain: nil, code: 502), .providerError)
        XCTAssertEqual(D.reason(kind: "sourceRateLimited", domain: nil, code: 509), .connectionLimit)
        XCTAssertEqual(D.reason(kind: "sourceCertificateRejected", domain: NSURLErrorDomain, code: -1202),
                       .certificateRejected)
        XCTAssertEqual(D.reason(kind: "nativeItemFailed", domain: "AVFoundationErrorDomain", code: -11828),
                       .unsupportedMedia)
        XCTAssertEqual(D.reason(kind: "audioBridgeProducedNoOutput", domain: nil, code: nil), .unsupportedMedia)
        XCTAssertEqual(D.reason(kind: "vodSourceFailed", domain: NSURLErrorDomain, code: NSURLErrorTimedOut), .network)
        XCTAssertEqual(D.reason(kind: "sourceOpenFailed", domain: "FFmpeg", code: -1094995529), .unknown)
    }

    func testProbeRefinesTheEngineReason() {
        typealias D = ExternalPlaybackDiagnostics
        var downgrade = ExternalStreamProbeReport()
        downgrade.hops = [.init(status: 302, downgradedToHTTP: true, changedHost: true)]
        downgrade.transportErrorDomain = NSURLErrorDomain
        downgrade.transportErrorCode = NSURLErrorAppTransportSecurityRequiresSecureConnection
        XCTAssertEqual(D.reason(engine: .unknown, probe: downgrade), .insecureConnectionBlocked)
        XCTAssertTrue(downgrade.summary.contains("downgrade=https_to_http"))
        XCTAssertTrue(downgrade.summary.contains("error=url-1022"))

        var page = ExternalStreamProbeReport()
        page.finalStatus = 200
        page.contentType = "text/html; charset=UTF-8"
        page.container = .html
        XCTAssertEqual(D.reason(engine: .unknown, probe: page), .notMedia)

        var refused = ExternalStreamProbeReport()
        refused.finalStatus = 403
        XCTAssertEqual(D.reason(engine: .unknown, probe: refused), .accessRefused)

        var avi = ExternalStreamProbeReport()
        avi.finalStatus = 206
        avi.container = .avi
        XCTAssertEqual(D.reason(engine: .unknown, probe: avi), .unsupportedMedia)

        var healthy = ExternalStreamProbeReport()
        healthy.finalStatus = 206
        healthy.container = .matroska
        XCTAssertEqual(D.reason(engine: .network, probe: healthy), .network,
                       "A healthy probe must not hide the engine's own classification")
        XCTAssertEqual(D.reason(engine: .accessRefused, probe: nil), .accessRefused)
    }

    func testDiagnosticCodeCarriesNoURLOrCredential() {
        var report = ExternalStreamProbeReport()
        report.finalStatus = 200
        report.finalScheme = "http"
        // A hostile header value must not smuggle a URL or query into the journal.
        report.contentType = "video/mp4; x=http://user:secret@host/movie/user/secret/1.mp4?token=abc"
        report.totalBytes = 1_500_000_000
        report.acceptsRanges = true
        report.container = .mp4
        let code = ExternalPlaybackDiagnostics.diagnosticCode(
            reason: .unknown, kind: "sourceOpenFailed", domain: NSURLErrorDomain, code: -1005, probe: report)
        for forbidden in ["secret", "token", "user", "://", "?", "@", "host"] {
            XCTAssertFalse(code.contains(forbidden), "\(forbidden) leaked into \(code)")
        }
        XCTAssertTrue(code.contains("type=video/mp4"))
        XCTAssertTrue(code.contains("size=1.4GB"))
        XCTAssertTrue(code.contains("code=url-1005"))
        XCTAssertEqual(ExternalPlaybackDiagnostics.sanitizedToken("http://a.b/c?d=e"), "http//a.b/cde")
    }

    func testContainerSniffing() {
        typealias D = ExternalPlaybackDiagnostics
        XCTAssertEqual(D.sniffContainer([0x1A, 0x45, 0xDF, 0xA3, 0x01]), .matroska)
        XCTAssertEqual(D.sniffContainer([0, 0, 0, 0x20] + Array("ftypisom".utf8)), .mp4)
        var ts = [UInt8](repeating: 0, count: 400)
        ts[0] = 0x47; ts[188] = 0x47; ts[376] = 0x47
        XCTAssertEqual(D.sniffContainer(ts), .mpegts)
        XCTAssertEqual(D.sniffContainer(Array("#EXTM3U\n#EXT-X-VERSION:3".utf8)), .hls)
        XCTAssertEqual(D.sniffContainer(Array("<!DOCTYPE html><html>".utf8)), .html)
        XCTAssertEqual(D.sniffContainer(Array("{\"user_info\":{}}".utf8)), .json)
        XCTAssertEqual(D.sniffContainer(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("AVI ".utf8)), .avi)
        XCTAssertEqual(D.sniffContainer([]), .unknown)
    }

    func testTotalBytesPrefersContentRange() {
        typealias D = ExternalPlaybackDiagnostics
        XCTAssertEqual(D.totalBytes(status: 206, contentRange: "bytes 0-4095/987654321", contentLength: 4096), 987_654_321)
        XCTAssertEqual(D.totalBytes(status: 200, contentRange: nil, contentLength: 1234), 1234)
        XCTAssertNil(D.totalBytes(status: 206, contentRange: nil, contentLength: 4096))
        XCTAssertNil(D.totalBytes(status: 200, contentRange: nil, contentLength: -1))
    }

    // MARK: Playback URL routing

    func testMovieAndEpisodeURLsUseTheirOwnRoutesAndContainers() throws {
        let movie = try XtreamURLBuilder.vodPlaybackURL(
            server: "https://panel.example:8443/base/", username: "u ser", password: "p@ss/1",
            kind: .movie, itemID: 42, fileExtension: "MKV")
        XCTAssertEqual(movie.absoluteString, "https://panel.example:8443/base/movie/u%20ser/p%40ss%2F1/42.mkv")
        let episode = try XtreamURLBuilder.vodPlaybackURL(
            server: "http://panel.example", username: "u", password: "p",
            kind: .series, itemID: 9001, fileExtension: "ts")
        XCTAssertEqual(episode.path, "/series/u/p/9001.ts")
        XCTAssertThrowsError(try XtreamURLBuilder.vodPlaybackURL(
            server: "http://panel.example", username: "u", password: "p",
            kind: .movie, itemID: 1, fileExtension: "mp4?x=1"))
        XCTAssertThrowsError(try XtreamURLBuilder.vodPlaybackURL(
            server: "http://panel.example", username: "u", password: "p",
            kind: .movie, itemID: 0, fileExtension: "mp4"))
        XCTAssertThrowsError(try XtreamURLBuilder.vodPlaybackURL(
            server: "ftp://panel.example", username: "u", password: "p",
            kind: .movie, itemID: 1, fileExtension: "mp4"))
    }

    // MARK: Presentation helpers

    func testTitleYearOnlyWhenSetApart() {
        XCTAssertEqual(XtreamVODTitle.year(in: "Heat (1995)"), 1995)
        XCTAssertEqual(XtreamVODTitle.year(in: "#1 Cheerleader Camp (2010)"), 2010)
        XCTAssertEqual(XtreamVODTitle.year(in: "Heat - 1995"), 1995)
        XCTAssertEqual(XtreamVODTitle.year(in: "Heat [1995]"), 1995)
        XCTAssertNil(XtreamVODTitle.year(in: "Blade Runner 2049"))
        XCTAssertNil(XtreamVODTitle.year(in: "Room 21000"))
        XCTAssertNil(XtreamVODTitle.year(in: "Movie (3000)"))
        XCTAssertNil(XtreamVODTitle.year(in: "Up"))
    }

    func testCategoryShelvesLeadWithLargestAndSkipAdultAndOther() {
        let ordered = XtreamVODCategorySummary.ordered([
            .init(name: "Drama", count: 40), .init(name: "Action", count: 40),
            .init(name: "XXX Adult", count: 900), .init(name: "Other", count: 500),
            .init(name: "Kids", count: 10), .init(name: "Empty", count: 0),
        ])
        XCTAssertEqual(ordered.map(\.name), ["XXX Adult", "Other", "Action", "Drama", "Kids", "Empty"])
        XCTAssertEqual(XtreamVODCategorySummary.shelfCategories(ordered).map(\.name), ["Action", "Drama", "Kids"])
        XCTAssertEqual(XtreamVODCategorySummary.shelfCategories(ordered, limit: 1).map(\.name), ["Action"])
    }

    // MARK: Store shelves

    func testNewestShelvesAndCategorySummariesStayProviderScoped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IPTVVODShelves-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try XtreamVODCatalogStore(directory: root)
        let provider = UUID()
        let other = UUID()
        func item(_ provider: UUID, _ id: Int, _ title: String, _ category: String) -> XtreamVODItem {
            .init(providerID: provider, kind: .movie, remoteID: id, title: title, category: category,
                  poster: nil, fileExtension: "mkv", summary: nil, genre: nil, rating: nil)
        }
        try await store.stage([
            item(provider, 5, "Echo", "Drama"), item(provider, 30, "Alpha", "Action"),
            item(provider, 12, "Bravo", "Drama"), item(provider, 7, "Delta", "Action"),
            item(provider, 99, "Zulu", "Drama"),
        ], generation: "g1")
        try await store.promote(providerID: provider, kind: .movie, generation: "g1")
        try await store.stage([item(other, 1000, "Other provider", "Drama")], generation: "o1")
        try await store.promote(providerID: other, kind: .movie, generation: "o1")

        let newest = await store.newest(providerID: provider, kind: .movie, limit: 3)
        XCTAssertEqual(newest.map(\.remoteID), [99, 30, 12])
        let drama = await store.newest(providerID: provider, kind: .movie, category: "Drama", limit: 10)
        XCTAssertEqual(drama.map(\.remoteID), [99, 12, 5])
        let summaries = await store.categorySummaries(providerID: provider, kind: .movie)
        XCTAssertEqual(summaries, [.init(name: "Drama", count: 3), .init(name: "Action", count: 2)])
        let series = await store.newest(providerID: provider, kind: .series)
        XCTAssertTrue(series.isEmpty)
        await store.close()
    }
}
#endif
