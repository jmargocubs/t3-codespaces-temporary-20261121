import Foundation

/// Why provider-owned media (IPTV VOD) failed to open, from Aether's typed failure and, when one
/// ran, a post-failure stream probe. Pure Foundation so it runs in macOS host tests.
///
/// Privacy: every input here is a kind token, an error domain/code, HTTP status codes, header
/// values and a few sniffed bytes. Nothing in this file accepts or emits a URL, host name,
/// username, password or token.
enum ExternalPlaybackFailureReason: String, Equatable, Sendable {
    /// App Transport Security refused a cleartext (http) request, usually a provider redirect
    /// from https to an http CDN host.
    case insecureConnectionBlocked = "ats_blocked"
    /// TLS trust failed (self-signed or expired certificate).
    case certificateRejected = "tls_rejected"
    /// HTTP 401/403. Xtream panels also use 403 when the account is already streaming
    /// elsewhere (connection limit).
    case accessRefused = "access_refused"
    /// HTTP 404/410: the provider no longer has the file.
    case notFound = "not_found"
    /// HTTP 429/503/509 or Aether's rate-limited kind: connection or rate limit.
    case connectionLimit = "connection_limit"
    /// Any other HTTP 5xx.
    case providerError = "provider_error"
    /// The response was a web page or JSON, not media.
    case notMedia = "not_media"
    /// The media opened but the device cannot decode or bridge a track.
    case unsupportedMedia = "unsupported_media"
    /// The provider could not be reached or the connection dropped.
    case network = "network"
    case unknown = "unknown"
}

/// The privacy-safe facts a stream probe gathered. Built by the iOS probe; classified and
/// formatted here.
struct ExternalStreamProbeReport: Equatable, Sendable {
    struct Hop: Equatable, Sendable {
        let status: Int
        /// The redirect target used `http` while the request before it used `https`.
        let downgradedToHTTP: Bool
        let changedHost: Bool
    }

    var hops: [Hop] = []
    var finalStatus: Int?
    var finalScheme: String?
    var contentType: String?
    var totalBytes: Int64?
    var acceptsRanges: Bool?
    var container: ExternalStreamContainer = .unknown
    var transportErrorDomain: String?
    var transportErrorCode: Int?

    /// One diagnostics line, e.g. `hops=1 downgrade=yes status=200 type=video/x-matroska
    /// size=1.4GB ranges=yes container=matroska`.
    var summary: String {
        var parts: [String] = ["hops=\(hops.count)"]
        if hops.contains(where: \.downgradedToHTTP) { parts.append("downgrade=https_to_http") }
        if hops.contains(where: \.changedHost) { parts.append("redirect_host_changed=yes") }
        if let finalScheme { parts.append("scheme=\(finalScheme)") }
        if let finalStatus { parts.append("status=\(finalStatus)") }
        if let contentType { parts.append("type=\(ExternalPlaybackDiagnostics.sanitizedToken(contentType))") }
        if let totalBytes { parts.append("size=\(ExternalPlaybackDiagnostics.byteSummary(totalBytes))") }
        if let acceptsRanges { parts.append("ranges=\(acceptsRanges ? "yes" : "no")") }
        parts.append("container=\(container.rawValue)")
        if let transportErrorDomain, let transportErrorCode {
            parts.append("error=\(ExternalPlaybackDiagnostics.shortDomain(transportErrorDomain))\(transportErrorCode)")
        }
        return parts.joined(separator: " ")
    }
}

enum ExternalStreamContainer: String, Equatable, Sendable {
    case matroska, mp4, mpegts, hls, avi, flv, html, json, unknown

    /// AVFoundation opens these natively. Aether remuxes Matroska and MPEG-TS for it; AVI and FLV
    /// depend on their codecs and are the formats most likely to fail on iPhone.
    var isCommonlyPlayable: Bool {
        switch self {
        case .matroska, .mp4, .mpegts, .hls: true
        case .avi, .flv, .html, .json, .unknown: false
        }
    }
}

enum ExternalPlaybackDiagnostics {
    /// Identifies the container from the first bytes of the response body.
    static func sniffContainer(_ bytes: [UInt8]) -> ExternalStreamContainer {
        guard !bytes.isEmpty else { return .unknown }
        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return .matroska }
        if bytes.count >= 8, Array(bytes[4..<8]) == Array("ftyp".utf8) { return .mp4 }
        if bytes.count >= 8, ["moov", "mdat", "free", "wide", "skip"].contains(where: { Array(bytes[4..<8]) == Array($0.utf8) }) {
            return .mp4
        }
        if bytes[0] == 0x47, bytes.count < 189 || bytes[188] == 0x47 { return .mpegts }
        if bytes.starts(with: Array("RIFF".utf8)), bytes.count >= 12, Array(bytes[8..<12]) == Array("AVI ".utf8) { return .avi }
        if bytes.starts(with: Array("FLV".utf8)) { return .flv }
        let head = String(decoding: bytes.prefix(64), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if head.hasPrefix("#extm3u") { return .hls }
        if head.hasPrefix("<!doctype html") || head.hasPrefix("<html") || head.hasPrefix("<?xml") || head.hasPrefix("<") {
            return .html
        }
        if head.hasPrefix("{") || head.hasPrefix("[") { return .json }
        return .unknown
    }

