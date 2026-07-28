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
        // Reset onboarding so each run starts from a first-launch state; without this the suite
        // passes locally and fails on a clean simulator, or vice versa.
        app.launchArguments = ["-onboarding.completed", "NO", "-auth.landingShown", "NO"]
        app.launch()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    /// The core claim: a user who never creates an account reaches a working app.
    func testGuestCanReachTodayWithoutAnAccount() throws {
        completeOnboarding()

        let skip = app.buttons["Continue without an account"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10), "guest mode must be offered, not buried")
        skip.tap()

        XCTAssertTrue(
            app.tabBars.buttons["Today"].waitForExistence(timeout: 10),
            "guest mode must land on the app, not a paywall"
        )
    }

    func testEveryTabIsReachableAsAGuest() throws {
        completeOnboarding()
        tapIfPresent(app.buttons["Continue without an account"])

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

        for label in ["Browse", "Decks", "Progress", "Settings", "Today"] {
            let tab = tabBar.buttons[label]
            XCTAssertTrue(tab.waitForExistence(timeout: 5), "\(label) tab is missing")
            tab.tap()
            XCTAssertTrue(tab.isSelected, "\(label) tab did not activate")
        }
    }

    /// The dictionary is bundled, so search must return results with no network involved.
    func testDictionarySearchFindsBundledContent() throws {
        completeOnboarding()
        tapIfPresent(app.buttons["Continue without an account"])

        app.tabBars.buttons["Browse"].tap()

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
        completeOnboarding()
        tapIfPresent(app.buttons["Continue without an account"])

        app.tabBars.buttons["Settings"].tap()
        app.staticTexts["Guest"].firstMatch.tap()

        XCTAssertTrue(
            app.buttons["Create an account"].waitForExistence(timeout: 10)
                || app.buttons["Sign in"].waitForExistence(timeout: 2),
            "the account screen must offer signing in"
        )
    }

    // MARK: - Helpers

    /// Walk the onboarding flow using its default answers.
    private func completeOnboarding() {
        let continueButton = app.buttons["Continue"]
        guard continueButton.waitForExistence(timeout: 10) else { return }

        // Four steps, the last of which changes label. Bounded so a layout change cannot spin here.
        for _ in 0..<6 {
            if app.buttons["Start learning"].exists {
                app.buttons["Start learning"].tap()
                return
            }
            guard continueButton.exists else { return }
            continueButton.tap()
        }
    }

    private func tapIfPresent(_ element: XCUIElement) {
        if element.waitForExistence(timeout: 5) {
            element.tap()
        }
    }
}
