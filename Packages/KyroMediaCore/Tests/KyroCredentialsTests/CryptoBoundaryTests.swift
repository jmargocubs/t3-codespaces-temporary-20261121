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

#if canImport(Security)
final class AppleKeychainCredentialStoreTests: XCTestCase {
  func testCredentialCRUDAndMissingValue() async throws {
    let store = AppleKeychainCredentialStore(service: "com.kyro.tests.\(UUID().uuidString)")
    let key = "provider:synthetic-account:access-token"
    let missing = try await store.read(key)
    XCTAssertNil(missing)
    let secret = Data("fixture-only-credential".utf8)
    try await store.write(secret, for: key)
    let saved = try await store.read(key)
    XCTAssertEqual(saved, secret)
    try await store.write(Data("rotated".utf8), for: key)
    let rotated = try await store.read(key)
    XCTAssertEqual(rotated, Data("rotated".utf8))
    try await store.remove(key)
    let removed = try await store.read(key)
    XCTAssertNil(removed)
  }
}
#endif
