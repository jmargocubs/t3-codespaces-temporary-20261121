import XCTest

/// Stage 1: the one shared Kyro header and the simplified Live TV Home. Runs against the Debug
/// fixture's unified shell, which hosts the real `KyroAppHeader` over `SiloTabBar`.
final class KyroAppHeaderUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-kyro.c3.introduction.completed", "YES",
                                "-kyroDebugLiveTVFixture", "-kyroDebugLiveTVNavReset",
                                "-kyroDebugGlobalNavigationReset"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "Unified shell loaded")
        sleep(2)
        return app
    }

    private func tab(_ name: String, _ app: XCUIApplication) -> XCUIElement {
        let button = app.tabBars.buttons[name]
        if !button.exists, app.tabBars.buttons.count == 1 {
            app.tabBars.buttons.firstMatch.tap()
            _ = button.waitForExistence(timeout: 3)
        }
        return button
    }

    private func header(_ app: XCUIApplication) -> XCUIElement { app.otherElements["kyroAppHeader"].firstMatch }
    private func headerCount(_ app: XCUIApplication) -> Int { app.otherElements.matching(identifier: "kyroAppHeader").count }

    func testOneHeaderIsShownOnAllFiveTabsAtTheSamePlace() {
        let app = launch()
        var frames: [CGRect] = []
        for name in ["Home", "Movies", "Series", "Sports", "Live TV"] {
            tab(name, app).tap()
            sleep(1)
            XCTAssertEqual(headerCount(app), 1, "exactly one header on \(name)")
            XCTAssertTrue(app.buttons["searchButton"].exists || app.buttons["Search"].exists, "Search on \(name)")
            XCTAssertTrue(app.buttons["kyroMoreMenu"].isHittable, "More on \(name)")
            frames.append(header(app).frame)
        }
        XCTAssertEqual(Set(frames.map { $0.minY.rounded() }).count, 1, "same top edge on every tab")
        XCTAssertEqual(Set(frames.map { $0.height.rounded() }).count, 1, "same height on every tab")
    }

    func testSportsHubAndProfileMenuForYouAreReachable() {
        let app = launch()
        tab("Sports", app).tap()
        XCTAssertTrue(app.otherElements["kyroSportsHub"].waitForExistence(timeout: 10), "Sports opens the S1 hub")

        app.buttons["Profile menu"].tap()
        let forYou = app.buttons["kyroProfileMenuForYou"]
        XCTAssertTrue(forYou.waitForExistence(timeout: 5), "For You stays in the profile menu")
        XCTAssertLessThan(forYou.frame.minY, app.buttons["Settings"].frame.minY, "For You appears above Settings")
    }

    func testNavigationSettingsOffersOnlySupportedFourthTabs() {
        let app = XCUIApplication()
        app.launchArguments += ["-kyro.c3.introduction.completed", "YES", "-kyroDebugSettingsRoute",
                                "-kyroDebugGlobalNavigationReset"]
        app.launch()

        let navigation = app.buttons["kyroSettingsNavigation"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 30), "Settings shows Navigation")
        navigation.tap()

        for choice in ["sports", "forYou", "favorites"] {
            XCTAssertTrue(app.buttons["kyroFourthTab-\(choice)"].waitForExistence(timeout: 5), choice)
        }
        XCTAssertFalse(app.buttons["kyroFourthTab-collections"].exists, "Collections stays inside Movies and Series")
    }

    func testLiveTVHasNoOwnHeaderOrFiveDestinationRow() {
        let app = launch()
        tab("Live TV", app).tap()
        XCTAssertTrue(app.staticTexts["liveTVHomeFavoritesHeader"].waitForExistence(timeout: 30))
        XCTAssertEqual(headerCount(app), 1, "only the shared header")
        XCTAssertFalse(app.otherElements["liveTVTabHeader"].exists)
        XCTAssertFalse(app.otherElements["kyroLiveTVRow"].exists)
        XCTAssertFalse(app.staticTexts["Kyro Live"].exists, "no KYRO LIVE wordmark")
        XCTAssertTrue(app.buttons["liveTVHomeGuide"].isHittable, "Guide is visible on Live TV Home")
        XCTAssertTrue(app.buttons["liveTVHomeAllChannels"].isHittable, "All Channels is visible on Live TV Home")
        XCTAssertTrue(app.buttons["liveTVHomeFavoriteChannels"].isHittable,
                      "Favorite Channels is visible even when the list is empty")
        XCTAssertFalse(app.buttons["liveTVSettingsLink"].exists, "Live TV Settings lives in Settings, not on Home")
        XCTAssertFalse(app.buttons["Live TV settings"].exists, "no Live TV gear")
    }

    func testBrowserHasABackToLiveTVHomeAndGuideRoundTripWorks() {
        let app = launch()
        tab("Live TV", app).tap()
        XCTAssertTrue(app.staticTexts["liveTVHomeFavoritesHeader"].waitForExistence(timeout: 30))
        app.buttons["liveTVHomeAllChannels"].tap()
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 5), "browser's system Back")
        XCTAssertFalse(app.buttons["liveTVBrowserBack"].exists, "no second, custom Back")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["liveTVHomeGuide"].waitForExistence(timeout: 5), "back on Live TV Home")
        app.buttons["liveTVHomeGuide"].tap()
        XCTAssertTrue(app.navigationBars["TV Guide"].waitForExistence(timeout: 10), "Guide pushed")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["liveTVHomeGuide"].waitForExistence(timeout: 5), "Guide returns to Live TV Home")
    }

    /// The real Settings screen (Debug route, no server needed): Live TV is one entry that pushes a
    /// subpage with the system Back, and Back returns to the Settings overview.
    func testSettingsLiveTVSubpageHasOneBackThatReturnsToSettings() {
        let app = XCUIApplication()
        app.launchArguments += ["-kyro.c3.introduction.completed", "YES", "-kyroDebugSettingsRoute"]
        app.launch()
        let row = app.buttons["kyroSettingsLiveTV"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Settings shows one Live TV entry")
        row.tap()
        XCTAssertTrue(app.navigationBars["Live TV Settings"].waitForExistence(timeout: 10), "Live TV subpage pushed")
        XCTAssertFalse(app.buttons["Done"].exists, "a pushed subpage has no Done button")
        XCTAssertEqual(app.navigationBars["Live TV Settings"].buttons.count, 1, "one system Back button")
        app.navigationBars["Live TV Settings"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Back returns to Settings")
        XCTAssertTrue(row.exists)
    }
}
