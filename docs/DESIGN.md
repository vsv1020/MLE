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
`DesignSystem/Palette.swift`, each token has a light and dark value.

**Light is crayon on paper. Dark is chalk on a blackboard.** Dark mode is not the
light palette dimmed: paper is a light material, and forcing it dark just produces
dirty paper. A blackboard is the natural dark counterpart — the same hand-drawn
language with the material inverted, ink becoming chalk.

| Token | Light (paper) | Dark (board) | Use |
| --- | --- | --- | --- |
| `brandPrimary` | `#2A62A8` crayon blue | `#8FBEF0` chalk blue | Primary actions, active tab |
| `brandSecondary` | `#A9501C` burnt sienna | `#F0A868` chalk apricot | Accents, streak flame |
| `canvas` | `#F7EFDC` | `#1B211D` | Screen background |
| `surface` | `#FFFDF6` | `#262D28` | Cards, sheets |
| `surfaceRaised` | `#FCF6E9` | `#2F3831` | Nested/secondary cards |
| `textPrimary` | `#33291F` | `#F4F0E2` | Headlines, word forms |
| `textSecondary` | `#6B5C46` | `#C2BCA8` | Definitions, metadata |
| `textTertiary` | `#786A54` | `#A8A18C` | Timestamps, hints |
| `separator` | `#33291F` | `#C9C4B2` | **Drawn outlines**, not hairlines |

Two things about this table are deliberate and easy to get wrong when editing it.

The three surfaces are **close together** — much closer than the slate scale they
replaced. Paper does not come in three obviously different shades. The old gap
between `surface` and `surfaceRaised` was wide enough that `textTertiary` could not
clear 4.5:1 on the darker one without collapsing into `textSecondary`; tightening the
surfaces is what buys the third text tone its own identity (5.17:1 against 6.36:1).

`separator` is **full-strength ink**, not a tint of the background. In this system the
separator *is* the drawn outline, so it is the darkest token in the light palette and
the lightest in the dark one. Anything that used it expecting a faint hairline needs
an explicit opacity.

Crayon black is never actually black — `#33291F` is a very dark warm brown. That is
what keeps a screen from reading as a printed document.

### Rating colours

The four review ratings are the most semantically loaded colours in the app. They
are consistent everywhere — buttons, statistics, forecast bars, history rows.

**Bright fill, dark ink, hard edge** — one value per rating, not one per appearance.

| Grade | Face | Label | Fill (both) | Edge (both) |
| --- | --- | --- | --- | --- |
| 1 | 😖 | Forgot | `#FB7185` | `#881337` |
| 2 | 😐 | Slow | `#FBBF24` | `#92400E` |
| 3 | 🙂 | Got it | `#34D399` | `#065F46` |
| 4 | 😎 | Instant | `#60A5FA` | `#1E40AF` |

**The faces changed; the scale did not.** FSRS still receives `1…4`. What the old
labels asked for was metacognition — deciding whether a recall was "Hard" or "Good"
is a judgement about your own mental effort, and a child cannot make it consistently.
An inconsistent answer is noise, and noise in `G` is noise in every interval computed
afterwards. Adults gain too: "Slow" is a far more answerable question than "Hard".

The face is never alone — the label sits under it and the four keep fixed positions,
so the bar works with VoiceOver and without colour vision.

These used to be *darker* in light mode than the obvious 600-weight picks, for a
stated reason: the rating bar set its labels in white, and white needs a dark fill to
clear 4.5:1. So the four colours the user looks at hundreds of times a day were the
dullest in the app — dulled by the accessibility requirement, which is the worst way
to lose a palette argument.

Inverting the pairing wins both at once. `onRating` is dark ink in both appearances
(`#33291F` light, `#1B211D` dark — warm, so it belongs to the paper), and dark ink on
a 400-weight fill reads at **5.28:1 at worst** against the previous scheme's 4.83:1.
Brighter *and* more legible; the old scheme had it backwards.

`ratingEdge` is **mandatory wherever a rating fill is drawn**, not decoration. A
400-weight fill on paper is only 1.46:1 at worst, and these colours are not
just button backgrounds — they are the bars on the session summary and the history
dots in entry detail, graphical objects WCAG 1.4.11 holds to 3:1. Without an edge,
brightening the fills would have traded readable data for prettier buttons. The edge
clears 6.19:1 against every paper tone and 3.43:1 at worst against its own fill,
so the shape has a boundary from both sides. In dark mode the edge is redundant — the
fill is already 4.51:1 against the nearest board tone — but it is drawn anyway, because a
hard outline is the whole cel-shaded idea and dropping it in one appearance would make
the two look like different apps.

