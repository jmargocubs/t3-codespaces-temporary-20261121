import Foundation
import XCTest
@testable import Silo

/// The coordinator's third source, TV programs: shared debounce, independent states, identity
/// (provider, catalog revision, guide generation) checks, cancellation and tap-time resolution.
@MainActor
final class UnifiedSearchProgramSourceTests: XCTestCase {
    private let providerA = UUID(uuidString: "A1F4C8A0-CB4C-4B3D-9F73-9AA2BDA7C6B0")!
    private let providerB = UUID(uuidString: "B1F4C8A0-CB4C-4B3D-9F73-9AA2BDA7C6B0")!
    /// The coordinator searches at the real current time, so listings are laid out around it.
    private let now = Date()

    func testSharedDebounceStartsEverySourceOnceForTheLatestText() async throws {
        let world = World(provider: providerA, titles: ["News Tonight", "Late News", "Match Day"])
        let coordinator = world.makeCoordinator()

        coordinator.onQueryChanged("Ne")
        try await Task.sleep(for: .milliseconds(8))
        coordinator.onQueryChanged("News")
        XCTAssertEqual(coordinator.siloState.phase, .debouncing)
        XCTAssertEqual(coordinator.liveTVState.phase, .debouncing)
        XCTAssertEqual(coordinator.programState.phase, .debouncing)

        try await waitUntil { coordinator.programState.phase == .loaded && coordinator.liveTVState.phase == .loaded
            && world.silo.queries == ["News"] }
        XCTAssertEqual(Set(coordinator.programResults.map(\.title)), ["News Tonight", "Late News"])
        let searches = await world.store.searchCountForTesting
        XCTAssertEqual(searches, 1, "one debounce, one program search, for the latest text only")
    }

    func testEachSourceFailsOrIsUnavailableIndependently() async throws {
        // No guide: programs unavailable, channels and Silo unaffected.
        let world = World(provider: providerA, titles: ["Sports Live"])
        world.guide.value = UnifiedSearchGuideSnapshot(guideGeneration: 1, guide: nil, isGuideLoading: false, isGuideStale: false)
        let coordinator = world.makeCoordinator()
        coordinator.onQueryChanged("channel")
        try await waitUntil { coordinator.liveTVState.phase == .loaded && coordinator.siloState.phase == .loaded
            && coordinator.programState.phase == .unavailable }
        XCTAssertEqual(coordinator.programState.message, "No TV guide is available.")
        XCTAssertEqual(coordinator.liveTVResults.count, 1)

        // Silo fails: programs and channels still load.
        let failing = World(provider: providerA, titles: ["Sports Live"])
        failing.silo.searchBehavior = { _, source in
            source.errorMessage = "Silo offline"
            source.hasSearched = true
        }
        let second = failing.makeCoordinator()
        second.onQueryChanged("sports")
        try await waitUntil { second.siloState.phase == .failed && second.programState.phase == .loaded
            && second.liveTVState.phase == .loaded }
        XCTAssertEqual(second.programResults.map(\.title), ["Sports Live"])
    }

    func testRapidQueriesCancelSupersededProgramSearches() async throws {
        let world = World(provider: providerA, channelCount: 300, perChannel: 60)
        let coordinator = world.makeCoordinator()
        coordinator.onQueryChanged("show")
        try await waitUntil { coordinator.programState.phase == .loading }
        for query in ["sh", "sho", "news", "news 1"] {
            coordinator.onQueryChanged(query)
            XCTAssertTrue(coordinator.programResults.isEmpty, "a new query clears program results at once")
        }
        try await waitUntil(timeout: .seconds(10)) { coordinator.programState.phase == .loaded }
        XCTAssertFalse(coordinator.programResults.isEmpty)
        XCTAssertTrue(coordinator.programResults.allSatisfy { $0.title.localizedStandardContains("news 1") })
        let builds = await world.store.buildCountForTesting
        XCTAssertEqual(builds, 1, "superseded queries share one index build")
    }

