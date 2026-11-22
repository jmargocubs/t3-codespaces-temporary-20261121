#if os(iOS) || KYRO_VOD_HOST_TESTS
import Foundation

/// How the player reaches a provider title's stream (Build 104).
///
/// `direct` hands the provider URL to the player unchanged, as Builds 100–103 did; every hop stays
/// HTTPS (or local), so App Transport Security allows it. `relayed` is for a route that reaches
/// plain HTTP on a non-local host, which ATS refuses inside the player: the player then reads it
/// through `XtreamVODCleartextRelay`.
enum XtreamVODStreamRoute: Equatable {
    case direct
    case relayed

    /// The route a chain of URLs needs: the stream URL, then each redirect target seen.
    static func decide(_ chain: [URL]) -> XtreamVODStreamRoute {
        chain.contains(where: requiresRelay) ? .relayed : .direct
    }

    /// A plain HTTP URL to a host `NSAllowsLocalNetworking` does not cover.
    static func requiresRelay(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        return !isLocal(url.host ?? "")
    }

    /// Hosts the app's ATS policy already allows over HTTP: loopback, unqualified names and
    /// `.local` names.
    static func isLocal(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.isEmpty { return false }
        if host == "localhost" || host == "::1" || host.hasPrefix("127.") { return true }
        if host.hasSuffix(".local") { return true }
        // An unqualified name has no dot; an IPv6 literal has colons and is not local unless
        // loopback (handled above).
        return !host.contains(".") && !host.contains(":")
    }

    /// Follows the stream's redirects with one ranged request and stops at the first hop that would
    /// need the relay, without loading it. A failure to reach the provider resolves to `direct`, so
    /// the player reports the provider's real error as before. The request carries the provider
    /// credentials in its URL; nothing about it is logged.
    static func resolve(_ url: URL, timeout: TimeInterval = 8) async -> (route: XtreamVODStreamRoute, hops: Int) {
        if requiresRelay(url) { return (.relayed, 0) }
        let recorder = RedirectRecorder()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: recorder, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                recorder.finish = { continuation.resume() }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        let chain = [url] + recorder.redirects
        return (decide(chain), recorder.redirects.count)
    }

    /// Stops at the first redirect the player could not follow, and at the first response.
    private final class RedirectRecorder: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _redirects: [URL] = []
        private var finished = false
        var finish: (() -> Void)?

        var redirects: [URL] { lock.withLock { _redirects } }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let next = request.url else { return completionHandler(nil) }
            let count = lock.withLock { _redirects.append(next); return _redirects.count }
            // Not followed: a hop the relay must take, or a loop.
            completionHandler(XtreamVODStreamRoute.requiresRelay(next) || count > XtreamVODCleartextRelay.maximumRedirects
                              ? nil : request)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            // The headers decide the route; the body is not needed.
            completionHandler(.cancel)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let callback: (() -> Void)? = lock.withLock {
                guard !finished else { return nil }
                finished = true
                return finish
            }
            callback?()
        }
    }
}
#endif
