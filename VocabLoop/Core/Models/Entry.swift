import Foundation
import SwiftData

/// One dictionary headword in one language.
///
/// `Entry` is *content*: it holds no scheduling state. Whether the user is learning
/// the word lives on ``Card``, which is what lets Browse show the whole dictionary
/// without silently enrolling every word the user glances at.
@Model
public final class Entry {
    /// Stable, content-addressed identity — `"en:abandon:1"` (language : headword :
    /// homograph index).
    ///
    /// Unique so that re-importing a seed pack upserts instead of duplicating, which
    /// is what makes import idempotent and content updates shippable.
    @Attribute(.unique) public var stableID: String

    /// BCP-47 code. Stored as a string rather than as ``LearningLanguage`` so a pack
    /// for a language this build does not know about can still be stored and ignored
    /// rather than failing to decode.
    public var languageCode: String

    /// The word as it should be displayed.
    public var headword: String

    /// Case- and diacritic-folded form used for search and for duplicate detection.
    /// Precomputed because SwiftData predicates cannot fold on the fly.
    public var normalizedHeadword: String

    /// Pronunciation in the notation named by ``phoneticNotationRaw``.
    public var phonetic: String?
    public var phoneticNotationRaw: String

    /// Distinct parts of speech across all senses, denormalised so Browse can filter
    /// without walking the sense relationship.
    public var partsOfSpeechRaw: [String]

    public var cefrRaw: String?

    /// 1-based frequency rank in a reference corpus; lower is more common. Used to
    /// order word introduction so learners meet useful words first.
    public var frequencyRank: Int?

    /// Per-language grammar metadata — see ``GrammarField``. An open bag on purpose:
    /// French needs gender, Thai needs a classifier, and neither should cost a
    /// migration.
    public var grammarNotes: [String: String]

    /// Free-form tags: topic packs, exam lists, user labels.
    public var tags: [String]

    /// `true` for words the user added by hand. Protects them from being overwritten
    /// by a seed re-import.
    public var isUserCreated: Bool

    public var createdAt: Date
    public var updatedAt: Date
    public var lastViewedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \Sense.entry)
    public var senses: [Sense]

    @Relationship(deleteRule: .cascade, inverse: \Card.entry)
    public var cards: [Card]

    @Relationship(inverse: \Deck.entries)
    public var decks: [Deck]

    public init(
        stableID: String,
        languageCode: String,
        headword: String,
        phonetic: String? = nil,
        phoneticNotation: PhoneticNotation = .ipa,
        partsOfSpeech: [PartOfSpeech] = [],
        cefr: CEFRLevel? = nil,
        frequencyRank: Int? = nil,
        grammarNotes: [String: String] = [:],
        tags: [String] = [],
        isUserCreated: Bool = false,
        now: Date = Date()
    ) {
        self.stableID = stableID
        self.languageCode = languageCode
        self.headword = headword
        self.normalizedHeadword = Entry.normalize(headword)
        self.phonetic = phonetic
        self.phoneticNotationRaw = phoneticNotation.rawValue
        self.partsOfSpeechRaw = partsOfSpeech.map(\.rawValue)
        self.cefrRaw = cefr?.rawValue
        self.frequencyRank = frequencyRank
        self.grammarNotes = grammarNotes
        self.tags = tags
        self.isUserCreated = isUserCreated
        self.createdAt = now
        self.updatedAt = now
        self.senses = []
        self.cards = []
        self.decks = []
    }

    // MARK: - Typed accessors

    public var language: LearningLanguage? { LearningLanguage(code: languageCode) }

    public var phoneticNotation: PhoneticNotation {
        PhoneticNotation(rawValue: phoneticNotationRaw) ?? .none
    }

    public var cefr: CEFRLevel? {
        get { cefrRaw.flatMap(CEFRLevel.init(rawValue:)) }
        set { cefrRaw = newValue?.rawValue }
    }

    public var partsOfSpeech: [PartOfSpeech] {
        get { partsOfSpeechRaw.map { PartOfSpeech(lenient: $0) } }
        set { partsOfSpeechRaw = newValue.map(\.rawValue) }
    }

    /// Senses in author-defined order. The relationship itself is unordered, so
    /// every read site must sort — doing it here means none of them forget.
    public var orderedSenses: [Sense] {
        senses.sorted { $0.order < $1.order }
    }

    public var primarySense: Sense? { orderedSenses.first }

    /// One-line gloss for list rows and notifications.
    public var primaryDefinition: String { primarySense?.definition ?? "" }

    /// `true` once the user has enrolled this word — i.e. it has cards.
    public var isEnrolled: Bool { !cards.isEmpty }

    /// Coarse learning status shown as a dot in Browse.
    public var maturity: CardMaturity {
        guard !cards.isEmpty else { return .new }
        // The least-advanced card governs: a word whose production card is still in
        // learning is not "mature" just because recognition is.
        let order: [CardMaturity] = [.new, .learning, .young, .mature]
        return cards
            .map(\.maturity)
            .min { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) } ?? .new
    }

    /// The best cloze prompt this entry can produce, or `nil` if none of its examples
    /// contain the headword in a locatable form.
    ///
    /// Senses are walked in author order and their examples in order, so the prompt a learner
    /// sees is stable rather than depending on which example happened to match first in an
    /// unordered fetch. An authored blank is preferred over a heuristic match.
    public func clozePrompt() -> ClozePrompt? {
        guard let language else { return nil }
        var heuristic: ClozePrompt?

        for sense in orderedSenses {
            for example in sense.examples {
                if ClozeMasker.hasAuthoredBlank(example.cloze),
                   let authored = ClozeMasker.makePrompt(
                       headword: headword, sentence: example.text,
                       language: language, authored: example.cloze
                   ) {
                    return authored
                }
                if heuristic == nil {
                    heuristic = ClozeMasker.makePrompt(
                        headword: headword, sentence: example.text, language: language
                    )
                }
            }
        }
        return heuristic
    }

    /// `true` when a cloze card is worth creating for this entry.
    public var supportsCloze: Bool { clozePrompt() != nil }

    /// Case- and diacritic-insensitive key. `"Café"` and `"cafe"` collide on purpose
    /// so a user cannot create a duplicate of a word that already exists.
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Deterministic identity for a headword, so the same content always produces the
    /// same row and imports stay idempotent.
    public static func makeStableID(language: String, headword: String, homograph: Int = 1) -> String {
        "\(language):\(normalize(headword)):\(homograph)"
    }

    public func touch(_ now: Date = Date()) { updatedAt = now }
}

