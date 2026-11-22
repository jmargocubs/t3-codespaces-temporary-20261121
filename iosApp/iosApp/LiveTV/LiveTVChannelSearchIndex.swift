import Foundation

/// An immutable, provider-scoped search projection of an IPTV catalog.
///
/// The index deliberately keeps only channel IDs, names, categories, normalized text, and the
/// catalog order. It never retains `LiveTVChannel` (which carries stream and logo URLs), provider
/// configuration, credentials, or playback state. A caller must resolve returned IDs against the
/// same provider and catalog revision before using them.
struct LiveTVChannelSearchIndex: Sendable {
    struct Identity: Hashable, Sendable {
        let providerID: UUID
        let catalogRevision: Int
    }

    struct Match: Equatable, Sendable {
        let channelID: String
        let ordinal: Int
    }

    let identity: Identity
    let localeIdentifier: String
    let estimatedStorageBytes: Int

    private struct Entry: Sendable {
        let channelID: String
        let name: String
        let category: String
        let foldedName: String
        let foldedCategory: String
        let ordinal: Int
    }

    private let entries: [Entry]
    private let locale: Locale
    /// `localizedStandardContains` has locale-sensitive behavior. Non-ASCII metadata/queries and
    /// Turkish/Azeri casing use the Foundation matcher directly rather than risking a false
    /// negative from the cached fast-path normalization.
    private let requiresExactMatching: Bool

    private init?(identity: Identity, channels: [LiveTVChannel], locale: Locale) {
        self.identity = identity
        self.locale = locale
        localeIdentifier = locale.identifier

        let localeLanguage = locale.identifier
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .first?.lowercased()
        let localeNeedsExactMatching = localeLanguage == "tr" || localeLanguage == "az"
        var hasNonASCII = false
        var builtEntries: [Entry] = []
        builtEntries.reserveCapacity(channels.count)
        for (ordinal, channel) in channels.enumerated() {
            if ordinal.isMultiple(of: 256), Task.isCancelled { return nil }
            if !channel.name.unicodeScalars.allSatisfy({ $0.value < 128 })
                || !channel.category.unicodeScalars.allSatisfy({ $0.value < 128 }) {
                hasNonASCII = true
            }
            builtEntries.append(Entry(
                channelID: channel.id,
                name: channel.name,
                category: channel.category,
                foldedName: Self.fold(channel.name, locale: locale),
                foldedCategory: Self.fold(channel.category, locale: locale),
                ordinal: ordinal
            ))
        }
        entries = builtEntries
        requiresExactMatching = hasNonASCII || localeNeedsExactMatching

        // Deterministic payload estimate, not a claim about allocator/RSS overhead. String storage
        // counts UTF-8 bytes for original + folded values; fixed entry storage uses its Swift stride.
        estimatedStorageBytes = entries.reduce(MemoryLayout<Entry>.stride * entries.count) { total, entry in
            total + entry.channelID.utf8.count + entry.name.utf8.count + entry.category.utf8.count
                + entry.foldedName.utf8.count + entry.foldedCategory.utf8.count
        }
    }

    /// Builds off the caller's actor. The result is tied to exactly this provider/catalog revision.
    static func build(providerID: UUID, catalogRevision: Int, channels: [LiveTVChannel],
                      locale: Locale = .current) async -> Self? {
        let identity = Identity(providerID: providerID, catalogRevision: catalogRevision)
        let worker: Task<Self?, Never> = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return nil }
            return Self(identity: identity, channels: channels, locale: locale)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Searches the pre-normalized projection off the caller's actor. Query whitespace follows
    /// `LiveTVChannelSearchModel`: leading/trailing whitespace/newlines are removed, and a blank
    /// query returns the full catalog in its original order.
    func search(query: String) async -> [Match]? {
        let worker = Task.detached(priority: .userInitiated) {
            self.searchSynchronously(query: query)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func searchSynchronously(query: String) -> [Match]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Task.isCancelled else { return nil }
        guard !trimmed.isEmpty else {
            var all: [Match] = []
            all.reserveCapacity(entries.count)
            for (offset, entry) in entries.enumerated() {
                if offset.isMultiple(of: 256), Task.isCancelled { return nil }
                all.append(Match(channelID: entry.channelID, ordinal: entry.ordinal))
            }
            return Task.isCancelled ? nil : all
        }

        let foldedQuery = Self.fold(trimmed, locale: locale)
        let exact = requiresExactMatching || !trimmed.unicodeScalars.allSatisfy { $0.value < 128 }
        var matches: [Match] = []
        matches.reserveCapacity(min(entries.count, 64))
        for (offset, entry) in entries.enumerated() {
            if offset.isMultiple(of: 256), Task.isCancelled { return nil }
            let matchesName: Bool
            let matchesCategory: Bool
            if exact {
                matchesName = entry.name.localizedStandardContains(trimmed)
                matchesCategory = entry.category.localizedStandardContains(trimmed)
            } else {
                matchesName = entry.foldedName.contains(foldedQuery)
                matchesCategory = entry.foldedCategory.contains(foldedQuery)
            }
            if matchesName || matchesCategory {
                matches.append(Match(channelID: entry.channelID, ordinal: entry.ordinal))
            }
        }
        return Task.isCancelled ? nil : matches
    }

    private static func fold(_ text: String, locale: Locale) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    }
}

