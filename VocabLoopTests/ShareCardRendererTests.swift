import UIKit
import XCTest
@testable import VocabLoop

/// One of every share card, with plausible values. Shared by the renderer and privacy suites.
enum ShareCardFixtures {
    static let look = MochiLook(stage: .kid, color: .vanilla, accessories: [.redScarf])

    static let goal = GoalCard(
        reviewsToday: 30, dailyGoal: 30, streak: 7, minutes: 12, look: look, level: 6, dayKey: "2026-10-01"
    )
    static let streak = StreakCard(streak: 7, longest: 12, look: look, level: 6)
    static let badge = BadgeCard(
        id: .night_owl, name: "Night owl", detail: "Study after 9 pm",
        symbolName: "moon.stars.fill", unlockedAt: Date(timeIntervalSince1970: 1_789_000_000),
        look: look, level: 6
    )
    static let mochi = MochiCard(look: look, level: 6, candy: 1_240, stageName: "Little Mochi")
    static let word = WordCard(
        headword: "ubiquitous", phonetic: "/juːˈbɪk.wɪ.təs/",
        definition: "seeming to be everywhere at the same time",
        example: "Phones are ubiquitous in cities now.", exampleCloze: nil,
        languageCode: "en", look: look
    )
    static let album = AlbumCard(
        albumTitle: "A1 Nouns · Page 3", familyTitle: "Nouns", albumLevel: "A1",
        page: 3, stickerCount: 12, look: look, level: 6
    )
    static let recap = WeeklyRecap(
        weekStartKey: "2026-09-25",
        dayKeys: ["2026-09-25", "2026-09-26", "2026-09-27", "2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01"],
        studiedDays: [true, true, false, true, true, true, true],
        reviews: 182, accuracy: 0.86, minutes: 64, wordsMastered: 12, wordsStarted: 20,
        bestCombo: 17, candyEarned: 260, level: 6, look: look, streak: 5,
        nailedWords: [
            RecapWord(entryStableID: "a", headword: "because", translation: "因为"),
            RecapWord(entryStableID: "b", headword: "window", translation: "窗户"),
        ],
        headline: "This week you mastered 12 words"
    )

    /// One per ``ShareCard`` case. The switch keeps it exhaustive: a new case fails to compile
    /// here until it has a fixture.
    static var all: [ShareCard] {
        ShareCard.Kind.allCases.map { kind -> ShareCard in
            switch kind {
            case .goal: return .goalComplete(goal)
            case .streak: return .streak(streak)
            case .badge: return .badge(badge)
            case .mochi: return .mochi(mochi)
            case .word: return .word(word)
            case .album: return .album(album)
            case .week: return .week(recap)
            }
        }
    }
}

/// Every card renders to a 1080×1350 PNG on disk (sharing plan §5).
@MainActor
final class ShareCardRendererTests: XCTestCase {
    /// A fresh directory per test, removed by the caller's `defer`.
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareCardRendererTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testEveryCardRendersA1080By1350PNG() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        for card in ShareCardFixtures.all {
            let url = try XCTUnwrap(ShareCardRenderer.writePNG(card, to: directory), "\(card.kind) did not render")
            let data = try Data(contentsOf: url)
            XCTAssertEqual(Array(data.prefix(8)), pngSignature, "\(card.kind) is not a PNG")
            let image = try XCTUnwrap(UIImage(data: data))
            XCTAssertEqual(image.size.width * image.scale, 1080, "\(card.kind)")
            XCTAssertEqual(image.size.height * image.scale, 1350, "\(card.kind)")
            XCTAssertEqual(url.lastPathComponent, card.fileName)
        }
    }

    func testRenderedCardCarriesHeadlineAndMessage() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let card = ShareCard.streak(ShareCardFixtures.streak)
        let rendered = try XCTUnwrap(ShareCardRenderer.render(card, to: directory))
        XCTAssertEqual(rendered.headline, "7 days in a row")
        XCTAssertTrue(rendered.message.hasSuffix(AppLinks.appStore.absoluteString))
    }

    func testSameCardSameFileName() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let card = ShareCard.goalComplete(ShareCardFixtures.goal)
        let first = try XCTUnwrap(ShareCardRenderer.writePNG(card, to: directory))
        let second = try XCTUnwrap(ShareCardRenderer.writePNG(card, to: directory))
        XCTAssertEqual(first, second)
        XCTAssertEqual(card.fileName, "VocabLoop-goal-2026-10-01.png")
    }

    func testFileNamesAreDistinctAndSafe() {
        let names = ShareCardFixtures.all.map(\.fileName)
        XCTAssertEqual(Set(names).count, names.count)
        for name in names {
            XCTAssertTrue(name.hasPrefix("VocabLoop-") && name.hasSuffix(".png"), name)
            XCTAssertFalse(name.dropLast(4).contains("."), name)
            XCTAssertFalse(name.contains("/"), name)
            XCTAssertFalse(name.contains(" "), name)
        }
        XCTAssertEqual(ShareCard.week(ShareCardFixtures.recap).fileName, "VocabLoop-my-week-2026-09-25.png")
        XCTAssertEqual(ShareCard.sanitized("à la carte / c'est"), "à-la-carte-c-est")
        XCTAssertEqual(ShareCard.sanitized("///"), "card")
    }

    func testUnwritableDirectoryGivesNilWithoutThrowing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareCardRendererTests-missing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("does/not/exist", isDirectory: true)
        XCTAssertNil(ShareCardRenderer.writePNG(.mochi(ShareCardFixtures.mochi), to: missing))
        XCTAssertNil(ShareCardRenderer.render(.mochi(ShareCardFixtures.mochi), to: missing))
    }

    func testRecapWrapperStillWritesTheWeek() throws {
        let url = try XCTUnwrap(RecapShareRenderer.writePNG(for: ShareCardFixtures.recap))
        XCTAssertEqual(url.lastPathComponent, "VocabLoop-my-week-2026-09-25.png")
        try? FileManager.default.removeItem(at: url)
    }
}
