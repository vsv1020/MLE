import Foundation
import SwiftData

/// Filters applied to the Browse list.
public struct BrowseFilter: Equatable, Sendable {
    public var query: String
    public var cefrLevels: Set<CEFRLevel>
    public var partsOfSpeech: Set<PartOfSpeech>
    public var maturities: Set<CardMaturity>
    public var deckSlug: String?
    public var onlyFlagged: Bool

    public init(
        query: String = "",
        cefrLevels: Set<CEFRLevel> = [],
        partsOfSpeech: Set<PartOfSpeech> = [],
        maturities: Set<CardMaturity> = [],
        deckSlug: String? = nil,
        onlyFlagged: Bool = false
    ) {
        self.query = query
        self.cefrLevels = cefrLevels
        self.partsOfSpeech = partsOfSpeech
        self.maturities = maturities
        self.deckSlug = deckSlug
        self.onlyFlagged = onlyFlagged
    }

    public var isEmpty: Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty
            && cefrLevels.isEmpty && partsOfSpeech.isEmpty && maturities.isEmpty
            && deckSlug == nil && !onlyFlagged
    }

    public var activeFilterCount: Int {
        cefrLevels.count + partsOfSpeech.count + maturities.count
            + (deckSlug == nil ? 0 : 1) + (onlyFlagged ? 1 : 0)
    }
}

/// Dictionary search and filtering.
///
/// Matching is done in Swift after a language-scoped fetch rather than in a SwiftData
/// predicate. That is a deliberate trade: predicates cannot fold diacritics or search
/// inside a relationship's definitions, and a search that misses "café" when you type
/// "cafe" is worse than one that scans a few thousand rows.
@MainActor
public final class SearchService {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    /// One search result, with the reason it matched so the UI can show context.
    ///
    /// Deliberately **not** `Sendable`: it holds an `Entry`, which is a SwiftData `@Model`
    /// class bound to a `ModelContext` and unsafe to move across actors. Search runs on the
    /// main actor and its results are consumed there, so claiming `Sendable` would have been
    /// a false promise the compiler flagged.
    public struct Result: Identifiable {
        public let entry: Entry
        /// Where the match was found. Definition matches show the matching definition
        /// in the row, because otherwise the result looks like a mistake.
        public let matchedInDefinition: Bool
        public var id: String { entry.stableID }
    }

    public func search(
        _ filter: BrowseFilter,
        language: LearningLanguage,
        limit: Int = 200
    ) throws -> [Result] {
        let languageCode = language.rawValue
        let entries = try context.fetch(
            FetchDescriptor<Entry>(
                predicate: #Predicate { $0.languageCode == languageCode },
                sortBy: [SortDescriptor(\.normalizedHeadword)]
            )
        )

        let needle = Entry.normalize(filter.query)
        var results: [Result] = []

        for entry in entries {
            if !filter.cefrLevels.isEmpty {
                guard let level = entry.cefr, filter.cefrLevels.contains(level) else { continue }
            }
            if !filter.partsOfSpeech.isEmpty {
                guard !filter.partsOfSpeech.isDisjoint(with: Set(entry.partsOfSpeech)) else { continue }
            }
            if !filter.maturities.isEmpty {
                guard filter.maturities.contains(entry.maturity) else { continue }
            }
            if let deckSlug = filter.deckSlug {
                guard entry.decks.contains(where: { $0.slug == deckSlug }) else { continue }
            }
            if filter.onlyFlagged {
                guard entry.cards.contains(where: \.isFlagged) else { continue }
            }

            guard !needle.isEmpty else {
                results.append(Result(entry: entry, matchedInDefinition: false))
                continue
            }

            if entry.normalizedHeadword.contains(needle) {
                results.append(Result(entry: entry, matchedInDefinition: false))
            } else if matchesDefinitionOrTranslation(entry, needle: needle) {
                results.append(Result(entry: entry, matchedInDefinition: true))
            }
        }

        // Rank before truncating, or the limit would cut off the best matches.
        //
        // Decorated with the rank *and* the original position, for two reasons. `sort` calls its
        // predicate O(n log n) times and `rank` walks strings, so computing it once per result
        // rather than once per comparison is the difference on a 10,000-word dictionary. And
        // Swift's sort is not stable: with only four rank buckets almost everything ties, and
        // ties would come back in an arbitrary order — the same search would produce a
        // differently-ordered list each time it ran. The index preserves the alphabetical order
        // the fetch already established.
        if !needle.isEmpty {
            results = results.enumerated()
                .map { (rank: rank($0.element, needle: needle), index: $0.offset, result: $0.element) }
                .sorted { lhs, rhs in
                    lhs.rank == rhs.rank ? lhs.index < rhs.index : lhs.rank < rhs.rank
                }
                .map(\.result)
        }
        return Array(results.prefix(limit))
    }

