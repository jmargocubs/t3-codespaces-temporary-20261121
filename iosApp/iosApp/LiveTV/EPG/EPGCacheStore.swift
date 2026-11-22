import Foundation

/// Disk cache of indexed guides: one compressed file per provider in the platform's guide directory.
///
/// Files are named by provider ID and hold only listings, never feed URLs or credentials. Writes
/// are atomic, and a failed write leaves the previous guide in place. Verified reads never delete a
/// guide they reject: a corrupt, foreign-version, oversized or unreadable file reads as missing and
/// is kept until a verified v2 guide replaces it, the provider is removed, or the orphan sweep runs.
/// Decompression is bounded by `EPGCacheFormat.Limits`. Total size and entry count are bounded,
/// evicting the least recently written guides first.
///
/// Synchronous file I/O: call it from a nonisolated async context, never the main actor.
struct EPGCacheStore: Sendable {
    let directory: URL
    /// Second v1 location on iOS/macOS. tvOS stores v1 and v2 side-by-side in `directory`.
    var legacyReadDirectory: URL?
    var formatLimits = EPGCacheFormat.Limits()
    var maximumTotalBytes = 128 * 1024 * 1024
    var maximumEntries = 8
    var maximumStateBytes = 4 * 1024
    var stateWriter: @Sendable (Data, URL) throws -> Void = { data, url in
        try Self.writeProtectedAtomically(data, url)
    }
#if DEBUG
    /// Deterministic read gate for cache lifecycle tests. Not compiled into release builds.
    var verifiedReadInterceptor: (@Sendable (UUID, Data, @Sendable () -> Bool) -> EPGIndex?)?
#endif
    /// Writes a whole migration stage.
    var stageWriter: @Sendable (Data, URL) throws -> Void = { data, url in
        try Self.writeProtectedAtomically(data, url)
    }
    /// Appends one chunk of a streamed v2 stage, or rewrites its header after a seek to the start.
    /// Injectable so tests can fail, hold or corrupt a write part-way through.
    var stageChunkWriter: @Sendable (Data, FileHandle) throws -> Void = { data, handle in
        try handle.write(contentsOf: data)
    }
    var promoter: @Sendable (URL, URL) throws -> Void = { source, destination in
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }
    /// Lists a guide directory for eviction accounting. Injectable so tests can simulate an
    /// unreadable directory without relying on simulator file permissions.
    var directoryLister: @Sendable (URL) throws -> [URL] = { url in
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
    }
    /// Size and modification date for eviction accounting. A nil field makes the inventory untrusted.
    var fileMetadataReader: @Sendable (URL) throws -> (size: Int?, modified: Date?) = { url in
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (values.fileSize, values.contentModificationDate)
    }
    /// Eviction spans providers, so serialize it with every provider's promotion and removal.
    private static let diskTransactionLock = NSRecursiveLock()

    /// Frozen Stage D names: `<uuid>.v1.epgcache`, `<uuid>.v2.epgcache`,
    /// `<uuid>.<nonce>.stage`. The unsuffixed `.epgcache` is the pre-Stage-D v1 name.
    private static let v1Extension = "epgcache"
    private static let fileExtension = v1Extension
    private static let v2Suffix = ".v2.epgcache"
    private static let abandonedSQLiteGenerationAge: TimeInterval = 24 * 60 * 60

    init(directory: URL, legacyReadDirectory: URL? = nil) {
        self.directory = directory
        self.legacyReadDirectory = legacyReadDirectory
    }

    static func makeDefault(fileManager: FileManager = .default) -> EPGCacheStore? {
        makeDefault(platform: currentPlatform, fileManager: fileManager)
    }

    /// Exposed for deterministic platform-path tests; production selects its compile-time platform.
    static func makeDefault(platform: EPGStoragePlatform, fileManager: FileManager = .default) -> EPGCacheStore? {
        let root: FileManager.SearchPathDirectory = platform == .tvOS ? .cachesDirectory : .applicationSupportDirectory
        guard let base = fileManager.urls(for: root, in: .userDomainMask).first else { return nil }
        let directory: URL
        if platform == .tvOS {
            directory = base.appendingPathComponent("LiveTVGuide", isDirectory: true)
        } else {
            directory = base.appendingPathComponent("Silo", isDirectory: true)
                .appendingPathComponent("LiveTV", isDirectory: true)
                .appendingPathComponent("Guide", isDirectory: true)
        }
        let legacy: URL? = platform == .tvOS ? nil : fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LiveTVGuide", isDirectory: true)
        return EPGCacheStore(directory: directory, legacyReadDirectory: legacy)
    }

    private static var currentPlatform: EPGStoragePlatform {
#if os(tvOS)
        .tvOS
#elseif os(macOS)
        .macOS
#else
        .iOS
#endif
    }

