#if os(iOS) || KYRO_VOD_HOST_TESTS
import Foundation
import Network
import XCTest
#if !KYRO_VOD_HOST_TESTS
@testable import Silo
#endif

/// Build 104: IPTV titles whose stream redirects to plain HTTP. Runs on the Mac without a
/// simulator (`swiftc -D KYRO_VOD_HOST_TESTS`, see docs/kyro-development/build-104-playback-performance.md)
/// and in the iOS test target. The relay tests use real sockets on the loopback interface.
final class IPTVVODStreamRelayTests: XCTestCase {
    // MARK: Route decision

    func testHTTPSRoutesStayDirectAndAnHTTPHopNeedsTheRelay() {
        let stream = URL(string: "https://panel.example.com/movie/u/p/42.mkv")!
        XCTAssertEqual(XtreamVODStreamRoute.decide([stream]), .direct)
        XCTAssertEqual(XtreamVODStreamRoute.decide([stream, URL(string: "https://cdn.example.com/x.mkv")!]), .direct)
        XCTAssertEqual(XtreamVODStreamRoute.decide([stream, URL(string: "http://cdn.example.net:8080/x.mkv?t=1")!]),
                       .relayed, "the captured failure: https panel → http media host")
        XCTAssertEqual(XtreamVODStreamRoute.decide([URL(string: "http://panel.example.com/movie/u/p/42.mkv")!]),
                       .relayed)
    }

    func testHostsTheAppAlreadyAllowsOverHTTPStayDirect() {
        for host in ["127.0.0.1", "localhost", "[::1]", "nas.local", "mediabox"] {
            XCTAssertFalse(XtreamVODStreamRoute.requiresRelay(URL(string: "http://\(host):8080/a.mkv")!), host)
        }
        for host in ["93.184.216.34", "cdn.example.net", "[2001:db8::1]"] {
            XCTAssertTrue(XtreamVODStreamRoute.requiresRelay(URL(string: "http://\(host)/a.mkv")!), host)
        }
        XCTAssertFalse(XtreamVODStreamRoute.requiresRelay(URL(string: "https://cdn.example.net/a.mkv")!))
    }

    // MARK: Relay HTTP

