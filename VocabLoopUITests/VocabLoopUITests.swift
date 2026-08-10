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
        advanceThroughFirstRun(stoppingAt: "Continue without an account")

        let skip = app.buttons["Continue without an account"]
        XCTAssertTrue(skip.waitForExistence(timeout: 20), "guest mode must be offered, not buried")
        skip.tap()

        XCTAssertTrue(
            app.tabBars.buttons["Today"].waitForExistence(timeout: 20),
            "guest mode must land on the app, not a paywall"
        )
    }

    func testEveryTabIsReachableAsAGuest() throws {
        let tabBar = reachMainTabs()

        for label in ["Browse", "Decks", "Progress", "Settings", "Today"] {
            let tab = tabBar.buttons[label]
            XCTAssertTrue(tab.waitForExistence(timeout: 5), "\(label) tab is missing")
            tab.tap()
            XCTAssertTrue(tab.isSelected, "\(label) tab did not activate")
        }
    }

    /// The dictionary is bundled, so search must return results with no network involved.
    func testDictionarySearchFindsBundledContent() throws {
        let tabBar = reachMainTabs()
        tabBar.buttons["Browse"].tap()

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
        tabBar.buttons["Settings"].tap()

        let guestRow = app.staticTexts["Guest"].firstMatch
        XCTAssertTrue(guestRow.waitForExistence(timeout: 10), "Settings must show the guest identity")
        guestRow.tap()

        XCTAssertTrue(
            app.buttons["Create an account"].waitForExistence(timeout: 10)
                || app.buttons["Sign in"].waitForExistence(timeout: 2),
            "the account screen must offer signing in"
        )
    }

    /// A review session, end to end, as a user actually does it.
    ///
    /// The unit suite covers grading arithmetic thoroughly — 225 tests over FSRS, SM-2, the queue
    /// builder and the day rollups — but until now nothing drove the loop the whole app exists for:
    /// accept a word, start a session, reveal, grade, land on the summary. Every step below is one
    /// the unit tests cannot see, because each is a wiring question rather than a logic one.
    func testAcceptingAWordAndReviewingItReachesTheSummary() throws {
        let tabBar = reachMainTabs()
        tabBar.buttons["Today"].tap()

        // Today's words are generated on device, so at least one is offered on a fresh install.
        let add = app.buttons["Add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 20), "Today must offer a daily word to enrol")
        XCTAssertTrue(scrollToHit(add), "the daily word's Add button never became tappable")
        add.tap()

        // The Today tile is one combined accessibility element whose label leads with the call to
        // action, so it is matched on that rather than on an exact string that includes counts.
        let startStudying = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Learn")
        ).firstMatch
        XCTAssertTrue(
            startStudying.waitForExistence(timeout: 15),
            "enrolling a word must turn the Today tile into an invitation to learn it"
        )
        startStudying.tap()

        let showAnswer = app.buttons["Show answer"]
        XCTAssertTrue(showAnswer.waitForExistence(timeout: 15), "the session must present a card")
        showAnswer.tap()

        // All four ratings, because a session offering fewer is a broken scheduler contract.
        let good = app.buttons["Good — I remembered it"]
        XCTAssertTrue(good.waitForExistence(timeout: 10), "the rating bar must appear on reveal")
        for label in ["Again — I did not remember this", "Hard — I remembered it with difficulty",
                      "Easy — I remembered it immediately"] {
            XCTAssertTrue(app.buttons[label].exists, "missing rating: \(label)")
        }
        XCTAssertFalse(showAnswer.exists, "Show answer must go away once the answer is showing")

        // Grade until the session ends. Bounded: pressing Good on a new card walks it through the
        // learning steps, so it comes back a couple of times before the queue empties.
        let done = app.buttons["Done"]
        var grades = 0
        while grades < 12, !done.exists {
            if showAnswer.exists {
                showAnswer.tap()
            } else if good.exists {
                good.tap()
                grades += 1
            } else {
                break
            }
        }

        XCTAssertGreaterThan(grades, 0, "no card was ever graded")
        XCTAssertTrue(
            done.waitForExistence(timeout: 10),
            "the session must end on a summary with a way out, not a dead end"
        )
        XCTAssertTrue(app.staticTexts["Session complete"].exists)

        done.tap()
        XCTAssertTrue(
            tabBar.waitForExistence(timeout: 10),
            "finishing a session must return to the app, not leave the cover up"
        )
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

        for (index, label) in ["Browse", "Decks", "Progress", "Settings"].enumerated() {
            let tab = tabBar.buttons[label]
            guard tab.waitForExistence(timeout: 5) else {
                XCTFail("\(label) tab is missing")
                continue
            }
            tab.tap()
            // Numbered so the attachments sort in tab order rather than alphabetically.
            attach(name: String(format: "%02d-%@", index + 2, label.lowercased()))
        }

        // One screen deeper, because a word's detail view is the densest layout in the app and so
        // the most likely to clip or overflow at a real width.
        tabBar.buttons["Browse"].tap()
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
    /// Ordered so the terminal actions win: on the last onboarding step both "Start learning" and
    /// nothing else is present, but checking "Continue" first would be wrong the moment a screen
    /// shows both.
    private static let firstRunAdvanceButtons = [
        "Continue without an account", "Start learning", "Continue", "Get started",
    ]

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
            if tabBar.exists { return }
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
