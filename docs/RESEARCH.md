# Research notes — offline vocabulary app for iOS

These notes capture the decisions that shaped the implementation, and *why* the
alternatives were rejected. They are meant to be read before changing anything in
`VocabLoop/Core/SRS` or `VocabLoop/Core/Persistence`.

---

## 1. The competitive landscape, and where the gaps are

| App | Memory model | Offline | Multi-language | Notable gap |
| --- | --- | --- | --- | --- |
| Anki (AnkiMobile) | SM-2, FSRS since 23.10 | Full | Any (user-authored) | Brutal UX; no curated content; no "daily word" |
| Quizlet | Leitner-ish "Learn" mode | Partial (paywalled) | Any | Scheduling is opaque and not evidence-based |
| Duolingo | Proprietary half-life regression | Weak | Many | Not a vocabulary tool; can't study your own list |
| Memrise | SM-2 derivative | Partial | Many | Content locked to their courses |
| Vocabulary.com | Adaptive, undocumented | No | English only | Online-only, English only |
| WordUp / Vocabulary Builder apps | Mostly fixed-interval or Leitner boxes | Varies | English only | Scheduling quality is the first thing cut |

The consistent gap: **a curated, well-designed consumer app whose scheduler is
actually a modern, published algorithm, and which works with the network off.**
That is the product thesis, and it dictates the two hard requirements below.

### Requirement A — offline is the default, not a mode
Everything that matters must work with the radio off: the whole dictionary, the
scheduler, review logging, streaks, statistics, and audio. Network is used for
*optional* account sync only. This rules out any design where content is fetched
per-word from a dictionary API at review time.

### Requirement B — the scheduler is a first-class, swappable component
Reviews are the product. The scheduler gets its own module, its own tests, and a
protocol boundary so the algorithm can be replaced (and the replacement compared)
without touching the UI.

---

## 2. Choosing the memory algorithm

### Candidates

**Leitner boxes / fixed ladders** (`1d → 3d → 7d → 21d …`)
Trivial to implement, and what most vocabulary apps actually ship. Rejected: the
interval ignores both item difficulty and the learner's actual recall, so easy
items are over-reviewed and hard items are under-reviewed. Measurably worse
retention-per-review than anything model-based.

**SM-2** (SuperMemo 2, Wozniak 1987 — the algorithm Anki used for 20 years)
Well understood, tiny (an ease factor and an interval per card), and completely
deterministic. Its weaknesses are known: ease factor drifts into "ease hell" on
lapse-prone cards, it has no notion of *retrievability* (how much you have
forgotten *right now*), and it cannot target a retention rate.

**FSRS** (Free Spaced Repetition Scheduler — Ye et al., the DSR model)
Models memory with three variables per card:

- **D**ifficulty — intrinsic hardness of the item, `1…10`
- **S**tability — days until recall probability decays to 90%
- **R**etrievability — current recall probability, a function of `S` and elapsed time

`R(t, S) = (1 + FACTOR · t/S)^DECAY` with `DECAY = −0.5`, `FACTOR = 19/81`

This power-law forgetting curve fits review-log data substantially better than
the exponential curve SM-2 implies. Crucially, FSRS inverts cleanly: given a
**desired retention** `r`, the next interval is

`I(r, S) = (S / FACTOR) · (r^(1/DECAY) − 1)`

so the user gets a real dial — "review me at 90% retention" — instead of an
opaque ease multiplier.

### Decision

**FSRS-5 is the default scheduler; SM-2 ships alongside it as a selectable
alternative.**

Rationale for shipping both:
1. FSRS is the better model and should be the default. It is the whole reason to
   build this app rather than another Leitner clone.
2. SM-2 is the honest baseline. Keeping it compiling and tested is what makes the
   `Scheduler` protocol boundary real rather than aspirational, and it gives us
   something to A/B against once we have review logs.
3. Users migrating from Anki decks understand SM-2's ease factor.

FSRS-5 specifically (19 parameters) rather than FSRS-6 (21): the FSRS-5 parameter
semantics and default weights are the ones I can state with confidence, and the
`FSRSParameters` struct takes the weight vector as data — moving to FSRS-6, or to
per-user optimised weights, is a parameter change plus a short-term-stability
tweak, not a rewrite. `decay` is already a stored parameter rather than a
constant for exactly this reason.

### What we log so weights can be optimised later

FSRS weights are meant to be **fit to the individual learner** (FSRS-rs does this
with gradient descent over review history). We cannot ship an optimiser in v1,
but we can make one possible later by logging, on every single review, everything
the optimiser needs:

`cardID, reviewedAt, rating, state before, elapsedDays, scheduledDays,
stabilityBefore/After, difficultyBefore/After, retrievabilityAtReview,
schedulerID, parametersVersion, durationMS`

This is `ReviewLog`. It is append-only and never pruned. Deleting it would make
per-user optimisation impossible forever, so it is treated as the app's most
valuable data.

### Interval fuzz

Without fuzz, cards introduced on the same day stay clumped forever and the
review load spikes. FSRS and Anki both apply a deterministic ±5%-ish spread that
widens with interval length. Ours is seeded from the card ID so it is stable
across runs (a card must not change its due date just because it was rescheduled
twice) — see `Fuzz.swift`.

---

## 3. Persistence: SwiftData vs Core Data vs SQLite

**SwiftData** (chosen). iOS 17+, `@Model` macro, `@Query` integrates with SwiftUI
observation, and `ModelActor` gives us a clean background-write story for the
seed import. It is Core Data underneath, so we keep the mature SQLite store and
the option to drop to `NSPersistentStore` APIs if we hit a wall.

