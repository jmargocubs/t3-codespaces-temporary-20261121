import Foundation
/// Stores the user's Seekr API key in Keychain. Never logs or bundles the key.
enum SeekrCredentials {
    static let keychainAccount = "seekr.api_key"

    /// Returns a non-empty API key when one is configured.
    static func apiKey(keychain: SharedKeychain = SharedKeychain(audience: .userIndependent)) -> String? {
        if let stored = keychain.get(keychainAccount)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }
        return nil
    }

    @discardableResult
    static func store(
        _ key: String,
        keychain: SharedKeychain = SharedKeychain(audience: .userIndependent)
    ) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return keychain.set(trimmed, for: keychainAccount)
    }

    static func clear(keychain: SharedKeychain = SharedKeychain(audience: .userIndependent)) {
        keychain.delete(keychainAccount)
    }
}
