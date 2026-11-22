import Foundation
import CryptoKit
import XCTest
@testable import Silo

@MainActor
final class UnifiedSearchCoordinatorTests: XCTestCase {
    private let providerA = UUID(uuidString: "A1F4C8A0-CB4C-4B3D-9F73-9AA2BDA7C6B0")!
    private let providerB = UUID(uuidString: "B1F4C8A0-CB4C-4B3D-9F73-9AA2BDA7C6B0")!

    func testDebounceAndRapidQueryReplacementRunOnlyLatestText() async throws {
        let silo = FakeSiloSearchSource()
        let catalog = FakeIPTVCatalog(snapshot: snapshot(provider: providerA, revision: 1,
                                                         channels: [channel(providerA, "Sports News", "News")]))
        let coordinator = makeCoordinator(silo: silo, catalog: catalog)

        coordinator.onQueryChanged("Sp")
        try await Task.sleep(for: .milliseconds(8))
        coordinator.onQueryChanged("Sports")
        XCTAssertEqual(coordinator.siloState.phase, .debouncing)
        XCTAssertEqual(coordinator.liveTVState.phase, .debouncing)

        try await waitUntil { silo.queries == ["Sports"] && coordinator.liveTVState.phase == .loaded }
        XCTAssertEqual(silo.queries, ["Sports"])
        XCTAssertGreaterThanOrEqual(silo.cancelCount, 2)
        XCTAssertEqual(coordinator.liveTVResults.map(\.name), ["Sports News"])
    }

    func testFiltersKeepSectionsSeparateAndSeeAllSelectsOnlyItsSection() {
        XCTAssertEqual(UnifiedSearchFilter.all.title, "All")
        XCTAssertEqual(UnifiedSearchFilter.moviesAndTV.title, "Movies & TV")
        XCTAssertEqual(UnifiedSearchFilter.liveTV.title, "Live TV")
        XCTAssertTrue(UnifiedSearchFilter.all.showsMoviesAndTV)
        XCTAssertTrue(UnifiedSearchFilter.all.showsLiveTV)
        XCTAssertTrue(UnifiedSearchFilter.moviesAndTV.showsMoviesAndTV)
        XCTAssertFalse(UnifiedSearchFilter.moviesAndTV.showsLiveTV)
        XCTAssertFalse(UnifiedSearchFilter.liveTV.showsMoviesAndTV)
        XCTAssertTrue(UnifiedSearchFilter.liveTV.showsLiveTV)
        XCTAssertEqual(UnifiedSearchFilter.all.seeAllFilter(for: .moviesAndTV), .moviesAndTV)
        XCTAssertEqual(UnifiedSearchFilter.all.seeAllFilter(for: .liveTV), .liveTV)
        XCTAssertEqual(UnifiedSearchResultsSection.combinedPreviewLimit, 6)
        XCTAssertTrue(UnifiedSearchResultsSection.hasAdditionalResults(total: 7, visible: 6))
        XCTAssertFalse(UnifiedSearchResultsSection.hasAdditionalResults(total: 6, visible: 6))
        XCTAssertEqual(UnifiedSearchResultsSection.nextVisibleLimit(current: 6, total: 100), 66)
        XCTAssertEqual(UnifiedSearchResultsSection.nextVisibleLimit(current: 66, total: 70), 70)
    }

    func testSiloLoadingAndFailureDoNotSuppressLiveTVResults() async throws {
        let silo = FakeSiloSearchSource()
        silo.searchBehavior = { _, source in
            source.errorMessage = "Silo offline"
            source.hasSearched = true
        }
        let catalog = FakeIPTVCatalog(snapshot: snapshot(provider: providerA, revision: 3,
                                                         channels: [channel(providerA, "Local Sports", "Sports")]))
        let coordinator = makeCoordinator(silo: silo, catalog: catalog)

        coordinator.onQueryChanged("sports")
        try await waitUntil {
            silo.startedQuery == "sports"
                && coordinator.liveTVState.phase == .loaded
                && coordinator.liveTVState.resultCount == 1
        }
        XCTAssertEqual(coordinator.liveTVState.phase, .loaded)
        try await waitUntil { coordinator.siloState.phase == .failed }
        XCTAssertEqual(coordinator.siloState.message, "Silo offline")
        XCTAssertEqual(coordinator.liveTVState.resultCount, 1)
        XCTAssertEqual(coordinator.liveTVResults.map(\.id), [channel(providerA, "Local Sports", "Sports").id])
    }

