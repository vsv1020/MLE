import XCTest
@testable import VocabLoop

/// Recap wording (engagement plan §1.9, §1.10): singular, plural and a kind zero, plus the small
/// pure helpers the recap surfaces share.
final class RecapHeadlineTests: XCTestCase {
    func testZeroIsKind() {
        XCTAssertEqual(RecapCopy.headline(wordsMastered: 0), "This week you kept your words growing")
    }

    func testNegativeIsTreatedAsZero() {
        XCTAssertEqual(RecapCopy.headline(wordsMastered: -3), RecapCopy.headline(wordsMastered: 0))
    }

    func testOneIsSingular() {
        XCTAssertEqual(RecapCopy.headline(wordsMastered: 1), "This week you mastered 1 word")
    }

    func testManyIsPlural() {
        XCTAssertEqual(RecapCopy.headline(wordsMastered: 2), "This week you mastered 2 words")
        XCTAssertEqual(RecapCopy.headline(wordsMastered: 42), "This week you mastered 42 words")
    }

    func testHeadlineNeverMentionsFailure() {
        for count in [0, 1, 5] {
            let text = (RecapCopy.headline(wordsMastered: count) + RecapCopy.parentHeadline(wordsMastered: count)).lowercased()
            for word in ["fail", "only", "missed", "lost"] {
                XCTAssertFalse(text.contains(word), "“\(text)” contains “\(word)”")
            }
        }
    }

    func testParentHeadline() {
        XCTAssertEqual(RecapCopy.parentHeadline(wordsMastered: 1), "1 word reached “well known” this week")
        XCTAssertEqual(RecapCopy.parentHeadline(wordsMastered: 9), "9 words reached “well known” this week")
    }

    func testCounts() {
        XCTAssertEqual(RecapCopy.count(1, "review"), "1 review")
        XCTAssertEqual(RecapCopy.count(0, "review"), "0 reviews")
        XCTAssertEqual(RecapCopy.count(3, "try", "tries"), "3 tries")
        XCTAssertEqual(RecapCopy.daysStudied([true, false, true, true, false, false, true]), "4 of 7 days")
        XCTAssertEqual(RecapCopy.percent(nil), "—")
        XCTAssertEqual(RecapCopy.percent(0.856), "86%")
    }

    func testWeekOnWeekDelta() {
        XCTAssertEqual(RecapCopy.delta(12), "+12 vs last week")
        XCTAssertEqual(RecapCopy.delta(-3), "\u{2212}3 vs last week")
        XCTAssertEqual(RecapCopy.delta(0), "Same as last week")
        XCTAssertEqual(RecapCopy.Trend(delta: 5), .up)
        XCTAssertEqual(RecapCopy.Trend(delta: -5), .down)
        XCTAssertEqual(RecapCopy.Trend(delta: 0), .same)
    }

    func testParentNotesExplainAccuracyAndStayOnDevice() {
        let notes = RecapCopy.parentNotes(accuracy: 0.85, reviews: 120, daysStudied: 5, streak: 9, trickyCount: 2)
        XCTAssertTrue(notes.contains { $0.contains("scheduler working as intended") })
        XCTAssertTrue(notes.contains { $0.contains("Nothing is sent anywhere") })
        XCTAssertTrue(notes.contains { $0.contains("worth another look") })

        let empty = RecapCopy.parentNotes(accuracy: nil, reviews: 0, daysStudied: 0, streak: 0, trickyCount: 0)
        XCTAssertTrue(empty.first?.contains("Nothing is lost") ?? false)
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
