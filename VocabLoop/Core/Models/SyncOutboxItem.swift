import Foundation
import SwiftData

/// What kind of change is waiting to be pushed.
public enum SyncOperation: String, Codable, CaseIterable, Hashable, Sendable {
    case reviewLogged
    case cardUpserted
    case entryUpserted
    case preferencesUpdated
    case deckUpserted
    case deckDeleted
    case entryDeleted
    case accountDeleted
}

/// A durable, ordered queue of local changes waiting to reach the server.
///
/// This is the whole offline-first story in one table. Local writes commit
/// immediately and append a row here; the ``SyncEngine`` drains the queue whenever
/// the network is reachable. Nothing in the UI ever awaits a request, so there is no
/// state in which the app is unusable because the server is unreachable.
///
/// The payload is pre-encoded `Data` rather than a relationship to the live object,
/// because the queue must describe *what happened*, not *what the object looks like
/// now*: by the time a row is drained the entity may have been edited again, or
/// deleted.
@Model
public final class SyncOutboxItem {
    @Attribute(.unique) public var itemID: String

    public var operationRaw: String
    /// Identity of the affected record, for de-duplication of repeated upserts.
    public var subjectID: String
    /// JSON body to send.
    public var payload: Data

    /// Monotonic ordering. Server-visible ordering must match the order the user made
    /// the changes in, and `createdAt` alone is not enough when two writes land in the
    /// same millisecond.
    public var sequence: Int

    public var createdAt: Date
    public var attempts: Int
    public var lastAttemptAt: Date?
    /// Last transport or server error, kept for the Settings sync status row. Users
    /// deserve to know *why* sync is stuck.
    public var lastError: String?
    /// Earliest next attempt, set by exponential backoff.
    public var nextAttemptAfter: Date?

    public init(
        operation: SyncOperation,
        subjectID: String,
        payload: Data,
        sequence: Int,
        now: Date = Date()
    ) {
        self.itemID = UUID().uuidString
        self.operationRaw = operation.rawValue
        self.subjectID = subjectID
        self.payload = payload
        self.sequence = sequence
        self.createdAt = now
        self.attempts = 0
    }

    public var operation: SyncOperation? { SyncOperation(rawValue: operationRaw) }

    public func isReady(at now: Date) -> Bool {
        guard let nextAttemptAfter else { return true }
        return nextAttemptAfter <= now
    }

    /// Exponential backoff with a ceiling, so a permanently failing item stops
    /// burning battery but never blocks the items behind it forever.
    public func recordFailure(_ message: String, now: Date = Date()) {
        attempts += 1
        lastAttemptAt = now
        lastError = message
        let delay = min(pow(2.0, Double(min(attempts, 10))), 3600)
        nextAttemptAfter = now.addingTimeInterval(delay)
    }

    /// Items that have failed this many times are surfaced in Settings as needing
    /// attention rather than retried silently forever.
    public static let attemptsBeforeSurfacing = 8
}
