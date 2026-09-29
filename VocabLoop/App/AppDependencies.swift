import SwiftUI
import SwiftData
import Observation
import OSLog

/// The composition root.
///
/// Built once in ``VocabLoopApp`` and injected through the SwiftUI environment. Nothing in
/// the app reaches for a singleton, which is what makes it possible to stand the whole
/// object graph up against an in-memory store in tests and previews.
@MainActor
@Observable
public final class AppDependencies {
    public let container: ModelContainer
    public let context: ModelContext

    public let auth: AuthService
    public let review: ReviewService
    public let dailyWords: DailyWordService
    public let stats: StatsService
    public let search: SearchService
    public let speech: SpeechService
    public let notifications: NotificationService
    public let network: NetworkMonitor
    public let sync: SyncEngine
    public let importer: SeedImporter
    public let entitlements: Entitlements
    public let purchases: PurchaseService

    /// `nil` in this build. Set a `baseURL` and both ``RemoteAuthBackend`` and
    /// ``SyncEngine`` come alive without any other change.
    public let apiConfiguration: APIConfiguration

    /// True once the first-launch seed import has finished. Home shows a loading state
    /// while it is false, rather than an empty dictionary that looks like a bug.
    public private(set) var isContentReady = false
    public private(set) var contentImportError: String?

    private let logger = Logger(subsystem: "com.vocabloop.app", category: "app")

    public init(
        container: ModelContainer,
        apiConfiguration: APIConfiguration = .offline
    ) {
        self.container = container
        // `mainContext` deliberately: every service here is `@MainActor`, and views bind
        // to the same context so an edit shows up without a manual refresh. Bulk work
        // (seed import) uses its own context on `SeedImporter`'s actor.
        let context = container.mainContext
        self.context = context
        self.apiConfiguration = apiConfiguration

        let client = APIClient(configuration: apiConfiguration)
        let monitor = NetworkMonitor()
        let isServerConfigured = apiConfiguration.baseURL != nil

        self.network = monitor
        self.speech = SpeechService()
        self.notifications = NotificationService()
        self.review = ReviewService(context: context)
        let entitlements = Entitlements.shared
        self.entitlements = entitlements
        self.purchases = PurchaseService(entitlements: entitlements)
        self.dailyWords = DailyWordService(context: context, entitlements: entitlements)
        self.stats = StatsService(context: context)
        self.search = SearchService(context: context)
        self.importer = SeedImporter(modelContainer: container)
        self.sync = SyncEngine(
            context: context, client: client, monitor: monitor,
            isServerConfigured: isServerConfigured
        )
        self.auth = AuthService(
            context: context,
            remoteBackend: RemoteAuthBackend(
                client: client, context: context, isServerConfigured: isServerConfigured
            )
        )
    }

    /// Everything that must happen before the first meaningful frame.
    ///
    /// Ordered deliberately: the session is restored first so that preferences (and
    /// therefore the languages to import) are known; content import comes next; the
    /// network monitor starts last because nothing waits on it.
    public func bootstrap() async {
        await auth.restore()
        network.start()

        let languages = languagesToInstall()
        do {
            let reports = try await importer.importPacks(for: languages)
            let touched = reports.reduce(0) { $0 + $1.entriesTouched }
            if touched > 0 {
                logger.info("Content import touched \(touched) entries")
            }
        } catch {
            // A failed import must not prevent launch. The user keeps whatever content is
            // already imported, and Settings ▸ Data offers a retry.
            contentImportError = error.localizedDescription
            logger.error("Content import failed: \(error.localizedDescription, privacy: .public)")
        }
        isContentReady = true

        Haptics.isEnabled = preferences?.hapticsEnabled ?? true
        // Not awaited before content: a slow App Store must not hold up the first card. The
        // cached flag in `Entitlements` covers the gap.
        Task { await purchases.load() }
        sync.refreshStatus()
        await sync.sync()
    }

    /// The active account, guaranteed to exist.
    public var account: UserAccount? {
        try? context.activeAccount()
    }

    public var preferences: StudyPreferences? {
        account?.preferences
    }

    /// Which language packs to import at launch.
    ///
    /// The active language plus anything previously installed, so switching to French does
    /// not silently drop the English dictionary. Import is version-gated and cheap when
    /// there is nothing to do.
    private func languagesToInstall() -> [LearningLanguage] {
        guard let preferences else { return [.default] }
        var languages = preferences.installedLanguages
        if !languages.contains(preferences.activeLanguage) {
            languages.append(preferences.activeLanguage)
        }
        return languages.isEmpty ? [.default] : languages
    }

    /// Re-run seed import, ignoring version gating. Exposed in Settings ▸ Data for when
    /// content looks wrong.
    public func reimportContent() async {
        isContentReady = false
        contentImportError = nil
        do {
            try await importer.importPacks(for: languagesToInstall(), force: true)
        } catch {
            contentImportError = error.localizedDescription
        }
        isContentReady = true
    }

    /// Install a language's packs on demand, when the user adds it in Settings.
    public func installLanguage(_ language: LearningLanguage) async {
        do {
            try await importer.importPacks(for: [language])
            if let preferences, !preferences.installedLanguageCodes.contains(language.rawValue) {
                preferences.installedLanguageCodes.append(language.rawValue)
                preferences.touch()
                try? context.save()
            }
        } catch {
            contentImportError = error.localizedDescription
        }
    }

    /// Persist a preferences change and queue it for sync.
    ///
    /// Every settings screen routes through here, so no path can save preferences without
    /// the outbox learning about it.
    public func savePreferences() {
        guard let preferences else { return }
        preferences.touch()
        try? context.save()
        Haptics.isEnabled = preferences.hapticsEnabled
        sync.enqueuePreferences(preferences)
    }

    /// In-memory graph for previews and tests.
    public static func preview() -> AppDependencies {
        // Force-try is acceptable here and nowhere else: an in-memory container cannot
        // fail for any reason a running app could recover from, and a preview that
        // silently renders nothing is harder to debug than a crash.
        let container = try! PersistenceController.makeInMemoryContainer()
        return AppDependencies(container: container)
    }
}

// MARK: - Environment

/// Holds the fallback graph, created lazily so a real app launch never builds it.
@MainActor
private enum PreviewDependencies {
    static let shared = AppDependencies.preview()
}

private struct AppDependenciesKey: EnvironmentKey {
    /// Previews and any view rendered outside the app's root get a working in-memory graph
    /// rather than a crash or an optional to unwrap at every call site.
    ///
    /// `assumeIsolated` rather than `@MainActor` on the property: `EnvironmentKey` declares
    /// `defaultValue` as non-isolated, and environment lookup only ever happens during view
    /// body evaluation, which is already on the main actor.
    static var defaultValue: AppDependencies {
        MainActor.assumeIsolated { PreviewDependencies.shared }
    }
}

extension EnvironmentValues {
    public var appDependencies: AppDependencies {
        get { self[AppDependenciesKey.self] }
        set { self[AppDependenciesKey.self] = newValue }
    }
}
