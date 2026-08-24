import Foundation
import SwiftData
import Observation

/// Drives one review session.
///
/// Holds the queue, the current card, the reveal state and the timing. Everything that
/// touches storage goes through ``ReviewService``, so the session cannot advance a card
/// without logging it.
@MainActor
@Observable
final class StudyViewModel {
    enum Phase {
        case loading
        case reviewing
        case finished
    }

    var phase: Phase = .loading
    var isAnswerRevealed = false
    var errorMessage: String?

    /// Cards remaining, current first.
    private(set) var queue: [Card] = []
    private(set) var currentIndex = 0

    /// Interval each rating would produce, for the button labels. Recomputed when the card
    /// changes, not when it is revealed, so the reveal animation has no work to do.
    private(set) var previews: [Rating: SchedulingOutcome] = [:]

    // MARK: Session totals

    private(set) var reviewedCount = 0
    private(set) var correctCount = 0
    private(set) var ratingCounts: [Rating: Int] = [:]
    private(set) var startedAt = Date()
    private(set) var deferredCount = 0
    /// Total cards at the start, so the progress bar has a stable denominator even as cards
    /// are re-inserted by intraday steps.
    private(set) var plannedCount = 0

    private var revealedAt: Date?
    private var lastGraded: Card?

    /// Kept so the queue can be topped up on the same terms it was first built on.
    private var options = ReviewQueueBuilder.Options()

    /// How many times the queue has been topped up. Nothing on screen reads it — it exists so
    /// tests can assert that a finished batch actually refilled rather than merely failing to
    /// end, which are indistinguishable from the outside.
    private(set) var refillCount = 0

    /// `true` once the session has run out of due cards and started introducing new ones.
    private(set) var hasMovedPastDue = false

    var currentCard: Card? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    /// The user's daily goal, or `nil` when they have not set one.
    private(set) var goalTarget: Int?

    /// Reviews completed *today*, not this session — the number a daily goal is measured in.
    /// Seeded from the stored day on `start` so a second session does not restart the count.
    private(set) var reviewsToday = 0

    /// Progress toward the daily goal, or `nil` when there is no goal to progress toward.
    ///
    /// Optional rather than defaulting to zero, because with an endless queue there is no
    /// denominator to invent. The old `reviewedCount / plannedCount` measured progress through
    /// one *batch*, and now that batches refill silently that number would fill up and reset
    /// repeatedly — a progress bar that lies twice per session is worse than no bar at all.
    var goalProgress: Double? {
        guard let goalTarget, goalTarget > 0 else { return nil }
        return min(Double(reviewsToday) / Double(goalTarget), 1)
    }

    var accuracy: Double? {
        guard reviewedCount > 0 else { return nil }
        return Double(correctCount) / Double(reviewedCount)
    }

    var elapsedSeconds: Int { Int(Date().timeIntervalSince(startedAt)) }

    /// `true` when the previous card can be un-graded.
    var canUndo: Bool { lastGraded != nil }

    // MARK: - Loading

    func start(dependencies: AppDependencies, options: ReviewQueueBuilder.Options, now: Date = Date()) {
        guard let preferences = dependencies.preferences else {
            phase = .finished
            return
        }
        self.options = options
        goalTarget = preferences.dailyGoalTarget
        // `try?` flattens the nested optional (SE-0230), so this is `StudyDay?`, not
        // `StudyDay??`. `createIfMissing: false` because merely opening the study screen is
        // not activity — writing a row here would make an abandoned session look like a
        // studied day.
        reviewsToday = (try? dependencies.review.studyDay(
            for: now, preferences: preferences, createIfMissing: false
        ))?.reviewsCompleted ?? 0
        do {
            let built = try ReviewQueueBuilder().build(
                in: dependencies.context, at: now, options: options
            )
            deferredCount = built.deferredCount
            queue = try built.items.compactMap { try dependencies.context.card(cardID: $0.cardID) }
            plannedCount = queue.count
            currentIndex = 0
            startedAt = now
            refreshPreviews(preferences: preferences, now: now)
            // An empty queue here really is "nothing at all" — `build` already looked at both
            // the due pile and the new-word pool — so this one stays `.finished`.
            phase = queue.isEmpty ? .finished : .reviewing
        } catch {
            errorMessage = error.localizedDescription
            phase = .finished
        }
    }

