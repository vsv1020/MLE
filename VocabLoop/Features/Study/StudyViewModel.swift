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

    var currentCard: Card? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    var progress: Double {
        guard plannedCount > 0 else { return 0 }
        return min(Double(reviewedCount) / Double(plannedCount), 1)
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
            if rating.isSuccess { correctCount += 1 }
            ratingCounts[rating, default: 0] += 1
            lastGraded = card
            Haptics.tap()

            advance(after: card, returnsThisSession: result.returnsThisSession, preferences: preferences, now: now)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Move to the next card, re-queuing the one just graded when its next step is minutes away.
    private func advance(
        after card: Card, returnsThisSession: Bool,
        preferences: StudyPreferences, now: Date
    ) {
        queue.remove(at: currentIndex)

        if returnsThisSession {
            // Re-insert a few positions back rather than at the end. Immediately is useless
            // (it tests short-term memory) and at the very end can be twenty minutes later,
            // by which point the learning step has expired anyway.
            let target = min(currentIndex + 3, queue.count)
            queue.insert(card, at: target)
        }

        if currentIndex >= queue.count { currentIndex = 0 }
        isAnswerRevealed = false
        revealedAt = nil

        if queue.isEmpty {
            phase = .finished
            Haptics.success()
        } else {
            refreshPreviews(preferences: preferences, now: now)
        }
    }

    /// Un-grade the previous card and put it back in front.
    func undo(dependencies: AppDependencies) {
        guard let card = lastGraded, let preferences = dependencies.preferences else { return }
        do {
            try dependencies.review.undoLastReview(card: card, preferences: preferences)
            reviewedCount = max(0, reviewedCount - 1)
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
        skipCurrent(preferences: preferences)
    }

    func suspend(dependencies: AppDependencies) {
        guard let card = currentCard, let preferences = dependencies.preferences else { return }
        try? dependencies.review.setSuspended(true, card: card)
        skipCurrent(preferences: preferences)
    }

    func toggleFlag(dependencies: AppDependencies) {
        guard let card = currentCard else { return }
        try? dependencies.review.setFlagged(!card.isFlagged, card: card)
    }

    private func skipCurrent(preferences: StudyPreferences) {
        guard queue.indices.contains(currentIndex) else { return }
        queue.remove(at: currentIndex)
        if currentIndex >= queue.count { currentIndex = 0 }
        isAnswerRevealed = false
        revealedAt = nil
        if queue.isEmpty {
            phase = .finished
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
