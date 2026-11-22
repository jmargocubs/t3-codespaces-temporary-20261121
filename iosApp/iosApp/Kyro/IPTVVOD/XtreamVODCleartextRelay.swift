#if os(iOS) || KYRO_VOD_HOST_TESTS
import Foundation
import Network
import os

/// Build 104: plays an IPTV title whose stream reaches the provider's media server over plain HTTP.
///
/// Xtream panels commonly answer the HTTPS stream URL with a redirect to an HTTP media host. The
/// player (Aether) reads sources through `URLSession`, so App Transport Security refuses that hop
/// (`NSURLErrorAppTransportSecurityRequiresSecureConnection`, -1022) and every movie and episode
/// fails. The app's ATS policy stays as it is (`NSAllowsLocalNetworking` only): relaxing it would
/// also let Silo server, pairing and sign-in traffic fall back to cleartext.
///
/// Instead the player reads `http://127.0.0.1:<port>/v/<token>/stream.<ext>`, which local
/// networking already permits, and this relay makes the provider request itself with
/// Network.framework: it follows the redirect chain (HTTPS hops keep full certificate validation),
/// forwards the player's `Range` and other end-to-end headers, and streams the response back as it
/// arrives. Only titles whose route actually reaches HTTP use it (`XtreamVODStreamRoute`).
///
/// It listens on the loopback interface only, serves only tokens registered for a playback, and
/// never logs a URL, host, path, query or credential.
final class XtreamVODCleartextRelay: @unchecked Sendable {
    static let shared = XtreamVODCleartextRelay()

    /// Routes kept at once; the oldest goes first. One playback uses one route.
    static let maximumRoutes = 8
    /// Redirects followed per request.
    static let maximumRedirects = 5

    private let queue = DispatchQueue(label: "com.cubbiestream.kyro.iptv-relay", qos: .userInitiated)
    private var listener: NWListener?
    private var port: UInt16?
    private var readyWaiters: [CheckedContinuation<UInt16, Error>] = []
    private var routes: [(token: String, origin: URL)] = []
    private let logger = Logger(subsystem: "com.cubbiestream.kyro", category: "iptv_vod_relay")

    init() {}

    /// The loopback URL the player reads `origin` through. Starts the relay on first use.
    func url(for origin: URL) async throws -> URL {
        let port = try await start()
        let token = UUID().uuidString.lowercased()
        queue.sync {
            routes.append((token, origin))
            if routes.count > Self.maximumRoutes { routes.removeFirst(routes.count - Self.maximumRoutes) }
        }
        let fileExtension = origin.pathExtension.isEmpty ? "" : ".\(origin.pathExtension)"
        return URL(string: "http://127.0.0.1:\(port)/v/\(token)/stream\(fileExtension)")!
    }

    /// Forgets a route once its playback has ended.
    func release(_ relayURL: URL) {
        guard let token = XtreamVODRelayHTTP.token(inPath: relayURL.path) else { return }
        queue.sync { routes.removeAll { $0.token == token } }
    }

