import Foundation

/// FSRS-5 — the Free Spaced Repetition Scheduler, and the app's default.
///
/// The model tracks three quantities per card:
///
/// - **D**ifficulty `1…10` — how intrinsically hard the item is
/// - **S**tability — days until recall probability decays to 90%
/// - **R**etrievability — current recall probability, derived from `S` and elapsed time
///
/// with a power-law forgetting curve
///
/// ```
/// R(t, S) = (1 + FACTOR · t/S)^DECAY        DECAY = -0.5, FACTOR = 19/81
/// ```
///
/// which inverts to give the interval for any desired retention `r`:
///
/// ```
/// I(r, S) = (S / FACTOR) · (r^(1/DECAY) − 1)
/// ```
///
/// That inversion is the reason FSRS is the default: the user gets a meaningful
/// "review me at 90% retention" dial instead of an opaque ease multiplier.
///
/// Intraday phases (`learning`, `relearning`) are driven by the configured step
/// lists rather than by `I(r, S)`, because a one-minute interval is a UI decision,
/// not a memory-model one. `S` and `D` are still updated during those steps using
/// the FSRS-5 same-day formula so that the state is correct at graduation.
///
/// All formulas are pure functions of their inputs; see `FSRSTests` for the
/// invariants they are pinned to.
public struct FSRSScheduler: Scheduler {
    public let kind: SchedulerKind = .fsrs5
    public let config: SchedulerConfig

    private var p: FSRSParameters { config.fsrsParameters.validated }

    public init(config: SchedulerConfig = .default) {
        self.config = config.sanitised
    }

    // MARK: - Forgetting curve

    /// `R(t, S)`, clamped to `0…1`.
    ///
    /// Returns `1` for a card with no stability yet: an unseen card is not "forgotten",
    /// it is unknown, and feeding `0` into the growth formula would blow it up.
    public func retrievability(of state: SchedulingState, at now: Date) -> Double {
        guard state.stability > 0 else { return 1 }
        return retrievability(elapsedDays: state.elapsedDays(at: now), stability: state.stability)
    }

    public func retrievability(elapsedDays: Double, stability: Double) -> Double {
        guard stability > 0 else { return 1 }
        let r = pow(1 + p.factor * elapsedDays / stability, p.decay)
        return min(max(r, 0), 1)
    }

    /// `I(r, S)` — the interval, in days, at which recall probability will have
    /// decayed to `desiredRetention`.
    public func interval(forStability stability: Double) -> Double {
        let r = config.desiredRetention
        let raw = (stability / p.factor) * (pow(r, 1 / p.decay) - 1)
        return min(max(raw, 1), config.maximumInterval)
    }

    // MARK: - Initial state

    /// `S₀(G) = w[G−1]`
    func initialStability(_ rating: Rating) -> Double {
        max(p.w(rating.rawValue - 1), 0.01)
    }

    /// `D₀(G) = w[4] − e^(w[5]·(G−1)) + 1`, clamped to `1…10`
    func initialDifficulty(_ rating: Rating) -> Double {
        clampDifficulty(p.w(4) - exp(p.w(5) * Double(rating.rawValue - 1)) + 1)
    }

    private func clampDifficulty(_ d: Double) -> Double {
        guard d.isFinite else { return 5 }
        return min(max(d, 1), 10)
    }

    // MARK: - Difficulty update

    /// Linear-damped delta plus mean reversion toward `D₀(Easy)`.
    ///
    /// The `(10 − D)/9` damping is what stops difficulty from saturating at 10 after
    /// a handful of lapses — the failure mode SM-2 calls "ease hell".
    func nextDifficulty(_ difficulty: Double, rating: Rating) -> Double {
        let delta = -p.w(6) * Double(rating.rawValue - 3)
        let damped = difficulty + delta * (10 - difficulty) / 9
        let reverted = p.w(7) * initialDifficulty(.easy) + (1 - p.w(7)) * damped
        return clampDifficulty(reverted)
    }

    // MARK: - Stability update

    /// `S'ᵣ = S · (1 + e^w8 · (11 − D) · S^−w9 · (e^(w10·(1−R)) − 1) · hard · easy)`
    ///
    /// The `(e^(w10·(1−R)) − 1)` term is why reviewing early buys almost nothing:
    /// as `R → 1` it goes to zero, so stability barely grows.
    func stabilityAfterRecall(stability: Double, difficulty: Double, retrievability r: Double, rating: Rating) -> Double {
        let hardPenalty = rating == .hard ? p.w(15) : 1
        let easyBonus = rating == .easy ? p.w(16) : 1
        let growth = exp(p.w(8))
            * (11 - difficulty)
            * pow(stability, -p.w(9))
            * (exp(p.w(10) * (1 - r)) - 1)
            * hardPenalty
            * easyBonus
        let next = stability * (1 + growth)
        return sanitiseStability(next, fallback: stability)
    }

    /// `S'_f = w11 · D^−w12 · ((S+1)^w13 − 1) · e^(w14·(1−R))`, capped at `S`.
    ///
    /// The cap is an FSRS-5 addition: forgetting an item must never be rewarded with
    /// more stability than it already had.
    func stabilityAfterLapse(stability: Double, difficulty: Double, retrievability r: Double) -> Double {
        let raw = p.w(11)
            * pow(difficulty, -p.w(12))
            * (pow(stability + 1, p.w(13)) - 1)
            * exp(p.w(14) * (1 - r))
        return sanitiseStability(min(raw, stability), fallback: stability)
    }

    /// `S' = S · e^(w17·(G − 3 + w18))` — the FSRS-5 same-day formula, used while a
    /// card is working through its intraday steps.
    func stabilityAfterSameDayReview(stability: Double, rating: Rating) -> Double {
        let next = stability * exp(p.w(17) * (Double(rating.rawValue) - 3 + p.w(18)))
        return sanitiseStability(next, fallback: stability)
    }

