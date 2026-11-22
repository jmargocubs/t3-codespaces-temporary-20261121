import XCTest

/// Classic Live TV navigation is the Media Server's own tab bar (`SiloTabBar`),
/// and the floating styles leave no bar behind. Live TV is pushed over the
/// shell's tab bar, as `MainTabView` does, using the Debug fixture.
final class KyroClassicNavigationUITests: XCTestCase {
    private static let destinations = ["Home", "Guide", "Favorites", "Channels", "Search"]

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(style: String?, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // These tests cover the earlier navigation, which the unified shell replaced on iPhone.
        app.launchArguments += ["-kyro.c3.introduction.completed", "YES", "-kyro.navigation.legacyShell", "YES",
                                "-kyroDebugLiveTVFixture",
                                "-kyroDebugLiveTVNavReset", "-kyroDebugLiveTVNavIdle", "stayVisible"]
        if let style { app.launchArguments += ["-kyroDebugLiveTVNavStyle", style] }
        app.launchArguments += extra
        app.launch()
        XCTAssertTrue(app.staticTexts["liveTVHomeFavoritesHeader"].waitForExistence(timeout: 30), "Fixture Home loaded")
        sleep(2)
        return app
    }

    private func handle(_ app: XCUIApplication) -> XCUIElement { app.buttons["kyroLiveTVNavHandle"] }
    private func window(_ app: XCUIApplication) -> XCUIElement { app.windows.firstMatch }
    private func tab(_ name: String, _ app: XCUIApplication) -> XCUIElement { app.tabBars.buttons[name] }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openNavigationSettings(_ app: XCUIApplication) {
        let gear = app.buttons["Live TV settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5), "Run on a 440pt iPhone: the gear is in the toolbar")
        gear.tap()
        let link = app.buttons["kyroLiveTVNavigationSettingsLink"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        XCTAssertTrue(app.buttons["kyroNavStyle.classic"].waitForExistence(timeout: 5))
    }

    private func choose(style: String, _ app: XCUIApplication) {
        openNavigationSettings(app)
        app.buttons["kyroNavStyle.\(style)"].tap()
        sleep(1)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Done"].tap()
        sleep(2)
    }

    // MARK: Classic

    func testClassicIsTheDefaultAndIsTheMediaServerTabBar() {
        // The Media Server shell's bar, for comparison: the same component draws both.
        let shell = XCUIApplication()
        shell.launchArguments += ["-kyro.c3.introduction.completed", "YES", "-kyroDebugMediaShell"]
        shell.launch()
        XCTAssertTrue(shell.tabBars.firstMatch.waitForExistence(timeout: 25))
        sleep(2)
        let shellBar = shell.tabBars.firstMatch.frame
        XCTAssertTrue(shell.tabBars.buttons["Libraries"].exists, "Media Server destinations unchanged")
        shell.terminate()

        // No style argument: a reset store starts on Classic.
        let app = launch(style: nil)
        XCTAssertFalse(handle(app).exists, "Classic: no floating handle")
        XCTAssertEqual(app.tabBars.count, 1, "Live TV covers the shell; only its own tab bar shows")
        let bar = app.tabBars.firstMatch
        XCTAssertEqual(bar.buttons.count, Self.destinations.count)
        for name in Self.destinations { XCTAssertTrue(tab(name, app).exists, name) }
        XCTAssertEqual(bar.frame.minY, shellBar.minY, accuracy: 1, "Same bar geometry as the Media Server")
        XCTAssertEqual(bar.frame.height, shellBar.height, accuracy: 1)
        XCTAssertTrue(tab("Home", app).isSelected)
        capture("b16-classic-home", app)

        tab("Guide", app).tap()
        XCTAssertTrue(app.staticTexts["TV Guide"].waitForExistence(timeout: 8), "Guide")
        XCTAssertTrue(tab("Guide", app).waitForExistence(timeout: 3), "The bar stays on the Guide")
        XCTAssertTrue(tab("Guide", app).isSelected)
        sleep(2)
        let row = app.staticTexts["Arena Sports"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let rowBefore = row.frame.minY
        window(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            .press(forDuration: 0.05, thenDragTo: window(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        sleep(1)
        XCTAssertTrue(!row.exists || row.frame.minY < rowBefore - 100, "The guide grid still scrolls")
        capture("b16-classic-guide-minimized", app)
        // Silo's bar minimizes while scrolling down, exactly as on Media Server pages:
        // only the selected tab stays, and tapping it brings the whole bar back.
        XCTAssertFalse(tab("Favorites", app).isHittable, "Minimized on scroll, like the Media Server bar")
        XCTAssertTrue(tab("Guide", app).isHittable, "The selected tab stays while minimized")
        tab("Guide", app).tap()
        sleep(2)
        XCTAssertTrue(tab("Favorites", app).waitForExistence(timeout: 3), "Tapping the minimized bar expands it")
        XCTAssertTrue(app.staticTexts["TV Guide"].exists, "Expanding the bar stays on the Guide")
        capture("b16-classic-guide", app)

        tab("Favorites", app).tap()
        XCTAssertTrue(app.staticTexts["liveTVFavoritesTitle"].waitForExistence(timeout: 8), "Favorites")
        XCTAssertTrue(tab("Favorites", app).isSelected)

        tab("Channels", app).tap()
        XCTAssertTrue(app.staticTexts["Browse Channels"].waitForExistence(timeout: 8), "Channels")
        XCTAssertTrue(tab("Channels", app).isSelected)
        capture("b16-classic-channels", app)

        tab("Search", app).tap()
        let field = app.textFields["liveTVChannelSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 8), "Search")
        XCTAssertLessThan(field.frame.maxY, window(app).frame.height * 0.4, "Search sits under the navigation bar")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Search field focused")
        field.typeText("Arena")
        XCTAssertTrue(app.staticTexts["Arena Sports"].waitForExistence(timeout: 5), "Search filters channels")
        XCTAssertTrue(tab("Search", app).isSelected)
        capture("b16-classic-search", app)
        // The keyboard covers the tab bar while typing, as anywhere on iOS: submit first.
        app.keyboards.buttons["search"].firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Keyboard dismissed")
        XCTAssertTrue(tab("Search", app).isSelected, "Still searching for \"Arena\"")

        tab("Home", app).tap()
        XCTAssertTrue(app.staticTexts["liveTVHomeFavoritesHeader"].waitForExistence(timeout: 8), "Home")
        XCTAssertTrue(tab("Home", app).isSelected)
    }

    /// Every tab reaches its screen from every other, including straight after leaving the Guide.
    func testClassicTabsSwitchInAnyOrder() {
        let app = launch(style: "classic")
        let screens = ["Home": "liveTVHomeFavoritesHeader", "Guide": "TV Guide", "Favorites": "liveTVFavoritesTitle", "Channels": "Browse Channels"]
        for name in ["Favorites", "Channels", "Home", "Guide", "Favorites", "Channels", "Guide", "Channels", "Home"] {
            XCTAssertTrue(tab(name, app).waitForExistence(timeout: 5), "\(name) tab")
            tab(name, app).tap()
            XCTAssertTrue(app.staticTexts[screens[name]!].waitForExistence(timeout: 10), "\(name) screen")
            XCTAssertTrue(tab(name, app).isSelected, "\(name) selected")
            sleep(1)
        }
    }

    func testClassicHonorsDestinationVisibility() throws {
        let app = launch(style: "classic")
        openNavigationSettings(app)
        let destinations = app.buttons["kyroNavDestinationsLink"]
        for _ in 0..<3 where !destinations.isHittable { app.swipeUp() }
        destinations.tap()
        let searchSwitch = app.switches["kyroNavDestination.search"]
        XCTAssertTrue(searchSwitch.waitForExistence(timeout: 5))
        sleep(1)
        capture("b16-destinations-before", app)
        searchSwitch.switches.firstMatch.tap()
        sleep(2)
        capture("b16-destinations-after", app)
        wait(for: [expectation(for: NSPredicate(format: "value == '0'"), evaluatedWith: searchSwitch)], timeout: 6)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Done"].tap()
        sleep(2)
        XCTAssertEqual(app.tabBars.firstMatch.buttons.count, 4)
        XCTAssertFalse(tab("Search", app).exists, "Hidden destination is not a tab")
    }

    // MARK: Floating styles leave nothing behind

    func testFloatingStylesHaveNoBottomBarOrReservedSpace() {
        for style in ["glassDock", "thumbFan"] {
            let app = launch(style: style)
            let height = window(app).frame.height
            XCTAssertTrue(handle(app).exists, style)
            XCTAssertEqual(app.tabBars.count, 0, "\(style): no tab bar on Home")
            capture("b16-\(style)-home", app)

            // The bottom of Home takes taps: the category tile there opens the browser.
            let tile = app.buttons.matching(NSPredicate(format: "label CONTAINS 'All Channels'")).firstMatch
            XCTAssertTrue(tile.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(tile.frame.midY, height * 0.75, "\(style): tile near the bottom")
            tile.tap()
            XCTAssertTrue(app.staticTexts["Browse Channels"].waitForExistence(timeout: 8),
                          "\(style): nothing intercepts taps at the bottom")

            XCTAssertEqual(app.tabBars.count, 0, "\(style): no tab bar in the browser")
            let field = app.textFields["liveTVChannelSearch"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            XCTAssertLessThan(field.frame.maxY, height * 0.4, "\(style): no search bar along the bottom")
            capture("b16-\(style)-channels-bottom", app)

            // Scrolling from the very bottom moves the list.
            let anchorText = app.staticTexts["Nature World"].firstMatch
            XCTAssertTrue(anchorText.waitForExistence(timeout: 5))
            let before = anchorText.frame.minY
            window(app).coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.95))
                .press(forDuration: 0.05, thenDragTo: window(app).coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.55)))
            sleep(1)
            XCTAssertTrue(!anchorText.exists || anchorText.frame.minY < before - 80,
                          "\(style): a drag from the bottom edge scrolls the list")

            // Nothing reserves the bottom: the handle snaps right down to the home indicator margin.
            let start = handle(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.6, thenDragTo: window(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)),
                        withVelocity: XCUIGestureVelocity(300), thenHoldForDuration: 0.4)
            sleep(1)
            let snapped = handle(app).frame
            XCTAssertGreaterThan(snapped.maxY, height - 64, "\(style): bottom edge not pushed up by a hidden bar")
            XCTAssertLessThan(snapped.maxY, height - 34, "\(style): clear of the home indicator")
            capture("b16-\(style)-bottom-edge", app)
            app.terminate()
        }
    }

    // MARK: Switching styles

    func testSwitchingStylesKeepsTheDestination() {
        let app = launch(style: "glassDock")
        handle(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let favorites = app.buttons["kyroLiveTVNav.favorites"]
        XCTAssertTrue(favorites.waitForExistence(timeout: 3))
        usleep(700_000)
        favorites.tap()
        XCTAssertTrue(app.staticTexts["liveTVFavoritesTitle"].waitForExistence(timeout: 8))

        choose(style: "classic", app)
        XCTAssertTrue(app.staticTexts["liveTVFavoritesTitle"].waitForExistence(timeout: 5), "Still on Favorites")
        XCTAssertTrue(tab("Favorites", app).isSelected, "Classic shows Favorites selected")
        XCTAssertFalse(handle(app).exists, "Classic: floating handle gone")

        choose(style: "thumbFan", app)
        XCTAssertTrue(app.staticTexts["liveTVFavoritesTitle"].waitForExistence(timeout: 5), "Still on Favorites")
        XCTAssertTrue(handle(app).waitForExistence(timeout: 5), "Thumb Fan handle back")
        XCTAssertEqual(app.tabBars.count, 0, "Thumb Fan: Classic bar gone")
    }
}
