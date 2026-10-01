# 1.0.8 — Home Screen widgets, Lock Screen widgets and a Live Activity

Status: plan, decided. One developer implements it in the order of §4. Sharing is a separate
workstream (`docs/SHARING-PLAN.md`) with disjoint file ownership. Supersedes the "do it in
Xcode" guidance in `docs/WIDGET.md`: there is no Xcode here, so the project file is hand-edited
and CI is the compiler, as it has been for everything else.

Non-negotiables carried over: the widget process never opens the SwiftData store (it reads
`widget-snapshot.json` from the App Group container); Live Activity state is pushed locally with
ActivityKit (no push server); kids audience, no guilt copy; Reduce Motion honoured; offline.

## 1. Product

### 1.1 Widgets (one extension, two kinds)

**`TodayWidget`** — kind `com.vocabloop.today`, display name "Today", families
`systemSmall`, `systemMedium`, `accessoryCircular`, `accessoryRectangular`, `accessoryInline`.
Everything shown comes from `WidgetSnapshot` (fields: `dueNow, reviewsToday, dailyGoal, streak,
studiedToday, mochiLevel, candy, bodyColor, accessories, updatedAt`) plus two additive optional
fields added in this release: `dayEndsAt: Date?` (end of the current 4am study day, from
`StudyCalendar.dayEnd(for: now)`) and `dueTomorrow: Int?` (graded cards due by `dayEndsAt + 1 day`,
same rule as `dueNow`). Old files without them still decode.

| Family | Content |
|---|---|
| systemSmall | Big `dueNow` + "due" (or "All caught up" + cheering Mochi when `dueNow == 0 && studiedToday`); streak chip top-right (flame grey until `studiedToday`, orange after, hidden when `streak == 0`); goal bar + "8 of 30 today" when `dailyGoal > 0`; small still Mochi (44pt) bottom-right. |
| systemMedium | Left: still Mochi 72pt + "Level N" capsule (`WidgetMochiView`). Right: the systemSmall numbers plus a "Start review" pill (visual only — the whole widget is one `widgetURL`). |
| accessoryCircular | `Gauge(value: goalProgress)` `.accessoryCircularCapacity` with `dueNow` in the centre; when `dailyGoal == 0`: flame + streak. Shape only, no colour (tinted rendering). |
| accessoryRectangular | Line 1 "VocabLoop", line 2 "12 due · 8/30 today" (or "12 due"), line 3 flame label "7-day streak" (hidden at 0). |
| accessoryInline | "12 words due · 7-day streak" / "All caught up" / "Open VocabLoop". |

States: **no snapshot** (never written, or the App Group is missing) → "Open VocabLoop to get
started" + curious Mochi. **Stale** (`now > updatedAt + 48h`) → sleepy Mochi, "Mochi is waiting
for you", no numbers (they would be wrong). **New day** (`now ≥ dayEndsAt`) → `reviewsToday = 0`,
`studiedToday = false`, `dueNow = dueTomorrow ?? dueNow`, streak unchanged (grey flame). Copy never
counts what did not happen: no "missed", "only", "0 left".

**`MochiWidget`** — kind `com.vocabloop.mochi`, `systemSmall` only. Large still Mochi from
`bodyColor/accessories/mochiLevel`, "Level N" capsule, "640 ⭐". Mood: `.cheer` when the goal is met,
`.happy` when `studiedToday`, `.curious` otherwise, `.sleepy` when stale. Tap → `vocabloop://mochi`.

**Deep links.** New URL scheme `vocabloop` (Config/Info.plist). `VocabLoopApp` gets
`.onOpenURL` → `IntentLaunchRequest.shared.pendingAction = .startReview` (`vocabloop://study`, and
any unknown path) or the new `.showMochi` (`vocabloop://mochi`). `StudySessionView.consumeIntentRequest`
already consumes `.startReview`; add `.showMochi` → `isShowingMochi = true`. No `AppIntent` buttons in
the widget (keeps `VocabLoopIntents.swift` and SwiftData out of the extension).

