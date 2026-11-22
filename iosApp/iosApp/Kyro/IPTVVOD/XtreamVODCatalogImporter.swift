#if os(iOS)
import Foundation

extension XtreamVODHTTP {
    static let temporaryFilePrefix = "kyro-vod-"

    /// Streams a catalog body to a temporary file. The cap is enforced from `Content-Length` and
    /// again while bytes arrive, so memory never holds more than one write buffer. The caller
    /// removes the returned file.
    ///
    /// - Parameter availableBytes: free space on the volume, or `nil` when unknown. A known
    ///   length plus `limits.reservedDiskBytes` must fit before the transfer starts.
    static func download(_ url: URL, session: URLSession, limits: XtreamVODCatalogLimits,
                         timeout: TimeInterval = 180,
                         directory: URL = FileManager.default.temporaryDirectory,
                         availableBytes: () -> Int64? = XtreamVODHTTP.availableDiskBytes) async throws -> URL {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do { (bytes, response) = try await session.bytes(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw XtreamVODError.network }
        guard let http = response as? HTTPURLResponse else { throw XtreamVODError.network }
        if http.statusCode == 401 || http.statusCode == 403 { throw XtreamVODError.authentication }
        if http.statusCode == 404 || http.statusCode == 405 || http.statusCode == 501 { throw XtreamVODError.unsupported }
        guard (200..<300).contains(http.statusCode) else { throw XtreamVODError.httpStatus(http.statusCode) }
        let expected = http.expectedContentLength
        guard expected <= 0 || expected <= Int64(limits.maximumDownloadBytes) else {
            throw XtreamVODError.downloadLimit(megabytes: limits.maximumDownloadMegabytes)
        }
        if let free = availableBytes(), free < max(0, expected) + Int64(limits.reservedDiskBytes) {
            throw XtreamVODError.storage
        }

        let file = directory.appendingPathComponent("\(temporaryFilePrefix)\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else { throw XtreamVODError.storage }
        let writeBufferBytes = 256 * 1024
        var buffer = [UInt8]()
        buffer.reserveCapacity(writeBufferBytes)
        var received = 0
        do {
            do {
                for try await byte in bytes {
                    buffer.append(byte)
                    if buffer.count == writeBufferBytes {
                        received += buffer.count
                        if received > limits.maximumDownloadBytes {
                            throw XtreamVODError.downloadLimit(megabytes: limits.maximumDownloadMegabytes)
                        }
                        try write(buffer, to: handle)
                        buffer.removeAll(keepingCapacity: true)
                        try Task.checkCancellation()
                    }
                }
            } catch let error as XtreamVODError {
                throw error
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                throw XtreamVODError.network
            }
            received += buffer.count
            if received > limits.maximumDownloadBytes {
                throw XtreamVODError.downloadLimit(megabytes: limits.maximumDownloadMegabytes)
            }
            try write(buffer, to: handle)
            do { try handle.close() } catch { throw XtreamVODError.storage }
            return file
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    private static func write(_ buffer: [UInt8], to handle: FileHandle) throws {
        guard !buffer.isEmpty else { return }
        // A full disk surfaces as a storage error, never as a smaller catalog.
        do { try handle.write(contentsOf: buffer) } catch { throw XtreamVODError.storage }
    }

    static func availableDiskBytes() -> Int64? {
        let path = FileManager.default.temporaryDirectory.path
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attributes[.systemFreeSize] as? NSNumber else { return nil }
        return free.int64Value
    }

    /// Removes transfer files a crash or forced quit left behind.
    static func removeStaleTemporaryFiles(in directory: URL = FileManager.default.temporaryDirectory) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(temporaryFilePrefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

/// Turns a downloaded catalog file into staged rows, one record at a time, off the main actor.
/// Nothing becomes visible until the service promotes the generation.
struct XtreamVODCatalogImporter: Sendable {
    let providerID: UUID
    let kind: XtreamVODKind
    let generation: String
    /// Category names by provider category ID, already sanitized.
    let categories: [String: String]
    let secrets: LiveTVSnapshotSecrets
    let username: String
    let password: String
    let limits: XtreamVODCatalogLimits
    var batchSize = 1_024
    var progressInterval = 2_048

    /// Imports up to `limits.maximumRecords` accepted titles from `file`, which holds `total`
    /// object records (from `XtreamVODCatalogFile.countRecords`).
    func run(file: URL, total: Int, store: XtreamVODCatalogStore,
             progress: @escaping @Sendable (XtreamVODImportCount) async -> Void) async throws -> XtreamVODImportCount {
        var scanner = XtreamVODCatalogScanner(maximumMemberBytes: limits.maximumRecordBytes)
        let decoder = JSONDecoder()
        var processed = 0, accepted = 0, malformed = 0, duplicate = 0
        var seen = Set<Int>()
        var batch: [XtreamVODItem] = []
        batch.reserveCapacity(batchSize)
        var pending: [XtreamVODCatalogScanner.Member] = []
        var limitReached = false

        func count(final: Bool = false) -> XtreamVODImportCount {
            .init(processed: processed, total: total, accepted: accepted + batch.count, malformed: malformed,
                  duplicate: duplicate, overLimit: final ? max(0, total - processed) : 0)
        }

        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: file) } catch { throw XtreamVODError.storage }
        defer { try? handle.close() }
        reading: while !limitReached {
            try Task.checkCancellation()
            let data: Data
            do { data = try handle.read(upToCount: XtreamVODCatalogFile.chunkBytes) ?? Data() }
            catch { throw XtreamVODError.storage }
            if data.isEmpty { break reading }
            _ = try data.withUnsafeBytes { raw in
                try scanner.consume(raw.bindMemory(to: UInt8.self)) { member in
                    pending.append(member)
                    return true
                }
            }
            for member in pending {
                if member.key == "user_info" || member.key == "server_info" || !member.isObject { continue }
                if accepted + batch.count >= limits.maximumRecords { limitReached = true; break }
                processed += 1
                guard let bytes = member.bytes,
                      let record = XtreamVODParser.record(from: bytes, decoder: decoder),
                      let item = item(from: record) else {
                    malformed += 1
                    continue
                }
                guard seen.insert(item.remoteID).inserted else { duplicate += 1; continue }
                batch.append(item)
                if batch.count == batchSize {
                    try await store.stage(batch, generation: generation)
                    accepted += batch.count
                    batch.removeAll(keepingCapacity: true)
                }
                if processed % progressInterval == 0 {
                    try Task.checkCancellation()
                    await progress(count())
                }
            }
            pending.removeAll(keepingCapacity: true)
        }
        if !limitReached { try scanner.finish() }
        if !batch.isEmpty {
            try await store.stage(batch, generation: generation)
            accepted += batch.count
            batch.removeAll()
        }
        let result = count(final: true)
        await progress(result)
        return result
    }

    /// Applies the same field limits and redaction as Build 94.
    func item(from record: XtreamVODRecord) -> XtreamVODItem? {
        guard let id = record.remoteID, id > 0, let title = safe(record.title, limit: 256) else { return nil }
        return .init(providerID: providerID, kind: kind, remoteID: id, title: title,
                     category: record.categoryID.flatMap { categories[$0] } ?? "Other",
                     poster: XtreamVODParser.safeArtwork(record.poster, username: username, password: password),
                     fileExtension: safe(record.fileExtension, limit: 8),
                     summary: safe(record.summary, limit: 1000),
                     genre: safe(record.genre, limit: 128),
                     rating: safe(record.rating, limit: 16))
    }

    func safe(_ raw: String?, limit: Int) -> String? {
        Self.safe(raw, limit: limit, secrets: secrets)
    }

    static func safe(_ raw: String?, limit: Int, secrets: LiveTVSnapshotSecrets) -> String? {
        guard let text = XtreamVODParser.clean(raw, limit: limit),
              LiveTVSnapshotRedaction.isSafe(text, maximumBytes: limit * 4, secrets: secrets) else { return nil }
        return text
    }
}
#endif
