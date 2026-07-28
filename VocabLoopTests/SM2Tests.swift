import XCTest
@testable import VocabLoop

/// SM-2 exists as the honest baseline to compare FSRS against, and to keep the ``Scheduler``
/// boundary real. These tests hold it to the behaviour SuperMemo 2 actually specifies.
final class SM2Tests: XCTestCase {
    private let scheduler = SM2Scheduler(config: SchedulerConfig(fuzzEnabled: false))
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testEaseFactorNeverFallsBelowTheFloor() {
        var state = SchedulingState(
            phase: .review, easeFactor: 1.4, intervalDays: 10,
            due: now, lastReviewedAt: now.addingTimeInterval(-10 * 86_400), reps: 3
        )
        for _ in 0..<50 {
            state = scheduler.apply(rating: .again, to: state, at: now, fuzzSeed: 1).state
            XCTAssertGreaterThanOrEqual(state.easeFactor, SM2Scheduler.minimumEaseFactor)
            // Bring it back to review so the next Again is a genuine lapse rather than a
            // relearning step.
            state.phase = .review
            state.intervalDays = 10
        }
    }

    func testGoodMultipliesIntervalByEaseFactor() {
        let state = SchedulingState(
            phase: .review, easeFactor: 2.5, intervalDays: 10,
            due: now, lastReviewedAt: now.addingTimeInterval(-10 * 86_400), reps: 3
        )
        let outcome = scheduler.apply(rating: .good, to: state, at: now, fuzzSeed: 1)
        XCTAssertEqual(outcome.state.intervalDays, 25, accuracy: 0.001)
    }

    func testRatingsAreOrderedByResultingInterval() {
        let state = SchedulingState(
            phase: .review, easeFactor: 2.5, intervalDays: 20,
            due: now, lastReviewedAt: now.addingTimeInterval(-20 * 86_400), reps: 5
        )
        let intervals = [Rating.hard, .good, .easy].map {
            scheduler.apply(rating: $0, to: state, at: now, fuzzSeed: 1).state.intervalDays
        }
        XCTAssertEqual(intervals, intervals.sorted(), "Hard < Good < Easy")
    }

    func testLapseSendsCardToRelearningAndCountsALapse() {
        let state = SchedulingState(
            phase: .review, easeFactor: 2.5, intervalDays: 30,
            due: now, lastReviewedAt: now.addingTimeInterval(-30 * 86_400), reps: 8, lapses: 0
        )
        let outcome = scheduler.apply(rating: .again, to: state, at: now, fuzzSeed: 1)
        XCTAssertEqual(outcome.state.phase, .relearning)
        XCTAssertEqual(outcome.state.lapses, 1)
        XCTAssertLessThan(outcome.intervalDays, 1)
    }

    func testEasyOnNewCardUsesTheEasyInterval() {
        let outcome = scheduler.apply(rating: .easy, to: .newCard(due: now), at: now, fuzzSeed: 1)
        XCTAssertEqual(outcome.state.phase, .review)
        XCTAssertEqual(outcome.state.intervalDays, SM2Scheduler.easyInterval, accuracy: 0.001)
    }

    func testGoodTwiceOnNewCardGraduatesToOneDay() {
        var state = scheduler.apply(rating: .good, to: .newCard(due: now), at: now, fuzzSeed: 1).state
        XCTAssertEqual(state.phase, .learning)
        state = scheduler.apply(rating: .good, to: state, at: now.addingTimeInterval(600), fuzzSeed: 1).state
        XCTAssertEqual(state.phase, .review)
        XCTAssertEqual(state.intervalDays, SM2Scheduler.graduatingInterval, accuracy: 0.001)
    }

    func testIntervalIsCappedByMaximumInterval() {
        let capped = SM2Scheduler(config: SchedulerConfig(maximumInterval: 100, fuzzEnabled: false))
        let state = SchedulingState(
            phase: .review, easeFactor: 2.5, intervalDays: 90,
            due: now, lastReviewedAt: now.addingTimeInterval(-90 * 86_400), reps: 10
        )
        let outcome = capped.apply(rating: .easy, to: state, at: now, fuzzSeed: 1)
        XCTAssertLessThanOrEqual(outcome.state.intervalDays, 100)
    }

    /// Statistics read `stability` regardless of which scheduler is active, so SM-2 mirrors its
    /// interval there. Otherwise every SM-2 card would report as `new` in the maturity buckets.
    func testStabilityMirrorsIntervalSoMaturityBucketsWork() {
        let state = SchedulingState(
            phase: .review, easeFactor: 2.5, intervalDays: 30,
            due: now, lastReviewedAt: now.addingTimeInterval(-30 * 86_400), reps: 8
        )
        let outcome = scheduler.apply(rating: .good, to: state, at: now, fuzzSeed: 1)
        XCTAssertEqual(outcome.state.stability, outcome.state.intervalDays, accuracy: 0.001)
        XCTAssertEqual(outcome.state.maturity, .mature)
    }

    func testSchedulerFactoryReturnsRequestedKind() {
        XCTAssertEqual(SchedulerFactory.make(.fsrs5, config: .default).kind, .fsrs5)
        XCTAssertEqual(SchedulerFactory.make(.sm2, config: .default).kind, .sm2)
    }

    /// The preview drives the interval labels on the rating buttons, so it must cover all four.
    func testPreviewCoversEveryRating() {
        for kind in SchedulerKind.allCases {
            let scheduler = SchedulerFactory.make(kind, config: .default)
            let previews = scheduler.preview(state: .newCard(due: now), at: now, fuzzSeed: 1)
            XCTAssertEqual(Set(previews.keys), Set(Rating.allCases), "\(kind) preview incomplete")
        }
    }
}
