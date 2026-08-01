# UI design specification — VocabLoop

The visual system is defined in code under `VocabLoop/DesignSystem/`. This document
is the intent behind it; when the two disagree, the code is wrong.

---

## Design principles

1. **The card is the product.** Every screen either gets you to a card or gets out
   of the way. No screen is more than one tap from studying.
2. **One decision per screen.** A review screen asks exactly one thing: did you
   recall it? Nothing else may compete for that moment.
3. **Progress must be legible in under a second.** Streak, due count, and today's
   completion are visible on Home without scrolling.
4. **Offline is invisible.** No spinners, no "connect to continue", no empty
   states caused by the network. The only network-aware UI is one sync status row
   in Settings.
5. **Calm, not gamified.** Encouragement over pressure: no lives, no punitive
   countdowns, no streak-loss dark patterns.

---

## Colour

Semantic tokens only — views never name a raw colour. Defined in
`DesignSystem/Colors.swift`, each token has a light and dark value.

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `brandPrimary` | `#4F46E5` indigo 600 | `#818CF8` indigo 400 | Primary actions, active tab |
| `brandSecondary` | `#0F766E` teal 700 | `#2DD4BF` teal 400 | Accents, streak flame |
| `canvas` | `#F8FAFC` | `#0B1120` | Screen background |
| `surface` | `#FFFFFF` | `#151C2E` | Cards, sheets |
| `surfaceRaised` | `#F1F5F9` | `#1E293B` | Nested/secondary cards |
| `textPrimary` | `#0F172A` | `#F8FAFC` | Headlines, word forms |
| `textSecondary` | `#475569` | `#94A3B8` | Definitions, metadata |
| `textTertiary` | `#5F6B7F` | `#8290A8` | Timestamps, hints |
| `separator` | `#E2E8F0` | `#25324A` | Hairlines |

### Rating colours

The four review ratings are the most semantically loaded colours in the app. They
are consistent everywhere — buttons, statistics, forecast bars, history rows.

| Rating | Token | Light | Dark |
| --- | --- | --- | --- |
| Again | `ratingAgain` | `#DC2626` | `#F87171` |
| Hard | `ratingHard` | `#B45309` | `#FBBF24` |
| Good | `ratingGood` | `#048062` | `#34D399` |
| Easy | `ratingEasy` | `#2563EB` | `#60A5FA` |

Red/green as the only difference between Again and Good would fail for the most
common colour-vision deficiency, so the rating buttons always carry a text label
and a distinct position; colour is redundant reinforcement, never the sole signal.

Rating labels are set in `onRating` (white in light, `#0B1120` in dark), **not** in
plain white. The dark fills are light by design so they read against a dark canvas,
which makes white on them unreadable — white on dark-mode Hard measures 1.67:1.

Several values here are a step darker than the obvious 500/600 weights, for one
reason: they are used as *text*, and the lighter weights do not clear 4.5:1.
`PaletteContrastTests` measures every pairing in this document through
`UITraitCollection`, in both appearances, and fails the build if one slips. Text
pairings are held to 4.5:1; the maturity dots, being non-text UI, to WCAG 1.4.11's
3:1.

---

## Typography

System fonts only — `SF Pro Rounded` for display, `SF Pro Text` for body. Every
size is a Dynamic Type text style so the whole app scales with the user's setting.
No `.font(.system(size:))` anywhere.

| Role | Style | Weight | Design |
| --- | --- | --- | --- |
| Word form on a flashcard | `.largeTitle` | `.bold` | `.rounded` |
| Screen title | `.title2` | `.bold` | `.rounded` |
| Section header | `.headline` | `.semibold` | `.default` |
| Definition | `.body` | `.regular` | `.default` |
| Example sentence | `.callout` | `.regular` | `.serif` italic |
| Phonetics | `.subheadline` | `.regular` | `.monospaced` |
| Metadata / CEFR chip | `.caption` | `.medium` | `.rounded` |
| Numeric statistic | `.title` | `.bold` | `.rounded` + monospaced digits |

Example sentences use a serif italic to separate "language being taught" from
"app chrome" at a glance — the single most useful typographic distinction in a
dictionary UI.

---

## Layout and spacing

4pt base scale: `xxs 4 · xs 8 · sm 12 · md 16 · lg 24 · xl 32 · xxl 48`.
Screen gutter is `md` (16). Card corner radius `20`, nested `14`, chips `8`.
Shadows are a single soft token (`y 4, blur 16, 8% black`) — one elevation only,
because two competing elevations always look accidental.

Minimum tap target 44×44pt, enforced by `PrimaryButton` and the rating bar.

---

## Information architecture

```
RootView
├─ Onboarding            (first launch only: language → daily goal → level → reminder)
├─ AuthLanding           (skippable — "Continue without an account" is equal weight)
└─ MainTabView
   ├─ Today       (Home)      due count · daily words · streak · start review
   ├─ Browse      (Dictionary) search · CEFR/POS/status filters · entry detail
   ├─ Decks                   built-in packs · custom decks · per-deck progress
   ├─ Progress    (Stats)     retention · forecast · heatmap · review counts
   └─ Settings                account · study · languages · notifications · data
```

