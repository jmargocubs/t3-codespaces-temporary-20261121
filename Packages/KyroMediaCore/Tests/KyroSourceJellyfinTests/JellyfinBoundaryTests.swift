import Foundation
import KyroFoundation
import KyroSourceJellyfin
import XCTest

final class JellyfinBoundaryTests: XCTestCase {
  func testProviderLocalIDsStayDistinctAcrossAccounts() throws {
    let fixture = Data(#"[{"Name":"Film","Id":"42","Type":"Movie"}]"#.utf8)
    let a = try JellyfinParser.parse(fixture, account: ProviderAccountID())
    let b = try JellyfinParser.parse(fixture, account: ProviderAccountID())
    XCTAssertNotEqual(a.first?.id, b.first?.id)
    XCTAssertThrowsError(try JellyfinParser.parse(Data(#"[{"Name":"Incomplete"}]"#.utf8)))
  }
}
