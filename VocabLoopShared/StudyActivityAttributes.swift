import Foundation
import ActivityKit

/// The study-session Live Activity: fixed attributes plus ``StudyActivityState``.
///
/// Compiled into both the app (which requests and updates it through `StudyActivityController`)
/// and `VocabLoopWidgets` (which draws it). The two must agree on this type byte for byte, which
/// is why it lives in `VocabLoopShared/`. Mochi travels as raw values, like the widget snapshot,
/// so an unknown colour or accessory from a newer app degrades instead of failing to decode.
public struct StudyActivityAttributes: ActivityAttributes, Sendable {
    public typealias ContentState = StudyActivityState

    public var mochiLevel: Int
    /// ``MochiBodyColor`` raw value.
    public var bodyColor: String
    /// ``MochiAccessory`` raw values.
    public var accessories: [String]
    /// `0` means no goal.
    public var dailyGoal: Int
    public var startedAt: Date

    public init(mochiLevel: Int, bodyColor: String, accessories: [String], dailyGoal: Int, startedAt: Date) {
        self.mochiLevel = mochiLevel
        self.bodyColor = bodyColor
        self.accessories = accessories
        self.dailyGoal = dailyGoal
        self.startedAt = startedAt
    }

    /// Mochi as the activity draws it.
    public var look: MochiLook {
        MochiLook(level: mochiLevel, bodyColor: bodyColor, accessories: accessories)
    }
}
