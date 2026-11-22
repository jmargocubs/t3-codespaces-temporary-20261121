import Foundation
import XCTest
@testable import Silo

final class LiveTVBrowsingContextTests: XCTestCase {
    private let provider = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let otherProvider = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private func channel(_ provider: UUID, _ suffix: String) -> LiveTVChannel {
        LiveTVChannel(id: "\(provider.uuidString):\(suffix)", guideID: nil, name: "News",
                      streamURL: URL(string: "https://user:password@stream.test/live?token=secret")!,
                      logoURL: nil, category: "News")
    }

    func testRoundTripRestoresFiltersSearchAndOpaquePositionForSameProvider() throws {
        let row = channel(provider, "opaque-channel-key")
        let original = LiveTVBrowsingContext(providerID: provider, category: "News", favoritesOnly: true,
                                             searchQuery: "morning news", channelID: row.id,
                                             offsetX: 820, offsetY: 416)
        let encoded = try XCTUnwrap(original.encoded())
        let decoded = try XCTUnwrap(LiveTVBrowsingContext.decoded(encoded, for: provider))
        XCTAssertEqual(decoded.validated(categories: ["News"], channels: [row]), original)
        XCTAssertNil(LiveTVBrowsingContext.decoded(encoded, for: otherProvider),
                     "provider-qualified context must not leak into another catalog")
        XCTAssertTrue(decoded.shouldPresentBrowser, "a hidden browser's saved state must be reopened before restoring its row")
    }

    func testHomeContextDoesNotReopenBrowserButSavedOffsetsDo() {
        let home = LiveTVBrowsingContext(providerID: provider, category: nil, favoritesOnly: false,
                                         searchQuery: "", channelID: nil, offsetX: nil, offsetY: nil)
        XCTAssertFalse(home.shouldPresentBrowser)
        let offset = LiveTVBrowsingContext(providerID: provider, category: nil, favoritesOnly: false,
                                           searchQuery: "", channelID: nil, offsetX: 0, offsetY: 420)
        XCTAssertTrue(offset.shouldPresentBrowser)
    }

    func testRemovedCategoryAndChannelFallBackToSafeDefaults() {
        let original = LiveTVBrowsingContext(providerID: provider, category: "Removed", favoritesOnly: true,
                                             searchQuery: "news", channelID: "\(provider.uuidString):gone",
                                             offsetX: 400, offsetY: 300)
        let restored = original.validated(categories: ["News"], channels: [])
        XCTAssertNil(restored.category)
        XCTAssertNil(restored.channelID)
        XCTAssertTrue(restored.favoritesOnly)
        XCTAssertEqual(restored.searchQuery, "news")
    }

    func testStateIsBoundedAndDoesNotPersistConnectionOrCredentialMaterial() throws {
        let original = LiveTVBrowsingContext(providerID: provider, category: String(repeating: "x", count: 500),
                                             favoritesOnly: false, searchQuery: "https://user:pass@example.test/?token=secret",
                                             channelID: String(repeating: "y", count: 2_000),
                                             offsetX: .infinity, offsetY: -1)
        let encoded = try XCTUnwrap(original.encoded())
        XCTAssertLessThanOrEqual(encoded.utf8.count, LiveTVBrowsingContext.maximumEncodedBytes)
        let decoded = try XCTUnwrap(LiveTVBrowsingContext.decoded(encoded, for: provider))
        XCTAssertLessThanOrEqual(decoded.category?.count ?? 0, LiveTVBrowsingContext.maximumCategoryCharacters)
        XCTAssertLessThanOrEqual(decoded.channelID?.count ?? 0, LiveTVBrowsingContext.maximumChannelIDCharacters)
        XCTAssertEqual(decoded.searchQuery, "")
        XCTAssertNil(decoded.offsetX)
        XCTAssertNil(decoded.offsetY)
        for sensitive in ["stream.test", "password", "token=secret"] {
            XCTAssertFalse(encoded.localizedCaseInsensitiveContains(sensitive))
        }
    }

    func testOversizedOrMalformedPersistedStateIsRejected() {
        XCTAssertNil(LiveTVBrowsingContext.decoded("{", for: provider))
        XCTAssertNil(LiveTVBrowsingContext.decoded(String(repeating: "x", count: 5_000), for: provider))
    }

