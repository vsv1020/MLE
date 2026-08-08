import XCTest
import SwiftData
@testable import VocabLoop

/// Browse is the second-most-used screen and had no tests. These pin the two properties a
/// dictionary search is actually judged on: that the order is the same every time, and that
/// folding works everywhere the user might type — not just where the script happens to be
/// case- and accent-free.
@MainActor
final class SearchTests: XCTestCase {

    private func makeFixture() throws -> (ModelContext, SearchService) {
        let context = try TestStore.makeContext()
        _ = try context.activeAccount()
        return (context, SearchService(context: context))
    }

    /// A sense with translations and synonyms, which `TestStore.makeEntry` does not build.
    @discardableResult
    private func makeEntry(
        in context: ModelContext,
        headword: String,
        definition: String,
        translations: [String: String] = [:],
        synonyms: [String] = [],
        frequencyRank: Int = 100
    ) throws -> Entry {
        let entry = Entry(
            stableID: Entry.makeStableID(language: "en", headword: headword),
            languageCode: "en",
            headword: headword,
            partsOfSpeech: [.verb],
            cefr: .b1,
            frequencyRank: frequencyRank
        )
        context.insert(entry)
        let sense = Sense(
            order: 0, partOfSpeech: .verb, definition: definition,
            translations: translations, synonyms: synonyms
        )
        context.insert(sense)
        sense.entry = entry
        entry.senses.append(sense)
        try context.save()
        return entry
    }

    // MARK: - Ordering

    /// The same query must produce the same order every time.
    ///
    /// `rank` puts results in one of four buckets, so on any real query almost everything ties.
    /// Swift's `sort` is not stable, so ranking by bucket alone left ties in an arbitrary order
    /// and the Browse list could shuffle itself between two identical searches.
    func testResultOrderIsStableAcrossRepeatedIdenticalSearches() throws {
        let (context, search) = try makeFixture()

        // Twelve substring matches, all in the same rank bucket, so ties are the norm.
        for letter in "abcdefghijkl" {
            try makeEntry(
                in: context, headword: "un\(letter)ind", definition: "not kind at all"
            )
        }

        let filter = BrowseFilter(query: "ind")
        let first = try search.search(filter, language: .english).map(\.id)
        XCTAssertEqual(first.count, 12, "the fixture must actually produce ties")

        for attempt in 1...5 {
            let again = try search.search(filter, language: .english).map(\.id)
            XCTAssertEqual(again, first, "order changed on attempt \(attempt)")
        }
    }

    /// Ties keep the alphabetical order the fetch established, rather than an arbitrary one.
    func testTiedResultsStayAlphabetical() throws {
        let (context, search) = try makeFixture()
        for headword in ["zebra crossing", "apple crossing", "middle crossing"] {
            try makeEntry(in: context, headword: headword, definition: "a place to cross")
        }

        let results = try search.search(BrowseFilter(query: "crossing"), language: .english)
        XCTAssertEqual(
            results.map(\.entry.headword),
            ["apple crossing", "middle crossing", "zebra crossing"]
        )
    }

    /// Better matches must survive truncation, which is the whole reason ranking happens
    /// before `prefix(limit)`.
    func testRankingPutsAnExactHeadwordFirstAndPrefixesBeforeSubstrings() throws {
        let (context, search) = try makeFixture()
        try makeEntry(in: context, headword: "misplace", definition: "to put somewhere wrong")
        try makeEntry(in: context, headword: "place", definition: "a location")
        try makeEntry(in: context, headword: "placeholder", definition: "a stand-in")
        try makeEntry(in: context, headword: "elsewhere", definition: "in another place entirely")

        let results = try search.search(BrowseFilter(query: "place"), language: .english)
        XCTAssertEqual(
            results.map(\.entry.headword),
            ["place", "placeholder", "misplace", "elsewhere"]
        )
        XCTAssertTrue(
            results.last?.matchedInDefinition == true,
            "the definition-only match must be marked, so the row can show why it matched"
        )
    }

    // MARK: - Folding

    func testHeadwordSearchFoldsCaseAndDiacritics() throws {
        let (context, search) = try makeFixture()
        try makeEntry(in: context, headword: "Café", definition: "a place that serves coffee")

        for query in ["cafe", "CAFE", "Café", "  café  "] {
            let results = try search.search(BrowseFilter(query: query), language: .english)
            XCTAssertEqual(results.count, 1, "no match for \(query.debugDescription)")
        }
    }

    /// Translations were compared raw while the needle was folded, so a translation with a
    /// capital letter or an accent never matched. Chinese hid it — the script has neither.
    func testTranslationSearchFoldsCaseAndDiacriticsToo() throws {
        let (context, search) = try makeFixture()
        try makeEntry(
            in: context, headword: "abandon", definition: "to leave behind for good",
            translations: ["fr": "Abandonner", "zh": "抛弃", "es": "Dejár"]
        )

        for query in ["abandonner", "ABANDONNER", "dejar", "抛弃"] {
            let results = try search.search(BrowseFilter(query: query), language: .english)
            XCTAssertEqual(
                results.count, 1,
                "translation search missed \(query.debugDescription)"
            )
            // `first?` rather than `[0]`: XCTest carries on after a failed assertion, and an
            // out-of-range subscript would take the whole test bundle down with it.
            XCTAssertTrue(
                results.first?.matchedInDefinition == true,
                "a translation hit is not a headword hit"
            )
        }
    }

    func testSynonymSearchAlsoFolds() throws {
        let (context, search) = try makeFixture()
        try makeEntry(
            in: context, headword: "naive", definition: "lacking experience",
            synonyms: ["Naïve", "credulous"]
        )
        XCTAssertEqual(
            try search.search(BrowseFilter(query: "naive"), language: .english).count, 1
        )
        XCTAssertEqual(
            try search.search(BrowseFilter(query: "credulous"), language: .english).count, 1
        )
    }

    // MARK: - Filters

    func testAnEmptyQueryReturnsEverythingInAlphabeticalOrder() throws {
        let (context, search) = try makeFixture()
        for headword in ["gamma", "alpha", "beta"] {
            try makeEntry(in: context, headword: headword, definition: "a letter")
        }
        let results = try search.search(BrowseFilter(), language: .english)
        XCTAssertEqual(results.map(\.entry.headword), ["alpha", "beta", "gamma"])
    }

    func testSearchIsScopedToOneLanguage() throws {
        let (context, search) = try makeFixture()
        try makeEntry(in: context, headword: "table", definition: "a piece of furniture")

        let french = Entry(
            stableID: Entry.makeStableID(language: "fr", headword: "table"),
            languageCode: "fr", headword: "table", partsOfSpeech: [.noun]
        )
        context.insert(french)
        try context.save()

        XCTAssertEqual(
            try search.search(BrowseFilter(query: "table"), language: .english).count, 1
        )
        XCTAssertEqual(
            try search.search(BrowseFilter(query: "table"), language: .french).count, 1
        )
    }

    func testLimitTruncatesAfterRankingRatherThanBefore() throws {
        let (context, search) = try makeFixture()
        // Ten definition-only matches inserted first, then the exact headword last, so a
        // truncate-then-rank implementation would drop the best result.
        for index in 0..<10 {
            try makeEntry(
                in: context, headword: "aaa\(index)", definition: "something about a bicycle"
            )
        }
        try makeEntry(in: context, headword: "bicycle", definition: "a two-wheeled vehicle")

        let results = try search.search(BrowseFilter(query: "bicycle"), language: .english, limit: 1)
        XCTAssertEqual(results.map(\.entry.headword), ["bicycle"])
    }
}
