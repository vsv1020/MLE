import XCTest
import SwiftData
@testable import VocabLoop

/// Sticker-book paging from `docs/ENGAGEMENT-PLAN.md` §1.7. Album IDs are persisted in the
/// engagement profile, so the paging must be stable: the same words on the same page, always.
@MainActor
final class CollectionPagingTests: XCTestCase {
    private typealias Row = (stableID: String, cefr: CEFRLevel?, pos: PartOfSpeech, rank: Int?, headword: String)

    private func row(_ headword: String, cefr: CEFRLevel? = .a1, pos: PartOfSpeech = .noun, rank: Int? = nil) -> Row {
        (stableID: "en:\(headword):1", cefr: cefr, pos: pos, rank: rank, headword: headword)
    }

    func testPagesHoldTwelveAndTheLastPageKeepsTheRemainder() {
        let rows = (0..<30).map { row(String(format: "w%02d", $0), rank: $0 + 1) }
        let albums = CollectionService.pageAlbums(entries: rows, languageCode: "en")
        XCTAssertEqual(Album.pageSize, 12)
        XCTAssertEqual(albums.map(\.entryStableIDs.count), [12, 12, 6])
        XCTAssertEqual(albums.map(\.page), [1, 2, 3])
        XCTAssertEqual(albums[0].id, "en|A1|nouns|1")
        XCTAssertEqual(albums[2].id, "en|A1|nouns|3")
        XCTAssertEqual(albums[2].title, "A1 名词 · 第 3 页")
        XCTAssertEqual(albums[0].entryStableIDs.first, "en:w00:1")
        XCTAssertEqual(albums[2].entryStableIDs.last, "en:w29:1")
    }

    func testOrderingIsByRankThenHeadwordWithUnrankedLast() {
        let rows = [
            row("zebra", rank: nil),
            row("banana", rank: 5),
            row("apple", rank: 5),
            row("cherry", rank: 1),
            row("aardvark", rank: nil),
        ]
        let albums = CollectionService.pageAlbums(entries: rows, languageCode: "en")
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(
            albums[0].entryStableIDs,
            ["en:cherry:1", "en:apple:1", "en:banana:1", "en:aardvark:1", "en:zebra:1"]
        )
        // Input order must not matter.
        let shuffled = CollectionService.pageAlbums(entries: Array(rows.reversed()), languageCode: "en")
        XCTAssertEqual(shuffled, albums)
    }

    func testFamilyMapping() {
        XCTAssertEqual(WordFamily(partOfSpeech: .noun), .nouns)
        XCTAssertEqual(WordFamily(partOfSpeech: .verb), .verbs)
        XCTAssertEqual(WordFamily(partOfSpeech: .adjective), .describingWords)
        XCTAssertEqual(WordFamily(partOfSpeech: .adverb), .describingWords)
        for pos in [PartOfSpeech.pronoun, .preposition, .conjunction, .determiner, .interjection,
                    .numeral, .particle, .classifier, .phrase, .idiom, .other] {
            XCTAssertEqual(WordFamily(partOfSpeech: pos), .littleWords, "\(pos)")
        }
    }

