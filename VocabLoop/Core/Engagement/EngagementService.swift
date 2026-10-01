import Foundation
import SwiftData
import OSLog
import WidgetKit

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

    /// Album lookup for the sticker/album events. Its own instance rather than
    /// `AppDependencies.collection` because the initializer is frozen; it is only consulted when
    /// a card becomes mature — a handful of times a day — and its per-language cache is
    /// dropped by ``invalidateAlbumCache()``.
    private lazy var collection = CollectionService(context: context)

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
    /// Call it after ``ReviewService/grade(card:rating:preferences:durationMS:now:)`` has saved,
    /// so today's ``StudyDay`` and the card's new maturity are already in the store. The order
    /// is `docs/ENGAGEMENT-PLAN.md` §2.2:
    ///
    /// 1. week rollover — the weekly fields are reset *before* anything is added to them;
    /// 2. base candy, `lifetimeReviews`, `lastStudiedAt`;
    /// 3. first review of the study day: +5, once per day (`lastFirstReviewDayKey`);
    /// 4. daily goal reached: +10 and `goalDaysTotal`;
    /// 5. combo milestone bonus, `bestCombo` and `bestComboThisWeek`;
    /// 6. `quizCorrectTotal`;
    /// 7. sticker and album, only on the crossing into maturity;
    /// 8. achievements, each unlocked once, +10 each;
    /// 9. level-up, comparing the level before this review with the level after it;
    /// 10. save; then the streak nudge is removed (whoever just studied has nothing to be nudged
    ///     about) and the widget snapshot is rewritten.
    ///
    /// The returned events start with `.candy(total)` — everything this review added — followed
    /// by the celebrations in the order above. Nothing here reads the rating except to count a
    /// correct quiz answer: candy is identical for every rating.
    ///
    /// Undo does not take anything back. Candy is XP for showing up, and a child watching their
    /// stars disappear is exactly the guilt this release avoids; the once-per-day and
    /// once-per-badge guards keep an undo-and-regrade from paying the same bonus twice.
    public func record(_ event: ReviewOutcomeEvent, preferences: StudyPreferences, now: Date) throws -> [EngagementEvent] {
        let profile = try self.profile()
        let calendar = StudyCalendar(preferences: preferences)
        let todayKey = calendar.dayKey(for: now)
        let levelBefore = profile.level
        var earned = 0
        var celebrations: [EngagementEvent] = []

        // 1. Week rollover.
        let currentWeekKey = Self.weekKey(for: now, calendar: calendar)
        if profile.weekKey != currentWeekKey {
            profile.weekKey = currentWeekKey
            profile.candyThisWeek = 0
            profile.bestComboThisWeek = 0
        }

        // 2. Base candy, whatever the rating.
        earned += RewardEngine.candyPerReview
        profile.lifetimeReviews += 1
        profile.lastStudiedAt = now

        // The streak including today. `ReviewService` has normally written today's `StudyDay`
        // already; if it has not, this review is still today's, so it counts.
        let days = try studyDays()
        let streak = StreakService.streak(days: days, calendar: calendar, now: now)
        let studiedTodayInStore = days.contains { $0.dayKey == todayKey && $0.reviewsCompleted > 0 }
        let currentStreak = studiedTodayInStore ? streak.current : streak.current + 1
        let longestStreak = max(streak.longest, currentStreak)

        // 3. First review of the study day.
        if profile.lastFirstReviewDayKey != todayKey {
            profile.lastFirstReviewDayKey = todayKey
            earned += RewardEngine.firstReviewBonus
            celebrations.append(.firstReviewToday(streak: currentStreak))
        }

        // 4. Daily goal. The view model reports the crossing once; `StudyDay.goalMet` is latched,
        // so an undo below the goal and a regrade does not report it again.
        if event.justReachedGoal {
            earned += RewardEngine.goalBonus
            profile.goalDaysTotal += 1
        }

        // 5. Combo.
        let combo = max(0, event.comboAfter)
        if RewardEngine.isComboMilestone(combo) {
            earned += RewardEngine.comboBonus(combo)
            celebrations.append(.comboMilestone(combo))
        }
        profile.bestCombo = max(profile.bestCombo, combo)
        profile.bestComboThisWeek = max(profile.bestComboThisWeek, combo)

        // 6. Quiz.
        if event.wasAutoGraded && event.rating.isSuccess {
            profile.quizCorrectTotal += 1
        }

        // 7. Sticker and album, exactly on the crossing into maturity.
        var matureWords: Int?
        if event.maturityBefore != .mature && event.maturityAfter == .mature {
            let stickerEvents = stickerAndAlbum(for: event, profile: profile)
            earned += stickerEvents.candy
            celebrations += stickerEvents.events
            matureWords = try? matureWordCount()
        } else if profile.lifetimeReviews == 1 {
            // The first review this profile records. On an upgrade with history, words matured
            // long before 1.0.7 should still earn their badges today, not on the next crossing.
            matureWords = try? matureWordCount()
        }

        // 8. Achievements. Re-evaluated until nothing new unlocks, because a badge's own candy
        // can be what reaches level 10. Bounded by the catalogue size.
        var unlocked = profile.unlockedAchievementIDs
        let localHour = Self.localHour(of: now, timeZone: calendar.timeZone)
        for _ in 0..<AchievementCatalog.all.count {
            let achievementContext = AchievementContext(
                lifetimeReviews: profile.lifetimeReviews,
                currentStreak: currentStreak,
                longestStreak: longestStreak,
                bestCombo: profile.bestCombo,
                matureWords: matureWords ?? 0,
                completedAlbums: profile.completedAlbumIDs.count,
                goalDaysTotal: profile.goalDaysTotal,
                quizCorrectTotal: profile.quizCorrectTotal,
                level: RewardEngine.level(forCandy: profile.candyTotal + earned),
                localHour: localHour
            )
            let newlyMet = AchievementCatalog.evaluate(achievementContext, alreadyUnlocked: unlocked)
            if newlyMet.isEmpty { break }
            for id in newlyMet {
                unlocked.insert(id.rawValue)
                profile.unlockedAchievements.append(UnlockedAchievement(id: id.rawValue, unlockedAt: now))
                earned += RewardEngine.achievementBonus
                celebrations.append(.achievement(id))
                for accessory in MochiAccessory.allCases
                where accessory.unlockAchievement == id
                    && !profile.unlockedAccessoryIDs.contains(accessory.rawValue) {
                    profile.unlockedAccessoryIDs.append(accessory.rawValue)
                }
            }
        }

        profile.candyTotal += earned
        profile.candyThisWeek += earned

        // 9. Level-up. One event with the level reached, even if a big bonus skipped one.
        let levelAfter = profile.level
        if levelAfter > levelBefore {
            celebrations.append(.levelUp(levelAfter))
        }

        // 10. Save, then side effects that must never fail the review.
        profile.touch(now)
        try context.save()

        notifications.cancelStreakReminder()
        writeWidgetSnapshot(preferences: preferences, now: now)

        return [.candy(earned)] + celebrations
    }

    /// Drop the album cache. Call after a content import changes the dictionary.
    public func invalidateAlbumCache() {
        collection.invalidateCache()
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

    /// Schedule or remove the evening "streak at risk" nudge from the stored study days.
    ///
    /// Call on app background and when a session opens. Scheduling rules live in
    /// ``NotificationService/refreshStreakReminder(preferences:streak:studiedToday:now:)``; this
    /// supplies the two facts it needs. If the days cannot be read, the nudge is removed rather
    /// than scheduled on a guess.
    public func refreshStreakReminder(preferences: StudyPreferences, now: Date) async {
        var streak = 0
        var studiedToday = true
        if let days = try? studyDays() {
            let calendar = StudyCalendar(preferences: preferences)
            let todayKey = calendar.dayKey(for: now)
            streak = StreakService.streak(days: days, calendar: calendar, now: now).current
            studiedToday = days.contains { $0.dayKey == todayKey && $0.reviewsCompleted > 0 }
        }
        await notifications.refreshStreakReminder(
            preferences: preferences, streak: streak, studiedToday: studiedToday, now: now
        )
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
            let graded = cards.filter { $0.phase != .new }
            let dueNow = graded.filter { $0.isDue(at: now) }.count
            // What the widget shows after the rollover if the app has not run since: the same
            // rule, evaluated at the end of tomorrow's study day.
            let dayEndsAt = calendar.dayEnd(for: now)
            let tomorrowEnds = calendar.dayEnd(for: dayEndsAt)
            let dueTomorrow = graded.filter { $0.isDue(at: tomorrowEnds) }.count
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
                    updatedAt: now,
                    dayEndsAt: dayEndsAt,
                    dueTomorrow: dueTomorrow
                )
            )
            // The one place the file changes, so the one place the widgets are told to re-read
            // it. WidgetKit coalesces app-initiated reloads; see `docs/WIDGET-PLAN.md` §1.1.
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            logger.error("Widget snapshot skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Pure parts

    /// Day key of the Monday that starts the study week containing `date`.
    ///
    /// The weekly profile fields (`candyThisWeek`, `bestComboThisWeek`) need a fixed boundary to
    /// reset at; the recap's rolling seven-day window cannot provide one. Monday in the study
    /// calendar — so 1am on a Monday still belongs to the week before, like every other day
    /// boundary in the app.
    static func weekKey(for date: Date, calendar: StudyCalendar) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        // `dayStart` is at the rollover hour of the study day's own date, so its weekday is the
        // study day's weekday.
        let weekday = gregorian.component(.weekday, from: calendar.dayStart(for: date)) // 1 = Sunday
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.dayKey(daysAgo: daysSinceMonday, from: date) ?? calendar.dayKey(for: date)
    }

    /// Wall-clock hour of `date`, `0…23`, for the night-owl and early-bird badges.
    static func localHour(of date: Date, timeZone: TimeZone) -> Int {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        return gregorian.component(.hour, from: date)
    }

    // MARK: - Private

    /// Sticker and album rewards for a card that has just become mature.
    ///
    /// The sticker is the *word*, and a word is only as mature as its weakest card (the rule
    /// ``Entry/maturity`` and the sticker book share). So the sticker lights — and pays — when
    /// the crossing card makes the whole word mature: at once for a one-direction word, on the
    /// last card for a word studied both ways. Lookup failures are logged and skipped; a missing
    /// sticker toast must never cost the review its candy.
    private func stickerAndAlbum(
        for event: ReviewOutcomeEvent,
        profile: EngagementProfile
    ) -> (candy: Int, events: [EngagementEvent]) {
        do {
            guard let entry = try context.entry(stableID: event.entryStableID),
                  entry.maturity == .mature
            else { return (0, []) }

            var candy = RewardEngine.stickerBonus
            var events: [EngagementEvent] = [.stickerLit(entryStableID: event.entryStableID)]

            if let album = try collection.album(containing: entry.stableID, languageCode: entry.languageCode),
               !profile.completedAlbumIDs.contains(album.id),
               try collection.progress(of: album).isComplete {
                profile.completedAlbumIDs.append(album.id)
                candy += RewardEngine.albumBonus
                events.append(.albumCompleted(albumID: album.id, title: album.title))
            }
            return (candy, events)
        } catch {
            logger.error("Sticker check skipped: \(error.localizedDescription, privacy: .public)")
            return (0, [])
        }
    }

    /// Words, across every language, whose cards are all mature.
    ///
    /// One card fetch, grouped by the entry part of `cardID` (`"<stableID>#<direction>"`), the
    /// same way the sticker book counts — so this number and the shiny stickers agree.
    private func matureWordCount() throws -> Int {
        var allMature: [String: Bool] = [:]
        for card in try context.fetch(FetchDescriptor<Card>()) {
            guard let hash = card.cardID.lastIndex(of: "#") else { continue }
            let stableID = String(card.cardID[..<hash])
            allMature[stableID] = (allMature[stableID] ?? true) && card.maturity == .mature
        }
        return allMature.values.filter { $0 }.count
    }

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
