import SwiftUI
import UIKit
import XCTest
@testable import Silo

final class LiveTVHomeLayoutTests: XCTestCase {
    private func channel(_ name: String, provider: UUID, category: String = "News",
                         stream: String = "https://stream.test/live") -> LiveTVChannel {
        LiveTVChannel(id: "\(provider.uuidString):\(name)", guideID: nil, name: name,
                      streamURL: URL(string: stream)!, logoURL: nil, category: category)
    }

    func testRecentHistorySplitsIntoContinueWatchingAndRecentlyWatchedWithoutRepeats() {
        let provider = UUID()
        let recents = (1...12).map { channel("R\($0)", provider: provider) }
        let sections = LiveTVHomeSections(recents: recents, favorites: [], isPlayable: { _ in true })

        XCTAssertEqual(sections.continueWatching.map(\.channel.name), ["R1", "R2", "R3"])
        XCTAssertEqual(sections.recentlyWatched.map(\.channel.name), ["R4", "R5", "R6", "R7", "R8", "R9", "R10"],
                       "older recents keep history order and stop at the existing ten-channel Home limit")
        XCTAssertTrue(Set(sections.continueWatching.map(\.id)).isDisjoint(with: sections.recentlyWatched.map(\.id)))

        let short = LiveTVHomeSections(recents: Array(recents.prefix(2)), favorites: [], isPlayable: { _ in true })
        XCTAssertEqual(short.continueWatching.map(\.channel.name), ["R1", "R2"])
        XCTAssertTrue(short.recentlyWatched.isEmpty, "three or fewer recents leave Recently Watched hidden")
    }

    func testFeaturedChannelsAreProviderScopedPlayableAndBounded() {
        let active = UUID()
        let other = UUID()
        let recents = [channel("Recent A", provider: active), channel("Shared", provider: active),
                       channel("Broken", provider: active, stream: "rtmp://stream.test/live")]
        let favorites = [channel("Shared", provider: active)] + (1...6).map { channel("Fav\($0)", provider: active) }
        let foreign = channel("Elsewhere", provider: other)
        let records = (recents + [foreign]).compactMap {
            LiveTVRecentChannel(providerID: UUID(uuidString: String($0.id.prefix(36)))!, channelID: $0.id)
        }
        let preview = LiveTVHomeChannelPreview.resolve(catalog: recents + favorites.dropFirst() + [foreign],
                                                       favoriteIDs: Set((favorites + [foreign]).map(\.id)),
                                                       recentRecords: records, providerID: active)
        let sections = LiveTVHomeSections(recents: preview.recents, favorites: preview.favorites,
                                          isPlayable: { $0.streamURL.scheme == "https" })

        XCTAssertEqual(sections.featured.map(\.channel.name), ["Recent A", "Shared", "Fav1", "Fav2", "Fav3", "Fav4"],
                       "recents lead, a channel in both lists appears once, unplayable channels are skipped")
        XCTAssertEqual(sections.featured.count, LiveTVHomeSections.featuredLimit)
        XCTAssertFalse(sections.featured.contains { $0.channel.id == foreign.id })
        XCTAssertFalse(sections.lineup.contains { $0.channel.id == foreign.id })
        XCTAssertTrue(sections.featured.allSatisfy { $0.artworkURL == nil }, "no artwork until the guide carries it")
    }

    func testCategorySymbolsFollowKeywordsInOrder() {
        XCTAssertEqual(LiveTVCategorySymbol.symbol(for: "SPORTS"), "sportscourt.fill")
        XCTAssertEqual(LiveTVCategorySymbol.symbol(for: "USA | ESPN News"), "sportscourt.fill",
                       "the first matching rule wins")
        XCTAssertEqual(LiveTVCategorySymbol.symbol(for: "World News"), "newspaper.fill")
        XCTAssertEqual(LiveTVCategorySymbol.symbol(for: "Movies HD"), "film.fill")
        XCTAssertEqual(LiveTVCategorySymbol.symbol(for: "Kids & Family"), "figure.and.child.holdinghands")
        XCTAssertEqual(LiveTVCategorySymbol.symbol(for: "Documentaries"), "globe.americas.fill")
        XCTAssertEqual(LiveTVCategorySymbol.symbol(for: "VIP Ultra 4K"), LiveTVCategorySymbol.fallback)
        for symbol in LiveTVCategorySymbol.allSymbols {
            XCTAssertNotNil(UIImage(systemName: symbol), "\(symbol) is not an SF Symbol on this OS")
        }
    }

