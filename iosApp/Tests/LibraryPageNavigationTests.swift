#if os(iOS) || KYRO_VOD_HOST_TESTS
import Foundation
import XCTest
#if !KYRO_VOD_HOST_TESTS
@testable import Silo
#endif

/// Build 103: what a Movies/Series poster opens, how a provider title reaches the player, and
/// which source a page shows and keeps mounted. Runs on the Mac without a simulator
/// (`swiftc -D KYRO_VOD_HOST_TESTS`, see docs/kyro-development/build-103-shared-library-page.md)
/// and in the iOS test target.
final class LibraryPageNavigationTests: XCTestCase {
    private let providerA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let providerB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    private func item(_ kind: XtreamVODKind, id: Int = 7, provider: UUID? = nil,
                      title: String = "Heat (1995)") -> XtreamVODItem {
        XtreamVODItem(providerID: provider ?? providerA, kind: kind, remoteID: id, title: title,
                      category: "Drama", poster: nil, fileExtension: "mkv", summary: nil,
                      genre: nil, rating: nil)
    }

    private func episode(_ id: Int, season: Int = 1, number: Int) -> XtreamVODEpisode {
        XtreamVODEpisode(remoteID: id, season: season, number: number, title: "Episode \(number)",
                         fileExtension: "mkv", summary: nil)
    }

    // MARK: Card to detail

    func testMoviePosterOpensTheMoviePageAndSeriesPosterOpensTheSeriesPage() {
        let movie = KyroIPTVDetailRequest(item: item(.movie), providerName: "My Playlist")
        let series = KyroIPTVDetailRequest(item: item(.series), providerName: "My Playlist")
        XCTAssertEqual(movie.page, .movie)
        XCTAssertEqual(series.page, .series)
        XCTAssertEqual(movie.item.kind, .movie)
        XCTAssertEqual(series.providerName, "My Playlist")
    }

    func testProviderPageIdentityNeverCollidesWithSiloOrAnotherProvider() {
        let movie = KyroIPTVDetailRequest(item: item(.movie, id: 42), providerName: "A")
        let sameIDSeries = KyroIPTVDetailRequest(item: item(.series, id: 42), providerName: "A")
        let otherProvider = KyroIPTVDetailRequest(item: item(.movie, id: 42, provider: providerB), providerName: "B")
        XCTAssertTrue(movie.pageIdentity.hasPrefix("iptv:"), "never readable as a Silo content ID")
        XCTAssertNotEqual(movie.pageIdentity, "42")
        XCTAssertNotEqual(movie.pageIdentity, sameIDSeries.pageIdentity)
        XCTAssertNotEqual(movie.pageIdentity, otherProvider.pageIdentity)
        XCTAssertNotEqual(movie, otherProvider)
        XCTAssertEqual(movie, KyroIPTVDetailRequest(item: item(.movie, id: 42), providerName: "A"))
    }

    // MARK: Playback hand-off

    func testStartPositionResumesUnlessStartOverOrBarelyStarted() {
        let watching = XtreamVODWatchState(position: 600, duration: 3600)
        XCTAssertEqual(KyroIPTVPlaybackPlan.startPosition(for: watching, fromStart: false), 600)
        XCTAssertEqual(KyroIPTVPlaybackPlan.startPosition(for: watching, fromStart: true), 0, "Start Over")
        let barely = XtreamVODWatchState(position: 10, duration: 3600)
        XCTAssertEqual(KyroIPTVPlaybackPlan.startPosition(for: barely, fromStart: false), 0)
        let finished = XtreamVODWatchState(position: 3590, duration: 3600, completed: true)
        XCTAssertEqual(KyroIPTVPlaybackPlan.startPosition(for: finished, fromStart: false), 0)
        XCTAssertEqual(KyroIPTVPlaybackPlan.startPosition(for: XtreamVODWatchState(), fromStart: false), 0)
    }

    func testProgressShowsOnlyForResumableTitlesWithADuration() {
        XCTAssertEqual(KyroIPTVPlaybackPlan.progress(for: XtreamVODWatchState(position: 900, duration: 3600)), 0.25)
        XCTAssertNil(KyroIPTVPlaybackPlan.progress(for: XtreamVODWatchState(position: 900, duration: 0)))
        XCTAssertNil(KyroIPTVPlaybackPlan.progress(for: XtreamVODWatchState(position: 5, duration: 3600)))
        XCTAssertNil(KyroIPTVPlaybackPlan.progress(for: XtreamVODWatchState(position: 900, duration: 3600, completed: true)))
    }

