import XCTest

/// Hold-to-move on the floating Live TV navigation, for both styles, over the
/// fixture Live TV pushed onto a navigation stack as the app does.
///
/// Positions are the handle's rendered frame. "Follows the finger" comes from
/// the app's handle trace (`kyroLiveTVNavTrace`, Debug only): every frame
/// laid out while the handle was picked up, how far it travelled and how far
/// it trailed the finger, measured before the snap.
final class KyroNavigationDragUITests: XCTestCase {
    private static let styles = ["glassDock", "thumbFan"]

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(style: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // The floating styles belong to the earlier navigation, which the unified shell replaced on iPhone.
        app.launchArguments += ["-kyro.c3.introduction.completed", "YES", "-kyro.navigation.legacyShell", "YES",
                                "-kyroDebugLiveTVFixture",
                                "-kyroDebugLiveTVNavReset", "-kyroDebugLiveTVNavIdle", "stayVisible",
                                "-kyroDebugLiveTVNavStyle", style] + extra
        app.launch()
        XCTAssertTrue(handle(app).waitForExistence(timeout: 25), "Live TV navigation")
        XCTAssertTrue(app.staticTexts["liveTVHomeFavoritesHeader"].waitForExistence(timeout: 15), "Fixture Home loaded")
        sleep(2)
        return app
    }

