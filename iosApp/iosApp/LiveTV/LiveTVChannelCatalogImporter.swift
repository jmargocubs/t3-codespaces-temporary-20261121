#if os(iOS) || KYRO_CHANNEL_HOST_TESTS
import Foundation
import CryptoKit

/// Production bridge from provider catalog input into the generation-scoped channel store.
/// Streaming inputs retain at most one 1,024-channel staging batch and never change the visible
/// generation until all rows validate. The array overload remains only for legacy callers/tests.
enum LiveTVChannelCatalogImporter {
    static let batchSize = 1_024

    struct Result: Equatable, Sendable {
        let channelCount: Int
        let batchCount: Int
    }

    struct M3UResult: Equatable, Sendable {
        let generation: String
        let channelCount: Int
        let hitChannelLimit: Bool
    }

    typealias XtreamResult = M3UResult

    struct StagedResult: Equatable, Sendable {
        let generation: String
        let channelCount: Int
        let batchCount: Int
    }

    /// Consumes a producer one bounded batch at a time. The producer may parse a file, network
    /// body, or synthetic fixture without ever constructing the complete channel array.
    /// Returning `nil` ends the generation; an empty batch is invalid because it could otherwise
    /// turn a stalled producer into an infinite import.
    @discardableResult
    static func stageBatches(providerID: UUID, in store: LiveTVChannelCatalogStore,
                             generation: String = UUID().uuidString,
                             nextBatch: () async throws -> [LiveTVChannel]?) async throws -> StagedResult {
        try Task.checkCancellation()
        var ordinal = 0
        var batches = 0
        while let batch = try await nextBatch() {
            try Task.checkCancellation()
            guard !batch.isEmpty, batch.count <= batchSize else {
                throw LiveTVChannelCatalogStore.StoreError.invalidGeneration
            }
            let accepted = try await store.stage(batch, providerID: providerID,
                                                 generation: generation, startingOrdinal: ordinal)
            guard accepted == batch.count else {
                throw LiveTVChannelCatalogStore.StoreError.invalidGeneration
            }
            ordinal += accepted
            batches += 1
        }
        try Task.checkCancellation()
        guard ordinal > 0 else { throw LiveTVChannelCatalogStore.StoreError.invalidGeneration }
        return StagedResult(generation: generation, channelCount: ordinal, batchCount: batches)
    }

    @discardableResult
    static func replaceBatches(providerID: UUID, in store: LiveTVChannelCatalogStore,
                               generation: String = UUID().uuidString,
                               nextBatch: () async throws -> [LiveTVChannel]?) async throws -> Result {
        let staged = try await stageBatches(providerID: providerID, in: store,
                                            generation: generation, nextBatch: nextBatch)
        try Task.checkCancellation()
        try await store.promote(providerID: providerID, generation: generation,
                                expectedCount: staged.channelCount)
        try? await store.pruneOrphans()
        return Result(channelCount: staged.channelCount, batchCount: staged.batchCount)
    }

    @discardableResult
    static func replace(_ channels: [LiveTVChannel], providerID: UUID,
                        in store: LiveTVChannelCatalogStore,
                        generation: String = UUID().uuidString) async throws -> Int {
        var ordinal = 0
        let result = try await replaceBatches(providerID: providerID, in: store, generation: generation) {
            guard ordinal < channels.count else { return nil }
            let end = min(ordinal + batchSize, channels.count)
            defer { ordinal = end }
            return Array(channels[ordinal..<end])
        }
        return result.channelCount
    }

    #if os(iOS)
    /// Parses and stages an M3U body without constructing a full catalog array. The downloaded
    /// bytes remain the largest transient allocation; the parser retains only deduplication keys
    /// and one 1,024-channel batch until atomic promotion.
    static func stageM3U(data: Data, providerID: UUID, in store: LiveTVChannelCatalogStore,
                         limit: Int = LiveTVCatalogLimits.maximumChannels,
                         generation: String = UUID().uuidString) async throws -> M3UResult {
        var scanner = try LiveTVM3UParser.StreamingScanner(data: data, providerID: providerID, limit: limit)
        let result = try await stageBatches(providerID: providerID, in: store, generation: generation) {
            try scanner.nextBatch(maximumCount: batchSize)
        }
        return M3UResult(generation: generation, channelCount: result.channelCount,
                         hitChannelLimit: scanner.hitChannelLimit)
    }

