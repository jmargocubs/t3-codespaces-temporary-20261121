import Foundation
import XCTest
@testable import Silo

final class LiveTVRecentlyWatchedTests: XCTestCase {
    private let firstProvider = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let secondProvider = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private func recent(_ provider: UUID, _ token: String) -> LiveTVRecentChannel {
        LiveTVRecentChannel(providerID: provider, channelID: "\(provider.uuidString):\(token)")!
    }

    private func channel(_ provider: UUID, _ token: String, name: String = "Channel",
                         url: String = "https://user:password@stream.test/live?token=secret") -> LiveTVChannel {
        LiveTVChannel(id: "\(provider.uuidString):\(token)", guideID: nil, name: name,
                      streamURL: URL(string: url)!, logoURL: URL(string: "https://art.test/logo")!, category: "News")
    }

    func testInitialHistoryIsEmpty() {
        XCTAssertTrue(LiveTVRecentHistory.channels(in: [], providerID: firstProvider, catalog: []).isEmpty)
    }

    func testPlayingReadyInsertionOrderAndDuplicatePrevention() {
        let a = recent(firstProvider, "a")
        let b = recent(firstProvider, "b")
        var history = LiveTVRecentHistory.inserting(a, into: [])
        history = LiveTVRecentHistory.inserting(b, into: history)
        XCTAssertEqual(history, [b, a])
        XCTAssertEqual(LiveTVRecentHistory.inserting(b, into: history), history)
        XCTAssertEqual(LiveTVRecentHistory.inserting(a, into: history), [a, b])
    }

    func testHistoryIsBoundedToFifteenAndKeepsNewestFirst() {
        let history = (0..<20).reduce(into: [LiveTVRecentChannel]()) { result, index in
            result = LiveTVRecentHistory.inserting(recent(firstProvider, "\(index)"), into: result)
        }
        XCTAssertEqual(history.count, 15)
        XCTAssertEqual(history.first?.channelID, "\(firstProvider.uuidString):19")
        XCTAssertFalse(history.contains(recent(firstProvider, "4")))
    }

    func testProviderIsolationAndCurrentCatalogResolution() {
        let one = channel(firstProvider, "same", name: "First provider")
        let two = channel(secondProvider, "same", name: "Second provider")
        let records = [recent(firstProvider, "same"), recent(secondProvider, "same")]
        XCTAssertEqual(LiveTVRecentHistory.channels(in: records, providerID: firstProvider, catalog: [one, two]), [one])
        XCTAssertEqual(LiveTVRecentHistory.channels(in: records, providerID: secondProvider, catalog: [one, two]), [two])
        XCTAssertTrue(LiveTVRecentHistory.channels(in: records, providerID: firstProvider, catalog: [two]).isEmpty)
    }

    func testRemovedChannelsArePrunedWithoutChangingOtherProviders() {
        let records = [recent(firstProvider, "keep"), recent(firstProvider, "removed"), recent(secondProvider, "keep")]
        let pruned = LiveTVRecentHistory.pruning(records, providerID: firstProvider,
                                                 validChannelIDs: ["\(firstProvider.uuidString):keep"])
        XCTAssertEqual(pruned, [records[0], records[2]])
    }

    func testProviderRemovalDropsItsHistory() {
        let records = [recent(firstProvider, "one"), recent(secondProvider, "two")]
        XCTAssertEqual(LiveTVRecentHistory.pruning(records, providerID: firstProvider, validChannelIDs: []), [records[1]])
    }

    func testCatalogRefreshRetainsStableIDsAndRemovesMissingIDs() {
        let records = [recent(firstProvider, "stable"), recent(firstProvider, "gone")]
        let refreshed = LiveTVRecentHistory.pruning(records, providerID: firstProvider,
                                                    validChannelIDs: ["\(firstProvider.uuidString):stable"])
        XCTAssertEqual(refreshed, [records[0]])
    }

    func testPersistenceReloadAndBoundedStorage() {
        let suite = "LiveTVRecentlyWatchedTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LiveTVRecentHistoryStore(defaults: defaults)
        let values = (0..<18).reduce(into: [LiveTVRecentChannel]()) { result, index in
            result = LiveTVRecentHistory.inserting(recent(firstProvider, "\(index)"), into: result)
        }
        store.save(values)
        store.flush()
        XCTAssertEqual(LiveTVRecentHistoryStore(defaults: defaults).read(), Array(values.prefix(15)))
    }

    func testPersistenceContainsOnlyOpaqueProviderAndChannelIdentifiers() throws {
        let suite = "LiveTVRecentlyWatchedPrivacyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LiveTVRecentHistoryStore(defaults: defaults)
        store.save([recent(firstProvider, "opaque-digest")])
        store.flush()
        let data = try XCTUnwrap(defaults.data(forKey: "liveTV.recently-watched.v1"))
        let stored = String(decoding: data, as: UTF8.self)
        for sensitive in ["Channel", "stream.test", "user:password", "token=secret", "art.test", "logo"] {
            XCTAssertFalse(stored.contains(sensitive))
        }
        XCTAssertTrue(stored.contains(firstProvider.uuidString))
        XCTAssertTrue(stored.contains("opaque-digest"))
    }

    func testForeignProviderChannelIdentityIsRejected() {
        XCTAssertNil(LiveTVRecentChannel(providerID: firstProvider,
                                         channelID: "\(secondProvider.uuidString):same"))
    }

    func testPlayingReadyRejectsRemovedProviderRemovedChannelAndStaleGeneration() {
        let id = "\(firstProvider.uuidString):channel"
        let validIDs: Set<String> = [id]
        XCTAssertNil(LiveTVRecentHistory.playingReadyEntry(
            channelID: id, generation: 4, currentGeneration: 4, activeChannelID: id, isPlaying: true,
            providerIsPresent: false, validChannelIDs: validIDs), "a removed provider must not be reinserted")
        XCTAssertNil(LiveTVRecentHistory.playingReadyEntry(
            channelID: id, generation: 4, currentGeneration: 4, activeChannelID: id, isPlaying: true,
            providerIsPresent: true, validChannelIDs: []), "a channel removed from the catalog must not be reinserted")
        XCTAssertNil(LiveTVRecentHistory.playingReadyEntry(
            channelID: id, generation: 3, currentGeneration: 4, activeChannelID: id, isPlaying: true,
            providerIsPresent: true, validChannelIDs: validIDs), "a stale player generation must not be recorded")
        XCTAssertNil(LiveTVRecentHistory.playingReadyEntry(
            channelID: id, generation: 4, currentGeneration: 4, activeChannelID: "replacement", isPlaying: true,
            providerIsPresent: true, validChannelIDs: validIDs), "a replaced channel must not be recorded")
        XCTAssertEqual(LiveTVRecentHistory.playingReadyEntry(
            channelID: id, generation: 4, currentGeneration: 4, activeChannelID: id, isPlaying: true,
            providerIsPresent: true, validChannelIDs: validIDs), recent(firstProvider, "channel"))
    }
}
