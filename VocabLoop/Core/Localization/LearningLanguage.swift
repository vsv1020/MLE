import Foundation

/// A language the user can study.
///
/// Everything language-specific is declared here as *data* rather than being
/// branched on at call sites. Adding Thai should be: add a case, add a seed pack,
/// fill in these properties. If adding a language requires touching a view or a
/// model, this type is missing a property — add it here instead.
///
/// The raw value is the BCP-47 code and is what gets persisted, so cases can be
/// reordered freely but never renamed.
public enum LearningLanguage: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case english = "en"
    case french = "fr"
    case thai = "th"

    public var id: String { rawValue }

    /// Name in the app's UI language.
    public var displayName: String {
        switch self {
        case .english: "英语"
        case .french: "法语"
        case .thai: "泰语"
        }
    }

    /// Name in the language itself — shown next to `displayName` in the picker,
    /// because a learner recognises "ไทย" faster than "Thai".
    public var endonym: String {
        switch self {
        case .english: "English"
        case .french: "Français"
        case .thai: "ไทย"
        }
    }

    public var flagEmoji: String {
        switch self {
        case .english: "🇬🇧"
        case .french: "🇫🇷"
        case .thai: "🇹🇭"
        }
    }

    /// Which notation the `phonetic` field uses. Not every language writes IPA, and
    /// mislabelling romanisation as IPA makes the pronunciation hint actively
    /// misleading.
    public var phoneticNotation: PhoneticNotation {
        switch self {
        case .english, .french: .ipa
        case .thai: .rtgs
        }
    }

    /// `false` for scripts written without spaces between words.
    ///
    /// This is the flag that stops us shipping a tokenizer that silently produces
    /// one enormous "word" for every Thai sentence.
    public var isWordSeparated: Bool {
        switch self {
        case .english, .french: true
        case .thai: false
        }
    }

    public var usesLatinScript: Bool {
        switch self {
        case .english, .french: true
        case .thai: false
        }
    }

    /// How to find a headword inside a sentence where it appears inflected.
    ///
    /// Only English gets the suffix heuristics. French conjugation is not suffix-append —
    /// guessing that `apprendre` becomes `apprendres` would be worse than not guessing, so
    /// French and Thai match exactly and rely on an authored blank for anything irregular.
    public var inflectionStrategy: InflectionStrategy {
        switch self {
        case .english: .englishSuffixes
        case .french, .thai: .exactOnly
        }
    }

    /// Thai is tonal, so tone is part of the item being learned and must be shown
    /// and spoken, not treated as decoration.
    public var isTonal: Bool { self == .thai }

    /// Grammatical properties worth prompting for on a user-created word. Drives the
    /// entry editor and the fields shown in `EntryDetailView`.
    public var grammarFields: [GrammarField] {
        switch self {
        case .english: [.irregularForms]
        case .french: [.gender, .irregularForms]
        case .thai: [.classifier, .toneMarks]
        }
    }

    /// Voice used by `AVSpeechSynthesizer`. A language tag rather than a specific
    /// voice identifier, so the system picks the best installed voice and we degrade
    /// gracefully when the premium voice is not downloaded.
    public var speechLanguageTag: String {
        switch self {
        case .english: "en-US"
        case .french: "fr-FR"
        case .thai: "th-TH"
        }
    }

    /// Locale used for collation, so Browse sorts the way a native speaker expects
    /// (French accents fold, Thai orders by its own alphabet).
    public var sortLocale: Locale { Locale(identifier: rawValue) }

    /// Bundled seed packs, in import order.
    public var seedPackNames: [String] {
        switch self {
        case .english: ["en_core_a1_a2", "en_core_b1_b2", "en_core_c1"]
        case .french: ["fr_starter"]
        case .thai: ["th_starter"]
        }
    }

    /// English is the launch language; the others ship as real but small packs so the
    /// abstraction is exercised by tests today rather than being discovered wrong later.
    public var isFullyStocked: Bool { self == .english }

    public static let `default` = LearningLanguage.english

    public init?(code: String) {
        // Tolerate region-qualified tags ("en-GB") from persisted preferences and
        // from Locale.preferredLanguages.
        let base = code.split(separator: "-").first.map(String.init) ?? code
        guard let match = LearningLanguage(rawValue: base.lowercased()) else { return nil }
        self = match
    }
}

