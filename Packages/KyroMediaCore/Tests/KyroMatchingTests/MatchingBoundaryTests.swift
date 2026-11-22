import KyroCatalog
import KyroMatching
import XCTest

final class MatchingBoundaryTests: XCTestCase {
  func testSharedIDsCannotOverrideConflictingYearOrEdition() {
    let original = CanonicalMedia(
      id: "original", kind: .movie, title: "Film", year: 1980, externalIDs: ["imdb": "tt1"])
    let remake = CanonicalMedia(
      id: "remake", kind: .movie, title: "Film", year: 2020, externalIDs: ["imdb": "tt1"])
    let edition = CanonicalMedia(
      id: "edition", kind: .movie, title: "Film", year: 1980, externalIDs: ["imdb": "tt1"],
      edition: "extended")
    XCTAssertFalse(MediaMatcher.matches(original, remake))
    XCTAssertTrue(MediaMatcher.matches(original, remake, override: .merge))
    XCTAssertFalse(MediaMatcher.matches(original, original, override: .separate))
    XCTAssertFalse(MediaMatcher.matches(original, edition))
    XCTAssertFalse(
      MediaMatcher.matches(
        CanonicalMedia(id: "a", kind: .movie, title: "Film"),
        CanonicalMedia(id: "b", kind: .movie, title: "Film")))
  }
}
