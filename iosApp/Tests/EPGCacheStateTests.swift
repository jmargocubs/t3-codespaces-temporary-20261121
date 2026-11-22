import CryptoKit
import Foundation
import XCTest
@testable import Silo
import Security

final class EPGCacheStateTests: XCTestCase {
    private let fingerprint = Data((0..<EPGSourceFingerprint.length).map(UInt8.init))

    func testPlatformPathsUseApplicationSupportExceptForTV() throws {
        let fm = FileManager.default
        let support = try XCTUnwrap(fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let caches = try XCTUnwrap(fm.urls(for: .cachesDirectory, in: .userDomainMask).first)
        XCTAssertEqual(EPGCacheStore.makeDefault(platform: .iOS)?.directory,
                       support.appendingPathComponent("Silo/LiveTV/Guide", isDirectory: true))
        XCTAssertEqual(EPGCacheStore.makeDefault(platform: .macOS)?.directory,
                       support.appendingPathComponent("Silo/LiveTV/Guide", isDirectory: true))
        XCTAssertEqual(EPGCacheStore.makeDefault(platform: .tvOS)?.directory,
                       caches.appendingPathComponent("LiveTVGuide", isDirectory: true))
    }

    func testDefaultStoreReadsOldCacheWithoutMigratingOrDeletingIt() throws {
        let newDirectory = temporaryDirectory().appendingPathComponent("new", isDirectory: true)
        let oldDirectory = temporaryDirectory().appendingPathComponent("old", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: newDirectory.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: oldDirectory.deletingLastPathComponent())
        }
        let provider = UUID()
        let index = EPGIndex.empty(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let legacy = EPGCacheStore(directory: oldDirectory)
        try legacy.save(index, providerID: provider)
        var moved = EPGCacheStore(directory: newDirectory)
        moved.legacyReadDirectory = oldDirectory
        XCTAssertNotNil(moved.load(providerID: provider))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDirectory.path), "fallback is read-only")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldDirectory.appendingPathComponent("\(provider.uuidString).epgcache").path))
    }

    func testMigrationPrefersNewestAcrossBothV1LocationsAndPromotesVerifiedV2() throws {
        let root = temporaryDirectory()
        let primary = root.appendingPathComponent("primary", isDirectory: true)
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let provider = UUID(), fp = fingerprint
        let old = EPGCacheStore(directory: legacy)
        let newer = EPGCacheStore(directory: primary)
        try old.save(.empty(fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)), providerID: provider)
        try newer.save(.empty(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)), providerID: provider)
        try newer.saveState(EPGCacheState(providerID: provider, sourceFingerprint: fp,
                                          lastSuccessfulFetchAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let store = EPGCacheStore(directory: primary, legacyReadDirectory: legacy)
        // Make both candidates available under stable legacy filenames.
        try FileManager.default.moveItem(at: primary.appendingPathComponent("\(provider.uuidString).epgcache"),
                                         to: primary.appendingPathComponent("\(provider.uuidString).v1.epgcache"))
        XCTAssertTrue(store.migrate(providerID: provider, fingerprint: fp))
        let v2 = try Data(contentsOf: primary.appendingPathComponent("\(provider.uuidString).v2.epgcache"))
        let decoded = try EPGCacheFormat.decode(v2, providerID: provider)
        XCTAssertEqual(decoded.header.sourceFingerprint, fp)
        XCTAssertEqual(decoded.index.fetchedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertFalse(FileManager.default.fileExists(atPath: primary.appendingPathComponent("\(provider.uuidString).v1.epgcache").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("\(provider.uuidString).epgcache").path))
        XCTAssertEqual(store.load(providerID: provider)?.fetchedAt, decoded.index.fetchedAt)
    }

    func testVerifiedV2WinsOverAndDeletesBothLegacyLocations() throws {
        let root = temporaryDirectory(), primary = root.appendingPathComponent("primary", isDirectory: true)
        let fallback = root.appendingPathComponent("fallback", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        let provider = UUID(), time = Date(timeIntervalSince1970: 1_800_000_000)
        let legacy = EPGCacheStore(directory: fallback)
        try legacy.save(.empty(fetchedAt: time.addingTimeInterval(-500)), providerID: provider)
        let current = EPGIndex.empty(fetchedAt: time)
        let bytes = try EPGCacheFormat.encode(current, providerID: provider, sourceFingerprint: fingerprint)
        try bytes.write(to: primary.appendingPathComponent("\(provider.uuidString).v2.epgcache"))
        try EPGCacheStore(directory: primary).save(.empty(fetchedAt: time.addingTimeInterval(-100)), providerID: provider)
        let store = EPGCacheStore(directory: primary, legacyReadDirectory: fallback)
        let result = try XCTUnwrap(store.loadVerified(providerID: provider, fingerprint: fingerprint))
        XCTAssertEqual(result.fetchedAt, time)
        XCTAssertFalse(FileManager.default.fileExists(atPath: primary.appendingPathComponent("\(provider.uuidString).epgcache").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallback.appendingPathComponent("\(provider.uuidString).epgcache").path))
    }

    func testMigrationFailuresKeepV1AndUnavailableIdentityDoesNotMigrate() throws {
        let root = temporaryDirectory(), provider = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let baseline = EPGCacheStore(directory: root)
        try baseline.save(.empty(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)), providerID: provider)
        try baseline.saveState(EPGCacheState(providerID: provider, sourceFingerprint: fingerprint,
                                             lastSuccessfulFetchAt: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertFalse(baseline.migrate(providerID: provider, fingerprint: Data()))
        var failedStage = baseline
        failedStage.stageWriter = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        XCTAssertFalse(failedStage.migrate(providerID: provider, fingerprint: fingerprint))
        var failedReopen = baseline
        failedReopen.stageWriter = { _, url in try Data("bad".utf8).write(to: url) }
        XCTAssertFalse(failedReopen.migrate(providerID: provider, fingerprint: fingerprint))
        var failedPromotion = baseline
        failedPromotion.promoter = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        XCTAssertFalse(failedPromotion.migrate(providerID: provider, fingerprint: fingerprint))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(provider.uuidString).epgcache").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(provider.uuidString).v2.epgcache").path))
    }

    func testMigrationRejectsAReopenedGuideWhoseContentDiffersFromV1() throws {
        let root = temporaryDirectory(), provider = UUID(), fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let fp = fingerprint
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = EPGCacheStore(directory: root)
        let sourceIndex = EPGIndex.empty(fetchedAt: fetchedAt)
        try store.save(sourceIndex, providerID: provider)
        try store.saveState(EPGCacheState(providerID: provider, sourceFingerprint: fingerprint,
                                          lastSuccessfulFetchAt: fetchedAt))
        var mismatchingEncoder = store
        mismatchingEncoder.stageWriter = { _, url in
            let changed = EPGIndex(fetchedAt: fetchedAt, programsByChannel: ["other": [
                EPGProgram(channelID: "other", start: fetchedAt, end: fetchedAt.addingTimeInterval(60), title: "wrong"),
            ]], channelIDsByName: [:], statistics: .init())
            try EPGCacheFormat.encode(changed, providerID: provider, sourceFingerprint: fp).write(to: url)
        }
        XCTAssertFalse(mismatchingEncoder.migrate(providerID: provider, fingerprint: fingerprint))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(provider.uuidString).epgcache").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(provider.uuidString).v2.epgcache").path))
    }

    func testCrossProviderEvictionWaitsForMigrationPromotion() async throws {
        let root = temporaryDirectory(), migratingID = UUID(), savingID = UUID()
        let fp = fingerprint
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var cache = EPGCacheStore(directory: root)
        cache.maximumEntries = 1
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try cache.save(.empty(fetchedAt: fetchedAt), providerID: migratingID)
        try cache.saveState(EPGCacheState(providerID: migratingID, sourceFingerprint: fp,
                                          lastSuccessfulFetchAt: fetchedAt))
        let migrationGate = StateWriteGate()
        var heldMigration = cache
        heldMigration.stageWriter = { data, url in try migrationGate.write(data, to: url) }
        let migration = Task.detached { heldMigration.migrate(providerID: migratingID, fingerprint: fp) }
        let enteredMigration = await Task.detached { migrationGate.waitUntilEntered(timeout: 5) }.value
        XCTAssertTrue(enteredMigration)

        let saveEnteredWriter = DispatchSemaphore(value: 0)
        var otherProviderSave = cache
        otherProviderSave.stageChunkWriter = { data, handle in
            saveEnteredWriter.signal()
            try handle.write(contentsOf: data)
        }
        let save = Task.detached {
            try otherProviderSave.saveV2(.empty(fetchedAt: fetchedAt.addingTimeInterval(1)),
                                         providerID: savingID, fingerprint: fp)
        }
        let enteredBeforePromotion = await Task.detached {
            StateWriteGate.wait(saveEnteredWriter, timeout: .now() + .milliseconds(50))
        }.value
        XCTAssertFalse(enteredBeforePromotion, "cross-provider eviction cannot enter while migration owns the disk transaction")
        migrationGate.release()
        let migrated = await migration.value
        XCTAssertTrue(migrated)
        _ = try await save.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(savingID.uuidString).v2.epgcache").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(migratingID.uuidString).epgcache").path),
                       "evicting the completed v2 cannot reveal v1")
    }

    func testPromotionThenInterruptionIsRecoveredByRetryWithoutLosingLegacy() throws {
        let root = temporaryDirectory(), provider = UUID(), time = Date(timeIntervalSince1970: 1_800_000_000)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let normal = EPGCacheStore(directory: root)
        try normal.save(.empty(fetchedAt: time), providerID: provider)
        try normal.saveState(EPGCacheState(providerID: provider, sourceFingerprint: fingerprint,
                                           lastSuccessfulFetchAt: time))
        var interrupted = normal
        interrupted.promoter = { stage, destination in
            try FileManager.default.moveItem(at: stage, to: destination)
            throw CocoaError(.fileWriteUnknown)
        }
        XCTAssertFalse(interrupted.migrate(providerID: provider, fingerprint: fingerprint))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(provider.uuidString).epgcache").path))
        XCTAssertTrue(normal.migrate(providerID: provider, fingerprint: fingerprint), "verified v2 makes retry cleanup idempotent")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(provider.uuidString).epgcache").path))
    }

    func testUnknownLZFSEAndV2IncompatibleLegacyArePreserved() throws {
        let root = temporaryDirectory(), provider = UUID(), incompatibleProvider = UUID(), time = Date(timeIntervalSince1970: 1_800_000_000)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = EPGCacheStore(directory: root)
        let unknown = root.appendingPathComponent("\(provider.uuidString).epgcache")
        try Data([0x4B, 0x45, 0x50, 0x47, 1, 0, 0, 0, 0]).write(to: unknown)
        XCTAssertFalse(store.migrate(providerID: provider, fingerprint: fingerprint))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))

        let longTitle = String(repeating: "x", count: 601)
        let program = EPGProgram(channelID: "guide", start: time, end: time.addingTimeInterval(60), title: longTitle)
        let index = EPGIndex(fetchedAt: time, programsByChannel: ["guide": [program]],
                             channelIDsByName: [:], statistics: .init())
        try store.save(index, providerID: incompatibleProvider)
        try store.saveState(EPGCacheState(providerID: incompatibleProvider, sourceFingerprint: fingerprint,
                                          lastSuccessfulFetchAt: time))
        XCTAssertFalse(store.migrate(providerID: incompatibleProvider, fingerprint: fingerprint), "v2 policy rejection must not discard v1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(incompatibleProvider.uuidString).epgcache").path))
    }

    func testSourceAwareServiceNeverDisplaysUnboundOrMismatchedCache() async throws {
        let root = temporaryDirectory(), provider = UUID(), time = Date(timeIntervalSince1970: 1_800_000_000)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceA = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/a.xml")!)
        let sourceB = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/b.xml")!)
        let fingerprinter = EPGSourceFingerprinter.inMemory()
        let fpA = try fingerprinter.fingerprint(for: sourceA).bytes
        let fpB = try fingerprinter.fingerprint(for: sourceB).bytes
        let store = EPGCacheStore(directory: root)
        try store.save(.empty(fetchedAt: time), providerID: provider)
        let service = EPGService(cache: store, loader: StateTestLoader(failure: EPGError.providerRejected),
                                 fingerprinter: fingerprinter)
        let unbound = await service.index(for: provider, source: sourceA)
        XCTAssertNil(unbound, "UUID-only v1 has no source binding")
        try store.saveState(EPGCacheState(providerID: provider, sourceFingerprint: fpB, lastSuccessfulFetchAt: time))
        let mismatchedLegacy = await service.index(for: provider, source: sourceA)
        XCTAssertNil(mismatchedLegacy, "other-source state cannot bind this v1")
        try store.saveV2(.empty(fetchedAt: time), providerID: provider, fingerprint: fpB)
        let mismatchedV2 = await service.index(for: provider, source: sourceA)
        XCTAssertNil(mismatchedV2, "v2 fingerprint mismatch is not displayed")
        let matchingV2 = await service.index(for: provider, source: sourceB)
        XCTAssertNotNil(matchingV2, "matching HMAC-bound v2 is displayed")
        XCTAssertEqual(fpA.count, EPGSourceFingerprint.length)
    }

    func testServiceMigrationIsExplicitAndRemovalCancelsQueuedStage() async throws {
        let root = temporaryDirectory(), provider = UUID(), time = Date(timeIntervalSince1970: 1_800_000_000)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/migrate.xml")!)
        let fingerprinter = EPGSourceFingerprinter.inMemory()
        let fp = try fingerprinter.fingerprint(for: source).bytes
        let cache = EPGCacheStore(directory: root)
        try cache.save(.empty(fetchedAt: time), providerID: provider)
        try cache.saveState(EPGCacheState(providerID: provider, sourceFingerprint: fp, lastSuccessfulFetchAt: time))
        let service = EPGService(cache: cache, loader: StateTestLoader(failure: EPGError.providerRejected),
                                 fingerprinter: fingerprinter)
        // Loading is safe, but migration is an independent explicit operation.
        let cached = await service.index(for: provider, source: source)
        XCTAssertNotNil(cached)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(provider.uuidString).v2.epgcache").path))
        let migrated = await service.migrateLegacyCache(providerID: provider, source: source)
        XCTAssertTrue(migrated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(provider.uuidString).v2.epgcache").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(provider.uuidString).epgcache").path))

        let second = UUID()
        try cache.save(.empty(fetchedAt: time), providerID: second)
        try cache.saveState(EPGCacheState(providerID: second, sourceFingerprint: fp, lastSuccessfulFetchAt: time))
        let gate = StateWriteGate()
        var held = cache
        held.stageWriter = { data, url in try gate.write(data, to: url) }
        let removing = EPGService(cache: held, loader: StateTestLoader(failure: EPGError.providerRejected),
                                  fingerprinter: fingerprinter)
        let migration = Task { await removing.migrateLegacyCache(providerID: second, source: source) }
        let entered = await Task.detached { gate.waitUntilEntered(timeout: 5) }.value
        XCTAssertTrue(entered, "migration stage write began")
        let removal = Task { await removing.remove(providerID: second) }
        try await Task.sleep(nanoseconds: 20_000_000)
        gate.release()
        let didPromote = await migration.value
        XCTAssertFalse(didPromote, "generation change prevents promotion")
        await removal.value
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertFalse(remaining.contains { $0.hasPrefix(second.uuidString) }, "removal deletes v1, state and stage")
    }

    func testUnavailableKeychainDoesNotDisplayOrMigrateDiskCache() async throws {
        let root = temporaryDirectory(), provider = UUID(), time = Date(timeIntervalSince1970: 1_800_000_000)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/locked.xml")!)
        let cache = EPGCacheStore(directory: root)
        try cache.save(.empty(fetchedAt: time), providerID: provider)
        let fingerprinter = EPGSourceFingerprinter(keys: EPGFingerprintKeyProvider(store: UnavailableFingerprintKeyStore()))
        let service = EPGService(cache: cache, loader: StateTestLoader(failure: EPGError.providerRejected),
                                 fingerprinter: fingerprinter)
        let index = await service.index(for: provider, source: source)
        XCTAssertNil(index, "a locked Keychain cannot establish source identity")
        let migrated = await service.migrateLegacyCache(providerID: provider, source: source)
        XCTAssertFalse(migrated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(provider.uuidString).epgcache").path))
    }

    func testStateRoundTripAndIdentityMismatchNeverValidatesAnotherGuide() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EPGCacheStore(directory: directory)
        let provider = UUID()
        let contentID = UUID()
        let state = EPGCacheState(providerID: provider, sourceFingerprint: fingerprint, contentID: contentID,
                                  lastSuccessfulFetchAt: Date(timeIntervalSince1970: 1_800_000_000),
                                  failureCount: 3, nextRetryAt: Date(timeIntervalSince1970: 1_800_000_900))
        try store.saveState(state)
        XCTAssertEqual(store.loadState(providerID: provider, fingerprint: fingerprint, contentID: contentID), state)
        XCTAssertNil(store.loadState(providerID: provider, fingerprint: fingerprint, contentID: UUID()),
                      "a matching source cannot make metadata for another guide current")
        XCTAssertNil(store.loadState(providerID: UUID(), fingerprint: fingerprint))
        XCTAssertNil(store.loadState(providerID: provider, fingerprint: Data(repeating: 0xFF, count: 32)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(provider.uuidString).state").path),
                       "identity mismatch discards metadata, not the guide")
    }

    func testMalformedAndOversizedStateAreMissesWithoutTouchingGuide() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EPGCacheStore(directory: directory)
        let provider = UUID()
        let guide = directory.appendingPathComponent("\(provider.uuidString).epgcache")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("valid-guide-placeholder".utf8).write(to: guide)
        let stateURL = directory.appendingPathComponent("\(provider.uuidString).state")
        try Data("{".utf8).write(to: stateURL)
        XCTAssertNil(store.loadState(providerID: provider, fingerprint: fingerprint))
        XCTAssertTrue(FileManager.default.fileExists(atPath: guide.path))
        try Data(repeating: 0, count: 4_097).write(to: stateURL)
        XCTAssertNil(store.loadState(providerID: provider, fingerprint: fingerprint))
        XCTAssertTrue(FileManager.default.fileExists(atPath: guide.path))
    }

    func testStateWriteFailureLeavesPreviousStateIntact() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = UUID()
        let first = EPGCacheState(providerID: provider, sourceFingerprint: fingerprint,
                                  failureCount: 1, nextRetryAt: Date(timeIntervalSince1970: 1_800_000_300))
        let replacement = EPGCacheState(providerID: provider, sourceFingerprint: fingerprint,
                                        failureCount: 2, nextRetryAt: Date(timeIntervalSince1970: 1_800_000_600))
        let failedReplacement = EPGCacheState(providerID: provider, sourceFingerprint: fingerprint,
                                              failureCount: 3, nextRetryAt: Date(timeIntervalSince1970: 1_800_000_900))
        let normal = EPGCacheStore(directory: directory)
        try normal.save(EPGIndex.empty(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)), providerID: provider)
        try normal.saveState(first)
        try normal.saveState(replacement)
        XCTAssertEqual(normal.loadState(providerID: provider, fingerprint: fingerprint), replacement,
                       "atomic replacement makes the newest complete state visible")
        var failing = EPGCacheStore(directory: directory)
        failing.stateWriter = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        XCTAssertThrowsError(try failing.saveState(failedReplacement))
        XCTAssertEqual(EPGCacheStore(directory: directory).loadState(providerID: provider, fingerprint: fingerprint), replacement)
        XCTAssertNotNil(normal.load(providerID: provider), "failed state writes do not discard a valid guide")
    }

    func testBackupExclusionAndProtectionAttributes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EPGCacheStore(directory: directory)
        let provider = UUID()
        let state = EPGCacheState(providerID: provider, sourceFingerprint: fingerprint,
                                  lastSuccessfulFetchAt: Date(timeIntervalSince1970: 1_800_000_000))
        try store.saveState(state)
