import Foundation
import SwiftData
import OSLog

/// Applies ratings to cards, and owns every write that a review implies.
///
/// A single review touches five things: the card's scheduling state, an append-only
/// ``ReviewLog`` row, the day's ``StudyDay`` rollup, the sync outbox, and — the first
/// time a word is answered — the ``DailyBatch`` acceptance record. Doing all of that
/// in one place, in one transaction, is what keeps statistics honest: there is no path
/// that advances a card without logging it.
@MainActor
public final class ReviewService {
    private let context: ModelContext
    private let logger = Logger(subsystem: "com.vocabloop.app", category: "review")

    public init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Enrolment

    /// Create the cards that make `entry` studiable, according to the user's enabled
    /// directions. Idempotent — re-enrolling a word is a no-op rather than a reset,
    /// which matters because the daily-word card can be tapped twice.
    @discardableResult
    public func enroll(
        entry: Entry,
        preferences: StudyPreferences,
        now: Date = Date()
    ) throws -> [Card] {
        var created: [Card] = []
        for direction in preferences.enabledDirections {
            let cardID = Card.makeCardID(entryStableID: entry.stableID, direction: direction)
            if try context.card(cardID: cardID) != nil { continue }

            let card = Card.make(
                for: entry, direction: direction,
                scheduler: preferences.scheduler, now: now
            )
            context.insert(card)
            card.entry = entry
            created.append(card)
            try enqueueSync(.cardUpserted, subjectID: cardID, payload: CardSyncPayload(card: card))
        }
        if !created.isEmpty {
            entry.touch(now)
            try context.save()
        }
        return created
    }

    /// Remove a word from study, keeping the dictionary entry and the review history.
    ///
    /// History is preserved deliberately: a user who un-enrols and later re-enrols a
    /// word should not have their past reviews vanish from statistics.
    public func unenroll(entry: Entry) throws {
        for card in entry.cards {
            context.delete(card)
        }
        try context.save()
    }

    // MARK: - Grading

    /// The result of a graded review, for the session UI.
    public struct GradeResult: Sendable {
        public var intervalDays: Double
        public var newPhase: LearningPhase
        /// `true` when the card will come back later in this same session.
        public var returnsThisSession: Bool
    }

    /// Grade one card.
    ///
    /// - Parameters:
    ///   - durationMS: Time from answer reveal to rating. Logged for statistics and,
    ///     later, as a signal that a `Good` was really a `Hard`.
    @discardableResult
    public func grade(
        card: Card,
        rating: Rating,
        preferences: StudyPreferences,
        durationMS: Int = 0,
        now: Date = Date()
    ) throws -> GradeResult {
        // A card graded under one algorithm and then under another keeps its state;
        // `schedulerRaw` records which produced the current values so the history stays
        // interpretable.
        let scheduler = preferences.makeScheduler()
        let stateBefore = card.schedulingState
        let outcome = scheduler.apply(
            rating: rating, to: stateBefore, at: now, fuzzSeed: card.fuzzSeed
        )

        card.schedulingState = outcome.state
        card.scheduler = scheduler.kind
        card.touch(now)

        let log = ReviewLog(
            cardID: card.cardID,
            entryStableID: card.entry?.stableID ?? "",
            languageCode: card.languageCode,
            direction: card.direction,
            reviewedAt: now,
            rating: rating,
            stateBefore: stateBefore,
            outcome: outcome,
            durationMS: durationMS,
            scheduler: scheduler.kind,
            parametersVersion: preferences.schedulerConfig.fsrsParameters.version
        )
        context.insert(log)
        log.card = card

        try recordActivity(
            rating: rating,
            wasIntroduction: stateBefore.phase == .new,
            durationMS: durationMS,
            preferences: preferences,
            now: now
        )

        try enqueueSync(.reviewLogged, subjectID: log.cardID, payload: ReviewLogSyncPayload(log: log))
        try enqueueSync(.cardUpserted, subjectID: card.cardID, payload: CardSyncPayload(card: card))
        try context.save()

        return GradeResult(
            intervalDays: outcome.intervalDays,
            newPhase: outcome.state.phase,
            // Intraday steps are short enough that the card genuinely reappears in the
            // same sitting; anything a day out does not.
            returnsThisSession: outcome.state.phase.isIntraday && outcome.intervalDays < 1
        )
    }

