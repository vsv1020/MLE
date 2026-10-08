import XCTest
@testable import VocabLoop

/// Recap wording (engagement plan §1.9, §1.10): one, many and a kind zero, plus the small pure
/// helpers the recap surfaces share. The copy is Chinese, which has no plural forms.
final class RecapHeadlineTests: XCTestCase {
    func testZeroIsKind() {
        XCTAssertEqual(RecapCopy.headline(wordsMastered: 0), "这周你的单词一直在长大")
    }

    func testNegativeIsTreatedAsZero() {
        XCTAssertEqual(RecapCopy.headline(wordsMastered: -3), RecapCopy.headline(wordsMastered: 0))
    }

    func testOneIsSingular() {
        XCTAssertEqual(RecapCopy.headline(wordsMastered: 1), "这周你掌握了 1 个单词")
    }

    func testManyIsPlural() {
        XCTAssertEqual(RecapCopy.headline(wordsMastered: 2), "这周你掌握了 2 个单词")
        XCTAssertEqual(RecapCopy.headline(wordsMastered: 42), "这周你掌握了 42 个单词")
    }

    func testHeadlineNeverMentionsFailure() {
        for count in [0, 1, 5] {
            let text = RecapCopy.headline(wordsMastered: count) + RecapCopy.parentHeadline(wordsMastered: count)
            // The Chinese for "fail", "only", "missed" and "lost".
            for word in ["失败", "只有", "仅", "错过", "丢", "失去"] {
                XCTAssertFalse(text.contains(word), "“\(text)” contains “\(word)”")
            }
        }
    }

    func testParentHeadline() {
        XCTAssertEqual(RecapCopy.parentHeadline(wordsMastered: 1), "本周有 1 个单词达到“记得很牢”")
        XCTAssertEqual(RecapCopy.parentHeadline(wordsMastered: 9), "本周有 9 个单词达到“记得很牢”")
    }

    func testCounts() {
        // Chinese has no plural: the count is the number, a space and the unit, and the
        // optional plural argument is ignored.
        XCTAssertEqual(RecapCopy.count(1, "次复习"), "1 次复习")
        XCTAssertEqual(RecapCopy.count(0, "次复习"), "0 次复习")
        XCTAssertEqual(RecapCopy.count(3, "次", "tries"), "3 次")
        XCTAssertEqual(RecapCopy.daysStudied([true, false, true, true, false, false, true]), "7 天中学了 4 天")
        XCTAssertEqual(RecapCopy.percent(nil), "—")
        XCTAssertEqual(RecapCopy.percent(0.856), "86%")
    }

    func testWeekOnWeekDelta() {
        XCTAssertEqual(RecapCopy.delta(12), "比上周 +12")
        XCTAssertEqual(RecapCopy.delta(-3), "比上周 \u{2212}3")
        XCTAssertEqual(RecapCopy.delta(0), "和上周一样")
        XCTAssertEqual(RecapCopy.Trend(delta: 5), .up)
        XCTAssertEqual(RecapCopy.Trend(delta: -5), .down)
        XCTAssertEqual(RecapCopy.Trend(delta: 0), .same)
    }

    func testParentNotesExplainAccuracyAndStayOnDevice() {
        let notes = RecapCopy.parentNotes(accuracy: 0.85, reviews: 120, daysStudied: 5, streak: 9, trickyCount: 2)
        XCTAssertTrue(notes.contains { $0.contains("复习安排正常运作") })
        XCTAssertTrue(notes.contains { $0.contains("不会发送到任何地方") })
        XCTAssertTrue(notes.contains { $0.contains("值得再看看") })

        let empty = RecapCopy.parentNotes(accuracy: nil, reviews: 0, daysStudied: 0, streak: 0, trickyCount: 0)
        XCTAssertTrue(empty.first?.contains("什么都不会丢") ?? false)
    }

    func testWeekdayInitialReadsTheKeyNotTheDevice() {
        let english = Locale(identifier: "en_US")
        // 1 October 2026 is a Thursday.
        XCTAssertEqual(RecapCopy.weekdayInitial(dayKey: "2026-10-01", locale: english), "T")
        XCTAssertEqual(RecapCopy.weekdayName(dayKey: "2026-10-01", locale: english), "Thursday")
        XCTAssertEqual(RecapCopy.weekdayName(dayKey: "2026-10-04", locale: english), "Sunday")
        XCTAssertEqual(RecapCopy.weekdayInitial(dayKey: "nonsense", locale: english), "")
    }

    func testShareImageIs1080By1350() {
        XCTAssertEqual(RecapShareMetrics.pixelSize.width, 1080)
        XCTAssertEqual(RecapShareMetrics.pixelSize.height, 1350)
    }

    func testRecapChipIsOfferedOncePerWeek() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        // Thursday 1 Oct 2026 and Sunday 4 Oct 2026 share ISO week 40; Monday 5 Oct is week 41.
        let thursday = Date(timeIntervalSince1970: 1_790_856_000)
        let sunday = thursday.addingTimeInterval(3 * 86_400)
        let monday = thursday.addingTimeInterval(4 * 86_400)

        let week = RecapNudge.weekKey(for: thursday, timeZone: utc)
        XCTAssertEqual(week, "2026-W40")
        XCTAssertEqual(RecapNudge.weekKey(for: sunday, timeZone: utc), week)
        XCTAssertEqual(RecapNudge.weekKey(for: monday, timeZone: utc), "2026-W41")

        XCTAssertTrue(RecapNudge.shouldOffer(currentWeekKey: week, seenWeekKey: nil))
        XCTAssertFalse(RecapNudge.shouldOffer(currentWeekKey: week, seenWeekKey: week))
        XCTAssertTrue(RecapNudge.shouldOffer(currentWeekKey: "2026-W41", seenWeekKey: week))
    }
}
