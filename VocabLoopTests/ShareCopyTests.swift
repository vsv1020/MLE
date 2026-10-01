import XCTest
@testable import VocabLoop

/// Share-card wording (sharing plan §1, §5): singular, plural and a kind zero per card, and never
/// a word about what did not happen.
final class ShareCopyTests: XCTestCase {
    func testGoalHeadline() {
        XCTAssertEqual(ShareCopy.goalHeadline(reviews: 30), "Daily goal done — 30 words today")
        XCTAssertEqual(ShareCopy.goalHeadline(reviews: 1), "Daily goal done — 1 word today")
        XCTAssertEqual(ShareCopy.goalHeadline(reviews: 0), "Daily goal done today")
    }

    func testStreakHeadline() {
        XCTAssertEqual(ShareCopy.streakHeadline(days: 7), "7 days in a row")
        XCTAssertEqual(ShareCopy.streakHeadline(days: 1), "1 day in a row")
        XCTAssertEqual(ShareCopy.streakHeadline(days: 0), "Ready for a new streak")
    }

    func testBadgeHeadline() {
        XCTAssertEqual(ShareCopy.badgeHeadline(name: "Night owl"), "New badge: Night owl")
        XCTAssertEqual(ShareCopy.badgeHeadline(name: "  "), "A new badge")
    }

    func testMochiHeadline() {
        XCTAssertEqual(ShareCopy.mochiHeadline(level: 6), "Meet my Mochi — level 6")
        XCTAssertEqual(ShareCopy.mochiHeadline(level: 0), "Meet my Mochi — level 1")
    }

    func testWordHeadline() {
        XCTAssertEqual(ShareCopy.wordHeadline(headword: "ubiquitous"), "Today I learned ubiquitous")
    }

    func testAlbumHeadline() {
        XCTAssertEqual(ShareCopy.albumHeadline(stickers: 12), "Page complete — 12 shining stickers")
        XCTAssertEqual(ShareCopy.albumHeadline(stickers: 1), "Page complete — 1 shining sticker")
        XCTAssertEqual(ShareCopy.albumHeadline(stickers: 0), "Page complete")
    }

    func testDetailsLeaveOutZeroes() {
        XCTAssertNil(ShareCopy.minutes(0))
        XCTAssertEqual(ShareCopy.minutes(1), "1 min")
        XCTAssertEqual(ShareCopy.minutes(12), "12 min")
        XCTAssertNil(ShareCopy.streakChip(0))
        XCTAssertEqual(ShareCopy.streakChip(4), "4-day streak")
        XCTAssertNil(ShareCopy.goalChip(0))
        XCTAssertEqual(ShareCopy.goalChip(30), "Goal: 30 a day")
        // A best run is offered only when it is a record above today's, never as a comparison.
        XCTAssertNil(ShareCopy.longestChip(current: 9, longest: 9))
        XCTAssertNil(ShareCopy.longestChip(current: 9, longest: 4))
        XCTAssertEqual(ShareCopy.longestChip(current: 3, longest: 12), "Best: 12 days")
    }

    func testMessageCarriesTheAppStoreLink() {
        XCTAssertEqual(AppLinks.appStore.absoluteString, "https://apps.apple.com/app/id6800027452")
        XCTAssertEqual(
            ShareCopy.message(headline: "7 days in a row"),
            "7 days in a row · https://apps.apple.com/app/id6800027452"
        )
        XCTAssertEqual(ShareCopy.appStoreShortLink, "apps.apple.com/app/id6800027452")
    }

    func testEmphasisPrefersClozeThenHeadword() {
        let cloze = ShareCopy.emphasis(in: "She lent me her bicycle.", cloze: "She {{lent}} me her bicycle.", headword: "lend")
        XCTAssertEqual(cloze?.before, "She ")
        XCTAssertEqual(cloze?.match, "lent")
        XCTAssertEqual(cloze?.after, " me her bicycle.")

        let plain = ShareCopy.emphasis(in: "Phones are Ubiquitous now.", cloze: nil, headword: "ubiquitous")
        XCTAssertEqual(plain?.match, "Ubiquitous")
        XCTAssertEqual(plain?.after, " now.")

        XCTAssertNil(ShareCopy.emphasis(in: "Nothing here.", cloze: nil, headword: "window"))
    }

    func testNeverMentionsFailure() {
        var lines: [String] = []
        for count in [0, 1, 2, 3, 7, 12, 30, 100] {
            lines.append(ShareCopy.goalHeadline(reviews: count))
            lines.append(ShareCopy.streakHeadline(days: count))
            lines.append(ShareCopy.mochiHeadline(level: count))
            lines.append(ShareCopy.albumHeadline(stickers: count))
            lines.append(RecapCopy.headline(wordsMastered: count))
            lines.append(ShareCopy.minutes(count) ?? "")
            lines.append(ShareCopy.streakChip(count) ?? "")
            lines.append(ShareCopy.goalChip(count) ?? "")
            lines.append(ShareCopy.longestChip(current: count, longest: count * 2) ?? "")
        }
        for achievement in AchievementCatalog.all {
            lines.append(ShareCopy.badgeHeadline(name: achievement.name))
        }
        lines.append(ShareCopy.wordHeadline(headword: "because"))
        lines.append(ShareCopy.invite)
        lines.append(contentsOf: ShareCard.Kind.allCases.map(ShareCopy.eyebrow))

        let forbidden = try! NSRegularExpression(pattern: "missed|only|failed|0 left|lost", options: [.caseInsensitive])
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            XCTAssertNil(forbidden.firstMatch(in: line, range: range), "“\(line)” mentions what did not happen")
        }
    }
}
