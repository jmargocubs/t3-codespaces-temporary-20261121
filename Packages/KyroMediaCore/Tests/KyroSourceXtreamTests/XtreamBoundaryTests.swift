import Foundation
import KyroFoundation
import KyroSourceXtream
import XCTest

final class XtreamBoundaryTests: XCTestCase {
  func testProviderLocalIDsStayDistinctAndNumericStringIDsDecode() throws {
    let numeric = Data(#"[{"stream_id":42,"name":"Film"}]"#.utf8)
    let string = Data(#"[{"stream_id":"42","name":"Film"}]"#.utf8)
    let account = ProviderAccountID()
    let numericItems = try XtreamParser.parse(numeric, account: account)
    let stringItems = try XtreamParser.parse(string, account: account)
    let otherItems = try XtreamParser.parse(numeric, account: ProviderAccountID())
    XCTAssertEqual(numericItems, stringItems)
    XCTAssertNotEqual(numericItems.first?.id, otherItems.first?.id)
    XCTAssertThrowsError(try XtreamParser.details(Data(#"{"info":{}}"#.utf8)))
  }
}
