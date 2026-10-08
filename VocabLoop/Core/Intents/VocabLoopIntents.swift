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
    static var title: LocalizedStringResource = "查看待复习"
    static var description = IntentDescription(
        "有多少单词等你复习，以及今日目标完成了多少。",
        categoryName: "复习"
    )
    /// Answers in place rather than opening the app — the whole point of asking Siri.
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try IntentStore.context()
        guard let (account, preferences) = try IntentStore.session(in: context) else {
            return .result(dialog: "先打开一次麻薯背单词，就可以开始了。")
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
                return .result(dialog: "都复习完了，现在没有要复习的单词。")
            }
            let noun = "张新卡片"
            return .result(
                dialog: "复习都完成了。还有 \(newWords) \(noun)，想学的时候随时开始。"
            )
        }

        let word = "个单词"
        let progress = stats.reviewsToday > 0
            ? "今天已经复习了 \(stats.reviewsToday) 张。"
            : ""
        return .result(dialog: "有 \(stats.dueNow) \(word)待复习。\(progress)")
    }
}

// MARK: - Start studying

struct StartReviewIntent: AppIntent {
    static var title: LocalizedStringResource = "开始复习"
    static var description = IntentDescription(
        "打开麻薯背单词，开始复习待复习的单词。",
        categoryName: "复习"
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
    static var title: LocalizedStringResource = "今日单词"
    static var description = IntentDescription(
        "读出今天的一个新词和它的释义。",
        categoryName: "学习"
    )
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let context = try IntentStore.context()
        guard let (account, preferences) = try IntentStore.session(in: context) else {
            return .result(value: "", dialog: "先打开一次麻薯背单词，就可以开始了。")
        }

        let service = DailyWordService(context: context)
        let batch = try service.batch(for: account, preferences: preferences)
        let entries = try service.entries(in: batch)

        // Prefer one the user has not already accepted — telling them about a word they
        // added this morning is not news.
        let accepted = Set(batch.acceptedEntryStableIDs)
        guard let entry = entries.first(where: { !accepted.contains($0.stableID) }) ?? entries.first else {
            return .result(value: "", dialog: "今天没有可以学的新词了。")
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
    static var title: LocalizedStringResource = "添加单词"
    static var description = IntentDescription(
        "把一个单词存进你的麻薯背单词词库，并开始学习它。",
        categoryName: "学习"
    )
    static var openAppWhenRun = false

    @Parameter(title: "单词", requestValueDialog: "要添加哪个单词？")
    var word: String

    @Parameter(title: "释义", requestValueDialog: "它是什么意思？")
    var meaning: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try IntentStore.context()
        guard let (_, preferences) = try IntentStore.session(in: context) else {
            return .result(dialog: "先打开一次麻薯背单词，就可以开始了。")
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

        return .result(dialog: "已添加 \(entry.headword)，下次学习时就会出现。")
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
        /// Open Mochi's room — the Mochi widget's tap (`vocabloop://mochi`).
        case showMochi
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
                "在\(.applicationName)开始复习",
                "用\(.applicationName)背单词",
                "\(.applicationName)复习",
            ],
            shortTitle: "开始复习",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: ReviewStatusIntent(),
            phrases: [
                "\(.applicationName)有多少单词要复习",
                "\(.applicationName)里有什么要复习",
            ],
            shortTitle: "待复习",
            systemImageName: "tray.full"
        )
        AppShortcut(
            intent: DailyWordIntent(),
            phrases: [
                "\(.applicationName)今天的单词是什么",
                "\(.applicationName)今日单词",
            ],
            shortTitle: "今日单词",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: AddWordIntent(),
            phrases: ["在\(.applicationName)添加单词"],
            shortTitle: "添加单词",
            systemImageName: "plus.circle"
        )
    }
}
