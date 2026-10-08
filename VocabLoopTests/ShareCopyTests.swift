import XCTest
@testable import VocabLoop

/// Share-card wording (sharing plan §1, §5): one, many and a kind zero per card, and never a word
/// about what did not happen. The copy is Chinese, which has no plural forms.
final class ShareCopyTests: XCTestCase {
    func testGoalHeadline() {
        XCTAssertEqual(ShareCopy.goalHeadline(reviews: 30), "今日目标完成，今天学了 30 个单词")
        XCTAssertEqual(ShareCopy.goalHeadline(reviews: 1), "今日目标完成，今天学了 1 个单词")
        XCTAssertEqual(ShareCopy.goalHeadline(reviews: 0), "今日目标完成")
    }

    func testStreakHeadline() {
        XCTAssertEqual(ShareCopy.streakHeadline(days: 7), "连续打卡 7 天")
        XCTAssertEqual(ShareCopy.streakHeadline(days: 1), "连续打卡 1 天")
        XCTAssertEqual(ShareCopy.streakHeadline(days: 0), "准备开始新的连续打卡")
    }

    func testBadgeHeadline() {
        XCTAssertEqual(ShareCopy.badgeHeadline(name: "夜猫子"), "新徽章：夜猫子")
        XCTAssertEqual(ShareCopy.badgeHeadline(name: "  "), "获得一枚新徽章")
    }

    func testMochiHeadline() {
        XCTAssertEqual(ShareCopy.mochiHeadline(level: 6), "来看看我的麻薯：6 级")
        XCTAssertEqual(ShareCopy.mochiHeadline(level: 0), "来看看我的麻薯：1 级")
    }

    func testWordHeadline() {
        XCTAssertEqual(ShareCopy.wordHeadline(headword: "ubiquitous"), "今天我学会了 ubiquitous")
    }

    func testAlbumHeadline() {
        XCTAssertEqual(ShareCopy.albumHeadline(stickers: 12), "这一页集齐了：12 张闪亮贴纸")
        XCTAssertEqual(ShareCopy.albumHeadline(stickers: 1), "这一页集齐了：1 张闪亮贴纸")
        XCTAssertEqual(ShareCopy.albumHeadline(stickers: 0), "这一页集齐了")
    }

    func testDetailsLeaveOutZeroes() {
        XCTAssertNil(ShareCopy.minutes(0))
        XCTAssertEqual(ShareCopy.minutes(1), "1 分钟")
        XCTAssertEqual(ShareCopy.minutes(12), "12 分钟")
        XCTAssertNil(ShareCopy.streakChip(0))
        XCTAssertEqual(ShareCopy.streakChip(4), "连续打卡 4 天")
        XCTAssertNil(ShareCopy.goalChip(0))
        XCTAssertEqual(ShareCopy.goalChip(30), "目标：每天 30 个")
        // A best run is offered only when it is a record above today's, never as a comparison.
        XCTAssertNil(ShareCopy.longestChip(current: 9, longest: 9))
        XCTAssertNil(ShareCopy.longestChip(current: 9, longest: 4))
        XCTAssertEqual(ShareCopy.longestChip(current: 3, longest: 12), "最长：12 天")
    }

    func testMessageCarriesTheAppStoreLink() {
        XCTAssertEqual(AppLinks.appStore.absoluteString, "https://apps.apple.com/app/id6800027452")
        XCTAssertEqual(
            ShareCopy.message(headline: "连续打卡 7 天"),
            "连续打卡 7 天 · https://apps.apple.com/app/id6800027452"
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

        // The copy is Chinese: the Chinese for "missed | only | failed | 0 left | lost".
        let forbidden = try! NSRegularExpression(pattern: "错过|只有|仅|失败|剩 ?0(?![0-9])|丢|失去", options: [])
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            XCTAssertNil(forbidden.firstMatch(in: line, range: range), "“\(line)” mentions what did not happen")
        }
    }
}
