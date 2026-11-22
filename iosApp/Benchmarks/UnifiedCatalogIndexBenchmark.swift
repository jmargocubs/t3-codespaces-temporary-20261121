// Build 110 unified Movies/Series index benchmark: 100K IPTV titles (two providers) plus a 10K
// Silo snapshot in the production `XtreamVODCatalogStore`. Compile with the production VOD model,
// scanner, store, unified catalog and index files under `-D KYRO_VOD_HOST_TESTS` (see
// docs/kyro-development/build-110-unified-browsing.md). No Simulator.
import Foundation
import Darwin
import SQLite3

enum LiveTVError: Error {
    case authenticationFailed, accountExpired, invalidXtreamResponse, invalidConfiguration, responseTooLarge
}
enum XtreamURLBuilder {
    static func apiURL(server: String, username: String, password: String,
                       action: String? = nil) throws -> URL {
        guard let url = URL(string: server) else { throw LiveTVError.invalidConfiguration }
        return url
    }
}
struct BrowseItem: Codable, Hashable {
    let contentId: String
    let type: String
    let title: String
    let year: Int?
    let posterUrl: String?
}
enum RequestMediaType { case movie, series }
struct RequestMediaResult {
    let mediaType: RequestMediaType
    let tmdbId: Int
    let title: String
    let year: Int?
}

