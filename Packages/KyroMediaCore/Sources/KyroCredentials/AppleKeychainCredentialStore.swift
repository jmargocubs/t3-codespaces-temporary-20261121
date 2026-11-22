import Foundation

#if canImport(Security)
import Security

/// Keychain-backed credential storage for Apple platforms. The account name
/// is namespaced by the caller (for example by provider account and purpose).
public actor AppleKeychainCredentialStore: CredentialStore {
  private let service: String
  private let accessGroup: String?

  public init(service: String = "com.kyro.credentials", accessGroup: String? = nil) {
    self.service = service
    self.accessGroup = accessGroup
  }

  public func read(_ key: String) throws -> Data? {
    var query = baseQuery(for: key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
    guard let data = result as? Data else { throw KeychainError(status: errSecDecode) }
    return data
  }

  public func write(_ value: Data, for key: String) throws {
    let query = baseQuery(for: key)
    let attributes: [String: Any] = [kSecValueData as String: value]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var insert = query
      insert.merge(attributes) { _, new in new }
      let addStatus = SecItemAdd(insert as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    } else if status != errSecSuccess {
      throw KeychainError(status: status)
    }
  }

  public func remove(_ key: String) throws {
    let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(status: status)
    }
  }

  private func baseQuery(for key: String) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
    return query
  }
}

public struct KeychainError: Error, Sendable, Equatable {
  public let status: Int32
  public init(status: Int32) { self.status = status }
}
#endif
