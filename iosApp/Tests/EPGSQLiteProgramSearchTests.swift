import Foundation
import XCTest
@testable import Silo

/// Program search over a SQLite-backed guide: the same matches, ranking and limits as the in-memory
/// `EPGProgramSearchIndex`, read from disk without loading the guide, cancellable, and published by
/// the store only while its query and identity are current.
final class EPGSQLiteProgramSearchTests: XCTestCase {
    private let provider = UUID(uuidString: "C1F4C8A0-CB4C-4B3D-9F73-9AA2BDA7C6B0")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private typealias P = EPGSQLiteSearchFixture.Programme

    // MARK: - Matching and ranking

    func testTitleMatchingIgnoresCaseAndRanksTitleBeforeSubtitle() async throws {
        let guides = try build([P("one", 0, "Abacus"), P("two", 60, "News About Cats"),
                                P("three", 120, "Evening", subtitle: "Abacus special"), P("four", 180, "Kebab")])
        let channels = ["one", "two", "three", "four"].map { channel($0) }
        let source = try await prepare(guides.sqlite, channels: channels)
        let results = try matches(await source.search(query: "  AB  ", now: now))
        XCTAssertEqual(results.map(\.channelID), ["one", "two", "three", "four"])
        XCTAssertEqual(results.map(\.quality), [.titlePrefix, .titleWordPrefix, .subtitle, .titleSubstring])
        let upper = try matches(await source.search(query: "ABACUS", now: now))
        let lower = try matches(await source.search(query: "abacus", now: now))
        XCTAssertEqual(upper, lower)
        XCTAssertEqual(upper.map(\.title), ["Abacus", "Evening"])
        let short = try matches(await source.search(query: "a", now: now))
        XCTAssertEqual(short, [], "programs need two characters")
    }

    func testUnicodeMatchingFollowsTheInMemoryIndexInEveryLocaleFamily() async throws {
        let titles = ["Café", "CAFE", "İstanbul", "ıstanbul", "Straße", "Ｗｉｄｅ", "😀 News", "naïve", "Match-Point"]
        let guides = try build(titles.enumerated().map { P("c\($0.offset)", Double($0.offset * 60), $0.element) })
        let channels = titles.indices.map { channel("c\($0)") }
        try await assertParity(guides, channels: channels,
                               queries: ["cafe", "café", "istanbul", "İstanbul", "ıst", "strasse", "wide", "😀 n", "nai", "match p"])
    }

    func testLiveProgrammesComeFirstThenUpcomingByStartAndEndedOnesAreLeftOut() async throws {
        let guides = try build([
            P("a", -3_600, "News Earlier", duration: 1_800),          // ended
            P("a", -1_800, "News At Boundary", duration: 1_800),      // ends exactly now: ended
            P("a", 0, "News Now", duration: 1_800),                   // starts exactly now: live
            P("b", -600, "Morning News", duration: 3_600),            // live, word prefix
            P("b", 3_000, "News Later", duration: 600),
            P("c", 1_200, "Breaking News", duration: 600),
        ])
        let source = try await prepare(guides.sqlite, channels: ["a", "b", "c"].map { channel($0) })
        let results = try matches(await source.search(query: "news", now: now))
        XCTAssertEqual(results.map(\.title), ["News Now", "Morning News", "Breaking News", "News Later"])
        XCTAssertEqual(results.map(\.isLive), [true, true, false, false])
        try await assertParity(guides, channels: ["a", "b", "c"].map { channel($0) }, queries: ["news", "ne"])
    }

    // MARK: - Missing, empty and unreadable guide data

    func testEmptyGuideAndUnmappedPlaylistReturnNoResults() async throws {
        let empty = try build([])
        let emptySource = try await prepare(empty.sqlite, channels: [channel("a")])
        let fromEmpty = try matches(await emptySource.search(query: "news", now: now))
        XCTAssertEqual(fromEmpty, [])

        let guides = try build([P("a", 0, "News")])
        let unmapped = try await prepare(guides.sqlite, channels: [channel("other"), channel("x", guideID: "")])
        XCTAssertEqual(unmapped.mappedChannelCount, 0)
        let fromUnmapped = try matches(await unmapped.search(query: "news", now: now))
        XCTAssertEqual(fromUnmapped, [])
        let noPlaylist = try await prepare(guides.sqlite, channels: [])
        let fromNoPlaylist = try matches(await noPlaylist.search(query: "news", now: now))
        XCTAssertEqual(fromNoPlaylist, [])

        let notSQLite = await EPGSQLiteProgramSearch.prepare(identity: identity(), guide: guides.memory,
                                                             channels: [channel("a")])
        XCTAssertNil(notSQLite, "an in-memory guide keeps using EPGProgramSearchIndex")
    }

