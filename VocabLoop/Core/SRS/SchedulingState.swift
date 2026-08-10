import Foundation

/// Where a card sits in its lifecycle.
///
/// `learning` and `relearning` are the intraday phases driven by fixed step lists;
/// `review` is the phase where the memory model owns the interval.
public enum LearningPhase: Int, Codable, CaseIterable, Hashable, Sendable {
    /// Never answered.
    case new = 0
    /// Being introduced, working through `learningSteps`.
    case learning = 1
    /// Graduated. Intervals come from the scheduler.
    case review = 2
    /// Lapsed out of `review`, working back through `relearningSteps`.
    case relearning = 3

    public var isIntraday: Bool { self == .learning || self == .relearning }
}

/// How mature a card is, for statistics and forecast colouring.
///
/// The 21-day young/mature boundary is the convention SuperMemo and Anki both use;
/// keeping it means our statistics are comparable to a user's Anki history.
public enum CardMaturity: String, Codable, CaseIterable, Hashable, Sendable {
    case new
    case learning
    case young
    case mature

    public static let matureThresholdDays: Double = 21
}

/// The complete memory state of one card, as a value type.
///
/// This is deliberately a superset of what any single scheduler needs: FSRS uses
/// `stability` and `difficulty`, SM-2 uses `easeFactor` and `intervalDays`. Both are
/// stored so a user can switch schedulers without losing their history — the unused
/// fields simply lie dormant, and `ReviewLog` records which scheduler produced each
/// value.
public struct SchedulingState: Codable, Hashable, Sendable {
    /// Lifecycle phase.
    public var phase: LearningPhase
    /// FSRS *S*: days until recall probability decays to 90%. `0` while `new`.
    public var stability: Double
    /// FSRS *D*: intrinsic item difficulty, clamped to `1…10`. `0` while `new`.
    public var difficulty: Double
    /// SM-2 ease factor. Ignored by FSRS.
    public var easeFactor: Double
    /// The interval that produced the current `due`, in days. Used for statistics
    /// and by SM-2 as its multiplicative base.
    public var intervalDays: Double
    /// When the card should next be shown.
    public var due: Date
    /// When it was last answered. `nil` while `new`.
    public var lastReviewedAt: Date?
    /// Total answers, including lapses and intraday steps.
    public var reps: Int
    /// Times the card was rated ``Rating/again`` while in `review`.
    public var lapses: Int
    /// Index into the active step list while in an intraday phase.
    public var stepIndex: Int

    public static let defaultEaseFactor: Double = 2.5

    public init(
        phase: LearningPhase = .new,
        stability: Double = 0,
        difficulty: Double = 0,
        easeFactor: Double = SchedulingState.defaultEaseFactor,
        intervalDays: Double = 0,
        due: Date = .distantPast,
        lastReviewedAt: Date? = nil,
        reps: Int = 0,
        lapses: Int = 0,
        stepIndex: Int = 0
    ) {
        self.phase = phase
        self.stability = stability
        self.difficulty = difficulty
        self.easeFactor = easeFactor
        self.intervalDays = intervalDays
        self.due = due
        self.lastReviewedAt = lastReviewedAt
        self.reps = reps
        self.lapses = lapses
        self.stepIndex = stepIndex
    }

    /// A brand new card, due immediately.
    public static func newCard(due: Date) -> SchedulingState {
        SchedulingState(phase: .new, due: due)
    }

    /// Fractional days since the last answer. `0` for a card never answered, and
    /// never negative (a clock moving backwards must not produce a negative
    /// elapsed time and inflate retrievability).
    public func elapsedDays(at now: Date) -> Double {
        guard let lastReviewedAt else { return 0 }
        return max(0, now.timeIntervalSince(lastReviewedAt) / 86_400)
    }

    public func isDue(at now: Date) -> Bool { due <= now }

    public var maturity: CardMaturity {
        switch phase {
        case .new: .new
        case .learning, .relearning: .learning
        case .review:
            intervalDays >= CardMaturity.matureThresholdDays ? .mature : .young
        }
    }
}

/// The result of grading a card: the new state, plus the inputs worth logging.
public struct SchedulingOutcome: Hashable, Sendable {
    /// The state to persist.
    public var state: SchedulingState
    /// Days until `state.due`, for display. Sub-day intervals are fractional.
    public var intervalDays: Double
    /// Recall probability at the moment of the review, *before* grading. This is
    /// the value an FSRS weight optimiser needs and cannot reconstruct later, so it
    /// is returned rather than recomputed.
    public var retrievabilityBefore: Double

    public init(state: SchedulingState, intervalDays: Double, retrievabilityBefore: Double) {
        self.state = state
        self.intervalDays = intervalDays
        self.retrievabilityBefore = retrievabilityBefore
    }
}
