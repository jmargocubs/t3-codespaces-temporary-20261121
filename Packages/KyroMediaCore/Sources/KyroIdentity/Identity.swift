import Foundation
import KyroCredentials
import KyroFoundation

public enum ProfileKind: String, Codable, Sendable { case standard, kids }
public struct KyroProfile: Codable, Sendable, Identifiable {
  public let id: KyroProfileID
  public var name: String
  public var kind: ProfileKind
  public var avatarEmoji: String?
  public var tombstonedAt: Date?
  public init(
    id: KyroProfileID = .init(), name: String, kind: ProfileKind, avatarEmoji: String? = nil
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.avatarEmoji = avatarEmoji
  }
}
