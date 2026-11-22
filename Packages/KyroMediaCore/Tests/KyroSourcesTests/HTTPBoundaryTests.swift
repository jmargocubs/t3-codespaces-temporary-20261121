import Foundation
import KyroFoundation
import XCTest

@testable import KyroSources

private actor UnauthorizedHTTP: HTTPClient {
  var count = 0
  func send(_ request: HTTPRequest) -> HTTPResponse {
    count += 1
    return HTTPResponse(status: 401)
  }
  func calls() -> Int { count }
}
@MainActor final class HTTPBoundaryTests: XCTestCase {
  func testRedirectCredentialsStayOnOriginalOrigin() {
    XCTAssertThrowsError(try SourceEndpoint(URL(string: "file:///not-a-provider")!))
    let original = URL(string: "https://original.invalid/items")!
    XCTAssertTrue(
      URLSessionHTTPClient.permitsRedirect(
        from: original, to: URL(string: "https://original.invalid/new")!))
    XCTAssertFalse(
      URLSessionHTTPClient.permitsRedirect(
        from: original, to: URL(string: "https://other.invalid/items")!))
    XCTAssertFalse(
      URLSessionHTTPClient.permitsRedirect(
        from: original, to: URL(string: "http://original.invalid/items")!))
    XCTAssertFalse(
      URLSessionHTTPClient.permitsRedirect(
        from: original, to: URL(string: "https://original.invalid:8443/items")!))
  }
  func testAuthenticationFailureIsNotRetriedAndDescriptionIsRedacted() async throws {
    let transport = UnauthorizedHTTP()
    let client = try ResilientHTTPClient(transport: transport)
    let request = HTTPRequest(
      url: URL(string: "https://synthetic.invalid/password?token=secret")!,
      headers: ["Authorization": "secret"])
    XCTAssertFalse(String(reflecting: request).contains("secret"))
    do {
      _ = try await client.send(request, account: .init())
      XCTFail("401 accepted")
    } catch HTTPFailure.status(401) {}
    let count = await transport.calls()
    XCTAssertEqual(count, 1)
  }
}
