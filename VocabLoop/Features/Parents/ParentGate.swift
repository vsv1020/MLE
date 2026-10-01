import Foundation

/// The arithmetic parental gate in front of the parent area (engagement plan §1.10).
///
/// A random `a × b` with both factors in `3…9`, three tries, nothing persisted: the standard
/// App Review parental gate. Easy for an adult, a real obstacle for a five-year-old, and no
/// stored PIN for anyone to forget.
///
/// Pure value logic so ``ParentGateTests`` can drive it with a seeded generator.
struct ParentGate: Equatable {
    struct Question: Equatable {
        let a: Int
        let b: Int

        var answer: Int { a * b }
        /// "What is 7 × 8?"
        var prompt: String { "What is \(a) × \(b)?" }
        /// Spoken form: VoiceOver reads "×" inconsistently.
        var accessibilityPrompt: String { "What is \(a) times \(b)?" }
    }

    enum State: Equatable {
        /// Waiting for an answer.
        case asking
        /// Answered correctly; the parent area is open.
        case passed
        /// Three wrong answers. Stays locked until the screen is left and opened again.
        case locked
    }

    static let factorRange = 3...9
    static let maxAttempts = 3

    private(set) var question: Question
    private(set) var attemptsLeft: Int
    private(set) var state: State

    init<G: RandomNumberGenerator>(using generator: inout G) {
        self.question = Self.makeQuestion(using: &generator)
        self.attemptsLeft = Self.maxAttempts
        self.state = .asking
    }

    init() {
        var generator = SystemRandomNumberGenerator()
        self.init(using: &generator)
    }

    static func makeQuestion<G: RandomNumberGenerator>(using generator: inout G) -> Question {
        Question(
            a: Int.random(in: factorRange, using: &generator),
            b: Int.random(in: factorRange, using: &generator)
        )
    }

    /// The number typed, or `nil` for anything that is not one. Whitespace is ignored.
    static func parse(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Check an answer. A blank entry is ignored and costs no attempt; anything else that is not
    /// the right number costs one and draws a new question, so the answer cannot be found by
    /// trying neighbouring numbers on the same sum.
    @discardableResult
    mutating func submit<G: RandomNumberGenerator>(_ text: String, using generator: inout G) -> State {
        guard state == .asking else { return state }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return state }

        if Self.parse(text) == question.answer {
            state = .passed
            return state
        }
        attemptsLeft -= 1
        if attemptsLeft <= 0 {
            attemptsLeft = 0
            state = .locked
        } else {
            question = Self.makeQuestion(using: &generator)
        }
        return state
    }

    @discardableResult
    mutating func submit(_ text: String) -> State {
        var generator = SystemRandomNumberGenerator()
        return submit(text, using: &generator)
    }
}
