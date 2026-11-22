import CoreGraphics
import ImageIO
import XCTest
@testable import Silo

final class SeekrCredentialLifecycleTests: XCTestCase {
    func testStoreReadAndRemoveUsesOnlyTheProvidedKeychain() {
        let keychain = SharedKeychain(service: "SeekrCredentialTests.\(UUID().uuidString)", accessGroup: nil,
                                      usesUserIndependentKeychain: false, allowsAppLocalFallback: false)
        XCTAssertNil(SeekrCredentials.apiKey(keychain: keychain))
        XCTAssertTrue(SeekrCredentials.store("sk_user_supplied", keychain: keychain))
        XCTAssertEqual(SeekrCredentials.apiKey(keychain: keychain), "sk_user_supplied")
        SeekrCredentials.clear(keychain: keychain)
        XCTAssertNil(SeekrCredentials.apiKey(keychain: keychain))
    }

    func testBlankKeyIsNotStored() {
        let keychain = SharedKeychain(service: "SeekrCredentialTests.\(UUID().uuidString)", accessGroup: nil,
                                      usesUserIndependentKeychain: false, allowsAppLocalFallback: false)
        XCTAssertFalse(SeekrCredentials.store(" \n", keychain: keychain))
        XCTAssertNil(SeekrCredentials.apiKey(keychain: keychain))
    }
}

final class SeekrPreviewSettingsLifecycleTests: XCTestCase {
    func testEnableDisablePostsChangeNotificationAndIgnoresNoOp() {
        let suite = "kyro.seekr.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SeekrPreviewSettings(defaults: defaults)
        settings.setPreviewsEnabled(false)

        var enabledValues: [Bool] = []
        let token = NotificationCenter.default.addObserver(
            forName: SeekrPreviewSettings.previewsEnabledDidChangeNotification,
            object: settings,
            queue: nil
        ) { note in
            if let enabled = note.userInfo?["enabled"] as? Bool {
                enabledValues.append(enabled)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        settings.setPreviewsEnabled(false) // no-op
        settings.setPreviewsEnabled(true)
        settings.setPreviewsEnabled(true) // no-op
        settings.setPreviewsEnabled(false)

        XCTAssertEqual(enabledValues, [true, false])
        XCTAssertFalse(settings.previewsEnabled)
    }

    func testSyncOffsetDefaultsToZeroAndClamps() {
        let defaults = UserDefaults(suiteName: "kyro.seekr.sync.\(UUID().uuidString)")!
        let settings = SeekrPreviewSettings(defaults: defaults)
        XCTAssertEqual(settings.syncOffsetMs(forTitleKey: "movie:tmdb:1"), 0)
        settings.setSyncOffsetMs(500_000, forTitleKey: "movie:tmdb:1")
        XCTAssertEqual(settings.syncOffsetMs(forTitleKey: "movie:tmdb:1"), 120_000)
        settings.setSyncOffsetMs(-500_000, forTitleKey: "movie:tmdb:1")
        XCTAssertEqual(settings.syncOffsetMs(forTitleKey: "movie:tmdb:1"), -120_000)
        settings.clearSyncOffset(forTitleKey: "movie:tmdb:1")
        XCTAssertEqual(settings.syncOffsetMs(forTitleKey: "movie:tmdb:1"), 0)
    }
}

final class SeekrPreviewSheetsLifecycleTests: XCTestCase {
    func testWaitingForDownloadFalseReturnsImmediatelyWhileFetchIsInFlight() async {
        let gate = StubURLProtocol.Gate()
        let stub = StubURLProtocol.Handler()
        let session = stub.makeSession()
        stub.route(StubURLProtocol.any) { _ in
            await gate.wait()
            return .init(
                status: 200,
                headers: ["Content-Type": "image/jpeg"],
                body: Self.makeSheetJPEG()
            )
        }

        let sheetURL = URL(string: "https://sprites.seekr.tv/sheet-slow.jpg")!
        let track = Self.track(sheetURL: sheetURL)
        let sheets = SeekrPreviewSheets(
            track: track,
            offsetMs: 0,
            session: session,
            diskDirectory: nil
        )

        let started = ContinuousClock.now
        let result = await sheets.thumbnail(atSourceTime: 1, waitingForDownload: false)
        let elapsed = ContinuousClock.now - started
        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, .milliseconds(250))

        await gate.open()
        // Allow the coalesced fetch to finish and populate memory.
        let deadline = ContinuousClock.now + .seconds(2)
        var warmed: (image: CGImage, cueStartSeconds: Double)?
        while ContinuousClock.now < deadline {
            warmed = await sheets.thumbnail(atSourceTime: 1, waitingForDownload: false)
            if warmed != nil { break }
            await Task.yield()
        }
        XCTAssertNotNil(warmed)
        await sheets.shutdown()
    }

    func testShutdownCancelsFurtherThumbnails() async {
        let stub = StubURLProtocol.Handler()
        let session = stub.makeSession()
        stub.route(StubURLProtocol.any) { _ in
            .init(
                status: 200,
                headers: ["Content-Type": "image/jpeg"],
                body: Self.makeSheetJPEG()
            )
        }
        let sheetURL = URL(string: "https://sprites.seekr.tv/sheet-shutdown.jpg")!
        let sheets = SeekrPreviewSheets(
            track: Self.track(sheetURL: sheetURL),
            session: session,
            diskDirectory: nil
        )
        let before = await sheets.thumbnail(atSourceTime: 0, waitingForDownload: true)
        XCTAssertNotNil(before)
        await sheets.shutdown()
        let after = await sheets.thumbnail(atSourceTime: 0, waitingForDownload: true)
        XCTAssertNil(after)
    }

    func testReplaceTrackDropsStaleTitleSheets() async {
        let stub = StubURLProtocol.Handler()
        let session = stub.makeSession()
        final class HitCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() {
                lock.lock(); value += 1; lock.unlock()
            }
            var count: Int {
                lock.lock(); defer { lock.unlock() }; return value
            }
        }
        let hits = HitCounter()
        stub.route(StubURLProtocol.any) { _ in
            hits.increment()
            return .init(
                status: 200,
                headers: ["Content-Type": "image/jpeg"],
                body: Self.makeSheetJPEG()
            )
        }

        let firstURL = URL(string: "https://sprites.seekr.tv/title-a.jpg")!
        let secondURL = URL(string: "https://sprites.seekr.tv/title-b.jpg")!
        let sheets = SeekrPreviewSheets(
            track: Self.track(contentKey: "movie:tmdb:1", sheetURL: firstURL),
            session: session,
            diskDirectory: nil
        )
        let first = await sheets.thumbnail(atSourceTime: 0, waitingForDownload: true)
        XCTAssertNotNil(first)
        let hitsAfterFirst = hits.count

        await sheets.replaceTrack(
            Self.track(contentKey: "movie:tmdb:2", sheetURL: secondURL),
            offsetMs: 0
        )
        // Memory cache for title A must not answer title B's cue.
        let second = await sheets.thumbnail(atSourceTime: 0, waitingForDownload: true)
        XCTAssertNotNil(second)
        XCTAssertGreaterThan(hits.count, hitsAfterFirst)
        await sheets.shutdown()
    }

