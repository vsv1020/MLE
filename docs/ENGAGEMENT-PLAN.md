# Engagement plan — VocabLoop 1.0.7

Single source of truth for the "make it fun to come back" release. Decisions here are final;
developers implement, they do not re-decide. When this document and code disagree during the
release, fix the code.

Scope (all approved, all in 1.0.7 unless marked): session combos · always-visible streak flame +
kind evening nudge · question-type rotation with auto-grading · Mochi growth, star candy and
wardrobe · word sticker book · achievements · weekly recap with share card · parent report ·
**widget: target deferred to 1.0.8, data path shipped now** (see §1.12).

Constraints that shaped every decision: no local compiler (CI only, ~15 min, `[full ci]`), so the
plan is additive files + a short list of named touch points; FSRS must receive honest `1…4`
grades; SwiftData changes must be lightweight-migratable; kids audience, no guilt, offline.

---

## 1. Product decisions

### 1.1 Combos
- **Combo** = consecutive answers in this session that were not *Forgot* (`Rating != .again`),
  self-graded or auto-graded alike. Session-scoped, in memory. Reset on Forgot. Undo restores the
  value from before the undone grade.
- **Milestones**: 3, 5, 10, 15, 20, 30, 50, 75, 100, then every 50.
- **Rewards per milestone** (star candy bonus): 3→+1, 5→+2, 10→+3, 15→+3, 20→+5, 30→+5, 50→+10,
  75→+10, 100+→+20. Small on purpose: the base candy (§1.3) is per *answer*, so an honest Forgot
  costs at most a few candies and never the day's progress. This is how we keep combos from
  becoming an incentive to press "Got it" on a word you forgot.
- **Mochi reactions**: 3 `.happy` + hop; 5 `.cheer`; 10 `.cheer` + 12-particle `SummaryBurst`
  behind Mochi; 20+ `.cheer` + burst + "superstar" sparkle ring; 50/100 also unlock achievements.
- **Combo broken** at ≥ 5: a kind toast "Nice run: 12 in a row!" — the run is celebrated, the
  break is not mentioned. Never a sound, never a haptic error.
- **Haptics**: milestone → `Haptics.success()`; ordinary correct → existing `Haptics.tap()`.
- **UI**: `ComboBanner` in the study top bar (replaces nothing; sits under the progress bar row)
  showing `🔥 12` only when combo ≥ 3, with a candy pill `⭐ 1,240` always visible.

### 1.2 Streak flame on the study screen + evening nudge
- Flame + day count in the top bar, trailing the review counter, on every study screen (root and
  sheet). **Grey** (`Palette.textTertiary`) until today's first review, then `Palette.brandSecondary`
  with a `Motion.pop` hop and `+1` when the first review of the day lands. Streak 0 → grey flame,
  no number.
- **"Streak at risk" notification** (`vocabloop.streak.risk`): one non-repeating
  `UNCalendarNotificationTrigger` at **19:30** local (18:30 when the daily reminder is 19:30),
  scheduled only when `streak.current >= 2` and the user has **not** studied today; removed the
  moment a review is recorded; recomputed on app background and in `refreshSchedule`. Requires the
  existing reminders authorization and the new `streakReminderEnabled` toggle (default on).
- **Copy** (English): title `A few words before bed?` body
  `Your {n}-day streak is waiting for today. Three words keep it going — Mochi saved your spot.`
  Never "lose", "break", "don't let". No count-down, no badge increment.

### 1.3 Star candy economy and Mochi levels
- **Earn**: 1 candy per graded review (any rating — honesty costs nothing). First review of the
  day +5. Daily goal reached +10. Combo milestones per §1.1. Sticker lights up (card becomes
  mature) +3. Album completed +25. Achievement +10.
- Typical 30-review day ≈ 50 candy. Candy is XP: it is never spent and there is no shop.
- **Level curve**: candy required to *reach* level `n` = `20 · n · (n − 1)`, i.e. L2 40, L3 120,
  L5 400, L10 1,800, L15 4,200, L20 7,600, cap L30 (17,400). At 50/day: L5 ≈ day 8, L10 ≈ day 36,
  L20 ≈ 5 months. Level is derived from total candy, never stored separately.
- **Growth stages** (`MochiStage`): `sprout` L1–4, `kid` L5–9 (tiny leaf tuft), `teen` L10–14
  (bigger blush, star on belly), `grown` L15+ (sparkle crown line). On the study card Mochi stays
  58×48pt; stage changes the drawing, not the frame.
- **Mochi misses you**: if `daysSinceLastStudy >= 3` when a session opens, a one-time toast
  `Mochi missed you! 💛 Let's do a few words.` with `.happy` mood. Nothing is lost, nothing is
  greyed out, candy and level are untouched.

### 1.4 Wardrobe (all drawn in `Canvas`, no image assets)
Level unlocks are **always free** — a child never earns something they cannot wear.

| Accessory (`MochiAccessory`) | Slot | Unlock |
|---|---|---|
| `redScarf` | neck | L2 |
| `partyHat` | head | L3 |
| `roundGlasses` | eyes | L4 |
| `bow` | head | L5 |
| `strawHat` | head | L6 |
| `crown` | head | L8 |
| `headphones` | head | L10 |
| `cape` | back | L12 |
| `nightcap` | head | achievement `night_owl` |
| `sunVisor` | head | achievement `early_bird` |
| `goldStarPin` | neck | achievement `combo_50` |
| `graduationCap` | head | achievement `mastered_100` |
| `wizardHat` · `halo` · `rainbowScarf` · `astronautHelmet` | head/neck | **Plus closet** (immediate) |

Body colours (`MochiBodyColor`): `vanilla` (default), `strawberry` L3, `matcha` L5, `blueberry`
L7, `mango` L9; Plus closet: `lavender`, `mint`, `cocoa`, `galaxy`. One accessory per slot
(head, eyes, neck, back) may be worn at once.

### 1.5 Question-type rotation and FSRS mapping
Kinds (`QuestionKind`): `flip` (existing self-graded card), `multipleChoice` (headword shown and
speakable → pick the meaning among 4), `listenChoose` (word is spoken, no text → pick the headword
among 4), `clozeChoose` (sentence with blank → pick the headword among 4), `typed` (definition +
zh → type the word; production/cloze cards only).

