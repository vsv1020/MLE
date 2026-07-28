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
    /// Chosen mid-morning UTC and away from a month boundary — a reference time near midnight
    /// makes day-boundary tests pass or fail depending on the machine's timezone.
    var referenceDate: Date { Date(timeIntervalSince1970: 1_700_000_000) }
}