    private static func track(
        contentKey: String = "movie:tmdb:1",
        sheetURL: URL
    ) -> SeekrTrack {
        SeekrTrack(
            contentKey: contentKey,
            cues: [
                SeekrCue(
                    startMs: 0,
                    endMs: 10_000,
                    sheetURL: sheetURL,
                    rect: CGRect(x: 0, y: 0, width: 320, height: 180)
                ),
                SeekrCue(
                    startMs: 10_000,
                    endMs: 20_000,
                    sheetURL: sheetURL,
                    rect: CGRect(x: 320, y: 0, width: 320, height: 180)
                ),
            ],
            scale: 1,
            sourceDurationMs: 20_000,
            exact: true,
            loadedAt: Date(),
            expiresAt: Date().addingTimeInterval(3600)
        )
    }

    /// 640×180 JPEG with two 320×180 tiles worth of pixels.
    private static func makeSheetJPEG() -> Data {
        let width = 640
        let height = 180
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bytesPerRow + x * 4
                pixels[i] = x < 320 ? 255 : 0
                pixels[i + 1] = 0
                pixels[i + 2] = x < 320 ? 0 : 255
                pixels[i + 3] = 255
            }
        }
        let data = CFDataCreateMutable(nil, 0)!
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil),
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

final class SeekrClientCancellationTests: XCTestCase {
    func testCancelledLookupDoesNotSurfaceAsSuccess() async {
        let gate = StubURLProtocol.Gate()
        let stub = StubURLProtocol.Handler()
        let session = stub.makeSession()
        stub.route(StubURLProtocol.any) { _ in
            await gate.wait()
            return .json(
                #"{"vtt_url":"https://sprites.seekr.tv/vtt","scale":1.0,"source_duration_ms":1000,"exact":true}"#
            )
        }
        let client = SeekrClient(
            baseURL: URL(string: "https://api.seekr.tv")!,
            session: session,
            apiKeyProvider: { "sk_live_test" }
        )
        let task = Task {
            await client.loadTrack(
                content: .movie(tmdbId: 550, imdbId: nil),
                durationMs: 1_000_000
            )
        }
        // Give the request a moment to hit the gate, then cancel the caller.
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await gate.open()
        _ = await task.value
        // A follow-up lookup after cancel must still be able to run (no stuck gate).
        let stub2 = StubURLProtocol.Handler()
        let session2 = stub2.makeSession()
        stub2.route(StubURLProtocol.path("/sprites")) { _ in .status(404) }
        let client2 = SeekrClient(
            baseURL: URL(string: "https://api.seekr.tv")!,
            session: session2,
            apiKeyProvider: { "sk_live_test" }
        )
        let result = await client2.loadTrack(
            content: .movie(tmdbId: 1, imdbId: nil),
            durationMs: 1_000_000
        )
        XCTAssertEqual(result, .failure(.noPreviews))
    }
}

