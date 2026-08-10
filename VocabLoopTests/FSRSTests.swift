import XCTest
@testable import VocabLoop

/// Pins the FSRS-5 implementation to its *invariants* rather than to magic numbers.
///
/// Asserting exact stabilities would lock in whichever weight vector happens to ship, and
/// would have to be rewritten the moment weights are optimised per user — which is the whole
/// point of storing them as data. The properties below must hold for *any* sane weight vector,
/// so they keep their value across every future change.
final class FSRSTests: XCTestCase {
    private let scheduler = FSRSScheduler(config: SchedulerConfig(fuzzEnabled: false))
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Forgetting curve

    /// Stability is *defined* as the interval at which recall probability is 90%. If this
    /// fails, `FACTOR` is wrong and every interval in the app is wrong with it.
    func testRetrievabilityAtStabilityIsNinetyPercent() {
        for stability in [1.0, 10.0, 100.0, 1000.0] {
            let r = scheduler.retrievability(elapsedDays: stability, stability: stability)
            XCTAssertEqual(r, 0.9, accuracy: 1e-9, "R(S, S) must be 0.9 for S = \(stability)")
        }
    }

    func testRetrievabilityStartsAtOneAndDecaysMonotonically() {
        XCTAssertEqual(scheduler.retrievability(elapsedDays: 0, stability: 10), 1.0, accuracy: 1e-12)

        var previous = 1.0
        for day in stride(from: 1.0, through: 200.0, by: 1.0) {
            let r = scheduler.retrievability(elapsedDays: day, stability: 10)
            XCTAssertLessThan(r, previous, "R must strictly decrease with elapsed time")
            XCTAssertGreaterThan(r, 0)
            previous = r
        }
    }

    /// An unseen card is unknown, not forgotten. Returning 0 here would feed a zero into the
    /// stability growth term and blow it up.
    func testRetrievabilityOfUnseenCardIsOne() {
        XCTAssertEqual(scheduler.retrievability(of: .newCard(due: now), at: now), 1.0)
    }

    // MARK: - Interval inversion

    func testIntervalForNinetyPercentRetentionEqualsStability() {
        let ninety = FSRSScheduler(config: SchedulerConfig(desiredRetention: 0.90, fuzzEnabled: false))
        for stability in [5.0, 20.0, 300.0] {
            XCTAssertEqual(ninety.interval(forStability: stability), stability, accuracy: 1e-6)
        }
    }

    /// The dial has to actually do something, in the right direction: wanting to remember more
    /// means reviewing sooner.
    func testHigherRetentionProducesShorterIntervals() {
        let stability = 100.0
        var previousInterval = Double.infinity
        for retention in [0.70, 0.80, 0.90, 0.95, 0.97] {
            let scheduler = FSRSScheduler(
                config: SchedulerConfig(desiredRetention: retention, fuzzEnabled: false)
            )
            let interval = scheduler.interval(forStability: stability)
            XCTAssertLessThan(interval, previousInterval, "retention \(retention) must review sooner")
            previousInterval = interval
        }
    }

    func testIntervalIsCappedByMaximumInterval() {
        let capped = FSRSScheduler(
            config: SchedulerConfig(maximumInterval: 365, fuzzEnabled: false)
        )
        XCTAssertLessThanOrEqual(capped.interval(forStability: 100_000), 365)
    }

    // MARK: - Initial state

    func testInitialStabilityIncreasesWithRating() {
        let stabilities = Rating.allCases.map { scheduler.initialStability($0) }
        XCTAssertEqual(stabilities, stabilities.sorted(), "S₀ must be monotonic in rating")
        XCTAssertTrue(stabilities.allSatisfy { $0 > 0 })
    }

    func testInitialDifficultyDecreasesWithRatingAndStaysInBounds() {
        let difficulties = Rating.allCases.map { scheduler.initialDifficulty($0) }
        XCTAssertEqual(difficulties, difficulties.sorted(by: >), "D₀ must fall as rating rises")
        XCTAssertTrue(difficulties.allSatisfy { $0 >= 1 && $0 <= 10 })
    }

    // MARK: - Difficulty