public enum PhoneticNotation: String, Codable, CaseIterable, Hashable, Sendable {
    /// International Phonetic Alphabet.
    case ipa
    /// Royal Thai General System of Transcription.
    case rtgs
    /// Hanyu Pinyin, for a future Mandarin pack.
    case pinyin
    case none

    public var label: String {
        switch self {
        case .ipa: "国际音标"
        case .rtgs: "罗马音"
        case .pinyin: "拼音"
        case .none: ""
        }
    }
}

/// Open set of per-language grammar metadata keys.
///
/// Stored as string keys in `Entry.grammarNotes` rather than as columns, so French
/// gender and Thai classifiers do not each cost a schema migration.
public enum GrammarField: String, Codable, CaseIterable, Hashable, Sendable {
    case gender
    case classifier
    case irregularForms
    case toneMarks
    case plural
    case conjugation

    public var label: String {
        switch self {
        case .gender: "阴阳性"
        case .classifier: "量词"
        case .irregularForms: "不规则变化"
        case .toneMarks: "声调"
        case .plural: "复数"
        case .conjugation: "动词变位"
        }
    }
}

/// CEFR proficiency band, used to gate which words the daily batch may introduce.
public enum CEFRLevel: String, Codable, CaseIterable, Hashable, Sendable, Comparable, Identifiable {
    case a1 = "A1"
    case a2 = "A2"
    case b1 = "B1"
    case b2 = "B2"
    case c1 = "C1"
    case c2 = "C2"

    public var id: String { rawValue }

    private var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: CEFRLevel, rhs: CEFRLevel) -> Bool { lhs.order < rhs.order }

    public var description: String {
        switch self {
        case .a1: "入门"
        case .a2: "初级"
        case .b1: "中级"
        case .b2: "中高级"
        case .c1: "高级"
        case .c2: "精通"
        }
    }
}

/// Part of speech. Deliberately a closed set: an open string field turns into
/// "noun" / "Noun" / "n." within a week of the first content import.
public enum PartOfSpeech: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case noun
    case verb
    case adjective
    case adverb
    case pronoun
    case preposition
    case conjunction
    case determiner
    case interjection
    case numeral
    case particle
    case classifier
    case phrase
    case idiom
    case other

    public var id: String { rawValue }

    /// Compact form for the chip on a flashcard.
    public var abbreviation: String {
        switch self {
        case .noun: "n."
        case .verb: "v."
        case .adjective: "adj."
        case .adverb: "adv."
        case .pronoun: "pron."
        case .preposition: "prep."
        case .conjunction: "conj."
        case .determiner: "det."
        case .interjection: "interj."
        case .numeral: "num."
        case .particle: "part."
        case .classifier: "clf."
        case .phrase: "phr."
        case .idiom: "idiom"
        case .other: "—"
        }
    }

    public var displayName: String {
        switch self {
        case .noun: "名词"
        case .verb: "动词"
        case .adjective: "形容词"
        case .adverb: "副词"
        case .pronoun: "代词"
        case .preposition: "介词"
        case .conjunction: "连词"
        case .determiner: "限定词"
        case .interjection: "感叹词"
        case .numeral: "数词"
        case .particle: "小品词"
        case .classifier: "量词"
        case .phrase: "短语"
        case .idiom: "习语"
        case .other: "其他"
        }
    }

    /// Lenient parse so a seed pack written by hand, or a future importer fed by an
    /// external dictionary, does not fail on `"Noun"` or `"v"`.
    public init(lenient raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "n", "n.", "noun": self = .noun
        case "v", "v.", "verb": self = .verb
        case "adj", "adj.", "adjective": self = .adjective
        case "adv", "adv.", "adverb": self = .adverb
        case "pron", "pronoun": self = .pronoun
        case "prep", "preposition": self = .preposition
        case "conj", "conjunction": self = .conjunction
        case "det", "determiner", "article": self = .determiner
        case "interj", "interjection": self = .interjection
        case "num", "numeral", "number": self = .numeral
        case "part", "particle": self = .particle
        case "clf", "classifier": self = .classifier
        case "phrase": self = .phrase
        case "idiom": self = .idiom
        default: self = PartOfSpeech(rawValue: key) ?? .other
        }
    }
}