@MainActor
final class SeekrScrubPreviewClearingTests: XCTestCase {
    private static func makeMockImage() -> CGImage {
        let width = 16
        let height = 9
        let bytesPerRow = width * 4
        let pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    func testDisableSeekrClearsOnlySeekrSourcedPreview() {
        let player = PlayerViewModel()
        defer { player.cleanup() }
        let image = Self.makeMockImage()

        // 1. Seekr source: disabling Seekr clears it.
        player.setScrubPreviewForTesting(image: image, sourceTime: 42.0, source: .seekr)
        XCTAssertNotNil(player.scrubPreviewImage)
        XCTAssertEqual(player.scrubPreviewImageSourceTime, 42.0)
        XCTAssertEqual(player.scrubPreviewImageSource, .seekr)

        player.applySeekrPreviewsEnabled(false)
        XCTAssertNil(player.scrubPreviewImage)
        XCTAssertNil(player.scrubPreviewImageSourceTime)
        XCTAssertNil(player.scrubPreviewImageSource)

        // 2. Server trickplay source: disabling Seekr preserves it.
        player.setScrubPreviewForTesting(image: image, sourceTime: 100.0, source: .server)
        XCTAssertNotNil(player.scrubPreviewImage)
        XCTAssertEqual(player.scrubPreviewImageSourceTime, 100.0)
        XCTAssertEqual(player.scrubPreviewImageSource, .server)

        player.applySeekrPreviewsEnabled(false)
        XCTAssertNotNil(player.scrubPreviewImage)
        XCTAssertEqual(player.scrubPreviewImageSourceTime, 100.0)
        XCTAssertEqual(player.scrubPreviewImageSource, .server)

        // 3. Cache-backed still source: disabling Seekr preserves it.
        player.setScrubPreviewForTesting(image: image, sourceTime: 150.0, source: .cache)
        XCTAssertNotNil(player.scrubPreviewImage)
        XCTAssertEqual(player.scrubPreviewImageSource, .cache)

        player.applySeekrPreviewsEnabled(false)
        XCTAssertNotNil(player.scrubPreviewImage)
        XCTAssertEqual(player.scrubPreviewImageSourceTime, 150.0)
        XCTAssertEqual(player.scrubPreviewImageSource, .cache)

        // 4. Extractor fallback source: disabling Seekr preserves it.
        player.setScrubPreviewForTesting(image: image, sourceTime: 200.0, source: .extractor)
        XCTAssertNotNil(player.scrubPreviewImage)
        XCTAssertEqual(player.scrubPreviewImageSource, .extractor)

        player.applySeekrPreviewsEnabled(false)
        XCTAssertNotNil(player.scrubPreviewImage)
        XCTAssertEqual(player.scrubPreviewImageSourceTime, 200.0)
        XCTAssertEqual(player.scrubPreviewImageSource, .extractor)
    }
}
