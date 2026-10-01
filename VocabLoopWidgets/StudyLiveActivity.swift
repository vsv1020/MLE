import ActivityKit
import SwiftUI
import WidgetKit

/// The study session on the Lock Screen and in the Dynamic Island. Content is pushed locally by
/// the app's `StudyActivityController`; everything said comes from `StudyActivityCopy`.
/// `docs/WIDGET-PLAN.md` §1.2.
struct StudyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StudyActivityAttributes.self) { context in
            StudyLockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Palette.canvas)
                .activitySystemActionForegroundColor(Palette.textPrimary)
                .widgetURL(WidgetLinks.study)
        } dynamicIsland: { context in
            let attributes = context.attributes
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StillMochi(mood: mood(for: state), look: attributes.look, width: 44)
                        .padding(.leading, Spacing.xxs)
                }
                DynamicIslandExpandedRegion(.center) {
                    ActivityProgress(attributes: attributes, state: state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityChips(state: state)
                        .padding(.trailing, Spacing.xxs)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(StudyActivityCopy.line(for: state, isStale: context.isStale))
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } compactLeading: {
                CompactGoalRing(attributes: attributes, state: state)
            } compactTrailing: {
                CompactCount(attributes: attributes, state: state)
            } minimal: {
                CompactGoalRing(attributes: attributes, state: state)
            }
            .widgetURL(WidgetLinks.study)
            .keylineTint(Palette.brandPrimary)
        }
    }

    private func mood(for state: StudyActivityState) -> Mascot.Mood {
        switch state.phase {
        case .studying: return StudyActivityPolicy.showsCombo(state.combo) ? .cheer : .happy
        case .goalReached: return .cheer
        case .finished: return .happy
        case .resting: return .sleepy
        }
    }
}

// MARK: - Lock Screen / banner

struct StudyLockScreenView: View {
    let attributes: StudyActivityAttributes
    let state: StudyActivityState
    let isStale: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            StillMochi(mood: isStale ? .sleepy : mood, look: attributes.look, width: 56)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack {
                    Text("VocabLoop")
                        .font(Typography.chip)
                        .foregroundStyle(Palette.textSecondary)
                    Spacer(minLength: 0)
                    ActivityChips(state: state)
                }
                ActivityProgress(attributes: attributes, state: state)
                Text(StudyActivityCopy.line(for: state, isStale: isStale))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(Spacing.md)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            StudyActivityCopy.accessibilitySummary(for: state, dailyGoal: attributes.dailyGoal, isStale: isStale)
        )
    }

    private var mood: Mascot.Mood {
        switch state.phase {
        case .studying: return .happy
        case .goalReached: return .cheer
        case .finished: return .happy
        case .resting: return .sleepy
        }
    }
}

// MARK: - Parts

/// "12 of 30 today" and a bar, or "12 reviews today" with no goal.
struct ActivityProgress: View {
    let attributes: StudyActivityAttributes
    let state: StudyActivityState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(StudyActivityCopy.progress(reviewsToday: state.reviewsToday, dailyGoal: attributes.dailyGoal))
                .font(Typography.bodyEmphasis)
                .foregroundStyle(Palette.textPrimary)
                .monospacedDigit()
                .contentTransition(reduceMotion ? ContentTransition.identity : ContentTransition.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let progress = StudyActivityPolicy.goalProgress(
                reviewsToday: state.reviewsToday, dailyGoal: attributes.dailyGoal
            ) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Palette.brandPrimary)
                    .animation(reduceMotion ? nil : .default, value: progress)
            }
        }
    }
}

/// Combo "×5" from three in a row, and the streak flame.
struct ActivityChips: View {
    let state: StudyActivityState

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            if StudyActivityPolicy.showsCombo(state.combo) {
                Text(StudyActivityCopy.combo(state.combo))
                    .font(Typography.chip)
                    .monospacedDigit()
                    .foregroundStyle(Palette.onBrand)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Palette.brandPrimary))
            }
            StreakChip(streak: state.streak, isLit: state.studiedToday)
        }
    }
}

/// The compact-leading and minimal ring: today's goal, or a star with no goal.
struct CompactGoalRing: View {
    let attributes: StudyActivityAttributes
    let state: StudyActivityState

    var body: some View {
        if let progress = StudyActivityPolicy.goalProgress(
            reviewsToday: state.reviewsToday, dailyGoal: attributes.dailyGoal
        ) {
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .tint(Palette.brandPrimary)
                .frame(width: 20, height: 20)
                .accessibilityLabel(StudyActivityCopy.progress(
                    reviewsToday: state.reviewsToday, dailyGoal: attributes.dailyGoal
                ))
        } else {
            Image(systemName: "star.fill")
                .foregroundStyle(Palette.brandSecondary)
                .accessibilityLabel(StudyActivityCopy.progress(reviewsToday: state.reviewsToday, dailyGoal: 0))
        }
    }
}

/// "12/30" (or "12 ✓"); "×5" while a combo of three or more is running.
struct CompactCount: View {
    let attributes: StudyActivityAttributes
    let state: StudyActivityState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(StudyActivityPolicy.showsCombo(state.combo)
             ? StudyActivityCopy.combo(state.combo)
             : StudyActivityCopy.compact(reviewsToday: state.reviewsToday, dailyGoal: attributes.dailyGoal))
            .font(Typography.buttonInterval)
            .monospacedDigit()
            .contentTransition(reduceMotion ? ContentTransition.identity : ContentTransition.numericText())
            .foregroundStyle(Palette.brandPrimary)
    }
}