    /// Also searches translations, so a Chinese-speaking learner can find a word by
    /// typing "抛弃" — which is how people actually look words up.
    private func matchesDefinitionOrTranslation(_ entry: Entry, needle: String) -> Bool {
        entry.senses.contains { sense in
            if Entry.normalize(sense.definition).contains(needle) { return true }
            // Normalised like everything else. `needle` has already been folded, so comparing it
            // against a raw translation meant "Abandonner" never matched "abandonner" — the
            // Chinese case happened to work because the script has no case or diacritics, which
            // is exactly the kind of coincidence that hides a bug for every other language.
            if sense.translations.values.contains(where: { Entry.normalize($0).contains(needle) }) {
                return true
            }
            if sense.synonyms.contains(where: { Entry.normalize($0).contains(needle) }) { return true }
            return false
        }
    }

    /// Lower sorts first: exact headword, then prefix, then substring, then definition.
    private func rank(_ result: Result, needle: String) -> Int {
        let headword = result.entry.normalizedHeadword
        if headword == needle { return 0 }
        if headword.hasPrefix(needle) { return 1 }
        if !result.matchedInDefinition { return 2 }
        return 3
    }

    /// Words the user opened recently, for the empty search state.
    public func recentlyViewed(language: LearningLanguage, limit: Int = 10) throws -> [Entry] {
        let languageCode = language.rawValue
        var descriptor = FetchDescriptor<Entry>(
            predicate: #Predicate { $0.languageCode == languageCode && $0.lastViewedAt != nil },
            sortBy: [SortDescriptor(\.lastViewedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    public func markViewed(_ entry: Entry, now: Date = Date()) throws {
        entry.lastViewedAt = now
        try context.save()
    }

    /// Create a user's own word, or return the existing entry if the headword is already
    /// in the dictionary.
    ///
    /// Returning the existing entry rather than erroring is the right behaviour for the
    /// "no results — add it as a custom word" flow: a user who cannot find a word
    /// because of a typo should land on the real entry, not create a duplicate.
    public func createUserEntry(
        headword: String,
        definition: String,
        partOfSpeech: PartOfSpeech,
        language: LearningLanguage,
        translation: String? = nil,
        example: String? = nil,
        phonetic: String? = nil,
        now: Date = Date()
    ) throws -> Entry {
        let normalized = Entry.normalize(headword)
        let languageCode = language.rawValue
        let existing = try context.fetch(
            FetchDescriptor<Entry>(
                predicate: #Predicate {
                    $0.languageCode == languageCode && $0.normalizedHeadword == normalized
                }
            )
        )
        if let match = existing.first { return match }

        let entry = Entry(
            stableID: "user:\(languageCode):\(UUID().uuidString)",
            languageCode: languageCode,
            headword: headword.trimmingCharacters(in: .whitespacesAndNewlines),
            phonetic: phonetic,
            phoneticNotation: language.phoneticNotation,
            partsOfSpeech: [partOfSpeech],
            isUserCreated: true,
            now: now
        )
        context.insert(entry)

        var translations: [String: String] = [:]
        if let translation, !translation.isEmpty {
            let native = StudyPreferences.systemNativeLanguageCodes().first ?? "en"
            translations[native] = translation
        }
        let sense = Sense(
            order: 0,
            partOfSpeech: partOfSpeech,
            definition: definition,
            translations: translations,
            examples: example.map { [ExampleSentence(text: $0)] } ?? []
        )
        context.insert(sense)
        sense.entry = entry
        entry.senses.append(sense)

        try context.save()
        return entry
    }
}
