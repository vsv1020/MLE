import SwiftUI
import WidgetKit

/// Where a tap goes. URL literals rather than `AppLinks` (which the sharing workstream owns);
/// `VocabLoopApp.action(for:)` is the other half.
enum WidgetLinks {
    static let study = URL(string: "vocabloop://study")!
    static let mochi = URL(string: "vocabloop://mochi")!
}

// MARK: - Timeline

/// One moment of either Home Screen widget.
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let state: WidgetDisplayState
}

/// Reads `widget-snapshot.json` from the App Group container — never the SwiftData store — and
/// lays out entries with ``WidgetTimelinePlanner``. Without the group (an unsigned build, or a
/// missing entitlement) the file is not there and every family shows "Open VocabLoop".
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        let now = Date()
        return SnapshotEntry(date: now, state: WidgetTimelinePlanner.state(of: WidgetSnapshot.sample(at: now), at: now))
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let now = Date()
        // The gallery preview shows what the widget looks like with numbers, even before the
        // first review.
        let file = WidgetSnapshotWriter().read() ?? (context.isPreview ? WidgetSnapshot.sample(at: now) : nil)
        completion(SnapshotEntry(date: now, state: WidgetTimelinePlanner.state(of: file, at: now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        let plan = WidgetTimelinePlanner.plan(snapshot: WidgetSnapshotWriter().read(), now: now)
        let entries = plan.entries.map { SnapshotEntry(date: $0.date, state: $0) }
        completion(Timeline(entries: entries, policy: .after(plan.reloadAfter)))
    }
}

extension WidgetSnapshot {
    /// Gallery and placeholder numbers.
    static func sample(at date: Date) -> WidgetSnapshot {
        WidgetSnapshot(
            dueNow: 12, reviewsToday: 8, dailyGoal: 30, streak: 7, studiedToday: true,
            mochiLevel: 4, candy: 640, bodyColor: MochiBodyColor.vanilla.rawValue,
            accessories: [MochiAccessory.redScarf.rawValue], updatedAt: date
        )
    }
}

// MARK: - Background

extension View {
    /// Paper behind the Home Screen families; nothing behind the Lock Screen ones, which the
    /// system tints. Required on iOS 17, or the widget renders an "adopt containerBackground"
    /// placeholder.
    func widgetBackground(for family: WidgetFamily) -> some View {
        containerBackground(for: .widget) {
            if family.isAccessory {
                Color.clear
            } else {
                Palette.canvas
            }
        }
    }
}

extension WidgetFamily {
    var isAccessory: Bool {
        switch self {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: return true
        default: return false
        }
    }
}

// MARK: - Parts

/// Flame and streak. Grey until today has a review, orange after; hidden at zero.
struct StreakChip: View {
    let streak: Int
    let isLit: Bool

    var body: some View {
        if streak > 0 {
            HStack(spacing: 2) {
                Image(systemName: "flame.fill")
                Text("\(streak)")
                    .monospacedDigit()
            }
            .font(Typography.chip)
            .foregroundStyle(isLit ? Palette.brandSecondary : Palette.textTertiary)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 3)
            .background(Capsule().fill(Palette.surface))
            .overlay(Capsule().stroke(Palette.separator.opacity(0.35), lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(WidgetCopy.streak(streak))
        }
    }
}

/// Today's goal as a bar. Never animated: widgets are snapshots.
struct GoalBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.surfaceRaised)
                Capsule()
                    .fill(Palette.brandPrimary)
                    .frame(width: max(0, proxy.size.width * min(1, progress)))
            }
            .overlay(Capsule().stroke(Palette.separator.opacity(0.35), lineWidth: 1))
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// The "Start review" pill on the medium widget. Visual only — the whole widget is one link.
struct StartPill: View {
    var body: some View {
        Text(WidgetCopy.startReview)
            .font(Typography.chip)
            .foregroundStyle(Palette.onBrand)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs + 1)
            .background(Capsule().fill(Palette.brandPrimary))
    }
}

/// A still Mochi, sized by width (Mochi is 1.2 wide for every 1 tall).
struct StillMochi: View {
    let mood: Mascot.Mood
    let look: MochiLook
    let width: CGFloat

    var body: some View {
        Mascot(mood: mood, look: look)
            .still()
            .frame(width: width, height: width / 1.2)
    }
}

enum WidgetFonts {
    /// The big number on the small and medium widgets. A text style, so it still follows
    /// Dynamic Type; the views cap it with `minimumScaleFactor`.
    static let hero = Font.system(.largeTitle, design: .rounded, weight: .black).monospacedDigit()
}
