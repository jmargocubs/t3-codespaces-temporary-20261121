import XCTest

/// Drives Kyro's floating Live TV navigation over the real Live TV screens.
/// `-kyroDebugLiveTVFixture` (Debug builds only) serves a fictional playlist
/// and guide in-process: no server, no IPTV credentials, nothing leaves the
/// machine.
final class KyroLiveTVNavigationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        let leftover = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Cancel"]
        if leftover.exists { leftover.tap() }
    }

    /// UI queries are slow, so the functional tests keep the navigation open while idle;
    /// `testIdleCollapseAndFadeKeepTheHandleTappable` covers the idle behaviors.
    private func launch(reset: Bool = true, idle: String = "stayVisible", expanded: Bool = false,
                        _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // The floating styles belong to the earlier navigation, which the unified shell replaced on iPhone.
        app.launchArguments += ["-kyro.c3.introduction.completed", "YES", "-kyro.navigation.legacyShell", "YES",
                                "-kyroDebugLiveTVFixture"]
        if reset { app.launchArguments += ["-kyroDebugLiveTVNavReset", "-kyroDebugLiveTVNavIdle", idle] }
        // Classic is the default since Build 16; these tests cover the floating styles.
        if !extra.contains("-kyroDebugLiveTVNavStyle") { app.launchArguments += ["-kyroDebugLiveTVNavStyle", "glassDock"] }
        app.launchArguments += extra
        app.launch()
        // An open dock replaces the handle.
        XCTAssertTrue((expanded ? item("home", app) : handle(app)).waitForExistence(timeout: 25),
                      "Live TV navigation")
        XCTAssertTrue(app.staticTexts["liveTVHomeFavoritesHeader"].waitForExistence(timeout: 15), "Fixture Home loaded")
        sleep(2) // the fixture finishes seeding favorites and the guide
        return app
    }

    private func handle(_ app: XCUIApplication) -> XCUIElement { app.buttons["kyroLiveTVNavHandle"] }
    private func item(_ name: String, _ app: XCUIApplication) -> XCUIElement { app.buttons["kyroLiveTVNav.\(name)"] }
    private func window(_ app: XCUIApplication) -> XCUIElement { app.windows.firstMatch }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func open(_ app: XCUIApplication) {
        handle(app).tap()
        XCTAssertTrue(item("home", app).waitForExistence(timeout: 3), "Navigation opened")
        usleep(700_000) // let the spring settle before checking hit targets
    }

    private func closeByTappingOutside(_ app: XCUIApplication, x: CGFloat = 0.2) {
        window(app).coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).tap()
        XCTAssertTrue(item("home", app).waitForNonExistence(timeout: 3), "Tap outside closes")
    }

    /// The gear sits in the toolbar's overflow menu when the bar is narrow.
    /// On narrow iPhones the system moves the gear into the toolbar's "More" menu,
    /// which the iOS 27 simulator does not open for UI automation (Build 13 behaved the
    /// same). Run this on a 430pt-class iPhone, where the gear is in the bar.
    private func openLiveTVSettings(_ app: XCUIApplication) throws {
        let gear = app.buttons["Live TV settings"]
        guard gear.exists else {
            throw XCTSkip("The Live TV settings gear is in the toolbar overflow on this screen width.")
        }
        gear.tap()
    }

    private func go(_ name: String, _ app: XCUIApplication) {
        open(app)
        item(name, app).tap()
    }

    /// Long-press the handle and drag it to a point given as a fraction of the window.
    private func drag(_ app: XCUIApplication, toX x: CGFloat, y: CGFloat) {
        let start = handle(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = window(app).coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
        start.press(forDuration: 0.8, thenDragTo: end)
        sleep(1)
    }

    // MARK: Adaptive Glass Dock

    func testGlassDockReachesEveryDestinationAndShowsTheActiveOne() {
        let app = launch()
        sleep(1)
        capture("06-header-and-07-compact-hero", app)
        XCTAssertEqual(handle(app).value as? String, "Home")
        capture("04-collapsed-navigation", app)

        open(app)
        let dock = app.otherElements["kyroLiveTVNavDock"]
        XCTAssertTrue(dock.exists)
        XCTAssertGreaterThan(dock.frame.height, dock.frame.width, "Right edge: a vertical rail")
        XCTAssertTrue(item("home", app).isSelected, "Home is the active destination")
        for name in ["home", "guide", "favorites", "channels", "search"] {
            XCTAssertTrue(item(name, app).isHittable, name)
            XCTAssertGreaterThanOrEqual(item(name, app).frame.height, 44, name)
        }
        sleep(1)
        capture("01-glass-dock-vertical", app)
        XCTAssertFalse(item("sportsHub", app).exists, "No Sports Hub until one exists")

        item("guide", app).tap()
        XCTAssertTrue(app.staticTexts["TV Guide"].waitForExistence(timeout: 5))
        XCTAssertTrue(handle(app).waitForExistence(timeout: 3), "Collapsed after navigating")
        XCTAssertEqual(handle(app).value as? String, "Guide")

        go("favorites", app)
        XCTAssertTrue(app.staticTexts["liveTVFavoritesTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(handle(app).value as? String, "Favorites")

        go("channels", app)
        XCTAssertTrue(app.staticTexts["Browse Channels"].waitForExistence(timeout: 5))
        XCTAssertEqual(handle(app).value as? String, "Channels")

        go("search", app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Search field focused")
        app.textFields["liveTVChannelSearch"].typeText("Arena")
        XCTAssertTrue(app.staticTexts["Arena Sports"].waitForExistence(timeout: 5))
        XCTAssertEqual(handle(app).value as? String, "Search")
        sleep(1)
        XCTAssertLessThanOrEqual(handle(app).frame.maxY, app.keyboards.firstMatch.frame.minY,
                                 "The handle rides above the keyboard")
        capture("08-search-with-keyboard", app)

        go("home", app)
        XCTAssertTrue(app.staticTexts["liveTVHomeFavoritesHeader"].waitForExistence(timeout: 5))
        XCTAssertEqual(handle(app).value as? String, "Home")

        // Search from the Guide pops the Guide first, then focuses the field.
        go("guide", app)
        XCTAssertTrue(app.staticTexts["TV Guide"].waitForExistence(timeout: 5))
        go("search", app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Search field focused after the Guide")
    }

    func testTapOutsideClosesAndThumbScrubbingChoosesOnRelease() {
        let app = launch()
        open(app)
        closeByTappingOutside(app)
        XCTAssertTrue(app.staticTexts["liveTVHomeFavoritesHeader"].exists, "…without touching Home")

        // Straight back in, without waiting for the close animation.
        open(app)
        let from = item("home", app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = item("channels", app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: to)
        XCTAssertTrue(app.staticTexts["Browse Channels"].waitForExistence(timeout: 5), "Lifting on Channels chooses it")
    }

    func testDockSnapsToEveryEdgeAndRemembersItAfterRelaunch() {
        var app = launch()
        let size = window(app).frame.size

        drag(app, toX: 0.06, y: 0.45)
        XCTAssertLessThan(handle(app).frame.midX, size.width * 0.2, "Left edge")
        open(app)
        let rail = app.otherElements["kyroLiveTVNavDock"]
        XCTAssertGreaterThan(rail.frame.height, rail.frame.width, "Left edge: a vertical rail")
        XCTAssertLessThan(rail.frame.minX, size.width * 0.1)
        closeByTappingOutside(app, x: 0.8)

        drag(app, toX: 0.5, y: 0.2)
        XCTAssertLessThan(handle(app).frame.midY, size.height * 0.3, "Top edge")

        drag(app, toX: 0.96, y: 0.08)
        XCTAssertGreaterThan(handle(app).frame.midX, size.width * 0.8, "Top-right corner keeps it on screen")
        XCTAssertTrue(window(app).frame.contains(handle(app).frame))

        drag(app, toX: 0.35, y: 0.97)
        let bottom = handle(app).frame
        XCTAssertGreaterThan(bottom.midY, size.height * 0.8, "Bottom edge")
        XCTAssertLessThan(bottom.maxY, size.height - 34, "Clear of the home indicator")
        open(app)
        let bar = app.otherElements["kyroLiveTVNavDock"]
        XCTAssertGreaterThan(bar.frame.width, bar.frame.height, "Bottom edge: a horizontal dock")
        XCTAssertTrue(window(app).frame.contains(bar.frame))

        app.terminate()
        app = launch(reset: false)
        XCTAssertEqual(handle(app).frame.midY, bottom.midY, accuracy: 4, "Position survives relaunch")
        XCTAssertEqual(handle(app).frame.midX, bottom.midX, accuracy: 4)
    }

    func testGlassDockHorizontalOnTheBottomEdge() {
        let app = launch(expanded: true, ["-kyroDebugLiveTVNavEdge", "bottom", "-kyroDebugLiveTVNavPosition", "0.5",
                                          "-kyroDebugLiveTVNavExpanded"])
        let dock = app.otherElements["kyroLiveTVNavDock"]
        XCTAssertTrue(dock.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(dock.frame.width, dock.frame.height)
        sleep(1)
        capture("02-glass-dock-horizontal", app)
    }

    // MARK: Thumb Fan

    func testThumbFanFansInwardAndNavigates() {
        let app = launch(["-kyroDebugLiveTVNavStyle", "thumbFan"])
        let orb = handle(app).frame
        open(app)
        for name in ["home", "guide", "favorites", "channels", "search"] {
            let frame = item(name, app).frame
            XCTAssertTrue(item(name, app).isHittable, name)
            XCTAssertLessThanOrEqual(frame.midX, orb.midX + 3, "Right edge fans to the left: \(name)")
            XCTAssertTrue(window(app).frame.contains(frame), name)
        }
        sleep(1)
        capture("03-thumb-fan", app)

        item("guide", app).tap()
        XCTAssertTrue(app.staticTexts["TV Guide"].waitForExistence(timeout: 5))
        go("home", app)
        XCTAssertTrue(app.staticTexts["liveTVHomeFavoritesHeader"].waitForExistence(timeout: 5))

        // Top-left corner: everything still fits, opening down and to the right.
        drag(app, toX: 0.04, y: 0.12)
        let corner = handle(app).frame
        open(app)
        for name in ["home", "guide", "favorites", "channels", "search"] {
            let frame = item(name, app).frame
            XCTAssertTrue(window(app).frame.contains(frame), name)
            XCTAssertGreaterThanOrEqual(frame.midX, corner.midX - 3, name)
            XCTAssertGreaterThanOrEqual(frame.midY, corner.midY - 3, name)
        }
        sleep(1)
        capture("03b-thumb-fan-corner", app)
        item("favorites", app).tap()
        XCTAssertTrue(app.staticTexts["liveTVFavoritesTitle"].waitForExistence(timeout: 5))
    }

    // MARK: Settings

    func testNavigationSettingsChangeStyleAndDestinations() throws {
        let app = launch()
        try openLiveTVSettings(app)
        let link = app.buttons["kyroLiveTVNavigationSettingsLink"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        XCTAssertTrue(app.buttons["kyroNavStyle.thumbFan"].waitForExistence(timeout: 5))
        sleep(1)
        capture("05-navigation-settings", app)

        app.buttons["kyroNavStyle.thumbFan"].tap()
        let destinations = app.buttons["kyroNavDestinationsLink"]
        for _ in 0..<3 where !destinations.isHittable { app.swipeUp() }
        destinations.tap()
        let searchSwitch = app.switches["kyroNavDestination.search"]
        XCTAssertTrue(searchSwitch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["kyroNavDestination.home"].exists, "Home has no switch: always shown")
        // Tapping a SwiftUI switch row's label does not flip it; tap the switch itself.
        searchSwitch.switches.firstMatch.tap()
        let hidden = expectation(for: NSPredicate(format: "value == '0'"), evaluatedWith: searchSwitch)
        wait(for: [hidden], timeout: 3)
        sleep(1)
        capture("05b-navigation-destinations", app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Done"].tap()

        open(app)
        XCTAssertFalse(item("search", app).exists, "Hidden destination is gone")
        XCTAssertTrue(item("guide", app).exists)
        XCTAssertFalse(app.otherElements["kyroLiveTVNavDock"].exists, "Thumb Fan selected")
        closeByTappingOutside(app)

        try openLiveTVSettings(app)
        app.buttons["kyroLiveTVNavigationSettingsLink"].tap()
        let resetAll = app.buttons["kyroNavResetAll"]
        for _ in 0..<4 where !resetAll.isHittable { app.swipeUp() }
        resetAll.tap()
        app.buttons["Reset Navigation"].tap()
        sleep(1)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Done"].tap()
        // Reset returns to Classic, the default: the shell's tab bar with every destination.
        XCTAssertTrue(app.tabBars.buttons["Search"].waitForExistence(timeout: 5), "Reset restores every destination")
        XCTAssertFalse(handle(app).exists, "Reset restores Classic, so no floating handle")
    }

    // MARK: Idle

    func testIdleCollapseAndFadeKeepTheHandleTappable() {
        let app = launch(idle: "collapseAndFade")
        open(app)
        XCTAssertTrue(item("home", app).waitForNonExistence(timeout: 14), "Collapses on its own when idle")
        sleep(5)
        capture("04b-collapsed-faded", app)
        XCTAssertTrue(handle(app).isHittable, "A faded handle is never untappable")
        open(app)
        item("guide", app).tap()
        XCTAssertTrue(app.staticTexts["TV Guide"].waitForExistence(timeout: 5))
    }

    // MARK: Coexistence

    func testScrollingAndTheGuideGridStillWorkUnderTheNavigation() {
        let app = launch()
        let categories = app.staticTexts["Live TV Categories"]
        let before = categories.frame.minY
        window(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.05, thenDragTo: window(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        sleep(1)
        // The fixture Home is only a little taller than large screens, so any real movement counts.
        XCTAssertLessThan(categories.frame.minY, before - 30, "Home scrolls under the navigation")
        XCTAssertTrue(handle(app).isHittable)

        go("guide", app)
        XCTAssertTrue(app.staticTexts["TV Guide"].waitForExistence(timeout: 5))
        sleep(2)
        let firstRow = app.staticTexts["Arena Sports"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        let rowBefore = firstRow.frame.minY
        capture("guide-before-scroll", app)
        window(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            .press(forDuration: 0.05, thenDragTo: window(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        sleep(1)
        XCTAssertTrue(!firstRow.exists || firstRow.frame.minY < rowBefore - 100, "The guide scrolls vertically")
        window(app).coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6))
            .press(forDuration: 0.05, thenDragTo: window(app).coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.6)))
        sleep(1)
        capture("guide-after-scroll", app)
        XCTAssertTrue(app.staticTexts["TV Guide"].exists, "A horizontal drag scrolls the grid, not the navigation")
        XCTAssertTrue(handle(app).isHittable, "Navigation still available over the guide")
    }

    func testNavigationSurvivesBackgroundingAndReturnsCollapsed() {
        let app = launch()
        open(app)
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        XCTAssertTrue(handle(app).waitForExistence(timeout: 5))
        XCTAssertFalse(item("home", app).exists, "Collapsed after returning")
        go("favorites", app)
        XCTAssertTrue(app.staticTexts["liveTVFavoritesTitle"].waitForExistence(timeout: 5))
    }
}