    func testLevelMappingFoldsC2IntoC1AndUnlevelledIntoA1() {
        XCTAssertEqual(AlbumLevel(cefr: .a1), .a1)
        XCTAssertEqual(AlbumLevel(cefr: .b2), .b2)
        XCTAssertEqual(AlbumLevel(cefr: .c1), .c1)
        XCTAssertEqual(AlbumLevel(cefr: .c2), .c1)
        XCTAssertEqual(AlbumLevel(cefr: nil), .a1)

        let albums = CollectionService.pageAlbums(
            entries: [row("erudite", cefr: .c2, pos: .adjective), row("ubiquitous", cefr: .c1, pos: .adjective)],
            languageCode: "en"
        )
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums[0].id, "en|C1|describingWords|1")
        XCTAssertEqual(albums[0].entryStableIDs.count, 2)
    }

    func testAlbumsComeOutInLevelThenFamilyOrder() {
        let rows = [
            row("run", cefr: .b1, pos: .verb),
            row("in", cefr: .a1, pos: .preposition),
            row("dog", cefr: .a1, pos: .noun),
            row("big", cefr: .a2, pos: .adjective),
            row("go", cefr: .a1, pos: .verb),
        ]
        let ids = CollectionService.pageAlbums(entries: rows, languageCode: "en").map(\.id)
        XCTAssertEqual(ids, [
            "en|A1|nouns|1",
            "en|A1|verbs|1",
            "en|A1|littleWords|1",
            "en|A2|describingWords|1",
            "en|B1|verbs|1",
        ])
    }

    func testStickerStates() {
        XCTAssertEqual(StickerState(maturity: nil, isEnrolled: false), .locked)
        XCTAssertEqual(StickerState(maturity: .mature, isEnrolled: false), .locked)
        XCTAssertEqual(StickerState(maturity: .new, isEnrolled: true), .sketch)
        XCTAssertEqual(StickerState(maturity: .learning, isEnrolled: true), .sketch)
        XCTAssertEqual(StickerState(maturity: .young, isEnrolled: true), .coloured)
        XCTAssertEqual(StickerState(maturity: .mature, isEnrolled: true), .shiny)
    }

    func testProgressCompletesOnlyWhenEveryStickerShines() {
        let album = Album(languageCode: "en", level: .a1, family: .nouns, page: 1, entryStableIDs: ["a", "b"])
        XCTAssertFalse(AlbumProgress(album: album, states: [.shiny, .coloured]).isComplete)
        XCTAssertEqual(AlbumProgress(album: album, states: [.shiny, .coloured]).shinyCount, 1)
        XCTAssertTrue(AlbumProgress(album: album, states: [.shiny, .shiny]).isComplete)
        XCTAssertFalse(AlbumProgress(album: album, states: []).isComplete, "an empty page is not an achievement")
    }

    /// The seed packs say "phrasal verb", which parses as `.other`; those belong with the verbs.
    func testPhrasalVerbsJoinTheVerbs() throws {
        let context = try TestStore.makeContext()
        let phrasal = Entry(stableID: "en:give up:1", languageCode: "en", headword: "give up", partsOfSpeech: [.other])
        let exclamation = Entry(stableID: "en:hello:1", languageCode: "en", headword: "hello", partsOfSpeech: [.other])
        context.insert(phrasal)
        context.insert(exclamation)
        XCTAssertEqual(CollectionService.albumPartOfSpeech(for: phrasal), .verb)
        XCTAssertEqual(CollectionService.albumPartOfSpeech(for: exclamation), .other)
    }

    /// The store-backed path: albums from real entries, progress from real cards.
    func testServiceBuildsAlbumsAndProgressFromTheStore() throws {
        let context = try TestStore.makeContext()
        var entries: [Entry] = []
        for index in 0..<13 {
            entries.append(try TestStore.makeEntry(in: context, headword: "noun\(index)", frequencyRank: index + 1))
        }
        try TestStore.makeCard(in: context, for: entries[0], due: referenceDate, intervalDays: 30)
        try TestStore.makeCard(in: context, for: entries[1], due: referenceDate, intervalDays: 5)

        let service = CollectionService(context: context)
        let albums = try service.albums(languageCode: "en")
        XCTAssertEqual(albums.map(\.entryStableIDs.count), [12, 1])

        let first = try service.progress(of: albums[0])
        XCTAssertEqual(first.states[0], .shiny)
        XCTAssertEqual(first.states[1], .coloured)
        XCTAssertEqual(first.states[2], .locked)
        XCTAssertEqual(first.shinyCount, 1)
        XCTAssertFalse(first.isComplete)

        XCTAssertEqual(try service.album(containing: entries[12].stableID, languageCode: "en")?.page, 2)
        let summary = try service.summary(languageCode: "en")
        XCTAssertEqual(summary.albums, 2)
        XCTAssertEqual(summary.complete, 0)
        XCTAssertEqual(summary.shiny, 1)
    }
}
