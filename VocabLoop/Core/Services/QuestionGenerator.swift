import Foundation
import SwiftData

/// How a review is asked.
///
/// Raw values are recorded on engagement events, so a case may be added but never renamed.
public enum QuestionKind: String, Codable, CaseIterable, Sendable {
    /// The existing self-graded flashcard.
    case flip
    /// Headword shown (and speakable) → pick its meaning among four.
    case multipleChoice
    /// Word spoken, no text → pick the headword among four.
    case listenChoose
    /// Sentence with a blank → pick the headword among four.
    case clozeChoose
    /// Definition (and translation) shown → type the word. Production and cloze cards only.
    case typed

    /// `true` when the app grades the answer instead of the learner — see ``AutoGrader``.
    public var isAutoGraded: Bool {
        switch self {
        case .flip: return false
        case .multipleChoice, .listenChoose, .clozeChoose, .typed: return true
        }
    }
}

/// The switches that decide whether quizzes may appear at all.
public struct QuestionPolicy: Sendable {
    /// Every card is a flip card. Set by the UI tests so their taps stay predictable.
    public var flipOnly: Bool
    /// The user's "Quiz questions" setting.
    public var quizEnabled: Bool
    /// A voice exists for the language, so `listenChoose` can actually be heard.
    public var hasSpeech: Bool

    public init(flipOnly: Bool = false, quizEnabled: Bool = true, hasSpeech: Bool = true) {
        self.flipOnly = flipOnly
        self.quizEnabled = quizEnabled
        self.hasSpeech = hasSpeech
    }

    /// Launch argument the UI test suite passes to keep every card a flip card.
    public static let flipOnlyLaunchArgument = "-uiTestingFlipOnly"

    /// `true` when this process was launched with ``flipOnlyLaunchArgument``. Always `false` in
    /// a release build, so a stray argument can never switch quizzes off for a real user.
    public static var isFlipOnlyLaunch: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(flipOnlyLaunchArgument)
        #else
        return false
        #endif
    }

    /// The policy for this process, these preferences and this device's voices.
    @MainActor
    public static func fromProcess(preferences: StudyPreferences, speech: SpeechService) -> QuestionPolicy {
        QuestionPolicy(
            flipOnly: isFlipOnlyLaunch,
            quizEnabled: preferences.quizModesEnabled,
            hasSpeech: speech.isSupported(preferences.activeLanguage)
        )
    }
}

/// One tappable answer.
public struct QuestionOption: Identifiable, Hashable, Sendable {
    /// The option's ``Entry/stableID``.
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// What the study screen shows for one card.
public struct Question: Equatable, Sendable {
    public var kind: QuestionKind
    public var cardID: String
    /// Exactly four for the choice kinds; empty for `flip` and `typed`.
    public var options: [QuestionOption]
    /// Index of the right answer in ``options``. Meaningless when ``options`` is empty.
    public var correctIndex: Int
    /// The right answer as text: the option text for `multipleChoice`, the headword for the
    /// other choice kinds, and the string to type for `typed` (the sentence's surface form —
    /// `lent`, not `lend` — on a cloze card).
    public var answerText: String
    /// The sentence with its blank, for `clozeChoose` and for `typed` on a cloze card.
    public var clozePrompt: ClozePrompt?
    public var seed: UInt64

    public init(
        kind: QuestionKind,
        cardID: String,
        options: [QuestionOption],
        correctIndex: Int,
        answerText: String,
        clozePrompt: ClozePrompt?,
        seed: UInt64
    ) {
        self.kind = kind
        self.cardID = cardID
        self.options = options
        self.correctIndex = correctIndex
        self.answerText = answerText
        self.clozePrompt = clozePrompt
        self.seed = seed
    }
}

/// A word reduced to what choosing distractors needs. Light, so a whole language fits in memory.
public struct DistractorCandidate: Hashable, Sendable {
    public var stableID: String
    public var headword: String
    /// Primary sense's part of speech.
    public var pos: PartOfSpeech
    public var cefr: CEFRLevel?
    /// What a `multipleChoice` option shows for this word — see ``QuestionGenerator/optionText(for:nativeCodes:)``.
    public var optionText: String
    /// Primary sense's synonyms: a synonym of the answer is never offered as a wrong answer.
    public var synonyms: [String]
    /// The learner has cards for this word.
    public var isEnrolled: Bool

