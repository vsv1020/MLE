import Foundation
import SwiftData
import OSLog

/// Everything the engagement layer needs to know about one graded review.
///
/// Built by the study view model after ``ReviewService`` has graded the card, so the maturity
/// values bracket the real state transition.
public struct ReviewOutcomeEvent: Sendable {
    public var cardID: String
    public var entryStableID: String
    public var rating: Rating
    public var questionKind: QuestionKind
    public var wasAutoGraded: Bool
    public var responseMS: Int
    public var phaseBefore: LearningPhase
    public var maturityBefore: CardMaturity
    public var maturityAfter: CardMaturity
    /// The view model's session combo, already updated for this answer.
    public var comboAfter: Int
    public var justReachedGoal: Bool
    public var reviewsToday: Int

    public init(
        cardID: String,
        entryStableID: String,
        rating: Rating,
        questionKind: QuestionKind,
        wasAutoGraded: Bool,
        responseMS: Int,
        phaseBefore: LearningPhase,
        maturityBefore: CardMaturity,
        maturityAfter: CardMaturity,
        comboAfter: Int,
        justReachedGoal: Bool,
        reviewsToday: Int
    ) {
        self.cardID = cardID
        self.entryStableID = entryStableID
        self.rating = rating
        self.questionKind = questionKind
        self.wasAutoGraded = wasAutoGraded
        self.responseMS = responseMS
        self.phaseBefore = phaseBefore
        self.maturityBefore = maturityBefore
        self.maturityAfter = maturityAfter
        self.comboAfter = comboAfter
        self.justReachedGoal = justReachedGoal
        self.reviewsToday = reviewsToday
    }
}

/// Something worth celebrating. The UI shows them one at a time.
public enum EngagementEvent: Equatable, Sendable {
    /// Total candy this review added, bonuses included.
    case candy(Int)
    case firstReviewToday(streak: Int)
    case comboMilestone(Int)
    /// Emitted by the view model, not the service, when a run of five or more ends. Listed here
    /// so the toast has one `switch`. The run is celebrated; the break is never mentioned.
    case comboEnded(best: Int)
    case stickerLit(entryStableID: String)
    case albumCompleted(albumID: String, title: String)
    case levelUp(Int)
    case achievement(AchievementID)
    case welcomeBack(daysAway: Int)
}

/// What the study screen needs when a session opens.
public struct SessionOpening: Sendable {
    public var streak: StreakService.Streak
    public var studiedToday: Bool
    /// Study days since the last review, or `nil` for someone who has never studied.
    public var daysSinceLastStudy: Int?
    public var candyTotal: Int
    public var level: Int
    public var look: MochiLook

    public init(
        streak: StreakService.Streak,
        studiedToday: Bool,
        daysSinceLastStudy: Int?,
        candyTotal: Int,
        level: Int,
        look: MochiLook
    ) {
        self.streak = streak
        self.studiedToday = studiedToday
        self.daysSinceLastStudy = daysSinceLastStudy
        self.candyTotal = candyTotal
        self.level = level
        self.look = look
    }
}

/// Candy, levels, the wardrobe and badges for the active account.
///
/// Sits *beside* ``ReviewService``, never inside it: the scheduler grades a card the same way
/// whether or not any of this exists, and nothing here can change a rating, an interval or a
/// review log. Rewards are rating-agnostic by construction — ``record(_:preferences:now:)``
/// receives the rating only to count it.
@MainActor
public final class EngagementService {
    private let context: ModelContext
    private let notifications: NotificationService
    private let snapshots: WidgetSnapshotWriter
    private let entitlements: Entitlements
    private let logger = Logger(subsystem: "com.vocabloop.app", category: "engagement")

    public init(
        context: ModelContext,
        notifications: NotificationService,
        snapshots: WidgetSnapshotWriter,
        entitlements: Entitlements
    ) {
        self.context = context
        self.notifications = notifications
        self.snapshots = snapshots
        self.entitlements = entitlements
    }

    // MARK: - Profile

