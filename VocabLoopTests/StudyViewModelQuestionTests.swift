import XCTest
import SwiftData
@testable import VocabLoop

/// Which question the session asks (engagement plan §1.5, §2.5).
///
/// The one that matters most: a fresh install opens on a flip card with "Show answer". New and
/// learning cards are never quizzed — an introduction cannot be a quiz — which is also what keeps
/// the UI tests' first taps the same with or without `-uiTestingFlipOnly`.
@MainActor
final class StudyViewModelQuestionTests: XCTestCase {
    private func makeDependencies() throws -> AppDependencies {
        let container = try PersistenceController.makeInMemoryContainer()
        let dependencies = AppDependencies(container: container)
        _ = try dependencies.context.activeAccount()
        let preferences = try XCTUnwrap(dependencies.preferences)
        preferences.dailyGoal = 0
        // Quizzes on, so a flip card here is the rule for new cards and not the setting.
        preferences.quizModesEnabled = true
        pinToUTC(preferences)
        return dependencies
    }

    func testFirstCardsOfAFreshGraphAreFlipCards() throws {
        let dependencies = try makeDependencies()
        let context = dependencies.context
        for index in 0..<8 {
            let entry = try TestStore.makeEntry(
                in: context, headword: "fresh\(index)", frequencyRank: index,
                definition: "fresh meaning \(index)"
            )
            try TestStore.makeCard(in: context, for: entry, phase: .new, due: referenceDate, intervalDays: 0)
        }

        let model = StudyViewModel()
        model.start(
            dependencies: dependencies,
            options: .init(maxNewCards: 8, languageCode: "en"),
            now: referenceDate
        )
        XCTAssertEqual(model.phase, .reviewing)

        // Every card through a few rounds of learning steps: new, then learning, never a quiz.
        for step in 0..<12 {
            let question = try XCTUnwrap(model.currentQuestion, "step \(step)")
            XCTAssertEqual(question.kind, .flip, "step \(step): new and learning cards are always flip")
            XCTAssertEqual(question.cardID, model.currentCard?.cardID, "the question is for the card on screen")
            XCTAssertFalse(model.isQuizQuestion)
            model.revealAnswer(now: referenceDate)
            XCTAssertTrue(model.isAnswerRevealed, "a flip card reveals with Show answer, as it always has")
            model.grade(step.isMultiple(of: 3) ? .again : .good, dependencies: dependencies, now: referenceDate)
            guard model.phase == .reviewing else { break }
        }
    }

    func testQuestionFollowsTheCardThroughBuryAndUndo() throws {
        let dependencies = try makeDependencies()
        let context = dependencies.context
        for index in 0..<3 {
            let entry = try TestStore.makeEntry(
                in: context, headword: "follow\(index)", frequencyRank: index,
                definition: "follow meaning \(index)"
            )
            try TestStore.makeCard(in: context, for: entry, phase: .new, due: referenceDate, intervalDays: 0)
        }
        let model = StudyViewModel()
        model.start(
            dependencies: dependencies,
            options: .init(maxNewCards: 3, languageCode: "en"),
            now: referenceDate
        )

        model.bury(dependencies: dependencies)
        XCTAssertEqual(model.currentQuestion?.cardID, model.currentCard?.cardID, "after bury")

        model.revealAnswer(now: referenceDate)
        model.grade(.good, dependencies: dependencies, now: referenceDate)
        XCTAssertEqual(model.currentQuestion?.cardID, model.currentCard?.cardID, "after a grade")

        model.undo(dependencies: dependencies)
        XCTAssertEqual(model.currentQuestion?.cardID, model.currentCard?.cardID, "after undo")
    }

    /// The session starts in `.loading` and must not offer a question for a card that is not there.
    func testNoQuestionBeforeStart() {
        let model = StudyViewModel()
        XCTAssertNil(model.currentQuestion)
        XCTAssertFalse(model.isQuizQuestion)
        XCTAssertEqual(model.combo, 0)
    }
}
