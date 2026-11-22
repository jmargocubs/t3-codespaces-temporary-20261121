#if os(iOS)
import XCTest
@testable import Silo

/// Build 103: an IPTV poster opens the same router-owned detail card as a Silo poster, with the
/// provider's page as its root. Needs the iOS runtime (Simulator or device).
@MainActor
final class IPTVDetailPresentationTests: XCTestCase {
    private func request(_ kind: XtreamVODKind, id: Int = 7) -> KyroIPTVDetailRequest {
        KyroIPTVDetailRequest(
            item: XtreamVODItem(providerID: UUID(), kind: kind, remoteID: id, title: "Title",
                                category: "All", poster: nil, fileExtension: "mp4", summary: nil,
                                genre: nil, rating: nil),
            providerName: "My Playlist"
        )
    }

    func testIPTVPosterOpensTheSharedDetailCardWithTheProviderRoot() throws {
        let router = AppRouter()
        let series = request(.series)
        router.presentIPTVDetail(series)

        let card = try XCTUnwrap(router.presentedItemDetail)
        XCTAssertEqual(card.iptv, series)
        XCTAssertEqual(card.iptv?.page, .series)
        XCTAssertNil(card.request)
        XCTAssertEqual(card.contentId, series.pageIdentity)
        XCTAssertTrue(router.itemDetailPath.isEmpty)
        XCTAssertTrue(router.path.isEmpty, "the page's stack is untouched; the card covers it")
    }

    func testSiloAndIPTVPostersReplaceEachOthersCardRoot() throws {
        let router = AppRouter()
        router.presentIPTVDetail(request(.movie))
        router.dismissItemDetail()
        router.presentItemDetail(contentId: "silo-movie", libraryId: 3)

        let silo = try XCTUnwrap(router.presentedItemDetail)
        XCTAssertNil(silo.iptv, "a Silo title never opens on a stale provider root")
        XCTAssertEqual(silo.contentId, "silo-movie")

        router.dismissItemDetail()
        router.presentIPTVDetail(request(.movie, id: 8))
        XCTAssertEqual(router.presentedItemDetail?.iptv?.item.remoteID, 8)
        XCTAssertNotEqual(router.presentedItemDetail?.id, silo.id)
    }

    func testIPTVCardStaysASheetWhenTheWindowWouldSplitADetail() throws {
        let router = AppRouter()
        router.presentsItemDetailFullWindow = true
        router.presentIPTVDetail(request(.movie))
        let opened = try XCTUnwrap(router.presentedItemDetail)
        XCTAssertFalse(opened.fillsWindow, "the provider page has no split layout")

        router.refitItemDetail()
        XCTAssertEqual(router.presentedItemDetail, opened, "a refit never rebuilds it under the player")
    }

    func testClosingTheCardLeavesNoProviderState() {
        let router = AppRouter()
        router.presentIPTVDetail(request(.series))
        router.dismissItemDetail()
        XCTAssertNil(router.presentedItemDetail)
        XCTAssertTrue(router.visibleItemDetailRoutes.isEmpty)
    }

    func testMatchedSourcesKeepEveryProviderAndBackReturnsToPrimary() throws {
        let router = AppRouter()
        let first = request(.movie, id: 7)
        let second = request(.movie, id: 8)
        router.presentUnifiedSiloDetail(contentId: "silo-movie", libraryId: 3,
                                        alternates: [first, second])
        XCTAssertEqual(router.presentedItemDetail?.alternates.count, 2)
        XCTAssertEqual(router.presentedItemDetail?.contentId, "silo-movie")
        router.openAlternateIPTVDetail(second)
        XCTAssertEqual(router.itemDetailPath.count, 1)
        router.goBackInItemDetail()
        XCTAssertTrue(router.itemDetailPath.isEmpty)
        XCTAssertEqual(router.presentedItemDetail?.alternates.count, 2)
    }
}
#endif
