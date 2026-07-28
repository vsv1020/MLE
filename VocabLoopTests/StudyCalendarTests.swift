import XCTest
@testable import VocabLoop

/// Day-boundary arithmetic. These are the bugs users notice and never forgive — a streak that
/// resets at midnight for someone studying at 1am, or twice a year when the clocks change.
final class StudyCalendarTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    func testStudyDayStartsAtConfiguredHourNotMidnight() {
        let calendar = StudyCalendar(timeZone: utc, dayStartHour: 4)
        let components = DateComponents(
            timeZone: utc, year: 2025, month: 3, day: 15, hour: 6, minute: 0
        )
        let sixAM = Calendar.current.date(from: components)!

        let start = calendar.dayStart(for: sixAM)
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = utc
        XCTAssertEqual(gregorian.component(.hour, from: start), 4)
        XCTAssertEqual(gregorian.component(.day, from: start), 15)
    }

    /// The whole reason `dayStartHour` exists: 1am belongs to the day that has not ended yet.
    func testEarlyMorningBelongsToThePreviousStudyDay() {
        let calendar = StudyCalendar(timeZone: utc, dayStartHour: 4)
        let oneAM = Calendar.current.date(
            from: DateComponents(timeZone: utc, year: 2025, month: 3, day: 15, hour: 1)
        )!
        let previousEvening = Calendar.current.date(
            from: DateComponents(timeZone: utc, year: 2025, month: 3, day: 14, hour: 23)
        )!

        XCTAssertEqual(calendar.dayKey(for: oneAM), "2025-03-14")
        XCTAssertTrue(calendar.isSameDay(oneAM, previousEvening))
    }

    func testDayKeyIsSortableAndZeroPadded() {
        let calendar = StudyCalendar(timeZone: utc, dayStartHour: 4)
        let date = Calendar.current.date(
            from: DateComponents(timeZone: utc, year: 2025, month: 1, day: 5, hour: 12)
        )!
        XCTAssertEqual(calendar.dayKey(for: date), "2025-01-05")
    }

    func testDayDifferenceCountsStudyDays() {
        let calendar = StudyCalendar(timeZone: utc, dayStartHour: 4)
        let start = Calendar.current.date(
            from: DateComponents(timeZone: utc, year: 2025, month: 3, day: 10, hour: 12)
        )!
        let end = Calendar.current.date(
            from: DateComponents(timeZone: utc, year: 2025, month: 3, day: 15, hour: 12)
        )!
        XCTAssertEqual(calendar.dayDifference(from: start, to: end), 5)
        XCTAssertEqual(calendar.dayDifference(from: end, to: start), -5)
    }

    func testRecentDayKeysAreContiguousAndOldestFirst() {
        let calendar = StudyCalendar(timeZone: utc, dayStartHour: 4)
        let keys = calendar.recentDayKeys(endingAt: referenceDate, count: 10)
        XCTAssertEqual(keys.count, 10)
        XCTAssertEqual(keys, keys.sorted(), "oldest first")
        XCTAssertEqual(Set(keys).count, 10, "no duplicates")
        XCTAssertEqual(keys.last, calendar.dayKey(for: referenceDate))
    }

    /// Calendar arithmetic, not `-86400`, so a DST transition cannot skip or repeat a day.
    /// London springs forward on 30 March 2025.
    func testDayKeysAreContiguousAcrossADaylightSavingTransition() {
        let london = TimeZone(identifier: "Europe/London")!
        let calendar = StudyCalendar(timeZone: london, dayStartHour: 4)
        let afterTransition = Calendar.current.date(
            from: DateComponents(timeZone: london, year: 2025, month: 4, day: 2, hour: 12)
        )!

        let keys = calendar.recentDayKeys(endingAt: afterTransition, count: 7)
        XCTAssertEqual(Set(keys).count, 7, "a DST transition must not duplicate a day: \(keys)")
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertTrue(keys.contains("2025-03-30"), "the transition day itself must appear: \(keys)")
    }

    func testDayKeyDaysAgoMatchesRecentDayKeys() {
        let calendar = StudyCalendar(timeZone: utc, dayStartHour: 4)
        let keys = calendar.recentDayKeys(endingAt: referenceDate, count: 5)
        for (offset, expected) in keys.reversed().enumerated() {
            XCTAssertEqual(calendar.dayKey(daysAgo: offset, from: referenceDate), expected)
        }
    }

    func testNextOccurrenceIsAlwaysInTheFuture() {
        let calendar = StudyCalendar(timeZone: utc, dayStartHour: 4)
        for hour in 0..<24 {
            let next = calendar.nextOccurrence(hour: hour, minute: 0, after: referenceDate)
            XCTAssertNotNil(next)
            XCTAssertGreaterThan(next!, referenceDate, "hour \(hour) produced a past time")
        }
    }

    func testDayStartHourIsClampedToValidRange() {
        XCTAssertEqual(StudyCalendar(timeZone: utc, dayStartHour: 99).dayStartHour, 23)
        XCTAssertEqual(StudyCalendar(timeZone: utc, dayStartHour: -5).dayStartHour, 0)
    }
}