#if os(iOS) || os(macOS)
        XCTAssertTrue(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false)
#endif
        XCTAssertTrue(EPGCacheStore.protectedWriteOptions.contains(.atomic))
        XCTAssertTrue(EPGCacheStore.protectedWriteOptions.contains(.completeFileProtectionUntilFirstUserAuthentication))
    }

    func testOrphanSweepRemovesOnlyUnknownProviderGuideAndStateFiles() throws {
        let directory = temporaryDirectory()
        let legacy = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: legacy)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let known = UUID(), orphan = UUID()
        for name in ["\(known.uuidString).epgcache", "\(known.uuidString).state",
                     "\(orphan.uuidString).epgcache", "\(orphan.uuidString).state", "unrelated.tmp"] {
            try Data([1]).write(to: directory.appendingPathComponent(name))
        }
        try Data([1]).write(to: legacy.appendingPathComponent("\(known.uuidString).epgcache"))
        try Data([1]).write(to: legacy.appendingPathComponent("\(orphan.uuidString).epgcache"))
        EPGCacheStore(directory: directory, legacyReadDirectory: legacy).removeOrphans(keeping: [known])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(known.uuidString).epgcache").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(known.uuidString).state").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(orphan.uuidString).epgcache").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(orphan.uuidString).state").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("\(known.uuidString).epgcache").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("\(orphan.uuidString).epgcache").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("unrelated.tmp").path))
    }

    func testOrphanSweepRemovesOnlyAbandonedRecognizedStageFiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let provider = UUID(), active = directory.appendingPathComponent("\(provider.uuidString).\(UUID().uuidString).stage")
        let abandoned = directory.appendingPathComponent("\(UUID().uuidString).\(UUID().uuidString).stage")
        let unrelated = directory.appendingPathComponent("unrelated.stage")
        for url in [active, abandoned, unrelated] { try Data([1]).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: abandoned.path)
        EPGCacheStore(directory: directory).removeOrphans(keeping: [provider])
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path), "active-process stage is never swept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path), "recognized stage from an earlier launch is swept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path), "unrecognized temporary files are preserved")
    }

    func testEvictingV2AlsoRemovesItsLegacyCopyWithoutTouchingTheKeptGuide() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var store = EPGCacheStore(directory: directory)
        store.maximumEntries = 1
        let evicted = UUID(), kept = UUID()
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = Date(timeIntervalSince1970: 1_800_000_000)
        try store.saveV2(.empty(fetchedAt: oldDate), providerID: evicted, fingerprint: fingerprint)
        let staleV1 = directory.appendingPathComponent("\(evicted.uuidString).epgcache")
        try EPGCacheFormat.encodeVersion1(.empty(fetchedAt: oldDate)).write(to: staleV1)
        for path in [staleV1.path, directory.appendingPathComponent("\(evicted.uuidString).v2.epgcache").path] {
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: path)
        }

        try store.saveV2(.empty(fetchedAt: newDate), providerID: kept, fingerprint: fingerprint)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleV1.path), "eviction cannot resurrect stale v1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(evicted.uuidString).v2.epgcache").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(kept.uuidString).v2.epgcache").path))
    }

    func testEvictionNeverDeletesLegacyV1OnItsOwn() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var store = EPGCacheStore(directory: directory)
        store.maximumEntries = 1
        let readableLegacy = UUID(), unreadableLegacy = UUID(), evictedWithLegacy = UUID(), kept = UUID()
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)

        // A v2 guide with a readable v1 copy is evicted together with that copy.
        try store.saveV2(.empty(fetchedAt: oldDate), providerID: evictedWithLegacy, fingerprint: fingerprint)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: directory.appendingPathComponent(
            "\(evictedWithLegacy.uuidString).v2.epgcache").path)
        let pairedV1 = directory.appendingPathComponent("\(evictedWithLegacy.uuidString).epgcache")
        try EPGCacheFormat.encodeVersion1(.empty(fetchedAt: oldDate)).write(to: pairedV1)

        // v1-only providers: one readable, one with bytes this build cannot read. Neither is a candidate.
        let standaloneV1 = directory.appendingPathComponent("\(readableLegacy.uuidString).epgcache")
        try EPGCacheFormat.encodeVersion1(.empty(fetchedAt: oldDate)).write(to: standaloneV1)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: standaloneV1.path)
        let unreadable = directory.appendingPathComponent("\(unreadableLegacy.uuidString).epgcache")
        try Data("KEPG\u{1}not-lzfse".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: unreadable.path)

        // Over the entry limit: the new v2 write is kept, and only the paired v2 guide is evicted.
        try store.saveV2(.empty(fetchedAt: fetched), providerID: kept, fingerprint: fingerprint)

        let v2Evicted = directory.appendingPathComponent("\(evictedWithLegacy.uuidString).v2.epgcache")
        XCTAssertFalse(FileManager.default.fileExists(atPath: v2Evicted.path), "the budget evicts the oldest v2 guide")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pairedV1.path), "its readable v1 copy goes with it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: standaloneV1.path), "a readable v1 file is not evicted on its own")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unreadable.path), "an unreadable v1 file is preserved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(kept.uuidString).v2.epgcache").path))
    }

    // MARK: - Eviction accounting

    /// Writes a v2 guide without triggering eviction and backdates it.
    private func seedV2(_ directory: URL, _ provider: UUID, age: TimeInterval) throws {
        var unlimited = EPGCacheStore(directory: directory)
        unlimited.maximumEntries = .max
        let date = Date(timeIntervalSince1970: 1_800_000_000 - age)
        try unlimited.saveV2(.empty(fetchedAt: date), providerID: provider, fingerprint: fingerprint)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: directory.appendingPathComponent(
            "\(provider.uuidString).v2.epgcache").path)
    }

    private func seedV1(_ url: URL, age: TimeInterval) throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000 - age)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try EPGCacheFormat.encodeVersion1(.empty(fetchedAt: date)).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func exists(_ directory: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    func testEvictionCountsLegacyFilesInTheSeparateLegacyDirectory() throws {
        let root = temporaryDirectory()
        let primary = root.appendingPathComponent("primary", isDirectory: true)
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let standalone = UUID(), oldest = UUID(), newer = UUID(), kept = UUID()
        try seedV1(legacy.appendingPathComponent("\(standalone.uuidString).epgcache"), age: 900)
        try seedV2(primary, oldest, age: 600)
        try seedV2(primary, newer, age: 300)
        var store = EPGCacheStore(directory: primary, legacyReadDirectory: legacy)
        store.maximumEntries = 3

        // Four entries: the standalone v1 in Caches, two older v2 guides and the new one.
        try store.saveV2(.empty(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)), providerID: kept,
                         fingerprint: fingerprint)

        XCTAssertFalse(exists(primary, "\(oldest.uuidString).v2.epgcache"), "legacy-directory v1 counts toward the limit")
        XCTAssertTrue(exists(primary, "\(newer.uuidString).v2.epgcache"), "eviction stops once the cache fits")
        XCTAssertTrue(exists(legacy, "\(standalone.uuidString).epgcache"), "a standalone v1 file is never a candidate")
        XCTAssertTrue(exists(primary, "\(kept.uuidString).v2.epgcache"))
    }

    func testEvictionCountsALegacyDirectoryThatIsThePrimaryDirectoryOnce() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let standalone = UUID(), older = UUID(), kept = UUID()
        try seedV1(directory.appendingPathComponent("\(standalone.uuidString).epgcache"), age: 900)
        try seedV2(directory, older, age: 600)
        // The same location spelled without the directory flag, as tvOS-style shared storage would be.
        var store = EPGCacheStore(directory: directory, legacyReadDirectory: URL(fileURLWithPath: directory.path))
        store.maximumEntries = 3

        try store.saveV2(.empty(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)), providerID: kept,
                         fingerprint: fingerprint)

        XCTAssertTrue(exists(directory, "\(older.uuidString).v2.epgcache"), "three files fit; none is counted twice")
        XCTAssertTrue(exists(directory, "\(standalone.uuidString).epgcache"))
        XCTAssertTrue(exists(directory, "\(kept.uuidString).v2.epgcache"))
    }

    func testEvictingAPairRecountsSoNoFurtherGuideIsEvictedByEntryCount() throws {
        let root = temporaryDirectory()
        let primary = root.appendingPathComponent("primary", isDirectory: true)
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paired = UUID(), middle = UUID(), recent = UUID(), kept = UUID()
        try seedV2(primary, paired, age: 900)
        try seedV1(primary.appendingPathComponent("\(paired.uuidString).v1.epgcache"), age: 900)
        try seedV1(legacy.appendingPathComponent("\(paired.uuidString).epgcache"), age: 900)
        try seedV2(primary, middle, age: 600)
        try seedV2(primary, recent, age: 300)
        var store = EPGCacheStore(directory: primary, legacyReadDirectory: legacy)
        store.maximumEntries = 3

        // Six entries. Evicting the oldest v2 also removes its two v1 copies, leaving exactly three.
        try store.saveV2(.empty(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)), providerID: kept,
                         fingerprint: fingerprint)

        XCTAssertFalse(exists(primary, "\(paired.uuidString).v2.epgcache"))
        XCTAssertFalse(exists(primary, "\(paired.uuidString).v1.epgcache"))
        XCTAssertFalse(exists(legacy, "\(paired.uuidString).epgcache"))
        XCTAssertTrue(exists(primary, "\(middle.uuidString).v2.epgcache"), "deleted v1 copies are not still counted")
        XCTAssertTrue(exists(primary, "\(recent.uuidString).v2.epgcache"))
        XCTAssertTrue(exists(primary, "\(kept.uuidString).v2.epgcache"))
    }

    func testEvictingAPairRecountsBytesAndEvictsOnlyWhatTheBudgetNeeds() throws {
        let root = temporaryDirectory()
        let primary = root.appendingPathComponent("primary", isDirectory: true)
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldest = UUID(), paired = UUID(), middle = UUID(), recent = UUID(), kept = UUID()
        try seedV2(primary, oldest, age: 1_200)
        try seedV2(primary, paired, age: 900)
        try seedV1(legacy.appendingPathComponent("\(paired.uuidString).epgcache"), age: 900)
        try seedV2(primary, middle, age: 600)
        try seedV2(primary, recent, age: 300)
        try seedV2(primary, kept, age: 0)
        func size(_ provider: UUID) throws -> Int {
            try XCTUnwrap(primary.appendingPathComponent("\(provider.uuidString).v2.epgcache")
                .resourceValues(forKeys: [.fileSizeKey]).fileSize)
        }
        var store = EPGCacheStore(directory: primary, legacyReadDirectory: legacy)
        // Room for three v2 guides plus less than half of another: evicting the oldest guide alone
        // is not enough, evicting the paired guide and its v1 copy is.
        store.maximumTotalBytes = try size(middle) + size(recent) + size(kept) + size(paired) / 2

        try store.saveV2(.empty(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)), providerID: kept,
                         fingerprint: fingerprint)

        XCTAssertFalse(exists(primary, "\(oldest.uuidString).v2.epgcache"))
        XCTAssertFalse(exists(primary, "\(paired.uuidString).v2.epgcache"))
        XCTAssertFalse(exists(legacy, "\(paired.uuidString).epgcache"), "the readable v1 copy goes with its v2 guide")
        XCTAssertTrue(exists(primary, "\(middle.uuidString).v2.epgcache"), "no guide is evicted once the bytes fit")
        XCTAssertTrue(exists(primary, "\(recent.uuidString).v2.epgcache"))
        XCTAssertTrue(exists(primary, "\(kept.uuidString).v2.epgcache"))
    }

    func testEvictionTerminatesWhenOnlyProtectedLegacyFilesExceedTheBudget() throws {
        let root = temporaryDirectory()
        let primary = root.appendingPathComponent("primary", isDirectory: true)
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let readable = legacy.appendingPathComponent("\(UUID().uuidString).epgcache")
        try seedV1(readable, age: 900)
        let unreadable = legacy.appendingPathComponent("\(UUID().uuidString).v1.epgcache")
        try Data("KEPG\u{1}not-lzfse".utf8).write(to: unreadable)
        let unsupported = primary.appendingPathComponent("\(UUID().uuidString).epgcache")
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        try Data("KEPG\u{9}future-version".utf8).write(to: unsupported)
        var store = EPGCacheStore(directory: primary, legacyReadDirectory: legacy)
        store.maximumEntries = 1
        store.maximumTotalBytes = 1
        let kept = UUID()

        // No v2 candidate exists, so eviction has nothing to remove and must return.
        try store.saveV2(.empty(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)), providerID: kept,
                         fingerprint: fingerprint)

        for url in [readable, unreadable, unsupported] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) is protected")
        }
        XCTAssertTrue(exists(primary, "\(kept.uuidString).v2.epgcache"), "the guide just written is never evicted")
    }

    func testFailedV2ReplacementUnderEvictionPressureKeepsEveryGuide() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let replaced = UUID(), other = UUID()
        try seedV2(directory, replaced, age: 600)
        try seedV2(directory, other, age: 300)
        let before = try v2Header(directory, replaced)
        var failedPromotion = EPGCacheStore(directory: directory)
        failedPromotion.maximumEntries = 1
        failedPromotion.promoter = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        var failedStage = failedPromotion
        failedStage.stageChunkWriter = { _, _ in throw CocoaError(.fileWriteNoPermission) }

        for store in [failedPromotion, failedStage] {
            XCTAssertThrowsError(try store.saveV2(.empty(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)),
                                                  providerID: replaced, fingerprint: fingerprint))
        }

        XCTAssertEqual(try v2Header(directory, replaced).contentID, before.contentID, "the previous verified guide is intact")
        XCTAssertTrue(exists(directory, "\(other.uuidString).v2.epgcache"), "a failed write evicts nothing")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".stage") }
        XCTAssertEqual(leftovers, [], "the failed stage is removed")
    }

    func testEvictionRemovesOnlyAbandonedStagesAndNeverCountsThem() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let older = UUID(), kept = UUID()
        try seedV2(directory, older, age: 600)
        let active = directory.appendingPathComponent("\(UUID().uuidString).\(UUID().uuidString).stage")
        let abandoned = directory.appendingPathComponent("\(UUID().uuidString).\(UUID().uuidString).stage")
        for url in [active, abandoned] { try Data(repeating: 1, count: 4_096).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: abandoned.path)
        var store = EPGCacheStore(directory: directory)
        store.maximumEntries = 2

        try store.saveV2(.empty(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)), providerID: kept,
                         fingerprint: fingerprint)

        XCTAssertTrue(exists(directory, "\(older.uuidString).v2.epgcache"), "stage files do not count as entries")
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path), "a stage that may still be written is kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path), "an abandoned recognized stage is removed")
    }

    // MARK: - Eviction inventory trust

    /// Two backdated v2 guides in `primary`, then a limit of one entry: a trusted inventory evicts both.
    private func overBudgetStore(_ primary: URL, legacy: URL?) throws -> (store: EPGCacheStore, older: UUID, newer: UUID) {
        let older = UUID(), newer = UUID()
        try seedV2(primary, older, age: 600)
        try seedV2(primary, newer, age: 300)
        var store = EPGCacheStore(directory: primary, legacyReadDirectory: legacy)
        store.maximumEntries = 1
        return (store, older, newer)
    }

    private func saveKept(_ store: EPGCacheStore, _ kept: UUID = UUID()) throws -> UUID {
        try store.saveV2(.empty(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)), providerID: kept,
                         fingerprint: fingerprint)
        return kept
    }

    func testEvictionTreatsAMissingLegacyDirectoryAsEmpty() throws {
        let root = temporaryDirectory()
        let primary = root.appendingPathComponent("primary", isDirectory: true)
        let missing = root.appendingPathComponent("never-created", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, older, newer) = try overBudgetStore(primary, legacy: missing)

        let kept = try saveKept(store)

        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertFalse(exists(primary, "\(older.uuidString).v2.epgcache"), "a missing legacy directory does not block eviction")
        XCTAssertFalse(exists(primary, "\(newer.uuidString).v2.epgcache"))
        XCTAssertTrue(exists(primary, "\(kept.uuidString).v2.epgcache"))
    }

    func testUnreadableLegacyDirectoryStopsEvictionWithoutDeletingAnyGuide() throws {
        let root = temporaryDirectory()
        let primary = root.appendingPathComponent("primary", isDirectory: true)
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let (base, older, newer) = try overBudgetStore(primary, legacy: legacy)
        var store = base
        let legacyPath = legacy.standardizedFileURL.path
        store.directoryLister = { url in
            if url.standardizedFileURL.path == legacyPath { throw CocoaError(.fileReadNoPermission) }
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        }

        let kept = try saveKept(store)

        XCTAssertTrue(exists(primary, "\(older.uuidString).v2.epgcache"), "an unreadable directory is not an empty one")
        XCTAssertTrue(exists(primary, "\(newer.uuidString).v2.epgcache"))
        XCTAssertTrue(exists(primary, "\(kept.uuidString).v2.epgcache"), "the new guide is still written")
    }

    func testMissingFileSizeStopsEvictionWithoutDeletingAnyGuide() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (base, older, newer) = try overBudgetStore(directory, legacy: nil)
        var store = base
        let newerName = "\(newer.uuidString).v2.epgcache"
        store.fileMetadataReader = { url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (url.lastPathComponent == newerName ? nil : values.fileSize, values.contentModificationDate)
        }

        let kept = try saveKept(store)

        XCTAssertTrue(exists(directory, "\(older.uuidString).v2.epgcache"), "an unknown size is not zero bytes")
        XCTAssertTrue(exists(directory, newerName))
        XCTAssertTrue(exists(directory, "\(kept.uuidString).v2.epgcache"))
    }

    func testInventoryFailureMidEvictionStopsFurtherDeletion() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (base, older, newer) = try overBudgetStore(directory, legacy: nil)
        var store = base
        let listings = LockedCounter()
        store.directoryLister = { url in
            // The first inventory is complete; every later one fails.
            guard listings.increment() == 1 else { throw CocoaError(.fileReadUnknown) }
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        }

        let kept = try saveKept(store)

        XCTAssertFalse(exists(directory, "\(older.uuidString).v2.epgcache"), "the trusted inventory evicts the oldest guide")
        XCTAssertTrue(exists(directory, "\(newer.uuidString).v2.epgcache"), "an untrusted recount removes nothing more")
        XCTAssertTrue(exists(directory, "\(kept.uuidString).v2.epgcache"))
    }

    func testEvictionResumesOnceATransientInventoryFailureClears() throws {
        let root = temporaryDirectory()
        let primary = root.appendingPathComponent("primary", isDirectory: true)
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let (base, older, newer) = try overBudgetStore(primary, legacy: legacy)
        var store = base
        let failing = LockedCounter(value: 1)
        let legacyPath = legacy.standardizedFileURL.path
        store.directoryLister = { url in
            if url.standardizedFileURL.path == legacyPath, failing.value != 0 { throw CocoaError(.fileReadUnknown) }
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        }

        let kept = try saveKept(store)
        XCTAssertTrue(exists(primary, "\(older.uuidString).v2.epgcache"), "no eviction while the inventory is incomplete")
        XCTAssertTrue(exists(primary, "\(newer.uuidString).v2.epgcache"))

        failing.value = 0
        _ = try saveKept(store, kept)

        XCTAssertFalse(exists(primary, "\(older.uuidString).v2.epgcache"), "the next write with a full inventory evicts")
        XCTAssertFalse(exists(primary, "\(newer.uuidString).v2.epgcache"))
        XCTAssertTrue(exists(primary, "\(kept.uuidString).v2.epgcache"))
    }

    // MARK: - Verified-header state reads

    private let linkedFetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

    /// A one-programme guide with a 20-character title, its validated header, and a linked state.
    private func linkedGuide(_ directory: URL) throws
        -> (store: EPGCacheStore, provider: UUID, header: EPGCacheFormat.Header, state: EPGCacheState) {
        let store = EPGCacheStore(directory: directory)
        let provider = UUID()
        let index = EPGIndex(fetchedAt: linkedFetchedAt, programsByChannel: ["news.one": [
            EPGProgram(channelID: "news.one", start: linkedFetchedAt, end: linkedFetchedAt.addingTimeInterval(3_600),
                       title: "A twenty char title."),
        ]], channelIDsByName: [:], statistics: .init())
        let contentID = try store.saveV2(index, providerID: provider, fingerprint: fingerprint)
        let verified = try XCTUnwrap(store.loadVerifiedGuide(providerID: provider, fingerprint: fingerprint))
        let header = try XCTUnwrap(verified.header, "a v2 read returns the header it validated")
        XCTAssertEqual(header.contentID, contentID)
        let state = EPGCacheState(providerID: provider, sourceFingerprint: fingerprint, contentID: contentID,
                                  lastSuccessfulFetchAt: linkedFetchedAt, failureCount: 2,
                                  nextRetryAt: linkedFetchedAt.addingTimeInterval(600))
        try store.saveState(state)
        return (store, provider, header, state)
    }

    /// A store whose policy rejects that guide on any full decode, while header checks still pass.
    /// It accepting linked state therefore shows the guide was not decoded again.
    private func probe(_ store: EPGCacheStore) -> EPGCacheStore {
        var strict = store
        strict.formatLimits.maximumTextLength = 5
        return strict
    }

    private func v2File(_ directory: URL, _ provider: UUID) -> URL {
        directory.appendingPathComponent("\(provider.uuidString).v2.epgcache")
    }

    func testVerifiedHeaderRestoresLinkedStateWithoutDecodingTheGuideAgain() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, provider, header, state) = try linkedGuide(directory)

        XCTAssertEqual(store.loadStateForCurrentGuide(providerID: provider, fingerprint: fingerprint,
                                                      verifiedHeader: header), state)
        XCTAssertEqual(probe(store).loadStateForCurrentGuide(providerID: provider, fingerprint: fingerprint,
                                                             verifiedHeader: header), state,
                       "the file just validated is recognized from its header and digest alone")
        XCTAssertNil(probe(store).loadStateForCurrentGuide(providerID: provider, fingerprint: fingerprint),
                     "without a verified header the guide is fully decoded, and this probe rejects it")
        XCTAssertEqual(store.loadStateForCurrentGuide(providerID: provider, fingerprint: fingerprint), state,
                       "full validation still accepts the same state")
    }

    func testVerifiedHeaderNeverLinksStateToAnotherGuideOrSource() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, provider, header, state) = try linkedGuide(directory)

        let otherSource = EPGCacheFormat.Header(
            providerID: header.providerID, contentID: header.contentID,
            sourceFingerprint: Data(repeating: 0xAB, count: EPGCacheFormat.fingerprintLength),
            fetchedAt: header.fetchedAt, coverage: header.coverage, programCount: header.programCount,
            channelCount: header.channelCount, compressedLength: header.compressedLength,
            decompressedLength: header.decompressedLength, payloadDigest: header.payloadDigest)
        XCTAssertNil(probe(store).loadStateForCurrentGuide(providerID: provider, fingerprint: fingerprint,
                                                           verifiedHeader: otherSource),
                     "a header bound to another source is ignored and the guide is fully validated")
        XCTAssertEqual(store.loadStateForCurrentGuide(providerID: provider, fingerprint: fingerprint,
                                                      verifiedHeader: otherSource), state)

        try store.saveState(EPGCacheState(providerID: provider, sourceFingerprint: fingerprint, contentID: UUID(),
                                          lastSuccessfulFetchAt: linkedFetchedAt))
        XCTAssertNil(store.loadStateForCurrentGuide(providerID: provider, fingerprint: fingerprint,
                                                    verifiedHeader: header),
                     "state linked to another write is not made current by this guide's header")
        XCTAssertTrue(FileManager.default.fileExists(atPath: v2File(directory, provider).path))
    }

    func testGuideReplacedAfterVerificationFallsBackToFullValidation() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, provider, staleHeader, staleState) = try linkedGuide(directory)
        let replacement = EPGIndex.empty(fetchedAt: linkedFetchedAt.addingTimeInterval(60))
        let newContentID = try store.saveV2(replacement, providerID: provider, fingerprint: fingerprint)

        XCTAssertNil(store.loadStateForCurrentGuide(providerID: provider, fingerprint: fingerprint,
                                                    verifiedHeader: staleHeader),
                     "state for the replaced guide is not current")
        let current = EPGCacheState(providerID: provider, sourceFingerprint: fingerprint, contentID: newContentID,
                                    lastSuccessfulFetchAt: replacement.fetchedAt)
        try store.saveState(current)
        XCTAssertEqual(store.loadStateForCurrentGuide(providerID: provider, fingerprint: fingerprint,
                                                      verifiedHeader: staleHeader), current,
                       "the replacement is fully validated and accepted on its own")
        XCTAssertNotEqual(staleState.contentID, newContentID)
    }

    func testGuideChangedOnDiskAfterVerificationIsNotTrusted() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, provider, header, _) = try linkedGuide(directory)
        let url = v2File(directory, provider)
        let original = try Data(contentsOf: url)
        var payloadFlip = original
        payloadFlip[payloadFlip.count - 2] ^= 0x01
        var headerEdit = original
        headerEdit[95] ^= 0x01  // coverage end
        let mutations: [(String, Data)] = [("payload byte", payloadFlip), ("header field", headerEdit),
                                           ("truncation", original.dropLast()), ("empty file", Data())]

        for (label, bytes) in mutations {
            try bytes.write(to: url)
            XCTAssertNil(store.loadStateForCurrentGuide(providerID: provider, fingerprint: fingerprint,
                                                        verifiedHeader: header), label)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(label): a state read never deletes the guide")
        }
        try original.write(to: url)
        XCTAssertNotNil(store.loadStateForCurrentGuide(providerID: provider, fingerprint: fingerprint,
                                                       verifiedHeader: header), "the state itself was kept")
    }

    func testGuidesThatFailDecodingNeverYieldAVerifiedHeaderOrState() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, provider, _, _) = try linkedGuide(directory)
        let url = v2File(directory, provider)
        let original = try Data(contentsOf: url)
        let start = Int(linkedFetchedAt.timeIntervalSince1970)
        func record(_ rows: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["fetchedAt": linkedFetchedAt.timeIntervalSince1970,
                                                        "channelIDs": ["news.one"], "names": [String: String](),
                                                        "rows": rows])
        }
        /// Replaces the payload and rewrites every header field it affects, so the digest and
        /// lengths are valid and only the record itself can be rejected.
        func digestValid(_ json: Data, programs: Int, coverage: (Int, Int)) throws -> Data {
            let payload = try (json as NSData).compressed(using: .lzfse) as Data
            var file = Data(original.prefix(EPGCacheFormat.headerLength))
            func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
                withUnsafeBytes(of: value.bigEndian) { file.replaceSubrange(offset..<offset + MemoryLayout<T>.size, with: $0) }
            }
            put(UInt64(coverage.0), at: 84)
            put(UInt64(coverage.1), at: 92)
            put(UInt32(programs), at: 100)
            put(UInt64(payload.count), at: 108)
            put(UInt64(json.count), at: 116)
            file.replaceSubrange(124..<156, with: Data(SHA256.hash(data: payload)))
            return file + payload
        }

        let control = try digestValid(record([["c": 0, "s": start, "d": 3_600, "t": "ok"]]), programs: 1,
                                      coverage: (start, start + 3_600))
        try control.write(to: url)
        XCTAssertNotNil(store.loadVerifiedGuide(providerID: provider, fingerprint: fingerprint),
                        "control: the rewritten framing itself is accepted")

        let rejected: [(String, Data)] = [
            ("malformed JSON", try digestValid(Data("{\"rows\":".utf8), programs: 1, coverage: (start, start + 3_600))),
            ("overlapping programmes", try digestValid(record([["c": 0, "s": start, "d": 3_600, "t": "a"],
                                                               ["c": 0, "s": start + 60, "d": 3_540, "t": "b"]]),
                                                        programs: 2, coverage: (start, start + 3_600))),
            ("reordered programmes", try digestValid(record([["c": 0, "s": start + 3_600, "d": 3_600, "t": "b"],
                                                             ["c": 0, "s": start, "d": 3_600, "t": "a"]]),
                                                      programs: 2, coverage: (start, start + 7_200))),
        ]
        for (label, bytes) in rejected {
            try bytes.write(to: url)
            XCTAssertNil(store.loadVerifiedGuide(providerID: provider, fingerprint: fingerprint), label)
            XCTAssertNil(store.loadStateForCurrentGuide(providerID: provider, fingerprint: fingerprint), label)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(label): rejection keeps the file")
        }
    }

    func testRestartRestoresTheVerifiedGuideAndItsLinkedBackoff() async throws {
        let directory = temporaryDirectory(), provider = UUID()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/linked-backoff.xml")!)
        let fingerprinter = EPGSourceFingerprinter.inMemory()
        let fp = try fingerprinter.fingerprint(for: source).bytes
        let cache = EPGCacheStore(directory: directory)
        let contentID = try cache.saveV2(.empty(fetchedAt: linkedFetchedAt), providerID: provider, fingerprint: fp)
        let restartAt = linkedFetchedAt.addingTimeInterval(13 * 3_600)  // stale but still usable
        try cache.saveState(EPGCacheState(providerID: provider, sourceFingerprint: fp, contentID: contentID,
                                          lastSuccessfulFetchAt: linkedFetchedAt, failureCount: 1,
                                          nextRetryAt: restartAt.addingTimeInterval(300)))
        let offline = StateTestLoader(failure: EPGError.providerRejected)
        let service = EPGService(cache: cache, loader: offline, fingerprinter: fingerprinter, now: { restartAt })

        let guide = try await service.refresh(providerID: provider, source: source)

        XCTAssertEqual(guide.fetchedAt, linkedFetchedAt, "the cached guide is restored")
        XCTAssertEqual(offline.calls, 0, "the linked backoff state is restored, so the feed is not fetched")
        let freshness = await service.freshness(for: provider)
        XCTAssertEqual(freshness, .stale)
    }

    func testSaveV2RejectsAStageThatDoesNotDecodeToTheSameGuide() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, provider, header, state) = try linkedGuide(directory)
        let original = try Data(contentsOf: v2File(directory, provider))
        let newer = EPGIndex.empty(fetchedAt: linkedFetchedAt.addingTimeInterval(60))
        let fp = fingerprint
        var disagreeing = store
        disagreeing.stageChunkWriter = { bytes, handle in
            // Same provider, source and content ID as the stage, but a different guide inside: only
            // the reopened header and content comparison can reject it.
            guard bytes.count == EPGCacheFormat.headerLength, bytes.starts(with: Data("KEPG".utf8)) else {
                return try handle.write(contentsOf: bytes)
            }
            let contentID = bytes[28..<44].withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: EPGCacheFormat.encode(.empty(fetchedAt: newer.fetchedAt.addingTimeInterval(1)),
                                                              providerID: provider, sourceFingerprint: fp,
                                                              contentID: contentID))
        }
        var corrupting = store
        let chunks = LockedCounter()
        corrupting.stageChunkWriter = { bytes, handle in
            // The second chunk is the first compressed output, after the zeroed header.
            var damaged = bytes
            if chunks.increment() == 2 { damaged[damaged.startIndex] ^= 0xFF }
            try handle.write(contentsOf: damaged)
        }

        for (label, failing) in [("encoder/decoder disagreement", disagreeing), ("stage corruption", corrupting)] {
            XCTAssertThrowsError(try failing.saveV2(newer, providerID: provider, fingerprint: fingerprint), label)
            XCTAssertEqual(try Data(contentsOf: v2File(directory, provider)), original, "\(label): previous guide kept")
            XCTAssertEqual(store.loadStateForCurrentGuide(providerID: provider, fingerprint: fingerprint,
                                                          verifiedHeader: header), state, "\(label): state kept")
        }
        let stages = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".stage") }
        XCTAssertEqual(stages, [], "failed stages are removed")
    }

    func testRetryStatePersistsAcrossServiceInstancesForTheSameSource() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = UUID()
        let source = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/list.xml")!)
        let keys = EPGInMemoryKeyStore()
        let fingerprinter = EPGSourceFingerprinter(keys: EPGFingerprintKeyProvider(store: keys))
        let cache = EPGCacheStore(directory: directory)
        let failedLoader = StateTestLoader(failure: EPGError.providerRejected)
        let first = EPGService(cache: cache, loader: failedLoader, fingerprinter: fingerprinter,
                               now: { Date(timeIntervalSince1970: 1_800_000_000) })
        do { _ = try await first.refresh(providerID: provider, source: source); XCTFail("expected feed failure") }
        catch { XCTAssertEqual(error as? EPGError, .providerRejected) }
        let fp = try fingerprinter.fingerprint(for: source).bytes
        let statePath = directory.appendingPathComponent("\(provider.uuidString).state").path
        let stateDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: statePath), Date() < stateDeadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let persisted = try XCTUnwrap(cache.loadState(providerID: provider, fingerprint: fp))
        XCTAssertEqual(persisted.failureCount, 1)
        XCTAssertEqual(persisted.nextRetryDate, Date(timeIntervalSince1970: 1_800_000_300))

        let offline = StateTestLoader(failure: EPGError.providerRejected)
        let restarted = EPGService(cache: cache, loader: offline, fingerprinter: fingerprinter,
                                   now: { Date(timeIntervalSince1970: 1_800_000_010) })
        do { _ = try await restarted.refresh(providerID: provider, source: source); XCTFail("expected backoff") }
        catch { XCTAssertEqual(error as? EPGError, .providerRejected) }
        XCTAssertEqual(offline.calls, 0, "persisted backoff survives a new service instance")
    }

    func testSuccessfulRefreshKeepsLinkedStateAcrossServiceRestart() async throws {
        let directory = temporaryDirectory(), provider = UUID()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/restart.xml")!)
        let fingerprinter = EPGSourceFingerprinter.inMemory()
        let fingerprint = try fingerprinter.fingerprint(for: source).bytes
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = EPGCacheStore(directory: directory)
        let first = EPGService(cache: cache, loader: StaticEPGLoader(data: Data("<tv/>".utf8)),
                               fingerprinter: fingerprinter, now: { fetchedAt })
        _ = try await first.refresh(providerID: provider, source: source)

        let deadline = Date().addingTimeInterval(5)
        var persisted: EPGCacheState?
        while persisted == nil, Date() < deadline {
            persisted = cache.loadStateForCurrentGuide(providerID: provider, fingerprint: fingerprint)
            if persisted == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        }
        let original = try XCTUnwrap(persisted, "guide and content-linked state should finish persisting")
        XCTAssertNotNil(original.contentID)
        XCTAssertEqual(original.lastSuccessfulFetchDate, fetchedAt)

        let offline = StateTestLoader(failure: EPGError.providerRejected)
        let restarted = EPGService(cache: cache, loader: offline, fingerprinter: fingerprinter,
                                   now: { fetchedAt.addingTimeInterval(1) })
        await XCTAssertThrowsErrorAsync(try await restarted.refresh(providerID: provider, source: source, force: true)) {
            XCTAssertEqual($0 as? EPGError, .providerRejected)
        }
        var afterFailure: EPGCacheState?
        let failureDeadline = Date().addingTimeInterval(5)
        while afterFailure?.failureCount != 1, Date() < failureDeadline {
            afterFailure = cache.loadStateForCurrentGuide(providerID: provider, fingerprint: fingerprint)
            if afterFailure?.failureCount != 1 { try await Task.sleep(nanoseconds: 2_000_000) }
        }
        let retried = try XCTUnwrap(afterFailure)
        XCTAssertEqual(retried.contentID, original.contentID, "retry state must stay linked to the verified guide")
        XCTAssertEqual(retried.sourceFingerprint, fingerprint)
        XCTAssertEqual(retried.lastSuccessfulFetchDate, fetchedAt, "restart preserves the prior successful fetch")
    }

    func testProviderRemovalDeletesPersistedRetryState() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = UUID()
        let source = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/list.xml")!)
        let keys = EPGInMemoryKeyStore()
        let fingerprinter = EPGSourceFingerprinter(keys: EPGFingerprintKeyProvider(store: keys))
        let cache = EPGCacheStore(directory: directory)
        let service = EPGService(cache: cache, loader: StateTestLoader(failure: EPGError.providerRejected),
                                 fingerprinter: fingerprinter)
        do { _ = try await service.refresh(providerID: provider, source: source); XCTFail("expected feed failure") }
        catch { XCTAssertEqual(error as? EPGError, .providerRejected) }
        let statePath = directory.appendingPathComponent("\(provider.uuidString).state").path
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: statePath), Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: statePath))
        await service.remove(providerID: provider)
        XCTAssertFalse(FileManager.default.fileExists(atPath: statePath))
    }

    func testOlderDiskStateNeverClearsANewerFailureWhileItsWriteIsHeld() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = UUID()
        let source = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/list.xml")!)
        let fingerprinter = EPGSourceFingerprinter.inMemory()
        let fp = try fingerprinter.fingerprint(for: source).bytes
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // On disk: the last refresh succeeded, so there is no backoff.
        try EPGCacheStore(directory: directory).saveState(
            EPGCacheState(providerID: provider, sourceFingerprint: fp, lastSuccessfulFetchAt: now.addingTimeInterval(-60)))

        let gate = StateWriteGate()
        var cache = EPGCacheStore(directory: directory)
        cache.stateWriter = { data, url in try gate.write(data, to: url) }
        let loader = StateTestLoader(failure: EPGError.providerRejected)
        let service = EPGService(cache: cache, loader: loader, fingerprinter: fingerprinter, now: { now })

        await XCTAssertThrowsErrorAsync(try await service.refresh(providerID: provider, source: source))
        XCTAssertEqual(loader.calls, 1)
        let entered = await Task.detached { gate.waitUntilEntered(timeout: 5) }.value
        XCTAssertTrue(entered, "the failure's state write is held")

        // The disk still says "no failures"; the newer in-memory backoff must win.
        await XCTAssertThrowsErrorAsync(try await service.refresh(providerID: provider, source: source)) {
            XCTAssertEqual($0 as? EPGError, .providerRejected)
        }
        XCTAssertEqual(loader.calls, 1, "a second refresh during the held write does not refetch")

        gate.release()
        let statePath = directory.appendingPathComponent("\(provider.uuidString).state")
        let deadline = Date().addingTimeInterval(5)
        while EPGCacheStore(directory: directory).loadState(providerID: provider, fingerprint: fp)?.failureCount != 1,
              Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let persisted = try XCTUnwrap(EPGCacheStore(directory: directory).loadState(providerID: provider, fingerprint: fp))
        XCTAssertEqual(persisted.failureCount, 1)
        XCTAssertEqual(persisted.lastSuccessfulFetchDate, now.addingTimeInterval(-60), "the last success is kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: statePath.path))
    }

    func testStateReadAndCleanupWaitForQueuedWritesForTheProvider() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = UUID()
        let first = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/a.xml")!)
        let second = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/b.xml")!)
        let fingerprinter = EPGSourceFingerprinter.inMemory()
        let secondFingerprint = try fingerprinter.fingerprint(for: second).bytes
        let gate = StateWriteGate()
        var cache = EPGCacheStore(directory: directory)
        cache.stateWriter = { data, url in try gate.write(data, to: url) }
        let loader = StateTestLoader(failure: EPGError.providerRejected)
        let service = EPGService(cache: cache, loader: loader, fingerprinter: fingerprinter,
                                 now: { Date(timeIntervalSince1970: 1_800_000_000) })

        await XCTAssertThrowsErrorAsync(try await service.refresh(providerID: provider, source: first))
        let entered = await Task.detached { gate.waitUntilEntered(timeout: 5) }.value
        XCTAssertTrue(entered, "the first source's state write is held")

        // A new source needs its own state read, which must queue behind the held write instead of
        // judging (and possibly deleting) the file while that write is still landing.
        let refresh = Task { try await service.refresh(providerID: provider, source: second) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(loader.calls, 1, "the second source's refresh is still waiting for the queued write")

        gate.release()
        gate.release()  // the second source's own failure write
        await XCTAssertThrowsErrorAsync(try await refresh.value)
        XCTAssertEqual(loader.calls, 2)
        let deadline = Date().addingTimeInterval(5)
        while EPGCacheStore(directory: directory).loadState(providerID: provider, fingerprint: secondFingerprint) == nil,
              Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let persisted = EPGCacheStore(directory: directory).loadState(providerID: provider, fingerprint: secondFingerprint)
        XCTAssertEqual(persisted?.failureCount, 1, "only the current source's state remains")
    }

    func testRemovalWaitsForAnInFlightStateWriteAndLeavesNoResurrectedFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = UUID()
        let source = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/list.xml")!)
        let keys = EPGInMemoryKeyStore()
        let fingerprinter = EPGSourceFingerprinter(keys: EPGFingerprintKeyProvider(store: keys))
        let gate = StateWriteGate()
        var cache = EPGCacheStore(directory: directory)
        cache.stateWriter = { data, url in try gate.write(data, to: url) }
        let service = EPGService(cache: cache, loader: StateTestLoader(failure: EPGError.providerRejected),
                                 fingerprinter: fingerprinter)
        do { _ = try await service.refresh(providerID: provider, source: source); XCTFail("expected feed failure") }
        catch { XCTAssertEqual(error as? EPGError, .providerRejected) }

        let entered = await Task.detached { gate.waitUntilEntered(timeout: 5) }.value
        XCTAssertTrue(entered, "failure state write reached the gate")
        let removal = Task { await service.remove(providerID: provider) }
        // Let the actor advance the generation and begin waiting for its pending write.
        try await Task.sleep(nanoseconds: 20_000_000)
        gate.release()
        await removal.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(provider.uuidString).state").path))
    }

    // MARK: - Fractional fetch times

    func testFractionalFetchTimesRoundTripExactlyThroughV2AndLinkedState() throws {
        let directory = temporaryDirectory(), provider = UUID()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EPGCacheStore(directory: directory)
        for step in 0..<8 {
            let raw = Self.fractionalDate(offset: Double(step) * 61.37)
            XCTAssertNotEqual(Date(timeIntervalSince1970: raw.timeIntervalSince1970), raw,
                              "precondition: this Date() value does not survive the 1970-based round trip")
            let canonical = EPGTimestamp.canonical(raw)
            XCTAssertEqual(EPGTimestamp.canonical(canonical), canonical, "canonicalization is idempotent")
            XCTAssertEqual(canonical.timeIntervalSince1970, raw.timeIntervalSince1970, "the persisted value is unchanged")
            XCTAssertLessThan(abs(canonical.timeIntervalSince(raw)), 1e-6, "freshness is unaffected")

            let index = Self.guide(fetchedAt: raw, title: "Step \(step)")
            XCTAssertEqual(index.fetchedAt, canonical)
            let contentID = try store.saveV2(index, providerID: provider, fingerprint: fingerprint)
            try store.saveState(EPGCacheState(providerID: provider, sourceFingerprint: fingerprint, contentID: contentID,
                                              lastSuccessfulFetchAt: index.fetchedAt))

            let reopened = try XCTUnwrap(store.loadVerified(providerID: provider, fingerprint: fingerprint))
            XCTAssertEqual(reopened.fetchedAt, index.fetchedAt)
            XCTAssertEqual(reopened.programsByChannel, index.programsByChannel)
            let header = try v2Header(directory, provider)
            XCTAssertEqual(header.contentID, contentID)
            XCTAssertEqual(header.fetchedAt, index.fetchedAt)
            let state = try XCTUnwrap(store.loadStateForCurrentGuide(providerID: provider, fingerprint: fingerprint))
            XCTAssertEqual(state.contentID, contentID)
            XCTAssertEqual(state.lastSuccessfulFetchDate, index.fetchedAt)
        }
    }

    func testFractionalClockRefreshesPersistEachGuideAndSurviveRestart() async throws {
        let directory = temporaryDirectory(), provider = UUID()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/fractional.xml")!)
        let fingerprinter = EPGSourceFingerprinter.inMemory()
        let fp = try fingerprinter.fingerprint(for: source).bytes
        let cache = EPGCacheStore(directory: directory)
        let clock = FractionalClock(Self.fractionalDate(offset: 0))
        let loader = ScriptedEPGLoader()
        let service = EPGService(cache: cache, loader: loader, fingerprinter: fingerprinter, now: { clock.date })

        var last: EPGIndex?
        for step in 0..<3 {
            clock.date = Self.fractionalDate(offset: Double(step) * 61.37)
            XCTAssertNotEqual(Date(timeIntervalSince1970: clock.date.timeIntervalSince1970), clock.date)
            loader.enqueue(.success(Self.feed(around: clock.date, title: "Refresh \(step)")))
            let index = try await service.refresh(providerID: provider, source: source, force: true)
            XCTAssertEqual(index.fetchedAt, EPGTimestamp.canonical(clock.date))
            XCTAssertNotEqual(index.fetchedAt, last?.fetchedAt)
            let state = try await persistedState(cache, provider, fp) { $0.lastSuccessfulFetchDate == index.fetchedAt }
            let header = try v2Header(directory, provider)
            XCTAssertEqual(header.fetchedAt, index.fetchedAt, "refresh \(step) was written as v2")
            XCTAssertEqual(state.contentID, header.contentID, "refresh \(step) state is linked to its guide")
            last = index
        }
        let written = try XCTUnwrap(last)
        XCTAssertEqual(loader.calls, 3)

        let offline = StateTestLoader(failure: EPGError.providerRejected)
        let restartClock = FractionalClock(Self.fractionalDate(offset: 3 * 61.37 + 5))
        let restarted = EPGService(cache: cache, loader: offline, fingerprinter: fingerprinter, now: { restartClock.date })
        let restored = await restarted.index(for: provider, source: source)
        let cached = try XCTUnwrap(restored, "the last guide survives restart")
        XCTAssertEqual(cached.fetchedAt, written.fetchedAt)
        XCTAssertEqual(cached.programsByChannel, written.programsByChannel)
        XCTAssertEqual(offline.calls, 0)

        await XCTAssertThrowsErrorAsync(try await restarted.refresh(providerID: provider, source: source, force: true))
        let failed = try await persistedState(cache, provider, fp) { $0.failureCount == 1 }
        XCTAssertEqual(failed.contentID, try v2Header(directory, provider).contentID)
        XCTAssertEqual(failed.lastSuccessfulFetchDate, written.fetchedAt, "restart keeps the last successful fetch")
    }

    func testFailureRecordedWhileItsGuideIsWrittenStaysLinkedToThatGuide() async throws {
        let directory = temporaryDirectory(), provider = UUID()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/ordering.xml")!)
        let fingerprinter = EPGSourceFingerprinter.inMemory()
        let fp = try fingerprinter.fingerprint(for: source).bytes
        let gate = StateWriteGate()
        var cache = EPGCacheStore(directory: directory)
        cache.stageChunkWriter = { data, handle in try gate.append(data, to: handle) }
        let clock = FractionalClock(Self.fractionalDate(offset: 0))
        let loader = ScriptedEPGLoader()
        loader.enqueue(.success(Self.feed(around: clock.date, title: "Guide")))
        loader.enqueue(.failure(EPGError.providerRejected))
        let service = EPGService(cache: cache, loader: loader, fingerprinter: fingerprinter, now: { clock.date })

        let index = try await service.refresh(providerID: provider, source: source)
        let entered = await Task.detached { gate.waitUntilEntered(timeout: 5) }.value
        XCTAssertTrue(entered, "the guide write is held")
        clock.date = Self.fractionalDate(offset: 30.5)
        await XCTAssertThrowsErrorAsync(try await service.refresh(providerID: provider, source: source, force: true)) {
            XCTAssertEqual($0 as? EPGError, .providerRejected)
        }
        gate.release()

        let state = try await persistedState(EPGCacheStore(directory: directory), provider, fp) { $0.failureCount == 1 }
        XCTAssertEqual(state.contentID, try v2Header(directory, provider).contentID,
                       "the newer failure keeps its retry fields and the link to the guide written before it")
        XCTAssertEqual(state.lastSuccessfulFetchDate, index.fetchedAt)
        XCTAssertNotNil(state.nextRetryDate)
    }

    /// A `Date()`-like value whose lowest bit is set. While seconds since 2001 lie in [2^29, 2^30)
    /// (2018 to 2035), that bit cannot survive conversion to seconds since 1970.
    private static func fractionalDate(offset: TimeInterval) -> Date {
        let seconds = Date().timeIntervalSinceReferenceDate + offset
        return Date(timeIntervalSinceReferenceDate: Double(bitPattern: seconds.bitPattern | 1))
    }

    private static func guide(fetchedAt: Date, title: String) -> EPGIndex {
        let base = (fetchedAt.timeIntervalSince1970 / 60).rounded(.down) * 60
        let programs = (0..<4).map { slot in
            EPGProgram(channelID: "news.one", start: Date(timeIntervalSince1970: base + Double(slot) * 1_800),
                       end: Date(timeIntervalSince1970: base + Double(slot + 1) * 1_800), title: "\(title) \(slot)")
        }
        return EPGIndex(fetchedAt: fetchedAt, programsByChannel: ["news.one": programs],
                        channelIDsByName: ["newsone": "news.one"], statistics: .init())
    }

    /// Eight hours of half-hour programmes starting half an hour before `date`, in whole seconds.
    private static func feed(around date: Date, title: String) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss '+0000'"
        let base = (date.timeIntervalSince1970 / 1_800).rounded(.down) * 1_800
        let rows = (0..<16).map { slot -> String in
            let start = Date(timeIntervalSince1970: base + Double(slot - 1) * 1_800)
            let stop = start.addingTimeInterval(1_800)
            return "<programme channel=\"news.one\" start=\"\(formatter.string(from: start))\" "
                + "stop=\"\(formatter.string(from: stop))\"><title>\(title) \(slot)</title></programme>"
        }
        return Data("<tv>\n\(rows.joined(separator: "\n"))\n</tv>".utf8)
    }

    // MARK: - Short-guide request ordering

    /// Completion order is controlled by the test body: each response is applied, or not, exactly
    /// where the test places its `applyShortPrograms` call. No timing or delays are involved.
    private let shortSource = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/short-order.xml")!)
    private let shortNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func shortListing(_ title: String, guideID: String = "sports.two") -> [EPGProgram] {
        [EPGProgram(channelID: guideID, start: shortNow.addingTimeInterval(-60),
                    end: shortNow.addingTimeInterval(3_600), title: title)]
    }

    private func shortService(loader: ScriptedEPGLoader = ScriptedEPGLoader(), cache: EPGCacheStore? = nil) -> EPGService {
        EPGService(cache: cache, loader: loader, fingerprinter: .inMemory(), now: { [shortNow] in shortNow })
    }

    func testShortResponseStartedBeforeFullRefreshIsRejected() async throws {
        let loader = ScriptedEPGLoader()
        loader.enqueue(.success(Self.feed(around: shortNow, title: "Full")))
        let service = shortService(loader: loader)
        let provider = UUID()
        let issued = await service.beginShortRequest(providerID: provider, source: shortSource, guideID: "sports.two")
        let ticket = try XCTUnwrap(issued)

        _ = try await service.refresh(providerID: provider, source: shortSource, force: true)
        let stale = await service.applyShortPrograms(shortListing("Stale short"), guideID: "sports.two", ticket: ticket)
        XCTAssertNil(stale, "a response that began before the full guide was published must not apply")

        let indexed = await service.index(for: provider, source: shortSource)
        let guide = try XCTUnwrap(indexed)
        XCTAssertFalse(guide.isShortGuideOnly)
        XCTAssertNil(guide.nowNext(guideID: "sports.two", name: nil, at: shortNow).current)
        XCTAssertEqual(guide.nowNext(guideID: "news.one", name: nil, at: shortNow).current?.title.hasPrefix("Full"), true)
        let freshness = await service.freshness(for: provider)
        XCTAssertEqual(freshness, .fresh, "rejection leaves full-guide freshness alone")
    }

    func testShortResponseStartedAfterFullRefreshIsAccepted() async throws {
        let loader = ScriptedEPGLoader()
        loader.enqueue(.success(Self.feed(around: shortNow, title: "Full")))
        let service = shortService(loader: loader)
        let provider = UUID()
        _ = try await service.refresh(providerID: provider, source: shortSource, force: true)

        let issued = await service.beginShortRequest(providerID: provider, source: shortSource, guideID: "sports.two")
        let ticket = try XCTUnwrap(issued)
        let applied = await service.applyShortPrograms(shortListing("Fresh short"), guideID: "sports.two", ticket: ticket)
        XCTAssertNotNil(applied)

        let indexed = await service.index(for: provider, source: shortSource)
        let guide = try XCTUnwrap(indexed)
        XCTAssertFalse(guide.isShortGuideOnly)
        XCTAssertEqual(guide.nowNext(guideID: "sports.two", name: nil, at: shortNow).current?.title, "Fresh short")
        XCTAssertEqual(guide.nowNext(guideID: "news.one", name: nil, at: shortNow).current?.title.hasPrefix("Full"), true,
                       "unrelated channels of the full guide are preserved")
        let freshness = await service.freshness(for: provider)
        XCTAssertEqual(freshness, .fresh)
    }

    func testFailedFullRefreshDoesNotInvalidatePendingShortResponse() async throws {
        let service = shortService(loader: ScriptedEPGLoader())  // no scripted responses: the refresh fails
        let provider = UUID()
        let issued = await service.beginShortRequest(providerID: provider, source: shortSource, guideID: "sports.two")
        let ticket = try XCTUnwrap(issued)
        await XCTAssertThrowsErrorAsync(try await service.refresh(providerID: provider, source: shortSource, force: true))
        let applied = await service.applyShortPrograms(shortListing("Still current"), guideID: "sports.two", ticket: ticket)
        XCTAssertNotNil(applied, "only a successful full publication supersedes short requests")
    }

    func testOverlappingShortRequestsForOneChannelNewestRequestWins() async throws {
        let service = shortService()
        // Responses arrive oldest-first, then newest-first, for two separate providers.
        let oldestFirst = UUID(), newestFirst = UUID()
        let issuedFirstA = await service.beginShortRequest(providerID: oldestFirst, source: shortSource, guideID: "sports.two")
        let issuedSecondA = await service.beginShortRequest(providerID: oldestFirst, source: shortSource, guideID: "sports.two")
        let issuedFirstB = await service.beginShortRequest(providerID: newestFirst, source: shortSource, guideID: "sports.two")
        let issuedSecondB = await service.beginShortRequest(providerID: newestFirst, source: shortSource, guideID: "sports.two")
        let firstA = try XCTUnwrap(issuedFirstA)
        let secondA = try XCTUnwrap(issuedSecondA)
        let firstB = try XCTUnwrap(issuedFirstB)
        let secondB = try XCTUnwrap(issuedSecondB)

        let olderA = await service.applyShortPrograms(shortListing("Older"), guideID: "sports.two", ticket: firstA)
        let newerA = await service.applyShortPrograms(shortListing("Newer"), guideID: "sports.two", ticket: secondA)
        let repeatedA = await service.applyShortPrograms(shortListing("Older late"), guideID: "sports.two", ticket: firstA)
        let newerB = await service.applyShortPrograms(shortListing("Newer"), guideID: "sports.two", ticket: secondB)
        let olderB = await service.applyShortPrograms(shortListing("Older"), guideID: "sports.two", ticket: firstB)
        XCTAssertNotNil(olderA)
        XCTAssertNotNil(newerA)
        XCTAssertNil(repeatedA, "a repeated older ticket cannot be applied again")
        XCTAssertNotNil(newerB)
        XCTAssertNil(olderB, "an older response completing after a newer one for the same channel is dropped")

        for provider in [oldestFirst, newestFirst] {
            let indexed = await service.index(for: provider, source: shortSource)
            let guide = try XCTUnwrap(indexed)
            XCTAssertEqual(guide.nowNext(guideID: "sports.two", name: nil, at: shortNow).current?.title,
                           "Newer", "newest request wins for \(provider == oldestFirst ? "oldest-first" : "newest-first") order")
        }
    }

    func testOlderResponseForOneChannelDoesNotBlockAnotherChannel() async throws {
        let service = shortService()
        let provider = UUID()
        let issuedSlow = await service.beginShortRequest(providerID: provider, source: shortSource, guideID: "sports.two")
        let issuedFast = await service.beginShortRequest(providerID: provider, source: shortSource, guideID: "news.one")
        let slow = try XCTUnwrap(issuedSlow)
        let fast = try XCTUnwrap(issuedFast)
        let otherChannel = await service.applyShortPrograms(shortListing("Other channel", guideID: "news.one"),
                                                            guideID: "news.one", ticket: fast)
        let slowChannel = await service.applyShortPrograms(shortListing("Slow channel"), guideID: "sports.two", ticket: slow)
        XCTAssertNotNil(otherChannel)
        XCTAssertNotNil(slowChannel, "ordering is per channel, not per provider")
        let indexed = await service.index(for: provider, source: shortSource)
        let guide = try XCTUnwrap(indexed)
        XCTAssertEqual(guide.nowNext(guideID: "news.one", name: nil, at: shortNow).current?.title, "Other channel")
        XCTAssertEqual(guide.nowNext(guideID: "sports.two", name: nil, at: shortNow).current?.title, "Slow channel")
    }

    func testRemovedProviderRejectsPendingShortResponse() async throws {
        let service = shortService()
        let provider = UUID()
        let issued = await service.beginShortRequest(providerID: provider, source: shortSource, guideID: "sports.two")
        let ticket = try XCTUnwrap(issued)
        await service.remove(providerID: provider)
        let applied = await service.applyShortPrograms(shortListing("Removed"), guideID: "sports.two", ticket: ticket)
        XCTAssertNil(applied)
        let reissued = await service.beginShortRequest(providerID: provider, source: shortSource, guideID: "sports.two")
        XCTAssertNil(reissued, "a removed provider issues no new tickets")
        let restored = await service.index(for: provider, source: shortSource)
        XCTAssertNil(restored)
    }

    func testSourceChangeRejectsPendingShortResponseFromTheOldSource() async throws {
        let service = shortService()
        let provider = UUID()
        let replaced = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/replacement.xml")!)
        let issuedOld = await service.beginShortRequest(providerID: provider, source: shortSource, guideID: "sports.two")
        let issuedNew = await service.beginShortRequest(providerID: provider, source: replaced, guideID: "sports.two")
        let pendingOld = try XCTUnwrap(issuedOld)
        let newSourceTicket = try XCTUnwrap(issuedNew)
        let oldApplied = await service.applyShortPrograms(shortListing("Old source"), guideID: "sports.two", ticket: pendingOld)
        let newApplied = await service.applyShortPrograms(shortListing("New source"), guideID: "sports.two",
                                                          ticket: newSourceTicket)
        XCTAssertNil(oldApplied)
        XCTAssertNotNil(newApplied)
        let indexed = await service.index(for: provider, source: replaced)
        let guide = try XCTUnwrap(indexed)
        XCTAssertEqual(guide.nowNext(guideID: "sports.two", name: nil, at: shortNow).current?.title, "New source")
    }

    func testOlderShortResponseAppliesWhenTheNewerRequestFailsOrIsCancelled() async throws {
        let service = shortService()
        let provider = UUID()
        let issuedOlder = await service.beginShortRequest(providerID: provider, source: shortSource, guideID: "sports.two")
        let issuedNewer = await service.beginShortRequest(providerID: provider, source: shortSource, guideID: "sports.two")
        let older = try XCTUnwrap(issuedOlder)
        let newer = try XCTUnwrap(issuedNewer)

        // The newer request has failed or is still pending: it never reaches applyShortPrograms.
        let olderApplied = await service.applyShortPrograms(shortListing("Older"), guideID: "sports.two", ticket: older)
        XCTAssertNotNil(olderApplied, "only a newer response that was applied supersedes an older one")
        // If the newer request does succeed later, it is newer than everything applied and wins.
        let newerApplied = await service.applyShortPrograms(shortListing("Newer"), guideID: "sports.two", ticket: newer)
        XCTAssertNotNil(newerApplied)

        let issuedThird = await service.beginShortRequest(providerID: provider, source: shortSource, guideID: "sports.two")
        let issuedFourth = await service.beginShortRequest(providerID: provider, source: shortSource, guideID: "sports.two")
        let third = try XCTUnwrap(issuedThird)
        let fourth = try XCTUnwrap(issuedFourth)
        let gate = ShortResponseGate()
        let cancelled = Task {
            await gate.wait()
            return await service.applyShortPrograms(shortListing("Cancelled"), guideID: "sports.two", ticket: fourth)
        }
        await gate.waitUntilArrived()
        cancelled.cancel()
        await gate.release()
        let cancelledResult = await cancelled.value
        XCTAssertNil(cancelledResult)
        let thirdApplied = await service.applyShortPrograms(shortListing("Third"), guideID: "sports.two", ticket: third)
        XCTAssertNotNil(thirdApplied, "a cancelled newer request does not block an older successful one")

        let indexed = await service.index(for: provider, source: shortSource)
        XCTAssertEqual(indexed?.nowNext(guideID: "sports.two", name: nil, at: shortNow).current?.title, "Third")
    }

    func testShortResponseCancelledAfterDownloadIsNotPublished() async throws {
        let service = shortService()
        let provider = UUID()
        let issued = await service.beginShortRequest(providerID: provider, source: shortSource, guideID: "sports.two")
        let ticket = try XCTUnwrap(issued)
        let gate = ShortResponseGate()
        // The download has finished; the task is cancelled before the response reaches the actor.
        let request = Task {
            await gate.wait()
            return await service.applyShortPrograms(shortListing("Cancelled"), guideID: "sports.two", ticket: ticket)
        }
        await gate.waitUntilArrived()
        request.cancel()
        await gate.release()
        let result = await request.value
        XCTAssertNil(result, "a cancelled request publishes nothing")
        let unpublished = await service.index(for: provider, source: shortSource)
        XCTAssertNil(unpublished)

        // Rejection changed nothing: the same ticket is still current for an uncancelled caller.
        let retried = await service.applyShortPrograms(shortListing("Retried"), guideID: "sports.two", ticket: ticket)
        XCTAssertEqual(retried?.nowNext(guideID: "sports.two", name: nil, at: shortNow).current?.title, "Retried")
    }

    func testInFlightShortResponseIsDroppedWhenItsProviderIsRemoved() async throws {
        let service = shortService()
        let provider = UUID()
        let issued = await service.beginShortRequest(providerID: provider, source: shortSource, guideID: "sports.two")
        let ticket = try XCTUnwrap(issued)
        let gate = ShortResponseGate()
        let request = Task {
            await gate.wait()
            return await service.applyShortPrograms(shortListing("Removed"), guideID: "sports.two", ticket: ticket)
        }
        await gate.waitUntilArrived()
        await service.remove(providerID: provider)
        await gate.release()
        let result = await request.value
        XCTAssertNil(result)
        let restored = await service.index(for: provider, source: shortSource)
        XCTAssertNil(restored)
    }

    func testInFlightShortResponseIsDroppedWhenTheSourceChanges() async throws {
        let service = shortService()
        let provider = UUID()
        let replaced = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/replacement.xml")!)
        let issued = await service.beginShortRequest(providerID: provider, source: shortSource, guideID: "sports.two")
        let ticket = try XCTUnwrap(issued)
        let gate = ShortResponseGate()
        let request = Task {
            await gate.wait()
            return await service.applyShortPrograms(shortListing("Old source"), guideID: "sports.two", ticket: ticket)
        }
        await gate.waitUntilArrived()
        _ = await service.index(for: provider, source: replaced)
        await gate.release()
        let result = await request.value
        XCTAssertNil(result, "a response for the previous source is never shown for the new one")
        let current = await service.index(for: provider, source: replaced)
        XCTAssertNil(current)
    }

    func testShortOnlyOverlayStillDoesNotSatisfyFullGuideFreshness() async throws {
        let service = shortService()
        let provider = UUID()
        let issued = await service.beginShortRequest(providerID: provider, source: shortSource, guideID: "sports.two")
        let ticket = try XCTUnwrap(issued)
        let partial = await service.applyShortPrograms(shortListing("Only short"), guideID: "sports.two", ticket: ticket)
        XCTAssertEqual(partial?.isShortGuideOnly, true)
        let freshness = await service.freshness(for: provider)
        XCTAssertEqual(freshness, .missing)
        let sourceless = await service.index(for: provider)
        XCTAssertNil(sourceless, "source-less lookups never publish short-only data")
    }

    private func v2Header(_ directory: URL, _ provider: UUID) throws -> EPGCacheFormat.Header {
        let data = try Data(contentsOf: directory.appendingPathComponent("\(provider.uuidString).v2.epgcache"))
        return try EPGCacheFormat.decode(data, providerID: provider).header
    }

    /// Polls until queued writes leave a state, verified against the current v2 guide, that matches.
    private func persistedState(_ cache: EPGCacheStore, _ provider: UUID, _ fingerprint: Data,
                                where matches: (EPGCacheState) -> Bool) async throws -> EPGCacheState {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let state = cache.loadStateForCurrentGuide(providerID: provider, fingerprint: fingerprint),
               matches(state) { return state }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("persisted state was not reached")
        throw CancellationError()
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("EPGCacheStateTests.\(UUID().uuidString)",
                                                                    isDirectory: true)
    }
}

