import XCTest
@testable import VocabLoop

/// The arithmetic parental gate (engagement plan §1.10): `a × b` with factors in 3…9, three
/// tries, nothing persisted.
final class ParentGateTests: XCTestCase {
    private func makeGate(seed: UInt64 = 42) -> (ParentGate, SeededGenerator) {
        var generator = SeededGenerator(seed: seed)
        let gate = ParentGate(using: &generator)
        return (gate, generator)
    }

    func testFactorsStayInRange() {
        for seed in UInt64(1)...200 {
            var generator = SeededGenerator(seed: seed)
            let question = ParentGate.makeQuestion(using: &generator)
            XCTAssertTrue(ParentGate.factorRange.contains(question.a), "a = \(question.a)")
            XCTAssertTrue(ParentGate.factorRange.contains(question.b), "b = \(question.b)")
            XCTAssertEqual(question.answer, question.a * question.b)
        }
    }

    func testSameSeedSameQuestion() {
        var first = SeededGenerator(seed: 7)
        var second = SeededGenerator(seed: 7)
        XCTAssertEqual(ParentGate.makeQuestion(using: &first), ParentGate.makeQuestion(using: &second))
    }

    func testPromptReadsAsAMultiplication() {
        let question = ParentGate.Question(a: 7, b: 8)
        XCTAssertEqual(question.prompt, "7 × 8 等于多少？")
        XCTAssertEqual(question.accessibilityPrompt, "7 乘以 8 等于多少？")
        XCTAssertEqual(question.answer, 56)
    }

    func testStartsAskingWithThreeTries() {
        let (gate, _) = makeGate()
        XCTAssertEqual(gate.state, .asking)
        XCTAssertEqual(gate.attemptsLeft, 3)
        XCTAssertEqual(ParentGate.maxAttempts, 3)
    }

    func testCorrectAnswerPasses() {
        var (gate, generator) = makeGate()
        let state = gate.submit("\(gate.question.answer)", using: &generator)
        XCTAssertEqual(state, .passed)
        XCTAssertEqual(gate.state, .passed)
    }

    func testWhitespaceAroundTheAnswerIsIgnored() {
        var (gate, generator) = makeGate()
        XCTAssertEqual(gate.submit("  \(gate.question.answer) \n", using: &generator), .passed)
    }

    func testWrongAnswerCostsATryAndAsksSomethingElse() {
        var (gate, generator) = makeGate()
        let wrong = gate.question.answer + 1
        XCTAssertEqual(gate.submit("\(wrong)", using: &generator), .asking)
        XCTAssertEqual(gate.attemptsLeft, 2)
    }

    func testThreeWrongAnswersLock() {
        var (gate, generator) = makeGate()
        for _ in 0..<3 {
            gate.submit("\(gate.question.answer + 1)", using: &generator)
        }
        XCTAssertEqual(gate.state, .locked)
        XCTAssertEqual(gate.attemptsLeft, 0)
    }

    func testLockedGateIgnoresEvenTheRightAnswer() {
        var (gate, generator) = makeGate()
        for _ in 0..<3 {
            gate.submit("\(gate.question.answer + 1)", using: &generator)
        }
        XCTAssertEqual(gate.submit("\(gate.question.answer)", using: &generator), .locked)
    }

    func testTwoWrongThenRightStillPasses() {
        var (gate, generator) = makeGate()
        gate.submit("\(gate.question.answer + 1)", using: &generator)
        gate.submit("\(gate.question.answer + 1)", using: &generator)
        XCTAssertEqual(gate.attemptsLeft, 1)
        XCTAssertEqual(gate.submit("\(gate.question.answer)", using: &generator), .passed)
    }

    func testBlankEntryCostsNothing() {
        var (gate, generator) = makeGate()
        let before = gate.question
        XCTAssertEqual(gate.submit("   ", using: &generator), .asking)
        XCTAssertEqual(gate.attemptsLeft, 3)
        XCTAssertEqual(gate.question, before)
    }

    func testNonNumericEntryIsAWrongAnswer() {
        var (gate, generator) = makeGate()
        XCTAssertEqual(gate.submit("fifty", using: &generator), .asking)
        XCTAssertEqual(gate.attemptsLeft, 2)
    }

    func testParse() {
        XCTAssertEqual(ParentGate.parse("42"), 42)
        XCTAssertEqual(ParentGate.parse(" 42 "), 42)
        XCTAssertNil(ParentGate.parse("4 2"))
        XCTAssertNil(ParentGate.parse(""))
    }

    func testAFreshGateIsNotPersisted() {
        var (gate, generator) = makeGate()
        for _ in 0..<3 {
            gate.submit("\(gate.question.answer + 1)", using: &generator)
        }
        XCTAssertEqual(gate.state, .locked)
        // Leaving and reopening the screen builds a new gate.
        XCTAssertEqual(ParentGate().state, .asking)
        XCTAssertEqual(ParentGate().attemptsLeft, 3)
    }
}
