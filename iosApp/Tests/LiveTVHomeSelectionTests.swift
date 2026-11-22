import Foundation
import XCTest
@testable import Silo

final class LiveTVHomeSelectionTests: XCTestCase {
    func testLiveTVBackPolicyReturnsHomeFromBrowserAndExitsOnlyAtHome() {
        XCTAssertEqual(LiveTVNavigationPolicy.backDestination(showingBrowser: true), .home)
        XCTAssertEqual(LiveTVNavigationPolicy.backDestination(showingBrowser: false), .exitLiveTV)
        XCTAssertEqual(LiveTVNavigationPolicy.backLabel(showingBrowser: true), "Back to Live TV Home")
    }

    private func channel(_ name: String, provider: UUID) -> LiveTVChannel {
        LiveTVChannel(id: "\(provider.uuidString):\(name)", guideID: nil, name: name,
                      streamURL: URL(string: "https://stream.test/live")!, logoURL: nil, category: "News")
    }

    func testPreviewResolverScopesFavoritesAndRecentsToCurrentProvider() {
        let activeProvider = UUID()
        let otherProvider = UUID()
        let active = [channel("Most recent", provider: activeProvider), channel("Older", provider: activeProvider)]
        let unrelated = channel("Other provider", provider: otherProvider)
        let records = [LiveTVRecentChannel(providerID: activeProvider, channelID: active[0].id)!,
                       LiveTVRecentChannel(providerID: otherProvider, channelID: unrelated.id)!]
        let preview = LiveTVHomeChannelPreview.resolve(catalog: active + [unrelated],
                                                       favoriteIDs: Set([active[1].id, unrelated.id]),
                                                       recentRecords: records, providerID: activeProvider)
        XCTAssertEqual(preview.favorites.map(\.name), ["Older"])
        XCTAssertEqual(preview.recents.map(\.name), ["Most recent"])
        XCTAssertEqual(LiveTVHomeSelection.hero(from: preview.recents), active[0])
        XCTAssertEqual(LiveTVHomeSelection.hero(from: []), nil)
        let noGuideData = LiveTVProgramPair(current: nil, next: nil)
        XCTAssertNil(noGuideData.current, "the hero falls back to channel identity when EPG is absent")
    }

    func testEntryPointFiltersAreIsolatedAndHeaderRoutesStayDistinct() {
        XCTAssertEqual(LiveTVBrowserFilters.search(query: "news"), LiveTVBrowserFilters(query: "news"))
        XCTAssertEqual(LiveTVBrowserFilters.favorites, LiveTVBrowserFilters(query: "", category: nil, favoritesOnly: true))
        XCTAssertEqual(LiveTVBrowserFilters.category("Sports"), LiveTVBrowserFilters(query: "", category: "Sports"))
        XCTAssertEqual(LiveTVBrowserFilters.channels, LiveTVBrowserFilters())
        var fired: [String] = []
        let handlers: [(LiveTVHomeHeaderAction, String)] = [(.search, "search"), (.guide, "guide"), (.settings, "settings")]
        for (action, expected) in handlers {
            fired = []
            action.activate(search: { fired.append("search") }, guide: { fired.append("guide") },
                            settings: { fired.append("settings") })
            XCTAssertEqual(fired, [expected])
        }
        XCTAssertEqual(Set(LiveTVHomeHeaderAction.allCases).count, 3)
    }

    func testHomeQuickDestinationsRouteToExistingGuideAndBrowserActions() {
        var events: [String] = []
        let actions = LiveTVHomeActions(
            browse: { filters in
                if filters.favoritesOnly { events.append("favorite channels") }
                else if filters == .channels { events.append("all channels") }
            },
            showGuide: { events.append("guide") })

        for destination in LiveTVHomeQuickDestination.allCases {
            destination.activate(actions)
        }

        XCTAssertEqual(events, ["guide", "all channels", "favorite channels"])
        XCTAssertEqual(LiveTVHomeQuickDestination.favoriteChannels.title, "Favorite Channels")
        XCTAssertEqual(Set(LiveTVHomeQuickDestination.allCases.map(\.accessibilityIdentifier)).count, 3)
    }

    func testCachedCatalogErrorRemainsVisibleWhenListStateIsReady() {
        let state = LiveTVChannelListContentState.resolve(hasProviders: true, isLoading: false,
                                                          errorMessage: "Playback failed", channelCount: 2)
        XCTAssertEqual(state, .ready)
        XCTAssertEqual(LiveTVHomeErrorPresentation.message("Playback failed"), "Playback failed")
        XCTAssertNil(LiveTVHomeErrorPresentation.message(nil))
    }

    func testPreviewRebuildUsesReplacementCatalogAndChangedFavoritesAndRecents() {
        let provider = UUID()
        let first = channel("First name", provider: provider)
        let replacement = LiveTVChannel(id: first.id, guideID: nil, name: "Updated name",
                                        streamURL: first.streamURL, logoURL: nil, category: first.category)
        let record = LiveTVRecentChannel(providerID: provider, channelID: first.id)!
        let initial = LiveTVHomeChannelPreview.resolve(catalog: [first], favoriteIDs: [first.id],
                                                       recentRecords: [record], providerID: provider)
        XCTAssertEqual(initial.favorites.first?.name, "First name")
        XCTAssertEqual(initial.recents.first?.name, "First name")
        let updated = LiveTVHomeChannelPreview.resolve(catalog: [replacement], favoriteIDs: [],
                                                       recentRecords: [], providerID: provider)
        XCTAssertTrue(updated.favorites.isEmpty)
        XCTAssertTrue(updated.recents.isEmpty)
        let refreshed = LiveTVHomeChannelPreview.resolve(catalog: [replacement], favoriteIDs: [replacement.id],
                                                         recentRecords: [record], providerID: provider)
        XCTAssertEqual(refreshed.favorites.first?.name, "Updated name")
        XCTAssertEqual(refreshed.recents.first?.name, "Updated name")
    }

    func testCatalogCompletenessPersistsThreeWayMeaning() throws {
        XCTAssertEqual(LiveTVCatalogStatus(truncated: false), .complete)
        XCTAssertEqual(LiveTVCatalogStatus(truncated: true), .truncated)
        XCTAssertEqual(LiveTVCatalogStatus(truncated: nil), .unknown)
        let oldPayload = #"{"id":"11111111-1111-4111-8111-111111111111","name":"Old","channelCount":42}"#
        let oldProvider = try JSONDecoder().decode(LiveTVProvider.self, from: Data(oldPayload.utf8))
        XCTAssertNil(oldProvider.catalogWasTruncated)
    }

    func testPreviewRailsAreBoundedAndHandleEmptyData() {
        let provider = UUID()
        let channels = (0..<15).map { channel("Channel \($0)", provider: provider) }
        XCTAssertEqual(LiveTVHomeSelection.lineup(from: channels).count, 12)
        XCTAssertEqual(LiveTVHomeSelection.recents(from: channels).count, 10)
        XCTAssertEqual(LiveTVHomeSelection.categories(from: (0..<20).map(String.init)).count, 8)
        XCTAssertTrue(LiveTVHomeSelection.lineup(from: []).isEmpty)
        XCTAssertTrue(LiveTVHomeSelection.recents(from: [], limit: 0).isEmpty)
        XCTAssertTrue(LiveTVHomeSelection.categories(from: []).isEmpty)
        XCTAssertNil(channels[0].logoURL, "missing logos remain valid home data")
    }
}