    /// Classifies Aether's typed failure. `kind` is `PlaybackErrorKind.rawValue`.
    static func reason(kind: String, domain: String?, code: Int?) -> ExternalPlaybackFailureReason {
        if domain == NSURLErrorDomain, let code {
            if code == NSURLErrorAppTransportSecurityRequiresSecureConnection { return .insecureConnectionBlocked }
            if (-1206)...(-1200) ~= code { return .certificateRejected }
            if [NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
                NSURLErrorDNSLookupFailed].contains(code) { return .network }
            if code == NSURLErrorUserAuthenticationRequired { return .accessRefused }
        }
        switch kind {
        case "sourceCertificateRejected": return .certificateRejected
        case "sourceRateLimited": return .connectionLimit
        case "sourceRefused":
            return code.map(reason(httpStatus:)) ?? .accessRefused
        case "audioBridgeProducedNoOutput", "softwarePipelineFailed", "dolbyVisionRequiresHardware",
             "noPlayableTrackWithinBudget", "masterPlaylistRejected":
            return .unsupportedMedia
        case "nativeItemFailed":
            // AVFoundationErrorDomain: -11828 cannot open, -11829 not supported, -11833 decoder
            // missing, -11821 decode failed. Anything else on the native item is a transport failure.
            if domain == "AVFoundationErrorDomain", let code, [-11828, -11829, -11833, -11821, -11838].contains(code) {
                return .unsupportedMedia
            }
            return .unknown
        default:
            return .unknown
        }
    }

    static func reason(httpStatus status: Int) -> ExternalPlaybackFailureReason {
        switch status {
        case 401, 403, 407, 451: .accessRefused
        case 404, 410: .notFound
        case 429, 503, 509: .connectionLimit
        case 500...599: .providerError
        default: .unknown
        }
    }

    /// Refines an engine classification with what the probe saw. The probe wins where it
    /// observed something the engine could only summarize (an ATS block, a status, a web page).
    static func reason(engine: ExternalPlaybackFailureReason,
                       probe: ExternalStreamProbeReport?) -> ExternalPlaybackFailureReason {
        guard let probe else { return engine }
        if let domain = probe.transportErrorDomain, let code = probe.transportErrorCode {
            let transport = reason(kind: "", domain: domain, code: code)
            if transport != .unknown { return transport }
        }
        if let status = probe.finalStatus, !(200..<300).contains(status) {
            let byStatus = reason(httpStatus: status)
            if byStatus != .unknown { return byStatus }
        }
        if probe.container == .html || probe.container == .json { return .notMedia }
        if let type = probe.contentType?.lowercased(),
           type.hasPrefix("text/html") || type.hasPrefix("application/json") { return .notMedia }
        if engine == .unknown, probe.finalStatus.map({ (200..<300).contains($0) }) == true,
           !probe.container.isCommonlyPlayable, probe.container != .unknown {
            return .unsupportedMedia
        }
        return engine
    }

    static func userMessage(for reason: ExternalPlaybackFailureReason) -> String {
        switch reason {
        case .insecureConnectionBlocked:
            "The provider sent this video over an insecure (http) connection, which iOS blocks for this app."
        case .certificateRejected:
            "The provider’s secure connection could not be verified."
        case .accessRefused:
            "The provider refused this stream. The account may already be streaming on another device, or its plan may not include Movies and Series."
        case .notFound:
            "The provider no longer has this title."
        case .connectionLimit:
            "The provider’s connection limit was reached. Stop other streams on this account, then try again."
        case .providerError:
            "The provider had a server error. Try again later."
        case .notMedia:
            "The provider returned a web page instead of video. Check the subscription in the provider’s portal."
        case .unsupportedMedia:
            "This video uses a format or codec Kyro’s player can’t play on this device."
        case .network:
            "The provider couldn’t be reached. Check the connection, then try again."
        case .unknown:
            "Kyro couldn’t open this provider stream."
        }
    }

    /// The one-line, credential-free code shown under the message and written to the journal.
    static func diagnosticCode(reason: ExternalPlaybackFailureReason, kind: String?, domain: String?,
                               code: Int?, probe: ExternalStreamProbeReport?) -> String {
        var parts = ["reason=\(reason.rawValue)"]
        if let kind, !kind.isEmpty { parts.append("engine=\(sanitizedToken(kind))") }
        if let domain, let code { parts.append("code=\(shortDomain(domain))\(code)") }
        else if let code { parts.append("code=\(code)") }
        if let probe { parts.append(probe.summary) }
        return parts.joined(separator: " ")
    }

    static func shortDomain(_ domain: String) -> String {
        switch domain {
        case NSURLErrorDomain: "url"
        case "AVFoundationErrorDomain": "av"
        case NSPOSIXErrorDomain: "posix"
        case NSOSStatusErrorDomain: "os"
        default: sanitizedToken(domain).prefix(12).lowercased()
        }
    }

    /// Keeps letters, digits and `/.-+_` so a header value can never smuggle a URL or a
    /// credential-bearing query into the journal.
    static func sanitizedToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/.-+_"))
        let base = value.split(separator: ";").first.map(String.init) ?? value
        return String(base.unicodeScalars.filter(allowed.contains).map(Character.init)).prefix(48).lowercased()
    }

    static func byteSummary(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 { return String(format: "%.1fGB", Double(bytes) / 1_073_741_824) }
        if bytes >= 1_048_576 { return String(format: "%.0fMB", Double(bytes) / 1_048_576) }
        return "\(bytes)B"
    }

    /// The total size from `Content-Range: bytes 0-4095/123456`, else `Content-Length` for a 200.
    static func totalBytes(status: Int, contentRange: String?, contentLength: Int64?) -> Int64? {
        if let contentRange, let slash = contentRange.lastIndex(of: "/"),
           let total = Int64(contentRange[contentRange.index(after: slash)...].trimmingCharacters(in: .whitespaces)) {
            return total
        }
        return status == 200 ? contentLength.flatMap { $0 > 0 ? $0 : nil } : nil
    }
}