    /// Stops listening and forgets every route. Tests use it; the app keeps the relay for the process.
    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            port = nil
            routes = []
        }
    }

    // MARK: Listener

    private func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { return continuation.resume(throwing: CancellationError()) }
                if let port = self.port { return continuation.resume(returning: port) }
                self.readyWaiters.append(continuation)
                guard self.listener == nil else { return }
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredInterfaceType = .loopback
                    parameters.acceptLocalOnly = true
                    parameters.allowLocalEndpointReuse = true
                    let listener = try NWListener(using: parameters, on: .any)
                    listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    self.listener = listener
                    listener.start(queue: self.queue)
                } catch {
                    self.failWaiters(error)
                }
            }
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else { return }
            self.port = port
            let waiters = readyWaiters
            readyWaiters = []
            waiters.forEach { $0.resume(returning: port) }
            logger.info("relay_ready")
        case .failed(let error):
            listener?.cancel()
            listener = nil
            port = nil
            failWaiters(error)
            logger.error("relay_failed")
        case .cancelled:
            listener = nil
            port = nil
        default:
            break
        }
    }

    private func failWaiters(_ error: Error) {
        let waiters = readyWaiters
        readyWaiters = []
        waiters.forEach { $0.resume(throwing: error) }
    }

    private func origin(for token: String) -> URL? {
        routes.last { $0.token == token }?.origin
    }

    // MARK: One player request

    /// One player request and the provider connection currently answering it. Touched only on
    /// the relay queue.
    private final class Exchange {
        let client: NWConnection
        var upstream: NWConnection?
        var isClosed = false
        init(client: NWConnection) { self.client = client }
    }

    private func accept(_ client: NWConnection) {
        client.start(queue: queue)
        let exchange = Exchange(client: client)
        readHead(from: client, buffer: Data()) { [weak self] head, _ in
            // Players send no request bodies to the relay; anything after the head is ignored.
            guard let self else { return client.cancel() }
            guard let head, let request = XtreamVODRelayHTTP.parseRequestHead(head) else {
                return self.respond(client, status: 400)
            }
            guard let token = XtreamVODRelayHTTP.token(inPath: request.target),
                  let origin = self.origin(for: token) else {
                return self.respond(client, status: 404)
            }
            // A player that hangs up (a seek, a stop) ends the provider request too.
            self.watchForHangUp(exchange)
            self.forward(request, to: origin, redirects: 0, exchange: exchange, started: DispatchTime.now())
        }
    }

    private func forward(_ request: XtreamVODRelayHTTP.Request, to url: URL, redirects: Int,
                         exchange: Exchange, started: DispatchTime) {
        let client = exchange.client
        guard !exchange.isClosed else { return }
        guard let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? (scheme == "https" ? 443 : 80))) else {
            return respond(client, status: 502)
        }
        let upstream = NWConnection(host: NWEndpoint.Host(host), port: port,
                                    using: scheme == "https" ? .tls : .tcp)
        exchange.upstream = upstream
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let head = XtreamVODRelayHTTP.upstreamRequestHead(request, url: url)
                upstream.send(content: head, completion: .contentProcessed { error in
                    if error != nil { return self.fail(client, upstream) }
                    self.readHead(from: upstream, buffer: Data()) { head, leftover in
                        self.relayResponse(head: head, leftover: leftover, request: request, url: url,
                                           redirects: redirects, exchange: exchange, upstream: upstream,
                                           started: started)
                    }
                })
            case .failed, .waiting:
                // `.waiting` is a refused or unreachable origin; the player retries on its own.
                upstream.stateUpdateHandler = nil
                self.fail(client, upstream)
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    private func relayResponse(head: Data?, leftover: Data, request: XtreamVODRelayHTTP.Request, url: URL,
                               redirects: Int, exchange: Exchange, upstream: NWConnection,
                               started: DispatchTime) {
        let client = exchange.client
        guard let head, let response = XtreamVODRelayHTTP.parseResponseHead(head) else {
            return fail(client, upstream)
        }
        if let next = XtreamVODRelayHTTP.redirectTarget(response, from: url) {
            upstream.stateUpdateHandler = nil
            upstream.cancel()
            guard redirects < Self.maximumRedirects else { return respond(client, status: 508) }
            var followed = request
            if response.status == 303, request.method != "HEAD" { followed.method = "GET" }
            return forward(followed, to: next, redirects: redirects + 1, exchange: exchange, started: started)
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        logger.info("relay_response status=\(response.status, privacy: .public) hops=\(redirects, privacy: .public) ms=\(Int(elapsed), privacy: .public)")
        let clientHead = XtreamVODRelayHTTP.clientResponseHead(response)
        client.send(content: clientHead + leftover, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { return self.fail(client, upstream) }
            self.pump(from: upstream, to: client)
        })
    }

    /// Streams the provider's body to the player with one chunk in flight, so a slow player slows
    /// the provider read instead of filling memory.
    private func pump(from upstream: NWConnection, to client: NWConnection) {
        upstream.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                client.send(content: data, completion: .contentProcessed { error in
                    if error != nil { return self.fail(client, upstream) }
                    if isComplete { return self.finish(client, upstream) }
                    self.pump(from: upstream, to: client)
                })
            } else if isComplete || error != nil {
                self.finish(client, upstream)
            } else {
                self.pump(from: upstream, to: client)
            }
        }
    }

    private func watchForHangUp(_ exchange: Exchange) {
        exchange.client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                exchange.isClosed = true
                exchange.upstream?.stateUpdateHandler = nil
                exchange.upstream?.cancel()
                exchange.client.cancel()
            } else {
                self.watchForHangUp(exchange)
            }
        }
    }

    private func readHead(from connection: NWConnection, buffer: Data,
                          completion: @escaping (_ head: Data?, _ leftover: Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard self != nil else { return completion(nil, Data()) }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let split = XtreamVODRelayHTTP.splitHead(buffer) {
                return completion(split.head, split.rest)
            }
            if isComplete || error != nil || buffer.count > XtreamVODRelayHTTP.maximumHeadBytes {
                return completion(nil, Data())
            }
            self?.readHead(from: connection, buffer: buffer, completion: completion)
        }
    }

    private func respond(_ client: NWConnection, status: Int) {
        client.send(content: XtreamVODRelayHTTP.statusOnlyResponse(status), contentContext: .finalMessage,
                    isComplete: true, completion: .contentProcessed { _ in client.cancel() })
    }

    private func fail(_ client: NWConnection, _ upstream: NWConnection) {
        upstream.stateUpdateHandler = nil
        upstream.cancel()
        logger.error("relay_upstream_failed")
        respond(client, status: 502)
    }

    private func finish(_ client: NWConnection, _ upstream: NWConnection) {
        upstream.cancel()
        client.send(content: nil, contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { _ in client.cancel() })
    }
}

