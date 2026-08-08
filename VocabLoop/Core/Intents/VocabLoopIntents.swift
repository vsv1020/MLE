import AppIntents
import Foundation
import Observation
import SwiftData

/// Siri and Shortcuts entry points.
///
/// These live in the app target rather than an extension, which is what makes them useful
/// today: an `AppIntent` here already powers Siri, the Shortcuts app, and Spotlight, with
/// no new target and no provisioning changes. The same intents are what a Widget or Control
/// Centre button would call once a Widget Extension exists — see `docs/WIDGET.md` — so
/// writing them now is not speculative work.
///
/// Everything reads from the local store, so every intent works with the radio off. An
/// intent that needed a network would be the first thing in the app to violate that.

// MARK: - Shared access

/// Opens the store for an intent.
///
/// With no App Intents extension target, these intents run **inside the app's process** —
/// launched into the background when the app is not already open. So this must not create its
/// own `ModelContainer`: that would be a second container on the same store file in the same
/// process, and it would put the destructive quarantine path in `makeContainer()` behind a
/// background launch. ``PersistenceController/sharedContainer()`` opens once and caches.
///
/// A fresh `ModelContext` per invocation is correct and cheap — contexts are lightweight, and
/// a long-lived one would accumulate an unbounded object graph across intent calls.
@MainActor
enum IntentStore {
    static func context() throws -> ModelContext {
        ModelContext(try PersistenceController.sharedContainer())
    }

    /// The active account and its preferences, or `nil` if the app has never launched.
    static func session(in context: ModelContext) throws -> (UserAccount, StudyPreferences)? {
        let account = try context.activeAccount()
        guard let preferences = account.preferences else { return nil }
        return (account, preferences)
    }
}

// MARK: - How many are due

struct ReviewStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Check reviews due"
    static var description = IntentDescription(
        "How many words are waiting, and how far through today's goal you are.",
        categoryName: "Studying"
    )
    /// Answers in place rather than opening the app — the whole point of asking Siri.
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try IntentStore.context()
        guard let (account, preferences) = try IntentStore.session(in: context) else {
            return .result(dialog: "Open VocabLoop once to get started.")
        }

        let stats = try StatsService(context: context)
            .statistics(for: account, preferences: preferences)

        // Phrased so a zero reads as an achievement rather than an error.
        //
        // Each branch returns its own literal instead of picking one with a ternary:
        // `IntentDialog` is only reachable from a string *literal* through
        // `ExpressibleByStringInterpolation`, and a ternary types its branches as `String`
        // first, so the conversion never gets a chance to happen.
        if stats.dueNow == 0 {
            let newWords = stats.newAvailable
            guard newWords > 0 else {
                return .result(dialog: "You are all caught up. Nothing is due right now.")
            }
            let noun = newWords == 1 ? "card is" : "cards are"
            return .result(
                dialog: "You are caught up on reviews. \(newWords) new \(noun) ready when you want them."
            )
        }

        let word = stats.dueNow == 1 ? "word" : "words"
        let progress = stats.reviewsToday > 0
            ? " You have done \(stats.reviewsToday) today."
            : ""
        return .result(dialog: "\(stats.dueNow) \(word) due.\(progress)")
    }
}

// MARK: - Start studying

struct StartReviewIntent: AppIntent {
    static var title: LocalizedStringResource = "Start a review session"
    static var description = IntentDescription(
        "Opens VocabLoop and begins reviewing the words that are due.",
        categoryName: "Studying"
    )
    /// Reviewing is inherently interactive, so this one does open the app.
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // A launch flag rather than a stored preference: it describes one launch, and a
        // preference would persist and start a session on the *next* cold launch too.
        IntentLaunchRequest.shared.pendingAction = .startReview
        return .result()
    }
}

// MARK: - Today's word

