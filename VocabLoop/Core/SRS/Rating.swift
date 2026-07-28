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

    public var shortLabel: String {
        switch self {
        case .again: "Again"
        case .hard: "Hard"
        case .good: "Good"
        case .easy: "Easy"
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