    func testUnreadableGuideFileIsReportedInsteadOfFailingOrCrashing() async throws {
        let guides = try build([P("a", 0, "News")])
        let source = try await prepare(guides.sqlite, channels: [channel("a")])
        try FileManager.default.removeItem(at: guides.url)
        let outcome = await source.search(query: "news", now: now)
        XCTAssertEqual(outcome, .storageUnavailable)

        let store = EPGProgramSearchIndexStore()
        let viaStore = await store.search(query: "news", input: input(guides.sqlite, channels: [channel("a")]), now: now)
        XCTAssertEqual(viaStore, .unsupportedStorage)
    }

    // MARK: - Limits and parity

    func testResultLimitsApplyAcrossStoredAndShortGuideRows() async throws {
        var programmes: [P] = []
        for number in 0..<12 {
            for slot in 0..<8 { programmes.append(P("ch\(number)", Double(slot * 900 - 600), "News \(number)-\(slot)", duration: 900)) }
        }
        let guides = try build(programmes)
        var overlay: [EPGProgram] = []
        for slot in 0..<4 {
            let start: Date = now.addingTimeInterval(TimeInterval(slot * 600 - 300))
            overlay.append(EPGProgram(channelID: "ch3", start: start, end: start.addingTimeInterval(600),
                                      title: "News Flash \(slot)"))
        }
        let memory = guides.memory.replacingPrograms(overlay, guideID: "ch3", now: now, limits: EPGLimits())
        let sqlite = guides.sqlite.replacingPrograms(overlay, guideID: "ch3", now: now, limits: EPGLimits())
        XCTAssertFalse(sqlite.programsByChannel.isEmpty, "the overlay stays in memory over the stored channel")
        let channels = (0..<12).map { channel("ch\($0)") }
        let source = try await prepare(sqlite, channels: channels)
        for limit in [0, 1, 5, 40] {
            let results = try matches(await source.search(query: "news", now: now, limit: limit))
            XCTAssertEqual(results.count, limit)
        }
        let all = try matches(await source.search(query: "news", now: now, limit: .max))
        XCTAssertTrue(all.contains { $0.title.hasPrefix("News Flash") })
        let overlaid = try XCTUnwrap(sqlite.programsByChannel["ch3"]).filter { $0.end > now }
        XCTAssertEqual(all.filter { $0.channelKey == "ch3" }.map(\.programID).sorted(), overlaid.map(\.id).sorted(),
                       "an overlaid channel answers from its overlay only, never also from its stored rows")
        XCTAssertEqual(Set(all.map(\.programID)).count, all.count)
        try await assertParity((memory, sqlite, guides.url), channels: channels, queries: ["news", "flash", "3-"])
    }

    /// The same feed, stored either way, answers identically: matches, order, qualities, channels,
    /// programme IDs, limits and locales, with HD duplicates, name-only mapping and unmapped rows.
    func testSQLiteAndInMemoryResultsAreIdentical() async throws {
        let words = ["News", "Evening News", "Match of the Day", "Café Society", "Straße", "İstanbul Today",
                     "Kids Club", "naïve Cooking", "Ｗｉｄｅ Shot", "match point", "😀 Live", "NEWS24"]
        var programmes: [P] = []
        for number in 0..<30 {
            for slot in 0..<12 {
                programmes.append(P("Ch\(number).tv", Double(slot * 1_200 - 3_000), "\(words[(number + slot * 5) % words.count]) \(slot)",
                                    subtitle: slot.isMultiple(of: 3) ? "\(words[(number * 7 + slot) % words.count]) part" : nil,
                                    duration: 1_200, channelName: "Channel \(number)"))
            }
        }
        let guides = try build(programmes)
        var channels: [LiveTVChannel] = []
        for number in 0..<40 {
            let guideID: String? = number.isMultiple(of: 7) ? nil : (number < 30 ? "ch\(number).TV" : "missing\(number)")
            channels.append(channel("p\(number)", guideID: guideID ?? "", name: "Channel \(number % 30)"))
        }
        channels += (0..<5).map { channel("hd\($0)", guideID: "Ch\($0).tv", name: "Channel \($0) HD") }
        try await assertParity(guides, channels: channels,
                               queries: ["ne", "news", "NEWS", "cafe", "café", "strasse", "istanbul", "İst", "wide",
                                         "match p", "😀 l", "nai", "part", "1", "zzzz"])
        try await assertParity(guides, channels: channels, queries: ["news", "café"], at: now.addingTimeInterval(4 * 3_600 + 17))
    }