    func testSiloIdentityChangeClearsOldResultsAndRerunsForNewIdentity() async throws {
        let identities = FakeIdentityBox(.init(serverID: "server-a", accountID: "account", profileID: "profile-a"))
        let silo = FakeSiloSearchSource()
        let catalog = FakeIPTVCatalog(snapshot: snapshot(provider: providerA, revision: 1, channels: []))
        let coordinator = makeCoordinator(silo: silo, catalog: catalog, identities: identities)

        coordinator.onQueryChanged("movie")
        try await waitUntil { silo.queries == ["movie"] }
        identities.value = .init(serverID: "server-b", accountID: "account", profileID: "profile-b")
        coordinator.synchronizeSiloIdentity()
        XCTAssertEqual(silo.resetCount, 1)
        XCTAssertEqual(coordinator.siloState.phase, .loading)

        try await waitUntil { silo.queries.count == 2 }
        XCTAssertEqual(silo.queries, ["movie", "movie"])
        XCTAssertEqual(coordinator.siloState.phase, .loaded)
    }

    func testIPTVProviderAndRevisionChangesReplaceResultsAndRejectOldIdentity() async throws {
        let silo = FakeSiloSearchSource()
        let catalog = FakeIPTVCatalog(snapshot: snapshot(provider: providerA, revision: 1,
                                                         channels: [channel(providerA, "Sports A", "Sports")]))
        let coordinator = makeCoordinator(silo: silo, catalog: catalog)
        coordinator.onQueryChanged("sports")
        try await waitUntil { coordinator.liveTVResults.count == 1 }
        let oldResultID = coordinator.liveTVResults[0].id

        catalog.value = snapshot(provider: providerB, revision: 2,
                                 channels: [channel(providerB, "Sports B", "Sports")])
        await coordinator.catalogDidChange()
        try await waitUntil { coordinator.liveTVResults.count == 1 && coordinator.liveTVResults[0].id != oldResultID }
        XCTAssertEqual(coordinator.liveTVResults.map(\.name), ["Sports B"])
        XCTAssertEqual(coordinator.liveTVState.phase, .loaded)
    }

    func testCatalogRevisionChangeRejectsLateQueryAndUsesLatestCatalog() async throws {
        let silo = FakeSiloSearchSource()
        let first = (0..<20_000).map { channel(providerA, "Sports \($0)", "News") }
        let catalog = FakeIPTVCatalog(snapshot: snapshot(provider: providerA, revision: 1, channels: first))
        let coordinator = makeCoordinator(silo: silo, catalog: catalog)

        coordinator.onQueryChanged("sports")
        try await Task.sleep(for: .milliseconds(30))
        catalog.value = snapshot(provider: providerA, revision: 2,
                                 channels: [channel(providerA, "Sports Updated", "News")])
        await coordinator.catalogDidChange()
        try await waitUntil { coordinator.liveTVResults.map(\.name) == ["Sports Updated"] }
        XCTAssertEqual(coordinator.liveTVState.resultCount, 1)
        XCTAssertFalse(coordinator.liveTVResults.contains { $0.name == "Sports 19999" })
    }

    func testPartialSuccessAndEmptyResultsHaveIndependentSourceStates() async throws {
        let silo = FakeSiloSearchSource()
        silo.searchBehavior = { _, source in source.hasSearched = true }
        let catalog = FakeIPTVCatalog(snapshot: snapshot(provider: providerA, revision: 1,
                                                         channels: [channel(providerA, "Only Sports", "Sports")]))
        let coordinator = makeCoordinator(silo: silo, catalog: catalog)

        coordinator.onQueryChanged("missing")
        try await waitUntil { coordinator.siloState.phase == .loaded && coordinator.liveTVState.phase == .loaded }
        XCTAssertEqual(coordinator.siloState.resultCount, 0)
        XCTAssertEqual(coordinator.liveTVState.resultCount, 0)

        silo.searchBehavior = { _, source in
            source.errorMessage = "Silo unavailable"
            source.hasSearched = true
        }
        coordinator.onQueryChanged("sports")
        try await waitUntil { coordinator.siloState.phase == .failed && coordinator.liveTVState.phase == .loaded }
        XCTAssertEqual(coordinator.liveTVState.resultCount, 1)
    }

