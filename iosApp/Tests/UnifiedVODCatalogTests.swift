#if os(iOS)
import XCTest
@testable import Silo

final class UnifiedVODCatalogTests: XCTestCase {
    private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private func entry(_ id: String, _ origin: UnifiedVODEntry.Origin, _ kind: UnifiedVODEntry.Kind = .movie,
                       _ title: String = "Arrival", _ year: Int? = 2016,
                       tmdb: String? = nil) -> UnifiedVODEntry {
        UnifiedVODEntry(id: id, origin: origin, kind: kind, title: title, year: year, tmdbID: tmdb)
    }

    func testConfidentTitleAndYearCombinesSiloAndMultiplePlaylists() {
        let titles = UnifiedVODCatalog.aggregate([
            entry("silo:1", .silo), entry("iptv:1", .iptv(first), .movie, "Arrival (2016)"),
            entry("iptv:2", .iptv(second), .movie, "Arrival - 2016")
        ])
        XCTAssertEqual(titles.count, 1)
        XCTAssertEqual(titles[0].entries.count, 3)
        XCTAssertEqual(titles[0].primaryEntry?.id, "silo:1")
        XCTAssertEqual(Set(titles[0].entries.map(\.origin)), [.silo, .iptv(first), .iptv(second)])
    }

    func testSingleSourceDetailIdentityAndProviderRemoval() {
        let silo = entry("silo:1", .silo)
        let iptv = entry("iptv:1", .iptv(first))
        XCTAssertEqual(UnifiedVODCatalog.aggregate([silo])[0].primaryEntry?.id, silo.id)
        XCTAssertEqual(UnifiedVODCatalog.aggregate([iptv])[0].primaryEntry?.id, iptv.id)
        XCTAssertEqual(UnifiedVODCatalog.aggregate([silo, iptv])[0].primaryEntry?.id, silo.id)
        let afterRemoval = UnifiedVODCatalog.aggregate([silo, iptv].filter { $0.origin != .iptv(first) })
        XCTAssertEqual(afterRemoval.count, 1)
        XCTAssertTrue(afterRemoval[0].iptvItems.isEmpty)
    }

    func testAmbiguousSameProviderDuplicateStaysSeparate() {
        let titles = UnifiedVODCatalog.aggregate([
            entry("silo:1", .silo), entry("silo:2", .silo), entry("iptv:1", .iptv(first))
        ])
        XCTAssertEqual(titles.count, 3)
    }

    func testMissingYearTypeAndConflictingIdentifiersDoNotMerge() {
        XCTAssertEqual(UnifiedVODCatalog.aggregate([
            entry("silo", .silo, .movie, "Arrival", nil),
            entry("iptv", .iptv(first), .movie, "Arrival", nil)
        ]).count, 2)
        XCTAssertEqual(UnifiedVODCatalog.aggregate([
            entry("movie", .silo), entry("series", .iptv(first), .series)
        ]).count, 2)
        XCTAssertEqual(UnifiedVODCatalog.aggregate([
            entry("silo", .silo, tmdb: "1"), entry("iptv", .iptv(first), tmdb: "2")
        ]).count, 2)
    }

    func testSharedIdentifierMatchesWhenTitlesDiffer() {
        let titles = UnifiedVODCatalog.aggregate([
            entry("silo", .silo, .movie, "Localized Title", nil, tmdb: "10"),
            entry("iptv", .iptv(first), .movie, "Original Title", nil, tmdb: "10")
        ])
        XCTAssertEqual(titles.count, 1)
    }

