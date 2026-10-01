import XCTest
@testable import VocabLoop

/// Pins the star-candy economy to the numbers in `docs/ENGAGEMENT-PLAN.md` §1.1 and §1.3.
///
/// A child notices a level arriving a day late; nobody notices the code that caused it. Every
/// number here is a product decision, so each one is spelled out rather than recomputed.
final class RewardEngineTests: XCTestCase {

    // MARK: - Level curve

    func testCandyRequiredMatchesThePublishedCurve() {
        XCTAssertEqual(RewardEngine.candyRequired(toReach: 1), 0)
        XCTAssertEqual(RewardEngine.candyRequired(toReach: 2), 40)
        XCTAssertEqual(RewardEngine.candyRequired(toReach: 3), 120)
        XCTAssertEqual(RewardEngine.candyRequired(toReach: 5), 400)
        XCTAssertEqual(RewardEngine.candyRequired(toReach: 10), 1_800)
        XCTAssertEqual(RewardEngine.candyRequired(toReach: 15), 4_200)
        XCTAssertEqual(RewardEngine.candyRequired(toReach: 20), 7_600)
        XCTAssertEqual(RewardEngine.candyRequired(toReach: 30), 17_400)
        XCTAssertEqual(RewardEngine.candyRequired(toReach: 0), 0, "nothing below level 1 costs anything")
    }

    func testLevelIsDerivedFromCandyAndCapped() {
        XCTAssertEqual(RewardEngine.level(forCandy: 0), 1)
        XCTAssertEqual(RewardEngine.level(forCandy: -5), 1, "a corrupt negative total is still level 1")
        XCTAssertEqual(RewardEngine.level(forCandy: 39), 1)
        XCTAssertEqual(RewardEngine.level(forCandy: 40), 2)
        XCTAssertEqual(RewardEngine.level(forCandy: 119), 2)
        XCTAssertEqual(RewardEngine.level(forCandy: 120), 3)
        XCTAssertEqual(RewardEngine.level(forCandy: 1_800), 10)
        XCTAssertEqual(RewardEngine.level(forCandy: 17_399), 29)
        XCTAssertEqual(RewardEngine.level(forCandy: 17_400), RewardEngine.maxLevel)
        XCTAssertEqual(RewardEngine.level(forCandy: 1_000_000), RewardEngine.maxLevel)
    }

    func testEveryLevelBoundaryRoundTrips() {
        for level in 1...RewardEngine.maxLevel {
            let threshold = RewardEngine.candyRequired(toReach: level)
            XCTAssertEqual(RewardEngine.level(forCandy: threshold), level, "exactly enough for L\(level)")
            if level > 1 {
                XCTAssertEqual(RewardEngine.level(forCandy: threshold - 1), level - 1, "one short of L\(level)")
            }
        }
    }

