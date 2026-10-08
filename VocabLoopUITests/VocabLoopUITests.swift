import XCTest

/// End-to-end smoke tests.
///
/// Deliberately few. UI tests are slow and brittle, so they cover the paths where a regression
/// would be invisible to the unit suite — namely that the app is *reachable and usable without an
/// account*, which is the product's central claim and cuts across onboarding, auth and the store.
final class VocabLoopUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // A flag the app acts on, not a value that overrides what the app reads.
        //
        // The previous form — `["-onboarding.completed", "NO"]` — put those keys in
        // `NSArgumentDomain`, which sits above the application domain and is read-only. Every
        // `@AppStorage` read then returned `false` regardless of what onboarding wrote, so
        // `RootView` bounced back to onboarding forever and no test in this file could reach the
        // tab bar. See `VocabLoopApp.resetFirstRunStateIfUITesting`.
        app.launchArguments = ["-uiTestingResetFirstRun"]
        // Every card a flip card, so taps on "显示答案" (Show answer) and the rating bar stay predictable.
        app.launchArguments += ["-uiTestingFlipOnly"]
        app.launch()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    /// The core claim: a user who never creates an account reaches a working app.
    ///
    /// Asserts the two things that make the claim true — that skipping is *offered* rather than
    /// buried, and that taking it lands on the app — instead of walking a fixed number of
    /// onboarding steps, which is a content decision that would break this test whenever it changes.
    func testGuestCanReachTodayWithoutAnAccount() throws {
        advanceThroughFirstRun(stoppingAt: "不注册，直接使用")

        let skip = app.buttons["不注册，直接使用"]
        XCTAssertTrue(skip.waitForExistence(timeout: 20), "guest mode must be offered, not buried")
        skip.tap()

        // The app's root is a study session now, not the tab bar — so "landed on the app" means
        // the session's library button is there, and the tabs are one tap behind it.
        XCTAssertTrue(
            libraryButton.waitForExistence(timeout: 20),
            "guest mode must land on the app, not a paywall"
        )
        // …and onto a card. A fresh install has no enrolled words; the session starts the most
        // common bundled ones itself. This once opened onto "Nothing to study" (现在没有要学的)
        // with a Done button that did nothing visible — reported from a real device.
        XCTAssertTrue(
            app.buttons["显示答案"].waitForExistence(timeout: 15),
            "a fresh install must open onto a word card"
        )
        XCTAssertFalse(app.staticTexts["现在没有要学的"].exists)
        libraryButton.tap()
        XCTAssertTrue(
            app.tabBars.buttons["今天"].waitForExistence(timeout: 10),
            "the library must open onto the tabs"
        )
    }

    func testEveryTabIsReachableAsAGuest() throws {
        let tabBar = reachMainTabs()

        for label in ["浏览", "词库", "进度", "设置", "今天"] {
            let tab = tabBar.buttons[label]
            XCTAssertTrue(tab.waitForExistence(timeout: 5), "\(label) tab is missing")
            tab.tap()
            XCTAssertTrue(tab.isSelected, "\(label) tab did not activate")
        }
    }

    /// The dictionary is bundled, so search must return results with no network involved.
    func testDictionarySearchFindsBundledContent() throws {
        let tabBar = reachMainTabs()
        tabBar.buttons["浏览"].tap()

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        searchField.typeText("because")

        XCTAssertTrue(
            app.staticTexts["because"].waitForExistence(timeout: 10),
            "a bundled A1 word must be findable offline"
        )
    }

    /// Settings must state plainly that studying works without an account.
    func testAccountScreenOffersSignInWithoutRequiringIt() throws {
        let tabBar = reachMainTabs()
        tabBar.buttons["设置"].tap()

        let guestRow = app.staticTexts["游客"].firstMatch
        XCTAssertTrue(guestRow.waitForExistence(timeout: 10), "Settings must show the guest identity")
        guestRow.tap()

        XCTAssertTrue(
            app.buttons["注册账号"].waitForExistence(timeout: 10)
                || app.buttons["登录"].waitForExistence(timeout: 2),
            "the account screen must offer signing in"
        )
    }

    /// A review session, end to end, as a user actually does it.
    ///
    /// The unit suite covers grading arithmetic thoroughly — 225 tests over FSRS, SM-2, the queue
    /// builder and the day rollups — but until now nothing drove the loop the whole app exists for:
    /// accept a word, return to the session, reveal, grade, keep going. Every step below is one
    /// the unit tests cannot see, because each is a wiring question rather than a logic one.
    func testAcceptingAWordAndReviewingKeepsGoing() throws {
        let tabBar = reachMainTabs()
        tabBar.buttons["今天"].tap()

        // Today's words are generated on device, so at least one is offered on a fresh install.
        let add = app.buttons["添加"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 20), "Today must offer a daily word to enrol")
        XCTAssertTrue(scrollToHit(add), "the daily word's Add button never became tappable")
        add.tap()

        // Today is a dashboard now, not a launcher: its button closes the library and returns to
        // the root session, which rebuilds its queue on the way back and so picks up the new word.
        let back = app.buttons["回去学习"]
        XCTAssertTrue(scrollToHit(back), "Today must offer a way back to the card")
        back.tap()

        let showAnswer = app.buttons["显示答案"]
        XCTAssertTrue(
            showAnswer.waitForExistence(timeout: 15),
            "returning from the library must present the word just enrolled"
        )
        showAnswer.tap()

        // All four grades, because a session offering fewer is a broken scheduler contract. The
        // visible labels became faces and plain words; the accessibility descriptions did not.
        let good = app.buttons["记得 —— 我想起来了"]
        XCTAssertTrue(good.waitForExistence(timeout: 10), "the rating bar must appear on reveal")
        for label in ["忘了 —— 我没想起来", "有点难 —— 想了好久才想起来",
                      "很简单 —— 一下就想起来了"] {
            XCTAssertTrue(app.buttons[label].exists, "missing rating: \(label)")
        }
        XCTAssertFalse(showAnswer.exists, "Show answer must go away once the answer is showing")

        // Keep going. With a bundled library the session never runs out — once the enrolled
        // cards are out of their steps it introduces more words — so the contract checked here is
        // that grading keeps producing cards rather than landing on a summary.
        var grades = 0
        while grades < 12 {
            if showAnswer.exists {
                showAnswer.tap()
            } else if good.waitForExistence(timeout: 5) {
                good.tap()
                grades += 1
            } else {
                break
            }
        }

        XCTAssertEqual(grades, 12, "the session stopped offering cards")
        XCTAssertFalse(app.staticTexts["都复习完了"].exists, "an endless session must not end")
        XCTAssertFalse(app.staticTexts["现在没有要学的"].exists)
        XCTAssertTrue(libraryButton.exists, "the library must stay one tap away mid-session")
    }

    /// Capture every top-level screen from the running app.
    ///
    /// `docs/screenshots/` holds renders of a faithful mockup, not the app — the project was
    /// written without a Swift toolchain, so until CI compiled it nobody had seen a single real
    /// frame. Colour and geometry come from the same tokens either way, but only a simulator can
    /// say whether the SwiftUI layout actually matches: whether anything clips, wraps, or overflows
    /// at a real width.
    ///
    /// The attachments land in `TestResults.xcresult`, which the workflow already uploads on every
    /// run, so this is browsable evidence rather than a claim. It asserts nothing beyond each screen
    /// being reachable — judging a layout is a human's job, and a test that pretended otherwise
    /// would only be a screenshot-diff suite that fails on every intentional change.
    func testCaptureEveryScreenForVisualReview() throws {
        let tabBar = reachMainTabs()
        attach(name: "01-today")

        // Tab labels are Chinese; the attachment names stay ASCII so the files sort and open
        // anywhere.
        let tabs = [("浏览", "browse"), ("词库", "decks"), ("进度", "progress"), ("设置", "settings")]
        for (index, (label, fileName)) in tabs.enumerated() {
            let tab = tabBar.buttons[label]
            guard tab.waitForExistence(timeout: 5) else {
                XCTFail("\(label) tab is missing")
                continue
            }
            tab.tap()
            // Numbered so the attachments sort in tab order rather than alphabetically.
            attach(name: String(format: "%02d-%@", index + 2, fileName))
        }

        // One screen deeper, because a word's detail view is the densest layout in the app and so
        // the most likely to clip or overflow at a real width.
        tabBar.buttons["浏览"].tap()
        let firstWord = app.cells.firstMatch
        if firstWord.waitForExistence(timeout: 10), scrollToHit(firstWord, attempts: 2) {
            firstWord.tap()
            attach(name: "06-word-detail")
        }
    }

    /// Attach a full-screen capture that survives a passing run.
    ///
    /// `.keepAlways`, because the default discards attachments when the test passes — and a passing
    /// run is exactly when these are wanted.
    private func attach(name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Helpers

    /// Bring an element into view, swiping up until it can be tapped.
    ///
    /// `XCUIElement.tap()` does not reliably scroll a SwiftUI `ScrollView` to its target, so an
    /// element that exists but sits below the fold fails with "not hittable" — which reads like a
    /// missing feature rather than a scroll position. Today's daily-word list is below the primary
    /// tile on a phone, so this is the ordinary case, not an edge one.
    private func scrollToHit(_ element: XCUIElement, attempts: Int = 6) -> Bool {
        for _ in 0..<attempts {
            if element.isHittable { return true }
            app.swipeUp()
        }
        return element.isHittable
    }

    /// Buttons that move the first-run flow forward, most-specific first.
    ///
    /// Ordered so the terminal actions win: on the last onboarding step both "开始学习" (Start
    /// learning) and nothing else is present, but checking "继续" (Continue) first would be wrong
    /// the moment a screen shows both. ("Get started" was dropped: no screen offers it, in
    /// English or Chinese.)
    private static let firstRunAdvanceButtons = [
        "不注册，直接使用", "开始学习", "继续",
    ]

    /// The root session's leading button, which opens the tabs.
    private var libraryButton: XCUIElement { app.buttons["打开词库"] }

    /// Drive the first-run screens until the tab bar is up.
    ///
    /// One loop rather than "complete onboarding, then dismiss the auth landing". The number of
    /// onboarding steps and the order of the first-run screens are product decisions; a test that
    /// encodes them fails on every copy change, and a UI test that fails for a reason other than a
    /// real regression stops being read. What every test here actually needs is the tab bar.
    ///
    /// The first launch also imports the bundled content packs before `RootView` advances, so the
    /// budget is generous: a cold simulator is slow and a flaky timeout is worse than a slow test.
    @discardableResult
    private func reachMainTabs(timeout: TimeInterval = 90) -> XCUIElement {
        advanceThroughFirstRun(timeout: timeout)
        // The first run ends on a card, not on the tabs: the root of the app is a study session
        // and the tabs live in the library sheet behind its leading button.
        if libraryButton.waitForExistence(timeout: 10) { libraryButton.tap() }
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(
            tabBar.waitForExistence(timeout: 10),
            "never reached the tab bar; the app is stuck on a first-run screen"
        )
        return tabBar
    }

    /// Tap first-run buttons until the tab bar appears, or until `stoppingAt` is on screen.
    ///
    /// `stoppingAt` exists so a test can assert something *about* a first-run screen — that the
    /// guest option is offered, say — rather than only about what is past it.
    private func advanceThroughFirstRun(timeout: TimeInterval = 90, stoppingAt label: String? = nil) {
        let tabBar = app.tabBars.firstMatch
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if tabBar.exists || libraryButton.exists { return }
            if let label, app.buttons[label].exists { return }

            let next = Self.firstRunAdvanceButtons
                .map { app.buttons[$0] }
                .first { $0.exists && $0.isHittable }

            guard let next else {
                // Nothing to tap yet — most likely still on the launch screen while content
                // imports. Poll rather than give up; `waitForExistence` on the tab bar is a
                // one-second sleep with a useful side effect.
                _ = tabBar.waitForExistence(timeout: 1)
                continue
            }
            next.tap()
        }
    }
}
