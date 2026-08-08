import XCTest
import SwiftData
@testable import VocabLoop

/// Grading a card touches five things at once: the card, the review log, the day rollup, the sync
/// outbox and — the first time — the daily batch. These tests hold that contract together, because
/// the moment one of them can be skipped, statistics start lying.
@MainActor
final class ReviewServiceTests: XCTestCase {

    private func makeFixture() throws -> (ModelContext, ReviewService, StudyPreferences, Entry) {
        let context = try TestStore.makeContext()
        let account = try context.activeAccount()
        let preferences = try XCTUnwrap(account.preferences)
        let entry = try TestStore.makeEntry(in: context, headword: "abandon")
        return (context, ReviewService(context: context), preferences, entry)
    }

    // MARK: - Enrolment

    func testEnrolCreatesOneCardPerEnabledDirection() throws {
        let (context, service, preferences, entry) = try makeFixture()
        preferences.enabledDirections = [.recognition, .production]

        let created = try service.enroll(entry: entry, preferences: preferences, now: referenceDate)

        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Card>()), 2)
        XCTAssertEqual(Set(created.map(\.direction)), Set([.recognition, .production]))
        XCTAssertTrue(created.allSatisfy { $0.phase == .new })
        XCTAssertTrue(created.allSatisfy { $0.entry?.stableID == entry.stableID })
    }

    func testEnrolIsIdempotent() throws {
        let (context, service, preferences, entry) = try makeFixture()
        try service.enroll(entry: entry, preferences: preferences, now: referenceDate)
        let second = try service.enroll(entry: entry, preferences: preferences, now: referenceDate)

        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<Card>()),
            preferences.enabledDirections.count
        )
    }

    /// Un-enrolling keeps the review history. A user who removes a word and adds it back should not
    /// find their past reviews erased from statistics.
    func testUnenrolRemovesCardsButKeepsTheEntry() throws {
        let (context, service, preferences, entry) = try makeFixture()
        try service.enroll(entry: entry, preferences: preferences, now: referenceDate)
        try service.unenroll(entry: entry)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Card>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Entry>()), 1)
    }

    // MARK: - Grading

    func testGradingWritesALogWithEveryOptimiserField() throws {
        let (context, service, preferences, entry) = try makeFixture()
        let card = try XCTUnwrap(
            try service.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )

        try service.grade(
            card: card, rating: .good, preferences: preferences,
            durationMS: 3_400, now: referenceDate
        )

        let logs = try context.fetch(FetchDescriptor<ReviewLog>())
        XCTAssertEqual(logs.count, 1)
        let log = try XCTUnwrap(logs.first)

        XCTAssertEqual(log.rating, .good)
        XCTAssertEqual(log.cardID, card.cardID)
        XCTAssertEqual(log.entryStableID, entry.stableID)
        XCTAssertEqual(log.phaseBefore, .new)
        XCTAssertEqual(log.durationMS, 3_400)
        XCTAssertEqual(log.reviewedAt, referenceDate)
        XCTAssertEqual(log.parametersVersion, preferences.schedulerConfig.fsrsParameters.version)
        XCTAssertEqual(log.scheduler, .fsrs5)
        // The prediction at review time is the one field an optimiser cannot reconstruct later.
        XCTAssertTrue(log.retrievabilityBefore >= 0 && log.retrievabilityBefore <= 1)
        XCTAssertGreaterThan(log.stabilityAfter, 0)
        XCTAssertTrue(log.difficultyAfter >= 1 && log.difficultyAfter <= 10)
        XCTAssertFalse(log.isGradedRecall, "the first showing is an introduction, not a recall test")
    }

    func testGradingAdvancesTheCardState() throws {
        let (_, service, preferences, entry) = try makeFixture()
        let card = try XCTUnwrap(
            try service.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )

        try service.grade(card: card, rating: .good, preferences: preferences, now: referenceDate)

        XCTAssertEqual(card.reps, 1)
        XCTAssertEqual(card.lastReviewedAt, referenceDate)
        XCTAssertNotEqual(card.phase, .new)
        XCTAssertGreaterThan(card.due, referenceDate)
        XCTAssertGreaterThan(card.stability, 0)
    }

    func testGradingUpdatesTheDayRollup() throws {
        let (_, service, preferences, entry) = try makeFixture()
        preferences.dailyGoal = 2
        let card = try XCTUnwrap(
            try service.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )

        try service.grade(card: card, rating: .good, preferences: preferences, durationMS: 2_000, now: referenceDate)
        var day = try XCTUnwrap(
            try service.studyDay(for: referenceDate, preferences: preferences, createIfMissing: false)
        )
        XCTAssertEqual(day.reviewsCompleted, 1)
        XCTAssertEqual(day.correctCount, 1)
        XCTAssertEqual(day.newCardsIntroduced, 1)
        XCTAssertEqual(day.studySeconds, 2)
        XCTAssertFalse(day.goalMet)

        try service.grade(
            card: card, rating: .again, preferences: preferences,
            now: referenceDate.addingTimeInterval(600)
        )
        day = try XCTUnwrap(
            try service.studyDay(for: referenceDate, preferences: preferences, createIfMissing: false)
        )
        XCTAssertEqual(day.reviewsCompleted, 2)
        XCTAssertEqual(day.correctCount, 1, "Again must not count as correct")
        XCTAssertTrue(day.goalMet)
    }

    /// A session left open on a locked phone would otherwise report hours of study time.
    func testAbsurdDurationIsCapped() throws {
        let (_, service, preferences, entry) = try makeFixture()
        let card = try XCTUnwrap(
            try service.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )

        try service.grade(
            card: card, rating: .good, preferences: preferences,
            durationMS: 6 * 3_600 * 1_000, now: referenceDate
        )
        let day = try XCTUnwrap(
            try service.studyDay(for: referenceDate, preferences: preferences, createIfMissing: false)
        )
        XCTAssertLessThanOrEqual(day.studySeconds, 120)
    }

    func testLapseFromReviewIncrementsLapses() throws {
        let (_, service, preferences, entry) = try makeFixture()
        let card = try XCTUnwrap(try service.enroll(entry: entry, preferences: preferences).first)

        // Place the card mid-review directly; going through 40 correct answers to get here would
        // test the scheduler rather than the lapse bookkeeping.
        card.schedulingState = SchedulingState(
            phase: .review, stability: 30, difficulty: 5, intervalDays: 30,
            due: referenceDate,
            lastReviewedAt: referenceDate.addingTimeInterval(-30 * 86_400),
            reps: 5
        )
        XCTAssertEqual(card.lapses, 0)

        try service.grade(card: card, rating: .again, preferences: preferences, now: referenceDate)
        XCTAssertEqual(card.lapses, 1)
        XCTAssertEqual(card.phase, .relearning)
    }

    // MARK: - Undo

    /// Undo is reconstructed from the review log, not from an in-memory snapshot, so it works after
    /// a relaunch and cannot disagree with the history.
    func testUndoRestoresThePreviousStateAndDeletesTheLog() throws {
        let (context, service, preferences, entry) = try makeFixture()
        let card = try XCTUnwrap(
            try service.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )

        // Graduate it so there is real state to restore.
        try service.grade(card: card, rating: .easy, preferences: preferences, now: referenceDate)
        let graduated = card.schedulingState

        let later = referenceDate.addingTimeInterval(5 * 86_400)
        try service.grade(card: card, rating: .again, preferences: preferences, now: later)
        XCTAssertEqual(card.lapses, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReviewLog>()), 2)

        try service.undoLastReview(card: card, preferences: preferences)

        XCTAssertEqual(card.phase, graduated.phase)
        XCTAssertEqual(card.stability, graduated.stability, accuracy: 1e-9)
        XCTAssertEqual(card.difficulty, graduated.difficulty, accuracy: 1e-9)
        XCTAssertEqual(card.intervalDays, graduated.intervalDays, accuracy: 1e-9)
        XCTAssertEqual(card.reps, graduated.reps)
        XCTAssertEqual(card.lapses, 0, "the lapse must be taken back too")
        XCTAssertEqual(card.lastReviewedAt, referenceDate, "the previous review defines lastReviewedAt")
        // An undone review did not happen; leaving the row would corrupt accuracy statistics.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReviewLog>()), 1)
    }

    func testUndoOfTheFirstReviewReturnsTheCardToNeverAnswered() throws {
        let (context, service, preferences, entry) = try makeFixture()
        let card = try XCTUnwrap(
            try service.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )

        try service.grade(card: card, rating: .good, preferences: preferences, now: referenceDate)
        try service.undoLastReview(card: card, preferences: preferences)

        XCTAssertEqual(card.phase, .new)
        XCTAssertNil(card.lastReviewedAt)
        XCTAssertEqual(card.reps, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReviewLog>()), 0)
    }

    func testUndoAlsoRollsBackTheDayRollup() throws {
        let (_, service, preferences, entry) = try makeFixture()
        let card = try XCTUnwrap(
            try service.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )

        try service.grade(card: card, rating: .good, preferences: preferences, now: referenceDate)
        try service.undoLastReview(card: card, preferences: preferences)

        let day = try XCTUnwrap(
            try service.studyDay(for: referenceDate, preferences: preferences, createIfMissing: false)
        )
        XCTAssertEqual(day.reviewsCompleted, 0)
        XCTAssertEqual(day.correctCount, 0)
        XCTAssertEqual(day.newCardsIntroduced, 0)
    }

    /// SM-2's ease factor is cumulative, so undo has to put it back.
    ///
    /// Nothing ever raises it after a lapse: `Again` subtracts 0.2 and that is permanent. An undo
    /// that left it lowered would shorten every future interval for that card forever, with no
    /// visible cause and nothing in the history to explain it.
    func testUndoRestoresTheSM2EaseFactor() throws {
        let (_, service, preferences, entry) = try makeFixture()
        preferences.scheduler = .sm2
        let card = try XCTUnwrap(
            try service.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )

        // Graduate, then lapse, which is what moves the ease factor.
        try service.grade(card: card, rating: .easy, preferences: preferences, now: referenceDate)
        let easeBeforeLapse = card.easeFactor

        let later = referenceDate.addingTimeInterval(10 * 86_400)
        try service.grade(card: card, rating: .again, preferences: preferences, now: later)
        XCTAssertLessThan(card.easeFactor, easeBeforeLapse, "the fixture must actually move the ease")

        try service.undoLastReview(card: card, preferences: preferences)
        XCTAssertEqual(card.easeFactor, easeBeforeLapse, accuracy: 1e-9)
    }

    /// Undoing mid-steps must put the card back on the step it was on, not the one it advanced to.
    ///
    /// Learning steps are `[1, 10]` by default. `Good` on step 0 moves to step 1; undoing that has
    /// to return `stepIndex` to 0, or answering `Good` again graduates the card straight out of
    /// learning and the second step is silently skipped.
    func testUndoRestoresThePositionInTheLearningSteps() throws {
        let (_, service, preferences, entry) = try makeFixture()
        preferences.learningStepsMinutes = [1, 10]
        let card = try XCTUnwrap(
            try service.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )
        XCTAssertEqual(card.stepIndex, 0)

        try service.grade(card: card, rating: .good, preferences: preferences, now: referenceDate)
        XCTAssertEqual(card.phase, .learning)
        XCTAssertEqual(card.stepIndex, 1, "Good on the first step advances to the second")

        let later = referenceDate.addingTimeInterval(600)
        try service.grade(card: card, rating: .good, preferences: preferences, now: later)
        XCTAssertEqual(card.phase, .review, "the second Good graduates it")

        try service.undoLastReview(card: card, preferences: preferences)
        XCTAssertEqual(card.phase, .learning)
        XCTAssertEqual(card.stepIndex, 1, "back on the second step, not the first and not graduated")

        try service.undoLastReview(card: card, preferences: preferences)
        XCTAssertEqual(card.phase, .new)
        XCTAssertEqual(card.stepIndex, 0)
    }

    /// Time studied must come back off the day, using the same cap it went on with.
    func testUndoRollsBackTimeStudiedWithTheSameCap() throws {
        let (_, service, preferences, entry) = try makeFixture()
        let card = try XCTUnwrap(
            try service.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )

        // Well past the 120s cap, so a mismatched cap on either side would show up.
        try service.grade(
            card: card, rating: .good, preferences: preferences,
            durationMS: 9_000_000, now: referenceDate
        )
        let day = try XCTUnwrap(
            try service.studyDay(for: referenceDate, preferences: preferences, createIfMissing: false)
        )
        XCTAssertEqual(day.studySeconds, 120, "one card cannot contribute more than the cap")

        try service.undoLastReview(card: card, preferences: preferences)
        XCTAssertEqual(day.studySeconds, 0)
        XCTAssertFalse(day.goalMet, "a day with no reviews cannot have met a goal")
    }

    func testUndoWithNoHistoryIsANoOp() throws {
        let (_, service, preferences, entry) = try makeFixture()
        let card = try XCTUnwrap(
            try service.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )
        XCTAssertNoThrow(try service.undoLastReview(card: card, preferences: preferences))
        XCTAssertEqual(card.phase, .new)
    }

    // MARK: - Card controls

    func testSuspendBuryAndFlag() throws {
        let (_, service, preferences, entry) = try makeFixture()
        let card = try XCTUnwrap(
            try service.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )

        try service.setSuspended(true, card: card)
        XCTAssertFalse(card.isDue(at: referenceDate), "a suspended card is never due")

        try service.setSuspended(false, card: card)
        try service.bury(card: card, preferences: preferences, now: referenceDate)
        XCTAssertFalse(card.isDue(at: referenceDate))
        XCTAssertTrue(
            card.isDue(at: referenceDate.addingTimeInterval(2 * 86_400)),
            "burying hides a card until the next study day, not forever"
        )

        try service.setFlagged(true, card: card)
        XCTAssertTrue(card.isFlagged)
    }

    /// Resetting a card clears its schedule but keeps the log — the log is what a future optimiser
    /// trains on.
    func testResetProgressKeepsTheReviewHistory() throws {
        let (context, service, preferences, entry) = try makeFixture()
        let card = try XCTUnwrap(
            try service.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )
        try service.grade(card: card, rating: .good, preferences: preferences, now: referenceDate)

        try service.resetProgress(card: card, now: referenceDate)

        XCTAssertEqual(card.phase, .new)
        XCTAssertEqual(card.reps, 0)
        XCTAssertEqual(card.stability, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReviewLog>()), 1)
    }

    // MARK: - Sync outbox

    /// Local writes commit immediately and enqueue. Nothing in the UI awaits the network, which is
    /// the whole of the offline-first story.
    func testGradingEnqueuesOutboxRowsInOrder() throws {
        let (context, service, preferences, entry) = try makeFixture()
        let card = try XCTUnwrap(
            try service.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )
        try service.grade(card: card, rating: .good, preferences: preferences, now: referenceDate)

        let items = try context.fetch(
            FetchDescriptor<SyncOutboxItem>(sortBy: [SortDescriptor(\.sequence)])
        )
        XCTAssertTrue(items.contains { $0.operation == .reviewLogged })
        XCTAssertTrue(items.contains { $0.operation == .cardUpserted })
        XCTAssertEqual(
            items.map(\.sequence), items.map(\.sequence).sorted(),
            "the server must see changes in the order the user made them"
        )
        XCTAssertEqual(Set(items.map(\.sequence)).count, items.count, "sequences must be unique")
    }

    func testOutboxPayloadDecodesBackToWhatWasWritten() throws {
        let (context, service, preferences, entry) = try makeFixture()
        let card = try XCTUnwrap(
            try service.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )
        try service.grade(card: card, rating: .hard, preferences: preferences, now: referenceDate)

        let item = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SyncOutboxItem>())
                .first { $0.operation == .reviewLogged }
        )
        let payload = try JSONDecoder().decode(ReviewLogSyncPayload.self, from: item.payload)
        XCTAssertEqual(payload.rating, Rating.hard.rawValue)
        XCTAssertEqual(payload.cardID, card.cardID)
        XCTAssertEqual(payload.entryStableID, entry.stableID)
    }

    func testOutboxBackoffGrowsAndIsBounded() throws {
        let item = SyncOutboxItem(
            operation: .reviewLogged, subjectID: "x", payload: Data(), sequence: 1
        )
        var previousDelay: TimeInterval = 0
        var now = referenceDate

        for attempt in 1...12 {
            item.recordFailure("network unreachable", now: now)
            let delay = try XCTUnwrap(item.nextAttemptAfter).timeIntervalSince(now)
            XCTAssertGreaterThan(delay, 0)
            XCTAssertLessThanOrEqual(delay, 3_600, "backoff must be capped so it does not sleep for days")
            if attempt <= 10 {
                XCTAssertGreaterThanOrEqual(delay, previousDelay, "backoff must not shrink")
            }
            previousDelay = delay
            now = now.addingTimeInterval(delay)
        }
        XCTAssertEqual(item.attempts, 12)
        XCTAssertEqual(item.lastError, "network unreachable")
    }

    func testOutboxItemIsReadyOnlyAfterItsBackoff() {
        let item = SyncOutboxItem(
            operation: .reviewLogged, subjectID: "x", payload: Data(), sequence: 1
        )
        XCTAssertTrue(item.isReady(at: referenceDate), "a fresh item is ready immediately")

        item.recordFailure("boom", now: referenceDate)
        XCTAssertFalse(item.isReady(at: referenceDate))
        XCTAssertTrue(item.isReady(at: referenceDate.addingTimeInterval(3_600)))
    }
}