    public init(
        stableID: String,
        headword: String,
        pos: PartOfSpeech,
        cefr: CEFRLevel?,
        optionText: String,
        synonyms: [String],
        isEnrolled: Bool
    ) {
        self.stableID = stableID
        self.headword = headword
        self.pos = pos
        self.cefr = cefr
        self.optionText = optionText
        self.synonyms = synonyms
        self.isEnrolled = isEnrolled
    }
}

/// Decides how each card is asked and builds the question.
///
/// **Quizzes never touch FSRS's input scale.** A quiz is only a different way of *finding out*
/// whether the learner remembered; ``AutoGrader`` turns the answer into the same `1…4` grade a
/// self-graded card produces, capped at `good`.
///
/// Everything is deterministic from the card (``seed(for:)``): the same card at the same
/// repetition always gets the same kind, the same distractors and the same answer position, so a
/// question survives an undo or a relaunch unchanged and every rule is testable.
@MainActor
public final class QuestionGenerator {
    private let context: ModelContext
    private var pool: [DistractorCandidate] = []
    private var byStableID: [String: DistractorCandidate] = [:]
    private var nativeCodes: [String] = []

    /// Longest `multipleChoice` option, in characters. Four short options a child can scan;
    /// four long definitions are a reading test.
    static let maxOptionLength = 60

    public init(context: ModelContext) {
        self.context = context
    }