    /// The `(10 − D)/9` damping exists to stop difficulty pinning at 10 after a few lapses —
    /// SM-2's "ease hell". This is the test that proves the damping is present.
    func testDifficultyStaysInBoundsUnderRepeatedExtremes() {
        var difficulty = 5.0
        for _ in 0..<200 {
            difficulty = scheduler.nextDifficulty(difficulty, rating: .again)
            XCTAssertTrue(difficulty >= 1 && difficulty <= 10, "D escaped bounds: \(difficulty)")
        }
        XCTAssertLessThanOrEqual(difficulty, 10)

        for _ in 0..<200 {
            difficulty = scheduler.nextDifficulty(difficulty, rating: .easy)
            XCTAssertTrue(difficulty >= 1 && difficulty <= 10, "D escaped bounds: \(difficulty)")
        }
        XCTAssertGreaterThanOrEqual(difficulty, 1)
    }

    func testAgainRaisesDifficultyAndEasyLowersIt() {
        let base = 5.0
        XCTAssertGreaterThan(scheduler.nextDifficulty(base, rating: .again), base)
        XCTAssertLessThan(scheduler.nextDifficulty(base, rating: .easy), base)
    }

    // MARK: - Stability

    func testStabilityAfterRecallIsMonotonicInRating() {
        let stability = 10.0
        let difficulty = 5.0
        let r = scheduler.retrievability(elapsedDays: 10, stability: stability)

        let values = [Rating.hard, .good, .easy].map {
            scheduler.stabilityAfterRecall(
                stability: stability,
                difficulty: scheduler.nextDifficulty(difficulty, rating: $0),
                retrievability: r,
                rating: $0
            )
        }
        XCTAssertEqual(values, values.sorted(), "Hard < Good < Easy for stability growth")
        XCTAssertTrue(values.allSatisfy { $0 > stability }, "a successful recall must not shrink S")
    }

    /// FSRS-5 caps post-lapse stability at the prior stability. Forgetting must never be
    /// rewarded with a longer interval than the card already had.
    func testStabilityAfterLapseNeverExceedsPriorStability() {
        for stability in [0.5, 1.0, 10.0, 100.0, 1000.0] {
            for difficulty in [1.0, 5.0, 10.0] {
                for elapsed in [0.0, 1.0, stability, stability * 5] {
                    let r = scheduler.retrievability(elapsedDays: elapsed, stability: stability)
                    let lapsed = scheduler.stabilityAfterLapse(
                        stability: stability, difficulty: difficulty, retrievability: r
                    )
                    XCTAssertLessThanOrEqual(
                        lapsed, stability + 1e-9,
                        "S=\(stability) D=\(difficulty) t=\(elapsed) produced \(lapsed)"
                    )
                    XCTAssertGreaterThan(lapsed, 0)
                }
            }
        }
    }

    /// Reviewing a card long before it is due should buy almost nothing — that is the
    /// `(e^(w10·(1−R)) − 1)` term, and it is what stops users gaming the scheduler by drilling.
    func testReviewingEarlyGainsLessThanReviewingOnTime() {
        let stability = 50.0
        let difficulty = 5.0

        let earlyGain = scheduler.stabilityAfterRecall(
            stability: stability, difficulty: difficulty,
            retrievability: scheduler.retrievability(elapsedDays: 1, stability: stability),
            rating: .good
        )
        let onTimeGain = scheduler.stabilityAfterRecall(
            stability: stability, difficulty: difficulty,
            retrievability: scheduler.retrievability(elapsedDays: stability, stability: stability),
            rating: .good
        )
        XCTAssertLessThan(earlyGain, onTimeGain)
    }

    // MARK: - Full grading flow

    func testNewCardEntersLearningAndIsDueWithinMinutes() {
        let outcome = scheduler.apply(rating: .good, to: .newCard(due: now), at: now, fuzzSeed: 1)
        XCTAssertEqual(outcome.state.phase, .learning)
        XCTAssertGreaterThan(outcome.state.stability, 0)
        XCTAssertTrue(outcome.state.difficulty >= 1 && outcome.state.difficulty <= 10)
        XCTAssertLessThan(outcome.intervalDays, 1, "a learning step must be intraday")
        XCTAssertEqual(outcome.state.reps, 1)
        XCTAssertEqual(outcome.state.lastReviewedAt, now)
    }

