import CoreGraphics
import XCTest
@testable import Silo

final class SeekrVTTTests: XCTestCase {
    func testParsesCuesAndXywhFragments() {
        let vtt = """
        WEBVTT

        00:00:00.000 --> 00:00:10.000
        https://sprites.seekr.tv/550/sheet_001.jpg?sig=abc#xywh=0,0,320,180

        00:00:10.000 --> 00:00:20.000
        https://sprites.seekr.tv/550/sheet_001.jpg?sig=abc#xywh=320,0,320,180

        1:01:05.500 --> 1:01:15.500
        https://sprites.seekr.tv/550/sheet_002.jpg?sig=def#xywh=0,180,320,180
        """
        let cues = SeekrVTT.parse(vtt)
        XCTAssertEqual(cues.count, 3)
        XCTAssertEqual(cues[0].startMs, 0)
        XCTAssertEqual(cues[0].endMs, 10_000)
        XCTAssertEqual(cues[0].rect, CGRect(x: 0, y: 0, width: 320, height: 180))
        XCTAssertEqual(cues[1].rect.origin.x, 320)
        XCTAssertEqual(cues[2].startMs, 3_665_500)
        XCTAssertEqual(cues[2].sheetURL.host, "sprites.seekr.tv")
    }

    func testParseTimeSupportsHourAndMinuteForms() {
        XCTAssertEqual(SeekrVTT.parseTime("00:00:10.000"), 10_000)
        XCTAssertEqual(SeekrVTT.parseTime("01:02:03.250"), 3_723_250)
        XCTAssertEqual(SeekrVTT.parseTime("12:34.500"), 754_500)
        XCTAssertNil(SeekrVTT.parseTime("bad"))
    }
}

final class SeekrTrackNearestCueTests: XCTestCase {
    private func track(cues: [(Int64, Int64)]) -> SeekrTrack {
        SeekrTrack(
            contentKey: "movie:tmdb:1",
            cues: cues.enumerated().map { index, times in
                SeekrCue(
                    startMs: times.0,
                    endMs: times.1,
                    sheetURL: URL(string: "https://sprites.seekr.tv/sheet.jpg")!,
                    rect: CGRect(x: index * 320, y: 0, width: 320, height: 180)
                )
            },
            scale: 1,
            sourceDurationMs: 30_000,
            exact: true,
            loadedAt: Date(),
            expiresAt: Date().addingTimeInterval(3600)
        )
    }

    func testPrefersNearestCueRatherThanFloor() {
        let track = track(cues: [
            (0, 10_000),
            (10_000, 20_000),
            (20_000, 30_000),
        ])
        // 18.5s is closer to the 20s cue start than to 10s.
        XCTAssertEqual(track.nearestCue(positionMs: 18_500)?.startMs, 20_000)
        XCTAssertEqual(track.nearestCue(positionMs: 14_000)?.startMs, 10_000)
        XCTAssertEqual(track.nearestCue(positionMs: 0)?.startMs, 0)
    }

    func testAppliesManualOffsetBeforeLookup() {
        let track = track(cues: [
            (0, 10_000),
            (10_000, 20_000),
            (20_000, 30_000),
        ])
        // Playback is 30s ahead of the sprite source at the head.
        XCTAssertEqual(track.nearestCue(positionMs: 30_000, offsetMs: -30_000)?.startMs, 0)
    }
}

final class SeekrContentTests: XCTestCase {
    func testMovieAndEpisodeValidation() {
        XCTAssertTrue(SeekrContent.movie(tmdbId: 550, imdbId: nil).isValid)
        XCTAssertTrue(SeekrContent.movie(tmdbId: nil, imdbId: "tt0137523").isValid)
        XCTAssertFalse(SeekrContent.movie(tmdbId: nil, imdbId: nil).isValid)
        XCTAssertTrue(
            SeekrContent.episode(showTmdbId: 1396, showImdbId: nil, season: 1, episode: 1).isValid
        )
        XCTAssertFalse(
            SeekrContent.episode(showTmdbId: nil, showImdbId: nil, season: 1, episode: 1).isValid
        )
    }
}