    func testLogoSamplingIgnoresClearAndNeutralPixelsAndFallbackIsStable() {
        let white: [UInt8] = [255, 255, 255, 255]
        let clear: [UInt8] = [200, 0, 0, 0]
        let red: [UInt8] = [220, 20, 30, 255]
        XCTAssertNil(LiveTVBrandColor.sample(rgba: Array([[UInt8]](repeating: white, count: 40).joined())
                                                 + Array([[UInt8]](repeating: clear, count: 60).joined())),
                     "a white wordmark on a transparent background has no brand hue")
        let sampled = LiveTVBrandColor.sample(rgba: Array([[UInt8]](repeating: red, count: 30).joined())
                                                  + Array([[UInt8]](repeating: white, count: 70).joined()))
        guard let color = sampled else { return XCTFail("a red logo should give a red brand color") }
        XCTAssertGreaterThan(color.r, color.g * 3)
        XCTAssertLessThanOrEqual(max(color.r, color.g, color.b), 0.781, "held below highlight brightness")

        XCTAssertEqual(LiveTVBrandColor.fallback(for: "Channel One"), LiveTVBrandColor.fallback(for: "channel one"))
        XCTAssertTrue(LiveTVBrandColor.palette.contains(LiveTVBrandColor.fallback(for: "Channel One")))
    }

    func testCarouselNeverRotatesWithZeroOrOneCandidate() {
        for count in [0, 1] {
            XCTAssertFalse(LiveTVHomeCarouselPolicy.shouldRotate(candidateCount: count, enabled: true, visible: true,
                                                                  interacting: false, infoPresented: false,
                                                                  reduceMotion: false, voiceOver: false))
        }
        XCTAssertNil(LiveTVHomeCarouselPolicy.page(after: nil, in: []))
        XCTAssertNil(LiveTVHomeCarouselPolicy.page(after: "a", in: ["a"]), "a single hero stays static")
    }

    func testCarouselRotationPausesForEverySafetyCondition() {
        func rotates(enabled: Bool = true, visible: Bool = true, interacting: Bool = false, info: Bool = false,
                     reduceMotion: Bool = false, voiceOver: Bool = false) -> Bool {
            LiveTVHomeCarouselPolicy.shouldRotate(candidateCount: 6, enabled: enabled, visible: visible,
                                                  interacting: interacting, infoPresented: info,
                                                  reduceMotion: reduceMotion, voiceOver: voiceOver)
        }
        XCTAssertTrue(rotates())
        XCTAssertFalse(rotates(enabled: false), "background, browser, Guide, Settings, player or PiP")
        XCTAssertFalse(rotates(visible: false), "hero mostly offscreen")
        XCTAssertFalse(rotates(interacting: true), "finger on the carousel or a fling settling")
        XCTAssertFalse(rotates(info: true), "Channel Info open")
        XCTAssertFalse(rotates(reduceMotion: true))
        XCTAssertFalse(rotates(voiceOver: true))
    }

    func testOnlyUserScrollPhasesPauseRotation() {
        XCTAssertTrue(LiveTVHomeCarouselPolicy.isUserScroll(.tracking))
        XCTAssertTrue(LiveTVHomeCarouselPolicy.isUserScroll(.interacting))
        XCTAssertTrue(LiveTVHomeCarouselPolicy.isUserScroll(.decelerating))
        XCTAssertFalse(LiveTVHomeCarouselPolicy.isUserScroll(.animating),
                       "an automatic page change must not count as interaction, or rotation would stall")
        XCTAssertFalse(LiveTVHomeCarouselPolicy.isUserScroll(.idle))
    }