    func testAutomaticPolicyDoesNotRetryOrSwitchAfterStart() {
        let silo = entry("silo", .silo)
        let iptv = entry("iptv", .iptv(first))
        XCTAssertEqual(VODPlaybackPolicy.order(sources: [iptv, silo]).map(\.id), ["silo", "iptv"])
        XCTAssertEqual(VODPlaybackPolicy.order(sources: [iptv, silo], failedIDs: ["silo"]).map(\.id), ["iptv"])
        XCTAssertEqual(VODPlaybackPolicy.order(sources: [iptv, silo], usableIDs: ["iptv"]).map(\.id), ["iptv"])
        XCTAssertTrue(VODPlaybackPolicy.order(sources: [iptv, silo], playbackStarted: true).isEmpty)
        XCTAssertTrue(VODPlaybackPolicy.order(preference: .askEveryTime, sources: [iptv, silo]).isEmpty)
        XCTAssertEqual(VODPlaybackPolicy.order(sources: [iptv, silo], manualSourceID: "iptv").map(\.id), ["iptv"])
    }

    func testRequestFallbackFiltersKnownIPTVAndKeepsMissingTitles() {
        let state = RequestState(status: nil, state: nil, requestable: true, reason: nil, requestId: nil)
        func request(_ title: String, _ year: Int?) -> RequestMediaResult {
            RequestMediaResult(mediaType: .movie, tmdbId: 1, title: title, year: year,
                               overview: nil, posterPath: nil, backdropPath: nil, releaseDate: nil,
                               voteAverage: nil, availability: .missing, libraryContentId: nil, request: state)
        }
        let playable = entry("iptv", .iptv(first), .movie, "Arrival (2016)")
        XCTAssertTrue(UnifiedVODCatalog.matchesRequest(request("Arrival", 2016), entry: playable))
        XCTAssertFalse(UnifiedVODCatalog.matchesRequest(request("Dune", 2021), entry: playable))
        XCTAssertFalse(UnifiedVODCatalog.matchesRequest(request("Arrival", 2017), entry: playable))
        let requests = [request("Arrival", 2016), request("Dune", 2021)]
        XCTAssertTrue(UnifiedVODCatalog.requestableResults(requests, local: [playable],
            siloReady: false, vodReady: true).isEmpty)
        XCTAssertTrue(UnifiedVODCatalog.requestableResults(requests, local: [playable],
            siloReady: true, vodReady: false).isEmpty)
        XCTAssertEqual(UnifiedVODCatalog.requestableResults(requests, local: [playable],
            siloReady: true, vodReady: true).map(\.title), ["Dune"])
    }

    func testSearchSubmissionAndKeyboardDismissalKeepCompletedQueryIdentity() {
        // Submission and keyboard dismissal do not start a new query or invalidate its token.
        var tracker = VODSearchRequestTracker()
        let submitted = tracker.begin(" Fraidy ")
        XCTAssertTrue(tracker.accepts(submitted, query: "Fraidy"))
        XCTAssertTrue(tracker.accepts(submitted, query: " Fraidy "))
    }

    func testRapidQueryChangeRejectsStaleIPTVResponse() {
        var tracker = VODSearchRequestTracker()
        let movieQuery = tracker.begin("Fraidy")
        let seriesQuery = tracker.begin("Fraidy series")
        XCTAssertFalse(tracker.accepts(movieQuery, query: "Fraidy"))
        XCTAssertTrue(tracker.accepts(seriesQuery, query: "Fraidy series"))
    }

    func testCancellationAndReopeningUseFreshSearchIdentity() {
        var tracker = VODSearchRequestTracker()
        let beforeDismissal = tracker.begin("Fraidy")
        tracker.cancel()
        XCTAssertFalse(tracker.accepts(beforeDismissal, query: "Fraidy"))
        let reopened = tracker.begin("Fraidy")
        XCTAssertTrue(tracker.accepts(reopened, query: "Fraidy"))
        XCTAssertFalse(tracker.accepts(beforeDismissal, query: "Fraidy"))
    }

    func testMovieAndSeriesQueriesHaveIndependentFreshResults() {
        var tracker = VODSearchRequestTracker()
        let movie = tracker.begin("Fraidy")
        XCTAssertTrue(tracker.accepts(movie, query: "Fraidy"))
        let series = tracker.begin("Fraidy series")
        XCTAssertFalse(tracker.accepts(movie, query: "Fraidy"))
        XCTAssertTrue(tracker.accepts(series, query: "Fraidy series"))
    }
}
#endif
