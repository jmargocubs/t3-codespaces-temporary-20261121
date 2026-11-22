#if os(iOS) && !KYRO_VOD_HOST_TESTS
import XCTest
@testable import Silo

/// Build 110: a matched unified title opens its existing Silo (or IPTV) detail and carries every
/// other IPTV source into the card. Needs the iOS runtime (Simulator or device).
@MainActor
final class UnifiedCatalogNavigationTests: XCTestCase {
    private func request(_ provider: UUID, _ id: Int, name: String) -> KyroIPTVDetailRequest {
        KyroIPTVDetailRequest(
            item: XtreamVODItem(providerID: provider, kind: .movie, remoteID: id, title: "Arrival (2016)",
                                category: "All", poster: nil, fileExtension: "mp4", summary: nil,
                                genre: nil, rating: nil),
            providerName: name
        )
    }

    func testMatchedSiloTitleKeepsEveryIPTVSourceAndBackReturnsToIt() throws {
        let router = AppRouter()
        let alternates = [request(UUID(), 1, name: "First"), request(UUID(), 2, name: "Second")]
        router.presentUnifiedSiloDetail(contentId: "movie:arrival", libraryId: 4, alternates: alternates)

        let card = try XCTUnwrap(router.presentedItemDetail)
        XCTAssertEqual(card.contentId, "movie:arrival")
        XCTAssertEqual(card.libraryId, 4)
        XCTAssertNil(card.iptv, "the Silo detail stays the root and keeps Silo playback")
        XCTAssertEqual(card.alternates, alternates)

        router.openAlternateIPTVDetail(alternates[1])
        XCTAssertEqual(router.itemDetailPath.count, 1, "the alternate is pushed inside the same card")
        XCTAssertEqual(router.presentedItemDetail?.id, card.id)
        router.goBackInItemDetail()
        XCTAssertTrue(router.itemDetailPath.isEmpty)
        XCTAssertEqual(router.presentedItemDetail?.contentId, "movie:arrival")
        XCTAssertTrue(router.path.isEmpty, "the browsing page underneath never moved")
    }

    func testIPTVOnlyTitleOpensItsProviderWithOtherProvidersAsAlternates() throws {
        let router = AppRouter()
        let primary = request(UUID(), 1, name: "First")
        let other = request(UUID(), 2, name: "Second")
        router.presentIPTVDetail(primary, alternates: [other])
        let card = try XCTUnwrap(router.presentedItemDetail)
        XCTAssertEqual(card.iptv, primary)
        XCTAssertEqual(card.alternates, [other])
    }

    func testPlainDetailsCarryNoAlternates() throws {
        let router = AppRouter()
        router.presentItemDetail(contentId: "movie:heat", libraryId: 1)
        XCTAssertEqual(router.presentedItemDetail?.alternates, [])
        router.dismissItemDetail()
        router.presentIPTVDetail(request(UUID(), 3, name: "Only"))
        XCTAssertEqual(router.presentedItemDetail?.alternates, [])
    }
}
#endif
