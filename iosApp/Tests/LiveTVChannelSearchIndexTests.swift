import Foundation
import XCTest
@testable import Silo

final class LiveTVChannelSearchIndexTests: XCTestCase {
    private let providerA = UUID(uuidString: "A1F4C8A0-CB4C-4B3D-9F73-9AA2BDA7C6B0")!
    private let providerB = UUID(uuidString: "B1F4C8A0-CB4C-4B3D-9F73-9AA2BDA7C6B0")!

    func testNameAndCategoryMatchesAgreeWithExistingLocalizedMatcher() async throws {
        let channels = [
            channel("first", name: "North News", category: "Local"),
            channel("second", name: "World One", category: "North Sports"),
            channel("third", name: "South News", category: "Sports")
        ]
        let index = try await makeIndex(channels)

        for query in ["north", "NEWS", "sports"] {
            let expected = channels.filter {
                $0.name.localizedStandardContains(query) || $0.category.localizedStandardContains(query)
            }.map(\.id)
            let actual = await index.search(query: query)?.map(\.channelID)
            XCTAssertEqual(actual, expected)
        }
    }

    func testCaseInsensitiveASCIIFastPathMatchesFoundation() async throws {
        let channels = [
            channel("first", name: "Cafe News", category: "Local"),
            channel("second", name: "SPORTS", category: "Live")
        ]
        let index = try await makeIndex(channels)
        let result = await index.search(query: "  CAFE  ")
        XCTAssertEqual(result?.map(\.channelID), ["first"])
        let sports = await index.search(query: "sports")?.map(\.channelID)
        XCTAssertEqual(sports, ["second"])
    }

    func testUnicodeAndDiacriticQueriesUseFoundationCompatibilityFallback() async throws {
        let channels = [
            channel("composed", name: "Café International", category: "News"),
            channel("decomposed", name: "Cafe\u{301} Local", category: "News"),
            channel("cjk", name: "東京ニュース", category: "日本")
        ]
        let index = try await makeIndex(channels)

        for query in ["café", "Café", "cafe", "東京", "ニュース", "日本"] {
            let expected = channels.filter {
                $0.name.localizedStandardContains(query) || $0.category.localizedStandardContains(query)
            }.map(\.id)
            let actual = await index.search(query: query)?.map(\.channelID)
            XCTAssertEqual(actual, expected, query)
        }
    }

    func testWhitespaceAndEmptyQueriesFollowLiveTVSearchModelNormalization() async throws {
        let channels = [channel("one", name: "One", category: "News"),
                        channel("two", name: "Two", category: "Sports")]
        let index = try await makeIndex(channels)
        let empty = await index.search(query: "")?.map(\.channelID)
        let whitespace = await index.search(query: " \n\t ")?.map(\.channelID)
        let padded = await index.search(query: "  News  ")?.map(\.channelID)
        XCTAssertEqual(empty, ["one", "two"])
        XCTAssertEqual(whitespace, ["one", "two"])
        XCTAssertEqual(padded, ["one"])
    }

    func testOrderingIsStableAndMatchesCatalogOrder() async throws {
        let channels = [channel("z", name: "Sports Z", category: "Sports"),
                        channel("a", name: "Sports A", category: "Sports"),
                        channel("m", name: "Sports M", category: "Sports")]
        let index = try await makeIndex(channels)
        let results = await index.search(query: "sports")
        XCTAssertEqual(results?.map(\.channelID), ["z", "a", "m"])
        XCTAssertEqual(results?.map(\.ordinal), [0, 1, 2])
    }

    func testIndexRetainsOnlySearchMetadataAndNotStreamOrLogoURLs() async throws {
        let channel = LiveTVChannel(id: "safe-id", guideID: "guide", name: "News",
                                    streamURL: URL(string: "https://private.example/live?token=secret")!,
                                    logoURL: URL(string: "https://private.example/logo.png")!, category: "Local")
        let index = try await makeIndex([channel])
        XCTAssertFalse(String(reflecting: index).contains("private.example"))
        XCTAssertFalse(String(reflecting: index).contains("secret"))
        let ids = await index.search(query: "news")?.map(\.channelID)
        XCTAssertEqual(ids, ["safe-id"])
    }

