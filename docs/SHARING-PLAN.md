# 1.0.8 — Sharing

Status: plan, decided. A separate workstream from `docs/WIDGET-PLAN.md`, written so one developer
can build it in parallel with the widget/Live Activity work without touching the same files (§6).
Owner's ask: "make sharing a real feature" — 1.0.7 has one share (the weekly recap); 1.0.8 turns
that into a system every celebratory moment can use.

## 1. What can be shared

Each card is a value type (`ShareCard` enum case with a small payload) rendered to a PNG by one
renderer. Only facts that are safe to leave the device go in: never a name, email, avatar, account
state, or user-typed text.

| Card | Payload (all pre-computed in the app, no store access at render time) | Headline (pure `ShareCopy`) | Where the button lives |
|---|---|---|---|
| `goalComplete` | reviewsToday, dailyGoal, streak, minutes, `MochiLook`, level | "Daily goal done — 30 words today" | `GoalCompleteView` (not while `isResting`), beside "See your week" |
| `streak` | streak, longest, `MochiLook`, level; offered at `streak ≥ 3` | "7 days in a row" | `StatsView.streakCard` ("Share my streak") |
| `badge` | `AchievementID`, name, detail, symbolName, unlockedAt (date only), `MochiLook` | "New badge: Night owl" | new `BadgeDetailSheet` opened by tapping an earned `BadgeTile` in `AchievementsView` |
| `mochi` | `MochiLook`, level, candy, stage name | "Meet my Mochi — level 6" | `MochiHomeView` toolbar (leading share icon); doubles as the level-up share: `MochiStatusCard` gets no button, the toast stays transient |
| `word` | headword, phonetic (if any), first sense definition, one example sentence, language code; **bundled entries only** (`entry.isUserCreated == false`) | "Today I learned *ubiquitous*" | `EntryDetailView` toolbar `ShareLink`, next to the existing `Menu` |
| `album` | album title, family title, level, page, sticker count, `MochiLook` | "Page complete — 12 shining stickers" | `AlbumGridView` "Page complete!" card |
| `week` | existing `WeeklyRecap` | existing `RecapCopy.headline` | `WeeklyRecapView` (unchanged behaviour, migrated to the shared renderer) |

Not shared: parent report (it stays behind the gate and on device), session summary without a goal
(nothing to celebrate yet is not a reason to post), Plus/purchase state.

## 2. Visual design

One `ShareCardFrame` wraps every card: 360×450 pt laid out at a fixed `dynamicTypeSize(.large)`,
rendered at 3× → **1080×1350** (4:5, uncropped in Messages/Instagram), **always light** (`Palette.canvas`
paper, `PaperGrain`, a `WobbleShape` crayon border seeded by the card kind, as `CardContainer(style:
.crayon)` draws today). Layout, top to bottom: eyebrow (sparkles + card-kind caption in
`Palette.brandSecondary`), headline (`Typography.screenTitle`, 3 lines max, `minimumScaleFactor 0.7`),
hero (Mochi via `WidgetMochiView` with a mood per card: `.cheer` for goal/badge/album/streak, `.happy`
for mochi/word), card-specific middle (stat chips, the word block, badge medallion, 7-day dots), then
a fixed footer: app name "VocabLoop", one invite line "Learn words with Mochi", and the App Store
short link `apps.apple.com/app/id6800027452` in `Typography.chip`. No QR code (unreadable at 4:5 in a
feed and it dates the card). Word card shows the headword in `Typography.wordDisplay`, phonetic in
`Typography.phonetic`, the definition in `Typography.body`, the example in `Typography.example` with
the headword emphasised — dictionary content only.

`ShareLink` message (iOS 16 `ShareLink(item:subject:message:preview:)`): subject "My VocabLoop card",
message = headline + " · https://apps.apple.com/app/id6800027452" so the link survives targets that drop
the image. `SharePreview(headline, image: Image(uiImage:))` from the rendered PNG. `AppLinks.appStore`
holds the URL (`https://apps.apple.com/app/id6800027452`).

