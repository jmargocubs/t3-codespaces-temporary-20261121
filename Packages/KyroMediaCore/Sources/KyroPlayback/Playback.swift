import Foundation
public struct PlaybackIntent: Codable, Sendable { public let mediaID: String; public let profileID: UUID; public init(mediaID:String, profileID:UUID) { self.mediaID=mediaID; self.profileID=profileID } }
public struct ResolvedStream: Codable, Sendable { public let url: URL; public let mimeType: String?; public init(url:URL,mimeType:String?=nil){self.url=url;self.mimeType=mimeType} }
public struct ResolvedPlayback: Codable, Sendable { public let stream: ResolvedStream; public init(stream:ResolvedStream){self.stream=stream} }
public protocol PlaybackReporter: Sendable { func report(progress: TimeInterval) async throws }
