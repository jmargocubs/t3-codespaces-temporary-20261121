import Foundation
import XCTest
@testable import Silo

@MainActor
final class LiveTVServiceResidencyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let fingerprint = Data(repeating: 0x42, count: EPGSourceFingerprint.length)

    func testRapidScrollingAndCategorySwitchingDeduplicateAndRefreshLoadedRows() async throws {
        let harness = try Harness(channels: 140, now: now, fingerprint: fingerprint)
        defer { harness.close() }
        let batches = ResidencyBatchRecorder()
        harness.service.residencyPrefetchHookForTesting = { index, keys in
            await batches.record(keys)
            index.prefetch(channelKeys: keys)
        }

        // Simulate rapid vertical scrolling, switching category, then scrolling back before the
        // one MainActor drain task gets scheduled. Repeated visible-row requests coalesce by key.
        for channel in harness.channels {
            _ = harness.service.guidePrograms(for: channel, overlapping: harness.window)
        }
        XCTAssertTrue(harness.service.isGuideChannelLoading(harness.channels[0]))
        for channel in harness.channels.reversed() {
            _ = harness.service.guidePrograms(for: channel, overlapping: harness.window)
        }
        XCTAssertEqual(harness.service.pendingResidencyCountForTesting, harness.channels.count)
        await harness.service.waitForResidencyForTesting()

        let completedBatches = await batches.values
        XCTAssertEqual(completedBatches.flatMap { $0 }.count, harness.channels.count)
        XCTAssertEqual(Set(completedBatches.flatMap { $0 }).count, harness.channels.count)
        XCTAssertLessThanOrEqual(completedBatches.count, 3, "64-row batches, not per-row disk jobs")
        for channel in harness.channels {
            XCTAssertEqual(harness.service.guideChannelRevision(for: channel), 1)
            XCTAssertEqual(harness.service.guidePrograms(for: channel, overlapping: harness.window).count, 2)
            XCTAssertFalse(harness.service.isGuideChannelLoading(channel))
        }
    }

    func testProviderSwitchWhilePrefetchIsHeldDropsOldCompletionAndDrainsNewProvider() async throws {
        let first = try Harness(channels: 1, now: now, fingerprint: fingerprint)
        let second = try Harness(channels: 1, now: now, fingerprint: fingerprint)
        defer { first.close(); second.close() }
        let gate = ResidencyGate()
        first.service.residencyPrefetchHookForTesting = { index, keys in
            await gate.pause(index.sqlite!.guide.metadata.providerID)
            index.prefetch(channelKeys: keys)
        }

        let firstChannel = first.channels[0]
        _ = first.service.guidePrograms(for: firstChannel, overlapping: first.window)
        await gate.waitUntilStarted(first.providerID)

        // Use the same service instance to exercise the real provider/guide identity switch.
        let service = first.service
        service.installGuideForResidencyTesting(second.index, providerID: second.providerID, channels: second.channels,
                                                selectProvider: false)
        service.selectProvider(second.providerID)
        service.residencyPrefetchHookForTesting = { index, keys in index.prefetch(channelKeys: keys) }
        let secondChannel = second.channels[0]
        _ = service.guidePrograms(for: secondChannel, overlapping: second.window)
        await gate.release(first.providerID)
        await service.waitForResidencyForTesting()

        XCTAssertEqual(service.guideChannelRevision(for: firstChannel), 0, "old provider result is stale")
        XCTAssertEqual(service.guideChannelRevision(for: secondChannel), 1)
        XCTAssertEqual(service.guidePrograms(for: secondChannel, overlapping: second.window).count, 2)
    }

    func testProviderRemovalWhilePrefetchIsHeldCannotPublishLateRowUpdates() async throws {
        let harness = try Harness(channels: 1, now: now, fingerprint: fingerprint)
        defer { harness.close() }
        let gate = ResidencyGate()
        harness.service.residencyPrefetchHookForTesting = { index, keys in
            await gate.pause(index.sqlite!.guide.metadata.providerID)
            index.prefetch(channelKeys: keys)
        }
        let channel = harness.channels[0]
        _ = harness.service.guidePrograms(for: channel, overlapping: harness.window)
        await gate.waitUntilStarted(harness.providerID)
        harness.service.forgetProvider(harness.providerID)
        await gate.release(harness.providerID)
        await harness.service.waitForResidencyForTesting()
        XCTAssertEqual(harness.service.guideChannelRevision(for: channel), 0)
    }

    func testPendingAndResidentWorkStayBoundedAtTheirProductionLimits() async throws {
        let harness = try Harness(channels: 700, now: now, fingerprint: fingerprint)
        defer { harness.close() }
        harness.service.residencyPrefetchHookForTesting = { index, keys in index.prefetch(channelKeys: keys) }
        for channel in harness.channels {
            _ = harness.service.guidePrograms(for: channel, overlapping: harness.window)
        }
        XCTAssertEqual(harness.service.pendingResidencyCountForTesting, 512)
        // Build 61: a full queue keeps the newest requests (the rows on screen) and drops the oldest.
        XCTAssertTrue(harness.service.isGuideChannelLoading(harness.channels[699]))
        XCTAssertFalse(harness.service.isGuideChannelLoading(harness.channels[0]),
                       "dropped requests are not mislabeled as queued")
        XCTAssertFalse(harness.service.isGuideChannelSettled(harness.channels[0]),
                       "a dropped row is not cached, so it asks again when next built")
        await harness.service.waitForResidencyForTesting()
        XCTAssertLessThanOrEqual(harness.index.sqlite!.guide.residentChannelCount, EPGSQLiteGuide.defaultResidentChannels)
    }

    func testRepeatedRequestsDoNotCreateConcurrentOrOutOfOrderLoads() async throws {
        let harness = try Harness(channels: 80, now: now, fingerprint: fingerprint)
        defer { harness.close() }
        let activity = ResidencyActivity()
        harness.service.residencyPrefetchHookForTesting = { index, keys in
            await activity.start()
            index.prefetch(channelKeys: keys)
            await activity.finish()
        }
        for _ in 0..<8 {
            for channel in harness.channels {
                _ = harness.service.programPair(for: channel, at: now)
                _ = harness.service.guidePrograms(for: channel, overlapping: harness.window)
            }
        }
        await harness.service.waitForResidencyForTesting()
        let maximumActive = await activity.maximum
        XCTAssertEqual(maximumActive, 1, "the production queue serializes batches, preventing out-of-order completions")
        XCTAssertTrue(harness.channels.allSatisfy { harness.service.guideChannelRevision(for: $0) == 1 })
    }

    @MainActor private final class Harness {
        let providerID: UUID
        let directory: URL
        let channels: [LiveTVChannel]
        let window: DateInterval
        var index: EPGIndex
        var service: LiveTVService

        init(channels count: Int, now: Date, fingerprint: Data) throws {
            providerID = UUID()
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveTVResidency-\(UUID().uuidString)", isDirectory: true)
            let directory = self.directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var xml = "<tv>"
            var channels: [LiveTVChannel] = []
            for number in 0..<count {
                xml += "<channel id=\"ch\(number)\"><display-name>Channel \(number)</display-name></channel>"
                xml += Self.programme("ch\(number)", now: now, offsetMinutes: -30, title: "Before \(number)")
                xml += Self.programme("ch\(number)", now: now, offsetMinutes: 0, title: "Current \(number)")
                channels.append(LiveTVChannel(id: "\(providerID.uuidString)-\(number)", guideID: "ch\(number)",
                                              name: "Channel \(number)",
                                              streamURL: URL(string: "https://stream.example.test/\(number).m3u8")!,
                                              logoURL: nil, category: number.isMultiple(of: 2) ? "A" : "B"))
            }
            xml += "</tv>"
            let dbURL = directory.appendingPathComponent("\(providerID.uuidString).\(UUID().uuidString).guide.sqlite")
            let build = try EPGSQLiteBuilder.build(xml: Data(xml.utf8), filter: nil, limits: EPGLimits(), fetchedAt: now,
                                                  providerID: providerID, fingerprint: fingerprint, destination: dbURL)
            index = EPGIndex(sqlite: build.index, statistics: build.statistics)
            self.channels = channels
            window = DateInterval(start: now.addingTimeInterval(-3_600), duration: 7_200)
            let defaults = UserDefaults(suiteName: "LiveTVResidencyTests.\(UUID().uuidString)")!
            service = LiveTVService(defaults: defaults, secretStore: ResidencySecretStore(),
                                    epg: EPGService(cache: nil, loader: URLSessionEPGFeedLoader.makeDefault(),
                                                    fingerprinter: .inMemory()))
            service.installGuideForResidencyTesting(index, providerID: providerID, channels: channels)
        }

        func close() {
            service.forgetProvider(providerID)
            index = EPGIndex.empty(fetchedAt: .now)
        }

        private static func programme(_ id: String, now: Date, offsetMinutes: Int, title: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMddHHmmss '+0000'"
            let start = formatter.string(from: now.addingTimeInterval(TimeInterval(offsetMinutes * 60)))
            let end = formatter.string(from: now.addingTimeInterval(TimeInterval((offsetMinutes + 30) * 60)))
            return "<programme channel=\"\(id)\" start=\"\(start)\" stop=\"\(end)\"><title>\(title)</title></programme>"
        }
    }

    private actor ResidencyGate {
        private var started = Set<UUID>()
        private var startWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
        private var releaseWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

        func pause(_ id: UUID) async {
            started.insert(id)
            startWaiters.removeValue(forKey: id)?.forEach { $0.resume() }
            await withCheckedContinuation { releaseWaiters[id] = $0 }
        }

        func waitUntilStarted(_ id: UUID) async {
            if started.contains(id) { return }
            await withCheckedContinuation { startWaiters[id, default: []].append($0) }
        }

        func release(_ id: UUID) { releaseWaiters.removeValue(forKey: id)?.resume() }
    }

    private actor ResidencyBatchRecorder {
        private(set) var values: [[String]] = []
        func record(_ batch: [String]) { values.append(batch) }
    }

    private actor ResidencyActivity {
        private var active = 0
        private(set) var maximum = 0
        func start() { active += 1; maximum = max(maximum, active) }
        func finish() { active -= 1 }
    }
}

@MainActor
private final class ResidencySecretStore: LiveTVSecretStore {
    func read(account: String) -> String? { nil }
    func save(_ value: String, account: String) -> Bool { true }
    func remove(account: String) -> Bool { true }
}
