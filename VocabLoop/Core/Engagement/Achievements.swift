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
            id: .first_review, name: "First step",
            detail: "Answer your very first card.", symbolName: "shoeprints.fill",
            isMet: { $0.lifetimeReviews >= 1 }
        ),
        Achievement(
            id: .streak_3, name: "Three in a row",
            detail: "Study three days in a row.", symbolName: "flame",
            isMet: { $0.bestStreak >= 3 }
        ),
        Achievement(
            id: .streak_7, name: "One whole week",
            detail: "Study seven days in a row.", symbolName: "flame.fill",
            isMet: { $0.bestStreak >= 7 }
        ),
        Achievement(
            id: .streak_30, name: "A month of words",
            detail: "Study thirty days in a row.", symbolName: "calendar",
            isMet: { $0.bestStreak >= 30 }
        ),
        Achievement(
            id: .combo_10, name: "On a roll",
            detail: "Get ten answers in a row.", symbolName: "bolt",
            isMet: { $0.bestCombo >= 10 }
        ),
        Achievement(
            id: .combo_25, name: "Unstoppable",
            detail: "Get twenty-five answers in a row.", symbolName: "bolt.fill",
            isMet: { $0.bestCombo >= 25 }
        ),
        Achievement(
            id: .combo_50, name: "Fifty!",
            detail: "Get fifty answers in a row.", symbolName: "bolt.circle.fill",
            isMet: { $0.bestCombo >= 50 }
        ),
        Achievement(
            id: .mastered_10, name: "Ten stickers",
            detail: "Make ten stickers shine.", symbolName: "star",
            isMet: { $0.matureWords >= 10 }
        ),
        Achievement(
            id: .mastered_100, name: "Sticker star",
            detail: "Make a hundred stickers shine.", symbolName: "star.fill",
            isMet: { $0.matureWords >= 100 }
        ),
        Achievement(
            id: .mastered_500, name: "Word collector",
            detail: "Make five hundred stickers shine.", symbolName: "star.circle.fill",
            isMet: { $0.matureWords >= 500 }
        ),
        Achievement(
            id: .album_first, name: "First album",
            detail: "Fill a whole sticker page.", symbolName: "book.closed.fill",
            isMet: { $0.completedAlbums >= 1 }
        ),
        Achievement(
            id: .night_owl, name: "Night owl",
            detail: "Study between 10 pm and 2 am.", symbolName: "moon.stars.fill",
            isMet: { $0.localHour >= 22 || $0.localHour < 2 }
        ),
        Achievement(
            id: .early_bird, name: "Early bird",
            detail: "Study between 5 am and 7 am.", symbolName: "sunrise.fill",
            isMet: { $0.localHour >= 5 && $0.localHour < 7 }
        ),
        Achievement(
            id: .goal_7, name: "Goal getter",
            detail: "Reach your daily goal on seven days.", symbolName: "target",
            isMet: { $0.goalDaysTotal >= 7 }
        ),
        Achievement(
            id: .quiz_100, name: "Quiz whiz",
            detail: "Get a hundred quiz questions right.", symbolName: "checkmark.seal.fill",
            isMet: { $0.quizCorrectTotal >= 100 }
        ),
        Achievement(
            id: .mochi_10, name: "Best friends",
            detail: "Help Mochi reach level 10.", symbolName: "heart.fill",
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