**Selection** (`QuestionGenerator.kind`), deterministic from `card.fuzzSeed ^ (UInt64(card.reps)
&* 0x9E37_79B9_7F4A_7C15)`, roll = seed % 10:
1. `policy.flipOnly` (launch arg `-uiTestingFlipOnly`) or `preferences.quizModesEnabled == false`
   → `flip`.
2. `card.phase` is `.new`, `.learning` or `.relearning` → `flip`. (An introduction cannot be a quiz;
   learning steps are minutes apart and a quiz there would test the option list, not memory.)
3. Fewer than 3 valid distractors → `flip`.
4. Recognition card, **young** (interval < 21d): roll 0–3 `flip`, 4–6 `multipleChoice`,
   7–8 `listenChoose`, 9 `clozeChoose`. **Mature**: 0–4 `flip`, 5–6 `multipleChoice`,
   7 `listenChoose`, 8–9 `clozeChoose`. `listenChoose` requires `speech.isSupported(language)`
   and `clozeChoose` requires `entry.clozePrompt() != nil`; otherwise fall back to `multipleChoice`.
5. Production card: 0–5 `flip`, 6–9 `typed`. Cloze card: 0–4 `flip`, 5–9 `typed` (sentence shown
   with the blank).

**Option text** for `multipleChoice`: the zh translation of the primary sense when the user's
native codes include it, else the English definition truncated to 60 chars. Four short options a
child can scan; long definitions are not.

**Distractors** (`QuestionGenerator.make`): same language; same primary part of speech; same CEFR
level, falling back to adjacent levels, then any level; not the same entry; headword not equal and
not in the answer's `synonyms`; option text not equal to the answer's option text; prefer entries
the learner has cards for (familiar distractors are fair distractors), then fill from the rest.
Three picked with `SeededGenerator(seed)`; the correct answer's position is `seed % 4`. The pool
is built once per session from a single `Entry` fetch for the language into light structs.

**Auto-grade → Rating** (`AutoGrader.rating`), measured from the moment the question appears:
| Kind | Correct, fast | Correct, slow | Near miss | Wrong |
|---|---|---|---|---|
| `multipleChoice` / `listenChoose` / `clozeChoose` | ≤ 6 s → `.good` | > 6 s → `.hard` | — | `.again` |
| `typed` | ≤ 12 s → `.good` | > 12 s → `.hard` | 1 edit, length ≥ 5 → `.hard` | `.again` |

Rationale: FSRS treats `good` as the expected outcome; recognising among four is weaker evidence
than free recall, so the ceiling is `good`, never `easy` — `easy` would inflate stability from a
25 % guess floor. Slow-but-correct is the paper's definition of `hard`. A wrong pick is a lapse; it
goes through the normal relearning step and returns this session like any Forgot. Time-to-answer
matters only as this one threshold; it is also logged in `durationMS` as today. The quiz kind is
recorded on the engagement event, not on `ReviewLog` (no schema change there).

**Feedback**: tap → option turns green (`Palette.success`) or red (`Palette.rating(.again)`), the
correct option is always shown green, the full answer side is revealed under the options, then a
single **Continue** button advances (no auto-advance: kids need to read the correct one). Typed:
the typed text is compared case-, whitespace- and diacritic-insensitively.

### 1.6 Sounds
No audio assets exist, so **`scripts/sounds.py` (stdlib `wave`/`math` only) generates mono 16-bit
44.1 kHz WAVs into `VocabLoop/Resources/Sounds/`** and both script and WAVs are committed. The
synchronized root group adds them to Copy Bundle Resources automatically, exactly like the seed
JSON. Played with **AudioToolbox `AudioServicesCreateSystemSoundID` / `AudioServicesPlaySystemSound`**:
respects the silent switch by design, needs no `AVAudioSession` category, cannot interfere with
`SpeechService`'s `.playback` session, and is one call with nothing to get wrong blind.

| `SoundEffect` | File | Character | When |
|---|---|---|---|
| `reveal` | `reveal.wav` | 70 ms soft pop, sine 520→380 Hz | Show answer |
| `correct` | `correct.wav` | 120 ms bright ding, E6 | Got it / Instant / quiz correct |
| `comboSmall` | `combo_3.wav` | C5-E5 two-note, 160 ms | combo 3, 5 |
| `comboMedium` | `combo_10.wav` | C5-E5-G5, 220 ms | combo 10, 15, 20 |
| `comboBig` | `combo_big.wav` | C5-E5-G5-C6 + shimmer, 400 ms | combo 30+ |
| `candy` | `candy.wav` | two 40 ms sparkles at 1.8/2.4 kHz | candy bonus (not base candy) |
| `sticker` | `sticker.wav` | 300 ms rising shimmer | sticker lights up |
| `levelUp` | `level_up.wav` | 800 ms triangle-wave fanfare C-E-G-C | level up |
| `badge` | `badge.wav` | 600 ms chime | achievement / album complete |
| `goal` | `goal.wav` | 1.0 s warm chime | daily goal reached |

No sound on Forgot, Slow, or a wrong quiz answer. Default **on** (the Settings toggle
`Sound effects` lives in Presentation under Haptic feedback); the silent switch always wins.
Total bundle cost < 400 KB.

### 1.7 Albums (sticker book)
Entries carry no topic tags, and a 3,301-word content pass is not a 1.0.7 job. Albums are
therefore **derived, deterministic and stored nowhere**:
- Family (`WordFamily`) from the primary sense's part of speech: `nouns`, `verbs` (incl. phrasal
  verb), `describingWords` (adjective, adverb), `littleWords` (everything else).
- Level: `A1 A2 B1 B2 C1` (C2 folds into C1), from `entry.cefr`.
- Within (level, family), order by `frequencyRank` (then headword) and **page in chunks of 12**
  (a 3×4 grid). Album id `"en|A1|nouns|3"`, title "A1 Nouns · Page 3". ≈ 275 albums.
