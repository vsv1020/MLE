import Foundation
import SwiftData

/// An achievement and when it was earned. Stored inside ``EngagementProfile`` as a `Codable`
/// array — the same embedding ``ExampleSentence`` uses — because it is never queried on its own.
public struct UnlockedAchievement: Codable, Hashable, Sendable {
    /// ``AchievementID`` raw value. A string rather than the enum so a badge retired in a later
    /// build still decodes instead of failing the whole row.
    public var id: String
    public var unlockedAt: Date

    public init(id: String, unlockedAt: Date) {
        self.id = id
        self.unlockedAt = unlockedAt
    }
}

/// Everything the "come back tomorrow" loop remembers for one account: candy, counters,
/// wardrobe, badges.
///
/// A new entity rather than columns on ``UserAccount`` or ``StudyPreferences``: adding an entity
/// is the one SwiftData change that is always a lightweight migration, and keeping it apart means
/// a bug here can never corrupt the account or the scheduler settings.
///
/// **Every stored property has a declaration default** (the precedent is
/// ``ReviewLog/easeFactorBefore``), and every default is a literal. Anything added later must do
/// the same, or opening an existing store will fail on launch.
///
/// Level, stage, streak and sticker state are *derived* and deliberately not stored here — see
/// ``RewardEngine``.
@Model
public final class EngagementProfile {
    /// The owning ``UserAccount/userID``. Unique: one profile per account.
    @Attribute(.unique) public var userID: String

    /// Lifetime star candy. Never spent — it is XP, and the level is derived from it.
    public var candyTotal: Int = 0
    public var lifetimeReviews: Int = 0
    /// Correct answers to auto-graded questions, for the `quiz_100` badge.
    public var quizCorrectTotal: Int = 0
    /// Study days on which the daily goal was reached, for the `goal_7` badge.
    public var goalDaysTotal: Int = 0
    public var bestCombo: Int = 0

    /// ``StudyCalendar`` day key of the first day of the week the weekly fields below belong to.
    /// When it no longer matches, the weekly fields are reset before anything is added.
    public var weekKey: String = ""
    public var candyThisWeek: Int = 0
    public var bestComboThisWeek: Int = 0

    public var lastStudiedAt: Date? = nil
    /// Day key of the last day the "first review today" bonus was paid, so it is paid once.
    public var lastFirstReviewDayKey: String = ""

    /// ``MochiAccessory`` raw values currently worn, at most one per slot.
    public var equippedAccessoryIDs: [String] = []
    /// Accessories granted by achievements. Level unlocks are derived from candy, not stored.
    public var unlockedAccessoryIDs: [String] = []
    /// ``MochiBodyColor`` raw value.
    public var bodyColorRaw: String = "vanilla"
    public var unlockedAchievements: [UnlockedAchievement] = []
    /// ``Album/id`` values completed so far, so an album pays its bonus once.
    public var completedAlbumIDs: [String] = []

    public var updatedAt: Date = Date()

    public init(userID: String) {
        self.userID = userID
        // Assigned as well as defaulted: the defaults are what a migrated row gets, these are
        // what a new one gets, and spelling them out keeps the two from drifting.
        self.candyTotal = 0
        self.lifetimeReviews = 0
        self.quizCorrectTotal = 0
        self.goalDaysTotal = 0
        self.bestCombo = 0
        self.weekKey = ""
        self.candyThisWeek = 0
        self.bestComboThisWeek = 0
        self.lastStudiedAt = nil
        self.lastFirstReviewDayKey = ""
        self.equippedAccessoryIDs = []
        self.unlockedAccessoryIDs = []
        self.bodyColorRaw = MochiBodyColor.vanilla.rawValue
        self.unlockedAchievements = []
        self.completedAlbumIDs = []
        self.updatedAt = Date()
    }

    /// Derived from ``candyTotal`` on every read.
    public var level: Int { RewardEngine.level(forCandy: candyTotal) }

    public var bodyColor: MochiBodyColor {
        MochiBodyColor(rawValue: bodyColorRaw) ?? .vanilla
    }

    public var unlockedAchievementIDs: Set<String> {
        Set(unlockedAchievements.map(\.id))
    }

    public func touch(_ now: Date = Date()) { updatedAt = now }
}
