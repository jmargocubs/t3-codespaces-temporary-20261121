import Foundation
import XCTest
@testable import Silo

/// Build 60: the watch screen's channel list reveals the playing row by point, and memoizes each
/// row's guide values for the current guide and minute.
@MainActor
final class LiveTVGuideListSupportTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 799_999_980) // on a minute boundary (13,333,333 minutes)

    private func channel(_ id: String) -> LiveTVChannel {
        LiveTVChannel(id: id, guideID: id, name: "Channel \(id)",
                      streamURL: URL(string: "https://tv.example/\(id).ts")!, logoURL: nil, category: "Sports")
    }

    private func entry(_ title: String) -> LiveTVEmbeddedGuideListEntry {
        LiveTVEmbeddedGuideListEntry(currentTitle: title, progress: 0.5, upcomingTitle: nil, upcomingStart: nil)
    }

    // MARK: Reveal

    /// The target uses the lazy stack's own average row height, so it lands where the stack
    /// places the row, and a 40,000-row list needs no row before it to be built.
    func testEstimatedOffsetCentresTheRowFromTheStackEstimate() {
        let offset = LiveTVGuideListReveal.estimatedOffset(index: 30_000, rowCount: 40_000,
                                                           contentHeight: 3_200_000, viewportHeight: 600)
        XCTAssertEqual(offset, 30_000.5 * 80 - 300, accuracy: 0.001)
    }

    func testEstimatedOffsetBeforeGeometryAndAtTheEnds() {
        let early = LiveTVGuideListReveal.estimatedOffset(index: 10, rowCount: 100, contentHeight: 0, viewportHeight: 600)
        XCTAssertEqual(early, 10.5 * LiveTVGuideListReveal.fallbackRowHeight - 300, accuracy: 0.001)
        XCTAssertEqual(LiveTVGuideListReveal.estimatedOffset(index: 0, rowCount: 100, contentHeight: 8_000, viewportHeight: 600), 0)
        XCTAssertEqual(LiveTVGuideListReveal.estimatedOffset(index: 99, rowCount: 100, contentHeight: 8_000, viewportHeight: 600),
                       8_000 - 600)
        XCTAssertEqual(LiveTVGuideListReveal.estimatedOffset(index: 3, rowCount: 0, contentHeight: 0, viewportHeight: 600), 0)
    }

    /// The row reports its middle in the list's content coordinates. `scrollTo(y:)` puts content
    /// y at the top of the area below the filter bar (measured with a top safe-area inset).
    func testCorrectionCentresTheReportedRow() throws {
        let corrected = try XCTUnwrap(LiveTVGuideListReveal.correctedOffset(
            rowContentMidY: 10_520, currentOffset: 10_000, contentHeight: 3_200_000, viewportHeight: 600))
        XCTAssertEqual(corrected, 10_220, accuracy: 0.001)
        XCTAssertNil(LiveTVGuideListReveal.correctedOffset(rowContentMidY: 10_302, currentOffset: 10_000,
                                                           contentHeight: 3_200_000, viewportHeight: 600))
        XCTAssertEqual(LiveTVGuideListReveal.correctedOffset(rowContentMidY: 40, currentOffset: 100,
                                                             contentHeight: 3_200_000, viewportHeight: 600), 0)
    }

    // MARK: Entry cache

    func testEntriesAreBuiltOncePerChannelGuideAndMinute() {
        let cache = LiveTVGuideListEntryCache()
        var builds = 0
        func read(_ id: String, revision: Int = 1, at date: Date? = nil, channelRevision: Int = 0) -> LiveTVEmbeddedGuideListEntry {
            cache.entry(for: channel(id), revision: revision, isGuideStale: false, now: date ?? now,
                        channelRevision: channelRevision) {
                builds += 1
                return entry("\(id)-\(builds)")
            }
        }

        XCTAssertEqual(read("a"), entry("a-1"))
        XCTAssertEqual(read("a", at: now.addingTimeInterval(59)), entry("a-1"), "Same minute")
        XCTAssertEqual(builds, 1)
        XCTAssertEqual(read("a", channelRevision: 1), entry("a-2"), "That channel's short guide changed")
        XCTAssertEqual(read("b"), entry("b-3"))
        XCTAssertEqual(read("a", at: now.addingTimeInterval(60)), entry("a-4"), "Next minute: progress moved")
        XCTAssertEqual(read("a", revision: 2, at: now.addingTimeInterval(60)), entry("a-5"), "New guide")
        XCTAssertEqual(cache.hitCount, 1)
        XCTAssertEqual(cache.missCount, 5)
    }

    /// Build 61: a row built before its listings loaded (or whose load a full queue dropped) is not
    /// stored, so its next build asks again instead of showing "No guide information" until the
    /// next minute.
    func testUnsettledEntriesAreRebuiltOnEveryRead() {
        let cache = LiveTVGuideListEntryCache()
        var builds = 0
        func read(settled: Bool) -> LiveTVEmbeddedGuideListEntry {
            cache.entry(for: channel("a"), revision: 1, isGuideStale: false, now: now, channelRevision: 0,
                        cacheable: settled) {
                builds += 1
                return entry("a-\(builds)")
            }
        }
        XCTAssertEqual(read(settled: false), entry("a-1"))
        XCTAssertEqual(read(settled: false), entry("a-2"))
        XCTAssertEqual(cache.entryCount, 0)
        XCTAssertEqual(read(settled: true), entry("a-3"))
        XCTAssertEqual(read(settled: true), entry("a-3"), "Settled values are cached as before")
        XCTAssertEqual(read(settled: false), entry("a-4"), "An unsettled read never returns a stored value")
        XCTAssertEqual(cache.entryCount, 0)
    }

    func testEntryCacheStaysBounded() {
        let cache = LiveTVGuideListEntryCache()
        for index in 0..<(LiveTVGuideListEntryCache.capacity + 40) {
            _ = cache.entry(for: channel("\(index)"), revision: 1, isGuideStale: false, now: now, channelRevision: 0) {
                entry("\(index)")
            }
        }
        XCTAssertEqual(cache.entryCount, LiveTVGuideListEntryCache.capacity)
        var rebuilt = false
        _ = cache.entry(for: channel("0"), revision: 1, isGuideStale: false, now: now, channelRevision: 0) {
            rebuilt = true
            return entry("0")
        }
        XCTAssertTrue(rebuilt, "The least recently used row was evicted")
    }
}