    func testStoreRejectsOtherProviderAndStaleCatalogRevision() async throws {
        let store = LiveTVChannelSearchIndexStore()
        let channels = [channel("one", name: "News", category: "Local")]
        let installed = await store.replaceCatalog(providerID: providerA, catalogRevision: 7, channels: channels)
        let otherProvider = await store.search(query: "news", providerID: providerB, catalogRevision: 7)
        let oldRevision = await store.search(query: "news", providerID: providerA, catalogRevision: 6)
        let current = await store.search(query: "news", providerID: providerA, catalogRevision: 7)?.map(\.channelID)
        XCTAssertTrue(installed)
        XCTAssertNil(otherProvider)
        XCTAssertNil(oldRevision)
        XCTAssertEqual(current, ["one"])

        let switched = await store.replaceCatalog(providerID: providerB, catalogRevision: 1,
                                                  channels: [channel("b", name: "Sports", category: "Live")])
        await store.invalidate(providerID: providerA)
        let stillActive = await store.search(query: "sports", providerID: providerB, catalogRevision: 1)?.map(\.channelID)
        XCTAssertTrue(switched)
        XCTAssertEqual(stillActive, ["b"], "late invalidation for A must not clear active provider B")
    }

    func testCatalogRevisionRebuildReplacesOldMetadata() async throws {
        let store = LiveTVChannelSearchIndexStore()
        let firstInstalled = await store.replaceCatalog(providerID: providerA, catalogRevision: 1,
                                                        channels: [channel("old", name: "Old News", category: "A")])
        let firstSearch = await store.search(query: "old", providerID: providerA, catalogRevision: 1)?.map(\.channelID)
        XCTAssertTrue(firstInstalled)
        XCTAssertEqual(firstSearch, ["old"])

        let secondInstalled = await store.replaceCatalog(providerID: providerA, catalogRevision: 2,
                                                         channels: [channel("new", name: "New News", category: "B")])
        let staleSearch = await store.search(query: "old", providerID: providerA, catalogRevision: 1)
        let secondSearch = await store.search(query: "new", providerID: providerA, catalogRevision: 2)?.map(\.channelID)
        let noOldMatch = await store.search(query: "old", providerID: providerA, catalogRevision: 2)
        XCTAssertTrue(secondInstalled)
        XCTAssertNil(staleSearch)
        XCTAssertEqual(secondSearch, ["new"])
        XCTAssertEqual(noOldMatch?.count, 0)
    }

    func testCanceledSearchAndSupersededQueryCannotPublish() async throws {
        let store = LiveTVChannelSearchIndexStore()
        let channels = (0..<40_000).map { index in
            channel("id-\(index)", name: "Channel \(index)", category: index.isMultiple(of: 2) ? "News" : "Sports")
        }
        let installed = await store.replaceCatalog(providerID: providerA, catalogRevision: 1, channels: channels)
        XCTAssertTrue(installed)
        let providerID = providerA

        let canceled = Task {
            await store.search(query: "Channel", providerID: providerID, catalogRevision: 1)
        }
        canceled.cancel()
        let canceledValue = await canceled.value
        XCTAssertNil(canceledValue)

        let stale = Task {
            await store.search(query: "Channel 1", providerID: providerID, catalogRevision: 1)
        }
        await Task.yield()
        let current = await store.search(query: "Channel 39999", providerID: providerA, catalogRevision: 1)
        XCTAssertEqual(current?.map(\.channelID), ["id-39999"])
        let staleValue = await stale.value
        XCTAssertNil(staleValue)
    }

    func testIndexBuildIsProviderAndRevisionQualified() async throws {
        let index = try await makeIndex([channel("one", name: "One", category: "News")])
        XCTAssertEqual(index.identity.providerID, providerA)
        XCTAssertEqual(index.identity.catalogRevision, 42)
        XCTAssertGreaterThan(index.estimatedStorageBytes, 0)
    }

    private func makeIndex(_ channels: [LiveTVChannel]) async throws -> LiveTVChannelSearchIndex {
        let index = await LiveTVChannelSearchIndex.build(providerID: providerA,
                                                         catalogRevision: 42,
                                                         channels: channels,
                                                         locale: Locale(identifier: "en_US"))
        return try XCTUnwrap(index)
    }

    private func channel(_ id: String, name: String, category: String) -> LiveTVChannel {
        LiveTVChannel(id: id, guideID: nil, name: name,
                      streamURL: URL(string: "https://fixture.invalid/\(id).m3u8")!,
                      logoURL: nil, category: category)
    }
}
