# Adding the widget

**Status (1.0.7): the data path ships, the widget target does not.** See
`docs/ENGAGEMENT-PLAN.md` §1.12 for the decision. The App Intents are done and live in the app
target (`VocabLoop/Core/Intents/`), so Siri, Shortcuts and Spotlight work now. Since 1.0.7 the
app also writes everything a widget shows to a small JSON file after every graded review. What
remains for 1.0.8 is project plumbing that has to be done in Xcode: a second target, an App
Group, and the widget's SwiftUI.

## Why this step is done in Xcode

A Widget Extension is a whole target — its own build phases, Info.plist, entitlements and
embed step. `project.pbxproj` is hand-written because there is no Xcode in the environment this
is built in, and a second `PBXNativeTarget` with synchronized-group exceptions, an embed phase
and App Group entitlements cannot be verified without one. It also changes signing for
`distribute.yml` and `release.yml`. Xcode's template generates it correctly in about thirty
seconds.

## The design: the widget reads a snapshot file, never the store

A widget runs in a second process. **It must never open the SwiftData store** — two processes
on one SQLite file is how stores get corrupted, and opening it would also mean moving the store
into the App Group container, a migration for every existing user. Instead:

- `WidgetSnapshotWriter` (`VocabLoop/Core/Services/WidgetSnapshotWriter.swift`) writes
  `widget-snapshot.json`, atomically, into `SharedStorage.containerURL`.
- `SharedStorage.containerURL` is the App Group container (`group.com.vocabloop.app`) when the
  capability exists and Application Support otherwise. 1.0.7 has no App Group, so the file lives
  in Application Support; the day the entitlement lands, the same code writes where the widget
  can read, with nothing else to change.
- `EngagementService.writeWidgetSnapshot(preferences:now:)` builds the snapshot. It runs after
  every graded review (inside `EngagementService.record`) and when the study screen goes to the
  background. Failures are logged and swallowed: a stale widget is better than an interrupted
  session.
- Deleting an account removes the file (`LocalAuthBackend.deleteAccount`); the guest left
  behind writes a fresh one on its first review.

The file (`WidgetSnapshot`, `Codable`, dates as seconds since 1970, keys sorted):

| Field | Meaning |
|---|---|
| `dueNow` | Graded cards due right now in the active language (same rule as Stats; new cards excluded) |
| `reviewsToday` | Reviews in today's study day |
| `dailyGoal` | The goal; `0` means no goal |
| `streak` | Current streak (today is neutral until it ends) |
| `studiedToday` | Whether today has a review yet — grey vs orange flame |
| `mochiLevel` | Mochi's level, derived from candy |
| `candy` | Lifetime star candy |
| `bodyColor` | `MochiBodyColor` raw value |
| `accessories` | `MochiAccessory` raw values currently worn |
| `updatedAt` | When the app wrote it |

`WidgetMochiView` (a plain SwiftUI view in the app target, used by the weekly recap card) is
the future widget body: it draws Mochi from `bodyColor`, `accessories` and `mochiLevel` alone.

## 1. Create the target

**File ▸ New ▸ Target ▸ Widget Extension.** Name it `VocabLoopWidgets`. Uncheck
*Include Live Activity* and *Include Configuration App Intent* — the intents already exist.

## 2. Add the App Group

The widget cannot read the app's container, so both need to share one.

- **VocabLoop target ▸ Signing & Capabilities ▸ + Capability ▸ App Groups**
- **VocabLoopWidgets target ▸** same
- Add `group.com.vocabloop.app` to both.

That is all: `SharedStorage.containerURL` starts resolving to the group container and the next
review writes the snapshot there. **Do not move `PersistenceController.storeURL`** — the store
stays in Application Support, where it is today, and no user data migrates.

The first launch after the update writes the file only after a review or a background; until
then the widget shows its "open VocabLoop" state, which is correct.

## 3. Add these files to the widget target

Membership is deliberately small — the widget needs the snapshot types, not the model layer:

- `VocabLoop/Core/Services/WidgetSnapshotWriter.swift` (`SharedStorage`, `WidgetSnapshot`,
  `WidgetSnapshotWriter`)
- `VocabLoop/Features/Recap/WidgetMochiView.swift` and what it draws with
  (`VocabLoop/Core/Engagement/MochiWardrobe.swift`, `VocabLoop/DesignSystem/Mascot.swift`,
  `VocabLoop/DesignSystem/MascotAccessories.swift`, `VocabLoop/DesignSystem/Palette.swift`) —
  check the compile errors Xcode reports and add the few helpers they name; none of them touch
  SwiftData