    /// `Easy` on a brand-new card skips introduction. A word the user already knows should not
    /// be drip-fed through two minutes of steps.
    func testEasyOnNewCardGraduatesImmediately() {
        let outcome = scheduler.apply(rating: .easy, to: .newCard(due: now), at: now, fuzzSeed: 1)
        XCTAssertEqual(outcome.state.phase, .review)
        XCTAssertGreaterThanOrEqual(outcome.intervalDays, 1)
    }

    func testGoodTwiceGraduatesThroughTwoLearningSteps() {
        var state = SchedulingState.newCard(due: now)
        state = scheduler.apply(rating: .good, to: state, at: now, fuzzSeed: 7).state
        XCTAssertEqual(state.phase, .learning)

        let later = now.addingTimeInterval(600)
        state = scheduler.apply(rating: .good, to: state, at: later, fuzzSeed: 7).state
        XCTAssertEqual(state.phase, .review)
        XCTAssertGreaterThanOrEqual(state.intervalDays, 1)
    }

    func testAgainOnReviewCardLapsesIntoRelearning() {
        var state = SchedulingState(
            phase: .review, stability: 40, difficulty: 5, intervalDays: 40,
            due: now, lastReviewedAt: now.addingTimeInterval(-40 * 86_400), reps: 6, lapses: 1
        )
        let before = state.stability
        state = scheduler.apply(rating: .again, to: state, at: now, fuzzSeed: 3).state

        XCTAssertEqual(state.phase, .relearning)
        XCTAssertEqual(state.lapses, 2)
        XCTAssertLessThan(state.stability, before)
        XCTAssertLessThan(state.intervalDays, 1, "relearning starts with an intraday step")
    }

    /// The long-run behaviour that matters: intervals must grow, and nothing may go NaN,
    /// negative or infinite anywhere along the way.
    func testLongSuccessfulSequenceGrowsIntervalsAndStaysFinite() {
        var state = SchedulingState.newCard(due: now)
        var clock = now
        var previousInterval = 0.0

        for step in 0..<40 {
            let outcome = scheduler.apply(rating: .good, to: state, at: clock, fuzzSeed: 11)
            state = outcome.state

            XCTAssertTrue(state.stability.isFinite && state.stability > 0, "step \(step): S = \(state.stability)")
            XCTAssertTrue(state.difficulty >= 1 && state.difficulty <= 10, "step \(step): D = \(state.difficulty)")
            XCTAssertTrue(state.intervalDays.isFinite && state.intervalDays >= 0)
            XCTAssertLessThanOrEqual(state.intervalDays, scheduler.config.maximumInterval)

            if state.phase == .review {
                XCTAssertGreaterThanOrEqual(
                    state.intervalDays, previousInterval - 1e-6,
                    "step \(step): interval shrank on a successful review"
                )
                previousInterval = state.intervalDays
            }
            clock = state.due
        }
        XCTAssertEqual(state.phase, .review)
        XCTAssertGreaterThan(previousInterval, 100, "40 correct answers should reach a long interval")
    }

