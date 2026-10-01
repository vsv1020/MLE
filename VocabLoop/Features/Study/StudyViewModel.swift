import Foundation
import SwiftData
import Observation

/// Drives one review session.
///
/// Holds the queue, the current card, the reveal state and the timing. Everything that
/// touches storage goes through ``ReviewService``, so the session cannot advance a card
/// without logging it.
@MainActor
@Observable
final class StudyViewModel {
    enum Phase {
        case loading
        case reviewing
        /// The daily goal was just reached. The queue is untouched underneath, so "keep going"
        /// resumes exactly where the user was.
        case goalReached
        case finished
    }

    var phase: Phase = .loading
    var isAnswerRevealed = false
    var errorMessage: String?

    /// Cards remaining, current first.
    private(set) var queue: [Card] = []
    private(set) var currentIndex = 0

    /// Interval each rating would produce, for the button labels. Recomputed when the card
    /// changes, not when it is revealed, so the reveal animation has no work to do.
    private(set) var previews: [Rating: SchedulingOutcome] = [:]

    // MARK: Session totals

    private(set) var reviewedCount = 0
    private(set) var correctCount = 0
    private(set) var ratingCounts: [Rating: Int] = [:]
    private(set) var startedAt = Date()
    private(set) var deferredCount = 0
    /// Total cards at the start, so the progress bar has a stable denominator even as cards
    /// are re-inserted by intraday steps.
    private(set) var plannedCount = 0

    private var revealedAt: Date?
    private var lastGraded: Card?

    /// The grade just given, for the mascot to react to. `nil` before the first answer.
    private(set) var lastRating: Rating?

    // MARK: Questions

    /// How the current card is being asked. `nil` only when there is no current card.
    ///
    /// Rebuilt wherever the current card can change (``refreshQuestion(dependencies:now:)``), and
    /// deterministic from the card, so an undone card comes back as the very same question.
    private(set) var currentQuestion: Question?

    /// When the current question appeared. A quiz's response time — the one thing that separates
    /// `good` from `hard` for an auto-graded answer — is measured from here, not from a reveal,
    /// because a quiz has no reveal before the answer.
    private(set) var questionShownAt: Date?

    /// The option the learner tapped, for the red/green feedback. `nil` before an answer, and for
    /// a typed question or "I don't know".
    private(set) var selectedOption: Int?

    /// What was typed into a `typed` question, kept so the feedback can show it next to the word.
    private(set) var typedAnswer: String?

    /// `true` once an auto-graded question has been answered and is showing its feedback. The
    /// grade is not sent until ``continueAfterAnswer(dependencies:now:)``: a child needs time to
    /// read the right answer, so nothing auto-advances.
    private(set) var isQuestionAnswered = false

    /// The grade ``AutoGrader`` gave the answer, waiting for Continue.
    private(set) var pendingAutoRating: Rating?

    /// Response time captured at the moment of the answer, so time spent reading the feedback
    /// is not counted as recall time.
    private var pendingResponseMS: Int?

    /// Built once per `start`, from the user's quiz setting, this device's voices and the UI-test
    /// flag — the same terms for every card in the session.
    private var policy = QuestionPolicy()

    /// `true` when the current card is asked as a quiz rather than as a self-graded flip card.
    var isQuizQuestion: Bool { currentQuestion?.kind.isAutoGraded ?? false }

    // MARK: Engagement

    /// Consecutive answers this session that were not *Forgot*. In memory only — a combo is a
    /// moment, not a record; the best one is kept by ``EngagementService`` instead.
    private(set) var combo = 0
    /// The combo before the most recent grade, so undo can put it back exactly.
    private(set) var comboBeforeLast = 0
    private(set) var bestComboThisSession = 0
    /// The milestone the most recent grade reached, for Mochi's reaction. Cleared by the next
    /// grade, so Mochi cheers once per milestone rather than for the rest of the session.
    private(set) var lastComboMilestone: Int?

