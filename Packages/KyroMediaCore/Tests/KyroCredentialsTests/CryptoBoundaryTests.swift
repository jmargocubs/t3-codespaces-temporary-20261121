import Crypto
import Foundation
import KyroCredentials
import XCTest

final class CryptoBoundaryTests: XCTestCase {
  func testKnownHashAndConstantTimeMACVerification() {
    XCTAssertEqual(
      SHA256.hash(data: Data("abc".utf8)).map { String(format: "%02x", $0) }.joined(),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let key = SymmetricKey(size: .bits256)
    let data = Data("synthetic challenge".utf8)
    let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
    XCTAssertTrue(HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: data, using: key))
    XCTAssertFalse(
      HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Data("changed".utf8), using: key))
    let second = SymmetricKey(size: .bits256)
    XCTAssertFalse(HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: data, using: second))
    XCTAssertEqual(SecretRedactor.redact("Authorization: Bearer synthetic-secret"), "[REDACTED]")
  }
}
