# Architecture — VocabLoop

## Layers

```
┌─────────────────────────────────────────────────────────────┐
│ Features/            SwiftUI views + @Observable view models │
├─────────────────────────────────────────────────────────────┤
│ DesignSystem/        tokens + reusable components            │
├─────────────────────────────────────────────────────────────┤
│ Core/Services        ReviewService, DailyWordService, Stats… │
│ Core/Auth            AuthService over AuthBackend            │
│ Core/Sync            SyncEngine over APIClient (outbox)      │
├─────────────────────────────────────────────────────────────┤
│ Core/SRS             Scheduler protocol · FSRS-5 · SM-2      │
│                      pure value types, zero dependencies     │
├─────────────────────────────────────────────────────────────┤
│ Core/Models          SwiftData @Model entities               │
│ Core/Persistence     container, seed import, migration plan  │
└─────────────────────────────────────────────────────────────┘
```

Dependency rule: arrows point **down only**. `Core/SRS` imports nothing but
`Foundation` and knows nothing about SwiftData — that is what makes it testable in
isolation and replaceable.

## Composition root

`AppDependencies` is created once in `VocabLoopApp` and injected through the
SwiftUI environment. It owns the `ModelContainer`, the `AuthService`, the
`SyncEngine`, and the service objects. Nothing in the app reaches for a singleton.

## Data model

```
Entry (unique stableID)  ──1:N──▶  Sense  ──▶  [Example] (embedded Codable)
  │ languageCode, headword, phonetic, cefr, frequencyRank, grammarNotes
  │
  ├──1:N──▶  Card  (one per direction: .recognition / .production)
  │            │ due, stability, difficulty, reps, lapses, state, schedulerID
  │            └──1:N──▶  ReviewLog   (append-only)
  │
  └──N:M──▶  Deck  (built-in packs and user decks)

UserAccount ──1:1──▶ StudyPreferences
DailyBatch  (per user × date × language, deterministic)
SyncOutboxItem (durable write queue)
```

`Card` carries the scheduler state as plain stored properties rather than an
encoded blob so it is queryable (`due < now`) and inspectable in the debugger.
`SchedulingState` is the value type the scheduler works with; `Card` converts to
and from it at the boundary.

## Concurrency

- Views and view models are `@MainActor`.
- Seed import and statistics aggregation run on a `ModelActor`
  (`ImportActor`, `StatsActor`) with their own `ModelContext`.
- `Core/SRS` types are `Sendable` value types with no shared state.
- `SyncEngine` is an `actor`.

## Testing

`VocabLoopTests` covers the layers that carry the risk:

| Suite | What it pins down |
| --- | --- |
| `FSRSTests` | Initial state, monotonicity in rating, `R` decay, retention→interval inversion, difficulty clamping, post-lapse stability ≤ prior stability |
| `SM2Tests` | Ease-factor floor, interval ladder, lapse reset |
| `FuzzTests` | Determinism per card, spread stays inside bounds |
| `ReviewQueueTests` | Ordering, per-session caps, learning-step interleaving |
| `DailyBatchTests` | Determinism per (user, date, language); no repeats |
| `AuthTests` | PBKDF2 round-trip, constant-time verify, validation rules, guest adoption |
| `SeedLoaderTests` | Idempotent import, version bump re-import, all bundled packs parse |
| `StreakTests` | Timezone/day-boundary correctness, freeze behaviour |
| `SyncOutboxTests` | Ordering, retry/backoff, append-only log merge |

Run: `xcodebuild test -scheme VocabLoop -destination 'platform=iOS Simulator,name=iPhone 16'`
