import Foundation
import AVFoundation
import UIKit
import XCTest
@testable import Silo

@MainActor
final class LiveTVFoundationTests: XCTestCase {
    func testM3UParsesMetadataAndDeduplicatesStableChannelIDs() throws {
        let providerID = UUID(uuidString: "A1F4C8A0-CB4C-4B3D-9F73-9AA2BDA7C6B0")!
        let source = #"""
        #EXTM3U
        #EXTINF:-1 tvg-id="news.one" tvg-logo="https://logos.example.test/news.png" group-title="News, Local",News One
        https://streams.example.test/news/index.m3u8?token=private
        #EXTINF:-1 tvg-id="news.one" group-title="Duplicate",Different duplicate label
        https://streams.example.test/news-copy/index.m3u8
        #EXTINF:-1 group-title="Sports",Sports One
        https://streams.example.test/sports/index.m3u8
        """#

        let channels = try LiveTVM3UParser.parse(data: Data(source.utf8), providerID: providerID)
        XCTAssertEqual(channels.count, 2)
        XCTAssertEqual(channels[0].name, "News One")
        XCTAssertEqual(channels[0].guideID, "news.one")
        XCTAssertEqual(channels[0].category, "News, Local")
        XCTAssertEqual(channels[0].logoURL?.host, "logos.example.test")
        XCTAssertEqual(channels[1].category, "Sports")
        XCTAssertEqual(channels[0].id, try XCTUnwrap(
            LiveTVM3UParser.parse(data: Data(source.utf8), providerID: providerID).first?.id
        ))
    }

    func testM3URejectsMalformedAndNonHTTPStreamsWithoutInventingChannels() throws {
        let providerID = UUID()
        let source = #"""
        #EXTM3U
        #EXTINF:-1,Missing URL
        #EXTINF:-1,Relative URL
        /relative/path.m3u8
        #EXTINF:-1,Unsupported Scheme
        rtmp://stream.example.test/live
        #EXTINF:-1,Valid
        https://stream.example.test/live/index.m3u8
        """#
        let channels = try LiveTVM3UParser.parse(data: Data(source.utf8), providerID: providerID)
        XCTAssertEqual(channels.map(\.name), ["Valid"])
    }

    func testM3UParseResultReportsChannelLimitWithoutInventingATotal() throws {
        let providerID = UUID()
        func playlist(count: Int) -> String {
            var lines = ["#EXTM3U"]
            for index in 0..<count {
                lines.append("#EXTINF:-1,Channel \(index)")
                lines.append("https://stream.example.test/\(index).m3u8")
            }
            return lines.joined(separator: "\n")
        }

        let exact = try LiveTVM3UParser.parseResult(data: Data(playlist(count: 3).utf8),
                                                    providerID: providerID, limit: 3)
        XCTAssertEqual(exact.channels.count, 3)
        XCTAssertFalse(exact.hitChannelLimit, "an exact-cap playlist is not truncated")

        let over = try LiveTVM3UParser.parseResult(data: Data(playlist(count: 5).utf8),
                                                   providerID: providerID, limit: 3)
        XCTAssertEqual(over.channels.count, 3)
        XCTAssertTrue(over.hitChannelLimit)
        XCTAssertEqual(over.channels.map(\.name), ["Channel 0", "Channel 1", "Channel 2"])

        let notice = LiveTVCatalogNotice.channelLimitReached(limit: 20_000)
        XCTAssertTrue(notice.contains("20"))
        XCTAssertTrue(notice.contains("limit"))
        XCTAssertFalse(notice.contains("of "), "must not invent a total channel count")
        XCTAssertNotEqual(notice, LiveTVError.responseTooLarge.localizedDescription)
    }

    func testEPGIndexConformsToEPGQueryingSeam() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let program = EPGProgram(channelID: "news.one", start: now.addingTimeInterval(-600),
                                 end: now.addingTimeInterval(600), title: "Bulletin")
        let index = try EPGIndex(document: EPGDocument(channels: [EPGChannel(id: "news.one", displayNames: ["News"])],
                                                       programs: [program]),
                                 fetchedAt: now, now: now, limits: EPGLimits())
        let querying: any EPGQuerying = index
        XCTAssertEqual(querying.programCount, 1)
        XCTAssertEqual(querying.channelKey(guideID: "news.one", name: nil), "news.one")
        XCTAssertEqual(querying.nowNext(channelKey: "news.one", at: now).current?.title, "Bulletin")
        XCTAssertEqual(querying.programs(channelKey: "news.one",
                                         overlapping: DateInterval(start: now, end: now.addingTimeInterval(60))).count, 1)
    }

    func testProviderURLAndGuideTokensStayOutOfUserDefaultsAndErrorsAreGeneric() throws {
        let suiteName = "LiveTVFoundationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secrets = MemoryLiveTVSecretStore()
        let service = LiveTVService(defaults: defaults, secretStore: secrets,
                                    epg: EPGService(cache: nil, loader: URLSessionEPGFeedLoader.makeDefault(),
                                                    fingerprinter: .inMemory()))
        let token = "playlist-token-should-not-leak"
        let guideToken = "guide-token-should-not-leak"

        let providerID = try service.saveConfiguration(
            name: "Test provider",
            playlistURL: "https://example.test/playlist.m3u?token=\(token)",
            xmltvURL: "https://example.test/guide.xml?auth=\(guideToken)"
        )
        let metadata = try XCTUnwrap(defaults.data(forKey: "liveTV.providers.v1"))
        let serializedMetadata = try XCTUnwrap(String(data: metadata, encoding: .utf8))
        XCTAssertFalse(serializedMetadata.contains(token))
        XCTAssertFalse(serializedMetadata.contains(guideToken))
        XCTAssertTrue(secrets.values["provider.\(providerID.uuidString)"]?.contains(token) == true)
        XCTAssertTrue(secrets.values["provider.\(providerID.uuidString)"]?.contains(guideToken) == true)
        XCTAssertFalse(LiveTVError.providerRejected.localizedDescription.contains(token))
    }

    func testChannelSearchAndFavoritesFiltering() throws {
        let providerID = UUID()
        let source = #"""
        #EXTM3U
        #EXTINF:-1 group-title="Local News",North News
        https://example.test/north.m3u8
        #EXTINF:-1 group-title="Sports",North Sports
        https://example.test/sports.m3u8
        #EXTINF:-1 group-title="News",World News
        https://example.test/world.m3u8
        """#
        let channels = try LiveTVM3UParser.parse(data: Data(source.utf8), providerID: providerID)
        let favorites: Set<String> = [try XCTUnwrap(channels.first?.id)]

        XCTAssertEqual(LiveTVChannelFiltering.filter(
            channels, query: "north", category: nil, favoritesOnly: false, favoriteIDs: favorites
        ).map(\.name), ["North News", "North Sports"])
        XCTAssertEqual(LiveTVChannelFiltering.filter(
            channels, query: "news", category: "News", favoritesOnly: false, favoriteIDs: favorites
        ).map(\.name), ["World News"])
        XCTAssertEqual(LiveTVChannelFiltering.filter(
            channels, query: "", category: nil, favoritesOnly: true, favoriteIDs: favorites
        ).map(\.name), ["North News"])
    }

    func testLargeCatalogSearchRunsCancellableAndReturnsStableMatchingChannels() async throws {
        let channels = (0..<20_000).map { index in
            LiveTVChannel(id: "provider:\(index)", guideID: nil, name: "Channel \(index)",
                          streamURL: URL(string: "https://fixture.invalid/\(index).m3u8")!, logoURL: nil,
                          category: index.isMultiple(of: 2) ? "Sports" : "News")
        }
        let search = LiveTVChannelSearchModel()
        search.update(channels: channels, query: "Channel 19999", category: "News", favoritesOnly: false,
                      favoriteIDs: [], debounce: .zero)
        await search.waitForCurrentSearch()
        XCTAssertEqual(search.resultCount, 1)
        XCTAssertEqual(search.groups["News"]?.first?.id, "provider:19999")

        let gate = TextInputDelayGate(hold: true)
        gate.install(on: search)
        defer { gate.release() }
        search.update(channels: channels, query: "Channel 2", category: "Sports", favoritesOnly: false,
                      favoriteIDs: [], debounce: .seconds(1))
        XCTAssertTrue(search.isDebouncingTextInput)
        if !search.isDebouncingTextInput { return }
        await gate.waitUntilEntered()
        search.update(channels: channels, query: "Channel 18000", category: "Sports", favoritesOnly: false,
                      favoriteIDs: [], debounce: .zero)
        XCTAssertFalse(search.isDebouncingTextInput, "an explicit zero debounce must replace the held query")
        await search.waitForCurrentSearch()
        XCTAssertEqual(search.groups.values.flatMap { $0 }.map(\.id), ["provider:18000"])
        gate.release()
        await Task.yield()
        XCTAssertEqual(search.groups.values.flatMap { $0 }.map(\.id), ["provider:18000"],
                       "releasing the superseded query must not publish it")
        search.cancel()
        XCTAssertEqual(search.resultCount, 0)
        XCTAssertFalse(search.isDebouncingTextInput)
    }

    func testCategoryAndInitialPopulationPublishWithoutTextDebounce() async {
        let channels = largeSearchCatalog()
        let search = LiveTVChannelSearchModel()
        let gate = TextInputDelayGate(hold: false)
        gate.install(on: search)

        search.update(channels: channels, query: "", category: nil, favoritesOnly: false, favoriteIDs: [])
        XCTAssertFalse(search.isDebouncingTextInput, "the first catalog population must not schedule the text debounce")
        if search.isDebouncingTextInput { return }
        await search.waitForCurrentSearch()
        XCTAssertTrue(gate.delays.isEmpty, "the first population must not call the text-input delay: \(gate.delays)")
        XCTAssertEqual(search.resultCount, 20_000)

        search.update(channels: channels, query: "", category: "Sports", favoritesOnly: false, favoriteIDs: [])
        XCTAssertFalse(search.isDebouncingTextInput, "a category change with the same query must not schedule the text debounce")
        if search.isDebouncingTextInput { return }
        await search.waitForCurrentSearch()
        XCTAssertTrue(gate.delays.isEmpty, "a category change must not call the text-input delay: \(gate.delays)")
        XCTAssertEqual(search.resultCount, 10_000)
        XCTAssertEqual(search.orderedCategories, ["Sports"])
    }

    func testRapidCategorySwitchPublishesOnlyTheLatestSelection() async {
        let channels = searchSchedulingCatalog()
        let search = LiveTVChannelSearchModel()
        let gate = TextInputDelayGate(hold: true)
        gate.install(on: search)
        defer { gate.release() }
        for category in ["News", "Sports", "News", "Sports", nil] as [String?] {
            search.update(channels: channels, query: "  ", category: category, favoritesOnly: false, favoriteIDs: [])
            XCTAssertFalse(search.isDebouncingTextInput)
        }
        if search.isDebouncingTextInput { return }
        await search.waitForCurrentSearch()
        XCTAssertTrue(gate.delays.isEmpty)
        XCTAssertEqual(search.resultCount, channels.count)
        XCTAssertEqual(Set(search.orderedCategories), ["News", "Sports"])
    }

    func testSearchInputReplacementRejectsTheStaleQuery() async {
        let channels = searchSchedulingCatalog()
        let search = LiveTVChannelSearchModel()
        let gate = TextInputDelayGate(hold: true)
        gate.install(on: search)
        defer { gate.release() }
        search.update(channels: channels, query: "", category: nil, favoritesOnly: false, favoriteIDs: [])
        await search.waitForCurrentSearch()

        search.update(channels: channels, query: "Channel 1", category: nil, favoritesOnly: false,
                      favoriteIDs: [], debounce: .seconds(30))
        XCTAssertTrue(search.isDebouncingTextInput)
        if !search.isDebouncingTextInput { return }
        await gate.waitUntilEntered()
        XCTAssertEqual(search.resultCount, channels.count, "the first query must stay unpublished while its delay is held")

        gate.hold = false
        search.update(channels: channels, query: "Channel 19999", category: "News", favoritesOnly: false, favoriteIDs: [])
        XCTAssertTrue(search.isDebouncingTextInput, "replacing the query is still a text edit")
        if !search.isDebouncingTextInput { return }
        XCTAssertEqual(search.resultCount, channels.count, "the replacement must not publish synchronously")
        await gate.waitUntilEntered(count: 2)
        XCTAssertEqual(gate.delays, [.seconds(30), .milliseconds(180)])
        await search.waitForCurrentSearch()
        XCTAssertEqual(search.resultCount, 1)
        XCTAssertEqual(search.groups["News"]?.map(\.id), ["provider:19999"])
        XCTAssertNil(search.groups["Sports"])
        gate.release()
        await Task.yield()
        XCTAssertEqual(search.groups["News"]?.map(\.id), ["provider:19999"],
                       "the held query must not publish after the replacement")
    }

    func testTextInputStaysDebouncedWhileCategoryStaysImmediate() async {
        let channels = searchSchedulingCatalog()
        let search = LiveTVChannelSearchModel()
        let gate = TextInputDelayGate(hold: true)
        gate.install(on: search)
        defer { gate.release() }
        search.update(channels: channels, query: "", category: nil, favoritesOnly: false, favoriteIDs: [])
        await search.waitForCurrentSearch()

        search.update(channels: channels, query: "Channel 19999", category: nil, favoritesOnly: false, favoriteIDs: [])
        XCTAssertTrue(search.isDebouncingTextInput)
        if !search.isDebouncingTextInput { return }
        await gate.waitUntilEntered()
        XCTAssertEqual(gate.delays, [.milliseconds(180)])
        XCTAssertEqual(search.resultCount, channels.count, "a keystroke must not publish while its delay is held")

        search.update(channels: channels, query: "Channel 19999", category: "News", favoritesOnly: false, favoriteIDs: [])
        XCTAssertFalse(search.isDebouncingTextInput, "the same query with a new category must not keep the text delay")
        if search.isDebouncingTextInput { return }
        await search.waitForCurrentSearch()
        XCTAssertEqual(search.resultCount, 1)
        XCTAssertEqual(search.groups["News"]?.map(\.id), ["provider:19999"])
        gate.release()
        await Task.yield()
        XCTAssertEqual(search.groups["News"]?.map(\.id), ["provider:19999"])
    }

    func testClearingAQueryPublishesTheCategoryWithoutTheTextDelay() async {
        let channels = searchSchedulingCatalog()
        let search = LiveTVChannelSearchModel()
        let gate = TextInputDelayGate(hold: true)
        gate.install(on: search)
        defer { gate.release() }
        search.update(channels: channels, query: "Channel 19999", category: nil, favoritesOnly: false,
                      favoriteIDs: [], debounce: .zero)
        await search.waitForCurrentSearch()
        XCTAssertEqual(search.resultCount, 1)

        search.update(channels: channels, query: "", category: "Sports", favoritesOnly: false, favoriteIDs: [])
        XCTAssertFalse(search.isDebouncingTextInput,
                       "clearing the field while switching category must not schedule the text debounce")
        if search.isDebouncingTextInput { return }
        await search.waitForCurrentSearch()
        XCTAssertEqual(gate.delays, [], "clearing to an empty query must not call the text-input delay: \(gate.delays)")
        XCTAssertEqual(search.orderedCategories, ["Sports"])
        XCTAssertEqual(search.resultCount, channels.filter { $0.category == "Sports" }.count)
        XCTAssertFalse(search.groups["Sports"]?.contains { $0.id == "provider:19999" } ?? false)

        search.update(channels: channels, query: "Channel 1", category: "Sports", favoritesOnly: false, favoriteIDs: [])
        XCTAssertTrue(search.isDebouncingTextInput)
        if !search.isDebouncingTextInput { return }
        await gate.waitUntilEntered()
        search.update(channels: channels, query: "   ", category: "News", favoritesOnly: false, favoriteIDs: [])
        XCTAssertFalse(search.isDebouncingTextInput, "a later clear-and-category update must cancel the held keystroke")
        if search.isDebouncingTextInput { return }
        await search.waitForCurrentSearch()
        XCTAssertEqual(search.orderedCategories, ["News"])
        XCTAssertEqual(search.resultCount, channels.filter { $0.category == "News" }.count)
        gate.release()
        await Task.yield()
        XCTAssertEqual(search.orderedCategories, ["News"], "the held keystroke must not replace the cleared category")
    }

    func testCancelledSearchDoesNotPublishAndTheNextPopulationIsImmediate() async {
        let channels = searchSchedulingCatalog()
        let search = LiveTVChannelSearchModel()
        let gate = TextInputDelayGate(hold: true)
        gate.install(on: search)
        defer { gate.release() }
        search.update(channels: channels, query: "", category: nil, favoritesOnly: false, favoriteIDs: [])
        await search.waitForCurrentSearch()
        search.update(channels: channels, query: "Channel 5", category: nil, favoritesOnly: false,
                      favoriteIDs: [], debounce: .seconds(30))
        XCTAssertTrue(search.isDebouncingTextInput)
        if !search.isDebouncingTextInput { return }
        await gate.waitUntilEntered()
        search.cancel()
        XCTAssertFalse(search.isDebouncingTextInput)
        XCTAssertEqual(search.resultCount, 0)
        XCTAssertTrue(search.groups.isEmpty)
        gate.release()
        await Task.yield()
        XCTAssertEqual(search.resultCount, 0, "a cancelled text delay must not publish after it is released")

        search.update(channels: channels, query: "Channel 18000", category: "Sports", favoritesOnly: false, favoriteIDs: [])
        XCTAssertFalse(search.isDebouncingTextInput, "the population after cancel is a fresh pass, not a keystroke")
        if search.isDebouncingTextInput { return }
        await search.waitForCurrentSearch()
        XCTAssertEqual(search.groups["Sports"]?.map(\.id), ["provider:18000"])
    }

    func testUnicodeSearchAndCategoryStayOnTheFilteredCatalog() async {
        let channels = largeSearchCatalog()
        let search = LiveTVChannelSearchModel()
        let gate = TextInputDelayGate(hold: false)
        gate.install(on: search)
        search.update(channels: channels, query: "cafe", category: nil, favoritesOnly: false, favoriteIDs: [],
                      debounce: .zero)
        XCTAssertFalse(search.isDebouncingTextInput)
        await search.waitForCurrentSearch()
        XCTAssertEqual(search.groups["News"]?.map(\.name), ["Café Culture"])

        search.update(channels: channels, query: "CAFÉ", category: "Sports", favoritesOnly: false, favoriteIDs: [])
        XCTAssertTrue(search.isDebouncingTextInput, "changing cafe to CAFÉ is a query edit and keeps the text debounce")
        search.waitForTextInput = { _ in }
        await search.waitForCurrentSearch()
        XCTAssertEqual(search.resultCount, 0, "the Café channel is News, so a Sports filter excludes it")

        search.update(channels: channels, query: "спорт", category: "Sports", favoritesOnly: false, favoriteIDs: [],
                      debounce: .zero)
        await search.waitForCurrentSearch()
        XCTAssertEqual(search.groups["Sports"]?.map(\.name), ["Спорт Один"])

        let favoriteID = "provider:7"
        search.update(channels: channels, query: "", category: "News", favoritesOnly: true,
                      favoriteIDs: [favoriteID])
        XCTAssertFalse(search.isDebouncingTextInput, "clearing the query while changing category and favorites must not debounce")
        if search.isDebouncingTextInput { return }
        await search.waitForCurrentSearch()
        XCTAssertEqual(search.groups["News"]?.map(\.id), [favoriteID])
    }

    private func searchSchedulingCatalog() -> [LiveTVChannel] {
        [
            searchChannel("0", "Café Culture", "News"),
            searchChannel("1", "Спорт Один", "Sports"),
            searchChannel("2", "Channel 2", "Sports"),
            searchChannel("7", "Channel 7", "News"),
            searchChannel("18000", "Channel 18000", "Sports"),
            searchChannel("19999", "Channel 19999", "News"),
        ]
    }

    private func searchChannel(_ id: String, _ name: String, _ category: String) -> LiveTVChannel {
        LiveTVChannel(id: "provider:\(id)", guideID: nil, name: name,
                      streamURL: URL(string: "https://fixture.invalid/\(id).m3u8")!,
                      logoURL: nil, category: category)
    }

    private func largeSearchCatalog() -> [LiveTVChannel] {
        (0..<20_000).map { index in
            let name: String
            let category: String
            if index == 0 {
                name = "Café Culture"
                category = "News"
            } else if index == 1 {
                name = "Спорт Один"
                category = "Sports"
            } else {
                name = "Channel \(index)"
                category = index.isMultiple(of: 2) ? "Sports" : "News"
            }
            return LiveTVChannel(id: "provider:\(index)", guideID: nil, name: name,
                                 streamURL: URL(string: "https://fixture.invalid/\(index).m3u8")!,
                                 logoURL: nil, category: category)
        }
    }

    func testFavoriteAndCategoryFilteringKeepsStableChannelIdentity() throws {
        let providerID = UUID()
        let channels = try LiveTVM3UParser.parse(data: Data(#"""
        #EXTM3U
        #EXTINF:-1 group-title="Sports",Match One
        https://fixture.invalid/match-one.m3u8
        #EXTINF:-1 group-title="News",Daily News
        https://fixture.invalid/news.m3u8
        """#.utf8), providerID: providerID)
        let favorite = try XCTUnwrap(channels.first)
        let sports = LiveTVChannelFiltering.filter(channels, query: "", category: "Sports",
                                                   favoritesOnly: true, favoriteIDs: [favorite.id])
        XCTAssertEqual(sports.map(\.id), [favorite.id])
        XCTAssertTrue(LiveTVChannelFiltering.filter(channels, query: "", category: "News",
                                                    favoritesOnly: true, favoriteIDs: [favorite.id]).isEmpty)
    }

    func testXMLTVUsesChannelIDsForCurrentAndNextProgramme() throws {
        let xml = #"""
        <tv>
          <programme channel="news.one" start="20260101110000 +0000" stop="20260101120000 +0000">
            <title>Current bulletin</title>
          </programme>
          <programme channel="news.one" start="20260101120000 +0000" stop="20260101130000 +0000">
            <title>Next bulletin</title>
          </programme>
          <programme channel="other" start="20260101110000 +0000" stop="20260101120000 +0000">
            <title>Other service</title>
          </programme>
        </tv>
        """#
        let now = ISO8601DateFormatter().date(from: "2026-01-01T11:30:00Z")!
        let index = try EPGIndex(document: XMLTVParser.parse(Data(xml.utf8)), fetchedAt: now, now: now, limits: EPGLimits())
        let pair = index.nowNext(guideID: "news.one", name: nil, at: now)
        XCTAssertEqual(pair.current?.title, "Current bulletin")
        XCTAssertEqual(pair.next?.title, "Next bulletin")
        XCTAssertNil(index.nowNext(guideID: nil, name: nil, at: now).current)
    }

    private func makeSession(_ engine: LiveTVTestEngine) -> LiveTVPlayerSession {
        LiveTVPlayerSession(scheduler: LiveTVTestScheduler(), makeEngine: { engine }, isOtherVideoActive: { false })
    }

    private func settle() async { for _ in 0..<8 { await Task.yield() } }

    func testLivePlayerRejectsUnsupportedLocalSourceAndRemainsIsolated() async {
        let engine = LiveTVTestEngine()
        let session = makeSession(engine)
        let channel = LiveTVChannel(
            id: "test", guideID: nil, name: "Local unsupported",
            streamURL: URL(fileURLWithPath: "/tmp/not-a-channel.ts"), logoURL: nil, category: "Other"
        )
        session.play(channel)
        await settle()
        XCTAssertEqual(session.state, .failed)
        XCTAssertTrue(engine.loads.isEmpty)
        session.stop()
        XCTAssertEqual(session.state, .stopped)
    }

    func testLivePlaybackSwitchAndStopClearPreviousSessionState() async {
        let engine = LiveTVTestEngine()
        let session = makeSession(engine)
        let first = LiveTVChannel(id: "first", guideID: nil, name: "First",
            streamURL: URL(string: "rtmp://fixture.invalid/first")!, logoURL: nil, category: "Sports")
        let next = LiveTVChannel(id: "next", guideID: nil, name: "Next",
            streamURL: URL(string: "https://fixture.invalid/live/next.ts")!, logoURL: nil, category: "Sports")
        session.play(first)
        XCTAssertEqual(session.state, .failed)
        XCTAssertNotNil(session.errorMessage)

        session.play(next)
        await settle()
        XCTAssertEqual(session.activeChannelID, next.id)
        XCTAssertEqual(session.state, .connecting)
        XCTAssertNil(session.errorMessage)
        XCTAssertEqual(engine.loads.last, next.streamURL)
        session.stop()
        XCTAssertNil(session.activeChannelID)
        XCTAssertEqual(session.state, .stopped)
        XCTAssertEqual(engine.finalStops, 1)
    }

    func testStableSessionDoesNotReplaceSameChannelAndSwitchRejectsStaleEvents() async {
        let engine = LiveTVTestEngine()
        let session = makeSession(engine)
        let first = LiveTVChannel(id: "first", guideID: nil, name: "First",
            streamURL: URL(string: "https://fixture.invalid/first.ts")!, logoURL: nil, category: "News")
        let next = LiveTVChannel(id: "next", guideID: nil, name: "Next",
            streamURL: URL(string: "https://fixture.invalid/next.ts")!, logoURL: nil, category: "News")
        session.play(first)
        let firstGeneration = session.controller.generation
        session.play(first)
        XCTAssertEqual(session.controller.generation, firstGeneration)

        session.play(next)
        session.controller.phaseChanged(.playing, generation: firstGeneration)
        session.controller.phaseChanged(.failed(.network, detail: nil), generation: firstGeneration)
        XCTAssertEqual(session.activeChannelID, next.id)
        XCTAssertEqual(session.state, .connecting)
        XCTAssertFalse(session.controller.isStallTimerArmed)
        session.stop()
    }

    func testPlayingReadyCallbackIsGenerationCheckedAndDeduplicated() async {
        let engine = LiveTVTestEngine()
        let session = makeSession(engine)
        let first = LiveTVChannel(id: "first", guideID: nil, name: "First",
            streamURL: URL(string: "https://fixture.invalid/first.ts")!, logoURL: nil, category: "News")
        let next = LiveTVChannel(id: "next", guideID: nil, name: "Next",
            streamURL: URL(string: "https://fixture.invalid/next.ts")!, logoURL: nil, category: "News")
        var ready: [(String, Int)] = []
        session.onPlayingReady = { ready.append(($0, $1)) }

        session.play(first)
        let staleGeneration = session.controller.generation
        session.play(next)
        session.controller.phaseChanged(.playing, generation: staleGeneration)
        XCTAssertTrue(ready.isEmpty)

        engine.onPhase?(.playing)
        await settle()
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(ready.first?.0, next.id)
        XCTAssertEqual(ready.first?.1, session.controller.generation)

        engine.onPhase?(.playing)
        await settle()
        XCTAssertEqual(ready.count, 1, "Repeated ready callbacks for one generation must not be reported twice")
        session.stop()
    }

    func testSystemInterruptionResumesOnlyPreviousPlaybackAndPiPPlayCanRecoverSameEngine() async {
        let engine = LiveTVTestEngine()
        let session = makeSession(engine)
        let channel = LiveTVChannel(id: "interrupt", guideID: nil, name: "Interrupt",
            streamURL: URL(string: "https://fixture.invalid/interrupt.ts")!, logoURL: nil, category: "News")
        session.play(channel)
        await settle()
        let generation = session.controller.generation
        session.controller.phaseChanged(.playing, generation: generation)

        session.controller.pauseForSystemInterruption()
        XCTAssertEqual(session.state, .paused)
        session.controller.resumeAfterSystemInterruption()
        XCTAssertEqual(engine.resumeCount, 1, "A permitted interruption end resumes the existing engine")
        XCTAssertEqual(session.state, .playing)

        session.controller.pauseForSystemInterruption()
        session.controller.phaseChanged(.playing, generation: generation)
        XCTAssertEqual(session.state, .playing, "PiP Play may recover after an interruption with no ended event")
        XCTAssertEqual(engine.loads.count, 1, "Recovery must not replace the player or restart the stream")

        session.controller.togglePlayback()
        session.controller.phaseChanged(.playing, generation: generation)
        XCTAssertEqual(session.state, .paused, "An intentional pause still wins over engine playback")
        XCTAssertGreaterThan(engine.pauseCount, 0)
        session.stop()
    }

    // MARK: Picture in Picture transport

    private let windowChannel = LiveTVChannel(id: "window", guideID: nil, name: "Window",
        streamURL: URL(string: "https://fixture.invalid/window.ts")!, logoURL: nil, category: "News")

    private func makeWindowSession(_ engine: LiveTVTestEngine, _ window: PictureInPictureWindowStub)
        async -> LiveTVPlayerSession {
        let session = LiveTVPlayerSession(scheduler: LiveTVTestScheduler(), makeEngine: { engine },
                                          isOtherVideoActive: { false },
                                          isOwnPictureInPictureEngaged: { window.isEngaged })
        session.play(windowChannel)
        await settle()
        engine.onPhase?(.playing)
        await settle()
        XCTAssertEqual(session.state, .playing)
        return session
    }

    /// Build 21: PiP Play reaches the engine directly. After a pause made in the window the
    /// controller took that motion for the engine resuming itself and paused it again.
    func testPiPPlayAfterAPauseInTheWindowResumesTheSameStream() async {
        let engine = LiveTVTestEngine()
        let window = PictureInPictureWindowStub()
        let session = await makeWindowSession(engine, window)
        window.isEngaged = true

        engine.onPhase?(.paused) // PiP Pause
        await settle()
        XCTAssertEqual(session.state, .paused)
        let pauses = engine.pauseCount

        engine.onPhase?(.playing) // PiP Play
        await settle()
        XCTAssertEqual(session.state, .playing)
        XCTAssertEqual(engine.pauseCount, pauses, "Nothing pauses the window's Play again")
        XCTAssertEqual(engine.loads.count, 1, "The same stream resumes, without a reload")
        XCTAssertEqual(engine.resumeCount, 0, "AVKit already resumed the engine; Live TV adds no second play")
        session.stop()
    }

    func testPiPPlayAfterAPauseMadeInTheAppResumes() async {
        let engine = LiveTVTestEngine()
        let window = PictureInPictureWindowStub()
        let session = await makeWindowSession(engine, window)
        window.isEngaged = true

        session.togglePlayback()
        XCTAssertEqual(session.state, .paused)
        engine.onPhase?(.playing)
        await settle()
        XCTAssertEqual(session.state, .playing)
        session.stop()
    }

    func testPiPPlayAfterAnInterruptionResumesWithoutAnEndedEvent() async {
        let engine = LiveTVTestEngine()
        let window = PictureInPictureWindowStub()
        let session = await makeWindowSession(engine, window)
        window.isEngaged = true

        engine.onSystemInterruption?()
        await settle()
        XCTAssertEqual(session.state, .paused)
        engine.onPhase?(.playing)
        await settle()
        XCTAssertEqual(session.state, .playing)
        XCTAssertEqual(engine.loads.count, 1)
        session.stop()
    }

    func testAPauseInTheWindowIsTheViewersAndAnInterruptionEndDoesNotUndoIt() async {
        let engine = LiveTVTestEngine()
        let window = PictureInPictureWindowStub()
        let session = await makeWindowSession(engine, window)
        window.isEngaged = true

        engine.onPhase?(.paused) // PiP Pause
        await settle()
        engine.onSystemInterruption?()
        engine.onSystemInterruptionEnded?() // .shouldResume
        await settle()
        XCTAssertEqual(session.state, .paused)
        XCTAssertEqual(engine.resumeCount, 0)
        session.stop()
    }

    func testOnceTheWindowClosesTheViewersPauseWinsOverEngineMotionAgain() async {
        let engine = LiveTVTestEngine()
        let window = PictureInPictureWindowStub()
        let session = await makeWindowSession(engine, window)

        session.togglePlayback()
        let pauses = engine.pauseCount
        engine.onPhase?(.playing) // no window: an engine resuming on its own
        await settle()
        XCTAssertEqual(session.state, .paused)
        XCTAssertGreaterThan(engine.pauseCount, pauses)
        session.stop()
    }

    func testRouteLossDoesNotAutomaticallyResumeAndManualPauseCannotArmResume() {
        let engine = LiveTVTestEngine()
        let session = makeSession(engine)
        let channel = LiveTVChannel(id: "route", guideID: nil, name: "Route",
            streamURL: URL(string: "https://fixture.invalid/route.ts")!, logoURL: nil, category: "News")
        session.play(channel)
        let generation = session.controller.generation
        session.controller.phaseChanged(.playing, generation: generation)
        session.controller.pauseForSystemInterruption(canResumeAutomatically: false)
        session.controller.resumeAfterSystemInterruption()
        XCTAssertEqual(engine.resumeCount, 0)

        session.controller.togglePlayback() // viewer explicitly resumes
        session.controller.togglePlayback() // viewer explicitly pauses
        session.controller.resumeAfterSystemInterruption()
        XCTAssertEqual(session.state, .paused)
        session.stop()
    }

    func testFailedStartupNeverEmitsPlayingReady() async {
        let engine = LiveTVTestEngine()
        let session = makeSession(engine)
        let channel = LiveTVChannel(id: "candidate", guideID: nil, name: "Candidate",
            streamURL: URL(string: "https://fixture.invalid/candidate.ts")!, logoURL: nil, category: "News")
        var readyCount = 0
        session.onPlayingReady = { _, _ in readyCount += 1 }

        session.play(channel)
        engine.onPhase?(.failed(.network, detail: nil))
        await settle()
        XCTAssertEqual(readyCount, 0)
        XCTAssertEqual(session.state, .failed)
        session.stop()
    }

    func testCancelledStartupAndLatePlayingEventNeverEmitPlayingReady() async {
        let engine = LiveTVTestEngine()
        let session = makeSession(engine)
        let channel = LiveTVChannel(id: "candidate", guideID: nil, name: "Candidate",
            streamURL: URL(string: "https://fixture.invalid/candidate.ts")!, logoURL: nil, category: "News")
        var readyCount = 0
        session.onPlayingReady = { _, _ in readyCount += 1 }

        session.play(channel)
        session.stop()
        engine.onPhase?(.playing)
        await settle()
        XCTAssertEqual(readyCount, 0)
    }

    func testLiveAudioClaimTracksActiveSessionWithoutChangingAudioPolicy() {
        var liveTVIsActive = true
        let liveTVClaim = AetherAudioSessionOwnership.Claim(isHoldingAudio: { liveTVIsActive })
        XCTAssertFalse(AetherAudioSessionOwnership.mayDeactivateSharedSession(otherOwnersHoldingAudio: [liveTVIsActive]))
        liveTVIsActive = false
        XCTAssertTrue(AetherAudioSessionOwnership.mayDeactivateSharedSession(otherOwnersHoldingAudio: [liveTVIsActive]))
        withExtendedLifetime(liveTVClaim) {}
    }

    func testLivePlaybackFailuresClassifyEngineKindsWithoutCodecClaims() {
        XCTAssertEqual(LiveTVPlaybackFailure.classify(domain: "AVFoundationErrorDomain", code: -11828), .itemFailure)
        XCTAssertEqual(LiveTVPlaybackFailure.classify(domain: "PrivateProvider", code: -1), .unknown)
        XCTAssertEqual(LiveTVPlaybackFailure.classifyEngine(kind: "sourceRefused", code: 403), .refused)
        XCTAssertEqual(LiveTVPlaybackFailure.classifyEngine(kind: "sourceRateLimited", code: 509), .rateLimited)
        XCTAssertEqual(LiveTVPlaybackFailure.classifyEngine(kind: "unheardOf", code: nil), .unknown)
        XCTAssertNil(LiveTVPlaybackFailure.diagnosticDetail(kind: "https://user:pass@host/live", code: 1))
        XCTAssertFalse(LiveTVPlaybackFailure.itemFailure.message.localizedCaseInsensitiveContains("codec"))
        XCTAssertEqual(LiveTVPlaybackController.stallTimeoutSeconds, 30)
        XCTAssertEqual(LiveTVPlaybackController.startupTimeoutSeconds, 30)
    }

    func testControlsHideOnlyWhilePlayingWithoutOverlayAndCancelOnClose() {
        let controls = LiveTVControlsVisibility(scheduler: LiveTVTestScheduler())
        XCTAssertTrue(controls.isVisible)
        for state in [LiveTVPlaybackState.connecting, .buffering, .paused, .failed] {
            controls.update(state: state, isOverlayPresented: false)
            XCTAssertTrue(controls.isVisible)
            XCTAssertFalse(controls.isHideTimerArmed)
        }
        controls.update(state: .playing, isOverlayPresented: true)
        XCTAssertFalse(controls.isHideTimerArmed)
        controls.update(state: .playing, isOverlayPresented: false)
        XCTAssertTrue(controls.isHideTimerArmed)
        controls.toggle()
        XCTAssertFalse(controls.isVisible)
        controls.toggle()
        XCTAssertTrue(controls.isVisible)
        controls.cancel()
        XCTAssertFalse(controls.isHideTimerArmed)
        controls.interact()
        XCTAssertFalse(controls.isHideTimerArmed)
    }

    func testLiveTVOrientationPolicyAllowsBothLandscapeSidesAndRestoresPortraitBrowsing() {
        var state = PlayerRotationState()
        state.activate()
        XCTAssertTrue(state.isPlayerActive)
        XCTAssertEqual(PlayerOrientationCoordinator.geometryMask(
            isPlayerActive: state.isPlayerActive, preferredOrientation: UIInterfaceOrientationMask.landscape
        ), .landscape)
        XCTAssertEqual(PlayerScreenOrientation.portrait.toggled, .landscape)
        XCTAssertEqual(PlayerScreenOrientation.landscape.toggled, .portrait)
        state.deactivate()
        XCTAssertFalse(state.isPlayerActive)
        XCTAssertEqual(PlayerOrientationCoordinator.orientationMask(
            isPlayerActive: state.isPlayerActive, browsingOrientations: .portrait
        ), .portrait)
    }

    func testXtreamAccountValidationCategoriesAndStreams() throws {
        try XtreamResponseParser.account(from: Data(#"{"user_info":{"auth":1,"status":"Active","exp_date":"0"}}"#.utf8))
        XCTAssertThrowsError(try XtreamResponseParser.account(from: Data(#"{"user_info":{"auth":0,"status":"Disabled"}}"#.utf8))) { error in
            XCTAssertEqual(error as? LiveTVError, .authenticationFailed)
        }
        let expired = Data(#"{"user_info":{"auth":1,"status":"Expired","exp_date":"1"}}"#.utf8)
        XCTAssertThrowsError(try XtreamResponseParser.account(from: expired)) { error in
            XCTAssertEqual(error as? LiveTVError, .accountExpired)
        }
        let categories = try XtreamResponseParser.categories(from: Data(#"[{"category_id":"3","category_name":"News"}]"#.utf8))
        XCTAssertEqual(categories.first?.categoryID, "3")
        XCTAssertEqual(categories.first?.categoryName, "News")
        let streams = try XtreamResponseParser.streams(from: Data(#"[{"stream_id":42,"name":"World News","stream_icon":"https://logo.example.test/a.png","category_id":"3","epg_channel_id":"world.news","container_extension":"m3u8"}]"#.utf8))
        XCTAssertEqual(streams.first?.streamID, 42)
        XCTAssertEqual(streams.first?.epgChannelID, "world.news")
        XCTAssertThrowsError(try XtreamResponseParser.streams(from: Data("not json".utf8)))
    }

    func testXtreamAdvertisedFormatsAreParsedPersistedAndMalformedValuesIgnored() throws {
        let hls = try XtreamResponseParser.account(from: Data(#"{"user_info":{"auth":1,"allowed_output_formats":["TS","m3u8","unsupported"]}}"#.utf8))
        XCTAssertEqual(hls, ["m3u8", "ts"])
        let missing = try XtreamResponseParser.account(from: Data(#"{"user_info":{"auth":1}}"#.utf8))
        XCTAssertEqual(missing, [])
        let malformed = try XtreamResponseParser.account(from: Data(#"{"user_info":{"auth":1,"allowed_output_formats":"m3u8"}}"#.utf8))
        XCTAssertEqual(malformed, [])
        let provider = LiveTVProvider(id: UUID(), name: "Xtream", channelCount: 0, lastRefreshed: nil,
                                      kind: .xtream, allowedOutputFormats: hls)
        let encoded = try JSONEncoder().encode(provider)
        let decoded = try JSONDecoder().decode(LiveTVProvider.self, from: encoded)
        XCTAssertEqual(decoded.allowedOutputFormats, ["m3u8", "ts"])
    }

    func testXtreamUsesHLSOnlyWhenProviderAdvertisesIt() throws {
        let hls = try XtreamURLBuilder.streamURL(server: "https://example.test:9443/base", username: "u", password: "p",
                                                  streamID: 9, extension: "ts", allowedOutputFormats: ["m3u8"])
        XCTAssertEqual(hls.path, "/base/live/u/p/9.m3u8")
        let ts = try XtreamURLBuilder.streamURL(server: "https://example.test/base", username: "u", password: "p",
                                                 streamID: 9, extension: "ts", allowedOutputFormats: [])
        XCTAssertEqual(ts.path, "/base/live/u/p/9.ts")
        let malformed = try XtreamURLBuilder.streamURL(server: "https://example.test/base", username: "u", password: "p",
                                                        streamID: 9, extension: "ts", allowedOutputFormats: ["m3u8;bad"])
        XCTAssertEqual(malformed.path, "/base/live/u/p/9.ts")
        let both = try XtreamURLBuilder.streamURL(server: "https://example.test", username: "u", password: "p",
                                                   streamID: 9, extension: nil, allowedOutputFormats: ["m3u8", "ts"])
        XCTAssertEqual(both.path, "/live/u/p/9.ts")
        let tsOnly = try XtreamURLBuilder.streamURL(server: "https://example.test", username: "u", password: "p",
                                                     streamID: 9, extension: "m3u8", allowedOutputFormats: ["ts"])
        XCTAssertEqual(tsOnly.path, "/live/u/p/9.ts")
        let unspecified = try XtreamURLBuilder.streamURL(server: "https://example.test", username: "u", password: "p",
                                                          streamID: 9, extension: "m3u8", allowedOutputFormats: [])
        XCTAssertEqual(unspecified.path, "/live/u/p/9.ts")
    }

    func testPlaybackFailureClassificationDoesNotExposeUnderlyingText() {
        XCTAssertEqual(LiveTVPlaybackFailure.classify(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue), .timeout)
        XCTAssertEqual(LiveTVPlaybackFailure.classify(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue), .network)
        XCTAssertEqual(LiveTVPlaybackFailure.classify(domain: NSURLErrorDomain, code: URLError.userAuthenticationRequired.rawValue), .authentication)
        XCTAssertEqual(LiveTVPlaybackFailure.classify(domain: "AVFoundationErrorDomain", code: -11828), .itemFailure)
        XCTAssertEqual(LiveTVPlaybackFailure.classify(domain: "PrivateProvider", code: -1), .unknown)
        XCTAssertFalse(LiveTVPlaybackFailure.unknown.message.contains("http"))
    }

    func testXtreamURLsPreserveSchemePortAndBasePathAndEncodeCredentials() throws {
        let api = try XtreamURLBuilder.apiURL(server: "http://provider.example.test:8088/edge/", username: "user name",
                                              password: "p@ss/word", action: "get_live_streams")
        XCTAssertEqual(api.scheme, "http")
        XCTAssertEqual(api.host, "provider.example.test")
        XCTAssertEqual(api.port, 8088)
        XCTAssertEqual(api.path, "/edge/player_api.php")
        let apiComponents = try XCTUnwrap(URLComponents(url: api, resolvingAgainstBaseURL: false))
        XCTAssertTrue(apiComponents.queryItems?.contains(URLQueryItem(name: "action", value: "get_live_streams")) == true)
        XCTAssertTrue(api.absoluteString.contains("user%20name"))
        let stream = try XtreamURLBuilder.streamURL(server: "https://provider.example.test:9443/base",
                                                    username: "a/b", password: "c?d", streamID: 17, extension: "m3u8",
                                                    allowedOutputFormats: ["m3u8"])
        XCTAssertEqual(stream.scheme, "https")
        XCTAssertEqual(stream.port, 9443)
        XCTAssertTrue(stream.absoluteString.contains("/base/live/a%2Fb/c%3Fd/17.m3u8"))
        XCTAssertFalse(stream.absoluteString.contains("?"))
    }

    func testXtreamCredentialsAreKeychainOnlyAndProviderTypesHaveSeparateIdentities() throws {
        let suiteName = "LiveTVXtreamTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secrets = MemoryLiveTVSecretStore()
        let service = LiveTVService(defaults: defaults, secretStore: secrets,
                                    epg: EPGService(cache: nil, loader: URLSessionEPGFeedLoader.makeDefault(),
                                                    fingerprinter: .inMemory()))
        let m3uID = try service.saveConfiguration(name: "M3U", playlistURL: "https://example.test/list.m3u", xmltvURL: nil)
        let password = "private-Xtream-pass"
        let xtreamID = try service.saveXtreamConfiguration(name: "Xtream", serverURL: "http://example.test:8080/base",
                                                           username: "private-user", password: password)
        XCTAssertNotEqual(m3uID, xtreamID)
        XCTAssertEqual(service.providers.map(\.kind), [.m3u, .xtream])
        let metadata = try XCTUnwrap(String(data: XCTUnwrap(defaults.data(forKey: "liveTV.providers.v1")), encoding: .utf8))
        XCTAssertFalse(metadata.contains(password))
        XCTAssertFalse(metadata.contains("private-user"))
        let stored = try XCTUnwrap(secrets.values["provider.\(xtreamID.uuidString)"])
        XCTAssertTrue(stored.contains(password))
        XCTAssertTrue(stored.contains("private-user"))
        service.selectProvider(m3uID)
        XCTAssertEqual(service.selectedProvider?.kind, .m3u)
        service.selectProvider(xtreamID)
        XCTAssertEqual(service.selectedProvider?.kind, .xtream)
    }

    func testExistingProviderMetadataWithoutKindMigratesAsM3U() throws {
        let id = UUID()
        let legacy = Data("{\"id\":\"\(id.uuidString)\",\"name\":\"Legacy Playlist\",\"channelCount\":12,\"lastRefreshed\":null}".utf8)
        let provider = try JSONDecoder().decode(LiveTVProvider.self, from: legacy)
        XCTAssertEqual(provider.id, id)
        XCTAssertEqual(provider.name, "Legacy Playlist")
        XCTAssertEqual(provider.channelCount, 12)
        XCTAssertEqual(provider.kind, .m3u)
    }
}

@MainActor
private final class MemoryLiveTVSecretStore: LiveTVSecretStore {
    var values: [String: String] = [:]
    func read(account: String) -> String? { values[account] }
    func save(_ value: String, account: String) -> Bool { values[account] = value; return true }
    func remove(account: String) -> Bool { values.removeValue(forKey: account) != nil }
}

@MainActor
private final class LiveTVTestEngine: LiveTVEngineDriving {
    var onPhase: ((LiveTVEnginePhase) -> Void)?
    var onLiveSourceReset: (() -> Void)?
    var onSystemInterruption: (() -> Void)?
    var onSystemInterruptionEnded: (() -> Void)?
    var onAudioRouteLost: (() -> Void)?
    private(set) var loads: [URL] = []
    private(set) var finalStops = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    func load(_ url: URL, route: LiveTVStreamRoute) async throws { loads.append(url) }
    func recoverLiveSource() -> Bool { true }
    func play() { resumeCount += 1 }
    func pause() { pauseCount += 1 }
    func stop(final: Bool, releaseAudioSession: Bool) { if final { finalStops += 1 } }
}

/// Whether Live TV's own Picture in Picture window holds the stream.
@MainActor
private final class PictureInPictureWindowStub {
    var isEngaged = false
}

@MainActor
private final class LiveTVTestScheduler: LiveTVScheduling {
    var now: Double { 0 }
    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) -> LiveTVTimerHandle {
        LiveTVTimerHandle {}
    }
}

/// Holds the search model's text-input delay so tests can see the scheduled duration without waiting on a clock.
@MainActor
private final class TextInputDelayGate {
    var hold: Bool
    private(set) var delays: [Duration] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var entryTarget = 1

    init(hold: Bool) {
        self.hold = hold
    }

    func install(on search: LiveTVChannelSearchModel) {
        search.waitForTextInput = { [weak self] duration in
            guard let self else { return }
            self.delays.append(duration)
            if self.delays.count >= self.entryTarget {
                self.entryWaiter?.resume()
                self.entryWaiter = nil
            }
            guard self.hold else { return }
            await withCheckedContinuation { continuation in
                self.continuations.append(continuation)
            }
        }
    }

    func waitUntilEntered(count: Int = 1) async {
        entryTarget = count
        if delays.count >= count { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}
