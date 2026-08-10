import Foundation

/// SM-2 — SuperMemo 2 (Wozniak, 1987), in the form Anki popularised.
///
/// Kept as a selectable alternative to FSRS for three reasons: it is the honest
/// baseline to compare FSRS against once we have review logs, it is what users
/// migrating from older Anki expect, and keeping a second implementation compiling
/// is what makes the ``Scheduler`` boundary real rather than decorative.
///
/// The model is a single ease factor per card, multiplied into the interval on each
/// success. It has no notion of retrievability, so ``retrievability(of:at:)`` is
/// approximated from the current interval purely so statistics screens have
/// something to plot; it is not used to schedule.
///
/// Known weakness, deliberately not patched: repeated lapses drag the ease factor
/// to its `1.3` floor and leave it there ("ease hell"). FSRS's damped difficulty
/// update is the fix, and is the reason FSRS is the default.
public struct SM2Scheduler: Scheduler {
    public let kind: SchedulerKind = .sm2
    public let config: SchedulerConfig

    /// The floor SuperMemo 2 places on the ease factor.
    static let minimumEaseFactor: Double = 1.3
    /// Interval, in days, awarded on graduating with `Good`.
    static let graduatingInterval: Double = 1
    /// Interval, in days, awarded on graduating with `Easy`.
    static let easyInterval: Double = 4
    /// Fraction of the old interval kept after a lapse.
    static let lapseIntervalMultiplier: Double = 0

    public init(config: SchedulerConfig = .default) {
        self.config = config.sanitised
    }

    /// SM-2 has no forgetting curve. This reuses the FSRS power-law shape with the
    /// current interval standing in for stability, which gives statistics screens a
    /// usable "how much have I forgotten" estimate without pretending SM-2 models it.
    public func retrievability(of state: SchedulingState, at now: Date) -> Double {
        guard state.intervalDays > 0 else { return 1 }
        let factor = pow(0.9, 1 / -0.5) - 1
        let r = pow(1 + factor * state.elapsedDays(at: now) / state.intervalDays, -0.5)
        return min(max(r, 0), 1)
    }

    public func apply(rating: Rating, to state: SchedulingState, at now: Date, fuzzSeed: UInt64) -> SchedulingOutcome {
        let rBefore = retrievability(of: state, at: now)
        var next = state
        next.reps += 1
        next.lastReviewedAt = now

        switch state.phase {
        case .new, .learning, .relearning:
            applyIntraday(&next, rating: rating, now: now, previousPhase: state.phase, fuzzSeed: fuzzSeed)
        case .review:
            applyReview(&next, rating: rating, now: now, fuzzSeed: fuzzSeed)
        }

        let intervalDays = next.due.timeIntervalSince(now) / 86_400
        return SchedulingOutcome(state: next, intervalDays: intervalDays, retrievabilityBefore: rBefore)
    }

    private func applyIntraday(
        _ state: inout SchedulingState, rating: Rating, now: Date,
        previousPhase: LearningPhase, fuzzSeed: UInt64
    ) {
        if state.easeFactor <= 0 { state.easeFactor = SchedulingState.defaultEaseFactor }
        let relearning = previousPhase == .relearning
        let steps = relearning ? config.relearningStepsMinutes : config.learningStepsMinutes
        let phase: LearningPhase = relearning ? .relearning : .learning
        // Clamped before use — see the matching note in `FSRSScheduler`.
        let currentIndex = previousPhase == .new ? 0 : min(max(state.stepIndex, 0), steps.count - 1)

        switch rating {
        case .again:
            state.phase = phase
            state.stepIndex = 0
            schedule(&state, minutes: steps[0], now: now)
        case .hard:
            state.phase = phase
            state.stepIndex = currentIndex
            schedule(&state, minutes: steps[currentIndex], now: now)
        case .good:
            let nextIndex = previousPhase == .new ? 1 : currentIndex + 1
            if nextIndex < steps.count {
                state.phase = phase
                state.stepIndex = nextIndex
                schedule(&state, minutes: steps[nextIndex], now: now)
            } else {
                graduate(&state, days: Self.graduatingInterval, now: now, fuzzSeed: fuzzSeed)
            }
        case .easy:
            graduate(&state, days: Self.easyInterval, now: now, fuzzSeed: fuzzSeed)
        }
    }

    private func applyReview(_ state: inout SchedulingState, rating: Rating, now: Date, fuzzSeed: UInt64) {
        let previousInterval = max(state.intervalDays, 1)
        var ease = state.easeFactor > 0 ? state.easeFactor : SchedulingState.defaultEaseFactor

        switch rating {
        case .again:
            ease -= 0.20
            state.easeFactor = max(ease, Self.minimumEaseFactor)
            state.lapses += 1
            state.intervalDays = max(previousInterval * Self.lapseIntervalMultiplier, 0)
            state.phase = .relearning
            state.stepIndex = 0
            schedule(&state, minutes: config.relearningStepsMinutes[0], now: now)

        case .hard:
            ease -= 0.15
            state.easeFactor = max(ease, Self.minimumEaseFactor)
            graduate(&state, days: previousInterval * 1.2, now: now, fuzzSeed: fuzzSeed)

        case .good:
            state.easeFactor = max(ease, Self.minimumEaseFactor)
            graduate(&state, days: previousInterval * state.easeFactor, now: now, fuzzSeed: fuzzSeed)

        case .easy:
            ease += 0.15
            state.easeFactor = max(ease, Self.minimumEaseFactor)
            graduate(&state, days: previousInterval * state.easeFactor * 1.3, now: now, fuzzSeed: fuzzSeed)
        }
    }

    private func schedule(_ state: inout SchedulingState, minutes: Double, now: Date) {
        state.intervalDays = minutes / (24 * 60)
        state.due = now.addingTimeInterval(minutes * 60)
    }

    private func graduate(_ state: inout SchedulingState, days: Double, now: Date, fuzzSeed: UInt64) {
        state.phase = .review
        state.stepIndex = 0
        let capped = min(max(days, 1), config.maximumInterval)
        let fuzzed = config.fuzzEnabled
            ? Fuzz.apply(intervalDays: capped, seed: fuzzSeed, maximumInterval: config.maximumInterval)
            : capped.rounded()
        state.intervalDays = max(1, fuzzed)
        state.due = now.addingTimeInterval(state.intervalDays * 86_400)
        // Mirror the interval into `stability` so statistics and maturity buckets
        // read the same field regardless of which scheduler is active.
        state.stability = state.intervalDays
    }
}