    private func handle(_ app: XCUIApplication) -> XCUIElement { app.buttons["kyroLiveTVNavHandle"] }
    private func handleTouch(_ app: XCUIApplication) -> XCUICoordinate {
        handle(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }
    private func item(_ name: String, _ app: XCUIApplication) -> XCUIElement { app.buttons["kyroLiveTVNav.\(name)"] }
    private func window(_ app: XCUIApplication) -> XCUIElement { app.windows.firstMatch }
    private func trace(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["kyroLiveTVNavTrace"].value as? String ?? ""
    }

    private func number(_ label: String, in trace: String) -> Int? {
        guard let range = trace.range(of: "\(label) (\\d+)", options: .regularExpression) else { return nil }
        return Int(trace[range].split(separator: " ").last ?? "")
    }

    /// Hold the handle, drag at finger speed to a fraction of the window, pause, lift.
    private func drag(_ app: XCUIApplication, toX x: CGFloat, y: CGFloat, hold: TimeInterval = 0.6) {
        let start = handle(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = window(app).coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
        // A moderate velocity gives the simulator several touch/layout samples;
        // the trace then proves rendered motion rather than a single jump.
        start.press(forDuration: hold, thenDragTo: end, withVelocity: XCUIGestureVelocity(100), thenHoldForDuration: 0.5)
        sleep(1)
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Follows, then snaps

    func testHandleFollowsTheFingerThenSnapsAndPersists() {
        for style in Self.styles {
            let app = launch(style: style)
            let size = window(app).frame.size

            // Use a touch-driven coordinate tap, not XCTest's accessibility
            // activation of the custom button trait. This exercises the same
            // recognizer path as a finger tap on device.
            handleTouch(app).tap()
            XCTAssertTrue(item("home", app).waitForExistence(timeout: 3),
                          "\(style): a physical tap still opens; trace=\(trace(app))")
            XCTAssertTrue(trace(app).hasPrefix("tap"), "\(style): \(trace(app))")
            window(app).coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
            XCTAssertTrue(item("home", app).waitForNonExistence(timeout: 3))

            // Make the intended left edge unambiguous: this point is farther
            // from the top/bottom safe-area edges than from the left edge.
            drag(app, toX: 0.12, y: 0.5)
            let summary = trace(app)
            XCTAssertTrue(summary.hasPrefix("moved"), "\(style): \(summary)")
            XCTAssertGreaterThanOrEqual(number("rendered", in: summary) ?? 0, 5, "\(style): rendered while held: \(summary)")
            XCTAssertGreaterThan(number("travel", in: summary) ?? 0, Int(size.width * 0.4),
                                 "\(style): the rendered handle crossed the screen before release: \(summary)")
            XCTAssertLessThanOrEqual(number("lag", in: summary) ?? 999, 24, "\(style): stayed under the finger: \(summary)")
            XCTAssertTrue(summary.contains("snapped left"), "\(style): \(summary)")
            XCTAssertFalse(item("home", app).exists, "\(style): moving does not open the navigation")

            let snapped = handle(app).frame
            XCTAssertLessThan(snapped.midX, size.width * 0.2, "\(style): snapped to the left edge")
            capture("drag-\(style)-snapped-left", app)

            // Persists across navigation and relaunch. Thumb Fan items spring out of the
            // orb with a stagger, so wait until Guide is hittable and the spring settles
            // before tapping where it ends up.
            handleTouch(app).tap()
            let guide = item("guide", app)
            XCTAssertTrue(guide.waitForExistence(timeout: 3), "\(style): navigation opened; trace=\(trace(app))")
            XCTAssertTrue(guide.waitUntilHittable(timeout: 3), "\(style): Guide reachable")
            usleep(700_000)
            guide.tap()
            XCTAssertTrue(app.staticTexts["TV Guide"].waitForExistence(timeout: 5))
            sleep(1)
            XCTAssertLessThan(handle(app).frame.midX, size.width * 0.2, "\(style): same edge on the Guide")
            app.terminate()

            let again = XCUIApplication()
            again.launchArguments += ["-kyro.c3.introduction.completed", "YES", "-kyro.navigation.legacyShell", "YES",
                                      "-kyroDebugLiveTVFixture", "-kyroDebugLiveTVNavStyle", style]
            again.launch()
            XCTAssertTrue(handle(again).waitForExistence(timeout: 25))
            XCTAssertTrue(again.staticTexts["liveTVHomeFavoritesHeader"].waitForExistence(timeout: 15))
            sleep(1)
            XCTAssertEqual(handle(again).frame.midX, snapped.midX, accuracy: 4, "\(style): survives relaunch")
            XCTAssertEqual(handle(again).frame.midY, snapped.midY, accuracy: 4)
            again.terminate()
        }
    }

    func testNormalSlowAndStationaryLongPressRemainTaps() {
        for style in Self.styles {
            let app = launch(style: style)
            let originalFrame = handle(app).frame
            for (name, duration) in [("normal", 0.0), ("slow", 0.25), ("stationary hold", 0.65)] {
                if duration == 0 {
                    handleTouch(app).tap()
                } else {
                    handleTouch(app).press(forDuration: duration)
                }
                XCTAssertTrue(item("home", app).waitForExistence(timeout: 3),
                              "\(style) \(name) opens the menu; trace=\(trace(app))")
                XCTAssertTrue(trace(app).hasPrefix("tap"), "\(style) \(name): \(trace(app))")
                // Avoid the navigation-stack Back button in the upper-left.
                window(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                XCTAssertTrue(item("home", app).waitForNonExistence(timeout: 3),
                              "\(style) \(name) menu closes on scrim tap")
                XCTAssertEqual(handle(app).frame.midX, originalFrame.midX, accuracy: 2,
                               "\(style) \(name) must not reposition")
                XCTAssertEqual(handle(app).frame.midY, originalFrame.midY, accuracy: 2)
            }
            app.terminate()
        }
    }

    // MARK: Every edge and corner

    func testSnapsToEveryEdgeAndCornerInBothStyles() {
        let targets: [(name: String, x: CGFloat, y: CGFloat)] = [
            ("left", 0.03, 0.5), ("top", 0.5, 0.02), ("right", 0.97, 0.5), ("bottom", 0.5, 0.98),
            ("top-left", 0.02, 0.02), ("top-right", 0.98, 0.02), ("bottom-left", 0.02, 0.98), ("bottom-right", 0.98, 0.98)
        ]
        for style in Self.styles {
            let app = launch(style: style)
            let bounds = window(app).frame
            for target in targets {
                drag(app, toX: target.x, y: target.y)
                let frame = handle(app).frame
                let label = "\(style) \(target.name): \(trace(app))"
                XCTAssertTrue(trace(app).hasPrefix("moved"), label)
                XCTAssertTrue(bounds.contains(frame), "On screen: \(label)")
                XCTAssertLessThan(frame.maxY, bounds.height - 34, "Clear of the home indicator: \(label)")
                if target.name.contains("left") { XCTAssertLessThan(frame.midX, bounds.width * 0.2, label) }
                if target.name.contains("right") { XCTAssertGreaterThan(frame.midX, bounds.width * 0.8, label) }
                if target.name.contains("top") { XCTAssertLessThan(frame.midY, bounds.height * 0.3, label) }
                if target.name.contains("bottom") { XCTAssertGreaterThan(frame.midY, bounds.height * 0.75, label) }
                if !target.name.contains("-") {
                    XCTAssertTrue(trace(app).contains("snapped \(target.name)"), label)
                }
            }
            capture("drag-\(style)-bottom-right-corner", app)
            app.terminate()
        }
    }

    // MARK: Dragging off

    func testWithDraggingOffTheHandleStaysAndTapsStillOpen() {
        for style in Self.styles {
            let app = launch(style: style, ["-kyroDebugLiveTVNavNoDrag"])
            let before = handle(app).frame
            drag(app, toX: 0.06, y: 0.35, hold: 0.8)
            XCTAssertFalse(trace(app).contains("picked up"), "\(style): \(trace(app))")
            XCTAssertTrue(app.staticTexts["liveTVHomeFavoritesHeader"].exists, "\(style): nothing was chosen")
            if item("home", app).exists {
                window(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                XCTAssertTrue(item("home", app).waitForNonExistence(timeout: 3))
            }
            XCTAssertEqual(handle(app).frame.midX, before.midX, accuracy: 2, "\(style): did not move")
            XCTAssertEqual(handle(app).frame.midY, before.midY, accuracy: 2)
            handleTouch(app).tap()
            XCTAssertTrue(item("home", app).waitForExistence(timeout: 3), "\(style): a tap still opens")
            app.terminate()
        }
    }

    // MARK: Coexistence

    func testDroppingOverChannelsNeitherChoosesNorPlays() {
        for style in Self.styles {
            let app = launch(style: style)
            let card = app.staticTexts["Classic Cinema"].firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            let start = handle(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.6, thenDragTo: card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                        withVelocity: XCUIGestureVelocity(300), thenHoldForDuration: 0.5)
            sleep(2)
            XCTAssertTrue(trace(app).hasPrefix("moved"), "\(style): \(trace(app))")
            XCTAssertTrue(app.staticTexts["liveTVHomeFavoritesHeader"].isHittable, "\(style): no channel opened or played")
            XCTAssertFalse(item("home", app).exists, "\(style): no destination chosen")
            app.terminate()
        }
    }
}

private extension XCUIElement {
    func waitUntilHittable(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists && isHittable { return true }
            usleep(150_000)
        }
        return exists && isHittable
    }
}