**Refresh policy.** The file only changes when the app writes it, so time-driven refreshes exist only
for the day rollover and the stale cut-off. `WidgetTimelinePlanner.plan(snapshot:now:)` (pure,
shared, unit-tested) returns entries `[now, dayEndsAt?, updatedAt + 48h?]` (future ones only,
sorted) and `reloadAfter` = the last entry's date when there are ≥2 entries, else `now + 6h`
(safety net re-read). Provider uses `Timeline(entries:policy: .after(reloadAfter))`.
`EngagementService.writeWidgetSnapshot` calls `WidgetCenter.shared.reloadAllTimelines()` right after
`snapshots.write(...)` — the one place the file changes (after every graded review and when the study
screen backgrounds). Budget: WidgetKit's daily reload budget governs the timeline's own refreshes;
app-initiated `WidgetCenter` reloads are coalesced and treated more leniently, but a 100-review session
is still 100 calls. Ship it plain; if the widget visibly lags after a long session, debounce in
`writeWidgetSnapshot` (at most one reload per 10 s, plus one on background) — not needed on day one.

### 1.2 Live Activity ("study session" with Dynamic Island)

**Starts** when `StudyViewModel.start` lands in `.reviewing` with a non-empty queue (root or
deck-scoped session), *and* `ActivityAuthorizationInfo().areActivitiesEnabled`, *and* the Settings
toggle is on. One activity at a time; a second `start` while one exists updates it.

**Attributes** (fixed for the activity): `mochiLevel`, `bodyColor`, `accessories`, `dailyGoal`,
`startedAt`. **ContentState**: `reviewsToday`, `combo`, `streak`, `studiedToday`, `phase`
(`studying | goalReached | finished | resting`), `updatedAt`.

| Presentation | Shows |
|---|---|
| Lock Screen / banner (≤160pt) | Still Mochi 56pt left; "VocabLoop" caption; "12 of 30 today" + progress bar (or "12 reviews today" when no goal); chips: combo "×5" (shown at ≥3), flame + streak. Bottom line from `StudyActivityCopy`. `.widgetURL(vocabloop://study)`. |
| DI compact leading | circular goal ring (`ProgressView` circular, 20pt), or a star when no goal. |
| DI compact trailing | "12/30" monospaced digits (or "12 ✓"); while `combo ≥ 3`: "×5". |
| DI minimal | the ring alone. |
| DI expanded | leading: Mochi 44pt; center: "12 of 30 today" + bar; trailing: combo chip and flame; bottom: copy line. |

Copy (pure `StudyActivityCopy.line(for:)`, tested): studying → "Keep going — Mochi is cheering";
`goalReached` → "Daily goal done ⭐"; `finished` → "All done for now"; `resting` → "See you
tomorrow"; stale → "Tap to pick up where you left off". Never "x missed".

**Updates**: after every grade (`StudyViewModel.grade` → after `recordEngagement`), on
`goalReached`, on `continueAfterGoal` (back to `studying`), and on undo (combo/counts restored).
Each update sets `staleDate = now + 30 min`. **Ends**: queue empty (`phase == .finished`) → final
state `finished`, `dismissalPolicy: .after(now + 10 min)`; "Done for today" → `resting`,
`.after(now + 15 min)` — wired in `StudySessionView`'s `onDone` closure, never inside
`GoalCompleteView` (the sharing workstream owns that file); leaving the study screen (sheet dismiss / "End session") →
`.after(now + 5 min)`; app launch → `endAllImmediately()` for anything a previous process left
behind; toggle switched off → immediate. App backgrounded mid-session: nothing is ended (the glance
is the point); the 30-min `staleDate` shows the stale copy, and on the next `.active` a stale activity
is ended immediately and re-requested at the next grade. iOS ends everything after 8h anyway.

