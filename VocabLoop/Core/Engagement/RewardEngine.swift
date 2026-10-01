import Foundation

/// How loud a combo milestone should be: which sound plays, how big Mochi's reaction is.
///
/// `.none` for every combo that is not a milestone, so a caller that plays
/// `RewardEngine.comboTier(combo)` after every answer stays silent between milestones rather
/// than chiming on each one.
public enum ComboTier: Equatable, Sendable {
    case none
    /// Combo 3 and 5.
    case small
    /// Combo 10, 15 and 20.
    case medium
    /// Combo 30 and every milestone after it.
    case big
}

/// The star-candy economy: what each thing earns, and what level a total buys.
///
/// Pure and storage-free on purpose. Every number a child will notice — "why did I only get one
/// candy?", "why am I still level 4?" — comes from here, so all of them can be pinned by a unit
/// test instead of being discovered on a device. The numbers are the product decisions in
/// `docs/ENGAGEMENT-PLAN.md` §1.1 and §1.3; change them there first.
public enum RewardEngine {
    /// Level cap. Reached at 17,400 candy — months of daily study, which is the point: a cap
    /// that arrives in a week leaves nothing to grow into.
    public static let maxLevel = 30

    // MARK: - Earning

    /// Every graded review, whatever the rating. Honesty costs nothing: pressing "Forgot" earns
    /// exactly what pressing "Got it" earns.
    public static let candyPerReview = 1
    /// The first review of a study day — the reward for showing up.
    public static let firstReviewBonus = 5
    /// Reaching the daily goal.
    public static let goalBonus = 10
    /// A word's sticker lights up (its card becomes mature).
    public static let stickerBonus = 3
    /// All stickers in an album are shiny.
    public static let albumBonus = 25
    /// Any achievement unlock.
    public static let achievementBonus = 10

    // MARK: - Levels

    /// Candy needed to *reach* `level`: `20 · n · (n − 1)`.
    ///
    /// Quadratic so early levels arrive within days (L2 at 40, L5 at 400) while later ones keep
    /// meaning something (L20 at 7,600). Level 1 and below cost nothing — everybody starts there.
    public static func candyRequired(toReach level: Int) -> Int {
        guard level > 1 else { return 0 }
        return 20 * level * (level - 1)
    }

    /// The level a candy total has bought, `1…maxLevel`.
    ///
    /// Derived, never stored: a stored level could disagree with the candy it came from, and
    /// then one of them is a bug nobody can find.
    public static func level(forCandy candy: Int) -> Int {
        var level = 1
        while level < maxLevel && candy >= candyRequired(toReach: level + 1) {
            level += 1
        }
        return level
    }

    /// Fraction of the way from the current level to the next, `0…1`. `1` at the cap.
    public static func progressToNextLevel(candy: Int) -> Double {
        let current = level(forCandy: candy)
        guard current < maxLevel else { return 1 }
        let floor = candyRequired(toReach: current)
        let ceiling = candyRequired(toReach: current + 1)
        guard ceiling > floor else { return 1 }
        let fraction = Double(max(0, candy) - floor) / Double(ceiling - floor)
        return min(1, max(0, fraction))
    }

    /// Mochi's growth stage for a level. The stage changes the drawing, never the frame.
    public static func stage(forLevel level: Int) -> MochiStage {
        switch level {
        case ..<5: return .sprout
        case 5..<10: return .kid
        case 10..<15: return .teen
        default: return .grown
        }
    }

    // MARK: - Combos

    /// Explicit milestones. Past the last one, every multiple of 50 is also a milestone — see
    /// ``isComboMilestone(_:)``.
    public static let comboMilestones: [Int] = [3, 5, 10, 15, 20, 30, 50, 75, 100]

    public static func isComboMilestone(_ combo: Int) -> Bool {
        if comboMilestones.contains(combo) { return true }
        return combo > 100 && combo % 50 == 0
    }

    /// Bonus candy for reaching `combo`, or `0` when it is not a milestone.
    ///
    /// Small on purpose. The base candy is per *answer*, so breaking a run with an honest
    /// "Forgot" costs a few candies at most — never enough to make pressing "Got it" on a word
    /// you forgot worth it.
    public static func comboBonus(_ combo: Int) -> Int {
        guard isComboMilestone(combo) else { return 0 }
        switch combo {
        case 3: return 1
        case 5: return 2
        case 10, 15: return 3
        case 20, 30: return 5
        case 50, 75: return 10
        default: return 20 // 100 and every 50 after it.
        }
    }

    /// Celebration size for `combo`, or `.none` when it is not a milestone.
    public static func comboTier(_ combo: Int) -> ComboTier {
        guard isComboMilestone(combo) else { return .none }
        switch combo {
        case ..<10: return .small
        case 10..<30: return .medium
        default: return .big
        }
    }
}
