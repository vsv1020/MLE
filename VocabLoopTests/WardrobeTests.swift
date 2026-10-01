import XCTest
import SwiftData
@testable import VocabLoop

/// The wardrobe's rules (`ENGAGEMENT-PLAN.md` §1.4, §1.11): level items free at their level,
/// badge items with their badge, the Plus closet only with Plus, one item per slot — and the
/// wardrobe screen's ``WardrobeRules`` agreeing with ``EngagementService`` on every item.
@MainActor
final class WardrobeTests: XCTestCase {
    private var snapshotURL: URL!
    private var context: ModelContext!
    private var entitlements: Entitlements!
    private var service: EngagementService!

    override func setUp() async throws {
        try await super.setUp()
        snapshotURL = FileManager.default.temporaryDirectory
            .appending(path: "wardrobe-\(UUID().uuidString).json")
        context = try TestStore.makeContext()
        _ = try context.activeAccount()
        entitlements = Entitlements(defaults: nil)
        service = EngagementService(
            context: context,
            notifications: NotificationService(),
            snapshots: WidgetSnapshotWriter(url: snapshotURL),
            entitlements: entitlements
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: snapshotURL)
        service = nil
        entitlements = nil
        context = nil
        try await super.tearDown()
    }

    private func setLevel(_ level: Int) throws {
        let profile = try service.profile()
        profile.candyTotal = RewardEngine.candyRequired(toReach: level)
        XCTAssertEqual(try service.profile().level, level)
    }

    private func grant(_ achievement: AchievementID) throws {
        let profile = try service.profile()
        profile.unlockedAchievements.append(UnlockedAchievement(id: achievement.rawValue, unlockedAt: referenceDate))
    }

    private func rulesLock(_ accessory: MochiAccessory) throws -> WardrobeLock {
        let profile = try service.profile()
        return WardrobeRules.lock(
            for: accessory, level: profile.level,
            unlockedAchievements: profile.unlockedAchievementIDs,
            grantedAccessories: Set(profile.unlockedAccessoryIDs),
            isPlus: entitlements.isPlus
        )
    }

    // MARK: - Unlock rules

    func testLevelItemsUnlockExactlyAtTheirLevel() {
        for accessory in MochiAccessory.allCases {
            guard let needed = accessory.unlockLevel else { continue }
            XCTAssertEqual(
                WardrobeRules.lock(for: accessory, level: needed - 1, unlockedAchievements: [], grantedAccessories: [], isPlus: false),
                .level(needed), accessory.rawValue
            )
            XCTAssertEqual(
                WardrobeRules.lock(for: accessory, level: needed, unlockedAchievements: [], grantedAccessories: [], isPlus: false),
                .unlocked, accessory.rawValue
            )
        }
        for color in MochiBodyColor.allCases {
            guard let needed = color.unlockLevel, needed > 1 else { continue }
            XCTAssertEqual(WardrobeRules.lock(for: color, level: needed - 1, isPlus: false), .level(needed), color.rawValue)
            XCTAssertEqual(WardrobeRules.lock(for: color, level: needed, isPlus: false), .unlocked, color.rawValue)
        }
        XCTAssertEqual(WardrobeRules.lock(for: .vanilla, level: 1, isPlus: false), .unlocked)
    }

    func testBadgeItemsNeedTheirBadgeAtAnyLevel() {
        for accessory in MochiAccessory.allCases {
            guard let achievement = accessory.unlockAchievement else { continue }
            XCTAssertEqual(
                WardrobeRules.lock(for: accessory, level: RewardEngine.maxLevel, unlockedAchievements: [],
                                   grantedAccessories: [], isPlus: true),
                .achievement(achievement), "\(accessory.rawValue): levels and Plus do not open a badge item"
            )
            XCTAssertEqual(
                WardrobeRules.lock(for: accessory, level: 1, unlockedAchievements: [achievement.rawValue],
                                   grantedAccessories: [], isPlus: false),
                .unlocked, accessory.rawValue
            )
        }
    }