    func testContextCollectionIsProviderIsolatedAndBounded() throws {
        var collection = LiveTVBrowsingContextCollection()
        var providers: [UUID] = []
        for index in 0..<12 {
            let id = UUID()
            providers.append(id)
            let value = LiveTVBrowsingContext(providerID: id, category: "Category \(index)", favoritesOnly: false,
                                              searchQuery: "search \(index)", channelID: nil, offsetX: nil, offsetY: nil)
            collection = collection.replacing(value)
        }
        let encoded = try XCTUnwrap(collection.encoded())
        let restored = try XCTUnwrap(LiveTVBrowsingContextCollection.decoded(encoded))
        XCTAssertLessThanOrEqual(restored.contexts.count, LiveTVBrowsingContextCollection.providerCapacity)
        XCTAssertEqual(restored.context(for: providers.last!)?.searchQuery, "search 11")
        XCTAssertNil(restored.context(for: providers.first!), "old provider snapshots are evicted at the fixed cap")
        XCTAssertLessThanOrEqual(encoded.utf8.count, LiveTVBrowsingContextCollection.maximumEncodedBytes)
    }

    func testDecodedCollectionReappliesPrivacySanitization() throws {
        let raw = #"{"contexts":[{"providerID":"11111111-1111-4111-8111-111111111111","category":"News","favoritesOnly":false,"searchQuery":"https://user:pass@example.test/?token=secret","channelID":"11111111-1111-4111-8111-111111111111:opaque","offsetX":12,"offsetY":24}]}"#
        let collection = try XCTUnwrap(LiveTVBrowsingContextCollection.decoded(raw))
        let context = try XCTUnwrap(collection.context(for: provider))
        XCTAssertEqual(context.searchQuery, "")
        let encoded = try XCTUnwrap(collection.encoded())
        XCTAssertFalse(encoded.contains("example.test"))
        XCTAssertFalse(encoded.contains("token=secret"))
    }

    // MARK: - Provider-specific readiness

    func testValidationWaitsForTheSnapshotsOwnProviderCatalog() throws {
        let row = channel(otherProvider, "sports-row")
        let saved = LiveTVBrowsingContext(providerID: otherProvider, category: "Sports", favoritesOnly: false,
                                          searchQuery: "", channelID: row.id, offsetX: 0, offsetY: 900,
                                          isBrowserVisible: true)
        XCTAssertNil(saved.validatedWhenReady(selectedProviderID: otherProvider, catalogIsLoaded: false,
                                              categories: [], channels: []),
                     "an unloaded catalog must not discard the saved category and row")
        XCTAssertNil(saved.validatedWhenReady(selectedProviderID: provider, catalogIsLoaded: true,
                                              categories: ["Sports"], channels: [row]),
                     "another provider's catalog never validates this snapshot")
        let kept = try XCTUnwrap(saved.validatedWhenReady(selectedProviderID: otherProvider, catalogIsLoaded: true,
                                                          categories: ["Sports"], channels: [row]))
        XCTAssertEqual(kept, saved)
        let pruned = try XCTUnwrap(saved.validatedWhenReady(selectedProviderID: otherProvider, catalogIsLoaded: true,
                                                            categories: ["News"], channels: []))
        XCTAssertNil(pruned.category, "a category the loaded catalog no longer has is dropped")
        XCTAssertNil(pruned.channelID, "a removed row is dropped")
        XCTAssertEqual(pruned.offsetY, 900, "the offset remains as the fallback position")
        XCTAssertEqual(pruned.isBrowserVisible, true)
    }

    // MARK: - Returning Home

    func testExplicitHomeChoiceWinsOverSavedBrowserState() {
        let home = LiveTVBrowsingContext(providerID: provider, category: "Sports", favoritesOnly: true,
                                         searchQuery: "", channelID: "\(provider.uuidString):row",
                                         offsetX: 0, offsetY: 420, isBrowserVisible: false)
        XCTAssertFalse(home.shouldPresentBrowser)
        var browsing = home
        browsing.isBrowserVisible = true
        XCTAssertTrue(browsing.shouldPresentBrowser)
    }