**Settings toggle**: `PresentationSettingsView`, in the Haptic/Sound section:
`Toggle("Show progress on Lock Screen")`, footer "Shows today's goal in the Dynamic Island and on the
Lock Screen while you study." Backed by `@AppStorage("liveActivity.enabled")` (default `true`; device
setting, not a schema change). **Reduce Motion**: no `.contentTransition(.numericText())`, no
animated bar; views read `accessibilityReduceMotion`. Widgets never animate; `Mascot(...).still()`.

## 2. Project file plan

### 2.1 Code layout and what is shared

Shared code is a new synchronized folder **`VocabLoopShared/`** listed in `fileSystemSynchronizedGroups`
of *both* the app and the extension (that is how Xcode 16 serialises multi-target membership of a
synchronized folder). Files move with `git mv`, names unchanged, no pbxproj edits per file. Minimal
closure, nothing imports SwiftData:

| Move to `VocabLoopShared/` | Why |
|---|---|
| `Core/Services/WidgetSnapshotWriter.swift` | `SharedStorage`, `WidgetSnapshot`, writer/reader |
| `Core/Engagement/MochiWardrobe.swift` | `MochiStage/Accessory/BodyColor/Look` — **after** splitting out `unlockAchievement` and `requiresPlus` into app-only `VocabLoop/Core/Engagement/MochiWardrobe+Unlocks.swift` (they pull `AchievementID` → `EngagementProfile` and `PlusCatalog` → `Deck`). Add `MochiStage.init(level:)` here; `RewardEngine.stage(forLevel:)` delegates to it. |
| `Core/SRS/Rating.swift` | Foundation-only; `MascotAccessories` colours via `Palette.rating(_:)` |
| `DesignSystem/Palette.swift` | **after** moving `maturity(_:)` (needs `CardMaturity`) into app-only `DesignSystem/Palette+Maturity.swift` |
| `DesignSystem/Typography.swift`, `Motion.swift`, `Crayon.swift`, `Mascot.swift`, `MascotAccessories.swift` | pure SwiftUI tokens and drawing (`Haptics` appears in a Mascot doc comment only) |
| `Features/Recap/WidgetMochiView.swift` | the widget body |

New shared files: `StudyActivityAttributes.swift` (`import ActivityKit`), `WidgetTimelinePlanner.swift`
(Foundation), `StudyActivityPolicy.swift` (pure state mapping + lifecycle decisions + `StudyActivityCopy`),
`MochiLook+Snapshot.swift` (`MochiLook(snapshot:)`). Everything in the folder compiles into the app
module too, so `@testable import VocabLoop` tests cover it and `PaletteContrastTests` are untouched.

Extension sources in **`VocabLoopWidgets/`**: `VocabLoopWidgetsBundle.swift` (`@main WidgetBundle`:
`TodayWidget`, `MochiWidget`, `StudyLiveActivity`), `TodayWidget.swift` (provider + family views),
`MochiWidget.swift`, `StudyLiveActivity.swift` (`ActivityConfiguration` + DI), `WidgetParts.swift`
(goal ring, streak chip, `containerBackground(Palette.canvas, for: .widget)`), `PrivacyInfo.xcprivacy`
(empty arrays). No asset catalog. The provider reads `WidgetSnapshotWriter().read()`; in the extension
`SharedStorage.containerURL` resolves to the group container, and without the entitlement it falls
back to the extension's own empty Application Support → the "Open VocabLoop" state, never a crash.

