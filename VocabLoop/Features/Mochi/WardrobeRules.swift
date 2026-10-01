import Foundation

/// Why a wardrobe item cannot be worn yet — or that it can.
///
/// Every locked state names how it opens, and none of them is a price: a level, a badge, or the
/// Plus closet (which links to the one screen that sells anything, ``PlusView``).
enum WardrobeLock: Equatable {
    case unlocked
    case level(Int)
    case achievement(AchievementID)
    case plus
}

/// What the wardrobe shows about each item, as pure functions of the profile's numbers.
///
/// Mirrors ``EngagementService``'s private unlock check; `WardrobeTests` holds the two to the same
/// answer for every item at every level, so the wardrobe can never offer what the service will
/// then refuse to put on.
enum WardrobeRules {
    static func lock(
        for accessory: MochiAccessory,
        level: Int,
        unlockedAchievements: Set<String>,
        grantedAccessories: Set<String>,
        isPlus: Bool
    ) -> WardrobeLock {
        if accessory.requiresPlus { return isPlus ? .unlocked : .plus }
        if let needed = accessory.unlockLevel, level >= needed { return .unlocked }
        if let achievement = accessory.unlockAchievement, unlockedAchievements.contains(achievement.rawValue) {
            return .unlocked
        }
        if grantedAccessories.contains(accessory.rawValue) { return .unlocked }
        if let needed = accessory.unlockLevel { return .level(needed) }
        if let achievement = accessory.unlockAchievement { return .achievement(achievement) }
        // Neither a level nor a badge nor Plus: nothing in the catalogue today. Shown as the
        // highest level rather than as something purchasable.
        return .level(RewardEngine.maxLevel)
    }

    static func lock(for color: MochiBodyColor, level: Int, isPlus: Bool) -> WardrobeLock {
        if color.requiresPlus { return isPlus ? .unlocked : .plus }
        guard let needed = color.unlockLevel else { return .level(RewardEngine.maxLevel) }
        return level >= needed ? .unlocked : .level(needed)
    }

    /// Short label under a locked tile: "Level 8", "Night owl badge", "Plus".
    static func label(for lock: WardrobeLock) -> String? {
        switch lock {
        case .unlocked: return nil
        case .level(let level): return "Level \(level)"
        case .achievement(let id): return "\(AchievementCatalog.achievement(id)?.name ?? "Badge") badge"
        case .plus: return "Plus"
        }
    }

    /// The sentence VoiceOver reads for a locked tile.
    static func spokenLock(for lock: WardrobeLock) -> String {
        switch lock {
        case .unlocked: return "Unlocked"
        case .level(let level): return "Locked. Unlocks at level \(level)"
        case .achievement(let id):
            return "Locked. Unlocks with the \(AchievementCatalog.achievement(id)?.name ?? "matching") badge"
        case .plus: return "Part of the Plus closet. Opens VocabLoop Plus"
        }
    }

    /// The next thing a level brings, after `level`: its name and the level it arrives at.
    /// Accessories before colours when both arrive together. `nil` past the last level unlock.
    static func nextUnlock(after level: Int) -> (name: String, level: Int)? {
        var best: (name: String, level: Int)?
        for accessory in MochiAccessory.allCases where !accessory.requiresPlus {
            guard let needed = accessory.unlockLevel, needed > level else { continue }
            if let current = best, current.level <= needed { continue }
            best = (accessory.name, needed)
        }
        for color in MochiBodyColor.allCases where !color.requiresPlus {
            guard let needed = color.unlockLevel, needed > level else { continue }
            if let current = best, current.level <= needed { continue }
            best = ("\(color.name) colour", needed)
        }
        return best
    }

    /// Candy still needed to reach the next level, or `nil` at the cap.
    static func candyToNextLevel(candy: Int) -> Int? {
        let level = RewardEngine.level(forCandy: candy)
        guard level < RewardEngine.maxLevel else { return nil }
        return max(0, RewardEngine.candyRequired(toReach: level + 1) - candy)
    }

    static func stageName(_ stage: MochiStage) -> String {
        switch stage {
        case .sprout: return "Sprout"
        case .kid: return "Little Mochi"
        case .teen: return "Big Mochi"
        case .grown: return "Grown-up Mochi"
        }
    }

    /// Wardrobe section title for a slot.
    static func slotTitle(_ slot: MochiAccessory.Slot) -> String {
        switch slot {
        case .head: return "Hats"
        case .eyes: return "Glasses"
        case .neck: return "Scarves and pins"
        case .back: return "Capes"
        }
    }

    /// The wardrobe item a badge unlocks, if any — shown on the badge so the two screens connect.
    static func accessory(unlockedBy achievement: AchievementID) -> MochiAccessory? {
        MochiAccessory.allCases.first { $0.unlockAchievement == achievement }
    }
}
