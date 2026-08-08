import Foundation
import SwiftData
import XCTest
@testable import VocabLoop

/// Shared fixtures for the SwiftData-backed suites.
///
/// Every test gets a fresh in-memory container. Sharing one would let a stray write in one test
/// change the outcome of another, which is the failure mode that makes a persistence suite
/// untrustworthy and eventually ignored.
@MainActor
enum TestStore {
    static func makeContext() throws -> ModelContext {
        ModelContext(try PersistenceController.makeInMemoryContainer())
    }

    /// An account with default preferences, marked active.
    @discardableResult
    static func makeAccount(
        in context: ModelContext,
        provider: AuthProvider = .guest
    ) throws -> UserAccount {
        let account = UserAccount(displayName: "Tester", provider: provider)
        context.insert(account)
        try context.save()
        return account
    }

    /// A dictionary entry with one sense.
    @discardableResult
    static func makeEntry(
        in context: ModelContext,
        headword: String,
        language: LearningLanguage = .english,
        cefr: CEFRLevel? = .a1,
        frequencyRank: Int? = 100,
        definition: String = "a test definition"
    ) throws -> Entry {
        let entry = Entry(
            stableID: Entry.makeStableID(language: language.rawValue, headword: headword),
            languageCode: language.rawValue,
            headword: headword,
            partsOfSpeech: [.noun],
            cefr: cefr,
            frequencyRank: frequencyRank
        )
        context.insert(entry)
        let sense = Sense(order: 0, partOfSpeech: .noun, definition: definition)
        context.insert(sense)
        sense.entry = entry
        entry.senses.append(sense)
        try context.save()
        return entry
    }

    /// An enrolled card, positioned wherever the test needs it.
    @discardableResult
    static func makeCard(
        in context: ModelContext,
        for entry: Entry,
        direction: CardDirection = .recognition,
        phase: LearningPhase = .review,
        due: Date,
        intervalDays: Double = 10,
        stability: Double = 10
    ) throws -> Card {
        let state = SchedulingState(
            phase: phase,
            stability: stability,
            difficulty: 5,
            intervalDays: intervalDays,
            due: due,
            lastReviewedAt: due.addingTimeInterval(-intervalDays * 86_400),
            reps: 3
        )
        let card = Card(
            cardID: Card.makeCardID(entryStableID: entry.stableID, direction: direction),
            direction: direction,
            languageCode: entry.languageCode,
            state: state,
            scheduler: .fsrs5
        )
        context.insert(card)
        card.entry = entry
        try context.save()
        return card
    }

    /// A day rollup, for streak and heatmap tests.
    @discardableResult
    static func makeStudyDay(
        in context: ModelContext,
        userID: String,
        calendar: StudyCalendar,
        daysAgo: Int,
        reviews: Int,
        from reference: Date
    ) throws -> StudyDay {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: reference) ?? reference
        let day = StudyDay(
            userID: userID,
            dayKey: calendar.dayKey(for: date),
            dayStart: calendar.dayStart(for: date)
        )
        day.reviewsCompleted = reviews
        day.correctCount = reviews
        context.insert(day)
        try context.save()
        return day
    }
}

extension XCTestCase {
    /// A fixed instant, so nothing in the suite depends on when it runs.
    ///
    /// 2023-11-15 10:00:00 UTC. Genuinely mid-morning and away from a month boundary, so a test
    /// that adds a few hours to it and expects the same study day gets one.
    ///
    /// The previous value, `1_700_000_000`, carried this same comment but was 22:13 UTC — late
    /// evening. `DailyWordTests.testBatchIsPersistedAndReusedWithinTheSameDay` adds eight hours to
    /// represent "the same evening" and landed on the next study day, so it created a second batch
    /// and failed. The comment was aspirational; the number is now what it claimed.
    var referenceDate: Date { Date(timeIntervalSince1970: 1_700_042_400) }

    /// A study calendar's worth of certainty: pin preferences to UTC.
    ///
    /// Day boundaries are computed in `preferences.timeZone`, which defaults to `TimeZone.current`
    /// — so any test reasoning about "the same day" is otherwise asserting something about the
    /// machine it runs on. CI runners are UTC and a developer's laptop is not.
    func pinToUTC(_ preferences: StudyPreferences) {
        preferences.timeZoneIdentifier = "UTC"
        preferences.dayStartHour = 4
    }
}
