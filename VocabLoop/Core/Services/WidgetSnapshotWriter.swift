import Foundation
import OSLog

/// Where files shared with a future widget live.
///
/// The App Group container when the capability exists; Application Support otherwise. 1.0.7
/// ships without the capability (see `docs/ENGAGEMENT-PLAN.md` §1.12), so today this resolves to
/// Application Support — and the day the entitlement lands, the same code starts writing where a
/// widget can read, with nothing else to change.
public enum SharedStorage {
    public static let appGroupID = "group.com.vocabloop.app"

    public static var containerURL: URL {
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return group
        }
        let base = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    public static var widgetSnapshotURL: URL {
        containerURL.appending(path: "widget-snapshot.json")
    }
}

/// Everything a home-screen widget needs, flattened to plain values.
///
/// A widget runs in a second process and must **never** open the SwiftData store — two
/// processes on one SQLite file is how stores get corrupted. It reads this file instead.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public var dueNow: Int
    public var reviewsToday: Int
    public var dailyGoal: Int
    public var streak: Int
    public var studiedToday: Bool
    public var mochiLevel: Int
    public var candy: Int
    /// ``MochiBodyColor`` raw value.
    public var bodyColor: String
    /// ``MochiAccessory`` raw values.
    public var accessories: [String]
    public var updatedAt: Date

    public init(
        dueNow: Int,
        reviewsToday: Int,
        dailyGoal: Int,
        streak: Int,
        studiedToday: Bool,
        mochiLevel: Int,
        candy: Int,
        bodyColor: String,
        accessories: [String],
        updatedAt: Date
    ) {
        self.dueNow = dueNow
        self.reviewsToday = reviewsToday
        self.dailyGoal = dailyGoal
        self.streak = streak
        self.studiedToday = studiedToday
        self.mochiLevel = mochiLevel
        self.candy = candy
        self.bodyColor = bodyColor
        self.accessories = accessories
        self.updatedAt = updatedAt
    }
}

/// Writes and reads ``WidgetSnapshot``. Failures are logged and swallowed: a widget showing
/// yesterday's numbers is better than a study session interrupted by a file error.
public struct WidgetSnapshotWriter: Sendable {
    public let url: URL

    public init(url: URL = SharedStorage.widgetSnapshotURL) {
        self.url = url
    }

    public func write(_ snapshot: WidgetSnapshot) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try Self.encoder.encode(snapshot)
            // Atomic, so a widget reading mid-write sees the old file or the new one, never half.
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Widget snapshot write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(WidgetSnapshot.self, from: data)
    }

    private static let logger = Logger(subsystem: "com.vocabloop.app", category: "widget")

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