    func testGuideGenerationChangeDropsOldResultsAndSearchesTheNewGuide() async throws {
        let world = World(provider: providerA, titles: ["Old Final"])
        let coordinator = world.makeCoordinator()
        coordinator.onQueryChanged("final")
        try await waitUntil { coordinator.programResults.map(\.title) == ["Old Final"] }

        world.setGuide(titles: ["New Final"], generation: 2)
        await coordinator.catalogDidChange()
        XCTAssertTrue(coordinator.programResults.allSatisfy { $0.title != "Old Final" })
        try await waitUntil { coordinator.programResults.map(\.title) == ["New Final"] }
        let builds = await world.store.buildCountForTesting
        XCTAssertEqual(builds, 2)
    }

    func testGuideChangeWithoutNotificationIsCaughtBeforePublishing() async throws {
        let world = World(provider: providerA, titles: ["Old Final"])
        let coordinator = world.makeCoordinator()
        coordinator.onQueryChanged("final")
        try await waitUntil { coordinator.programState.phase == .loaded }

        // The guide changes and nobody calls catalogDidChange; the next search must still use it.
        world.setGuide(titles: ["New Final"], generation: 7)
        coordinator.onQueryChanged("final ")
        try await waitUntil { coordinator.programResults.map(\.title) == ["New Final"] }
    }

    /// The guide changes while the store is still searching, and nobody notifies the coordinator.
    func testGuideSwapDuringAnInFlightSearchIsRejectedAndSearchedAgain() async throws {
        let world = World(provider: providerA, channelCount: 300, perChannel: 60)
        let coordinator = world.makeCoordinator()
        coordinator.onQueryChanged("news 4")
        try await waitUntil { coordinator.programState.phase == .loading }
        world.setGuide(titles: ["News 4 Replacement"], generation: 42)
        try await waitUntil(timeout: .seconds(10)) {
            coordinator.programState.phase == .loaded && !coordinator.programResults.isEmpty
        }
        XCTAssertEqual(coordinator.programResults.map(\.title), ["News 4 Replacement"])
    }

    func testRefreshOfAnInstalledGuideKeepsResultsUntilTheNewGuidePublishes() async throws {
        let world = World(provider: providerA, titles: ["Match Day"])
        let coordinator = world.makeCoordinator()
        coordinator.onQueryChanged("match")
        try await waitUntil { coordinator.programResults.map(\.title) == ["Match Day"] }
        let searchesBefore = await world.store.searchCountForTesting

        // A background refresh starts and fails: same guide, same generation.
        world.guide.value = UnifiedSearchGuideSnapshot(guideGeneration: world.guide.value.guideGeneration,
                                                       guide: world.currentGuide, isGuideLoading: true, isGuideStale: false)
        await coordinator.catalogDidChange()
        world.guide.value = UnifiedSearchGuideSnapshot(guideGeneration: world.guide.value.guideGeneration,
                                                       guide: world.currentGuide, isGuideLoading: false, isGuideStale: false)
        await coordinator.catalogDidChange()
        XCTAssertEqual(coordinator.programResults.map(\.title), ["Match Day"], "no flicker")
        let searchesAfter = await world.store.searchCountForTesting
        XCTAssertEqual(searchesAfter, searchesBefore, "no needless re-search")
    }

    func testRetryProgramsSearchesProgramsOnlyAgain() async throws {
        let world = World(provider: providerA, titles: ["Grand Prix"])
        world.guide.value = UnifiedSearchGuideSnapshot(guideGeneration: 1, guide: nil, isGuideLoading: false, isGuideStale: false)
        let coordinator = world.makeCoordinator()
        coordinator.onQueryChanged("grand")
        try await waitUntil { coordinator.programState.phase == .unavailable && world.silo.queries == ["grand"] }

        world.setGuide(titles: ["Grand Prix"], generation: 2)
        coordinator.retryPrograms()
        try await waitUntil { coordinator.programResults.map(\.title) == ["Grand Prix"] }
        XCTAssertEqual(world.silo.queries, ["grand"], "retrying programs leaves Silo alone")
    }

