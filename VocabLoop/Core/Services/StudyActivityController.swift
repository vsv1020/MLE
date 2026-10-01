import Foundation
import ActivityKit
import OSLog

/// Owns the study-session Live Activity (`docs/WIDGET-PLAN.md` §1.2).
///
/// One activity at a time, pushed locally — there is no push server. Every ActivityKit error is
/// logged and swallowed: a Lock Screen glance is never worth interrupting a review over, and on a
/// device or build where activities cannot run (Live Activities off, an iPad, a `VL_WIDGETS=off`
/// build with no extension to draw them) every call here simply does nothing visible.
///
/// The rules — when to start, what the content says, how long an ended one lingers — live in
/// ``StudyActivityPolicy``, which is pure and tested. This class only talks to ActivityKit.
@MainActor
public final class StudyActivityController {
    /// `@AppStorage` key of the Settings toggle. A device setting, not part of the account.
    nonisolated public static let enabledKey = "liveActivity.enabled"

    private var activity: Activity<StudyActivityAttributes>?
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.vocabloop.app", category: "liveActivity")

    /// `false` inside the unit-test host, so no test ever talks to ActivityKit.
    private let isAvailable: Bool

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isAvailable = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    /// The Settings toggle; on unless the user switched it off.
    public var isEnabled: Bool {
        defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Whether the system allows Live Activities for this app right now.
    private var isSystemEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// `true` while this process holds an activity.
    public var isActive: Bool { activity != nil }

    // MARK: - Lifecycle

    /// Start an activity for a session that has just landed on a card, or update the one already
    /// running. Attributes are fixed for an activity's life, so an existing one keeps its own.
    public func begin(
        attributes: StudyActivityAttributes, state: StudyActivityState, isReviewing: Bool,
        queueIsEmpty: Bool, now: Date = Date()
    ) {
        guard isAvailable else { return }
        guard StudyActivityPolicy.shouldStart(
            settingEnabled: isEnabled, systemEnabled: isSystemEnabled,
            isReviewing: isReviewing, queueIsEmpty: queueIsEmpty
        ) else { return }
        if activity != nil {
            update(state: state, now: now)
            return
        }
        request(attributes: attributes, state: state, now: now)
    }

    /// New numbers for the running activity. With none running — it went stale while the app was
    /// away and was ended on return — a new one is requested, so the next grade brings it back.
    public func update(state: StudyActivityState, attributes: StudyActivityAttributes? = nil, now: Date = Date()) {
        guard isAvailable else { return }
        guard let activity else {
            if let attributes, isEnabled, isSystemEnabled, state.phase == .studying {
                request(attributes: attributes, state: state, now: now)
            }
            return
        }
        let content = ActivityContent(state: state, staleDate: StudyActivityPolicy.staleDate(now: now))
        Task {
            await activity.update(content)
        }
    }

    /// End the running activity with its final content and the dismissal ``StudyActivityPolicy``
    /// gives `ending`. A no-op when nothing is running.
    public func end(_ ending: StudyActivityEnding, state: StudyActivityState? = nil, now: Date = Date()) {
        guard isAvailable, let activity else { return }
        self.activity = nil
        let finalContent: ActivityContent<StudyActivityState>?
        if var state {
            state.phase = ending.finalPhase
            finalContent = ActivityContent(state: state, staleDate: nil)
        } else {
            finalContent = nil
        }
        let policy: ActivityUIDismissalPolicy
        if let date = StudyActivityPolicy.dismissalDate(for: ending, now: now) {
            policy = .after(date)
        } else {
            policy = .immediate
        }
        Task {
            await activity.end(finalContent, dismissalPolicy: policy)
        }
    }

    /// End every study activity at once, including ones a previous process left behind. Called
    /// at launch, and when the Settings toggle is switched off.
    public func endAllImmediately() {
        guard isAvailable else { return }
        activity = nil
        // Captured now, before any `await`, so an activity requested a moment later by the new
        // session is not swept up with the leftovers.
        let leftovers = Activity<StudyActivityAttributes>.activities
        guard !leftovers.isEmpty else { return }
        Task {
            for leftover in leftovers {
                await leftover.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// On returning to the foreground: an activity whose content went stale while the app was
    /// away is ended immediately rather than revived; the next grade requests a fresh one.
    public func endIfStale(now: Date = Date()) {
        guard isAvailable, let activity else { return }
        let ended = activity.activityState == .ended || activity.activityState == .dismissed
        if ended || StudyActivityPolicy.shouldEndOnReturn(staleDate: activity.content.staleDate, now: now) {
            end(.abandoned, now: now)
        }
    }

    // MARK: - Private

    private func request(attributes: StudyActivityAttributes, state: StudyActivityState, now: Date) {
        let content = ActivityContent(state: state, staleDate: StudyActivityPolicy.staleDate(now: now))
        do {
            activity = try Activity<StudyActivityAttributes>.request(
                attributes: attributes, content: content, pushType: nil
            )
        } catch {
            logger.info("Live Activity not started: \(error.localizedDescription, privacy: .public)")
        }
    }
}
