import Foundation

/// The learner's self-assessment of a single recall attempt.
///
/// The raw values are the grades `1…4` used by both FSRS and SM-2, so they can be
/// substituted directly into the papers' formulas (`G` in FSRS) and persisted
/// without a translation table.
public enum Rating: Int, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    /// Failed to recall. The only rating that counts as a lapse.
    case again = 1
    /// Recalled, but with effort or after a long hesitation.
    case hard = 2
    /// Recalled correctly. The expected answer for a well-scheduled card.
    case good = 3
    /// Recalled instantly. Signals the interval was shorter than necessary.
    case easy = 4

    public var id: Int { rawValue }

    /// `false` only for ``again`` — used for accuracy statistics and lapse counting.
    public var isSuccess: Bool { self != .again }

    /// The face shown on the rating bar.
    ///
    /// The grades stay `1…4` — this changes the *label*, not the scale, so FSRS receives exactly
    /// what it received before. What it fixes is that the old labels asked for metacognition:
    /// deciding whether a recall was "Hard" or "Good" is a judgement about your own mental
    /// effort, and a child cannot make it consistently. An inconsistent answer is noise, and
    /// noise in `G` is noise in every interval the scheduler computes afterwards.
    ///
    /// Never the only signal: ``shortLabel`` sits under every face, and the four keep their
    /// fixed positions, so this works with VoiceOver and without colour vision.
    public var face: String {
        switch self {
        case .again: "😖"
        case .hard: "😐"
        case .good: "🙂"
        case .easy: "😎"
        }
    }

    /// Plain language rather than scheduler vocabulary.
    ///
    /// "Again" described what the *app* would do next; these describe what the *learner* just
    /// experienced, which is the thing being asked about. Adults benefit too — "Slow" is a far
    /// more answerable question than "Hard".
    public var shortLabel: String {
        switch self {
        case .again: "Forgot"
        case .hard: "Slow"
        case .good: "Got it"
        case .easy: "Instant"
        }
    }

    /// Spoken by VoiceOver, and used as the accessibility label on the rating bar.
    public var accessibilityDescription: String {
        switch self {
        case .again: "Again — I did not remember this"
        case .hard: "Hard — I remembered it with difficulty"
        case .good: "Good — I remembered it"
        case .easy: "Easy — I remembered it immediately"
        }
    }
}
