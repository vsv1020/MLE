import Foundation
import SwiftData
import Observation
import OSLog

/// What the Settings sync row shows.
public enum SyncStatus: Equatable, Sendable {
    /// No server configured for this build — the shipping default.
    case disabled
    /// Nothing pending.
    case idle(lastSyncedAt: Date?)
    /// Pending changes, waiting for connectivity or for the next attempt.
    case pending(count: Int)
    case syncing(progress: Double)
    /// Stuck. Includes the reason, because "sync failed" with no explanation is useless.
    case failed(pendingCount: Int, reason: String)

    public var isDisabled: Bool { self == .disabled }
}

/// Drains the local outbox to the server.
///
/// The outbox pattern is the whole of the offline-first story: local writes commit
/// immediately and append a ``SyncOutboxItem``; this engine sends them when it can. No
/// UI path ever awaits the network, so there is no state in which an unreachable server
/// makes the app unusable.
///
/// Off in the shipping build. ``APIConfiguration/offline`` leaves `baseURL` nil, so
/// ``status`` is ``SyncStatus/disabled`` and ``sync()`` returns immediately — but the
/// outbox is still written, so a build that gains a server pushes everything that
/// accumulated in the meantime.
@MainActor
@Observable
public final class SyncEngine {
    public private(set) var status: SyncStatus = .disabled
    public private(set) var lastSyncedAt: Date?

    /// Sync on cellular. Default on — a vocabulary sync is a few kilobytes, and the
    /// surprising behaviour would be silently not syncing all day.
    public var allowCellular = true

    private let context: ModelContext
    private let client: APIClient
    private let monitor: NetworkMonitor
    private let isServerConfigured: Bool
    private let logger = Logger(subsystem: "com.vocabloop.app", category: "sync")
    private var isRunning = false

    /// Rows per request. Large enough that a month of offline study is a handful of
    /// requests, small enough that a failure does not waste much work.
    static let batchSize = 200

    public init(
        context: ModelContext,
        client: APIClient,
        monitor: NetworkMonitor,
        isServerConfigured: Bool
    ) {
        self.context = context
        self.client = client
        self.monitor = monitor
        self.isServerConfigured = isServerConfigured
        self.status = isServerConfigured ? .idle(lastSyncedAt: nil) : .disabled
    }

    /// Number of changes waiting to be pushed. Shown in Settings even when sync is
    /// disabled, so the user can see their work is being recorded.
    public func pendingCount() -> Int {
        (try? context.fetchCount(FetchDescriptor<SyncOutboxItem>())) ?? 0
    }

    public func refreshStatus() {
        guard isServerConfigured else {
            status = .disabled
            return
        }
        let pending = pendingCount()
        if let failure = firstBlockingFailure() {
            status = .failed(pendingCount: pending, reason: failure)
        } else if pending > 0 {
            status = .pending(count: pending)
        } else {
            status = .idle(lastSyncedAt: lastSyncedAt)
        }
    }

    /// Drain the outbox.
    ///
    /// Safe to call as often as you like: it is a no-op when already running, when there
    /// is no server, when the network is unsuitable, or when there is nothing to send.
    public func sync() async {
        guard isServerConfigured else { return }
        guard !isRunning else { return }
        guard monitor.shouldSync(allowCellular: allowCellular) else {
            refreshStatus()
            return
        }

        isRunning = true
        defer {
            isRunning = false
            refreshStatus()
        }

        let total = pendingCount()
        guard total > 0 else {
            status = .idle(lastSyncedAt: lastSyncedAt)
            return
        }

        var sent = 0
        while true {
            let batch = (try? readyBatch()) ?? []
            guard !batch.isEmpty else { break }

            status = .syncing(progress: total > 0 ? Double(sent) / Double(total) : 0)

            do {
                let request = try buildRequest(from: batch)
                if !request.isEmpty {
                    _ = try await client.send(
                        APIClient.Endpoint(path: "sync/push", method: "POST"),
                        body: request,
                        as: SyncPushResponse.self
                    )
                }
                // Only delete after the server has accepted. A crash between the request
                // and this point re-sends the batch, which is why every operation is
                // idempotent server-side.
                for item in batch {
                    context.delete(item)
                }
                try context.save()
                sent += batch.count
            } catch {
                let message = (error as? AuthError)?.errorDescription ?? error.localizedDescription
                logger.error("Push failed: \(message, privacy: .public)")
                // Failure is recorded per item so backoff is per item, and one poison row
                // cannot stall the queue forever.
                for item in batch {
                    item.recordFailure(message)
                }
                try? context.save()
                return
            }
        }

        lastSyncedAt = Date()
    }

    /// The next batch, oldest first, skipping items still in backoff.
    ///
    /// Ordered by ``SyncOutboxItem/sequence`` because the server must see the changes in
    /// the order the user made them — `createdAt` is not enough when two writes land in
    /// the same millisecond.
    private func readyBatch() throws -> [SyncOutboxItem] {
        let now = Date()
        var descriptor = FetchDescriptor<SyncOutboxItem>(sortBy: [SortDescriptor(\.sequence)])
        descriptor.fetchLimit = Self.batchSize
        return try context.fetch(descriptor).filter { $0.isReady(at: now) }
    }