- `VocabLoop/Core/Intents/VocabLoopIntents.swift` only if the widget's button should run
  `StartReviewIntent` in-process; otherwise use `openAppWhenRun` via a `Link` to the app

```swift
import WidgetKit
import SwiftUI

struct DueEntry: TimelineEntry {
    let date: Date
    /// `nil` when the app has never written a snapshot, so the widget can say so instead of
    /// showing zeros.
    let snapshot: WidgetSnapshot?

    static let placeholder = DueEntry(
        date: .now,
        snapshot: WidgetSnapshot(
            dueNow: 12, reviewsToday: 8, dailyGoal: 30, streak: 24, studiedToday: true,
            mochiLevel: 6, candy: 640, bodyColor: "strawberry", accessories: ["redScarf"],
            updatedAt: .now
        )
    )
}

struct DueProvider: TimelineProvider {
    func placeholder(in context: Context) -> DueEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (DueEntry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DueEntry>) -> Void) {
        // Every 30 minutes rather than on due-date boundaries: WidgetKit budgets refreshes, and
        // the app reloads the timeline itself after each review (step 4).
        let next = Date().addingTimeInterval(30 * 60)
        completion(Timeline(entries: [load()], policy: .after(next)))
    }

    /// Reads the file the app wrote. Never opens the SwiftData store.
    private func load() -> DueEntry {
        DueEntry(date: .now, snapshot: WidgetSnapshotWriter().read())
    }
}

struct DueWidgetView: View {
    var entry: DueEntry
    @Environment(\.widgetFamily) private var family

    private var progress: Double {
        guard let s = entry.snapshot, s.dailyGoal > 0 else { return 0 }
        return min(Double(s.reviewsToday) / Double(s.dailyGoal), 1)
    }

    var body: some View {
        if let s = entry.snapshot {
            switch family {
            case .accessoryCircular:
                Gauge(value: progress) {
                    Text("\(s.dueNow)").font(.system(.body, design: .rounded, weight: .bold))
                }
                .gaugeStyle(.accessoryCircularCapacity)
            default:
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(s.dueNow)")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        Text("due")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if s.streak > 0 {
                            Label("\(s.streak)", systemImage: "flame.fill")
                                .font(.system(.caption, design: .rounded, weight: .semibold))
                                // Grey until today's first review, like the study screen.
                                .foregroundStyle(s.studiedToday ? Palette.brandSecondary : Palette.textTertiary)
                        }
                    }
                    Spacer(minLength: 0)
                    if s.dailyGoal > 0 {
                        ProgressView(value: progress).tint(Palette.brandPrimary)
                        Text("\(s.reviewsToday) of \(s.dailyGoal) today")
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        } else {
            Text("Open VocabLoop to get started")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
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

A medium family can add `WidgetMochiView` beside the numbers, built from `bodyColor`,
`accessories` and `mochiLevel`.

## 4. Refresh it when the snapshot changes

Add to `EngagementService.writeWidgetSnapshot`, after `snapshots.write(...)` — the one place the
file is written, so the widget reloads exactly when its data changed:

```swift
#if canImport(WidgetKit)
// Cheap, and the alternative is a widget that lies until its next scheduled refresh.
WidgetCenter.shared.reloadTimelines(ofKind: "com.vocabloop.due")
#endif
```

(with `import WidgetKit` at the top of that file).

## What this gets you

One `StartReviewIntent` drives the Shortcuts app, Siri, the home-screen widget button, a Lock
Screen accessory, and — with no extra code — a Control Centre control if you add a
`ControlWidget`. That is the whole reason the intents were written before the widget.

## Caveats worth knowing

- **App Groups need a provisioning capability**, like Sign in with Apple. A free Apple ID
  cannot use one, so `xcodebuild` in CI must keep working through the Application Support
  fallback in `SharedStorage.containerURL` — do not remove it.
- **The widget only reads.** The snapshot is the app's to write; a widget that wrote it would
  race a review session. The write is atomic, so a read mid-write sees the old file or the new
  one, never half.
- **Snapshot fields are additive.** The widget may ship a build behind the app; add new fields
  as optionals or with decoding defaults, never rename one.
- **`.accessoryCircular` has no colour**, only a tint mask. The gauge above is deliberately
  shape-only rather than relying on `brandPrimary`.