    /// Undo the most recent review of a card, restoring the state it had before.
    ///
    /// Reconstructed from the log rather than from an in-memory snapshot, so undo works
    /// after the app has been relaunched, and so it cannot disagree with the history.
    /// The log row is deleted — an undone review did not happen, and leaving it would
    /// corrupt accuracy statistics and any future weight optimisation.
    public func undoLastReview(card: Card, preferences: StudyPreferences) throws {
        guard let last = card.reviews.max(by: { $0.reviewedAt < $1.reviewedAt }) else { return }

        card.phase = last.phaseBefore
        card.stability = last.stabilityBefore
        card.difficulty = last.difficultyBefore
        card.intervalDays = last.scheduledDays
        card.reps = max(0, card.reps - 1)
        if last.rating == .again, last.phaseBefore == .review {
            card.lapses = max(0, card.lapses - 1)
        }
        // The previous review is what defined "last reviewed"; if there is none, this
        // was the introduction and the card returns to never-answered.
        let earlier = card.reviews
            .filter { $0.reviewedAt < last.reviewedAt }
            .max(by: { $0.reviewedAt < $1.reviewedAt })
        card.lastReviewedAt = earlier?.reviewedAt
        card.due = earlier.map { $0.reviewedAt.addingTimeInterval(last.scheduledDays * 86_400) }
            ?? last.reviewedAt

        if let day = try studyDay(for: last.reviewedAt, preferences: preferences, createIfMissing: false) {
            day.reviewsCompleted = max(0, day.reviewsCompleted - 1)
            if last.rating.isSuccess { day.correctCount = max(0, day.correctCount - 1) }
            if last.phaseBefore == .new { day.newCardsIntroduced = max(0, day.newCardsIntroduced - 1) }
        }

        context.delete(last)
        try context.save()
    }

    // MARK: - Daily rollup

    /// Update today's ``StudyDay``.
    ///
    /// `goalMet` is latched and never recomputed: changing the daily goal must not
    /// retroactively grant or revoke past days, or the streak becomes a lie.
    private func recordActivity(
        rating: Rating,
        wasIntroduction: Bool,
        durationMS: Int,
        preferences: StudyPreferences,
        now: Date
    ) throws {
        guard let day = try studyDay(for: now, preferences: preferences, createIfMissing: true) else { return }
        day.reviewsCompleted += 1
        if rating.isSuccess { day.correctCount += 1 }
        if wasIntroduction { day.newCardsIntroduced += 1 }
        // Cap a single card's contribution: a session left open on a locked phone
        // would otherwise report hours of study.
        day.studySeconds += min(durationMS / 1000, 120)
        if !day.goalMet, day.reviewsCompleted >= preferences.dailyGoal {
            day.goalMet = true
        }
    }

    func studyDay(
        for date: Date,
        preferences: StudyPreferences,
        createIfMissing: Bool
    ) throws -> StudyDay? {
        let account = try context.activeAccount()
        let calendar = StudyCalendar(preferences: preferences)
        let dayKey = calendar.dayKey(for: date)
        let key = StudyDay.makeKey(userID: account.userID, dayKey: dayKey)

        var descriptor = FetchDescriptor<StudyDay>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first { return existing }
        guard createIfMissing else { return nil }

        let day = StudyDay(
            userID: account.userID,
            dayKey: dayKey,
            dayStart: calendar.dayStart(for: date)
        )
        context.insert(day)
        return day
    }

    // MARK: - Card controls

    public func setSuspended(_ suspended: Bool, card: Card) throws {
        card.isSuspended = suspended
        card.touch()
        try context.save()
    }

    /// Hide a card until the next study day. Used by "not this one right now".
    public func bury(card: Card, preferences: StudyPreferences, now: Date = Date()) throws {
        card.buriedUntil = StudyCalendar(preferences: preferences).dayEnd(for: now)
        card.touch(now)
        try context.save()
    }

    public func setFlagged(_ flagged: Bool, card: Card) throws {
        card.isFlagged = flagged
        card.touch()
        try context.save()
    }

    /// Reset a card to never-answered, discarding its scheduling state but keeping its
    /// review history — the log is what a future optimiser trains on.
    public func resetProgress(card: Card, now: Date = Date()) throws {
        card.schedulingState = .newCard(due: now)
        card.touch(now)
        try context.save()
    }

    // MARK: - Sync

    private func enqueueSync(_ operation: SyncOperation, subjectID: String, payload: some Encodable) throws {
        // Sync failing must never fail a review. The local write has already happened;
        // a missing outbox row costs a delayed sync, not the user's session.
        do {
            let item = SyncOutboxItem(
                operation: operation,
                subjectID: subjectID,
                payload: try JSONEncoder().encode(payload),
                sequence: try context.nextOutboxSequence()
            )
            context.insert(item)
        } catch {
            logger.error("Could not enqueue \(operation.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
