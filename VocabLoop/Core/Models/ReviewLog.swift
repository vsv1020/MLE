import Foundation
import SwiftData

/// One graded recall attempt. Append-only, and never pruned.
///
/// This table is the app's most valuable data, for two reasons:
///
/// 1. **FSRS weights are meant to be fitted per learner.** We cannot ship an
///    optimiser in v1, but every field an optimiser needs is captured here, so one
///    can be added later and applied retroactively. Dropping these rows would make
///    that impossible forever.
/// 2. **It is the conflict-free source of truth for sync.** Review history is
///    genuinely an event log, so two devices merge by union with no reconciliation.
///    When two devices disagree about a card's `S`/`D`, the answer is to replay the
///    merged log rather than to pick a winner.
///
/// Because of (1), fields are recorded *before and after* the state transition even
/// though the "before" values are recoverable in principle by walking backwards —
/// in practice a single missing row would corrupt the whole chain.
@Model
public final class ReviewLog {
    /// Denormalised card identity, so logs survive card deletion for statistics and
    /// so a sync merge can match rows without resolving relationships first.
    public var cardID: String
    public var entryStableID: String
    public var languageCode: String
    public var directionRaw: String

    public var reviewedAt: Date
    public var ratingRaw: Int

    /// Phase the card was in when it was shown. `new` marks the introduction, which
    /// is excluded from accuracy statistics — grading a word you have never seen is
    /// not a recall test.
    public var phaseBeforeRaw: Int
    public var phaseAfterRaw: Int

    /// Days since the previous review (`0` for an introduction).
    public var elapsedDays: Double
    /// Days the card *was* scheduled for, i.e. the interval it just completed.
    public var scheduledDays: Double
    /// Days until the next review, after grading.
    public var intervalDaysAfter: Double

    public var stabilityBefore: Double
    public var stabilityAfter: Double
    public var difficultyBefore: Double
    public var difficultyAfter: Double
    /// Model's predicted recall probability at the moment of the review. The single
    /// most important field for evaluating and refitting the scheduler.
    public var retrievabilityBefore: Double

    /// Milliseconds from card reveal to rating. Used for "time studied" and, later,
    /// as a signal that a `Good` was really a `Hard`.
    public var durationMS: Int

    public var schedulerRaw: String
    /// Which weight vector produced this decision — see `FSRSParameters.version`.
    public var parametersVersion: String

    /// `false` until this row has been accepted by the server. Never blocks the UI.
    public var isSynced: Bool

    public var card: Card?

    public init(
        cardID: String,
        entryStableID: String,
        languageCode: String,
        direction: CardDirection,
        reviewedAt: Date,
        rating: Rating,
        stateBefore: SchedulingState,
        outcome: SchedulingOutcome,
        durationMS: Int,
        scheduler: SchedulerKind,
        parametersVersion: String
    ) {
        self.cardID = cardID
        self.entryStableID = entryStableID
        self.languageCode = languageCode
        self.directionRaw = direction.rawValue
        self.reviewedAt = reviewedAt
        self.ratingRaw = rating.rawValue
        self.phaseBeforeRaw = stateBefore.phase.rawValue
        self.phaseAfterRaw = outcome.state.phase.rawValue
        self.elapsedDays = stateBefore.elapsedDays(at: reviewedAt)
        self.scheduledDays = stateBefore.intervalDays
        self.intervalDaysAfter = outcome.intervalDays
        self.stabilityBefore = stateBefore.stability
        self.stabilityAfter = outcome.state.stability
        self.difficultyBefore = stateBefore.difficulty
        self.difficultyAfter = outcome.state.difficulty
        self.retrievabilityBefore = outcome.retrievabilityBefore
        self.durationMS = durationMS
        self.schedulerRaw = scheduler.rawValue
        self.parametersVersion = parametersVersion
        self.isSynced = false
    }

    public var rating: Rating { Rating(rawValue: ratingRaw) ?? .good }
    public var phaseBefore: LearningPhase { LearningPhase(rawValue: phaseBeforeRaw) ?? .new }
    public var phaseAfter: LearningPhase { LearningPhase(rawValue: phaseAfterRaw) ?? .review }
    public var direction: CardDirection { CardDirection(rawValue: directionRaw) ?? .recognition }
    public var scheduler: SchedulerKind { SchedulerKind(rawValue: schedulerRaw) ?? .fsrs5 }

    /// `true` when this row represents a genuine recall test, i.e. not the first
    /// showing. Accuracy statistics filter on this.
    public var isGradedRecall: Bool { phaseBefore != .new }
}