    func testAutomaticAdvanceWrapsAndRestartsTheWaitOncePerPage() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(LiveTVHomeCarouselPolicy.page(after: nil, in: ids), "b", "an unscrolled carousel is on the first page")
        XCTAssertEqual(LiveTVHomeCarouselPolicy.page(after: "b", in: ids), "c")
        XCTAssertEqual(LiveTVHomeCarouselPolicy.page(after: "c", in: ids), "a")
        XCTAssertEqual(LiveTVHomeCarouselPolicy.page(after: "gone", in: ids), "b")
        let before = LiveTVHomeCarouselPolicy.TimerKey(rotating: true, page: "a", ids: ids)
        XCTAssertNotEqual(before, LiveTVHomeCarouselPolicy.TimerKey(rotating: true, page: "b", ids: ids),
                          "a page change, automatic or manual, starts a fresh seven-second wait")
        XCTAssertEqual(before, LiveTVHomeCarouselPolicy.TimerKey(rotating: true, page: "a", ids: ids),
                       "an unrelated redraw does not reset the wait")
    }

    func testSelectionSurvivesReorderingAndStartsOverForANewProvider() {
        let first = UUID(), second = UUID()
        let old = ["\(first):A", "\(first):B", "\(first):C"]
        XCTAssertEqual(LiveTVHomeCarouselPolicy.selection(keeping: old[2], in: [old[2], old[0], old[1]]), old[2],
                       "watching a featured channel reorders the list without jumping pages")
        XCTAssertEqual(LiveTVHomeCarouselPolicy.selection(keeping: old[1], in: [old[0], old[2]]), old[0])
        XCTAssertEqual(LiveTVHomeCarouselPolicy.selection(keeping: old[1], in: ["\(second):X", "\(second):Y"]),
                       "\(second):X", "another provider's channels never inherit a page")
        XCTAssertNil(LiveTVHomeCarouselPolicy.selection(keeping: old[0], in: []))
    }

    func testChannelInfoShowsOnlyGenuineGuideText() {
        let provider = UUID()
        let infoChannel = channel("Info", provider: provider)
        func program(_ title: String, summary: String?) -> LiveTVProgram {
            LiveTVProgram(id: title, channelID: infoChannel.id, title: title, startsAt: .now, endsAt: .now.addingTimeInterval(1800),
                          summary: summary)
        }
        let empty = LiveTVChannelInfo(channel: infoChannel, programs: LiveTVProgramPair(current: nil, next: nil))
        XCTAssertFalse(empty.hasGuide, "no guide data shows the fallback message")
        XCTAssertNil(empty.summary)
        let nextOnly = LiveTVChannelInfo(channel: infoChannel,
                                         programs: LiveTVProgramPair(current: nil, next: program("Later", summary: "Soon.")))
        XCTAssertTrue(nextOnly.hasGuide)
        XCTAssertNil(nextOnly.summary, "the summary belongs to the airing program only")
        let blank = LiveTVChannelInfo(channel: infoChannel,
                                      programs: LiveTVProgramPair(current: program("Now", summary: " \n "), next: nil))
        XCTAssertNil(blank.summary)
        let real = LiveTVChannelInfo(channel: infoChannel,
                                     programs: LiveTVProgramPair(current: program("Now", summary: "  Genuine summary. "), next: nil))
        XCTAssertEqual(real.summary, "Genuine summary.")
    }

    func testProgramTimesNeverShowDatesAcrossMidnight() {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 23, minute: 30))!
        let program = LiveTVProgram(id: "late", channelID: "c", title: "Late", startsAt: start,
                                    endsAt: start.addingTimeInterval(60 * 60))
        let text = LiveTVHomeText.timeRange(program)
        XCTAssertFalse(text.contains("2026"), "got \(text)")
        XCTAssertFalse(text.contains("31"), "got \(text)")
    }

    func testDarkCutOutLogosGetAPlateAndOtherLogosDoNot() {
        func image(_ pixel: [UInt8], count: Int, clear: Int) -> [UInt8] {
            Array([[UInt8]](repeating: pixel, count: count).joined()) + Array([[UInt8]](repeating: [0, 0, 0, 0], count: clear).joined())
        }
        XCTAssertTrue(LiveTVBrandColor.hasDarkMark(rgba: image([20, 20, 24, 255], count: 40, clear: 60)))
        XCTAssertFalse(LiveTVBrandColor.hasDarkMark(rgba: image([250, 250, 250, 255], count: 40, clear: 60)),
                       "a white wordmark already reads on a dark card")
        XCTAssertFalse(LiveTVBrandColor.hasDarkMark(rgba: image([20, 20, 24, 255], count: 100, clear: 0)),
                       "an opaque logo brings its own background")
        XCTAssertFalse(LiveTVBrandColor.hasDarkMark(rgba: []))
    }
}