- Sticker state per word = `Entry.maturity`: not enrolled → dotted outline; `new`/`learning` →
  pencil sketch (grey); `young` → coloured; `mature` → coloured + shine. The sticker is the
  headword in `Typography.wordTitle` on a `WobbleShape` chip tinted by family.
- Album complete = all 12 mature → `badge.wav`, +25 candy, achievement progress. Albums in a Plus
  pack (`PlusCatalog.premiumDeckSlugs`) show a small "Plus" tag but are browsable.
- 1.0.8: when a `topics` content pass lands, `CollectionService` prefers `Entry.tags` grouping —
  the API below already takes a grouping strategy, so nothing else changes.

### 1.8 Achievements (`AchievementID`, 16)
| id | Name | Condition |
|---|---|---|
| `first_review` | First step | 1 review |
| `streak_3` | Three in a row | streak ≥ 3 |
| `streak_7` | One whole week | streak ≥ 7 |
| `streak_30` | A month of words | streak ≥ 30 |
| `combo_10` | On a roll | combo ≥ 10 |
| `combo_25` | Unstoppable | combo ≥ 25 |
| `combo_50` | Fifty! | combo ≥ 50 |
| `mastered_10` | Ten stickers | 10 mature words |
| `mastered_100` | Sticker star | 100 mature words |
| `mastered_500` | Word collector | 500 mature words |
| `album_first` | First album | 1 complete album |
| `night_owl` | Night owl | a review between 22:00 and 02:00 local |
| `early_bird` | Early bird | a review between 05:00 and 07:00 local |
| `goal_7` | Goal getter | daily goal met on 7 days (lifetime) |
| `quiz_100` | Quiz whiz | 100 correct auto-graded answers |
| `mochi_10` | Best friends | Mochi level 10 |

Each has a 1-line description and an SF Symbol; unlock → toast + `badge.wav` + +10 candy.
Conditions are pure functions of `AchievementContext` so they are unit-testable with no store.