Study is deliberately **not** a tab. It is a full-screen modal cover launched from
Today or from a deck, because a review session must own the screen — a visible tab
bar during review is an invitation to abandon the session.

---

## Screen specifications

### Today

The only screen most users see on most days. Top to bottom:

1. **Greeting + date**, `title2`. Streak chip trailing (flame + day count, in
   `brandSecondary`; grey when the streak is at risk today).
2. **Ring card** — the primary CTA. A `ProgressRing` showing
   `reviewsCompletedToday / dailyGoal`, with the due count centred. Tapping
   anywhere on the card starts the session. Label reads `Review 24 cards`, or
   `All caught up` with a secondary "Study ahead" affordance when nothing is due.
3. **Daily words** — a horizontally paged carousel of today's new words. Each is a
   `surface` card: word form (`largeTitle`), phonetics, part of speech chip,
   primary definition, one example. Two actions: `Add to my words` (creates the
   cards) and a speaker button. Cards the user has accepted show a filled check
   and stay in place for the rest of the day rather than disappearing — vanishing
   content reads as a bug.
4. **Three stat tiles** — Learning · Young · Mature, matching the Progress screen's
   vocabulary so the two screens teach the same model.

### Study session

Full-screen cover. Chrome is one thin progress bar and a close button; nothing else.

- **Front:** the prompt only. For recognition cards, the word form plus phonetics
  and a speaker button. For production cards, the definition. A single
  `Show answer` button pinned to the bottom safe area.
- **Back:** the front content stays in place at the top (it must not jump) and the
  answer expands below it — definitions, examples, grammar notes. The rating bar
  replaces `Show answer` in the same position.
- **Rating bar:** four buttons in fixed order `Again · Hard · Good · Easy`, each
  labelled with the interval it would produce (`10m`, `1d`, `4d`, `9d`). Showing
  the consequence of each choice is what makes an SRS feel trustworthy instead of
  arbitrary.
- **Flip animation:** 0.3s ease-out opacity + 4pt rise. When `reduceMotion` is on,
  a cross-fade with no movement. Never a 3D flip — it obscures text mid-rotation.
- **Keyboard/gesture:** space or tap to reveal; `1–4` to rate on iPad hardware
  keyboards; swipe down to close with a confirm if the session is unfinished.
- **Summary on completion:** cards reviewed, accuracy, time, rating breakdown, and
  the next due time. One button back to Today.

### Browse

Search field pinned at the top with `.searchable`. Results are a plain list —
word form, phonetics, truncated primary definition, and a status dot (new /
learning / young / mature). Filter chips scroll horizontally beneath the search
field: CEFR level, part of speech, learning status. Empty search shows recently
viewed, then the full list alphabetically.

Entry detail is a scroll view: word form + phonetics + speaker, CEFR and frequency
chips, then one `surfaceRaised` block per sense (definition, examples, synonyms,
antonyms, grammar notes), then a scheduling section — current state, due date,
stability, difficulty, and the full review history. Exposing the scheduler state
is a deliberate trust decision: the user can always see why a card is due when it
is.

### Progress

Retention headline (`Recall accuracy, last 30 days`) with a sparkline; a 12-month
contribution heatmap of reviews per day; a 30-day due-count forecast as a stacked
bar chart coloured by card maturity; and counts by state. All computed locally
from `ReviewLog`.

### Settings

Grouped list: **Account** (profile, sign in / sign out, change password, export
data, delete account) · **Study** (daily goal, new words per day, scheduler
choice, desired retention, maximum interval, learning steps) · **Languages**
(active learning language, installed packs) · **Notifications** (reminder time,
daily-word push) · **Data** (storage used, re-import seeds, sync status) ·
**About**.

The scheduler section shows desired retention as a slider from 70% to 97% with
plain-language consequences beneath it ("Higher retention means more reviews") —
a raw percentage with no explanation is how you get users setting 99%.

---

## Motion

| Interaction | Motion |
| --- | --- |
| Card reveal | 0.3s ease-out, opacity + 4pt rise |
| Card advance | 0.25s slide left, next card slides in from right |
| Rating tap | Light impact haptic; success haptic on session complete |
| Progress ring | 0.6s spring on value change |
| Tab switch | System default |

Everything above collapses to a cross-fade under `reduceMotion`.

---

## Empty and error states

Every empty state names the action that resolves it — `EmptyStateView(icon:,
title:, message:, action:)`. Never a bare "No data".

- No cards due → "All caught up. Next review in 3 hours." + `Study ahead`
- No search results → "No match for 'xyz'." + `Add it as a custom word`
- Not signed in, on Account → "Studying as a guest. Your progress is saved on this
  device." + `Create an account to sync`

Error copy states what happened and what to do, and never blames the user. Auth
failures never disclose whether an email exists — one message for both cases.
