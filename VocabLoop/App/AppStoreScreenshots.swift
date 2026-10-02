import Foundation
import SwiftData
import OSLog

/// App Store screenshot mode: `-appStoreScreenshots`.
///
/// Launched with that argument (by `VocabLoopUITests/AppStoreScreenshotTests`, run from
/// `.github/workflows/screenshots.yml`), a debug build wipes itself to a fresh install, skips the
/// first run and seeds a believable library — a 12-day streak, 24 of 30 cards done today, Mochi at
/// level 9 in a straw hat and scarf, a finished sticker page and a few badges — so every screenshot
/// is a real frame of the real app.
///
/// Everything that acts lives under `#if DEBUG`; in a release build ``isActive`` is a constant
/// `false` and the argument does nothing. Without the argument nothing here runs at all, so the
/// unit and UI suites see the app exactly as before.
enum AppStoreScreenshots {
    static let launchArgument = "-appStoreScreenshots"

    /// `true` only in a debug build launched with ``launchArgument``.
    static let isActive: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(launchArgument)
        #else
        return false
        #endif
    }()

    #if DEBUG

    /// What the purchase button shows, since the simulator has no App Store product to load.
    /// The U.S. price of the Plus lifetime purchase (`docs/APP-STORE-LISTING.md` §4).
    static let displayPrice = "¥198"

    /// The words due today, in the order the session asks them (most overdue first).
    ///
    /// Three self-graded cards build a combo, the fourth is the study-screen screenshot, the
    /// fifth is the multiple-choice question, and the sixth reaches the daily goal (24 + 6 = 30).
    static let dueHeadwords = ["island", "imagine", "ocean", "delicious", "adventure", "journey"]

    /// The one due word asked as a multiple-choice question.
    static let quizHeadword = "adventure"

    static let languageCode = LearningLanguage.english.rawValue
    static let dailyGoal = 30
    static let reviewsAlreadyToday = 24
    static let streakDays = 12
    /// Level 9 (1,440–1,799 candy): the "kid" stage, with the straw hat, scarf and blueberry
    /// colour unlocked — and far enough from level 10 that the capture never levels up mid-run.
    static let candyTotal = 1_520
    static let enrolledWordTarget = 80

    private static let seededKey = "appStoreScreenshots.seeded"
    private static let logger = Logger(subsystem: "com.vocabloop.app", category: "screenshots")

    /// How each due card is asked: every one a flip card except ``quizHeadword``.
    private static let forcedKinds: [String: QuestionKind] = {
        var kinds: [String: QuestionKind] = [:]
        for headword in dueHeadwords {
            let stableID = Entry.makeStableID(language: languageCode, headword: headword)
            let cardID = Card.makeCardID(entryStableID: stableID, direction: .recognition)
            kinds[cardID] = headword == quizHeadword ? .multipleChoice : .flip
        }
        return kinds
    }()

    /// The scripted question kind for `cardID`, or `nil` to let ``QuestionGenerator`` decide.
    static func forcedQuestionKind(for cardID: String) -> QuestionKind? {
        guard isActive else { return nil }
        return forcedKinds[cardID]
    }

    // MARK: - Reset

    /// Put the app back to a fresh install with the first run already finished.
    ///
    /// Runs in `VocabLoopApp.init`, before the store is opened: the store files are deleted, the
    /// defaults domain is cleared (which also forgets the content-pack versions, so the packs
    /// re-import), and onboarding and the auth landing are marked done. The Live Activity toggle
    /// is switched off so nothing appears on the Lock Screen or asks for anything mid-capture.
    /// Notification permission is only ever requested from Settings, so nothing to do there.
    static func resetToFreshInstall() {
        let defaults = UserDefaults.standard
        if let domain = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: domain)
        }
        let fileManager = FileManager.default
        let store = PersistenceController.storeURL.path(percentEncoded: false)
        for suffix in ["", "-wal", "-shm"] where fileManager.fileExists(atPath: store + suffix) {
            try? fileManager.removeItem(atPath: store + suffix)
        }
        defaults.set(true, forKey: "onboarding.completed")
        defaults.set(true, forKey: "auth.landingShown")
        defaults.set(false, forKey: StudyActivityController.enabledKey)
        defaults.set(false, forKey: seededKey)
    }

    // MARK: - Seed

    /// Seed the demo library into the active (guest) account. Once per launch.
    @MainActor
    static func seedDemoLibrary(into dependencies: AppDependencies, now: Date = Date()) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: seededKey) else { return }
        do {
            try seed(dependencies, now: now)
            defaults.set(true, forKey: seededKey)
        } catch {
            logger.error("Screenshot seed failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    private static func seed(_ dependencies: AppDependencies, now: Date) throws {
        let context = dependencies.context
        let account = try context.activeAccount()
        guard let preferences = account.preferences else { return }

        // Preferences: English, quizzes on, recognition cards, a goal of 30.
        preferences.activeLanguageCode = languageCode
        preferences.dailyGoal = dailyGoal
        preferences.quizModesEnabled = true
        preferences.enabledDirections = [.recognition]
        preferences.touch(now)
        try context.save()

        let calendar = StudyCalendar(preferences: preferences)

        // MARK: Cards

        // The due words first, so nothing below can claim them.
        var dueEntries: [Entry] = []
        for headword in dueHeadwords {
            let stableID = Entry.makeStableID(language: languageCode, headword: headword)
            if let entry = try context.entry(stableID: stableID) {
                dueEntries.append(entry)
            } else {
                logger.error("Screenshot seed: no entry for \(headword, privacy: .public)")
            }
        }
        let dueIDs = Set(dueEntries.map(\.stableID))

        // Everything else comes from the first two A1 sticker pages of each word family, so the
        // sticker book has a finished page (the first one) and several nearly-finished ones.
        let albums = try dependencies.collection.albums(languageCode: languageCode)
        let familyOrder = WordFamily.allCases
        let pagesToFill = albums
            .filter { $0.level == .a1 && $0.page <= 2 }
            .sorted { lhs, rhs in
                if lhs.page != rhs.page { return lhs.page < rhs.page }
                let a = familyOrder.firstIndex(of: lhs.family) ?? 0
                let b = familyOrder.firstIndex(of: rhs.family) ?? 0
                return a < b
            }
        let completeAlbumID = pagesToFill.first?.id

        let otherTarget = max(0, enrolledWordTarget - dueEntries.count)
        var otherIDs: [(stableID: String, isCompletePage: Bool)] = []
        for album in pagesToFill {
            for stableID in album.entryStableIDs where !dueIDs.contains(stableID) {
                guard otherIDs.count < otherTarget else { break }
                otherIDs.append((stableID: stableID, isCompletePage: album.id == completeAlbumID))
            }
        }

        let day: TimeInterval = 86_400
        var matureWords = 0
        for (index, item) in otherIDs.enumerated() {
            guard let entry = try context.entry(stableID: item.stableID) else { continue }
            let cards = try dependencies.review.enroll(entry: entry, preferences: preferences, now: now)
            // Two in three outside the finished page shine; the rest are "known" (young).
            let isMature = item.isCompletePage || index % 3 != 2
            if isMature { matureWords += 1 }
            // Shining: a 25–64 day interval, last seen 1–15 days ago. Known: 5–14 days, last seen
            // 1–3 days ago. Either way the next review is days or weeks away, never today.
            let interval: Double = isMature ? Double(25 + (index * 7) % 40) : Double(5 + index % 10)
            let reviewedDaysAgo: Double = isMature ? Double(index % 15 + 1) : Double(index % 3 + 1)
            let reviewedAt = now.addingTimeInterval(-reviewedDaysAgo * day)
            for card in cards {
                card.schedulingState = SchedulingState(
                    phase: .review,
                    stability: interval,
                    difficulty: 4 + Double(index % 4) * 0.5,
                    intervalDays: interval,
                    due: reviewedAt.addingTimeInterval(interval * day),
                    lastReviewedAt: reviewedAt,
                    reps: isMature ? 6 + index % 4 : 3 + index % 2,
                    lapses: index % 9 == 0 ? 1 : 0,
                    stepIndex: 0
                )
                card.touch(now)
            }
        }

        // The six due cards: two-day reviews, a little overdue, each less so than the one
        // before, which is exactly the order `ReviewQueueBuilder` asks them in. Young, and a
        // "Good" keeps them well short of 21 days — no sticker lights up mid-capture.
        for (index, entry) in dueEntries.enumerated() {
            let cards = try dependencies.review.enroll(entry: entry, preferences: preferences, now: now)
            let elapsedDays = 3.6 - Double(index) * 0.25
            for card in cards {
                let reviewedAt = now.addingTimeInterval(-elapsedDays * day)
                card.schedulingState = SchedulingState(
                    phase: .review,
                    stability: 2,
                    difficulty: 5,
                    intervalDays: 2,
                    due: reviewedAt.addingTimeInterval(2 * day),
                    lastReviewedAt: reviewedAt,
                    reps: 3,
                    lapses: 0,
                    stepIndex: 0
                )
                card.touch(now)
            }
        }
        try context.save()

        // MARK: Study days — a 12-day streak, today 24 of 30

        // Midday of each study day, well clear of the rollover hour on either side.
        let todayNoon = calendar.dayStart(for: now).addingTimeInterval(8 * 3_600)
        let pastReviews = [32, 41, 30, 36, 28, 45, 33, 30, 38, 31, 35]
        var goalDays = 0
        var lifetimeReviews = 0
        for offset in 0..<streakDays {
            let date = offset == 0 ? now : todayNoon.addingTimeInterval(-Double(offset) * day)
            guard let studyDay = try dependencies.review.studyDay(
                for: date, preferences: preferences, createIfMissing: true
            ) else { continue }
            let reviews = offset == 0 ? reviewsAlreadyToday : pastReviews[(offset - 1) % pastReviews.count]
            studyDay.reviewsCompleted = reviews
            studyDay.correctCount = Int((Double(reviews) * 0.88).rounded())
            studyDay.newCardsIntroduced = offset == 0 ? 0 : 3 + offset % 4
            studyDay.studySeconds = reviews * 14
            studyDay.goalMet = offset > 0 && reviews >= dailyGoal
            if studyDay.goalMet { goalDays += 1 }
            lifetimeReviews += reviews
        }
        try context.save()

        // MARK: Mochi, stickers and badges

        let profile = try dependencies.engagement.profile()
        profile.candyTotal = candyTotal
        profile.candyThisWeek = 164
        profile.lifetimeReviews = lifetimeReviews + 310
        profile.quizCorrectTotal = 86
        profile.goalDaysTotal = goalDays
        profile.bestCombo = 23
        profile.bestComboThisWeek = 14
        profile.weekKey = EngagementService.weekKey(for: now, calendar: calendar)
        profile.lastStudiedAt = now.addingTimeInterval(-10 * 60)
        // Today's first-review bonus is already paid: today has 24 reviews.
        profile.lastFirstReviewDayKey = calendar.dayKey(for: now)

        let progress = try dependencies.collection.allProgress(languageCode: languageCode)
        profile.completedAlbumIDs = progress.filter(\.isComplete).map(\.album.id)

        // Every badge this history has earned, plus the two clock badges — granted up front so a
        // capture that happens to run at night does not pop a "Night owl" toast over a screenshot.
        let earned = AchievementCatalog.evaluate(
            AchievementContext(
                lifetimeReviews: profile.lifetimeReviews,
                currentStreak: streakDays,
                longestStreak: streakDays,
                bestCombo: profile.bestCombo,
                matureWords: matureWords,
                completedAlbums: profile.completedAlbumIDs.count,
                goalDaysTotal: profile.goalDaysTotal,
                quizCorrectTotal: profile.quizCorrectTotal,
                level: RewardEngine.level(forCandy: candyTotal),
                localHour: 12
            ),
            alreadyUnlocked: []
        )
        var unlocked: [UnlockedAchievement] = []
        for (index, id) in (earned + [AchievementID.night_owl, .early_bird]).enumerated() {
            if unlocked.contains(where: { $0.id == id.rawValue }) { continue }
            let daysAgo = Double(max(1, streakDays * 3 - index * 3))
            unlocked.append(UnlockedAchievement(id: id.rawValue, unlockedAt: now.addingTimeInterval(-daysAgo * day)))
        }
        // Accessories a badge unlocks (the nightcap, the sun visor) follow from the badges.
        profile.unlockedAchievements = unlocked
        profile.touch(now)
        try context.save()

        // Dressed through the wardrobe's own rules, which check the level just reached.
        try dependencies.engagement.setEquipped(.strawHat, slot: .head)
        try dependencies.engagement.setEquipped(.redScarf, slot: .neck)
        try dependencies.engagement.setBodyColor(.blueberry)

        dependencies.collection.invalidateCache()
        dependencies.engagement.invalidateAlbumCache()
        logger.info("Screenshot seed: \(otherIDs.count + dueEntries.count) words, \(matureWords) shining")
    }

    #endif
}
