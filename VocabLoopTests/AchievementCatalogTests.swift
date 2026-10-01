import XCTest
@testable import VocabLoop

/// The sixteen badges (engagement plan §1.8). Each condition is a pure function of
/// `AchievementContext`, so each is pinned here just below and at its threshold.
final class AchievementCatalogTests: XCTestCase {

    private func isMet(_ id: AchievementID, _ context: AchievementContext) throws -> Bool {
        try XCTUnwrap(AchievementCatalog.achievement(id)).isMet(context)
    }

    func testCatalogueListsEveryBadgeOnceInDeclarationOrder() {
        XCTAssertEqual(AchievementCatalog.all.map(\.id), AchievementID.allCases)
        for achievement in AchievementCatalog.all {
            XCTAssertFalse(achievement.name.isEmpty, "\(achievement.id)")
            XCTAssertFalse(achievement.detail.isEmpty, "\(achievement.id)")
            XCTAssertFalse(achievement.symbolName.isEmpty, "\(achievement.id)")
        }
    }

    func testNothingIsMetByAnEmptyContextAtNoon() {
        XCTAssertEqual(AchievementCatalog.evaluate(AchievementContext(), alreadyUnlocked: []), [])
    }

    func testFirstReview() throws {
        XCTAssertFalse(try isMet(.first_review, AchievementContext(lifetimeReviews: 0)))
        XCTAssertTrue(try isMet(.first_review, AchievementContext(lifetimeReviews: 1)))
    }

    func testStreaksCountTheCurrentOrTheLongest() throws {
        let thresholds: [(AchievementID, Int)] = [(.streak_3, 3), (.streak_7, 7), (.streak_30, 30)]
        for (id, n) in thresholds {
            XCTAssertFalse(try isMet(id, AchievementContext(currentStreak: n - 1, longestStreak: n - 1)), "\(id)")
            XCTAssertTrue(try isMet(id, AchievementContext(currentStreak: n, longestStreak: n)), "\(id)")
            // A streak that has since ended still earned it.
            XCTAssertTrue(try isMet(id, AchievementContext(currentStreak: 0, longestStreak: n)), "\(id)")
        }
    }

    func testCombos() throws {
        let thresholds: [(AchievementID, Int)] = [(.combo_10, 10), (.combo_25, 25), (.combo_50, 50)]
        for (id, n) in thresholds {
            XCTAssertFalse(try isMet(id, AchievementContext(bestCombo: n - 1)), "\(id)")
            XCTAssertTrue(try isMet(id, AchievementContext(bestCombo: n)), "\(id)")
        }
    }

    func testMasteredWords() throws {
        let thresholds: [(AchievementID, Int)] = [(.mastered_10, 10), (.mastered_100, 100), (.mastered_500, 500)]
        for (id, n) in thresholds {
            XCTAssertFalse(try isMet(id, AchievementContext(matureWords: n - 1)), "\(id)")
            XCTAssertTrue(try isMet(id, AchievementContext(matureWords: n)), "\(id)")
        }
    }

    func testFirstAlbum() throws {
        XCTAssertFalse(try isMet(.album_first, AchievementContext(completedAlbums: 0)))
        XCTAssertTrue(try isMet(.album_first, AchievementContext(completedAlbums: 1)))
    }

    /// 22:00 up to, not including, 02:00.
    func testNightOwlHours() throws {
        for hour in [22, 23, 0, 1] {
            XCTAssertTrue(try isMet(.night_owl, AchievementContext(localHour: hour)), "\(hour)")
        }
        for hour in [2, 3, 12, 21] {
            XCTAssertFalse(try isMet(.night_owl, AchievementContext(localHour: hour)), "\(hour)")
        }
    }

    /// 05:00 up to, not including, 07:00.
    func testEarlyBirdHours() throws {
        for hour in [5, 6] {
            XCTAssertTrue(try isMet(.early_bird, AchievementContext(localHour: hour)), "\(hour)")
        }
        for hour in [4, 7, 12] {
            XCTAssertFalse(try isMet(.early_bird, AchievementContext(localHour: hour)), "\(hour)")
        }
    }

    func testGoalDays() throws {
        XCTAssertFalse(try isMet(.goal_7, AchievementContext(goalDaysTotal: 6)))
        XCTAssertTrue(try isMet(.goal_7, AchievementContext(goalDaysTotal: 7)))
    }

    func testQuizWhiz() throws {
        XCTAssertFalse(try isMet(.quiz_100, AchievementContext(quizCorrectTotal: 99)))
        XCTAssertTrue(try isMet(.quiz_100, AchievementContext(quizCorrectTotal: 100)))
    }

    func testMochiLevelTen() throws {
        XCTAssertFalse(try isMet(.mochi_10, AchievementContext(level: 9)))
        XCTAssertTrue(try isMet(.mochi_10, AchievementContext(level: 10)))
    }

    func testEvaluateNeverReturnsAnAlreadyUnlockedBadge() {
        let context = AchievementContext(lifetimeReviews: 5, bestCombo: 30, localHour: 23)
        let first = AchievementCatalog.evaluate(context, alreadyUnlocked: [])
        XCTAssertEqual(first, [.first_review, .combo_10, .combo_25, .night_owl])

        let unlocked = Set(first.map(\.rawValue))
        XCTAssertEqual(AchievementCatalog.evaluate(context, alreadyUnlocked: unlocked), [])
        XCTAssertEqual(
            AchievementCatalog.evaluate(
                AchievementContext(lifetimeReviews: 5, bestCombo: 50, localHour: 23),
                alreadyUnlocked: unlocked
            ),
            [.combo_50]
        )
    }

    /// Raw values are persisted; renaming one would silently take a badge away.
    func testRawValuesAreFrozen() {
        XCTAssertEqual(
            AchievementID.allCases.map(\.rawValue),
            [
                "first_review", "streak_3", "streak_7", "streak_30", "combo_10", "combo_25", "combo_50",
                "mastered_10", "mastered_100", "mastered_500", "album_first", "night_owl", "early_bird",
                "goal_7", "quiz_100", "mochi_10",
            ]
        )
    }
}
