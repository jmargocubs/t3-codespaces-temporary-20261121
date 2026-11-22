import Foundation
import XCTest
import KyroFoundation
import KyroPlayback
import KyroCapabilities

actor RecordingPlaybackReporter: PlaybackReporter {
    var events: [PlaybackEvent] = []
    func report(_ event: PlaybackEvent, sessionID: UUID) { events.append(event) }
    func snapshot() -> [PlaybackEvent] { events }
}
@MainActor final class PlaybackCapabilityTests: XCTestCase {
    func testIndependentPlaybackContractsQualityAndRedaction() async throws {
        let intent = try PlaybackIntent(mediaID: "kyro:v1:movie:imdb:tt100", profileID: .init(), deviceID: .init(), startSeconds: 42)
        XCTAssertEqual(try JSONDecoder().decode(PlaybackIntent.self, from: JSONEncoder().encode(intent)), intent)
        let quality = try MediaQuality(width: 3_840, height: 2_160, videoCodec: "hevc", provenance: .streamProbe)
        XCTAssertEqual(quality.resolution, .uhd)
        XCTAssertEqual(quality.provenance, .streamProbe)
        let stream = try ResolvedStream(url: URL(string: "https://user:secret@synthetic.invalid/movie/password/file?token=secret")!, headers: ["Authorization": "secret"], quality: quality)
        XCTAssertFalse(stream.description.contains("secret"))
        XCTAssertFalse(stream.description.contains("password"))
        let playback = try ResolvedPlayback(intent: intent, account: .init(), streams: [stream])
        let reporter = RecordingPlaybackReporter()
        try await reporter.report(.started(position: 42), sessionID: playback.sessionID)
        let events = await reporter.snapshot()
        XCTAssertEqual(events, [.started(position: 42)])
        XCTAssertThrowsError(try PlaybackIntent(mediaID: "", profileID: .init(), deviceID: .init()))
        XCTAssertThrowsError(try MediaQuality(height: -1))
        XCTAssertThrowsError(try ResolvedPlayback(intent: intent, account: .init(), streams: []))
    }
    func testCapabilityStatesAndProfileIsolation() async throws {
        let profile = KyroProfileID()
        let capability = Capability(id: "playback", state: CapabilityRequirements(supported: true, authenticated: true, granted: true, reachable: true).state)
        XCTAssertEqual(capability.state, .available)
        XCTAssertEqual(CapabilityRequirements(supported: false, authenticated: true, granted: true, reachable: true).state, .unsupported)
        XCTAssertEqual(CapabilityRequirements(supported: true, authenticated: false, granted: true, reachable: true).state, .requiresAuthentication)
        XCTAssertEqual(CapabilityRequirements(supported: true, authenticated: true, granted: false, reachable: true).state, .requiresGrant)
        XCTAssertEqual(CapabilityRequirements(supported: true, authenticated: true, granted: true, reachable: nil).state, .unknown)
        let provider = ProfileCapabilityProvider(values: [profile: [capability]])
        let allowed = await provider.capabilities(for: profile)
        let other = await provider.capabilities(for: .init())
        XCTAssertEqual(allowed, [capability])
        XCTAssertTrue(other.isEmpty)
    }
}
