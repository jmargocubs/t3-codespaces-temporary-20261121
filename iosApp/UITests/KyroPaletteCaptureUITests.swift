import XCTest

/// Screenshots for the Build 15 C3 palette comparison. Live TV runs over the
/// Debug fixture; the Media Server shell runs in the Debug harness
/// (`-kyroDebugMediaShell`), because real Home needs a signed-in server.
/// Run on the 440pt iPhone so the Live TV gear is in the toolbar.
final class KyroPaletteCaptureUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchLiveTV(style: String) -> XCUIApplication {
        let app = XCUIApplication()
        // The Build 15 palette captures used the earlier navigation's styles.
        app.launchArguments += ["-kyro.c3.introduction.completed", "YES", "-kyro.navigation.legacyShell", "YES",
                                "-kyroDebugLiveTVFixture",
                                "-kyroDebugLiveTVNavReset", "-kyroDebugLiveTVNavIdle", "stayVisible",
                                "-kyroDebugLiveTVNavStyle", style]
        app.launch()
        XCTAssertTrue(app.buttons["kyroLiveTVNavHandle"].waitForExistence(timeout: 25))
        XCTAssertTrue(app.staticTexts["liveTVHomeFavoritesHeader"].waitForExistence(timeout: 15))
        sleep(3)
        return app
    }

    private func openNavigation(_ app: XCUIApplication) {
        app.buttons["kyroLiveTVNavHandle"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["kyroLiveTVNav.home"].waitForExistence(timeout: 3))
        sleep(1)
    }

    func testCaptureMediaServerShell() {
        for legacy in [true, false] {
            let app = XCUIApplication()
            app.launchArguments += ["-kyro.c3.introduction.completed", "YES", "-kyroDebugMediaShell"]
            if legacy { app.launchArguments.append("-kyroDebugMediaShellLegacy") }
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["kyroDebugMediaHome"].firstMatch.waitForExistence(timeout: 25))
            sleep(3)
            capture(legacy ? "before-01-media-shell-home" : "after-01-media-shell-home", app)
            app.terminate()
        }
    }

    func testCaptureLiveTV() throws {
        var app = launchLiveTV(style: "glassDock")
        capture("after-03-livetv-home", app)
        openNavigation(app)
        capture("after-05-glass-dock", app)
        app.buttons["kyroLiveTVNav.channels"].tap()
        sleep(3)
        capture("after-04-livetv-channels", app)

        let gear = app.buttons["Live TV settings"]
        if gear.waitForExistence(timeout: 5) {
            gear.tap()
            let link = app.buttons["kyroLiveTVNavigationSettingsLink"]
            XCTAssertTrue(link.waitForExistence(timeout: 5))
            sleep(1)
            capture("after-07a-livetv-settings", app)
            link.tap()
            XCTAssertTrue(app.buttons["kyroNavStyle.thumbFan"].waitForExistence(timeout: 5))
            sleep(1)
            capture("after-07b-navigation-settings", app)
        }
        app.terminate()

        app = launchLiveTV(style: "thumbFan")
        openNavigation(app)
        capture("after-06-thumb-fan", app)
        app.terminate()
    }
}