    // MARK: - Cancellation, staleness and identity

    func testCancelledSearchReturnsNilPromptly() async throws {
        let large = try buildLarge(channels: 400, perChannel: 40)
        let source = try await prepare(large.guides.sqlite, channels: large.channels)
        let clock = ContinuousClock()
        let task = Task { await source.search(query: "episode", now: now, limit: .max) }
        task.cancel()
        let started = clock.now
        let outcome = await task.value
        XCTAssertNil(outcome)
        XCTAssertLessThan(started.duration(to: clock.now), .milliseconds(250))
    }

    func testSupersededQueryCannotPublish() async throws {
        let large = try buildLarge(channels: 400, perChannel: 40)
        let store = EPGProgramSearchIndexStore()
        let current = input(large.guides.sqlite, channels: large.channels)
        let older = Task { await store.search(query: "episode", input: current, now: now, limit: .max) }
        while await store.currentIdentity == nil { await Task.yield() }
        let newer = await store.search(query: "news", input: current, now: now)
        let olderOutcome = await older.value
        guard case .results(let results)? = newer else { return XCTFail("the newest query must publish") }
        XCTAssertFalse(results.isEmpty)
        if case .results = olderOutcome { XCTFail("an older query published after a newer one started") }
        let builds = await store.buildCountForTesting
        XCTAssertEqual(builds, 1, "queries for one identity share one prepared source")
    }

    func testGuideRefreshDuringSearchDropsTheOldResultAndSearchesTheNewGuide() async throws {
        let large = try buildLarge(channels: 400, perChannel: 40)
        let store = EPGProgramSearchIndexStore()
        let running = Task {
            await store.search(query: "episode", input: input(large.guides.sqlite, channels: large.channels), now: now,
                               limit: .max)
        }
        while await store.currentIdentity == nil { await Task.yield() }
        let refreshed = try build([P("ch0", 0, "Fresh Episode")])
        let next = await store.search(query: "episode",
                                      input: input(refreshed.sqlite, channels: large.channels, generation: 2), now: now)
        let stale = await running.value
        if case .results = stale { XCTFail("a search of the replaced guide published") }
        guard case .results(let results)? = next else { return XCTFail("the refreshed guide must answer") }
        XCTAssertEqual(results.map(\.title), ["Fresh Episode"])
        let identity = await store.currentIdentity
        XCTAssertEqual(identity?.guideGeneration, 2)
    }

    func testProviderCatalogAndStorageChangesRebuildAndRemapChannels() async throws {
        let guides = try build([P("a", 0, "News A"), P("b", 60, "News B")])
        let store = EPGProgramSearchIndexStore()
        let first = try matches(await store.search(query: "news", input: input(guides.sqlite, channels: [channel("a"), channel("b")]), now: now))
        XCTAssertEqual(first.map(\.channelID), ["a", "b"])

        // A new catalog revision: channel `a` is gone and `b` now has another playlist ID and position.
        let moved = [channel("x0", guideID: "zz"), channel("b2", guideID: "b")]
        let second = try matches(await store.search(query: "news", input: input(guides.sqlite, channels: moved, revision: 2), now: now))
        XCTAssertEqual(second.map(\.channelID), ["b2"])
        XCTAssertEqual(second.map(\.channelOrdinal), [1])

        // Another provider, then the same guide stored in memory: each identity rebuilds once.
        _ = try matches(await store.search(query: "news", input: input(guides.sqlite, channels: moved, revision: 2, provider: UUID()), now: now))
        let memory = try matches(await store.search(query: "news", input: input(guides.memory, channels: moved, revision: 2, generation: 9), now: now))
        XCTAssertEqual(memory, second)
        _ = try matches(await store.search(query: "news", input: input(guides.memory, channels: moved, revision: 2, generation: 9), now: now))
        let builds = await store.buildCountForTesting
        XCTAssertEqual(builds, 4)
    }

