import Foundation
import XCTest
import KyroFoundation
import KyroIdentity
import KyroCredentials
import CArgon2

@MainActor final class IdentityTests: XCTestCase {
    func testArgon2KnownVectorAndSaltedPINs() throws {
        // Upstream reference vector (src/test.c), Argon2id v19.
        var hash = [UInt8](repeating: 0, count: 32)
        let code = "password".withCString { pwd in "somesalt".withCString { salt in
            argon2id_hash_raw(2, 65_536, 1, pwd, 8, salt, 8, &hash, 32)
        }}
        XCTAssertEqual(code, ARGON2_OK.rawValue)
        XCTAssertEqual(hash.map { String(format: "%02x", $0) }.joined(), "09316115d5cf24ed5a15a31a3ba326e5cf32edc24702987c02b6566f61913cf7")
        let first = try ProfilePIN(pin: "1234"), second = try ProfilePIN(pin: "1234")
        XCTAssertNotEqual(first.encoded, second.encoded)
        XCTAssertTrue(try first.verify("1234"))
        XCTAssertFalse(try first.verify("9999"))
        XCTAssertThrowsError(try ProfilePIN.Cost(memoryKiB: 8, iterations: 1))
        let tampered = try JSONDecoder().decode(ProfilePIN.self, from: Data("{\"encoded\":\"$argon2id$v=19$m=999999999,t=2,p=1$salt$hash\"}".utf8))
        XCTAssertThrowsError(try tampered.verify("1234"))
    }
    func testPersistentProfilesTombstonesGrantsAndPIN() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("identity.sqlite")
        let household = HouseholdID()
        let db = try SQLiteDatabase(path: url)
        let store = IdentityStore(database: db, household: household)
        let adult = KyroProfile(name: "Adult", kind: .standard), child = KyroProfile(name: "Child", kind: .kids)
        try await store.create(adult); try await store.create(child)
        try await store.setPIN("5826", for: adult.id)
        let account = ProviderAccount(provider: "jellyfin", label: "Synthetic")
        try await store.register(account)
        try await store.grant(SourceGrant(profile: adult.id, account: account.id, subject: "one", writable: true))
        do { try await store.grant(SourceGrant(profile: child.id, account: account.id, subject: "one", writable: true)); XCTFail("Exclusive subject") } catch {}
        try await store.grant(SourceGrant(profile: child.id, account: account.id, subject: "one", writable: false))
        try await db.close()
        let reopened = try SQLiteDatabase(path: url)
        let persisted = IdentityStore(database: reopened, household: household)
        let profiles = try await persisted.profiles()
        XCTAssertEqual(profiles.count, 2)
        let verified = try await persisted.verifyPIN("5826", for: adult.id)
        XCTAssertTrue(verified)
        try await persisted.delete(adult.id)
        let deleted = try await persisted.profiles(includeDeleted: true)
        XCTAssertNotNil(deleted.first(where: { $0.id == adult.id })?.tombstonedAt)
        do { try await persisted.create(adult); XCTFail("Resurrected") } catch {}
        try await persisted.grant(SourceGrant(profile: child.id, account: account.id, subject: "one", writable: true))
        try await reopened.close()
        let bytes = try Data(contentsOf: url)
        XCTAssertNil(bytes.range(of: Data("5826".utf8)))
    }
    func testMemoryCredentials() async throws {
        let store = MemoryCredentialStore()
        await store.write(Data([1, 2]), for: "account")
        let value = await store.read("account")
        XCTAssertEqual(value, Data([1, 2]))
        await store.remove("account")
        let removed = await store.read("account")
        XCTAssertNil(removed)
    }
}
