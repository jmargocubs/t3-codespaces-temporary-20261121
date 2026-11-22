import Foundation
import KyroFoundation

public struct PlaybackIntent: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let mediaID: String
    public let profileID: KyroProfileID
    public let deviceID: DeviceID
    public let startSeconds: Double
    public let preferredVersion: String?
    public init(requestID: UUID = UUID(), mediaID: String, profileID: KyroProfileID, deviceID: DeviceID, startSeconds: Double = 0, preferredVersion: String? = nil) throws {
        guard !mediaID.isEmpty, startSeconds.isFinite, startSeconds >= 0 else { throw PlaybackError.invalidIntent }
        self.requestID = requestID; self.mediaID = mediaID; self.profileID = profileID; self.deviceID = deviceID
        self.startSeconds = startSeconds; self.preferredVersion = preferredVersion
    }
}
public enum QualityProvenance: String, Codable, Sendable { case provider, streamProbe, userOverride, unknown }
public enum ResolutionClass: String, Codable, Sendable { case unknown, sd, hd, fullHD, uhd }
public struct MediaQuality: Codable, Sendable, Equatable {
    public let width: Int?
    public let height: Int?
    public let bitrate: Int?
    public let videoCodec: String?
    public let audioCodec: String?
    public let hdr: String?
    public let provenance: QualityProvenance
    public init(width: Int? = nil, height: Int? = nil, bitrate: Int? = nil, videoCodec: String? = nil, audioCodec: String? = nil, hdr: String? = nil, provenance: QualityProvenance = .unknown) throws {
        guard width.map({ $0 > 0 }) ?? true, height.map({ $0 > 0 }) ?? true, bitrate.map({ $0 > 0 }) ?? true else { throw PlaybackError.invalidQuality }
        self.width = width; self.height = height; self.bitrate = bitrate; self.videoCodec = videoCodec; self.audioCodec = audioCodec; self.hdr = hdr; self.provenance = provenance
    }
    public var resolution: ResolutionClass {
        guard let height else { return .unknown }
        if height >= 2_160 { return .uhd }; if height >= 1_080 { return .fullHD }; if height >= 720 { return .hd }; return .sd
    }
}
public enum StreamDelivery: String, Sendable { case directPlay, directStream, transcode }
/// Ephemeral transport details deliberately have no Codable conformance.
public struct ResolvedStream: Sendable, CustomStringConvertible {
    public let url: URL
    public let headers: [String: String]
    public let mimeType: String?
    public let delivery: StreamDelivery
    public let quality: MediaQuality
    public init(url: URL, headers: [String: String] = [:], mimeType: String? = nil, delivery: StreamDelivery = .directPlay, quality: MediaQuality? = nil) throws {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw PlaybackError.invalidStream }
        self.url = url; self.headers = headers; self.mimeType = mimeType; self.delivery = delivery; self.quality = try quality ?? MediaQuality()
    }
    public var description: String { "ResolvedStream(\(DiagnosticRedactor.url(url)), \(delivery.rawValue))" }
}
public struct ResolvedPlayback: Sendable {
    public let intent: PlaybackIntent
    public let sessionID: UUID
    public let account: ProviderAccountID
    public let streams: [ResolvedStream]
    public let expiresAt: Date?
    public init(intent: PlaybackIntent, sessionID: UUID = UUID(), account: ProviderAccountID, streams: [ResolvedStream], expiresAt: Date? = nil) throws {
        guard !streams.isEmpty else { throw PlaybackError.noStreams }
        self.intent = intent; self.sessionID = sessionID; self.account = account; self.streams = streams; self.expiresAt = expiresAt
    }
}
public enum PlaybackEvent: Sendable, Equatable {
    case started(position: Double), progress(position: Double, duration: Double), paused(position: Double), ended(position: Double), failed(code: String)
}
public protocol PlaybackReporter: Sendable { func report(_ event: PlaybackEvent, sessionID: UUID) async throws }
public enum PlaybackError: Error { case invalidIntent, invalidQuality, invalidStream, noStreams }