    /// Missing, malformed, oversized or unreadable state is a cache miss, never permission to
    /// discard a guide. A well-formed state that fails validation, such as one for another source,
    /// is deleted. The file is read once, and callers must serialize this with the provider's state
    /// writes, so that deletion can only ever remove the bytes that were judged.
    func loadState(providerID: UUID, fingerprint: Data, contentID: UUID? = nil) -> EPGCacheState? {
        let url = stateURL(providerID)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size >= 0, size <= maximumStateBytes,
              let data = try? Data(contentsOf: url), data.count <= maximumStateBytes,
              let state = try? JSONDecoder().decode(EPGCacheState.self, from: data) else { return nil }
        guard state.isValid(for: providerID, fingerprint: fingerprint, associatedContentID: contentID) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return state
    }

    /// Reads state for a source without confusing an absent/unreadable v2 file with a content-ID
    /// mismatch. Linked state is accepted only when a fully validated v2 guide for this source
    /// carries the same ID; legacy state is accepted only when it remains unlinked.
    ///
    /// `verifiedHeader` is the header `loadVerifiedGuide` returned for a guide it fully validated.
    /// When the file on disk still has exactly that header and its payload still matches the
    /// header's SHA-256 digest, it is byte-for-byte the validated file, so its content ID is used
    /// without decoding and indexing the guide a second time. Any difference falls back to full
    /// validation of the current file.
    func loadStateForCurrentGuide(providerID: UUID, fingerprint: Data,
                                  verifiedHeader: EPGCacheFormat.Header? = nil) -> EPGCacheState? {
        Self.diskTransactionLock.lock()
        defer { Self.diskTransactionLock.unlock() }
        let url = stateURL(providerID)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size >= 0, size <= maximumStateBytes,
              let data = try? Data(contentsOf: url), data.count <= maximumStateBytes,
              let state = try? JSONDecoder().decode(EPGCacheState.self, from: data) else { return nil }
        guard state.isValid(for: providerID, fingerprint: fingerprint,
                            associatedContentID: state.contentID) else {
            // Source mismatch invalidates retry metadata, not any guide file.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard let linkedContentID = state.contentID else { return state }
        guard let guideData = try? Data(contentsOf: v2URL(providerID), options: .mappedIfSafe) else { return nil }
        if let verifiedHeader, verifiedHeader.providerID == providerID,
           verifiedHeader.sourceFingerprint == fingerprint,
           EPGCacheFormat.isUnchanged(guideData, since: verifiedHeader, limits: formatLimits) {
            return verifiedHeader.contentID == linkedContentID ? state : nil
        }
        guard let guide = try? EPGCacheFormat.decode(guideData, providerID: providerID, limits: formatLimits),
              guide.header.sourceFingerprint == fingerprint,
              guide.header.contentID == linkedContentID else { return nil }
        return state
    }

    func saveState(_ state: EPGCacheState) throws {
        Self.diskTransactionLock.lock()
        defer { Self.diskTransactionLock.unlock() }
        guard state.isValid(for: state.providerID, fingerprint: state.sourceFingerprint,
                            associatedContentID: state.contentID) else {
            throw EPGCacheStateStoreError.invalidState
        }
        let data = try JSONEncoder().encode(state)
        guard data.count <= maximumStateBytes else { throw EPGCacheStateStoreError.tooLarge }
        try prepareDirectory()
        try stateWriter(data, stateURL(state.providerID))
    }

    func removeState(providerID: UUID) {
        Self.diskTransactionLock.lock()
        defer { Self.diskTransactionLock.unlock() }
        try? FileManager.default.removeItem(at: stateURL(providerID))
    }

    /// Removes guide and state files for providers no longer configured. Listing failure is a no-op.
    func removeOrphans(keeping providerIDs: Set<UUID>) {
        Self.diskTransactionLock.lock()
        defer { Self.diskTransactionLock.unlock() }
        sweep(directory, keeping: providerIDs, extensions: [Self.v1Extension, "state"])
        sweepV2(in: directory, keeping: providerIDs)
        sweepSQLite(in: directory, keeping: providerIDs)
        sweepStages(in: directory)
        if let legacyReadDirectory, legacyReadDirectory != directory {
            sweep(legacyReadDirectory, keeping: providerIDs, extensions: [Self.v1Extension])
        }
    }

    private func sweep(_ directory: URL, keeping providerIDs: Set<UUID>, extensions: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where extensions.contains(file.pathExtension) {
            guard let id = providerIDForFile(file),
                  !providerIDs.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Unverified format inspection is available only to debug/test builds. Production reads must
    /// go through `loadVerified(providerID:fingerprint:)`.
#if DEBUG
    func load(providerID: UUID) -> EPGIndex? {
        if let index = loadV2(providerID: providerID) { return index }
        let candidates = legacyURLs(providerID: providerID)
        return candidates.compactMap { url in
            loadV1(at: url, deleteInvalid: url.deletingLastPathComponent() == directory)
        }.max { $0.fetchedAt < $1.fetchedAt }
    }
#endif

    /// A guide that passed verification. `header` is the validated v2 header that bound it to its
    /// source, or nil for a guide read through the legacy v1 path.
    struct VerifiedGuide: Sendable {
        let index: EPGIndex
        let header: EPGCacheFormat.Header?
    }

    /// Returns only a guide with an established binding to the requested source. A v2 header is
    /// independently bound by its HMAC fingerprint. A v1 guide is eligible only when matching
    /// persisted Stage C state binds the exact fetchedAt; a UUID match alone is never sufficient.
    func loadVerified(providerID: UUID, fingerprint: Data,
                      isCurrent: @Sendable () -> Bool = { true }) -> EPGIndex? {
        loadVerifiedGuide(providerID: providerID, fingerprint: fingerprint, isCurrent: isCurrent)?.index
    }

    /// `loadVerified`, also returning the validated v2 header so state can be checked against the
    /// same file without decoding it again.
    func loadVerifiedGuide(providerID: UUID, fingerprint: Data,
                           preferSQLite: Bool = false, sqliteReadPolicy: EPGSQLiteReadPolicy = .cachedOnly,
                           isCurrent: @Sendable () -> Bool = { true }) -> VerifiedGuide? {
        Self.diskTransactionLock.lock()
        defer { Self.diskTransactionLock.unlock() }
#if DEBUG
        if let verifiedReadInterceptor {
            return verifiedReadInterceptor(providerID, fingerprint, isCurrent).map { VerifiedGuide(index: $0, header: nil) }
        }
#endif
        guard fingerprint.count == EPGCacheFormat.fingerprintLength else { return nil }
        // SQLite first when enabled; a missing, foreign, corrupt or incompatible file falls through to v2.
        if preferSQLite, let index = loadSQLite(providerID: providerID, fingerprint: fingerprint,
                                                 readPolicy: sqliteReadPolicy) {
            return VerifiedGuide(index: index, header: nil)
        }
        if let data = try? Data(contentsOf: v2URL(providerID), options: .mappedIfSafe),
           let decoded = try? EPGCacheFormat.decode(data, providerID: providerID, limits: formatLimits),
           decoded.header.sourceFingerprint == fingerprint {
            deleteReadableLegacy(providerID: providerID, isCurrent: isCurrent)
            return VerifiedGuide(index: decoded.index, header: decoded.header)
        }
        guard let state = readState(providerID: providerID), state.sourceFingerprint == fingerprint,
              state.contentID == nil, let successAt = state.lastSuccessfulFetchDate else { return nil }
        var newest: EPGIndex?
        for url in legacyURLs(providerID: providerID) {
            guard let candidate = loadV1(at: url, deleteInvalid: false), candidate.fetchedAt == successAt else { continue }
            if newest == nil || candidate.fetchedAt > newest!.fetchedAt { newest = candidate }
        }
        return newest.map { VerifiedGuide(index: $0, header: nil) }
    }

    /// A non-destructive state read for identity decisions. Unlike retry-state loading, a mismatch
    /// is not evidence that any guide is corrupt and must not delete state or guide files.
    func readState(providerID: UUID) -> EPGCacheState? {
        let url = stateURL(providerID)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size >= 0, size <= maximumStateBytes,
              let data = try? Data(contentsOf: url), data.count <= maximumStateBytes,
              let state = try? JSONDecoder().decode(EPGCacheState.self, from: data),
              state.isValid(for: providerID, fingerprint: state.sourceFingerprint,
                            associatedContentID: state.contentID) else { return nil }
        return state
    }

    /// Runs only when explicitly requested by EPGService; normal cache reads never migrate.
    /// Binding v1 to the supplied fingerprint assumes provider sources cannot be edited in place.
    func migrate(providerID: UUID, fingerprint: Data, isCurrent: @Sendable () -> Bool = { true }) -> Bool {
        Self.diskTransactionLock.lock()
        defer { Self.diskTransactionLock.unlock() }
        guard fingerprint.count == EPGCacheFormat.fingerprintLength, isCurrent() else { return false }
        let v2 = v2URL(providerID)
        if let data = try? Data(contentsOf: v2, options: .mappedIfSafe),
           let existing = try? EPGCacheFormat.decode(data, providerID: providerID, limits: formatLimits),
           existing.header.sourceFingerprint == fingerprint {
            if let state = readState(providerID: providerID), state.sourceFingerprint == fingerprint,
               state.contentID == nil, state.lastSuccessfulFetchDate == existing.index.fetchedAt,
               isCurrent() {
                do { try saveState(state.linked(to: existing.header.contentID)) }
                catch { return false }
            }
            deleteReadableLegacy(providerID: providerID, isCurrent: isCurrent)
            return true
        }
        guard let state = readState(providerID: providerID), state.sourceFingerprint == fingerprint,
              state.contentID == nil, let successDate = state.lastSuccessfulFetchDate else { return false }
        // Decode candidates sequentially so a feed with large records does not multiply peak memory.
        var selected: EPGIndex?
        for url in legacyURLs(providerID: providerID) {
            guard let candidate = loadV1(at: url, deleteInvalid: false), candidate.fetchedAt == successDate else { continue }
            if selected == nil || candidate.fetchedAt > selected!.fetchedAt { selected = candidate }
        }
        guard let index = selected, isCurrent() else { return false }
        // A raw v1 guide has no source identity. Only Stage C's independently persisted success
        // state, with an exact fetch-time association, can authorize binding it to this source.
        do {
            let contentID = UUID()
            let bytes = try EPGCacheFormat.encode(index, providerID: providerID, sourceFingerprint: fingerprint,
                                                  contentID: contentID, limits: formatLimits)
            try prepareDirectory()
            let stage = directory.appendingPathComponent("\(providerID.uuidString).\(UUID().uuidString).stage")
            defer { try? FileManager.default.removeItem(at: stage) }
            guard isCurrent() else { return false }
            try stageWriter(bytes, stage)
            let reopened = try Data(contentsOf: stage, options: .mappedIfSafe)
            let checked = try EPGCacheFormat.decode(reopened, providerID: providerID, limits: formatLimits)
            guard checked.header.sourceFingerprint == fingerprint,
                  checked.header.providerID == providerID,
                  checked.header.contentID == contentID,
                  Self.sameGuideContent(checked.index, index), isCurrent() else { return false }
            try promoter(stage, v2)
            guard isCurrent() else { return true } // promoted v2 is safe; leave v1 if generation changed
            try saveState(state.linked(to: contentID))
            deleteReadableLegacy(providerID: providerID, isCurrent: isCurrent)
            return true
        } catch { return false }
    }

    /// Deletes the provider's v1 files that the v1 reader decodes. Callers have either just
    /// verified or promoted a source-bound v2 guide, or evicted the provider's entry, so a readable
    /// v1 guide could only ever resurface as stale data. The v1 reader applies structural checks
    /// only, so a readable v1 guide outside current v2 policy is deleted too. Unknown framing, a file
    /// larger than this build's limits, and an unreadable file are kept.
    private func deleteReadableLegacy(providerID: UUID, isCurrent: @Sendable () -> Bool) {
        for url in legacyURLs(providerID: providerID) where isCurrent() {
            guard loadV1(at: url, deleteInvalid: false) != nil, isCurrent() else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Exact comparison. Fetch times are canonical by construction (`EPGTimestamp`), so a guide read
    /// back equals the one written; any difference in fetch time or programmes rejects the stage.
    private static func sameGuideContent(_ lhs: EPGIndex, _ rhs: EPGIndex) -> Bool {
        lhs.fetchedAt == rhs.fetchedAt && lhs.programsByChannel == rhs.programsByChannel &&
            lhs.channelIDsByName == rhs.channelIDsByName && lhs.coverageEnd == rhs.coverageEnd &&
            lhs.programCount == rhs.programCount
    }

    private func legacyURLs(providerID: UUID) -> [URL] {
        var urls = [directory.appendingPathComponent("\(providerID.uuidString).v1.epgcache"),
                    directory.appendingPathComponent("\(providerID.uuidString).epgcache")]
        if let legacyReadDirectory, legacyReadDirectory != directory {
            urls.append(legacyReadDirectory.appendingPathComponent("\(providerID.uuidString).epgcache"))
            urls.append(legacyReadDirectory.appendingPathComponent("\(providerID.uuidString).v1.epgcache"))
        }
        return urls
    }

    private func loadV2(providerID: UUID) -> EPGIndex? {
        let url = v2URL(providerID)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let decoded = try? EPGCacheFormat.decode(data, providerID: providerID, limits: formatLimits) else { return nil }
        return decoded.index
    }

    private func loadV1(at url: URL, deleteInvalid: Bool) -> EPGIndex? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        do { return try EPGCacheFormat.decodeVersion1(data, limits: formatLimits) }
        catch EPGCacheFormatError.tooLarge { return nil }
        catch is EPGCacheFormatError {
            if deleteInvalid { try? FileManager.default.removeItem(at: url) }
            return nil
        } catch { return nil }
    }

    private func sweepStages(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files where file.pathExtension == "stage" {
            let parts = file.deletingPathExtension().lastPathComponent.split(separator: ".")
            guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil,
                  UUID(uuidString: String(parts[1])) != nil else { continue }
            // A young stage may still belong to an interrupted-but-retrying write, or be in use
            // by another process sharing the container. Sweep only files older than a full day.
            guard let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  date < Date().addingTimeInterval(-Self.abandonedStageAge) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
    private func sweepV2(in directory: URL, keeping providerIDs: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasSuffix(Self.v2Suffix) {
            let stem = String(file.lastPathComponent.dropLast(Self.v2Suffix.count))
            guard let id = UUID(uuidString: stem), !providerIDs.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
    private static let abandonedStageAge: TimeInterval = 24 * 60 * 60

    /// Legacy v1 fixture writer, intentionally unavailable in release builds.
#if DEBUG
    func save(_ index: EPGIndex, providerID: UUID) throws {
        Self.diskTransactionLock.lock()
        defer { Self.diskTransactionLock.unlock() }
        try prepareDirectory()
        let file = try EPGCacheFormat.encodeVersion1(index, limits: formatLimits)
        try Self.writeProtectedAtomically(file, fileURL(providerID))
        evict(keeping: providerID)
    }
#endif

    /// Writes a source-bound v2 guide atomically. The guide is checked against v2 policy before a
    /// stage exists, streamed into the stage in bounded batches, then reopened, fully decoded and
    /// compared with the guide and header written; only an exact match is promoted. Any failure, or
    /// `isCurrent` turning false at a checkpoint before promotion admission, removes the stage and
    /// leaves the previous guide and state untouched. Invalidation after admission may not stop the
    /// atomic replacement; source binding and ordered removal protect readers (see below).
    @discardableResult
    func saveV2(_ index: EPGIndex, providerID: UUID, fingerprint: Data,
                isCurrent: @Sendable () -> Bool = { true }) throws -> UUID {
        Self.diskTransactionLock.lock()
        defer { Self.diskTransactionLock.unlock() }
        guard isCurrent() else { throw CancellationError() }
        try prepareDirectory()
        let contentID = UUID()
        let writer = try EPGCacheFormat.Writer(index, providerID: providerID, sourceFingerprint: fingerprint,
                                               contentID: contentID, limits: formatLimits)
        let stage = directory.appendingPathComponent("\(providerID.uuidString).\(UUID().uuidString).stage")
        defer { try? FileManager.default.removeItem(at: stage) }
        let written = try writeStage(writer, to: stage, isCurrent: isCurrent)
        guard isCurrent() else { throw CancellationError() }
        let reopened = try Data(contentsOf: stage, options: .mappedIfSafe)
        let checked = try EPGCacheFormat.decode(reopened, providerID: providerID, limits: formatLimits)
        guard checked.header == written, checked.header.sourceFingerprint == fingerprint,
              checked.header.contentID == contentID,
              Self.sameGuideContent(checked.index, index) else { throw EPGCacheFormatError.mismatchedMetadata }
        // Admission boundary: after this final check the verified replacement may complete even
        // if the generation changes. The filesystem commit is the atomic replacement/move below.
        // Source binding prevents a new source from using it; removal waits for this write then
        // deletes it. Task cancellation alone deliberately does not abort synchronous persistence.
        guard isCurrent() else { throw CancellationError() }
        try promoter(stage, v2URL(providerID))
        deleteReadableLegacy(providerID: providerID, isCurrent: { true })
        evict(keeping: providerID)
        return contentID
    }

    /// Streams `writer` into a new stage created with the guide's data protection. The stage is
    /// flushed to storage and closed before it is reopened for verification.
    private func writeStage(_ writer: EPGCacheFormat.Writer, to stage: URL,
                            isCurrent: () -> Bool) throws -> EPGCacheFormat.Header {
        try Data().write(to: stage, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
        let handle = try FileHandle(forWritingTo: stage)
        var isClosed = false
        defer { if !isClosed { try? handle.close() } }
        let header = try writer.write(isCurrent: isCurrent, append: { try stageChunkWriter($0, handle) },
                                      writeHeader: { header in
                                          try handle.seek(toOffset: 0)
                                          try stageChunkWriter(header, handle)
                                      })
        try handle.synchronize()
        isClosed = true
        try handle.close()
        return header
    }

    func remove(providerID: UUID) {
        Self.diskTransactionLock.lock()
        defer { Self.diskTransactionLock.unlock() }
        try? FileManager.default.removeItem(at: fileURL(providerID))
        for url in legacyURLs(providerID: providerID) { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: v2URL(providerID))
        try? FileManager.default.removeItem(at: sqlitePointerURL(providerID))
        for url in sqliteFiles(providerID: providerID) { removeSQLiteIfUnleased(url) }
        for stage in stageURLs(providerID: providerID) { try? FileManager.default.removeItem(at: stage) }
        removeState(providerID: providerID)
    }

    private func fileURL(_ providerID: UUID) -> URL {
        fileURL(providerID, in: directory)
    }

    private func v2URL(_ providerID: UUID) -> URL { directory.appendingPathComponent("\(providerID.uuidString)\(Self.v2Suffix)") }
    private func stageURLs(providerID: UUID) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?.filter {
            $0.lastPathComponent.lowercased().hasPrefix("\(providerID.uuidString.lowercased()).") && $0.pathExtension == "stage"
        } ?? []
    }

    fileprivate func providerIDForFile(_ file: URL) -> UUID? {
        let name = file.lastPathComponent
        if name.hasSuffix(Self.v2Suffix) {
            return UUID(uuidString: String(name.dropLast(Self.v2Suffix.count)))
        }
        if name.hasSuffix(Self.sqliteSuffix) || name.hasSuffix(Self.sqlitePointerSuffix) {
            return UUID(uuidString: String(name.prefix { $0 != "." }))
        }
        let v1Suffix = ".v1.epgcache"
        if name.hasSuffix(v1Suffix) { return UUID(uuidString: String(name.dropLast(v1Suffix.count))) }
        return UUID(uuidString: file.deletingPathExtension().lastPathComponent)
    }

    private func fileURL(_ providerID: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(providerID.uuidString).appendingPathExtension(Self.fileExtension)
    }

    private func stateURL(_ providerID: UUID) -> URL {
        directory.appendingPathComponent(providerID.uuidString).appendingPathExtension("state")
    }

    fileprivate func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
#if os(iOS) || os(macOS)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = directory
        try target.setResourceValues(values)
#endif
    }

    private static func writeProtectedAtomically(_ data: Data, _ url: URL) throws {
        try data.write(to: url, options: protectedWriteOptions)
    }

    static var protectedWriteOptions: Data.WritingOptions {
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    }

    /// Drops the least recently written v2 guides until the cache fits its size and count limits.
    ///
    /// The budget covers every recognized guide file: v2 guides in `directory` and v1 files in both
    /// v1 locations, each file counted once even when both locations are the same directory. Legacy
    /// v1 files are never removal candidates here: a v1 file is deleted only with its provider's
    /// evicted v2 guide, and only when it is readable. The provider just written is always kept.
    /// The inventory is re-read after every removal, so a deleted pair is never still counted and no
    /// guide is removed once the cache fits. If kept and legacy files alone exceed a limit, eviction
    /// stops when no candidate remains; the cache stays over until a verified v2 write, provider
    /// removal, or the orphan sweep removes them.
    ///
    /// Eviction deletes only on a complete inventory. If a directory that exists cannot be listed,
    /// or a counted file's size or date cannot be read, nothing more is removed: an incomplete count
    /// could otherwise remove a valid guide. A legacy directory that does not exist counts as empty.
    ///
    /// Stage files are not guides and never count. Recognized stages older than the abandoned-stage
    /// age are removed first, exactly as the orphan sweep does; younger stages are left alone.
    private func evict(keeping providerID: UUID) {
        sweepStages(in: directory)
        var attempted = Set<String>()
        while let inventory = evictionInventory(keeping: providerID),
              inventory.entries > maximumEntries || inventory.bytes > maximumTotalBytes,
              let victim = inventory.candidates.first(where: { !attempted.contains($0.path) }) {
            attempted.insert(victim.path)
            try? FileManager.default.removeItem(at: victim)
            // The verified v2 guide is gone, so a readable v1 copy for the same provider must not
            // resurface as stale data. Unreadable or unsupported v1 files are left in place. If the
            // v2 guide could not be removed, it still supersedes v1 and nothing else is touched.
            guard !FileManager.default.fileExists(atPath: victim.path),
                  let id = providerIDForFile(victim) else { continue }
            deleteReadableLegacy(providerID: id, isCurrent: { true })
        }
    }

    /// Recognized guide files counted against the budget, and the v2 guides that may be evicted,
    /// oldest first. Nil when the inventory cannot be trusted: the primary directory cannot be
    /// listed, an existing legacy directory cannot be listed, or a counted file lacks a size or,
    /// for a candidate, a modification date.
    private func evictionInventory(keeping providerID: UUID) -> (entries: Int, bytes: Int, candidates: [URL])? {
        guard let primary = try? directoryLister(directory) else { return nil }
        var files = primary.filter { providerIDForFile($0) != nil && $0.pathExtension == Self.v1Extension }
        if let legacy = distinctLegacyReadDirectory {
            do {
                // Only v1 names are guides in the legacy location; v2 is never read from there.
                files += try directoryLister(legacy).filter {
                    providerIDForFile($0) != nil && $0.pathExtension == Self.v1Extension && !$0.lastPathComponent.hasSuffix(Self.v2Suffix)
                }
            } catch let error where Self.isMissingItem(error) {
                // No legacy cache was ever written here; there is nothing to count.
            } catch {
                return nil
            }
        }
        var seen = Set<String>()
        var entries = 0, bytes = 0
        var candidates: [(url: URL, date: Date)] = []
        for file in files where seen.insert(file.resolvingSymlinksInPath().path).inserted {
            guard let metadata = try? fileMetadataReader(file), let size = metadata.size, size >= 0 else { return nil }
            let (sum, overflow) = bytes.addingReportingOverflow(size)
            bytes = overflow ? Int.max : sum
            entries += 1
            if file.lastPathComponent.hasSuffix(Self.v2Suffix), providerIDForFile(file) != providerID {
                guard let modified = metadata.modified else { return nil }
                candidates.append((file, modified))
            }
        }
        candidates.sort { lhs, rhs in
            lhs.date != rhs.date ? lhs.date < rhs.date : lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }
        return (entries, bytes, candidates.map(\.url))
    }

    /// True only for "no such file or directory", never for permission or I/O failures.
    private static func isMissingItem(_ error: Error) -> Bool {
        let error = error as NSError
        switch (error.domain, error.code) {
        case (NSCocoaErrorDomain, NSFileReadNoSuchFileError), (NSCocoaErrorDomain, NSFileNoSuchFileError),
             (NSPOSIXErrorDomain, Int(ENOENT)):
            return true
        default:
            return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isMissingItem) ?? false
        }
    }

    /// The legacy v1 location when it is a different directory from `directory`.
    private var distinctLegacyReadDirectory: URL? {
        guard let legacyReadDirectory,
              legacyReadDirectory.resolvingSymlinksInPath().standardizedFileURL.path
                != directory.resolvingSymlinksInPath().standardizedFileURL.path else { return nil }
        return legacyReadDirectory
    }
}

// MARK: - SQLite guides (optional; see `EPGStorageMode`)

extension EPGCacheStore {
    fileprivate static let sqliteSuffix = ".guide.sqlite"
    fileprivate static let sqlitePointerSuffix = ".guide-current"

    /// The current generation URL (or the fixed-name Stage B database for backward compatibility).
    func sqliteURL(_ providerID: UUID) -> URL {
        Self.diskTransactionLock.lock()
        defer { Self.diskTransactionLock.unlock() }
        return activeSQLiteURL(providerID) ?? directory.appendingPathComponent("\(providerID.uuidString)\(Self.sqliteSuffix)")
    }

    private func sqlitePointerURL(_ providerID: UUID) -> URL {
        directory.appendingPathComponent("\(providerID.uuidString)\(Self.sqlitePointerSuffix)")
    }

    private func activeSQLiteURL(_ providerID: UUID) -> URL? {
        guard let name = try? String(contentsOf: sqlitePointerURL(providerID), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              name.hasPrefix("\(providerID.uuidString)."), name.hasSuffix(Self.sqliteSuffix),
              !name.contains("/"), !name.contains("\\") else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A private, unique build path. Stages share the `.stage` naming, so the existing stage sweep
    /// and provider removal clean them up too.
    func sqliteStageURL(providerID: UUID) throws -> URL {
        try prepareDirectory()
        // The builder writes directly to an immutable generation path. Publishing changes only a
        // tiny text pointer, never the vnode underneath an open SQLite connection.
        return directory.appendingPathComponent("\(providerID.uuidString).\(UUID().uuidString)\(Self.sqliteSuffix)")
    }

    /// Opens the provider's promoted SQLite guide when it carries this provider and source fingerprint.
    /// A rejected file is left alone, like a rejected v2 file; the next verified write replaces it.
    func loadSQLite(providerID: UUID, fingerprint: Data, readPolicy: EPGSQLiteReadPolicy = .cachedOnly) -> EPGIndex? {
        Self.diskTransactionLock.lock()
        defer { Self.diskTransactionLock.unlock() }
        let pointer = sqlitePointerURL(providerID)
        let url = FileManager.default.fileExists(atPath: pointer.path)
            ? activeSQLiteURL(providerID)
            : directory.appendingPathComponent("\(providerID.uuidString)\(Self.sqliteSuffix)")
        guard let url else { return nil }
        guard FileManager.default.fileExists(atPath: url.path),
              let guide = try? EPGSQLiteGuide.open(url, providerID: providerID, fingerprint: fingerprint) else {
            return nil
        }
        return EPGIndex(sqlite: EPGSQLiteIndex(guide: guide, readPolicy: readPolicy))
    }

    /// Atomically activates a fully built, immutable generation by replacing only a text pointer.
    /// Existing SQLite readers retain their generation path; no live database vnode is renamed,
    /// replaced or unlinked. Failure leaves both the previous pointer and guide intact.
    func promoteSQLite(stage: URL, guide: EPGSQLiteGuide, providerID: UUID,
                       isCurrent: @Sendable () -> Bool) throws {
        Self.diskTransactionLock.lock()
        defer { Self.diskTransactionLock.unlock() }
        guard isCurrent() else { throw CancellationError() }
        let name = stage.lastPathComponent
        guard stage.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              name.hasPrefix("\(providerID.uuidString)."), name.hasSuffix(Self.sqliteSuffix),
              guide.url.standardizedFileURL == stage.standardizedFileURL,
              FileManager.default.fileExists(atPath: stage.path) else { throw EPGSQLiteError.mismatchedIdentity }
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: stage.path)
        let pointerStage = directory.appendingPathComponent("\(providerID.uuidString).\(UUID().uuidString).stage")
        defer { try? FileManager.default.removeItem(at: pointerStage) }
        try stageWriter(Data(name.utf8), pointerStage)
        guard isCurrent() else { throw CancellationError() }
        try promoter(pointerStage, sqlitePointerURL(providerID))
        guide.markPublished()
        evictSQLite(keeping: providerID)
    }

    /// Bounds SQLite guides by the same entry and byte budget as v2 guides, oldest first, never the
    /// provider just written. Deletes only on a complete inventory.
    private func evictSQLite(keeping providerID: UUID) {
        guard let files = try? directoryLister(directory) else { return }
        var entries: [(url: URL, size: Int, modified: Date)] = []
        for file in files where file.lastPathComponent.hasSuffix(Self.sqliteSuffix) {
            guard let metadata = try? fileMetadataReader(file), let size = metadata.size,
                  let modified = metadata.modified else { return }
            entries.append((file, size, modified))
        }
        var bytes = entries.reduce(0) { $0 + $1.size }
        var count = entries.count
        let keep = sqliteURL(providerID).lastPathComponent
        for victim in entries.sorted(by: { $0.modified < $1.modified }) where victim.url.lastPathComponent != keep {
            let id = providerIDForFile(victim.url)
            let wasActive = id.map { activeSQLiteURL($0) == victim.url } ?? false
            let retiredGeneration = id == providerID && !wasActive
            guard retiredGeneration || count > maximumEntries || bytes > maximumTotalBytes else { continue }
            guard !EPGSQLiteFileLeases.isLeased(victim.url) else { continue }
            removeSQLiteIfUnleased(victim.url)
            if wasActive, let id {
                try? FileManager.default.removeItem(at: sqlitePointerURL(id))
            }
            count -= 1
            bytes -= victim.size
        }
    }

    fileprivate func sweepSQLite(in directory: URL, keeping providerIDs: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.lastPathComponent.hasSuffix(Self.sqlitePointerSuffix) {
            guard let id = providerIDForFile(file), !providerIDs.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
        for file in files where file.lastPathComponent.hasSuffix(Self.sqliteSuffix) {
            guard let id = providerIDForFile(file) else { continue }
            if !providerIDs.contains(id) {
                removeSQLiteIfUnleased(file)
                continue
            }
            // A crashed build can leave an unactivated generation. Do not reap a live reader, and
            // never remove a legacy fixed-name database solely because it lacks a pointer.
            let isLegacy = file.lastPathComponent == "\(id.uuidString)\(Self.sqliteSuffix)"
            let isActive = activeSQLiteURL(id) == file
            guard !isLegacy, !isActive,
                  let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < Date().addingTimeInterval(-Self.abandonedSQLiteGenerationAge) else { continue }
            removeSQLiteIfUnleased(file)
        }
    }

    private func sqliteFiles(providerID: UUID) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?.filter {
            $0.lastPathComponent.hasPrefix("\(providerID.uuidString).") && $0.lastPathComponent.hasSuffix(Self.sqliteSuffix)
        } ?? []
    }

    private func removeSQLiteIfUnleased(_ url: URL) {
        guard !EPGSQLiteFileLeases.isLeased(url) else { return }
        try? FileManager.default.removeItem(at: url)
        for suffix in ["-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}

enum EPGStoragePlatform: Equatable, Sendable {
    case iOS
    case macOS
    case tvOS
}

enum EPGCacheStateStoreError: Error, Equatable {
    case invalidState
    case tooLarge
}
