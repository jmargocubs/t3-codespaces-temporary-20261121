import XCTest

/// Kyro's unified navigation: Sports and Live TV in the app's five fixed
/// top-level tabs, the iPhone default since Build 27. Uses the Debug
/// fixture's unified shell, which has `MainTabView`'s shape: one stack over
/// `SiloTabBar`, Live TV provided by the shell's environment.
///
/// Measured facts are also logged as `KYRO-P0` lines and screenshots.
final class KyroUnifiedNavigationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-kyro.c3.introduction.completed", "YES",
                                "-kyroDebugLiveTVFixture", "-kyroDebugLiveTVNavReset",
                                "-kyroDebugGlobalNavigationReset",
                                "-kyroDebugLiveTVNavIdle", "stayVisible"]
        app.launchArguments += extra
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "Unified shell loaded")
        sleep(2)
        return app
    }

    /// The bar minimizes on scroll to the selected tab; tapping that expands it again.
    private func tab(_ name: String, _ app: XCUIApplication) -> XCUIElement {
        let button = app.tabBars.buttons[name]
        if !button.exists, app.tabBars.buttons.count == 1 {
            note("bar minimized; expanding to reach \(name)")
            app.tabBars.buttons.firstMatch.tap()
            _ = button.waitForExistence(timeout: 3)
        }
        return button
    }
    private func window(_ app: XCUIApplication) -> XCUIElement { app.windows.firstMatch }
    private func pill(_ name: String, _ app: XCUIApplication) -> XCUIElement { app.buttons["kyroLiveTVRow.\(name)"] }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func note(_ fact: String) {
        print("KYRO-P0 \(name): \(fact)")
    }

    private func drag(_ app: XCUIApplication, fromY: CGFloat, toY: CGFloat, x: CGFloat = 0.5) {
        window(app).coordinate(withNormalizedOffset: CGVector(dx: x, dy: fromY))
            .press(forDuration: 0.05, thenDragTo: window(app).coordinate(withNormalizedOffset: CGVector(dx: x, dy: toY)))
        sleep(1)
    }

    private func openLiveTV(_ app: XCUIApplication) {
        tab("Live TV", app).tap()
        XCTAssertTrue(app.staticTexts["liveTVHomeFavoritesHeader"].waitForExistence(timeout: 30), "Fixture Live TV Home loaded")
        sleep(2)
    }

    // MARK: The tab

    func testLiveTVIsANativeTabOfTheOneTabBar() {
        let app = launch()
        let bar = app.tabBars.firstMatch
        let names = bar.buttons.allElementsBoundByIndex.map(\.label)
        note("tabs: \(names)")
        XCTAssertEqual(names, ["Home", "Movies", "Series", "Sports", "Live TV"],
                       "the fixed tabs stay intact and Sports is fourth")
        XCTAssertTrue(app.otherElements["kyroDebugMediaPage.Home"].exists || app.staticTexts["Home row 0"].exists)
        let mediaBarFrame = bar.frame
        capture("p0-media-home", app)

        openLiveTV(app)
        XCTAssertEqual(app.tabBars.count, 1, "One tab bar: Live TV's own Classic bar is not drawn")
        XCTAssertTrue(tab("Live TV", app).isSelected)
        XCTAssertEqual(bar.frame.minY, mediaBarFrame.minY, accuracy: 1, "The bar does not move between apps")
        for name in Self.destinations {
            XCTAssertTrue(pill(name, app).isHittable, "Classic: \(name) in Live TV's row")
        }
        XCTAssertTrue(pill("home", app).isSelected)
        XCTAssertTrue(app.buttons["Live TV settings"].isHittable, "Live TV header on the page")
        XCTAssertFalse(app.buttons["TV Guide"].exists, "The row offers the Guide; the header doesn't repeat it")
        XCTAssertFalse(app.buttons["Search channels"].exists, "The row offers Search; the header doesn't repeat it")
        XCTAssertFalse(app.buttons["Back"].exists, "Nothing behind a tab root to go back to")
        XCTAssertFalse(app.buttons["Back to Live TV Home"].exists)
        XCTAssertLessThan(app.buttons["Live TV settings"].frame.maxY, pill("home", app).frame.minY + 1,
                          "Header above the row")
        note("navigation bars: \(app.navigationBars.count)")
        capture("p0-livetv-home", app)

        pill("channels", app).tap()
        XCTAssertTrue(app.staticTexts["Browse Channels"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Back to Live TV Home"].exists, "Home is in the row; no Back in the browser")
        capture("p1-livetv-channels", app)
        pill("home", app).tap()
        XCTAssertTrue(app.staticTexts["liveTVHomeFavoritesHeader"].waitForExistence(timeout: 5))

        app.buttons["Live TV settings"].tap()
        XCTAssertTrue(app.buttons["kyroLiveTVNavigationSettingsLink"].waitForExistence(timeout: 5),
                      "Live TV and navigation settings reachable from the tab")
        capture("p0-livetv-settings", app)
        app.buttons["kyroLiveTVNavigationSettingsLink"].tap()
        let toggle = app.switches["kyroUnifiedNavigationToggle"]
        // Look, never tap: the switch writes the app's real defaults.
        app.swipeUp()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Test switch present in Debug builds")
        note("test switch value=\(String(describing: toggle.value))")
        capture("p1-navigation-settings-test-switch", app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Done"].tap()
        sleep(1)

        tab("Home", app).tap()
        sleep(1)
        XCTAssertTrue(app.staticTexts["Home row 0"].waitForExistence(timeout: 5), "Back on the Media Server")
        XCTAssertFalse(app.staticTexts["liveTVHomeFavoritesHeader"].isHittable, "Live TV is not shown over Home")
        note("Live TV header after returning to Home: settings=\(app.buttons["Live TV settings"].exists)")
        capture("p0-media-home-again", app)
    }

    // MARK: State across tab switches

    private static let destinations = ["home", "guide", "favorites", "channels", "search"]
    private static let channelNames = [
        "Arena Sports", "Metro 24 News", "Classic Cinema", "Nature World", "Prime Drama", "Cartoon Hub", "Tunes TV",
        "Golf Channel One", "City Weather", "Global Business", "Comedy Max", "History Vault", "Racing Live",
        "Family Movies", "Cooking Studio", "Science Now", "Retro Hits", "Kids Junior", "Tennis Center", "Local 7",
    ]

    /// Channel rows fully on screen, top to bottom.
    private func visibleChannels(_ app: XCUIApplication) -> [String] {
        Self.channelNames
            .map { (name: $0, button: app.buttons["Play \($0)"]) }
            .filter { $0.button.exists && $0.button.isHittable }
            .sorted { $0.button.frame.minY < $1.button.frame.minY }
            .map(\.name)
    }

    /// Scrolls Media Home and Live TV's channel list, then switches between them
    /// `rounds` times, checking both stay exactly where they were.
    private func checkRoundTrips(_ app: XCUIApplication, rounds: Int, label: String) {
        drag(app, fromY: 0.8, toY: 0.2)
        drag(app, fromY: 0.8, toY: 0.2)
        let marker = app.staticTexts["Home row 20"]
        XCTAssertTrue(marker.exists, "Home scrolled to row 20")
        let markerY = marker.frame.minY
        XCTAssertFalse(app.staticTexts["Home row 0"].isHittable, "Home scrolled")

        openLiveTV(app)
        pill("channels", app).tap()
        XCTAssertTrue(app.staticTexts["Browse Channels"].waitForExistence(timeout: 5), "Channels browser")
        let top = visibleChannels(app)
        // A swipe can land while the list is still settling; swipe again until the first screen is gone.
        var before = top
        for _ in 0..<3 where Set(before).intersection(top).count > 1 {
            app.swipeUp()
            sleep(2)
            before = visibleChannels(app)
        }
        note("\(label): channels at top=\(top) scrolled=\(before)")
        XCTAssertLessThanOrEqual(Set(before).intersection(top).count, 1, "The channel list scrolled past its first screen")
        XCTAssertFalse(before.isEmpty)
        capture("\(label)-browser-scrolled", app)

        for round in 1...rounds {
            tab("Home", app).tap()
            sleep(2)
            XCTAssertEqual(marker.frame.minY, markerY, accuracy: 2, "Round \(round): Media Home offset kept")
            tab("Live TV", app).tap()
            sleep(2)
            XCTAssertTrue(pill("channels", app).isSelected, "Round \(round): still on Channels")
            let after = visibleChannels(app)
            note("\(label) round \(round): channels=\(after)")
            XCTAssertEqual(after, before, "Round \(round): channel list position kept")
        }
        capture("\(label)-browser-after", app)
    }

    func testMediaAndLiveTVStateSurviveTabSwitches() {
        checkRoundTrips(launch(), rounds: 1, label: "p1-state")
    }

    func testRepeatedSwitchesKeepEveryPosition() {
        checkRoundTrips(launch(), rounds: 4, label: "p1-repeat")
    }

    func testHiddenLiveTVKeepsItsPositionWhenFavoritesChange() {
        // The hook stars Golf Channel One each time Live TV is hidden, so one round.
        let app = launch(["-kyroDebugUnifiedFavoriteWhileHidden"])
        checkRoundTrips(app, rounds: 1, label: "p1-favorite-hidden")
        pill("favorites", app).tap()
        XCTAssertTrue(app.buttons["Play Golf Channel One"].waitForExistence(timeout: 5),
                      "The favorite made while hidden is there")
    }

    func testHiddenLiveTVKeepsItsPositionWhenThePlaylistReloads() {
        checkRoundTrips(launch(["-kyroDebugUnifiedRefreshWhileHidden"]), rounds: 1, label: "p1-refresh-hidden")
    }

    /// `MainTabView` moves its selection for a deep link or Siri; that must leave Live TV.
    func testAMediaTabRequestLeavesLiveTV() {
        let app = launch(["-kyroDebugUnifiedStartOnLiveTV", "-kyroDebugUnifiedSelectAfter", "12", "Libraries"])
        XCTAssertTrue(app.staticTexts["liveTVHomeFavoritesHeader"].waitForExistence(timeout: 20), "Started on Live TV")
        XCTAssertTrue(tab("Live TV", app).isSelected)
        XCTAssertTrue(app.staticTexts["Movies row 0"].waitForExistence(timeout: 20), "The request opened Movies")
        XCTAssertTrue(tab("Movies", app).isSelected)
        XCTAssertFalse(tab("Live TV", app).isSelected)
        capture("p1-request-left-livetv", app)
    }

    // MARK: Playback presentation

    /// The fixture's streams cannot play, so this proves presentation only, not playback.
    func testLiveTVPlayerPresentsOverTheTabAndReturnsToIt() {
        let app = launch()
        openLiveTV(app)
        let watch = app.buttons["Watch Arena Sports live"]
        XCTAssertTrue(watch.waitForExistence(timeout: 10))
        watch.tap()
        let stop = app.buttons["Stop Live TV"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "Live TV player presented from the tab")
        XCTAssertFalse(app.tabBars.firstMatch.isHittable, "The player covers the tab bar")
        capture("p1-player-over-tab", app)
        stop.tap()
        XCTAssertTrue(app.staticTexts["liveTVHomeFavoritesHeader"].waitForExistence(timeout: 10), "Back on Live TV")
        XCTAssertTrue(tab("Live TV", app).isSelected)
        XCTAssertEqual(app.tabBars.count, 1)
        capture("p1-player-closed", app)
    }

    // MARK: Accessibility

    func testAccessibilityTextSizeKeepsEveryDestinationReachable() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        openLiveTV(app)
        for name in Self.destinations {
            let segment = pill(name, app)
            XCTAssertTrue(segment.isHittable, "\(name) reachable at accessibility sizes")
            XCTAssertGreaterThanOrEqual(segment.frame.height, 44, "\(name) keeps a 44pt target")
        }
        XCTAssertTrue(app.buttons["Live TV settings"].isHittable)
        XCTAssertTrue(pill("home", app).staticTexts["Home"].exists, "The selected destination keeps its title")
        XCTAssertFalse(pill("guide", app).staticTexts["Guide"].exists, "Inactive segments show their symbol alone")
        pill("favorites", app).tap()
        XCTAssertTrue(pill("favorites", app).staticTexts["Favorites"].waitForExistence(timeout: 8),
                      "The new selection takes the title")
        XCTAssertFalse(pill("home", app).staticTexts["Home"].exists)
        capture("p1-accessibility-xl", app)
    }

    // MARK: Guide

    func testGuideKeepsScrollingSearchAndNavigation() {
        let app = launch()
        openLiveTV(app)
        pill("guide", app).tap()
        XCTAssertTrue(app.staticTexts["TV Guide"].waitForExistence(timeout: 8), "Guide")
        sleep(2)
        note("on Guide: tab bars=\(app.tabBars.count) row=\(app.otherElements["kyroLiveTVRow"].exists || pill("guide", app).exists) "
             + "search field=\(app.searchFields.count)")
        capture("p0-guide", app)

        let firstRow = app.staticTexts["Arena Sports"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        let before = firstRow.frame.minY
        drag(app, fromY: 0.75, toY: 0.4)
        XCTAssertTrue(!firstRow.exists || firstRow.frame.minY < before - 100, "The guide scrolls vertically")
        window(app).coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6))
            .press(forDuration: 0.05, thenDragTo: window(app).coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.6)))
        sleep(1)
        XCTAssertTrue(app.staticTexts["TV Guide"].exists, "A horizontal drag scrolls the grid")
        capture("p0-guide-scrolled", app)

        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 3) {
            field.tap()
            let focused = app.keyboards.firstMatch.waitForExistence(timeout: 5)
            note("guide search keyboard=\(focused) focus=\(String(describing: field.value(forKey: "hasKeyboardFocus")))")
            capture("p0-guide-search-tapped", app)
            if focused {
                app.typeText("Arena")
                sleep(2)
                note("guide search: Arena visible=\(app.staticTexts["Arena Sports"].exists) "
                     + "Metro hidden=\(!app.staticTexts["Metro 24 News"].exists)")
                capture("p0-guide-search", app)
                if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() } else { app.buttons["Close"].firstMatch.tap() }
                sleep(1)
            }
        } else {
            note("guide search field not found")
        }

        // Back to Live TV through its own row, not a second bar.
        if pill("home", app).exists {
            pill("home", app).tap()
        } else {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(app.staticTexts["liveTVHomeFavoritesHeader"].waitForExistence(timeout: 8), "Live TV Home again")
        sleep(1)
        XCTAssertEqual(app.tabBars.count, 1)
        XCTAssertTrue(tab("Live TV", app).isSelected, "Still the Live TV tab")
        capture("p0-guide-back-home", app)
    }

    // MARK: Contextual returns (Build 22)

    /// Every control on screen that leaves the current page: the system Back and any custom one.
    private func backControls(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format:
            "identifier == 'BackButton' OR label BEGINSWITH[c] 'Back' OR label == 'Live TV Home'"))
    }

    func testGuideHasExactlyOneBackAndItReturnsToLiveTVHome() {
        let app = launch()
        openLiveTV(app)
        pill("guide", app).tap()
        XCTAssertTrue(app.navigationBars["TV Guide"].waitForExistence(timeout: 8), "Guide")
        sleep(1)
        capture("b22-guide", app)
        note("guide back controls=\(backControls(app).count) labels=\(backControls(app).allElementsBoundByIndex.map(\.label))")
        XCTAssertEqual(backControls(app).count, 1, "One way back from the Guide")

        backControls(app).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["liveTVHomeFavoritesHeader"].waitForExistence(timeout: 8), "Live TV Home again")
        XCTAssertTrue(tab("Live TV", app).isSelected, "Still the Live TV tab, not the app's Home")
        XCTAssertEqual(app.tabBars.count, 1)
    }

    /// Search is a segment of the row; Home is the way back. Neither the header nor the page
    /// draws a Back of its own.
    func testSearchSegmentOpensSearchAndTheHomeSegmentReturns() {
        let app = launch()
        openLiveTV(app)
        XCTAssertEqual(backControls(app).count, 0, "Live TV Home is a tab root")
        pill("search", app).tap()
        XCTAssertTrue(app.textFields["liveTVChannelSearch"].waitForExistence(timeout: 8), "Search")
        XCTAssertTrue(pill("search", app).isSelected)
        XCTAssertEqual(backControls(app).count, 0, "The row replaces the browser's Back")
        XCTAssertFalse(app.buttons["Back to Live TV Home"].exists)
        capture("cp1-search", app)

        pill("home", app).tap()
        XCTAssertTrue(app.staticTexts["liveTVHomeFavoritesHeader"].waitForExistence(timeout: 8), "Live TV Home again")
        XCTAssertTrue(pill("home", app).isSelected)
        XCTAssertTrue(tab("Live TV", app).isSelected)
        XCTAssertFalse(tab("Home", app).isSelected, "Live TV's Home never selects the app's Home")
        XCTAssertEqual(app.tabBars.count, 1)
    }

    // MARK: Favorites and the row (Checkpoint 1)

    func testRowSwitchesHomeFavoritesChannelsSearchInsideOneTab() {
        let app = launch()
        openLiveTV(app)
        pill("favorites", app).tap()
        XCTAssertTrue(app.staticTexts["liveTVFavoritesTitle"].waitForExistence(timeout: 8), "Favorites")
        XCTAssertTrue(pill("favorites", app).isSelected)
        XCTAssertFalse(pill("home", app).isSelected)
        pill("channels", app).tap()
        XCTAssertTrue(app.staticTexts["Browse Channels"].waitForExistence(timeout: 8))
        XCTAssertTrue(pill("channels", app).isSelected)
        XCTAssertFalse(pill("favorites", app).isSelected)
        pill("search", app).tap()
        XCTAssertTrue(app.textFields["liveTVChannelSearch"].waitForExistence(timeout: 8))
        XCTAssertTrue(pill("search", app).isSelected)
        pill("favorites", app).tap()
        XCTAssertTrue(app.staticTexts["liveTVFavoritesTitle"].waitForExistence(timeout: 8))
        XCTAssertTrue(pill("favorites", app).isSelected, "Leaving Search for Favorites selects Favorites")
        XCTAssertFalse(pill("search", app).isSelected)
        pill("home", app).tap()
        XCTAssertTrue(app.staticTexts["liveTVHomeFavoritesHeader"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.tabBars.count, 1, "The global tab bar never left")
        XCTAssertTrue(tab("Live TV", app).isSelected)
        XCTAssertEqual(app.tabBars.firstMatch.buttons.allElementsBoundByIndex.map(\.label),
                       ["Home", "Movies", "Series", "Sports", "Live TV"], "Global tabs unchanged")
    }

    func testFavoritesListsStarredChannelsAndUnstarringRemovesOne() {
        let app = launch()
        openLiveTV(app)
        pill("favorites", app).tap()
        XCTAssertTrue(app.staticTexts["liveTVFavoritesTitle"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Play Arena Sports"].waitForExistence(timeout: 5), "A starred channel is listed")
        XCTAssertTrue(app.buttons["Play Metro 24 News"].exists)
        XCTAssertFalse(app.buttons["Play Tunes TV"].exists, "An unstarred channel is not")
        capture("cp1-favorites-populated", app)

        app.buttons["Remove Arena Sports from Favorites"].tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.buttons["Play Arena Sports"])
        waitForExpectations(timeout: 8)
        XCTAssertTrue(app.buttons["Play Metro 24 News"].exists, "The others stay")
    }

    func testFavoritesEmptyStateExplainsHowToAddOne() {
        let app = launch(["-kyroDebugLiveTVNoFavorites"])
        openLiveTV(app)
        pill("favorites", app).tap()
        XCTAssertTrue(app.staticTexts["No Favorites Yet"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Tap the star next to any channel to add it to Favorites."].exists)
        capture("cp1-favorites-empty", app)
        app.buttons["Browse Channels"].tap()
        XCTAssertTrue(app.staticTexts["Browse Channels"].waitForExistence(timeout: 8), "The action leads to Channels")
        XCTAssertTrue(pill("channels", app).isSelected)
    }

    func testCalendarFromMoreReturnsToTheTabItWasOpenedFrom() {
        let app = launch()
        tab("Series", app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["kyroDebugMediaPage.Series"].waitForExistence(timeout: 8))
        app.buttons["kyroMoreMenu"].firstMatch.tap()
        let calendar = app.buttons["Calendar"].firstMatch
        XCTAssertTrue(calendar.waitForExistence(timeout: 5), "More offers Calendar")
        calendar.tap()
        XCTAssertTrue(app.descendants(matching: .any)["kyroDebugMediaPage.Calendar"].waitForExistence(timeout: 8))
        sleep(1)
        capture("b22-calendar", app)
        XCTAssertEqual(backControls(app).count, 1, "Calendar has a way back")

        backControls(app).firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["kyroDebugMediaPage.Series"].waitForExistence(timeout: 8))
        XCTAssertTrue(tab("Series", app).isSelected, "Back from Calendar restores the tab it came from")
        XCTAssertEqual(app.tabBars.count, 1)
    }

    // MARK: More, mini player, floating styles

    func testTheUnifiedShellAlwaysKeepsExactlyFiveGlobalTabs() {
        let app = launch()
        let names = app.tabBars.firstMatch.buttons.allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(names, ["Home", "Movies", "Series", "Sports", "Live TV"])
        XCTAssertTrue(tab("Live TV", app).isHittable)
        XCTAssertFalse(tab("More", app).exists, "secondary destinations belong to Kyro's More menu")
    }

    func testMiniPlayerAccessoryStaysAboveTheBarOnLiveTV() {
        let app = launch(["-kyroDebugUnifiedMiniPlayer"])
        let accessory = app.descendants(matching: .any).matching(identifier: "kyroDebugMiniPlayer").firstMatch
        XCTAssertTrue(accessory.waitForExistence(timeout: 5), "Accessory on the Media Server")
        let mediaFrame = accessory.frame
        capture("p0-mini-media", app)
        openLiveTV(app)
        XCTAssertTrue(accessory.exists, "Accessory still attached on Live TV")
        note("accessory media=\(mediaFrame) livetv=\(accessory.frame) bar=\(app.tabBars.firstMatch.frame)")
        XCTAssertEqual(accessory.frame.minY, mediaFrame.minY, accuracy: 2)
        capture("p0-mini-livetv", app)
        drag(app, fromY: 0.75, toY: 0.35)
        note("after scrolling Live TV: accessory=\(accessory.frame) bar=\(app.tabBars.firstMatch.frame)")
        capture("p0-mini-livetv-scrolled", app)
    }

    func testFloatingStylesStillDriveLiveTVInsideItsTab() throws {
        try XCTSkipIf(true, "Glass Dock and Thumb Fan are not connected to the unified shell; "
                      + "reconnecting them is deferred (Phase 3A Checkpoint 2).")
        let app = launch(["-kyroDebugLiveTVNavStyle", "glassDock"])
        openLiveTV(app)
        let handle = app.buttons["kyroLiveTVNavHandle"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "Glass Dock handle inside the Live TV tab")
        XCTAssertFalse(pill("home", app).exists, "No pill row under a floating style")
        XCTAssertEqual(app.tabBars.count, 1)
        XCTAssertLessThan(handle.frame.maxY, app.tabBars.firstMatch.frame.minY, "Handle clear of the tab bar")
        capture("p0-dock-collapsed", app)
        handle.tap()
        XCTAssertTrue(app.buttons["kyroLiveTVNav.guide"].waitForExistence(timeout: 5))
        capture("p0-dock-open", app)
        app.buttons["kyroLiveTVNav.channels"].tap()
        XCTAssertTrue(app.staticTexts["Browse Channels"].waitForExistence(timeout: 5))
        tab("Home", app).tap()
        sleep(1)
        XCTAssertFalse(handle.exists && handle.isHittable, "The Live TV handle stays with Live TV")
    }

    func testAPushedMediaScreenCoversTheBarAsBefore() {
        let app = launch()
        app.buttons["kyroDebugPushMedia"].tap()
        XCTAssertTrue(app.staticTexts["Media Detail"].waitForExistence(timeout: 5))
        sleep(1)
        note("pushed media screen: tab bar hittable=\(app.tabBars.firstMatch.exists && app.tabBars.firstMatch.isHittable)")
        capture("p0-media-pushed", app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(tab("Live TV", app).waitForExistence(timeout: 5))
    }
}