@main
enum UnifiedCatalogIndexBenchmark {
    static func ms(_ start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: .now).components
        return Double(d.seconds) * 1_000 + Double(d.attoseconds) / 1e15
    }

    static func rssMegabytes() -> Int {
        var info = rusage()
        guard getrusage(RUSAGE_SELF, &info) == 0 else { return -1 }
        return Int(info.ru_maxrss) / 1_048_576
    }

    static let words = ["Silent", "Crimson", "Last", "Lost", "Midnight", "Golden", "Broken", "Hidden",
                        "Winter", "Iron", "Dark", "Bright", "Eternal", "Northern", "Savage", "Quiet"]
    static let nouns = ["River", "Empire", "Garden", "Signal", "Harbor", "Machine", "Kingdom", "Witness",
                        "Mountain", "Protocol", "Storm", "Orchard", "Frontier", "Echo", "Voyage", "Code"]

    static func title(_ n: Int) -> String {
        "\(words[n % 16]) \(nouns[(n / 16) % 16]) \(n / 256)"
    }

    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory())
            .appendingPathComponent("unified-\(UUID().uuidString)")
        let store = try XtreamVODCatalogStore(directory: root)
        let providers = [UUID(uuidString: "00000000-0000-0000-0000-0000000000b1")!,
                         UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!]
        let perProvider = [60_000, 40_000]
        var keyMs = 0.0
        var importMs = 0.0
        for (index, provider) in providers.enumerated() {
            let generation = UUID().uuidString
            let start = ContinuousClock.now
            var batch: [XtreamVODItem] = []
            for n in 0..<perProvider[index] {
                // Provider 2 repeats provider 1's first 40K titles, so ~40K cross-provider matches.
                batch.append(XtreamVODItem(providerID: provider, kind: .movie, remoteID: n + 1,
                                           title: "\(title(n)) (\(1950 + n % 70))", category: "Cat \(n % 40)",
                                           poster: "https://img.example/\(n).jpg", fileExtension: "mkv",
                                           summary: nil, genre: "Drama", rating: "7"))
                if batch.count == 2_000 { try await store.stage(batch, generation: generation); batch.removeAll() }
            }
            try await store.stage(batch, generation: generation)
            try await store.buildPageAnchors(providerID: provider, kind: .movie, generation: generation)
            importMs += ms(start)
            let keys = ContinuousClock.now
            try await store.buildUnifiedKeys(providerID: provider, kind: .movie, generation: generation)
            keyMs += ms(keys)
            try await store.promote(providerID: provider, kind: .movie, generation: generation)
        }

        // 10K Silo titles, every other one matching an IPTV title and year.
        let encoder = JSONEncoder()
        let siloStart = ContinuousClock.now
        let scope = "bench-scope"
        let snapshot = UUID().uuidString
        var records: [UnifiedSiloRecord] = []
        for n in 0..<10_000 {
            let source = n.isMultiple(of: 2) ? n * 3 : 200_000 + n
            let item = BrowseItem(contentId: "movie:\(n)", type: "movie", title: title(source),
                                  year: 1950 + source % 70, posterUrl: "https://silo.example/\(n).jpg")
            records.append(UnifiedSiloRecord(contentID: item.contentId, title: item.title, year: item.year,
                                             poster: item.posterUrl, payload: try encoder.encode(item)))
            if records.count == 60 {
                try await store.stageSilo(records, scope: scope, libraryID: 1, kind: .movie, snapshot: snapshot)
                records.removeAll()
            }
        }
        try await store.stageSilo(records, scope: scope, libraryID: 1, kind: .movie, snapshot: snapshot)
        try await store.promoteSilo(scope: scope, libraryID: 1, kind: .movie, snapshot: snapshot,
                                    itemCount: 10_000, syncedAt: Date())
        let siloMs = ms(siloStart)

        let indexScope = UnifiedIndexScope(kind: .movie, siloScope: scope, siloLibraryIDs: [1], providerIDs: providers)
        let first = ContinuousClock.now
        let firstPage = await store.unifiedPage(indexScope, direction: .forward(after: nil))
        let firstMs = ms(first)

        // Walk the whole catalog forward through the bounded window, as a viewer scrolling to Z would.
        var window = UnifiedCatalogWindow()
        window.rowGranularity = 3
        window.replace(with: firstPage, hasMoreBefore: false)
        var pages = 1, slowest = 0.0, cards = window.cards.count, mergedCards = 0, maxWindow = window.cards.count
        var seen = Set(window.cards.map(\.id))
        let walk = ContinuousClock.now
        while window.hasMoreAfter {
            let t = ContinuousClock.now
            let page = await store.unifiedPage(indexScope, direction: .forward(after: window.forwardCursor))
            slowest = max(slowest, ms(t))
            let before = Set(window.cards.map(\.id))
            window.appendForward(page)
            for card in window.cards where !before.contains(card.id) {
                guard seen.insert(card.id).inserted else { fatalError("duplicate card \(card.id)") }
                cards += 1
                if card.members.count > 1 { mergedCards += 1 }
            }
            maxWindow = max(maxWindow, window.cards.count)
            pages += 1
        }
        let walkMs = ms(walk)
        mergedCards += firstPage.rows.isEmpty ? 0 : UnifiedCatalogGrouping.cards(from: firstPage.rows).filter { $0.members.count > 1 }.count

        // And back to A, restoring every evicted card.
        var backPages = 0, slowestBack = 0.0
        let back = ContinuousClock.now
        while window.hasMoreBefore, let cursor = window.backwardCursor {
            let t = ContinuousClock.now
            let page = await store.unifiedPage(indexScope, direction: .backward(before: cursor))
            slowestBack = max(slowestBack, ms(t))
            window.prependBackward(page)
            backPages += 1
        }
        let backMs = ms(back)
        guard window.cards.first?.id == UnifiedCatalogGrouping.cards(from: firstPage.rows).first?.id else {
            fatalError("backward walk did not return to the first card")
        }

        let noop = ContinuousClock.now
        let rebuilt = try await store.ensureUnifiedKeys()
        let noopMs = ms(noop)
        let counts = await store.unifiedRowCounts()
        let searchStart = ContinuousClock.now
        let search = await store.page(providerID: providers[0], kind: .movie, query: "crimson harbor")
        let searchMs = ms(searchStart)
        await store.close()
        let size = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("catalog.sqlite").path)[.size] as? Int) ?? -1

        print("IPTV rows: \(perProvider.reduce(0, +)) (2 providers), Silo rows: 10000")
        print(String(format: "IPTV stage+anchors: %.0f ms; unified key build (100K): %.0f ms", importMs, keyMs))
        print(String(format: "Silo stage+promote (10K, 60-row pages): %.0f ms", siloMs))
        print(String(format: "first page: %.1f ms", firstMs))
        print(String(format: "forward walk: %d pages, %d cards (%d merged), %.0f ms total, slowest page %.1f ms, max window %d",
                     pages, cards, mergedCards, walkMs, slowest, maxWindow))
        print(String(format: "backward walk: %d pages, %.0f ms total, slowest page %.1f ms", backPages, backMs, slowestBack))
        print(String(format: "ensureUnifiedKeys no-op: %d rebuilt, %.1f ms", rebuilt, noopMs))
        print(String(format: "FTS search (unchanged path): %d results, %.1f ms", search.count, searchMs))
        print("rows: silo \(counts.siloItems), iptv keys \(counts.iptvKeys)")
        print("DB main file: \(size / 1_048_576) MB; peak RSS: \(rssMegabytes()) MB")
    }
}
