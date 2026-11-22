import CryptoKit
import Foundation
import XCTest
@testable import Silo

/// The streamed v2 writer behind `EPGCacheStore.saveV2`: exact output, binding, replacement, eviction,
/// generation invalidation and failures before promotion, which preserve the previous guide/state
/// pair. Separate tests cover the nontransactional state write and invalidation after admission.
final class EPGCacheStreamingWriteTests: XCTestCase {
    private let fingerprint = Data((0..<EPGSourceFingerprint.length).map { UInt8($0) })
    private let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000.25)

    // MARK: - Output

    func testSaveReopensAndRestoresTheExactGuideAcrossBatches() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EPGCacheStore(directory: directory)
        let provider = UUID()
        let index = richGuide()
        XCTAssertGreaterThan(index.programCount, 2 * EPGCacheFormat.Writer.batchRows, "spans several row batches")
        XCTAssertGreaterThan(index.channelIDsByName.count, EPGCacheFormat.Writer.batchRows, "spans several name batches")

        let contentID = try store.saveV2(index, providerID: provider, fingerprint: fingerprint)

        let file = try Data(contentsOf: v2File(directory, provider))
        let payload = file.dropFirst(EPGCacheFormat.headerLength)
        let header = try EPGCacheFormat.header(of: file, fileSize: file.count)
        XCTAssertEqual(header.providerID, provider)
        XCTAssertEqual(header.contentID, contentID)
        XCTAssertEqual(header.sourceFingerprint, fingerprint)
        XCTAssertEqual(header.fetchedAt, fetchedAt, "fractional fetch times survive")
        XCTAssertEqual(header.programCount, index.programCount)
        XCTAssertEqual(header.channelCount, 3)
        XCTAssertEqual(header.compressedLength, payload.count)
        XCTAssertEqual(header.payloadDigest, Data(SHA256.hash(data: payload)))
        XCTAssertEqual(header.decompressedLength, try decompressed(payload).count)
        let framing = try XCTUnwrap(EPGCacheFormat.lzfseFraming(Data(payload)))
        XCTAssertEqual(framing.length, payload.count, "one LZFSE stream ends exactly at the end of the file")
        XCTAssertEqual(framing.decodedBytes, header.decompressedLength)

        let verified = try XCTUnwrap(store.loadVerifiedGuide(providerID: provider, fingerprint: fingerprint))
        XCTAssertEqual(verified.header, header)
        assertSameGuide(verified.index, index)
        XCTAssertEqual(stages(directory), [])
    }

    func testPayloadIsTheVersion2RecordAndIndependentOfBatchSize() throws {
        let index = richGuide()
        let provider = UUID(), contentID = UUID()
        var payloads: [Data] = []
        for batchRows in [1, 7, EPGCacheFormat.Writer.batchRows, 1_000_000] {
            let writer = try EPGCacheFormat.Writer(index, providerID: provider, sourceFingerprint: fingerprint,
                                                   contentID: contentID)
            var file = Data()
            _ = try writer.write(batchRows: batchRows, append: { file.append($0) },
                                 writeHeader: { file.replaceSubrange(0..<EPGCacheFormat.headerLength, with: $0) })
            payloads.append(Data(file.dropFirst(EPGCacheFormat.headerLength)))
        }
        XCTAssertEqual(Set(payloads).count, 1, "batches change neither the JSON nor the compressed stream")

        let json = try decompressed(payloads[0])
        XCTAssertEqual(try (json as NSData).compressed(using: .lzfse) as Data, payloads[0],
                       "the incremental stream is the one-shot compression of the same JSON: no restarts")
        let legacy = try EPGCacheFormat.encodeVersion1(index)
        let oneShot = try decompressed(legacy.dropFirst(5))
        let streamed = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? NSDictionary)
        let reference = try XCTUnwrap(try JSONSerialization.jsonObject(with: oneShot) as? NSDictionary)
        XCTAssertEqual(streamed, reference, "the same record a one-shot JSONEncoder writes")

        let rows = try XCTUnwrap(streamed["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, index.programCount)
        let text = try XCTUnwrap(String(data: json, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix(#"{"channelIDs":["#))
        XCTAssertEqual(text.components(separatedBy: #"{"c":"#).count - 1, index.programCount,
                       "every row spells its keys in sorted order, starting with the channel")
    }

    func testEmptyGuideStreamsWithoutCoverage() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EPGCacheStore(directory: directory)
        let provider = UUID()
        try store.saveV2(.empty(fetchedAt: fetchedAt), providerID: provider, fingerprint: fingerprint)
        let verified = try XCTUnwrap(store.loadVerifiedGuide(providerID: provider, fingerprint: fingerprint))
        XCTAssertNil(verified.header?.coverage)
        XCTAssertEqual(verified.index.programCount, 0)
        XCTAssertEqual(verified.index.fetchedAt, fetchedAt)
    }

    // MARK: - Binding, state and replacement

    func testGuideIsBoundToItsSourceAndLinkedStateToItsContentID() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EPGCacheStore(directory: directory)
        let provider = UUID()
        let first = try store.saveV2(richGuide(), providerID: provider, fingerprint: fingerprint)
        let other = Data(repeating: 0xAB, count: EPGSourceFingerprint.length)
        XCTAssertNil(store.loadVerifiedGuide(providerID: provider, fingerprint: other), "another source")
        XCTAssertNil(store.loadVerifiedGuide(providerID: UUID(), fingerprint: fingerprint), "another provider")

        let state = linkedState(provider, contentID: first)
        try store.saveState(state)
        let verified = try XCTUnwrap(store.loadVerifiedGuide(providerID: provider, fingerprint: fingerprint))
        XCTAssertEqual(store.loadStateForCurrentGuide(providerID: provider, fingerprint: fingerprint,
                                                      verifiedHeader: verified.header), state)
        XCTAssertEqual(store.loadStateForCurrentGuide(providerID: provider, fingerprint: fingerprint), state,
                       "full validation agrees with the verified-header shortcut")

        let second = try store.saveV2(smallGuide(title: "Replacement"), providerID: provider, fingerprint: fingerprint)
        XCTAssertNotEqual(second, first, "every write has a new random content ID")
        XCTAssertNil(store.loadStateForCurrentGuide(providerID: provider, fingerprint: fingerprint),
                     "state linked to the replaced guide no longer validates")
        let replaced = try XCTUnwrap(store.loadVerifiedGuide(providerID: provider, fingerprint: fingerprint))
        XCTAssertEqual(replaced.header?.contentID, second)
        assertSameGuide(replaced.index, smallGuide(title: "Replacement"))
        XCTAssertEqual(stages(directory), [])
    }

    func testServiceWritesLinkedStateAndANewServiceRestoresGuideAndState() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let source = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/streamed.xml")!)
        let fingerprinter = EPGSourceFingerprinter.inMemory()
        let fp = try fingerprinter.fingerprint(for: source).bytes
        let cache = EPGCacheStore(directory: directory)
        let writer = EPGService(cache: cache, loader: FixedFeedLoader(data: feed(around: now, slots: 300)),
                                fingerprinter: fingerprinter, now: { now })

        let written = try await writer.refresh(providerID: provider, source: source)
        XCTAssertGreaterThan(written.programCount, EPGCacheFormat.Writer.batchRows)
        await writer.removeOrphanedCacheFiles(keeping: [provider])  // waits for the queued write
        let header = try v2Header(directory, provider)
        let state = try XCTUnwrap(cache.loadStateForCurrentGuide(providerID: provider, fingerprint: fp))
        XCTAssertEqual(state.contentID, header.contentID)
        XCTAssertEqual(state.lastSuccessfulFetchDate, written.fetchedAt)

        let offline = FixedFeedLoader(data: nil)
        let restarted = EPGService(cache: cache, loader: offline, fingerprinter: fingerprinter, now: { now })
        let restored = try await restarted.refresh(providerID: provider, source: source)
        XCTAssertEqual(offline.calls, 0, "the restored fresh guide answers without a download")
        assertSameGuide(restored, written)
        XCTAssertEqual(stages(directory), [])
    }

    func testServiceStateFailureAfterPromotionKeepsNewGuideButNotOldStateLink() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let source = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/state-failure.xml")!)
        let fingerprinter = EPGSourceFingerprinter.inMemory()
        let fp = try fingerprinter.fingerprint(for: source).bytes
        var cache = EPGCacheStore(directory: directory)
        let old = smallGuide(title: "Previous")
        let oldID = try cache.saveV2(old, providerID: provider, fingerprint: fp)
        try cache.saveState(EPGCacheState(providerID: provider, sourceFingerprint: fp,
                                          contentID: oldID, lastSuccessfulFetchAt: old.fetchedAt))
        let stateURL = directory.appendingPathComponent("\(provider.uuidString).state")
        let oldState = try Data(contentsOf: stateURL)
        let failures = StreamTestCounter()
        cache.stateWriter = { _, _ in failures.increment(); throw CocoaError(.fileWriteOutOfSpace) }
        let service = EPGService(cache: cache, loader: FixedFeedLoader(data: feed(around: now, slots: 300)),
                                 fingerprinter: fingerprinter, now: { now })
        let newGuide = try await service.refresh(providerID: provider, source: source, force: true)
        await service.removeOrphanedCacheFiles(keeping: [provider])
        XCTAssertEqual(failures.value, 1)
        let verified = try XCTUnwrap(cache.loadVerifiedGuide(providerID: provider, fingerprint: fp))
        XCTAssertNotEqual(verified.header?.contentID, oldID)
        assertSameGuide(verified.index, newGuide)
        XCTAssertEqual(try Data(contentsOf: stateURL), oldState)
        XCTAssertNil(cache.loadStateForCurrentGuide(providerID: provider, fingerprint: fp),
                     "old state survives on disk but cannot authorize retry state for the new guide")
        let offline = FixedFeedLoader(data: nil)
        let restarted = EPGService(cache: cache, loader: offline, fingerprinter: fingerprinter, now: { now })
        let restored = try await restarted.refresh(providerID: provider, source: source)
        assertSameGuide(restored, newGuide)
        XCTAssertEqual(offline.calls, 0)
        XCTAssertEqual(stages(directory), [])
    }

    func testSourceInvalidationAfterPromotionAdmissionNeverShowsOldSource() async throws {
        try await checkInvalidationAtPromotion(removing: false)
    }

    func testRemovalAfterPromotionAdmissionCannotResurrectCache() async throws {
        try await checkInvalidationAtPromotion(removing: true)
    }

    private func checkInvalidationAtPromotion(removing: Bool) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let sourceA = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/commit-a.xml")!)
        let sourceB = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/commit-b.xml")!)
        let fingerprinter = EPGSourceFingerprinter.inMemory()
        let gate = StreamTestGate()
        var cache = EPGCacheStore(directory: directory)
        let promote = cache.promoter
        cache.promoter = { stage, destination in gate.hold(); try promote(stage, destination) }
        let service = EPGService(cache: cache, loader: FixedFeedLoader(data: feed(around: now, slots: 300)),
                                 fingerprinter: fingerprinter, now: { now })
        _ = try await service.refresh(providerID: provider, source: sourceA)
        let entered = await Task.detached { gate.waitUntilEntered(timeout: 5) }.value
        defer { gate.release() }
        XCTAssertTrue(entered)
        let invalidated = expectation(description: "generation advanced after promotion admission")
        await service.observeGenerationInvalidation { invalidated.fulfill() }
        let invalidation = Task { () -> EPGIndex? in
            if removing { await service.remove(providerID: provider); return nil }
            return await service.index(for: provider, source: sourceB)
        }
        await fulfillment(of: [invalidated], timeout: 5)
        gate.release()
        let visible = await invalidation.value
        XCTAssertNil(visible)
        await service.removeOrphanedCacheFiles(keeping: [provider])
        if removing {
            let late = await service.index(for: provider, source: sourceA)
            XCTAssertNil(late)
            XCTAssertFalse(exists(v2File(directory, provider)))
            XCTAssertFalse(exists(directory.appendingPathComponent("\(provider.uuidString).state")))
        } else {
            let fpA = try fingerprinter.fingerprint(for: sourceA).bytes
            let fpB = try fingerprinter.fingerprint(for: sourceB).bytes
            XCTAssertNotNil(cache.loadVerifiedGuide(providerID: provider, fingerprint: fpA),
                            "already admitted promotion may finish for its original source")
            XCTAssertNil(cache.loadVerifiedGuide(providerID: provider, fingerprint: fpB))
            let offline = EPGService(cache: cache, loader: FixedFeedLoader(data: nil),
                                     fingerprinter: fingerprinter, now: { now })
            let restored = await offline.index(for: provider, source: sourceB)
            XCTAssertNil(restored)
        }
        XCTAssertEqual(stages(directory), [])
    }

    func testTaskCancellationAloneDoesNotAbortAdmittedPersistence() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = StreamTestGate(), provider = UUID()
        var cache = EPGCacheStore(directory: directory)
        cache.stageChunkWriter = { data, handle in try gate.append(data, to: handle) }
        let store = cache, guide = richGuide(), fp = fingerprint
        let task = Task.detached { try store.saveV2(guide, providerID: provider, fingerprint: fp) }
        let entered = await Task.detached { gate.waitUntilEntered(timeout: 5) }.value
        XCTAssertTrue(entered)
        task.cancel()
        gate.release()
        let id = try await task.value
        let restored = try XCTUnwrap(store.loadVerifiedGuide(providerID: provider, fingerprint: fp))
        XCTAssertEqual(restored.header?.contentID, id)
        assertSameGuide(restored.index, guide)
        XCTAssertEqual(stages(directory), [])
    }

    // MARK: - Eviction

    func testStreamedWriteEvictsOldestGuideAndKeepsProtectedLegacy() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldest = UUID(), newer = UUID(), written = UUID(), keptLegacy = UUID()
        try seedV2(directory, oldest, age: 900)
        try seedV2(directory, newer, age: 300)
        let readableLegacy = directory.appendingPathComponent("\(oldest.uuidString).v1.epgcache")
        try EPGCacheFormat.encodeVersion1(.empty(fetchedAt: fetchedAt)).write(to: readableLegacy)
        let unknownLegacy = directory.appendingPathComponent("\(keptLegacy.uuidString).epgcache")
        try Data([0x4B, 0x45, 0x50, 0x47, 9, 1, 2, 3]).write(to: unknownLegacy)
        var store = EPGCacheStore(directory: directory)
        store.maximumEntries = 3

        try store.saveV2(richGuide(), providerID: written, fingerprint: fingerprint)

        XCTAssertFalse(exists(v2File(directory, oldest)), "the least recently written guide is evicted")
        XCTAssertFalse(exists(readableLegacy), "its readable v1 copy cannot resurface")
        XCTAssertTrue(exists(v2File(directory, newer)))
        XCTAssertTrue(exists(v2File(directory, written)), "the guide just written is kept")
        XCTAssertTrue(exists(unknownLegacy), "unsupported legacy files are protected")
        XCTAssertEqual(stages(directory), [])
    }

    func testAYoungForeignStageIsNeverTouchedAndAnAbandonedOneIsSwept() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let provider = UUID()
        let active = directory.appendingPathComponent("\(provider.uuidString).\(UUID().uuidString).stage")
        let abandoned = directory.appendingPathComponent("\(provider.uuidString).\(UUID().uuidString).stage")
        for url in [active, abandoned] { try Data(repeating: 0, count: 300).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: abandoned.path)

        try EPGCacheStore(directory: directory).saveV2(richGuide(), providerID: provider, fingerprint: fingerprint)

        XCTAssertEqual(try Data(contentsOf: active), Data(repeating: 0, count: 300),
                       "an interrupted-but-young stage may still belong to another writer")
        XCTAssertFalse(exists(abandoned))
        XCTAssertEqual(stages(directory), [active.lastPathComponent])
    }

    // MARK: - Failures keep the previous guide and state

    func testCancellationAtEveryCheckpointKeepsThePreviousGuideAndState() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, provider) = try previousGuide(directory)
        let replacement = richGuide(title: "Cancelled")
        let calls = StreamTestCounter()
        var counting = store
        counting.maximumEntries = .max
        try counting.saveV2(replacement, providerID: UUID(), fingerprint: fingerprint,
                            isCurrent: { calls.increment(); return true })
        let checkpoints = calls.value
        XCTAssertGreaterThan(checkpoints, 5, "checked before the stage, between batches and before promotion")

        let snapshot = try preserved(directory, store, provider)
        for cancelAt in 1...checkpoints {
            let seen = StreamTestCounter()
            XCTAssertThrowsError(try store.saveV2(replacement, providerID: provider, fingerprint: fingerprint,
                                                  isCurrent: { seen.increment() < cancelAt })) {
                XCTAssertTrue($0 is CancellationError, "checkpoint \(cancelAt): \($0)")
            }
            try snapshot.assertIntact("cancelled at checkpoint \(cancelAt) of \(checkpoints)")
        }
    }

    func testServiceRemovalDuringAStreamedWriteAbandonsItAndRemovesEverything() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let source = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/removed.xml")!)
        let gate = StreamTestGate()
        var cache = EPGCacheStore(directory: directory)
        cache.stageChunkWriter = { data, handle in try gate.append(data, to: handle) }
        let service = EPGService(cache: cache, loader: FixedFeedLoader(data: feed(around: now, slots: 300)),
                                 fingerprinter: .inMemory(), now: { now })

        _ = try await service.refresh(providerID: provider, source: source)
        let entered = await Task.detached { gate.waitUntilEntered(timeout: 5) }.value
        XCTAssertTrue(entered, "the streamed stage write is held")
        let invalidated = expectation(description: "removal generation advanced")
        await service.observeGenerationInvalidation { invalidated.fulfill() }
        let removal = Task { await service.remove(providerID: provider) }
        await fulfillment(of: [invalidated], timeout: 5)
        gate.release()
        await removal.value

        XCTAssertLessThan(gate.chunks, 4, "the write stops at its next batch instead of finishing")
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(remaining.contains { $0.hasPrefix(provider.uuidString) }, "no guide, state or stage remains")
    }

    func testSourceChangeDuringAStreamedWriteKeepsThePreviousGuideAndState() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let sourceA = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/a.xml")!)
        let sourceB = EPGFeedSource.xmltv(URL(string: "https://guide.example.test/b.xml")!)
        let fingerprinter = EPGSourceFingerprinter.inMemory()
        let fpA = try fingerprinter.fingerprint(for: sourceA).bytes
        let plain = EPGCacheStore(directory: directory)
        let contentID = try plain.saveV2(smallGuide(title: "Previous"), providerID: provider, fingerprint: fpA)
        try plain.saveState(EPGCacheState(providerID: provider, sourceFingerprint: fpA, contentID: contentID,
                                          lastSuccessfulFetchAt: smallGuide(title: "Previous").fetchedAt))
        let guideBefore = try Data(contentsOf: v2File(directory, provider))
        let stateFile = directory.appendingPathComponent("\(provider.uuidString).state")
        let stateBefore = try Data(contentsOf: stateFile)

        let gate = StreamTestGate()
        var cache = plain
        cache.stageChunkWriter = { data, handle in try gate.append(data, to: handle) }
        let service = EPGService(cache: cache, loader: FixedFeedLoader(data: feed(around: now, slots: 300)),
                                 fingerprinter: fingerprinter, now: { now })
        _ = try await service.refresh(providerID: provider, source: sourceA, force: true)
        let entered = await Task.detached { gate.waitUntilEntered(timeout: 5) }.value
        XCTAssertTrue(entered, "the streamed stage write is held")
        let invalidated = expectation(description: "source generation advanced")
        await service.observeGenerationInvalidation { invalidated.fulfill() }
        let switched = Task { await service.index(for: provider, source: sourceB) }
        await fulfillment(of: [invalidated], timeout: 5)
        gate.release()
        _ = await switched.value
        await service.removeOrphanedCacheFiles(keeping: [provider])

        XCTAssertEqual(try Data(contentsOf: v2File(directory, provider)), guideBefore, "previous guide kept")
        XCTAssertEqual(try Data(contentsOf: stateFile), stateBefore, "previous linked state kept")
        XCTAssertEqual(stages(directory), [])
    }

    func testAWriteFailingAtAnyByteKeepsThePreviousGuideAndState() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, provider) = try previousGuide(directory)
        let replacement = richGuide(title: "Interrupted")
        let total = try EPGCacheFormat.encode(replacement, providerID: provider, sourceFingerprint: fingerprint).count
        let snapshot = try preserved(directory, store, provider)
        let header = EPGCacheFormat.headerLength
        // Before anything, inside and after the placeholder header, mid-payload, the last payload
        // byte, and the header rewrite (which begins once all `total` bytes are out).
        for limit in [0, 1, header - 1, header, header + 1, total / 2, total - 1, total, total + 100] {
            var failing = store
            let written = StreamTestCounter()
            failing.stageChunkWriter = { data, handle in
                // Writes what fits, then fails, as a full disk would.
                let room = max(0, limit - written.value)
                if data.count > room {
                    try handle.write(contentsOf: data.prefix(room))
                    written.add(room)
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try handle.write(contentsOf: data)
                written.add(data.count)
            }
            XCTAssertThrowsError(try failing.saveV2(replacement, providerID: provider, fingerprint: fingerprint),
                                 "fails after \(limit) bytes")
            try snapshot.assertIntact("write failing after \(limit) of \(total) bytes")
        }
    }

    func testCorruptTruncatedOrUnpromotableStagesKeepThePreviousGuideAndState() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, provider) = try previousGuide(directory)
        let replacement = richGuide(title: "Rejected")
        let snapshot = try preserved(directory, store, provider)
        let isHeader: @Sendable (Data) -> Bool = {
            $0.count == EPGCacheFormat.headerLength && $0.starts(with: Data("KEPG".utf8))
        }
        let chunks = StreamTestCounter()

        var flipped = store
        flipped.stageChunkWriter = { data, handle in
            var copy = data
            // The second chunk is the first compressed output, after the zeroed header.
            if chunks.increment() == 2 { copy[copy.startIndex + copy.count / 2] ^= 0x01 }
            try handle.write(contentsOf: copy)
        }
        var truncated = store
        truncated.stageChunkWriter = { data, handle in
            if isHeader(data) {
                // Drops the last payload byte before the header goes in.
                try handle.truncate(atOffset: try handle.seekToEnd() - 1)
                try handle.seek(toOffset: 0)
            }
            try handle.write(contentsOf: data)
        }
        var trailing = store
        trailing.stageChunkWriter = { data, handle in
            try handle.write(contentsOf: data)
            if isHeader(data) {
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: Data([0]))
            }
        }
        var wrongHeader = store
        wrongHeader.stageChunkWriter = { data, handle in
            var copy = data
            if isHeader(data) { copy[copy.startIndex + 103] ^= 0x01 }  // programme count
            try handle.write(contentsOf: copy)
        }
        var unpromotable = store
        unpromotable.promoter = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        var tinyPayload = store
        tinyPayload.formatLimits.maximumDecodedBytes = 4_096
        var tinyFile = store
        tinyFile.formatLimits.maximumFileBytes = 1_024

        let cases: [(String, EPGCacheStore, EPGCacheFormatError?)] = [
            ("flipped payload byte", flipped, .digestMismatch),
            ("truncated payload", truncated, .lengthMismatch),
            ("trailing byte", trailing, .lengthMismatch),
            ("header disagreeing with the record", wrongHeader, .mismatchedMetadata),
            ("failed promotion", unpromotable, nil),
            ("decoded size over the limit while streaming", tinyPayload, .tooLarge),
            ("file size over the limit while streaming", tinyFile, .tooLarge),
        ]
        for (label, failing, expected) in cases {
            XCTAssertThrowsError(try failing.saveV2(replacement, providerID: provider, fingerprint: fingerprint), label) {
                if let expected { XCTAssertEqual($0 as? EPGCacheFormatError, expected, label) }
            }
            try snapshot.assertIntact(label)
        }
    }

    func testPolicyRejectionHappensBeforeAnyStageExists() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, provider) = try previousGuide(directory)
        let snapshot = try preserved(directory, store, provider)
        let writes = StreamTestCounter()
        var observed = store
        observed.stageChunkWriter = { data, handle in
            writes.increment()
            try handle.write(contentsOf: data)
        }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let longTitle = EPGIndex(fetchedAt: start, programsByChannel: ["a.uk": [
            EPGProgram(channelID: "a.uk", start: start, end: start.addingTimeInterval(60),
                       title: String(repeating: "x", count: 601)),
        ]], channelIDsByName: [:], statistics: .init())
        let outOfRange = EPGIndex(fetchedAt: start, programsByChannel: ["a.uk": [
            EPGProgram(channelID: "a.uk", start: Date(timeIntervalSince1970: 1e30),
                       end: Date(timeIntervalSince1970: 1e30 + 60), title: "late"),
        ]], channelIDsByName: [:], statistics: .init())
        var fewer = observed
        fewer.formatLimits.maximumPrograms = 10

        let cases: [(String, EPGCacheStore, EPGIndex, EPGCacheFormatError)] = [
            ("text over the limit", observed, longTitle, .invalidRecord),
            ("time out of range", observed, outOfRange, .invalidRecord),
            ("too many programmes", fewer, richGuide(), .tooLarge),
        ]
        for (label, failing, index, expected) in cases {
            XCTAssertThrowsError(try failing.saveV2(index, providerID: provider, fingerprint: fingerprint)) {
                XCTAssertEqual($0 as? EPGCacheFormatError, expected, label)
            }
            XCTAssertThrowsError(try failing.saveV2(index, providerID: provider, fingerprint: Data([1]))) {
                XCTAssertEqual($0 as? EPGCacheFormatError, .malformedHeader, label)
            }
            try snapshot.assertIntact(label)
        }
        XCTAssertEqual(writes.value, 0, "a rejected guide never creates or writes a stage")
    }

    // MARK: - Fixtures

    /// Three channels of half-hour programmes, about 2.6 row batches, with escaping-sensitive text,
    /// every optional field both present and absent, and more names than one batch.
    private func richGuide(title: String = "Programme") -> EPGIndex {
        let base = 1_800_000_000.0
        var channels: [String: [EPGProgram]] = [:]
        for (offset, id) in ["BBCOne.uk", "itv.uk", "Sky News.uk"].enumerated() {
            let key = EPGChannelKey.guideID(id)!
            channels[key] = (0..<450).map { slot in
                let start = Date(timeIntervalSince1970: base + Double(slot * 1_800 + offset * 60))
                let i = slot + offset
                return EPGProgram(channelID: id, start: start, end: start.addingTimeInterval(1_800),
                                  title: "\(title) \(slot) \u{201C}quoted\u{201D} \"q\" \\ / 😀 é",
                                  subtitle: i % 2 == 0 ? "Part \(slot)\nline" : nil,
                                  summary: i % 3 == 0 ? String(repeating: "Summary \(slot). ", count: 4) : nil,
                                  category: i % 5 == 0 ? nil : "News",
                                  episode: i % 7 == 0 ? "S\(slot / 10) E\(slot % 10)" : nil)
            }
        }
        var names: [String: String] = [:]
        for i in 0..<700 { names["name \(i)"] = ["BBCOne.uk", "itv.uk", "Sky News.uk"][i % 3] }
        return EPGIndex(fetchedAt: fetchedAt, programsByChannel: channels, channelIDsByName: names,
                        statistics: .init())
    }

    private func smallGuide(title: String) -> EPGIndex {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return EPGIndex(fetchedAt: start, programsByChannel: ["news.one": [
            EPGProgram(channelID: "news.one", start: start, end: start.addingTimeInterval(3_600), title: title),
        ]], channelIDsByName: ["newsone": "news.one"], statistics: .init())
    }

    /// Half-hour programmes on three channels from an hour before `date`, in whole seconds. The
    /// index keeps at most 250 per channel, so 300 slots give 750 rows: more than one batch.
    private func feed(around date: Date, slots: Int) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss '+0000'"
        let base = (date.timeIntervalSince1970 / 1_800).rounded(.down) * 1_800 - 3_600
        var rows: [String] = []
        for channel in ["news.one", "sport.two", "film.three"] {
            for slot in 0..<slots {
                let start = Date(timeIntervalSince1970: base + Double(slot) * 1_800)
                rows.append("<programme channel=\"\(channel)\" start=\"\(formatter.string(from: start))\" "
                            + "stop=\"\(formatter.string(from: start.addingTimeInterval(1_800)))\">"
                            + "<title>\(channel) \(slot)</title><desc>Item &amp; detail</desc></programme>")
            }
        }
        return Data("<tv>\n\(rows.joined(separator: "\n"))\n</tv>".utf8)
    }

    /// A store holding a verified guide and linked retry state for one provider.
    private func previousGuide(_ directory: URL) throws -> (EPGCacheStore, UUID) {
        let store = EPGCacheStore(directory: directory)
        let provider = UUID()
        let contentID = try store.saveV2(smallGuide(title: "Previous"), providerID: provider, fingerprint: fingerprint)
        try store.saveState(linkedState(provider, contentID: contentID))
        return (store, provider)
    }

    private func linkedState(_ provider: UUID, contentID: UUID) -> EPGCacheState {
        EPGCacheState(providerID: provider, sourceFingerprint: fingerprint, contentID: contentID,
                      lastSuccessfulFetchAt: Date(timeIntervalSince1970: 1_800_000_000), failureCount: 2,
                      nextRetryAt: Date(timeIntervalSince1970: 1_800_000_600))
    }

    /// Captures the provider's guide and state so a failed write can be shown to have kept them.
    private func preserved(_ directory: URL, _ store: EPGCacheStore, _ provider: UUID) throws -> Snapshot {
        let state = try XCTUnwrap(store.loadStateForCurrentGuide(providerID: provider, fingerprint: fingerprint))
        return Snapshot(directory: directory, store: store, provider: provider, fingerprint: fingerprint,
                        guide: try Data(contentsOf: v2File(directory, provider)),
                        stateBytes: try Data(contentsOf: directory.appendingPathComponent("\(provider.uuidString).state")),
                        state: state)
    }

    private struct Snapshot {
        let directory: URL
        let store: EPGCacheStore
        let provider: UUID
        let fingerprint: Data
        let guide: Data
        let stateBytes: Data
        let state: EPGCacheState

        func assertIntact(_ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("\(provider.uuidString).v2.epgcache")),
                           guide, "\(label): previous guide kept", file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("\(provider.uuidString).state")),
                           stateBytes, "\(label): previous state file kept", file: file, line: line)
            let verified = store.loadVerifiedGuide(providerID: provider, fingerprint: fingerprint)
            XCTAssertNotNil(verified, "\(label): previous guide still verifies", file: file, line: line)
            XCTAssertEqual(store.loadStateForCurrentGuide(providerID: provider, fingerprint: fingerprint,
                                                          verifiedHeader: verified?.header),
                           state, "\(label): linked retry state still restores", file: file, line: line)
            let stages = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".stage") }
            XCTAssertEqual(stages, [], "\(label): no stage left", file: file, line: line)
        }
    }

    /// Writes a v2 guide without triggering eviction and backdates it.
    private func seedV2(_ directory: URL, _ provider: UUID, age: TimeInterval) throws {
        var unlimited = EPGCacheStore(directory: directory)
        unlimited.maximumEntries = .max
        try unlimited.saveV2(smallGuide(title: "Seed"), providerID: provider, fingerprint: fingerprint)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000 - age)],
                                              ofItemAtPath: v2File(directory, provider).path)
    }

    private func assertSameGuide(_ lhs: EPGIndex, _ rhs: EPGIndex, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.fetchedAt, rhs.fetchedAt, file: file, line: line)
        XCTAssertEqual(lhs.programCount, rhs.programCount, file: file, line: line)
        XCTAssertEqual(lhs.programsByChannel, rhs.programsByChannel, file: file, line: line)
        XCTAssertEqual(lhs.channelIDsByName, rhs.channelIDsByName, file: file, line: line)
    }

    private func decompressed(_ payload: Data) throws -> Data {
        try (Data(payload) as NSData).decompressed(using: .lzfse) as Data
    }

    private func v2Header(_ directory: URL, _ provider: UUID) throws -> EPGCacheFormat.Header {
        let data = try Data(contentsOf: v2File(directory, provider))
        return try EPGCacheFormat.decode(data, providerID: provider).header
    }

    private func v2File(_ directory: URL, _ provider: UUID) -> URL {
        directory.appendingPathComponent("\(provider.uuidString).v2.epgcache")
    }

    private func stages(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".stage") }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("EPGCacheStreamingWriteTests.\(UUID().uuidString)",
                                                                    isDirectory: true)
    }
}

private final class StreamTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    @discardableResult func increment() -> Int { lock.withLock { stored += 1; return stored } }
    func add(_ amount: Int) { lock.withLock { stored += amount } }
}

/// Holds the first chunk of a streamed stage until released, then lets the rest through.
private final class StreamTestGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0

    var chunks: Int { lock.withLock { count } }

    func hold() { entered.signal(); released.wait() }

    func append(_ data: Data, to handle: FileHandle) throws {
        let first = lock.withLock { () -> Bool in
            count += 1
            return count == 1
        }
        if first {
            hold()
        }
        try handle.write(contentsOf: data)
    }

    func waitUntilEntered(timeout: TimeInterval) -> Bool { entered.wait(timeout: .now() + timeout) == .success }
    func release() { released.signal() }
}

private final class FixedFeedLoader: EPGFeedLoading, @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data?
    private var count = 0

    init(data: Data?) { self.data = data }
    var calls: Int { lock.withLock { count } }

    func load(_ url: URL, maximumBytes: Int) async throws -> Data {
        lock.withLock { count += 1 }
        guard let data else { throw EPGError.providerRejected }
        return data
    }
}