    func testOlderSnapshotsWithoutVisibilityKeepTheirPreviousMeaning() throws {
        let legacy = #"{"contexts":[{"providerID":"11111111-1111-4111-8111-111111111111","category":"Sports","favoritesOnly":false,"searchQuery":"","offsetX":0,"offsetY":420},{"providerID":"22222222-2222-4222-8222-222222222222","favoritesOnly":false,"searchQuery":""}]}"#
        let collection = try XCTUnwrap(LiveTVBrowsingContextCollection.decoded(legacy),
                                       "a snapshot written before the visibility field must still decode")
        let filtered = try XCTUnwrap(collection.context(for: provider))
        XCTAssertNil(filtered.isBrowserVisible)
        XCTAssertTrue(filtered.shouldPresentBrowser, "older browser snapshots still reopen the browser")
        XCTAssertFalse(try XCTUnwrap(collection.context(for: otherProvider)).shouldPresentBrowser)

        let home = filtered.returningHome()
        let reloaded = try XCTUnwrap(LiveTVBrowsingContextCollection.decoded(
            try XCTUnwrap(collection.replacing(home).encoded())))
        XCTAssertEqual(reloaded.context(for: provider)?.isBrowserVisible, false, "the Home choice survives a reload")
        XCTAssertFalse(try XCTUnwrap(reloaded.context(for: provider)).shouldPresentBrowser)
    }

    func testReturningHomeKeepsBrowsePositionButDropsSearch() {
        let row = "\(provider.uuidString):row"
        let category = LiveTVBrowsingContext(providerID: provider, category: "Sports", favoritesOnly: false,
                                             searchQuery: "", channelID: row, offsetX: 0, offsetY: 420,
                                             isBrowserVisible: true)
        let home = category.returningHome()
        XCTAssertEqual(home.isBrowserVisible, false)
        XCTAssertEqual(home.category, "Sports")
        XCTAssertEqual(home.channelID, row)
        XCTAssertEqual(home.offsetY, 420)

        let search = LiveTVBrowsingContext(providerID: provider, category: "Sports", favoritesOnly: true,
                                           searchQuery: "cnn", channelID: row, offsetX: 0, offsetY: 420,
                                           isBrowserVisible: true)
        let cleared = search.returningHome()
        XCTAssertEqual(cleared, LiveTVBrowsingContext(providerID: provider, category: nil, favoritesOnly: false,
                                                      searchQuery: "", channelID: nil, offsetX: nil, offsetY: nil,
                                                      isBrowserVisible: false),
                       "a search snapshot keeps no stale query, filters or result position")
    }

    func testHomeSnapshotResumesOnlyTheBrowserItCameFrom() throws {
        let row = "\(provider.uuidString):row"
        let home = LiveTVBrowsingContext(providerID: provider, category: "Sports", favoritesOnly: false,
                                         searchQuery: "", channelID: row, offsetX: 0, offsetY: 420,
                                         isBrowserVisible: false)
        let resumed = try XCTUnwrap(home.resumedBrowser(for: .category("Sports")))
        XCTAssertEqual(resumed.channelID, row)
        XCTAssertEqual(resumed.isBrowserVisible, true)
        XCTAssertNil(home.resumedBrowser(for: .category("News")))
        XCTAssertNil(home.resumedBrowser(for: .favorites))
        XCTAssertNil(home.resumedBrowser(for: .channels))

        var browsing = home
        browsing.isBrowserVisible = true
        XCTAssertNil(browsing.resumedBrowser(for: .category("Sports")), "only a Home snapshot is resumed this way")
        let positionless = LiveTVBrowsingContext(providerID: provider, category: "Sports", favoritesOnly: false,
                                                 searchQuery: "", channelID: nil, offsetX: nil, offsetY: nil,
                                                 isBrowserVisible: false)
        XCTAssertNil(positionless.resumedBrowser(for: .category("Sports")))
    }

    // MARK: - Guide restoration lifecycle

    func testGuideLeaveWhileCatalogLoadsKeepsPendingRowAndTimelineOffset() throws {
        let rowID = "\(provider.uuidString):saved-row"
        let saved = LiveTVBrowsingContext(providerID: provider, category: "Sports", favoritesOnly: true,
                                          searchQuery: "game", channelID: rowID, offsetX: 1_240, offsetY: 860)
        var restoration = LiveTVGuideBrowsingRestoration()
        restoration.begin(context: saved, providerID: provider)

        // This is the state at Guide.onDisappear: ScrollPosition was freshly initialized and has
        // no row or point yet. The save path must serialize the pending restore instead.
        let emptyPosition = LiveTVBrowsingContext(providerID: provider, category: "Sports", favoritesOnly: true,
                                                  searchQuery: "game", channelID: nil,
                                                  offsetX: nil, offsetY: nil)
        let save = try XCTUnwrap(restoration.contextToSave(providerID: provider,
                                                           restoredProviderID: provider,
                                                           current: emptyPosition))
        XCTAssertEqual(save, saved)
        XCTAssertEqual(LiveTVBrowsingContextCollection().replacing(save).context(for: provider)?.channelID, rowID)
        XCTAssertEqual(save.offsetX, 1_240, "the horizontal timeline offset survives leaving before load")
        XCTAssertEqual(save.offsetY, 860)
    }