private final class StateWriteGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let releaseSignal = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var held = false

    func write(_ data: Data, to url: URL) throws {
        entered.signal()
        releaseSignal.wait()
        try data.write(to: url, options: EPGCacheStore.protectedWriteOptions)
    }

    /// Holds only the first chunk of a streamed stage, then lets the rest through.
    func append(_ data: Data, to handle: FileHandle) throws {
        let first = lock.withLock { () -> Bool in
            defer { held = true }
            return !held
        }
        if first {
            entered.signal()
            releaseSignal.wait()
        }
        try handle.write(contentsOf: data)
    }

    func waitUntilEntered(timeout: TimeInterval) -> Bool {
        entered.wait(timeout: .now() + timeout) == .success
    }

    static func wait(_ semaphore: DispatchSemaphore, timeout: DispatchTime) -> Bool {
        semaphore.wait(timeout: timeout) == .success
    }

    func release() { releaseSignal.signal() }
}

private struct UnavailableFingerprintKeyStore: EPGFingerprintKeyStoring {
    func readKey() throws -> Data? { throw EPGSourceIdentityError.keyUnavailable }
    func addKey(_ key: Data) throws { throw EPGSourceIdentityError.keyUnavailable }
    func deleteKey() throws { throw EPGSourceIdentityError.keyUnavailable }
}

