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
        // `recordActivity` writes a StudyDay keyed by study day, so the rollup assertions in this
        // suite depend on a day boundary. Pinned, so they do not depend on the runner's timezone.
        pinToUTC(preferences)
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
    ///
    /// The review itself is *not* in the outbox: `ReviewLog` is append-only and carries `isSynced`,
    /// so it is its own queue. A second copy per graded card was the app's largest source of
    /// unbounded storage growth.
    func testGradingEnqueuesOutboxRowsInOrder() throws {
        let (context, service, preferences, entry) = try makeFixture()
        let card = try XCTUnwrap(
            try service.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )
        try service.grade(card: card, rating: .good, preferences: preferences, now: referenceDate)

        let items = try context.fetch(
            FetchDescriptor<SyncOutboxItem>(sortBy: [SortDescriptor(\.sequence)])
        )
        XCTAssertTrue(items.contains { $0.operation == .cardUpserted })
        XCTAssertFalse(
            items.contains { $0.operation == .reviewLogged },
            "a review is queued on ReviewLog.isSynced, not duplicated into the outbox"
        )
        XCTAssertEqual(
            items.map(\.sequence), items.map(\.sequence).sorted(),
            "the server must see changes in the order the user made them"
        )
        XCTAssertEqual(Set(items.map(\.sequence)).count, items.count, "sequences must be unique")

        // And the review is genuinely queued somewhere.
        let unsynced = try context.fetch(
            FetchDescriptor<ReviewLog>(predicate: #Predicate { !$0.isSynced })
        )
        XCTAssertEqual(unsynced.count, 1)
        XCTAssertEqual(unsynced.first?.cardID, card.cardID)
    }

    func testOutboxPayloadDecodesBackToWhatWasWritten() throws {
        let (context, service, preferences, entry) = try makeFixture()
        let card = try XCTUnwrap(
            try service.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )
        try service.grade(card: card, rating: .hard, preferences: preferences, now: referenceDate)

        let item = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SyncOutboxItem>())
                .first { $0.operation == .cardUpserted }
        )
        let payload = try JSONDecoder().decode(CardSyncPayload.self, from: item.payload)
        XCTAssertEqual(payload.cardID, card.cardID)

        // The review payload the server receives is built from the log, so check it there.
        let log = try XCTUnwrap(try context.fetch(FetchDescriptor<ReviewLog>()).first)
        let reviewPayload = ReviewLogSyncPayload(log: log)
        XCTAssertEqual(reviewPayload.rating, Rating.hard.rawValue)
        XCTAssertEqual(reviewPayload.cardID, card.cardID)
        XCTAssertEqual(reviewPayload.entryStableID, entry.stableID)
    }

    /// The outbox must be bounded by how much *state* exists, not by how much the user studies.
    ///
    /// This is the growth bug in one test. Grading the same card twenty times used to leave forty
    /// rows — twenty reviews and twenty card upserts — every one of them dead except the last card
    /// state, and none of them ever drained because the shipping build has no server. At a hundred
    /// reviews a day that was tens of thousands of rows in the first year.
    func testRepeatedGradingDoesNotGrowTheOutbox() throws {
        let (context, service, preferences, entry) = try makeFixture()
        let card = try XCTUnwrap(
            try service.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )

        var now = referenceDate
        for _ in 0..<20 {
            now = now.addingTimeInterval(600)
            try service.grade(card: card, rating: .good, preferences: preferences, now: now)
        }

        let items = try context.fetch(FetchDescriptor<SyncOutboxItem>())
        XCTAssertEqual(
            items.count, 1,
            "one card has one current state: \(items.map { "\($0.operation?.rawValue ?? "?"):\($0.subjectID)" })"
        )
        XCTAssertEqual(items.first?.operation, .cardUpserted)

        // The reviews themselves are all still there — they are the history, and losing one would
        // corrupt what a future weight fit trains on.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReviewLog>()), 20)
    }

    /// Un-enrolling must not leave the server told to upsert a card that no longer exists.
    ///
    /// The pending row outlived the card it described, so the first successful sync would have
    /// pushed the state of a deleted card — and the next pull would have handed it straight back.
    /// A word removed from study would reappear.
    func testUnenrollingDropsThePendingUpsertForTheDeletedCards() throws {
        let (context, service, preferences, entry) = try makeFixture()
        preferences.enabledDirections = [.recognition, .production]
        let created = try service.enroll(entry: entry, preferences: preferences, now: referenceDate)
        XCTAssertEqual(created.count, 2)
        let cardIDs = created.map(\.cardID)

        try service.grade(
            card: try XCTUnwrap(created.first), rating: .good,
            preferences: preferences, now: referenceDate
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<SyncOutboxItem>())
                .filter { cardIDs.contains($0.subjectID) }.count,
            2, "both cards are queued before un-enrolling"
        )

        try service.unenroll(entry: entry)

        let leftovers = try context.fetch(FetchDescriptor<SyncOutboxItem>())
            .filter { cardIDs.contains($0.subjectID) }
        XCTAssertTrue(
            leftovers.isEmpty,
            "queued state for a deleted card would resurrect it: \(leftovers.map(\.subjectID))"
        )
        XCTAssertTrue(entry.cards.isEmpty)

        // The history stays. `unenroll` promises it in words, `ReviewLog.cardID` is denormalised
        // "so logs survive card deletion", and the log is what a future weight fit trains on — but
        // `Card.reviews` was `.cascade`, so removing a word from study silently destroyed all three.
        // The only symptom would have been an accuracy figure that quietly changed.
        let survivors = try context.fetch(FetchDescriptor<ReviewLog>())
        XCTAssertEqual(survivors.count, 1, "un-enrolling must not delete the review history")

        // Orphaned but complete: everything a consumer reads is on the row itself, which is the
        // whole reason those fields are denormalised.
        let log = try XCTUnwrap(survivors.first)
        XCTAssertNil(log.card, "the card is gone, so the relationship is nullified")
        XCTAssertEqual(log.cardID, cardIDs.first)
        XCTAssertEqual(log.entryStableID, entry.stableID)
        XCTAssertFalse(log.languageCode.isEmpty)
    }

    /// Every card mutation must reach the queue, not just grading.
    ///
    /// Suspending, flagging, burying, resetting and undoing all change a card, and none of them
    /// enqueued anything — so on a device with sync on, pausing a word would have been a purely
    /// local edit that the next push overwrote. Cheap to fix only because upserts now replace: one
    /// card stays one row however many times it changes.
    func testEveryCardMutationQueuesTheNewState() throws {
        let (context, service, preferences, entry) = try makeFixture()
        let card = try XCTUnwrap(
            try service.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )

        func queuedState() throws -> CardSyncPayload {
            let item = try XCTUnwrap(
                try context.fetch(FetchDescriptor<SyncOutboxItem>())
                    .first { $0.subjectID == card.cardID && $0.operation == .cardUpserted },
                "nothing queued for this card"
            )
            return try JSONDecoder().decode(CardSyncPayload.self, from: item.payload)
        }

        try service.setSuspended(true, card: card)
        XCTAssertTrue(try queuedState().isSuspended, "a suspend must be visible to the server")

        try service.setSuspended(false, for: entry)
        XCTAssertFalse(try queuedState().isSuspended)

        try service.setFlagged(true, card: card)
        XCTAssertTrue(try queuedState().isFlagged)

        try service.grade(card: card, rating: .easy, preferences: preferences, now: referenceDate)
        XCTAssertGreaterThan(try queuedState().reps, 0)

        try service.undoLastReview(card: card, preferences: preferences)
        XCTAssertEqual(try queuedState().reps, 0, "an undo must not be a purely local edit")

        try service.resetProgress(for: entry, now: referenceDate)
        XCTAssertEqual(try queuedState().phase, LearningPhase.new.rawValue)

        // Six mutations, still one row.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncOutboxItem>()), 1)
    }

    /// The replacement must carry the *latest* card state, not the first.
    func testTheSurvivingCardRowHoldsTheLatestState() throws {
        let (context, service, preferences, entry) = try makeFixture()
        let card = try XCTUnwrap(
            try service.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )

        try service.grade(card: card, rating: .easy, preferences: preferences, now: referenceDate)
        let later = referenceDate.addingTimeInterval(30 * 86_400)
        try service.grade(card: card, rating: .easy, preferences: preferences, now: later)

        let item = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SyncOutboxItem>())
                .first { $0.operation == .cardUpserted }
        )
        let payload = try JSONDecoder().decode(CardSyncPayload.self, from: item.payload)
        XCTAssertEqual(payload.intervalDays, card.intervalDays, accuracy: 1e-9)
        XCTAssertEqual(payload.reps, card.reps)
        XCTAssertEqual(card.reps, 2)
    }

    /// Replacing must not reorder the queue.
    func testReplacedCardRowKeepsItsQueuePosition() throws {
        let (context, service, preferences, entry) = try makeFixture()
        let card = try XCTUnwrap(
            try service.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )
        let firstSequence = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SyncOutboxItem>()).first?.sequence
        )

        // A later, unrelated write, so there is somewhere for the card row to jump to.
        let other = try TestStore.makeEntry(in: context, headword: "unrelated")
        try service.enroll(entry: other, preferences: preferences, now: referenceDate)

        try service.grade(card: card, rating: .good, preferences: preferences, now: referenceDate)

        let item = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SyncOutboxItem>())
                .first { $0.subjectID == card.cardID }
        )
        XCTAssertEqual(
            item.sequence, firstSequence,
            "the row must stay where it was queued, or the server sees the changes out of order"
        )
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
