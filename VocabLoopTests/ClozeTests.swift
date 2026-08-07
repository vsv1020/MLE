import XCTest
import SwiftData
@testable import VocabLoop

/// Cloze masking is where the language-agnostic design gets tested for real: a token scan
/// works for English and French and fails completely for Thai, which has no spaces between
/// words. That is why `LearningLanguage.isWordSeparated` exists, and this suite is what
/// proves it is wired to something.
final class ClozeMaskerTests: XCTestCase {

    // MARK: - Word-separated languages

    func testExactMatchIsMaskedAndTheBlankDoesNotLeakLength() throws {
        let prompt = try XCTUnwrap(ClozeMasker.makePrompt(
            headword: "borrow", sentence: "Can I borrow your pen?", language: .english
        ))
        XCTAssertEqual(prompt.answer, "borrow")
        XCTAssertEqual(prompt.masked, "Can I \(ClozePrompt.blank) your pen?")
        XCTAssertEqual(prompt.revealed, "Can I borrow your pen?")

        // A blank scaled to the answer would turn recall into a crossword clue, so a short
        // word and a long one must leave an identical gap.
        let longWord = try XCTUnwrap(ClozeMasker.makePrompt(
            headword: "ubiquitous", sentence: "Phones are ubiquitous.", language: .english
        ))
        XCTAssertEqual(
            prompt.masked.filter { $0 == "_" }.count,
            longWord.masked.filter { $0 == "_" }.count,
            "the blank must not reveal how long the answer is"
        )
    }

    /// The card asks for the form that belongs in the sentence, so the answer is the surface
    /// form found there — not the dictionary headword.
    func testRegularInflectionsAreFoundAndTheSurfaceFormIsTheAnswer() throws {
        let cases: [(String, String, String)] = [
            ("learn", "I learned to swim when I was six.", "learned"),
            ("learn", "She is learning Thai.", "learning"),
            ("easy", "The test was easier than I expected.", "easier"),
            ("apologise", "He apologised for being late.", "apologised"),
            ("arrive", "We arrived at the airport an hour early.", "arrived"),
            ("study", "She studies every evening.", "studies"),
        ]
        for (headword, sentence, expected) in cases {
            let prompt = try XCTUnwrap(
                ClozeMasker.makePrompt(headword: headword, sentence: sentence, language: .english),
                "no match for \(headword) in \"\(sentence)\""
            )
            XCTAssertEqual(prompt.answer, expected, "wrong span for \(headword)")
            XCTAssertEqual(prompt.revealed, sentence, "reveal must reconstruct the sentence")
        }
    }

    /// Token scanning, not substring searching — otherwise `art` would blank part of `start`.
    func testDoesNotMatchInsideALongerWord() {
        XCTAssertNil(ClozeMasker.makePrompt(
            headword: "art", sentence: "We start at noon.", language: .english
        ))
        XCTAssertNil(ClozeMasker.makePrompt(
            headword: "one", sentence: "She telephoned him.", language: .english
        ))
    }

    /// English suffix heuristics are wrong for French — `apprendre` does not become
    /// `apprendres` — so other word-separated languages match exactly and rely on an
    /// authored blank.
    func testNonEnglishLanguagesDoNotGuessInflections() {
        XCTAssertEqual(LearningLanguage.english.inflectionStrategy, .englishSuffixes)
        XCTAssertEqual(LearningLanguage.french.inflectionStrategy, .exactOnly)

        XCTAssertNil(
            ClozeMasker.makePrompt(
                headword: "apprendre",
                sentence: "J'apprends le français depuis un an.",
                language: .french
            ),
            "French conjugation must not be guessed at"
        )
        // The exact form still works.
        XCTAssertNotNil(ClozeMasker.makePrompt(
            headword: "maison", sentence: "Nous rentrons à la maison.", language: .french
        ))
    }

    // MARK: - Languages without word separation