    func testDismissalAfterProgramsLoadedKeepsThemForReturn() async throws {
        let world = World(provider: providerA, titles: ["Cup Final"])
        let coordinator = world.makeCoordinator()
        coordinator.onQueryChanged("final")
        try await waitUntil { coordinator.programState.phase == .loaded && coordinator.liveTVState.phase == .loaded
            && coordinator.siloState.phase == .loaded }
        coordinator.cancelForDismissal()
        XCTAssertEqual(coordinator.programResults.map(\.title), ["Cup Final"], "like channels, finished results survive a detail")
        coordinator.resumeAfterDismissalIfNeeded()
        let searches = await world.store.searchCountForTesting
        XCTAssertEqual(searches, 1, "nothing was pending, so nothing restarts")
    }

    func testProviderAndCatalogChangesReplaceProgramResults() async throws {
        let world = World(provider: providerA, titles: ["Derby A"])
        let coordinator = world.makeCoordinator()
        coordinator.onQueryChanged("derby")
        try await waitUntil { coordinator.programResults.map(\.title) == ["Derby A"] }

        world.setCatalog(provider: providerB, revision: 5, titles: ["Derby B"])
        await coordinator.catalogDidChange()
        try await waitUntil { coordinator.programResults.map(\.title) == ["Derby B"] }
        XCTAssertTrue(coordinator.programResults.allSatisfy { $0.channelID.hasPrefix(self.providerB.uuidString) })

        world.setCatalog(provider: providerB, revision: 6, titles: ["Derby B2"])
        await coordinator.catalogDidChange()
        try await waitUntil { coordinator.programResults.map(\.title) == ["Derby B2"] }
    }

    func testLocaleChangesReuseTheIndexAndUseTheNewLocale() async throws {
        let locale = TestLocaleBox(Locale(identifier: "en_US"))
        let world = World(provider: providerA, titles: ["ISTANBUL Live"], locale: locale)
        let coordinator = world.makeCoordinator()
        coordinator.onQueryChanged("istanbul")
        try await waitUntil { coordinator.programState.phase == .loaded }

        for id in ["tr_TR", "en_US"] {
            locale.value = Locale(identifier: id)
            coordinator.onQueryChanged(id == "tr_TR" ? "istanbul " : "istanbul")
            try await waitUntil { coordinator.programState.phase == .loaded }
            let used = await world.store.lastMatchingLocaleIdentifierForTesting
            XCTAssertEqual(used, id)
        }
        let builds = await world.store.buildCountForTesting
        XCTAssertEqual(builds, 1, "a locale change alone never rebuilds")
    }

    func testEmptyLoadingStaleAndEmptySQLiteGuideStates() async throws {
        let world = World(provider: providerA, titles: ["Anything"])
        let coordinator = world.makeCoordinator()

        world.guide.value = UnifiedSearchGuideSnapshot(guideGeneration: 3, guide: nil, isGuideLoading: true, isGuideStale: false)
        await coordinator.catalogDidChange()
        XCTAssertEqual(coordinator.programState, UnifiedSearchSourceStatus(phase: .loading, message: "Loading the TV guide…"))

        world.guide.value = UnifiedSearchGuideSnapshot(guideGeneration: 4, guide: world.currentGuide, isGuideLoading: false,
                                                       isGuideStale: true)
        await coordinator.catalogDidChange()
        XCTAssertEqual(coordinator.programState, UnifiedSearchSourceStatus(phase: .unavailable, message: "The TV guide is out of date."))

        // A SQLite-backed guide with no listings is searchable and simply finds nothing.
        world.guide.value = UnifiedSearchGuideSnapshot(guideGeneration: 5, guide: try makeSQLiteGuide(), isGuideLoading: false,
                                                       isGuideStale: false)
        await coordinator.catalogDidChange()
        XCTAssertEqual(coordinator.programState, UnifiedSearchSourceStatus(phase: .loaded, resultCount: 0))
        coordinator.onQueryChanged("anything")
        try await waitUntil { coordinator.liveTVState.phase == .loaded && coordinator.programState.phase == .loaded }
        XCTAssertTrue(coordinator.programResults.isEmpty)
        let builds = await world.store.buildCountForTesting
        XCTAssertEqual(builds, 1, "the SQLite guide prepared one search source")

        world.setGuide(titles: ["Anything"], generation: 6)
        await coordinator.catalogDidChange()
        try await waitUntil { coordinator.programResults.map(\.title) == ["Anything"] }
        coordinator.onQueryChanged("a")
        try await waitUntil { coordinator.programState.phase == .idle }
        XCTAssertTrue(coordinator.programResults.isEmpty, "programs need two characters")

        let empty = World(provider: providerA, titles: [])
        let emptyCoordinator = empty.makeCoordinator()
        emptyCoordinator.onQueryChanged("news")
        try await waitUntil { emptyCoordinator.programState.phase == .loaded }
        XCTAssertEqual(emptyCoordinator.programState.resultCount, 0)

        let noProvider = World(provider: nil, titles: [])
        XCTAssertEqual(noProvider.makeCoordinator().programState.phase, .unavailable)
    }

