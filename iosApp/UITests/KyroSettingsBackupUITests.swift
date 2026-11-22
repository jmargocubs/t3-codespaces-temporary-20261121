import UIKit
import XCTest

/// Build 92: Settings → Account & Connections → Backup & Restore, driven through the real UI on an
/// iPhone simulator. Covers the system Files picker with a file Kyro itself exported, the Paste
/// Backup Text fallback, the preview, selective restore, Undo, refusal of text that isn't a backup,
/// and the size limit. Every step saves a screenshot to the result bundle as evidence.
///
/// Uses the Debug-only `-kyroDebugSettingsRoute`, which opens the real Settings screen without a
/// server. The fourth-tab choice in Settings → Navigation is the backed-up setting the tests change,
/// because it shows its current value as a selected row.
final class KyroSettingsBackupUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    // MARK: Files picker

    func testExportedBackupCanBePickedInFilesAndPreviewed() {
        let app = launch()
        openBackup(app)
        snap("01 Backup & Restore")
        XCTAssertTrue(app.buttons["settingsBackup.options"].exists)
        XCTAssertFalse(app.buttons["settingsBackup.copyText"].exists, "advanced export starts collapsed")

        tapScrolling(app.buttons["settingsBackup.export"], in: app)
        let save = app.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 20), "the Files save sheet opens")
        snap("02 Export save sheet")
        save.tap()
        if app.buttons["Replace"].waitForExistence(timeout: 3) { app.buttons["Replace"].tap() }
        XCTAssertTrue(text(containing: "Settings exported", in: app).waitForExistence(timeout: 20), "export finished")
        snap("03 Exported")

        tapScrolling(app.buttons["settingsBackup.import"], in: app)
        let backupFile = findExportedBackup(in: app)
        snap("04 Files picker showing the exported backup")
        XCTAssertTrue(backupFile.isHittable, "the exported .kyrosettings file is selectable")
        backupFile.tap()

        // A pick that never reaches Kyro (Builds 88–91 on iPhone) would leave no preview.
        XCTAssertTrue(app.buttons["settingsBackup.done"].waitForExistence(timeout: 20), "Kyro received the file and shows the review")
        XCTAssertTrue(text(containing: "Your settings already match this backup", in: app).exists, "the same device's backup has no changes")
        snap("05 Preview after picking the file")
        app.buttons["settingsBackup.done"].tap()
        XCTAssertTrue(app.buttons["settingsBackup.import"].waitForExistence(timeout: 5))
    }

    // MARK: Paste Backup Text

    func testPastedBackupPreviewsRestoresSelectedGroupAndUndoes() {
        let app = launch()
        chooseFourthTab("favorites", app)

        openBackup(app)
        tapScrolling(app.buttons["settingsBackup.options"], in: app)
        tapScrolling(app.buttons["settingsBackup.copyText"], in: app)
        XCTAssertTrue(text(containing: "Settings copied as text", in: app).waitForExistence(timeout: 5))
        snap("10 Copied settings as text")

        chooseFourthTab("forYou", app)
        openBackup(app)
        tapScrolling(app.buttons["settingsBackup.paste"], in: app)
        XCTAssertTrue(app.navigationBars["Paste Backup Text"].waitForExistence(timeout: 5), "the paste screen opens")
        snap("11 Paste screen")

        paste(into: app)
        snap("12 Backup text pasted")
        app.buttons["settingsBackup.pasteReview"].tap()

        // Preview: exactly the fourth tab differs.
        let apply = app.buttons["settingsBackup.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10), "a valid backup closes the paste screen and shows the preview")
        XCTAssertTrue(text(containing: "1 setting will change", in: app).exists)
        XCTAssertTrue(text(containing: "Fourth tab", in: app).exists)
        snap("13 Preview of differences")

        // Selective restore: turning the one setting off leaves nothing to apply.
        let fourthTab = app.switches["settingsBackup.change.navigation.fourthTab"]
        XCTAssertTrue(fourthTab.waitForExistence(timeout: 5))
        toggle(fourthTab)
        XCTAssertTrue(waitFor(apply, label: "Restore 0 Settings"), apply.label)
        XCTAssertFalse(apply.isEnabled)
        snap("14 Navigation group deselected")
        toggle(fourthTab)
        XCTAssertTrue(waitFor(apply, label: "Restore 1 Setting"), apply.label)

        apply.tap()
        let confirm = app.buttons["Restore Settings"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(text(containing: "1 setting updated", in: app).waitForExistence(timeout: 10))
        snap("15 Restored")
        app.buttons["settingsBackup.done"].tap()
        XCTAssertTrue(fourthTabIsSelected("favorites", app), "the restore wrote the backed-up value")

        openBackup(app)
        tapScrolling(app.buttons["settingsBackup.undo"], in: app)
        XCTAssertTrue(app.buttons["Undo Last Restore"].waitForExistence(timeout: 5))
        app.buttons["Undo Last Restore"].tap()
        XCTAssertTrue(text(containing: "Undid 1 setting", in: app).waitForExistence(timeout: 10))
        snap("16 Undone")
        XCTAssertTrue(fourthTabIsSelected("forYou", app), "Undo put back the earlier value")
    }

    func testTextThatIsNotABackupIsRefused() {
        let app = launch()
        openBackup(app)
        tapScrolling(app.buttons["settingsBackup.paste"], in: app)
        let editor = app.textViews["settingsBackup.pasteText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("{\"format\": \"not-kyro\"}")
        app.buttons["settingsBackup.pasteReview"].tap()

        let problem = app.descendants(matching: .any)["settingsBackup.pasteProblem"].firstMatch
        XCTAssertTrue(problem.waitForExistence(timeout: 5), "the reason is shown on the paste screen")
        XCTAssertTrue(problem.label.contains("isn't a Kyro settings backup"), problem.label)
        XCTAssertTrue(app.navigationBars["Paste Backup Text"].exists, "the paste screen stays open")
        snap("20 Invalid text refused")

        app.buttons["settingsBackup.pasteCancel"].tap()
        XCTAssertTrue(app.buttons["settingsBackup.import"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settingsBackup.apply"].exists, "nothing was loaded")
    }

    func testPastedTextOverTheSizeLimitIsRefused() {
        let app = launch()
        openBackup(app)
        tapScrolling(app.buttons["settingsBackup.paste"], in: app)
        XCTAssertTrue(app.textViews["settingsBackup.pasteText"].waitForExistence(timeout: 5))

        UIPasteboard.general.string = String(repeating: "x", count: 300 * 1024)
        tapPasteButton(app)
        let problem = app.descendants(matching: .any)["settingsBackup.pasteProblem"].firstMatch
        XCTAssertTrue(problem.waitForExistence(timeout: 10), "an oversized paste is refused")
        XCTAssertTrue(problem.label.contains("too long"), problem.label)
        XCTAssertFalse(app.buttons["settingsBackup.pasteReview"].isEnabled, "the oversized text is not kept")
        snap("30 Oversized text refused")
    }

    // MARK: Helpers

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-kyro.c3.introduction.completed", "YES", "-kyroDebugSettingsRoute",
                                "-kyroDebugGlobalNavigationReset"]
        app.launch()
        XCTAssertTrue(app.buttons["kyroDebugSettingsClose"].waitForExistence(timeout: 40), "Settings opened")
        return app
    }

    private func popToSettingsRoot(_ app: XCUIApplication) {
        let close = app.buttons["kyroDebugSettingsClose"]
        var attempts = 0
        while !close.exists && attempts < 5 {
            app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
            _ = close.waitForExistence(timeout: 2)
            attempts += 1
        }
        XCTAssertTrue(close.exists, "back at the Settings root")
    }

    private func openBackup(_ app: XCUIApplication) {
        popToSettingsRoot(app)
        tapScrolling(app.staticTexts["Account & Connections"].firstMatch, in: app)
        tapScrolling(app.descendants(matching: .any)["settings.backupRestore"].firstMatch, in: app)
        XCTAssertTrue(app.navigationBars["Backup & Restore"].waitForExistence(timeout: 10), "Backup & Restore opened")
    }

    /// Navigation settings live under Settings > Appearance & Navigation.
    private func openNavigationSettings(_ app: XCUIApplication) {
        tapScrolling(app.staticTexts["Appearance & Navigation"].firstMatch, in: app)
        tapScrolling(app.buttons["kyroSettingsNavigation"], in: app)
    }

    private func chooseFourthTab(_ choice: String, _ app: XCUIApplication) {
        popToSettingsRoot(app)
        openNavigationSettings(app)
        let row = app.buttons["kyroFourthTab-\(choice)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(waitForSelected(row), "\(choice) chosen")
    }

    private func fourthTabIsSelected(_ choice: String, _ app: XCUIApplication) -> Bool {
        popToSettingsRoot(app)
        openNavigationSettings(app)
        let row = app.buttons["kyroFourthTab-\(choice)"]
        guard row.waitForExistence(timeout: 5) else { return false }
        snap("Navigation shows \(choice)")
        return waitForSelected(row)
    }

    private func tapScrolling(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element) exists")
        var swipes = 0
        while !element.isHittable && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(element.isHittable, "\(element) is on screen")
        element.tap()
    }

    private func text(containing fragment: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    /// The exported file in the Files picker: Recents first, then On My iPhone.
    private func findExportedBackup(in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "label BEGINSWITH 'Kyro Settings'")
        let file = app.cells.matching(predicate).firstMatch
        let fileText = app.staticTexts.matching(predicate).firstMatch
        if file.waitForExistence(timeout: 15) { return file }
        if fileText.exists { return fileText }
        snap("04a Files picker before browsing")
        let browse = app.buttons["Browse"].firstMatch
        if browse.exists { browse.tap() }
        let onDevice = app.staticTexts["On My iPhone"].firstMatch
        if onDevice.waitForExistence(timeout: 10) { onDevice.tap() }
        if file.waitForExistence(timeout: 15) { return file }
        XCTAssertTrue(fileText.waitForExistence(timeout: 5), "the exported backup is listed in Files")
        return fileText
    }

    private func tapPasteButton(_ app: XCUIApplication) {
        let paste = app.buttons["settingsBackup.pasteButton"].exists
            ? app.buttons["settingsBackup.pasteButton"] : app.buttons["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "the Paste button is shown")
        paste.tap()
        let allow = app.alerts.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
    }

    /// Pastes with the Paste button, falling back to the text view's edit menu.
    private func paste(into app: XCUIApplication) {
        let editor = app.textViews["settingsBackup.pasteText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        tapPasteButton(app)
        if !waitFor(editor, valueLongerThan: 100) {
            editor.press(forDuration: 1.2)
            let menuPaste = app.menuItems["Paste"].firstMatch
            if menuPaste.waitForExistence(timeout: 3) { menuPaste.tap() }
        }
        XCTAssertTrue(waitFor(editor, valueLongerThan: 100), "the backup text is in the editor")
        XCTAssertTrue(app.buttons["settingsBackup.pasteReview"].isEnabled)
    }

    private func toggle(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    private func waitFor(_ element: XCUIElement, label: String, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitFor(_ element: XCUIElement, valueLongerThan count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ((element.value as? String) ?? "").count > count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
    }

    private func waitForSelected(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
