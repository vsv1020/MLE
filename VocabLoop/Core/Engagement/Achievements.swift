import Foundation

/// The sixteen badges. Raw values are persisted in ``EngagementProfile/unlockedAchievements``,
/// so a case may be added but never renamed.
public enum AchievementID: String, CaseIterable, Codable, Sendable {
    case first_review
    case streak_3
    case streak_7
    case streak_30
    case combo_10
    case combo_25
    case combo_50
    case mastered_10
    case mastered_100
    case mastered_500
    case album_first
    case night_owl
    case early_bird
    case goal_7
    case quiz_100
    case mochi_10
}

/// Everything an achievement condition may look at.
///
/// A plain value rather than the store, so every condition is a pure function that a unit test
/// can drive with literals.
public struct AchievementContext: Sendable {
    public var lifetimeReviews: Int
    public var currentStreak: Int
    public var longestStreak: Int
    public var bestCombo: Int
    public var matureWords: Int
    public var completedAlbums: Int
    public var goalDaysTotal: Int
    public var quizCorrectTotal: Int
    public var level: Int
    /// Wall-clock hour of the review being recorded, `0…23`, in the user's time zone.
    public var localHour: Int

    public init(
        lifetimeReviews: Int = 0,
        currentStreak: Int = 0,
        longestStreak: Int = 0,
        bestCombo: Int = 0,
        matureWords: Int = 0,
        completedAlbums: Int = 0,
        goalDaysTotal: Int = 0,
        quizCorrectTotal: Int = 0,
        level: Int = 1,
        localHour: Int = 12
    ) {
        self.lifetimeReviews = lifetimeReviews
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.bestCombo = bestCombo
        self.matureWords = matureWords
        self.completedAlbums = completedAlbums
        self.goalDaysTotal = goalDaysTotal
        self.quizCorrectTotal = quizCorrectTotal
        self.level = level
        self.localHour = localHour
    }

    /// The better of the current and the longest streak.
    ///
    /// A streak badge rewards having done it, so a streak that has since ended still counts —
    /// taking a badge's chance away because of a missed day would be the guilt this release
    /// avoids everywhere else.
    var bestStreak: Int { max(currentStreak, longestStreak) }
}

/// One badge: its copy, its symbol, and the condition that earns it.
public struct Achievement: Identifiable, Sendable {
    public let id: AchievementID
    public let name: String
    /// One line, written for a child.
    public let detail: String
    /// SF Symbol name.
    public let symbolName: String
    public let isMet: @Sendable (AchievementContext) -> Bool

    public init(
        id: AchievementID,
        name: String,
        detail: String,
        symbolName: String,
        isMet: @escaping @Sendable (AchievementContext) -> Bool
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.symbolName = symbolName
        self.isMet = isMet
    }
}

/// An achievement and, when earned, the moment it was.
public struct AchievementStatus: Identifiable, Sendable {
    public let achievement: Achievement
    public let unlockedAt: Date?

    public init(achievement: Achievement, unlockedAt: Date?) {
        self.achievement = achievement
        self.unlockedAt = unlockedAt
    }

    public var id: AchievementID { achievement.id }
    public var isUnlocked: Bool { unlockedAt != nil }
}

/// The catalogue, in display order, and the one function that decides what is newly earned.
public enum AchievementCatalog {
    public static let all: [Achievement] = [
        Achievement(
            id: .first_review, name: "第一步",
            detail: "回答你的第一张卡片。", symbolName: "shoeprints.fill",
            isMet: { $0.lifetimeReviews >= 1 }
        ),
        Achievement(
            id: .streak_3, name: "连续三天",
            detail: "连续学习 3 天。", symbolName: "flame",
            isMet: { $0.bestStreak >= 3 }
        ),
        Achievement(
            id: .streak_7, name: "整整一周",
            detail: "连续学习 7 天。", symbolName: "flame.fill",
            isMet: { $0.bestStreak >= 7 }
        ),
        Achievement(
            id: .streak_30, name: "单词满月",
            detail: "连续学习 30 天。", symbolName: "calendar",
            isMet: { $0.bestStreak >= 30 }
        ),
        Achievement(
            id: .combo_10, name: "手感正好",
            detail: "连续答对 10 题。", symbolName: "bolt",
            isMet: { $0.bestCombo >= 10 }
        ),
        Achievement(
            id: .combo_25, name: "势不可挡",
            detail: "连续答对 25 题。", symbolName: "bolt.fill",
            isMet: { $0.bestCombo >= 25 }
        ),
        Achievement(
            id: .combo_50, name: "五十连！",
            detail: "连续答对 50 题。", symbolName: "bolt.circle.fill",
            isMet: { $0.bestCombo >= 50 }
        ),
        Achievement(
            id: .mastered_10, name: "十张贴纸",
            detail: "让 10 张贴纸闪亮起来。", symbolName: "star",
            isMet: { $0.matureWords >= 10 }
        ),
        Achievement(
            id: .mastered_100, name: "贴纸之星",
            detail: "让 100 张贴纸闪亮起来。", symbolName: "star.fill",
            isMet: { $0.matureWords >= 100 }
        ),
        Achievement(
            id: .mastered_500, name: "单词收藏家",
            detail: "让 500 张贴纸闪亮起来。", symbolName: "star.circle.fill",
            isMet: { $0.matureWords >= 500 }
        ),
        Achievement(
            id: .album_first, name: "集满第一页",
            detail: "集满一整页贴纸。", symbolName: "book.closed.fill",
            isMet: { $0.completedAlbums >= 1 }
        ),
        Achievement(
            id: .night_owl, name: "夜猫子",
            detail: "在晚上 10 点到凌晨 2 点之间学习。", symbolName: "moon.stars.fill",
            isMet: { $0.localHour >= 22 || $0.localHour < 2 }
        ),
        Achievement(
            id: .early_bird, name: "早起的鸟儿",
            detail: "在早上 5 点到 7 点之间学习。", symbolName: "sunrise.fill",
            isMet: { $0.localHour >= 5 && $0.localHour < 7 }
        ),
        Achievement(
            id: .goal_7, name: "目标达人",
            detail: "累计 7 天完成每日目标。", symbolName: "target",
            isMet: { $0.goalDaysTotal >= 7 }
        ),
        Achievement(
            id: .quiz_100, name: "小测验高手",
            detail: "小测验累计答对 100 题。", symbolName: "checkmark.seal.fill",
            isMet: { $0.quizCorrectTotal >= 100 }
        ),
        Achievement(
            id: .mochi_10, name: "好朋友",
            detail: "帮麻薯升到 10 级。", symbolName: "heart.fill",
            isMet: { $0.level >= 10 }
        ),
    ]

    public static func achievement(_ id: AchievementID) -> Achievement? {
        all.first { $0.id == id }
    }

    /// Achievements met by `context` that are not already in `alreadyUnlocked` (raw values), in
    /// catalogue order. Never returns one twice, so the caller can award each result blindly.
    public static func evaluate(_ context: AchievementContext, alreadyUnlocked: Set<String>) -> [AchievementID] {
        all.compactMap { achievement in
            guard !alreadyUnlocked.contains(achievement.id.rawValue) else { return nil }
            return achievement.isMet(context) ? achievement.id : nil
        }
    }
}
