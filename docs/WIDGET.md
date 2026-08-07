# Adding the widget

The App Intents are done and live in the app target (`VocabLoop/Core/Intents/`), so Siri,
Shortcuts and Spotlight work now. The widget needs one thing I deliberately did not do:
a second Xcode target.

## Why this step is yours, not mine

A Widget Extension is a whole target — its own build phases, Info.plist, entitlements and
embed step. I hand-wrote `project.pbxproj` because there is no Xcode in the environment this
was built in, and adding a second target to a project that **has never once compiled** would
stack an unverifiable change on an unverified base. Xcode's template generates it correctly in
about thirty seconds. That is a better trade than me guessing at it.

The App Group is the part worth doing early either way: it changes where the store file lives,
so moving it after there is study data to migrate is meaningfully harder than moving it now.

## 1. Create the target

**File ▸ New ▸ Target ▸ Widget Extension.** Name it `VocabLoopWidgets`. Uncheck
*Include Live Activity* and *Include Configuration App Intent* — the intents already exist.

## 2. Add the App Group

A widget runs in its own process and cannot read the app's container, so both need to share one.

- **VocabLoop target ▸ Signing & Capabilities ▸ + Capability ▸ App Groups**
- **VocabLoopWidgets target ▸** same
- Add `group.com.vocabloop.app` to both.

Then point the store at it — `PersistenceController.storeURL` currently returns
Application Support:

```swift
public static var storeURL: URL {
    // A widget runs in a separate process, so the store has to live somewhere both can
    // reach. Falls back to Application Support when the App Group is not configured, so
    // the app still runs without the capability.
    let base = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: "group.com.vocabloop.app")
        ?? URL.applicationSupportDirectory
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appending(path: "VocabLoop.store")
}
```

The fallback matters: without it, a build with no App Group capability would fail to open a
store at all rather than degrading.

**If you already have study data on a device**, copy `VocabLoop.store`, `-wal` and `-shm` from
Application Support into the group container before first launch, or that data becomes
invisible. On a fresh install there is nothing to move.

## 3. Add these files to the widget target

Membership matters: the widget target needs the model layer and the services, not the views.
Add `VocabLoop/Core/**` and `VocabLoop/DesignSystem/Palette.swift` to
**VocabLoopWidgets ▸ Build Phases ▸ Compile Sources**, and the seed packs to its
**Copy Bundle Resources** only if you want the widget to survive a first launch before the app
has imported content (you probably do not — an empty widget on first install is fine).

```swift
import WidgetKit
import SwiftUI
import SwiftData
import AppIntents

struct DueSnapshot: TimelineEntry {
    let date: Date
    let dueNow: Int
    let reviewsToday: Int
    let dailyGoal: Int
    let streak: Int
    /// nil when the app has never launched, so the widget can say so instead of showing zeros.
    let hasData: Bool

    static let placeholder = DueSnapshot(
        date: .now, dueNow: 12, reviewsToday: 8, dailyGoal: 30, streak: 24, hasData: true
    )
}

struct DueProvider: TimelineProvider {
    func placeholder(in context: Context) -> DueSnapshot { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (DueSnapshot) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DueSnapshot>) -> Void) {
        // Refreshing every 30 minutes rather than on a due-date boundary: WidgetKit budgets
        // refreshes, and a due count that is half an hour stale is not misleading. Scheduling
        // one per card's due date would exhaust the budget by mid-morning.
        let next = Date().addingTimeInterval(30 * 60)
        completion(Timeline(entries: [load()], policy: .after(next)))
    }

    @MainActor
    private func load() -> DueSnapshot {
        guard
            let container = try? PersistenceController.makeContainer(),
            let account = try? ModelContext(container).activeAccount(),
            let preferences = account.preferences
        else {
            return DueSnapshot(date: .now, dueNow: 0, reviewsToday: 0, dailyGoal: 0,
                               streak: 0, hasData: false)
        }
        let context = ModelContext(container)
        let stats = (try? StatsService(context: context)
            .statistics(for: account, preferences: preferences)) ?? .empty

        return DueSnapshot(
            date: .now,
            dueNow: stats.dueNow,
            reviewsToday: stats.reviewsToday,
            dailyGoal: preferences.dailyGoal,
            streak: stats.currentStreak,
            hasData: true
        )
    }
}

struct DueWidgetView: View {
    var entry: DueSnapshot
    @Environment(\.widgetFamily) private var family

    private var progress: Double {
        guard entry.dailyGoal > 0 else { return 0 }
        return min(Double(entry.reviewsToday) / Double(entry.dailyGoal), 1)
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: progress) {
                Text("\(entry.dueNow)").font(.system(.body, design: .rounded, weight: .bold))
            }
            .gaugeStyle(.accessoryCircularCapacity)

        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(entry.dueNow)")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .contentTransition(.numericText())
                    Text(entry.dueNow == 1 ? "due" : "due")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if entry.streak > 0 {
                        Label("\(entry.streak)", systemImage: "flame.fill")
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(Palette.brandSecondary)
                            .labelStyle(.titleAndIcon)
                    }
                }

                if !entry.hasData {
                    Text("Open VocabLoop to get started")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                } else if entry.dueNow == 0 {
                    Text("All caught up")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    // The intent is already written; the widget just calls it.
                    Button(intent: StartReviewIntent()) {
                        Text("Review")
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.brandPrimary)
                }

                Spacer(minLength: 0)

                if entry.hasData, entry.dailyGoal > 0 {
                    ProgressView(value: progress)
                        .tint(Palette.brandPrimary)
                    Text("\(entry.reviewsToday) of \(entry.dailyGoal) today")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct DueWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.vocabloop.due", provider: DueProvider()) { entry in
            DueWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Reviews due")
        .description("How many words are waiting, and today's progress.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

@main
struct VocabLoopWidgetBundle: WidgetBundle {
    var body: some Widget { DueWidget() }
}
```

## 4. Refresh it when the count changes

Add to `ReviewService.grade`, after the save:

```swift
#if canImport(WidgetKit)
// Cheap, and the alternative is a widget that lies until its next scheduled refresh.
WidgetCenter.shared.reloadTimelines(ofKind: "com.vocabloop.due")
#endif
```

## What this gets you

One `StartReviewIntent` now drives: the Shortcuts app, Siri, the home-screen widget button,
a Lock Screen accessory, and — with no extra code — a Control Centre control if you add a
`ControlWidget`. That is the whole reason the intents were written before the widget.

## Caveats worth knowing

- **App Groups need a provisioning capability**, like Sign in with Apple. A free Apple ID
  cannot use one, so `xcodebuild` in CI must keep working through the Application Support
  fallback — do not remove it.
- **Two processes, one SQLite file.** SwiftData handles the locking, but the widget should only
  ever read. A widget that writes will eventually contend with a review session.
- **`.accessoryCircular` has no colour**, only a tint mask. The gauge above is deliberately
  shape-only rather than relying on `brandPrimary`.
