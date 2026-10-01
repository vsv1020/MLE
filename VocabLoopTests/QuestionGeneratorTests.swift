import XCTest
import SwiftData
@testable import VocabLoop

/// The question-selection rules and distractor picking from `docs/ENGAGEMENT-PLAN.md` §1.5.
@MainActor
final class QuestionGeneratorTests: XCTestCase {
    private let quiz = QuestionPolicy(flipOnly: false, quizEnabled: true, hasSpeech: true)

    // MARK: - Fixtures

    private func makeCard(
        in context: ModelContext,
        headword: String = "alpha",
        direction: CardDirection = .recognition,
        phase: LearningPhase = .review,
        intervalDays: Double = 10
    ) throws -> Card {
        let entry = try TestStore.makeEntry(in: context, headword: headword)
        return try TestStore.makeCard(
            in: context, for: entry, direction: direction, phase: phase,
            due: referenceDate, intervalDays: intervalDays
        )
    }

    private func roll(_ card: Card) -> Int {
        Int(QuestionGenerator.seed(for: card) % 10)
    }

    /// The recognition table, written out independently of the implementation.
    private func expectedRecognitionKind(roll: Int, mature: Bool) -> QuestionKind {
        if mature {
            switch roll {
            case 0...4: return .flip
            case 5...6: return .multipleChoice
            case 7: return .listenChoose
            default: return .clozeChoose
            }
        }
        switch roll {
        case 0...3: return .flip
        case 4...6: return .multipleChoice
        case 7...8: return .listenChoose
        default: return .clozeChoose
        }
    }

    private func candidate(
        _ headword: String,
        pos: PartOfSpeech = .noun,
        cefr: CEFRLevel? = .a1,
        text: String? = nil,
        synonyms: [String] = [],
        enrolled: Bool = false
    ) -> DistractorCandidate {
        DistractorCandidate(
            stableID: "en:\(headword.lowercased()):1",
            headword: headword,
            pos: pos,
            cefr: cefr,
            optionText: text ?? "meaning of \(headword)",
            synonyms: synonyms,
            isEnrolled: enrolled
        )
    }

    // MARK: - Kind rules

    func testFlipOnlyAndDisabledQuizzesAlwaysFlip() throws {
        let context = try TestStore.makeContext()
        let card = try makeCard(in: context)
        for reps in 0..<30 {
            card.reps = reps
            XCTAssertEqual(
                QuestionGenerator.kind(for: card, policy: QuestionPolicy(flipOnly: true), distractorCount: 3, canCloze: true),
                .flip
            )
            XCTAssertEqual(
                QuestionGenerator.kind(for: card, policy: QuestionPolicy(quizEnabled: false), distractorCount: 3, canCloze: true),
                .flip
            )
        }
    }

    /// An introduction cannot be a quiz, and learning steps are minutes apart.
    func testNewLearningAndRelearningCardsAlwaysFlip() throws {
        let context = try TestStore.makeContext()
        for (index, phase) in [LearningPhase.new, .learning, .relearning].enumerated() {
            for direction in CardDirection.allCases {
                let card = try makeCard(
                    in: context, headword: "word\(index)\(direction.rawValue)",
                    direction: direction, phase: phase
                )
                for reps in 0..<30 {
                    card.reps = reps
                    XCTAssertEqual(
                        QuestionGenerator.kind(for: card, policy: quiz, distractorCount: 3, canCloze: true),
                        .flip, "\(phase) \(direction) reps \(reps)"
                    )
                }
            }
        }
    }

    func testTooFewDistractorsFallsBackToFlip() throws {
        let context = try TestStore.makeContext()
        let card = try makeCard(in: context)
        for reps in 0..<30 {
            card.reps = reps
            XCTAssertEqual(QuestionGenerator.kind(for: card, policy: quiz, distractorCount: 2, canCloze: true), .flip)
        }
    }

    func testRecognitionFollowsTheYoungAndMatureTables() throws {
        let context = try TestStore.makeContext()
        let young = try makeCard(in: context, headword: "young", intervalDays: 10)
        let mature = try makeCard(in: context, headword: "mature", intervalDays: 30)
        for reps in 0..<40 {
            young.reps = reps
            mature.reps = reps
            XCTAssertEqual(
                QuestionGenerator.kind(for: young, policy: quiz, distractorCount: 3, canCloze: true),
                expectedRecognitionKind(roll: roll(young), mature: false), "young reps \(reps)"
            )
            XCTAssertEqual(
                QuestionGenerator.kind(for: mature, policy: quiz, distractorCount: 3, canCloze: true),
                expectedRecognitionKind(roll: roll(mature), mature: true), "mature reps \(reps)"
            )
        }
    }