    /// Adversarial inputs. A corrupt persisted card must degrade, never crash or produce NaN.
    ///
    /// The out-of-range `stepIndex` cases matter in practice as well as in theory: shortening the
    /// learning-step list in Settings leaves existing cards pointing past the end of it.
    func testPathologicalStateDoesNotProduceInvalidSchedule() {
        let broken = [
            SchedulingState(phase: .review, stability: 0, difficulty: 0, intervalDays: 0, due: now, lastReviewedAt: now),
            SchedulingState(phase: .review, stability: .infinity, difficulty: 5, intervalDays: 1, due: now, lastReviewedAt: now),
            SchedulingState(phase: .review, stability: -5, difficulty: 20, intervalDays: -1, due: now, lastReviewedAt: now),
            SchedulingState(phase: .review, stability: .nan, difficulty: .nan, intervalDays: .nan, due: now, lastReviewedAt: now),
            SchedulingState(phase: .learning, stability: 3, difficulty: 5, intervalDays: 0.01, due: now, lastReviewedAt: now, stepIndex: -4),
            SchedulingState(phase: .learning, stability: 3, difficulty: 5, intervalDays: 0.01, due: now, lastReviewedAt: now, stepIndex: 99),
            SchedulingState(phase: .relearning, stability: 3, difficulty: 5, intervalDays: 0.01, due: now, lastReviewedAt: now, stepIndex: 99),
        ]

        for state in broken {
            for rating in Rating.allCases {
                let outcome = scheduler.apply(rating: rating, to: state, at: now, fuzzSeed: 1)
                XCTAssertTrue(outcome.state.stability.isFinite, "S not finite for \(state.stability)")
                XCTAssertGreaterThan(outcome.state.stability, 0)
                XCTAssertTrue(outcome.state.difficulty >= 1 && outcome.state.difficulty <= 10)
                XCTAssertTrue(outcome.intervalDays.isFinite)
                XCTAssertGreaterThan(outcome.state.due, Date.distantPast)
            }
        }
    }

    /// A card answered late has decayed more, so the same rating should not produce a shorter
    /// interval than answering it on time would have.
    func testOverdueCardIsNotPenalisedRelativeToOnTime() {
        let state = SchedulingState(
            phase: .review, stability: 20, difficulty: 5, intervalDays: 20,
            due: now, lastReviewedAt: now.addingTimeInterval(-20 * 86_400), reps: 4
        )
        let onTime = scheduler.apply(rating: .good, to: state, at: now, fuzzSeed: 5)
        let late = scheduler.apply(
            rating: .good, to: state, at: now.addingTimeInterval(20 * 86_400), fuzzSeed: 5
        )
        XCTAssertGreaterThanOrEqual(late.state.stability, onTime.state.stability)
        XCTAssertLessThan(late.retrievabilityBefore, onTime.retrievabilityBefore)
    }

    // MARK: - Parameters

    func testCorruptWeightsFallBackToDefaults() {
        let truncated = FSRSParameters(weights: [1, 2, 3], version: "broken")
        XCTAssertFalse(truncated.isValid)
        XCTAssertEqual(truncated.validated.weights, FSRSParameters.fsrs5Default.weights)

        let notFinite = FSRSParameters(
            weights: Array(repeating: Double.nan, count: 19), version: "broken"
        )
        XCTAssertFalse(notFinite.isValid)
    }

    func testDefaultParametersAreValid() {
        XCTAssertTrue(FSRSParameters.fsrs5Default.isValid)
        XCTAssertEqual(FSRSParameters.fsrs5Default.weights.count, FSRSParameters.fsrs5WeightCount)
        XCTAssertEqual(FSRSParameters.fsrs5Default.factor, 19.0 / 81.0, accuracy: 1e-12)
    }

    func testOutOfRangeRetentionIsClampedRatherThanTrusted() {
        let absurd = SchedulerConfig(desiredRetention: 1.5).sanitised
        XCTAssertLessThanOrEqual(absurd.desiredRetention, SchedulerConfig.retentionRange.upperBound)

        let tiny = SchedulerConfig(desiredRetention: 0.01).sanitised
        XCTAssertGreaterThanOrEqual(tiny.desiredRetention, SchedulerConfig.retentionRange.lowerBound)
    }

    func testEmptyLearningStepsAreReplacedRatherThanCrashing() {
        let config = SchedulerConfig(
            learningStepsMinutes: [], relearningStepsMinutes: []
        ).sanitised
        XCTAssertFalse(config.learningStepsMinutes.isEmpty)
        XCTAssertFalse(config.relearningStepsMinutes.isEmpty)

        // The step lists are indexed directly during grading, so an empty list would be a
        // crash rather than a wrong interval.
        let scheduler = FSRSScheduler(config: config)
        let outcome = scheduler.apply(rating: .again, to: .newCard(due: now), at: now, fuzzSeed: 1)
        XCTAssertEqual(outcome.state.phase, .learning)
    }
}
