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
        XCTAssertEqual(WidgetCopy.inline(state()), "12 个单词待复习 · 连续打卡 7 天")
        XCTAssertEqual(WidgetCopy.inline(state(dueNow: 1, streak: 0)), "1 个单词待复习")
        XCTAssertEqual(WidgetCopy.inline(state(dueNow: 0)), "都复习完了")
        XCTAssertEqual(WidgetCopy.inline(state(kind: .empty)), "打开麻薯背单词")
        XCTAssertEqual(WidgetCopy.inline(state(kind: .stale)), "打开麻薯背单词")
    }

    func testRectangular() {
        XCTAssertEqual(WidgetCopy.rectangularDetail(state()), "待复习 12 · 今天 8/30")
        XCTAssertEqual(WidgetCopy.rectangularDetail(state(dailyGoal: 0)), "待复习 12")
        XCTAssertEqual(WidgetCopy.rectangularDetail(state(kind: .stale)), "麻薯在等你")
        XCTAssertEqual(WidgetCopy.rectangularDetail(state(kind: .empty)), "打开麻薯背单词，开始学习")
    }

    func testMochiMood() {
        XCTAssertEqual(WidgetCopy.mochiMood(state(reviewsToday: 30)), .cheer)
        XCTAssertEqual(WidgetCopy.mochiMood(state()), .happy)
        XCTAssertEqual(WidgetCopy.mochiMood(state(reviewsToday: 0, studiedToday: false)), .curious)
        XCTAssertEqual(WidgetCopy.mochiMood(state(kind: .stale)), .sleepy)
        XCTAssertEqual(WidgetCopy.mochiMood(state(kind: .empty)), .curious)
    }

    /// Kids audience: nothing counts what did not happen. The copy is Chinese, so the banned
    /// words are the Chinese for "missed | only | failed | 0 left".
    func testNoCopyCountsWhatDidNotHappen() throws {
        let banned = try NSRegularExpression(pattern: "错过|只有|仅|失败|剩 ?0(?![0-9])", options: [])
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
