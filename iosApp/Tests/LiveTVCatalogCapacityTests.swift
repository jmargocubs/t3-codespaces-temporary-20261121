import Foundation
import CryptoKit
import XCTest
@testable import Silo

/// Build 38: the 40,000-channel catalog (import, identity, persistence, search and event
/// matching) and the shared-guide-ID event channels Build 37 dropped on import.
final class LiveTVCatalogCapacityTests: XCTestCase {
    private let providerID = UUID(uuidString: "6F1C2B5E-9B7C-4E0B-A2E4-1D3C5B7A9F00")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Production cap

    /// The 100K validation override is compile-time only; an ordinary build must keep 40,000.
    func testProductionCapIsFortyThousandWithoutValidationFlag() {
        #if KYRO_LIVETV_100K_VALIDATION
        XCTAssertEqual(LiveTVCatalogLimits.maximumChannels, 100_000)
        XCTAssertTrue(LiveTVCatalogLimits.isValidationOverrideActive)
        #else
        XCTAssertEqual(LiveTVCatalogLimits.maximumChannels, 40_000)
        XCTAssertFalse(LiveTVCatalogLimits.isValidationOverrideActive)
        #endif
        XCTAssertEqual(LiveTVCatalogLimits.productionMaximumChannels, 40_000)
    }

    // MARK: Identity

    func testEventChannelsSharingAGuideIDAreAllImported() throws {
        let playlist = """
        #EXTM3U
        #EXTINF:-1 tvg-id="DAZN1.uk" group-title="UK | DAZN",DAZN 1 UK
        http://iptv.example/live/1.ts
        #EXTINF:-1 tvg-id="DAZN1.uk" group-title="DAZN EVENTS",DAZN UK: Michigan State @ Michigan
        http://iptv.example/live/2.ts
        #EXTINF:-1 tvg-id="DAZN1.uk" group-title="DAZN EVENTS",DAZN UK: Arsenal v Spurs
        http://iptv.example/live/3.ts
        #EXTINF:-1 tvg-id="DAZN1.uk" group-title="DAZN EVENTS",DAZN UK: Michigan State @ Michigan
        http://iptv.example/live/4.ts
        """
        let channels = try LiveTVM3UParser.parse(data: Data(playlist.utf8), providerID: providerID)
        XCTAssertEqual(channels.map(\.name), ["DAZN 1 UK", "DAZN UK: Michigan State @ Michigan", "DAZN UK: Arsenal v Spurs"],
                       "every differently named event feed is kept; an exact repeat is not")
        XCTAssertEqual(Set(channels.map(\.id)).count, 3)
        XCTAssertEqual(channels[0].id, legacyID("dazn1.uk"), "the first channel keeps its Build 37 identity")
        XCTAssertTrue(channels.allSatisfy { $0.guideID == "DAZN1.uk" }, "every variant keeps the shared guide")

        let again = try LiveTVM3UParser.parse(data: Data(playlist.utf8), providerID: providerID)
        XCTAssertEqual(again.map(\.id), channels.map(\.id), "identities are stable across refreshes")
    }

    func testChannelsWithoutGuideIDKeepTheirNameIdentity() throws {
        let playlist = "#EXTM3U\n#EXTINF:-1 group-title=\"Events\",NCAAF 03: SHSU @ JXST\nhttp://iptv.example/9.ts\n"
        let channels = try LiveTVM3UParser.parse(data: Data(playlist.utf8), providerID: providerID)
        XCTAssertEqual(channels.first?.id, legacyID("ncaaf 03: shsu @ jxst"))
        XCTAssertEqual(channels.first?.category, "Events")
    }

    // MARK: 20,000 and 40,000

    func test20kCatalogRegression() throws {
        let data = KyroSyntheticCatalog.playlist(count: 20_000)
        let parsed = try LiveTVM3UParser.parseResult(data: data, providerID: providerID)
        XCTAssertEqual(parsed.channels.count, 20_000)
        XCTAssertFalse(parsed.hitChannelLimit)
        XCTAssertEqual(Set(parsed.channels.map(\.id)).count, 20_000)
        let legacyCap = try LiveTVM3UParser.parseResult(data: data, providerID: providerID, limit: 20_000)
        XCTAssertEqual(legacyCap.channels.map(\.id), parsed.channels.map(\.id), "same identities as the 20,000 cap")
    }

