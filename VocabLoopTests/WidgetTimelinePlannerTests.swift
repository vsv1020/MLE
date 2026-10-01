import XCTest
@testable import VocabLoop

/// The widget's timeline: entries only at the moments the display can change without the app
/// writing a new file — the study-day rollover and the stale cut-off.
final class WidgetTimelinePlannerTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let hour: TimeInterval = 60 * 60

    private func date(_ day: Int, _ hourOfDay: Int, month: Int = 3, zone: TimeZone? = nil) -> Date {
        Calendar.current.date(
            from: DateComponents(timeZone: zone ?? utc, year: 2025, month: month, day: day, hour: hourOfDay)
        )!
    }

    private func snapshot(updatedAt: Date, dayEndsAt: Date?, dueTomorrow: Int? = 20) -> WidgetSnapshot {
        WidgetSnapshot(
            dueNow: 12, reviewsToday: 8, dailyGoal: 30, streak: 7, studiedToday: true,
            mochiLevel: 4, candy: 640, bodyColor: "matcha", accessories: ["partyHat"],
            updatedAt: updatedAt, dayEndsAt: dayEndsAt, dueTomorrow: dueTomorrow
        )
    }

    func testNoSnapshotIsOneEmptyEntryAndASafetyReload() {
        let now = date(15, 12)
        let plan = WidgetTimelinePlanner.plan(snapshot: nil, now: now)
        XCTAssertEqual(plan.entries.count, 1)
        XCTAssertEqual(plan.entries[0].date, now)
        XCTAssertEqual(plan.entries[0].kind, .empty)
        XCTAssertTrue(plan.entries[0].isEmpty)
        XCTAssertNil(plan.entries[0].snapshot)
        XCTAssertEqual(plan.reloadAfter, now.addingTimeInterval(6 * hour))
    }

    func testFreshSnapshotPlansNowRolloverAndStaleCutOff() {
        let updatedAt = date(15, 10)
        let now = date(15, 12)
        let dayEndsAt = date(16, 4)
        let plan = WidgetTimelinePlanner.plan(snapshot: snapshot(updatedAt: updatedAt, dayEndsAt: dayEndsAt), now: now)

        let staleAt = updatedAt.addingTimeInterval(48 * hour)
        XCTAssertEqual(plan.entries.map(\.date), [now, dayEndsAt, staleAt])
        XCTAssertEqual(plan.entries.map(\.date), plan.entries.map(\.date).sorted())
        XCTAssertEqual(plan.reloadAfter, staleAt)

        // Now: the file as written.
        let current = plan.entries[0]
        XCTAssertEqual(current.kind, .current)
        XCTAssertEqual(current.snapshot?.reviewsToday, 8)
        XCTAssertEqual(current.snapshot?.dueNow, 12)
        XCTAssertEqual(current.snapshot?.studiedToday, true)

        // The rollover: a new day the app has not seen.
        let newDay = plan.entries[1]
        XCTAssertEqual(newDay.kind, .current)
        XCTAssertEqual(newDay.snapshot?.reviewsToday, 0)
        XCTAssertEqual(newDay.snapshot?.studiedToday, false)
        XCTAssertEqual(newDay.snapshot?.dueNow, 20, "dueNow becomes dueTomorrow")
        XCTAssertEqual(newDay.snapshot?.streak, 7, "the streak is left alone, with a grey flame")

        // The cut-off: no numbers.
        XCTAssertEqual(plan.entries[2].kind, .stale)
        XCTAssertTrue(plan.entries[2].isStale)
    }

    func testPastRolloverIsNotEmittedButStillApplied() {
        let updatedAt = date(15, 22)
        let dayEndsAt = date(16, 4)
        let now = date(16, 9)
        let plan = WidgetTimelinePlanner.plan(snapshot: snapshot(updatedAt: updatedAt, dayEndsAt: dayEndsAt), now: now)

        XCTAssertFalse(plan.entries.contains { $0.date == dayEndsAt })
        XCTAssertEqual(plan.entries.map(\.date), [now, updatedAt.addingTimeInterval(48 * hour)])
        XCTAssertEqual(plan.entries[0].snapshot?.reviewsToday, 0)
        XCTAssertEqual(plan.entries[0].snapshot?.dueNow, 20)
    }

    func testOldFileWithoutTheNewFieldsNeverRollsOver() {
        let updatedAt = date(15, 10)
        let now = date(16, 9)
        let plan = WidgetTimelinePlanner.plan(
            snapshot: snapshot(updatedAt: updatedAt, dayEndsAt: nil, dueTomorrow: nil), now: now
        )
        XCTAssertEqual(plan.entries.map(\.date), [now, updatedAt.addingTimeInterval(48 * hour)])
        XCTAssertEqual(plan.entries[0].snapshot?.reviewsToday, 8)
    }

    func testRolloverWithoutDueTomorrowKeepsDueNow() {
        let state = WidgetTimelinePlanner.state(
            of: snapshot(updatedAt: date(15, 10), dayEndsAt: date(16, 4), dueTomorrow: nil), at: date(16, 5)
        )
        XCTAssertEqual(state.snapshot?.dueNow, 12)
        XCTAssertEqual(state.snapshot?.reviewsToday, 0)
    }

    func testStaleSnapshotIsStaleWithOneEntryAndASafetyReload() {
        let updatedAt = date(10, 10)
        let now = date(15, 12)
        let plan = WidgetTimelinePlanner.plan(snapshot: snapshot(updatedAt: updatedAt, dayEndsAt: date(11, 4)), now: now)
        XCTAssertEqual(plan.entries.count, 1)
        XCTAssertTrue(plan.entries[0].isStale)
        XCTAssertNil(plan.entries[0].goalProgress, "no numbers when stale")
        XCTAssertEqual(plan.reloadAfter, now.addingTimeInterval(6 * hour))
    }

    /// The rollover instant comes from the file, never from the widget's own clock arithmetic:
    /// across London's spring-forward the study day is 23 hours long, and the widget must roll
    /// over at exactly the `dayEndsAt` the app computed.
    func testRolloverAcrossADaylightSavingTransitionComesFromTheFile() {
        let london = TimeZone(identifier: "Europe/London")!
        let calendar = StudyCalendar(timeZone: london, dayStartHour: 4)
        let updatedAt = date(29, 20, zone: london)
        let dayEndsAt = calendar.dayEnd(for: updatedAt)
        XCTAssertEqual(dayEndsAt.timeIntervalSince(calendar.dayStart(for: updatedAt)), 23 * hour)

        let plan = WidgetTimelinePlanner.plan(
            snapshot: snapshot(updatedAt: updatedAt, dayEndsAt: dayEndsAt), now: updatedAt
        )
        XCTAssertEqual(plan.entries[1].date, dayEndsAt)
        XCTAssertEqual(
            WidgetTimelinePlanner.state(of: plan.entries[0].snapshot, at: dayEndsAt.addingTimeInterval(-1)).snapshot?.reviewsToday,
            8
        )
        XCTAssertEqual(plan.entries[1].snapshot?.reviewsToday, 0)
    }

    func testDisplayHelpers() {
        var file = snapshot(updatedAt: date(15, 10), dayEndsAt: date(16, 4))
        file.reviewsToday = 45
        file.dueNow = 0
        let state = WidgetTimelinePlanner.state(of: file, at: date(15, 11))
        XCTAssertTrue(state.isGoalMet)
        XCTAssertEqual(state.goalProgress, 1)
        XCTAssertTrue(state.isCaughtUp)

        file.dailyGoal = 0
        let noGoal = WidgetTimelinePlanner.state(of: file, at: date(15, 11))
        XCTAssertNil(noGoal.goalProgress)
        XCTAssertFalse(noGoal.isGoalMet)
    }
}