    /// Things to celebrate, oldest first. The screen drains them one at a time with
    /// ``takeNextEvent()``; nothing here waits on them being shown.
    private(set) var events: [EngagementEvent] = []

    private(set) var opening: SessionOpening?
    private(set) var streak: StreakService.Streak = .none
    /// Drives the flame: grey until the first review of the day lands, then lit.
    private(set) var studiedToday = false
    private(set) var candyTotal = 0
    private(set) var look: MochiLook = .default

    /// Held so ``revealAnswer(now:)`` can play its pop without growing a `dependencies`
    /// parameter that every existing caller would then have to pass.
    private var sounds: SoundService?

    /// UserDefaults key for the day "Mochi missed you" was last shown. Device-local on purpose:
    /// it is a UI nicety, not something an account needs to carry.
    static let welcomeBackShownDayKey = "mochi.welcomeBackShownDayKey"

    /// Days away before Mochi says it missed you (engagement plan §1.3).
    static let welcomeBackThresholdDays = 3

    /// The run length from which a broken combo is still celebrated (engagement plan §1.1).
    static let comboEndedCelebrationThreshold = 5

    /// Kept so the queue can be topped up on the same terms it was first built on.
    private var options = ReviewQueueBuilder.Options()

    /// How many times the queue has been topped up. Nothing on screen reads it — it exists so
    /// tests can assert that a finished batch actually refilled rather than merely failing to
    /// end, which are indistinguishable from the outside.
    private(set) var refillCount = 0

    /// `true` once the session has run out of due cards and started introducing new ones.
    private(set) var hasMovedPastDue = false

    var currentCard: Card? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    /// The user's daily goal, or `nil` when they have not set one.
    private(set) var goalTarget: Int?

    /// Reviews completed *today*, not this session — the number a daily goal is measured in.
    /// Seeded from the stored day on `start` so a second session does not restart the count.
    private(set) var reviewsToday = 0

    /// Progress toward the daily goal, or `nil` when there is no goal to progress toward.
    ///
    /// Optional rather than defaulting to zero, because with an endless queue there is no
    /// denominator to invent. The old `reviewedCount / plannedCount` measured progress through
    /// one *batch*, and now that batches refill silently that number would fill up and reset
    /// repeatedly — a progress bar that lies twice per session is worse than no bar at all.
    var goalProgress: Double? {
        guard let goalTarget, goalTarget > 0 else { return nil }
        return min(Double(reviewsToday) / Double(goalTarget), 1)
    }

    /// `true` once today's goal is met — the counter stops reading "34 / 30", which looks like
    /// a bug, and becomes a plain count with a tick.
    var isGoalMet: Bool {
        guard let goalTarget, goalTarget > 0 else { return false }
        return reviewsToday >= goalTarget
    }

    var accuracy: Double? {
        guard reviewedCount > 0 else { return nil }
        return Double(correctCount) / Double(reviewedCount)
    }

    var elapsedSeconds: Int { Int(Date().timeIntervalSince(startedAt)) }

    /// `true` when the previous card can be un-graded.
    var canUndo: Bool { lastGraded != nil }

    // MARK: - Loading

