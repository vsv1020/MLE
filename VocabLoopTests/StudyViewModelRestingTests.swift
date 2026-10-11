import XCTest
import SwiftData
@testable import VocabLoop

/// Reopening the app after today's goal: the root session rests on the goal screen unless the
/// learner chose "keep going" today. Reported as "after finishing, quit and come back — it
/// carried on".
@MainActor
final class StudyViewModelRestingTests: XCTestCase {
    private var dependencies: AppDependencies!
    private var defaults: UserDefaults!
    private let suiteName = "StudyViewModelRestingTests"

    override func setUpWithError() throws {
        try super.setUpWithError()
        let container = try PersistenceController.makeInMemoryContainer()
        dependencies = AppDependencies(container: container)
        let context = dependencies.context
        _ = try context.activeAccount()
        let preferences = try XCTUnwrap(dependencies.preferences)
        preferences.dailyGoal = 2
        pinToUTC(preferences)

        for index in 0..<10 {
            let entry = try TestStore.makeEntry(
                in: context, headword: "rest\(index)", frequencyRank: index,
                definition: "rest meaning \(index)"
            )
            try TestStore.makeCard(in: context, for: entry, phase: .new, due: referenceDate, intervalDays: 0)
        }

        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        dependencies = nil
        super.tearDown()
    }

    /// A fresh screen, as after quitting and reopening the app.
    private func openSession() -> StudyViewModel {
        let model = StudyViewModel()
        model.start(
            dependencies: dependencies,
            options: .init(maxNewCards: 10, languageCode: "en"),
            now: referenceDate
        )
        return model
    }

    private func meetTheGoal() {
        let model = openSession()
        for _ in 0..<2 {
            model.revealAnswer(now: referenceDate)
            model.grade(.good, dependencies: dependencies, now: referenceDate)
        }
        XCTAssertEqual(model.phase, .goalReached)
    }

    func testBelowTheGoalTheSessionCarriesOn() {
        let model = openSession()
        XCTAssertFalse(model.restIfGoalAlreadyMet(defaults: defaults))
        XCTAssertEqual(model.phase, .reviewing)
    }

    func testReopeningAfterTheGoalRestsOnTheGoalScreen() {
        meetTheGoal()

        let reopened = openSession()
        XCTAssertTrue(reopened.restIfGoalAlreadyMet(defaults: defaults))
        XCTAssertEqual(reopened.phase, .goalReached)
    }

    func testKeepGoingIsRememberedForTheDay() {
        meetTheGoal()

        let reopened = openSession()
        XCTAssertTrue(reopened.restIfGoalAlreadyMet(defaults: defaults))
        reopened.continueAfterGoal(now: referenceDate, defaults: defaults)
        XCTAssertNotEqual(reopened.phase, .goalReached)

        let again = openSession()
        XCTAssertFalse(again.restIfGoalAlreadyMet(defaults: defaults))
        XCTAssertNotEqual(again.phase, .goalReached)
    }
}