    func testListenAndClozeFallBackToMultipleChoice() throws {
        let context = try TestStore.makeContext()
        let card = try makeCard(in: context)
        let silent = QuestionPolicy(flipOnly: false, quizEnabled: true, hasSpeech: false)
        for reps in 0..<40 {
            card.reps = reps
            let kind = QuestionGenerator.kind(for: card, policy: silent, distractorCount: 3, canCloze: false)
            XCTAssertTrue(kind == .flip || kind == .multipleChoice, "reps \(reps) gave \(kind)")
        }
    }

    func testProductionAndClozeCardsOnlyFlipOrType() throws {
        let context = try TestStore.makeContext()
        let production = try makeCard(in: context, headword: "make", direction: .production)
        let cloze = try makeCard(in: context, headword: "lend", direction: .cloze)
        for reps in 0..<40 {
            production.reps = reps
            cloze.reps = reps
            XCTAssertEqual(
                QuestionGenerator.kind(for: production, policy: quiz, distractorCount: 3, canCloze: false),
                roll(production) <= 5 ? QuestionKind.flip : QuestionKind.typed
            )
            XCTAssertEqual(
                QuestionGenerator.kind(for: cloze, policy: quiz, distractorCount: 3, canCloze: true),
                roll(cloze) <= 4 ? QuestionKind.flip : QuestionKind.typed
            )
            XCTAssertEqual(
                QuestionGenerator.kind(for: cloze, policy: quiz, distractorCount: 3, canCloze: false),
                .flip, "a cloze card cannot be typed without its sentence"
            )
        }
    }

    func testSeedChangesWithRepsAndIsStable() throws {
        let context = try TestStore.makeContext()
        let card = try makeCard(in: context)
        card.reps = 4
        let first = QuestionGenerator.seed(for: card)
        XCTAssertEqual(QuestionGenerator.seed(for: card), first)
        card.reps = 5
        XCTAssertNotEqual(QuestionGenerator.seed(for: card), first)
    }

    // MARK: - Distractors

    func testDistractorExclusionRules() {
        let answer = candidate("happy", pos: .adjective, text: "feeling good", synonyms: ["glad", "Cheerful"])
        let pool = [
            answer,                                                             // the answer itself
            candidate("Happy", pos: .adjective, text: "another sense"),          // same headword, any case
            candidate("glad", pos: .adjective),                                  // a synonym
            candidate("cheerful", pos: .adjective),                              // a synonym, case-folded
            candidate("joyful", pos: .adjective, text: "Feeling good"),          // same option text
            candidate("table", pos: .noun),                                      // different part of speech
            candidate("sad", pos: .adjective),
            candidate("tall", pos: .adjective),
            candidate("quiet", pos: .adjective),
        ]
        let picked = QuestionGenerator.pickDistractors(answer: answer, pool: pool, seed: 42)
        XCTAssertEqual(Set(picked.map(\.headword)), ["sad", "tall", "quiet"])
    }

    func testDistractorsAreDeterministicAndIgnorePoolOrder() {
        let answer = candidate("apple")
        let pool = (0..<20).map { candidate("word\($0)", enrolled: $0 % 3 == 0) }
        let first = QuestionGenerator.pickDistractors(answer: answer, pool: pool, seed: 7)
        let again = QuestionGenerator.pickDistractors(answer: answer, pool: pool, seed: 7)
        let reversed = QuestionGenerator.pickDistractors(answer: answer, pool: Array(pool.reversed()), seed: 7)
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(first, again)
        XCTAssertEqual(first, reversed)
    }

