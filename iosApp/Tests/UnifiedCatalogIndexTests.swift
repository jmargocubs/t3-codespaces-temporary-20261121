#if os(iOS) || KYRO_VOD_HOST_TESTS
import Foundation
import CryptoKit
import XCTest
#if !KYRO_VOD_HOST_TESTS
@testable import Silo
#endif

/// Build 110 unified Movies/Series index: matching, ordering, keyset paging, the bounded window,
/// Silo snapshot sync, IPTV generation lifecycle and identity isolation. Runs on the Mac without a
/// simulator (`-D KYRO_VOD_HOST_TESTS`, see docs/kyro-development/build-110-unified-browsing.md)
/// and in the iOS test target.
final class UnifiedCatalogIndexTests: XCTestCase {
    private let p1 = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
    private let p2 = UUID(uuidString: "00000000-0000-0000-0000-0000000000a2")!
    private let scopeA = "scope-a"
    private let scopeB = "scope-b"
    private var directory: URL!
    private var store: XtreamVODCatalogStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unified-index-\(UUID().uuidString)")
        store = try XtreamVODCatalogStore(directory: directory)
    }

    override func tearDown() async throws {
        await store.close()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Fixtures

    private func iptv(_ provider: UUID, _ id: Int, _ title: String, kind: XtreamVODKind = .movie) -> XtreamVODItem {
        XtreamVODItem(providerID: provider, kind: kind, remoteID: id, title: title, category: "All",
                      poster: "https://img/\(id)", fileExtension: "mp4", summary: nil, genre: nil, rating: nil)
    }

    /// Imports a provider generation the way the service does: stage, anchors, keys, promote.
    private func importIPTV(_ provider: UUID, _ items: [XtreamVODItem], kind: XtreamVODKind = .movie,
                            generation: String = UUID().uuidString, promote: Bool = true) async throws {
        try await store.stage(items, generation: generation)
        try await store.buildPageAnchors(providerID: provider, kind: kind, generation: generation)
        try await store.buildUnifiedKeys(providerID: provider, kind: kind, generation: generation)
        if promote { try await store.promote(providerID: provider, kind: kind, generation: generation) }
    }

    private func record(_ id: String, _ title: String, _ year: Int?) -> UnifiedSiloRecord {
        UnifiedSiloRecord(contentID: id, title: title, year: year, poster: nil,
                          payload: Data("{\"contentId\":\"\(id)\"}".utf8))
    }

    private func importSilo(_ records: [UnifiedSiloRecord], scope: String? = nil, library: Int = 1,
                            kind: XtreamVODKind = .movie) async throws {
        let snapshot = UUID().uuidString
        try await store.stageSilo(records, scope: scope ?? scopeA, libraryID: library, kind: kind, snapshot: snapshot)
        try await store.promoteSilo(scope: scope ?? scopeA, libraryID: library, kind: kind, snapshot: snapshot,
                                    itemCount: records.count, syncedAt: Date())
    }

    private func scope(silo: String? = "scope-a", libraries: [Int] = [1], providers: [UUID]? = nil,
                       kind: XtreamVODKind = .movie) -> UnifiedIndexScope {
        UnifiedIndexScope(kind: kind, siloScope: silo, siloLibraryIDs: libraries, providerIDs: providers ?? [p1, p2])
    }

    /// Every card of the scope, read forward in pages of `limit` without a window.
    private func allCards(_ scope: UnifiedIndexScope, limit: Int = 500) async -> [UnifiedCatalogCard] {
        var rows: [UnifiedIndexRow] = []
        var cursor: UnifiedIndexCursor?
        while true {
            let page = await store.unifiedPage(scope, direction: .forward(after: cursor), limit: limit)
            rows += page.rows
            cursor = page.rows.last?.cursor
            if page.reachedEdge || page.rows.isEmpty { break }
        }
        return UnifiedCatalogGrouping.cards(from: rows)
    }

    // MARK: Matching

    func testSiloOnlyIPTVOnlyAndMatchedTitlesInterleaveAlphabetically() async throws {
        try await importSilo([record("s-arrival", "Arrival", 2016), record("s-zodiac", "Zodiac", 2007)])
        try await importIPTV(p1, [iptv(p1, 1, "Arrival (2016)"), iptv(p1, 2, "Heat (1995)")])

        let cards = await allCards(scope())
        XCTAssertEqual(cards.map(\.title), ["Arrival", "Heat (1995)", "Zodiac"],
                       "one alphabetical catalog, not Silo first then IPTV")
        let arrival = cards[0]
        XCTAssertEqual(arrival.members.count, 2)
        XCTAssertTrue(arrival.hasSilo, "Silo is the primary member of a matched title")
        XCTAssertEqual(arrival.iptvItems.map(\.id), [iptv(p1, 1, "x").id], "the provider-qualified ID is kept")
        XCTAssertFalse(cards[1].hasSilo)
        XCTAssertEqual(cards[2].members.count, 1)
        XCTAssertTrue(cards[2].hasSilo)
    }

    func testOneRecordPerProviderMergesAcrossMultipleProviders() async throws {
        try await importSilo([record("s1", "Arrival", 2016)])
        try await importIPTV(p1, [iptv(p1, 10, "Arrival (2016)")])
        try await importIPTV(p2, [iptv(p2, 20, "ARRIVAL [2016]")])

        let cards = await allCards(scope())
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(Set(cards[0].iptvItems.map(\.providerID)), [p1, p2])
        XCTAssertEqual(cards[0].id, "m:" + UnifiedCatalogKeys.matchKey(title: "Arrival", year: 2016))
    }

    func testAmbiguousAndYearlessTitlesStaySeparate() async throws {
        try await importSilo([record("s1", "Arrival", 2016), record("s2", "Solaris", 1972), record("s3", "Solaris", 1972)])
        try await importIPTV(p1, [iptv(p1, 1, "Arrival (2016)"), iptv(p1, 2, "Arrival (2016)"),
                                  iptv(p1, 3, "Arrival (2017)"), iptv(p1, 4, "Solaris"),
                                  iptv(p1, 5, "Solaris (1972)")])

        let cards = await allCards(scope())
        // Arrival 2016: two records from p1 make the group ambiguous: 3 separate cards.
        // Arrival 2017: alone. Solaris 1972: two Silo records: 3 separate. "Solaris" (no year): alone.
        XCTAssertEqual(cards.count, 8)
        XCTAssertTrue(cards.allSatisfy { $0.members.count == 1 })
        XCTAssertEqual(Set(cards.map(\.id)).count, cards.count)
    }

    func testDifferentKindsNeverMix() async throws {
        try await importSilo([record("s1", "Fargo", 1996)])
        try await importIPTV(p1, [iptv(p1, 1, "Fargo (1996)", kind: .series)], kind: .series)
        let movies = await allCards(scope())
        let series = await allCards(scope(kind: .series))
        XCTAssertEqual(movies.map(\.members.count), [1])
        XCTAssertTrue(movies[0].hasSilo)
        XCTAssertEqual(series.map(\.iptvItems.count), [1])
    }

    // MARK: Ordering

    func testGlobalOrderingFoldsCaseAndDiacriticsAndBreaksTiesStably() async throws {
        try await importSilo([record("s1", "Ägypten", 2001), record("s2", "Alien 3", 1992), record("s3", "Aliens", 1986)])
        try await importIPTV(p1, [iptv(p1, 1, "alien (1979)"), iptv(p1, 2, "Banana"), iptv(p1, 3, "apple"),
                                  iptv(p1, 4, "Banana"), iptv(p1, 5, "Alien (2003)")])
        let titles = await allCards(scope()).map(\.title)
        XCTAssertEqual(titles, ["Ägypten", "alien (1979)", "Alien (2003)", "Alien 3", "Aliens", "apple", "Banana", "Banana"])
        let again = await allCards(scope(), limit: 1).map(\.id)
        let v1 = await allCards(scope()).map(\.id)
        XCTAssertEqual(again, v1, "page size never changes the order")
    }

    // MARK: Paging and window

    private func seedLargeCatalog() async throws {
        let p1Items = (0..<700).map { iptv(p1, $0, String(format: "Title %04d (%d)", $0, 1950 + $0 % 60)) }
        let p2Items = (0..<400).map { iptv(p2, $0, String(format: "Title %04d (%d)", $0 * 2, 1950 + ($0 * 2) % 60)) }
        try await importIPTV(p1, p1Items)
        try await importIPTV(p2, p2Items)
        try await importSilo((0..<300).map { record("s\($0)", String(format: "Title %04d", $0 * 3), 1950 + ($0 * 3) % 60) })
    }

    func testForwardAndBackwardPagingVisitEveryCardOnceInOrder() async throws {
        try await seedLargeCatalog()
        let expected = await allCards(scope()).map(\.id)
        XCTAssertEqual(Set(expected).count, expected.count)

        var window = UnifiedCatalogWindow()
        window.maximumCards = 150
        window.replace(with: await store.unifiedPage(scope(), direction: .forward(after: nil), limit: 37),
                       hasMoreBefore: false)
        var seen = window.cards.map(\.id)
        while window.hasMoreAfter {
            let before = window.cards.map(\.id)
            window.appendForward(await store.unifiedPage(scope(), direction: .forward(after: window.forwardCursor), limit: 37))
            XCTAssertLessThanOrEqual(window.cards.count, 150)
            XCTAssertEqual(Set(window.cards.map(\.id)).count, window.cards.count, "no duplicate card in the window")
            let added = window.cards.map(\.id).filter { !before.contains($0) }
            seen += added
        }
        XCTAssertEqual(seen, expected, "forward paging neither skips nor repeats a card")
        XCTAssertTrue(window.hasMoreBefore, "the trimmed head stays reachable")

        var back = window.cards.map(\.id)
        while window.hasMoreBefore {
            let before = Set(window.cards.map(\.id))
            window.prependBackward(await store.unifiedPage(scope(), direction: .backward(before: window.backwardCursor!), limit: 37))
            XCTAssertLessThanOrEqual(window.cards.count, 150)
            back = window.cards.map(\.id).filter { !before.contains($0) } + back
        }
        XCTAssertEqual(back, expected, "backward paging restores every trimmed card in order")
    }

    func testEvictedCardsAreRestoredIdenticallyAndRowsStayAligned() async throws {
        try await seedLargeCatalog()
        var window = UnifiedCatalogWindow()
        window.maximumCards = 120
        window.rowGranularity = 3
        window.replace(with: await store.unifiedPage(scope(), direction: .forward(after: nil)), hasMoreBefore: false)
        let firstScreen = Array(window.cards.prefix(30).map(\.id))
        for _ in 0..<3 {
            window.appendForward(await store.unifiedPage(scope(), direction: .forward(after: window.forwardCursor)))
        }
        XCTAssertFalse(window.cards.contains { firstScreen.contains($0.id) }, "the first screen was evicted")
        let anchor = window.cards[0].id
        var guardCount = 0
        while window.hasMoreBefore && guardCount < 50 {
            let before = window.cards.count
            let anchorIndex = window.cards.firstIndex { $0.id == anchor }
            window.prependBackward(await store.unifiedPage(scope(), direction: .backward(before: window.backwardCursor!)))
            if let anchorIndex, let now = window.cards.firstIndex(where: { $0.id == anchor }), window.hasMoreBefore {
                XCTAssertEqual((now - anchorIndex) % 3, 0, "prepends add whole rows: visible rows never reflow")
            }
            XCTAssertLessThanOrEqual(window.cards.count, 120)
            _ = before
            guardCount += 1
        }
        XCTAssertEqual(Array(window.cards.prefix(30).map(\.id)), firstScreen)
    }

    func testMatchGroupSplitByPageLimitIsCompleted() async throws {
        try await importSilo([record("s1", "Arrival", 2016)])
        try await importIPTV(p1, [iptv(p1, 1, "Arrival (2016)"), iptv(p1, 2, "Aardvark")])
        try await importIPTV(p2, [iptv(p2, 1, "Arrival (2016)")])
        // Limit 2 stops inside the Arrival group (Aardvark, then the first Arrival row).
        let page = await store.unifiedPage(scope(), direction: .forward(after: nil), limit: 2)
        let cards = UnifiedCatalogGrouping.cards(from: page.rows)
        XCTAssertEqual(cards.map(\.members.count), [1, 3])
        let tail = await store.unifiedPage(scope(), direction: .backward(before: UnifiedIndexCursor(sortKey: "zzz", matchKey: "", entryKey: "")), limit: 1)
        XCTAssertEqual(UnifiedCatalogGrouping.cards(from: tail.rows).map(\.members.count), [3])
    }

    func testBoundaryGroupHealsWhenANewSourceArrives() async throws {
        try await importIPTV(p1, [iptv(p1, 1, "Arrival (2016)"), iptv(p1, 2, "Zodiac (2007)")])
        var window = UnifiedCatalogWindow()
        window.replace(with: await store.unifiedPage(scope(), direction: .forward(after: nil), limit: 1), hasMoreBefore: false)
        XCTAssertEqual(window.cards.map(\.members.count), [1])
        // A Silo sync publishes the same title while the window is open.
        try await importSilo([record("s1", "Arrival", 2016)])
        window.appendForward(await store.unifiedPage(scope(), direction: .forward(after: window.forwardCursor), limit: 10))
        XCTAssertEqual(window.cards.map(\.title), ["Arrival", "Zodiac (2007)"])
        XCTAssertEqual(window.cards[0].members.count, 2, "the boundary card merged instead of duplicating")
    }

    func testStaleCursorAfterRefreshNeverDuplicates() async throws {
        try await importIPTV(p1, (0..<50).map { iptv(p1, $0, String(format: "Movie %02d", $0)) })
        let first = await store.unifiedPage(scope(), direction: .forward(after: nil), limit: 20)
        // A new generation replaces the catalog between two reads.
        try await importIPTV(p1, (0..<60).map { iptv(p1, $0 + 100, String(format: "Movie %02d", $0)) })
        let second = await store.unifiedPage(scope(), direction: .forward(after: first.rows.last?.cursor), limit: 100)
        XCTAssertTrue(second.rows.allSatisfy { $0.cursor.sortKey > first.rows.last!.cursor.sortKey })
        XCTAssertEqual(second.rows.count, 40, "the old cursor resumes after Movie 19 in the new generation")
    }

    // MARK: IPTV lifecycle

    func testStagedGenerationIsInvisibleUntilPromotedAndNeverMixed() async throws {
        try await importIPTV(p1, [iptv(p1, 1, "Old Title (2000)")], generation: "gen-a")
        try await importIPTV(p1, [iptv(p1, 2, "New Title (2001)")], generation: "gen-b", promote: false)
        let v2 = await allCards(scope()).map(\.title)
        XCTAssertEqual(v2, ["Old Title (2000)"])
        try await store.promote(providerID: p1, kind: .movie, generation: "gen-b")
        let v3 = await allCards(scope()).map(\.title)
        XCTAssertEqual(v3, ["New Title (2001)"])
        try await store.pruneOrphanedGenerations()
        let v4 = await store.unifiedRowCounts().iptvKeys
        XCTAssertEqual(v4, 1, "retired generation keys are pruned")
    }

    func testFailedImportDiscardsItsKeys() async throws {
        try await importIPTV(p1, [iptv(p1, 1, "Kept (2000)")], generation: "gen-a")
        try await importIPTV(p1, [iptv(p1, 2, "Dropped (2001)")], generation: "gen-b", promote: false)
        await store.discard(providerID: p1, kind: .movie, generation: "gen-b")
        let v5 = await store.unifiedRowCounts().iptvKeys
        XCTAssertEqual(v5, 1)
        let v6 = await allCards(scope()).map(\.title)
        XCTAssertEqual(v6, ["Kept (2000)"])
    }

    func testProviderRemovalAndDisabledProvidersAreExcluded() async throws {
        try await importSilo([record("s1", "Arrival", 2016)])
        try await importIPTV(p1, [iptv(p1, 1, "Arrival (2016)"), iptv(p1, 2, "Heat (1995)")])
        try await importIPTV(p2, [iptv(p2, 1, "Ronin (1998)")])

        let vodDisabled = await allCards(scope(providers: []))
        XCTAssertEqual(vodDisabled.map(\.title), ["Arrival"])
        XCTAssertTrue(vodDisabled[0].iptvItems.isEmpty)
        let v7 = await allCards(scope(providers: [p2])).map(\.title)
        XCTAssertEqual(v7, ["Arrival", "Ronin (1998)"])

        await store.remove(providerID: p1)
        let cards = await allCards(scope())
        XCTAssertEqual(cards.map(\.title), ["Arrival", "Ronin (1998)"])
        XCTAssertTrue(cards[0].iptvItems.isEmpty, "a removed provider leaves no source behind")
        let v8 = await store.unifiedRowCounts().iptvKeys
        XCTAssertEqual(v8, 1)
    }

    func testLegacyGenerationsAreBackfilledOnce() async throws {
        let generation = "legacy"
        try await store.stage([iptv(p1, 1, "Arrival (2016)")], generation: generation)
        try await store.promote(providerID: p1, kind: .movie, generation: generation)
        let v9 = await allCards(scope()).isEmpty
        XCTAssertTrue(v9, "a pre-Build 110 generation has no keys yet")
        let v10 = try await store.ensureUnifiedKeys()
        XCTAssertEqual(v10, 1)
        let v11 = try await store.ensureUnifiedKeys()
        XCTAssertEqual(v11, 0)
        let v12 = await allCards(scope()).map(\.title)
        XCTAssertEqual(v12, ["Arrival (2016)"])
    }

    // MARK: Silo snapshots and identity

    private func accountScope(_ account: String?, profile: String? = nil,
                              server: String = "server-a") -> String? {
        UnifiedSiloScope.make(serverID: server, serverURL: "https://silo.example",
                              accountID: account, profileID: profile)
    }

    func testAccountBoundScopeSeparatesAccountsWithoutProfilesAndProfileSwitches() async throws {
        let alice = try XCTUnwrap(accountScope("account-alice"))
        let bob = try XCTUnwrap(accountScope("account-bob"))
        let aliceProfile = try XCTUnwrap(accountScope("account-alice", profile: "profile-1"))
        XCTAssertNotEqual(alice, bob, "two accounts on the same server without profiles must not share a cache")
        XCTAssertNotEqual(alice, aliceProfile)
        XCTAssertNotEqual(alice, accountScope("account-alice", server: "server-b"))
        XCTAssertNil(accountScope(nil), "unverified account identity fails closed")
        XCTAssertNil(accountScope(""))

        try await importSilo([record("alice", "Alice Private", 2001)], scope: alice)
        let aliceCards = await allCards(scope(silo: alice, providers: [])).map(\.title)
        let bobCards = await allCards(scope(silo: bob, providers: [])).isEmpty
        let profileCards = await allCards(scope(silo: aliceProfile, providers: [])).isEmpty
        let anonymousCards = await allCards(scope(silo: nil, providers: [])).isEmpty
        XCTAssertEqual(aliceCards, ["Alice Private"])
        XCTAssertTrue(bobCards)
        XCTAssertTrue(profileCards)
        XCTAssertTrue(anonymousCards)
        try await store.purgeSilo(keepingScope: bob)
        let purged = await allCards(scope(silo: alice, providers: [])).isEmpty
        XCTAssertTrue(purged)
    }

    func testInterruptedSwitchAndRestartCannotExposePreviousAccount() async throws {
        let alice = try XCTUnwrap(accountScope("account-alice"))
        let bob = try XCTUnwrap(accountScope("account-bob"))
        try await importSilo([record("alice", "Alice Private", 2001)], scope: alice)
        try await store.stageSilo([record("bob", "Bob Partial", 2002)], scope: bob,
                                  libraryID: 1, kind: .movie, snapshot: "interrupted-switch")
        await store.close()
        store = try XtreamVODCatalogStore(directory: directory)
        let bobCards = await allCards(scope(silo: bob, providers: [])).isEmpty
        let anonymousCards = await allCards(scope(silo: nil, providers: [])).isEmpty
        XCTAssertTrue(bobCards,
                      "an unpromoted new-account snapshot is not visible after restart")
        XCTAssertTrue(anonymousCards)
        try await store.purgeSilo(keepingScope: bob)
        let aliceCards = await allCards(scope(silo: alice, providers: [])).isEmpty
        let activeCount = await store.unifiedRowCounts().siloActive
        XCTAssertTrue(aliceCards)
        XCTAssertEqual(activeCount, 0, "an interrupted staged snapshot remains private, not active")
    }

    func testLegacyAmbiguousScopeIsInvisibleAndPurged() async throws {
        let oldRaw = "server-a|https://silo.example|-"
        let legacy = SHA256.hash(data: Data(oldRaw.utf8)).map { String(format: "%02x", $0) }.joined()
        let alice = try XCTUnwrap(accountScope("account-alice"))
        XCTAssertNotEqual(legacy, alice)
        try await importSilo([record("old", "Legacy Private", 2001)], scope: legacy)
        let beforeRestart = await allCards(scope(silo: alice, providers: [])).isEmpty
        XCTAssertTrue(beforeRestart)
        await store.close()
        store = try XtreamVODCatalogStore(directory: directory)
        let afterRestart = await allCards(scope(silo: alice, providers: [])).isEmpty
        XCTAssertTrue(afterRestart,
                      "legacy ambiguous rows cannot appear under the new account after restart")
        try await store.purgeSilo(keepingScope: alice)
        let count = await store.unifiedRowCounts().siloItems
        XCTAssertEqual(count, 0)
    }

    func testPartialSnapshotIsInvisibleAndObsoleteTitlesGoOnlyAfterCompletion() async throws {
        try await importSilo([record("s1", "Arrival", 2016), record("s2", "Gone", 1999)])
        try await store.stageSilo([record("s1", "Arrival", 2016)], scope: scopeA, libraryID: 1, kind: .movie, snapshot: "partial")
        let v13 = await allCards(scope()).map(\.title)
        XCTAssertEqual(v13, ["Arrival", "Gone"], "the last complete snapshot stays")
        try await store.promoteSilo(scope: scopeA, libraryID: 1, kind: .movie, snapshot: "partial", itemCount: 1, syncedAt: Date())
        let v14 = await allCards(scope()).map(\.title)
        XCTAssertEqual(v14, ["Arrival"])
        let v15 = await store.unifiedRowCounts().siloItems
        XCTAssertEqual(v15, 1)
    }

    func testProfileScopesNeverSeeEachOthersTitles() async throws {
        try await importSilo([record("a1", "Private A", 2001)], scope: scopeA)
        try await importSilo([record("b1", "Private B", 2002)], scope: scopeB)
        let v16 = await allCards(scope(silo: scopeA, providers: [])).map(\.title)
        XCTAssertEqual(v16, ["Private A"])
        let v17 = await allCards(scope(silo: scopeB, providers: [])).map(\.title)
        XCTAssertEqual(v17, ["Private B"])
        let v18 = await allCards(scope(silo: nil, providers: [])).isEmpty
        XCTAssertTrue(v18)
        try await store.purgeSilo(keepingScope: scopeB)
        let v19 = await allCards(scope(silo: scopeA, providers: [])).isEmpty
        XCTAssertTrue(v19)
        try await store.purgeSilo(keepingScope: nil)
        let v20 = await store.unifiedRowCounts().siloItems
        XCTAssertEqual(v20, 0)
        let v21 = await store.unifiedRowCounts().siloActive
        XCTAssertEqual(v21, 0)
    }

    func testRevokedLibrariesAreDeletedAndHiddenLibrariesFiltered() async throws {
        try await importSilo([record("a", "Alpha", 2001)], library: 1)
        try await importSilo([record("b", "Beta", 2002)], library: 2)
        let v22 = await allCards(scope(libraries: [2], providers: [])).map(\.title)
        XCTAssertEqual(v22, ["Beta"])
        try await store.retainSiloLibraries(scope: scopeA, kind: .movie, libraryIDs: [1])
        let v23 = await allCards(scope(libraries: [1, 2], providers: [])).map(\.title)
        XCTAssertEqual(v23, ["Alpha"])
    }

    // MARK: Sync engine

    private struct FakeError: Error {}

    private func page(_ records: [UnifiedSiloRecord], next: Int?, startsOver: Bool = false,
                      scope: String = "scope-a") -> UnifiedSiloSyncPage<Int> {
        UnifiedSiloSyncPage(records: records, next: next, startsOver: startsOver, scope: scope)
    }

    func testSyncPublishesOnlyAFinishedWalk() async throws {
        let store = self.store!
        let pages = [page([record("1", "One", 2001)], next: 1), page([record("2", "Two", 2002)], next: nil)]
        let outcome = await UnifiedSiloSyncEngine.sync(store: store, scope: scopeA, libraryID: 1, kind: .movie,
                                                       freshness: nil, isCurrent: { true },
                                                       first: { pages[0] }, next: { pages[$0] })
        XCTAssertEqual(outcome, .synced(count: 2))
        let v24 = await allCards(scope(providers: [])).map(\.title)
        XCTAssertEqual(v24, ["One", "Two"])
        let fresh = await UnifiedSiloSyncEngine.sync(store: store, scope: scopeA, libraryID: 1, kind: .movie,
                                                     freshness: 3600, isCurrent: { true },
                                                     first: { XCTFail("no repeat scan"); return pages[0] },
                                                     next: { pages[$0] })
        XCTAssertEqual(fresh, .skippedFresh)
    }

    func testInterruptedSyncKeepsThePreviousSnapshot() async throws {
        let store = self.store!
        try await importSilo([record("old", "Old", 2000)])
        let outcome = await UnifiedSiloSyncEngine.sync(
            store: store, scope: scopeA, libraryID: 1, kind: .movie, freshness: nil, isCurrent: { true },
            first: { self.page([self.record("1", "New", 2001)], next: 1) },
            next: { (_: Int) -> UnifiedSiloSyncPage<Int> in throw FakeError() })
        XCTAssertEqual(outcome, .failed)
        let v25 = await allCards(scope(providers: [])).map(\.title)
        XCTAssertEqual(v25, ["Old"])
        let v26 = await store.unifiedRowCounts().siloItems
        XCTAssertEqual(v26, 1, "the partial snapshot was discarded")
    }

    func testRejectedCursorRestartsIntoAFreshSnapshot() async throws {
        let store = self.store!
        let pages = [
            page([record("1", "Before Rescan", 2001)], next: 1),
            page([record("2", "After Rescan", 2002)], next: 2, startsOver: true),
            page([record("3", "Tail", 2003)], next: nil)
        ]
        let outcome = await UnifiedSiloSyncEngine.sync(store: store, scope: scopeA, libraryID: 1, kind: .movie,
                                                       freshness: nil, isCurrent: { true },
                                                       first: { pages[0] }, next: { pages[$0] })
        XCTAssertEqual(outcome, .synced(count: 2))
        let restarted = await allCards(scope(providers: [])).map(\.title)
        XCTAssertEqual(restarted, ["After Rescan", "Tail"], "rows read before the rejected cursor are not reused")

        let looping = await UnifiedSiloSyncEngine.sync(
            store: store, scope: scopeA, libraryID: 1, kind: .movie, freshness: nil, isCurrent: { true },
            first: { pages[0] }, next: { _ in self.page([self.record("x", "Loop", 2004)], next: 1, startsOver: true) })
        XCTAssertEqual(looping, .failed)
        let v27 = await allCards(scope(providers: [])).map(\.title)
        XCTAssertEqual(v27, ["After Rescan", "Tail"])
    }

    func testIdentityChangeDuringSyncNeverPublishes() async throws {
        let store = self.store!
        let flag = IdentityFlag()
        let outcome = await UnifiedSiloSyncEngine.sync(
            store: store, scope: scopeA, libraryID: 1, kind: .movie, freshness: nil,
            isCurrent: { await flag.current },
            first: { self.page([self.record("1", "Mine", 2001)], next: 1) },
            next: { _ in await flag.change(); return self.page([self.record("2", "Theirs", 2002)], next: nil) })
        XCTAssertEqual(outcome, .identityChanged)
        let v28 = await store.unifiedRowCounts().siloItems
        XCTAssertEqual(v28, 0)

        let foreign = await UnifiedSiloSyncEngine.sync(
            store: store, scope: scopeA, libraryID: 1, kind: .movie, freshness: nil, isCurrent: { true },
            first: { self.page([self.record("1", "Other Profile", 2001)], next: nil, scope: "scope-b") },
            next: { _ in XCTFail(); return self.page([], next: nil) })
        XCTAssertEqual(foreign, .identityChanged, "a page read for another identity is refused")
        let v29 = await allCards(scope(providers: [])).isEmpty
        XCTAssertTrue(v29)
    }

    func testCancelledSyncDiscardsItsSnapshot() async throws {
        let store = self.store!
        let task = Task {
            await UnifiedSiloSyncEngine.sync(
                store: store, scope: self.scopeA, libraryID: 1, kind: .movie, freshness: nil, isCurrent: { true },
                first: { self.page([self.record("1", "One", 2001)], next: 1) },
                next: { _ in
                    try await Task.sleep(for: .seconds(5))
                    return self.page([], next: nil)
                })
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let v30 = await task.value
        XCTAssertEqual(v30, .cancelled)
        let v31 = await store.unifiedRowCounts().siloItems
        XCTAssertEqual(v31, 0)
    }

    // MARK: Detail routing

    func testDetailTargetsKeepEverySource() async throws {
        try await importSilo([record("s1", "Arrival", 2016), record("s2", "Zodiac", 2007)])
        try await importIPTV(p1, [iptv(p1, 1, "Arrival (2016)"), iptv(p1, 2, "Heat (1995)")])
        try await importIPTV(p2, [iptv(p2, 1, "Arrival (2016)"), iptv(p2, 2, "Heat (1995)")])
        let cards = await allCards(scope())
        XCTAssertEqual(cards.map(\.title), ["Arrival", "Heat (1995)", "Zodiac"])

        guard case let .silo(contentID, libraryID, _, alternates) = UnifiedDetailTarget(card: cards[0]) else {
            return XCTFail("a matched title opens the Silo detail")
        }
        XCTAssertEqual(contentID, "s1")
        XCTAssertEqual(libraryID, 1)
        XCTAssertEqual(Set(alternates.map(\.id)), [iptv(p1, 1, "").id, iptv(p2, 1, "").id])

        guard case let .iptv(primary, others) = UnifiedDetailTarget(card: cards[1]) else {
            return XCTFail("an IPTV-only title opens the IPTV detail")
        }
        XCTAssertEqual(Set([primary.id] + others.map(\.id)), [iptv(p1, 2, "").id, iptv(p2, 2, "").id])
        XCTAssertEqual(others.count, 1, "the second provider stays reachable")

        guard case let .silo(zodiac, _, _, none) = UnifiedDetailTarget(card: cards[2]) else {
            return XCTFail("a Silo-only title opens the Silo detail")
        }
        XCTAssertEqual(zodiac, "s2")
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: Universal Search preservation

    func testUnifiedKeysLeaveSearchAndCatalogRowsUnchanged() async throws {
        let items = [iptv(p1, 1, "Arrival (2016)"), iptv(p1, 2, "Arrival of the Fittest"), iptv(p1, 3, "Heat (1995)")]
        let generation = "search"
        try await store.stage(items, generation: generation)
        try await store.promote(providerID: p1, kind: .movie, generation: generation)
        let before = await store.page(providerID: p1, kind: .movie, query: "arriv")
        let count = await store.count(providerID: p1, kind: .movie)
        try await store.ensureUnifiedKeys()
        let after = await store.page(providerID: p1, kind: .movie, query: "arriv")
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(after.count, 2)
        let v32 = await store.count(providerID: p1, kind: .movie)
        XCTAssertEqual(v32, count)
        // Search's own grouping keeps its current-locale normalization.
        let entry = UnifiedVODEntry(id: "x", origin: .iptv(p1), kind: .movie, title: "Arrival (2016)", year: 2016)
        XCTAssertEqual(entry.normalizedTitle, "arrival")
        XCTAssertEqual(UnifiedCatalogKeys.normalizedTitle("Arrival (2016)", year: 2016), "arrival")
    }
}

private actor IdentityFlag {
    private(set) var current = true
    func change() { current = false }
}
#endif
