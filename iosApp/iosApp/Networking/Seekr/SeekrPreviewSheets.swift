import CoreGraphics
import Foundation
import ImageIO
import OSLog

/// Fetches Seekr sprite sheets, crops 320×180 tiles, and answers scrub times.
///
/// Sheets stay compressed in memory (bounded) with a small temporary disk
/// cache. Duplicate in-flight downloads are coalesced so rapid scrubbing does
/// not stampede the network. Signed URL expiry is respected by refusing stale
/// tracks so the owner can reload.
actor SeekrPreviewSheets {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.cubbiestream.kyro",
        category: "SeekrPreviewSheets"
    )
    private static let sheetWait: Duration = .seconds(1)
    private static let maxMemorySheets = 12
    private static let diskCacheBytes = 24 * 1024 * 1024

    private var track: SeekrTrack
    private var offsetMs: Int64
    private let session: URLSession
    private var data: [URL: Data] = [:]
    private var order: [URL] = []
    private var fetches: [URL: Task<Data?, Never>] = [:]
    private var failedAt: [URL: Date] = [:]
    private var decoded: (url: URL, image: CGImage)?
    private var closed = false
    private let diskDirectory: URL?

    init(
        track: SeekrTrack,
        offsetMs: Int64 = 0,
        session: URLSession? = nil,
        diskDirectory: URL? = SeekrPreviewSheets.makeDiskDirectory()
    ) {
        self.track = track
        self.offsetMs = offsetMs
        self.diskDirectory = diskDirectory
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.httpAdditionalHeaders = ["User-Agent": "KyroSeekr/1.0"]
            self.session = URLSession(configuration: config)
        }
    }

    func updateOffsetMs(_ value: Int64) {
        offsetMs = value
    }

    func replaceTrack(_ track: SeekrTrack, offsetMs: Int64) {
        self.track = track
        self.offsetMs = offsetMs
        data = [:]
        order = []
        for fetch in fetches.values { fetch.cancel() }
        fetches = [:]
        failedAt = [:]
        decoded = nil
    }

    func shutdown() {
        closed = true
        for fetch in fetches.values { fetch.cancel() }
        fetches = [:]
        decoded = nil
    }

    /// Prefetch sheets near `sourceSeconds`, then expand outward.
    func warm(aroundSourceSeconds seconds: Double) async {
        guard !closed, !track.isExpired else { return }
        let positionMs = Int64((max(seconds, 0) * 1_000).rounded())
        guard let center = track.nearestCue(positionMs: positionMs, offsetMs: offsetMs) else { return }
        var urls: [URL] = [center.sheetURL]
        // Neighbouring cues often share a sheet; collect a few unique ones.
        if let index = track.cues.firstIndex(where: { $0.startMs == center.startMs }) {
            for delta in 1...40 {
                if index + delta < track.cues.count {
                    let url = track.cues[index + delta].sheetURL
                    if !urls.contains(url) { urls.append(url) }
                }
                if index - delta >= 0 {
                    let url = track.cues[index - delta].sheetURL
                    if !urls.contains(url) { urls.append(url) }
                }
                if urls.count >= 4 { break }
            }
        }
        for url in urls {
            if Task.isCancelled || closed { return }
            if data[url] == nil, let fetch = fetch(url) {
                _ = await fetch.value
            }
        }
    }

    /// Thumbnail for a source-media time in seconds, or nil when unavailable.
    func thumbnail(atSourceTime seconds: Double, waitingForDownload: Bool = true) async -> (image: CGImage, cueStartSeconds: Double)? {
        guard !closed, seconds.isFinite, seconds >= 0 else { return nil }
        if track.isExpired {
            Self.logger.info("Seekr track expired; skipping thumbnail.")
            return nil
        }
        let positionMs = Int64((seconds * 1_000).rounded())
        guard let cue = track.nearestCue(positionMs: positionMs, offsetMs: offsetMs) else { return nil }
        guard let image = await sheetImage(cue.sheetURL, waitingForDownload: waitingForDownload) else {
            return nil
        }
        // Sheet may be served at a different pixel size than the VTT coordinates.
        let nominalWidth = cue.rect.width
        let scale = nominalWidth > 0 ? CGFloat(image.width) / expectedSheetWidth(for: cue, image: image) : 1
        let rect = CGRect(
            x: cue.rect.minX * scale,
            y: cue.rect.minY * scale,
            width: cue.rect.width * scale,
            height: cue.rect.height * scale
        ).integral
        guard let cropped = image.cropping(to: rect) else { return nil }
        return (cropped, cue.startSeconds)
    }

    func awaitSheet(atSourceTime seconds: Double) async -> Bool {
        guard !closed, let cue = track.nearestCue(
            positionMs: Int64((max(seconds, 0) * 1_000).rounded()),
            offsetMs: offsetMs
        ) else { return false }
        if data[cue.sheetURL] == nil, let fetch = fetches[cue.sheetURL] {
            _ = await fetch.value
        }
        return !closed && data[cue.sheetURL] != nil
    }

    private func expectedSheetWidth(for cue: SeekrCue, image: CGImage) -> CGFloat {
        // Infer columns from the largest x+w among cues on this sheet when possible.
        let sameSheet = track.cues.filter { $0.sheetURL == cue.sheetURL }
        let maxX = sameSheet.map { $0.rect.maxX }.max() ?? cue.rect.maxX
        if maxX > 0 { return maxX }
        return CGFloat(image.width)
    }

    private func sheetImage(_ url: URL, waitingForDownload: Bool) async -> CGImage? {
        if let decoded, decoded.url == url { return decoded.image }
        guard let bytes = await sheetData(url, waitingForDownload: waitingForDownload),
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(
                  source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) else { return nil }
        decoded = (url, image)
        return image
    }

    private func sheetData(_ url: URL, waitingForDownload: Bool) async -> Data? {
        if let bytes = data[url] { return bytes }
        if let disk = readDisk(url) {
            storeMemory(url, disk)
            return disk
        }
        guard let fetch = fetch(url), waitingForDownload else { return nil }
        return await Self.value(of: fetch, within: Self.sheetWait)
    }

    private func fetch(_ url: URL) -> Task<Data?, Never>? {
        if let fetch = fetches[url] { return fetch }
        if let failed = failedAt[url], -failed.timeIntervalSinceNow < 30 { return nil }
        let fetch = Task<Data?, Never> {
            let bytes = await download(url)
            return bytes
        }
        fetches[url] = fetch
        Task {
            let bytes = await fetch.value
            fetches[url] = nil
            if let bytes {
                storeMemory(url, bytes)
                writeDisk(url, bytes)
            } else if !Task.isCancelled {
                failedAt[url] = Date()
            }
        }
        return fetch
    }

    private func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            switch http.statusCode {
            case 200:
                return data
            case 403:
                Self.logger.info("Seekr sheet URL expired (403).")
                return nil
            default:
                return nil
            }
        } catch {
            if !Task.isCancelled {
                Self.logger.info("Seekr sheet download failed: \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
    }

    private func storeMemory(_ url: URL, _ bytes: Data) {
        if data[url] == nil {
            order.append(url)
        }
        data[url] = bytes
        while order.count > Self.maxMemorySheets {
            let evicted = order.removeFirst()
            data[evicted] = nil
            if decoded?.url == evicted { decoded = nil }
        }
    }

    private func readDisk(_ url: URL) -> Data? {
        guard let path = diskPath(for: url) else { return nil }
        return try? Data(contentsOf: path)
    }

    private func writeDisk(_ url: URL, _ bytes: Data) {
        guard let directory = diskDirectory, let path = diskPath(for: url) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? bytes.write(to: path, options: .atomic)
        trimDiskCache()
    }

    private func diskPath(for url: URL) -> URL? {
        guard let directory = diskDirectory else { return nil }
        let name = StableHash.hex(url.absoluteString) + ".jpg"
        return directory.appendingPathComponent(name)
    }

    private func trimDiskCache() {
        guard let directory = diskDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                  options: [.skipsHiddenFiles]
              ) else { return }
        var entries: [(url: URL, date: Date, size: Int)] = []
        var total = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = values?.fileSize ?? 0
            total += size
            entries.append((file, values?.contentModificationDate ?? .distantPast, size))
        }
        guard total > Self.diskCacheBytes else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries {
            guard total > Self.diskCacheBytes else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private static func value(of fetch: Task<Data?, Never>, within limit: Duration) async -> Data? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task { once.resume(with: await fetch.value) }
            Task {
                try? await Task.sleep(for: limit)
                once.resume(with: nil)
            }
        }
    }

    private static func makeDiskDirectory() -> URL? {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("kyro-seekr-sheets", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

/// One-shot resume helper shared with ServerTrickplaySheets' wait pattern.
private final class ResumeOnce<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T?, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = continuation
    }

    func resume(with value: T?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }
}

private enum StableHash {
    static func hex(_ string: String) -> String {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}