    /// Build the distractor pool for a session: one `Entry` fetch and one `Card` fetch, reduced to
    /// light structs. Call once when a session starts; ``make(for:policy:)`` never fetches.
    public func prepare(languageCode: String, nativeCodes: [String]) throws {
        self.nativeCodes = nativeCodes
        let entries = try context.fetch(
            FetchDescriptor<Entry>(predicate: #Predicate { $0.languageCode == languageCode })
        )
        let cards = try context.fetch(
            FetchDescriptor<Card>(predicate: #Predicate { $0.languageCode == languageCode })
        )
        var enrolled = Set<String>()
        for card in cards {
            if let hash = card.cardID.lastIndex(of: "#") {
                enrolled.insert(String(card.cardID[..<hash]))
            }
        }
        var candidates: [DistractorCandidate] = []
        candidates.reserveCapacity(entries.count)
        for entry in entries {
            if let candidate = Self.candidate(
                from: entry, nativeCodes: nativeCodes, isEnrolled: enrolled.contains(entry.stableID)
            ) {
                candidates.append(candidate)
            }
        }
        pool = candidates
        byStableID = Dictionary(candidates.map { ($0.stableID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The kind of question for `card`. The rules, in order:
    ///
    /// 1. Quizzes switched off (setting or UI-test flag) → `flip`.
    /// 2. New, learning or relearning → `flip`. An introduction cannot be a quiz, and learning
    ///    steps are minutes apart, so a quiz there would test the option list, not memory.
    /// 3. Fewer than three valid distractors → `flip`.
    /// 4. Recognition: a roll of `seed % 10` against a table that leans on `flip` and shifts
    ///    toward harder kinds once the card is mature. `listenChoose` needs a voice and
    ///    `clozeChoose` a sentence; without one they fall back to `multipleChoice`.
    /// 5. Production `0–5 flip, 6–9 typed`; cloze `0–4 flip, 5–9 typed` (needs its sentence).
    public static func kind(for card: Card, policy: QuestionPolicy, distractorCount: Int, canCloze: Bool) -> QuestionKind {
        if policy.flipOnly || !policy.quizEnabled { return .flip }
        switch card.phase {
        case .new, .learning, .relearning:
            return .flip
        case .review:
            break
        }
        if distractorCount < 3 { return .flip }

        let roll = Int(seed(for: card) % 10)
        switch card.direction {
        case .recognition:
            let isMature = card.intervalDays >= CardMaturity.matureThresholdDays
            let picked: QuestionKind
            if isMature {
                switch roll {
                case 0...4: picked = .flip
                case 5...6: picked = .multipleChoice
                case 7: picked = .listenChoose
                default: picked = .clozeChoose
                }
            } else {
                switch roll {
                case 0...3: picked = .flip
                case 4...6: picked = .multipleChoice
                case 7...8: picked = .listenChoose
                default: picked = .clozeChoose
                }
            }
            if picked == .listenChoose && !policy.hasSpeech { return .multipleChoice }
            if picked == .clozeChoose && !canCloze { return .multipleChoice }
            return picked
        case .production:
            return roll <= 5 ? .flip : .typed
        case .cloze:
            guard canCloze else { return .flip }
            return roll <= 4 ? .flip : .typed
        }
    }

    /// The question for `card`. Never fails: anything missing — no entry, no pool, too few
    /// distractors — gives the flip card the app always had.
    public func make(for card: Card, policy: QuestionPolicy) -> Question {
        let seed = Self.seed(for: card)
        let flip = Question(
            kind: .flip, cardID: card.cardID, options: [], correctIndex: 0,
            answerText: card.entry?.headword ?? "", clozePrompt: nil, seed: seed
        )
        // Cheap exits first: most cards in a session are flips, and those need no distractors.
        guard let entry = card.entry,
              !policy.flipOnly, policy.quizEnabled, card.phase == .review
        else { return flip }

        let known = byStableID[entry.stableID]
        guard let answer = known ?? Self.candidate(from: entry, nativeCodes: nativeCodes, isEnrolled: true)
        else { return flip }

        let distractors = Self.pickDistractors(answer: answer, pool: pool, seed: seed)
        let cloze = entry.clozePrompt()
        let kind = Self.kind(for: card, policy: policy, distractorCount: distractors.count, canCloze: cloze != nil)
        let correctIndex = Int(seed % 4)

        switch kind {
        case .flip:
            return flip
        case .multipleChoice:
            var options = distractors.map { QuestionOption(id: $0.stableID, text: $0.optionText) }
            let index = min(correctIndex, options.count)
            options.insert(QuestionOption(id: answer.stableID, text: answer.optionText), at: index)
            return Question(
                kind: kind, cardID: card.cardID, options: options, correctIndex: index,
                answerText: answer.optionText, clozePrompt: nil, seed: seed
            )
        case .listenChoose, .clozeChoose:
            var options = distractors.map { QuestionOption(id: $0.stableID, text: $0.headword) }
            let index = min(correctIndex, options.count)
            options.insert(QuestionOption(id: answer.stableID, text: answer.headword), at: index)
            return Question(
                kind: kind, cardID: card.cardID, options: options, correctIndex: index,
                answerText: answer.headword, clozePrompt: kind == .clozeChoose ? cloze : nil, seed: seed
            )
        case .typed:
            let isCloze = card.direction == .cloze
            return Question(
                kind: kind, cardID: card.cardID, options: [], correctIndex: 0,
                answerText: isCloze ? (cloze?.answer ?? entry.headword) : entry.headword,
                clozePrompt: isCloze ? cloze : nil, seed: seed
            )
        }
    }

    // MARK: - Pure parts

    /// Up to three wrong answers for `answer`, chosen deterministically by `seed`.
    ///
    /// A distractor must share the answer's part of speech (so grammar never gives the answer
    /// away), must not be the answer, its headword, one of its synonyms or a word whose option
    /// reads the same — a "wrong" option that is also right is the one unforgivable quiz bug.
    /// Preference order: same CEFR level, then adjacent, then any; within each, words the learner
    /// already studies first (familiar distractors are fair distractors). The pool's order never
    /// matters: each bucket is sorted by ID before the seeded shuffle.
    static func pickDistractors(answer: DistractorCandidate, pool: [DistractorCandidate], seed: UInt64) -> [DistractorCandidate] {
        let answerHeadword = normalize(answer.headword)
        let answerText = normalize(answer.optionText)
        let synonyms = Set(answer.synonyms.map(normalize))

        var valid: [DistractorCandidate] = []
        for candidate in pool where candidate.pos == answer.pos && candidate.stableID != answer.stableID {
            let headword = normalize(candidate.headword)
            let text = normalize(candidate.optionText)
            guard !headword.isEmpty, !text.isEmpty,
                  headword != answerHeadword,
                  !synonyms.contains(headword),
                  text != answerText
            else { continue }
            valid.append(candidate)
        }

        var generator = SeededGenerator(seed: seed)
        var picked: [DistractorCandidate] = []
        var usedHeadwords: Set<String> = [answerHeadword]
        var usedTexts: Set<String> = [answerText]

        for distance in 0...2 {
            for wantEnrolled in [true, false] {
                guard picked.count < 3 else { return picked }
                let bucket = valid
                    .filter { levelDistance(answer.cefr, $0.cefr) == distance && $0.isEnrolled == wantEnrolled }
                    .sorted { $0.stableID < $1.stableID }
                    .shuffled(using: &generator)
                for candidate in bucket {
                    guard picked.count < 3 else { break }
                    let headword = normalize(candidate.headword)
                    let text = normalize(candidate.optionText)
                    // Two options that read the same would make two answers look identical.
                    guard !usedHeadwords.contains(headword), !usedTexts.contains(text) else { continue }
                    usedHeadwords.insert(headword)
                    usedTexts.insert(text)
                    picked.append(candidate)
                }
            }
        }
        return picked
    }

    /// The card's question seed: its fuzz seed mixed with its repetition count, so the same card
    /// is asked differently on its next review but identically if this one is undone and replayed.
    static func seed(for card: Card) -> UInt64 {
        card.fuzzSeed ^ (UInt64(card.reps) &* 0x9E37_79B9_7F4A_7C15)
    }

    /// The text a `multipleChoice` option shows: the Chinese translation of the primary sense when
    /// the learner reads Chinese, else the definition cut to ``maxOptionLength`` characters.
    static func optionText(for sense: Sense, nativeCodes: [String]) -> String {
        let readsChinese = nativeCodes.contains { $0.lowercased().hasPrefix("zh") }
        if readsChinese, let translation = sense.translation(preferring: ["zh"]),
           !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return translation
        }
        return truncate(sense.definition, to: maxOptionLength)
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit, limit > 1 else { return trimmed }
        return String(trimmed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Helpers

    private static func candidate(from entry: Entry, nativeCodes: [String], isEnrolled: Bool) -> DistractorCandidate? {
        guard let sense = entry.primarySense else { return nil }
        let text = optionText(for: sense, nativeCodes: nativeCodes)
        guard !text.isEmpty else { return nil }
        return DistractorCandidate(
            stableID: entry.stableID,
            headword: entry.headword,
            pos: sense.partOfSpeech,
            cefr: entry.cefr,
            optionText: text,
            synonyms: sense.synonyms,
            isEnrolled: isEnrolled
        )
    }

    /// `0` same level, `1` adjacent, `2` anything else (including a missing level on one side).
    private static func levelDistance(_ lhs: CEFRLevel?, _ rhs: CEFRLevel?) -> Int {
        switch (lhs, rhs) {
        case (.none, .none):
            return 0
        case let (.some(a), .some(b)):
            let ia = CEFRLevel.allCases.firstIndex(of: a) ?? 0
            let ib = CEFRLevel.allCases.firstIndex(of: b) ?? 0
            return min(abs(ia - ib), 2)
        default:
            return 2
        }
    }

    /// Case-, diacritic- and width-insensitive, trimmed — the same folding as ``Entry/normalize(_:)``.
    private static func normalize(_ text: String) -> String {
        Entry.normalize(text)
    }
}
