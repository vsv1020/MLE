import XCTest
import SwiftData
@testable import VocabLoop

/// Auto-graded questions through the view model (engagement plan §1.5, §2.5): a tap becomes a
/// rating via ``AutoGrader``, nothing is sent until Continue, the logged duration runs from the
/// question appearing to the tap, and a wrong pick is an ordinary lapse that comes back this
/// session.
@MainActor
final class StudyViewModelAutoGradeTests: XCTestCase {
    private var dependencies: AppDependencies!
    private var card: Card!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let container = try PersistenceController.makeInMemoryContainer()
        dependencies = AppDependencies(container: container)
        let context = dependencies.context
        _ = try context.activeAccount()
        let preferences = try XCTUnwrap(dependencies.preferences)
        preferences.dailyGoal = 0
        preferences.quizModesEnabled = true
        pinToUTC(preferences)

        // Distractors: same part of speech and level as the answer, each with its own meaning —
        // two options reading the same are excluded, so identical definitions would leave none.
        for index in 0..<6 {
            try TestStore.makeEntry(
                in: context, headword: "distractor\(index)", frequencyRank: 100 + index,
                definition: "distractor meaning \(index)"
            )
        }

        let entry = try TestStore.makeEntry(
            in: context, headword: "target", frequencyRank: 1, definition: "the target meaning"
        )
        // A young review card, due now: the only kind that may be quizzed.
        card = try TestStore.makeCard(
            in: context, for: entry, phase: .review,
            due: referenceDate.addingTimeInterval(-3_600), intervalDays: 10
        )
        // Pick the repetition count whose roll is 4…6 on the young recognition table, which is
        // `multipleChoice` whatever this machine's voices are and with no example sentence —
        // so the test does not depend on the simulator having an English voice installed.
        let reps = try XCTUnwrap((0..<200).first { reps in
            card.reps = reps
            return (4...6).contains(Int(QuestionGenerator.seed(for: card) % 10))
        })
        card.reps = reps
        try context.save()
    }

    override func tearDown() {
        card = nil
        dependencies = nil
        super.tearDown()
    }

    /// Started with no new cards, so the one due card is the whole queue.
    private func startSession() throws -> StudyViewModel {
        let model = StudyViewModel()
        model.start(
            dependencies: dependencies,
            options: .init(maxNewCards: 0, languageCode: "en"),
            now: referenceDate
        )
        XCTAssertEqual(model.phase, .reviewing)
        XCTAssertEqual(model.currentCard?.cardID, card.cardID)
        let question = try XCTUnwrap(model.currentQuestion)
        XCTAssertEqual(question.kind, .multipleChoice)
        XCTAssertEqual(question.options.count, 4, "a choice question always offers exactly four")
        XCTAssertEqual(Set(question.options.map(\.text)).count, 4, "four different-looking options")
        XCTAssertEqual(question.options[question.correctIndex].text, "the target meaning")
        XCTAssertEqual(model.questionShownAt, referenceDate)
        return model
    }

    private func lastLog() throws -> ReviewLog {
        try XCTUnwrap(card.reviews.max(by: { $0.reviewedAt < $1.reviewedAt }))
    }

    func testFastCorrectPickIsGoodAndTimedFromTheQuestion() throws {
        let model = try startSession()
        let question = try XCTUnwrap(model.currentQuestion)

        model.answer(optionIndex: question.correctIndex, now: referenceDate.addingTimeInterval(2))
        XCTAssertTrue(model.isQuestionAnswered)
        XCTAssertTrue(model.isAnswerRevealed, "the answer side shows under the options")
        XCTAssertEqual(model.pendingAutoRating, .good)
        XCTAssertEqual(model.reviewedCount, 0, "nothing is graded until Continue")
        XCTAssertTrue(card.reviews.isEmpty)

        // Reading the feedback for ten seconds is not recall time.
        model.continueAfterAnswer(dependencies: dependencies, now: referenceDate.addingTimeInterval(12))
        XCTAssertEqual(model.reviewedCount, 1)
        let log = try lastLog()
        XCTAssertEqual(log.rating, .good)
        XCTAssertEqual(log.durationMS, 2_000, "measured from the question appearing to the tap")
        XCTAssertEqual(model.combo, 1, "an auto-graded answer counts toward the combo")
    }

    /// Time away — Mochi's sheet, another app — is not recall time: the clock restarts on return,
    /// so a quick answer afterwards is still `good` and is timed from the return.
    func testRestartingTheClockDiscountsTimeAway() throws {
        let model = try startSession()
        let question = try XCTUnwrap(model.currentQuestion)

        let back = referenceDate.addingTimeInterval(300)
        model.restartQuestionClock(now: back)
        XCTAssertEqual(model.questionShownAt, back)

        model.answer(optionIndex: question.correctIndex, now: back.addingTimeInterval(2))
        XCTAssertEqual(model.pendingAutoRating, .good, "five minutes away does not make it slow")

        // Once answered, the time is captured; returning again changes nothing.
        model.restartQuestionClock(now: back.addingTimeInterval(60))
        XCTAssertEqual(model.questionShownAt, back)

        model.continueAfterAnswer(dependencies: dependencies, now: back.addingTimeInterval(70))
        XCTAssertEqual(try lastLog().durationMS, 2_000, "measured from the return, not the first showing")
    }

    func testSlowCorrectPickIsHard() throws {
        let model = try startSession()
        let question = try XCTUnwrap(model.currentQuestion)
        model.answer(optionIndex: question.correctIndex, now: referenceDate.addingTimeInterval(8))
        XCTAssertEqual(model.pendingAutoRating, .hard)
        model.continueAfterAnswer(dependencies: dependencies, now: referenceDate.addingTimeInterval(9))
        XCTAssertEqual(try lastLog().rating, .hard)
        XCTAssertEqual(try lastLog().durationMS, 8_000)
    }

    func testWrongPickIsALapseThatComesBackThisSession() throws {
        let model = try startSession()
        let question = try XCTUnwrap(model.currentQuestion)
        let wrong = (question.correctIndex + 1) % question.options.count

        model.answer(optionIndex: wrong, now: referenceDate.addingTimeInterval(1))
        XCTAssertEqual(model.selectedOption, wrong)
        XCTAssertEqual(model.pendingAutoRating, .again)

        // A second tap cannot change the answer.
        model.answer(optionIndex: question.correctIndex, now: referenceDate.addingTimeInterval(2))
        XCTAssertEqual(model.selectedOption, wrong)
        XCTAssertEqual(model.pendingAutoRating, .again)

        model.continueAfterAnswer(dependencies: dependencies, now: referenceDate.addingTimeInterval(3))
        XCTAssertEqual(try lastLog().rating, .again)
        XCTAssertTrue(
            model.queue.contains { $0.cardID == card.cardID },
            "a lapse goes through relearning and returns this session, like any Forgot"
        )
        XCTAssertEqual(model.currentCard?.cardID, card.cardID, "it is the only card, so it is next")
        XCTAssertEqual(
            model.currentQuestion?.kind, .flip,
            "a relearning card is never quizzed"
        )
        XCTAssertFalse(model.isQuestionAnswered, "the next question starts unanswered")
        XCTAssertNil(model.selectedOption)
    }

    func testAutoGradeIsNeverEasy() throws {
        let model = try startSession()
        let question = try XCTUnwrap(model.currentQuestion)
        model.answer(optionIndex: question.correctIndex, now: referenceDate)
        XCTAssertEqual(model.pendingAutoRating, .good, "an instant correct pick is still only Good")
    }

    func testAQuizCannotBeRevealedBeforeItIsAnswered() throws {
        let model = try startSession()
        model.revealAnswer(now: referenceDate)
        XCTAssertFalse(model.isAnswerRevealed, "revealing first would hand over the answer")
    }

    func testIDontKnowIsAnHonestLapse() throws {
        let model = try startSession()
        model.giveUpOnQuestion(now: referenceDate.addingTimeInterval(4))
        XCTAssertTrue(model.isQuestionAnswered)
        XCTAssertNil(model.selectedOption)
        XCTAssertEqual(model.pendingAutoRating, .again)
    }

    func testUndoBringsBackTheSameQuestionUnanswered() throws {
        let model = try startSession()
        let question = try XCTUnwrap(model.currentQuestion)
        model.answer(optionIndex: question.correctIndex, now: referenceDate.addingTimeInterval(1))
        model.continueAfterAnswer(dependencies: dependencies, now: referenceDate.addingTimeInterval(2))

        model.undo(dependencies: dependencies)
        XCTAssertEqual(model.currentCard?.cardID, card.cardID)
        XCTAssertEqual(model.currentQuestion, question, "same card, same repetition, same question")
        XCTAssertFalse(model.isQuestionAnswered)
        XCTAssertNil(model.pendingAutoRating)
    }

    func testQuizSettingOffKeepsTheCardAFlipCard() throws {
        try XCTUnwrap(dependencies.preferences).quizModesEnabled = false
        let model = StudyViewModel()
        model.start(
            dependencies: dependencies,
            options: .init(maxNewCards: 0, languageCode: "en"),
            now: referenceDate
        )
        XCTAssertEqual(model.currentQuestion?.kind, .flip)
        XCTAssertFalse(model.isQuizQuestion)
    }
}