    /// Group an outbox batch into one request.
    ///
    /// Repeated upserts of the same subject collapse to the last one: a card reviewed five
    /// times offline needs one final state pushed, not five. Reviews are *not* collapsed —
    /// each one is a distinct event, and losing any of them would corrupt the history that
    /// makes future weight optimisation possible.
    private func buildRequest(from batch: [SyncOutboxItem]) throws -> SyncPushRequest {
        var reviews: [ReviewLogSyncPayload] = []
        var cardsBySubject: [String: CardSyncPayload] = [:]
        var entriesBySubject: [String: EntrySyncPayload] = [:]
        var preferences: PreferencesSyncPayload?
        var deletedEntryIDs: [String] = []
        let decoder = JSONDecoder()

        for item in batch {
            guard let operation = item.operation else { continue }
            switch operation {
            case .reviewLogged:
                if let payload = try? decoder.decode(ReviewLogSyncPayload.self, from: item.payload) {
                    reviews.append(payload)
                }
            case .cardUpserted:
                if let payload = try? decoder.decode(CardSyncPayload.self, from: item.payload) {
                    cardsBySubject[item.subjectID] = payload
                }
            case .entryUpserted:
                if let payload = try? decoder.decode(EntrySyncPayload.self, from: item.payload) {
                    entriesBySubject[item.subjectID] = payload
                }
            case .preferencesUpdated:
                if let payload = try? decoder.decode(PreferencesSyncPayload.self, from: item.payload) {
                    preferences = payload
                }
            case .entryDeleted:
                deletedEntryIDs.append(item.subjectID)
            case .deckUpserted, .deckDeleted, .accountDeleted:
                // Handled by dedicated endpoints once a server exists; the outbox rows are
                // kept so nothing is lost in the meantime.
                continue
            }
        }

        return SyncPushRequest(
            reviews: reviews.sorted { $0.reviewedAt < $1.reviewedAt },
            cards: Array(cardsBySubject.values),
            entries: Array(entriesBySubject.values),
            preferences: preferences,
            deletedEntryIDs: deletedEntryIDs
        )
    }

    /// Reason to surface in Settings, when an item has failed enough times that silence
    /// would be misleading.
    private func firstBlockingFailure() -> String? {
        var descriptor = FetchDescriptor<SyncOutboxItem>(sortBy: [SortDescriptor(\.sequence)])
        descriptor.fetchLimit = Self.batchSize
        let items = (try? context.fetch(descriptor)) ?? []
        return items
            .first { $0.attempts >= SyncOutboxItem.attemptsBeforeSurfacing }?
            .lastError
    }

    /// Enqueue the user's preferences.
    ///
    /// Preferences are last-write-wins — the only records where that is safe, because they hold
    /// no history worth merging. So a pending row is **replaced** rather than appended to.
    ///
    /// This matters more than it looks: the target-retention slider saves on every tick, so
    /// dragging it from 70% to 97% at 1% steps called this 27 times. Appending would leave 27
    /// rows in the store, each carrying a full preferences payload, all but the last of them
    /// dead. `SyncEngine` already collapses same-subject upserts inside one batch, so they
    /// would have sent correctly — they would just have sat in the database until then.
    public func enqueuePreferences(_ preferences: StudyPreferences) {
        do {
            let payload = try JSONEncoder().encode(PreferencesSyncPayload(preferences: preferences))
            let subject = Self.preferencesSubjectID

            let pending = try context.fetch(
                FetchDescriptor<SyncOutboxItem>(predicate: #Predicate { $0.subjectID == subject })
            )
            if let existing = pending.max(by: { $0.sequence < $1.sequence }) {
                // Keep the original sequence: the server needs to see this change where the
                // user made it, not jumped to the end of the queue.
                existing.payload = payload
                // Any earlier duplicates are dead weight from before this fix, or from a
                // concurrent write; drop them.
                for stale in pending where stale !== existing {
                    context.delete(stale)
                }
            } else {
                context.insert(SyncOutboxItem(
                    operation: .preferencesUpdated,
                    subjectID: subject,
                    payload: payload,
                    sequence: try context.nextOutboxSequence()
                ))
            }
            try context.save()
            refreshStatus()
        } catch {
            logger.error("Could not enqueue preferences: \(error.localizedDescription, privacy: .public)")
        }
    }

    static let preferencesSubjectID = "preferences"

    /// Clear the queue. Offered in Settings as the escape hatch for a permanently stuck
    /// item; it discards unsent changes, so the UI must say so before calling it.
    public func discardPending() {
        try? context.delete(model: SyncOutboxItem.self)
        try? context.save()
        refreshStatus()
    }
}
