import Foundation

/// How close an answer was.
public enum MatchQuality: Sendable {
    case exact
    /// One edit away from a word of five or more letters — a typo, not a different word.
    case nearMiss
    case wrong
}

/// Compares a typed answer with the expected word.
///
/// Case, surrounding and repeated whitespace, diacritics and character width are all ignored:
/// a child who types "cafe" for "café", or "Apple " for "apple", has remembered the word, and
/// marking that wrong would teach them the keyboard is the test.
public enum TypedAnswerMatcher {
    /// Words shorter than this get no typo allowance: one edit turns "cat" into "car", which is a
    /// different word, while one edit in "beautiful" is a slip.
    static let nearMissMinimumLength = 5

    public static func match(typed: String, answer: String) -> MatchQuality {
        let given = fold(typed)
        let expected = fold(answer)
        guard !given.isEmpty, !expected.isEmpty else { return .wrong }
        if given == expected { return .exact }
        if expected.count >= nearMissMinimumLength && editDistance(given, expected) == 1 {
            return .nearMiss
        }
        return .wrong
    }

    /// Levenshtein distance over `Character`s, so a composed letter counts as one edit.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let lhs = Array(a)
        let rhs = Array(b)
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let substitution = previous[j - 1] + (lhs[i - 1] == rhs[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }

    /// Folded, trimmed, with internal runs of whitespace collapsed to one space.
    static func fold(_ text: String) -> String {
        let folded = Entry.normalize(text)
        return folded
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

/// Turns a quiz answer into the `1…4` grade FSRS expects.
///
/// **Never `.easy`.** Recognising a word among four is weaker evidence than free recall — a
/// guess is right a quarter of the time — so the ceiling is `good`, the outcome FSRS treats as
/// expected. `easy` would inflate stability from a 25 % guess floor. Slow-but-correct is `hard`,
/// which is the paper's own definition of it; wrong is `again`, a normal lapse.
///
/// Response time matters only as this one threshold, measured from the moment the question
/// appeared.
public enum AutoGrader {
    /// Choice questions answered within this many milliseconds are `good`; slower is `hard`.
    public static let choiceFastMS = 6_000
    /// Typed answers get longer: finding letters on a keyboard is not recall time.
    public static let typedFastMS = 12_000

    public static func rating(kind: QuestionKind, quality: MatchQuality, responseMS: Int) -> Rating {
        switch kind {
        case .typed:
            switch quality {
            case .exact: return responseMS <= typedFastMS ? .good : .hard
            case .nearMiss: return .hard
            case .wrong: return .again
            }
        case .multipleChoice, .listenChoose, .clozeChoose, .flip:
            // A pick is right or wrong; there is no near miss among four options, so anything but
            // an exact match is a lapse. `flip` is self-graded and never asks — it is answered
            // like a choice only so this function is total.
            switch quality {
            case .exact: return responseMS <= choiceFastMS ? .good : .hard
            case .nearMiss, .wrong: return .again
            }
        }
    }
}
