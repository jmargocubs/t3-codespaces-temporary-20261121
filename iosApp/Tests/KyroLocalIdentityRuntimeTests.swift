import Foundation
import XCTest
@testable import Silo

@MainActor
final class KyroLocalIdentityRuntimeTests: XCTestCase {
    func testStandaloneProfilesPersistAndVerifyPINWithoutSiloSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KyroLocalIdentityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "KyroLocalIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let databaseURL = directory.appendingPathComponent("identity.sqlite")
        let runtime = KyroLocalIdentityRuntime(databaseURL: databaseURL, defaults: defaults)

        try await runtime.ensureInitialProfile()
        let initialProfiles = try await runtime.profiles()
        XCTAssertEqual(initialProfiles.map(\.name), ["Home"])

        try await runtime.createProfile(
            name: "Kids", isChild: true, avatarEmoji: "preset:dicebear:adventurer:otter", pin: "4826")
        let profiles = try await runtime.profiles()
        XCTAssertEqual(profiles.count, 2)
        let kids = try XCTUnwrap(profiles.first(where: { $0.name == "Kids" }))
        XCTAssertTrue(kids.isChild)
        XCTAssertTrue(kids.hasPin)
        XCTAssertEqual(kids.avatarEmoji, "preset:dicebear:adventurer:otter")

        let wrongPINAccepted = try await runtime.verify("0000", profileID: try XCTUnwrap(UUID(uuidString: kids.id)))
        XCTAssertFalse(wrongPINAccepted)
        try await runtime.select(kids, pin: "4826")
        XCTAssertEqual(defaults.string(forKey: KyroLocalIdentityDefaults.activeProfileIDKey), kids.id)

        let reopened = KyroLocalIdentityRuntime(databaseURL: databaseURL, defaults: defaults)
        let reopenedProfiles = try await reopened.profiles()
        XCTAssertEqual(reopenedProfiles, profiles)
    }
}