    func testNoIPTVProviderIsAnIndependentUnavailableState() async throws {
        let silo = FakeSiloSearchSource()
        let catalog = FakeIPTVCatalog(snapshot: UnifiedSearchIPTVCatalogSnapshot(
            providerID: nil, catalogRevision: 0, hasProvider: false,
            isLoading: false, errorMessage: nil, channels: []))
        let coordinator = makeCoordinator(silo: silo, catalog: catalog)
        XCTAssertEqual(coordinator.liveTVState.phase, .unavailable)

        coordinator.onQueryChanged("movie")
        try await waitUntil { silo.queries == ["movie"] }
        XCTAssertEqual(coordinator.liveTVState.phase, .unavailable)
        XCTAssertEqual(coordinator.siloState.phase, .loaded)
    }

    func testCanceledSiloQueryCannotPublishAfterReplacement() async throws {
        let silo = FakeSiloSearchSource()
        silo.searchBehavior = { query, source in
            source.startedQuery = query
            if query == "old" { try? await Task.sleep(for: .milliseconds(100)) }
            guard !Task.isCancelled else { return }
            source.hasSearched = true
        }
        let catalog = FakeIPTVCatalog(snapshot: snapshot(provider: providerA, revision: 1, channels: []))
        let coordinator = makeCoordinator(silo: silo, catalog: catalog)

        coordinator.onQueryChanged("old")
        await silo.waitUntilStarted("old")
        coordinator.onQueryChanged("new")
        try await waitUntil { silo.queries == ["old", "new"] && coordinator.siloState.phase == .loaded }
        try await waitUntil { silo.completedQueries.contains("old") }
        XCTAssertEqual(silo.queries, ["old", "new"])
        XCTAssertEqual(coordinator.query, "new")
        XCTAssertEqual(coordinator.siloState.phase, .loaded)
    }

    func testDismissalCancelsPendingWorkAndReentryRestartsCurrentQuery() async throws {
        let silo = FakeSiloSearchSource()
        let catalog = FakeIPTVCatalog(snapshot: snapshot(provider: providerA, revision: 1,
                                                         channels: [channel(providerA, "Live News", "News")]))
        let coordinator = makeCoordinator(silo: silo, catalog: catalog)

        coordinator.onQueryChanged("news")
        try await waitUntil { coordinator.siloState.phase == .debouncing }
        coordinator.cancelForDismissal()
        XCTAssertGreaterThanOrEqual(silo.cancelCount, 2)
        XCTAssertTrue(coordinator.liveTVResults.isEmpty)
        XCTAssertEqual(coordinator.siloState.phase, .idle)

        coordinator.resumeAfterDismissalIfNeeded()
        try await waitUntil { silo.queries == ["news"] && coordinator.liveTVState.phase == .loaded }
        XCTAssertEqual(coordinator.query, "news")
        XCTAssertEqual(coordinator.liveTVResults.map(\.name), ["Live News"])
    }

    func testChannelResolutionUsesCurrentProviderCatalogAndSafeSearchMetadata() async throws {
        let catalog = FakeIPTVCatalog(snapshot: snapshot(provider: providerA, revision: 1,
                                                         channels: [channel(providerA, "Local News", "News")]))
        let coordinator = makeCoordinator(silo: FakeSiloSearchSource(), catalog: catalog)
        coordinator.onQueryChanged("news")
        try await waitUntil { coordinator.liveTVResults.count == 1 }
        let result = try XCTUnwrap(coordinator.liveTVResults.first)
        let resolvedResult = await coordinator.resolveChannel(for: result)
        let resolved = try XCTUnwrap(resolvedResult)
        XCTAssertEqual(resolved.id, result.id)
        XCTAssertTrue(resolved.streamURL.absoluteString.contains("token=secret"))
        XCTAssertFalse(result.logoURL?.absoluteString.contains("token=secret") ?? false)

        catalog.value = snapshot(provider: providerB, revision: 2,
                                 channels: [channel(providerB, "Local News", "News")])
        await coordinator.catalogDidChange()
        try await waitUntil { coordinator.liveTVResults.first?.id != result.id }
        let staleResolution = await coordinator.resolveChannel(for: result)
        XCTAssertNil(staleResolution)
    }