    /// The active account's profile, created on first use.
    ///
    /// Fetch-or-create rather than create-at-sign-up so every existing install gets one the first
    /// time it is asked for, with no migration step.
    public func profile() throws -> EngagementProfile {
        let userID = try context.activeAccount().userID
        var descriptor = FetchDescriptor<EngagementProfile>(predicate: #Predicate { $0.userID == userID })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first { return existing }

        let profile = EngagementProfile(userID: userID)
        context.insert(profile)
        try context.save()
        return profile
    }

    // MARK: - Session

    public func sessionOpened(preferences: StudyPreferences, now: Date) throws -> SessionOpening {
        let profile = try self.profile()
        let days = try studyDays()
        let calendar = StudyCalendar(preferences: preferences)
        let streak = StreakService.streak(days: days, calendar: calendar, now: now)
        let todayKey = calendar.dayKey(for: now)
        let studiedToday = days.contains { $0.dayKey == todayKey && $0.reviewsCompleted > 0 }

        // Installs upgrading to 1.0.7 have history but no `lastStudiedAt` yet; their last
        // active study day stands in, so "Mochi missed you" works for them on day one.
        let lastActiveDay = days.filter { $0.reviewsCompleted > 0 }.map(\.dayStart).max()
        let lastStudied = profile.lastStudiedAt ?? lastActiveDay
        let daysSince = lastStudied.map { max(0, calendar.dayDifference(from: $0, to: now)) }

        return SessionOpening(
            streak: streak,
            studiedToday: studiedToday,
            daysSinceLastStudy: daysSince,
            candyTotal: profile.candyTotal,
            level: profile.level,
            look: look(for: profile)
        )
    }

    /// Apply one graded review to the profile and report what to celebrate.
    ///
    /// Foundation (W0) scope: base candy, `lastStudiedAt`, save. The full sequence — weekly
    /// rollover, first-review bonus, combo bonus, stickers and albums, achievements, level-up,
    /// streak reminder and widget snapshot — is specified in `docs/ENGAGEMENT-PLAN.md` §2.2.
    public func record(_ event: ReviewOutcomeEvent, preferences: StudyPreferences, now: Date) throws -> [EngagementEvent] {
        let profile = try self.profile()
        let earned = RewardEngine.candyPerReview
        profile.candyTotal += earned
        profile.lastStudiedAt = now
        profile.touch(now)
        try context.save()
        return [.candy(earned)]
    }

    public func streak(preferences: StudyPreferences, now: Date) throws -> StreakService.Streak {
        StreakService.streak(days: try studyDays(), calendar: StudyCalendar(preferences: preferences), now: now)
    }

    // MARK: - Wardrobe

    /// What Mochi looks like right now. `.default` if the profile cannot be read.
    public func currentLook() -> MochiLook {
        guard let profile = try? self.profile() else { return .default }
        return look(for: profile)
    }

    /// Wear `accessory` in `slot`, replacing whatever was there; `nil` empties the slot. Ignored
    /// for an item that is locked or belongs to a different slot.
    public func setEquipped(_ accessory: MochiAccessory?, slot: MochiAccessory.Slot) throws {
        let profile = try self.profile()
        if let accessory {
            guard accessory.slot == slot, isUnlocked(accessory, profile: profile) else { return }
        }
        var equipped = profile.equippedAccessoryIDs.filter { raw in
            guard let worn = MochiAccessory(rawValue: raw) else { return false }
            return worn.slot != slot
        }
        if let accessory { equipped.append(accessory.rawValue) }
        profile.equippedAccessoryIDs = equipped
        profile.touch()
        try context.save()
    }

    public func setBodyColor(_ color: MochiBodyColor) throws {
        let profile = try self.profile()
        guard isUnlocked(color, profile: profile) else { return }
        profile.bodyColorRaw = color.rawValue
        profile.touch()
        try context.save()
    }

    public func isUnlocked(_ accessory: MochiAccessory) -> Bool {
        guard let profile = try? self.profile() else { return false }
        return isUnlocked(accessory, profile: profile)
    }

    public func isUnlocked(_ color: MochiBodyColor) -> Bool {
        guard let profile = try? self.profile() else { return color == .vanilla }
        return isUnlocked(color, profile: profile)
    }

    // MARK: - Achievements

    /// Every achievement, in catalogue order, with its unlock date when earned.
    public func achievementStatuses(preferences: StudyPreferences, now: Date) throws -> [AchievementStatus] {
        let profile = try self.profile()
        var unlockedAt: [String: Date] = [:]
        for unlocked in profile.unlockedAchievements where unlockedAt[unlocked.id] == nil {
            unlockedAt[unlocked.id] = unlocked.unlockedAt
        }
        return AchievementCatalog.all.map { achievement in
            AchievementStatus(achievement: achievement, unlockedAt: unlockedAt[achievement.id.rawValue])
        }
    }

    // MARK: - Side effects

    /// Schedule or remove the evening "streak at risk" nudge.
    ///
    /// Foundation (W0) scope: a no-op. Wired to `NotificationService.refreshStreakReminder`
    /// when that lands (engagement plan §1.2, §2.2).
    public func refreshStreakReminder(preferences: StudyPreferences, now: Date) async {
        _ = notifications
    }

    /// Write the widget snapshot file. Never throws: a stale widget is not worth an error.
    public func writeWidgetSnapshot(preferences: StudyPreferences, now: Date) {
        do {
            let profile = try self.profile()
            let days = try studyDays()
            let calendar = StudyCalendar(preferences: preferences)
            let todayKey = calendar.dayKey(for: now)
            let today = days.first { $0.dayKey == todayKey }
            let streak = StreakService.streak(days: days, calendar: calendar, now: now)

            let languageCode = preferences.activeLanguageCode
            let cards = try context.fetch(
                FetchDescriptor<Card>(predicate: #Predicate { $0.languageCode == languageCode })
            )
            // Same definition of "due now" as `StatsService`: graded cards only, not new ones.
            let dueNow = cards.filter { $0.phase != .new && $0.isDue(at: now) }.count
            let look = self.look(for: profile)

            snapshots.write(
                WidgetSnapshot(
                    dueNow: dueNow,
                    reviewsToday: today?.reviewsCompleted ?? 0,
                    dailyGoal: preferences.dailyGoal,
                    streak: streak.current,
                    studiedToday: (today?.reviewsCompleted ?? 0) > 0,
                    mochiLevel: profile.level,
                    candy: profile.candyTotal,
                    bodyColor: look.color.rawValue,
                    accessories: look.accessories.map(\.rawValue),
                    updatedAt: now
                )
            )
        } catch {
            logger.error("Widget snapshot skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private

    private func studyDays() throws -> [StudyDay] {
        let userID = try context.activeAccount().userID
        return try context.fetch(
            FetchDescriptor<StudyDay>(
                predicate: #Predicate { $0.userID == userID },
                sortBy: [SortDescriptor(\.dayStart)]
            )
        )
    }

    private func look(for profile: EngagementProfile) -> MochiLook {
        let color = profile.bodyColor
        let accessories = profile.equippedAccessoryIDs
            .compactMap { MochiAccessory(rawValue: $0) }
            .filter { isUnlocked($0, profile: profile) }
        return MochiLook(
            stage: RewardEngine.stage(forLevel: profile.level),
            color: isUnlocked(color, profile: profile) ? color : .vanilla,
            accessories: accessories
        )
    }

    /// Plus closet items need Plus; everything else is earned and, once earned, always free.
    private func isUnlocked(_ accessory: MochiAccessory, profile: EngagementProfile) -> Bool {
        if accessory.requiresPlus { return entitlements.isPlus }
        if let level = accessory.unlockLevel, profile.level >= level { return true }
        if let achievement = accessory.unlockAchievement,
           profile.unlockedAchievementIDs.contains(achievement.rawValue) {
            return true
        }
        return profile.unlockedAccessoryIDs.contains(accessory.rawValue)
    }

    private func isUnlocked(_ color: MochiBodyColor, profile: EngagementProfile) -> Bool {
        if color.requiresPlus { return entitlements.isPlus }
        guard let level = color.unlockLevel else { return false }
        return profile.level >= level
    }
}