    func testPlusClosetNeedsPlusAndNothingElseDoes() {
        let everything = Set(AchievementID.allCases.map(\.rawValue))
        for accessory in MochiAccessory.allCases {
            let free = WardrobeRules.lock(for: accessory, level: RewardEngine.maxLevel,
                                          unlockedAchievements: everything, grantedAccessories: [], isPlus: false)
            XCTAssertEqual(free == .plus, accessory.requiresPlus, accessory.rawValue)
            XCTAssertEqual(
                WardrobeRules.lock(for: accessory, level: RewardEngine.maxLevel, unlockedAchievements: everything,
                                   grantedAccessories: [], isPlus: true),
                .unlocked, accessory.rawValue
            )
        }
        XCTAssertEqual(MochiAccessory.allCases.filter(\.requiresPlus).count, 4)
        XCTAssertEqual(MochiBodyColor.allCases.filter(\.requiresPlus).count, 4)
        for color in MochiBodyColor.allCases where color.requiresPlus {
            XCTAssertEqual(WardrobeRules.lock(for: color, level: RewardEngine.maxLevel, isPlus: false), .plus)
            XCTAssertEqual(WardrobeRules.lock(for: color, level: 1, isPlus: true), .unlocked)
        }
    }

    /// Every locked label names a level, a badge or Plus — never a price.
    func testLockedLabelsNeverMentionMoney() {
        let locks: [WardrobeLock] = [.level(8), .achievement(.night_owl), .plus]
        for lock in locks {
            let text = (WardrobeRules.label(for: lock) ?? "") + " " + WardrobeRules.spokenLock(for: lock)
            for word in ["buy", "Buy", "$", "price", "Price", "purchase", "Purchase"] {
                XCTAssertFalse(text.contains(word), "\(lock): \(text)")
            }
        }
        XCTAssertEqual(WardrobeRules.label(for: .level(8)), "Level 8")
        XCTAssertEqual(WardrobeRules.label(for: .plus), "Plus")
        XCTAssertEqual(WardrobeRules.label(for: .achievement(.night_owl)), "Night owl badge")
        XCTAssertNil(WardrobeRules.label(for: .unlocked))
    }

    func testNextUnlockWalksTheLevelLadder() {
        XCTAssertEqual(WardrobeRules.nextUnlock(after: 1)?.name, "Red scarf")
        XCTAssertEqual(WardrobeRules.nextUnlock(after: 1)?.level, 2)
        XCTAssertEqual(WardrobeRules.nextUnlock(after: 2)?.name, "Party hat", "an accessory before a colour on the same level")
        XCTAssertEqual(WardrobeRules.nextUnlock(after: 6)?.level, 7)
        XCTAssertEqual(WardrobeRules.nextUnlock(after: 6)?.name, "Blueberry colour")
        XCTAssertEqual(WardrobeRules.nextUnlock(after: 10)?.name, "Cape")
        XCTAssertNil(WardrobeRules.nextUnlock(after: 12))
    }

    func testCandyToNextLevel() {
        XCTAssertEqual(WardrobeRules.candyToNextLevel(candy: 0), 40)
        XCTAssertEqual(WardrobeRules.candyToNextLevel(candy: 39), 1)
        XCTAssertEqual(WardrobeRules.candyToNextLevel(candy: 40), 80)
        XCTAssertNil(WardrobeRules.candyToNextLevel(candy: RewardEngine.candyRequired(toReach: RewardEngine.maxLevel)))
    }

    // MARK: - The screen agrees with the service

