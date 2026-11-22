import Crypto
import Foundation

public protocol CredentialStore: Sendable {
    func read(_ key: String) async throws -> Data?
    func write(_ value: Data, for key: String) async throws
    func remove(_ key: String) async throws
}
public actor MemoryCredentialStore: CredentialStore {
    private var values: [String: Data] = [:]
    public init() {}
    public func read(_ key: String) -> Data? { values[key] }
    public func write(_ value: Data, for key: String) { values[key] = value }
    public func remove(_ key: String) { values[key] = nil }
}
public enum SecretRedactor {
    public static func redact(_ input: String) -> String {
        input.replacingOccurrences(of: "(?i)(authorization|token|password|api[_-]?key)(\\s*[:=]\\s*)([^\\s&,;]+)", with: "$1$2[REDACTED]", options: .regularExpression)
    }
}
