import XCTest
import SwiftData
@testable import VocabLoop

/// The training set is the payoff for keeping `ReviewLog` append-only, so its shape is pinned
/// here rather than discovered when an optimiser is first pointed at it.
@MainActor
final class OptimizerTests: XCTestCase {

    private func makeFixture() throws -> (ModelContext, OptimizerService, StudyPreferences, ReviewService) {
        let context = try TestStore.makeContext()
        let account = try context.activeAccount()
        let preferences = try XCTUnwrap(account.preferences)
        return (context, OptimizerService(context: context), preferences, ReviewService(context: context))
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "optimizer.reviewCountAtLastFit")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "optimizer.reviewCountAtLastFit")
        super.tearDown()
    }

    // MARK: - Training set shape

    /// `deltaT` is the gap since the previous review *of the same card*, and `-1` marks a
    /// card's first review. Getting this wrong would silently teach the optimiser the wrong
    /// forgetting curve, with no visible symptom.
    func testDeltaTIsMeasuredPerCardAndFirstReviewIsMinusOne() throws {
        let (context, service, preferences, review) = try makeFixture()

        let first = try TestStore.makeEntry(in: context, headword: "alpha")
        let second = try TestStore.makeEntry(in: context, headword: "beta")
        let cardA = try XCTUnwrap(try review.enroll(entry: first, preferences: preferences).first)
        let cardB = try XCTUnwrap(try review.enroll(entry: second, preferences: preferences).first)

        // Interleaved on purpose: A, B, A. A naive "gap since the previous row" would give the
        // third row the gap to B's review instead of to A's.
        try review.grade(card: cardA, rating: .good, preferences: preferences, now: referenceDate)
        try review.grade(card: cardB, rating: .good, preferences: preferences,
                         now: referenceDate.addingTimeInterval(2 * 86_400))
        try review.grade(card: cardA, rating: .good, preferences: preferences,
                         now: referenceDate.addingTimeInterval(5 * 86_400))

        let set = try service.trainingSet(preferences: preferences)
        XCTAssertEqual(set.reviewCount, 3)
        XCTAssertEqual(set.cardCount, 2)

        let rowsForA = set.rows.filter { $0.cardID == cardA.cardID }
        XCTAssertEqual(rowsForA.count, 2)
        XCTAssertEqual(rowsForA[0].deltaT, -1, "a card's first review has no previous review")
        XCTAssertEqual(rowsForA[1].deltaT, 5, accuracy: 0.001, "5 days since A's own last review, not 3 since B's")

        let rowsForB = set.rows.filter { $0.cardID == cardB.cardID }
        XCTAssertEqual(rowsForB.map(\.deltaT), [-1])
    }

    func testRowsAreOrderedInTime() throws {
        let (context, service, preferences, review) = try makeFixture()
        let entry = try TestStore.makeEntry(in: context, headword: "alpha")
        let card = try XCTUnwrap(try review.enroll(entry: entry, preferences: preferences).first)

        for day in 0..<6 {
            try review.grade(
                card: card, rating: .good, preferences: preferences,
                now: referenceDate.addingTimeInterval(Double(day) * 86_400)
            )
        }
        let set = try service.trainingSet(preferences: preferences)
        XCTAssertEqual(set.rows.map(\.reviewTime), set.rows.map(\.reviewTime).sorted())
        XCTAssertTrue(set.rows.dropFirst().allSatisfy { $0.deltaT >= 0 })
    }

    func testIntroductionsAreKeptInTheTrainingSetButExcludedFromReadiness() throws {
        let (context, service, preferences, review) = try makeFixture()
        let entry = try TestStore.makeEntry(in: context, headword: "alpha")
        let card = try XCTUnwrap(try review.enroll(entry: entry, preferences: preferences).first)

        // One introduction (state 0) and one genuine recall.
        try review.grade(card: card, rating: .easy, preferences: preferences, now: referenceDate)
        try review.grade(card: card, rating: .good, preferences: preferences,
                         now: referenceDate.addingTimeInterval(3 * 86_400))

        // The optimiser wants the introduction — it is what the initial-stability weights are
        // fitted from.
        let set = try service.trainingSet(preferences: preferences)
        XCTAssertEqual(set.rows.count, 2)
        XCTAssertTrue(set.rows.contains { $0.state == LearningPhase.new.rawValue })

        // Readiness counts only recall observations, so it cannot be inflated by adding words.
        let readiness = try service.readiness(preferences: preferences)
        XCTAssertEqual(readiness.reviewCount, 1)
    }

    func testTrainingSetIsScopedToTheActiveLanguage() throws {
        let (context, service, preferences, review) = try makeFixture()
        preferences.activeLanguage = .english

        let english = try TestStore.makeEntry(in: context, headword: "english", language: .english)
        let french = try TestStore.makeEntry(in: context, headword: "maison", language: .french)
        let cardEN = try XCTUnwrap(try review.enroll(entry: english, preferences: preferences).first)
        let cardFR = try XCTUnwrap(try review.enroll(entry: french, preferences: preferences).first)

        try review.grade(card: cardEN, rating: .good, preferences: preferences, now: referenceDate)
        try review.grade(card: cardFR, rating: .good, preferences: preferences, now: referenceDate)

        let set = try service.trainingSet(preferences: preferences)
        XCTAssertEqual(set.rows.map(\.cardID), [cardEN.cardID])
    }

    /// The header and column order are a contract with the published optimiser.
    func testCSVHasTheExpectedHeaderAndOneRowPerReview() throws {
        let (context, service, preferences, review) = try makeFixture()
        let entry = try TestStore.makeEntry(in: context, headword: "alpha")
        let card = try XCTUnwrap(try review.enroll(entry: entry, preferences: preferences).first)
        try review.grade(card: card, rating: .hard, preferences: preferences, now: referenceDate)

        let csv = try service.trainingSet(preferences: preferences).csv()
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.first, "card_id,review_time,review_rating,review_state,delta_t")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains(card.cardID))
        XCTAssertTrue(lines[1].contains(",\(Rating.hard.rawValue),"))
    }

    /// A card ID containing a comma must not silently add columns to the export.
    ///
    /// `Entry.normalize` folds case and diacritics but keeps punctuation, and a user can type
    /// whatever they like into Add a word — so `"more, or less"` becomes the card ID
    /// `en:more, or less:1#recognition`. Unquoted, that row reaches the optimiser with three
    /// extra columns and either fails to parse or, worse, parses into nonsense.
    func testCSVQuotesCardIDsContainingSeparators() throws {
        let (context, service, preferences, review) = try makeFixture()
        let entry = try TestStore.makeEntry(in: context, headword: "more, or less")
        let card = try XCTUnwrap(try review.enroll(entry: entry, preferences: preferences).first)
        try review.grade(card: card, rating: .good, preferences: preferences, now: referenceDate)

        let csv = try service.trainingSet(preferences: preferences).csv()
        let row = String(try XCTUnwrap(csv.split(separator: "\n").last))
        XCTAssertTrue(card.cardID.contains(","), "the fixture only means something if the ID has a comma")
        XCTAssertTrue(row.hasPrefix("\"\(card.cardID)\","), "got: \(row)")

        // Five columns, once the quoted field is accounted for.
        let fields = splitCSVRow(row)
        XCTAssertEqual(fields.count, 5)
        XCTAssertEqual(fields[0], card.cardID)
    }

    func testCSVFieldQuotingFollowsRFC4180() {
        XCTAssertEqual(FSRSTrainingSet.csvField("en:plain:1#recognition"), "en:plain:1#recognition")
        XCTAssertEqual(FSRSTrainingSet.csvField("a,b"), "\"a,b\"")
        XCTAssertEqual(FSRSTrainingSet.csvField("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(FSRSTrainingSet.csvField("two\nlines"), "\"two\nlines\"")
        XCTAssertEqual(FSRSTrainingSet.csvField("carriage\rreturn"), "\"carriage\rreturn\"")
    }

    /// Minimal RFC 4180 reader, so the test parses the export the way a consumer would rather
    /// than re-implementing the writer's own assumptions.
    private func splitCSVRow(_ row: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let characters = Array(row)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        current.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                inQuotes = true
            } else if character == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        fields.append(current)
        return fields
    }

    func testEmptyHistoryProducesAnEmptySetRatherThanFailing() throws {
        let (_, service, preferences, _) = try makeFixture()
        let set = try service.trainingSet(preferences: preferences)
        XCTAssertTrue(set.rows.isEmpty)
        XCTAssertEqual(set.cardCount, 0)
        XCTAssertTrue(set.csv().hasPrefix("card_id"))
    }

    // MARK: - Readiness gate

    /// Fitting 19 weights to a handful of reviews produces confident nonsense, so the gate is
    /// part of the feature.
    func testReadinessRequiresBothVolumeAndBreadth() {
        let plentyButNarrow = OptimizerReadiness(
            reviewCount: 5_000, cardCount: 10, hasFittedWeights: false, reviewCountAtLastFit: nil
        )
        XCTAssertFalse(plentyButNarrow.meetsMinimum, "volume on 10 cards does not generalise")
        XCTAssertTrue(plentyButNarrow.explanation.contains("不同的"))

        let broadButThin = OptimizerReadiness(
            reviewCount: 50, cardCount: 200, hasFittedWeights: false, reviewCountAtLastFit: nil
        )
        XCTAssertFalse(broadButThin.meetsMinimum)

        let ready = OptimizerReadiness(
            reviewCount: 1_200, cardCount: 300, hasFittedWeights: false, reviewCountAtLastFit: nil
        )
        XCTAssertTrue(ready.meetsMinimum)
        XCTAssertTrue(ready.meetsRecommended)
    }

    /// "Not enough data" is useless; the message has to say how much further there is to go.
    func testExplanationGivesAConcreteRemainingCount() {
        let readiness = OptimizerReadiness(
            reviewCount: 300, cardCount: 100, hasFittedWeights: false, reviewCountAtLastFit: nil
        )
        XCTAssertFalse(readiness.meetsMinimum)
        XCTAssertTrue(readiness.explanation.contains("100"), readiness.explanation)
        XCTAssertEqual(readiness.reviewsUntilRecommended, 700)
    }

    /// FSRS guidance is to re-fit each time the review count doubles.
    func testRefitIsSuggestedWhenReviewsDouble() {
        let justFitted = OptimizerReadiness(
            reviewCount: 1_000, cardCount: 200, hasFittedWeights: true, reviewCountAtLastFit: 1_000
        )
        XCTAssertFalse(justFitted.shouldRefit)

        let doubled = OptimizerReadiness(
            reviewCount: 2_000, cardCount: 200, hasFittedWeights: true, reviewCountAtLastFit: 1_000
        )
        XCTAssertTrue(doubled.shouldRefit)
    }

    func testReadinessReflectsWhetherWeightsAreFitted() throws {
        let (_, service, preferences, _) = try makeFixture()
        XCTAssertFalse(try service.readiness(preferences: preferences).hasFittedWeights)

        try service.applyFittedWeights(
            FSRSParameters.fsrs5Default.weights, preferences: preferences, reviewCount: 1_500
        )
        let after = try service.readiness(preferences: preferences)
        XCTAssertTrue(after.hasFittedWeights)
        XCTAssertEqual(after.reviewCountAtLastFit, 1_500)
    }

    // MARK: - Applying weights

    /// A bad weight vector would corrupt every future interval with no visible symptom until
    /// cards start returning at absurd times, so it is rejected before it is stored.
    func testInvalidWeightVectorsAreRejected() throws {
        let (_, service, preferences, _) = try makeFixture()

        XCTAssertThrowsError(
            try service.applyFittedWeights([1, 2, 3], preferences: preferences, reviewCount: 1_000)
        )
        XCTAssertThrowsError(
            try service.applyFittedWeights(
                Array(repeating: Double.nan, count: FSRSParameters.fsrs5WeightCount),
                preferences: preferences, reviewCount: 1_000
            )
        )
        XCTAssertNil(preferences.fsrsWeights, "nothing invalid may be stored")
    }

    /// Applying weights must not disturb what the cards have already earned.
    func testApplyingWeightsPreservesEarnedCardState() throws {
        let (context, service, preferences, review) = try makeFixture()
        let entry = try TestStore.makeEntry(in: context, headword: "alpha")
        let card = try XCTUnwrap(try review.enroll(entry: entry, preferences: preferences).first)
        try review.grade(card: card, rating: .easy, preferences: preferences, now: referenceDate)

        let stability = card.stability
        let difficulty = card.difficulty
        let due = card.due

        var weights = FSRSParameters.fsrs5Default.weights
        weights[2] = 4.0
        try service.applyFittedWeights(weights, preferences: preferences, reviewCount: 1_000)

        XCTAssertEqual(card.stability, stability, "measured stability must survive a re-fit")
        XCTAssertEqual(card.difficulty, difficulty)
        XCTAssertEqual(card.due, due)
        XCTAssertEqual(preferences.schedulerConfig.fsrsParameters.weights[2], 4.0)
    }

    func testResetRestoresTheDefaults() throws {
        let (_, service, preferences, _) = try makeFixture()
        try service.applyFittedWeights(
            FSRSParameters.fsrs5Default.weights, preferences: preferences, reviewCount: 900
        )
        try service.resetToDefaultWeights(preferences: preferences)

        XCTAssertNil(preferences.fsrsWeights)
        XCTAssertEqual(preferences.fsrsParametersVersion, FSRSParameters.fsrs5Default.version)
        XCTAssertNil(try service.readiness(preferences: preferences).reviewCountAtLastFit)
    }

    // MARK: - Parsing pasted weights

    /// Accepts what the published optimiser actually prints.
    func testParsesTheOptimiserOutputFormat() throws {
        let printed = "[0.4872, 1.4003, 3.7145, 13.8206, 5.1618, 1.2298, 0.8975, 0.031, 1.6474, "
            + "0.1367, 1.0461, 2.1072, 0.0793, 0.3246, 1.587, 0.2272, 2.8755, 0.5, 0.6621]"
        let weights = try XCTUnwrap(OptimizerService.parseWeights(printed))
        XCTAssertEqual(weights.count, FSRSParameters.fsrs5WeightCount)
        XCTAssertEqual(weights[0], 0.4872, accuracy: 1e-9)

        // Space-separated and newline-separated variants, since people paste from anywhere.
        XCTAssertEqual(OptimizerService.parseWeights("0.4 1.1 3.2")?.count, 3)
        XCTAssertEqual(OptimizerService.parseWeights("0.4,\n1.1,\n3.2")?.count, 3)
    }

    func testRejectsNonNumericPaste() {
        XCTAssertNil(OptimizerService.parseWeights(""))
        XCTAssertNil(OptimizerService.parseWeights("hello world"))
        // A partially numeric list is a truncated paste, not a usable vector.
        XCTAssertNil(OptimizerService.parseWeights("[0.4, 1.1, oops, 3.2]"))
    }
}
