import XCTest
import SwiftData
@testable import VocabLoop

/// The store-backed half of the sticker book (`ENGAGEMENT-PLAN.md` §1.7): albums built from a
/// real in-memory dictionary, sticker states from real cards, completion, the cache, and the
/// Plus tag. Paging itself is pinned by `CollectionPagingTests`.
@MainActor
final class CollectionServiceTests: XCTestCase {
    private var context: ModelContext!
    private var service: CollectionService!

    override func setUp() async throws {
        try await super.setUp()
        context = try TestStore.makeContext()
        service = CollectionService(context: context)
    }

    override func tearDown() async throws {
        service = nil
        context = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// `count` A1 nouns ranked 1…count, so page order is creation order.
    @discardableResult
    private func makeNouns(_ count: Int, prefix: String = "noun") throws -> [Entry] {
        try (0..<count).map { index in
            try TestStore.makeEntry(
                in: context, headword: String(format: "\(prefix)%02d", index),
                cefr: .a1, frequencyRank: index + 1
            )
        }
    }

    @discardableResult
    private func makeVerb(_ headword: String, cefr: CEFRLevel? = .a1) throws -> Entry {
        let entry = Entry(
            stableID: Entry.makeStableID(language: "en", headword: headword),
            languageCode: "en",
            headword: headword,
            partsOfSpeech: [.verb],
            cefr: cefr,
            frequencyRank: 1
        )
        context.insert(entry)
        try context.save()
        return entry
    }

    /// A review card whose interval puts it at `maturity` (young below 21 days, mature at 21+).
    private func enrol(_ entry: Entry, phase: LearningPhase = .review, interval: Double,
                       direction: CardDirection = .recognition) throws {
        try TestStore.makeCard(
            in: context, for: entry, direction: direction, phase: phase,
            due: referenceDate.addingTimeInterval(interval * 86_400), intervalDays: interval, stability: interval
        )
    }

    // MARK: - Albums

    func testAlbumsForASeededLanguageArePagedByLevelAndFamily() throws {
        try makeNouns(14)
        try makeVerb("run")
        try makeVerb("analyse", cefr: .c2)

        let albums = try service.albums(languageCode: "en")
        XCTAssertEqual(albums.map(\.id), ["en|A1|nouns|1", "en|A1|nouns|2", "en|A1|verbs|1", "en|C1|verbs|1"])
        XCTAssertEqual(albums.map(\.entryStableIDs.count), [12, 2, 1, 1])
        XCTAssertEqual(albums[1].title, "A1 名词 · 第 2 页")
        XCTAssertTrue(try service.albums(languageCode: "fr").isEmpty, "no French words, no French albums")
    }

    func testAlbumContainingFindsTheRightPage() throws {
        let nouns = try makeNouns(14)
        let page2 = try XCTUnwrap(service.album(containing: nouns[13].stableID, languageCode: "en"))
        XCTAssertEqual(page2.id, "en|A1|nouns|2")
        XCTAssertEqual(try service.album(containing: nouns[0].stableID, languageCode: "en")?.page, 1)
        XCTAssertNil(try service.album(containing: "en:nothing:1", languageCode: "en"))
    }

    func testAlbumsAreCachedUntilInvalidated() throws {
        try makeNouns(3)
        XCTAssertEqual(try service.albums(languageCode: "en").first?.entryStableIDs.count, 3)

        try makeNouns(1, prefix: "late")
        XCTAssertEqual(
            try service.albums(languageCode: "en").first?.entryStableIDs.count, 3,
            "albums are a function of the dictionary and only change on import"
        )
        service.invalidateCache()
        XCTAssertEqual(try service.albums(languageCode: "en").first?.entryStableIDs.count, 4)
    }

    // MARK: - Progress

    func testStickerStatesFollowTheLeastAdvancedCard() throws {
        let nouns = try makeNouns(6)
        // 0: never enrolled → locked.
        try enrol(nouns[1], phase: .learning, interval: 0)          // sketch
        try enrol(nouns[2], interval: 5)                              // coloured
        try enrol(nouns[3], interval: 30)                             // shiny
        try enrol(nouns[4], interval: 30)                             // mature recognition…
        try enrol(nouns[4], interval: 5, direction: .production)      // …young production → coloured
        try enrol(nouns[5], phase: .new, interval: 0)                 // enrolled, never answered → sketch

        let album = try XCTUnwrap(service.albums(languageCode: "en").first)
        let progress = try service.progress(of: album)
        XCTAssertEqual(progress.states, [.locked, .sketch, .coloured, .shiny, .coloured, .sketch])
        XCTAssertEqual(progress.shinyCount, 1)
        XCTAssertFalse(progress.isComplete)
    }

    func testAPageCompletesWhenEveryStickerShines() throws {
        let nouns = try makeNouns(14)
        // Page 2 holds the last two words; make both mature.
        try enrol(nouns[12], interval: 25)
        try enrol(nouns[13], interval: 40)
        try enrol(nouns[0], interval: 40)

        let albums = try service.albums(languageCode: "en")
        let first = try service.progress(of: albums[0])
        let second = try service.progress(of: albums[1])
        XCTAssertFalse(first.isComplete, "one shiny sticker of twelve")
        XCTAssertEqual(first.shinyCount, 1)
        XCTAssertTrue(second.isComplete, "a short last page completes at its own size")

        let summary = try service.summary(languageCode: "en")
        XCTAssertEqual(summary.albums, 2)
        XCTAssertEqual(summary.complete, 1)
        XCTAssertEqual(summary.shiny, 3)
    }

    func testAllProgressMatchesPerAlbumProgress() throws {
        let nouns = try makeNouns(14)
        try makeVerb("swim")
        try enrol(nouns[2], interval: 30)
        try enrol(nouns[13], interval: 3)

        let all = try service.allProgress(languageCode: "en")
        let albums = try service.albums(languageCode: "en")
        XCTAssertEqual(all.map(\.album), albums, "book order")
        for (combined, album) in zip(all, albums) {
            XCTAssertEqual(combined.states, try service.progress(of: album).states, album.id)
        }
    }

    func testAnEmptyPageIsNeverComplete() {
        let album = Album(languageCode: "en", level: .a1, family: .nouns, page: 1, entryStableIDs: [])
        XCTAssertFalse(AlbumProgress(album: album, states: []).isComplete)
    }

    // MARK: - Plus tag

    func testPlusTagOnlyForPagesMadeOfPlusOnlyWords() throws {
        let words = try makeNouns(3)
        let premium = Deck(slug: "en_core_b1_b2", name: "Core B1–B2", languageCode: "en")
        let free = Deck(slug: "en_core_a1_a2", name: "Core A1–A2", languageCode: "en")
        context.insert(premium)
        context.insert(free)
        premium.entries = [words[0], words[1], words[2]]
        free.entries = [words[2]]
        try context.save()

        let plusOnly = try service.plusOnlyEntryIDs(languageCode: "en")
        XCTAssertEqual(plusOnly, [words[0].stableID, words[1].stableID], "a word in a free deck is free")

        let mixed = Album(languageCode: "en", level: .a1, family: .nouns, page: 1,
                          entryStableIDs: words.map(\.stableID))
        let allPlus = Album(languageCode: "en", level: .a1, family: .nouns, page: 2,
                            entryStableIDs: [words[0].stableID, words[1].stableID])
        XCTAssertFalse(CollectionService.isPlusAlbum(mixed, plusOnlyEntryIDs: plusOnly))
        XCTAssertTrue(CollectionService.isPlusAlbum(allPlus, plusOnlyEntryIDs: plusOnly))
    }
}
