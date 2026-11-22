import CArgon2
import Crypto
import Foundation

public struct ProfilePIN: Codable, Sendable, Equatable {
    public let encoded: String
    public struct Cost: Sendable {
        public let memoryKiB: UInt32
        public let iterations: UInt32
        public init(memoryKiB: UInt32 = 19_456, iterations: UInt32 = 2) throws {
            guard (19_456...131_072).contains(memoryKiB), (2...10).contains(iterations) else { throw PINError.invalidCost }
            self.memoryKiB = memoryKiB; self.iterations = iterations
        }
    }
    public init(pin: String, cost: Cost? = nil) throws {
        guard (4...12).contains(pin.utf8.count), pin.utf8.allSatisfy({ (48...57).contains($0) }) else { throw PINError.invalidPIN }
        let cost = try cost ?? Cost()
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let password = Data(pin.utf8)
        var output = [CChar](repeating: 0, count: 256)
        let code = password.withUnsafeBytes { pwd in
            salt.withUnsafeBytes { salt in
                argon2id_hash_encoded(cost.iterations, cost.memoryKiB, 1, pwd.baseAddress, pwd.count, salt.baseAddress, salt.count, 32, &output, output.count)
            }
        }
        guard code == ARGON2_OK.rawValue else { throw PINError.derivationFailed }
        encoded = String(decoding: output.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    public func verify(_ pin: String) throws -> Bool {
        guard encoded.utf8.count <= 256 else { throw PINError.invalidRecord }
        // Treat stored hashes as untrusted: reject excessive work before C allocates.
        let parts = encoded.split(separator: "$", omittingEmptySubsequences: false)
        guard parts.count == 6, parts[1] == "argon2id", parts[2] == "v=19" else { throw PINError.invalidRecord }
        let costs = parts[3].split(separator: ",")
        guard costs.count == 3, costs[0].hasPrefix("m="), costs[1].hasPrefix("t="), costs[2] == "p=1",
              let memory = UInt32(costs[0].dropFirst(2)), let iterations = UInt32(costs[1].dropFirst(2)) else { throw PINError.invalidRecord }
        _ = try Cost(memoryKiB: memory, iterations: iterations)
        guard pin.utf8.count <= 12 else { return false }
        let bytes = Data(pin.utf8)
        let code = bytes.withUnsafeBytes { argon2id_verify(encoded, $0.baseAddress, $0.count) }
        if code == ARGON2_VERIFY_MISMATCH.rawValue { return false }
        guard code == ARGON2_OK.rawValue else { throw PINError.invalidRecord }
        return true
    }
    public enum PINError: Error { case invalidCost, invalidPIN, invalidRecord, derivationFailed }
}