    /// A SQLite-backed guide is searched through the same coordinator path: results publish under the
    /// guide's identity, a tap resolves the programme from disk without filling the resident window,
    /// and a guide refresh drops the old results and searches the new guide.
    func testSQLiteBackedGuideFindsResolvesAndRefreshesPrograms() async throws {
        let world = World(provider: providerA, titles: ["Placeholder", "Placeholder"])
        let sqliteGuide = try makeSQLiteGuide(programmes: [
            .init("g0", -600, "Evening News", duration: 3_600),
            .init("g1", 1_200, "Late News", subtitle: "Weather", duration: 1_800),
            .init("g1", -900, "Cooking", duration: 1_800),
        ])
        world.guide.value = UnifiedSearchGuideSnapshot(guideGeneration: 10, guide: sqliteGuide, isGuideLoading: false,
                                                       isGuideStale: false)
        let coordinator = world.makeCoordinator()
        coordinator.onQueryChanged("NEWS")
        try await waitUntil { coordinator.programState.phase == .loaded }
        XCTAssertEqual(coordinator.programResults.map(\.title), ["Evening News", "Late News"])
        XCTAssertEqual(coordinator.programResults.map(\.wasLiveAtSearch), [true, false])
        XCTAssertEqual(coordinator.programResults.map(\.channelName), ["Channel 0", "Channel 1"])

        let tapped = try XCTUnwrap(coordinator.programResults.last)
        XCTAssertEqual(sqliteGuide.sqlite?.guide.residentChannelCount, 0)
        let resolution = await coordinator.resolveProgram(for: tapped)
        let resolved = try XCTUnwrap(resolution)
        XCTAssertEqual(resolved.channel.id, tapped.channelID)
        XCTAssertEqual(resolved.program.title, "Late News")
        XCTAssertEqual(resolved.program.subtitle, "Weather")
        XCTAssertEqual(sqliteGuide.sqlite?.guide.residentChannelCount, 0, "resolution reads one channel without caching it")

        // Refresh to an in-memory guide: old results drop at once, then the new guide answers.
        world.setGuide(titles: ["News Refreshed"], generation: 11)
        await coordinator.catalogDidChange()
        XCTAssertTrue(coordinator.programResults.isEmpty)
        let staleResolution = await coordinator.resolveProgram(for: tapped)
        XCTAssertNil(staleResolution)
        try await waitUntil { coordinator.programResults.map(\.title) == ["News Refreshed"] }
    }

    func testDismissalCancelsPendingProgramWorkAndReentryRestartsIt() async throws {
        let world = World(provider: providerA, titles: ["Evening News"])
        let coordinator = world.makeCoordinator()
        coordinator.onQueryChanged("news")
        XCTAssertEqual(coordinator.programState.phase, .debouncing)
        coordinator.cancelForDismissal()
        XCTAssertTrue(coordinator.programResults.isEmpty)
        XCTAssertNotEqual(coordinator.programState.phase, .debouncing)
        try await Task.sleep(for: .milliseconds(60))
        let searches = await world.store.searchCountForTesting
        XCTAssertEqual(searches, 0, "dismissal cancelled the debounce before any program search")

        coordinator.resumeAfterDismissalIfNeeded()
        try await waitUntil { coordinator.programResults.map(\.title) == ["Evening News"] }
    }