/// The HTTP/1.1 the relay reads and writes, kept pure for tests.
enum XtreamVODRelayHTTP {
    static let maximumHeadBytes = 32 * 1024

    struct Request: Equatable {
        var method: String
        let target: String
        /// End-to-end headers in the player's order, names as sent.
        let headers: [(name: String, value: String)]

        static func == (lhs: Request, rhs: Request) -> Bool {
            lhs.method == rhs.method && lhs.target == rhs.target
                && lhs.headers.map(\.name) == rhs.headers.map(\.name)
                && lhs.headers.map(\.value) == rhs.headers.map(\.value)
        }
    }

    struct Response {
        let status: Int
        let statusLine: String
        let headers: [(name: String, value: String)]

        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    /// Hop-by-hop headers (RFC 9110 §7.6.1) plus the ones the relay sets itself.
    private static let droppedRequestHeaders: Set<String> = [
        "host", "connection", "keep-alive", "proxy-connection", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade", "accept-encoding",
    ]
    private static let droppedResponseHeaders: Set<String> = [
        "connection", "keep-alive", "proxy-connection", "proxy-authenticate", "trailer", "upgrade",
    ]

    /// The token in a relay path, `/v/<token>/stream.<ext>`.
    static func token(inPath path: String) -> String? {
        let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let parts = pathOnly.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "v", parts[1].count == 36 else { return nil }
        return String(parts[1])
    }

    static func splitHead(_ buffer: Data) -> (head: Data, rest: Data)? {
        guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return (buffer[buffer.startIndex..<range.upperBound], buffer[range.upperBound...])
    }

    private static func lines(_ head: Data) -> [String]? {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return nil }
        return text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
    }

    private static func headers(_ lines: ArraySlice<String>) -> [(name: String, value: String)] {
        lines.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : (name, value)
        }
    }

    static func parseRequestHead(_ head: Data) -> Request? {
        guard let lines = lines(head), let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
        return Request(method: String(parts[0]), target: String(parts[1]), headers: headers(lines.dropFirst()))
    }

    static func parseResponseHead(_ head: Data) -> Response? {
        guard let lines = lines(head), let first = lines.first else { return nil }
        let parts = first.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else { return nil }
        return Response(status: status, statusLine: first, headers: headers(lines.dropFirst()))
    }

    /// The request the relay sends to `url`: the player's method and end-to-end headers (Range,
    /// User-Agent, Accept, If-Range…), the origin's own Host, an identity encoding so byte ranges
    /// stay exact, and `Connection: close` so each player request is one provider request.
    static func upstreamRequestHead(_ request: Request, url: URL) -> Data {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var target = components?.percentEncodedPath ?? "/"
        if target.isEmpty { target = "/" }
        if let query = components?.percentEncodedQuery { target += "?\(query)" }
        let scheme = url.scheme?.lowercased() ?? "http"
        var host = url.host ?? ""
        if host.contains(":") { host = "[\(host)]" }
        if let port = url.port, port != (scheme == "https" ? 443 : 80) { host += ":\(port)" }
        var lines = ["\(request.method) \(target) HTTP/1.1", "Host: \(host)"]
        for header in request.headers where !droppedRequestHeaders.contains(header.name.lowercased()) {
            lines.append("\(header.name): \(header.value)")
        }
        lines.append("Accept-Encoding: identity")
        lines.append("Connection: close")
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// Where a redirect leads, for 301, 302, 303, 307 and 308 to an http or https URL.
    static func redirectTarget(_ response: Response, from url: URL) -> URL? {
        guard [301, 302, 303, 307, 308].contains(response.status),
              let location = response.header("Location"), !location.isEmpty,
              let next = URL(string: location, relativeTo: url)?.absoluteURL,
              let scheme = next.scheme?.lowercased(), scheme == "http" || scheme == "https",
              next.host?.isEmpty == false else { return nil }
        return next
    }

    /// The provider's response head for the player, with this hop's connection headers replaced.
    static func clientResponseHead(_ response: Response) -> Data {
        var lines = [response.statusLine]
        for header in response.headers where !droppedResponseHeaders.contains(header.name.lowercased()) {
            lines.append("\(header.name): \(header.value)")
        }
        lines.append("Connection: close")
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    static func statusOnlyResponse(_ status: Int) -> Data {
        let reason: String
        switch status {
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 508: reason = "Loop Detected"
        default: reason = "Bad Gateway"
        }
        return Data("HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }
}
#endif
