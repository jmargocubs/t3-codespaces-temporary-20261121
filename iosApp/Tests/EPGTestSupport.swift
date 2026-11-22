import Foundation
import Security
@testable import Silo

/// A fingerprint key store held in memory, so tests never touch the simulator's real Keychain item.
final class EPGInMemoryKeyStore: EPGFingerprintKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?

    func readKey() throws -> Data? { lock.withLock { value } }

    func addKey(_ key: Data) throws {
        try lock.withLock {
            guard value == nil else { throw EPGKeyStoreError(status: errSecDuplicateItem) }
            value = key
        }
    }

    func deleteKey() throws { lock.withLock { value = nil } }
}

extension EPGSourceFingerprinter {
    /// A fingerprinter with its own in-memory key.
    static func inMemory() -> EPGSourceFingerprinter {
        EPGSourceFingerprinter(keys: EPGFingerprintKeyProvider(store: EPGInMemoryKeyStore()))
    }
}