    func testResolutionUsesTheCurrentCatalogAndGuideAndExposesNoSecrets() async throws {
        let world = World(provider: providerA, titles: ["Cup Final"])
        let coordinator = world.makeCoordinator()
        coordinator.onQueryChanged("final")
        try await waitUntil { coordinator.programResults.count == 1 }
        let result = try XCTUnwrap(coordinator.programResults.first)
        XCTAssertFalse(result.logoURL?.absoluteString.contains("token") ?? false)
        XCTAssertFalse(String(describing: result).contains("stream"), "results carry no stream URL")

        let resolved = await coordinator.resolveProgram(for: result)
        let pair = try XCTUnwrap(resolved)
        XCTAssertEqual(pair.channel.id, result.channelID)
        XCTAssertTrue(pair.channel.streamURL.absoluteString.contains("token=secret"))
        XCTAssertEqual(pair.program.id, result.programID)
        XCTAssertEqual(pair.program.title, "Cup Final")

        // A newer guide makes the displayed result stale even before a new search publishes.
        world.setGuide(titles: ["Cup Final"], generation: 9)
        let stale = await coordinator.resolveProgram(for: result)
        XCTAssertNil(stale)
        await coordinator.catalogDidChange()
        XCTAssertTrue(coordinator.programResults.isEmpty)
        let afterChange = await coordinator.resolveProgram(for: result)
        XCTAssertNil(afterChange)
    }

    /// A valid provider channel with no logo still publishes its programme and resolves at tap time.
    func testValidChannelWithoutALogoReturnsTheProgrammeAndResolves() async throws {
        let world = World(provider: nil)
        world.setCatalog(provider: providerA, revision: 1, title: "Quiet Logo", logoURL: nil)
        let coordinator = world.makeCoordinator()
        coordinator.onQueryChanged("quiet")
        try await waitUntil { coordinator.programState.phase == .loaded }

        let program = try XCTUnwrap(world.currentGuide?.programsByChannel["g0"]?.first)
        let channelID = "\(providerA.uuidString):g0"
        XCTAssertEqual(coordinator.programState, UnifiedSearchSourceStatus(phase: .loaded, resultCount: 1))
        XCTAssertEqual(coordinator.programResults.count, 1)
        let result = try XCTUnwrap(coordinator.programResults.first)
        XCTAssertEqual(result.id, "\(channelID)|\(program.id)")
        XCTAssertEqual(result.programID, program.id)
        XCTAssertEqual(result.channelID, channelID)
        XCTAssertEqual(result.channelKey, "g0")
        XCTAssertEqual(result.channelName, "Channel 0")
        XCTAssertNil(result.logoURL)
        XCTAssertEqual(result.title, "Quiet Logo")

        let resolved = await coordinator.resolveProgram(for: result)
        let pair = try XCTUnwrap(resolved)
        XCTAssertNil(pair.channel.logoURL)
        XCTAssertEqual(pair.channel.id, channelID)
        XCTAssertEqual(pair.program.id, program.id)
        XCTAssertEqual(pair.program.title, "Quiet Logo")
    }

    func testUnchangedGuideIdentityNeverRebuildsAcrossQueriesOrNotifications() async throws {
        let world = World(provider: providerA, titles: ["Morning News", "Night News"])
        let coordinator = world.makeCoordinator()
        for query in ["news", "morning", "night", "news"] {
            coordinator.onQueryChanged(query)
            try await waitUntil { coordinator.programState.phase == .loaded }
            await coordinator.catalogDidChange()
        }
        XCTAssertEqual(coordinator.programResults.count, 2)
        let builds = await world.store.buildCountForTesting
        XCTAssertEqual(builds, 1)
    }

