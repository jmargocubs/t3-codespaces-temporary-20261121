import XCTest

/// Drives Kyro's introduction on an iPhone simulator with no saved server.
/// The completion flag is passed in the launch arguments' defaults domain,
/// so each test starts from a known state without erasing app data.
final class KyroIntroductionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        // A leftover system "Open in Kyro?" prompt would cover the app.
        let leftover = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Cancel"]
        if leftover.exists {
            leftover.tap()
        }
    }

    private func launch(introductionCompleted: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-kyro.c3.introduction.completed", introductionCompleted ? "YES" : "NO"]
        app.launch()
        return app
    }

    private func text(containing fragment: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    private func serverSetupHeadline(in app: XCUIApplication) -> XCUIElement {
        text(containing: "your server", in: app)
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testGetStartedWalksThreePagesIntoServerSetup() {
        let app = launch(introductionCompleted: false)
        let primary = app.buttons["kyroIntroPrimaryButton"]
        let skip = app.buttons["kyroIntroSkipButton"]

        XCTAssertTrue(primary.waitForExistence(timeout: 15))
        XCTAssertTrue(text(containing: "All in One Place", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(skip.isHittable)
        sleep(1)
        capture("page-1", app)

        primary.tap()
        XCTAssertTrue(text(containing: "Stream your favorite channels", in: app).waitForExistence(timeout: 3))
        sleep(1)
        capture("page-2", app)

        primary.tap()
        XCTAssertTrue(text(containing: "Your Way", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(primary.label.contains("Get Started"), primary.label)
        XCTAssertTrue(skip.waitForNonExistence(timeout: 3), "The last page has no Skip")
        sleep(1)
        capture("page-3", app)

        primary.tap()
        XCTAssertTrue(serverSetupHeadline(in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(primary.exists)
        sleep(1)
        capture("server-setup-after-get-started", app)
    }

    func testSkipGoesStraightToServerSetup() {
        let app = launch(introductionCompleted: false)
        let skip = app.buttons["kyroIntroSkipButton"]
        XCTAssertTrue(skip.waitForExistence(timeout: 15))

        skip.tap()
        XCTAssertTrue(serverSetupHeadline(in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["kyroIntroPrimaryButton"].exists)
    }

    /// Server setup after the introduction still connects: a closed local
    /// port fails with setup's own error, and nothing leaves the machine.
    func testServerSetupAfterIntroductionStillConnects() {
        let app = launch(introductionCompleted: false)
        let skip = app.buttons["kyroIntroSkipButton"]
        XCTAssertTrue(skip.waitForExistence(timeout: 15))
        skip.tap()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("127.0.0.1:9\n")
        // Setup's own warning for a plain-HTTP address.
        let connect = app.buttons["Connect"]
        if connect.waitForExistence(timeout: 10) {
            connect.tap()
        }
        XCTAssertTrue(text(containing: "Could not reach", in: app).waitForExistence(timeout: 45))
        capture("server-setup-unreachable", app)
    }

    func testSwipeMovesBetweenPages() {
        let app = launch(introductionCompleted: false)
        XCTAssertTrue(app.buttons["kyroIntroPrimaryButton"].waitForExistence(timeout: 15))

        app.swipeLeft()
        XCTAssertTrue(text(containing: "Stream your favorite channels", in: app).waitForExistence(timeout: 3))
        app.swipeRight()
        XCTAssertTrue(text(containing: "All in One Place", in: app).waitForExistence(timeout: 3))
    }

    /// Opens a link the way the system does and confirms iOS's
    /// "Open in Kyro?" prompt for the custom scheme.
    private func openThroughSystem(_ link: String) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCUIDevice.shared.system.open(URL(string: link)!)
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 5) {
            open.tap()
        }
    }

    func testLinkDuringIntroductionWaitsAndSetupStillFollows() {
        let app = launch(introductionCompleted: false)
        let primary = app.buttons["kyroIntroPrimaryButton"]
        XCTAssertTrue(primary.waitForExistence(timeout: 15))

        openThroughSystem("kyro://search?q=Dune")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        // A signed-out link stays queued; it does not tear down the intro.
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        capture("intro-after-link", app)

        app.buttons["kyroIntroSkipButton"].tap()
        XCTAssertTrue(serverSetupHeadline(in: app).waitForExistence(timeout: 5))
    }

    func testColdLaunchFromLinkPassesThroughStartup() {
        let app = launch(introductionCompleted: true)
        XCTAssertTrue(serverSetupHeadline(in: app).waitForExistence(timeout: 15))
        app.terminate()

        openThroughSystem("kyro://search?q=Dune")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        // Splash, then the stored route for this signed-out install: server
        // setup, or the introduction if this simulator never completed it.
        let setup = serverSetupHeadline(in: app)
        let intro = app.buttons["kyroIntroPrimaryButton"]
        let deadline = Date().addingTimeInterval(20)
        while !setup.exists, !intro.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(setup.exists || intro.exists)
        capture("cold-link-server-setup", app)
    }

    // MARK: Replay from Settings (debug-only Settings route)

    private func launchDebugSettings(introductionCompleted: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-kyro.c3.introduction.completed", introductionCompleted ? "YES" : "NO",
            "-kyroDebugSettingsRoute",
        ]
        app.launch()
        return app
    }

    private func replayRow(in app: XCUIApplication) -> XCUIElement {
        let row = app.buttons["settings.replayIntroduction"]
        XCTAssertTrue(app.buttons["kyroDebugSettingsClose"].waitForExistence(timeout: 20))
        var attempts = 0
        while !(row.exists && row.isHittable), attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(row.isHittable, "Replay Introduction row not reachable in Settings")
        return row
    }

    /// The one match the user can actually tap: the replay above the
    /// first-launch introduction it covers.
    private func hittable(_ query: XCUIElementQuery) -> XCUIElement {
        for index in 0..<query.count where query.element(boundBy: index).isHittable {
            return query.element(boundBy: index)
        }
        return query.firstMatch
    }

    private func assertOnFirstPage(_ app: XCUIApplication) {
        XCTAssertTrue(text(containing: "All in One Place", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["kyroIntroSkipButton"].waitForExistence(timeout: 3))
    }

    private func assertBackInSettings(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["kyroIntroPrimaryButton"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.replayIntroduction"].waitForExistence(timeout: 5))
    }

    func testReplaySkipAndGetStartedReturnToSettingsAndRestartOnPageOne() {
        let app = launchDebugSettings(introductionCompleted: true)
        let primary = app.buttons["kyroIntroPrimaryButton"]

        // First replay: move to page 2, then Skip back to Settings.
        replayRow(in: app).tap()
        assertOnFirstPage(app)
        capture("replay-page-1", app)
        primary.tap()
        XCTAssertTrue(text(containing: "Stream your favorite channels", in: app).waitForExistence(timeout: 3))
        app.buttons["kyroIntroSkipButton"].tap()
        assertBackInSettings(app)
        capture("settings-after-skip", app)

        // Second replay opens on page 1 again; swipe, then Get Started.
        replayRow(in: app).tap()
        assertOnFirstPage(app)
        app.swipeLeft()
        XCTAssertTrue(text(containing: "Stream your favorite channels", in: app).waitForExistence(timeout: 3))
        primary.tap()
        XCTAssertTrue(text(containing: "Your Way", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(primary.label.contains("Get Started"), primary.label)
        primary.tap()
        assertBackInSettings(app)

        // Third replay still starts at page 1.
        replayRow(in: app).tap()
        assertOnFirstPage(app)
        app.buttons["kyroIntroSkipButton"].tap()
        assertBackInSettings(app)
        capture("settings-after-repeat", app)
    }

    /// Replay never completes the first-launch introduction or changes the
    /// route: a new install's own introduction is still waiting underneath.
    func testReplayLeavesFirstLaunchIntroductionAndRouteAlone() {
        let app = launchDebugSettings(introductionCompleted: false)
        let primaries = app.buttons.matching(identifier: "kyroIntroPrimaryButton")
        // The new install's own introduction stays in the tree under Settings.
        XCTAssertTrue(app.buttons["kyroDebugSettingsClose"].waitForExistence(timeout: 20))
        XCTAssertEqual(primaries.count, 1)

        replayRow(in: app).tap()
        XCTAssertTrue(text(containing: "All in One Place", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(primaries.count, 2)
        for _ in 0..<3 {
            hittable(primaries).tap()
            sleep(1)
        }
        // Replay dismissed; the first-launch introduction is still there.
        XCTAssertTrue(app.buttons["settings.replayIntroduction"].waitForExistence(timeout: 5))
        XCTAssertEqual(primaries.count, 1)

        app.buttons["kyroDebugSettingsClose"].tap()
        let primary = app.buttons["kyroIntroPrimaryButton"]
        XCTAssertTrue(primary.waitForExistence(timeout: 5), "First-launch introduction should still be showing")
        XCTAssertTrue(text(containing: "All in One Place", in: app).exists)
        app.buttons["kyroIntroSkipButton"].tap()
        XCTAssertTrue(serverSetupHeadline(in: app).waitForExistence(timeout: 5))
    }

    func testCompletedIntroductionIsBypassed() {
        let app = launch(introductionCompleted: true)
        XCTAssertTrue(serverSetupHeadline(in: app).waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["kyroIntroPrimaryButton"].exists)
    }
}