#if DEBUG
/// Writes fixture renders of the Home and Channel Info for visual review. Skipped unless
/// `TEST_RUNNER_KYRO_HOME_RENDER_DIR` names an output folder. Fictional channels only.
@MainActor
final class LiveTVHomeRenderCheck: XCTestCase {
    private let provider = LiveTVProvider(id: UUID(), name: "Fixture IPTV", channelCount: 20_000, lastRefreshed: nil)

    private func fixture(_ name: String, _ category: String) -> LiveTVChannel {
        LiveTVChannel(id: "\(provider.id.uuidString):\(name)", guideID: nil, name: name,
                      streamURL: URL(string: "https://stream.test/\(name.replacingOccurrences(of: " ", with: "-"))")!,
                      logoURL: nil, category: category)
    }

    private func program(_ title: String, for channel: LiveTVChannel, offset: TimeInterval = 0,
                         summary: String? = nil) -> LiveTVProgram {
        let start = Date().addingTimeInterval(offset - 25 * 60)
        return LiveTVProgram(id: "\(channel.id):\(title)", channelID: channel.id, title: title, startsAt: start,
                             endsAt: start.addingTimeInterval(60 * 60), summary: summary)
    }

    private func epgProgram(_ title: String, for channel: LiveTVChannel, offset: TimeInterval = 0) -> EPGProgram {
        let start = Date().addingTimeInterval(offset - 25 * 60)
        return EPGProgram(channelID: channel.id, start: start, end: start.addingTimeInterval(60 * 60), title: title)
    }