    func testWithoutAProgramSourceTheCoordinatorBehavesAsBefore() async throws {
        let world = World(provider: providerA, titles: ["Sports Live"])
        let coordinator = world.makeCoordinator(programsEnabled: false)
        XCTAssertEqual(coordinator.programState, .idle)
        coordinator.onQueryChanged("sports")
        try await waitUntil { coordinator.liveTVState.phase == .loaded && coordinator.siloState.phase == .loaded }
        XCTAssertEqual(coordinator.programState, .idle)
        XCTAssertTrue(coordinator.programResults.isEmpty)
        let searches = await world.store.searchCountForTesting
        XCTAssertEqual(searches, 0)
    }

    // MARK: - Fixtures

    /// One provider's catalog and guide, plus the fakes and store a coordinator reads them through.
    @MainActor
    private final class World {
        let silo = ProgramFakeSilo()
        let store: EPGProgramSearchIndexStore
        let catalog: ProgramFakeBox<UnifiedSearchIPTVCatalogSnapshot>
        let guide: ProgramFakeBox<UnifiedSearchGuideSnapshot>
        private(set) var currentGuide: EPGIndex?
        private let now = Date()

        init(provider: UUID?, titles: [String] = [], channelCount: Int = 0, perChannel: Int = 0,
             locale: TestLocaleBox? = nil) {
            store = locale.map { box in EPGProgramSearchIndexStore(matchingLocale: { box.value }) } ?? EPGProgramSearchIndexStore()
            catalog = ProgramFakeBox(UnifiedSearchIPTVCatalogSnapshot(providerID: nil, catalogRevision: 0, hasProvider: false,
                                                                      isLoading: false, errorMessage: nil, channels: []))
            guide = ProgramFakeBox(.none)
            if let provider {
                if channelCount > 0 {
                    setLarge(provider: provider, channels: channelCount, perChannel: perChannel)
                } else {
                    setCatalog(provider: provider, revision: 1, titles: titles)
                }
            }
        }

        func makeCoordinator(programsEnabled: Bool = true) -> UnifiedSearchCoordinator {
            let identity = UnifiedSiloIdentity(serverID: "server", accountID: "account", profileID: "profile")
            let guide = guide
            let catalog = catalog
            return UnifiedSearchCoordinator(
                silo: silo, indexStore: LiveTVChannelSearchIndexStore(),
                catalogSnapshot: { catalog.value }, siloIdentityProvider: { identity },
                programs: programsEnabled ? UnifiedSearchProgramSource(store: store) { _ in guide.value } : nil,
                debounceDuration: .milliseconds(20))
        }

        /// One channel per title; each title airs now on its own channel.
        func setCatalog(provider: UUID, revision: Int, titles: [String]) {
            let channels = titles.indices.map { channel(provider, "Channel \($0)", guideID: "g\($0)") }
            catalog.value = UnifiedSearchIPTVCatalogSnapshot(providerID: provider, catalogRevision: revision, hasProvider: true,
                                                             isLoading: false, errorMessage: nil, channels: channels)
            setGuide(titles: titles, generation: guide.value.guideGeneration + 1)
        }

        /// One programme on a provider-qualified channel. `logoURL` may be nil.
        func setCatalog(provider: UUID, revision: Int, title: String, logoURL: URL?) {
            let channels = [channel(provider, "Channel 0", guideID: "g0", logoURL: logoURL)]
            catalog.value = UnifiedSearchIPTVCatalogSnapshot(providerID: provider, catalogRevision: revision, hasProvider: true,
                                                             isLoading: false, errorMessage: nil, channels: channels)
            setGuide(titles: [title], generation: guide.value.guideGeneration + 1)
        }

        func setGuide(titles: [String], generation: Int) {
            var programs: [String: [EPGProgram]] = [:]
            for (offset, title) in titles.enumerated() {
                programs["g\(offset)"] = [EPGProgram(channelID: "g\(offset)", start: now.addingTimeInterval(-600),
                                                     end: now.addingTimeInterval(3_000), title: title)]
            }
            let index = EPGIndex(fetchedAt: now, programsByChannel: programs, channelIDsByName: [:], statistics: .init())
            currentGuide = index
            guide.value = UnifiedSearchGuideSnapshot(guideGeneration: generation, guide: index, isGuideLoading: false,
                                                     isGuideStale: false)
        }