    func testWardrobeRulesMatchTheServiceAtEveryLevel() throws {
        for isPlus in [false, true] {
            entitlements.setPlus(isPlus)
            for level in [1, 2, 3, 4, 5, 7, 8, 10, 12, 30] {
                try setLevel(level)
                for accessory in MochiAccessory.allCases {
                    XCTAssertEqual(
                        try rulesLock(accessory) == .unlocked, service.isUnlocked(accessory),
                        "\(accessory.rawValue) at level \(level), Plus \(isPlus)"
                    )
                }
                for color in MochiBodyColor.allCases {
                    XCTAssertEqual(
                        WardrobeRules.lock(for: color, level: level, isPlus: isPlus) == .unlocked,
                        service.isUnlocked(color),
                        "\(color.rawValue) at level \(level), Plus \(isPlus)"
                    )
                }
            }
        }
    }

    func testBadgeItemsAgreeWithTheServiceOnceEarned() throws {
        try grant(.night_owl)
        XCTAssertTrue(service.isUnlocked(.nightcap))
        XCTAssertEqual(try rulesLock(.nightcap), .unlocked)
        XCTAssertFalse(service.isUnlocked(.sunVisor))
        XCTAssertEqual(try rulesLock(.sunVisor), .achievement(.early_bird))
    }

    // MARK: - Wearing

    func testOneItemPerSlot() throws {
        try setLevel(12)
        try service.setEquipped(.partyHat, slot: .head)
        try service.setEquipped(.crown, slot: .head)
        try service.setEquipped(.roundGlasses, slot: .eyes)
        try service.setEquipped(.redScarf, slot: .neck)
        try service.setEquipped(.cape, slot: .back)

        let look = service.currentLook()
        XCTAssertEqual(Set(look.accessories), [.crown, .roundGlasses, .redScarf, .cape])
        for slot in MochiAccessory.Slot.allCases {
            XCTAssertEqual(look.accessories.filter { $0.slot == slot }.count, 1, slot.rawValue)
        }

        try service.setEquipped(nil, slot: .head)
        XCTAssertFalse(service.currentLook().accessories.contains { $0.slot == .head }, "nil empties the slot")
    }

    func testAnItemCannotBeWornInAnotherSlot() throws {
        try setLevel(12)
        try service.setEquipped(.crown, slot: .neck)
        XCTAssertTrue(service.currentLook().accessories.isEmpty)
    }

    func testPlusClosetIsGatedByEntitlements() throws {
        try setLevel(RewardEngine.maxLevel)
        try service.setEquipped(.halo, slot: .head)
        try service.setBodyColor(.galaxy)
        XCTAssertFalse(service.currentLook().accessories.contains(.halo), "no Plus, no halo — even at the top level")
        XCTAssertEqual(service.currentLook().color, .vanilla)

        entitlements.setPlus(true)
        try service.setEquipped(.halo, slot: .head)
        try service.setBodyColor(.galaxy)
        XCTAssertTrue(service.currentLook().accessories.contains(.halo))
        XCTAssertEqual(service.currentLook().color, .galaxy)

        // A refund or a different Apple ID: the closet item comes off, and nothing earned does.
        try service.setEquipped(.redScarf, slot: .neck)
        entitlements.setPlus(false)
        let look = service.currentLook()
        XCTAssertFalse(look.accessories.contains(.halo))
        XCTAssertTrue(look.accessories.contains(.redScarf))
        XCTAssertEqual(look.color, .vanilla)
    }

    func testColoursUnlockWithLevels() throws {
        try service.setBodyColor(.matcha)
        XCTAssertEqual(service.currentLook().color, .vanilla, "matcha is level 5")
        try setLevel(5)
        try service.setBodyColor(.matcha)
        XCTAssertEqual(service.currentLook().color, .matcha)
    }

    func testStageFollowsLevel() throws {
        let expectations: [(Int, MochiStage)] = [(1, .sprout), (4, .sprout), (5, .kid), (9, .kid),
                                                  (10, .teen), (14, .teen), (15, .grown), (30, .grown)]
        for (level, stage) in expectations {
            try setLevel(level)
            XCTAssertEqual(service.currentLook().stage, stage, "level \(level)")
        }
    }
}
