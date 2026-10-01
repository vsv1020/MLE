import XCTest
import SwiftData
@testable import VocabLoop

/// Session combos (engagement plan §1.1, §2.5): up on anything but *Forgot*, back to zero on
/// *Forgot*, restored exactly by undo, and a broken run of five or more celebrated — never mourned.
@MainActor
final class StudyViewModelComboTests: XCTestCase {
    private var dependencies: AppDependencies!
    private var model: StudyViewModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The real object graph: `start` reads `dependencies.preferences` and grades through
        // `dependencies.review`, and both must see the cards written below.
        let container = try PersistenceController.makeInMemoryContainer()
        dependencies = AppDependencies(container: container)
        let context = dependencies.context
        _ = try context.activeAccount()
        let preferences = try XCTUnwrap(dependencies.preferences)
        // No goal, so the goal screen never interrupts a run of grades.
        preferences.dailyGoal = 0
        pinToUTC(preferences)

        // New cards, so every one is a flip card and grading needs no quiz answer.
        for index in 0..<10 {
            let entry = try TestStore.makeEntry(
                in: context, headword: "combo\(index)", frequencyRank: index,
                definition: "combo meaning \(index)"
            )
            try TestStore.makeCard(in: context, for: entry, phase: .new, due: referenceDate, intervalDays: 0)
        }

        model = StudyViewModel()
        model.start(
            dependencies: dependencies,
            options: .init(maxNewCards: 10, languageCode: "en"),
            now: referenceDate
        )
        XCTAssertEqual(model.phase, .reviewing)
    }

    override func tearDown() {
        model = nil
        dependencies = nil
        super.tearDown()
    }

    private func answer(_ rating: Rating, times: Int = 1) {
        for _ in 0..<times {
            model.revealAnswer(now: referenceDate)
            model.grade(rating, dependencies: dependencies, now: referenceDate)
        }
    }

    func testComboCountsEverythingButForgot() {
        XCTAssertEqual(model.combo, 0)
        answer(.good)
        answer(.hard)
        answer(.easy)
        XCTAssertEqual(model.combo, 3, "Slow is still remembered, so it keeps the run going")
        XCTAssertEqual(model.lastComboMilestone, 3)

        answer(.again)
        XCTAssertEqual(model.combo, 0, "Forgot resets the run")
        XCTAssertNil(model.lastComboMilestone)
        XCTAssertEqual(model.bestComboThisSession, 3)
    }

    func testMilestoneIsCelebratedExactlyOnce() {
        answer(.good, times: 3)
        let milestones = model.events.filter { $0 == .comboMilestone(3) }
        XCTAssertEqual(milestones.count, 1, "one celebration for reaching three, whoever reports it")

        answer(.good)
        XCTAssertNil(model.lastComboMilestone, "four is not a milestone")
    }

    func testBreakingARunOfFiveIsCelebratedNotMourned() {
        answer(.good, times: 6)
        answer(.again)
        XCTAssertTrue(
            model.events.contains(.comboEnded(best: 6)),
            "a run of six that ends is celebrated as a run of six"
        )
        XCTAssertEqual(
            RewardToast.message(for: .comboEnded(best: 6))?.text, "Nice run: 6 in a row!",
            "the break itself is never mentioned"
        )
    }

    func testBreakingAShortRunIsNotAnnounced() {
        answer(.good, times: 4)
        answer(.again)
        XCTAssertFalse(model.events.contains { event in
            if case .comboEnded = event { return true }
            return false
        }, "below five there is no run worth a toast")
    }

    func testUndoRestoresTheComboFromBeforeTheUndoneGrade() {
        answer(.good, times: 3)
        answer(.again)
        XCTAssertEqual(model.combo, 0)

        model.undo(dependencies: dependencies)
        XCTAssertEqual(model.combo, 3, "undoing the Forgot gives the run back")
        XCTAssertTrue(model.events.isEmpty, "nothing waiting to be shown was about a live answer")

        answer(.good)
        XCTAssertEqual(model.combo, 4)
        model.undo(dependencies: dependencies)
        XCTAssertEqual(model.combo, 3, "undoing a Got it takes exactly one off")
    }

    func testFlameLightsOnTheFirstReviewOfTheDay() {
        XCTAssertFalse(model.studiedToday, "a fresh install has not studied today")
        answer(.good)
        XCTAssertTrue(model.studiedToday)
        XCTAssertEqual(model.streak.current, 1, "the first study day is a one-day streak")
    }

    func testDrainingEventsEmptiesTheQueueInOrder() {
        answer(.good, times: 3)
        var drained: [EngagementEvent] = []
        while let event = model.takeNextEvent() { drained.append(event) }
        XCTAssertFalse(drained.isEmpty)
        XCTAssertTrue(model.events.isEmpty)
        XCTAssertNil(model.takeNextEvent())
    }

    /// Candy is per answer and rating-agnostic: an honest Forgot earns what Got it earns.
    func testEveryAnswerAddsCandy() {
        let before = model.candyTotal
        answer(.again)
        XCTAssertGreaterThan(model.candyTotal, before, "Forgot still earns its candy")
    }
}