private final class StateTestLoader: EPGFeedLoading, @unchecked Sendable {
    private let lock = NSLock()
    private let failure: Error
    private var count = 0

    init(failure: Error) { self.failure = failure }
    var calls: Int { lock.withLock { count } }

    func load(_ url: URL, maximumBytes: Int) async throws -> Data {
        lock.withLock { count += 1 }
        throw failure
    }
}

private final class FractionalClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    var date: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Answers each download with the next enqueued result, failing once the script runs out.
private final class ScriptedEPGLoader: EPGFeedLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Result<Data, Error>] = []
    private var count = 0

    var calls: Int { lock.withLock { count } }
    func enqueue(_ response: Result<Data, Error>) { lock.withLock { responses.append(response) } }

    func load(_ url: URL, maximumBytes: Int) async throws -> Data {
        let next: Result<Data, Error> = lock.withLock {
            count += 1
            return responses.isEmpty ? .failure(EPGError.providerRejected) : responses.removeFirst()
        }
        return try next.get()
    }
}

private struct StaticEPGLoader: EPGFeedLoading {
    let data: Data
    func load(_ url: URL, maximumBytes: Int) async throws -> Data { data }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                          file: StaticString = #filePath, line: UInt = #line,
                                          _ handler: (Error) -> Void = { _ in }) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}

/// Stands in for a short-guide download that the test completes. It ignores cancellation, as a
/// download that has already returned would, so the cancellation check under test is the actor's.
private actor ShortResponseGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        arrived = true
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters = []
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilArrived() async {
        if arrived { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters = []
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int
    init(value: Int = 0) { stored = value }
    var value: Int {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func increment() -> Int { lock.withLock { stored += 1; return stored } }
}