    func test40kImportKeepsEveryChannelAndStopsAtTheCap() throws {
        let parsed = try LiveTVM3UParser.parseResult(data: KyroSyntheticCatalog.playlist(count: 40_000), providerID: providerID)
        XCTAssertEqual(parsed.channels.count, 40_000)
        XCTAssertFalse(parsed.hitChannelLimit, "an exact-cap playlist is not truncated")
        XCTAssertEqual(Set(parsed.channels.map(\.id)).count, 40_000)
        XCTAssertEqual(parsed.channels.last?.name, KyroSyntheticCatalog.name(39_999), "the tail, where event groups sit, is kept")

        let over = try LiveTVM3UParser.parseResult(data: KyroSyntheticCatalog.playlist(count: 40_001), providerID: providerID)
        XCTAssertEqual(over.channels.count, LiveTVCatalogLimits.maximumChannels)
        XCTAssertTrue(over.hitChannelLimit)
    }

    func test40kCategoryMembership() throws {
        let channels = try LiveTVM3UParser.parse(data: KyroSyntheticCatalog.playlist(count: 40_000), providerID: providerID)
        let categories = LiveTVChannel.orderedCategories(of: channels)
        XCTAssertEqual(categories.count, KyroSyntheticCatalog.categoryCount)
        let events = channels.filter { $0.category == "DAZN EVENTS" }
        XCTAssertEqual(events.count, (0..<40_000).filter { $0 % 50 == 7 }.count, "every event channel keeps its group")
        XCTAssertTrue(events.allSatisfy { $0.name.contains(": ") })
        XCTAssertEqual(Set(channels.map(\.category)), Set(categories))
    }

