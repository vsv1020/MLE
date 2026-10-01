# The widgets and the Live Activity

**Status (1.0.8): built.** The decision record and the full design — families, states, copy,
the project-file objects, signing and CI — is **[`docs/WIDGET-PLAN.md`](WIDGET-PLAN.md)**. It
supersedes the "do it in Xcode" guidance this file used to carry: there is no Xcode where this
project is written, so the extension target was added to `project.pbxproj` by hand and CI is
the compiler. This page is the short map.

## Where things are

| Path | What |
|---|---|
| `VocabLoopShared/` | Compiled into **both** the app and the extension (a synchronized folder listed in both targets). The snapshot file types, the design system Mochi is drawn with, `WidgetTimelinePlanner`, `WidgetCopy`, `StudyActivityAttributes`, `StudyActivityPolicy`/`StudyActivityCopy`. Nothing here imports SwiftData. |
| `VocabLoopWidgets/` | The extension: `TodayWidget` (small, medium, three Lock Screen families), `MochiWidget`, `StudyLiveActivity` (Lock Screen + Dynamic Island). |
| `VocabLoop/Core/Services/StudyActivityController.swift` | App-only: requests, updates and ends the Live Activity. |
| `Config/VocabLoopWidgets-Info.plist`, `Config/VocabLoopWidgets.entitlements` | Extension point and App Group. |

## The design: the widget reads a snapshot file, never the store

A widget runs in a second process. **It must never open the SwiftData store** — two processes
on one SQLite file is how stores get corrupted, and opening it would also mean moving the store
into the App Group container, a migration for every existing user. Instead:

- `WidgetSnapshotWriter` writes `widget-snapshot.json`, atomically, into
  `SharedStorage.containerURL` — the App Group container `group.com.vocabloop.app`, or
  Application Support when the group is missing (a `VL_WIDGETS=off` build), exactly as 1.0.7.
- `EngagementService.writeWidgetSnapshot(preferences:now:)` builds it after every graded review
  and when the study screen goes to the background, then calls
  `WidgetCenter.shared.reloadAllTimelines()`. Failures are logged and swallowed.
- The store stays where it always was. No user data moves.

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
| `dayEndsAt` | *1.0.8, optional.* End of the current study day — the widget's rollover moment |
| `dueTomorrow` | *1.0.8, optional.* `dueNow` evaluated at the end of the next study day |

Files written by 1.0.7 have neither optional field and still decode; they simply never roll over.

## Shipping without the extension

If release signing fails on the App Group, run the release with `widgets: off` (or set the
repository variable `VL_WIDGETS=off`). `scripts/strip-widget-target.py` unhooks the extension
from the app target and the App Group entitlement is removed for that archive; nothing in the
code changes. See `docs/WIDGET-PLAN.md` §3 and the header of `.github/workflows/release.yml`
for the owner's one-time App Group steps.
