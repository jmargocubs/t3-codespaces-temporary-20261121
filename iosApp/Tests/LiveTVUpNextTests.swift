import Foundation
import XCTest
@testable import Silo

final class LiveTVUpNextTests: XCTestCase {
    private let provider = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let otherProvider = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private func channel(_ name: String, provider: UUID, guideID: String? = nil) -> LiveTVChannel {
        LiveTVChannel(id: "\(provider.uuidString):\(name)", guideID: guideID,
                      name: name, streamURL: URL(string: "https://stream.test/\(name)")!,
                      logoURL: nil, category: "News")
    }

    private func program(_ channelID: String, _ start: TimeInterval, _ title: String,
                         now: Date) -> EPGProgram {
        let date = now.addingTimeInterval(start)
        return EPGProgram(channelID: channelID, start: date, end: date.addingTimeInterval(1_800), title: title)
    }

    func testFutureProgramsAreChronologicalAndBounded() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let news = channel("News", provider: provider, guideID: "news")
        let sports = channel("Sports", provider: provider, guideID: "sports")
        let items = LiveTVUpNextResolver.resolve(candidates: [
            .init(channel: news, programs: [program("news", 3_600, "Later", now: now),
                                            program("news", 1_800, "Soon", now: now),
                                            program("news", -1_800, "Already aired", now: now)]),
            .init(channel: sports, programs: [program("sports", 7_200, "Last", now: now)])
        ], providerID: provider, now: now, limit: 2)

        XCTAssertEqual(items.map { $0.program.title }, ["Soon", "Later"])
        XCTAssertTrue(items.allSatisfy { $0.program.start > now })
    }

    func testProviderIsolationAndDuplicateGuideListings() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = channel("First", provider: provider, guideID: "shared")
        let alias = channel("Alias", provider: provider, guideID: "shared")
        let foreign = channel("Foreign", provider: otherProvider, guideID: "foreign")
        let shared = program("SHARED", 3_600, "One listing", now: now)
        let items = LiveTVUpNextResolver.resolve(candidates: [
            .init(channel: first, programs: [shared]),
            .init(channel: alias, programs: [program("shared", 3_600, "Duplicate listing", now: now)]),
            .init(channel: foreign, programs: [program("foreign", 1_800, "Other provider", now: now)])
        ], providerID: provider, now: now)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.channel.id, first.id)
        XCTAssertEqual(items.first?.program.title, "One listing")
    }

    func testMissingStaleAndInvalidGuideDataHideTheRail() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let news = channel("News", provider: provider, guideID: "news")
        let invalid = [program("news", -60, "Past", now: now),
                       program("news", 3_600, "   ", now: now)]

        XCTAssertTrue(LiveTVUpNextResolver.resolve(candidates: [], providerID: provider, now: now).isEmpty)
        XCTAssertTrue(LiveTVUpNextResolver.resolve(candidates: [.init(channel: news, programs: invalid)],
                                                   providerID: provider, now: now, guideIsUsable: false).isEmpty)
        XCTAssertTrue(LiveTVUpNextResolver.resolve(candidates: [.init(channel: news, programs: invalid)],
                                                   providerID: provider, now: now).isEmpty)
    }

    func testAllChannelsNavigationUsesTheUnfilteredBrowserRoute() {
        XCTAssertEqual(LiveTVBrowserFilters.channels,
                       LiveTVBrowserFilters(query: "", category: nil, favoritesOnly: false))
    }
}