    private func makeCoordinator(silo: FakeSiloSearchSource,
                                 catalog: FakeIPTVCatalog,
                                 identities: FakeIdentityBox? = nil) -> UnifiedSearchCoordinator {
        // Built here, on the main actor: a default argument is evaluated outside the class's isolation.
        let identities = identities ?? FakeIdentityBox(.init(serverID: "server", accountID: "account", profileID: "profile"))
        return UnifiedSearchCoordinator(
            silo: silo,
            indexStore: LiveTVChannelSearchIndexStore(),
            catalogSnapshot: { catalog.value },
            siloIdentityProvider: { identities.value },
            debounceDuration: .milliseconds(20)
        )
    }

    private func snapshot(provider: UUID, revision: Int,
                          channels: [LiveTVChannel]) -> UnifiedSearchIPTVCatalogSnapshot {
        UnifiedSearchIPTVCatalogSnapshot(providerID: provider, catalogRevision: revision,
                                         hasProvider: true, isLoading: false,
                                         errorMessage: nil, channels: channels)
    }

    private func channel(_ provider: UUID, _ name: String, _ category: String) -> LiveTVChannel {
        let digest = String(SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined())
        return LiveTVChannel(id: "\(provider.uuidString):\(digest)", guideID: nil, name: name,
                             streamURL: URL(string: "https://fixture.invalid/stream?token=secret")!,
                             logoURL: URL(string: "https://fixture.invalid/logo.png?token=secret")!, category: category)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool,
                           timeout: Duration = .seconds(2)) async throws {
        let start = ContinuousClock.now
        while !condition() {
            if start.duration(to: .now) >= timeout { XCTFail("Condition timed out"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class FakeIdentityBox {
    var value: UnifiedSiloIdentity?
    init(_ value: UnifiedSiloIdentity?) { self.value = value }
}

@MainActor
private final class FakeIPTVCatalog {
    var value: UnifiedSearchIPTVCatalogSnapshot
    init(snapshot: UnifiedSearchIPTVCatalogSnapshot) { value = snapshot }
}

@MainActor
private final class FakeSiloSearchSource: UnifiedSearchSiloServing {
    var titleResults: [BrowseItem] = []
    var peopleResults: [Person] = []
    var requestResults: [RequestMediaResult] = []
    var isLoading = false
    var hasSearched = false
    var errorMessage: String?
    var startedQuery: String?
    var queries: [String] = []
    var completedQueries: [String] = []
    var cancelCount = 0
    var resetCount = 0
    private var startedWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    var searchBehavior: @MainActor (String, FakeSiloSearchSource) async -> Void = { _, source in
        source.hasSearched = true
    }

    func performSearch(query: String) async {
        queries.append(query)
        startedQuery = query
        resumeStartedWaiters(for: query)
        defer { completedQueries.append(query) }
        isLoading = true
        errorMessage = nil
        await searchBehavior(query, self)
        guard !Task.isCancelled else { isLoading = false; return }
        isLoading = false
    }

    /// Returns once `performSearch` has been entered for `query`: an event, not a poll, so a slow
    /// machine delays the test instead of failing it. The deadline only turns a search that never
    /// starts into a failure instead of a hung test.
    func waitUntilStarted(_ query: String, deadline: Duration = .seconds(30)) async {
        if queries.contains(query) { return }
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: deadline)
            self?.resumeStartedWaiters(for: query)
        }
        await withCheckedContinuation { continuation in
            if queries.contains(query) {
                continuation.resume()
            } else {
                startedWaiters[query, default: []].append(continuation)
            }
        }
        watchdog.cancel()
        if !queries.contains(query) { XCTFail("Search for \(query) never started") }
    }

    private func resumeStartedWaiters(for query: String) {
        for waiter in startedWaiters.removeValue(forKey: query) ?? [] { waiter.resume() }
    }

    func loadMore() async {}

    func cancelForQueryChange() {
        cancelCount += 1
        isLoading = false
        hasSearched = false
        errorMessage = nil
        titleResults = []
        peopleResults = []
        requestResults = []
    }

    func resetForIdentityChange() {
        resetCount += 1
        cancelForQueryChange()
    }
}