Rejected: **raw SQLite/GRDB** — faster for a 100k-row dictionary, but we would be
hand-writing the change tracking and SwiftUI wiring that SwiftData gives us free,
and our working set (cards due today) is small.
Rejected: **Core Data directly** — same engine, much more ceremony, no benefit.

Known SwiftData constraints we design around:
- No `UNIQUE` constraint enforcement beyond `@Attribute(.unique)`, and unique
  attributes upsert rather than throw. We lean on that deliberately for
  idempotent seed import (`Entry.stableID` is unique).
- Predicates can't express everything. Queue building filters in Swift after a
  coarse fetch — fine at our data volume, and it keeps the queue rules readable.

### Seed content shipped in the bundle

Dictionary content ships as JSON in `VocabLoop/Resources/Seeds/`, imported on
first launch and re-imported (idempotently) when a pack's `version` increases.
JSON rather than a prebuilt `.sqlite` because it diffs in git, is trivial to
extend by hand, and lets a future content pipeline write it from any source.

---

## 4. Multi-language extensibility (en now; fr, th later)

The mistake to avoid is baking English into the schema. Design rules:

1. **`LearningLanguage` is data, not a type.** Every `Entry` carries a
   `languageCode`; every `Deck` and every query is scoped by it. Adding Thai is
   adding a seed pack and a case to `LearningLanguage`, not a new model.
2. **Script-specific concerns are declared per language**, not branched on at
   call sites: `usesLatinScript`, `hasTones`, `defaultVoiceIdentifier`,
   `sortLocale`, `wordSeparated` (Thai has no inter-word spaces — this flag is
   what stops us shipping a broken tokenizer later).
3. **Phonetics are a string plus a notation tag** (IPA for en/fr, RTGS/paiboon
   for th) rather than an IPA-shaped field.
4. **Grammar metadata is an open key/value bag** (`grammarNotes`). French needs
   gender, Thai needs a classifier, English needs neither. A fixed column set
   would force a migration per language.
5. **Cards are per (entry, direction)** so recognition and production can be
   scheduled independently — which matters far more in Thai than in English.

`fr_starter.json` and `th_starter.json` ship as small real packs, not as
placeholders, so the abstraction is exercised by the test suite today rather than
being discovered to be wrong in six months.

---

## 5. Authentication with offline as a hard requirement

The constraint that shapes everything: **a user who is offline, or who never
creates an account, must be able to study.** Auth therefore cannot gate the app.

Design:

- **Guest is a real, first-class session.** The app is fully usable with no
  account. Signing up later *adopts* the guest's local data rather than
  discarding it.
- **`AuthBackend` protocol with two implementations.**
  `LocalAuthBackend` is the default and is genuinely offline: email + password
  with PBKDF2-HMAC-SHA256 (210k iterations, per-user 16-byte salt, constant-time
  verify), records in the local store, tokens in the Keychain.
  `RemoteAuthBackend` speaks a documented REST contract for when a server exists.
  Same protocol, so the UI never learns which one is live.
- **Sign in with Apple** via `AuthenticationServices`, with the credential
  mapped into the same `Session` type. Required by App Store review guideline
  4.8 once we offer any third-party login.
- **Sessions live in the Keychain** (`kSecAttrAccessibleAfterFirstUnlock`) so
  they survive relaunch and are available to background refresh, and are cleared
  on sign-out and on account deletion.
- **Complete means complete**: sign up with validation, sign in, sign out,
  password reset, password change, email change, profile edit, session
  restoration, and account deletion (GDPR/App Store 5.1.1(v) requires in-app
  deletion) — plus data export.

Password rules follow NIST SP 800-63B rather than the usual symbol theatre:
minimum 8 characters, maximum not below 64, no composition rules, and a
block-list check against the most common leaked passwords.

---

## 6. Sync (scaffolded, not shipped-on)

Offline-first sync is where this kind of app usually breaks. The scaffold uses
the shape that survives:

- **Outbox / durable queue.** Local writes commit immediately and append a
  `SyncOutboxItem`; the engine drains the queue when reachable, with retry and
  exponential backoff. The UI never awaits the network.
- **Per-record `updatedAt` + `lastWriteWins` per field group** for preferences,
  and **append-only merge** for `ReviewLog` — review history genuinely is an
  event log, so it merges without conflict, which is the single biggest reason to
  model it as one.
- **Conflict on `Card` scheduling state resolves to the log**: replay the merged
  review log through the scheduler rather than trying to reconcile two `S`/`D`
  values. This is the payoff for logging everything in §2.

`SyncEngine` is present and tested against a stub `APIClient`; it is off until a
server exists.

---

## 7. Daily words

"Daily word" is a retention feature, and the trap is letting it fight the
scheduler for attention. Rules:

- A day's batch is **deterministic per (user, date, language)** — derived from a
  seeded shuffle so the same day always yields the same words, offline, with no
  server call, and identically after a reinstall.
- New words are drawn respecting the user's CEFR range and never repeat an entry
  already introduced.
- Accepting a daily word is what creates its `Card`s. Browsing does not, so the
  daily surface never silently inflates tomorrow's review load.
- The daily batch and the review queue are **separate surfaces** on Home: "learn
  new" vs "review due". Reviews always take visual priority, because skipping
  reviews is what actually loses the streak.

---

## 8. Accessibility and platform fit

Non-negotiable from the first commit, because retrofitting is what never happens:
Dynamic Type throughout (no fixed font sizes), VoiceOver labels on every
flashcard control, `reduceMotion` honoured on card flips, tap targets ≥ 44pt, and
contrast ratios ≥ 4.5:1 verified for both light and dark in the design system.

Audio uses `AVSpeechSynthesizer` — on-device, free, offline, and available in
every language we plan to support. Recorded audio would be better quality but
would have to be downloaded, which violates §1.