    func test40kSnapshotPersistsAndRestores() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KyroCatalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LiveTVChannelSnapshotStore(directory: directory)
        let channels = try LiveTVM3UParser.parse(data: KyroSyntheticCatalog.playlist(count: 40_000), providerID: providerID)
        let saved = await store.save(providerID: providerID, channels: channels)
        XCTAssertEqual(saved, .saved)
        let size = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("\(providerID.uuidString).json").path)[.size] as? Int
        XCTAssertLessThan(size ?? .max, LiveTVChannelSnapshotStore.maximumFileBytes)
        let restored = await store.loadCatalog(providerID: providerID)
        XCTAssertEqual(restored?.channels.count, 40_000, "a 40,000-channel snapshot is no longer deleted on load")
        XCTAssertEqual(restored?.channels.map(\.id), channels.map(\.id))
        XCTAssertEqual(restored?.channels.map(\.guideID), channels.map(\.guideID))
        XCTAssertTrue(restored?.channels.allSatisfy { $0.streamURL.absoluteString == "about:blank" } == true,
                      "no stream address is persisted")

        let tooMany = channels + [LiveTVChannel(id: "\(providerID.uuidString):\(String(repeating: "a", count: 64))", guideID: nil,
                                                name: "Extra", streamURL: URL(string: "https://x.example/1.ts")!,
                                                logoURL: nil, category: "Other")]
        let refused = await store.save(providerID: providerID, channels: tooMany)
        XCTAssertEqual(refused, .refusedOverChannelLimit)
        let kept = await store.loadCatalog(providerID: providerID)
        XCTAssertEqual(kept?.channels.count, 40_000, "a refused write leaves the valid snapshot")
    }

    func test40kSearchAndEventMatching() async throws {
        let channels = try LiveTVM3UParser.parse(data: KyroSyntheticCatalog.playlist(count: 40_000), providerID: providerID)
        let search = await LiveTVChannelSearchIndex.build(providerID: providerID, catalogRevision: 1, channels: channels)
        let found = await search?.search(query: "Michigan State")
        XCTAssertEqual(found?.count, channels.filter { $0.name.contains("Michigan State") }.count)

        #if os(iOS)
        let index = try XCTUnwrap(KyroSportsChannelIndex.build(channels: channels, providerID: providerID, catalogRevision: 1))
        let result = KyroSportsStreamMatcher.match(request: .init(game: KyroSyntheticCatalog.michiganGame(now: now), now: now),
                                                   index: index, guide: nil, guideKeys: nil)
        let expected = channels.filter { $0.name.hasSuffix(": Michigan State @ Michigan") }
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(result.matches.count, min(expected.count, KyroSportsStreamMatcher.maximumMatches))
        XCTAssertTrue(Set(result.matches.map(\.channel.id)).isSubset(of: Set(expected.map(\.id))), "only this matchup")
        XCTAssertFalse(result.autoPlayCandidates.isEmpty)
        XCTAssertLessThan(result.diagnostics.nameCandidates, 2_000, "a tap evaluates candidates, not the catalog")
        #endif
    }

    #if os(iOS)
    func test40kGuideAssociationsGroupSharedGuideIDs() throws {
        let channels = try LiveTVM3UParser.parse(data: KyroSyntheticCatalog.playlist(count: 40_000), providerID: providerID)
        let guideIDs = Array(Set(channels.compactMap(\.guideID))).sorted()
        let document = EPGDocument(channels: guideIDs.map { EPGChannel(id: $0, displayNames: [$0]) },
                                   programs: guideIDs.map { EPGProgram(channelID: $0, start: now, end: now.addingTimeInterval(3600), title: "Show") })
        let guide = try EPGIndex(document: document, fetchedAt: now, now: now, limits: EPGLimits())
        let index = try XCTUnwrap(KyroSportsChannelIndex.build(channels: channels))
        let map = try XCTUnwrap(index.guideKeyMap(for: guide))
        let grouped = Dictionary(grouping: channels.filter { $0.guideID != nil }) { $0.guideID!.lowercased() }
        XCTAssertEqual(map.count, grouped.count)
        for (key, members) in grouped.prefix(200) {
            XCTAssertEqual(map[key]?.count, members.count, key)
        }
    }
    #endif

    // MARK: Helpers

    private func legacyID(_ source: String) -> String {
        let digest = SHA256.hash(data: Data("\(providerID.uuidString)|\(source)".utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(providerID.uuidString):\(digest)"
    }
}

// MARK: - Benchmarks (opt-in)

/// Run with `KYRO_BENCH_CHANNELS=40000` (or 20000). Prints `KYRO-BENCH` lines; no stream URL,
/// credential or playlist content is printed.
final class LiveTVCatalogBenchmarkTests: XCTestCase {
    private let providerID = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCatalogPipelineBenchmark() async throws {
        guard let raw = ProcessInfo.processInfo.environment["KYRO_BENCH_CHANNELS"], let count = Int(raw) else {
            throw XCTSkip("set KYRO_BENCH_CHANNELS to run")
        }
        func ms(_ start: UInt64) -> String { String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6) }
        func line(_ text: String) { print("KYRO-BENCH n=\(count) \(text) footprint_mb=\(KyroSyntheticCatalog.footprintMB())") }

        line("baseline")
        var start = DispatchTime.now().uptimeNanoseconds
        let data = KyroSyntheticCatalog.playlist(count: count)
        line("playlist_bytes=\(data.count) generate_ms=\(ms(start))")

        start = DispatchTime.now().uptimeNanoseconds
        let parsed = try LiveTVM3UParser.parseResult(data: data, providerID: providerID)
        line("m3u_parse_ms=\(ms(start)) channels=\(parsed.channels.count) truncated=\(parsed.hitChannelLimit)")
        let channels = parsed.channels

        start = DispatchTime.now().uptimeNanoseconds
        let xtream = KyroSyntheticCatalog.xtreamStreams(count: count)
        let records = try XtreamResponseParser.streams(from: xtream)
        line("xtream_bytes=\(xtream.count) xtream_decode_ms=\(ms(start)) records=\(records.count) fits_cap=\(xtream.count <= LiveTVCatalogLimits.maximumPlaylistBytes)")

        start = DispatchTime.now().uptimeNanoseconds
        let categories = LiveTVChannel.orderedCategories(of: channels)
        line("categories_ms=\(ms(start)) categories=\(categories.count)")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KyroBench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LiveTVChannelSnapshotStore(directory: directory)
        start = DispatchTime.now().uptimeNanoseconds
        let saved = await store.save(providerID: providerID, channels: channels)
        let size = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("\(providerID.uuidString).json").path)[.size] as? Int) ?? -1
        line("snapshot_save_ms=\(ms(start)) result=\(saved) snapshot_bytes=\(size)")
        start = DispatchTime.now().uptimeNanoseconds
        let restored = await store.loadCatalog(providerID: providerID)
        line("snapshot_load_ms=\(ms(start)) restored=\(restored?.channels.count ?? -1)")

        start = DispatchTime.now().uptimeNanoseconds
        let search = await LiveTVChannelSearchIndex.build(providerID: providerID, catalogRevision: 1, channels: channels)
        line("search_index_ms=\(ms(start))")
        for query in ["espn", "Michigan State", "zzzz-none"] {
            start = DispatchTime.now().uptimeNanoseconds
            let hits = await search?.search(query: query)
            line("search_ms=\(ms(start)) query_len=\(query.count) hits=\(hits?.count ?? -1)")
        }

        #if os(iOS)
        start = DispatchTime.now().uptimeNanoseconds
        let index = try XCTUnwrap(KyroSportsChannelIndex.build(channels: channels, providerID: providerID, catalogRevision: 1))
        line("match_index_ms=\(ms(start)) tokens=\(index.tokenCount)")

        // In-memory guide: one programme block per unique guide ID, capped like production.
        let guideIDs = Array(Set(channels.compactMap(\.guideID))).sorted()
        let document = KyroSyntheticCatalog.guide(guideIDs: guideIDs, now: now)
        start = DispatchTime.now().uptimeNanoseconds
        let memoryGuide = try EPGIndex(document: document, fetchedAt: now, now: now, limits: EPGLimits())
        line("epg_memory_index_ms=\(ms(start)) guide_channels=\(guideIDs.count) programmes=\(memoryGuide.programCount)")
        start = DispatchTime.now().uptimeNanoseconds
        let memoryKeys = try XCTUnwrap(index.guideKeyMap(for: memoryGuide))
        line("guide_key_map_ms=\(ms(start)) keys=\(memoryKeys.count)")
        let game = KyroSyntheticCatalog.michiganGame(now: now)
        for _ in 0..<3 {
            start = DispatchTime.now().uptimeNanoseconds
            let result = KyroSportsStreamMatcher.match(request: .init(game: game, now: now), index: index, guide: memoryGuide, guideKeys: memoryKeys)
            line("match_memory_guide_ms=\(ms(start)) matches=\(result.matches.count) auto=\(result.autoPlayCandidates.count) guide_rows=\(result.diagnostics.guideRows) name_candidates=\(result.diagnostics.nameCandidates)")
        }

        // SQLite guide built from XMLTV, the production large-guide backend.
        let xml = KyroSyntheticCatalog.xmltv(document: document)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("KyroBench-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: destination) }
        start = DispatchTime.now().uptimeNanoseconds
        let built = try EPGSQLiteBuilder.build(xml: xml, filter: nil, limits: EPGLimits(), fetchedAt: now, providerID: providerID,
                                                fingerprint: Data(repeating: 0, count: EPGSourceFingerprint.length),
                                                destination: destination, readPolicy: .cachedOnly)
        line("epg_sqlite_build_ms=\(ms(start)) xml_bytes=\(xml.count)")
        let sqliteGuide = EPGIndex(sqlite: built.index, statistics: built.statistics)
        start = DispatchTime.now().uptimeNanoseconds
        let sqliteKeys = try XCTUnwrap(index.guideKeyMap(for: sqliteGuide))
        line("guide_key_map_sqlite_ms=\(ms(start)) keys=\(sqliteKeys.count)")
        for _ in 0..<3 {
            start = DispatchTime.now().uptimeNanoseconds
            let result = KyroSportsStreamMatcher.match(request: .init(game: game, now: now), index: index, guide: sqliteGuide, guideKeys: sqliteKeys)
            line("match_sqlite_guide_ms=\(ms(start)) matches=\(result.matches.count) auto=\(result.autoPlayCandidates.count) guide_rows=\(result.diagnostics.guideRows)")
        }
        start = DispatchTime.now().uptimeNanoseconds
        let window = DateInterval(start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(7200))
        let rows = sqliteGuide.windowPrograms(overlapping: window, anchors: ["michigan", "spartans", "wolverines"])
        line("sqlite_window_query_ms=\(ms(start)) rows=\(rows.count)")

        // Cancellation: a superseded index build stops early.
        let gate = AsyncStream<Void>.makeStream()
        let cancelled = Task { () -> KyroSportsChannelIndex? in
            for await _ in gate.stream { break }
            return KyroSportsChannelIndex.build(channels: channels)
        }
        cancelled.cancel()
        gate.continuation.finish()
        let value = await cancelled.value
        line("cancelled_build_returned_nil=\(value == nil)")
        #endif
    }
}

