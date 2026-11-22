#if os(iOS) || KYRO_VOD_HOST_TESTS
import XCTest
#if !KYRO_VOD_HOST_TESTS
@testable import Silo
#endif

/// Build 104: the device performance report splits frame pacing by top-level section and by the
/// time a Live TV catalog refresh runs, so a lag report names where the frames were lost.
@MainActor
final class KyroPerformanceSectionTallyTests: XCTestCase {
    private let frame = 1.0 / 60

    func testFramesCountTowardTheSectionOnScreen() {
        let stats = KyroPerformanceStats(now: 0)
        stats.setSection("Movies", at: 0)
        for _ in 0..<60 { stats.frame(interval: frame, expected: frame) }
        stats.frame(interval: 0.4, expected: frame)       // a main-thread stall on Movies
        stats.setSection("Sports", at: 2)
        for _ in 0..<30 { stats.frame(interval: frame, expected: frame) }
        stats.setSection("Movies", at: 3)

        XCTAssertEqual(stats.sections["Movies"]?.frames, 61)
        XCTAssertEqual(stats.sections["Movies"]?.stalls, 1)
        XCTAssertEqual(stats.sections["Movies"]?.seconds, 2)
        XCTAssertEqual(stats.sections["Sports"]?.frames, 30)
        XCTAssertEqual(stats.sections["Sports"]?.stalls, 0)
        XCTAssertEqual(stats.sections["Sports"]?.seconds, 1)
        let report = stats.report(now: 4)
        XCTAssertTrue(report.contains("Section Movies: 3 s"), report)
        XCTAssertTrue(report.contains("Section Sports: 1 s"), report)
    }

    func testCatalogRefreshWindowExcludesInactiveTime() {
        let stats = KyroPerformanceStats(now: 0)
        stats.setCatalogRefresh(true, at: 1)
        stats.frame(interval: 0.3, expected: frame)
        stats.pause(at: 2)
        stats.frame(interval: 0.3, expected: frame)       // not counted while inactive
        stats.resume(at: 10)
        stats.setCatalogRefresh(false, at: 11)

        XCTAssertEqual(stats.catalogRefreshes, 1)
        XCTAssertEqual(stats.whileCatalogRefresh.frames, 1)
        XCTAssertEqual(stats.whileCatalogRefresh.stalls, 1)
        XCTAssertEqual(stats.whileCatalogRefresh.seconds, 2, "1 s before the pause and 1 s after it")
        XCTAssertTrue(stats.report(now: 12).contains("While a catalog refresh ran: 2 s"))
    }

    func testResetStartsNewTalliesButKeepsTheCurrentSection() {
        let stats = KyroPerformanceStats(now: 0)
        stats.setSection("Live TV", at: 0)
        stats.frame(interval: frame, expected: frame)
        stats.reset(at: 5)
        XCTAssertTrue(stats.sections.isEmpty)
        stats.frame(interval: frame, expected: frame)
        XCTAssertEqual(stats.sections["Live TV"]?.frames, 1)
    }
}
#endif
