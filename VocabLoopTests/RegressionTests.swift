import XCTest
import SwiftData
@testable import VocabLoop

/// One test per bug found by review rather than by a failing test.
///
/// Each of these was reachable in normal use and none of them would have crashed — they would
/// have shown a wrong number, or quietly grown the database. That is exactly the class of
/// defect a test suite has to carry, because nothing else will catch it twice.
@MainActor
final class RegressionTests: XCTestCase {

    // MARK: - Outbox growth from a slider drag

    /// Preferences are last-write-wins, so a pending row must be *replaced*, not appended to.
    ///
    /// The retention slider saves on every tick. Dragging it across its range at 1% steps
    /// called `enqueuePreferences` 27 times, leaving 27 rows each holding a full payload.
    func testRepeatedPreferenceSavesReplaceTheirOutboxRowInsteadOfAppending() throws {
        let context = try TestStore.makeContext()
        let account = try context.activeAccount()
        let preferences = try XCTUnwrap(account.preferences)

        let engine = SyncEngine(
            context: context,
            client: APIClient(configuration: .offline),
            monitor: NetworkMonitor(),
            isServerConfigured: false
        )

        // Simulate the drag.
        for percent in stride(from: 0.70, through: 0.97, by: 0.01) {
            preferences.desiredRetention = (percent * 100).rounded() / 100
            engine.enqueuePreferences(preferences)
        }

        let rows = try context.fetch(
            FetchDescriptor<SyncOutboxItem>(
                predicate: #Predicate { $0.subjectID == "preferences" }
            )
        )
        XCTAssertEqual(rows.count, 1, "28 saves left \(rows.count) rows; they must collapse to one")

        // And the surviving row must hold the *last* value, not the first.
        let payload = try JSONDecoder().decode(PreferencesSyncPayload.self, from: rows[0].payload)
        XCTAssertEqual(payload.desiredRetention, 0.97, accuracy: 1e-9)
    }

