import XCTest
@testable import Silo

final class SeekrClientTests: XCTestCase {
    func testValidateKeyReportsServerValidationFailure() async {
        let stub = StubURLProtocol.Handler()
        let session = stub.makeSession()
        stub.route(StubURLProtocol.path("/v1/keys/validate")) { request in
            XCTAssertEqual(request.header("X-API-Key"), "sk_user_supplied")
            return .json(#"{"valid":false}"#)
        }
        let client = SeekrClient(baseURL: URL(string: "https://api.seekr.tv")!, session: session,
                                 apiKeyProvider: { "sk_user_supplied" })
        let valid = await client.validateKey()
        XCTAssertFalse(valid)
    }

    func testValidateKeyTreatsNetworkFailureAsFailure() async {
        let stub = StubURLProtocol.Handler()
        let session = stub.makeSession()
        stub.route(StubURLProtocol.any) { _ in
            throw URLError(.notConnectedToInternet)
        }
        let client = SeekrClient(baseURL: URL(string: "https://api.seekr.tv")!, session: session,
                                 apiKeyProvider: { "sk_user_supplied" })
        let valid = await client.validateKey()
        XCTAssertFalse(valid)
    }

    func testLookupBuildsMovieAndEpisodeQueryAndParsesSuccess() async throws {
        let stub = StubURLProtocol.Handler()
        let session = stub.makeSession()

        stub.route(StubURLProtocol.any) { request in
            if request.path == "/sprites" {
                XCTAssertEqual(request.header("X-API-Key"), "sk_live_test")
                XCTAssertEqual(request.query["duration_ms"], "8340000")
                XCTAssertEqual(request.query["tmdb_id"], "550")
                return .json(
                    #"{"vtt_url":"https://sprites.seekr.tv/vtt?sig=1","scale":1.0,"source_duration_ms":8348000,"exact":true}"#
                )
            }
            if request.url?.host == "sprites.seekr.tv" {
                XCTAssertNil(request.header("X-API-Key"))
                let vtt = """
                WEBVTT

                00:00:00.000 --> 00:00:10.000
                https://sprites.seekr.tv/sheet.jpg?sig=1#xywh=0,0,320,180
                """
                return .text(vtt, contentType: "text/vtt")
            }
            return .status(404)
        }

        let client = SeekrClient(
            baseURL: URL(string: "https://api.seekr.tv")!,
            session: session,
            apiKeyProvider: { "sk_live_test" }
        )
        let result = await client.loadTrack(
            content: .movie(tmdbId: 550, imdbId: nil),
            durationMs: 8_340_000
        )
        guard case let .success(track) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(track.cues.count, 1)
        XCTAssertEqual(track.sourceDurationMs, 8_348_000)
        XCTAssertTrue(track.exact)
        XCTAssertEqual(track.scale, 1)
    }

    func testEpisodeQueryUsesShowIds() async {
        let stub = StubURLProtocol.Handler()
        let session = stub.makeSession()
        stub.route(StubURLProtocol.path("/sprites")) { request in
            XCTAssertEqual(request.query["show_tmdb_id"], "1396")
            XCTAssertEqual(request.query["season"], "1")
            XCTAssertEqual(request.query["episode"], "1")
            return .status(404)
        }
        let client = SeekrClient(
            baseURL: URL(string: "https://api.seekr.tv")!,
            session: session,
            apiKeyProvider: { "sk_live_test" }
        )
        let result = await client.loadTrack(
            content: .episode(showTmdbId: 1396, showImdbId: nil, season: 1, episode: 1),
            durationMs: 3_480_000
        )
        XCTAssertEqual(result, .failure(.noPreviews))
    }

    func testMissingTitleIsRememberedAndUnauthorizedRejectsLaterLookups() async {
        let stub = StubURLProtocol.Handler()
        let session = stub.makeSession()

        var calls = 0
        stub.route(StubURLProtocol.any) { request in
            calls += 1
            if request.query["tmdb_id"] == "1" {
                return .json(#"{"error":"no matching sprite sheet found"}"#, status: 404)
            }
            return .json(#"{"error":"invalid or missing credentials"}"#, status: 401)
        }

        let client = SeekrClient(
            baseURL: URL(string: "https://api.seekr.tv")!,
            session: session,
            apiKeyProvider: { "sk_live_test" }
        )
        let missing = await client.loadTrack(content: .movie(tmdbId: 1, imdbId: nil), durationMs: 1_000_000)
        XCTAssertEqual(missing, .failure(.noPreviews))

        // Same unavailable title is not requested again.
        let missingAgain = await client.loadTrack(content: .movie(tmdbId: 1, imdbId: nil), durationMs: 1_000_000)
        XCTAssertEqual(missingAgain, .failure(.noPreviews))
        XCTAssertEqual(calls, 1)

        let unauthorized = await client.loadTrack(
            content: .movie(tmdbId: 2, imdbId: nil),
            durationMs: 1_000_000
        )
        XCTAssertEqual(unauthorized, .failure(.unauthorized))

        let skipped = await client.loadTrack(
            content: .movie(tmdbId: 3, imdbId: nil),
            durationMs: 1_000_000
        )
        XCTAssertEqual(skipped, .failure(.unauthorized))
        XCTAssertEqual(calls, 2)
    }

    func testRateLimitHonorsRetryAfterWithoutRepeatCalls() async {
        let stub = StubURLProtocol.Handler()
        let session = stub.makeSession()

        var calls = 0
        stub.route(StubURLProtocol.any) { _ in
            calls += 1
            return .init(
                status: 429,
                headers: ["Retry-After": "120", "Content-Type": "application/json"],
                body: Data(#"{"error":"rate limited"}"#.utf8)
            )
        }

        let client = SeekrClient(
            baseURL: URL(string: "https://api.seekr.tv")!,
            session: session,
            apiKeyProvider: { "sk_live_test" }
        )
        let first = await client.loadTrack(content: .movie(tmdbId: 550, imdbId: nil), durationMs: 8_340_000)
        guard case let .failure(.rateLimited(retry)) = first else {
            return XCTFail("expected rate limit, got \(first)")
        }
        XCTAssertEqual(retry, 120)

        let second = await client.loadTrack(content: .movie(tmdbId: 603, imdbId: nil), durationMs: 8_160_000)
        guard case .failure(.rateLimited) = second else {
            return XCTFail("expected cached rate limit, got \(second)")
        }
        XCTAssertEqual(calls, 1)
    }
}