    func start(dependencies: AppDependencies, options: ReviewQueueBuilder.Options, now: Date = Date()) {
        guard let preferences = dependencies.preferences else {
            phase = .finished
            return
        }
        self.options = options
        lastRating = nil
        lastComboMilestone = nil
        // Whatever was waiting to be shown belonged to the previous queue. The combo itself is
        // kept: `start` also runs when the library sheet closes, and a trip to look something up
        // is not the end of a run.
        events.removeAll()
        sounds = dependencies.sounds
        policy = dependencies.questionPolicy(for: preferences)
        goalTarget = preferences.dailyGoalTarget
        // `try?` flattens the nested optional (SE-0230), so this is `StudyDay?`, not
        // `StudyDay??`. `createIfMissing: false` because merely opening the study screen is
        // not activity — writing a row here would make an abandoned session look like a
        // studied day.
        reviewsToday = (try? dependencies.review.studyDay(
            for: now, preferences: preferences, createIfMissing: false
        ))?.reviewsCompleted ?? 0
        do {
            var built = try ReviewQueueBuilder().build(
                in: dependencies.context, at: now, options: options
            )
            // A fresh install lands here: thousands of bundled words, none of them enrolled, so
            // the builder — which only ever draws from enrolled cards — has nothing. Start the
            // most common words rather than opening the app onto "Nothing to study".
            if built.items.isEmpty,
               try introduceNewWords(dependencies: dependencies, preferences: preferences, now: now) {
                built = try ReviewQueueBuilder().build(
                    in: dependencies.context, at: now, options: options
                )
            }
            deferredCount = built.deferredCount
            queue = try built.items.compactMap { try dependencies.context.card(cardID: $0.cardID) }
            plannedCount = queue.count
            currentIndex = 0
            startedAt = now
            refreshPreviews(preferences: preferences, now: now)
            // An empty queue here really is "nothing at all" — `build` already looked at the
            // due pile and the enrolled new cards, and there were no words left to introduce.
            phase = queue.isEmpty ? .finished : .reviewing
        } catch {
            errorMessage = error.localizedDescription
            phase = .finished
        }

        openEngagement(dependencies: dependencies, preferences: preferences, now: now)
        // One fetch for the whole session. A failure only means every card stays a flip card,
        // which is the app as it was — not worth an alert.
        try? dependencies.questions.prepare(
            languageCode: options.languageCode ?? preferences.activeLanguageCode,
            nativeCodes: preferences.nativeLanguageCodes
        )
        refreshQuestion(dependencies: dependencies, now: now)
    }

