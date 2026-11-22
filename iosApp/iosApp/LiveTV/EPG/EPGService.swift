import Foundation
import OSLog

/// Where a provider's guide comes from. Descriptions are redacted: the Xtream case contains a
/// password, and an XMLTV URL can carry userinfo, a query, or a fragment. Diagnostics must use
/// these descriptions rather than a synthesized dump of the associated values.
enum EPGFeedSource: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    case xmltv(URL)
    case xtream(server: String, username: String, password: String)

    var description: String {
        switch self {
        case .xmltv: "EPGFeedSource.xmltv(redacted)"
        case .xtream: "EPGFeedSource.xtream(redacted)"
        }
    }

    var debugDescription: String { description }

    /// Reflection would otherwise print every associated value, including a password or token.
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .enum) }

    func feedURL() throws -> URL {
        switch self {
        case .xmltv(let url):
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw EPGError.invalidSource
            }
            return url
        case let .xtream(server, username, password):
            return try XtreamEPG.xmltvURL(server: server, username: username, password: password)
        }
    }
}

/// Downloads a guide feed. Implementations must honor task cancellation and never surface the URL.
protocol EPGFeedLoading: Sendable {
    func load(_ url: URL, maximumBytes: Int) async throws -> Data
    /// `maximumDecodedBytes` applies only to a body the HTTP stack already decoded from a declared
    /// content coding into XML text; every other body stays under `maximumBytes`.
    func load(_ url: URL, maximumBytes: Int, maximumDecodedBytes: Int) async throws -> Data
}

extension EPGFeedLoading {
    func load(_ url: URL, maximumBytes: Int, maximumDecodedBytes: Int) async throws -> Data {
        try await load(url, maximumBytes: maximumBytes)
    }
}

struct URLSessionEPGFeedLoader: EPGFeedLoading {
    let session: URLSession
    var onAcceptedBytes: (@Sendable (Int) -> Void)? = nil

