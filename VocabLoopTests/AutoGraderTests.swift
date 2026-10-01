import XCTest
@testable import VocabLoop

/// The auto-grade table from `docs/ENGAGEMENT-PLAN.md` §1.5. A release gate: these grades go
/// straight into FSRS, and the one thing a quiz must never do is claim more than it measured.
final class AutoGraderTests: XCTestCase {
    private let choiceKinds: [QuestionKind] = [.multipleChoice, .listenChoose, .clozeChoose]

    // MARK: - Table

    func testChoiceQuestionsFollowTheTable() {
        for kind in choiceKinds {
            XCTAssertEqual(AutoGrader.rating(kind: kind, quality: .exact, responseMS: 1_200), .good, "\(kind) fast")
            XCTAssertEqual(AutoGrader.rating(kind: kind, quality: .exact, responseMS: 6_000), .good, "\(kind) at the threshold")
            XCTAssertEqual(AutoGrader.rating(kind: kind, quality: .exact, responseMS: 6_001), .hard, "\(kind) slow")
            XCTAssertEqual(AutoGrader.rating(kind: kind, quality: .wrong, responseMS: 900), .again, "\(kind) wrong")
            XCTAssertEqual(AutoGrader.rating(kind: kind, quality: .nearMiss, responseMS: 900), .again, "\(kind) has no near miss")
        }
    }

    func testTypedQuestionsFollowTheTable() {
        XCTAssertEqual(AutoGrader.rating(kind: .typed, quality: .exact, responseMS: 4_000), .good)
        XCTAssertEqual(AutoGrader.rating(kind: .typed, quality: .exact, responseMS: 12_000), .good)
        XCTAssertEqual(AutoGrader.rating(kind: .typed, quality: .exact, responseMS: 12_001), .hard)
        XCTAssertEqual(AutoGrader.rating(kind: .typed, quality: .nearMiss, responseMS: 2_000), .hard)
        XCTAssertEqual(AutoGrader.rating(kind: .typed, quality: .wrong, responseMS: 2_000), .again)
    }

    func testThresholdsMatchThePlan() {
        XCTAssertEqual(AutoGrader.choiceFastMS, 6_000)
        XCTAssertEqual(AutoGrader.typedFastMS, 12_000)
    }

    /// `easy` from a four-option pick would inflate stability from a 25 % guess floor.
    func testAutoGradingNeverReturnsEasy() {
        for kind in QuestionKind.allCases {
            for quality in [MatchQuality.exact, .nearMiss, .wrong] {
                for responseMS in [0, 1, 500, 5_999, 6_000, 6_001, 11_999, 12_000, 12_001, 60_000, Int.max] {
                    XCTAssertNotEqual(
                        AutoGrader.rating(kind: kind, quality: quality, responseMS: responseMS), .easy,
                        "\(kind) \(quality) \(responseMS)ms"
                    )
                }
            }
        }
    }

    func testOnlyFlipIsSelfGraded() {
        XCTAssertFalse(QuestionKind.flip.isAutoGraded)
        for kind in QuestionKind.allCases where kind != .flip {
            XCTAssertTrue(kind.isAutoGraded, "\(kind)")
        }
    }

    // MARK: - Typed matching

    func testExactMatchIgnoresCaseWhitespaceAndDiacritics() {
        XCTAssertEqual(TypedAnswerMatcher.match(typed: "apple", answer: "apple"), .exact)
        XCTAssertEqual(TypedAnswerMatcher.match(typed: "  Apple ", answer: "apple"), .exact)
        XCTAssertEqual(TypedAnswerMatcher.match(typed: "cafe", answer: "café"), .exact)
        XCTAssertEqual(TypedAnswerMatcher.match(typed: "Give   up", answer: "give up"), .exact)
    }

    func testOneEditOnALongWordIsANearMiss() {
        XCTAssertEqual(TypedAnswerMatcher.match(typed: "beautifull", answer: "beautiful"), .nearMiss)
        XCTAssertEqual(TypedAnswerMatcher.match(typed: "hapy", answer: "happy"), .nearMiss)
        XCTAssertEqual(TypedAnswerMatcher.match(typed: "tabel", answer: "table"), .wrong, "a swap is two edits")
    }

    func testShortWordsGetNoTypoAllowance() {
        XCTAssertEqual(TypedAnswerMatcher.match(typed: "car", answer: "cat"), .wrong)
        XCTAssertEqual(TypedAnswerMatcher.match(typed: "hous", answer: "house"), .nearMiss, "five letters is long enough")
        XCTAssertEqual(TypedAnswerMatcher.match(typed: "bok", answer: "book"), .wrong)
    }

    func testEmptyOrUnrelatedAnswersAreWrong() {
        XCTAssertEqual(TypedAnswerMatcher.match(typed: "", answer: "apple"), .wrong)
        XCTAssertEqual(TypedAnswerMatcher.match(typed: "   ", answer: "apple"), .wrong)
        XCTAssertEqual(TypedAnswerMatcher.match(typed: "banana", answer: "apple"), .wrong)
    }

    func testEditDistance() {
        XCTAssertEqual(TypedAnswerMatcher.editDistance("", ""), 0)
        XCTAssertEqual(TypedAnswerMatcher.editDistance("", "abc"), 3)
        XCTAssertEqual(TypedAnswerMatcher.editDistance("abc", ""), 3)
        XCTAssertEqual(TypedAnswerMatcher.editDistance("abc", "abc"), 0)
        XCTAssertEqual(TypedAnswerMatcher.editDistance("kitten", "sitting"), 3)
        XCTAssertEqual(TypedAnswerMatcher.editDistance("flaw", "lawn"), 2)
        XCTAssertEqual(TypedAnswerMatcher.editDistance("happy", "hapy"), 1)
        XCTAssertEqual(TypedAnswerMatcher.editDistance("happy", "happyy"), 1)
        XCTAssertEqual(TypedAnswerMatcher.editDistance("happy", "hippy"), 1)
        XCTAssertEqual(TypedAnswerMatcher.editDistance("naïve", "naive"), 1, "counted in characters, not bytes")
    }
}