## 3. Components (new folder `VocabLoop/Features/Share/`)

- `ShareCard.swift` — `enum ShareCard { case goalComplete(GoalCard), streak(StreakCard), badge(BadgeCard),
  mochi(MochiCard), word(WordCard), album(AlbumCard), week(WeeklyRecap) }`, each payload `Equatable, Sendable`;
  `var fileName: String` (stable, e.g. `VocabLoop-goal-2026-10-01.png`), `var headline: String` (delegates to
  `ShareCopy`), `var accessibilityLabel`. `WordCard.make(from: Entry) -> WordCard?` returns `nil` for
  `isUserCreated` entries or entries without a sense — the only place that touches a model, and it copies
  plain strings out.
- `ShareCopy.swift` — every sentence, pure functions, same house rules as `RecapCopy` (celebrate what
  happened, never count what did not; no "only/missed/failed").
- `ShareCardFrame.swift` + `ShareCardViews.swift` — the frame and one body view per case; `ShareCardMetrics`
  (`pointSize 360×450`, `scale 3`, `pixelSize`) replaces `RecapShareMetrics` (keep the old name as a
  `typealias` so `RecapHeadlineTests.testShareImageIs1080By1350` still passes).
- `ShareCardRenderer.swift` — `@MainActor enum ShareCardRenderer { static func writePNG(_ card: ShareCard) -> URL? ;
  static func content(for:) -> some View }`: `ImageRenderer` at `scale 3`, `proposedSize` = point size,
  `.environment(\.colorScheme, .light)`, `.dynamicTypeSize(.large)`, PNG written atomically to
  `temporaryDirectory/<fileName>`; `nil` on failure (button simply not offered). Generalises
  `RecapShareRenderer`, which becomes a thin wrapper (or is deleted and `WeeklyRecapView` calls the new one).
- `ShareCardButton.swift` — `ShareCardButton(card:, label: "Share today")`: renders in a `.task` on first
  appearance (a few ms), then shows a styled `ShareLink` (brand-filled capsule, `pressable()`, 44pt
  target), hidden until the URL exists and hidden entirely when sharing is disabled (§4). Also an
  icon-only `.toolbar` variant for `EntryDetailView` and `MochiHomeView`.
- `BadgeDetailSheet.swift` (in `Features/Achievements/`) — medallion, name, detail, "Earned 12 Sep",
  Mochi reward line, `ShareCardButton(.badge)`; `BadgeTile` becomes a `Button` for unlocked badges.

Existing views only *add* a button and build a payload from state they already hold (`GoalCompleteView`
has `model.reviewsToday`, `formattedDuration`, streak and look from `loadEngagement`; `AlbumGridView` has
`album` + `progress`; `StatsView` has `statistics.currentStreak/longestStreak` and needs `engagement.currentLook()`
+ `profile().level`, both already injected).

## 4. Kid safety and App Review

- **No personal data on any card** by construction: payloads carry no `displayName`, `email`, account id
  or free text. The word card refuses user-created entries (which can contain anything a child typed).
  `ShareCardPrivacyTests` keeps it that way.
- **No parental gate on sharing.** The share sheet is the OS's, nothing leaves the device without the user
  picking a destination, no data is collected, and the cards link to the App Store page only. Guideline
  1.3 (Kids Category) requires gates for links *out of the app* and purchases; VocabLoop is in Education,
  not the Kids Category, and even under 1.3 a system share sheet is not an external link. 5.1.4 (apps
  for kids) concerns data collection and third-party analytics/ads — none here. Gating a celebration
  behind a maths question would also be exactly the friction the recap avoided.
- **Parents get an off switch**: `ParentGateView` (behind the existing gate) gains a section
  "Sharing" with `Toggle("Allow sharing cards")` backed by `@AppStorage("sharing.enabled")`, default on;
  off hides every `ShareCardButton`, including the recap's. Device-level, no schema change.
- Reduce Motion: cards are static images; the badge sheet reuses `Motion` helpers like every other sheet.

## 5. Tests (`VocabLoopTests`)

