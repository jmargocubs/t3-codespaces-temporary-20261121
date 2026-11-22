import XCTest
@testable import Silo

/// Build 61: guide listings load newest request first, and a full queue drops its oldest request.
final class LiveTVGuideResidencyQueueTests: XCTestCase {
    func testNewestRequestsLoadFirst() {
        var queue = LiveTVGuideResidencyQueue()
        for index in 0..<10 { queue.request("key\(index)", channelID: "ch\(index)") }
        XCTAssertEqual(queue.takeNewest(3).map(\.key), ["key9", "key8", "key7"])
        XCTAssertEqual(queue.count, 7)
        XCTAssertEqual(queue.takeNewest(64).map(\.key), (0..<7).reversed().map { "key\($0)" })
        XCTAssertTrue(queue.isEmpty)
    }

    /// A fast fling past 700 rows: the rows still on screen (the newest) stay queued.
    func testAFullQueueDropsTheOldestRequestNotTheNewest() {
        var queue = LiveTVGuideResidencyQueue()
        var evicted: [String] = []
        for index in 0..<700 {
            if let dropped = queue.request("key\(index)", channelID: "ch\(index)") { evicted.append(dropped.key) }
        }
        XCTAssertEqual(queue.count, LiveTVGuideResidencyQueue.capacity)
        XCTAssertEqual(evicted, (0..<188).map { "key\($0)" })
        XCTAssertTrue(queue.contains("key699"))
        XCTAssertFalse(queue.contains("key0"))
        XCTAssertEqual(queue.takeNewest(1).first?.key, "key699")
    }

    /// Scrolling back over a row that is still waiting moves it to the front, without a duplicate.
    func testARepeatedRequestMovesToTheFrontAndMergesChannels() {
        var queue = LiveTVGuideResidencyQueue()
        queue.request("a", channelID: "ch-a")
        queue.request("b", channelID: "ch-b")
        queue.request("a", channelID: "ch-a2")
        XCTAssertEqual(queue.count, 2)
        let first = queue.takeNewest(1)
        XCTAssertEqual(first.first?.key, "a")
        XCTAssertEqual(first.first?.channelIDs, ["ch-a", "ch-a2"])
        XCTAssertEqual(queue.takeNewest(1).first?.key, "b")
    }

    func testRemoveAll() {
        var queue = LiveTVGuideResidencyQueue()
        queue.request("a", channelID: "ch-a")
        queue.removeAll()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertFalse(queue.contains("a"))
        XCTAssertTrue(queue.takeNewest(5).isEmpty)
    }
}