// MARK: - Synthetic data

enum KyroSyntheticCatalog {
    /// "DAZN EVENTS" plus 300 groups, minus the six groups whose residues only event rows hit.
    static let categoryCount = 295

    private static let networks = ["ESPN", "FOX", "CBS", "NBC", "ABC", "TNT", "DAZN", "Sky Sports", "BBC", "beIN"]
    private static let matchups = [
        "Michigan State @ Michigan", "SHSU @ JXST", "Ohio State vs Penn State", "Arsenal v Spurs",
        "Lakers @ Celtics", "Bears at Lions", "Rangers vs Devils", "Yankees @ Red Sox"
    ]

    /// Channel names are deterministic: 2% are event channels, a quarter share a guide ID with
    /// their HD/SD/backup siblings, and the rest are ordinary channels.
    static func name(_ index: Int) -> String {
        if index % 50 == 7 {
            return "DAZN \(index): \(matchups[(index / 50) % matchups.count])"
        }
        let network = networks[(index / 4) % networks.count]
        let suffix = ["", " HD", " SD", " (Backup)"][index % 4]
        return "\(network) \(index / 4)\(suffix)"
    }

    static func category(_ index: Int) -> String {
        index % 50 == 7 ? "DAZN EVENTS" : "Group \(index % (categoryCount - 1))"
    }

