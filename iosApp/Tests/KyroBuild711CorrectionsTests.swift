import Foundation
import XCTest
@testable import Silo

/// Build 71.1: the category picker's row projection, the Stats tab's Team | Player selector state,
/// and the pinned player's compact channel label.
final class KyroBuild711CorrectionsTests: XCTestCase {
    private func gameID(_ raw: String) -> KyroGameID {
        KyroGameID(provider: "espn", league: .collegeFootball, rawID: raw)
    }

    // MARK: Category picker projection

    func testProjectionExcludesFrequentFromRemainingWithoutReorderingCatalog() {
        let categories = ["News", "Sports", "24/7 Movies", "Kids", "Music"]
        let projection = LiveTVGuideCategoryPickerModel.projection(
            categories: categories, query: "", frequent: ["Sports", "Kids"])
        XCTAssertEqual(projection.frequent, ["Sports", "Kids"])
        XCTAssertEqual(projection.remaining, ["News", "24/7 Movies", "Music"])
    }

    func testProjectionHidesFrequentWhileSearching() {
        let categories = ["24/7 Movies", "24/7 Sitcoms", "Sports"]
        let projection = LiveTVGuideCategoryPickerModel.projection(
            categories: categories, query: " 24/7 ", frequent: ["24/7 Movies"])
        XCTAssertEqual(projection.frequent, [])
        XCTAssertEqual(projection.remaining, ["24/7 Movies", "24/7 Sitcoms"])
    }

    func testProjectionWithNoMatchesIsEmpty() {
        let projection = LiveTVGuideCategoryPickerModel.projection(
            categories: ["News"], query: "zzz", frequent: ["News"])
        XCTAssertTrue(projection.frequent.isEmpty && projection.remaining.isEmpty)
    }

    /// A large catalog derives its rows from a precomputed frequent list, so a render is a single
    /// pass over the categories. Build 71 ranked the whole channel catalog once per row.
    func testProjectionOfLargeCatalogIsLinear() {
        let categories = (0..<2_000).map { "24/7 Category \($0)" }
        let start = Date()
        for _ in 0..<50 {
            _ = LiveTVGuideCategoryPickerModel.projection(categories: categories, query: "",
                                                          frequent: Array(categories.prefix(4)))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }

    // MARK: Stats section selection

    func testSectionDefaultsToTeamStats() {
        XCTAssertEqual(KyroSportsPlayerBoxScoreSelection().section(for: gameID("1")), .team)
    }

    func testSectionAndTeamPersistTogetherForSameEvent() {
        var selection = KyroSportsPlayerBoxScoreSelection()
        selection.select("ucla", for: gameID("1"))
        selection.selectSection(.players, for: gameID("1"))
        XCTAssertEqual(selection.section(for: gameID("1")), .players)
        XCTAssertEqual(selection.teamID, "ucla")
        selection.selectSection(.team, for: gameID("1"))
        selection.selectSection(.players, for: gameID("1"))
        XCTAssertEqual(selection.teamID, "ucla", "Toggling sections keeps the chosen team")
    }

    func testNewEventResetsSectionAndTeam() {
        var selection = KyroSportsPlayerBoxScoreSelection()
        selection.select("ucla", for: gameID("1"))
        selection.selectSection(.players, for: gameID("1"))
        XCTAssertEqual(selection.section(for: gameID("2")), .team)

        selection.selectSection(.players, for: gameID("2"))
        XCTAssertNil(selection.teamID, "A section choice for another event drops the old team")

        selection.select("ill", for: gameID("3"))
        XCTAssertEqual(selection.section(for: gameID("3")), .team, "A team choice for another event resets the section")
    }

    func testPinnedAndInspectedSelectionsAreIndependentValues() {
        var pinned = KyroSportsPlayerBoxScoreSelection()
        var inspected = KyroSportsPlayerBoxScoreSelection()
        pinned.selectSection(.players, for: gameID("1"))
        inspected.selectSection(.team, for: gameID("1"))
        XCTAssertEqual(pinned.section(for: gameID("1")), .players)
        XCTAssertEqual(inspected.section(for: gameID("1")), .team)
    }

    // MARK: Pinned strip channel label

    func testCompactChannelNameDropsRegionPrefixAndQualityTags() {
        XCTAssertEqual(KyroSportsInlineStrip.compactChannelName("US| ESPN 2 FHD"), "ESPN 2")
        XCTAssertEqual(KyroSportsInlineStrip.compactChannelName("USA: Big Ten Network HD"), "Big Ten Network")
        XCTAssertEqual(KyroSportsInlineStrip.compactChannelName("US|FOX Sports 1 (HD)"), "FOX Sports 1")
        XCTAssertEqual(KyroSportsInlineStrip.compactChannelName("UK - Sky Sports Main Event 4K"), "Sky Sports Main Event")
    }

    func testCompactChannelNameKeepsOrdinaryNames() {
        XCTAssertEqual(KyroSportsInlineStrip.compactChannelName("ESPN"), "ESPN")
        XCTAssertEqual(KyroSportsInlineStrip.compactChannelName("NBC  Sports   Chicago"), "NBC Sports Chicago")
        XCTAssertEqual(KyroSportsInlineStrip.compactChannelName("HD"), "HD", "A name that is only a tag stays")
        XCTAssertEqual(KyroSportsInlineStrip.compactChannelName("CBS Sports Network"), "CBS Sports Network")
    }
}
