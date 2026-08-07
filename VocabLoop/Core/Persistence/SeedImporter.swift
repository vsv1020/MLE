import Foundation
import SwiftData
import OSLog

/// Imports bundled content packs into the store.
///
/// Runs on its own `ModelActor` so a first-launch import of several thousand entries
/// never blocks the main thread — the user should reach a usable Today screen while
/// the dictionary is still loading.
///
/// Import is **idempotent**. Entries are keyed by ``Entry/stableID``, so running an
/// import twice updates in place rather than duplicating. That property is what makes
/// content updates shippable at all, and it is pinned by `SeedLoaderTests`.
@ModelActor
public actor SeedImporter {
    private static let logger = Logger(subsystem: "com.vocabloop.app", category: "seed")

    /// Version of each pack already imported. `UserDefaults` rather than a table
    /// because this describes the *device's* bundled content state, not user data —
    /// it must not sync between devices running different app versions.
    private static func versionKey(_ packName: String) -> String { "seed.version.\(packName)" }

    public static func importedVersion(of packName: String, defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: versionKey(packName))
    }

    static func setImportedVersion(_ version: Int, of packName: String, defaults: UserDefaults = .standard) {
        defaults.set(version, forKey: versionKey(packName))
    }

    /// Import every pack for `languages`, skipping those already at the bundled version.
    @discardableResult
    public func importPacks(
        for languages: [LearningLanguage],
        bundle: Bundle = .main,
        force: Bool = false
    ) async throws -> [SeedImportReport] {
        var reports: [SeedImportReport] = []
        for language in languages {
            for packName in language.seedPackNames {
                let report = try importPack(named: packName, bundle: bundle, force: force)
                reports.append(report)
            }
        }
        return reports
    }

    @discardableResult
    public func importPack(
        named packName: String,
        bundle: Bundle = .main,
        force: Bool = false
    ) throws -> SeedImportReport {
        let pack = try Self.loadPack(named: packName, bundle: bundle)

        let alreadyImported = Self.importedVersion(of: packName)
        if !force, alreadyImported >= pack.version {
            return SeedImportReport(
                packName: packName, version: pack.version,
                entriesInserted: 0, entriesUpdated: 0, skipped: true
            )
        }

        let deck = try upsertDeck(for: pack)
        var inserted = 0
        var updated = 0

        // Fetch the pack's existing entries once. One query plus a dictionary beats a
        // per-entry fetch by roughly the number of entries, which on a first-launch
        // import of several thousand words is the difference between a second and a
        // minute.
        let wantedIDs = Set(pack.entries.map {
            Entry.makeStableID(
                language: pack.languageCode,
                headword: $0.headword,
                homograph: $0.resolvedHomograph
            )
        })
        let existing = try modelContext.fetch(
            FetchDescriptor<Entry>(predicate: #Predicate { wantedIDs.contains($0.stableID) })
        )
        var byStableID = Dictionary(existing.map { ($0.stableID, $0) }, uniquingKeysWith: { first, _ in first })

        for seedEntry in pack.entries {
            let stableID = Entry.makeStableID(
                language: pack.languageCode,
                headword: seedEntry.headword,
                homograph: seedEntry.resolvedHomograph
            )

            if let entry = byStableID[stableID] {
                // Never clobber a word the user wrote themselves, even if a pack later
                // ships the same headword.
                guard !entry.isUserCreated else { continue }
                apply(seedEntry, to: entry, languageCode: pack.languageCode)
                updated += 1
                if !entry.decks.contains(where: { $0.slug == deck.slug }) {
                    entry.decks.append(deck)
                }
            } else {
                let entry = makeEntry(from: seedEntry, stableID: stableID, languageCode: pack.languageCode)
                modelContext.insert(entry)
                entry.decks.append(deck)
                byStableID[stableID] = entry
                inserted += 1
            }
        }

        try modelContext.save()
        Self.setImportedVersion(pack.version, of: packName)
        Self.logger.info(
            "Imported \(packName, privacy: .public) v\(pack.version): +\(inserted) ~\(updated)"
        )

        return SeedImportReport(
            packName: packName, version: pack.version,
            entriesInserted: inserted, entriesUpdated: updated, skipped: false
        )
    }

    // MARK: - Loading

    public static func loadPack(named packName: String, bundle: Bundle = .main) throws -> SeedPack {
        guard let url = bundle.url(forResource: packName, withExtension: "json", subdirectory: "Seeds")
            ?? bundle.url(forResource: packName, withExtension: "json")
        else {
            throw SeedImportError.packNotFound(packName)
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(SeedPack.self, from: data)
        } catch let error as SeedImportError {
            throw error
        } catch {
            throw SeedImportError.decodingFailed(packName, underlying: String(describing: error))
        }
    }

    // MARK: - Upserts

    private func upsertDeck(for pack: SeedPack) throws -> Deck {
        if let existing = try modelContext.deck(slug: pack.packName) {
            existing.name = pack.deck.name
            existing.summary = pack.deck.summary
            existing.symbolName = pack.deck.symbolName ?? existing.symbolName
            existing.colorHex = pack.deck.colorHex ?? existing.colorHex
            existing.sortOrder = pack.deck.sortOrder ?? existing.sortOrder
            existing.updatedAt = Date()
            return existing
        }
        let deck = Deck(
            slug: pack.packName,
            name: pack.deck.name,
            summary: pack.deck.summary,
            languageCode: pack.languageCode,
            isBuiltIn: true,
            sortOrder: pack.deck.sortOrder ?? 0,
            colorHex: pack.deck.colorHex,
            symbolName: pack.deck.symbolName ?? "books.vertical"
        )
        modelContext.insert(deck)
        return deck
    }

    private func makeEntry(from seed: SeedEntry, stableID: String, languageCode: String) -> Entry {
        let entry = Entry(
            stableID: stableID,
            languageCode: languageCode,
            headword: seed.headword,
            phonetic: seed.phonetic,
            phoneticNotation: LearningLanguage(code: languageCode)?.phoneticNotation ?? .ipa,
            cefr: seed.resolvedCEFR,
            frequencyRank: seed.frequencyRank,
            grammarNotes: seed.grammarNotes ?? [:],
            tags: seed.tags ?? []
        )
        apply(seed, to: entry, languageCode: languageCode)
        return entry
    }

    private func apply(_ seed: SeedEntry, to entry: Entry, languageCode: String) {
        entry.headword = seed.headword
        entry.normalizedHeadword = Entry.normalize(seed.headword)
        entry.phonetic = seed.phonetic
        entry.phoneticNotationRaw = (LearningLanguage(code: languageCode)?.phoneticNotation ?? .ipa).rawValue
        entry.cefr = seed.resolvedCEFR
        entry.frequencyRank = seed.frequencyRank
        entry.grammarNotes = seed.grammarNotes ?? [:]
        entry.tags = seed.tags ?? []
        entry.updatedAt = Date()

        // Senses are replaced wholesale rather than diffed. They have no identity of
        // their own and carry no user data, so a rewrite is both simpler and correct;
        // diffing would risk leaving a stale definition attached to a word.
        for sense in entry.senses {
            modelContext.delete(sense)
        }
        entry.senses = []

        var partsOfSpeech: [PartOfSpeech] = []
        for (index, seedSense) in seed.senses.enumerated() {
            let pos = PartOfSpeech(lenient: seedSense.partOfSpeech)
            if !partsOfSpeech.contains(pos) { partsOfSpeech.append(pos) }

            let sense = Sense(
                order: index,
                partOfSpeech: pos,
                definition: seedSense.definition,
                translations: seedSense.translations ?? [:],
                examples: (seedSense.examples ?? []).map {
                    ExampleSentence(
                        text: $0.text,
                        translations: $0.translations ?? [:],
                        cloze: $0.cloze
                    )
                },
                synonyms: seedSense.synonyms ?? [],
                antonyms: seedSense.antonyms ?? [],
                register: seedSense.register,
                usageNote: seedSense.usageNote
            )
            modelContext.insert(sense)
            sense.entry = entry
            entry.senses.append(sense)
        }
        entry.partsOfSpeech = partsOfSpeech
    }
}
