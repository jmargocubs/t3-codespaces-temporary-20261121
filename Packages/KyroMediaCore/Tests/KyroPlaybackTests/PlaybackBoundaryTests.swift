import Foundation
import KyroPlayback
import XCTest

final class PlaybackBoundaryTests: XCTestCase {
  func testUnsupportedTransportAndNonFinitePositionsAreRejected() throws {
    XCTAssertThrowsError(try ResolvedStream(url: URL(string: "file:///synthetic/movie")!))
    XCTAssertThrowsError(
      try PlaybackIntent(
        mediaID: "film", profileID: .init(), deviceID: .init(), startSeconds: .infinity))
    XCTAssertEqual(try MediaQuality().resolution, .unknown)
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        MediaQuality.self, from: Data(#"{"height":-1,"provenance":"provider"}"#.utf8)))
  }
}
