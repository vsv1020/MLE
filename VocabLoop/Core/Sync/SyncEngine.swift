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
    ///
    /// `nonisolated` because it is used as a default argument, and default arguments are evaluated
    /// in the caller's context — which for a `@MainActor` type's static property means "main
    /// actor-isolated static property can not be referenced from a nonisolated context", a warning
    /// today and an error under the Swift 6 language mode. An immutable `Int` has no reason to be
    /// actor-isolated in the first place.
    nonisolated static let batchSize = 200

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
    /// Both queues, because Settings shows this number and half of it would be a lie.
    public func pendingCount() -> Int {
        let outbox = (try? context.fetchCount(FetchDescriptor<SyncOutboxItem>())) ?? 0
        let reviews = (try? context.fetchCount(
            FetchDescriptor<ReviewLog>(predicate: #Predicate { !$0.isSynced })
        )) ?? 0
        return outbox + reviews
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

        // Only the rows this build can send. `pendingCount()` includes operations awaiting
        // their own endpoint, and counting those would leave the progress bar short of full
        // on a sync that in fact sent everything it could.
        let total = pushablePendingCount()
        guard total > 0 else {
            status = .idle(lastSyncedAt: lastSyncedAt)
            return
        }

        var sent = 0
        while true {
            // Two sources, drained together. Reviews live on `ReviewLog` (marked by `isSynced`)
            // rather than in the outbox, because the log is already append-only and never pruned —
            // a second copy per review was pure duplication and, with no server, never drained.
            let reviews = (try? unsyncedReviews()) ?? []
            let batch = (try? readyBatch()) ?? []
            guard !reviews.isEmpty || !batch.isEmpty else { break }

            status = .syncing(progress: total > 0 ? Double(sent) / Double(total) : 0)

            do {
                let request = try buildRequest(from: batch, reviews: reviews)
                if !request.isEmpty {
                    _ = try await client.send(
                        APIClient.Endpoint(path: "sync/push", method: "POST"),
                        body: request,
                        as: SyncPushResponse.self
                    )
                }
                // Only commit the "sent" markers after the server has accepted. A crash between
                // the request and this point re-sends the batch, which is why every operation is
                // idempotent server-side.
                for review in reviews {
                    review.isSynced = true
                }
                for item in batch {
                    context.delete(item)
                }
                try context.save()
                // Each iteration either marks a review or deletes a row, so both sources strictly
                // shrink and the loop terminates.
                sent += batch.count + reviews.count
            } catch {
                let message = (error as? AuthError)?.errorDescription ?? error.localizedDescription
                logger.error("Push failed: \(message, privacy: .public)")
                // Failure is recorded per item so backoff is per item, and one poison row
                // cannot stall the queue forever. Reviews need no backoff marker: they are not
                // deleted on success, so an unsynced one is simply retried next time.
                for item in batch {
                    item.recordFailure(message)
                }
                try? context.save()
                return
            }
        }

        lastSyncedAt = Date()
    }

    /// Reviews the server has not acknowledged yet, oldest first.
    ///
    /// `ReviewLog` is the queue for reviews. It is append-only and never pruned — it is what a
    /// future weight optimiser trains on — so a parallel outbox copy bought nothing and cost a row
    /// per graded card, permanently, in a build with no server to drain it.
    func unsyncedReviews(limit: Int = SyncEngine.batchSize) throws -> [ReviewLog] {
        var descriptor = FetchDescriptor<ReviewLog>(
            predicate: #Predicate { !$0.isSynced },
            sortBy: [SortDescriptor(\.reviewedAt)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    /// Operations `buildRequest` can actually put on the wire.
    ///
    /// The `sync/push` endpoint carries reviews, cards, entries, preferences and entry
    /// deletions. Decks and account deletion get their own endpoints once a server exists.
    /// Until then their rows must be *skipped*, not drained: ``sync`` deletes every item in a
    /// batch once the server accepts it, so an unsupported row picked up here would be thrown
    /// away by a request that never mentioned it. Skipping is also what keeps ``sync``'s loop
    /// finite — a row that is kept but still fetched would be re-read forever.
    /// `.reviewLogged` is absent on purpose: reviews are queued on ``ReviewLog/isSynced``, not
    /// here, so an outbox row carrying one is a leftover from an older build. Excluding it means
    /// such a row is skipped rather than drained — and skipping is what stops a review being
    /// deleted by a request that never mentioned it.
    static let pushableOperations: Set<SyncOperation> = [
        .cardUpserted, .entryUpserted, .preferencesUpdated, .entryDeleted,
    ]

    /// The next batch, oldest first, skipping items still in backoff.
    ///
    /// Ordered by ``SyncOutboxItem/sequence`` because the server must see the changes in
    /// the order the user made them — `createdAt` is not enough when two writes land in
    /// the same millisecond.
    /// Internal rather than private so a test can assert on the selection itself. What it
    /// excludes is the difference between a sync and silent data loss, and asserting that
    /// through `sync()` would need a live server to accept the batch first.
    func readyBatch() throws -> [SyncOutboxItem] {
        let now = Date()
        // No `fetchLimit`: the limit has to be applied *after* filtering, or a run of
        // unsupported rows at the head of the queue would fill the batch, come back empty of
        // anything sendable, and stall every real change behind it.
        let descriptor = FetchDescriptor<SyncOutboxItem>(sortBy: [SortDescriptor(\.sequence)])
        let ready = try context.fetch(descriptor).filter { item in
            guard item.isReady(at: now) else { return false }
            // A nil operation is a raw string this build does not know — written by a newer
            // version, or corrupt. Never drained, because draining means deleting.
            guard let operation = item.operation else { return false }
            return Self.pushableOperations.contains(operation)
        }
        return Array(ready.prefix(Self.batchSize))
    }

    /// Everything this build could actually send, for an honest progress fraction.
    ///
    /// Excludes outbox operations still waiting for their own endpoint — counting those would leave
    /// the bar short of full on a sync that in fact sent everything it could.
    private func pushablePendingCount() -> Int {
        let all = (try? context.fetch(FetchDescriptor<SyncOutboxItem>())) ?? []
        let outbox = all.filter { item in
            guard let operation = item.operation else { return false }
            return Self.pushableOperations.contains(operation)
        }.count
        let reviews = (try? context.fetchCount(
            FetchDescriptor<ReviewLog>(predicate: #Predicate { !$0.isSynced })
        )) ?? 0
        return outbox + reviews
    }

    /// Group an outbox batch into one request.
    ///
    /// Repeated upserts of the same subject collapse to the last one: a card reviewed five
    /// times offline needs one final state pushed, not five. Reviews are *not* collapsed —
    /// each one is a distinct event, and losing any of them would corrupt the history that
    /// makes future weight optimisation possible.
    private func buildRequest(
        from batch: [SyncOutboxItem], reviews unsynced: [ReviewLog]
    ) throws -> SyncPushRequest {
        // Straight from the log, in time order, with no collapsing. Every review is a distinct
        // event and losing any of them would corrupt the history a future optimiser trains on.
        var reviews = unsynced.map(ReviewLogSyncPayload.init(log:))
        var cardsBySubject: [String: CardSyncPayload] = [:]
        var entriesBySubject: [String: EntrySyncPayload] = [:]
        var preferences: PreferencesSyncPayload?
        var deletedEntryIDs: [String] = []
        let decoder = JSONDecoder()

        for item in batch {
            guard let operation = item.operation else { continue }
            switch operation {
            case .reviewLogged:
                // Only reachable for a row written by a build that still queued reviews here.
                // `readyBatch` excludes the operation, so this cannot arrive from a current write —
                // but decoding it is still the right thing to do if one ever does, rather than
                // dropping a review on the floor during an upgrade.
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
                // Unreachable: `readyBatch` filters these out via `pushableOperations`, because
                // a batch is deleted wholesale once the server accepts it and a row this
                // request never mentioned would be silently discarded. Kept as a case rather
                // than a `default` so adding an operation to the enum without deciding whether
                // it is pushable is a compile error.
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
        // A batch delete is safe here, unlike in `LocalAuthBackend.deleteAccount`: `SyncOutboxItem`
        // has no relationships, so there is no inverse for the store-level delete to fail to
        // maintain.
        try? context.delete(model: SyncOutboxItem.self)

        // Reviews are marked sent rather than deleted. "Discard pending" means "stop trying to
        // send these", not "erase my history" — the log stays, so statistics and any future weight
        // fit are untouched. Without this the count in Settings would not budge and the escape
        // hatch would look broken.
        for review in (try? context.fetch(
            FetchDescriptor<ReviewLog>(predicate: #Predicate { !$0.isSynced })
        )) ?? [] {
            review.isSynced = true
        }
        try? context.save()
        refreshStatus()
    }
}