    /// Guides are larger and slower than playlists, so they get their own longer resource timeout.
    static func makeDefault() -> URLSessionEPGFeedLoader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        configuration.urlCache = nil
        return URLSessionEPGFeedLoader(session: URLSession(configuration: configuration))
    }

    func load(_ url: URL, maximumBytes: Int) async throws -> Data {
        try await load(url, maximumBytes: maximumBytes, maximumDecodedBytes: maximumBytes)
    }

    func load(_ url: URL, maximumBytes: Int, maximumDecodedBytes: Int) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/xml, text/xml, application/gzip, application/x-xz, */*",
                         forHTTPHeaderField: "Accept")
        let delegate = BoundedEPGDownload(maximumBytes: maximumBytes,
                                          maximumDecodedBytes: max(maximumBytes, maximumDecodedBytes),
                                          onAcceptedBytes: onAcceptedBytes)
        let boundedSession = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(request, session: boundedSession, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

/// Owns one URLSession data task and stops it as soon as the actual body exceeds its cap.
///
/// URLSession transparently decodes gzip, deflate and Brotli content codings, so a provider's
/// 12 MB compressed transfer arrives as 80 MB of XML. Such a body is held to the expanded-XML cap
/// instead of the download cap, but only when both the declared coding is one URLSession decodes
/// and the delivered bytes are XML text. A compressed file (`.xml.gz`, `.xml.xz`) sent with or
/// without a content coding starts with its archive magic, not `<`, and keeps the download cap.
private final class BoundedEPGDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private enum Representation { case undecided, decodedXML, other }

    private static let decodedCodings: Set<String> = ["gzip", "x-gzip", "deflate", "br"]

    private let lock = NSLock()
    private let maximumBytes: Int
    private let maximumDecodedBytes: Int
    private var isTransportDecoded = false
    private var representation = Representation.undecided
    private let onAcceptedBytes: (@Sendable (Int) -> Void)?
    private var continuation: CheckedContinuation<Data, Error>?
    private var responseError: Error?
    private var body = Data()
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var finished = false
    private var cancelled = false

    init(maximumBytes: Int, maximumDecodedBytes: Int, onAcceptedBytes: (@Sendable (Int) -> Void)?) {
        self.maximumBytes = maximumBytes
        self.maximumDecodedBytes = maximumDecodedBytes
        self.onAcceptedBytes = onAcceptedBytes
    }

    func start(_ request: URLRequest, session: URLSession, continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        self.continuation = continuation
        self.session = session
        let shouldCancel = cancelled
        lock.unlock()
        guard !shouldCancel else { finish(.failure(CancellationError())); return }
        let task = session.dataTask(with: request)
        lock.lock()
        self.task = task
        let cancelledBeforeResume = cancelled
        lock.unlock()
        if cancelledBeforeResume { task.cancel() } else { task.resume() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            let codings = (http.value(forHTTPHeaderField: "Content-Encoding") ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty && $0 != "identity" }
            isTransportDecoded = !codings.isEmpty && codings.allSatisfy(Self.decodedCodings.contains)
        }
        // For a content-coded response the declared length is the compressed transfer, which stays
        // under the download cap.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            responseError = EPGError.providerRejected
            completionHandler(.cancel)
        } else if response.expectedContentLength > Int64(maximumBytes) {
            responseError = EPGError.responseTooLarge
            completionHandler(.cancel)
        } else if !(response is HTTPURLResponse) {
            responseError = EPGError.providerRejected
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if representation == .undecided {
            representation = isTransportDecoded ? Self.classify(data, atStart: body.isEmpty) : .other
        }
        let limit = representation == .decodedXML ? maximumDecodedBytes : maximumBytes
        guard body.count <= limit - data.count else {
            responseError = EPGError.responseTooLarge
            dataTask.cancel()
            return
        }
        body.append(data)
        onAcceptedBytes?(body.count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let responseError { finish(.failure(responseError)); return }
        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled || (error as? URLError)?.code == .cancelled { finish(.failure(CancellationError())); return }
        if error != nil { finish(.failure(EPGError.providerRejected)); return }
        finish(.success(body))
    }

    /// XML text after an optional UTF-8 byte-order mark and whitespace; undecided until a
    /// significant byte arrives, and the download cap applies meanwhile. While undecided the body
    /// holds only whitespace, so each chunk is classified on its own without copying the body.
    private static func classify(_ chunk: Data, atStart: Bool) -> Representation {
        var bytes = chunk[...]
        if atStart, bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard let first = bytes.first(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }) else { return .undecided }
        return first == UInt8(ascii: "<") ? .decodedXML : .other
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        continuation?.resume(with: result)
        session?.finishTasksAndInvalidate()
    }
}

/// Identifies one Xtream short-guide request. It is issued before the request leaves the device and
/// is honoured only if the provider's source and generation are unchanged, no full guide has been
/// published since, and no newer request for the same channel has already been applied.
struct EPGShortRequestTicket: Sendable, Equatable {
    fileprivate let providerID: UUID
    fileprivate let generation: Int
    fileprivate let publication: Int
    fileprivate let channelKey: String
    fileprivate let sequence: Int
}

struct EPGShortGuideRetentionStats: Equatable, Sendable {
    let overlayCount: Int
    let programmeCount: Int
}

struct EPGShortGuideApplyResult: Sendable {
    let index: EPGIndex
    let evictedGuideIDs: [String]
}

/// Owns every provider's guide: loads it from cache, refreshes it from the feed, and answers
/// freshness questions.
///
/// - One refresh runs per provider; concurrent callers share it. The shared work is cancelled
///   only when every caller waiting on it has been cancelled.
/// - Downloading, decompression, parsing, indexing and cache I/O run in nonisolated async
///   functions, so they leave the actor free for lookups without detaching from the caller's task.
/// - A failed or cancelled refresh never replaces a usable guide or the cache.
/// - Removing a provider discards any refresh still in flight for it.
actor EPGService {
    private struct RetryFailure {
        let source: EPGFeedSource
        let sourceFingerprint: Data?
        let count: Int
        let nextRetryAt: Date
    }

    private struct Flight {
        let id: UUID
        let source: EPGFeedSource
        let sourceFingerprint: Data?
        let generation: Int
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<EPGIndex, Error>] = [:]
    }

    private let cache: EPGCacheStore?
    private let loader: any EPGFeedLoading
    private let fingerprinter: EPGSourceFingerprinter
    nonisolated let policy: EPGRefreshPolicy
    nonisolated let limits: EPGLimits
    /// `.memory` (the default) keeps today's in-memory index and v2 cache. `.sqlite` builds and
    /// restores guides through SQLite and falls back to the memory path whenever SQLite fails.
    nonisolated let storage: EPGStorageMode
    nonisolated let sqliteReadPolicy: EPGSQLiteReadPolicy
    private let now: @Sendable () -> Date

    private var indexes: [UUID: EPGIndex] = [:]
    /// In-memory guides are visible only to the exact source that was fetched or verified.
    private var indexSources: [UUID: EPGFeedSource] = [:]
    private var requestedSources: [UUID: EPGFeedSource] = [:]
    private var flights: [UUID: Flight] = [:]
    private var failures: [UUID: RetryFailure] = [:]
    private var cacheStates: [UUID: EPGCacheState] = [:]
    /// The persisted retry state load for each provider, at most one per process and source.
    private var stateLoads: [UUID: (fingerprint: Data, task: Task<Void, Never>)] = [:]
    /// Disk operations for one provider, chained so they run in order: writes, and state reads
    /// whose cleanup could otherwise remove a newer file.
    private var pendingWrites: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]
    private var orphanSweepTask: Task<Void, Never>?
    private var checkedCache = [UUID: Data]()
    /// The validated v2 header of the guide `loadCached` accepted, so the retry-state read can
    /// check that the file is unchanged instead of decoding the whole guide a second time.
    private var verifiedCacheHeaders: [UUID: EPGCacheFormat.Header] = [:]
    private let diskGenerationGate = EPGDiskGenerationGate()
    /// Bumped on removal so work that started before it cannot restore the provider's guide.
    private var generations: [UUID: Int] = [:]
    /// Provider UUIDs are unique and never reused. Once removed, no delayed caller may revive it.
    private var removedProviders = Set<UUID>()
    private var clearingProviders = Set<UUID>()
    /// Short-guide listings applied this process, by guide channel key. They are newer than a cached
    /// guide for the hours they cover, so they are reapplied when one loads; a full refresh supersedes them.
    private var shortGuides: [UUID: [String: (guideID: String, programs: [EPGProgram])]] = [:]
    /// Most-recently-viewed overlay keys, one bounded list per provider.
    private var shortGuideAccess: [UUID: [String]] = [:]
    static let shortGuideRetentionCapacity = 256
    /// Incremented by every successful full publication. A short request issued before it is stale.
    private var publications: [UUID: Int] = [:]
    private var shortRequestSequence: [UUID: Int] = [:]
    /// The newest short request applied for each channel. An older response for that channel is dropped.
    private var appliedShortSequence: [UUID: [String: Int]] = [:]
#if DEBUG
    /// Acknowledges invalidation before waiting for disk work; tests must not guess actor scheduling.
    private var generationInvalidationObserver: (@Sendable () -> Void)?
    func observeGenerationInvalidation(_ observer: @escaping @Sendable () -> Void) {
        generationInvalidationObserver = observer
    }
#endif

    private var lastCacheWriteDiagnostic: Date?
    private static let cacheLogger = Logger(subsystem: "com.cubbiestream.kyro", category: "EPGCache")

    init(cache: EPGCacheStore?, loader: any EPGFeedLoading, fingerprinter: EPGSourceFingerprinter = EPGSourceFingerprinter(),
         policy: EPGRefreshPolicy = EPGRefreshPolicy(),
         limits: EPGLimits = EPGLimits(), storage: EPGStorageMode = .memory,
         sqliteReadPolicy: EPGSQLiteReadPolicy = .cachedOnly, now: @escaping @Sendable () -> Date = { Date() }) {
        self.storage = storage
        self.sqliteReadPolicy = sqliteReadPolicy
        self.cache = cache
        self.loader = loader
        self.fingerprinter = fingerprinter
        self.policy = policy
        self.limits = limits
        self.now = now
    }

    /// The guide in memory, else the cached one, if it is still usable.
    func index(for providerID: UUID) async -> EPGIndex? {
        // Source-less callers may use only a full guide already established by a refresh this process.
        // Short-guide listings are visible through the source-aware lookup, but they are not that guide.
        guard !removedProviders.contains(providerID), !clearingProviders.contains(providerID),
              let index = fullGuide(providerID), indexSources[providerID] != nil,
              policy.freshness(of: index, now: now()).isUsable else { return nil }
        return index
    }

    /// Source-aware cached-first read. When Keychain is unavailable, disk data is not shown;
    /// already verified in-memory data for this exact source remains usable during the outage.
    func index(for providerID: UUID, source: EPGFeedSource) async -> EPGIndex? {
        guard !removedProviders.contains(providerID), !clearingProviders.contains(providerID) else { return nil }
        activateSource(source, for: providerID)
        if let index = indexes[providerID], !index.isShortGuideOnly, indexSources[providerID] == source,
           policy.freshness(of: index, now: now()).isUsable { return index }
        // Without a fingerprint only the verified in-memory guide, possibly short-guide-only, is usable.
        if let fingerprint = try? fingerprinter.fingerprint(for: source).bytes {
            await loadCached(providerID, source: source, fingerprint: fingerprint)
        }
        guard let index = indexes[providerID], indexSources[providerID] == source,
              policy.freshness(of: index, now: now()).isUsable else { return nil }
        return index
    }

    /// Callers currently waiting on the provider's refresh. For diagnostics and tests.
    func waiterCount(for providerID: UUID) -> Int {
        flights[providerID]?.waiters.count ?? 0
    }

    func freshness(for providerID: UUID) -> EPGFreshness {
        // Short-guide listings do not make the full guide fresh, missing, or expired.
        fullGuide(providerID).map { policy.freshness(of: $0, now: now()) } ?? .missing
    }

    /// One-time startup cleanup for providers removed while the app was not running.
    func removeOrphanedCacheFiles(keeping providerIDs: Set<UUID>) async {
        guard let cache else { return }
        let priorSweep = orphanSweepTask
        let writes = pendingWrites.values.map(\.task)
        let sweep = Task {
            await priorSweep?.value
            for write in writes { await write.value }
            await Self.sweepCache(cache, keeping: providerIDs)
        }
        orphanSweepTask = sweep
        await sweep.value
    }

    /// A fresh guide for the provider, downloading it only when the policy says it is due.
    ///
    /// - Parameters:
    ///   - channels: the playlist's channels, so only listings the playlist can show are kept.
    ///   - force: refresh even when the guide is fresh or a recent failure is backing off.
    func refresh(providerID: UUID, source: EPGFeedSource, channels: EPGChannelFilter? = nil,
                 force: Bool = false) async throws -> EPGIndex {
        guard !removedProviders.contains(providerID), !clearingProviders.contains(providerID) else { throw CancellationError() }
        activateSource(source, for: providerID)
        // Keychain failures disable persisted identity/retry state, not the network refresh.
        let fingerprint = try? fingerprinter.fingerprint(for: source).bytes
        let generation = generations[providerID, default: 0]
        // A current in-memory failure is newer than queued disk state. Avoid blocking a caller on
        // cache I/O when backoff already answers the request (and preserve ordered state writes).
        if !force, flights[providerID] == nil,
           isBackingOff(providerID, fingerprint: fingerprint, source: source) {
            if let current = fullGuide(providerID), policy.freshness(of: current, now: now()).isUsable {
                return current
            }
            throw EPGError.providerRejected
        }
        if fullGuide(providerID) == nil, let fingerprint {
            await loadCached(providerID, source: source, fingerprint: fingerprint)
        }
        guard generations[providerID, default: 0] == generation else { throw CancellationError() }
        if let fingerprint {
            if failures[providerID]?.sourceFingerprint != fingerprint { failures[providerID] = nil }
            await loadPersistedState(providerID, fingerprint: fingerprint, source: source, generation: generation)
            guard generations[providerID, default: 0] == generation else { throw CancellationError() }
        }
        if !force, flights[providerID] == nil {
            let current = fullGuide(providerID)
            let freshness = current.map { policy.freshness(of: $0, now: now()) } ?? .missing
            if freshness == .fresh, let current { return current }
            // A feed that just failed is not refetched on every visit, whatever the guide's state.
            if isBackingOff(providerID, fingerprint: fingerprint, source: source) {
                if freshness.isUsable, let current { return current }
                throw EPGError.providerRejected
            }
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                join(providerID, waiterID: waiterID, continuation: continuation, source: source,
                     sourceFingerprint: fingerprint, generation: generation, channels: channels)
            }
        } onCancel: {
            Task { await self.leave(providerID, waiterID: waiterID) }
        }
    }

    /// Issues a ticket for one Xtream short-guide request. Call it before the request is sent.
    /// Returns nil when the provider is removed or the guide id has no channel key.
    func beginShortRequest(providerID: UUID, source: EPGFeedSource, guideID: String) -> EPGShortRequestTicket? {
        guard !removedProviders.contains(providerID), !clearingProviders.contains(providerID) else { return nil }
        activateSource(source, for: providerID)
        guard let key = EPGChannelKey.guideID(guideID) else { return nil }
        let sequence = shortRequestSequence[providerID, default: 0] + 1
        shortRequestSequence[providerID] = sequence
        return EPGShortRequestTicket(providerID: providerID, generation: generations[providerID, default: 0],
                                     publication: publications[providerID, default: 0],
                                     channelKey: key, sequence: sequence)
    }

    /// Applies a short-guide response if its ticket is still current. A response is rejected when
    /// the provider was removed or its source changed, when a full guide was published after the
    /// request started, when a newer request for the same channel has already been applied, or
    /// when the calling task is cancelled. Cancellation is checked here, inside the actor, so a
    /// response cancelled after its download but before publication cannot be applied.
    /// Rejection changes nothing. Not persisted: the next full refresh supersedes it.
    func applyShortPrograms(_ programs: [EPGProgram], guideID: String,
                            ticket: EPGShortRequestTicket) -> EPGIndex? {
        applyShortProgramsWithRetention(programs, guideID: guideID, ticket: ticket)?.index
    }

    func applyShortProgramsWithRetention(_ programs: [EPGProgram], guideID: String,
                                         ticket: EPGShortRequestTicket) -> EPGShortGuideApplyResult? {
        let providerID = ticket.providerID
        guard !Task.isCancelled,
              !removedProviders.contains(providerID), !clearingProviders.contains(providerID),
              generations[providerID, default: 0] == ticket.generation,
              publications[providerID, default: 0] == ticket.publication,
              EPGChannelKey.guideID(guideID) == ticket.channelKey,
              ticket.sequence > appliedShortSequence[providerID]?[ticket.channelKey] ?? 0,
              let source = requestedSources[providerID] else { return nil }
        // An expired guide is not a base: newer listings would otherwise stay hidden behind its age.
        // Without a full guide the result is short-guide-only, so it never stands in for one.
        let base = indexes[providerID].flatMap { policy.freshness(of: $0, now: now()).isUsable ? $0 : nil }
            ?? .shortGuideBase(fetchedAt: now())
        let updated = base.replacingPrograms(programs, guideID: guideID, now: now(), limits: limits)
        indexes[providerID] = updated
        indexSources[providerID] = source
        shortGuides[providerID, default: [:]][ticket.channelKey] = (guideID, programs)
        let evictedGuideID = retainShortGuide(providerID: providerID, channelKey: ticket.channelKey)
        appliedShortSequence[providerID, default: [:]][ticket.channelKey] = ticket.sequence
        return EPGShortGuideApplyResult(index: indexes[providerID] ?? updated,
                                        evictedGuideIDs: evictedGuideID.map { [$0] } ?? [])
    }

    func shortGuideRetentionStats(providerID: UUID) -> EPGShortGuideRetentionStats {
        let overlays = shortGuides[providerID] ?? [:]
        return EPGShortGuideRetentionStats(overlayCount: overlays.count,
                                           programmeCount: overlays.values.reduce(0) { $0 + $1.programs.count })
    }

    /// Distinguishes a fresh retained overlay from one evicted from this bounded process-local store.
    func hasShortGuide(providerID: UUID, guideID: String) -> Bool {
        guard let key = EPGChannelKey.guideID(guideID), shortGuides[providerID]?[key] != nil else {
            return false
        }
        _ = retainShortGuide(providerID: providerID, channelKey: key)
        return true
    }

    /// Issues a ticket and applies the response immediately. Only safe when no await separates
    /// the request from the response; otherwise use `beginShortRequest` and `applyShortPrograms`.
    func replacePrograms(_ programs: [EPGProgram], guideID: String, providerID: UUID,
                         source: EPGFeedSource) -> EPGIndex? {
        guard let ticket = beginShortRequest(providerID: providerID, source: source, guideID: guideID) else {
            return nil
        }
        return applyShortPrograms(programs, guideID: guideID, ticket: ticket)
    }

    /// Forgets the provider's guide, cancels its refresh and deletes its cache file.
    func remove(providerID: UUID) async {
        removedProviders.insert(providerID)
        await clearProviderData(providerID)
    }

    /// Drops a guide for a still-configured provider that currently has no EPG source.
    func clear(providerID: UUID) async {
        guard !removedProviders.contains(providerID) else { return }
        clearingProviders.insert(providerID)
        await clearProviderData(providerID)
        clearingProviders.remove(providerID)
    }

    private func clearProviderData(_ providerID: UUID) async {
        if let flight = flights.removeValue(forKey: providerID) {
            flight.task?.cancel()
            for continuation in flight.waiters.values { continuation.resume(throwing: CancellationError()) }
        }
        indexes[providerID] = nil
        indexSources[providerID] = nil
        shortGuides[providerID] = nil
        shortGuideAccess[providerID] = nil
        appliedShortSequence[providerID] = nil
        shortRequestSequence[providerID] = nil
        failures[providerID] = nil
        cacheStates[providerID] = nil
        stateLoads[providerID] = nil
        checkedCache[providerID] = nil
        verifiedCacheHeaders[providerID] = nil
        generations[providerID, default: 0] += 1
        diskGenerationGate.set(providerID, generation: generations[providerID, default: 0])
#if DEBUG
        generationInvalidationObserver?()
#endif
        if let write = pendingWrites.removeValue(forKey: providerID) { await write.task.value }
        await orphanSweepTask?.value
        if let cache { await Self.removeCache(cache, providerID: providerID) }
    }

    // MARK: - Refresh flights

    private func join(_ providerID: UUID, waiterID: UUID, continuation: CheckedContinuation<EPGIndex, Error>,
                      source: EPGFeedSource, sourceFingerprint: Data?, generation: Int,
                      channels: EPGChannelFilter?) {
        if flights[providerID] != nil {
            flights[providerID]?.waiters[waiterID] = continuation
            return
        }
        let flightID = UUID()
        flights[providerID] = Flight(id: flightID, source: source, sourceFingerprint: sourceFingerprint,
                                     generation: generation, waiters: [waiterID: continuation])
        let loader = loader, limits = limits, fetchedAt = now()
        let sqlitePlan = sqliteBuildPlan(providerID: providerID, fingerprint: sourceFingerprint)
        flights[providerID]?.task = Task {
            let result: Result<EPGIndex, Error>
            do {
                result = .success(try await Self.build(source: source, channels: channels, loader: loader,
                                                       limits: limits, fetchedAt: fetchedAt, sqlite: sqlitePlan))
            } catch {
                result = .failure(error)
            }
            self.complete(providerID, flightID: flightID, result: result)
        }
    }

    private func complete(_ providerID: UUID, flightID: UUID, result: Result<EPGIndex, Error>) {
        // A removed provider or superseded flight must not publish late results.
        guard let flight = flights[providerID], flight.id == flightID else { return }
        flights[providerID] = nil
        switch result {
        case .success(let index):
            indexes[providerID] = index
            indexSources[providerID] = flight.source
            // The full guide supersedes every short-guide overlay and every short request still in flight.
            shortGuides[providerID] = nil
            shortGuideAccess[providerID] = nil
            publications[providerID, default: 0] += 1
            failures[providerID] = nil
            if let fingerprint = flight.sourceFingerprint {
                let fresh = EPGCacheState(providerID: providerID, sourceFingerprint: fingerprint,
                                          lastSuccessfulFetchAt: index.fetchedAt)
                cacheStates[providerID] = fresh
                // Cache v2 has no completeness bit. Keep partial results in memory, but don't
                // persist them as a successful complete feed that would look healthy next launch.
                if !index.statistics.incomplete {
                    persist(index, fingerprint: fingerprint, providerID: providerID, generation: flight.generation)
                }
            }
            // A SQLite guide that will not be promoted (incomplete feed, no fingerprint, no cache) must not
            // leave its stage on disk: unlinking keeps the open connection readable and a crash leaves nothing.
            let willPersist = cache != nil && flight.sourceFingerprint != nil && !index.statistics.incomplete
            if let sqlite = index.sqlite, !willPersist { try? FileManager.default.removeItem(at: sqlite.guide.url) }
            for continuation in flight.waiters.values { continuation.resume(returning: index) }
        case .failure(let error):
            if !(error is CancellationError) {
                if let fingerprint = flight.sourceFingerprint {
                    let prior = failures[providerID].flatMap { $0.sourceFingerprint == fingerprint ? $0.count : nil } ?? 0
                    let count = min(EPGCacheState.maximumFailureCount, prior + 1)
                    let nextRetryAt = now().addingTimeInterval(policy.retryDelay(afterFailures: count))
                    failures[providerID] = RetryFailure(source: flight.source, sourceFingerprint: fingerprint, count: count,
                                                        nextRetryAt: nextRetryAt)
                    let previous = cacheStates[providerID].flatMap {
                        $0.sourceFingerprint == fingerprint ? $0.lastSuccessfulFetchDate : nil
                    }
                    let linkedContentID = cacheStates[providerID].flatMap {
                        $0.sourceFingerprint == fingerprint ? $0.contentID : nil
                    }
                    let state = EPGCacheState(providerID: providerID, sourceFingerprint: fingerprint,
                                              contentID: linkedContentID,
                                              lastSuccessfulFetchAt: previous, failureCount: count,
                                              nextRetryAt: nextRetryAt)
                    cacheStates[providerID] = state
                    persistState(state, generation: flight.generation)
                } else {
                    // Retain process-local backoff if Keychain is temporarily unavailable.
                    let prior = failures[providerID]?.count ?? 0
                    let count = min(EPGCacheState.maximumFailureCount, prior + 1)
                    failures[providerID] = RetryFailure(source: flight.source, sourceFingerprint: nil, count: count,
                        nextRetryAt: now().addingTimeInterval(policy.retryDelay(afterFailures: count)))
                }
            }
            for continuation in flight.waiters.values { continuation.resume(throwing: error) }
        }
    }

    private func leave(_ providerID: UUID, waiterID: UUID) {
        guard var flight = flights[providerID], let continuation = flight.waiters.removeValue(forKey: waiterID) else {
            return
        }
        continuation.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flight.task?.cancel()
            flights[providerID] = nil
        } else {
            flights[providerID] = flight
        }
    }

    private func isBackingOff(_ providerID: UUID, fingerprint: Data?, source: EPGFeedSource) -> Bool {
        guard let failure = failures[providerID] else { return false }
        if let fingerprint {
            guard failure.sourceFingerprint == fingerprint else { return false }
        } else {
            guard failure.source == source else { return false }
        }
        return now() < failure.nextRetryAt
    }

    // MARK: - Cache

    /// Loads the verified cached guide unless a full guide is already in memory. A short-guide-only
    /// index does not block it; its listings are reapplied on top of the cached guide.
    private func loadCached(_ providerID: UUID, source: EPGFeedSource, fingerprint: Data) async {
        guard let cache, checkedCache[providerID] != fingerprint else { return }
        let generation = generations[providerID, default: 0]
        let read = enqueueCacheRead(cache, providerID: providerID, fingerprint: fingerprint, generation: generation)
        guard let cached = await read.value else { return }
        // A refresh may have finished, or the provider been removed, while the file was read.
        guard fullGuide(providerID) == nil, generations[providerID, default: 0] == generation else { return }
        checkedCache[providerID] = fingerprint
        verifiedCacheHeaders[providerID] = cached.header
        indexes[providerID] = applyingShortGuides(to: cached.index, providerID: providerID)
        indexSources[providerID] = source
    }

    /// The in-memory guide only when it is a full guide, not short-guide listings alone.
    private func fullGuide(_ providerID: UUID) -> EPGIndex? {
        indexes[providerID].flatMap { $0.isShortGuideOnly ? nil : $0 }
    }

    private func applyingShortGuides(to index: EPGIndex, providerID: UUID) -> EPGIndex {
        (shortGuides[providerID] ?? [:]).values.reduce(index) {
            $0.replacingPrograms($1.programs, guideID: $1.guideID, now: now(), limits: limits)
        }
    }

    private func retainShortGuide(providerID: UUID, channelKey: String) -> String? {
        var access = shortGuideAccess[providerID] ?? []
        access.removeAll { $0 == channelKey }
        access.insert(channelKey, at: 0)
        guard access.count > Self.shortGuideRetentionCapacity,
              let evicted = access.popLast() else {
            shortGuideAccess[providerID] = access
            return nil
        }
        shortGuideAccess[providerID] = access
        let evictedGuideID = shortGuides[providerID]?[evicted]?.guideID
        shortGuides[providerID]?.removeValue(forKey: evicted)
        if shortGuides[providerID]?.isEmpty == true { shortGuides[providerID] = nil }
        // A short-only index has no durable base listing to preserve. Full-guide overlays remain
        // backed by XMLTV and are therefore removed only from the retention map.
        if let evictedGuideID, let index = indexes[providerID], index.isShortGuideOnly {
            indexes[providerID] = index.removingPrograms(guideID: evictedGuideID)
        }
        return evictedGuideID
    }

    /// Explicit Stage D integration point. It is deliberately never called by startup or cache reads.
    /// Provider source is fixed for this operation; source changes or removal advance the generation
    /// and invalidate every boundary callback.
    func migrateLegacyCache(providerID: UUID, source: EPGFeedSource) async -> Bool {
        guard !removedProviders.contains(providerID), !clearingProviders.contains(providerID) else { return false }
        activateSource(source, for: providerID)
        guard let cache, let fingerprint = try? fingerprinter.fingerprint(for: source).bytes else { return false }
        let generation = generations[providerID, default: 0]
        let previous = pendingWrites[providerID]?.task
        let priorSweep = orphanSweepTask
        let id = UUID()
        let guardToken = diskGenerationGate
        let fingerprinter = self.fingerprinter
        let operation = Task<Bool, Never> {
            await priorSweep?.value
            await previous?.value
            guard self.canWrite(providerID: providerID, generation: generation) else {
                self.finishWrite(providerID, writeID: id)
                return false
            }
            let valid: @Sendable () -> Bool = {
                guard guardToken.isCurrent(providerID, generation: generation) else { return false }
                return fingerprinter.check(stored: fingerprint, against: source) == .matches
            }
            let result = await Task.detached {
                cache.migrate(providerID: providerID, fingerprint: fingerprint, isCurrent: valid)
            }.value
            self.finishWrite(providerID, writeID: id)
            return result
        }
        pendingWrites[providerID] = (id, Task { _ = await operation.value })
        return await operation.value
    }

    private func enqueueCacheRead(_ cache: EPGCacheStore, providerID: UUID, fingerprint: Data,
                                  generation: Int) -> Task<EPGCacheStore.VerifiedGuide?, Never> {
        let previous = pendingWrites[providerID]?.task
        let priorSweep = orphanSweepTask
        let id = UUID()
        let read = Task<EPGCacheStore.VerifiedGuide?, Never> {
            await priorSweep?.value
            await previous?.value
            guard self.canWrite(providerID: providerID, generation: generation) else { return nil }
            let gate = self.diskGenerationGate
            return await Self.readVerifiedCache(cache, providerID: providerID, fingerprint: fingerprint,
                                                storage: self.storage, readPolicy: self.sqliteReadPolicy,
                                                isCurrent: { gate.isCurrent(providerID, generation: generation) })
        }
        pendingWrites[providerID] = (id, Task {
            _ = await read.value
            self.finishWrite(providerID, writeID: id)
        })
        return read
    }

    /// Seeds retry state from disk once per process and source; concurrent callers share the load.
    /// Disk never replaces a success or failure this process already recorded, since that is newer.
    private func loadPersistedState(_ providerID: UUID, fingerprint: Data, source: EPGFeedSource,
                                    generation: Int) async {
        guard let cache else { return }
        if let load = stateLoads[providerID], load.fingerprint == fingerprint { return await load.task.value }
        let read = enqueueStateRead(cache, providerID: providerID, fingerprint: fingerprint, generation: generation)
        let load = Task {
            let state = await read.value
            guard let state, self.canWrite(providerID: providerID, generation: generation),
                  self.failures[providerID] == nil,
                  self.cacheStates[providerID].map({ $0.sourceFingerprint != fingerprint }) ?? true else { return }
            self.cacheStates[providerID] = state
            if state.failureCount > 0, let nextRetryAt = state.nextRetryDate {
                self.failures[providerID] = RetryFailure(source: source, sourceFingerprint: fingerprint,
                                                         count: state.failureCount, nextRetryAt: nextRetryAt)
            }
        }
        stateLoads[providerID] = (fingerprint, load)
        await load.value
    }

    /// Reads state behind every queued operation for the provider, so the read's cleanup of an
    /// invalid file can never remove one written after it was judged invalid.
    private func enqueueStateRead(_ cache: EPGCacheStore, providerID: UUID, fingerprint: Data,
                                  generation: Int) -> Task<EPGCacheState?, Never> {
        let previous = pendingWrites[providerID]?.task
        let priorSweep = orphanSweepTask
        let operationID = UUID()
        // Only a hint: the store uses it only if the file on disk is still byte-for-byte that guide.
        let verifiedHeader = verifiedCacheHeaders[providerID]
        let read = Task<EPGCacheState?, Never> {
            await priorSweep?.value
            await previous?.value
            guard self.canWrite(providerID: providerID, generation: generation) else { return nil }
            return await Self.readState(cache, providerID: providerID, fingerprint: fingerprint,
                                        verifiedHeader: verifiedHeader)
        }
        pendingWrites[providerID] = (operationID, Task {
            _ = await read.value
            self.finishWrite(providerID, writeID: operationID)
        })
        return read
    }

    // Persistence is independently queued after publication. Cancelling a refresh waiter does not
    // cancel this task. Generation invalidation aborts before the promotion admission check; once
    // admitted, promotion may finish. Guide promotion and state writing are not one transaction.
    private func persist(_ index: EPGIndex, fingerprint: Data, providerID: UUID, generation: Int) {
        guard let cache else { return }
        let previous = pendingWrites[providerID]?.task
        let priorSweep = orphanSweepTask
        let writeID = UUID()
        // Writes for one provider run in order, so an older guide never lands on top of a newer one.
        pendingWrites[providerID] = (writeID, Task {
            await priorSweep?.value
            await previous?.value
            guard self.canWrite(providerID: providerID, generation: generation) else {
                self.finishWrite(providerID, writeID: writeID)
                return
            }
            let gate = self.diskGenerationGate
            if let sqlite = index.sqlite {
                // SQLite identity lives in the file itself; the state stays unlinked, which the
                // state reader accepts without a v2 file.
                if await Self.promoteSQLite(cache, stage: sqlite.guide.url, guide: sqlite.guide, providerID: providerID,
                                            isCurrent: { gate.isCurrent(providerID, generation: generation) }) {
                    let state = EPGCacheState(providerID: providerID, sourceFingerprint: fingerprint,
                                              lastSuccessfulFetchAt: index.fetchedAt)
                    if !(await Self.writeState(cache, state: state)) {
                        self.recordCacheWriteFailure("state metadata write")
                    }
                } else if self.canWrite(providerID: providerID, generation: generation) {
                    self.recordCacheWriteFailure("SQLite guide write")
                }
            } else if let contentID = await Self.writeV2Cache(cache, index: index, providerID: providerID,
                                                       fingerprint: fingerprint,
                                                       isCurrent: { gate.isCurrent(providerID, generation: generation) }) {
                let state = EPGCacheState(providerID: providerID, sourceFingerprint: fingerprint,
                                          contentID: contentID, lastSuccessfulFetchAt: index.fetchedAt)
                if !(await Self.writeState(cache, state: state)) {
                    self.recordCacheWriteFailure("state metadata write")
                } else if self.canWrite(providerID: providerID, generation: generation) {
                    self.linkInMemoryState(providerID, fingerprint: fingerprint, fetchedAt: index.fetchedAt,
                                           contentID: contentID)
                }
            } else if self.canWrite(providerID: providerID, generation: generation) {
                // A write abandoned for a removed provider or a changed source is not a failure.
                self.recordCacheWriteFailure("v2 guide write")
            }
            self.finishWrite(providerID, writeID: writeID)
        })
    }

    private func persistState(_ state: EPGCacheState, generation: Int) {
        guard let cache else { return }
        let previous = pendingWrites[state.providerID]?.task
        let priorSweep = orphanSweepTask
        let writeID = UUID()
        pendingWrites[state.providerID] = (writeID, Task {
            await priorSweep?.value
            await previous?.value
            guard self.canWrite(providerID: state.providerID, generation: generation) else {
                self.finishWrite(state.providerID, writeID: writeID)
                return
            }
            let resolved = self.linkedForWrite(state)
            if !(await Self.writeState(cache, state: resolved)) { self.recordCacheWriteFailure("state metadata write") }
            self.finishWrite(state.providerID, writeID: writeID)
        })
    }

    /// Links the written guide's content ID into the in-memory state for that same success. A
    /// failure recorded while the guide was being written is newer and keeps its retry fields; a
    /// later success is never overwritten by this older one.
    private func linkInMemoryState(_ providerID: UUID, fingerprint: Data, fetchedAt: Date, contentID: UUID) {
        guard let current = cacheStates[providerID], current.sourceFingerprint == fingerprint,
              current.lastSuccessfulFetchDate == fetchedAt, current.contentID == nil else { return }
        cacheStates[providerID] = current.linked(to: contentID)
    }

    /// A failure state captured before its guide's write finished carries no content ID. If memory
    /// has since linked exactly that state to the written guide, persist the linked form.
    private func linkedForWrite(_ state: EPGCacheState) -> EPGCacheState {
        guard state.contentID == nil, let current = cacheStates[state.providerID],
              let contentID = current.contentID, current.sourceFingerprint == state.sourceFingerprint,
              current.lastSuccessfulFetchAt == state.lastSuccessfulFetchAt,
              current.failureCount == state.failureCount, current.nextRetryAt == state.nextRetryAt else {
            return state
        }
        return state.linked(to: contentID)
    }

    private func canWrite(providerID: UUID, generation: Int) -> Bool {
        generations[providerID, default: 0] == generation
    }

    /// Rate-limited static diagnostics only: never log a source URL, username, password, or error
    /// description supplied by a transport/filesystem implementation.
    private func recordCacheWriteFailure(_ operation: String) {
        let instant = now()
        guard lastCacheWriteDiagnostic.map({ instant.timeIntervalSince($0) >= 300 }) ?? true else { return }
        lastCacheWriteDiagnostic = instant
        Self.cacheLogger.error("EPG cache \(operation, privacy: .public) failed; guide and state are persisted separately")
    }

    private func activateSource(_ source: EPGFeedSource, for providerID: UUID) {
        guard let prior = requestedSources[providerID], prior != source else {
            requestedSources[providerID] = source
            return
        }
        generations[providerID, default: 0] += 1
        diskGenerationGate.set(providerID, generation: generations[providerID, default: 0])
#if DEBUG
        generationInvalidationObserver?()
#endif
        if let flight = flights.removeValue(forKey: providerID) {
            flight.task?.cancel()
            for waiter in flight.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
        indexes[providerID] = nil
        indexSources[providerID] = nil
        shortGuides[providerID] = nil
        shortGuideAccess[providerID] = nil
        checkedCache[providerID] = nil
        verifiedCacheHeaders[providerID] = nil
        failures[providerID] = nil
        requestedSources[providerID] = source
    }

    private func finishWrite(_ providerID: UUID, writeID: UUID) {
        if pendingWrites[providerID]?.id == writeID { pendingWrites[providerID] = nil }
    }

    // MARK: - Off-actor work

    private struct SQLiteBuildPlan: Sendable {
        let providerID: UUID
        let fingerprint: Data
        let cache: EPGCacheStore?
        let readPolicy: EPGSQLiteReadPolicy
    }

    private func sqliteBuildPlan(providerID: UUID, fingerprint: Data?) -> SQLiteBuildPlan? {
        guard storage == .sqlite else { return nil }
        return SQLiteBuildPlan(providerID: providerID, fingerprint: fingerprint ?? Data(repeating: 0, count: 32),
                               cache: cache, readPolicy: sqliteReadPolicy)
    }

    private nonisolated static func build(source: EPGFeedSource, channels: EPGChannelFilter?,
                                          loader: any EPGFeedLoading, limits: EPGLimits,
                                          fetchedAt: Date, sqlite: SQLiteBuildPlan?) async throws -> EPGIndex {
        let url = try source.feedURL()
        let download = try await loader.load(url, maximumBytes: limits.maximumDownloadBytes,
                                             maximumDecodedBytes: limits.maximumXMLBytes)
        try Task.checkCancellation()
        let xml = try EPGPayloadDecoder.xmlData(from: download, maximumBytes: limits.maximumXMLBytes)
        try Task.checkCancellation()
        if let sqlite {
            do {
                return try buildSQLite(xml: xml, channels: channels, limits: limits, fetchedAt: fetchedAt, plan: sqlite)
            } catch let error where error is CancellationError || error is EPGError {
                throw error
            } catch {
                // Disk full, SQLite failure, unwritable directory: the same feed builds in memory.
                cacheLogger.error("EPG SQLite build failed; using the in-memory index")
            }
        }
        let window = DateInterval(start: fetchedAt.addingTimeInterval(-limits.pastRetention),
                                  end: fetchedAt.addingTimeInterval(limits.futureHorizon))
        let document = try XMLTVParser.parse(xml, filter: channels, window: window, limits: limits)
        try Task.checkCancellation()
        return try EPGIndex(document: document, fetchedAt: fetchedAt, now: fetchedAt, limits: limits)
    }

    private nonisolated static func buildSQLite(xml: Data, channels: EPGChannelFilter?, limits: EPGLimits,
                                                fetchedAt: Date, plan: SQLiteBuildPlan) throws -> EPGIndex {
        let stage = try plan.cache?.sqliteStageURL(providerID: plan.providerID)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).stage")
        let built = try EPGSQLiteBuilder.build(xml: xml, filter: channels, limits: limits, fetchedAt: fetchedAt,
                                               providerID: plan.providerID, fingerprint: plan.fingerprint,
                                               destination: stage, readPolicy: plan.readPolicy)
        return EPGIndex(sqlite: built.index, statistics: built.statistics)
    }

    private nonisolated static func readVerifiedCache(_ cache: EPGCacheStore, providerID: UUID,
                                                      fingerprint: Data, storage: EPGStorageMode,
                                                      readPolicy: EPGSQLiteReadPolicy,
                                                      isCurrent: @Sendable () -> Bool) async -> EPGCacheStore.VerifiedGuide? {
        cache.loadVerifiedGuide(providerID: providerID, fingerprint: fingerprint, preferSQLite: storage == .sqlite,
                                sqliteReadPolicy: readPolicy, isCurrent: isCurrent)
    }

    private nonisolated static func promoteSQLite(_ cache: EPGCacheStore, stage: URL, guide: EPGSQLiteGuide, providerID: UUID,
                                                  isCurrent: @Sendable () -> Bool) async -> Bool {
        do { try cache.promoteSQLite(stage: stage, guide: guide, providerID: providerID, isCurrent: isCurrent) } catch { return false }
        return true
    }

    private nonisolated static func sweepCache(_ cache: EPGCacheStore, keeping providerIDs: Set<UUID>) async {
        cache.removeOrphans(keeping: providerIDs)
    }

    private nonisolated static func readState(_ cache: EPGCacheStore, providerID: UUID, fingerprint: Data,
                                              verifiedHeader: EPGCacheFormat.Header?) async -> EPGCacheState? {
        cache.loadStateForCurrentGuide(providerID: providerID, fingerprint: fingerprint,
                                       verifiedHeader: verifiedHeader)
    }

    private nonisolated static func writeV2Cache(_ cache: EPGCacheStore, index: EPGIndex, providerID: UUID,
                                                 fingerprint: Data,
                                                 isCurrent: @Sendable () -> Bool) async -> UUID? {
        try? cache.saveV2(index, providerID: providerID, fingerprint: fingerprint, isCurrent: isCurrent)
    }

    private nonisolated static func writeState(_ cache: EPGCacheStore, state: EPGCacheState) async -> Bool {
        do { try cache.saveState(state) } catch { return false }
        return true
    }

    private nonisolated static func removeCache(_ cache: EPGCacheStore, providerID: UUID) async {
        cache.remove(providerID: providerID)
    }
}

/// Synchronous cross-task generation token used by disk-boundary callbacks. `remove` advances it
/// before awaiting queued work, so a delayed migration cannot stage, promote or delete afterward.
private final class EPGDiskGenerationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: Int] = [:]
    func set(_ id: UUID, generation: Int) { lock.withLock { values[id] = generation } }
    func isCurrent(_ id: UUID, generation: Int) -> Bool {
        lock.withLock { values[id, default: 0] == generation }
    }
}
