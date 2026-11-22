// Compile with the production LiveTVChannelCatalogStore and KYRO_CHANNEL_HOST_TESTS.
// This host-only declaration mirrors the channel value type in LiveTVModels.swift; the SQL actor
// and all measured queries are production code, not a benchmark-specific reimplementation.
import Foundation
import Darwin

struct LiveTVChannel: Hashable, Identifiable, Sendable {
    let id: String
    let guideID: String?
    let name: String
    let streamURL: URL
    let logoURL: URL?
    let category: String
    var streamID: Int? = nil
}

enum LiveTVCatalogLimits { static let maximumChannels = 40_000 }

@main
enum LiveTVChannelStoreBenchmark {
    static let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    static func channel(_ ordinal: Int, provider: UUID = first, category: String? = nil) -> LiveTVChannel {
        LiveTVChannel(id: provider.uuidString + ":" + String(format: "%064x", ordinal + 1),
                      guideID: "epg-\(ordinal + 1)", name: String(format: "Channel %07d", ordinal),
                      streamURL: URL(string: "https://streams.example.test/live/\(ordinal + 1).m3u8")!,
                      logoURL: nil, category: category ?? "Category \(ordinal % 40)", streamID: ordinal + 1)
    }

    static func milliseconds(_ start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now).components
        return Int(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
    }

    static func peakRSSMB() -> Int {
        var info = rusage()
        return getrusage(RUSAGE_SELF, &info) == 0 ? Int(info.ru_maxrss) / 1_048_576 : -1
    }

