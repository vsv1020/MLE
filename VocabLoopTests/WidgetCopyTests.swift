import XCTest
@testable import VocabLoop

/// What the Home Screen and Lock Screen widgets say, in every state they can be in.
final class WidgetCopyTests: XCTestCase {
    private let updatedAt = Date(timeIntervalSince1970: 1_700_042_400)

    private func state(
        dueNow: Int = 12, reviewsToday: Int = 8, dailyGoal: Int = 30, streak: Int = 7,
        studiedToday: Bool = true, kind: WidgetDisplayState.Kind = .current
    ) -> WidgetDisplayState {
        let snapshot = WidgetSnapshot(
            dueNow: dueNow, reviewsToday: reviewsToday, dailyGoal: dailyGoal, streak: streak,
            studiedToday: studiedToday, mochiLevel: 4, candy: 640, bodyColor: "vanilla",
            accessories: [], updatedAt: updatedAt
        )
        return WidgetDisplayState(date: updatedAt, kind: kind, snapshot: kind == .empty ? nil : snapshot)
    }

    func testInline() {
        XCTAssertEqual(WidgetCopy.inline(state()), "12 words due · 7-day streak")
        XCTAssertEqual(WidgetCopy.inline(state(dueNow: 1, streak: 0)), "1 word due")
        XCTAssertEqual(WidgetCopy.inline(state(dueNow: 0)), "All caught up")
        XCTAssertEqual(WidgetCopy.inline(state(kind: .empty)), "Open VocabLoop")
        XCTAssertEqual(WidgetCopy.inline(state(kind: .stale)), "Open VocabLoop")
    }

    func testRectangular() {
        XCTAssertEqual(WidgetCopy.rectangularDetail(state()), "12 due · 8/30 today")
        XCTAssertEqual(WidgetCopy.rectangularDetail(state(dailyGoal: 0)), "12 due")
        XCTAssertEqual(WidgetCopy.rectangularDetail(state(kind: .stale)), "Mochi is waiting for you")
        XCTAssertEqual(WidgetCopy.rectangularDetail(state(kind: .empty)), "Open VocabLoop to get started")
    }

    func testMochiMood() {
        XCTAssertEqual(WidgetCopy.mochiMood(state(reviewsToday: 30)), .cheer)
        XCTAssertEqual(WidgetCopy.mochiMood(state()), .happy)
        XCTAssertEqual(WidgetCopy.mochiMood(state(reviewsToday: 0, studiedToday: false)), .curious)
        XCTAssertEqual(WidgetCopy.mochiMood(state(kind: .stale)), .sleepy)
        XCTAssertEqual(WidgetCopy.mochiMood(state(kind: .empty)), .curious)
    }

    /// Kids audience: nothing counts what did not happen.
    func testNoCopyCountsWhatDidNotHappen() throws {
        let banned = try NSRegularExpression(pattern: "missed|only|failed|0 left", options: [.caseInsensitive])
        var lines: [String] = [WidgetCopy.emptyTitle, WidgetCopy.staleTitle, WidgetCopy.caughtUp, WidgetCopy.openApp]
        for kind in [WidgetDisplayState.Kind.empty, .stale, .current] {
            for due in [0, 1, 12] {
                for goal in [0, 30] {
                    for streak in [0, 7] {
                        let s = state(dueNow: due, dailyGoal: goal, streak: streak, kind: kind)
                        lines += [WidgetCopy.inline(s), WidgetCopy.rectangularDetail(s), WidgetCopy.accessibilityLabel(s)]
                    }
                }
            }
        }
        for line in lines {
            XCTAssertNil(banned.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), line)
        }
    }
}