/// Owns the currently valid index and rejects superseded builds/searches. A query result is
/// returned only if its query generation, provider, and catalog revision are still current.
/// This actor is intentionally independent of SwiftUI, navigation, and playback.
actor LiveTVChannelSearchIndexStore {
    static let shared = LiveTVChannelSearchIndexStore()

    private var identity: LiveTVChannelSearchIndex.Identity?
    private var index: LiveTVChannelSearchIndex?
    private var catalogGeneration = 0
    private var queryGeneration = 0
    private var buildWorker: Task<LiveTVChannelSearchIndex?, Never>?
    private var searchWorker: Task<[LiveTVChannelSearchIndex.Match]?, Never>?

    /// Replaces the active catalog and builds its immutable search projection. A replacement
    /// immediately invalidates old queries, even while the new index is still being built.
    @discardableResult
    func replaceCatalog(providerID: UUID, catalogRevision: Int,
                        channels: [LiveTVChannel]) async -> Bool {
        let nextIdentity = LiveTVChannelSearchIndex.Identity(providerID: providerID,
                                                             catalogRevision: catalogRevision)
        if index?.identity == nextIdentity { return true }
        if identity == nextIdentity, let buildWorker {
            let generation = catalogGeneration
            guard let built = await buildWorker.value,
                  !Task.isCancelled, generation == catalogGeneration,
                  identity == nextIdentity, built.identity == nextIdentity else { return false }
            index = built
            self.buildWorker = nil
            return true
        }
        catalogGeneration += 1
        queryGeneration += 1
        let generation = catalogGeneration
        searchWorker?.cancel()
        searchWorker = nil
        buildWorker?.cancel()
        index = nil
        identity = nextIdentity

        let worker = Task {
            await LiveTVChannelSearchIndex.build(providerID: providerID,
                                                 catalogRevision: catalogRevision,
                                                 channels: channels)
        }
        buildWorker = worker
        let built = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, generation == catalogGeneration,
              identity == nextIdentity, let built,
              built.identity == nextIdentity else {
            if generation == catalogGeneration, identity == nextIdentity, Task.isCancelled {
                buildWorker = nil
                identity = nil
                index = nil
            }
            return false
        }
        index = built
        buildWorker = nil
        return true
    }

    /// Returns `nil` for an unknown identity, cancellation, or a query superseded by a newer
    /// query/catalog. Successful results are ordered as in the supplied catalog.
    func search(query: String, providerID: UUID,
                catalogRevision: Int) async -> [LiveTVChannelSearchIndex.Match]? {
        queryGeneration += 1
        let generation = queryGeneration
        let expected = LiveTVChannelSearchIndex.Identity(providerID: providerID,
                                                         catalogRevision: catalogRevision)
        searchWorker?.cancel()
        searchWorker = nil
        guard identity == expected else { return nil }

        let sourceIndex: LiveTVChannelSearchIndex
        if let index, index.identity == expected {
            sourceIndex = index
        } else if let buildWorker {
            guard let built = await buildWorker.value,
                  !Task.isCancelled, generation == queryGeneration,
                  identity == expected, built.identity == expected else { return nil }
            sourceIndex = built
            index = built
            self.buildWorker = nil
        } else {
            return nil
        }

        let worker = Task {
            await sourceIndex.search(query: query)
        }
        searchWorker = worker
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, generation == queryGeneration,
              identity == expected, index?.identity == expected,
              let result else { return nil }
        searchWorker = nil
        return result
    }

    /// Invalidates the active catalog; an optional provider guard prevents a late removal for an
    /// old provider from clearing a different provider that has since become active.
    func invalidate(providerID: UUID? = nil) {
        guard providerID == nil || identity?.providerID == providerID else { return }
        catalogGeneration += 1
        queryGeneration += 1
        buildWorker?.cancel()
        searchWorker?.cancel()
        buildWorker = nil
        searchWorker = nil
        identity = nil
        index = nil
    }
}
