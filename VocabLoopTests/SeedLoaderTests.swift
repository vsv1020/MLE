import XCTest
import SwiftData
@testable import VocabLoop

/// Content import. The property that matters is **idempotence** — without it, shipping a content
/// update would duplicate the dictionary, and there would be no way to fix a typo in a definition
/// after release.
@MainActor
final class SeedLoaderTests: XCTestCase {
    /// Packs live in the app bundle, not the test bundle.
    ///
    /// Resolved from a type compiled into the app target rather than via `Bundle.main`, so the
    /// suite finds the packs whether it runs with a test host or not.
    private var bundle: Bundle { Bundle(for: Entry.self) }

    private func makeImporter() throws -> (SeedImporter, ModelContainer) {
        let container = try PersistenceController.makeInMemoryContainer()
        return (SeedImporter(modelContainer: container), container)
    }

    /// Clear the version gate so each test starts from an un-imported state.
    private func resetVersions() {
        for language in LearningLanguage.allCases {
            for pack in language.seedPackNames {
                UserDefaults.standard.removeObject(forKey: "seed.version.\(pack)")
            }
        }
    }

    override func setUp() {
        super.setUp()
        resetVersions()
    }

    override func tearDown() {
        resetVersions()
        super.tearDown()
    }

    // MARK: - Parsing

    /// Every bundled pack must decode. A malformed pack would leave the dictionary empty on first
    /// launch, which is indistinguishable from a broken app.
    func testEveryBundledPackParses() throws {
        for language in LearningLanguage.allCases {
            for packName in language.seedPackNames {
                let pack = try SeedImporter.loadPack(named: packName, bundle: bundle)
                XCTAssertEqual(pack.packName, packName, "packName must match its filename")
                XCTAssertEqual(pack.languageCode, language.rawValue)
                XCTAssertGreaterThanOrEqual(pack.version, 1)
                XCTAssertFalse(pack.entries.isEmpty, "\(packName) has no entries")
                XCTAssertFalse(pack.deck.name.isEmpty)

                for entry in pack.entries {
                    XCTAssertFalse(entry.headword.trimmingCharacters(in: .whitespaces).isEmpty)
                    XCTAssertFalse(entry.senses.isEmpty, "\(entry.headword) has no senses")
                    for sense in entry.senses {
                        XCTAssertFalse(
                            sense.definition.trimmingCharacters(in: .whitespaces).isEmpty,
                            "\(entry.headword) has an empty definition"
                        )
                    }
                }
            }
        }
    }

    func testPackHeadwordsAreUniqueWithinAPack() throws {
        for language in LearningLanguage.allCases {
            for packName in language.seedPackNames {
                let pack = try SeedImporter.loadPack(named: packName, bundle: bundle)
                let ids = pack.entries.map {
                    Entry.makeStableID(
                        language: pack.languageCode,
                        headword: $0.headword,
                        homograph: $0.resolvedHomograph
                    )
                }
                XCTAssertEqual(
                    Set(ids).count, ids.count,
                    "\(packName) contains duplicate headwords, which would collide on import"
                )
            }
        }
    }

    func testMissingPackThrowsARecognisableError() {
        do {
            _ = try SeedImporter.loadPack(named: "definitely_not_a_pack", bundle: bundle)
            XCTFail("expected a failure")
        } catch let error as SeedImportError {
            guard case .packNotFound = error else {
                return XCTFail("expected packNotFound, got \(error)")
            }
        } catch {
            XCTFail("expected SeedImportError, got \(error)")
        }
    }

    // MARK: - Import

    func testImportInsertsEntriesSensesAndADeck() async throws {
        let (importer, container) = try makeImporter()
        let report = try await importer.importPack(named: "en_core_a1_a2", bundle: bundle)

        XCTAssertFalse(report.skipped)
        XCTAssertGreaterThan(report.entriesInserted, 0)
        XCTAssertEqual(report.entriesUpdated, 0)

        let context = ModelContext(container)
        let entries = try context.fetch(FetchDescriptor<Entry>())
        XCTAssertEqual(entries.count, report.entriesInserted)
        XCTAssertTrue(entries.allSatisfy { !$0.senses.isEmpty })
        XCTAssertTrue(entries.allSatisfy { !$0.decks.isEmpty }, "entries must join their pack's deck")

        let deck = try context.deck(slug: "en_core_a1_a2")
        XCTAssertNotNil(deck)
        XCTAssertTrue(deck?.isBuiltIn ?? false)
    }

    /// The core guarantee. Import twice, get the same dictionary.
    func testImportIsIdempotent() async throws {
        let (importer, container) = try makeImporter()
        let first = try await importer.importPack(named: "en_core_a1_a2", bundle: bundle)

        // A fresh context per observation. A context created before the importer's save may not
        // have merged its changes, which would make this test flaky rather than wrong.
        let afterFirst = ModelContext(container)
        let entriesAfterFirst = try afterFirst.fetchCount(FetchDescriptor<Entry>())
        let sensesAfterFirst = try afterFirst.fetchCount(FetchDescriptor<Sense>())
        XCTAssertGreaterThan(entriesAfterFirst, 0)

        // Forced, to bypass the version gate and exercise the upsert path itself.
        let second = try await importer.importPack(named: "en_core_a1_a2", bundle: bundle, force: true)

        XCTAssertEqual(second.entriesInserted, 0, "nothing new should be inserted")
        XCTAssertEqual(second.entriesUpdated, first.entriesInserted)

        let afterSecond = ModelContext(container)
        XCTAssertEqual(try afterSecond.fetchCount(FetchDescriptor<Entry>()), entriesAfterFirst)
        XCTAssertEqual(
            try afterSecond.fetchCount(FetchDescriptor<Sense>()), sensesAfterFirst,
            "senses are replaced wholesale and must not accumulate"
        )
        XCTAssertEqual(try afterSecond.fetchCount(FetchDescriptor<Deck>()), 1)
    }