    func testUpstreamRequestKeepsTheRangeAndRewritesConnectionHeaders() throws {
        let head = Data(("GET /v/\(UUID().uuidString.lowercased())/stream.mkv HTTP/1.1\r\nHost: 127.0.0.1:5000\r\n"
                         + "Range: bytes=100-199\r\nUser-Agent: AetherEngine\r\nAccept-Encoding: gzip\r\n"
                         + "Connection: keep-alive\r\nKeep-Alive: timeout=5\r\n\r\n").utf8)
        let request = try XCTUnwrap(XtreamVODRelayHTTP.parseRequestHead(head))
        XCTAssertEqual(request.method, "GET")
        let url = URL(string: "http://cdn.example.net:8080/movie/a%20b/42.mkv?token=x%2By&e=1")!
        let text = String(decoding: XtreamVODRelayHTTP.upstreamRequestHead(request, url: url), as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        XCTAssertEqual(lines.first, "GET /movie/a%20b/42.mkv?token=x%2By&e=1 HTTP/1.1", "path and query keep their encoding")
        XCTAssertTrue(lines.contains("Host: cdn.example.net:8080"))
        XCTAssertTrue(lines.contains("Range: bytes=100-199"))
        XCTAssertTrue(lines.contains("User-Agent: AetherEngine"))
        XCTAssertTrue(lines.contains("Accept-Encoding: identity"), "byte ranges stay exact")
        XCTAssertTrue(lines.contains("Connection: close"))
        XCTAssertFalse(lines.contains("Host: 127.0.0.1:5000"))
        XCTAssertFalse(text.contains("gzip") || text.contains("keep-alive") || text.contains("Keep-Alive"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))

        let https = String(decoding: XtreamVODRelayHTTP.upstreamRequestHead(request, url: URL(string: "https://cdn.example.net/a.ts")!),
                           as: UTF8.self)
        XCTAssertTrue(https.contains("Host: cdn.example.net\r\n"), "the default port is not written")
    }

    func testRedirectTargetsResolveRelativeLocationsAndRejectOtherSchemes() throws {
        let base = URL(string: "https://panel.example.com/movie/u/p/42.mkv")!
        func response(_ status: Int, _ location: String?) -> XtreamVODRelayHTTP.Response {
            var head = "HTTP/1.1 \(status) X\r\n"
            if let location { head += "location: \(location)\r\n" }
            return XtreamVODRelayHTTP.parseResponseHead(Data((head + "\r\n").utf8))!
        }
        XCTAssertEqual(XtreamVODRelayHTTP.redirectTarget(response(302, "http://cdn.example.net:8080/x.mkv?t=1"), from: base),
                       URL(string: "http://cdn.example.net:8080/x.mkv?t=1"))
        XCTAssertEqual(XtreamVODRelayHTTP.redirectTarget(response(301, "/live/7.ts"), from: base),
                       URL(string: "https://panel.example.com/live/7.ts"))
        for status in [303, 307, 308] { XCTAssertNotNil(XtreamVODRelayHTTP.redirectTarget(response(status, "/a"), from: base)) }
        XCTAssertNil(XtreamVODRelayHTTP.redirectTarget(response(200, "/a"), from: base))
        XCTAssertNil(XtreamVODRelayHTTP.redirectTarget(response(302, nil), from: base))
        XCTAssertNil(XtreamVODRelayHTTP.redirectTarget(response(302, "file:///etc/passwd"), from: base))
    }

    func testPlayerResponseKeepsRangeHeadersAndClosesTheConnection() throws {
        let head = Data("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-9/100\r\nContent-Length: 10\r\nConnection: keep-alive\r\nKeep-Alive: timeout=5\r\n\r\n".utf8)
        let response = try XCTUnwrap(XtreamVODRelayHTTP.parseResponseHead(head))
        XCTAssertEqual(response.status, 206)
        let text = String(decoding: XtreamVODRelayHTTP.clientResponseHead(response), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 206 Partial Content\r\n"))
        XCTAssertTrue(text.contains("Content-Range: bytes 0-9/100\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 10\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertFalse(text.contains("keep-alive") || text.contains("Keep-Alive"))
    }

    func testOnlyRegisteredRelayPathsCarryAToken() {
        let token = UUID().uuidString.lowercased()
        XCTAssertEqual(XtreamVODRelayHTTP.token(inPath: "/v/\(token)/stream.mkv"), token)
        XCTAssertEqual(XtreamVODRelayHTTP.token(inPath: "/v/\(token)/stream.mkv?x=1"), token)
        XCTAssertNil(XtreamVODRelayHTTP.token(inPath: "/v/short/stream.mkv"))
        XCTAssertNil(XtreamVODRelayHTTP.token(inPath: "/movie/u/p/42.mkv"))
    }

    // MARK: Playback request

    func testPlaybackRequestUsesTheRoutedURLAndTheTitleState() {
        let provider = UUID()
        let movie = XtreamVODItem(providerID: provider, kind: .movie, remoteID: 42, title: "Heat (1995)",
                                  category: "Drama", poster: nil, fileExtension: "mkv", summary: nil, genre: nil, rating: nil)
        let relayed = URL(string: "http://127.0.0.1:49152/v/\(UUID().uuidString.lowercased())/stream.mkv")!
        let request = KyroIPTVPlaybackPlan.request(playURL: relayed, item: movie, episode: nil, providerName: "My Playlist",
                                                   state: XtreamVODWatchState(position: 600, duration: 6000), fromStart: false)
        XCTAssertEqual(request.url, relayed)
        XCTAssertEqual(request.title, "Heat (1995)")
        XCTAssertEqual(request.sourceLabel, "IPTV · My Playlist")
        XCTAssertEqual(request.startPosition, 600)

        let show = XtreamVODItem(providerID: provider, kind: .series, remoteID: 9, title: "Om Nom Stories",
                                 category: "Kids", poster: nil, fileExtension: nil, summary: nil, genre: nil, rating: nil)
        let episode = XtreamVODEpisode(remoteID: 901, season: 1, number: 2, title: "Strange Delivery",
                                       fileExtension: "mp4", summary: nil)
        let direct = URL(string: "https://panel.example.com/series/u/p/901.mp4")!
        let episodeRequest = KyroIPTVPlaybackPlan.request(playURL: direct, item: show, episode: episode, providerName: "P",
                                                          state: XtreamVODWatchState(position: 600, duration: 6000), fromStart: true)
        XCTAssertEqual(episodeRequest.url, direct)
        XCTAssertEqual(episodeRequest.title, "Om Nom Stories · S1 E2")
        XCTAssertEqual(episodeRequest.startPosition, 0, "Start Over")
    }

    // MARK: Relay over real sockets

    func testRelayFollowsTheRedirectAndServesTheRequestedRange() async throws {
        let origin = try await LoopbackOrigin.start()
        defer { origin.stop() }
        let relay = XtreamVODCleartextRelay()
        defer { relay.stop() }
        let streamURL = URL(string: "http://127.0.0.1:\(origin.port)/movie/user/pass/42.mkv")!
        let relayURL = try await relay.url(for: streamURL)
        XCTAssertEqual(relayURL.host, "127.0.0.1")
        XCTAssertEqual(relayURL.pathExtension, "mkv")
        XCTAssertFalse(relayURL.absoluteString.contains("user") || relayURL.absoluteString.contains("pass"),
                       "the player URL carries no credential")

        var request = URLRequest(url: relayURL)
        request.setValue("bytes=10-19", forHTTPHeaderField: "Range")
        request.setValue("AetherTest", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes 10-19/\(LoopbackOrigin.body.count)")
        XCTAssertEqual(data, LoopbackOrigin.body.subdata(in: 10..<20))

        let seen = origin.requests
        XCTAssertEqual(seen.count, 2, "the redirect and the media request")
        XCTAssertTrue(seen[0].hasPrefix("GET /movie/user/pass/42.mkv HTTP/1.1\r\n"))
        XCTAssertTrue(seen[1].hasPrefix("GET /media/42.mkv?token=a%2Bb HTTP/1.1\r\n"), "the redirect's query is kept")
        for head in seen {
            XCTAssertTrue(head.contains("Host: 127.0.0.1:\(origin.port)\r\n"))
            XCTAssertTrue(head.contains("Range: bytes=10-19\r\n"))
            XCTAssertTrue(head.contains("User-Agent: AetherTest\r\n"))
            XCTAssertTrue(head.contains("Connection: close\r\n"))
        }
    }

    func testRelayRefusesUnknownTokensAndRedirectLoops() async throws {
        let origin = try await LoopbackOrigin.start()
        defer { origin.stop() }
        let relay = XtreamVODCleartextRelay()
        defer { relay.stop() }
        let known = try await relay.url(for: URL(string: "http://127.0.0.1:\(origin.port)/loop")!)
        let session = URLSession(configuration: .ephemeral)

        let unknown = URL(string: "http://127.0.0.1:\(known.port!)/v/\(UUID().uuidString.lowercased())/stream.mkv")!
        let (_, missing) = try await session.data(from: unknown)
        XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode, 404, "the relay is not an open proxy")

        let (_, loop) = try await session.data(from: known)
        XCTAssertEqual((loop as? HTTPURLResponse)?.statusCode, 508)

        relay.release(known)
        let (_, released) = try await session.data(from: known)
        XCTAssertEqual((released as? HTTPURLResponse)?.statusCode, 404, "a finished playback's route is gone")
    }

    func testRouteCheckStopsAtTheFirstHTTPHopWithoutLoadingIt() async throws {
        let origin = try await LoopbackOrigin.start()
        defer { origin.stop() }
        // 127.0.0.1 is local, so the check follows it; its redirect to a remote HTTP host is not loaded.
        let resolved = await XtreamVODStreamRoute.resolve(URL(string: "http://127.0.0.1:\(origin.port)/to-remote-http")!)
        XCTAssertEqual(resolved.route, .relayed)
        XCTAssertEqual(resolved.hops, 1)

        let direct = await XtreamVODStreamRoute.resolve(URL(string: "http://127.0.0.1:\(origin.port)/movie/user/pass/42.mkv")!)
        XCTAssertEqual(direct.route, .direct, "local hops only")
    }
}

/// A tiny HTTP/1.1 origin on the loopback interface: a redirect, a ranged media file, a redirect
/// loop and a redirect to a remote HTTP host. Records each request head it receives.
private final class LoopbackOrigin: @unchecked Sendable {
    static let body = Data((0..<200).map { UInt8($0) })

    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.origin")
    private let lock = NSLock()
    private var _requests: [String] = []
    private(set) var port: UInt16 = 0
    private var isReady = false

    var requests: [String] { lock.withLock { _requests } }

    private init(listener: NWListener) { self.listener = listener }

    static func start() async throws -> LoopbackOrigin {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let origin = LoopbackOrigin(listener: try NWListener(using: parameters, on: .any))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            origin.listener.stateUpdateHandler = { state in
                // Called on the origin's serial queue.
                guard !origin.isReady else { return }
                switch state {
                case .ready:
                    origin.isReady = true
                    origin.port = origin.listener.port?.rawValue ?? 0
                    continuation.resume()
                case .failed(let error):
                    origin.isReady = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            origin.listener.newConnectionHandler = { origin.serve($0) }
            origin.listener.start(queue: origin.queue)
        }
        return origin
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, _ in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete { connection.cancel() } else { self.read(connection, buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.upperBound], as: UTF8.self)
            self.lock.withLock { self._requests.append(head) }
            connection.send(content: self.response(for: head), contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func response(for head: String) -> Data {
        let target = head.split(separator: " ")[1]
        switch target {
        case "/movie/user/pass/42.mkv":
            return Data("HTTP/1.1 302 Found\r\nLocation: /media/42.mkv?token=a%2Bb\r\nContent-Length: 0\r\n\r\n".utf8)
        case "/loop":
            return Data("HTTP/1.1 302 Found\r\nLocation: /loop\r\nContent-Length: 0\r\n\r\n".utf8)
        case "/to-remote-http":
            return Data("HTTP/1.1 302 Found\r\nLocation: http://media.example.invalid:8080/x.mkv\r\nContent-Length: 0\r\n\r\n".utf8)
        case "/media/42.mkv?token=a%2Bb":
            var lower = 0, upper = Self.body.count - 1
            if let line = head.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("range: bytes=") }) {
                let bounds = line.dropFirst("range: bytes=".count).split(separator: "-").compactMap { Int($0) }
                if bounds.count == 2 { lower = bounds[0]; upper = bounds[1] }
            }
            let slice = Self.body.subdata(in: lower..<(upper + 1))
            return Data(("HTTP/1.1 206 Partial Content\r\nContent-Type: video/x-matroska\r\n"
                         + "Content-Range: bytes \(lower)-\(upper)/\(Self.body.count)\r\nContent-Length: \(slice.count)\r\n"
                         + "Connection: keep-alive\r\n\r\n").utf8) + slice
        default:
            return Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8)
        }
    }
}
#endif
