import Foundation
import KyroFoundation
import KyroIdentity

enum KyroLocalIdentityDefaults {
    static let householdIDKey = "kyro.identity.household-id"
    static let activeProfileIDKey = "kyro.identity.active-profile-id"

    static var activeProfileID: String? {
        UserDefaults.standard.string(forKey: activeProfileIDKey)
    }
}

/// The local household identity used when no Silo server is configured.
/// Silo sessions remain owned by AuthService; this store only backs the
/// existing profile picker in standalone mode.
@MainActor
final class KyroLocalIdentityRuntime {
    static let shared = KyroLocalIdentityRuntime()

    private let database: SQLiteDatabase?
    private let identity: IdentityStore?
    private let household: HouseholdID
    private(set) var startupError: Error?

    private init() {
        let defaults = UserDefaults.standard
        let key = KyroLocalIdentityDefaults.householdIDKey
        let householdID: HouseholdID
        if let value = defaults.string(forKey: key),
           let uuid = UUID(uuidString: value) {
            householdID = HouseholdID(rawValue: uuid)
        } else {
            householdID = HouseholdID()
            defaults.set(householdID.description, forKey: key)
        }
        household = householdID

        do {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Kyro", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let database = try SQLiteDatabase(path: root.appendingPathComponent("identity.sqlite"))
            self.database = database
            identity = IdentityStore(database: database, household: householdID)
        } catch {
            startupError = error
            database = nil
            identity = nil
        }
    }

    func ensureInitialProfile() async throws {
        guard let identity else { throw startupError ?? RuntimeError.storageUnavailable }
        if try await identity.profiles().isEmpty {
            try await identity.create(KyroProfile(name: "Home", kind: .standard))
        }
    }

    func createProfile(name: String, isChild: Bool, avatarEmoji: String?, pin: String?) async throws {
        guard let identity else { throw startupError ?? RuntimeError.storageUnavailable }
        let profile = KyroProfile(
            name: name,
            kind: isChild ? .kids : .standard,
            avatarEmoji: avatarEmoji
        )
        try await identity.create(profile)
        if let pin, !pin.isEmpty {
            do {
                try await identity.setPIN(pin, for: profile.id)
            } catch {
                try? await identity.delete(profile.id)
                throw error
            }
        }
    }

    func profiles() async throws -> [UserProfile] {
        guard let identity else { throw startupError ?? RuntimeError.storageUnavailable }
        var result: [UserProfile] = []
        for profile in try await identity.profiles() {
            result.append(UserProfile(
                id: profile.id.description,
                name: profile.name,
                avatarEmoji: profile.avatarEmoji,
                hasPin: try await identity.hasPIN(for: profile.id),
                isChild: profile.kind == .kids,
                isPrimary: false
            ))
        }
        return result
    }

    func select(_ profile: UserProfile, pin: String?) async throws {
        guard let identity,
              let uuid = UUID(uuidString: profile.id) else { throw RuntimeError.profileUnavailable }
        let profileID = KyroProfileID(rawValue: uuid)
        if profile.hasPin {
            guard let pin, try await identity.verifyPIN(pin, for: profileID) else {
                throw RuntimeError.incorrectPIN
            }
        }
        UserDefaults.standard.set(profile.id, forKey: KyroLocalIdentityDefaults.activeProfileIDKey)
    }

    func verify(_ pin: String, profileID: UUID) async throws -> Bool {
        guard let identity else { throw startupError ?? RuntimeError.storageUnavailable }
        return try await identity.verifyPIN(pin, for: KyroProfileID(rawValue: profileID))
    }

    enum RuntimeError: LocalizedError {
        case storageUnavailable, profileUnavailable, incorrectPIN
        var errorDescription: String? {
            switch self {
            case .storageUnavailable: "Kyro couldn't open local profile storage."
            case .profileUnavailable: "This Kyro profile is no longer available."
            case .incorrectPIN: "The profile PIN is incorrect."
            }
        }
    }
}