struct DailyWordIntent: AppIntent {
    static var title: LocalizedStringResource = "Word of the day"
    static var description = IntentDescription(
        "Reads out one of today's new words with its meaning.",
        categoryName: "Learning"
    )
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let context = try IntentStore.context()
        guard let (account, preferences) = try IntentStore.session(in: context) else {
            return .result(value: "", dialog: "Open VocabLoop once to get started.")
        }

        let service = DailyWordService(context: context)
        let batch = try service.batch(for: account, preferences: preferences)
        let entries = try service.entries(in: batch)

        // Prefer one the user has not already accepted — telling them about a word they
        // added this morning is not news.
        let accepted = Set(batch.acceptedEntryStableIDs)
        guard let entry = entries.first(where: { !accepted.contains($0.stableID) }) ?? entries.first else {
            return .result(value: "", dialog: "No new words are available today.")
        }

        let definition = entry.primaryDefinition
        let spoken = definition.isEmpty
            ? entry.headword
            : "\(entry.headword). \(definition)."
        return .result(value: spoken, dialog: "\(spoken)")
    }
}

// MARK: - Add a word

struct AddWordIntent: AppIntent {
    static var title: LocalizedStringResource = "Add a word"
    static var description = IntentDescription(
        "Saves a word to your VocabLoop dictionary and starts studying it.",
        categoryName: "Learning"
    )
    static var openAppWhenRun = false

    @Parameter(title: "Word", requestValueDialog: "Which word?")
    var word: String

    @Parameter(title: "Meaning", requestValueDialog: "What does it mean?")
    var meaning: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try IntentStore.context()
        guard let (_, preferences) = try IntentStore.session(in: context) else {
            return .result(dialog: "Open VocabLoop once to get started.")
        }

        let search = SearchService(context: context)
        // `createUserEntry` is idempotent: an existing headword returns the existing entry
        // rather than a duplicate, so saying the same word twice is harmless.
        let entry = try search.createUserEntry(
            headword: word,
            definition: meaning,
            partOfSpeech: .other,
            language: preferences.activeLanguage
        )
        try ReviewService(context: context).enroll(entry: entry, preferences: preferences)

        return .result(dialog: "Added \(entry.headword). It will come up in your next session.")
    }
}

// MARK: - Launch coordination

/// Carries a one-shot instruction from an intent into the app's UI.
///
/// `openAppWhenRun` brings the app forward but says nothing about *why*, so the intent
/// leaves a note here and `RootView` consumes it exactly once. Deliberately not persisted:
/// "start a session" describes this launch, and a stored flag would fire again on the next
/// cold start, which reads as the app hijacking itself.
@MainActor
@Observable
public final class IntentLaunchRequest {
    public static let shared = IntentLaunchRequest()

    public enum Action: Equatable {
        case startReview
    }

    public var pendingAction: Action?

    private init() {}

    /// Read and clear.
    public func take() -> Action? {
        defer { pendingAction = nil }
        return pendingAction
    }
}

// MARK: - Shortcuts

/// Phrases Siri accepts without the user configuring anything.
///
/// `.applicationName` is required in every phrase — Siri needs the app name to disambiguate,
/// and a phrase without it is rejected at build time.
struct VocabLoopShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartReviewIntent(),
            phrases: [
                "Start reviewing in \(.applicationName)",
                "Study my words in \(.applicationName)",
                "Review \(.applicationName)",
            ],
            shortTitle: "Start reviewing",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: ReviewStatusIntent(),
            phrases: [
                "How many words are due in \(.applicationName)",
                "What is due in \(.applicationName)",
            ],
            shortTitle: "Reviews due",
            systemImageName: "tray.full"
        )
        AppShortcut(
            intent: DailyWordIntent(),
            phrases: [
                "What is my word of the day in \(.applicationName)",
                "Today's word in \(.applicationName)",
            ],
            shortTitle: "Word of the day",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: AddWordIntent(),
            phrases: ["Add a word to \(.applicationName)"],
            shortTitle: "Add a word",
            systemImageName: "plus.circle"
        )
    }
}