        private func setLarge(provider: UUID, channels count: Int, perChannel: Int) {
            var programs: [String: [EPGProgram]] = [:]
            var channels: [LiveTVChannel] = []
            for number in 0..<count {
                let key = "g\(number)"
                channels.append(channel(provider, "Channel \(number)", guideID: key))
                programs[key] = (0..<perChannel).map { slot in
                    let start = now.addingTimeInterval(TimeInterval(slot * 600 - 300))
                    return EPGProgram(channelID: key, start: start, end: start.addingTimeInterval(600),
                                      title: slot.isMultiple(of: 4) ? "News \(slot)" : "Show \(number)-\(slot)",
                                      subtitle: "Episode \(number * perChannel + slot)")
                }
            }
            catalog.value = UnifiedSearchIPTVCatalogSnapshot(providerID: provider, catalogRevision: 1, hasProvider: true,
                                                             isLoading: false, errorMessage: nil, channels: channels)
            let index = EPGIndex(fetchedAt: now, programsByChannel: programs, channelIDsByName: [:], statistics: .init())
            currentGuide = index
            guide.value = UnifiedSearchGuideSnapshot(guideGeneration: 1, guide: index, isGuideLoading: false, isGuideStale: false)
        }

        private func channel(_ provider: UUID, _ name: String, guideID: String) -> LiveTVChannel {
            channel(provider, name, guideID: guideID,
                    logoURL: URL(string: "https://fixture.invalid/logo/\(guideID).png?token=secret")!)
        }

        private func channel(_ provider: UUID, _ name: String, guideID: String, logoURL: URL?) -> LiveTVChannel {
            LiveTVChannel(id: "\(provider.uuidString):\(guideID)", guideID: guideID, name: name,
                          streamURL: URL(string: "https://fixture.invalid/stream/\(guideID)?token=secret")!,
                          logoURL: logoURL,
                          category: "TV")
        }
    }

    private func makeSQLiteGuide() throws -> EPGIndex {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProgramSourceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let xml = "<tv><channel id=\"g0\"><display-name>Channel 0</display-name></channel></tv>"
        let built = try EPGSQLiteBuilder.build(xml: Data(xml.utf8), filter: nil, limits: EPGLimits(), fetchedAt: now,
                                               providerID: providerA,
                                               fingerprint: Data(repeating: 0x42, count: EPGSourceFingerprint.length),
                                               destination: directory.appendingPathComponent("guide.sqlite"))
        return EPGIndex(sqlite: built.index, statistics: built.statistics)
    }

    /// A SQLite-backed guide opened cached-only, as the app opens it, with listings around `now`.
    private func makeSQLiteGuide(programmes: [EPGSQLiteSearchFixture.Programme]) throws -> EPGIndex {
        try EPGSQLiteSearchFixture.buildBoth(programmes, now: now, provider: providerA, testCase: self).sqlite
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async throws {
        let start = ContinuousClock.now
        while !condition() {
            if start.duration(to: .now) >= timeout { XCTFail("Condition timed out"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class ProgramFakeBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

final class TestLocaleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Locale
    init(_ locale: Locale) { stored = locale }
    var value: Locale {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

@MainActor
private final class ProgramFakeSilo: UnifiedSearchSiloServing {
    var titleResults: [BrowseItem] = []
    var peopleResults: [Person] = []
    var requestResults: [RequestMediaResult] = []
    var isLoading = false
    var hasSearched = false
    var errorMessage: String?
    var queries: [String] = []
    var searchBehavior: @MainActor (String, ProgramFakeSilo) async -> Void = { _, source in source.hasSearched = true }

    func performSearch(query: String) async {
        queries.append(query)
        isLoading = true
        errorMessage = nil
        await searchBehavior(query, self)
        isLoading = false
    }

    func loadMore() async {}

    func cancelForQueryChange() {
        isLoading = false
        hasSearched = false
        errorMessage = nil
    }

    func resetForIdentityChange() { cancelForQueryChange() }
}