### 1.9 Weekly recap
Window = the 7 study days ending today (user's `StudyCalendar`). Contents (`WeeklyRecap`):
reviews, accuracy, days studied (7 dots), minutes studied, **words mastered this week** (ReviewLog
rows in the window with `scheduledDays < 21 && intervalDaysAfter >= 21`), words started, best
combo, candy earned, Mochi level + look, 3 "words you nailed" (highest `stabilityAfter` this week),
up to 3 "tricky words" (≥ 2 Forgot this week — shown as "worth another look", never "failed").
Surfaces: a "This week" card at the top of Progress; a "See your week" chip on `GoalCompleteView`
once per week (key `recap.seenWeekKey` in UserDefaults). **Share card**: `RecapCardView` rendered
by `ImageRenderer` at 1080×1350 → `ShareLink`. Headline copy: `This week you mastered 42 words`.

### 1.10 Parent view
Settings ▸ **For parents** ▸ `ParentGateView` (random `a × b`, a,b ∈ 3…9, three tries, not
persisted — the standard App Review parental gate) ▸ `ParentReportView`: the same `WeeklyRecap`
plus previous-week comparison arrows, total minutes, the full list of words started this week with
zh translation, tricky words, streak, and plain-language notes ("Accuracy around 85 % is the
scheduler working as intended"). Plus adds the 12-week history list and **Export PDF**
(`ImageRenderer.render` to PDF → `ShareLink`). No account, nothing leaves the device.

### 1.11 Plus split
Free: everything the learner *earns* — studying, all question types, combos, candy, levels,
every level- and achievement-unlock, streak flame, sounds, sticker book, achievements, weekly
recap and share card, parent report (current week). **Plus**: the Plus closet (4 accessories +
4 colours, §1.4), parent report history + PDF export. Add one line to `PlusView` benefits and
`PlusCatalog.plusClosetAccessoryIDs`. Rationale: never gate the loop or anything a child worked
for; gate adult conveniences and extras.

### 1.12 Widget — defer the target, ship the data path
**Decision: no Widget Extension target in 1.0.7.** Reasons: a second `PBXNativeTarget` with its
own synchronized group exceptions, embed phase, entitlements and App Group hand-written into
`project.pbxproj` cannot be verified without Xcode; it also changes signing for `distribute.yml`
and `release.yml`; and an App Group moves the store file for existing users. Each of those is a
whole-release risk for a release already carrying nine features.
**De-risking now**, so 1.0.8 is only target plumbing: `WidgetSnapshotWriter` writes
`widget-snapshot.json` (`WidgetSnapshot`: dueNow, reviewsToday, dailyGoal, streak, studiedToday,
mochiLevel, mochiLook, candy, updatedAt) after every grade and on background, into
`SharedStorage.containerURL` (App Group container when the capability exists, else Application
Support). The 1.0.8 widget reads that file and **never opens the SwiftData store from a second
process**. `WidgetMochiView` (a plain SwiftUI view in the app target, used by the recap card) is
the future widget body. `docs/WIDGET.md` is updated to this design.

---

## 2. Architecture

### 2.1 Persistence (what lives where)
- **SwiftData, new `@Model EngagementProfile`** (one row per `userID`, `@Attribute(.unique)
  userID`) — registered in `PersistenceController.schema`. Adding an entity is a lightweight
  migration; every property has a declaration default (precedent: `ReviewLog.easeFactorBefore`).
  Holds everything that must survive reinstall-free upgrades and travel with the account.
- **SwiftData, `StudyPreferences`** gets three defaulted stored properties (lightweight):
  `public var soundEffectsEnabled: Bool = true`, `public var quizModesEnabled: Bool = true`,
  `public var streakReminderEnabled: Bool = true`. Same object every settings screen already saves
  through `savePreferences()`.
- **Derived, not stored**: Mochi level (from candy), album membership, sticker state, streak,
  weekly recap (from `StudyDay` + `ReviewLog`).
- **UserDefaults**: `recap.seenWeekKey`, `mochi.welcomeBackShownDayKey` — device-local UI nags.
- **Files**: `widget-snapshot.json` in `SharedStorage.containerURL`.
- No `ReviewLog`, `Card`, `Entry` schema changes.

### 2.2 New types (file → signatures)

`VocabLoop/Core/Engagement/EngagementProfile.swift`
```swift
public struct UnlockedAchievement: Codable, Hashable, Sendable { public var id: String; public var unlockedAt: Date }
@Model public final class EngagementProfile {
    @Attribute(.unique) public var userID: String
    public var candyTotal: Int = 0
    public var lifetimeReviews: Int = 0
    public var quizCorrectTotal: Int = 0
    public var goalDaysTotal: Int = 0
    public var bestCombo: Int = 0
    public var weekKey: String = ""          // StudyCalendar dayKey of the week's first day
    public var candyThisWeek: Int = 0
    public var bestComboThisWeek: Int = 0
    public var lastStudiedAt: Date? = nil
    public var lastFirstReviewDayKey: String = ""   // guards the +5 "showed up" bonus
    public var equippedAccessoryIDs: [String] = []
    public var unlockedAccessoryIDs: [String] = []  // achievement-granted ones; level ones are derived
    public var bodyColorRaw: String = "vanilla"
    public var unlockedAchievements: [UnlockedAchievement] = []
    public var completedAlbumIDs: [String] = []
    public var updatedAt: Date = Date()
    public init(userID: String)
    public var level: Int { RewardEngine.level(forCandy: candyTotal) }
}
```

`VocabLoop/Core/Engagement/RewardEngine.swift` (pure, no SwiftData)
```swift
public enum RewardEngine {
    public static let maxLevel = 30
    public static func candyRequired(toReach level: Int) -> Int        // 20·n·(n−1)
    public static func level(forCandy candy: Int) -> Int
    public static func progressToNextLevel(candy: Int) -> Double       // 0…1
    public static let comboMilestones: [Int]                            // 3,5,10,15,20,30,50,75,100
    public static func isComboMilestone(_ combo: Int) -> Bool           // includes every 50 past 100
    public static func comboBonus(_ combo: Int) -> Int
    public static func comboTier(_ combo: Int) -> ComboTier             // .none/.small/.medium/.big
    public static let candyPerReview = 1, firstReviewBonus = 5, goalBonus = 10,
                      stickerBonus = 3, albumBonus = 25, achievementBonus = 10
    public static func stage(forLevel level: Int) -> MochiStage
}
public enum ComboTier: Equatable { case none, small, medium, big }
```

`VocabLoop/Core/Engagement/EngagementService.swift`
```swift
public struct ReviewOutcomeEvent: Sendable {
    public var cardID: String, entryStableID: String, rating: Rating
    public var questionKind: QuestionKind, wasAutoGraded: Bool, responseMS: Int
    public var phaseBefore: LearningPhase, maturityBefore: CardMaturity, maturityAfter: CardMaturity
    public var comboAfter: Int            // VM-owned session combo, already updated
    public var justReachedGoal: Bool, reviewsToday: Int
}
public enum EngagementEvent: Equatable, Sendable {
    case candy(Int)                       // total added by this review incl. bonuses
    case firstReviewToday(streak: Int)
    case comboMilestone(Int)
    case comboEnded(best: Int)            // emitted by VM, not service; listed here for the UI switch
    case stickerLit(entryStableID: String)
    case albumCompleted(albumID: String, title: String)
    case levelUp(Int)
    case achievement(AchievementID)
    case welcomeBack(daysAway: Int)
}
public struct SessionOpening: Sendable {
    public var streak: StreakService.Streak, studiedToday: Bool, daysSinceLastStudy: Int?
    public var candyTotal: Int, level: Int, look: MochiLook
}
@MainActor public final class EngagementService {
    public init(context: ModelContext, notifications: NotificationService,
                snapshots: WidgetSnapshotWriter, entitlements: Entitlements)
    public func profile() throws -> EngagementProfile                   // fetch-or-create for active account
    public func sessionOpened(preferences: StudyPreferences, now: Date) throws -> SessionOpening
    public func record(_ event: ReviewOutcomeEvent, preferences: StudyPreferences, now: Date) throws -> [EngagementEvent]
    public func streak(preferences: StudyPreferences, now: Date) throws -> StreakService.Streak
    public func currentLook() -> MochiLook
    public func setEquipped(_ accessory: MochiAccessory?, slot: MochiAccessory.Slot) throws
    public func setBodyColor(_ color: MochiBodyColor) throws
    public func isUnlocked(_ accessory: MochiAccessory) -> Bool
    public func isUnlocked(_ color: MochiBodyColor) -> Bool
    public func achievementStatuses(preferences: StudyPreferences, now: Date) throws -> [AchievementStatus]
    public func refreshStreakReminder(preferences: StudyPreferences, now: Date) async
    public func writeWidgetSnapshot(preferences: StudyPreferences, now: Date)
}
```
`record` does, in order: candy base + bonuses; week rollover (`weekKey`); `lastStudiedAt`; first-
review-of-day bonus; combo milestone bonus and `bestCombo`; `quizCorrectTotal`; sticker/album
detection (`maturityBefore != .mature && maturityAfter == .mature` → `CollectionService.album(for:)`
→ completion check); achievements via `AchievementCatalog.evaluate`; level-up detection
(level before vs after); `try context.save()`; then fire-and-forget `refreshStreakReminder` and
`writeWidgetSnapshot`.

`VocabLoop/Core/Engagement/Achievements.swift`
```swift
public enum AchievementID: String, CaseIterable, Codable, Sendable { case first_review, streak_3, … mochi_10 }
public struct Achievement: Identifiable, Sendable { public let id: AchievementID, name: String, detail: String, symbolName: String
    public let isMet: @Sendable (AchievementContext) -> Bool }
public struct AchievementContext: Sendable { lifetimeReviews, currentStreak, longestStreak, bestCombo, matureWords,
    completedAlbums, goalDaysTotal, quizCorrectTotal, level: Int; localHour: Int }
public struct AchievementStatus: Identifiable, Sendable { public let achievement: Achievement; public let unlockedAt: Date? }
public enum AchievementCatalog {
    public static let all: [Achievement]
    public static func evaluate(_ context: AchievementContext, alreadyUnlocked: Set<String>) -> [AchievementID]
}
```

`VocabLoop/Core/Engagement/CollectionService.swift`
```swift
public enum WordFamily: String, CaseIterable, Codable, Sendable { case nouns, verbs, describingWords, littleWords
    public init(partOfSpeech: PartOfSpeech); public var title: String; public var tint: Color }
public enum AlbumLevel: String, CaseIterable, Sendable { case a1, a2, b1, b2, c1; public init(cefr: CEFRLevel?) }
public struct Album: Identifiable, Hashable, Sendable { public let id: String, languageCode: String, level: AlbumLevel,
    family: WordFamily, page: Int, entryStableIDs: [String]; public var title: String; public static let pageSize = 12 }
public enum StickerState: Sendable { case locked, sketch, coloured, shiny; public init(maturity: CardMaturity?, isEnrolled: Bool) }
public struct AlbumProgress: Sendable { public var album: Album; public var states: [StickerState]; public var shinyCount: Int
    public var isComplete: Bool }
public enum AlbumGrouping: Sendable { case levelAndFamily /* 1.0.7 */, tags /* 1.0.8 */ }
@MainActor public final class CollectionService {
    public init(context: ModelContext, grouping: AlbumGrouping = .levelAndFamily)
    public func albums(languageCode: String) throws -> [Album]           // cached per language, invalidated on reimport
    public func album(containing entryStableID: String, languageCode: String) throws -> Album?
    public func progress(of album: Album) throws -> AlbumProgress
    public func summary(languageCode: String) throws -> (albums: Int, complete: Int, shiny: Int)
    public func invalidateCache()
    static func pageAlbums(entries: [(stableID: String, cefr: CEFRLevel?, pos: PartOfSpeech, rank: Int?, headword: String)],
                           languageCode: String) -> [Album]               // pure, tested
}
```

`VocabLoop/Core/Engagement/MochiWardrobe.swift`
```swift
public enum MochiStage: Int, Sendable { case sprout, kid, teen, grown }
public enum MochiAccessory: String, CaseIterable, Codable, Sendable { case redScarf, partyHat, … astronautHelmet
    public enum Slot: String, CaseIterable, Sendable { case head, eyes, neck, back }
    public var slot: Slot; public var name: String; public var unlockLevel: Int?; public var unlockAchievement: AchievementID?
    public var requiresPlus: Bool }
public enum MochiBodyColor: String, CaseIterable, Codable, Sendable { case vanilla, strawberry, … galaxy
    public var name: String; public var unlockLevel: Int?; public var requiresPlus: Bool; public var fill: Color }
public struct MochiLook: Equatable, Sendable { public var stage: MochiStage; public var color: MochiBodyColor;
    public var accessories: [MochiAccessory]; public static let `default` = MochiLook(stage: .sprout, color: .vanilla, accessories: []) }
extension PlusCatalog { public static var plusClosetAccessoryIDs: Set<String>; public static var plusClosetColorIDs: Set<String> }
```

`VocabLoop/Core/Engagement/WeeklyRecapService.swift`
```swift
public struct RecapWord: Identifiable, Sendable { public let entryStableID: String, headword: String, translation: String? }
public struct WeeklyRecap: Sendable {
    public var weekStartKey: String, dayKeys: [String], studiedDays: [Bool]
    public var reviews: Int, accuracy: Double?, minutes: Int, wordsMastered: Int, wordsStarted: Int
    public var bestCombo: Int, candyEarned: Int, level: Int, look: MochiLook, streak: Int
    public var nailedWords: [RecapWord], trickyWords: [RecapWord], startedWords: [RecapWord]
    public var previous: WeeklyRecapDelta?   // reviews/minutes/mastered deltas vs the prior 7 days
    public var headline: String              // "This week you mastered 42 words"
}
public struct WeeklyRecapDelta: Sendable { public var reviews: Int, minutes: Int, wordsMastered: Int }
@MainActor public final class WeeklyRecapService {
    public init(context: ModelContext, engagement: EngagementService)
    public func recap(for account: UserAccount, preferences: StudyPreferences, endingAt now: Date) throws -> WeeklyRecap
    public func history(for account: UserAccount, preferences: StudyPreferences, weeks: Int, now: Date) throws -> [WeeklyRecap]
    static func masteredCount(logs: [ReviewLog]) -> Int                   // pure, tested
}
```

`VocabLoop/Core/Services/QuestionGenerator.swift`
```swift
public enum QuestionKind: String, Codable, CaseIterable, Sendable { case flip, multipleChoice, listenChoose, clozeChoose, typed
    public var isAutoGraded: Bool }
public struct QuestionPolicy: Sendable { public var flipOnly: Bool; public var quizEnabled: Bool; public var hasSpeech: Bool
    public static func fromProcess(preferences: StudyPreferences, speech: SpeechService) -> QuestionPolicy }
public struct QuestionOption: Identifiable, Hashable, Sendable { public let id: String /* entryStableID */, text: String }
public struct Question: Equatable, Sendable {
    public var kind: QuestionKind; public var cardID: String; public var options: [QuestionOption]   // 4 or empty
    public var correctIndex: Int; public var answerText: String; public var clozePrompt: ClozePrompt?; public var seed: UInt64 }
public struct DistractorCandidate: Hashable, Sendable { stableID, headword, pos: PartOfSpeech, cefr: CEFRLevel?,
    optionText: String, synonyms: [String], isEnrolled: Bool }
@MainActor public final class QuestionGenerator {
    public init(context: ModelContext)
    public func prepare(languageCode: String, nativeCodes: [String]) throws         // one fetch → candidate pool
    public static func kind(for card: Card, policy: QuestionPolicy, distractorCount: Int, canCloze: Bool) -> QuestionKind
    public func make(for card: Card, policy: QuestionPolicy) -> Question             // never throws; falls back to .flip
    static func pickDistractors(answer: DistractorCandidate, pool: [DistractorCandidate], seed: UInt64) -> [DistractorCandidate] // pure
    static func seed(for card: Card) -> UInt64
}
```

`VocabLoop/Core/Services/AutoGrader.swift`
```swift
public enum MatchQuality: Sendable { case exact, nearMiss, wrong }
public enum TypedAnswerMatcher { public static func match(typed: String, answer: String) -> MatchQuality
    static func editDistance(_ a: String, _ b: String) -> Int }
public enum AutoGrader {
    public static let choiceFastMS = 6_000, typedFastMS = 12_000
    public static func rating(kind: QuestionKind, quality: MatchQuality, responseMS: Int) -> Rating   // never .easy
}
```

`VocabLoop/Core/Services/SoundService.swift`
```swift
public enum SoundEffect: String, CaseIterable, Sendable { case reveal, correct, comboSmall, comboMedium, comboBig, candy, sticker, levelUp, badge, goal
    var fileName: String }
@MainActor public final class SoundService {
    public var isEnabled: Bool                       // set from preferences.soundEffectsEnabled in bootstrap/savePreferences
    public init(bundle: Bundle = .main)
    public func preload()                            // AudioServicesCreateSystemSoundID for each file; missing file → logged, skipped
    public func play(_ effect: SoundEffect)
    public func play(comboTier: ComboTier)
}
```

`VocabLoop/Core/Services/WidgetSnapshotWriter.swift`
```swift
public enum SharedStorage { public static let appGroupID = "group.com.vocabloop.app"; public static var containerURL: URL
    public static var widgetSnapshotURL: URL }
public struct WidgetSnapshot: Codable, Equatable, Sendable { dueNow, reviewsToday, dailyGoal, streak: Int; studiedToday: Bool;
    mochiLevel, candy: Int; bodyColor: String; accessories: [String]; updatedAt: Date }
public struct WidgetSnapshotWriter: Sendable { public init(url: URL = SharedStorage.widgetSnapshotURL)
    public func write(_ snapshot: WidgetSnapshot); public func read() -> WidgetSnapshot? }
```

`VocabLoop/Core/Services/NotificationService.swift` (additions)
```swift
static let streakRiskIdentifier = "vocabloop.streak.risk"
public func refreshStreakReminder(preferences: StudyPreferences, streak: Int, studiedToday: Bool, now: Date) async
static func streakReminderFireDate(preferences: StudyPreferences, now: Date, calendar: StudyCalendar) -> Date?  // pure, tested
```
`refreshSchedule` and `cancelAll` add `streakRiskIdentifier` to their removal lists; `refreshSchedule`
ends by calling `refreshStreakReminder` with values the caller passes through two new defaulted
parameters `streak: Int = 0, studiedToday: Bool = true` (existing call sites compile unchanged).

### 2.3 UI files (all new unless listed under touch points)
`Features/Study/`: `QuestionCardView.swift` (switch on `Question.kind`; `.flip` → existing
`FlashcardView`), `MultipleChoiceView.swift` (shared by choice kinds: prompt slot + 4 `WobbleShape`
option buttons + Continue), `TypedAnswerView.swift`, `ComboBanner.swift`, `StreakFlame.swift`,
`RewardToast.swift` (queue of `EngagementEvent`, one at a time, 1.6 s each, tappable to dismiss).
`Features/Mochi/`: `MochiHomeView.swift` (segmented: Mochi · Stickers · Badges; sheet from the
study screen and from Today), `WardrobeView.swift`, `MochiStatusCard.swift` (level ring, candy,
next unlock). `DesignSystem/MascotAccessories.swift` (one `static func draw(_:in:size:)` per
accessory, stage details, body colour fill). `Features/Collection/`: `StickerBookView.swift`,
`AlbumGridView.swift`, `StickerView.swift`. `Features/Achievements/AchievementsView.swift`.
`Features/Recap/`: `WeeklyRecapView.swift`, `RecapCardView.swift` (1080×1350, uses
`WidgetMochiView`), `WidgetMochiView.swift`. `Features/Parents/`: `ParentGateView.swift`,
`ParentReportView.swift`.

### 2.4 Touch points in existing files (exact)
| File | Where | Change | Owner |
|---|---|---|---|
| `Core/Persistence/PersistenceController.swift` | `schema` array | add `EngagementProfile.self` | W0 |
| `Core/Models/StudyPreferences.swift` | after `hapticsEnabled` | 3 defaulted stored props (§2.1) | W0 |
| `App/AppDependencies.swift` | props + `init` + `bootstrap()` + `savePreferences()` | `engagement`, `collection`, `recap`, `questions`, `sounds`, `widgetSnapshots`; `sounds.preload()`; `sounds.isEnabled = preferences?.soundEffectsEnabled ?? true` in both places; `QuestionPolicy.flipOnly` from `-uiTestingFlipOnly` under `#if DEBUG` | W0 |
| `App/VocabLoopApp.swift` | `resetFirstRunStateIfUITesting` | nothing (flag read in AppDependencies) | — |
| `DesignSystem/Mascot.swift` | `init` | add `look: MochiLook = .default`; store; `drawFace` unchanged; body fill `look.color.fill`; call `MascotAccessories.draw` before/after face by slot | W0 (signature), W3 (drawing) |
| `Features/Study/StudyViewModel.swift` | see §2.5 | W1 |
| `Features/Study/StudySessionView.swift` | `topBar` (flame + combo), `.reviewing` branch (`QuestionCardView`), Mochi overlay becomes a `Button` → `MochiHomeView` sheet, `RewardToast` overlay, `bottomControls` (flip only), `onChange(scenePhase)` → `writeWidgetSnapshot` | W1 |
| `Features/Study/GoalCompleteView.swift` | under stat tiles | "See your week" chip (once per week) | W4 |
| `Core/Services/NotificationService.swift` | §2.2 | W2 |
| `Core/Services/ReviewService.swift` | none | — |
| `Features/Settings/SettingsView.swift` | `PresentationSettingsView` (Sound effects toggle + Quiz questions toggle), `NotificationSettingsView` (Streak reminder toggle), new `Section("For parents")` after Reminders | W4 |
| `Features/Home/HomeView.swift` | after `statsRow` | `mochiRow` → `MochiHomeView` | W4 |
| `Features/Stats/StatsView.swift` | top of the scroll | `WeeklyRecapCard` | W4 |
| `Features/Plus/PlusView.swift` | benefits list | Plus closet + parent history lines | W4 |
| `Core/Purchases/Entitlements.swift` | `PlusCatalog` | 2 static sets (§MochiWardrobe) | W0 |
| `VocabLoopUITests/VocabLoopUITests.swift` | `setUp` | `app.launchArguments += ["-uiTestingFlipOnly"]` | W1 |
| `docs/WIDGET.md` | rewrite §1–4 to the snapshot design | W2 |
| `VocabLoop.xcodeproj/project.pbxproj` | **untouched in 1.0.7** | — |

### 2.5 StudyViewModel contract (W1)
New state: `currentQuestion: Question?`, `questionShownAt: Date?`, `combo: Int`,
`comboBeforeLast: Int`, `bestComboThisSession: Int`, `events: [EngagementEvent]` (UI drains),
`opening: SessionOpening?`, `streak: StreakService.Streak`, `studiedToday: Bool`, `candyTotal: Int`,
`look: MochiLook`, `selectedOption: Int?`, `isQuestionAnswered: Bool`.
- `start(...)`: after `phase` is set → `opening = try? dependencies.engagement.sessionOpened(...)`;
  `try? dependencies.questions.prepare(...)`; `refreshQuestion(dependencies:)`; emit
  `.welcomeBack` once per day via UserDefaults.
- `private func refreshQuestion(dependencies:)` called wherever `refreshPreviews` is called (start,
  advance both branches, undo, skipCurrent): `currentQuestion = questions.make(for: card, policy:)`,
  `questionShownAt = now`, `selectedOption = nil`, `isQuestionAnswered = false`. For auto-graded kinds
  the answer side is revealed by `answer(optionIndex:)` / `submitTyped(_:)`, which set
  `isAnswerRevealed = true`, `isQuestionAnswered = true`, compute the `Rating` with `AutoGrader` and
  store it as `pendingAutoRating`; **`continueAfterAnswer(dependencies:)`** then calls `grade`.
- `grade(_:dependencies:now:)`: unchanged up to `Haptics.tap()`; then `comboBeforeLast = combo`;
  `combo = rating == .again ? 0 : combo + 1`; if combo dropped from ≥ 5 → `events.append(.comboEnded)`;
  build `ReviewOutcomeEvent` (maturity before from `card.maturity` captured before the service
  call; after from `card.maturity` after) → `events += try engagement.record(...)`; sounds:
  `correct` for `.good/.easy` self-grades and auto-correct, `comboTier` on milestone, `goal` on
  `justReachedGoal`, `levelUp`/`badge`/`sticker` on those events. `durationMS` for auto-graded
  kinds = from `questionShownAt`.
- `undo`: `combo = comboBeforeLast`; `events.removeAll()`.
- Everything else (queue, refill, goal) untouched.

---

## 3. Workstreams

**W0 — Foundation (lands first, alone, one `[full ci]`).** Owns: every file under
`Core/Engagement/`, `Core/Services/QuestionGenerator.swift`, `AutoGrader.swift`,
`SoundService.swift`, `WidgetSnapshotWriter.swift`, `scripts/sounds.py`,
`Resources/Sounds/*.wav`, and the touch points marked W0 in §2.4 (`PersistenceController`,
`StudyPreferences`, `AppDependencies`, `Entitlements`, `Mascot.init` signature). Delivers every
signature in §2.2 compiling, with **real bodies for the pure parts** (`RewardEngine`,
`AutoGrader`, `TypedAnswerMatcher`, `QuestionGenerator.kind/pickDistractors/seed`,
`CollectionService.pageAlbums`, `AchievementCatalog`, `MochiWardrobe`, `SharedStorage`,
`WidgetSnapshotWriter`, `SoundService` complete) and **minimal-but-correct bodies** for the
store-backed parts (`profile()`, `sessionOpened`, `record` doing candy + lastStudiedAt + save only;
`CollectionService.albums/progress` wired to `pageAlbums`; `WeeklyRecapService.recap` returning
counts from `StudyDay` only). After W0 merges, these files are frozen for W0's owner only; other
workstreams request changes rather than editing. Tests (new `VocabLoopTests/`):
`RewardEngineTests` (curve values, milestones, bonuses), `AutoGraderTests` (table of §1.5, never
`.easy`, edit-distance cases), `QuestionGeneratorTests` (kind rules incl. `.new`/learning → flip,
flipOnly, determinism of `pickDistractors`, exclusion rules), `CollectionPagingTests` (page size,
family mapping, C2→C1, ordering), `EngagementProfileSchemaTests` (in-memory container with the new
schema opens; `profile()` creates once), `WidgetSnapshotTests` (round-trip). Acceptance: CI green;
`PaletteContrastTests` untouched; `applyDailyGoalDefaultOnce`-style launch unaffected.

**W1 — Study loop, questions, sounds-in-UI.** Owns: `StudyViewModel.swift`,
`StudySessionView.swift`, `Features/Study/QuestionCardView.swift`, `MultipleChoiceView.swift`,
`TypedAnswerView.swift`, `ComboBanner.swift`, `StreakFlame.swift`, `RewardToast.swift`,
`VocabLoopUITests.swift` (one line). May touch: `QuestionGenerator.make` body only if a bug
(coordinate with W0). Depends on W0. Acceptance: fresh install opens on `Show answer` (UI test
`testGuestCanReachTodayWithoutAnAccount` passes with and without `-uiTestingFlipOnly`, because
new/learning cards are always flip); all four rating accessibility labels unchanged; choice
questions show exactly 4 options with accessibility labels `Option 1: …`; Continue button label
`Continue`; combo banner hidden below 3; flame grey→orange on first review; `RewardToast` never
blocks the rating bar; `-uiTestingFlipOnly` honoured. Tests: `StudyViewModelComboTests` (combo
up/reset/undo, `comboEnded` at ≥ 5), `StudyViewModelAutoGradeTests` (option tap → rating → card
re-queued on wrong, `durationMS` from question shown), `StudyViewModelQuestionTests` (first cards of
a fresh in-memory graph are `.flip`).

**W2 — Engagement core, streak nudge, recap data, widget snapshot.** Owns full bodies of
`EngagementService.swift`, `Achievements.swift` conditions, `WeeklyRecapService.swift`,
`NotificationService.swift`, `docs/WIDGET.md`. Depends on W0. Acceptance: `record` implements the
full §2.2 order; week rollover resets weekly fields; first-review bonus once per day; sticker/album
events fire exactly on the young→mature crossing; achievements unlock once; streak reminder
scheduled only when `streak ≥ 2 && !studiedToday && streakReminderEnabled`, removed on review;
snapshot file written after each grade. Tests: `EngagementServiceTests` (candy totals for a
scripted day, level-up event, first-review bonus idempotence, undo-free invariants),
`AchievementCatalogTests` (each condition met/unmet, no double unlock), `WeeklyRecapTests`
(`masteredCount` from logs, window boundaries with `pinToUTC`), `StreakReminderTests`
(`streakReminderFireDate` 19:30 / 18:30 collision / next day when past).

**W3 — Mochi, wardrobe, sticker book, badges UI.** Owns: `Mascot.swift` (drawing only),
`DesignSystem/MascotAccessories.swift`, `Features/Mochi/*`, `Features/Collection/*`,
`Features/Achievements/*`, and the `CollectionService` fetch bodies (`albums`, `album(containing:)`,
`progress`, `summary`, cache). Depends on W0. Acceptance: every accessory renders at 58×48 and
160×133 without clipping; stage drawings differ visibly; wardrobe shows locked items with level or
"Plus" label and never a buy button for kids (Plus items link to `PlusView`); sticker grid 3×4;
album header shows `7 / 12`; `AchievementsView` lists all 16 with locked/unlocked states; all
decorative art `accessibilityHidden`; Reduce Motion respected. Tests: `CollectionServiceTests`
(albums for a seeded language, progress states, completion), `WardrobeTests` (unlock rules, one per
slot, Plus gating via `Entitlements(defaults: nil)`), `PaletteContrastTests` extended with the four
family tints and sticker text (≥ 4.5:1).

**W4 — Recap, parent, settings and library surfaces.** Owns: `Features/Recap/*`,
`Features/Parents/*`, `SettingsView.swift`, `HomeView.swift`, `StatsView.swift`, `PlusView.swift`,
`GoalCompleteView.swift`. Depends on W0 (and W2 for real numbers; builds against the W0 stub
otherwise). Acceptance: Progress shows the recap card; share produces a 1080×1350 image with
headline, 7 dots, Mochi, 3 nailed words; parent gate blocks three wrong answers; report shows
the §1.10 fields; Plus-gated history/export show the Plus row, not a dead button; new toggles
persist through `savePreferences()`; UI tests `testEveryTabIsReachableAsAGuest` and
`testAccountScreenOffersSignInWithoutRequiringIt` still pass (Settings keeps its `Guest` row).
Tests: `ParentGateTests` (pure question/answer logic), `RecapHeadlineTests` (0/1/n wording).

**Shared hot file ownership summary**: `StudySessionView`/`StudyViewModel` → W1 ·
`SettingsView`/`HomeView`/`StatsView` → W4 · `AppDependencies`/`PersistenceController`/
`StudyPreferences` → W0 (frozen after) · `Mascot.swift` → W0 signature then W3 · `NotificationService`
→ W2 · `project.pbxproj` → nobody.

---

## 4. Integration, release order, risks

**Order**: (1) W0 branch → `[full ci]` → merge. (2) W1–W4 in parallel on `claude/w1…w4`, each
reviewed by reading only (no local build) with a checklist: every new symbol exists in §2.2 with
the same spelling; no `switch` over a W0 enum without `default` unless exhaustive today; every
`Color`/`Font` token exists in `Palette`/`Typography`. (3) Merge order **W2 → W3 → W1 → W4** into
an integration branch, one `[full ci]`. (4) Fix round (expect ≤ 1). (5) Bump version to 1.0.7,
release workflow. Budget: 3–4 full CI runs.

**Risks and mitigations**
- *Compile hotspots*: `@Model` default-value expressions must be literals or static lets (done
  for `ReviewLog`; keep to that); `[UnlockedAchievement]` follows the `[ExampleSentence]` precedent;
  no `#Predicate` on the new model beyond `userID ==`; `Mascot` keeps `drawFace` exhaustive (no new
  `Mood` case — "misses you" is a toast); `ImageRenderer` only from `@MainActor` views; AudioToolbox
  import is `import AudioToolbox` and `SystemSoundID` is `UInt32`; `ShareLink` with `Image` requires
  `Transferable` — share a `URL` to a PNG written in `temporaryDirectory` instead.
- *SwiftData migration*: new entity + defaulted attributes only. The quarantine fallback in
  `makeContainer` remains the backstop; `EngagementProfileSchemaTests` opens the full schema.
  Nothing is renamed, no optional→non-optional, no unique constraint added to an existing model.
- *FSRS integrity*: auto grades never exceed `.good`; quizzes never on new/learning cards; candy is
  rating-agnostic; combo bonuses are small and milestone-only; Forgot has no sound, no error
  haptic, no sad face. Review of `AutoGraderTests` is a release gate.
- *UI test stability*: new/learning cards are flip by rule, plus `-uiTestingFlipOnly`; existing
  button labels (`Show answer`, `Open library`, rating accessibility labels, `Guest`, `Add`,
  `Back to studying`) are unchanged; `RewardToast` is `allowsHitTesting(false)` and auto-dismisses;
  the Mochi button has `accessibilityLabel("Mochi")` and is not in the tab bar.
- *App Review*: parental gate before the parent report; Plus items are described, purchase only
  in `PlusView` (existing StoreKit flow); notifications remain opt-in from Settings; no streak-loss
  wording; sounds respect the silent switch; everything offline; `PrivacyInfo.xcprivacy` unchanged
  (UserDefaults keys are UI state, already declared reason).
- *Performance*: `QuestionGenerator.prepare` is one fetch per session (~3 k rows → light structs);
  `CollectionService` caches albums per language; `WeeklyRecapService` fetches `ReviewLog` by date
  range only; `EngagementService.record` adds one row update + one save per grade.
- *Widget*: deferred; the snapshot file and `WidgetMochiView` make 1.0.8 a project-file-only task
  done in Xcode per `docs/WIDGET.md`.