    func testDistractorsPreferSameLevelThenEnrolled() {
        let answer = candidate("apple", cefr: .a2)
        let sameLevelEnrolled = (0..<2).map { candidate("known\($0)", cefr: .a2, enrolled: true) }
        let sameLevel = (0..<5).map { candidate("same\($0)", cefr: .a2) }
        let adjacent = (0..<5).map { candidate("near\($0)", cefr: .b1, enrolled: true) }
        let far = (0..<5).map { candidate("far\($0)", cefr: .c1, enrolled: true) }
        let pool = far + adjacent + sameLevel + sameLevelEnrolled

        for seed: UInt64 in [1, 2, 3, 99, 12_345] {
            let picked = QuestionGenerator.pickDistractors(answer: answer, pool: pool, seed: seed)
            XCTAssertEqual(picked.count, 3)
            XCTAssertTrue(picked.allSatisfy { $0.cefr == .a2 }, "seed \(seed): same level first")
            XCTAssertEqual(picked.filter(\.isEnrolled).count, 2, "seed \(seed): both enrolled words first")
        }

        // Without enough at the same level, adjacent levels fill before distant ones.
        let thin = far + adjacent + [candidate("only", cefr: .a2)]
        let picked = QuestionGenerator.pickDistractors(answer: answer, pool: thin, seed: 5)
        XCTAssertEqual(picked.count, 3)
        XCTAssertEqual(picked.filter { $0.cefr == .a2 }.count, 1)
        XCTAssertEqual(picked.filter { $0.cefr == .b1 }.count, 2)
    }

    func testDistractorsNeverRepeatAnOptionText() {
        let answer = candidate("apple")
        let pool = [
            candidate("pear", text: "a fruit"),
            candidate("plum", text: "A fruit"),
            candidate("fig", text: "a fruit "),
            candidate("kiwi", text: "a green fruit"),
        ]
        let picked = QuestionGenerator.pickDistractors(answer: answer, pool: pool, seed: 3)
        XCTAssertEqual(picked.count, 2, "three of the four read the same, so only one of them may appear")
    }

    // MARK: - Building questions

    func testMakeBuildsFourOptionsWithTheAnswerAtTheSeededPosition() throws {
        let context = try TestStore.makeContext()
        let card = try makeCard(in: context, headword: "apple", intervalDays: 10)
        for index in 0..<6 {
            try TestStore.makeEntry(in: context, headword: "fruit\(index)", definition: "definition \(index)")
        }
        let generator = QuestionGenerator(context: context)
        try generator.prepare(languageCode: "en", nativeCodes: ["en"])
        let noVoice = QuestionPolicy(flipOnly: false, quizEnabled: true, hasSpeech: false)

        var sawChoice = false
        for reps in 0..<40 {
            card.reps = reps
            let question = generator.make(for: card, policy: noVoice)
            XCTAssertEqual(question, generator.make(for: card, policy: noVoice), "deterministic")
            switch question.kind {
            case .flip:
                XCTAssertTrue(question.options.isEmpty)
            case .multipleChoice:
                sawChoice = true
                XCTAssertEqual(question.options.count, 4)
                XCTAssertEqual(Set(question.options.map(\.id)).count, 4)
                XCTAssertEqual(question.correctIndex, Int(question.seed % 4))
                XCTAssertEqual(question.options[question.correctIndex].id, card.entry?.stableID)
                XCTAssertEqual(question.answerText, "a test definition")
            case .listenChoose, .clozeChoose, .typed:
                XCTFail("reps \(reps): no voice, no example sentence and a recognition card allow only flip or choice")
            }
        }
        XCTAssertTrue(sawChoice, "forty repetitions should include a multiple-choice question")
    }

    func testMakeFlipsANewCardAndAnUnpreparedGenerator() throws {
        let context = try TestStore.makeContext()
        let newCard = try makeCard(in: context, headword: "fresh", phase: .new, intervalDays: 0)
        for index in 0..<6 {
            try TestStore.makeEntry(in: context, headword: "other\(index)", definition: "definition \(index)")
        }
        let generator = QuestionGenerator(context: context)
        XCTAssertEqual(generator.make(for: newCard, policy: quiz).kind, .flip)

        let reviewCard = try makeCard(in: context, headword: "known")
        for reps in 0..<20 {
            reviewCard.reps = reps
            XCTAssertEqual(generator.make(for: reviewCard, policy: quiz).kind, .flip, "no pool, no distractors")
        }
    }

    func testOptionTextPrefersChineseAndTruncatesDefinitions() throws {
        let context = try TestStore.makeContext()
        let sense = Sense(
            order: 0, partOfSpeech: .noun,
            definition: String(repeating: "long ", count: 30),
            translations: ["zh": "苹果"]
        )
        context.insert(sense)
        XCTAssertEqual(QuestionGenerator.optionText(for: sense, nativeCodes: ["zh", "en"]), "苹果")
        let english = QuestionGenerator.optionText(for: sense, nativeCodes: ["en"])
        XCTAssertLessThanOrEqual(english.count, 60)
        XCTAssertTrue(english.hasSuffix("…"))
    }
}
