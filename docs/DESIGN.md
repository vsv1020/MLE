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

**Bright fill, dark ink, hard edge** — one value per rating, not one per appearance.

| Rating | Fill (both) | Edge (both) |
| --- | --- | --- |
| Again | `#FB7185` | `#881337` |
| Hard | `#FBBF24` | `#92400E` |
| Good | `#34D399` | `#065F46` |
| Easy | `#60A5FA` | `#1E40AF` |

These used to be *darker* in light mode than the obvious 600-weight picks, for a
stated reason: the rating bar set its labels in white, and white needs a dark fill to
clear 4.5:1. So the four colours the user looks at hundreds of times a day were the
dullest in the app — dulled by the accessibility requirement, which is the worst way
to lose a palette argument.

Inverting the pairing wins both at once. `onRating` is now dark ink in both
appearances (`#0F172A` light, `#0B1120` dark), and dark ink on a 400-weight fill
reads at **6.63:1 at worst** against the previous scheme's 4.83:1. Brighter *and*
more legible; the old scheme had it backwards.

`ratingEdge` is **mandatory wherever a rating fill is drawn**, not decoration. A
400-weight fill on a light surface is only 1.52:1 at worst, and these colours are not
just button backgrounds — they are the bars on the session summary and the history
dots in entry detail, graphical objects WCAG 1.4.11 holds to 3:1. Without an edge,
brightening the fills would have traded readable data for prettier buttons. The edge
clears 6.47:1 against every light surface and 3.43:1 at worst against its own fill,
so the shape has a boundary from both sides. In dark mode the edge is redundant — the
fill is already 5.44:1 against the darkest surface — but it is drawn anyway, because a
hard outline is the whole cel-shaded idea and dropping it in one appearance would make
the two look like different apps.

On the rating bar the edge's *weight* also carries the emphasis on Good — 3pt against
1.5pt — because in a well-scheduled deck Good is the answer four times out of five and
nothing said so. Visual only: making it easier to physically hit needs the row to
reflow, which is a decision worth feeling on a device first.

Red/green as the only difference between Again and Good would fail for the most
common colour-vision deficiency, so the rating buttons always carry a text label
and a distinct position; colour is redundant reinforcement, never the sole signal.

Elsewhere in the palette several values *are* a step darker than the obvious 500/600
weights, and for the reason the ratings no longer need: `brandSecondary`,
`textTertiary` and the `new` maturity dot are used as **text or as a lone graphic**,
where there is nothing to put an edge on, so the tone itself has to clear the
threshold. The ratings escaped that constraint by not being text.

`PaletteContrastTests` measures every pairing in this document through
`UITraitCollection`, in both appearances, and fails the build if one slips. Text
pairings are held to 4.5:1; non-text UI — the maturity dots, the rating fills and
their edges — to WCAG 1.4.11's 3:1. The suite also asserts the *negative* cases: that
plain white would fail on a rating fill in both appearances, and that colouring chip
text with its own hue would still fail over its own tint. Both are shapes a real
regression already took, and a test that only checks the good values cannot see them
coming back.

---

## Typography

System fonts only — `SF Pro Rounded` for display, `SF Pro Text` for body. Every
size is a Dynamic Type text style so the whole app scales with the user's setting.
No `.font(.system(size:))` anywhere.

| Role | Style | Weight | Design |
| --- | --- | --- | --- |
| Word form on a flashcard | `.largeTitle` | `.bold` | `.rounded` |
| Screen title | `.title2` | `.heavy` | `.rounded` |
| Section header | `.headline` | `.bold` | `.default` |
| Definition | `.body` | `.regular` | `.default` |
| Example sentence | `.callout` | `.regular` | `.serif` italic |
| Phonetics | `.subheadline` | `.regular` | `.monospaced` |
| Metadata / CEFR chip | `.caption` | `.medium` | `.rounded` |
| Numeric statistic | `.title` | `.black` | `.rounded` + monospaced digits |
| Numeric statistic, small | `.title3` | `.heavy` | `.rounded` + monospaced digits |

Example sentences use a serif italic to separate "language being taught" from
"app chrome" at a glance — the single most useful typographic distinction in a
dictionary UI.

**Numerals and headings carry the extra weight; language does not.** Statistics and
titles run `.heavy`/`.black`, because heavy weight on SF Rounded is what makes a
number read as *drawn* rather than as data — and weight is the one lever that does
not fight Dynamic Type, unlike size. The word form, example, phonetics, caption and
chip styles keep their original weights deliberately: those carry the language being
taught, including Thai tone marks, where extra weight closes counters and costs
legibility.

---

## Layout and spacing

4pt base scale: `xxs 4 · xs 8 · sm 12 · md 16 · lg 24 · xl 32 · xxl 48`.
Screen gutter is `md` (16). Card corner radius `20`, nested `14`, chips `10`
(bumped from 8, which rendered almost square at chip size), buttons `14`.

**Depth: one level, two treatments.** A `CardContainer` is either `.flat` — the
original soft token, `y 4, blur 16, 8% black` — or `.sticker`, a hard offset edge
with no blur (`y 3, blur 0`) plus a 1.5pt `separator` outline. Never both on one
card: a blurred shadow under a hard one turns the cel-shaded edge into mud, which is
the usual way this look is got wrong.

`.sticker` exists for two reasons. A blurred shadow says *photographic* and a hard
one says *drawn*, so it is the cheapest character-per-line in the whole system. And
it fixes a real bug: `Elevation.shadowColor` is a fixed `Color.black.opacity(0.08)`
rather than an adaptive colour, so on the `#0B1120` dark canvas it is invisible —
dark mode had **no depth cue at all**. The sticker edge is an opacity on
`textTertiary`, which adapts, so it survives both appearances.

`.flat` remains the default, so opting in is per-screen. Applied on Progress, the
daily word and Today; deliberately *not* on the four raised cards in entry detail,
which are a trust surface and should stay quiet.

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
  and a speaker button. For production cards, the definition. For cloze cards, the
  example sentence with the word removed, plus the definition in `textTertiary` as
  the only help — without it the card is a guessing game. A single `Show answer`
  button pinned to the bottom safe area.
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

**Cloze blanks** are a fixed width, never scaled to the answer. A blank that grows with
the word leaks how many letters to produce and turns recall into a crossword clue. The
answer shown on reveal is the *surface form* found in the sentence — `lent`, not `lend` —
because that difference is most of what the card teaches; the lemma is shown beside it
when the two differ.

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