/// One meaning of an ``Entry``.
@Model
public final class Sense {
    /// Author-defined display order within the entry.
    public var order: Int
    public var partOfSpeechRaw: String

    /// Definition in the *target* language — the monolingual gloss.
    public var definition: String

    /// Locale code → translation. A dictionary rather than a single field so one
    /// content pack can serve learners with different native languages.
    public var translations: [String: String]

    /// Example sentences, stored as an embedded `Codable` array rather than as a
    /// relationship. They are never queried independently of their sense, and a
    /// third entity would triple the row count of the dictionary for nothing.
    public var examples: [ExampleSentence]

    public var synonyms: [String]
    public var antonyms: [String]

    /// `formal`, `informal`, `slang`, `literary`… — nil when neutral.
    public var register: String?

    /// Usage note: false friends, common learner errors, collocations.
    public var usageNote: String?

    public var entry: Entry?

    public init(
        order: Int,
        partOfSpeech: PartOfSpeech,
        definition: String,
        translations: [String: String] = [:],
        examples: [ExampleSentence] = [],
        synonyms: [String] = [],
        antonyms: [String] = [],
        register: String? = nil,
        usageNote: String? = nil
    ) {
        self.order = order
        self.partOfSpeechRaw = partOfSpeech.rawValue
        self.definition = definition
        self.translations = translations
        self.examples = examples
        self.synonyms = synonyms
        self.antonyms = antonyms
        self.register = register
        self.usageNote = usageNote
    }

    public var partOfSpeech: PartOfSpeech {
        get { PartOfSpeech(lenient: partOfSpeechRaw) }
        set { partOfSpeechRaw = newValue.rawValue }
    }

    /// Translation for the user's native language, falling back through the app's
    /// preferred languages before giving up.
    public func translation(preferring codes: [String]) -> String? {
        for code in codes {
            if let hit = translations[code] { return hit }
            if let base = code.split(separator: "-").first.map(String.init),
               let hit = translations[base] {
                return hit
            }
        }
        return nil
    }
}

/// An example sentence and its optional translation.
public struct ExampleSentence: Codable, Hashable, Sendable, Identifiable {
    public var text: String
    public var translations: [String: String]

    /// The same sentence with the target span marked, e.g.
    /// `"She {{lent}} me her bicycle."`
    ///
    /// Optional, and only needed where ``ClozeMasker`` cannot find the headword on its own —
    /// irregular verbs (`lend → lent`) and elision (`de + eau → d'eau`). It decodes as `nil`
    /// when absent, so existing stored blobs and packs without the field stay valid.
    public var cloze: String?

    /// Derived rather than stored — these live inside a `Codable` blob, so a stored
    /// UUID would change on every re-encode and break SwiftUI's diffing.
    public var id: String { text }

    public init(text: String, translations: [String: String] = [:], cloze: String? = nil) {
        self.text = text
        self.translations = translations
        self.cloze = cloze
    }

    public func translation(preferring codes: [String]) -> String? {
        for code in codes {
            if let hit = translations[code] { return hit }
            if let base = code.split(separator: "-").first.map(String.init),
               let hit = translations[base] {
                return hit
            }
        }
        return nil
    }
}
