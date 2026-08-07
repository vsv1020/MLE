import Foundation
import SwiftData

/// Which way round the card is tested.
///
/// Separate cards per direction — rather than one card tested both ways — so that
/// recognition and production are scheduled independently. The gap between the two
/// is small in English and large in Thai, which is exactly the kind of thing a
/// single shared interval gets wrong.
public enum CardDirection: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    /// Word → meaning. "What does *abandon* mean?"
    case recognition
    /// Meaning → word. "What is the word for *to give up completely*?"
    case production
    /// Sentence with the word removed. "Can I _____ your pen?"
    ///
    /// Harder than production and closer to using the language: the blank constrains which
    /// form is correct, so the learner has to produce `lent`, not `lend`. Only created when
    /// the entry actually has a maskable example — see ``ClozeMasker``.
    case cloze

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .recognition: "Recognition"
        case .production: "Production"
        case .cloze: "In context"
        }
    }

    public var explanation: String {
        switch self {
        case .recognition: "See the word, recall its meaning"
        case .production: "See the meaning, recall the word"
        case .cloze: "Fill the word into a real sentence"
        }
    }

    public var symbolName: String {
        switch self {
        case .recognition: "text.magnifyingglass"
        case .production: "pencil.and.scribble"
        case .cloze: "text.insert"
        }
    }

    /// `true` when a card of this kind can only exist if the entry supplies extra content.
    public var requiresExampleSentence: Bool { self == .cloze }
}

/// One schedulable item: an ``Entry`` tested in one ``CardDirection``.
///
/// The scheduler state is stored as plain properties rather than an encoded
/// ``SchedulingState`` blob, so `due < now` is a real SwiftData predicate and the
/// values are readable in the debugger and in `EntryDetailView`. ``schedulingState``
/// converts across that boundary.
@Model
public final class Card {
    /// `"<entry.stableID>#recognition"`. Unique, so enrolling a word twice is a
    /// no-op rather than a duplicate.
    ///
    /// Named `cardID` and not `id` because `PersistentModel` already supplies `id`.
    @Attribute(.unique) public var cardID: String

    public var directionRaw: String

    /// Denormalised from `entry` so queue queries and statistics can filter by
    /// language without joining. Kept in sync by ``Card/make(for:direction:now:)``.
    public var languageCode: String

    // MARK: Scheduler state

    public var phaseRaw: Int
    /// FSRS *S*, in days.
    public var stability: Double
    /// FSRS *D*, `1…10`.
    public var difficulty: Double
    /// SM-2 ease factor.
    public var easeFactor: Double
    /// Interval that produced the current ``due``, in days.
    public var intervalDays: Double
    public var due: Date
    public var lastReviewedAt: Date?
    public var reps: Int
    public var lapses: Int
    public var stepIndex: Int
    /// Which algorithm produced the current state — needed to interpret it, and to
    /// filter training data for a future weight optimiser.
    public var schedulerRaw: String

    // MARK: User controls

    /// Excluded from every queue until un-suspended. For words the user does not
    /// want to study but does not want to delete.
    public var isSuspended: Bool
    /// Temporarily hidden, e.g. "not again today". Cleared by time, not by hand.
    public var buriedUntil: Date?
    /// Flagged for later attention. Purely a user marker; does not affect scheduling.
    public var isFlagged: Bool

    public var createdAt: Date
    public var updatedAt: Date

    public var entry: Entry?

    @Relationship(deleteRule: .cascade, inverse: \ReviewLog.card)
    public var reviews: [ReviewLog]

    public init(
        cardID: String,
        direction: CardDirection,
        languageCode: String,
        state: SchedulingState,
        scheduler: SchedulerKind,
        now: Date = Date()
    ) {
        self.cardID = cardID
        self.directionRaw = direction.rawValue
        self.languageCode = languageCode
        self.phaseRaw = state.phase.rawValue
        self.stability = state.stability
        self.difficulty = state.difficulty
        self.easeFactor = state.easeFactor
        self.intervalDays = state.intervalDays
        self.due = state.due
        self.lastReviewedAt = state.lastReviewedAt
        self.reps = state.reps
        self.lapses = state.lapses
        self.stepIndex = state.stepIndex
        self.schedulerRaw = scheduler.rawValue
        self.isSuspended = false
        self.buriedUntil = nil
        self.isFlagged = false
        self.createdAt = now
        self.updatedAt = now
        self.reviews = []
    }

    /// Create the card for `entry` in `direction`, due immediately.
    public static func make(
        for entry: Entry,
        direction: CardDirection,
        scheduler: SchedulerKind,
        now: Date = Date()
    ) -> Card {
        Card(
            cardID: makeCardID(entryStableID: entry.stableID, direction: direction),
            direction: direction,
            languageCode: entry.languageCode,
            state: .newCard(due: now),
            scheduler: scheduler,
            now: now
        )
    }

    public static func makeCardID(entryStableID: String, direction: CardDirection) -> String {
        "\(entryStableID)#\(direction.rawValue)"
    }

    // MARK: - Typed accessors

    public var direction: CardDirection {
        get { CardDirection(rawValue: directionRaw) ?? .recognition }
        set { directionRaw = newValue.rawValue }
    }

    public var phase: LearningPhase {
        get { LearningPhase(rawValue: phaseRaw) ?? .new }
        set { phaseRaw = newValue.rawValue }
    }

    public var scheduler: SchedulerKind {
        get { SchedulerKind(rawValue: schedulerRaw) ?? .fsrs5 }
        set { schedulerRaw = newValue.rawValue }
    }

    /// Bridge to and from the pure value type the schedulers operate on.
    public var schedulingState: SchedulingState {
        get {
            SchedulingState(
                phase: phase,
                stability: stability,
                difficulty: difficulty,
                easeFactor: easeFactor,
                intervalDays: intervalDays,
                due: due,
                lastReviewedAt: lastReviewedAt,
                reps: reps,
                lapses: lapses,
                stepIndex: stepIndex
            )
        }
        set {
            phase = newValue.phase
            stability = newValue.stability
            difficulty = newValue.difficulty
            easeFactor = newValue.easeFactor
            intervalDays = newValue.intervalDays
            due = newValue.due
            lastReviewedAt = newValue.lastReviewedAt
            reps = newValue.reps
            lapses = newValue.lapses
            stepIndex = newValue.stepIndex
        }
    }

    public var maturity: CardMaturity { schedulingState.maturity }

    /// Eligible to appear in a review queue right now.
    public var isAvailable: Bool {
        !isSuspended && (buriedUntil == nil || buriedUntil! <= Date())
    }

    public func isDue(at now: Date) -> Bool {
        guard !isSuspended else { return false }
        if let buriedUntil, buriedUntil > now { return false }
        return due <= now
    }

    /// Stable seed for interval fuzzing, derived from the card's identity so it never
    /// changes across launches, reinstalls, or a replay of the review log.
    ///
    /// `hashValue` would be wrong here — Swift seeds its hasher per process, so the
    /// same card would fuzz differently on every launch.
    public var fuzzSeed: UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a offset basis
        for byte in cardID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3 // FNV prime
        }
        return hash
    }

    /// Accuracy over this card's own history, or `nil` before the first review.
    public var successRate: Double? {
        let graded = reviews.filter { $0.phaseBefore != .new }
        guard !graded.isEmpty else { return nil }
        let hits = graded.filter { $0.rating.isSuccess }.count
        return Double(hits) / Double(graded.count)
    }

    public func touch(_ now: Date = Date()) { updatedAt = now }
}
