import SwiftUI
import WidgetKit

/// Words due, today's goal and the streak — Home Screen and Lock Screen.
/// `docs/WIDGET-PLAN.md` §1.1.
struct TodayWidget: Widget {
    static let kind = "com.vocabloop.today"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            TodayWidgetView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("Words due, today's goal and your streak.")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
    }
}

struct TodayWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(WidgetLinks.study)
            .widgetBackground(for: family)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemMedium:
            TodayMediumView(state: entry.state)
        case .accessoryCircular:
            TodayCircularView(state: entry.state)
        case .accessoryRectangular:
            TodayRectangularView(state: entry.state)
        case .accessoryInline:
            Text(WidgetCopy.inline(entry.state))
        default:
            TodaySmallView(state: entry.state)
        }
    }
}

// MARK: - Home Screen

/// The two states with no numbers: never written (or no App Group), and stale.
struct NoNumbersView: View {
    let state: WidgetDisplayState
    var mochiWidth: CGFloat = 64

    var body: some View {
        VStack(spacing: Spacing.xs) {
            StillMochi(
                mood: state.isStale ? .sleepy : .curious,
                look: state.snapshot.map(MochiLook.init(snapshot:)) ?? .default,
                width: mochiWidth
            )
            Text(state.isStale ? WidgetCopy.staleTitle : WidgetCopy.emptyTitle)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WidgetCopy.accessibilityLabel(state))
    }
}

/// The numbers block shared by small and medium: due count (or "All caught up"), goal bar.
struct TodayNumbers: View {
    let snapshot: WidgetSnapshot
    let state: WidgetDisplayState

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            if state.isCaughtUp {
                Text(WidgetCopy.caughtUp)
                    .font(Typography.sectionHeader)
                    .foregroundStyle(Palette.textPrimary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(2)
            } else {
                Text(WidgetCopy.dueCount(snapshot.dueNow))
                    .font(WidgetFonts.hero)
                    .foregroundStyle(Palette.textPrimary)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text("due")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 0)
            if snapshot.dailyGoal > 0, let progress = state.goalProgress {
                GoalBar(progress: progress)
                Text(WidgetCopy.goal(reviewsToday: snapshot.reviewsToday, dailyGoal: snapshot.dailyGoal))
                    .font(Typography.chip)
                    .foregroundStyle(Palette.textSecondary)
                    .monospacedDigit()
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
            }
        }
    }
}

struct TodaySmallView: View {
    let state: WidgetDisplayState

    var body: some View {
        if state.kind == .current, let snapshot = state.snapshot {
            TodayNumbers(snapshot: snapshot, state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .overlay(alignment: .topTrailing) {
                    StreakChip(streak: snapshot.streak, isLit: snapshot.studiedToday)
                }
                .overlay(alignment: .bottomTrailing) {
                    StillMochi(
                        mood: state.isCaughtUp ? .cheer : (snapshot.studiedToday ? .happy : .curious),
                        look: MochiLook(snapshot: snapshot),
                        width: 44
                    )
                    // Above the goal caption, not on top of it.
                    .padding(.bottom, snapshot.dailyGoal > 0 ? 26 : 0)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(WidgetCopy.accessibilityLabel(state))
        } else {
            NoNumbersView(state: state)
        }
    }
}

struct TodayMediumView: View {
    let state: WidgetDisplayState

    var body: some View {
        if state.kind == .current, let snapshot = state.snapshot {
            HStack(spacing: Spacing.md) {
                WidgetMochiView(
                    look: MochiLook(snapshot: snapshot),
                    level: snapshot.mochiLevel,
                    mood: state.isCaughtUp ? .cheer : (snapshot.studiedToday ? .happy : .curious),
                    isStill: true
                )
                .frame(width: 72)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    TodayNumbers(snapshot: snapshot, state: state)
                    StartPill()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .overlay(alignment: .topTrailing) {
                    StreakChip(streak: snapshot.streak, isLit: snapshot.studiedToday)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(WidgetCopy.accessibilityLabel(state))
        } else {
            NoNumbersView(state: state, mochiWidth: 72)
        }
    }
}

// MARK: - Lock Screen

/// Shape only, no colour: the Lock Screen renders accessory widgets tinted.
struct TodayCircularView: View {
    let state: WidgetDisplayState

    var body: some View {
        Group {
            if state.kind == .current, let snapshot = state.snapshot {
                if let progress = state.goalProgress {
                    Gauge(value: progress) {
                        Text("Goal")
                    } currentValueLabel: {
                        Text(WidgetCopy.dueCount(snapshot.dueNow))
                            .monospacedDigit()
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                } else {
                    ZStack {
                        AccessoryWidgetBackground()
                        VStack(spacing: 0) {
                            Image(systemName: "flame.fill")
                            Text("\(snapshot.streak)")
                                .font(.system(.body, design: .rounded, weight: .bold))
                                .monospacedDigit()
                        }
                    }
                }
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: state.isStale ? "moon.zzz.fill" : "book.closed.fill")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WidgetCopy.accessibilityLabel(state))
    }
}

struct TodayRectangularView: View {
    let state: WidgetDisplayState

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("VocabLoop")
                .font(.headline)
                .widgetAccentable()
            Text(WidgetCopy.rectangularDetail(state))
                .font(.body)
                .monospacedDigit()
                .minimumScaleFactor(0.8)
                .lineLimit(1)
            if state.kind == .current, let snapshot = state.snapshot, snapshot.streak > 0 {
                Label(WidgetCopy.streak(snapshot.streak), systemImage: "flame.fill")
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WidgetCopy.accessibilityLabel(state))
    }
}