    // MARK: - Size

    /// A guide far larger than the result limit: results stay bounded, nothing is loaded into the
    /// guide's resident window, and the search finishes in reasonable time.
    func testLargeGuideSearchIsBoundedAndNeverFillsTheResidentWindow() async throws {
        let large = try buildLarge(channels: 1_000, perChannel: 40)
        XCTAssertEqual(large.guides.sqlite.programCount, 40_000)
        let store = EPGProgramSearchIndexStore()
        let clock = ContinuousClock()
        let started = clock.now
        let results = try matches(await store.search(query: "episode", input: input(large.guides.sqlite, channels: large.channels), now: now))
        let elapsed = started.duration(to: clock.now)
        XCTAssertEqual(results.count, EPGProgramSearchIndex.defaultResultLimit)
        XCTAssertEqual(large.guides.sqlite.sqlite?.guide.residentChannelCount, 0, "search never loads listings into memory")
        XCTAssertLessThan(elapsed, .seconds(5))
        let none = try matches(await store.search(query: "zzqx", input: input(large.guides.sqlite, channels: large.channels), now: now))
        XCTAssertEqual(none, [])
    }

    // MARK: - Helpers

    private func identity(revision: Int = 1, generation: Int = 1, provider: UUID? = nil) -> EPGProgramSearchIndex.Identity {
        .init(providerID: provider ?? self.provider, catalogRevision: revision, guideGeneration: generation)
    }

    private func input(_ guide: EPGIndex, channels: [LiveTVChannel], revision: Int = 1, generation: Int = 1,
                       provider: UUID? = nil) -> EPGProgramSearchIndexStore.Input {
        .init(identity: identity(revision: revision, generation: generation, provider: provider), guide: guide, channels: channels)
    }

    private func build(_ programmes: [P]) throws -> (memory: EPGIndex, sqlite: EPGIndex, url: URL) {
        try EPGSQLiteSearchFixture.buildBoth(programmes, now: now, provider: provider, testCase: self)
    }

    private func buildLarge(channels count: Int, perChannel: Int) throws -> (guides: (memory: EPGIndex, sqlite: EPGIndex, url: URL), channels: [LiveTVChannel]) {
        var programmes: [P] = []
        programmes.reserveCapacity(count * perChannel)
        for number in 0..<count {
            for slot in 0..<perChannel {
                programmes.append(P("ch\(number)", Double(slot * 600 - 300),
                                    slot.isMultiple(of: 4) ? "News \(slot)" : "Show \(number)-\(slot)",
                                    subtitle: "Episode \(number * perChannel + slot)", duration: 600))
            }
        }
        return (try build(programmes), (0..<count).map { channel("ch\($0)") })
    }

    private func prepare(_ guide: EPGIndex, channels: [LiveTVChannel]) async throws -> EPGSQLiteProgramSearch {
        let source = await EPGSQLiteProgramSearch.prepare(identity: identity(), guide: guide, channels: channels)
        return try XCTUnwrap(source)
    }

    private func matches(_ outcome: EPGSQLiteProgramSearch.Outcome?, file: StaticString = #filePath,
                         line: UInt = #line) throws -> [EPGProgramSearchIndex.Match] {
        guard case .results(let results)? = outcome else {
            XCTFail("expected results, got \(String(describing: outcome))", file: file, line: line)
            throw CancellationError()
        }
        return results
    }

    private func matches(_ outcome: EPGProgramSearchIndexStore.Outcome?, file: StaticString = #filePath,
                         line: UInt = #line) throws -> [EPGProgramSearchIndex.Match] {
        guard case .results(let results)? = outcome else {
            XCTFail("expected results, got \(String(describing: outcome))", file: file, line: line)
            throw CancellationError()
        }
        return results
    }