    private func outputDirectory() throws -> URL {
        guard let directory = ProcessInfo.processInfo.environment["KYRO_HOME_RENDER_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_KYRO_HOME_RENDER_DIR to render the Home fixtures.")
        }
        return URL(fileURLWithPath: directory)
    }

    func testRenderFixtureHome() throws {
        let directory = try outputDirectory()
        let recents = [fixture("Sports One", "Sports"), fixture("City News", "News"), fixture("Classic Films", "Movies"),
                       fixture("Cartoon Hub", "Kids"), fixture("Nature World", "Documentary"), fixture("Comedy Max", "Entertainment")]
        let favorites = [fixture("Sports One", "Sports"), fixture("Metro 24", "News"), fixture("Arena Two", "Sports"),
                         fixture("Prime Drama", "Entertainment"), fixture("Tunes", "Music")]
        let titles = ["Sports One": "Evening Highlights", "City News": "Nightly Report", "Classic Films": "Feature Presentation"]
        let epg = LiveTVHomeEPG { [self] channel, _ in titles[channel.name].map { program($0, for: channel) } }
        let upNext = [
            LiveTVUpNextItem(channel: favorites[1], program: epgProgram("The Daily Brief", for: favorites[1], offset: 30 * 60)),
            LiveTVUpNextItem(channel: favorites[2], program: epgProgram("Championship Live", for: favorites[2], offset: 90 * 60)),
            LiveTVUpNextItem(channel: favorites[3], program: epgProgram("After Hours", for: favorites[3], offset: 150 * 60)),
            LiveTVUpNextItem(channel: favorites[4], program: epgProgram("Tonight in Sound", for: favorites[4], offset: 210 * 60))
        ]
        let model = LiveTVHomeModel(providers: [provider], selectedProviderID: provider.id, channelCount: 20_000,
                                    contentState: .ready,
                                    sections: LiveTVHomeSections(recents: recents, favorites: favorites, isPlayable: { _ in true }),
                                    upNext: upNext,
                                    categories: ["Sports", "News", "Movies", "Kids", "Documentary", "Music"],
                                    carouselEnabled: false)
        func home(_ size: DynamicTypeSize) -> some View {
            NavigationStack {
                LiveTVHomeContent(model: model, epg: epg, actions: LiveTVHomeActions())
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        LiveTVHomeToolbar(back: {}, backLabel: "Back", search: {}, guide: {}, settings: {})
                    }
            }
            .dynamicTypeSize(size)
        }
        try render(home(.large), size: CGSize(width: 430, height: 1700), to: directory.appendingPathComponent("home-fixture.png"))
        try render(home(.accessibility2), size: CGSize(width: 430, height: 1100),
                   to: directory.appendingPathComponent("home-fixture-ax2.png"))
    }

    func testRenderFixtureChannelInfo() throws {
        let directory = try outputDirectory()
        let channel = fixture("Sports One", "Sports")
        let withGuide = LiveTVChannelInfo(channel: channel, programs: LiveTVProgramPair(
            current: program("Evening Highlights", for: channel,
                             summary: "Fictional fixture summary used only to check wrapping and spacing in the sheet."),
            next: program("Late Night Recap", for: channel, offset: 60 * 60)))
        let longDescription = LiveTVChannelInfo(channel: channel, programs: LiveTVProgramPair(
            current: program("Evening Highlights", for: channel, summary: String(repeating:
                "A longer fictional guide description verifies that the Channel Info sheet remains scrollable and keeps both actions reachable. ", count: 5)),
            next: program("Late Night Recap", for: channel, offset: 60 * 60)))
        let noGuide = LiveTVChannelInfo(channel: fixture("Metro 24", "News"), programs: LiveTVProgramPair(current: nil, next: nil))
        for (info, name) in [(withGuide, "channel-info-fixture.png"), (noGuide, "channel-info-no-guide-fixture.png")] {
            try render(LiveTVChannelInfoSheet(info: info, isFavorite: name.contains("no-guide"), toggleFavorite: {}, watchLive: {}),
                       size: CGSize(width: 430, height: 620), to: directory.appendingPathComponent(name))
        }
        try render(LiveTVChannelInfoSheet(info: longDescription, isFavorite: true, toggleFavorite: {}, watchLive: {})
                       .dynamicTypeSize(.accessibility3),
                   size: CGSize(width: 430, height: 900),
                   to: directory.appendingPathComponent("channel-info-large-type-fixture.png"))
    }

    func testRenderFixtureMyFavoritesHeader() throws {
        let directory = try outputDirectory()
        let view = NavigationStack {
            Text("Favorites")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(20)
                .foregroundStyle(.white)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarBackButtonHidden(true)
                .toolbar {
                    LiveTVHomeToolbar(back: {}, backLabel: "Back to Live TV Home",
                                      search: {}, guide: {}, settings: {})
                }
        }
        try render(view, size: CGSize(width: 430, height: 900),
                   to: directory.appendingPathComponent("live-tv-my-favorites-header-fixture.png"))
    }

    /// The Guide's program sheet: current-program status and the Watch button.
    func testRenderFixtureGuideProgramDetail() throws {
        let directory = try outputDirectory()
        let channel = fixture("Sports One", "Sports")
        let detail = LiveTVGuideDetail(channel: channel, program: epgProgram("Evening Highlights", for: channel))
        try render(LiveTVProgramDetailView(detail: detail, onWatch: {}), size: CGSize(width: 430, height: 700),
                   to: directory.appendingPathComponent("guide-program-detail-fixture.png"))
    }

    /// A real window, not ImageRenderer: ImageRenderer cannot draw ScrollView content.
    private func render(_ view: some View, size: CGSize, to url: URL) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            _ = window.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        window.isHidden = true
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: url)
        let attachment = XCTAttachment(image: image)
        attachment.name = url.lastPathComponent
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
