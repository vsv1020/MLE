import XCTest
@testable import VocabLoop

/// The Live Activity's rules, without ActivityKit: when it starts, what it says, how long it
/// stays. `StudyActivityController` only carries these out.
final class StudyActivityPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_042_400)

    func testShouldStartTruthTable() {
        for setting in [false, true] {
            for system in [false, true] {
                for reviewing in [false, true] {
                    for empty in [false, true] {
                        let expected = setting && system && reviewing && !empty
                        XCTAssertEqual(
                            StudyActivityPolicy.shouldStart(
                                settingEnabled: setting, systemEnabled: system,
                                isReviewing: reviewing, queueIsEmpty: empty
                            ),
                            expected,
                            "setting \(setting) system \(system) reviewing \(reviewing) empty \(empty)"
                        )
                    }
                }
            }
        }
    }

    func testStateMapping() {
        let state = StudyActivityPolicy.state(
            reviewsToday: 12, combo: 5, streak: 7, studiedToday: true, phase: .studying, now: now
        )
        XCTAssertEqual(state.reviewsToday, 12)
        XCTAssertEqual(state.combo, 5)
        XCTAssertEqual(state.streak, 7)
        XCTAssertTrue(state.studiedToday)
        XCTAssertEqual(state.phase, .studying)
        XCTAssertEqual(state.updatedAt, now)

        let goal = StudyActivityPolicy.state(
            reviewsToday: 30, combo: 0, streak: 1, studiedToday: true, phase: .goalReached, now: now
        )
        XCTAssertEqual(goal.phase, .goalReached)
        XCTAssertEqual(StudyActivityPolicy.goalProgress(reviewsToday: goal.reviewsToday, dailyGoal: 30), 1)
    }

    func testStateClampsAndLightsTheFlameOnceThereIsAReview() {
        let state = StudyActivityPolicy.state(
            reviewsToday: -1, combo: -3, streak: -2, studiedToday: false, phase: .studying, now: now
        )
        XCTAssertEqual(state.reviewsToday, 0)
        XCTAssertEqual(state.combo, 0)
        XCTAssertEqual(state.streak, 0)
        XCTAssertFalse(state.studiedToday)

        let lit = StudyActivityPolicy.state(
            reviewsToday: 1, combo: 1, streak: 3, studiedToday: false, phase: .studying, now: now
        )
        XCTAssertTrue(lit.studiedToday)
    }

    func testGoalProgress() {
        XCTAssertNil(StudyActivityPolicy.goalProgress(reviewsToday: 12, dailyGoal: 0))
        XCTAssertEqual(StudyActivityPolicy.goalProgress(reviewsToday: 12, dailyGoal: 30)!, 0.4, accuracy: 0.0001)
        XCTAssertEqual(StudyActivityPolicy.goalProgress(reviewsToday: 45, dailyGoal: 30), 1)
    }

    func testComboChipFromThree() {
        XCTAssertFalse(StudyActivityPolicy.showsCombo(2))
        XCTAssertTrue(StudyActivityPolicy.showsCombo(3))
    }

    func testStaleDateIsThirtyMinutesOut() {
        XCTAssertEqual(StudyActivityPolicy.staleDate(now: now), now.addingTimeInterval(30 * 60))
    }

    func testDismissalPerEnding() {
        XCTAssertEqual(StudyActivityPolicy.dismissalDate(for: .finished, now: now), now.addingTimeInterval(10 * 60))
        XCTAssertEqual(StudyActivityPolicy.dismissalDate(for: .resting, now: now), now.addingTimeInterval(15 * 60))
        XCTAssertEqual(StudyActivityPolicy.dismissalDate(for: .left, now: now), now.addingTimeInterval(5 * 60))
        XCTAssertNil(StudyActivityPolicy.dismissalDate(for: .disabled, now: now))
        XCTAssertNil(StudyActivityPolicy.dismissalDate(for: .abandoned, now: now))

        XCTAssertEqual(StudyActivityEnding.finished.finalPhase, .finished)
        XCTAssertEqual(StudyActivityEnding.resting.finalPhase, .resting)
    }

    func testEndOnReturnOnlyOnceStale() {
        XCTAssertFalse(StudyActivityPolicy.shouldEndOnReturn(staleDate: nil, now: now))
        XCTAssertFalse(StudyActivityPolicy.shouldEndOnReturn(staleDate: now.addingTimeInterval(60), now: now))
        XCTAssertTrue(StudyActivityPolicy.shouldEndOnReturn(staleDate: now, now: now))
        XCTAssertTrue(StudyActivityPolicy.shouldEndOnReturn(staleDate: now.addingTimeInterval(-60), now: now))
    }

    func testCopyLines() {
        func line(_ phase: StudyActivityPhase, stale: Bool = false) -> String {
            StudyActivityCopy.line(
                for: StudyActivityPolicy.state(
                    reviewsToday: 3, combo: 0, streak: 2, studiedToday: true, phase: phase, now: now
                ),
                isStale: stale
            )
        }
        XCTAssertEqual(line(.studying), "继续背 —— 麻薯在为你加油")
        XCTAssertEqual(line(.goalReached), "今日目标完成 ⭐")
        XCTAssertEqual(line(.finished), "暂时都学完啦")
        XCTAssertEqual(line(.resting), "明天见")
        XCTAssertEqual(line(.studying, stale: true), "轻点一下，从上次停下的地方继续")

        XCTAssertEqual(StudyActivityCopy.progress(reviewsToday: 12, dailyGoal: 30), "今天已学 12/30")
        XCTAssertEqual(StudyActivityCopy.progress(reviewsToday: 12, dailyGoal: 0), "今天复习了 12 张")
        XCTAssertEqual(StudyActivityCopy.progress(reviewsToday: 1, dailyGoal: 0), "今天复习了 1 张")
        XCTAssertEqual(StudyActivityCopy.compact(reviewsToday: 12, dailyGoal: 30), "12/30")
        XCTAssertEqual(StudyActivityCopy.compact(reviewsToday: 12, dailyGoal: 0), "12 ✓")
        XCTAssertEqual(StudyActivityCopy.combo(5), "×5")
        XCTAssertEqual(StudyActivityCopy.streak(7), "连续打卡 7 天")
    }

    /// Kids audience: nothing on the Lock Screen counts what did not happen. The copy is Chinese,
    /// so the banned words are the Chinese for "missed | only | failed | 0 left".
    func testNoCopyCountsWhatDidNotHappen() throws {
        let banned = try NSRegularExpression(pattern: "错过|只有|仅|失败|剩 ?0(?![0-9])", options: [])
        var lines: [String] = []
        for phase in StudyActivityPhase.allCases {
            for stale in [false, true] {
                for reviews in [0, 1, 30] {
                    for goal in [0, 30] {
                        let state = StudyActivityPolicy.state(
                            reviewsToday: reviews, combo: 4, streak: 0, studiedToday: reviews > 0,
                            phase: phase, now: now
                        )
                        lines.append(StudyActivityCopy.line(for: state, isStale: stale))
                        lines.append(StudyActivityCopy.accessibilitySummary(for: state, dailyGoal: goal, isStale: stale))
                        lines.append(StudyActivityCopy.progress(reviewsToday: reviews, dailyGoal: goal))
                        lines.append(StudyActivityCopy.compact(reviewsToday: reviews, dailyGoal: goal))
                    }
                }
            }
        }
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            XCTAssertNil(banned.firstMatch(in: line, range: range), line)
        }
    }

    func testContentStateRoundTripsThroughJSON() throws {
        let state = StudyActivityPolicy.state(
            reviewsToday: 12, combo: 5, streak: 7, studiedToday: true, phase: .goalReached, now: now
        )
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(StudyActivityState.self, from: data), state)
    }
}