    /// Decodes Xtream live records one top-level JSON member at a time. The scanner and pending
    /// member buffers are bounded by one input chunk; decoded records are released after their
    /// 1,024-channel store batch commits.
    static func stageXtream(data: Data, providerID: UUID, in store: LiveTVChannelCatalogStore,
                            server: String, username: String, password: String,
                            outputFormats: [String], categories: [String: String],
                            limit: Int = LiveTVCatalogLimits.maximumChannels,
                            generation: String = UUID().uuidString) async throws -> XtreamResult {
        guard limit > 0 else { throw LiveTVError.invalidXtreamResponse }
        var scanner = XtreamVODCatalogScanner(maximumMemberBytes: 1 * 1024 * 1024)
        let decoder = JSONDecoder()
        var seen = Set<Int>()
        var batch: [LiveTVChannel] = []
        batch.reserveCapacity(batchSize)
        var accepted = 0
        var hitChannelLimit = false
        let chunkBytes = 1 << 20
        var offset = 0

        while offset < data.count, !hitChannelLimit {
            try Task.checkCancellation()
            let end = min(offset + chunkBytes, data.count)
            var members: [XtreamVODCatalogScanner.Member] = []
            do {
                try data.withUnsafeBytes { raw in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    let chunk = UnsafeBufferPointer(rebasing: bytes[offset..<end])
                    try scanner.consume(chunk) { member in members.append(member); return true }
                }
            } catch {
                throw LiveTVError.invalidXtreamResponse
            }
            offset = end
            for member in members where member.isObject {
                try Task.checkCancellation()
                if accepted + batch.count >= limit {
                    hitChannelLimit = true
                    break
                }
                guard let bytes = member.bytes,
                      let record = try? decoder.decode(XtreamLiveStreamResponse.self, from: Data(bytes)),
                      let streamID = record.streamID, streamID > 0, seen.insert(streamID).inserted,
                      let name = record.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else { continue }
                let streamURL = try XtreamURLBuilder.streamURL(
                    server: server, username: username, password: password, streamID: streamID,
                    extension: record.containerExtension, allowedOutputFormats: outputFormats
                )
                let digest = LiveTVM3UParser.hex(SHA256.hash(
                    data: Data("\(providerID.uuidString)|xtream|\(streamID)".utf8)
                ))
                batch.append(LiveTVChannel(
                    id: "\(providerID.uuidString):\(digest)",
                    guideID: record.epgChannelID.flatMap {
                        let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        return value.isEmpty ? nil : value
                    } ?? String(streamID),
                    name: name,
                    streamURL: streamURL,
                    logoURL: record.streamIcon.flatMap { URL(string: $0) }.flatMap {
                        ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil ? $0 : nil
                    },
                    category: record.categoryID.flatMap { categories[$0] } ?? "Other",
                    streamID: streamID
                ))
                if batch.count == batchSize {
                    let inserted = try await store.stage(batch, providerID: providerID,
                                                         generation: generation, startingOrdinal: accepted)
                    guard inserted == batch.count else {
                        throw LiveTVChannelCatalogStore.StoreError.invalidGeneration
                    }
                    accepted += inserted
                    batch.removeAll(keepingCapacity: true)
                }
            }
        }
        if !hitChannelLimit {
            do { try scanner.finish() } catch { throw LiveTVError.invalidXtreamResponse }
        }
        if !batch.isEmpty {
            let inserted = try await store.stage(batch, providerID: providerID,
                                                 generation: generation, startingOrdinal: accepted)
            guard inserted == batch.count else {
                throw LiveTVChannelCatalogStore.StoreError.invalidGeneration
            }
            accepted += inserted
        }
        guard accepted > 0 else { throw LiveTVError.noChannels }
        return XtreamResult(generation: generation, channelCount: accepted,
                            hitChannelLimit: hitChannelLimit)
    }
    #endif

    /// Transitional offline bridge. A cached channel is intentionally non-playable, matching the
    /// existing JSON snapshot rule; a fresh provider refresh supplies its current stream URL.
    static func restore(providerID: UUID, from store: LiveTVChannelCatalogStore,
                        maximumChannels: Int = LiveTVCatalogLimits.maximumChannels,
                        playable: Bool = false) async -> [LiveTVChannel]? {
        guard let stored = await store.offlineCatalog(providerID: providerID, maximumChannels: maximumChannels) else {
            return nil
        }
        if playable { return stored }
        var result: [LiveTVChannel] = []
        result.reserveCapacity(stored.count)
        let offlineURL = URL(string: "about:blank")!
        for channel in stored {
            result.append(LiveTVChannel(id: channel.id, guideID: channel.guideID, name: channel.name,
                                        streamURL: offlineURL, logoURL: channel.logoURL,
                                        category: channel.category, streamID: channel.streamID))
        }
        return result
    }
}
#endif
