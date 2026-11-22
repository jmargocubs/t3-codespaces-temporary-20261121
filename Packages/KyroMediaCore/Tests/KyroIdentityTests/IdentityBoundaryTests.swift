import Foundation
import KyroFoundation
import KyroIdentity
import XCTest

@MainActor final class IdentityBoundaryTests: XCTestCase {
  func testPINAttemptLimitSurvivesReopen() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("identity.sqlite")
    let household = HouseholdID()
    let profile = KyroProfile(name: "Adult", kind: .standard)
    let db = try SQLiteDatabase(path: url)
    let store = IdentityStore(database: db, household: household)
    try await store.create(profile)
    try await store.setPIN("5837", for: profile.id)
    let hasPIN = try await store.hasPIN(for: profile.id)
    XCTAssertTrue(hasPIN)
    let now = Date(timeIntervalSince1970: 1_000)
    for _ in 0..<5 {
      let valid = try await store.verifyPIN("0000", for: profile.id, now: now)
      XCTAssertFalse(valid)
    }
    try await db.close()
    let reopened = try SQLiteDatabase(path: url)
    let persisted = IdentityStore(database: reopened, household: household)
    let blocked = try await persisted.verifyPIN("5837", for: profile.id, now: now)
    XCTAssertFalse(blocked)
    let allowed = try await persisted.verifyPIN(
      "5837", for: profile.id, now: now.addingTimeInterval(61))
    XCTAssertTrue(allowed)
    try await reopened.close()
  }
  func testConcurrentWritableGrantHasOnlyOneOwner() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let db = try SQLiteDatabase(path: folder.appendingPathComponent("identity.sqlite"))
    let store = IdentityStore(database: db, household: .init())
    let account = ProviderAccount(provider: "synthetic", label: "Test")
    try await store.register(account)
    let profiles = (0..<10).map { KyroProfile(name: "Profile \($0)", kind: .standard) }
    for profile in profiles { try await store.create(profile) }
    let owners = await withTaskGroup(of: Int.self) { group in
      for profile in profiles {
        group.addTask {
          do {
            try await store.grant(
              SourceGrant(profile: profile.id, account: account.id, subject: "same", writable: true)
            )
            return 1
          } catch { return 0 }
        }
      }
      var count = 0
      for await value in group { count += value }
      return count
    }
    XCTAssertEqual(owners, 1)
    try await db.close()
  }
}
