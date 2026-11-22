import XCTest

final class KyroProgramSearchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // `-kyroDebugLiveTVFixture` triggers the fixture; `-kyroDebugSearchFixture` picks Search over it.
        app.launchArguments += ["-kyro.c3.introduction.completed", "YES",
                                "-kyroDebugLiveTVFixture", "-kyroDebugSearchFixture"]
        app.launchArguments += extra
        app.launch()
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 30), "Search fixture loaded")
        return app
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func queryArguments(_ query: String) -> [String] {
        ["-kyroDebugSearchQuery", query]
    }

    func testProgramSearchShowsCurrentAndUpcomingResultsWithoutEnded() {
        let app = launch(queryArguments("Championship"))
        XCTAssertTrue(app.staticTexts["TV Programs"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Live TV"].exists)
        XCTAssertFalse(app.staticTexts["Live TV Channels"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "On now")).firstMatch
            .waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Upcoming")).firstMatch
            .waitForExistence(timeout: 30))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Ended")).count, 0)
        capture("search-programs-after", app)
    }

    func testProgramSearchCanShowBeforeStateWithoutPrograms() {
        let app = launch(queryArguments("Championship") + ["-kyroDebugSearchNoPrograms"])
        XCTAssertTrue(app.staticTexts["Live TV"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["TV Programs"].exists)
        capture("search-programs-before", app)
    }

    func testProgramSearchEmptyState() {
        let app = launch(queryArguments("zzzzqq"))
        XCTAssertTrue(app.staticTexts["No matching TV programs"].waitForExistence(timeout: 30))
        capture("search-programs-empty", app)
    }

    func testProgramSearchUnavailableWhenGuideFails() {
        let app = launch(queryArguments("Championship") + ["-kyroDebugSearchNoGuide"])
        XCTAssertTrue(app.staticTexts["No TV guide is available."].waitForExistence(timeout: 30))
        capture("search-programs-unavailable", app)
    }

    func testProgramDetailWatchResolvesAndChoosesChannel() {
        let app = launch(queryArguments("Championship"))
        let current = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "On now")).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        current.tap()
        XCTAssertTrue(app.staticTexts["Championship Live"].waitForExistence(timeout: 15))
        let watch = app.buttons["Watch Now"]
        XCTAssertTrue(watch.waitForExistence(timeout: 15))
        capture("search-program-detail", app)
        watch.tap()
        XCTAssertFalse(app.alerts["Program Unavailable"].waitForExistence(timeout: 3))
        let watching = app.descendants(matching: .any)["kyroDebugSearchWatching"]
        XCTAssertTrue(watching.waitForExistence(timeout: 15))
        let chosen = NSPredicate(format: "label != %@", "none")
        expectation(for: chosen, evaluatedWith: watching)
        waitForExpectations(timeout: 15)
    }

    func testProgramDetailInvalidatesWhenProviderIsRemoved() {
        let app = launch(queryArguments("Championship") + ["-kyroDebugSearchRemoveProviderAfter", "15"])
        let current = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "On now")).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        current.tap()
        XCTAssertTrue(app.buttons["Watch Now"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.alerts["Program Unavailable"].waitForExistence(timeout: 40))
        app.alerts["Program Unavailable"].buttons["OK"].tap()
        XCTAssertFalse(app.alerts["Program Unavailable"].exists)
    }
}