    // MARK: - Reveal and grade

    func revealAnswer(now: Date = Date()) {
        guard !isAnswerRevealed else { return }
        isAnswerRevealed = true
        revealedAt = now
        Haptics.reveal()
    }

    func grade(_ rating: Rating, dependencies: AppDependencies, now: Date = Date()) {
        guard let card = currentCard, let preferences = dependencies.preferences else { return }

        // Measured from reveal, not from card display: time spent reading the answer is not
        // recall time, and only the recall attempt is a useful signal.
        let durationMS = revealedAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? 0

        do {
            let result = try dependencies.review.grade(
                card: card, rating: rating, preferences: preferences,
                durationMS: durationMS, now: now
            )
            reviewedCount += 1
            reviewsToday += 1
            if rating.isSuccess { correctCount += 1 }
            ratingCounts[rating, default: 0] += 1
            lastGraded = card
            Haptics.tap()

            advance(
                after: card, returnsThisSession: result.returnsThisSession,
                dependencies: dependencies, preferences: preferences, now: now
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Move to the next card, re-queuing the one just graded when its next step is minutes away.
    private func advance(
        after card: Card, returnsThisSession: Bool,
        dependencies: AppDependencies, preferences: StudyPreferences, now: Date
    ) {
        queue.remove(at: currentIndex)

        if returnsThisSession {
            // Re-insert a few positions back rather than at the end. Immediately is useless
            // (it tests short-term memory) and at the very end can be twenty minutes later,
            // by which point the learning step has expired anyway.
            let target = min(currentIndex + 3, queue.count)
            queue.insert(card, at: target)
            // The session genuinely got longer. Without this the counter reads "25/20" once
            // enough cards have come back, which looks like a bug rather than like the
            // consequence of pressing Again.
            plannedCount += 1
        }

        if currentIndex >= queue.count { currentIndex = 0 }
        isAnswerRevealed = false
        revealedAt = nil

        if queue.isEmpty {
            // The session does not end because a batch ran out. It ends when the *library* runs
            // out, which for almost everyone never happens.
            //
            // This is what "study as much as you like" actually requires. The obvious
            // implementation — lift the caps and let the queue pull unlimited cards — quietly
            // breaks FSRS, because its intervals are derived from reviews that happen near the
            // due date. Reviewing a card twelve days early and reporting "I remembered it" tells
            // the model you retained it for twelve days when you retained it for five minutes,
            // and stability gets over-estimated until the schedule collapses.
            //
            // Refilling keeps the caps and re-runs the same query. Due cards come first; when
            // they are gone the builder returns *new* cards, which have no due date and so
            // cannot distort anything. Unlimited study is therefore unlimited *introduction*,
            // which is both what was asked for and the only version of it that is safe.
            if refill(dependencies: dependencies, preferences: preferences, now: now) {
                refreshPreviews(preferences: preferences, now: now)
            } else {
                phase = .finished
                Haptics.success()
            }
        } else {
            refreshPreviews(preferences: preferences, now: now)
        }
    }

    /// Top the queue up in place. `false` only when the store has nothing left to offer.
    private func refill(
        dependencies: AppDependencies, preferences: StudyPreferences, now: Date
    ) -> Bool {
        do {
            let built = try ReviewQueueBuilder().build(
                in: dependencies.context, at: now, options: options
            )
            let alreadyQueued = Set(queue.map(\.cardID))
            let fresh = try built.items
                .filter { !alreadyQueued.contains($0.cardID) }
                .compactMap { try dependencies.context.card(cardID: $0.cardID) }
            guard !fresh.isEmpty else { return false }

            // Every card in the batch being unseen is what "the due pile is finished" looks
            // like from here. Latched, because a later batch mixing in a lapsed card should not
            // make the readout claim the backlog came back.
            if fresh.allSatisfy({ $0.phase == .new }) { hasMovedPastDue = true }

            queue.append(contentsOf: fresh)
            deferredCount = built.deferredCount
            refillCount += 1
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Un-grade the previous card and put it back in front.
    func undo(dependencies: AppDependencies) {
        guard let card = lastGraded, let preferences = dependencies.preferences else { return }
        do {
            try dependencies.review.undoLastReview(card: card, preferences: preferences)
            reviewedCount = max(0, reviewedCount - 1)
            reviewsToday = max(0, reviewsToday - 1)
            // Which rating to un-count is not recoverable from the card, so the totals are
            // rebuilt from what is left rather than guessed at.
            recomputeTotalsAfterUndo()
            queue.removeAll { $0.cardID == card.cardID }
            queue.insert(card, at: currentIndex)
            lastGraded = nil
            isAnswerRevealed = false
            revealedAt = nil
            phase = .reviewing
            refreshPreviews(preferences: preferences)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func recomputeTotalsAfterUndo() {
        let total = ratingCounts.values.reduce(0, +)
        guard total > reviewedCount else { return }
        // Remove one from the largest bucket — an approximation, and the honest one: the
        // alternative is storing a per-review undo stack for a control the user taps once.
        if let heaviest = ratingCounts.max(by: { $0.value < $1.value })?.key {
            ratingCounts[heaviest] = max(0, (ratingCounts[heaviest] ?? 1) - 1)
            if heaviest.isSuccess { correctCount = max(0, correctCount - 1) }
        }
    }

    // MARK: - Card controls

    func bury(dependencies: AppDependencies) {
        guard let card = currentCard, let preferences = dependencies.preferences else { return }
        try? dependencies.review.bury(card: card, preferences: preferences)
        skipCurrent(dependencies: dependencies, preferences: preferences)
    }

    func suspend(dependencies: AppDependencies) {
        guard let card = currentCard, let preferences = dependencies.preferences else { return }
        try? dependencies.review.setSuspended(true, card: card)
        skipCurrent(dependencies: dependencies, preferences: preferences)
    }

    func toggleFlag(dependencies: AppDependencies) {
        guard let card = currentCard else { return }
        try? dependencies.review.setFlagged(!card.isFlagged, card: card)
    }

    private func skipCurrent(
        dependencies: AppDependencies, preferences: StudyPreferences, now: Date = Date()
    ) {
        guard queue.indices.contains(currentIndex) else { return }
        queue.remove(at: currentIndex)
        if currentIndex >= queue.count { currentIndex = 0 }
        isAnswerRevealed = false
        revealedAt = nil
        if queue.isEmpty {
            // Burying or suspending the last card in a batch is not the end of the session
            // either — and previously it *was*, which meant putting one word aside could close
            // the screen on you.
            if refill(dependencies: dependencies, preferences: preferences, now: now) {
                refreshPreviews(preferences: preferences, now: now)
            } else {
                phase = .finished
            }
        } else {
            refreshPreviews(preferences: preferences)
        }
    }

    // MARK: - Previews

    private func refreshPreviews(preferences: StudyPreferences, now: Date = Date()) {
        guard let card = currentCard else {
            previews = [:]
            return
        }
        previews = preferences.makeScheduler().preview(
            state: card.schedulingState, at: now, fuzzSeed: card.fuzzSeed
        )
    }

    func intervalLabel(for rating: Rating) -> String {
        guard let outcome = previews[rating] else { return "" }
        return IntervalFormatter.short(days: outcome.intervalDays)
    }
}