    /// Version gating is what makes re-import cheap on every launch after the first.
    func testSecondImportAtTheSameVersionIsSkipped() async throws {
        let (importer, _) = try makeImporter()
        _ = try await importer.importPack(named: "en_core_a1_a2", bundle: bundle)
        let second = try await importer.importPack(named: "en_core_a1_a2", bundle: bundle)

        XCTAssertTrue(second.skipped)
        XCTAssertEqual(second.entriesTouched, 0)
    }

    /// A word the user wrote themselves must survive a pack that later ships the same headword.
    func testImportDoesNotOverwriteUserCreatedEntries() async throws {
        let (importer, container) = try makeImporter()
        let context = ModelContext(container)

        let mine = Entry(
            stableID: Entry.makeStableID(language: "en", headword: "because"),
            languageCode: "en",
            headword: "because",
            isUserCreated: true
        )
        context.insert(mine)
        let sense = Sense(order: 0, partOfSpeech: .conjunction, definition: "my own definition")
        context.insert(sense)
        sense.entry = mine
        mine.senses.append(sense)
        try context.save()

        _ = try await importer.importPack(named: "en_core_a1_a2", bundle: bundle)

        // Read through a fresh context so this observes what the store holds, not what the
        // pre-import context remembers.
        let reloaded = try XCTUnwrap(
            try ModelContext(container)
                .entry(stableID: Entry.makeStableID(language: "en", headword: "because"))
        )
        XCTAssertTrue(reloaded.isUserCreated)
        XCTAssertEqual(reloaded.primaryDefinition, "my own definition")
    }

    // MARK: - Multi-language

    /// The multi-language abstraction has to be exercised, not just designed. French and Thai
    /// ship as real packs so this test is meaningful today.
    func testNonEnglishPacksImportWithTheirOwnScriptAndMetadata() async throws {
        let (importer, container) = try makeImporter()
        _ = try await importer.importPacks(for: [.french, .thai], bundle: bundle)

        let context = ModelContext(container)

        let french = try context.fetch(
            FetchDescriptor<Entry>(predicate: #Predicate { $0.languageCode == "fr" })
        )
        XCTAssertFalse(french.isEmpty)
        XCTAssertTrue(
            french.contains { !$0.grammarNotes.isEmpty },
            "French nouns carry gender, which is what the grammarNotes bag exists for"
        )
        XCTAssertTrue(french.allSatisfy { $0.phoneticNotation == .ipa })

        let thai = try context.fetch(
            FetchDescriptor<Entry>(predicate: #Predicate { $0.languageCode == "th" })
        )
        XCTAssertFalse(thai.isEmpty)
        XCTAssertTrue(thai.allSatisfy { $0.phoneticNotation == .rtgs }, "Thai romanises, it does not write IPA")
        XCTAssertTrue(
            thai.contains { $0.grammarNotes.keys.contains(GrammarField.classifier.rawValue) },
            "Thai counts with classifiers"
        )
        XCTAssertTrue(
            thai.contains { $0.headword.unicodeScalars.contains { !$0.isASCII } },
            "Thai headwords are in Thai script"
        )
    }

    func testLanguagePropertiesMatchTheirScripts() {
        XCTAssertTrue(LearningLanguage.english.isWordSeparated)
        XCTAssertTrue(LearningLanguage.french.isWordSeparated)
        XCTAssertFalse(
            LearningLanguage.thai.isWordSeparated,
            "Thai has no spaces between words — a tokenizer must not assume otherwise"
        )
        XCTAssertTrue(LearningLanguage.thai.isTonal)
        XCTAssertFalse(LearningLanguage.thai.usesLatinScript)
    }

    func testLanguageCodeParsingToleratesRegionQualifiers() {
        XCTAssertEqual(LearningLanguage(code: "en-GB"), .english)
        XCTAssertEqual(LearningLanguage(code: "EN"), .english)
        XCTAssertEqual(LearningLanguage(code: "fr-CA"), .french)
        XCTAssertNil(LearningLanguage(code: "de"))
    }

    func testPartOfSpeechParsingIsLenient() {
        XCTAssertEqual(PartOfSpeech(lenient: "Noun"), .noun)
        XCTAssertEqual(PartOfSpeech(lenient: "v."), .verb)
        XCTAssertEqual(PartOfSpeech(lenient: " adj "), .adjective)
        XCTAssertEqual(PartOfSpeech(lenient: "article"), .determiner)
        XCTAssertEqual(PartOfSpeech(lenient: "gibberish"), .other)
    }

    func testEntryNormalisationFoldsCaseAndDiacritics() {
        XCTAssertEqual(Entry.normalize("Café"), Entry.normalize("cafe"))
        XCTAssertEqual(Entry.normalize("  Abandon "), "abandon")
        XCTAssertEqual(
            Entry.makeStableID(language: "en", headword: "Abandon"),
            Entry.makeStableID(language: "en", headword: "abandon"),
            "the same word must not import twice because of capitalisation"
        )
    }
}
