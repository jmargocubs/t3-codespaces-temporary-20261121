import Foundation
import SQLite3
import XCTest
@testable import Silo

/// The optional SQLite guide store: it must return exactly what the in-memory `EPGIndex` returns,
/// survive bad files and failed imports, and stay off unless the internal flag is set.
final class EPGSQLiteStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let fingerprint = Data((0..<EPGSourceFingerprint.length).map { UInt8($0) })

    // MARK: - Equivalence with the in-memory index

    func testQueriesStatisticsAndCoverageMatchTheInMemoryIndex() throws {
        let feed = trickyFeed()
        let (memory, sqlite) = try buildBoth(feed, limits: EPGLimits())

        XCTAssertEqual(sqlite.programCount, memory.programCount)
        XCTAssertEqual(sqlite.coverageEnd, memory.coverageEnd)
        XCTAssertEqual(sqlite.fetchedAt, memory.fetchedAt)
        XCTAssertEqual(sqlite.channelCount, memory.channelCount)
        XCTAssertEqual(sqlite.statistics, memory.statistics)
        XCTAssertGreaterThan(memory.statistics.duplicates, 0)
        XCTAssertGreaterThan(memory.statistics.overlapsTrimmed, 0)
        try assertSameQueries(memory, sqlite)
    }

    func testPerChannelAndGlobalCapsTrimLikeTheInMemoryIndex() throws {
        var limits = EPGLimits()
        limits.maximumProgramsPerChannel = 6
        limits.maximumIndexedPrograms = 20
        let (memory, sqlite) = try buildBoth(trickyFeed(), limits: limits)
        XCTAssertLessThanOrEqual(memory.programCount, 20)
        XCTAssertGreaterThan(memory.statistics.overLimit, 0)
        XCTAssertEqual(sqlite.programCount, memory.programCount)
        XCTAssertEqual(sqlite.statistics, memory.statistics)
        try assertSameQueries(memory, sqlite)
    }

    func testMissingAndMismatchedChannelIDsMatchNothing() throws {
        let (memory, sqlite) = try buildBoth(trickyFeed(), limits: EPGLimits())
        for index in [memory, sqlite] {
            XCTAssertNil(index.channelKey(guideID: "no.such.channel", name: nil))
            XCTAssertNil(index.channelKey(guideID: nil, name: "Nothing Like It"))
            XCTAssertNil(index.channelKey(guideID: "", name: ""))
            XCTAssertEqual(index.nowNext(guideID: "no.such.channel", name: nil, at: now), .empty)
            XCTAssertEqual(index.programs(channelKey: "no.such.channel",
                                          overlapping: DateInterval(start: now, duration: 3_600)), [])
        }
        // Case folding and an unambiguous display name still match; an ambiguous name does not.
        XCTAssertEqual(sqlite.channelKey(guideID: "NEWS.ONE", name: nil), "news.one")
        XCTAssertEqual(sqlite.channelKey(guideID: nil, name: "News One HD"), "news.one")
        XCTAssertNil(sqlite.channelKey(guideID: nil, name: "Shared Name"))
    }

    func testBoundariesAreHalfOpenExactlyAsInMemory() throws {
        let (memory, sqlite) = try buildBoth(trickyFeed(), limits: EPGLimits())
        // `news.one` airs 0-30 and 30-60 minutes from now: the instant 30 belongs to the second.
        for offset in [-1, 0, 1, 1_799, 1_800, 1_801, 3_599, 3_600, 3_601] {
            let at = now.addingTimeInterval(TimeInterval(offset))
            XCTAssertEqual(sqlite.nowNext(channelKey: "news.one", at: at), memory.nowNext(channelKey: "news.one", at: at), "offset \(offset)")
        }
        let touching = DateInterval(start: now.addingTimeInterval(1_800), duration: 0)
        XCTAssertEqual(sqlite.programs(channelKey: "news.one", overlapping: touching),
                       memory.programs(channelKey: "news.one", overlapping: touching))
    }

    // MARK: - Memory-only lookups

    func testCachedOnlyLookupsNeverReadDiskUntilPrefetched() throws {
        let built = try build(trickyFeed(), readPolicy: .cachedOnly)
        let index = built.index
        XCTAssertFalse(index.isResident(channelKey: "news.one"))
        XCTAssertEqual(index.nowNext(channelKey: "news.one", at: now), .empty, "not loaded: reads as empty")
        XCTAssertEqual(index.programs(channelKey: "news.one", overlapping: DateInterval(start: now, duration: 3_600)), [])
        XCTAssertEqual(index.guide.residentChannelCount, 0)

        index.prefetch(channelKeys: ["news.one", "no.such.channel"])
        XCTAssertTrue(index.isResident(channelKey: "news.one"))
        XCTAssertTrue(index.isResident(channelKey: "no.such.channel"), "an unknown channel has nothing to load")
        XCTAssertNotNil(index.nowNext(channelKey: "news.one", at: now).current)
        XCTAssertEqual(index.guide.residentChannelCount, 1)
    }

    func testResidentWindowIsBounded() throws {
        let feed = bulkFeed(channels: 40, perChannel: 5)
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let built = try EPGSQLiteBuilder.build(xml: feed, filter: nil, limits: EPGLimits(), fetchedAt: now,
                                               providerID: UUID(), fingerprint: fingerprint, destination: url)
        let small = try EPGSQLiteGuide.open(url, providerID: built.index.guide.metadata.providerID,
                                            fingerprint: fingerprint, maximumChannels: 8, maximumPrograms: 1_000)
        small.prefetch((0..<40).map { "ch\($0)" })
        XCTAssertLessThanOrEqual(small.residentChannelCount, 8)
        small.prefetch(["ch39"])
        XCTAssertTrue(small.isResident("ch39"))
    }

    func testRapidConcurrentPrefetchesStayProviderLocalAndWithinTheWindow() throws {
        let feed = bulkFeed(channels: 40, perChannel: 5)
        let firstURL = tempFile()
        let secondURL = tempFile()
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let firstID = UUID()
        let secondID = UUID()
        let first = try EPGSQLiteBuilder.build(xml: feed, filter: nil, limits: EPGLimits(), fetchedAt: now,
                                               providerID: firstID, fingerprint: fingerprint, destination: firstURL).index
        let second = try EPGSQLiteBuilder.build(xml: feed, filter: nil, limits: EPGLimits(), fetchedAt: now,
                                                providerID: secondID, fingerprint: fingerprint, destination: secondURL).index
        let bounded = try EPGSQLiteGuide.open(firstURL, providerID: firstID, fingerprint: fingerprint,
                                              maximumChannels: 8, maximumPrograms: 1_000)
        DispatchQueue.concurrentPerform(iterations: 16) { turn in
            let key = "ch\((turn * 7) % 40)"
            bounded.prefetch([key])
            // A different provider must never contribute listings to this guide.
            second.prefetch(channelKeys: [key])
        }
        XCTAssertLessThanOrEqual(bounded.residentChannelCount, 8)
        XCTAssertEqual(first.guide.metadata.providerID, firstID)
        XCTAssertEqual(second.guide.metadata.providerID, secondID)
        let memory = try EPGIndex(document: XMLTVParser.parse(feed), fetchedAt: now, now: now, limits: EPGLimits())
        for turn in 0..<16 {
            let key = "ch\((turn * 7) % 40)"
            XCTAssertEqual(second.programs(channelKey: key,
                                           overlapping: DateInterval(start: now, duration: 3_600)).map(\.title),
                           memory.programs(channelKey: key,
                                           overlapping: DateInterval(start: now, duration: 3_600)).map(\.title))
        }
    }

    // MARK: - Short-guide overlays

    func testShortGuideOverlayMatchesInMemoryIncludingCountAndCoverage() throws {
        let (memory, sqlite) = try buildBoth(trickyFeed(), limits: EPGLimits())
        let limits = EPGLimits()
        let short = [
            EPGProgram(channelID: "News.One", start: now.addingTimeInterval(1_200), end: now.addingTimeInterval(4_800),
                       title: "Fresh"),
            EPGProgram(channelID: "News.One", start: now.addingTimeInterval(4_800), end: now.addingTimeInterval(400_000),
                       title: "Fresh Long"),
        ]
        let memoryUpdated = memory.replacingPrograms(short, guideID: "News.One", now: now, limits: limits)
        let sqliteUpdated = sqlite.replacingPrograms(short, guideID: "News.One", now: now, limits: limits)
        XCTAssertEqual(sqliteUpdated.programCount, memoryUpdated.programCount)
        XCTAssertEqual(sqliteUpdated.coverageEnd, memoryUpdated.coverageEnd)
        XCTAssertEqual(sqliteUpdated.channelCount, memoryUpdated.channelCount)
        XCTAssertTrue(sqliteUpdated.isSQLiteBacked)
        try assertSameQueries(memoryUpdated, sqliteUpdated)

        // Applying a second overlay and a repeat of the first stays equal.
        let again = sqliteUpdated.replacingPrograms(short, guideID: "news.one", now: now, limits: limits)
        let againMemory = memoryUpdated.replacingPrograms(short, guideID: "news.one", now: now, limits: limits)
        XCTAssertEqual(again.programCount, againMemory.programCount)
        try assertSameQueries(againMemory, again)
    }

    // MARK: - Import safety

    func testMalformedFeedThrowsAndLeavesNoFile() {
        let url = tempFile()
        XCTAssertThrowsError(try EPGSQLiteBuilder.build(xml: Data("<html>not a guide</html>".utf8), filter: nil,
                                                        limits: EPGLimits(), fetchedAt: now, providerID: UUID(),
                                                        fingerprint: fingerprint, destination: url)) {
            XCTAssertEqual($0 as? EPGError, .malformedFeed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCancelledImportLeavesNoFileAndNoPartialGuide() async throws {
        let url = tempFile()
        let feed = bulkFeed(channels: 400, perChannel: 30)
        let fingerprint = fingerprint, now = now
        let task = Task.detached {
            try await Task.sleep(nanoseconds: 0)
            try EPGSQLiteBuilder.build(xml: feed, filter: nil, limits: EPGLimits(), fetchedAt: now, providerID: UUID(),
                                       fingerprint: fingerprint, destination: url)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled import must not complete")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testTruncatedFeedKeepsUsableListingsAndIsMarkedIncomplete() throws {
        var feed = String(decoding: trickyFeed(), as: UTF8.self)
        feed = String(feed.dropLast(feed.count / 4))
        let built = try build(Data(feed.utf8), readPolicy: .readThrough)
        XCTAssertTrue(built.statistics.incomplete)
        XCTAssertGreaterThan(built.index.programCount, 0)
    }

    // MARK: - Bad files

    func testWrongProviderWrongSourceAndGarbageFilesAreRejectedWithoutDeletion() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EPGCacheStore(directory: directory)
        let provider = UUID()
        try promoted(cache, provider: provider, feed: trickyFeed())
        let file = cache.sqliteURL(provider)
        XCTAssertNotNil(cache.loadSQLite(providerID: provider, fingerprint: fingerprint))

        XCTAssertNil(cache.loadSQLite(providerID: provider, fingerprint: Data(repeating: 9, count: fingerprint.count)),
                     "another source's fingerprint")
        let other = UUID()
        try FileManager.default.copyItem(at: file, to: cache.sqliteURL(other))
        XCTAssertNil(cache.loadSQLite(providerID: other, fingerprint: fingerprint), "a guide copied from another provider")

        let garbage = UUID()
        try Data("this is not a database".utf8).write(to: cache.sqliteURL(garbage))
        XCTAssertNil(cache.loadSQLite(providerID: garbage, fingerprint: fingerprint))
        let empty = UUID()
        try Data().write(to: cache.sqliteURL(empty))
        XCTAssertNil(cache.loadSQLite(providerID: empty, fingerprint: fingerprint))
        for url in [file, cache.sqliteURL(other), cache.sqliteURL(garbage), cache.sqliteURL(empty)] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "a rejected file is not deleted on read")
        }
    }

    func testIncompatibleSchemaAndTruncatedFilesAreRejected() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EPGCacheStore(directory: directory)
        let provider = UUID()
        try promoted(cache, provider: provider, feed: trickyFeed())
        let file = cache.sqliteURL(provider)
        let original = try Data(contentsOf: file)

        try mutate(file, "UPDATE meta SET value = 99 WHERE key = 'schema'")
        XCTAssertNil(cache.loadSQLite(providerID: provider, fingerprint: fingerprint), "a newer schema is not guessed at")

        try original.write(to: file)
        try mutate(file, "UPDATE meta SET value = value + 1 WHERE key = 'program_count'")
        XCTAssertNil(cache.loadSQLite(providerID: provider, fingerprint: fingerprint), "counts that disagree with the data")

        try original.prefix(original.count / 3).write(to: file)
        XCTAssertNil(cache.loadSQLite(providerID: provider, fingerprint: fingerprint), "a truncated file")
    }

    func testPromotionReplacesTheGuideAtomicallyAndKeepsTheOldOneOnFailure() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var cache = EPGCacheStore(directory: directory)
        let provider = UUID()
        try promoted(cache, provider: provider, feed: trickyFeed())
        let before = try Data(contentsOf: cache.sqliteURL(provider))

        cache.promoter = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        let stage = try cache.sqliteStageURL(providerID: provider)
        let built = try EPGSQLiteBuilder.build(xml: bulkFeed(channels: 5, perChannel: 3), filter: nil,
                                               limits: EPGLimits(), fetchedAt: now, providerID: provider,
                                               fingerprint: fingerprint, destination: stage)
        XCTAssertThrowsError(try cache.promoteSQLite(stage: stage, guide: built.index.guide,
                                                      providerID: provider, isCurrent: { true }))
        XCTAssertEqual(try Data(contentsOf: cache.sqliteURL(provider)), before, "the last valid guide is untouched")
        XCTAssertNotNil(cache.loadSQLite(providerID: provider, fingerprint: fingerprint))

        // A superseded generation never swaps either.
        cache.promoter = EPGCacheStore(directory: directory).promoter
        XCTAssertThrowsError(try cache.promoteSQLite(stage: stage, guide: built.index.guide,
                                                      providerID: provider, isCurrent: { false })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: cache.sqliteURL(provider)), before)
        withExtendedLifetime(built) {}
    }

    func testActiveReaderGenerationsAreNeverRenamedAndRepeatedActivationHasNoSQLiteSidecars() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EPGCacheStore(directory: directory)
        let provider = UUID()
        try promoted(cache, provider: provider, feed: trickyFeed())
        let reader = try XCTUnwrap(cache.loadSQLite(providerID: provider, fingerprint: fingerprint,
                                                    readPolicy: .readThrough))
        let expected = reader.nowNext(channelKey: "news.one", at: now)
        XCTAssertNotNil(expected.current)

        let originalURL = try XCTUnwrap(reader.sqlite?.guide.url)
        for turn in 0..<5 {
            try promoted(cache, provider: provider, feed: bulkFeed(channels: 3, perChannel: 3))
            let current = try XCTUnwrap(cache.loadSQLite(providerID: provider, fingerprint: fingerprint,
                                                         readPolicy: .readThrough))
            XCTAssertNotEqual(current.sqlite?.guide.url, originalURL, "activation must select a new generation")
            XCTAssertNil(current.channelKey(guideID: "news.one", name: nil), "new opens see generation \(turn)")
            XCTAssertEqual(reader.nowNext(channelKey: "news.one", at: now), expected,
                           "the old reader remains on its immutable generation")
            let directoryFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertFalse(directoryFiles.contains { $0.hasSuffix("-wal") || $0.hasSuffix("-shm") || $0.hasSuffix("-journal") },
                           "finished guides use rollback-journal mode and leave no sidecars")
        }
    }

    // MARK: - Service integration

    func testFlagIsOffByDefaultAndMemoryModeWritesNoSQLite() async throws {
        let defaults = UserDefaults(suiteName: "EPGSQLiteStoreTests-\(UUID().uuidString)")!
        XCTAssertEqual(EPGStorageMode.current(defaults: defaults), .memory)
        defaults.set(true, forKey: EPGStorageMode.defaultsKey)
        XCTAssertEqual(EPGStorageMode.current(defaults: defaults),
                       EPGStorageMode.isInternalToggleCompiled ? .sqlite : .memory,
                       "only the internal test build reads the SQLite preference")

        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = EPGService(cache: EPGCacheStore(directory: directory), loader: FeedLoader(trickyFeed()),
                                 fingerprinter: .inMemory(), now: { self.now })
        let provider = UUID()
        let index = try await service.refresh(providerID: provider, source: source("memory"))
        await service.removeOrphanedCacheFiles(keeping: [provider])
        XCTAssertFalse(index.isSQLiteBacked)
        XCTAssertEqual(files(directory, ".guide.sqlite"), [])
        XCTAssertEqual(files(directory, ".v2.epgcache").count, 1)
    }

    func testAPreferenceLeftByAnInternalBuildDoesNotEnableSQLiteElsewhere() {
        XCTAssertEqual(EPGStorageMode.resolve(preferenceEnabled: true, toggleCompiled: false), .memory)
        XCTAssertEqual(EPGStorageMode.resolve(preferenceEnabled: false, toggleCompiled: false), .memory)
        XCTAssertEqual(EPGStorageMode.resolve(preferenceEnabled: false, toggleCompiled: true), .memory)
        XCTAssertEqual(EPGStorageMode.resolve(preferenceEnabled: true, toggleCompiled: true), .sqlite)
    }

    func testSQLiteServiceRefreshPersistsAndANewServiceRestoresOffline() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fingerprinter = EPGSourceFingerprinter.inMemory()
        let provider = UUID(), src = source("restore")
        let writer = sqliteService(directory, FeedLoader(trickyFeed()), fingerprinter)
        let written = try await writer.refresh(providerID: provider, source: src)
        XCTAssertTrue(written.isSQLiteBacked)
        await writer.removeOrphanedCacheFiles(keeping: [provider])
        XCTAssertEqual(files(directory, ".guide.sqlite").count, 1)
        XCTAssertEqual(files(directory, ".stage"), [], "the stage was promoted")

        let offline = FeedLoader(nil)
        let restarted = sqliteService(directory, offline, fingerprinter)
        let restored = try await restarted.refresh(providerID: provider, source: src)
        XCTAssertEqual(offline.calls, 0, "restored without a download")
        XCTAssertTrue(restored.isSQLiteBacked)
        XCTAssertEqual(restored.fetchedAt, written.fetchedAt)
        XCTAssertEqual(restored.programCount, written.programCount)
        // The restored index reads through a resident window: prefetch, then compare.
        let (memory, _) = try buildBoth(trickyFeed(), limits: EPGLimits())
        restored.prefetch(channelKeys: Array(restored.sqlite!.guide.channelKeys))
        try assertSameQueries(memory, restored)
        let persisted = try XCTUnwrap(EPGCacheStore(directory: directory).readState(providerID: provider))
        XCTAssertNil(persisted.contentID, "SQLite identity lives in the file; the state stays unlinked")
        XCTAssertEqual(persisted.lastSuccessfulFetchDate, written.fetchedAt)
    }

    func testFailedRefreshKeepsTheLastValidGuideInMemoryAndOnDisk() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fingerprinter = EPGSourceFingerprinter.inMemory()
        let provider = UUID(), src = source("failure")
        let loader = FeedLoader(trickyFeed())
        let service = sqliteService(directory, loader, fingerprinter)
        let good = try await service.refresh(providerID: provider, source: src)
        await service.removeOrphanedCacheFiles(keeping: [provider])
        let cache = EPGCacheStore(directory: directory)
        let before = try Data(contentsOf: cache.sqliteURL(provider))

        loader.data = Data("<html>provider error page</html>".utf8)
        do {
            _ = try await service.refresh(providerID: provider, source: src, force: true)
            XCTFail("a malformed feed must fail the refresh")
        } catch {
            XCTAssertEqual(error as? EPGError, .malformedFeed)
        }
        await service.removeOrphanedCacheFiles(keeping: [provider])
        XCTAssertEqual(try Data(contentsOf: cache.sqliteURL(provider)), before)
        let current = await service.index(for: provider)
        XCTAssertEqual(current?.programCount, good.programCount)
        XCTAssertEqual(files(directory, ".stage"), [])
    }

    func testSQLiteFailureFallsBackToTheInMemoryIndexAndV2Cache() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A file where the cache directory should be: neither a stage nor a v2 file can be written,
        // but the guide must still build in memory.
        try Data().write(to: directory)
        let service = sqliteService(directory, FeedLoader(trickyFeed()), .inMemory())
        let index = try await service.refresh(providerID: UUID(), source: source("fallback"))
        XCTAssertFalse(index.isSQLiteBacked)
        XCTAssertGreaterThan(index.programCount, 0)
        try FileManager.default.removeItem(at: directory)
    }

    func testSQLiteEnabledServiceRestoresAnExistingV2GuideInMemory() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fingerprinter = EPGSourceFingerprinter.inMemory()
        let provider = UUID(), src = source("v2-fallback")
        let legacy = EPGService(cache: EPGCacheStore(directory: directory), loader: FeedLoader(trickyFeed()),
                                fingerprinter: fingerprinter, now: { self.now })
        let written = try await legacy.refresh(providerID: provider, source: src)
        await legacy.removeOrphanedCacheFiles(keeping: [provider])

        let offline = FeedLoader(nil)
        let upgraded = sqliteService(directory, offline, fingerprinter)
        let restored = try await upgraded.refresh(providerID: provider, source: src)
        XCTAssertEqual(offline.calls, 0)
        XCTAssertFalse(restored.isSQLiteBacked, "no SQLite guide yet: the v2 cache is the fallback")
        XCTAssertEqual(restored.programsByChannel, written.programsByChannel)
    }

    func testProvidersStayIsolatedAndRemovalDeletesOnlyTheirOwnFiles() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fingerprinter = EPGSourceFingerprinter.inMemory()
        let service = sqliteService(directory, FeedLoader(trickyFeed()), fingerprinter)
        let a = UUID(), b = UUID()
        var indexA: EPGIndex? = try await service.refresh(providerID: a, source: source("a"))
        _ = try await service.refresh(providerID: b, source: source("b"))
        await service.removeOrphanedCacheFiles(keeping: [a, b])
        XCTAssertEqual(files(directory, ".guide.sqlite").count, 2)

        let cache = EPGCacheStore(directory: directory)
        let fingerprintB = try fingerprinter.fingerprint(for: source("b")).bytes
        XCTAssertNil(cache.loadSQLite(providerID: a, fingerprint: fingerprintB), "provider A never serves B's source")

        await service.remove(providerID: b)
        XCTAssertEqual(files(directory, ".guide.sqlite").filter { $0.hasPrefix("\(a.uuidString).") }.count, 1)
        XCTAssertGreaterThan(indexA?.programCount ?? 0, 0)
        await service.removeOrphanedCacheFiles(keeping: [])
        XCTAssertEqual(files(directory, ".guide.sqlite").count, 1, "live reader files are not unlinked")
        indexA = nil
        await service.remove(providerID: a)
        await service.removeOrphanedCacheFiles(keeping: [])
        XCTAssertEqual(files(directory, ".guide.sqlite"), [], "a later sweep removes closed orphan generations")
    }

    func testSQLiteGuidesAreEvictedOldestFirstWithinTheEntryBudget() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var cache = EPGCacheStore(directory: directory)
        cache.maximumEntries = 2
        var providers: [UUID] = []
        for age in [300.0, 200, 100] {
            let provider = UUID()
            providers.append(provider)
            try promoted(cache, provider: provider, feed: bulkFeed(channels: 4, perChannel: 3))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)],
                                                  ofItemAtPath: cache.sqliteURL(provider).path)
        }
        let newest = UUID()
        try promoted(cache, provider: newest, feed: bulkFeed(channels: 4, perChannel: 3))
        let remaining = Set(files(directory, ".guide.sqlite"))
        XCTAssertEqual(remaining.count, 2)
        XCTAssertTrue(remaining.contains { $0.hasPrefix("\(newest.uuidString).") }, "the provider just written is kept")
        XCTAssertFalse(remaining.contains { $0.hasPrefix("\(providers[0].uuidString).") }, "the oldest goes first")
    }

    func testShortGuideThroughTheServiceUpdatesOnlyItsChannelOnASQLiteGuide() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = UUID(), src = source("short")
        let service = sqliteService(directory, FeedLoader(trickyFeed()), .inMemory(), readPolicy: .readThrough)
        let base = try await service.refresh(providerID: provider, source: src)
        let otherBefore = base.nowNext(channelKey: "sport.two", at: now)
        let issued = await service.beginShortRequest(providerID: provider, source: src, guideID: "news.one")
        let ticket = try XCTUnwrap(issued)
        let short = [EPGProgram(channelID: "news.one", start: now.addingTimeInterval(-600),
                                end: now.addingTimeInterval(600), title: "Breaking")]
        let result = await service.applyShortProgramsWithRetention(short, guideID: "news.one", ticket: ticket)
        let applied = try XCTUnwrap(result)
        XCTAssertTrue(applied.index.isSQLiteBacked)
        XCTAssertEqual(applied.index.nowNext(channelKey: "news.one", at: now).current?.title, "Breaking")
        XCTAssertEqual(applied.index.nowNext(channelKey: "sport.two", at: now), otherBefore)
        XCTAssertGreaterThan(applied.index.programCount, 0)

        // A full refresh supersedes the overlay; a restart does not resurrect it.
        let refreshed = try await service.refresh(providerID: provider, source: src, force: true)
        XCTAssertNotEqual(refreshed.nowNext(channelKey: "news.one", at: now).current?.title, "Breaking")
    }

    // MARK: - Helpers

    private func trickyFeed() -> Data {
        var rows = """
        <channel id="News.One"><display-name>News One HD</display-name></channel>
        <channel id="sport.two"><display-name>Sport Two</display-name><display-name>Shared Name</display-name></channel>
        <channel id="film.three"><display-name>Film Three</display-name><display-name>Shared Name</display-name></channel>
        <channel id="empty.four"><display-name>Empty Four</display-name></channel>
        <channel id="no.programmes.five"><display-name>Five</display-name></channel>

        """
        func add(_ channel: String, _ startMin: Double, _ endMin: Double, _ title: String) {
            rows += programme(channel, startMin, endMin, title)
        }
        // Contiguous, so a boundary instant belongs to exactly one programme.
        add("News.One", 0, 30, "News A")
        add("news.one", 30, 60, "News B")
        add("news.one", 60, 120, "News C")
        // Same start twice: the first wins. Overlap: the earlier one is trimmed.
        add("news.one", 60, 90, "Duplicate start")
        add("sport.two", 0, 90, "Sport Long")
        add("sport.two", 60, 120, "Sport Overlapping")
        add("sport.two", 120, 180, "Sport After")
        add("film.three", -400, -380, "Long gone")          // outside the six-hour retention
        add("film.three", 60 * 24 * 9, 60 * 24 * 9 + 30, "Far future") // beyond the horizon
        add("film.three", -20, 10, "Film Now")
        add("film.three", 10, 50, "Film Next")
        for slot in 0..<40 { add("busy.six", Double(slot * 30), Double(slot * 30 + 30), "Busy \(slot)") }
        add("café.seven", 0, 45, "Ünïcode – 日本語 &amp; more")
        rows += "<programme channel=\"bad\" start=\"garbage\" stop=\"20260101120000 +0000\"><title>Bad</title></programme>\n"
        rows += "<programme channel=\"\" start=\"20260101120000 +0000\" stop=\"20260101130000 +0000\"><title>No id</title></programme>\n"
        return Data("<tv>\n\(rows)</tv>".utf8)
    }

    private func bulkFeed(channels: Int, perChannel: Int) -> Data {
        var rows = ""
        for channel in 0..<channels {
            rows += "<channel id=\"ch\(channel)\"><display-name>Channel \(channel)</display-name></channel>\n"
            for slot in 0..<perChannel {
                rows += programme("ch\(channel)", Double(slot * 30 - 30), Double(slot * 30), "P\(channel).\(slot)")
            }
        }
        return Data("<tv>\n\(rows)</tv>".utf8)
    }

    private func programme(_ channel: String, _ startMin: Double, _ endMin: Double, _ title: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss '+0000'"
        let start = formatter.string(from: now.addingTimeInterval(startMin * 60))
        let stop = formatter.string(from: now.addingTimeInterval(endMin * 60))
        return "<programme channel=\"\(channel)\" start=\"\(start)\" stop=\"\(stop)\"><title>\(title)</title>"
            + "<sub-title>Sub \(title)</sub-title><desc>Desc &amp; \(title)</desc><category>Cat</category>"
            + "<episode-num system=\"xmltv_ns\">0.9.</episode-num></programme>\n"
    }

    private func buildBoth(_ feed: Data, limits: EPGLimits) throws -> (memory: EPGIndex, sqlite: EPGIndex) {
        let window = DateInterval(start: now.addingTimeInterval(-limits.pastRetention),
                                  end: now.addingTimeInterval(limits.futureHorizon))
        let document = try XMLTVParser.parse(feed, window: window, limits: limits)
        let memory = try EPGIndex(document: document, fetchedAt: now, now: now, limits: limits)
        let built = try build(feed, limits: limits, readPolicy: .readThrough)
        return (memory, EPGIndex(sqlite: built.index, statistics: built.statistics))
    }

    private func build(_ feed: Data, limits: EPGLimits = EPGLimits(),
                       readPolicy: EPGSQLiteReadPolicy) throws -> EPGSQLiteBuildResult {
        let url = tempFile()
        return try EPGSQLiteBuilder.build(xml: feed, filter: nil, limits: limits, fetchedAt: now, providerID: UUID(),
                                          fingerprint: fingerprint, destination: url, readPolicy: readPolicy)
    }

    /// The same answers for every channel, instant and window the guide can be asked about.
    private func assertSameQueries(_ memory: EPGIndex, _ other: EPGIndex, file: StaticString = #filePath,
                                   line: UInt = #line) throws {
        let keys = Array(memory.programsByChannel.keys) + ["no.such.channel"]
        let names = ["News One", "Sport Two", "Shared Name", "Film Three", "Busy Six", "Nothing", "café seven"]
        for name in names {
            XCTAssertEqual(other.channelKey(guideID: nil, name: name), memory.channelKey(guideID: nil, name: name),
                           name, file: file, line: line)
        }
        for key in keys {
            XCTAssertEqual(other.channelKey(guideID: key.uppercased(), name: nil),
                           memory.channelKey(guideID: key.uppercased(), name: nil), file: file, line: line)
            for offset in stride(from: -7_200, through: 14_400, by: 450) {
                let at = now.addingTimeInterval(TimeInterval(offset))
                XCTAssertEqual(other.nowNext(channelKey: key, at: at), memory.nowNext(channelKey: key, at: at),
                               "\(key) @ \(offset)", file: file, line: line)
            }
            for (start, length) in [(-3_600, 7_200), (0, 1), (1_800, 0), (-86_400, 400_000), (900, 1_800), (100_000, 5)] {
                let interval = DateInterval(start: now.addingTimeInterval(TimeInterval(start)), duration: TimeInterval(length))
                XCTAssertEqual(other.programs(channelKey: key, overlapping: interval),
                               memory.programs(channelKey: key, overlapping: interval),
                               "\(key) window \(start)+\(length)", file: file, line: line)
            }
        }
    }

    @discardableResult
    private func promoted(_ cache: EPGCacheStore, provider: UUID, feed: Data) throws -> EPGSQLiteBuildResult {
        let stage = try cache.sqliteStageURL(providerID: provider)
        let built = try EPGSQLiteBuilder.build(xml: feed, filter: nil, limits: EPGLimits(), fetchedAt: now,
                                               providerID: provider, fingerprint: fingerprint, destination: stage)
        try cache.promoteSQLite(stage: stage, guide: built.index.guide, providerID: provider, isCurrent: { true })
        return built
    }

    private func mutate(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    private func sqliteService(_ directory: URL, _ loader: FeedLoader, _ fingerprinter: EPGSourceFingerprinter,
                               readPolicy: EPGSQLiteReadPolicy = .cachedOnly) -> EPGService {
        EPGService(cache: EPGCacheStore(directory: directory), loader: loader, fingerprinter: fingerprinter,
                   storage: .sqlite, sqliteReadPolicy: readPolicy, now: { self.now })
    }

    private func source(_ name: String) -> EPGFeedSource {
        .xmltv(URL(string: "https://guide.example.test/\(name).xml")!)
    }

    private func files(_ directory: URL, _ suffix: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(suffix) }.sorted()
    }

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("KyroEPGSQLite-\(UUID().uuidString)", isDirectory: true)
    }

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("KyroEPGSQLite-\(UUID().uuidString).stage")
    }
}

private final class FeedLoader: EPGFeedLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var payload: Data?
    private var count = 0

    init(_ data: Data?) { payload = data }
    var data: Data? {
        get { lock.withLock { payload } }
        set { lock.withLock { payload = newValue } }
    }
    var calls: Int { lock.withLock { count } }

    func load(_ url: URL, maximumBytes: Int) async throws -> Data {
        lock.withLock { count += 1 }
        guard let data else { throw EPGError.providerRejected }
        return data
    }
}
