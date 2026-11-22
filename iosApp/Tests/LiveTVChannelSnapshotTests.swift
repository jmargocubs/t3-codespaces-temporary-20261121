import Foundation
import XCTest
@testable import Silo

@MainActor
final class LiveTVChannelSnapshotTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var secrets: SnapshotTestSecretStore!
    private var snapshots: LiveTVChannelSnapshotStore!
    private var guideCache: EPGCacheStore!
    private var epgFingerprinter: EPGSourceFingerprinter!

    private let playlist = #"""
    #EXTM3U
    #EXTINF:-1 tvg-id="news.one" group-title="news",News One
    https://stream.example.test/news.m3u8
    #EXTINF:-1 tvg-id="sport" group-title="Sports",Sport
    https://stream.example.test/sport.m3u8
    """#

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suiteName = "LiveTVChannelSnapshotTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        secrets = SnapshotTestSecretStore()
        snapshots = LiveTVChannelSnapshotStore(directory: directory.appendingPathComponent("channels"))
        guideCache = EPGCacheStore(directory: directory.appendingPathComponent("guide"))
        epgFingerprinter = .inMemory()
        PlaylistURLProtocol.reset(body: playlist)
    }

    override func tearDown() async throws {
        PlaylistURLProtocol.reset(body: "")
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeService(loader: any EPGFeedLoading = OfflineGuideLoader(),
                             epgService: EPGService? = nil,
                             shortEPGNow: @escaping () -> Date = { Date() }) -> LiveTVService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaylistURLProtocol.self, PanelURLProtocol.self]
        let epg = epgService ?? EPGService(cache: guideCache, loader: loader, fingerprinter: epgFingerprinter)
        return LiveTVService(defaults: defaults, secretStore: secrets, session: URLSession(configuration: configuration),
                             epg: epg, channelSnapshotStore: snapshots,
                             channelStoreDirectory: directory.appendingPathComponent("channel-index"),
                             shortEPGNow: shortEPGNow)
    }

    private func addProvider(to service: LiveTVService, name: String = "Provider", guide: Bool = false) throws -> UUID {
        try service.saveConfiguration(name: name, playlistURL: "https://playlist.test/\(name).m3u",
                                      xmltvURL: guide ? "https://epg.test/guide.xml" : nil)
    }

    private func seedCache(providerID: UUID, fetchedAtOffset: TimeInterval = 0) async throws {
        let channels = try LiveTVM3UParser.parse(data: Data(playlist.utf8), providerID: providerID)
        await snapshots.save(providerID: providerID, channels: channels)
        let now = Date().addingTimeInterval(fetchedAtOffset)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss '+0000'"
        let xml = """
        <tv><programme channel="news.one" start="\(formatter.string(from: now.addingTimeInterval(-600)))" \
        stop="\(formatter.string(from: now.addingTimeInterval(3_000)))"><title>Cached Now</title></programme></tv>
        """
        let index = try EPGIndex(document: XMLTVParser.parse(Data(xml.utf8)), fetchedAt: now, now: now, limits: EPGLimits())
        try guideCache.save(index, providerID: providerID)
        let source = EPGFeedSource.xmltv(URL(string: "https://epg.test/guide.xml")!)
        let fingerprint = try epgFingerprinter.fingerprint(for: source).bytes
        try guideCache.saveState(EPGCacheState(providerID: providerID, sourceFingerprint: fingerprint,
                                               lastSuccessfulFetchAt: now))
    }

    // MARK: - Store

    func testSnapshotIsVersionedRedactedAndRejectsCorruptIncompatibleAndForeignFiles() async throws {
        let providerID = UUID()
        let file = snapshots.directory.appendingPathComponent("\(providerID.uuidString).json")
        let channel = try XCTUnwrap(LiveTVM3UParser.parse(data: Data("""
        #EXTM3U
        #EXTINF:-1 tvg-id="news",News
        https://stream.invalid/live?token=secret
        """.utf8), providerID: providerID).first)
        let channelWithURLLogo = LiveTVChannel(id: channel.id, guideID: "news",
            name: "News", streamURL: URL(string: "https://stream.invalid/live?token=secret")!,
            logoURL: URL(string: "https://provider.invalid/logo")!, category: "Local")
        await snapshots.save(providerID: providerID, channels: [channelWithURLLogo])
        let serialized = try XCTUnwrap(String(data: Data(contentsOf: file), encoding: .utf8))
        XCTAssertTrue(serialized.contains("\"version\":1"))
        XCTAssertFalse(serialized.contains("stream.invalid"))
        XCTAssertFalse(serialized.contains("provider.invalid"))
        XCTAssertFalse(serialized.contains("secret"))
        let cached = await snapshots.loadCatalog(providerID: providerID)
        XCTAssertEqual(cached?.channels.map(\.name), ["News"])
        XCTAssertEqual(cached?.channels.first?.streamURL.scheme, "about")
        let foreignLoad = await snapshots.load(providerID: UUID())
        XCTAssertNil(foreignLoad)

        let incompatible = serialized.replacingOccurrences(of: "\"version\":1", with: "\"version\":2")
        try Data(incompatible.utf8).write(to: file)
        let incompatibleLoad = await snapshots.load(providerID: providerID)
        XCTAssertNil(incompatibleLoad)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "incompatible snapshots are deleted")

        let foreignEntries = serialized.replacingOccurrences(of: "\(providerID.uuidString):", with: "\(UUID().uuidString):")
        try Data(foreignEntries.utf8).write(to: file)
        let foreignEntriesLoad = await snapshots.load(providerID: providerID)
        XCTAssertEqual(foreignEntriesLoad?.channels, [], "foreign channel IDs are sanitized out")

        try Data("broken".utf8).write(to: file)
        let corruptLoad = await snapshots.load(providerID: providerID)
        XCTAssertNil(corruptLoad)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "corrupt snapshots are deleted")
    }

    func testUnsafeProviderMetadataIsOmittedButOrdinaryUnicodeAndGuideIDsRemain() async throws {
        let providerID = UUID()
        let data = Data(#"""
        #EXTM3U
        #EXTINF:-1 tvg-id="https://user:pass@guide.example/xml?token=private",Safe Channel
        https://stream.example/safe.m3u8
        #EXTINF:-1 tvg-id="news.unicode",https://provider.example/live?password=private
        https://stream.example/name.m3u8
        #EXTINF:-1 tvg-id="sport.one" group-title="Authorization: Bearer abcdef0123456789",Sport
        https://stream.example/category.m3u8
        #EXTINF:-1 tvg-id="account.user",streamuser
        https://stream.example/username.m3u8
        #EXTINF:-1 tvg-id="password.channel" group-title="Pass-Word-1",Channel
        https://stream.example/password.m3u8
        #EXTINF:-1 tvg-id="news.日本語" group-title="文化",東京ニュース
        https://stream.example/unicode.m3u8
        """#.utf8)
        let channels = try LiveTVM3UParser.parse(data: data, providerID: providerID)
        XCTAssertEqual(channels.count, 6)
        await snapshots.save(providerID: providerID, channels: channels,
                             secrets: LiveTVSnapshotSecrets(passwords: ["Pass-Word-1"], usernames: ["streamuser"]))

        let loaded = await snapshots.load(providerID: providerID)
        XCTAssertEqual(loaded?.channels.map(\.name), ["東京ニュース"])
        XCTAssertEqual(loaded?.channels.first?.guideID, "news.日本語")
        let bytes = try Data(contentsOf: snapshots.directory.appendingPathComponent("\(providerID.uuidString).json"))
        let persisted = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        for sensitive in ["user:pass", "token=private", "provider.example", "password=private", "Authorization",
                          "abcdef0123456789", "streamuser", "Pass-Word-1"] {
            XCTAssertFalse(persisted.localizedCaseInsensitiveContains(sensitive))
        }
    }

    func testPercentEncodedSignedAndTokenMetadataIsOmitted() async throws {
        let providerID = UUID()
        let data = Data(#"""
        #EXTM3U
        #EXTINF:-1 tvg-id="https%3A%2F%2Fcdn.example%2Flive%3Ftoken%3Dabc123",Single Encoded URL
        https://stream.example/1.m3u8
        #EXTINF:-1 tvg-id="double.one",https%253A%252F%252Fcdn.example%252Fx
        https://stream.example/2.m3u8
        #EXTINF:-1 tvg-id="signed.one" group-title="stream.m3u8?sig=abcdef0123",Signed Category
        https://stream.example/3.m3u8
        #EXTINF:-1 tvg-id="news%3Fsig%3Dabc",Encoded Signed Guide
        https://stream.example/4.m3u8
        #EXTINF:-1 tvg-id="promo.one",Promo p%40ss%21word
        https://stream.example/5.m3u8
        #EXTINF:-1 tvg-id="jwt.one",eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2ln
        https://stream.example/6.m3u8
        #EXTINF:-1 tvg-id="encoded.control",Line%250ABreak
        https://stream.example/7.m3u8
        #EXTINF:-1 tvg-id="pct.one",100% Sport
        https://stream.example/8.m3u8
        #EXTINF:-1 tvg-id="fr.ciné" group-title="Cinéma",Ciné+ Frisson
        https://stream.example/9.m3u8
        #EXTINF:-1 tvg-id="news.日本語" group-title="文化",東京ニュース
        https://stream.example/10.m3u8
        #EXTINF:-1 tvg-id="BBCOne.uk" group-title="UK | News",BBC One HD
        https://stream.example/11.m3u8
        """#.utf8)
        let channels = try LiveTVM3UParser.parse(data: data, providerID: providerID)
        XCTAssertEqual(channels.count, 11)
        await snapshots.save(providerID: providerID, channels: channels,
                             secrets: LiveTVSnapshotSecrets(passwords: ["p@ss!word"]))

        let loaded = await snapshots.load(providerID: providerID)
        XCTAssertEqual(loaded?.channels.map(\.name), ["100% Sport", "Ciné+ Frisson", "東京ニュース", "BBC One HD"])
        XCTAssertEqual(loaded?.channels.map(\.guideID), ["pct.one", "fr.ciné", "news.日本語", "BBCOne.uk"])
        XCTAssertEqual(loaded?.channels.map(\.category), ["Other", "Cinéma", "文化", "UK | News"])
        let persisted = try XCTUnwrap(String(data: Data(contentsOf: snapshots.directory
            .appendingPathComponent("\(providerID.uuidString).json")), encoding: .utf8))
        for sensitive in ["cdn.example", "abc123", "sig", "p%40ss", "eyJ", "%250A"] {
            XCTAssertFalse(persisted.localizedCaseInsensitiveContains(sensitive), sensitive)
        }
    }

    func testProviderSecretsBlockCredentialsWithoutDroppingOrdinaryNames() async throws {
        let providerID = UUID()
        let source = LiveTVSourceConfiguration(
            playlistURL: "https://prov.example.net/get.php?username=sport&password=s3cr3tPass&type=m3u_plus&output=mpegts",
            xmltvURL: "https://prov.example.net/xmltv.php?username=sport&password=s3cr3tPass")
        let secrets = LiveTVSnapshotSecrets(source: source)
        XCTAssertFalse(secrets.endpoints.contains("m3u_plus"), "generic query values are not secrets")
        XCTAssertFalse(secrets.endpoints.contains("mpegts"))
        let data = Data(#"""
        #EXTM3U
        #EXTINF:-1 tvg-id="sport.one" group-title="Sport",Sport 1
        https://stream.example/1.m3u8
        #EXTINF:-1 tvg-id="sky.sport" group-title="Sports",Sky Sport: Live
        https://stream.example/2.m3u8
        #EXTINF:-1 tvg-id="mpegts.demo" group-title="Live",MPEGTS Demo
        https://stream.example/3.m3u8
        #EXTINF:-1 tvg-id="plus.one",M3U Plus Movies
        https://stream.example/4.m3u8
        #EXTINF:-1 tvg-id="leak.password",sport:s3cr3tPass
        https://stream.example/5.m3u8
        #EXTINF:-1 tvg-id="prov.example.net",Host Guide
        https://stream.example/6.m3u8
        #EXTINF:-1 tvg-id="leak.path" group-title="live/sport/",Path Credential
        https://stream.example/7.m3u8
        """#.utf8)
        let channels = try LiveTVM3UParser.parse(data: data, providerID: providerID)
        XCTAssertEqual(channels.count, 7)
        await snapshots.save(providerID: providerID, channels: channels, secrets: secrets)

        let loaded = await snapshots.load(providerID: providerID)
        XCTAssertEqual(loaded?.channels.map(\.name), ["Sport 1", "Sky Sport: Live", "MPEGTS Demo", "M3U Plus Movies"])
        let persisted = try XCTUnwrap(String(data: Data(contentsOf: snapshots.directory
            .appendingPathComponent("\(providerID.uuidString).json")), encoding: .utf8))
        XCTAssertFalse(persisted.contains("s3cr3tPass"))
        XCTAssertFalse(persisted.contains("prov.example.net"))
        XCTAssertFalse(persisted.contains("live/sport/"))
    }

    func testMalformedPercentSignsCannotHideEncodedURLsOrCredentials() async throws {
        let password = LiveTVSnapshotSecrets(passwords: ["p@ss!word"])
        XCTAssertFalse(LiveTVSnapshotRedaction.isSafe("% https%3A%2F%2Fcdn.example%2Flive%3Ftoken%3Dabc", maximumBytes: 256))
        XCTAssertFalse(LiveTVSnapshotRedaction.isSafe("100% p%40ss%21word", maximumBytes: 256, secrets: password))
        XCTAssertFalse(LiveTVSnapshotRedaction.isSafe("50% off %253Fsig%253Dabc", maximumBytes: 256), "two layers")
        XCTAssertFalse(LiveTVSnapshotRedaction.isSafe("%zz stream.m3u8%3Fsig%3Dabc", maximumBytes: 256))
        XCTAssertTrue(LiveTVSnapshotRedaction.isSafe("100% Sport", maximumBytes: 256))
        XCTAssertTrue(LiveTVSnapshotRedaction.isSafe("50%+ Deals", maximumBytes: 256))
        XCTAssertTrue(LiveTVSnapshotRedaction.isSafe("Ciné+ 100%", maximumBytes: 256))

        let providerID = UUID()
        let channels = try LiveTVM3UParser.parse(data: Data(#"""
        #EXTM3U
        #EXTINF:-1 tvg-id="pct.url",% https%3A%2F%2Fcdn.example%2Flive%3Ftoken%3Dabc
        https://stream.example/1.m3u8
        #EXTINF:-1 tvg-id="pct.password",100% p%40ss%21word
        https://stream.example/2.m3u8
        #EXTINF:-1 tvg-id="pct.safe",100% Sport
        https://stream.example/3.m3u8
        """#.utf8), providerID: providerID)
        await snapshots.save(providerID: providerID, channels: channels, secrets: password)
        let loaded = await snapshots.load(providerID: providerID)
        XCTAssertEqual(loaded?.channels.map(\.name), ["100% Sport"])
        let persisted = try XCTUnwrap(String(data: Data(contentsOf: snapshots.directory
            .appendingPathComponent("\(providerID.uuidString).json")), encoding: .utf8))
        XCTAssertFalse(persisted.contains("cdn.example"))
        XCTAssertFalse(persisted.contains("p%40ss"))
    }

    func testUnicodeFormattingIsKeptButControlsAndBidiOverridesAreRejected() {
        for safe in ["می\u{200C}خواهم شبکه خبر", "👨\u{200D}👩\u{200D}👧 Family", "ערוץ 1", "\u{200F}قناة الأخبار",
                     "News \u{200E}HD", "東京ニュース"] {
            XCTAssertTrue(LiveTVSnapshotRedaction.isSafe(safe, maximumBytes: 256), safe)
        }
        for unsafe in ["News\u{202E}gpj.exe", "\u{2066}Sport\u{2069}", "\u{202A}x", "a\u{0007}b", "Tab\there",
                       "News%E2%80%AE", "Line%250ABreak", "C1\u{0085}next"] {
            XCTAssertFalse(LiveTVSnapshotRedaction.isSafe(unsafe, maximumBytes: 256), unsafe.debugDescription)
        }
    }

    func testFailedReplacementWritePreservesThePreviousSnapshot() async throws {
        let providerID = UUID()
        let channels = try LiveTVM3UParser.parse(data: Data(playlist.utf8), providerID: providerID)
        let first = await snapshots.save(providerID: providerID, channels: channels)
        XCTAssertEqual(first, .saved)
        let file = snapshots.directory.appendingPathComponent("\(providerID.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let before = try Data(contentsOf: file)

        // JSONEncoder cannot encode a non-finite date, so the replacement fails to encode.
        let unencodable = LiveTVChannelSnapshot(providerID: providerID, channels: channels,
                                                savedAt: Date(timeIntervalSinceReferenceDate: .nan))
        let failed = await snapshots.save(unencodable)
        XCTAssertEqual(failed, .writeFailed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "a failed write leaves the last valid snapshot")
        XCTAssertEqual(try Data(contentsOf: file), before)
        let restored = await snapshots.loadCatalog(providerID: providerID)
        XCTAssertEqual(restored?.channels.count, channels.count)
    }

    func testOverChannelLimitSavePreservesThePreviousSnapshot() async throws {
        let providerID = UUID()
        let channels = try LiveTVM3UParser.parse(data: Data(playlist.utf8), providerID: providerID)
        let initialSave = await snapshots.save(providerID: providerID, channels: channels)
        XCTAssertEqual(initialSave, .saved)
        let file = snapshots.directory.appendingPathComponent("\(providerID.uuidString).json")
        let before = try Data(contentsOf: file)

        let overLimit = (0..<(LiveTVChannelSnapshotStore.maximumChannels + 1)).map { number -> LiveTVChannel in
            let hex = String(format: "%064x", number)
            return LiveTVChannel(id: "\(providerID.uuidString):\(hex)", guideID: nil, name: "Ch\(number)",
                                 streamURL: URL(string: "https://stream.example/\(number).m3u8")!,
                                 logoURL: nil, category: "News")
        }
        XCTAssertEqual(LiveTVChannelSnapshot(providerID: providerID, channels: overLimit).channels.count,
                       LiveTVChannelSnapshotStore.maximumChannels + 1)
        let result = await snapshots.save(providerID: providerID, channels: overLimit)
        XCTAssertEqual(result, .refusedOverChannelLimit)
        XCTAssertEqual(try Data(contentsOf: file), before)
        let restored = await snapshots.loadCatalog(providerID: providerID)
        XCTAssertEqual(restored?.channels.count, channels.count)
    }

    func testSnapshotRejectsOversizedFileAndOmitsOverlongFields() async throws {
        let providerID = UUID()
        try FileManager.default.createDirectory(at: snapshots.directory, withIntermediateDirectories: true)
        let file = snapshots.directory.appendingPathComponent("\(providerID.uuidString).json")
        try Data(repeating: 0x20, count: LiveTVChannelSnapshotStore.maximumFileBytes + 1).write(to: file)
        let oversized = await snapshots.load(providerID: providerID)
        XCTAssertNil(oversized)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        let valid = try XCTUnwrap(LiveTVM3UParser.parse(data: Data("""
        #EXTM3U
        #EXTINF:-1,Valid
        https://stream.example/valid.m3u8
        """.utf8), providerID: providerID).first)
        let overlong = LiveTVChannel(id: valid.id, guideID: valid.guideID,
            name: String(repeating: "X", count: 300), streamURL: valid.streamURL, logoURL: nil, category: "News")
        await snapshots.save(providerID: providerID, channels: [valid, overlong])
        let afterLongField = await snapshots.load(providerID: providerID)
        XCTAssertEqual(afterLongField?.channels.map(\.name), ["Valid"])
    }

    // MARK: - Service

    func testOfflineStartupShowsCachedChannelsAndGuideAndKeepsThemWhenRefreshFails() async throws {
        let providerID = try addProvider(to: makeService(), guide: true)
        try await seedCache(providerID: providerID)
        PlaylistURLProtocol.reset(body: playlist, status: 503)

        let service = makeService()
        await service.prepareSelectedProvider()

        XCTAssertEqual(PlaylistURLProtocol.requests, 1)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertEqual(service.channels.map(\.name), ["News One", "Sport"])
        XCTAssertEqual(LiveTVChannelListContentState.resolve(hasProviders: true, isLoading: false,
            errorMessage: service.errorMessage, channelCount: service.channels.count), .ready,
            "the actual list presentation state stays ready and renders the refresh failure as a banner")
        XCTAssertEqual(LiveTVChannelListContentState.resolve(hasProviders: true, isLoading: false,
            errorMessage: service.errorMessage, channelCount: 0), .failed(service.errorMessage!))
        XCTAssertEqual(service.categories, ["news", "Sports"])
        let news = try XCTUnwrap(service.channels.first)
        XCTAssertEqual(service.programPair(for: news).current?.title, "Cached Now")
        XCTAssertFalse(service.isGuideStale)
        let guideNames = (try? FileManager.default.contentsOfDirectory(atPath: guideCache.directory.path)) ?? []
        XCTAssertTrue(guideNames.contains("\(providerID.uuidString).epgcache"))
        XCTAssertFalse(guideNames.contains { $0.hasSuffix(".v2.epgcache") || $0.hasSuffix(".stage") },
                       "startup may show a bound v1 guide but must not migrate it")

        // Cached rows carry no stream address, so they cannot open the player.
        service.choose(news, from: .list)
        XCTAssertNil(service.presentation.channel(for: .list))
        XCTAssertEqual(service.errorMessage, "Refresh the playlist to play this channel.")

        // Returning to Live TV straight after a failure does not retry the download.
        await service.prepareSelectedProvider()
        XCTAssertEqual(PlaylistURLProtocol.requests, 1)
    }

    func testCachedFirstRestoreRejectsGuideAfterTheProviderSourceChanges() async throws {
        let service = makeService()
        let providerID = try addProvider(to: service, guide: true)
        try await seedCache(providerID: providerID)
        let account = "provider.\(providerID.uuidString)"
        let stored = try XCTUnwrap(secrets.read(account: account)?.data(using: .utf8))
        var configuration = try JSONDecoder().decode(LiveTVSourceConfiguration.self, from: stored)
        configuration.xmltvURL = "https://epg.test/other-guide.xml"
        _ = secrets.save(String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self), account: account)

        let restored = makeService()
        await restored.restoreCachedState(for: providerID)
        let channel = try XCTUnwrap(restored.channels.first)
        XCTAssertNil(restored.programPair(for: channel).current,
                     "provider UUID and cached-first restoration cannot bind the old source's v1 guide")
        XCTAssertFalse(FileManager.default.fileExists(atPath: guideCache.directory
            .appendingPathComponent("\(providerID.uuidString).v2.epgcache").path))
    }

    func testVerifiedV2GuideSurvivesRestartAndAFailedRefresh() async throws {
        let writerLoader = StaticGuideLoader(payload: guideXML(title: "Fresh Guide"))
        let writer = makeService(loader: writerLoader)
        let providerID = try addProvider(to: writer, guide: true)
        PlaylistURLProtocol.reset(body: playlist)
        await writer.prepareSelectedProvider()
        let written = try XCTUnwrap(writer.channels.first { $0.name == "News One" })
        XCTAssertEqual(writer.programPair(for: written).current?.title, "Fresh Guide")
        XCTAssertEqual(writerLoader.calls, 1)
        let v2 = guideCache.directory.appendingPathComponent("\(providerID.uuidString).v2.epgcache")
        let state = guideCache.directory.appendingPathComponent("\(providerID.uuidString).state")
        try await waitUntil { FileManager.default.fileExists(atPath: v2.path) && FileManager.default.fileExists(atPath: state.path) }
        let preserved = try Data(contentsOf: v2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: guideCache.directory
            .appendingPathComponent("\(providerID.uuidString).epgcache").path))

        PlaylistURLProtocol.reset(body: playlist, status: 503)
        let offline = CountingOfflineGuideLoader()
        let restarted = makeService(loader: offline)
        await restarted.prepareSelectedProvider()
        let restored = try XCTUnwrap(restarted.channels.first { $0.name == "News One" })
        XCTAssertEqual(restarted.programPair(for: restored).current?.title, "Fresh Guide")
        XCTAssertEqual(offline.calls, 0, "offline startup serves the verified v2 guide without a download")
        XCTAssertFalse(restarted.isGuideStale)

        PlaylistURLProtocol.reset(body: playlist)
        await restarted.refresh(providerID: providerID)
        XCTAssertGreaterThan(offline.calls, 0, "a due refresh still attempts the network")
        XCTAssertEqual(restarted.programPair(for: restored).current?.title, "Fresh Guide")
        XCTAssertEqual(try Data(contentsOf: v2), preserved, "a failed refresh leaves the verified v2 guide in place")
    }

    func testChannelStoreRefreshPagingAndOfflineFallback() async throws {
        let writer = makeService()
        let providerID = try addProvider(to: writer)
        let otherProvider = try addProvider(to: writer, name: "Other")
        await writer.refresh(providerID: providerID)
        let firstPage = await writer.channelPage(providerID: providerID, limit: 1)
        let sportsPage = await writer.channelPage(providerID: providerID, category: "Sports")
        let otherPage = await writer.channelPage(providerID: otherProvider)
        XCTAssertEqual(firstPage.map(\.name), ["News One"])
        XCTAssertEqual(sportsPage.map(\.name), ["Sport"])
        XCTAssertTrue(otherPage.isEmpty)
        let totalCount = await writer.channelCount(providerID: providerID)
        let newsCount = await writer.channelCount(providerID: providerID, query: "News")
        let sportsCount = await writer.channelCount(providerID: providerID, category: "Sports")
        XCTAssertEqual(totalCount, 2)
        XCTAssertEqual(newsCount, 1)
        XCTAssertEqual(sportsCount, 1)
        let sportsManual = await writer.sportsManualChannels(matching: "News", providerID: providerID)
        XCTAssertEqual(sportsManual.map(\.name), ["News One"])
        writer.toggleFavorite(try XCTUnwrap(firstPage.first))
        let favoritePage = await writer.channelPage(providerID: providerID, favoritesOnly: true)
        XCTAssertEqual(favoritePage.map(\.name), ["News One"])
        let favoriteCount = await writer.channelCount(providerID: providerID, favoritesOnly: true)
        XCTAssertEqual(favoriteCount, 1)
        let directory = await writer.categoryDirectory(providerID: providerID)
        XCTAssertEqual(directory.totalChannelCount, 2)
        XCTAssertEqual(directory.favoriteChannelCount, 1)
        XCTAssertEqual(directory.entry(for: "Sports").channelCount, 1)

        PlaylistURLProtocol.reset(body: playlist, status: 503)
        await writer.refresh(providerID: providerID)
        let preservedPage = await writer.channelPage(providerID: providerID)
        XCTAssertEqual(preservedPage.count, 2,
                       "a failed refresh must not replace the active SQLite generation")

        await snapshots.remove(providerID: providerID)
        let restarted = makeService()
        await restarted.restoreCachedState(for: providerID)
        XCTAssertEqual(restarted.channels.map(\.name), ["News One", "Sport"])
        XCTAssertTrue(restarted.channels.allSatisfy { $0.streamURL.scheme == "about" },
                      "offline restoration remains browse-only")
    }

    func testPagedChannelModelKeepsABoundedBidirectionalWindow() async throws {
        let rowCount = 1_205
        let entries = (0..<rowCount).map { index in
            "#EXTINF:-1 tvg-id=\"guide.\(index)\" group-title=\"Category \(index % 8)\",Channel \(index)\n" +
            "https://stream.example.test/\(index).m3u8"
        }
        PlaylistURLProtocol.reset(body: (["#EXTM3U"] + entries).joined(separator: "\n"))
        let service = makeService()
        let providerID = try addProvider(to: service)
        await service.refresh(providerID: providerID)

        let model = LiveTVPagedChannelModel()
        model.reset(service: service, providerID: providerID,
                    catalogRevision: service.channelCatalogRevision,
                    query: "", category: nil, favoritesOnly: false)
        // The root view and pushed browser can both refresh the same observation. This must not
        // cancel the matching in-flight query and strand the loading state.
        model.reset(service: service, providerID: providerID,
                    catalogRevision: service.channelCatalogRevision,
                    query: "", category: nil, favoritesOnly: false)
        await model.waitForCurrentQuery()
        XCTAssertEqual(model.totalCount, rowCount)
        XCTAssertEqual(model.channels.count, LiveTVPagedChannelModel.pageSize)

        while model.hasMoreAfter {
            model.loadPageIfNeeded(around: try XCTUnwrap(model.channels.last), service: service)
            await model.waitForCurrentQuery()
            XCTAssertLessThanOrEqual(model.channels.count, LiveTVPagedChannelModel.maximumRetainedChannels)
        }
        XCTAssertTrue(model.hasMoreBefore)
        XCTAssertEqual(model.channels.last?.name, "Channel 1204")

        while model.hasMoreBefore {
            model.loadPageIfNeeded(around: try XCTUnwrap(model.channels.first), service: service)
            await model.waitForCurrentQuery()
            XCTAssertLessThanOrEqual(model.channels.count, LiveTVPagedChannelModel.maximumRetainedChannels)
        }
        XCTAssertEqual(model.channels.first?.name, "Channel 0")
    }

    func testLiveTVSectionSequenceIsIsolatedAndEmptyFavoritesStayEmpty() async throws {
        let service = makeService()
        let providerID = try addProvider(to: service)
        await service.refresh(providerID: providerID)
        let model = LiveTVPagedChannelModel()

        model.reset(service: service, providerID: providerID, catalogRevision: service.channelCatalogRevision,
                    query: "", category: nil, favoritesOnly: false)
        await model.waitForCurrentQuery()
        XCTAssertEqual(model.totalCount, 2, "All Channels is the full catalog without choosing a category")
        XCTAssertEqual(Set(model.channels.map(\.name)), ["News One", "Sport"])

        model.reset(service: service, providerID: providerID, catalogRevision: service.channelCatalogRevision,
                    query: "", category: "news", favoritesOnly: false)
        await model.waitForCurrentQuery()
        XCTAssertEqual(model.channels.map(\.name), ["News One"])
        XCTAssertTrue(service.favoriteChannelIDs.isEmpty, "Category selection never mutates favorites")

        model.reset(service: service, providerID: providerID, catalogRevision: service.channelCatalogRevision,
                    query: "", category: nil, favoritesOnly: true)
        await model.waitForCurrentQuery()
        XCTAssertEqual(model.totalCount, 0, "An empty favorites collection remains empty")
        XCTAssertTrue(model.channels.isEmpty)

        let favorite = try XCTUnwrap(model.channels.first { $0.name == "Sport" })
        service.toggleFavorite(favorite)
        model.reset(service: service, providerID: providerID, catalogRevision: service.channelCatalogRevision,
                    query: "", category: nil, favoritesOnly: true)
        await model.waitForCurrentQuery()
        XCTAssertEqual(model.channels.map(\.name), ["Sport"], "Favorites contains explicitly favorited channels only")

        model.reset(service: service, providerID: providerID, catalogRevision: service.channelCatalogRevision,
                    query: "", category: nil, favoritesOnly: false)
        await model.waitForCurrentQuery()
        XCTAssertEqual(model.totalCount, 2, "Returning to All Channels restores the full collection")

        model.reset(service: service, providerID: providerID, catalogRevision: service.channelCatalogRevision,
                    query: "", category: "Sports", favoritesOnly: false)
        model.reset(service: service, providerID: providerID, catalogRevision: service.channelCatalogRevision,
                    query: "", category: "news", favoritesOnly: false)
        model.reset(service: service, providerID: providerID, catalogRevision: service.channelCatalogRevision,
                    query: "", category: nil, favoritesOnly: false)
        await model.waitForCurrentQuery()
        XCTAssertEqual(model.channels.map(\.name), ["News One", "Sport"],
                       "Rapid section switching cannot publish an older category result")
    }

    func testSourceChangeDoesNotDisplayAnotherV2GuideAndRemovalDoesNotRecreateIt() async throws {
        let loader = StaticGuideLoader(payload: guideXML(title: "Original Guide"))
        let service = makeService(loader: loader)
        let providerID = try addProvider(to: service, guide: true)
        PlaylistURLProtocol.reset(body: playlist)
        await service.prepareSelectedProvider()
        let v2 = guideCache.directory.appendingPathComponent("\(providerID.uuidString).v2.epgcache")
        try await waitUntil { FileManager.default.fileExists(atPath: v2.path) }
        let preserved = try Data(contentsOf: v2)

        let account = "provider.\(providerID.uuidString)"
        let stored = try XCTUnwrap(secrets.read(account: account)?.data(using: .utf8))
        var configuration = try JSONDecoder().decode(LiveTVSourceConfiguration.self, from: stored)
        configuration.xmltvURL = "https://epg.test/other-guide.xml"
        _ = secrets.save(String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self), account: account)

        let changed = makeService(loader: CountingOfflineGuideLoader())
        await changed.restoreCachedState(for: providerID)
        let channel = try XCTUnwrap(changed.channels.first { $0.name == "News One" })
        XCTAssertNil(changed.programPair(for: channel).current,
                     "a v2 guide for the previous XMLTV URL is not shown for the new source")
        XCTAssertEqual(try Data(contentsOf: v2), preserved, "a source mismatch does not rewrite or delete the previous v2 guide")

        await service.removeProvider(providerID)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: guideCache.directory.path)) ?? []
        XCTAssertFalse(names.contains { $0.contains(providerID.uuidString) })
        let revived = makeService()
        await revived.restoreCachedState(for: providerID)
        XCTAssertFalse(revived.providers.contains { $0.id == providerID })
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: guideCache.directory.path)) ?? []).isEmpty)
    }

    func testShortGuideOverlayKeepsTheFullGuideAndDoesNotSuppressRefresh() async throws {
        let clock = GuideClock(Date())
        let loader = StaticGuideLoader(payload: twoChannelGuideXML(at: clock.date))
        let epg = EPGService(cache: guideCache, loader: loader, fingerprinter: epgFingerprinter, now: { clock.date })
        let service = makeService(loader: loader, epgService: epg, shortEPGNow: { clock.date })
        let providerID = try service.saveXtreamConfiguration(name: "Panel", serverURL: "http://panel.test:8080",
                                                             username: "alice", password: "s3cret-pass")
        PanelURLProtocol.reset()
        await service.prepareSelectedProvider()
        let news = try XCTUnwrap(service.channels.first { $0.name == "News One" })
        let sport = try XCTUnwrap(service.channels.first { $0.name == "Sport" })
        XCTAssertEqual(service.programPair(for: news).current?.title, "Full News")
        XCTAssertEqual(service.programPair(for: sport).current?.title, "Full Sport")
        XCTAssertEqual(loader.calls, 1)
        XCTAssertNotNil(news.streamID)
        XCTAssertNotNil(sport.streamID)

        PanelURLProtocol.shortBody = #"{"epg_listings":[]}"#
        await service.refreshShortEPG(for: news)
        XCTAssertEqual(service.programPair(for: news).current?.title, "Full News")
        XCTAssertEqual(service.programPair(for: sport).current?.title, "Full Sport")
        XCTAssertNil(service.guideMessage, "an empty short response must not claim the full guide is empty")
        XCTAssertEqual(loader.calls, 1)
        await service.refreshShortEPG(for: news)
        XCTAssertEqual(PanelURLProtocol.shortRequests, 1, "empty listings are briefly negative-cached")
        clock.date = clock.date.addingTimeInterval(6 * 60)
        await service.refreshShortEPG(for: news)
        XCTAssertEqual(PanelURLProtocol.shortRequests, 2, "empty listings become eligible after negative-cache expiry")

        clock.date = Date()
        let start = Int(clock.date.addingTimeInterval(-60).timeIntervalSince1970)
        let end = Int(clock.date.addingTimeInterval(3_600).timeIntervalSince1970)
        let title = Data("Short now".utf8).base64EncodedString()
        PanelURLProtocol.shortBody = #"{"epg_listings":[{"title":"\#(title)","start_timestamp":\#(start),"stop_timestamp":\#(end)}]}"#
        await service.refreshShortEPG(for: sport)
        XCTAssertEqual(service.programPair(for: sport).current?.title, "Short now")
        XCTAssertEqual(service.programPair(for: news).current?.title, "Full News",
                       "a short-guide overlay must not hide the rest of the full guide")
        XCTAssertEqual(loader.calls, 1)

        clock.date = clock.date.addingTimeInterval(13 * 3_600)
        await service.refresh(providerID: providerID)
        XCTAssertEqual(loader.calls, 2, "short listings do not make the stale full guide look fresh")
        XCTAssertEqual(service.programPair(for: news, at: clock.date).current?.title, "Full News")
    }

    private func makeXtreamService(clock: GuideClock) async throws -> (LiveTVService, UUID, LiveTVChannel, LiveTVChannel) {
        let loader = StaticGuideLoader(payload: twoChannelGuideXML(at: clock.date))
        let epg = EPGService(cache: guideCache, loader: loader, fingerprinter: epgFingerprinter, now: { clock.date })
        let service = makeService(loader: loader, epgService: epg, shortEPGNow: { clock.date })
        let providerID = try service.saveXtreamConfiguration(name: "Panel", serverURL: "http://panel.test:8080",
                                                             username: "alice", password: "s3cret-pass")
        PanelURLProtocol.reset()
        await service.prepareSelectedProvider()
        let news = try XCTUnwrap(service.channels.first { $0.name == "News One" })
        let sport = try XCTUnwrap(service.channels.first { $0.name == "Sport" })
        return (service, providerID, news, sport)
    }

    private func shortGuideBody(title: String, at date: Date) -> String {
        let start = Int(date.addingTimeInterval(-60).timeIntervalSince1970)
        let end = Int(date.addingTimeInterval(3_600).timeIntervalSince1970)
        let encoded = Data(title.utf8).base64EncodedString()
        return #"{"epg_listings":[{"title":"\#(encoded)","start_timestamp":\#(start),"stop_timestamp":\#(end)}]}"#
    }

    func testCancellingAShortGuideDownloadPublishesNothingReportsNothingAndAllowsARetry() async throws {
        let clock = GuideClock(Date())
        let (service, _, _, sport) = try await makeXtreamService(clock: clock)
        XCTAssertEqual(service.programPair(for: sport).current?.title, "Full Sport")
        PanelURLProtocol.shortBody = shortGuideBody(title: "Cancelled", at: clock.date)
        PanelURLProtocol.holdShortGuide()

        let request = Task { await service.refreshShortEPG(for: sport) }
        try await waitUntil { PanelURLProtocol.heldShortRequests == 1 }
        request.cancel()
        await request.value

        XCTAssertEqual(service.programPair(for: sport).current?.title, "Full Sport")
        XCTAssertNil(service.guideMessage, "cancellation is not reported as a provider failure")

        // The cancelled request did not leave the channel marked as loaded.
        PanelURLProtocol.releaseShortGuide()
        PanelURLProtocol.shortBody = shortGuideBody(title: "Retried", at: clock.date)
        await service.refreshShortEPG(for: sport)
        XCTAssertEqual(PanelURLProtocol.shortRequests, 2)
        XCTAssertEqual(service.programPair(for: sport).current?.title, "Retried")
    }

    func testConcurrentShortGuideSelectionsShareOneInFlightRequest() async throws {
        let clock = GuideClock(Date())
        let (service, _, _, sport) = try await makeXtreamService(clock: clock)
        PanelURLProtocol.shortBody = shortGuideBody(title: "Concurrent", at: clock.date)
        PanelURLProtocol.holdShortGuide()
        let first = Task { await service.refreshShortEPG(for: sport) }
        try await waitUntil { PanelURLProtocol.heldShortRequests == 1 }
        let second = Task { await service.refreshShortEPG(for: sport) }
        await second.value
        XCTAssertEqual(PanelURLProtocol.shortRequests, 1)
        PanelURLProtocol.releaseShortGuide()
        await first.value
        XCTAssertEqual(service.programPair(for: sport).current?.title, "Concurrent")
        await service.refreshShortEPG(for: sport)
        XCTAssertEqual(PanelURLProtocol.shortRequests, 1, "fresh non-empty listings are cached")
    }

    func testRemovingTheProviderDuringAShortGuideDownloadPublishesNothing() async throws {
        let clock = GuideClock(Date())
        let (service, providerID, _, sport) = try await makeXtreamService(clock: clock)
        PanelURLProtocol.shortBody = shortGuideBody(title: "Removed", at: clock.date)
        PanelURLProtocol.holdShortGuide()

        let request = Task { await service.refreshShortEPG(for: sport) }
        try await waitUntil { PanelURLProtocol.heldShortRequests == 1 }
        await service.removeProvider(providerID)
        PanelURLProtocol.releaseShortGuide()
        await request.value

        XCTAssertFalse(service.providers.contains { $0.id == providerID })
        XCTAssertNil(service.programPair(for: sport).current)
        XCTAssertNil(service.guideMessage)
        let guideFiles = (try? FileManager.default.contentsOfDirectory(atPath: guideCache.directory.path)) ?? []
        XCTAssertFalse(guideFiles.contains { $0.hasPrefix(providerID.uuidString) }, "a late response recreates no files")
    }

    func testRemovalDuringHeldCachedGuideReadCannotStartNetworkRefreshOrRecreateFiles() async throws {
        let baseCache = guideCache
        let gate = CacheReadGate()
        var heldCache = guideCache!
        heldCache.verifiedReadInterceptor = { providerID, fingerprint, isCurrent in
            gate.enterAndWait()
            return baseCache!.loadVerified(providerID: providerID, fingerprint: fingerprint, isCurrent: isCurrent)
        }
        let epgLoader = CountingOfflineGuideLoader()
        let service = makeService(epgService: EPGService(cache: heldCache, loader: epgLoader,
                                                        fingerprinter: epgFingerprinter))
        let providerID = try addProvider(to: service, guide: true)
        try await seedCache(providerID: providerID)
        PlaylistURLProtocol.reset(body: playlist)

        let refresh = Task { await service.refresh(providerID: providerID) }
        let readStarted = await gate.waitUntilEntered(timeout: 5)
        XCTAssertTrue(readStarted, "refreshGuide should enter the held cached guide read")
        let removal = Task { await service.removeProvider(providerID) }
        try await waitUntil { !service.providers.contains(where: { $0.id == providerID }) }
        gate.release()
        await refresh.value
        await removal.value

        XCTAssertEqual(epgLoader.calls, 0, "the resumed refreshGuide must stop after the cached-read await")
        XCTAssertFalse(service.providers.contains(where: { $0.id == providerID }))
        let remainingGuideFiles = (try? FileManager.default.contentsOfDirectory(atPath: guideCache.directory.path)) ?? []
        XCTAssertFalse(remainingGuideFiles.contains { $0.hasPrefix(providerID.uuidString) },
                       "provider removal leaves no guide, state or stage to recreate later")
        let remainingSnapshot = await snapshots.load(providerID: providerID)
        XCTAssertNil(remainingSnapshot)
    }

    func testRepeatedNavigationDoesNotRedownloadAFreshPlaylist() async throws {
        let service = makeService()
        let providerID = try addProvider(to: service)
        await service.prepareSelectedProvider()
        XCTAssertEqual(PlaylistURLProtocol.requests, 1)
        XCTAssertEqual(service.channels.first?.streamURL.scheme, "https")
        XCTAssertEqual(service.categories, ["news", "Sports"], "refreshed and cached categories share one order")
        let legacySnapshot = await snapshots.loadCatalog(providerID: providerID)
        XCTAssertNil(legacySnapshot, "successful SQLite promotion removes the redundant JSON catalog")
        let restarted = makeService()
        await restarted.restoreCachedState(for: providerID)
        XCTAssertEqual(restarted.categories, service.categories)
        XCTAssertTrue(restarted.channels.allSatisfy { $0.streamURL.scheme == "about" },
                      "the protected SQLite generation remains the browse-only offline source")

        await service.prepareSelectedProvider()
        await service.prepareSelectedProvider(now: Date().addingTimeInterval(60 * 60))
        XCTAssertEqual(PlaylistURLProtocol.requests, 1)

        await service.prepareSelectedProvider(now: Date().addingTimeInterval(13 * 60 * 60))
        XCTAssertEqual(PlaylistURLProtocol.requests, 2, "a playlist older than the refresh interval is downloaded again")

        await service.refreshSelectedProvider()
        XCTAssertEqual(PlaylistURLProtocol.requests, 3, "an explicit refresh always downloads")
    }

    func testPlayerPickerRejectsCachedOnlyChannelWithoutChangingPiPOwnership() async throws {
        let service = makeService()
        let providerID = try addProvider(to: service)
        try await seedCache(providerID: providerID)
        await service.restoreCachedState(for: providerID)
        let cached = try XCTUnwrap(service.channels.first)
        let live = try XCTUnwrap(LiveTVM3UParser.parse(data: Data(playlist.utf8), providerID: providerID).last)
        service.presentation.surfaceAppeared(.list)
        _ = service.presentation.select(live, from: .list)
        service.presentation.pictureInPictureStartedFromControl()
        var pipStops = 0
        service.presentation.stopPictureInPicture = { pipStops += 1 }

        XCTAssertFalse(service.playFromPlayerPicker(cached))
        XCTAssertEqual(service.presentation.phase, .pictureInPicture(live))
        XCTAssertEqual(service.presentation.activeChannel?.id, live.id)
        XCTAssertEqual(pipStops, 0)
    }

    func testRemovingAProviderDuringRefreshDiscardsItsResult() async throws {
        let service = makeService()
        let kept = try addProvider(to: service, name: "Kept")
        let removed = try addProvider(to: service, name: "Removed")
        XCTAssertEqual(service.selectedProviderID, removed)
        PlaylistURLProtocol.reset(body: playlist, held: true)

        let refresh = Task { await service.refreshSelectedProvider() }
        try await waitUntil { PlaylistURLProtocol.requests == 1 }
        XCTAssertTrue(service.isLoading)
        await service.removeProvider(removed)
        XCTAssertFalse(service.isLoading)
        XCTAssertEqual(service.selectedProviderID, kept)
        PlaylistURLProtocol.release()
        await refresh.value

        XCTAssertTrue(service.channels.isEmpty)
        XCTAssertEqual(service.providers.map(\.id), [kept])
        let removedSnapshot = await snapshots.load(providerID: removed)
        XCTAssertNil(removedSnapshot)

        // The cancelled refresh no longer blocks the remaining provider.
        PlaylistURLProtocol.reset(body: playlist)
        await service.refreshSelectedProvider()
        XCTAssertEqual(service.channels.count, 2)
        XCTAssertTrue(service.channels.allSatisfy { $0.id.hasPrefix(kept.uuidString) })
    }

    func testRemovingAnUnselectedProviderKeepsTheSelectedProvidersStatus() async throws {
        let setup = makeService()
        let firstOther = try addProvider(to: setup, name: "FirstOther")
        let secondOther = try addProvider(to: setup, name: "SecondOther")
        let kept = try addProvider(to: setup, name: "Kept", guide: true)
        let gate = GuideLoadGate()
        let service = makeService(loader: ControlledGuideLoader(gate: gate))
        service.selectProvider(kept)

        let refresh = Task { await service.refresh(providerID: kept) }
        await gate.waitUntilStarted()
        let cachedOnly = LiveTVChannel(id: "\(kept.uuidString):" + String(repeating: "a", count: 64), guideID: nil,
                                       name: "Cached", streamURL: URL(string: "about:blank")!, logoURL: nil, category: "News")
        service.choose(cachedOnly, from: .list)
        let banner = try XCTUnwrap(service.errorMessage)
        XCTAssertTrue(service.isGuideLoading)

        await service.removeProvider(firstOther)
        XCTAssertEqual(service.selectedProviderID, kept)
        XCTAssertEqual(service.errorMessage, banner)
        XCTAssertTrue(service.isGuideLoading, "the selected provider's guide is still loading")

        await gate.release(Data("<html><body>502 Bad Gateway</body></html>".utf8))
        await refresh.value
        let guideMessage = try XCTUnwrap(service.guideMessage)
        XCTAssertFalse(service.isGuideLoading)

        await service.removeProvider(secondOther)
        XCTAssertEqual(service.selectedProviderID, kept)
        XCTAssertEqual(service.errorMessage, banner)
        XCTAssertEqual(service.guideMessage, guideMessage)
        XCTAssertEqual(service.providers.map(\.id), [kept])
    }

    func testRemovalSettlesSelectionAndStateBeforeDiskCleanup() async throws {
        let setup = makeService()
        let kept = try addProvider(to: setup, name: "Kept", guide: true)
        let removed = try addProvider(to: setup, name: "Removed", guide: true)
        try await seedCache(providerID: kept)
        try await seedCache(providerID: removed, fetchedAtOffset: -13 * 60 * 60)
        let service = makeService()
        service.selectProvider(removed)
        await service.restoreCachedState(for: kept)
        await service.restoreCachedState(for: removed)
        XCTAssertTrue(service.isGuideStale)

        let live = try XCTUnwrap(LiveTVM3UParser.parse(data: Data(playlist.utf8), providerID: kept).first)
        service.presentation.surfaceAppeared(.list)
        _ = service.presentation.select(live, from: .list)
        service.presentation.pictureInPictureStartedFromControl()
        var pipStops = 0
        service.presentation.stopPictureInPicture = { pipStops += 1 }

        // Exactly what runs before removal's first suspension point.
        service.forgetProvider(removed)
        XCTAssertEqual(service.providers.map(\.id), [kept])
        XCTAssertEqual(service.selectedProviderID, kept)
        XCTAssertEqual(service.channels.map(\.name), ["News One", "Sport"])
        XCTAssertFalse(service.isGuideStale, "the stale flag now describes the kept provider")
        XCTAssertNil(service.errorMessage)
        XCTAssertFalse(service.isLoading)
        XCTAssertEqual(service.presentation.phase, .pictureInPicture(live))
        XCTAssertEqual(pipStops, 0)
        let fileBeforeCleanup = snapshots.directory.appendingPathComponent("\(removed.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileBeforeCleanup.path), "disk cleanup has not run yet")

        await service.deleteProviderFiles(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileBeforeCleanup.path))
        let guideFile = directory.appendingPathComponent("guide/\(removed.uuidString).epgcache")
        XCTAssertFalse(FileManager.default.fileExists(atPath: guideFile.path))
        XCTAssertEqual(service.presentation.phase, .pictureInPicture(live))
    }

    func testGuideRefreshCompletionCannotChangeSelectedProvidersGuideState() async throws {
        let setup = makeService()
        let first = try addProvider(to: setup, name: "First", guide: true)
        let second = try addProvider(to: setup, name: "Second", guide: true)
        try await seedCache(providerID: first, fetchedAtOffset: -13 * 60 * 60)
        try await seedCache(providerID: second)
        let gate = GuideLoadGate()
        let service = makeService(loader: ControlledGuideLoader(gate: gate))
        service.selectProvider(first)
        await service.restoreCachedState(for: first)
        XCTAssertTrue(service.isGuideStale)

        let refresh = Task { await service.refresh(providerID: first) }
        await gate.waitUntilStarted()
        service.selectProvider(second)
        await service.restoreCachedState(for: second)
        XCTAssertFalse(service.isGuideStale)
        await gate.release(guideXML(title: "Fresh guide"))
        await refresh.value

        XCTAssertEqual(service.selectedProviderID, second)
        XCTAssertFalse(service.isGuideStale)
        XCTAssertNil(service.guideMessage)
        XCTAssertEqual(service.programPair(for: try XCTUnwrap(service.channels.first)).current?.title, "Cached Now")
    }

    func testRemovingProviderDuringGuideRefreshDoesNotPublishLateStatus() async throws {
        let setup = makeService()
        let removed = try addProvider(to: setup, name: "Removed", guide: true)
        let kept = try addProvider(to: setup, name: "Kept", guide: true)
        try await seedCache(providerID: removed, fetchedAtOffset: -13 * 60 * 60)
        try await seedCache(providerID: kept)
        let gate = GuideLoadGate()
        let service = makeService(loader: ControlledGuideLoader(gate: gate))
        service.selectProvider(removed)
        await service.restoreCachedState(for: removed)
        let refresh = Task { await service.refresh(providerID: removed) }
        await gate.waitUntilStarted()

        await service.removeProvider(removed)
        await refresh.value
        XCTAssertEqual(service.selectedProviderID, kept)
        XCTAssertNil(service.guideMessage)
        let removedSnapshot = await snapshots.load(providerID: removed)
        XCTAssertNil(removedSnapshot)
    }

    func testLargeSnapshotLoadsOffTheInitializerAndOnlyOnce() async throws {
        let providerID = try addProvider(to: makeService())
        let channels = (0..<LiveTVChannelSnapshotStore.maximumChannels).map { number in
            let digest = String(repeating: "0", count: 60) + String(format: "%04x", number)
            return LiveTVChannel(id: "\(providerID.uuidString):\(digest)", guideID: "\(number)", name: "Channel \(number)",
                          streamURL: URL(string: "https://stream.example.test/\(number)")!, logoURL: nil,
                          category: "Group \(number % 40)")
        }
        await snapshots.save(providerID: providerID, channels: channels)

        let service = makeService()
        XCTAssertTrue(service.channels.isEmpty, "the initializer does not read the snapshot on the main actor")
        async let first: Void = service.restoreCachedState(for: providerID)
        async let second: Void = service.restoreCachedState(for: providerID)
        _ = await (first, second)
        await service.restoreCachedState(for: providerID)

        XCTAssertEqual(service.channels.count, channels.count)
        XCTAssertEqual(service.channelCatalogRevision, 1, "concurrent restores share one load")
        XCTAssertEqual(service.categories.first, "Group 0")
        XCTAssertEqual(service.categories.last, "Group 39")
        XCTAssertEqual(PlaylistURLProtocol.requests, 0)
    }

    // MARK: - Provider readiness and Home previews

    func testCatalogReadinessIsPerProviderEvenAfterAnotherProviderLoaded() async throws {
        let writer = makeService()
        let first = try addProvider(to: writer, name: "First")
        let second = try addProvider(to: writer, name: "Second")
        try await seedCache(providerID: first)
        try await seedCache(providerID: second)

        let service = makeService()
        XCTAssertEqual(service.selectedProviderID, first)
        await service.restoreCachedState(for: first)
        XCTAssertTrue(service.hasCatalog(for: first))
        XCTAssertGreaterThan(service.channelCatalogRevision, 0)
        service.selectProvider(second)
        XCTAssertFalse(service.hasCatalog(for: second),
                       "the global revision is already positive, but this provider's catalog is still loading")
        await service.restoreCachedState(for: second)
        XCTAssertTrue(service.hasCatalog(for: second))
    }

    func testHomePreviewKeepsRailsVisibleWhileTheSameProviderRebuilds() async throws {
        let writer = makeService()
        let providerID = try addProvider(to: writer)
        try await seedCache(providerID: providerID)
        let channels = try LiveTVM3UParser.parse(data: Data(playlist.utf8), providerID: providerID)
        let news = try XCTUnwrap(channels.first { $0.name == "News One" })
        let sport = try XCTUnwrap(channels.first { $0.name == "Sport" })
        writer.toggleFavorite(news)
        let history = LiveTVRecentHistoryStore(defaults: defaults)
        history.save([try XCTUnwrap(LiveTVRecentChannel(providerID: providerID, channelID: sport.id))])
        history.flush()

        let service = makeService()
        await service.restoreCachedState(for: providerID)
        await service.homePreviewRebuildForTesting()
        XCTAssertEqual(service.homeFavoriteChannels.map(\.id), [news.id])
        XCTAssertEqual(service.homeRecentChannels.map(\.id), [sport.id])

        service.toggleFavorite(sport)
        XCTAssertEqual(service.homeFavoriteChannels.map(\.id), [news.id], "the lineup stays on screen while it rebuilds")
        XCTAssertEqual(service.homeRecentChannels.map(\.id), [sport.id], "the hero and recents stay on screen too")
        await service.homePreviewRebuildForTesting()
        XCTAssertEqual(service.homeFavoriteChannels.map(\.id), [news.id, sport.id])
        XCTAssertEqual(service.homeRecentChannels.map(\.id), [sport.id])
    }

    func testHomePreviewClearsOnProviderChangeAndNeverPublishesTheOlderProvidersScan() async throws {
        let writer = makeService()
        let first = try addProvider(to: writer, name: "First")
        let second = try addProvider(to: writer, name: "Second")
        try await seedCache(providerID: first)
        try await seedCache(providerID: second)
        let firstChannels = try LiveTVM3UParser.parse(data: Data(playlist.utf8), providerID: first)
        let secondChannels = try LiveTVM3UParser.parse(data: Data(playlist.utf8), providerID: second)
        writer.toggleFavorite(firstChannels[0])
        writer.toggleFavorite(secondChannels[1])

        let service = makeService()
        await service.restoreCachedState(for: first)
        await service.homePreviewRebuildForTesting()
        XCTAssertEqual(service.homeFavoriteChannels.map(\.id), [firstChannels[0].id])

        service.toggleFavorite(firstChannels[1])  // schedules a scan of the first provider
        service.selectProvider(second)            // supersedes it before it can publish
        XCTAssertTrue(service.homeFavoriteChannels.isEmpty, "a provider change clears the rails at once")
        XCTAssertTrue(service.homeRecentChannels.isEmpty)
        await service.homePreviewRebuildForTesting()
        XCTAssertFalse(service.homeFavoriteChannels.contains { LiveTVRecentChannel.belongs($0.id, to: first) },
                       "the superseded scan of the first provider is never published")

        await service.restoreCachedState(for: second)
        await service.homePreviewRebuildForTesting()
        XCTAssertEqual(service.homeFavoriteChannels.map(\.id), [secondChannels[1].id])
    }

    func testRefreshReplacesCachedPreviewChannelsWithPlayableOnes() async throws {
        let writer = makeService()
        let providerID = try addProvider(to: writer)
        try await seedCache(providerID: providerID)
        let news = try XCTUnwrap(LiveTVM3UParser.parse(data: Data(playlist.utf8), providerID: providerID)
            .first { $0.name == "News One" })
        writer.toggleFavorite(news)

        let service = makeService()
        await service.restoreCachedState(for: providerID)
        await service.homePreviewRebuildForTesting()
        XCTAssertEqual(service.homeFavoriteChannels.first?.streamURL.scheme, "about", "cached rows are browse-only")

        PlaylistURLProtocol.reset(body: playlist)
        await service.refresh(providerID: providerID)
        await service.homePreviewRebuildForTesting()
        XCTAssertEqual(service.homeFavoriteChannels.map(\.id), [news.id])
        XCTAssertEqual(service.homeFavoriteChannels.first?.streamURL.scheme, "https",
                       "the rebuilt rail holds the refreshed, playable channel rather than the cached one")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition())
    }

    private func twoChannelGuideXML(at now: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss '+0000'"
        func stamp(_ delta: TimeInterval) -> String { formatter.string(from: now.addingTimeInterval(delta)) }
        return Data("""
        <tv><programme channel="news.one" start="\(stamp(-600))" stop="\(stamp(172_800))"><title>Full News</title></programme>\
        <programme channel="sport" start="\(stamp(-600))" stop="\(stamp(172_800))"><title>Full Sport</title></programme></tv>
        """.utf8)
    }

    private func guideXML(title: String) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss '+0000'"
        let now = Date()
        return Data("""
        <tv><programme channel="news.one" start="\(formatter.string(from: now.addingTimeInterval(-600)))" \
        stop="\(formatter.string(from: now.addingTimeInterval(3_000)))"><title>\(title)</title></programme></tv>
        """.utf8)
    }
}

@MainActor
private final class SnapshotTestSecretStore: LiveTVSecretStore {
    var values: [String: String] = [:]
    func read(account: String) -> String? { values[account] }
    func save(_ value: String, account: String) -> Bool { values[account] = value; return true }
    func remove(account: String) -> Bool { values.removeValue(forKey: account) != nil }
}

private final class GuideClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date
    init(_ date: Date) { stored = date }
    var date: Date {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class StaticGuideLoader: EPGFeedLoading, @unchecked Sendable {
    private let lock = NSLock()
    private let payload: Data
    private var count = 0
    init(payload: Data) { self.payload = payload }
    var calls: Int { lock.withLock { count } }
    func load(_ url: URL, maximumBytes: Int) async throws -> Data {
        lock.withLock { count += 1 }
        return payload
    }
    func load(_ url: URL, maximumBytes: Int, maximumDecodedBytes: Int) async throws -> Data {
        try await load(url, maximumBytes: maximumBytes)
    }
}

private struct OfflineGuideLoader: EPGFeedLoading {
    func load(_ url: URL, maximumBytes: Int) async throws -> Data { throw EPGError.providerRejected }
    func load(_ url: URL, maximumBytes: Int, maximumDecodedBytes: Int) async throws -> Data { throw EPGError.providerRejected }
}

private final class CountingOfflineGuideLoader: EPGFeedLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func load(_ url: URL, maximumBytes: Int) async throws -> Data {
        lock.withLock { count += 1 }
        throw EPGError.providerRejected
    }
    func load(_ url: URL, maximumBytes: Int, maximumDecodedBytes: Int) async throws -> Data {
        try await load(url, maximumBytes: maximumBytes)
    }
}

private final class CacheReadGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let releaseSignal = DispatchSemaphore(value: 0)
    func enterAndWait() { entered.signal(); releaseSignal.wait() }
    func waitUntilEntered(timeout: TimeInterval) async -> Bool {
        let semaphore = entered
        return await Task.detached { Self.wait(semaphore, timeout: timeout) }.value
    }
    func release() { releaseSignal.signal() }

    private static func wait(_ semaphore: DispatchSemaphore, timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }
}

private struct ControlledGuideLoader: EPGFeedLoading {
    let gate: GuideLoadGate
    func load(_ url: URL, maximumBytes: Int) async throws -> Data { try await gate.load() }
    func load(_ url: URL, maximumBytes: Int, maximumDecodedBytes: Int) async throws -> Data {
        try await gate.load()
    }
}

private actor GuideLoadGate {
    private var continuation: CheckedContinuation<Data, Error>?
    private var started = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func load() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if cancelled || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.continuation = continuation
                    started = true
                    startWaiters.forEach { $0.resume() }
                    startWaiters = []
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release(_ data: Data) {
        continuation?.resume(returning: data)
        continuation = nil
    }

    private func cancel() {
        cancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        startWaiters.forEach { $0.resume() }
        startWaiters = []
    }
}

/// Serves `playlist.test`. A held response waits for `release()` or for the task to be cancelled.
private final class PlaylistURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var body = Data()
    private static var status = 200
    private static var isHeld = false
    private static var requestCount = 0
    private static var waiting: [PlaylistURLProtocol] = []

    static var requests: Int { lock.withLock { requestCount } }

    static func reset(body: String, status: Int = 200, held: Bool = false) {
        lock.withLock {
            self.body = Data(body.utf8)
            self.status = status
            isHeld = held
            requestCount = 0
            waiting = []
        }
    }

    static func release() {
        let released = lock.withLock { () -> [PlaylistURLProtocol] in
            isHeld = false
            defer { waiting = [] }
            return waiting
        }
        released.forEach { $0.respond() }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "playlist.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let held = Self.lock.withLock { () -> Bool in
            Self.requestCount += 1
            if Self.isHeld { Self.waiting.append(self) }
            return Self.isHeld
        }
        if !held { respond() }
    }

    override func stopLoading() {
        Self.lock.withLock { Self.waiting.removeAll { $0 === self } }
    }

    private func respond() {
        let (body, status) = Self.lock.withLock { (Self.body, Self.status) }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Serves the Xtream panel used by the short-guide regression. Other tests never request this host.
/// A held short-guide response waits for `releaseShortGuide()` or for its task to be cancelled.
private final class PanelURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var shortListings = #"{"epg_listings":[]}"#
    private static var holdsShortGuide = false
    private static var shortRequestCount = 0
    private static var heldShortGuides: [PanelURLProtocol] = []

    static func reset() {
        lock.withLock {
            shortListings = #"{"epg_listings":[]}"#
            holdsShortGuide = false
            shortRequestCount = 0
            heldShortGuides = []
        }
    }
    static var shortBody: String {
        get { lock.withLock { shortListings } }
        set { lock.withLock { shortListings = newValue } }
    }
    static var shortRequests: Int { lock.withLock { shortRequestCount } }
    static var heldShortRequests: Int { lock.withLock { heldShortGuides.count } }
    static func holdShortGuide() { lock.withLock { holdsShortGuide = true } }
    static func releaseShortGuide() {
        let released = lock.withLock { () -> [PanelURLProtocol] in
            holdsShortGuide = false
            defer { heldShortGuides = [] }
            return heldShortGuides
        }
        released.forEach { $0.respond() }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "panel.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let held = Self.lock.withLock { () -> Bool in
            guard action == "get_short_epg" else { return false }
            Self.shortRequestCount += 1
            if Self.holdsShortGuide { Self.heldShortGuides.append(self) }
            return Self.holdsShortGuide
        }
        if !held { respond() }
    }

    override func stopLoading() {
        Self.lock.withLock { Self.heldShortGuides.removeAll { $0 === self } }
    }

    private var action: String? {
        let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return items.first { $0.name == "action" }?.value
    }

    private func respond() {
        let body: String
        switch action {
        case nil:
            body = #"{"user_info":{"auth":1,"status":"Active","allowed_output_formats":["ts"]}}"#
        case "get_live_categories":
            body = #"[{"category_id":"1","category_name":"News"}]"#
        case "get_live_streams":
            body = #"[{"stream_id":7,"name":"News One","epg_channel_id":"news.one","category_id":"1","container_extension":"ts"},{"stream_id":8,"name":"Sport","epg_channel_id":"sport","category_id":"1","container_extension":"ts"}]"#
        case "get_short_epg":
            body = Self.shortBody
        default:
            body = "{}"
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