    /// Thai writes `หนังสือสองเล่ม` with no spaces, so there are no tokens to scan. This is
    /// the case the whole `isWordSeparated` flag exists for.
    func testThaiFallsBackToSubstringMatching() throws {
        XCTAssertFalse(LearningLanguage.thai.isWordSeparated)

        let cases: [(String, String)] = [
            ("หนังสือ", "หนังสือสองเล่ม"),
            ("น้ำ", "ขอน้ำหนึ่งแก้ว"),
            ("อาหาร", "อาหารไทยอร่อยมาก"),
            ("จำ", "ผมจำคำนี้ไม่ได้"),
        ]
        for (headword, sentence) in cases {
            let prompt = try XCTUnwrap(
                ClozeMasker.makePrompt(headword: headword, sentence: sentence, language: .thai),
                "no match for \(headword)"
            )
            XCTAssertEqual(prompt.answer, headword)
            XCTAssertEqual(prompt.revealed, sentence)
            XCTAssertTrue(prompt.masked.contains(ClozePrompt.blank))
        }
    }

    // MARK: - Authored blanks

    func testAuthoredBlankWinsOverTheHeuristics() throws {
        // The heuristics cannot get from `lend` to `lent`; the pack says where the blank goes.
        let prompt = try XCTUnwrap(ClozeMasker.makePrompt(
            headword: "lend",
            sentence: "She lent me her bicycle.",
            language: .english,
            authored: "She {{lent}} me her bicycle."
        ))
        XCTAssertEqual(prompt.answer, "lent")
        XCTAssertEqual(prompt.revealed, "She lent me her bicycle.")
    }

    /// French elision: `de + eau → d'eau`, so the token is `d'eau` and not `eau`.
    func testAuthoredBlankHandlesElision() throws {
        let prompt = try XCTUnwrap(ClozeMasker.makePrompt(
            headword: "eau",
            sentence: "Un verre d'eau, s'il vous plaît.",
            language: .french,
            authored: "Un verre d'{{eau}}, s'il vous plaît."
        ))
        XCTAssertEqual(prompt.answer, "eau")
        XCTAssertEqual(prompt.before, "Un verre d'")
    }

    func testMalformedMarkupFallsBackRatherThanCrashing() {
        // Unclosed, empty, and reversed markers must all be ignored, and the heuristic used.
        for broken in ["Can I {{borrow your pen?", "Can I {{}} your pen?", "Can I }}borrow{{ pen?"] {
            let prompt = ClozeMasker.makePrompt(
                headword: "borrow", sentence: "Can I borrow your pen?",
                language: .english, authored: broken
            )
            XCTAssertEqual(prompt?.answer, "borrow", "should have fallen back for: \(broken)")
        }
    }

    func testStripMarkupRestoresThePlainSentence() {
        XCTAssertEqual(
            ClozeMasker.stripMarkup("She {{lent}} me her bicycle."),
            "She lent me her bicycle."
        )
        XCTAssertTrue(ClozeMasker.hasAuthoredBlank("a {{b}} c"))
        XCTAssertFalse(ClozeMasker.hasAuthoredBlank("a b c"))
        XCTAssertFalse(ClozeMasker.hasAuthoredBlank(nil))
    }

    // MARK: - Degenerate input

    func testEmptyAndUnmatchableInputReturnsNil() {
        XCTAssertNil(ClozeMasker.makePrompt(headword: "", sentence: "A sentence.", language: .english))
        XCTAssertNil(ClozeMasker.makePrompt(headword: "word", sentence: "", language: .english))
        XCTAssertNil(ClozeMasker.makePrompt(
            headword: "elephant", sentence: "Can I borrow your pen?", language: .english
        ))
    }

    /// VoiceOver reads a run of underscores character by character, which is useless.
    func testAccessibleMaskedSaysBlankRatherThanUnderscores() throws {
        let prompt = try XCTUnwrap(ClozeMasker.makePrompt(
            headword: "borrow", sentence: "Can I borrow your pen?", language: .english
        ))
        XCTAssertFalse(prompt.accessibleMasked.contains("_"))
        XCTAssertTrue(prompt.accessibleMasked.contains("blank"))
    }
}

/// Cloze against the real bundled content and the real enrolment path.
@MainActor
final class ClozeContentTests: XCTestCase {
    private var bundle: Bundle { Bundle(for: Entry.self) }