    func testProgressToNextLevel() {
        XCTAssertEqual(RewardEngine.progressToNextLevel(candy: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(RewardEngine.progressToNextLevel(candy: 20), 0.5, accuracy: 1e-9)
        // L2 → L3 spans 40…120.
        XCTAssertEqual(RewardEngine.progressToNextLevel(candy: 80), 0.5, accuracy: 1e-9)
        XCTAssertEqual(RewardEngine.progressToNextLevel(candy: 17_400), 1, accuracy: 1e-9)
        XCTAssertEqual(RewardEngine.progressToNextLevel(candy: 99_999), 1, accuracy: 1e-9)
    }

    func testStagesFollowTheLevelBands() {
        XCTAssertEqual(RewardEngine.stage(forLevel: 1), .sprout)
        XCTAssertEqual(RewardEngine.stage(forLevel: 4), .sprout)
        XCTAssertEqual(RewardEngine.stage(forLevel: 5), .kid)
        XCTAssertEqual(RewardEngine.stage(forLevel: 9), .kid)
        XCTAssertEqual(RewardEngine.stage(forLevel: 10), .teen)
        XCTAssertEqual(RewardEngine.stage(forLevel: 14), .teen)
        XCTAssertEqual(RewardEngine.stage(forLevel: 15), .grown)
        XCTAssertEqual(RewardEngine.stage(forLevel: 30), .grown)
    }

    // MARK: - Earning

    func testBaseRewardsMatchThePlan() {
        XCTAssertEqual(RewardEngine.candyPerReview, 1)
        XCTAssertEqual(RewardEngine.firstReviewBonus, 5)
        XCTAssertEqual(RewardEngine.goalBonus, 10)
        XCTAssertEqual(RewardEngine.stickerBonus, 3)
        XCTAssertEqual(RewardEngine.albumBonus, 25)
        XCTAssertEqual(RewardEngine.achievementBonus, 10)
    }

    // MARK: - Combos

    func testComboMilestones() {
        XCTAssertEqual(RewardEngine.comboMilestones, [3, 5, 10, 15, 20, 30, 50, 75, 100])
        for combo in [3, 5, 10, 15, 20, 30, 50, 75, 100, 150, 200, 250, 1_000] {
            XCTAssertTrue(RewardEngine.isComboMilestone(combo), "\(combo) is a milestone")
        }
        for combo in [0, 1, 2, 4, 6, 9, 11, 25, 40, 60, 99, 101, 125, 175] {
            XCTAssertFalse(RewardEngine.isComboMilestone(combo), "\(combo) is not a milestone")
        }
    }

    func testComboBonusesAreSmallAndMilestoneOnly() {
        let expected: [Int: Int] = [3: 1, 5: 2, 10: 3, 15: 3, 20: 5, 30: 5, 50: 10, 75: 10, 100: 20, 150: 20, 200: 20]
        for (combo, bonus) in expected {
            XCTAssertEqual(RewardEngine.comboBonus(combo), bonus, "bonus at \(combo)")
        }
        for combo in [0, 1, 2, 4, 7, 12, 25, 99, 125] {
            XCTAssertEqual(RewardEngine.comboBonus(combo), 0, "no bonus at \(combo)")
        }
    }

    func testComboTiersFollowTheSoundTable() {
        XCTAssertEqual(RewardEngine.comboTier(2), ComboTier.none)
        XCTAssertEqual(RewardEngine.comboTier(3), .small)
        XCTAssertEqual(RewardEngine.comboTier(4), ComboTier.none, "between milestones there is nothing to play")
        XCTAssertEqual(RewardEngine.comboTier(5), .small)
        XCTAssertEqual(RewardEngine.comboTier(10), .medium)
        XCTAssertEqual(RewardEngine.comboTier(15), .medium)
        XCTAssertEqual(RewardEngine.comboTier(20), .medium)
        XCTAssertEqual(RewardEngine.comboTier(30), .big)
        XCTAssertEqual(RewardEngine.comboTier(100), .big)
        XCTAssertEqual(RewardEngine.comboTier(150), .big)
    }

    // MARK: - Catalogues

    func testPlusClosetListsNameRealItems() {
        XCTAssertEqual(PlusCatalog.plusClosetAccessoryIDs.count, 4)
        XCTAssertEqual(PlusCatalog.plusClosetColorIDs.count, 4)
        for id in PlusCatalog.plusClosetAccessoryIDs {
            XCTAssertNotNil(MochiAccessory(rawValue: id), "\(id) is not an accessory")
        }
        for id in PlusCatalog.plusClosetColorIDs {
            XCTAssertNotNil(MochiBodyColor(rawValue: id), "\(id) is not a colour")
        }
    }

    /// Every item has exactly one way to get it, and level/achievement items are never Plus.
    func testEveryWardrobeItemHasExactlyOneUnlockRoute() {
        for accessory in MochiAccessory.allCases {
            let routes = [accessory.unlockLevel != nil, accessory.unlockAchievement != nil, accessory.requiresPlus]
            XCTAssertEqual(routes.filter { $0 }.count, 1, "\(accessory) unlock routes")
        }
        for color in MochiBodyColor.allCases {
            XCTAssertNotEqual(color.unlockLevel != nil, color.requiresPlus, "\(color) unlock routes")
        }
        XCTAssertEqual(MochiBodyColor.vanilla.unlockLevel, 1)
        XCTAssertEqual(MochiAccessory.redScarf.unlockLevel, 2)
        XCTAssertEqual(MochiAccessory.cape.slot, .back)
        XCTAssertEqual(MochiAccessory.roundGlasses.slot, .eyes)
        XCTAssertEqual(MochiAccessory.goldStarPin.unlockAchievement, .combo_50)
    }

    func testAchievementCatalogCoversEveryIDOnce() {
        let ids = AchievementCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, 16)
        XCTAssertEqual(Set(ids), Set(AchievementID.allCases))
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testAchievementEvaluationSkipsWhatIsAlreadyUnlocked() {
        let context = AchievementContext(lifetimeReviews: 1, bestCombo: 12, localHour: 23)
        XCTAssertEqual(
            AchievementCatalog.evaluate(context, alreadyUnlocked: []),
            [.first_review, .combo_10, .night_owl]
        )
        XCTAssertEqual(
            AchievementCatalog.evaluate(context, alreadyUnlocked: ["first_review", "night_owl"]),
            [.combo_10]
        )
    }
}