    /// Read the profile, streak and Mochi's look for the top bar, and say "Mochi missed you"
    /// once a day to someone returning after a few days away.
    ///
    /// Engagement never blocks studying: if the profile cannot be read, the session runs with
    /// a grey flame and no candy rather than with an error.
    private func openEngagement(
        dependencies: AppDependencies, preferences: StudyPreferences, now: Date
    ) {
        guard let opening = try? dependencies.engagement.sessionOpened(preferences: preferences, now: now) else {
            return
        }
        self.opening = opening
        streak = opening.streak
        studiedToday = opening.studiedToday
        candyTotal = opening.candyTotal
        look = opening.look

        guard let daysAway = opening.daysSinceLastStudy,
              daysAway >= Self.welcomeBackThresholdDays,
              !opening.studiedToday
        else { return }
        // Once per study day, not once per `start`: the root session restarts every time the
        // library closes, and a welcome repeated on each return stops being a welcome.
        let todayKey = StudyCalendar(preferences: preferences).dayKey(for: now)
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.welcomeBackShownDayKey) != todayKey else { return }
        defaults.set(todayKey, forKey: Self.welcomeBackShownDayKey)
        events.append(.welcomeBack(daysAway: daysAway))
    }

    /// Restart the current quiz question's response clock, after time spent away from it.
    ///
    /// Called when Mochi's sheet closes and when the app comes back to the foreground. A quiz's
    /// response time separates `good` from `hard`, and minutes spent in a sheet or in another app
    /// are not recall time — without this the next answer would always be graded "slow". Only a
    /// showing, unanswered quiz question is touched: an answered one already captured its time.
    func restartQuestionClock(now: Date = Date()) {
        guard isQuizQuestion, !isQuestionAnswered else { return }
        questionShownAt = now
    }

    /// "Keep going" from the goal screen.
    func continueAfterGoal(now: Date = Date()) {
        guard phase == .goalReached else { return }
        phase = queue.isEmpty ? .finished : .reviewing
        // The next question was built while the goal screen was up. Time spent celebrating is
        // not time spent recalling, so its clock starts now — otherwise every quiz right after
        // the goal would be graded "slow".
        if currentQuestion != nil, !isQuestionAnswered { questionShownAt = now }
    }

    // MARK: - Reveal and grade

    func revealAnswer(now: Date = Date()) {
        guard !isAnswerRevealed else { return }
        // A quiz reveals its answer by being answered. Revealing it first would hand over the
        // answer and then grade the learner on it.
        guard !isQuizQuestion || isQuestionAnswered else { return }
        isAnswerRevealed = true
        revealedAt = now
        Haptics.reveal()
        sounds?.play(.reveal)
    }

    // MARK: - Quiz answers

    /// The learner tapped option `optionIndex` of a choice question.
    ///
    /// Grades it with ``AutoGrader`` but does not send the grade yet — see
    /// ``continueAfterAnswer(dependencies:now:)``.
    func answer(optionIndex: Int, now: Date = Date()) {
        guard let question = currentQuestion,
              question.kind.isAutoGraded, question.kind != .typed,
              !isQuestionAnswered,
              question.options.indices.contains(optionIndex)
        else { return }
        selectedOption = optionIndex
        finishQuestion(
            question, quality: optionIndex == question.correctIndex ? .exact : .wrong, now: now
        )
    }

    /// The learner submitted `text` for a typed question.
    func submitTyped(_ text: String, now: Date = Date()) {
        guard let question = currentQuestion, question.kind == .typed, !isQuestionAnswered else { return }
        typedAnswer = text
        finishQuestion(
            question, quality: TypedAnswerMatcher.match(typed: text, answer: question.answerText), now: now
        )
    }

    /// "I don't know": an honest lapse, graded exactly like a wrong answer. Offered because a
    /// child who cannot recall a word should not have to guess at a keyboard to move on.
    func giveUpOnQuestion(now: Date = Date()) {
        guard let question = currentQuestion, question.kind.isAutoGraded, !isQuestionAnswered else { return }
        finishQuestion(question, quality: .wrong, now: now)
    }

    private func finishQuestion(_ question: Question, quality: MatchQuality, now: Date) {
        let responseMS = questionShownAt.map { max(0, Int(now.timeIntervalSince($0) * 1000)) } ?? 0
        pendingResponseMS = responseMS
        pendingAutoRating = AutoGrader.rating(kind: question.kind, quality: quality, responseMS: responseMS)
        isQuestionAnswered = true
        isAnswerRevealed = true
        revealedAt = now
        Haptics.reveal()
        // A near miss is a typo, not a wrong word, so it sounds like success. A wrong answer is
        // silent — never a buzzer, never an error haptic (engagement plan §1.6).
        if quality != .wrong { sounds?.play(.correct) }
    }

    /// Continue from an answered quiz: send the auto-grade and move on.
    func continueAfterAnswer(dependencies: AppDependencies, now: Date = Date()) {
        guard isQuestionAnswered, let rating = pendingAutoRating else { return }
        grade(rating, dependencies: dependencies, now: now)
    }

    func grade(_ rating: Rating, dependencies: AppDependencies, now: Date = Date()) {
        guard let card = currentCard, let preferences = dependencies.preferences else { return }

        let question = currentQuestion?.cardID == card.cardID ? currentQuestion : nil
        let questionKind = question?.kind ?? .flip
        let wasAutoGraded = questionKind.isAutoGraded && isQuestionAnswered
        // Self-graded: measured from reveal, not from card display — time spent reading the
        // answer is not recall time, and only the recall attempt is a useful signal. Auto-graded:
        // from the question appearing to the tap, captured at the tap.
        let durationMS: Int
        if wasAutoGraded, let pendingResponseMS {
            durationMS = pendingResponseMS
        } else {
            durationMS = revealedAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? 0
        }
        // Captured before the service call, which moves the card on.
        let phaseBefore = card.phase
        let maturityBefore = card.maturity
        // Today's latched `goalMet`, read before the grade can latch it. The in-memory counts
        // alone cannot tell a first crossing from a second one: undo drops `reviewsToday` back
        // below the goal, the regrade crosses it again, and the goal bonus would be paid twice.
        // The stored latch survives the undo, so it can. `createIfMissing: false` for the same
        // reason as in `start` — reading is not activity.
        let wasGoalLatched = (try? dependencies.review.studyDay(
            for: now, preferences: preferences, createIfMissing: false
        ))?.goalMet ?? false

        do {
            let result = try dependencies.review.grade(
                card: card, rating: rating, preferences: preferences,
                durationMS: durationMS, now: now
            )
            reviewedCount += 1
            let wasBelowGoal = !isGoalMet
            reviewsToday += 1
            // Exactly on the crossing, so it celebrates once a day: a session opened after the
            // goal is already met, or the fortieth card of an evening, does not interrupt — nor
            // does crossing it again after an undo, since the day had already latched it.
            let justReachedGoal = wasBelowGoal && isGoalMet && !wasGoalLatched
            if rating.isSuccess { correctCount += 1 }
            ratingCounts[rating, default: 0] += 1
            lastGraded = card
            lastRating = rating
            Haptics.tap()

            recordEngagement(
                card: card, rating: rating, questionKind: questionKind, wasAutoGraded: wasAutoGraded,
                responseMS: durationMS, phaseBefore: phaseBefore, maturityBefore: maturityBefore,
                justReachedGoal: justReachedGoal, dependencies: dependencies,
                preferences: preferences, now: now
            )

            advance(
                after: card, returnsThisSession: result.returnsThisSession,
                dependencies: dependencies, preferences: preferences, now: now
            )
            // If the library also ran out on this card, the summary already says "done".
            if justReachedGoal, phase == .reviewing {
                phase = .goalReached
                Haptics.success()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Update the combo, hand the review to ``EngagementService`` and play what it earned.
    ///
    /// Runs after ``ReviewService`` has stored the grade and never feeds back into it: nothing
    /// here can change a rating or an interval. A failure in the engagement layer is swallowed —
    /// a missed candy is not worth interrupting a review over.
    private func recordEngagement(
        card: Card, rating: Rating, questionKind: QuestionKind, wasAutoGraded: Bool,
        responseMS: Int, phaseBefore: LearningPhase, maturityBefore: CardMaturity,
        justReachedGoal: Bool, dependencies: AppDependencies,
        preferences: StudyPreferences, now: Date
    ) {
        comboBeforeLast = combo
        combo = rating == .again ? 0 : combo + 1
        bestComboThisSession = max(bestComboThisSession, combo)
        let isMilestone = rating != .again && RewardEngine.isComboMilestone(combo)
        lastComboMilestone = isMilestone ? combo : nil

        var newEvents: [EngagementEvent] = []
        // The run is celebrated; the break is never mentioned.
        if rating == .again && comboBeforeLast >= Self.comboEndedCelebrationThreshold {
            newEvents.append(.comboEnded(best: comboBeforeLast))
        }

        let wasFirstReviewToday = !studiedToday
        let outcome = ReviewOutcomeEvent(
            cardID: card.cardID,
            entryStableID: card.entry?.stableID ?? "",
            rating: rating,
            questionKind: questionKind,
            wasAutoGraded: wasAutoGraded,
            responseMS: responseMS,
            phaseBefore: phaseBefore,
            maturityBefore: maturityBefore,
            maturityAfter: card.maturity,
            comboAfter: combo,
            justReachedGoal: justReachedGoal,
            reviewsToday: reviewsToday
        )
        let recorded = (try? dependencies.engagement.record(outcome, preferences: preferences, now: now)) ?? []
        newEvents.append(contentsOf: recorded)
        // The service owns the milestone bonus and normally reports it; added here only when it
        // did not, so the run is still celebrated even if the profile could not be written.
        if isMilestone && !recorded.contains(.comboMilestone(combo)) {
            newEvents.append(.comboMilestone(combo))
        }

        for event in newEvents {
            switch event {
            case .candy(let amount):
                candyTotal += amount
            case .levelUp:
                look = dependencies.engagement.currentLook()
            case .firstReviewToday(let days):
                streak.current = max(streak.current, days)
            case .comboMilestone, .comboEnded, .stickerLit, .albumCompleted, .achievement, .welcomeBack:
                break
            }
        }

        if wasFirstReviewToday {
            // The flame lights on the first review of the day. The streak is re-read rather than
            // incremented: today may already have been counted by a session on another screen.
            studiedToday = true
            if let current = try? dependencies.engagement.streak(preferences: preferences, now: now) {
                streak = current
            }
        }

        if isMilestone { Haptics.success() }
        playSound(
            for: newEvents, rating: rating, wasAutoGraded: wasAutoGraded, justReachedGoal: justReachedGoal
        )
        events.append(contentsOf: newEvents)
    }

    /// One sound per answer: the most important one.
    ///
    /// System sounds overlap rather than queue, so a level-up landing on a combo milestone on
    /// the goal-reaching card would otherwise play three chimes at once — noise, not a reward.
    /// Nothing at all for *Forgot*, *Slow* or a wrong quiz answer (engagement plan §1.6); a
    /// correct quiz answer already chimed when it was tapped.
    private func playSound(
        for events: [EngagementEvent], rating: Rating, wasAutoGraded: Bool, justReachedGoal: Bool
    ) {
        guard let sounds else { return }
        var isLevelUp = false
        var isBadge = false
        var isSticker = false
        var isBonusCandy = false
        for event in events {
            switch event {
            case .levelUp: isLevelUp = true
            case .achievement, .albumCompleted: isBadge = true
            case .stickerLit: isSticker = true
            case .candy(let amount): isBonusCandy = isBonusCandy || amount > RewardEngine.candyPerReview
            case .firstReviewToday, .comboMilestone, .comboEnded, .welcomeBack: break
            }
        }
        // `.none` except exactly on a milestone, so this is silent between them.
        let tier = rating == .again ? ComboTier.none : RewardEngine.comboTier(combo)

        if isLevelUp {
            sounds.play(.levelUp)
        } else if isBadge {
            sounds.play(.badge)
        } else if justReachedGoal {
            sounds.play(.goal)
        } else if isSticker {
            sounds.play(.sticker)
        } else if tier != .none {
            sounds.play(comboTier: tier)
        } else if isBonusCandy {
            sounds.play(.candy)
        } else if !wasAutoGraded && (rating == .good || rating == .easy) {
            sounds.play(.correct)
        }
    }

    /// The oldest event waiting to be shown, removed from the queue.
    func takeNextEvent() -> EngagementEvent? {
        events.isEmpty ? nil : events.removeFirst()
    }

    /// Re-read Mochi and the candy total, after the wardrobe may have changed them.
    func refreshEngagement(dependencies: AppDependencies) {
        look = dependencies.engagement.currentLook()
        if let profile = try? dependencies.engagement.profile() {
            candyTotal = profile.candyTotal
        }
    }

    /// Move to the next card, re-queuing the one just graded when its next step is minutes away.
    private func advance(
        after card: Card, returnsThisSession: Bool,
        dependencies: AppDependencies, preferences: StudyPreferences, now: Date
    ) {
        queue.remove(at: currentIndex)

        if returnsThisSession {
            // Re-insert a few positions back rather than at the end. Immediately is useless
            // (it tests short-term memory) and at the very end can be twenty minutes later,
            // by which point the learning step has expired anyway.
            let target = min(currentIndex + 3, queue.count)
            queue.insert(card, at: target)
            // The session genuinely got longer. Without this the counter reads "25/20" once
            // enough cards have come back, which looks like a bug rather than like the
            // consequence of pressing Again.
            plannedCount += 1
        }

        if currentIndex >= queue.count { currentIndex = 0 }
        isAnswerRevealed = false
        revealedAt = nil

        if queue.isEmpty {
            // The session does not end because a batch ran out. It ends when the *library* runs
            // out, which for almost everyone never happens.
            //
            // This is what "study as much as you like" actually requires. The obvious
            // implementation — lift the caps and let the queue pull unlimited cards — quietly
            // breaks FSRS, because its intervals are derived from reviews that happen near the
            // due date. Reviewing a card twelve days early and reporting "I remembered it" tells
            // the model you retained it for twelve days when you retained it for five minutes,
            // and stability gets over-estimated until the schedule collapses.
            //
            // Refilling keeps the caps and re-runs the same query. Due cards come first; when
            // they are gone the builder returns *new* cards, which have no due date and so
            // cannot distort anything. Unlimited study is therefore unlimited *introduction*,
            // which is both what was asked for and the only version of it that is safe.
            if refill(dependencies: dependencies, preferences: preferences, now: now) {
                refreshPreviews(preferences: preferences, now: now)
            } else {
                phase = .finished
                Haptics.success()
            }
        } else {
            refreshPreviews(preferences: preferences, now: now)
        }
        refreshQuestion(dependencies: dependencies, now: now)
    }

    /// Top the queue up in place. `false` only when the store has nothing left to offer.
    private func refill(
        dependencies: AppDependencies, preferences: StudyPreferences, now: Date
    ) -> Bool {
        do {
            let built = try ReviewQueueBuilder().build(
                in: dependencies.context, at: now, options: options
            )
            let alreadyQueued = Set(queue.map(\.cardID))
            var fresh = try built.items
                .filter { !alreadyQueued.contains($0.cardID) }
                .compactMap { try dependencies.context.card(cardID: $0.cardID) }
            // Enrolled cards exhausted: this is where "study as much as you like" continues
            // into words the user has never added. Without it the endless queue ended the
            // moment the user's own list ran out.
            if fresh.isEmpty,
               try introduceNewWords(dependencies: dependencies, preferences: preferences, now: now) {
                fresh = try ReviewQueueBuilder().build(in: dependencies.context, at: now, options: options)
                    .items
                    .filter { !alreadyQueued.contains($0.cardID) }
                    .compactMap { try dependencies.context.card(cardID: $0.cardID) }
            }
            guard !fresh.isEmpty else { return false }

            // Every card in the batch being unseen is what "the due pile is finished" looks
            // like from here. Latched, because a later batch mixing in a lapsed card should not
            // make the readout claim the backlog came back.
            if fresh.allSatisfy({ $0.phase == .new }) { hasMovedPastDue = true }

            queue.append(contentsOf: fresh)
            deferredCount = built.deferredCount
            refillCount += 1
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// How many words to start when the queue runs dry. Small, because each word becomes one
    /// card per enabled direction, and a batch of new words is followed by their learning steps.
    static let introductionBatchSize = 5

    /// Enrol the next most useful unstarted words. `true` when at least one card was created.
    ///
    /// Skipped for a deck-scoped session — introducing words from outside the deck would put
    /// them in front of someone who asked to study only that deck — and for study-ahead, whose
    /// whole point is cards the user already has.
    private func introduceNewWords(
        dependencies: AppDependencies, preferences: StudyPreferences, now: Date
    ) throws -> Bool {
        guard options.deckSlug == nil, !options.includeAhead, options.maxNewCards > 0 else { return false }
        let account = try dependencies.context.activeAccount()
        let entries = try dependencies.dailyWords.nextEntriesToIntroduce(
            for: account, preferences: preferences, limit: Self.introductionBatchSize
        )
        var created = 0
        for entry in entries {
            created += try dependencies.review.enroll(entry: entry, preferences: preferences, now: now).count
        }
        return created > 0
    }

    /// Un-grade the previous card and put it back in front.
    func undo(dependencies: AppDependencies) {
        guard let card = lastGraded, let preferences = dependencies.preferences else { return }
        do {
            try dependencies.review.undoLastReview(card: card, preferences: preferences)
            reviewedCount = max(0, reviewedCount - 1)
            reviewsToday = max(0, reviewsToday - 1)
            // Which rating to un-count is not recoverable from the card, so the totals are
            // rebuilt from what is left rather than guessed at.
            recomputeTotalsAfterUndo()
            queue.removeAll { $0.cardID == card.cardID }
            queue.insert(card, at: currentIndex)
            lastGraded = nil
            lastRating = nil
            isAnswerRevealed = false
            revealedAt = nil
            phase = .reviewing
            refreshPreviews(preferences: preferences)
            // Same card, same repetition count, so the same question comes back.
            refreshQuestion(dependencies: dependencies)
            // The combo goes back to what it was before the undone grade — including back *up*
            // when the undone grade was the Forgot that broke a run.
            combo = comboBeforeLast
            lastComboMilestone = nil
            // Anything not yet shown was about the undone answer.
            events.removeAll()
            refreshEngagement(dependencies: dependencies)
            if reviewsToday == 0 {
                studiedToday = false
                if let current = try? dependencies.engagement.streak(preferences: preferences, now: Date()) {
                    streak = current
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func recomputeTotalsAfterUndo() {
        let total = ratingCounts.values.reduce(0, +)
        guard total > reviewedCount else { return }
        // Remove one from the largest bucket — an approximation, and the honest one: the
        // alternative is storing a per-review undo stack for a control the user taps once.
        if let heaviest = ratingCounts.max(by: { $0.value < $1.value })?.key {
            ratingCounts[heaviest] = max(0, (ratingCounts[heaviest] ?? 1) - 1)
            if heaviest.isSuccess { correctCount = max(0, correctCount - 1) }
        }
    }

    // MARK: - Card controls

    func bury(dependencies: AppDependencies) {
        guard let card = currentCard, let preferences = dependencies.preferences else { return }
        try? dependencies.review.bury(card: card, preferences: preferences)
        skipCurrent(dependencies: dependencies, preferences: preferences)
    }

    func suspend(dependencies: AppDependencies) {
        guard let card = currentCard, let preferences = dependencies.preferences else { return }
        try? dependencies.review.setSuspended(true, card: card)
        skipCurrent(dependencies: dependencies, preferences: preferences)
    }

    func toggleFlag(dependencies: AppDependencies) {
        guard let card = currentCard else { return }
        try? dependencies.review.setFlagged(!card.isFlagged, card: card)
    }

    private func skipCurrent(
        dependencies: AppDependencies, preferences: StudyPreferences, now: Date = Date()
    ) {
        guard queue.indices.contains(currentIndex) else { return }
        queue.remove(at: currentIndex)
        if currentIndex >= queue.count { currentIndex = 0 }
        isAnswerRevealed = false
        revealedAt = nil
        if queue.isEmpty {
            // Burying or suspending the last card in a batch is not the end of the session
            // either — and previously it *was*, which meant putting one word aside could close
            // the screen on you.
            if refill(dependencies: dependencies, preferences: preferences, now: now) {
                refreshPreviews(preferences: preferences, now: now)
            } else {
                phase = .finished
            }
        } else {
            refreshPreviews(preferences: preferences)
        }
        refreshQuestion(dependencies: dependencies, now: now)
    }

    // MARK: - Questions

    /// Build the question for whatever card is now current, and clear the previous answer.
    ///
    /// Called everywhere ``refreshPreviews(preferences:now:)`` is, for the same reason: both
    /// describe the current card, and a stale question would grade this card against the last
    /// card's options.
    private func refreshQuestion(dependencies: AppDependencies, now: Date = Date()) {
        selectedOption = nil
        typedAnswer = nil
        isQuestionAnswered = false
        pendingAutoRating = nil
        pendingResponseMS = nil
        guard let card = currentCard else {
            currentQuestion = nil
            questionShownAt = nil
            return
        }
        currentQuestion = dependencies.questions.make(for: card, policy: policy)
        questionShownAt = now
    }

    // MARK: - Previews

    private func refreshPreviews(preferences: StudyPreferences, now: Date = Date()) {
        guard let card = currentCard else {
            previews = [:]
            return
        }
        previews = preferences.makeScheduler().preview(
            state: card.schedulingState, at: now, fuzzSeed: card.fuzzSeed
        )
    }

    func intervalLabel(for rating: Rating) -> String {
        guard let outcome = previews[rating] else { return "" }
        return IntervalFormatter.short(days: outcome.intervalDays)
    }
}