    /// Every bundled entry must be able to produce a cloze card. The five that the heuristics
    /// cannot reach carry an authored blank; if content is added without one, this fails and
    /// says which word needs it.
    func testEveryBundledEntryCanProduceAClozePrompt() throws {
        var unmaskable: [String] = []

        for language in LearningLanguage.allCases {
            for packName in language.seedPackNames {
                let pack = try SeedImporter.loadPack(named: packName, bundle: bundle)
                for seedEntry in pack.entries {
                    let examples = seedEntry.senses.flatMap { $0.examples ?? [] }
                    let matched = examples.contains { example in
                        ClozeMasker.makePrompt(
                            headword: seedEntry.headword,
                            sentence: example.text,
                            language: language,
                            authored: example.cloze
                        ) != nil
                    }
                    if !matched {
                        unmaskable.append("\(packName)/\(seedEntry.headword)")
                    }
                }
            }
        }

        XCTAssertTrue(
            unmaskable.isEmpty,
            "these entries cannot produce a cloze card and need a \"cloze\" marker on one "
            + "of their examples: \(unmaskable.joined(separator: ", "))"
        )
    }

    /// An authored marker must be the same sentence as `text`, or the reveal would show
    /// something the learner never read.
    func testAuthoredMarkersMatchTheirSentence() throws {
        for language in LearningLanguage.allCases {
            for packName in language.seedPackNames {
                let pack = try SeedImporter.loadPack(named: packName, bundle: bundle)
                for entry in pack.entries {
                    for example in entry.senses.flatMap({ $0.examples ?? [] }) {
                        guard let cloze = example.cloze else { continue }
                        XCTAssertEqual(
                            ClozeMasker.stripMarkup(cloze), example.text,
                            "\(packName)/\(entry.headword): the marked sentence differs from text"
                        )
                    }
                }
            }
        }
    }

    /// The correctness rule: a cloze card is only created when a blank can actually be placed.
    /// A cloze card with the blank in the wrong place teaches the wrong thing.
    func testEnrolmentSkipsClozeWhenNoSentenceCanBeMasked() throws {
        let context = try TestStore.makeContext()
        let account = try context.activeAccount()
        let preferences = try XCTUnwrap(account.preferences)
        preferences.enabledDirections = [.recognition, .cloze]
        let service = ReviewService(context: context)

        // No examples at all — TestStore.makeEntry creates a bare sense.
        let bare = try TestStore.makeEntry(in: context, headword: "unexampled")
        XCTAssertFalse(bare.supportsCloze)
        let bareCards = try service.enroll(entry: bare, preferences: preferences)
        XCTAssertEqual(bareCards.map(\.direction), [.recognition])

        // An example containing the headword — cloze is created.
        let usable = try TestStore.makeEntry(in: context, headword: "borrow")
        let sense = try XCTUnwrap(usable.primarySense)
        sense.examples = [ExampleSentence(text: "Can I borrow your pen?")]
        try context.save()

        XCTAssertTrue(usable.supportsCloze)
        let usableCards = try service.enroll(entry: usable, preferences: preferences)
        XCTAssertEqual(Set(usableCards.map(\.direction)), [.recognition, .cloze])
    }

    /// An authored blank must win even when a heuristic match exists on an earlier example,
    /// and the chosen prompt must be stable rather than depending on fetch order.
    func testEntryPrefersAuthoredBlankAndIsDeterministic() throws {
        let context = try TestStore.makeContext()
        let entry = try TestStore.makeEntry(in: context, headword: "lend")
        let sense = try XCTUnwrap(entry.primarySense)
        sense.examples = [
            ExampleSentence(text: "I will lend it to you."),
            ExampleSentence(text: "She lent me her bicycle.", cloze: "She {{lent}} me her bicycle."),
        ]
        try context.save()

        let first = try XCTUnwrap(entry.clozePrompt())
        XCTAssertEqual(first.answer, "lent", "the authored blank must take precedence")
        for _ in 0..<5 {
            XCTAssertEqual(entry.clozePrompt(), first, "the prompt must not vary between reads")
        }
    }

    func testClozeIsNotInTheDefaultDirections() throws {
        let context = try TestStore.makeContext()
        let account = try context.activeAccount()
        let preferences = try XCTUnwrap(account.preferences)
        // Cloze roughly doubles review load, so it is opt-in rather than on by default.
        XCTAssertEqual(preferences.enabledDirections, [.recognition])
        XCTAssertTrue(CardDirection.cloze.requiresExampleSentence)
        XCTAssertFalse(CardDirection.recognition.requiresExampleSentence)
    }
}
