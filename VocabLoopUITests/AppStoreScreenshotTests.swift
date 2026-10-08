import XCTest

/// The App Store screenshots, captured from the running app.
///
/// Launches with `-appStoreScreenshots`, which wipes the app to a fresh install and seeds a demo
/// library (see `VocabLoop/App/AppStoreScreenshots.swift`): 24 of 30 cards done today, a 12-day
/// streak, Mochi at level 9, a finished sticker page. Six due cards are scripted — three flip
/// cards, a flip card to photograph, a multiple-choice question, and the card that reaches the goal.
///
/// Run by `.github/workflows/screenshots.yml`, which sets `TEST_RUNNER_APPSTORE_SCREENSHOTS=1`
/// (`xcodebuild` hands `TEST_RUNNER_`-prefixed variables to the test runner without the prefix).
/// Everywhere else it skips: it erases the app's data, which the regular suite should not
/// inherit halfway through.
final class AppStoreScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["APPSTORE_SCREENSHOTS"] == "1",
            "App Store screenshots run only from the screenshots workflow"
        )
        continueAfterFailure = false
        app = XCUIApplication()
        // Deliberately not `-uiTestingFlipOnly`: the second screenshot is a quiz.
        app.launchArguments = [
            "-appStoreScreenshots",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    func testAppStoreScreenshots() throws {
        // A wiped install imports every word pack before the first card: give it time.
        let showAnswer = app.buttons["显示答案"]
        XCTAssertTrue(showAnswer.waitForExistence(timeout: 240), "the study screen never showed a card")
        settle(1.5)

        // Three self-graded cards: the flame is lit already, these build a combo of three.
        for _ in 0..<3 { gradeFlipCardGood() }

        // 01 — the fourth card, front side, with the combo and candy under the top bar. Long
        // enough after the "连对 3 个！" toast (1.6 s) for it to have gone.
        XCTAssertTrue(showAnswer.waitForExistence(timeout: 10), "the fourth card is not a flip card")
        settle(3)
        capture("01-study")
        gradeFlipCardGood()

        // 02 — the multiple-choice question, right answer tapped and green.
        let correct = app.buttons["quiz.option.correct"]
        XCTAssertTrue(correct.waitForExistence(timeout: 10), "the fifth card is not a multiple-choice question")
        settle(1.5)
        correct.tap()
        let continueButton = app.buttons["继续"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10), "an answered quiz must offer Continue")
        settle(2)
        capture("02-quiz")
        continueButton.tap()
        settle(1)

        // 03 — the sixth card is review 30 of 30: the goal screen.
        gradeFlipCardGood()
        let goalTitle = app.staticTexts["goal.title"]
        XCTAssertTrue(goalTitle.waitForExistence(timeout: 10), "reaching the goal must show the goal screen")
        settle(3.5)
        capture("03-goal")

        // 04 — Mochi's room, from the Mochi peeking over the next card.
        let keepGoing = app.buttons["继续背"]
        XCTAssertTrue(keepGoing.waitForExistence(timeout: 5))
        keepGoing.tap()
        let mochi = app.buttons["麻薯"]
        XCTAssertTrue(mochi.waitForExistence(timeout: 15), "Mochi must peek over the next card")
        settle(1.5)
        mochi.tap()
        let sections = app.segmentedControls.firstMatch
        XCTAssertTrue(sections.waitForExistence(timeout: 10), "Mochi's room did not open")
        settle(2.5)
        capture("04-mochi")

        // 05 — the sticker book, opened on the finished first page.
        let stickersTab = sections.buttons["贴纸"]
        XCTAssertTrue(stickersTab.waitForExistence(timeout: 5))
        stickersTab.tap()
        settle(1.5)
        let completePage = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "第 1 页。", "已集齐"))
            .firstMatch
        var pushedAlbum = false
        if completePage.waitForExistence(timeout: 10) {
            completePage.tap()
            // The page's own title, "A1 名词 · 第 1 页", and the navigation title both say so.
            let pageTitle = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "第 1 页")).firstMatch
            pushedAlbum = pageTitle.waitForExistence(timeout: 10)
            XCTAssertTrue(pushedAlbum, "the finished sticker page did not open")
        } else {
            // Still a sticker book, just its contents page rather than a finished page.
            print("No finished sticker page found; capturing the sticker book's contents instead")
        }
        settle(2)
        capture("05-stickers")

        // Out of Mochi's room: back to its root if a page was pushed, then Done.
        if pushedAlbum {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists { back.tap() }
            settle(1)
        }
        let done = app.navigationBars.buttons["完成"].firstMatch
        if done.waitForExistence(timeout: 5) {
            done.tap()
        } else {
            // A sheet closes with a swipe down too.
            app.swipeDown(velocity: .fast)
        }
        settle(1.5)

        // The iPad set is the five store screenshots only; the purchase review screenshot (06)
        // comes from the iPhone run.
        if UIDevice.current.userInterfaceIdiom == .pad { return }

        // 06 — 设置 ▸ 麻薯 Plus, the in-app purchase review screenshot.
        let library = app.buttons["打开词库"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.tap()
        let settingsTab = app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10), "the library did not open")
        settingsTab.tap()
        var plusRow = app.buttons["settings.plus"]
        if !plusRow.waitForExistence(timeout: 10) {
            plusRow = app.staticTexts["麻薯 Plus"].firstMatch
        }
        XCTAssertTrue(plusRow.waitForExistence(timeout: 5), "Settings has no 麻薯 Plus row")
        plusRow.tap()
        XCTAssertTrue(app.staticTexts["plus.title"].waitForExistence(timeout: 10), "the Plus page did not open")
        let buy = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "解锁麻薯 Plus")).firstMatch
        XCTAssertTrue(buy.waitForExistence(timeout: 15), "the Plus page must show its purchase button")
        settle(2)
        capture("06-plus")
    }

    // MARK: - Helpers

    /// Reveal the current flip card and grade it "Good" (记得), then let the next card arrive.
    private func gradeFlipCardGood(file: StaticString = #filePath, line: UInt = #line) {
        let showAnswer = app.buttons["显示答案"]
        XCTAssertTrue(showAnswer.waitForExistence(timeout: 15), "expected a flip card", file: file, line: line)
        showAnswer.tap()
        let good = app.buttons["记得 —— 我想起来了"]
        XCTAssertTrue(good.waitForExistence(timeout: 10), "the rating bar did not appear", file: file, line: line)
        settle(0.6)
        good.tap()
        settle(1.2)
    }

    /// Let animations, toasts and sheet transitions finish before a capture.
    private func settle(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// The whole screen, status bar included, kept even though the test passes.
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