App-only new/changed: `Core/Services/StudyActivityController.swift` (`@MainActor final class`,
owns the `Activity<StudyActivityAttributes>?`, swallows every ActivityKit error, exposes
`begin/update/end/endAllImmediately`, `isEnabled` from the defaults key; injected as
`AppDependencies.liveActivity`); `EngagementService` (two snapshot fields, `WidgetCenter` reload);
`StudyViewModel` + `StudySessionView` (hooks in §1.2); `VocabLoopApp` (`onOpenURL`);
`IntentLaunchRequest.Action.showMochi`; `SettingsView` (toggle, only the `PresentationSettingsView`
struct); `AppDependencies.bootstrap` (`endAllImmediately`); `PrivacyInfo.xcprivacy` comment
(CA92.1 still correct: the app's defaults are not in the group).

### 2.2 Config files

- `Config/Info.plist` (app): add `NSSupportsLiveActivities` = true; `CFBundleURLTypes` =
  `[{CFBundleURLName: com.vocabloop.app, CFBundleURLSchemes: [vocabloop]}]`.
- `Config/VocabLoop.entitlements`: add `com.apple.security.application-groups` = `[group.com.vocabloop.app]`
  (keep `applesignin`).
- `Config/VocabLoopWidgets.entitlements` (new): only `com.apple.security.application-groups` = `[group.com.vocabloop.app]`.
- `Config/VocabLoopWidgets-Info.plist` (new): `NSExtension` → `NSExtensionPointIdentifier` =
  `com.apple.widgetkit-extension`. Merged with the generated keys because `GENERATE_INFOPLIST_FILE = YES`
  (exactly what Xcode's template does). Kept in `Config/` so the synchronized folder never treats it as a resource.

### 2.3 `project.pbxproj` objects (IDs continue the existing `1A2B3C…` scheme; last used is `31`)

```
PBXFileReference
  …40  VocabLoopWidgets.appex   explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = VocabLoopWidgets.appex; sourceTree = BUILT_PRODUCTS_DIR;
  …41  WidgetKit.framework      lastKnownFileType = wrapper.framework; name = WidgetKit.framework; path = System/Library/Frameworks/WidgetKit.framework; sourceTree = SDKROOT;
  …42  SwiftUI.framework        same shape, path = System/Library/Frameworks/SwiftUI.framework;
PBXBuildFile
  …43  WidgetKit.framework in Frameworks   fileRef = …41
  …44  SwiftUI.framework in Frameworks     fileRef = …42
  …45  VocabLoopWidgets.appex in Embed Foundation Extensions   fileRef = …40; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); };
PBXFileSystemSynchronizedRootGroup
  …46  VocabLoopWidgets   path = VocabLoopWidgets; sourceTree = "<group>";
  …4C  VocabLoopShared    path = VocabLoopShared;  sourceTree = "<group>";
PBXNativeTarget …47 VocabLoopWidgets
  buildConfigurationList = …48; buildPhases = (…49 Sources, …4A Frameworks, …4B Resources); buildRules = (); dependencies = ();
  fileSystemSynchronizedGroups = (…46, …4C); name = productName = VocabLoopWidgets; productReference = …40;
  productType = "com.apple.product-type.app-extension";
PBXSourcesBuildPhase …49, PBXResourcesBuildPhase …4B: files = (); PBXFrameworksBuildPhase …4A: files = (…43, …44);
PBXCopyFilesBuildPhase …4F "Embed Foundation Extensions"
  buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = (…45); name = "Embed Foundation Extensions"; runOnlyForDeploymentPostprocessing = 0;
PBXTargetDependency …50   target = …47; targetProxy = …51;
PBXContainerItemProxy …51 containerPortal = …01; proxyType = 1; remoteGlobalIDString = …47; remoteInfo = VocabLoopWidgets;
XCConfigurationList …48   buildConfigurations = (…4D Debug, …4E Release); defaultConfigurationName = Release;
XCBuildConfiguration …4D / …4E  (identical except name)
  ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;  CODE_SIGN_ENTITLEMENTS = Config/VocabLoopWidgets.entitlements;
  CODE_SIGN_STYLE = Automatic;  CURRENT_PROJECT_VERSION = 1;  GENERATE_INFOPLIST_FILE = YES;
  INFOPLIST_FILE = Config/VocabLoopWidgets-Info.plist;  INFOPLIST_KEY_CFBundleDisplayName = VocabLoop;
  INFOPLIST_KEY_NSHumanReadableCopyright = "";  IPHONEOS_DEPLOYMENT_TARGET = 17.0;
  LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks");
  MARKETING_VERSION = 1.0;  PRODUCT_BUNDLE_IDENTIFIER = com.vocabloop.app.widgets;  PRODUCT_NAME = "$(TARGET_NAME)";
  SKIP_INSTALL = YES;  SWIFT_EMIT_LOC_STRINGS = YES;  TARGETED_DEVICE_FAMILY = "1,2";
  (SWIFT_VERSION 5.0, SDKROOT, strict concurrency inherited from the project configuration)
Edits to existing objects
  app target …04: buildPhases += …4F (after Resources); dependencies += …50; fileSystemSynchronizedGroups += …4C
  main group …02: children += …46, …4C (before Products);  Products …03: children += …40
  PBXProject …01: targets += …47; TargetAttributes[…47] = { CreatedOnToolsVersion = 16.0; }
```

Version numbers: `release.yml` passes `CURRENT_PROJECT_VERSION`/`MARKETING_VERSION` on the command
line, which applies to every target, so app and extension always match (App Store requires it).
`DEVELOPMENT_TEAM` likewise. **Scheme: no change** — the app target now depends on the extension, so
`xcodebuild test -scheme VocabLoop` and `archive` build and embed it. The simulator build with
`CODE_SIGNING_ALLOWED=NO` is fine for an `.appex`.

## 3. CI and release

### 3.1 What automatic signing can and cannot do from CI (decision)

`-allowProvisioningUpdates` with the ASC API key already registers App IDs, creates development and
(cloud-managed) distribution certificates and profiles — 1.0.7 shipped that way with the Sign in with
Apple entitlement. It will register `com.vocabloop.app.widgets` and build profiles for it. What it
cannot be relied on for is **App Groups**: the group identifier `group.com.vocabloop.app` is a separate
portal resource with no public App Store Connect API endpoint (the API has `bundleIds` and
`bundleIdCapabilities` — `APP_GROUPS` can be *enabled* on an App ID, but a group cannot be *created* or
*assigned* to it; fastlane's `produce group` does this through the unofficial portal API with an Apple
ID login, which CI must not use). Xcode Cloud's own documentation lists App Groups among the
capabilities that must be configured in the portal by hand. So:

**Owner does once, in developer.apple.com ▸ Certificates, Identifiers & Profiles ▸ Identifiers (≈3 min):**
1. `+` ▸ App Groups ▸ register `group.com.vocabloop.app` (description "VocabLoop").
2. App IDs ▸ `com.vocabloop.app` ▸ App Groups ▸ enable ▸ Configure ▸ tick the group ▸ Save.
3. `+` ▸ App IDs ▸ App ▸ explicit `com.vocabloop.app.widgets` ("VocabLoop Widgets") ▸ App Groups ▸ Configure ▸ tick the group ▸ Register.
   (Step 3 may be skipped: the CI script below registers the App ID and enables the capability; only the
   tick in Configure cannot be scripted — if skipped, do step 3's Configure after the first CI run.)
Editing an App ID's capabilities invalidates its existing profiles; CI regenerates them on every run anyway.

**CI script `scripts/asc-provision.mjs`** (Node, same ES256 JWT + `api()` helpers as
`asc-certificates.mjs`; env `ASC_KEY_ID, ASC_ISSUER_ID, KEY_PATH, APP_BUNDLE_ID, EXT_BUNDLE_ID, APP_GROUP`):
`GET /v1/bundleIds?filter[identifier]=…&include=bundleIdCapabilities` for both IDs (match
`attributes.identifier` exactly — the filter is a prefix match); `POST /v1/bundleIds`
`{identifier, name: "VocabLoop Widgets", platform: "IOS"}` when the extension ID is missing;
`POST /v1/bundleIdCapabilities` `{capabilityType: "APP_GROUPS", relationships.bundleId}` for any of the
two lacking it (409 = already there). Prints a table; exits non-zero only when a bundle ID is still missing
or `APP_GROUPS` could not be enabled, with the owner checklist above in the error. It cannot verify the
group assignment, and says so. Idempotent, ~2 s, runs before any Xcode step so a failure costs no macOS minutes.

### 3.2 `release.yml`

- `workflow_dispatch.inputs.widgets`: choice `on|off`, default `on`. Job env
  `VL_WIDGETS: ${{ github.event.inputs.widgets || vars.VL_WIDGETS || 'on' }}` (repository variable for tag/RELEASE pushes).
- New step after "Install API key", `if: env.VL_WIDGETS == 'on'`: "Provision extension App ID" → `node scripts/asc-provision.mjs`.
- New step before "Archive", `if: env.VL_WIDGETS == 'off'`: "Ship without widgets" →
  `python3 scripts/strip-widget-target.py` then `plutil -remove com.apple.security.application-groups Config/VocabLoop.entitlements`.
- Archive/export commands unchanged (automatic signing + API key provisions the extension's profiles;
  `app-store-connect` export with `signingStyle automatic` signs embedded extensions). Extend the archive
  grep to `error:|Provisioning|entitlement|\*\* ARCHIVE` so signing failures are visible in the step log.
- Header comment: add the owner's one-time App Group steps next to the existing setup list.

`scripts/strip-widget-target.py` (stdlib, ~40 lines): deletes exactly two lines from `project.pbxproj` —
`…50 /* PBXTargetDependency */,` in the app target's `dependencies` and
`…4F /* Embed Foundation Extensions */,` in its `buildPhases` — and fails if either is not found exactly
once. The extension target stays defined but unbuilt, the app archives without an `.appex`, and with the
group entitlement removed `SharedStorage` falls back to Application Support exactly as 1.0.7. `--check`
mode (dry run, used by `ios.yml`) proves the two anchors exist.

### 3.3 `ios.yml`

- `content` job (Ubuntu, seconds): add "Project file sanity": a Python step that collects every
  24-hex object ID in `project.pbxproj`, asserts each ID that is referenced also has a definition line
  (`^\s*ID /\*…\*/ = {`), asserts `preferredProjectObjectVersion = 77` is unchanged, and runs
  `python3 scripts/strip-widget-target.py --check`. This catches the dangling-reference class of hand-edit
  mistakes before a 10x-billed macOS minute is spent.
- `build-test` job: no command changes. `-list` will show four targets; `xcodebuild test` builds the
  extension for the simulator as an app dependency with `CODE_SIGNING_ALLOWED=NO`.
- ExportOptions: unchanged.

## 4. Implementation order, ownership, tests, risks

One developer, two commits so the second can be reverted alone:

**Commit A — shared folder + app-side features (must be green on its own).**
1. `git mv` the files in §2.1 into `VocabLoopShared/`; create `MochiWardrobe+Unlocks.swift` and `Palette+Maturity.swift`; `MochiStage.init(level:)`; `RewardEngine.stage(forLevel:)` delegates.
2. pbxproj: add group `…4C` to the main group and to the app target's `fileSystemSynchronizedGroups` (nothing else yet).
3. `WidgetSnapshot` + `dayEndsAt`/`dueTomorrow` (optional, defaulted init params so `WidgetSnapshotTests` compile); `EngagementService.writeWidgetSnapshot` fills them and calls `WidgetCenter.shared.reloadAllTimelines()`.
4. `WidgetTimelinePlanner`, `StudyActivityAttributes`, `StudyActivityPolicy` + `StudyActivityCopy`, `MochiLook(snapshot:)`.
5. `StudyActivityController`, `AppDependencies.liveActivity`, hooks in `StudyViewModel`/`StudySessionView`, Settings toggle, `onOpenURL` + `.showMochi`, `Config/Info.plist` URL scheme.
6. Tests (below). Push with `[full ci]`.

**Commit B — the extension target, signing, CI.**
7. pbxproj objects of §2.3 (except `…4C`, already there); `Config/VocabLoopWidgets-Info.plist`, both entitlements files, `NSSupportsLiveActivities`.
8. `VocabLoopWidgets/` sources; `PrivacyInfo.xcprivacy`.
9. `scripts/asc-provision.mjs`, `scripts/strip-widget-target.py`, `ios.yml` sanity step, `release.yml` steps. Push with `[full ci]`; then a `workflow_dispatch` release to TestFlight.
10. Update `docs/WIDGET.md` to point here; `README` "Not built yet" loses the widget bullet; `RELEASE` → 1.0.8 notes.

**Tests (`VocabLoopTests`, all pure, no ActivityKit calls):**
- `WidgetTimelinePlannerTests`: nil snapshot → one entry, reload at +6h; fresh snapshot with `dayEndsAt` →
  entries `[now, dayEndsAt, updatedAt+48h]` sorted, new-day entry has `reviewsToday 0`, `studiedToday false`,
  `dueNow == dueTomorrow`; past `dayEndsAt` → not emitted; stale snapshot → `isStale`; DST day (reuse
  `StudyCalendarTests` fixtures) — rollover is taken from the file, never recomputed in the widget.
- `WidgetSnapshotTests` (+2): a 1.0.7 JSON fixture without the new keys decodes; new fields round-trip.
- `StudyActivityPolicyTests`: `shouldStart` truth table (settings off / system off / empty queue);
  state mapping from (`reviewsToday`, goal, combo, streak, phase); `staleDate = +30 min`; dismissal per
  phase (`finished` +10, `resting` +15, `left` +5); copy lines contain none of "missed|only|failed|0 left".
- `MochiLookSnapshotTests`: unknown `bodyColor`/accessory raw values degrade to vanilla / dropped.
- `RewardEngineTests` unchanged and still pass (delegation). `PaletteContrastTests` unchanged.
- UI tests untouched: the tab labels, launch arguments and root session are not changed; the Live Activity
  request on the simulator shows nothing XCUITest can see and the controller never throws.

**Risks and mitigations**
| Risk | Mitigation |
|---|---|
| Multi-target synchronized folder serialised wrongly → "cannot find Palette in scope" in the extension | Caught by the first `[full ci]` of commit B. Fallback: turn `VocabLoopShared/` into a local Swift package (`Package.swift`, one target, `XCLocalSwiftPackageReference` + `XCSwiftPackageProductDependency` in both targets; the moved types are already `public`, app files add `import VocabLoopShared`). |
| A moved file still references something app-only (compile error in the extension only) | The closure in §2.1 was traced by grep; anything missed is a one-line split into an `+App.swift` extension file, never a reverse move. |
| App Group not assigned in the portal → archive fails on "doesn't match the entitlements … application-groups" | Owner checklist §3.1; the archive log grep surfaces the exact message; `VL_WIDGETS=off` ships meanwhile. |
| ASC API refuses `APP_GROUPS` without settings | Script treats 409/422 on capability creation as non-fatal and prints the manual step; Xcode's own provisioning may still add it. |
| WidgetKit reload budget | One reload per snapshot write; debounce only if observed. |
| Live Activity never ends when the app is killed mid-session | `staleDate` 30 min, iOS 8-hour cap, `endAllImmediately()` at next launch. |
| UI test flakiness from the new `.onOpenURL`/activity code | Both are inert without a URL / a real session; no new alerts or sheets at launch. |
| `INFOPLIST_FILE` + `GENERATE_INFOPLIST_FILE` merge | Same arrangement the app target uses today. |

**Rollback if release signing fails (app must still ship):** set repository variable `VL_WIDGETS=off`
(or dispatch with `widgets: off`) and re-run — no code change, same commit, the archive has no
extension and no App Group entitlement; the app's `SharedStorage` fallback keeps writing the
snapshot to Application Support; `StudyActivityController` finds `areActivitiesEnabled` true but the
request has nothing to render and is swallowed. If the strip path itself is broken, `git revert`
commit B (commit A compiles alone and ships 1.0.8's app-side changes). Nothing in either path touches
user data: the store never moves.

Done means: `[full ci]` green on both commits; TestFlight build installs; Today widget shows live
numbers after one review; Lock Screen widgets render in tinted mode; Live Activity appears on session
start, counts up, celebrates the goal, and is gone 10 min after the summary; `VL_WIDGETS=off`
produces an installable build with no widget gallery entry.
