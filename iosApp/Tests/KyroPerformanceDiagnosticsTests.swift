import XCTest
@testable import Silo

/// Build 61: the performance report separates time away from the app from real stalls, and
/// carries its own numbers for the Guide and for buffering.
@MainActor
final class KyroPerformanceDiagnosticsTests: XCTestCase {
    private let frame = 1.0 / 60

    /// Build 60 report: "Worst frame: 23,999 ms" in a 66-second window. Time spent in another app
    /// is a pause, not a frame.
    func testTimeAwayFromTheAppIsNotAFrameOrAStall() {
        let stats = KyroPerformanceStats(now: 0)
        for _ in 0..<120 { stats.frame(interval: frame, expected: frame) }
        stats.pause(at: 2)
        stats.frame(interval: 24, expected: frame) // a stray callback while inactive
        stats.resume(at: 26)
        for _ in 0..<60 { stats.frame(interval: frame, expected: frame) }

        XCTAssertEqual(stats.frames, 180)
        XCTAssertEqual(stats.stalls, 0)
        XCTAssertEqual(stats.hitches, 0)
        XCTAssertLessThan(stats.worstFrameMilliseconds, 20)
        XCTAssertEqual(stats.pauses, 1)
        XCTAssertEqual(stats.activeSeconds(at: 27), 3, accuracy: 0.001)
        let report = stats.report(now: 27)
        XCTAssertTrue(report.contains("27 s window, 3 s active"), report)
        XCTAssertTrue(report.contains("Inactive (not measured): 1 times, 24 s"), report)
    }

    /// A genuine main-thread block while active is still a stall.
    func testAnActiveStallIsStillReported() {
        let stats = KyroPerformanceStats(now: 0)
        stats.frame(interval: 0.4, expected: frame)
        XCTAssertEqual(stats.stalls, 1)
        XCTAssertEqual(stats.hitches, 1)
        XCTAssertEqual(stats.worstFrameMilliseconds, 400, accuracy: 0.001)
    }

    /// Build 60's report read "Guide body: 0, List row build: 0" without saying the Guide was never
    /// on screen. Guide pacing now counts only while a Guide is visible, and says when it was not.
    func testGuideFramesCountOnlyWhileAGuideIsVisible() {
        let stats = KyroPerformanceStats(now: 0)
        stats.frame(interval: 0.3, expected: frame)
        XCTAssertTrue(stats.report(now: 1).contains("Guide on screen: not shown during this window"))

        stats.setGuideVisible("watch", true, at: 1)
        for _ in 0..<60 { stats.frame(interval: frame, expected: frame) }
        stats.frame(interval: 0.05, expected: frame)
        stats.setGuideVisible("watch", false, at: 3)
        stats.frame(interval: 0.3, expected: frame)

        XCTAssertEqual(stats.guide.frames, 61)
        XCTAssertEqual(stats.guide.hitches, 1)
        XCTAssertEqual(stats.guide.stalls, 0, "The stalls before and after belong to other screens")
        XCTAssertEqual(stats.guide.seconds, 2, accuracy: 0.001)
        XCTAssertEqual(stats.stalls, 2)
    }

    func testTwoGuideSurfacesCountTheirOverlapOnce() {
        let stats = KyroPerformanceStats(now: 0)
        stats.setGuideVisible("screen", true, at: 0)
        stats.setGuideVisible("watch", true, at: 1)
        stats.setGuideVisible("screen", false, at: 2)
        stats.setGuideVisible("watch", false, at: 4)
        XCTAssertEqual(stats.guide.seconds, 4, accuracy: 0.001)
    }

    /// Buffering with a free main thread points at the stream or network; with stalls, at the app.
    func testBufferingCarriesTheMainThreadPacingDuringIt() {
        let stats = KyroPerformanceStats(now: 0)
        stats.setBuffering(true, at: 10)
        for _ in 0..<600 { stats.frame(interval: frame, expected: frame) }
        stats.setBuffering(false, at: 20)
        stats.frame(interval: 0.5, expected: frame)

        XCTAssertEqual(stats.bufferingEpisodes, 1)
        XCTAssertEqual(stats.longestBufferingSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(stats.whileBuffering.frames, 600)
        XCTAssertEqual(stats.whileBuffering.stalls, 0)
        XCTAssertEqual(stats.whileBuffering.framesPerSecond, 60, accuracy: 0.01)
        let report = stats.report(now: 21)
        XCTAssertTrue(report.contains("Buffering: 1 episodes, longest 10.0 s"), report)
        XCTAssertTrue(report.contains("While buffering: 10 s, 60 frames/s, hitches 0, stalls (≥250 ms) 0"), report)
    }

    func testTimeAwayIsExcludedFromGuideAndBufferingSpans() {
        let stats = KyroPerformanceStats(now: 0)
        stats.setGuideVisible("watch", true, at: 0)
        stats.setBuffering(true, at: 0)
        stats.pause(at: 5)
        stats.resume(at: 65)
        stats.setGuideVisible("watch", false, at: 70)
        stats.setBuffering(false, at: 70)
        XCTAssertEqual(stats.guide.seconds, 10, accuracy: 0.001)
        XCTAssertEqual(stats.whileBuffering.seconds, 10, accuracy: 0.001)
    }

    func testResetStartsAFreshWindowAndKeepsOpenSpans() {
        let stats = KyroPerformanceStats(now: 0)
        stats.setGuideVisible("watch", true, at: 0)
        stats.frame(interval: 0.5, expected: frame)
        stats.pause(at: 1)
        stats.resume(at: 30)
        stats.reset(at: 40)
        XCTAssertEqual(stats.stalls, 0)
        XCTAssertEqual(stats.pauses, 0)
        XCTAssertEqual(stats.activeSeconds(at: 50), 10, accuracy: 0.001)
        stats.setGuideVisible("watch", false, at: 45)
        XCTAssertEqual(stats.guide.seconds, 5, accuracy: 0.001, "The Guide stayed visible across the reset")
    }
}
