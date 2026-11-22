#if os(iOS)
import Foundation

/// Asks the provider once what a failed VOD stream URL really returns: redirect hops, status,
/// content type, size, range support and the container's first bytes. It reads at most a few
/// kilobytes and then cancels, and it runs only after the player has released the stream, so it
/// never takes a second provider connection during playback.
///
/// The report holds statuses, booleans, sanitized header tokens and a container name. It never
/// holds a URL, host, username, password or token.
enum XtreamVODStreamProbe {
    static func probe(_ url: URL, timeout: TimeInterval = 12) async -> ExternalStreamProbeReport {
        let recorder = Recorder(originalScheme: url.scheme?.lowercased(), originalHost: url.host?.lowercased())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: recorder, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        var report = ExternalStreamProbeReport()
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse {
                report.finalStatus = http.statusCode
                report.finalScheme = http.url?.scheme?.lowercased()
                report.contentType = http.value(forHTTPHeaderField: "Content-Type")
                report.acceptsRanges = http.statusCode == 206
                    || http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") == true
                report.totalBytes = ExternalPlaybackDiagnostics.totalBytes(
                    status: http.statusCode,
                    contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                    contentLength: http.expectedContentLength)
            }
            var head: [UInt8] = []
            head.reserveCapacity(512)
            for try await byte in bytes {
                head.append(byte)
                if head.count >= 512 { break }
            }
            report.container = ExternalPlaybackDiagnostics.sniffContainer(head)
        } catch {
            let nsError = error as NSError
            report.transportErrorDomain = nsError.domain
            report.transportErrorCode = nsError.code
        }
        report.hops = recorder.hops
        return report
    }

    private final class Recorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [ExternalStreamProbeReport.Hop] = []
        private var lastScheme: String?
        private var lastHost: String?

        init(originalScheme: String?, originalHost: String?) {
            lastScheme = originalScheme
            lastHost = originalHost
        }

        var hops: [ExternalStreamProbeReport.Hop] {
            lock.withLock { recorded }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            let count = record(status: response.statusCode, scheme: request.url?.scheme?.lowercased(),
                               host: request.url?.host?.lowercased())
            // Bounded like a player: a redirect loop is a provider fault, not a stream.
            return count <= 8 ? request : nil
        }

        private func record(status: Int, scheme: String?, host: String?) -> Int {
            lock.withLock {
                recorded.append(.init(status: status,
                                      downgradedToHTTP: lastScheme == "https" && scheme == "http",
                                      changedHost: host != lastHost))
                lastScheme = scheme
                lastHost = host
                return recorded.count
            }
        }
    }
}
#endif