    func testPlayerNamesTheTitleEpisodeAndSource() {
        let show = item(.series, title: "Severance")
        XCTAssertEqual(KyroIPTVPlaybackPlan.title(for: show, episode: episode(1, season: 2, number: 3)),
                       "Severance · S2 E3")
        XCTAssertEqual(KyroIPTVPlaybackPlan.title(for: item(.movie), episode: nil), "Heat (1995)")
        XCTAssertEqual(KyroIPTVPlaybackPlan.sourceLabel(providerName: "My Playlist"), "IPTV · My Playlist")
    }

    func testSeriesPlayOffersTheLatestUnfinishedEpisodeElseTheNextOne() {
        let episodes = [episode(1, number: 1), episode(2, number: 2), episode(3, number: 3), episode(4, number: 4)]
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 2_000)

        var states: [Int: XtreamVODWatchState] = [
            1: XtreamVODWatchState(position: 100, duration: 1000, updatedAt: old),
            3: XtreamVODWatchState(position: 200, duration: 1000, updatedAt: recent),
        ]
        XCTAssertEqual(KyroIPTVPlaybackPlan.resumeEpisode(in: episodes) { states[$0.remoteID] ?? .init() }?.remoteID, 3)

        states = [1: .init(completed: true), 2: .init(completed: true)]
        XCTAssertEqual(KyroIPTVPlaybackPlan.resumeEpisode(in: episodes) { states[$0.remoteID] ?? .init() }?.remoteID, 3)

        states = [4: .init(completed: true)]
        XCTAssertNil(KyroIPTVPlaybackPlan.resumeEpisode(in: episodes) { states[$0.remoteID] ?? .init() },
                     "after the last episode the page falls back to the first")
        XCTAssertNil(KyroIPTVPlaybackPlan.resumeEpisode(in: episodes) { _ in .init() })
    }

    // MARK: Source switching

    func testSwitchingSourcesKeepsTheShownProviderPageMounted() {
        var state = LibraryPageSourceState()
        state.update(offeredAlternateID: "iptv.A", showsAlternate: false)
        XCTAssertFalse(state.mountsAlternate("iptv.A"), "not built until first shown")

        state.update(offeredAlternateID: "iptv.A", showsAlternate: true)
        XCTAssertTrue(state.mountsAlternate("iptv.A"))
        state.update(offeredAlternateID: "iptv.A", showsAlternate: false)
        XCTAssertTrue(state.mountsAlternate("iptv.A"), "back to Silo keeps the provider's scroll and pages")
    }

    func testAnotherProviderOrTurningIPTVOffDropsTheStalePage() {
        var state = LibraryPageSourceState()
        state.update(offeredAlternateID: "iptv.A", showsAlternate: true)
        state.update(offeredAlternateID: "iptv.A", showsAlternate: false)

        state.update(offeredAlternateID: "iptv.B", showsAlternate: false)
        XCTAssertFalse(state.mountsAlternate("iptv.A"))
        XCTAssertFalse(state.mountsAlternate("iptv.B"))

        state.update(offeredAlternateID: "iptv.B", showsAlternate: true)
        XCTAssertTrue(state.mountsAlternate("iptv.B"))

        state.update(offeredAlternateID: nil, showsAlternate: false)
        XCTAssertFalse(state.mountsAlternate("iptv.B"))
        state.update(offeredAlternateID: "iptv.B", showsAlternate: false)
        XCTAssertFalse(state.mountsAlternate("iptv.B"), "turning IPTV back on does not revive the old page")
    }

    func testThePageShowsIPTVWhenChosenOrWhenItIsTheOnlyCatalog() {
        typealias S = LibraryPageSourceState
        XCTAssertFalse(S.showsAlternate(isOffered: false, isSelected: true, hasActiveLibrary: false, isLoadingLibraries: false))
        XCTAssertTrue(S.showsAlternate(isOffered: true, isSelected: true, hasActiveLibrary: true, isLoadingLibraries: false))
        XCTAssertFalse(S.showsAlternate(isOffered: true, isSelected: false, hasActiveLibrary: true, isLoadingLibraries: false))
        XCTAssertTrue(S.showsAlternate(isOffered: true, isSelected: false, hasActiveLibrary: false, isLoadingLibraries: false),
                      "a profile with no Silo library of this type lands on IPTV")
        XCTAssertFalse(S.showsAlternate(isOffered: true, isSelected: false, hasActiveLibrary: false, isLoadingLibraries: true),
                       "no flash of IPTV while Silo libraries load")
    }
}
#endif
