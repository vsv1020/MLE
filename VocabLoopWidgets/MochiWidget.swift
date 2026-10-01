import SwiftUI
import WidgetKit

/// Mochi on the Home Screen, dressed as in the app. Tap → Mochi's room.
/// `docs/WIDGET-PLAN.md` §1.1.
struct MochiWidget: Widget {
    static let kind = "com.vocabloop.mochi"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            MochiWidgetView(state: entry.state)
                .widgetURL(WidgetLinks.mochi)
                .widgetBackground(for: .systemSmall)
        }
        .configurationDisplayName("Mochi")
        .description("Mochi, in today's outfit.")
        .supportedFamilies([.systemSmall])
    }
}

struct MochiWidgetView: View {
    let state: WidgetDisplayState

    var body: some View {
        VStack(spacing: Spacing.xxs) {
            if let snapshot = state.snapshot {
                WidgetMochiView(
                    look: MochiLook(snapshot: snapshot),
                    level: snapshot.mochiLevel,
                    mood: WidgetCopy.mochiMood(state),
                    isStill: true
                )
                .frame(maxHeight: .infinity)
                Text(state.isStale ? WidgetCopy.staleTitle : WidgetCopy.candy(snapshot.candy))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .monospacedDigit()
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
            } else {
                StillMochi(mood: .curious, look: .default, width: 84)
                    .frame(maxHeight: .infinity)
                Text(WidgetCopy.openApp)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let snapshot = state.snapshot else { return WidgetCopy.emptyTitle }
        if state.isStale { return WidgetCopy.staleTitle }
        return "Mochi, \(WidgetCopy.level(snapshot.mochiLevel)), \(snapshot.candy) star candy"
    }
}