    static func residentRSSMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) / 1_048_576 : -1
    }

    static func correctness(root: URL) async throws {
        let store = try LiveTVChannelCatalogStore(directory: root.appendingPathComponent("correctness"))
        let original = [channel(0), channel(1)]
        let originalCount = try await LiveTVChannelCatalogImporter.replace(original, providerID: first,
                                                                          in: store, generation: "old")
        precondition(originalCount == 2)
        try await store.setFavorite(true, channelID: original[1].id, providerID: first)
        let other = channel(0, provider: second)
        let otherCount = try await store.stage([other], providerID: second, generation: "old", startingOrdinal: 0)
        precondition(otherCount == 1)
        try await store.promote(providerID: second, generation: "old", expectedCount: 1)
        let replacement = [channel(0, category: "New Category"), channel(1, category: "New Category")]
        let interruptedCount = try await store.stage([replacement[0]], providerID: first,
                                                     generation: "interrupted", startingOrdinal: 0)
        precondition(interruptedCount == 1)
        do {
            try await store.promote(providerID: first, generation: "interrupted", expectedCount: 2)
            preconditionFailure("incomplete generation promoted")
        } catch LiveTVChannelCatalogStore.StoreError.invalidGeneration { }
        let stillOld = await store.page(providerID: first)
        precondition(stillOld.map(\.category) == original.map(\.category))
        let replacementCount = try await LiveTVChannelCatalogImporter.replace(replacement, providerID: first,
                                                                              in: store, generation: "new")
        precondition(replacementCount == 2)
        let activeBeforeRollback = await store.activeGeneration(providerID: first)
        precondition(activeBeforeRollback == "new")
        let raced = [channel(0, category: "Raced Category"), channel(1, category: "Raced Category")]
        let racedCount = try await store.stage(raced, providerID: first,
                                               generation: "raced", startingOrdinal: 0)
        try await store.promote(providerID: first, generation: "raced", expectedCount: racedCount)
        try await store.restoreActiveGeneration(providerID: first, generation: activeBeforeRollback)
        let current = await store.page(providerID: first)
        let favorites = await store.page(providerID: first, favoritesOnly: true)
        let oldProvider = await store.page(providerID: second)
        precondition(current.map(\.category) == ["New Category", "New Category"])
        precondition(favorites.map(\.id) == [original[1].id])
        try await store.replaceFavorites([original[0].id], providerID: first)
        let reconciledFavorites = await store.page(providerID: first, favoritesOnly: true)
        precondition(reconciledFavorites.map(\.id) == [original[0].id])
        precondition(oldProvider.map(\.id) == [other.id])
        let collision = await store.channel(providerID: first, id: other.id)
        let guideMatched = await store.channel(providerID: first, id: original[0].id)
        let guideIDs = await store.channelIDs(providerID: first, guideID: "epg-1")
        let ordered = await store.channels(providerID: first,
                                           ids: [original[1].id, other.id, original[0].id])
        let secondOffset = await store.offset(providerID: first, channelID: original[1].id,
                                              category: "New Category")
        let epgAssociations = await store.epgAssociationValues(providerID: first)
        let programAssociations = await store.programAssociations(providerID: first)
        let containsSecond = await store.contains(providerID: first, id: original[1].id)
        precondition(collision == nil)
        precondition(guideMatched?.guideID == "epg-1")
        precondition(guideIDs == [original[0].id])
        precondition(containsSecond)
        precondition(ordered.map(\.id) == [original[1].id, original[0].id])
        precondition(secondOffset == 1)
        precondition(epgAssociations?.names == replacement.map(\.name))
        precondition(programAssociations.map(\.id) == replacement.map(\.id))
        let cancelledImport = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await store.stage([channel(2)], providerID: first,
                                          generation: "cancelled", startingOrdinal: 0)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let cancellationWorked = await cancelledImport.value
        precondition(cancellationWorked)
        await store.close()
        let recovered = try LiveTVChannelCatalogStore(directory: root.appendingPathComponent("correctness"))
        try await recovered.pruneOrphans()
        let restoredCount = await recovered.count(providerID: first)
        let restoredFavorites = await recovered.page(providerID: first, favoritesOnly: true)
        let offline = await LiveTVChannelCatalogImporter.restore(providerID: first, from: recovered)
        precondition(restoredCount == 2)
        precondition(restoredFavorites.count == 1)
        precondition(offline?.map(\.guideID) == replacement.map(\.guideID))
        precondition(offline?.allSatisfy { $0.streamURL.scheme == "about" } == true)
        await recovered.close()
        print("host_snapshot_provider_favorites_epg,pass")
    }

    static func run(count: Int, root: URL) async throws {
        let directory = root.appendingPathComponent("channels-\(count)")
        let store = try LiveTVChannelCatalogStore(directory: directory)
        var nextOrdinal = 0
        let start = ContinuousClock.now
        let imported = try await LiveTVChannelCatalogImporter.replaceBatches(
            providerID: first, in: store, generation: "benchmark"
        ) {
            guard nextOrdinal < count else { return nil }
            let end = min(nextOrdinal + LiveTVChannelCatalogImporter.batchSize, count)
            let batch = (nextOrdinal..<end).map { channel($0) }
            nextOrdinal = end
            return batch
        }
        precondition(imported.channelCount == count)
        let importMS = milliseconds(start)
        let streamingImportPeakRSS = peakRSSMB()
        let searchStart = ContinuousClock.now
        let search = await store.page(providerID: first, query: "Channel 0001234")
        let searchMS = milliseconds(searchStart)
        let broadSearchStart = ContinuousClock.now
        let broadSearch = await store.page(providerID: first, query: "Channel")
        let broadSearchMS = milliseconds(broadSearchStart)
        let categoryStart = ContinuousClock.now
        let category = await store.page(providerID: first, category: "Category 17", offset: 100)
        let categoryMS = milliseconds(categoryStart)
        let deepCategoryStart = ContinuousClock.now
        let deepCategory = await store.page(providerID: first, category: "Category 17",
                                            offset: count / 40 - 100)
        let deepCategoryMS = milliseconds(deepCategoryStart)
        let guideStart = ContinuousClock.now
        let guide = await store.page(providerID: first, offset: count - 100)
        let guideMS = milliseconds(guideStart)
        let keysetStart = ContinuousClock.now
        let keyset = await store.page(providerID: first, afterOrdinal: count - 101)
        let keysetMS = milliseconds(keysetStart)
        let epgStart = ContinuousClock.now
        let epgIDs = await store.channelIDs(providerID: first, guideID: "epg-\(count)")
        let epgMS = milliseconds(epgStart)
        // Sports guide-key retrieval: mixed-case lookup must hit the normalized guide ID.
        let sportsKeyStart = ContinuousClock.now
        let sportsKeyed = await store.channels(providerID: first, guideKeys: ["epg-\(count)", "epg-1", "missing"])
        let sportsKeyMS = milliseconds(sportsKeyStart)
        precondition(Set(sportsKeyed.map(\.id)) == [channel(count - 1).id, channel(0).id])
        let categories = await store.categories(providerID: first)
        let stored = await store.count(providerID: first)
        let isolated = await store.count(providerID: second)
        let searchCount = await store.count(providerID: first, query: "Channel 0001234",
                                            category: nil, favoritesOnly: false)
        let categoryCount = await store.count(providerID: first, query: "",
                                              category: "Category 17", favoritesOnly: false)
        precondition(stored == count && isolated == 0 && search.count == 1 && search[0].streamID == 1_235)
        precondition(searchCount == 1 && categoryCount == count / 40)
        precondition(category.count == 100 && deepCategory.count == 100
                     && guide.count == 100 && keyset.count == 100 && broadSearch.count == 100)
        precondition(epgIDs == [channel(count - 1).id])
        precondition(guide.first?.streamID == count - 99 && guide.last?.streamID == count)
        precondition(categories.count == 40 && categories.reduce(0) { $0 + $1.count } == count)
        let last = channel(count - 1)
        let resolved = await store.channel(providerID: first, id: last.id)
        let containsLast = await store.contains(providerID: first, id: last.id)
        precondition(resolved?.guideID == last.guideID && resolved?.streamURL == last.streamURL)
        precondition(containsLast)
        let deepOffset = await store.offset(providerID: first, channelID: last.id)
        let deepCategoryOffset = await store.offset(providerID: first, channelID: last.id,
                                                    category: last.category)
        precondition(deepOffset == count - 1 && deepCategoryOffset == count / 40 - 1)
        let resolvedIDs = await store.channels(providerID: first,
                                               ids: [last.id, channel(0).id], limit: 2)
        precondition(resolvedIDs.map(\.id) == [last.id, channel(0).id])
        try await store.setFavorite(true, channelID: last.id, providerID: first)
        let favorites = await store.page(providerID: first, favoritesOnly: true)
        let favoriteCount = await store.count(providerID: first, query: "", category: nil, favoritesOnly: true)
        let summaries = await store.categorySummaries(providerID: first)
        precondition(favorites.map(\.id) == [last.id] && favoriteCount == 1)
        precondition(summaries.count == 40 && summaries.reduce(0) { $0 + $1.channelCount } == count
                     && summaries.reduce(0) { $0 + $1.favoriteCount } == 1)
        // These compact projections are the largest remaining association payloads. They omit
        // stream/artwork URLs and full channel values; measure them explicitly instead of
        // recreating the compatibility catalog that production no longer retains.
        var epgAssociations = await store.epgAssociationValues(providerID: first)
        var programAssociations = await store.programAssociations(providerID: first)
        precondition(epgAssociations?.names.count == count && programAssociations.count == count)
        let compactAssociationRSS = residentRSSMB()
        epgAssociations = nil
        programAssociations = []
        let retainedAfterAssociationsRSS = residentRSSMB()
        await store.close()
        let retainedRSS = residentRSSMB()
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("channels.sqlite").path)
        let bytes = (attributes[.size] as? NSNumber)?.intValue ?? -1
        print("\(count),\(importMS),\(searchMS),\(broadSearchMS),\(categoryMS),\(deepCategoryMS),\(guideMS),\(keysetMS),\(epgMS),\(sportsKeyMS),\(bytes),\(streamingImportPeakRSS),\(peakRSSMB()),\(compactAssociationRSS),\(retainedAfterAssociationsRSS),\(retainedRSS)")
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else {
            fputs("usage: live-tv-channel-benchmark TEMP_DIRECTORY [CHANNEL_COUNT]\n", stderr)
            exit(2)
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try await correctness(root: root)
        print("count,import_ms,search_ms,broad_search_ms,category_ms,deep_category_ms,guide_page_ms,keyset_page_ms,epg_lookup_ms,sports_guide_key_ms,sqlite_bytes,streaming_import_peak_rss_mb,process_peak_rss_mb,compact_association_rss_mb,retained_after_associations_rss_mb,retained_after_close_rss_mb")
        let counts: [Int]
        if CommandLine.arguments.count == 3 {
            guard let count = Int(CommandLine.arguments[2]), count > 0 else {
                fputs("CHANNEL_COUNT must be a positive integer\n", stderr)
                exit(2)
            }
            counts = [count]
        } else {
            counts = [40_000, 60_000, 80_000, 100_000]
        }
        for count in counts { try await run(count: count, root: root) }
    }
}
