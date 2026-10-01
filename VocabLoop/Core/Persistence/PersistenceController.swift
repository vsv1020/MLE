import Foundation
import SwiftData
import OSLog

/// Owns the app's `ModelContainer`.
///
/// One place that knows the schema, so a model added without being registered fails
/// here rather than at a random `@Query` site.
public enum PersistenceController {
    static let logger = Logger(subsystem: "com.vocabloop.app", category: "persistence")

    /// Every `@Model` type in the app. SwiftData only knows about types listed here.
    public static let schema = Schema([
        Entry.self,
        Sense.self,
        Card.self,
        ReviewLog.self,
        Deck.self,
        UserAccount.self,
        StudyPreferences.self,
        DailyBatch.self,
        StudyDay.self,
        SyncOutboxItem.self,
        EngagementProfile.self,
    ])

    /// The on-disk container used by the app.
    ///
    /// If opening the store fails — almost always an incompatible schema left by a
    /// development build — the store is moved aside and a fresh one is created rather
    /// than crashing on launch. Content is re-seeded from the bundle, and the moved
    /// file is left on disk so a real user's history can be recovered by support
    /// instead of being silently destroyed.
    public static func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            logger.error("Store failed to open, quarantining: \(error.localizedDescription, privacy: .public)")
            quarantineStore()
            return try ModelContainer(for: schema, configurations: configuration)
        }
    }

    /// Cache for ``sharedContainer()``.
    @MainActor private static var cachedContainer: ModelContainer?

    /// The one container for this process.
    ///
    /// App Intents have no extension target here, so they run **inside the app's process** —
    /// launched into the background when the app is not already running. Without this, an
    /// intent calling `makeContainer()` would open a *second* `ModelContainer` on the same
    /// store file in the same process. That is not a supported configuration, and it makes the
    /// quarantine path in ``makeContainer()`` genuinely dangerous: a transient open failure in
    /// a background intent could move the store aside while the app has it open.
    ///
    /// Everything that needs the on-disk store goes through here.
    @MainActor
    public static func sharedContainer() throws -> ModelContainer {
        if let cachedContainer { return cachedContainer }
        let container = try makeContainer()
        cachedContainer = container
        return container
    }

    /// In-memory container for tests and SwiftUI previews.
    public static func makeInMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: configuration)
    }

    public static var storeURL: URL {
        let base = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: "VocabLoop.store")
    }

    /// Bytes on disk, for the Settings ▸ Data screen.
    public static func storeSizeInBytes() -> Int64 {
        let fm = FileManager.default
        // SQLite keeps its write-ahead log and shared memory alongside the main file;
        // reporting only the first understates real usage during heavy study.
        let suffixes = ["", "-wal", "-shm"]
        return suffixes.reduce(into: Int64(0)) { total, suffix in
            let path = storeURL.path() + suffix
            if let size = try? fm.attributesOfItem(atPath: path)[.size] as? Int64 {
                total += size
            }
        }
    }

    private static func quarantineStore() {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(filePath: storeURL.path() + suffix)
            guard fm.fileExists(atPath: source.path()) else { continue }
            let destination = URL(filePath: source.path() + ".quarantined-\(stamp)")
            try? fm.moveItem(at: source, to: destination)
        }
    }
}

/// Convenience fetches used across services, kept in one place so their predicates
/// stay consistent.
public extension ModelContext {
    /// The single account marked active, creating a guest if there is none.
    ///
    /// Guaranteeing an account exists is what lets every other query scope by
    /// `userID` unconditionally, instead of threading an optional through the app.
    func activeAccount() throws -> UserAccount {
        var descriptor = FetchDescriptor<UserAccount>(
            predicate: #Predicate { $0.isActive },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        if let existing = try fetch(descriptor).first {
            if existing.preferences == nil { existing.preferences = StudyPreferences() }
            return existing
        }

        let guest = UserAccount.makeGuest()
        insert(guest)
        try save()
        return guest
    }

    func entry(stableID: String) throws -> Entry? {
        var descriptor = FetchDescriptor<Entry>(predicate: #Predicate { $0.stableID == stableID })
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    func entries(stableIDs: [String]) throws -> [Entry] {
        guard !stableIDs.isEmpty else { return [] }
        let wanted = Set(stableIDs)
        let all = try fetch(FetchDescriptor<Entry>(predicate: #Predicate { wanted.contains($0.stableID) }))
        // Preserve the caller's order — daily batches are presented in generated order,
        // and a fetch makes no ordering promise.
        let byID = Dictionary(all.map { ($0.stableID, $0) }, uniquingKeysWith: { first, _ in first })
        return stableIDs.compactMap { byID[$0] }
    }

    func card(cardID: String) throws -> Card? {
        var descriptor = FetchDescriptor<Card>(predicate: #Predicate { $0.cardID == cardID })
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    func deck(slug: String) throws -> Deck? {
        var descriptor = FetchDescriptor<Deck>(predicate: #Predicate { $0.slug == slug })
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    /// Next sequence number for the sync outbox.
    func nextOutboxSequence() throws -> Int {
        var descriptor = FetchDescriptor<SyncOutboxItem>(
            sortBy: [SortDescriptor(\.sequence, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try fetch(descriptor).first?.sequence ?? 0) + 1
    }
}