    func testGuideReturnsAfterCatalogLoadsThenNewPositionReplacesRestoredSnapshot() throws {
        let row = channel(provider, "saved-row")
        let saved = LiveTVBrowsingContext(providerID: provider, category: "News", favoritesOnly: false,
                                          searchQuery: "", channelID: row.id, offsetX: 720, offsetY: 384)
        var collection = LiveTVBrowsingContextCollection().replacing(saved)
        var restoration = LiveTVGuideBrowsingRestoration()

        let encoded = try XCTUnwrap(collection.encoded())
        let decodedCollection = try XCTUnwrap(LiveTVBrowsingContextCollection.decoded(encoded))
        let decoded = try XCTUnwrap(decodedCollection.context(for: provider))
        restoration.begin(context: decoded, providerID: provider)
        XCTAssertNil(decoded.validatedWhenReady(selectedProviderID: provider, catalogIsLoaded: false,
                                                categories: [], channels: []),
                     "an unloaded catalog cannot prune the pending row or category")
        XCTAssertEqual(restoration.pendingContext?.channelID, row.id)

        let validated = try XCTUnwrap(decoded.validatedWhenReady(selectedProviderID: provider,
                                                                 catalogIsLoaded: true,
                                                                 categories: ["News"], channels: [row]))
        restoration.updatePendingContext(validated)
        XCTAssertEqual(validated.channelID, row.id)
        XCTAssertEqual(validated.offsetX, 720)
        XCTAssertEqual(validated.offsetY, 384)
        restoration.complete(context: validated) // Guide has issued row/offset restoration.

        let browsedPosition = LiveTVBrowsingContext(providerID: provider, category: "News", favoritesOnly: false,
                                                    searchQuery: "", channelID: "\(provider.uuidString):next-row",
                                                    offsetX: 1_600, offsetY: 1_280)
        let replacement = try XCTUnwrap(restoration.contextToSave(providerID: provider,
                                                                  restoredProviderID: provider,
                                                                  current: browsedPosition))
        collection = collection.replacing(replacement)
        XCTAssertEqual(collection.context(for: provider), browsedPosition,
                       "after restoration completes, genuine browsing replaces the old snapshot")
    }

    func testGuideProviderSwitchKeepsPendingSnapshotsIsolated() throws {
        let rowA = "\(provider.uuidString):row-a"
        let contextA = LiveTVBrowsingContext(providerID: provider, category: "News", favoritesOnly: false,
                                             searchQuery: "", channelID: rowA, offsetX: 300, offsetY: 450)
        let contextB = LiveTVBrowsingContext(providerID: otherProvider, category: "Sports", favoritesOnly: true,
                                             searchQuery: "", channelID: nil, offsetX: nil, offsetY: nil)
        var collection = LiveTVBrowsingContextCollection().replacing(contextA)
        var restoration = LiveTVGuideBrowsingRestoration()
        restoration.begin(context: contextA, providerID: provider)

        // Provider-change save occurs for the outgoing provider before the new context is loaded.
        let outgoing = try XCTUnwrap(restoration.contextToSave(providerID: provider,
                                                               restoredProviderID: provider,
                                                               current: contextB))
        XCTAssertEqual(outgoing, contextA)
        collection = collection.replacing(outgoing)
        restoration.begin(context: collection.context(for: otherProvider) ?? contextB,
                          providerID: otherProvider)
        let saveB = try XCTUnwrap(restoration.contextToSave(providerID: otherProvider,
                                                            restoredProviderID: otherProvider,
                                                            current: contextA))
        XCTAssertEqual(saveB, contextB, "a pending B restore, not A's current filter state, is saved for B")
        collection = collection.replacing(saveB)
        XCTAssertEqual(collection.context(for: provider), contextA,
                       "saving B cannot replace A's unresolved row and offset")

        // Returning to A restores its own still-pending row/offset, rather than B's empty state.
        collection = collection.replacing(contextB)
        restoration.begin(context: collection.context(for: provider), providerID: provider)
        XCTAssertEqual(restoration.pendingContext, contextA)
        XCTAssertEqual(restoration.contextToSave(providerID: provider, restoredProviderID: otherProvider,
                                                  current: contextB), contextA)
        XCTAssertEqual(collection.context(for: provider)?.offsetX, 300)
    }
}
