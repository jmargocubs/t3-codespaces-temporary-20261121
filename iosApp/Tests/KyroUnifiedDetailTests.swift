import XCTest
@testable import Silo

#if os(iOS)
final class KyroUnifiedDetailTests: XCTestCase {
    private let providerID = UUID(uuidString: "00000000-0000-0000-0000-000000000111")!

    private func item(_ title: String = "Arrival (2016)", kind: XtreamVODKind = .movie,
                      id: Int = 7) -> XtreamVODItem {
        XtreamVODItem(providerID: providerID, kind: kind, remoteID: id, title: title,
                      category: "Drama", poster: "https://example.test/poster.jpg", fileExtension: "mp4",
                      summary: "Provider summary", genre: "Drama, Mystery", rating: "7.2")
    }

    private func candidate(_ title: String, year: Int?, id: Int,
                           type: RequestMediaType = .movie) -> RequestMediaResult {
        RequestMediaResult(mediaType: type, tmdbId: id, title: title, year: year, overview: nil,
                           posterPath: nil, backdropPath: nil, releaseDate: nil, voteAverage: nil,
                           availability: .missing, libraryContentId: nil,
                           request: RequestState(status: nil, state: nil, requestable: false,
                                                 reason: nil, requestId: nil))
    }

    func testExactTitleYearAndMediaTypeAreRequired() {
        let candidates = [candidate("Arrival", year: 2016, id: 1),
                          candidate("Arrival", year: 2017, id: 2),
                          candidate("Arrival", year: 2016, id: 3, type: .series)]
        XCTAssertEqual(KyroIPTVMetadataMatch.uniqueID(item: item(), providerDetail: nil,
                                                      candidates: candidates), 1)
        XCTAssertNil(KyroIPTVMetadataMatch.uniqueID(item: item("Arrival"), providerDetail: nil,
                                                    candidates: candidates))
        XCTAssertNil(KyroIPTVMetadataMatch.uniqueID(item: item(), providerDetail: nil,
                                                    candidates: candidates + [candidate("Arrival", year: 2016, id: 4)]))
        XCTAssertEqual(KyroIPTVMetadataMatch.searchTitle("Arrival (2016)", year: 2016), "Arrival")
    }

    func testDetailExternalIDWinsWithoutSearchAndProviderIDRemainsIntact() {
        var detail = XtreamVODDetail(summary: nil, genre: nil, rating: nil, duration: nil, episodes: [])
        detail.tmdbID = 99
        XCTAssertEqual(KyroIPTVMetadataMatch.uniqueID(item: item(), providerDetail: detail,
                                                      candidates: []), 99)
        XCTAssertEqual(item().id, "\(providerID.uuidString):movie:7")
    }

    func testMissingMetadataLeavesProviderPresentationAvailable() {
        let model = KyroIPTVDetailPresentation(item: item(), provider: nil, metadata: nil)
        XCTAssertEqual(model.synopsis, "Provider summary")
        XCTAssertEqual(model.posterURL, "https://example.test/poster.jpg")
        XCTAssertNil(model.backdropURL)
        XCTAssertEqual(model.genres, ["Drama", "Mystery"])
        XCTAssertEqual(model.providerRatingChip, "★ 7.2")
        XCTAssertTrue(model.ratings.isEmpty)
    }

    func testUnifiedHeaderIdentityDoesNotDependOnBrowseTab() {
        for _ in LibraryPageTab.allCases {
            XCTAssertEqual(UnifiedBrowseChrome.title(for: .movies), "Movies")
            XCTAssertEqual(UnifiedBrowseChrome.title(for: .series), "Series")
        }
        XCTAssertNil(UnifiedBrowseChrome.title(for: .audiobooks))
    }

    func testSeriesEpisodesRemainProviderPlaybackIdentities() {
        let episode = XtreamVODEpisode(remoteID: 501, season: 2, number: 3,
                                        title: "Episode 3", fileExtension: "mkv", summary: "Plot")
        let detail = XtreamVODDetail(summary: nil, genre: nil, rating: nil,
                                      duration: nil, episodes: [episode])
        let series = item("A Show (2020)", kind: .series)
        let model = KyroIPTVDetailPresentation(item: series, provider: detail, metadata: nil)
        XCTAssertEqual(model.facts.count, 2)
        XCTAssertEqual(detail.episodes.first?.remoteID, 501)
        XCTAssertEqual(KyroIPTVPlaybackPlan.title(for: series, episode: episode),
                       "A Show (2020) · S2 E3")
    }

    func testProviderTrailerMustBeARealYouTubeDestination() {
        XCTAssertEqual(XtreamVODParser.verifiedTrailerURL("dQw4w9WgXcQ")?.host, "www.youtube.com")
        XCTAssertNil(XtreamVODParser.verifiedTrailerURL("http://youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertNil(XtreamVODParser.verifiedTrailerURL("https://example.com/watch?v=dQw4w9WgXcQ"))
    }

    func testMetadataCacheClearKeepsPlaybackUnchanged() async {
        await KyroIPTVMetadataEnrichment.shared.clear()
        let movie = item()
        let state = XtreamVODWatchState(position: 30, duration: 120, updatedAt: .now,
                                        favorite: false, completed: false)
        XCTAssertEqual(KyroIPTVPlaybackPlan.startPosition(for: state, fromStart: false), 30)
        XCTAssertEqual(KyroIPTVPlaybackPlan.title(for: movie, episode: nil), movie.title)
    }

    @MainActor
    func testSuccessfulMetadataIsCachedAndConcurrentOpensCoalesce() async throws {
        let payload = #"{"mediaType":"movie","tmdbId":99,"title":"Arrival","availability":"missing","request":{"requestable":false}}"#
        let response = try JSONDecoder().decode(RequestMediaDetail.self, from: Data(payload.utf8))
        var calls = 0
        let cache = KyroIPTVMetadataEnrichment(search: { _, _ in
            XCTFail("An external ID must not search")
            throw NSError(domain: "unexpected", code: 1)
        }, load: { _, _ in
            calls += 1
            try await Task.sleep(for: .milliseconds(25))
            return response
        })
        var provider = XtreamVODDetail(summary: nil, genre: nil, rating: nil, duration: nil, episodes: [])
        provider.tmdbID = 99
        let resolvedProvider = provider
        let movie = item()
        async let first = cache.detail(for: movie, providerDetail: resolvedProvider)
        async let second = cache.detail(for: movie, providerDetail: resolvedProvider)
        let (one, two) = await (first, second)
        XCTAssertEqual(one?.tmdbId, 99)
        XCTAssertEqual(two?.tmdbId, 99)
        let cached = await cache.detail(for: movie, providerDetail: provider)
        XCTAssertEqual(cached?.tmdbId, 99)
        XCTAssertEqual(calls, 1)
        cache.clear()
        _ = await cache.detail(for: movie, providerDetail: provider)
        XCTAssertEqual(calls, 2)
    }
}
#endif