    private func assertParity(_ guides: (memory: EPGIndex, sqlite: EPGIndex, url: URL), channels: [LiveTVChannel],
                              queries: [String], at date: Date? = nil,
                              file: StaticString = #filePath, line: UInt = #line) async throws {
        let at = date ?? now
        let built = await EPGProgramSearchIndex.build(identity: identity(), guide: guides.memory,
                                                      channels: channels, now: now)
        let index = try XCTUnwrap(built)
        let source = try await prepare(guides.sqlite, channels: channels)
        for localeID in ["en_US", "tr_TR"] {
            let locale = Locale(identifier: localeID)
            for query in queries {
                for limit in [Int.max, EPGProgramSearchIndex.defaultResultLimit, 3] {
                    let found = await index.search(query: query, now: at, limit: limit, matchingLocale: locale)
                    let expected = try XCTUnwrap(found)
                    let actual = try matches(await source.search(query: query, now: at, limit: limit, matchingLocale: locale))
                    XCTAssertEqual(actual, expected, "\(localeID) '\(query)' limit \(limit)", file: file, line: line)
                }
            }
        }
    }

    private func channel(_ id: String, guideID: String? = nil, name: String? = nil) -> LiveTVChannel {
        let guide = guideID ?? id
        return LiveTVChannel(id: id, guideID: guide.isEmpty ? nil : guide, name: name ?? id.uppercased(),
                             streamURL: URL(string: "https://invalid.example/\(id)")!, logoURL: nil, category: "TV")
    }
}

/// Builds one XMLTV feed into both guide storages, so tests can compare them on identical data.
enum EPGSQLiteSearchFixture {
    struct Programme {
        let channel: String
        let offset: TimeInterval
        let title: String
        let subtitle: String?
        let duration: TimeInterval
        let channelName: String?

        init(_ channel: String, _ offset: TimeInterval, _ title: String, subtitle: String? = nil,
             duration: TimeInterval = 300, channelName: String? = nil) {
            self.channel = channel
            self.offset = offset
            self.title = title
            self.subtitle = subtitle
            self.duration = duration
            self.channelName = channelName
        }
    }

    static func xml(_ programmes: [Programme], now: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        func stamp(_ date: Date) -> String { formatter.string(from: date) + " +0000" }
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        }
        var seen = Set<String>()
        var out = "<tv>"
        for programme in programmes where seen.insert(programme.channel).inserted {
            out += "<channel id=\"\(escape(programme.channel))\"><display-name>\(escape(programme.channelName ?? programme.channel))</display-name></channel>"
        }
        for programme in programmes {
            let start = now.addingTimeInterval(programme.offset)
            out += "<programme channel=\"\(escape(programme.channel))\" start=\"\(stamp(start))\" "
                + "stop=\"\(stamp(start.addingTimeInterval(programme.duration)))\"><title>\(escape(programme.title))</title>"
            if let subtitle = programme.subtitle { out += "<sub-title>\(escape(subtitle))</sub-title>" }
            out += "<desc>A summary that only the guide sheet reads.</desc></programme>"
        }
        return Data((out + "</tv>").utf8)
    }

    /// The in-memory index, the SQLite-backed index (cached-only, as the app opens it) and its file.
    static func buildBoth(_ programmes: [Programme], now: Date, provider: UUID,
                          testCase: XCTestCase) throws -> (memory: EPGIndex, sqlite: EPGIndex, url: URL) {
        let feed = xml(programmes, now: now)
        let limits = EPGLimits()
        let window = DateInterval(start: now.addingTimeInterval(-limits.pastRetention),
                                  end: now.addingTimeInterval(limits.futureHorizon))
        let memory = try EPGIndex(document: XMLTVParser.parse(feed, window: window, limits: limits),
                                  fetchedAt: now, now: now, limits: limits)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPGSQLiteProgramSearch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("guide.sqlite")
        let built = try EPGSQLiteBuilder.build(xml: feed, filter: nil, limits: limits, fetchedAt: now, providerID: provider,
                                               fingerprint: Data(repeating: 0x42, count: EPGSourceFingerprint.length),
                                               destination: url)
        return (memory, EPGIndex(sqlite: built.index, statistics: built.statistics), url)
    }
}