On the rating bar the edge's *weight* also carries the emphasis on Got it — 3.5pt
against 2pt — because in a well-scheduled deck Good is the answer four times out of five and
nothing said so. Visual only: making it easier to physically hit needs the row to
reflow, which is a decision worth feeling on a device first.

Red/green as the only difference between Forgot and Got it would fail for the most
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

**Depth: one level, three treatments.** A `CardContainer` is `.flat` (the original
soft token, `y 4, blur 16, 8% black`), `.sticker` (a hard offset edge, `y 3, blur 0`,
plus a 1.5pt outline), or `.crayon` (a `WobbleShape` outline at 2.5pt). Never two on
one card: a blurred shadow under a hard one turns a drawn edge into mud, which is the
usual way this look is got wrong.

`.crayon` is the house style and every current call site uses it. It is **not** the
parameter default — `.flat` stays the default so a new `CardContainer` never silently
inherits a decorative treatment. The screens that stay plain do so by construction
rather than by passing `.flat`: the trust surfaces (account, password,
delete-my-data) are built from `Form` and `Section` and never reach this type. That
is the right outcome — a screen that takes your password and then apologises for it
in crayon is worse than a plain one, and here it cannot happen by accident.

Both drawn styles exist for the same two reasons. A blurred shadow says
*photographic* and a hard one says *drawn*, so the edge is the cheapest
character-per-line in the whole system. And it fixes a real bug:
`Elevation.shadowColor` is a fixed `Color.black.opacity(0.08)` rather than an
adaptive colour, so on the dark canvas it is invisible and dark mode had **no depth
cue at all**. The drawn edge is an opacity on `textTertiary`, which adapts, so it
survives both appearances.

Every `CardContainer` call site is now `.crayon` — the eleven across Progress, Today,
the daily word and entry detail. `.sticker` is kept as the un-wobbled version of the
same idea, for anywhere a drawn outline is wanted without the hand-drawn character.

Minimum tap target 44×44pt, enforced by `PrimaryButton` and the rating bar.

---

## Information architecture

```
RootView
├─ Onboarding            (first launch only: language → level → summary)
├─ AuthLanding           (skippable — "Continue without an account" is equal weight)
└─ StudySessionView      ← the root. Opening the app lands on a card.
   └─ MainTabView        (the library, opened from the card's top bar)
      ├─ Today       (Home)      due count · daily words · streak
      ├─ Browse      (Dictionary) search · CEFR/POS/status filters · entry detail
      ├─ Decks                   built-in packs · custom decks · per-deck progress
      ├─ Progress    (Stats)     retention · forecast · heatmap · review counts
      └─ Settings                account · study · languages · notifications · data
```

**The card is the root.** This used to be `MainTabView`, so opening the app landed on
a dashboard with a button that started studying. Counting from the icon, a first
launch put seven screens between the user and their first word, four of which were
questions — including a demand to commit to a daily goal before seeing a single card.
There are none now. The session builds itself and everything else sits behind the
library button.

At the root the session has no close button, because there is nothing to close: the
queue refills rather than ending, and every answer is written to the store as it is
given. The leading control opens the library and returns you to a card. Leaving the
app *is* stopping — there is no "end session" step to perform.

Study is still not a tab. A visible tab bar during review is an invitation to abandon
the session, which is exactly why the tabs live one layer behind the card rather than
alongside it.

**Today is a dashboard, not a launcher.** It used to be the entry point and its whole
job was to get you into a session; the session is the root now, so it reports where
you stand and its button — "Back to studying" — dismisses the library rather than
presenting a second session on top of the first.

One path still presents its own session, because it genuinely is a different one:
**study ahead**. That used to be the *fallback* — `includeAhead: !hasWorkToDo` meant
that the moment you were caught up, tapping the card started reviewing cards that were
not due yet, making the most damaging action in the app its own default. It is now an
explicit choice, shown only when nothing is due and no new words remain, behind a
confirmation that states the cost: answering early tells the scheduler you retained a
card for longer than you did, so its intervals get less accurate.

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