- `ShareCopyTests`: singular/plural and kind-zero forms per card; `testNeverMentionsFailure` over every
  headline for a grid of inputs (`missed|only|failed|0 left|lost`).
- `ShareCardMetricsTests`: 360×450 pt, 1080×1350 px; `RecapShareMetrics` alias still 1080×1350.
- `ShareCardRendererTests` (simulator, `@MainActor`): each `ShareCard` case renders to non-nil PNG data
  with the PNG signature and `UIImage(data:).size == 1080×1350`; two renders of the same card produce
  the same file name; failure of `temporaryDirectory` write → `nil`, no throw.
- `ShareCardPrivacyTests`: `WordCard.make(from:)` returns `nil` for `isUserCreated` and for an entry
  without senses (uses `TestStore.makeEntry`); a `Mirror` over every payload asserts no property named
  `displayName|email|userID|accountID`.
- `WeeklyRecapTests` / `RecapHeadlineTests` unchanged and passing after the migration.
- UI tests untouched (no new launch flow, tab labels unchanged).

## 6. Workstream boundaries (run in parallel with the widget work)

**Sharing stream owns:** `VocabLoop/Features/Share/**` (new), `Features/Achievements/AchievementsView.swift`
+ `BadgeDetailSheet.swift`, `Features/Study/GoalCompleteView.swift`, `Features/Stats/StatsView.swift`,
`Features/Mochi/MochiHomeView.swift`, `Features/Browse/EntryDetailView.swift`,
`Features/Collection/AlbumGridView.swift`, `Features/Recap/RecapCardView.swift` + `WeeklyRecapView.swift`,
`Features/Parents/ParentGateView.swift`, `Core/AppLinks.swift`, and the five test files in §5.

**Widget stream owns** (do not touch from here): `project.pbxproj`, `Config/**`, `.github/**`, `scripts/**`,
`VocabLoopShared/**`, `VocabLoopWidgets/**`, `Core/Engagement/EngagementService.swift`,
`Core/Services/StudyActivityController.swift`, `Features/Study/StudySessionView.swift`,
`Features/Study/StudyViewModel.swift`, `App/*`, `Core/Intents/*`, and the `PresentationSettingsView`
struct inside `Features/Settings/SettingsView.swift`.

**Shared touch points, and how they are avoided:**
- `WidgetMochiView.swift`, `Palette.swift`, `Typography.swift`, `Crayon.swift`, `Mascot*.swift`,
  `MochiWardrobe.swift` move to `VocabLoopShared/` in the widget stream's first commit. The sharing stream
  uses these types but never edits those files; if it needs a new token, it adds a file under
  `Features/Share/` instead. Rebase after the move lands — a rename plus unrelated edits merges cleanly.
- `SettingsView.swift`: the widget stream edits only `PresentationSettingsView`; the sharing stream does
  not edit this file at all (its toggle lives in `ParentGateView.swift`).
- `GoalCompleteView.swift`: sharing stream only. The Live Activity's "Done for today" hook is wired in
  `StudySessionView`'s `onDone` closure, not inside `GoalCompleteView`.
- `AppLinks.swift`: sharing stream only (adds `appStore`). The widget deep links are URL literals in the
  extension and `VocabLoopApp`, not in `AppLinks`.
- `RELEASE`, `README.md`, `docs/ENGAGEMENT-PLAN.md`: the widget stream writes the 1.0.8 notes last and
  includes one line for sharing; the sharing stream adds nothing there.

## 7. Order

1. `ShareCard`, `ShareCopy`, `ShareCardMetrics`, `ShareCardFrame`, renderer, button, `AppLinks.appStore`;
   migrate the weekly recap to them (behaviour identical). Tests of §5 except privacy.
2. Goal card + button; Mochi card + toolbar; word card + privacy tests.
3. Badge detail sheet + card; album card; streak card.
4. Parent toggle. Push with `[full ci]`. Acceptance: every button yields a 1080×1350 light-mode PNG with
   the footer and link; share sheet preview shows the headline; nothing on any card identifies the child;
   with the parent toggle off no share button exists anywhere.
