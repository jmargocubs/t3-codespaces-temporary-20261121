import Foundation
import XCTest
@testable import Silo

@MainActor
final class LiveTVGuideTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private func program(_ start: String, _ end: String, _ title: String = "Show") -> EPGProgram {
        EPGProgram(channelID: "a", start: date(start), end: date(end), title: title)
    }

    private func channel(_ id: String) -> LiveTVChannel {
        LiveTVChannel(id: id, guideID: id, name: "Channel \(id)",
                      streamURL: URL(string: "https://fixture.invalid/\(id).m3u8")!,
                      logoURL: nil, category: "News")
    }

    private func cachedPrograms(for id: String, title: String = "Show") -> [EPGProgram] {
        [EPGProgram(channelID: id, start: date("2026-01-01T12:00:00Z"),
                    end: date("2026-01-01T13:00:00Z"), title: title)]
    }

    // MARK: - Timeline

    func testCategoryPickerStartsAtSelectionThenRestoresLastVisibleRow() {
        let provider = UUID()
        var state = LiveTVGuideCategoryPickerState()
        let categories = ["News", "Sports", "Movies"]
        XCTAssertEqual(state.target(providerID: provider, selectedCategory: "Sports", categories: categories),
                       .category("Sports"))

        state.remember(.category("Movies"), providerID: provider, categories: categories)
        XCTAssertEqual(state.target(providerID: provider, selectedCategory: "Sports", categories: categories),
                       .category("Movies"), "later presentations restore the prior visible row")
    }

    func testCategoryPickerKeepsProviderPositionsAndUsesDistinctAllID() {
        let firstProvider = UUID()
        let secondProvider = UUID()
        var state = LiveTVGuideCategoryPickerState()
        state.remember(.category("News"), providerID: firstProvider, categories: ["News"])
        state.remember(.allCategories, providerID: secondProvider, categories: ["News"])

        XCTAssertEqual(state.target(providerID: firstProvider, selectedCategory: nil, categories: ["News"]),
                       .category("News"))
        XCTAssertEqual(state.target(providerID: secondProvider, selectedCategory: "News", categories: ["News"]),
                       .allCategories)
        XCTAssertNotEqual(LiveTVGuideCategoryPickerID.allCategories, .category("All Categories"))
    }

    func testCategoryPickerFallsBackWhenRememberedCategoryIsRemoved() {
        let provider = UUID()
        var state = LiveTVGuideCategoryPickerState()
        state.remember(.category("Sports"), providerID: provider, categories: ["News", "Sports"])
        state.reconcile(providerID: provider, categories: ["News"])

        XCTAssertEqual(state.target(providerID: provider, selectedCategory: "News", categories: ["News"]),
                       .category("News"))
        XCTAssertEqual(state.target(providerID: provider, selectedCategory: nil, categories: ["News"]),
                       .allCategories)
    }

    func testCategoryPickerFiltersCaseInsensitivelyAndTrimsQuery() {
        let categories = ["News", "Sports", "Movies"]
        XCTAssertEqual(LiveTVGuideCategoryPickerModel.filteredCategories(categories, query: "  SPORT "), ["Sports"])
        XCTAssertEqual(LiveTVGuideCategoryPickerModel.filteredCategories(categories, query: ""), categories)
    }

    func testCategoryPickerFrequentCategoriesPrioritizeFavoritesThenChannelCount() {
        let providerChannels = [
            LiveTVChannel(id: "news-1", guideID: nil, name: "News 1", streamURL: URL(string: "https://example.invalid/1")!, logoURL: nil, category: "News"),
            LiveTVChannel(id: "sports-1", guideID: nil, name: "Sports 1", streamURL: URL(string: "https://example.invalid/2")!, logoURL: nil, category: "Sports"),
            LiveTVChannel(id: "sports-2", guideID: nil, name: "Sports 2", streamURL: URL(string: "https://example.invalid/3")!, logoURL: nil, category: "Sports"),
            LiveTVChannel(id: "movies-1", guideID: nil, name: "Movies 1", streamURL: URL(string: "https://example.invalid/4")!, logoURL: nil, category: "Movies")
        ]
        XCTAssertEqual(
            LiveTVGuideCategoryPickerModel.frequentCategories(
                categories: ["News", "Sports", "Movies"], channels: providerChannels, favoriteIDs: ["news-1"]),
            ["News", "Sports", "Movies"])
    }

    func testHomeBrowserAndGuidePickerPositionsRemainIndependent() {
        let provider = UUID()
        let categories = ["News", "Sports", "Movies"]
        var home = LiveTVGuideCategoryPickerState()
        var browser = LiveTVGuideCategoryPickerState()
        var guide = LiveTVGuideCategoryPickerState()
        home.remember(.category("News"), providerID: provider, categories: categories)
        browser.remember(.category("Sports"), providerID: provider, categories: categories)
        guide.remember(.category("Movies"), providerID: provider, categories: categories)

        XCTAssertEqual(home.target(providerID: provider, selectedCategory: nil, categories: categories), .category("News"))
        XCTAssertEqual(browser.target(providerID: provider, selectedCategory: nil, categories: categories), .category("Sports"))
        XCTAssertEqual(guide.target(providerID: provider, selectedCategory: nil, categories: categories), .category("Movies"))
    }

    func testTimelineAlignsToLocalHalfHoursAndBoundsTheWindow() throws {
        let now = date("2026-01-01T12:17:00Z")
        let timeline = LiveTVGuideTimeline(now: now, timeZone: utc)
        XCTAssertEqual(timeline.start, date("2026-01-01T11:00:00Z"))
        XCTAssertEqual(timeline.end, date("2026-01-02T00:30:00Z"))
        XCTAssertEqual(timeline.width, 13.5 * 60 * 4)
        XCTAssertEqual(timeline.x(for: now), 77 * 4)
        XCTAssertEqual(timeline.x(for: .distantPast), 0, "positions clamp to the window")
        XCTAssertEqual(timeline.x(for: .distantFuture), timeline.width)
        XCTAssertEqual(timeline.ticks.count, 27)
        XCTAssertEqual(timeline.ticks.prefix(3).map(\.isHour), [true, false, true])

        // Nepal is UTC+5:45; ticks still fall on local :00 and :30.
        let nepal = try XCTUnwrap(TimeZone(identifier: "Asia/Kathmandu"))
        let local = LiveTVGuideTimeline(now: date("2026-01-01T12:00:00Z"), timeZone: nepal)
        XCTAssertEqual(local.start, date("2026-01-01T10:45:00Z"), "16:30 local")
        XCTAssertEqual(local.ticks.prefix(2).map(\.isHour), [false, true])
    }

    func testDaylightSavingKeepsRealWidthsAndLocalHourTicks() throws {
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        // 01:10 EST, the second 1 a.m. on the fall-back night.
        let timeline = LiveTVGuideTimeline(now: date("2026-11-01T06:10:00Z"), timeZone: newYork)
        XCTAssertEqual(timeline.start, date("2026-11-01T05:00:00Z"), "01:00 EDT")
        XCTAssertEqual(timeline.ticks.prefix(5).map(\.isHour), [true, false, true, false, true],
                       "both 1 a.m. hours get an hour tick")
        let cells = LiveTVGuideCell.cells(for: [program("2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z")], in: timeline)
        XCTAssertEqual(cells.first?.width, 60 * 4, "a programme across the change keeps its real hour")
    }

    func testRebuildAndScrollTargets() {
        let now = date("2026-01-01T12:17:00Z")
        let timeline = LiveTVGuideTimeline(now: now, timeZone: utc)
        XCTAssertFalse(timeline.needsRebuild(at: now))
        XCTAssertTrue(timeline.needsRebuild(at: timeline.end.addingTimeInterval(-2 * 3_600)))
        XCTAssertTrue(timeline.needsRebuild(at: timeline.start.addingTimeInterval(-1)))
        XCTAssertEqual(timeline.scrollOffset(showing: now), (77 - 30) * 4)
        XCTAssertEqual(timeline.scrollOffset(showing: timeline.start), 0)
    }

    // MARK: - Cells and selection

    func testCellsClipToTheWindowAndKeepAMinimumWidth() {
        let timeline = LiveTVGuideTimeline(now: date("2026-01-01T12:00:00Z"), timeZone: utc)
        let cells = LiveTVGuideCell.cells(for: [
            program("2026-01-01T09:00:00Z", "2026-01-01T11:30:00Z", "Started early"),
            program("2026-01-01T08:00:00Z", "2026-01-01T09:00:00Z", "Outside"),
            program("2026-01-01T12:00:00Z", "2026-01-01T12:00:30Z", "Blip"),
            program("2026-01-02T03:00:00Z", "2026-01-02T04:00:00Z", "Too late"),
        ], in: timeline)
        XCTAssertEqual(cells.map(\.program.title), ["Started early", "Blip"])
        XCTAssertEqual(cells[0].x, 0)
        XCTAssertEqual(cells[0].width, 30 * 4)
        XCTAssertTrue(cells[0].startsBeforeWindow)
        XCTAssertEqual(cells[1].x, 60 * 4)
        XCTAssertEqual(cells[1].width, LiveTVGuideCell.minimumWidth)
        XCTAssertFalse(cells[1].startsBeforeWindow)
    }

    func testOnlyTheAiringProgrammeTunesAndBoundariesAreHalfOpen() {
        let show = program("2026-01-01T12:00:00Z", "2026-01-01T13:00:00Z")
        XCTAssertEqual(LiveTVGuideProgramState(show, at: date("2026-01-01T11:59:59Z")), .upcoming)
        XCTAssertEqual(LiveTVGuideProgramState(show, at: date("2026-01-01T12:00:00Z")), .current)
        XCTAssertEqual(LiveTVGuideProgramState(show, at: date("2026-01-01T13:00:00Z")), .past)
        XCTAssertEqual(LiveTVGuideAction(show, at: date("2026-01-01T12:30:00Z")), .tune)
        XCTAssertEqual(LiveTVGuideAction(show, at: date("2026-01-01T11:00:00Z")), .showDetails, "upcoming never plays")
        XCTAssertEqual(LiveTVGuideAction(show, at: date("2026-01-01T14:00:00Z")), .showDetails)
    }

    func testIndexedGuideFeedsCellsAndSelection() throws {
        let now = date("2026-01-01T12:15:00Z")
        let xml = """
        <tv>
          <programme channel="news" start="20260101120000 +0000" stop="20260101130000 +0000"><title>Bulletin</title></programme>
          <programme channel="news" start="20260101130000 +0000" stop="20260101140000 +0000"><title>Debate</title></programme>
        </tv>
        """
        let index = try EPGIndex(document: XMLTVParser.parse(Data(xml.utf8)), fetchedAt: now, now: now, limits: EPGLimits())
        let timeline = LiveTVGuideTimeline(now: now, timeZone: utc)
        let key = try XCTUnwrap(index.channelKey(guideID: "NEWS", name: nil))
        let cells = LiveTVGuideCell.cells(for: index.programs(channelKey: key, overlapping: timeline.interval), in: timeline)
        XCTAssertEqual(cells.map(\.program.title), ["Bulletin", "Debate"])
        XCTAssertEqual(cells.map { LiveTVGuideAction($0.program, at: now) }, [.tune, .showDetails])
        XCTAssertEqual(cells[1].x, cells[0].x + cells[0].width, "adjacent programmes leave no gap")
    }

    func testVisibleSpanBuildsNearbyCellsAndChangesOnlyAtWholeHours() {
        let hour: CGFloat = 240
        let timeline = LiveTVGuideTimeline(now: date("2026-01-01T12:00:00Z"), timeZone: utc)
        let base = date("2026-01-01T11:00:00Z")
        let cells = LiveTVGuideCell.cells(for: (0..<26).map { slot in
            EPGProgram(channelID: "a", start: base.addingTimeInterval(TimeInterval(slot) * 1_800),
                       end: base.addingTimeInterval(TimeInterval(slot + 1) * 1_800), title: "P\(slot)")
        }, in: timeline)
        XCTAssertGreaterThan(cells.count, 15)

        let near = LiveTVGuideVisibleSpan(offsetX: 500, viewportWidth: 314, bucketWidth: hour)
        XCTAssertEqual(near, LiveTVGuideVisibleSpan(offsetX: 719, viewportWidth: 314, bucketWidth: hour), "same hour, same span")
        XCTAssertNotEqual(near, LiveTVGuideVisibleSpan(offsetX: 721, viewportWidth: 314, bucketWidth: hour))
        let built = cells.filter(near.renders)
        XCTAssertLessThan(built.count, cells.count / 2, "most of the window is not built")
        // Everything that overlaps the screen is built, wherever the offset lands in its hour.
        for offset in stride(from: CGFloat(480), to: 720, by: 7) {
            for cell in cells where cell.x < offset + 314 && cell.x + cell.width > offset {
                XCTAssertTrue(near.renders(cell), "offset \(offset)")
            }
        }
        // A cell can straddle the leading edge only if it is flagged, so unflagged titles never need to move.
        for offset in stride(from: CGFloat(480), to: 720, by: 7) {
            for cell in cells where cell.x < offset && cell.x + cell.width > offset {
                XCTAssertTrue(near.pinsTitle(of: cell), "offset \(offset)")
            }
        }
        XCTAssertLessThan(built.filter(near.pinsTitle).count, 5)
        let atStart = LiveTVGuideVisibleSpan(offsetX: -50, viewportWidth: 300, bucketWidth: hour)
        XCTAssertEqual(atStart.render.lowerBound, 0, "an overscrolled start clamps to the window")
    }

    // MARK: - Cell cache

    @MainActor
    func testCellCacheEnforcesCapacityAndEvictsLeastRecentlyUsedRows() {
        let cache = LiveTVGuideCellCache()
        let timeline = LiveTVGuideTimeline(now: date("2026-01-01T12:00:00Z"), timeZone: utc)
        var builds = 0
        func load(_ id: String, revision: Int = 1) -> [LiveTVGuideCell] {
            cache.cells(for: channel(id), revision: revision, isGuideStale: false, timeline: timeline) {
                builds += 1
                return cachedPrograms(for: id)
            }
        }

        for index in 0..<LiveTVGuideCellCache.capacity { _ = load("\(index)") }
        _ = load("0") // Promote the oldest row before inserting two more.
        _ = load("\(LiveTVGuideCellCache.capacity)")
        _ = load("\(LiveTVGuideCellCache.capacity + 1)")

        XCTAssertEqual(cache.entryCount, LiveTVGuideCellCache.capacity)
        XCTAssertEqual(cache.evictionCount, 2)
        XCTAssertEqual(cache.hitCount, 1)
        XCTAssertEqual(builds, LiveTVGuideCellCache.capacity + 2)

        _ = load("1") // Row 1 was the least-recently-used row after row 0 was promoted.
        XCTAssertEqual(cache.missCount, LiveTVGuideCellCache.capacity + 3)
        XCTAssertEqual(cache.entryCount, LiveTVGuideCellCache.capacity)
    }

    @MainActor
    func testCellCacheRevisionAndTimelineChangesDiscardOldProgrammeCells() {
        let cache = LiveTVGuideCellCache()
        let firstTimeline = LiveTVGuideTimeline(now: date("2026-01-01T12:00:00Z"), timeZone: utc)
        let secondTimeline = LiveTVGuideTimeline(now: date("2026-01-01T13:00:00Z"), timeZone: utc)
        let row = channel("one")
        var builds = 0

        let first = cache.cells(for: row, revision: 1, isGuideStale: false, timeline: firstTimeline) {
            builds += 1
            return cachedPrograms(for: row.id, title: "Old programme")
        }
        let revised = cache.cells(for: row, revision: 2, isGuideStale: false, timeline: firstTimeline) {
            builds += 1
            return cachedPrograms(for: row.id, title: "New programme")
        }
        let retimed = cache.cells(for: row, revision: 2, isGuideStale: false, timeline: secondTimeline) {
            builds += 1
            return cachedPrograms(for: row.id, title: "Retimed programme")
        }

        XCTAssertEqual(first.first?.program.title, "Old programme")
        XCTAssertEqual(revised.first?.program.title, "New programme")
        XCTAssertEqual(retimed.first?.program.title, "Retimed programme")
        XCTAssertEqual(builds, 3)
        XCTAssertEqual(cache.entryCount, 1)
        XCTAssertEqual(cache.hitCount, 0)
    }

    @MainActor
    func testCellCacheStoresEmptyRowsAndBoundsLargeVerticalSurfing() {
        let cache = LiveTVGuideCellCache()
        let timeline = LiveTVGuideTimeline(now: date("2026-01-01T12:00:00Z"), timeZone: utc)
        for index in 0..<20_000 {
            _ = cache.cells(for: channel("\(index)"), revision: 1, isGuideStale: false, timeline: timeline) { [] }
        }

        XCTAssertEqual(cache.entryCount, LiveTVGuideCellCache.capacity)
        XCTAssertEqual(cache.missCount, 20_000)
        XCTAssertEqual(cache.evictionCount, 20_000 - LiveTVGuideCellCache.capacity)

        for index in (20_000 - LiveTVGuideCellCache.capacity)..<20_000 {
            _ = cache.cells(for: channel("\(index)"), revision: 1, isGuideStale: false, timeline: timeline) { XCTFail("recent row should be cached"); return [] }
        }
        XCTAssertEqual(cache.hitCount, LiveTVGuideCellCache.capacity)
        XCTAssertEqual(cache.entryCount, LiveTVGuideCellCache.capacity)
    }

    @MainActor
    func testCellCacheTargetedRevisionInvalidatesOnlyAffectedRow() {
        let cache = LiveTVGuideCellCache()
        let timeline = LiveTVGuideTimeline(now: date("2026-01-01T12:00:00Z"), timeZone: utc)
        let rows = [channel("a"), channel("b"), channel("c")]
        func load(_ row: LiveTVChannel, channelRevision: Int = 0) -> [LiveTVGuideCell] {
            cache.cells(for: row, revision: 1, isGuideStale: false, timeline: timeline,
                        channelRevision: channelRevision) {
                cachedPrograms(for: row.id, title: "\(row.id)-\(channelRevision)")
            }
        }

        rows.forEach { _ = load($0) }
        let updated = load(rows[0], channelRevision: 1)
        _ = load(rows[1])
        _ = load(rows[2])

        XCTAssertEqual(updated.first?.program.title, "a-1")
        XCTAssertEqual(cache.targetedInvalidationCount, 1)
        XCTAssertEqual(cache.globalInvalidationCount, 0)
        XCTAssertEqual(cache.entryCount, 3)
        XCTAssertEqual(cache.missCount, 4)
        XCTAssertEqual(cache.hitCount, 2, "unrelated rows remain cached")
    }

    @MainActor
    func testCellCacheMultipleChannelUpdatesAndGlobalChangesRemainBounded() {
        let cache = LiveTVGuideCellCache()
        let firstTimeline = LiveTVGuideTimeline(now: date("2026-01-01T12:00:00Z"), timeZone: utc)
        let secondTimeline = LiveTVGuideTimeline(now: date("2026-01-01T13:00:00Z"), timeZone: utc)
        let rows = [channel("a"), channel("b"), channel("c")]
        func load(_ row: LiveTVChannel, revision: Int = 1, channelRevision: Int = 0,
                  timeline: LiveTVGuideTimeline) {
            _ = cache.cells(for: row, revision: revision, isGuideStale: false, timeline: timeline,
                            channelRevision: channelRevision) {
                cachedPrograms(for: row.id, title: "\(revision)-\(channelRevision)")
            }
        }

        rows.forEach { load($0, timeline: firstTimeline) }
        load(rows[0], channelRevision: 1, timeline: firstTimeline)
        load(rows[2], channelRevision: 1, timeline: firstTimeline)
        load(rows[1], timeline: firstTimeline) // unrelated row remains a hit
        XCTAssertEqual(cache.targetedInvalidationCount, 2)
        XCTAssertEqual(cache.entryCount, 3)
        XCTAssertEqual(cache.hitCount, 1)

        load(rows[0], revision: 2, timeline: firstTimeline) // full/provider refresh
        XCTAssertEqual(cache.globalInvalidationCount, 1)
        XCTAssertEqual(cache.entryCount, 1)
        load(rows[0], revision: 2, timeline: secondTimeline) // timeline change is global too
        XCTAssertEqual(cache.globalInvalidationCount, 2)
        XCTAssertEqual(cache.entryCount, 1)
    }

    @MainActor
    func testCellCacheTargetedInvalidationPreservesLRUOrder() {
        let cache = LiveTVGuideCellCache()
        let timeline = LiveTVGuideTimeline(now: date("2026-01-01T12:00:00Z"), timeZone: utc)
        func load(_ id: String, channelRevision: Int = 0) {
            _ = cache.cells(for: channel(id), revision: 1, isGuideStale: false, timeline: timeline,
                            channelRevision: channelRevision) { cachedPrograms(for: id) }
        }

        for index in 0..<LiveTVGuideCellCache.capacity { load("row-\(index)") }
        load("row-0")
        load("row-0", channelRevision: 1) // replacement touches, but does not allocate another entry
        load("new-row")
        load("row-0", channelRevision: 1)

        XCTAssertEqual(cache.targetedInvalidationCount, 1)
        XCTAssertEqual(cache.evictionCount, 1)
        XCTAssertEqual(cache.hitCount, 2)
        XCTAssertEqual(cache.entryCount, LiveTVGuideCellCache.capacity)
        load("row-1") // row 1 was still the least-recently-used row
        XCTAssertEqual(cache.missCount, LiveTVGuideCellCache.capacity + 3)
    }

    @MainActor
    func testCellCacheRepeatedShortUpdatesRetainUnrelatedRows() {
        let cache = LiveTVGuideCellCache()
        let timeline = LiveTVGuideTimeline(now: date("2026-01-01T12:00:00Z"), timeZone: utc)
        let rows = (0..<LiveTVGuideCellCache.capacity).map { channel("row-\($0)") }
        func load(_ row: LiveTVChannel, channelRevision: Int = 0) {
            _ = cache.cells(for: row, revision: 1, isGuideStale: false, timeline: timeline,
                            channelRevision: channelRevision) { cachedPrograms(for: row.id) }
        }

        rows.forEach { load($0) }
        for revision in 1...100 {
            load(rows[0], channelRevision: revision)
            rows.dropFirst().forEach { load($0) }
        }

        XCTAssertEqual(cache.missCount, LiveTVGuideCellCache.capacity + 100,
                       "only the changed row is reconstructed per publication")
        XCTAssertEqual(cache.targetedInvalidationCount, 100)
        XCTAssertEqual(cache.hitCount, 95 * 100)
        XCTAssertEqual(cache.evictionCount, 0)
        XCTAssertEqual(cache.entryCount, LiveTVGuideCellCache.capacity)
    }

    // MARK: - States

    func testContentStateCoversSetupLoadingErrorsAndFilters() {
        func state(providers: Bool = true, loading: Bool = false, error: String? = nil,
                   channels: Int = 10, visible: Int = 10) -> LiveTVGuideContentState {
            .resolve(hasProviders: providers, isLoading: loading, errorMessage: error, channelCount: channels, visibleCount: visible)
        }
        XCTAssertEqual(state(providers: false, channels: 0, visible: 0), .setup)
        XCTAssertEqual(state(loading: true, channels: 0, visible: 0), .loading)
        XCTAssertEqual(state(error: "Down", channels: 0, visible: 0), .failed("Down"))
        XCTAssertEqual(state(channels: 0, visible: 0), .noChannels)
        XCTAssertEqual(state(visible: 0), .noMatches)
        XCTAssertEqual(state(loading: true), .ready, "a refresh keeps the current grid on screen")
        XCTAssertEqual(state(error: "Down"), .ready, "a failed refresh keeps the last channels")
    }

    func testGuideSearchMatchesChannelListAndIntersectsCategoryAndFavorites() async {
        let channels = [
            LiveTVChannel(id: "one", guideID: nil, name: "North News", streamURL: URL(string: "https://test/1")!,
                          logoURL: nil, category: "Local News"),
            LiveTVChannel(id: "two", guideID: nil, name: "North Sports", streamURL: URL(string: "https://test/2")!,
                          logoURL: nil, category: "Sports"),
            LiveTVChannel(id: "three", guideID: nil, name: "World News", streamURL: URL(string: "https://test/3")!,
                          logoURL: nil, category: "News"),
        ]
        let favorites: Set<String> = ["one", "two"]
        let search = LiveTVChannelSearchModel()
        search.update(channels: channels, query: "north", category: nil, favoritesOnly: false,
                      favoriteIDs: favorites, debounce: .zero, includeGroups: false)
        await search.waitForCurrentSearch()
        let channelListMatches = LiveTVChannelFiltering.filter(channels, query: "north", category: nil,
                                                               favoritesOnly: false, favoriteIDs: favorites)
        XCTAssertEqual(search.matches, channelListMatches)
        let selection = LiveTVPresentation(scheduler: LiveTVTaskScheduler())
        XCTAssertEqual(selection.select(search.matches[0], from: .guide), .present)
        XCTAssertEqual(selection.channel(for: .guide)?.id, channelListMatches[0].id,
                       "a search result retains its channel identity through the existing guide selection path")

        search.update(channels: channels, query: "news", category: "Local News", favoritesOnly: true,
                      favoriteIDs: favorites, debounce: .zero, includeGroups: false)
        await search.waitForCurrentSearch()
        XCTAssertEqual(search.matches.map(\.id), ["one"], "search, category, and favorites are ANDed")
        XCTAssertTrue(search.groups.isEmpty, "guide searches do not retain an extra grouped catalog result")
    }

    func testGuideSearchEmptyClearRestoresFilteredContextAndProviderSwitchRejectsStaleResults() async {
        func fixture(_ prefix: String) -> [LiveTVChannel] {
            ["North News", "World News"].enumerated().map { index, name in
                LiveTVChannel(id: "\(prefix)-\(index)", guideID: nil, name: name,
                              streamURL: URL(string: "https://test/\(prefix)-\(index)")!, logoURL: nil, category: "News")
            }
        }
        let first = fixture("provider-a")
        let second = fixture("provider-b")
        let search = LiveTVChannelSearchModel()
        search.update(channels: first, query: "absent", category: "News", favoritesOnly: false,
                      favoriteIDs: [], debounce: .zero, includeGroups: false)
        await search.waitForCurrentSearch()
        XCTAssertTrue(search.matches.isEmpty, "an unmatched query produces the empty-results state")

        search.update(channels: second, query: "north", category: nil, favoritesOnly: false,
                      favoriteIDs: [], debounce: .zero, includeGroups: false)
        await search.waitForCurrentSearch()
        XCTAssertEqual(search.matches.map(\.id), ["provider-b-0"], "provider changes use only the new active catalog")

        search.cancel()
        let restored = LiveTVChannelFiltering.filter(first, query: "", category: "News",
                                                     favoritesOnly: false, favoriteIDs: [])
        XCTAssertEqual(restored.map(\.id), first.map(\.id), "clearing search rebuilds the previous guide filters")
    }

    func testRepeatedGuideSearchPublishesOnlyTheLatestQuery() async {
        let channels = [
            LiveTVChannel(id: "news", guideID: nil, name: "North News", streamURL: URL(string: "https://test/news")!,
                          logoURL: nil, category: "News"),
            LiveTVChannel(id: "sports", guideID: nil, name: "North Sports", streamURL: URL(string: "https://test/sports")!,
                          logoURL: nil, category: "Sports"),
        ]
        let search = LiveTVChannelSearchModel()
        search.update(channels: channels, query: "news", category: nil, favoritesOnly: false,
                      favoriteIDs: [], debounce: .milliseconds(180), includeGroups: false)
        search.update(channels: channels, query: "sports", category: nil, favoritesOnly: false,
                      favoriteIDs: [], debounce: .milliseconds(180), includeGroups: false)
        await search.waitForCurrentSearch()
        XCTAssertEqual(search.matches.map(\.id), ["sports"], "a superseded query cannot repopulate the guide")
        XCTAssertFalse(search.isSearching)
    }

    func testPendingGuideSearchKeepsPreviousRowsUntilResultsArrive() async {
        let channels = [
            LiveTVChannel(id: "news", guideID: nil, name: "North News", streamURL: URL(string: "https://test/news")!,
                          logoURL: nil, category: "News"),
            LiveTVChannel(id: "sports", guideID: nil, name: "North Sports", streamURL: URL(string: "https://test/sports")!,
                          logoURL: nil, category: "Sports"),
        ]
        let search = LiveTVChannelSearchModel()
        search.update(channels: channels, query: "news", category: nil, favoritesOnly: false,
                      favoriteIDs: [], debounce: .zero, includeGroups: false)
        await search.waitForCurrentSearch()
        search.update(channels: channels, query: "sports", category: nil, favoritesOnly: false,
                      favoriteIDs: [], debounce: .milliseconds(180), includeGroups: false)
        XCTAssertTrue(search.isSearching)
        XCTAssertEqual(search.matches.map(\.id), ["news"], "pending work does not clear the prior result set")
        await search.waitForCurrentSearch()
        XCTAssertEqual(search.matches.map(\.id), ["sports"])
    }

    func testSearchDismissalRestoresFiltersAndBothGuideOffsets() {
        let restoration = LiveTVGuideSearchRestoration(category: "Sports", favoritesOnly: true,
                                                        offsetX: 720, offsetY: 384, query: "north")
        XCTAssertEqual(restoration.dismissedFilters, LiveTVBrowserFilters(category: "Sports", favoritesOnly: true))
        XCTAssertEqual(restoration.offsetX, 720)
        XCTAssertEqual(restoration.offsetY, 384)
        XCTAssertEqual(restoration.dismissedFilters.query, "",
                       "clearing or closing search returns to the original browsing context")
    }

    func testSearchRestorationBoundsInvalidOffsetsInsteadOfMovingTheGuide() {
        let restoration = LiveTVGuideSearchRestoration(category: nil, favoritesOnly: false,
                                                        offsetX: .infinity, offsetY: -1, query: "")
        XCTAssertEqual(restoration.offsetX, 0)
        XCTAssertEqual(restoration.offsetY, 0)
    }

    func testBannerPrefersErrorsThenGuideMessagesAndHidesWhileLoading() {
        typealias State = LiveTVGuideContentState
        XCTAssertEqual(State.banner(errorMessage: "Down", guideMessage: "Old", isGuideStale: true, isGuideLoading: true), "Down")
        XCTAssertNil(State.banner(errorMessage: nil, guideMessage: "Old", isGuideStale: true, isGuideLoading: true))
        XCTAssertEqual(State.banner(errorMessage: nil, guideMessage: "No listings", isGuideStale: false, isGuideLoading: false),
                       "No listings")
        XCTAssertEqual(State.banner(errorMessage: nil, guideMessage: nil, isGuideStale: true, isGuideLoading: false),
                       "Program guide unavailable")
        XCTAssertNil(State.banner(errorMessage: nil, guideMessage: nil, isGuideStale: false, isGuideLoading: false))
        XCTAssertEqual(
            State.banner(errorMessage: nil, catalogNotice: "Import stopped at the 20,000 channel limit. Additional channels were not imported.",
                         guideMessage: "No listings", isGuideStale: true, isGuideLoading: false),
            "Import stopped at the 20,000 channel limit. Additional channels were not imported.")
        XCTAssertEqual(
            State.banner(errorMessage: "Down", catalogNotice: "cap", guideMessage: "Old", isGuideStale: true, isGuideLoading: false),
            "Down")
    }
}