    /// Replacing must not reorder the queue: the server needs the change where the user made
    /// it, not jumped to the end.
    func testReplacedPreferencesKeepTheirOriginalQueuePosition() throws {
        let context = try TestStore.makeContext()
        let account = try context.activeAccount()
        let preferences = try XCTUnwrap(account.preferences)
        let engine = SyncEngine(
            context: context, client: APIClient(configuration: .offline),
            monitor: NetworkMonitor(), isServerConfigured: false
        )

        engine.enqueuePreferences(preferences)
        let firstSequence = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SyncOutboxItem>()).first?.sequence
        )

        // A later, unrelated write.
        let entry = try TestStore.makeEntry(in: context, headword: "alpha")
        try ReviewService(context: context).enroll(entry: entry, preferences: preferences)

        preferences.dailyGoal = 99
        engine.enqueuePreferences(preferences)

        let preferenceRows = try context.fetch(
            FetchDescriptor<SyncOutboxItem>(predicate: #Predicate { $0.subjectID == "preferences" })
        )
        XCTAssertEqual(preferenceRows.count, 1)
        XCTAssertEqual(
            preferenceRows[0].sequence, firstSequence,
            "the row must stay where it was queued"
        )
    }

    // MARK: - Operations the push endpoint cannot carry

    /// Every ``SyncOperation`` must be either pushable or deliberately excluded.
    ///
    /// `sync` deletes a whole batch once the server accepts it, so an operation that
    /// `buildRequest` does not put on the wire but `readyBatch` hands over would be discarded
    /// by a request that never mentioned it — silent data loss on the first successful sync.
    /// This test is what makes adding a case to the enum a decision rather than an oversight.
    func testEveryOperationIsEitherPushableOrKnowinglyExcluded() {
        // `.reviewLogged` is excluded because reviews travel on `ReviewLog.isSynced` instead; the
        // other three are waiting for their own endpoints.
        let excluded: Set<SyncOperation> = [
            .reviewLogged, .deckUpserted, .deckDeleted, .accountDeleted,
        ]
        XCTAssertEqual(
            SyncEngine.pushableOperations.union(excluded),
            Set(SyncOperation.allCases),
            "a new SyncOperation must be added to pushableOperations or to this list"
        )
        XCTAssertTrue(
            SyncEngine.pushableOperations.isDisjoint(with: excluded),
            "an operation cannot be both pushable and excluded"
        )
    }

    /// `readyBatch` must not hand over a row the request cannot represent.
    ///
    /// `sync` deletes every item in the batch once the server accepts it, and an all-excluded
    /// batch produces an *empty* request — which "succeeds" trivially and then drains rows that
    /// were never sent. So the guard has to be at selection time, and that is what is asserted.
    func testReadyBatchSkipsOperationsThePushRequestCannotCarry() throws {
        let context = try TestStore.makeContext()
        _ = try context.activeAccount()

        // Excluded rows first, so they would fill a batch that applied its limit before
        // filtering and stall the sendable row behind them.
        var sequence = 0
        for operation in [SyncOperation.deckUpserted, .deckDeleted, .accountDeleted] {
            context.insert(SyncOutboxItem(
                operation: operation, subjectID: "subject-\(sequence)",
                payload: Data("{}".utf8), sequence: sequence
            ))
            sequence += 1
        }
        context.insert(SyncOutboxItem(
            operation: .cardUpserted, subjectID: "card-1",
            payload: Data("{}".utf8), sequence: sequence
        ))
        try context.save()

        let engine = SyncEngine(
            context: context, client: APIClient(configuration: .offline),
            monitor: NetworkMonitor(), isServerConfigured: false
        )
        XCTAssertEqual(engine.pendingCount(), 4, "all four rows are recorded")

        let batch = try engine.readyBatch()
        XCTAssertEqual(batch.map(\.subjectID), ["card-1"], "only the sendable row may be drained")
    }

    /// An outbox row carrying a review is a leftover from a build that queued them there.
    ///
    /// It must be *skipped*, not drained: `sync` deletes a batch once the server accepts it, and a
    /// review deleted by a request that never mentioned it is gone from the history a future weight
    /// fit trains on. Reviews now travel via `ReviewLog.isSynced`.
    func testALeftoverReviewRowIsNotDrainedByTheOutbox() throws {
        let context = try TestStore.makeContext()
        _ = try context.activeAccount()
        context.insert(SyncOutboxItem(
            operation: .reviewLogged, subjectID: "review-1",
            payload: Data("{}".utf8), sequence: 0
        ))
        try context.save()

        let engine = SyncEngine(
            context: context, client: APIClient(configuration: .offline),
            monitor: NetworkMonitor(), isServerConfigured: false
        )
        XCTAssertTrue(
            try engine.readyBatch().isEmpty,
            "reviewLogged is not a pushable outbox operation any more"
        )
        XCTAssertEqual(engine.pendingCount(), 1, "but it is still counted as pending, not hidden")
    }

    /// Reviews are queued on the log, and `unsyncedReviews` is what finds them.
    func testUnsyncedReviewsAreFoundOldestFirstAndMarkableAsSent() throws {
        let context = try TestStore.makeContext()
        let account = try context.activeAccount()
        let preferences = try XCTUnwrap(account.preferences)
        let review = ReviewService(context: context)
        let entry = try TestStore.makeEntry(in: context, headword: "queued")
        let card = try XCTUnwrap(
            try review.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )

        var now = referenceDate
        for _ in 0..<3 {
            now = now.addingTimeInterval(600)
            try review.grade(card: card, rating: .good, preferences: preferences, now: now)
        }

        let engine = SyncEngine(
            context: context, client: APIClient(configuration: .offline),
            monitor: NetworkMonitor(), isServerConfigured: false
        )
        let unsynced = try engine.unsyncedReviews()
        XCTAssertEqual(unsynced.count, 3)
        XCTAssertEqual(
            unsynced.map(\.reviewedAt), unsynced.map(\.reviewedAt).sorted(),
            "the server must see reviews in the order they happened"
        )

        // Marking them sent takes them out of the queue without touching the history.
        for log in unsynced { log.isSynced = true }
        try context.save()
        XCTAssertTrue(try engine.unsyncedReviews().isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReviewLog>()), 3, "history is kept")
    }

    /// "Discard pending" must actually clear the number Settings shows.
    ///
    /// Reviews are marked sent rather than deleted — the user asked to stop *sending*, not to erase
    /// their history — but if they stayed unsynced the count would not budge and the escape hatch
    /// would look broken.
    func testDiscardPendingClearsBothQueuesButKeepsTheHistory() throws {
        let context = try TestStore.makeContext()
        let account = try context.activeAccount()
        let preferences = try XCTUnwrap(account.preferences)
        let review = ReviewService(context: context)
        let entry = try TestStore.makeEntry(in: context, headword: "discarded")
        let card = try XCTUnwrap(
            try review.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )
        try review.grade(card: card, rating: .good, preferences: preferences, now: referenceDate)

        let engine = SyncEngine(
            context: context, client: APIClient(configuration: .offline),
            monitor: NetworkMonitor(), isServerConfigured: false
        )
        XCTAssertGreaterThan(engine.pendingCount(), 0)

        engine.discardPending()
        XCTAssertEqual(engine.pendingCount(), 0)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<ReviewLog>()), 1,
            "discarding a send must not erase the review"
        )
    }

    // MARK: - New-card count after accepting a daily word

    /// `enabledDirections.count` is not the number of cards created: cloze is skipped for an
    /// entry with no maskable example. Assuming it overstated the count on the Today tile.
    func testAcceptReportsCardsActuallyCreatedNotEnabledDirections() throws {
        let context = try TestStore.makeContext()
        let account = try context.activeAccount()
        let preferences = try XCTUnwrap(account.preferences)
        preferences.enabledDirections = [.recognition, .production, .cloze]

        let daily = DailyWordService(context: context)
        let review = ReviewService(context: context)

        // No examples, so cloze cannot be built — 2 cards, not 3.
        let unmaskable = try TestStore.makeEntry(in: context, headword: "unexampled")
        let batch = DailyBatch(
            userID: account.userID, dayKey: "2025-03-15", languageCode: "en",
            entryStableIDs: [unmaskable.stableID]
        )
        context.insert(batch)
        try context.save()

        let created = try daily.accept(
            entry: unmaskable, in: batch, preferences: preferences, reviewService: review
        )
        XCTAssertEqual(created.count, 2)
        XCTAssertNotEqual(
            created.count, preferences.enabledDirections.count,
            "this fixture exists precisely because the two differ"
        )

        // Re-accepting creates nothing, so a caller adding blindly would double-count.
        let again = try daily.accept(
            entry: unmaskable, in: batch, preferences: preferences, reviewService: review
        )
        XCTAssertTrue(again.isEmpty)
    }

    // MARK: - Session counter when a card comes back

    /// Pressing Again re-queues the card, so the session really is longer. Without growing the
    /// denominator the header read "25/20", which looks like a bug rather than a consequence.
    func testSessionDenominatorGrowsWhenACardIsRequeued() throws {
        // The real object graph rather than a bare context: `StudyViewModel.start` reads
        // `dependencies.preferences` and grades through `dependencies.review`, so a fixture
        // built on a separate context would not be the one the session sees. `dependencies.context`
        // *is* the container's `mainContext`, so the cards written below are the cards queued.
        let container = try PersistenceController.makeInMemoryContainer()
        let dependencies = AppDependencies(container: container)
        let context = dependencies.context

        _ = try context.activeAccount()

        // Three separate words, so a re-queued card has somewhere to go.
        for index in 0..<3 {
            let entry = try TestStore.makeEntry(
                in: context, headword: "word\(index)", frequencyRank: index
            )
            try TestStore.makeCard(
                in: context, for: entry, phase: .new, due: referenceDate, intervalDays: 0
            )
        }

        let model = StudyViewModel()
        model.start(
            dependencies: dependencies,
            options: .init(maxNewCards: 3, languageCode: "en"),
            now: referenceDate
        )
        XCTAssertEqual(model.plannedCount, 3, "all three new cards should be queued")
        let planned = model.plannedCount

        model.revealAnswer(now: referenceDate)
        model.grade(.again, dependencies: dependencies, now: referenceDate)

        XCTAssertEqual(model.plannedCount, planned + 1, "Again re-queues, so the session is longer")
        XCTAssertEqual(model.reviewedCount, 1)
        // No goal set in these preferences, so there is nothing to show progress against. This
        // is the endless-queue contract: a session without a daily goal has no denominator, and
        // the bar is absent rather than stuck at zero.
        XCTAssertNil(model.goalProgress, "no daily goal means no progress bar")
    }

    /// Progress is a ratio shown as a bar, so it must stay in `0...1` no matter how many
    /// reviews a day accumulates — and must be absent entirely when no goal is set.
    func testProgressIsAbsentWithoutAGoalAndClampedWithOne() throws {
        let model = StudyViewModel()
        XCTAssertNil(model.goalProgress, "an unstarted session has no goal and so no progress")
        XCTAssertNil(model.accuracy, "accuracy is unknown before the first answer, not 0%")
    }

    /// A daily goal that has been exceeded must not overfill the bar.
    ///
    /// Easy to reach now that the queue never ends: a goal of two and an evening of study puts
    /// `reviewsToday` well past it, and an unclamped ratio would draw the capsule off the edge
    /// of the screen.
    func testProgressClampsWhenTheGoalIsExceeded() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let dependencies = AppDependencies(container: container)
        let context = dependencies.context
        _ = try context.activeAccount()
        let preferences = try XCTUnwrap(dependencies.preferences)
        preferences.dailyGoal = 2

        for index in 0..<6 {
            let entry = try TestStore.makeEntry(
                in: context, headword: "over\(index)", frequencyRank: index
            )
            try TestStore.makeCard(
                in: context, for: entry, phase: .new, due: referenceDate, intervalDays: 0
            )
        }

        let model = StudyViewModel()
        model.start(
            dependencies: dependencies,
            options: .init(maxNewCards: 6, languageCode: "en"),
            now: referenceDate
        )
        XCTAssertEqual(model.goalTarget, 2, "a goal above zero is a real target")

        for _ in 0..<5 {
            model.revealAnswer(now: referenceDate)
            model.grade(.good, dependencies: dependencies, now: referenceDate)
        }

        let progress = try XCTUnwrap(model.goalProgress)
        XCTAssertEqual(progress, 1.0, "five reviews against a goal of two is still a full bar")
    }

    /// `0` is the sentinel for "no goal", and it must never latch `goalMet`.
    ///
    /// Without the guard in `recordActivity`, `reviewsCompleted >= 0` is true on the very first
    /// review of every day, and the app would congratulate people for a target they declined.
    func testNoGoalNeverCountsAsMet() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let dependencies = AppDependencies(container: container)
        let context = dependencies.context
        _ = try context.activeAccount()
        let preferences = try XCTUnwrap(dependencies.preferences)
        XCTAssertEqual(preferences.dailyGoal, 0, "a fresh install starts with no goal")
        XCTAssertNil(preferences.dailyGoalTarget)

        let entry = try TestStore.makeEntry(in: context, headword: "nogoal", frequencyRank: 1)
        try TestStore.makeCard(
            in: context, for: entry, phase: .new, due: referenceDate, intervalDays: 0
        )

        let model = StudyViewModel()
        model.start(
            dependencies: dependencies,
            options: .init(maxNewCards: 1, languageCode: "en"),
            now: referenceDate
        )
        model.revealAnswer(now: referenceDate)
        model.grade(.good, dependencies: dependencies, now: referenceDate)

        let day = try XCTUnwrap(
            try dependencies.review.studyDay(
                for: referenceDate, preferences: preferences, createIfMissing: false
            )
        )
        XCTAssertEqual(day.reviewsCompleted, 1)
        XCTAssertFalse(day.goalMet, "no goal set means no goal met")
    }

    // MARK: - Daily goal

    /// Meeting the goal stops to celebrate — once — and "keep going" resumes the same queue.
    ///
    /// Reported as "34 / 30": the session sailed past the goal with no acknowledgement at all.
    func testReachingTheGoalCelebratesOnceAndCanContinue() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let dependencies = AppDependencies(container: container)
        let context = dependencies.context
        _ = try context.activeAccount()
        let preferences = try XCTUnwrap(dependencies.preferences)
        preferences.dailyGoal = 2

        for index in 0..<5 {
            let entry = try TestStore.makeEntry(in: context, headword: "goal\(index)", frequencyRank: index)
            try TestStore.makeCard(in: context, for: entry, phase: .new, due: referenceDate, intervalDays: 0)
        }

        let model = StudyViewModel()
        model.start(dependencies: dependencies, options: .init(maxNewCards: 5, languageCode: "en"), now: referenceDate)

        model.revealAnswer(now: referenceDate)
        model.grade(.easy, dependencies: dependencies, now: referenceDate)
        XCTAssertEqual(model.phase, .reviewing, "one short of the goal")
        XCTAssertFalse(model.isGoalMet)

        model.revealAnswer(now: referenceDate)
        model.grade(.easy, dependencies: dependencies, now: referenceDate)
        XCTAssertEqual(model.phase, .goalReached, "the card that meets the goal stops to say so")
        XCTAssertTrue(model.isGoalMet)

        let remaining = model.queue.count
        model.continueAfterGoal()
        XCTAssertEqual(model.phase, .reviewing)
        XCTAssertEqual(model.queue.count, remaining, "keep going resumes the same queue")

        model.revealAnswer(now: referenceDate)
        model.grade(.easy, dependencies: dependencies, now: referenceDate)
        XCTAssertEqual(model.phase, .reviewing, "past the goal, no second interruption")
    }

    /// A session opened after the goal is already met must not celebrate it again.
    func testGoalAlreadyMetDoesNotCelebrateAgain() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let dependencies = AppDependencies(container: container)
        let context = dependencies.context
        _ = try context.activeAccount()
        let preferences = try XCTUnwrap(dependencies.preferences)
        preferences.dailyGoal = 1

        for index in 0..<3 {
            let entry = try TestStore.makeEntry(in: context, headword: "again\(index)", frequencyRank: index)
            try TestStore.makeCard(in: context, for: entry, phase: .new, due: referenceDate, intervalDays: 0)
        }

        let first = StudyViewModel()
        first.start(dependencies: dependencies, options: .init(maxNewCards: 3, languageCode: "en"), now: referenceDate)
        first.revealAnswer(now: referenceDate)
        first.grade(.easy, dependencies: dependencies, now: referenceDate)
        XCTAssertEqual(first.phase, .goalReached)

        let second = StudyViewModel()
        second.start(dependencies: dependencies, options: .init(maxNewCards: 3, languageCode: "en"), now: referenceDate)
        XCTAssertTrue(second.isGoalMet, "today's count carries over between sessions")
        second.revealAnswer(now: referenceDate)
        second.grade(.easy, dependencies: dependencies, now: referenceDate)
        XCTAssertEqual(second.phase, .reviewing)
    }

    // MARK: - The queue does not end

    /// Finishing a batch must top the queue up, not close the session.
    ///
    /// This is the whole "study as much as you like" contract. `maxNewCards: 2` used to be a
    /// session cap; it is now a batch size, so grading both cards should pull the next two
    /// rather than reaching `.finished` with four words still unseen.
    func testExhaustingABatchRefillsInsteadOfFinishing() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let dependencies = AppDependencies(container: container)
        let context = dependencies.context
        _ = try context.activeAccount()

        for index in 0..<6 {
            let entry = try TestStore.makeEntry(
                in: context, headword: "endless\(index)", frequencyRank: index
            )
            try TestStore.makeCard(
                in: context, for: entry, phase: .new, due: referenceDate, intervalDays: 0
            )
        }

        let model = StudyViewModel()
        model.start(
            dependencies: dependencies,
            options: .init(maxNewCards: 2, languageCode: "en"),
            now: referenceDate
        )
        XCTAssertEqual(model.queue.count, 2, "one batch, not the whole library")

        // Grade both cards of the first batch. `.easy` so neither is re-queued as a learning
        // step, which would refill the queue for the wrong reason.
        for _ in 0..<2 {
            model.revealAnswer(now: referenceDate)
            model.grade(.easy, dependencies: dependencies, now: referenceDate)
        }

        XCTAssertEqual(model.phase, .reviewing, "a finished batch is not a finished session")
        XCTAssertFalse(model.queue.isEmpty, "the queue refilled")
        XCTAssertGreaterThan(model.refillCount, 0)
        XCTAssertTrue(model.hasMovedPastDue, "a batch of only new cards means the due pile is done")
    }

    /// The session still ends when the library genuinely runs out.
    ///
    /// The counterpart to the test above: refilling must not become an infinite loop that keeps
    /// a session open with nothing in it.
    func testSessionFinishesWhenNothingIsLeft() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let dependencies = AppDependencies(container: container)
        let context = dependencies.context
        _ = try context.activeAccount()

        let entry = try TestStore.makeEntry(in: context, headword: "onlyone", frequencyRank: 1)
        try TestStore.makeCard(
            in: context, for: entry, phase: .new, due: referenceDate, intervalDays: 0
        )

        let model = StudyViewModel()
        model.start(
            dependencies: dependencies,
            options: .init(maxNewCards: 4, languageCode: "en"),
            now: referenceDate
        )
        XCTAssertEqual(model.queue.count, 1)

        model.revealAnswer(now: referenceDate)
        model.grade(.easy, dependencies: dependencies, now: referenceDate)

        XCTAssertEqual(model.phase, .finished, "one card and nothing else really is the end")
        XCTAssertTrue(model.queue.isEmpty)
    }

    /// A fresh install must open onto a card, not onto "Nothing to study".
    ///
    /// Reported from a device: the bundled library had thousands of words, none of them
    /// enrolled, and the queue only ever drew enrolled cards — so the first screen was empty and
    /// its Done button re-ran the same empty query. The session now starts the most common words
    /// itself, in frequency order.
    func testFreshInstallIntroducesWordsInsteadOfFinishing() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let dependencies = AppDependencies(container: container)
        let context = dependencies.context
        _ = try context.activeAccount()

        for index in 0..<20 {
            _ = try TestStore.makeEntry(
                in: context, headword: "bundled\(index)", frequencyRank: 20 - index
            )
        }

        let model = StudyViewModel()
        model.start(dependencies: dependencies, options: .init(), now: referenceDate)

        XCTAssertEqual(model.phase, .reviewing, "opens onto a card")
        XCTAssertEqual(model.currentCard?.entry?.headword, "bundled19", "most frequent word first")
        let enrolled = try context.fetch(FetchDescriptor<Entry>()).filter(\.isEnrolled)
        XCTAssertEqual(enrolled.count, StudyViewModel.introductionBatchSize, "a small batch, not the dictionary")
    }

    /// Running out of the user's own words continues into unstarted ones.
    func testExhaustingEnrolledCardsIntroducesMoreWords() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let dependencies = AppDependencies(container: container)
        let context = dependencies.context
        _ = try context.activeAccount()

        let own = try TestStore.makeEntry(in: context, headword: "own", frequencyRank: 1)
        try TestStore.makeCard(in: context, for: own, phase: .new, due: referenceDate, intervalDays: 0)
        _ = try TestStore.makeEntry(in: context, headword: "waiting", frequencyRank: 2)

        let model = StudyViewModel()
        model.start(dependencies: dependencies, options: .init(), now: referenceDate)
        model.revealAnswer(now: referenceDate)
        model.grade(.easy, dependencies: dependencies, now: referenceDate)

        XCTAssertEqual(model.phase, .reviewing)
        XCTAssertEqual(model.currentCard?.entry?.headword, "waiting")
    }

    // MARK: - Pausing and resuming a whole word

    /// Resuming a word must unsuspend *all* of its cards.
    ///
    /// The bug was a loop at the call site: "is this word paused?" is derived from the cards, so
    /// unsuspending the first one made the condition false and the loop suspended the second one
    /// instead. A word with two directions could not be resumed at all — it just swapped which
    /// card was paused.
    func testResumingAWordUnsuspendsEveryOneOfItsCards() throws {
        let context = try TestStore.makeContext()
        _ = try context.activeAccount()
        let review = ReviewService(context: context)

        let entry = try TestStore.makeEntry(in: context, headword: "reversible")
        for direction in [CardDirection.recognition, .production] {
            let card = try TestStore.makeCard(
                in: context, for: entry, direction: direction, due: referenceDate
            )
            card.isSuspended = true
        }
        try context.save()
        XCTAssertEqual(entry.cards.count, 2)
        XCTAssertTrue(entry.cards.allSatisfy(\.isSuspended), "the fixture starts fully paused")

        try review.setSuspended(false, for: entry)
        XCTAssertTrue(
            entry.cards.allSatisfy { !$0.isSuspended },
            "every card must resume, not just the first"
        )

        // And the other direction, which never had the bug — the target only flips while resuming.
        try review.setSuspended(true, for: entry)
        XCTAssertTrue(entry.cards.allSatisfy(\.isSuspended))
    }

    /// Resetting a word resets every card, and keeps the review log.
    func testResettingAWordResetsEveryOneOfItsCards() throws {
        let context = try TestStore.makeContext()
        _ = try context.activeAccount()
        let review = ReviewService(context: context)

        let entry = try TestStore.makeEntry(in: context, headword: "recoverable")
        for direction in [CardDirection.recognition, .production] {
            try TestStore.makeCard(
                in: context, for: entry, direction: direction,
                phase: .review, due: referenceDate, intervalDays: 40, stability: 40
            )
        }
        try context.save()

        try review.resetProgress(for: entry, now: referenceDate)
        for card in entry.cards {
            XCTAssertEqual(card.phase, .new, "\(card.direction) was left scheduled")
            XCTAssertEqual(card.intervalDays, 0, accuracy: 1e-9)
        }
    }

    // MARK: - HTTPS enforcement

    /// A bearer token must never leave the device in clear text because someone pointed the
    /// app at a local http server.
    ///
    /// The predicate is tested rather than the initialiser: constructing a rejected
    /// configuration trips `assertionFailure`, which aborts the whole test run.
    func testOnlyHTTPSBaseURLsAreAcceptable() {
        XCTAssertTrue(APIConfiguration.isTransportAcceptable(nil), "no server is the shipping default")
        XCTAssertTrue(APIConfiguration.isTransportAcceptable(URL(string: "https://api.example.com")))
        XCTAssertTrue(APIConfiguration.isTransportAcceptable(URL(string: "HTTPS://api.example.com")))

        for rejected in ["http://api.example.com", "http://localhost:8080", "ws://api.example.com",
                         "file:///tmp/x", "ftp://example.com"] {
            XCTAssertFalse(
                APIConfiguration.isTransportAcceptable(URL(string: rejected)),
                "\(rejected) must be refused"
            )
        }

        XCTAssertNil(APIConfiguration.offline.baseURL, "the shipping default must have no server")
        XCTAssertNotNil(
            APIConfiguration(baseURL: URL(string: "https://api.example.com")).baseURL,
            "a valid https URL must survive the initialiser"
        )
    }
}