    /// Guards every stability computation. A non-finite or non-positive `S` would
    /// silently corrupt the card's schedule forever, so it is never persisted.
    private func sanitiseStability(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite, value > 0 else { return max(fallback, 0.01) }
        return min(value, config.maximumInterval)
    }

    // MARK: - Grading

    public func apply(rating: Rating, to state: SchedulingState, at now: Date, fuzzSeed: UInt64) -> SchedulingOutcome {
        let rBefore = retrievability(of: state, at: now)
        var next = state
        next.reps += 1
        next.lastReviewedAt = now

        switch state.phase {
        case .new:
            next.stability = initialStability(rating)
            next.difficulty = initialDifficulty(rating)
            applyIntroductionSteps(to: &next, rating: rating, now: now, fuzzSeed: fuzzSeed)

        case .learning, .relearning:
            next.difficulty = nextDifficulty(state.difficulty, rating: rating)
            // FSRS-5 uses the same-day formula for *every* rating while the gap is
            // under a day — including Again, which shrinks stability rather than
            // applying the full post-lapse penalty. A learning card answered a day
            // or more later is a genuine recall attempt, so it takes the long-term
            // formulas instead.
            if state.elapsedDays(at: now) < 1 {
                next.stability = stabilityAfterSameDayReview(stability: state.stability, rating: rating)
            } else if rating == .again {
                next.stability = stabilityAfterLapse(
                    stability: state.stability, difficulty: next.difficulty, retrievability: rBefore
                )
            } else {
                next.stability = stabilityAfterRecall(
                    stability: state.stability, difficulty: next.difficulty,
                    retrievability: rBefore, rating: rating
                )
            }
            applyIntradaySteps(to: &next, rating: rating, now: now, fuzzSeed: fuzzSeed, phase: state.phase)

        case .review:
            next.difficulty = nextDifficulty(state.difficulty, rating: rating)
            if rating == .again {
                next.lapses += 1
                next.stability = stabilityAfterLapse(
                    stability: state.stability, difficulty: next.difficulty, retrievability: rBefore
                )
                next.phase = .relearning
                next.stepIndex = 0
                scheduleIntraday(&next, minutes: config.relearningStepsMinutes[0], now: now)
            } else {
                next.stability = stabilityAfterRecall(
                    stability: state.stability, difficulty: next.difficulty,
                    retrievability: rBefore, rating: rating
                )
                graduate(&next, now: now, fuzzSeed: fuzzSeed)
            }
        }

        let intervalDays = next.due.timeIntervalSince(now) / 86_400
        return SchedulingOutcome(state: next, intervalDays: intervalDays, retrievabilityBefore: rBefore)
    }

    /// First-ever answer. `Easy` skips introduction entirely — a word the learner
    /// already knows should not be drip-fed through two minutes of steps.
    private func applyIntroductionSteps(to state: inout SchedulingState, rating: Rating, now: Date, fuzzSeed: UInt64) {
        let steps = config.learningStepsMinutes
        switch rating {
        case .easy:
            graduate(&state, now: now, fuzzSeed: fuzzSeed)
        case .good:
            if steps.count > 1 {
                state.phase = .learning
                state.stepIndex = 1
                scheduleIntraday(&state, minutes: steps[1], now: now)
            } else {
                graduate(&state, now: now, fuzzSeed: fuzzSeed)
            }
        case .hard, .again:
            state.phase = .learning
            state.stepIndex = 0
            scheduleIntraday(&state, minutes: steps[0], now: now)
        }
    }

    /// Answering a card that is mid-steps. `Hard` repeats the current step rather
    /// than advancing or resetting, which is the behaviour learners expect from Anki.
    private func applyIntradaySteps(
        to state: inout SchedulingState, rating: Rating, now: Date, fuzzSeed: UInt64, phase: LearningPhase
    ) {
        let steps = phase == .relearning ? config.relearningStepsMinutes : config.learningStepsMinutes
        state.phase = phase

        // Clamped before use. The step lists are indexed directly, so a persisted index that is
        // negative or beyond the list — a corrupt store, or a settings change that shortened the
        // list — would be a crash rather than a wrong interval.
        let currentIndex = min(max(state.stepIndex, 0), steps.count - 1)

        switch rating {
        case .again:
            state.stepIndex = 0
            scheduleIntraday(&state, minutes: steps[0], now: now)
        case .hard:
            state.stepIndex = currentIndex
            scheduleIntraday(&state, minutes: steps[currentIndex], now: now)
        case .good:
            let nextIndex = currentIndex + 1
            if nextIndex < steps.count {
                state.stepIndex = nextIndex
                scheduleIntraday(&state, minutes: steps[nextIndex], now: now)
            } else {
                graduate(&state, now: now, fuzzSeed: fuzzSeed)
            }
        case .easy:
            graduate(&state, now: now, fuzzSeed: fuzzSeed)
        }
    }

    private func scheduleIntraday(_ state: inout SchedulingState, minutes: Double, now: Date) {
        state.intervalDays = minutes / (24 * 60)
        state.due = now.addingTimeInterval(minutes * 60)
    }

    /// Leave the step list and hand the interval over to the memory model.
    private func graduate(_ state: inout SchedulingState, now: Date, fuzzSeed: UInt64) {
        state.phase = .review
        state.stepIndex = 0
        let base = interval(forStability: state.stability)
        let days = config.fuzzEnabled
            ? Fuzz.apply(intervalDays: base, seed: fuzzSeed, maximumInterval: config.maximumInterval)
            : base.rounded()
        state.intervalDays = max(1, days)
        state.due = now.addingTimeInterval(state.intervalDays * 86_400)
    }
}