    static func guideID(_ index: Int) -> String? {
        if index % 50 == 7 { return index % 3 == 0 ? "DAZN1.uk" : nil }
        return "\(networks[(index / 4) % networks.count].replacingOccurrences(of: " ", with: "")).\(index / 4).ch"
    }

    static func playlist(count: Int) -> Data {
        var text = "#EXTM3U\n"
        text.reserveCapacity(count * 230)
        for index in 0..<count {
            let guide = guideID(index).map { " tvg-id=\"\($0)\"" } ?? ""
            text += "#EXTINF:-1\(guide) tvg-name=\"\(name(index))\" tvg-logo=\"http://logos.example/images/\(index).png\" group-title=\"\(category(index))\",\(name(index))\n"
            text += "http://iptv.example:8080/live/user000/pass000/\(100_000 + index).ts\n"
        }
        return Data(text.utf8)
    }

    /// An Xtream `get_live_streams` body of `count` records with realistic field sizes.
    static func xtreamStreams(count: Int) -> Data {
        var text = "["
        text.reserveCapacity(count * 420)
        for index in 0..<count {
            if index > 0 { text += "," }
            text += "{\"num\":\(index + 1),\"name\":\"\(name(index))\",\"stream_type\":\"live\",\"stream_id\":\(100_000 + index),"
            text += "\"stream_icon\":\"http://logos.example/images/channels/\(index)-logo-large.png\",\"epg_channel_id\":\"\(guideID(index) ?? "")\","
            text += "\"added\":\"1700000000\",\"is_adult\":0,\"category_id\":\"\(index % 300)\",\"category_ids\":[\(index % 300)],"
            text += "\"custom_sid\":\"\",\"tv_archive\":0,\"direct_source\":\"\",\"tv_archive_duration\":0}"
        }
        text += "]"
        return Data(text.utf8)
    }

    #if os(iOS)
    static func michiganGame(now: Date) -> KyroSportsGame {
        let away = KyroSportsTeam(id: "a", league: .collegeFootball, abbreviation: "MSU", nickname: "Spartans",
                                  location: "Michigan State", alternateNames: ["Michigan State Spartans"])
        let home = KyroSportsTeam(id: "h", league: .collegeFootball, abbreviation: "MICH", nickname: "Wolverines",
                                  location: "Michigan", alternateNames: ["Michigan Wolverines"])
        return KyroSportsGame(id: KyroGameID(provider: "espn", league: .collegeFootball, rawID: "bench"),
                              league: .collegeFootball, startTime: now, status: .live,
                              home: KyroGameTeam(team: home), away: KyroGameTeam(team: away), broadcast: "FOX")
    }
    #endif

    /// Twenty half-hour programmes per guide channel around `now`; the production index caps the
    /// total at `EPGLimits.maximumIndexedPrograms`. One channel in 500 carries the matchup.
    static func guide(guideIDs: [String], now: Date) -> EPGDocument {
        var programs: [EPGProgram] = []
        programs.reserveCapacity(guideIDs.count * 20)
        for (offset, id) in guideIDs.enumerated() {
            for slot in 0..<20 {
                let start = now.addingTimeInterval(Double(slot - 6) * 1800)
                let title = offset % 500 == 0 && slot == 6 ? "College Football: Michigan State at Michigan" : "Programme \(slot) on \(offset)"
                programs.append(EPGProgram(channelID: id, start: start, end: start.addingTimeInterval(1800), title: title,
                                           summary: "Synthetic listing \(slot).", category: "Sports"))
            }
        }
        return EPGDocument(channels: guideIDs.map { EPGChannel(id: $0, displayNames: [$0]) }, programs: programs)
    }

    static func xmltv(document: EPGDocument) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        var text = "<tv>"
        for channel in document.channels { text += "<channel id=\"\(channel.id)\"><display-name>\(channel.id)</display-name></channel>" }
        for program in document.programs {
            text += "<programme channel=\"\(program.channelID)\" start=\"\(formatter.string(from: program.start))\" stop=\"\(formatter.string(from: program.end))\"><title>\(program.title)</title><desc>\(program.summary ?? "")</desc></programme>"
        }
        text += "</tv>"
        return Data(text.utf8)
    }

    /// Physical footprint in MB, the figure iOS jetsam limits apply to.
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
}
