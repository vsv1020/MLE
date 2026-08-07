# What to build next

Ordered by (learning value × leverage from what already exists) ÷ cost. Every item says
what it depends on and what it would cost, and the last section says what I would *not*
build and why — that list is the more useful half.

Sources for the outside-world claims are at the bottom. Treat the "best Anki alternative
2026" genre with suspicion: most of those pages are content marketing published by
competing apps. Where a claim only appears in that genre, it is marked as such.

---

## Tier 0 — before any of this

**Make it compile and run.** The project has never been built. CI will produce the first
error list; until a session runs end-to-end on a simulator, every estimate below is
guesswork and every new feature multiplies the debugging surface.

Specifically worth verifying by hand once it launches, because they are the things a
compiler cannot check:

- A card actually moves through `new → learning → review` and the interval labels on the
  rating buttons match what the detail screen then shows.
- The daily batch is identical after force-quitting and relaunching.
- Sign up → sign out → sign back in preserves the cards studied as a guest.
- Dynamic Type at the largest accessibility size does not clip the rating bar.

---

## Tier 1 — the data is already being collected

### 1. On-device FSRS weight optimiser

The app's whole thesis is "the scheduler is a real model". Fitting the model *to the
individual* is where that thesis pays off, and `ReviewLog` was designed for exactly this
— every field an optimiser needs is already captured on every review.

Feasibility is settled: `fsrs-rs` has full training support, and at least one shipping iOS
app (Discito) bridges it via `swift-bridge` FFI for on-device optimisation. There is also
a pure-Swift FSRS port (`swift-fsrs`) for the scheduling half.

**This is where we can beat Anki rather than match it.** Anki makes you find the button and
press it. We know the review count, so we can offer it at the right moment and explain what
changed — "your memory holds words about 15% longer than the default assumes; intervals
have been adjusted."

Gate it on data volume: ~400 reviews is the current minimum, ~1,000 before the fitted
weights beat the defaults meaningfully, then re-fit each time the count doubles. Below that
threshold the honest UI is "keep studying — 620 more reviews and I can tune this to you".

Cost: moderate. An FFI dependency is the first non-Apple dependency in the project, so it
needs a real look at binary size and build complexity before committing.

### 2. Cloze cards — words in a sentence, not on their own

The strongest content-side gap, and the schema already holds what it needs: every sense
carries `examples` with translations. A cloze card blanks the target word in its own example
sentence.

Why it matters: retrieval in context forces deeper processing than an isolated word pair,
and it is the difference between recognising a word and being able to use it. It is also the
gap most often named in the Anki-alternative literature — Anki shows whatever you typed and
has no notion of context.

Implementation is genuinely small: a third `CardDirection` case, a prompt renderer that
masks the headword in the example string, and one seed-pack field for a hand-authored blank
where the automatic mask would be wrong (inflected forms — "borrowed" in a sentence about
`borrow`).

Cost: low. Highest learning-quality gain per line of code in this document.

### 3. Anki and CSV import

The target user is specific: someone who likes FSRS and dislikes AnkiMobile's price and
interface. That person already has a deck. Import is the adoption lever, and CSV import was
among the most-requested AnkiDroid features for years.

`.apkg` is a zip containing a SQLite collection — readable without a dependency. Mapping
Anki's `revlog` into `ReviewLog` matters more than the cards: it is what lets the optimiser
work on day one instead of after a month.

Cost: moderate, mostly in the long tail of note types.

---

## Tier 2 — platform surfaces, cheap and disproportionately visible

Since iOS 17 one `App Intent` can drive a widget button, a Control Centre control, and a
Live Activity button. Write the intent once and it lights up several surfaces.

### 4. Widget · Lock Screen · Control Centre
Due count, today's ring, and a tap that opens straight into a session. This is the single
best retention mechanism available to a study app, and it needs no new domain logic —
`StatsService.statistics` already returns everything a widget renders.

Cost: low. Needs a Widget Extension target and moving the store to an App Group so the
widget can read it — worth doing early, because retrofitting an App Group means migrating
the store file.

### 5. Apple Watch app
A vocabulary review is a 5-second interaction, which is exactly what a watch is good at.
Recognition cards and the four rating buttons fit the screen unchanged.

Cost: moderate. Needs the sync story between watch and phone thought through.

### 6. Share Extension + Spotlight
"Add this word to VocabLoop" from Safari, Books, or any text selection — sentence mining
from what the user is actually reading, which pairs directly with cloze cards. Spotlight
indexing via `CSSearchableIndex` makes the whole dictionary searchable from the home screen.

Cost: low. `SearchService.createUserEntry` already exists and is idempotent.

### 7. Live Activity during a session
Progress and streak on the Lock Screen and in the Dynamic Island while studying.

Cost: low, but honestly: this is polish. A review session is a foreground activity, so the
Live Activity is mostly decorative. Do it after 4–6.

---

## Tier 3 — the on-device model (optional, iOS 26+)

Apple's **Foundation Models** framework exposes a ~3B-parameter on-device LLM: free, no API
key, no network, private, with structured output via `@Generable`. For an app whose first
principle is "offline is the default, not a mode", this is the only form of generation that
does not violate the thesis — a cloud LLM would.

What it is genuinely good at, at that size:

- **More example sentences** for a word the user keeps failing, at their level.
- **Cloze blanks** chosen sensibly for hand-added words that have no example.
- **A one-line "why you might have missed this"** on a lapse — false friend, similar
  spelling, the `borrow`/`lend` direction problem.
- **Distractors** for a multiple-choice mode, which are tedious to author by hand.

Two hard constraints, both of which make this an *enhancement* and never a dependency:
it needs iOS 26 and an Apple-Intelligence-capable device, and the app targets iOS 17. So
every feature above must have a non-generated fallback, and `SystemLanguageModel.default
.availability` has to be checked rather than assumed. A 3B model also gets language facts
wrong, so anything it produces about a word should be presented as a suggestion the user can
reject — never written into the dictionary as fact.

**Also worth a look:** the on-device Translation framework, to fill in a translation when a
content pack lacks the user's native language. Cheaper and more predictable than the LLM for
that specific job.

---

## Tier 4 — content, which is the real bottleneck

146 entries is a demo, not a product. This is the item most likely to decide whether anyone
keeps using the app, and it is not a coding problem.

A content pipeline needs: a frequency list, definitions, examples, and translations, all
under a licence that permits redistribution. Wiktionary (CC BY-SA) and the various open
frequency lists are the usual starting point; the licence terms are a real constraint, not a
footnote, and attribution has to ship in the app.

The importer is already idempotent and version-gated, so shipping a content update is a
`version` bump. The hard part is upstream of that.

---

## Sync: use CloudKit, not the REST server I scaffolded

`SyncEngine` and `RemoteAuthBackend` assume a server we would have to build, host, secure
and pay for. For per-user data with no sharing between users, **CloudKit is strictly better**:
free, no server, no auth of our own, and it is what users expect of an Apple-platform app.

One real obstacle, and it is not small. SwiftData's CloudKit integration **rejects
`@Attribute(.unique)` outright** — the container refuses to load — and requires every
attribute to be optional or defaulted and every relationship optional. The schema currently
uses `.unique` in seven places:

```
Entry.stableID · Card.cardID · Deck.slug · UserAccount.userID
DailyBatch.key · StudyDay.key · SyncOutboxItem.itemID
```

Those constraints are load-bearing: idempotent seed import depends on `stableID` upserting
rather than duplicating, and that property is what makes content updates shippable.

The migration is tractable but deliberate: replace the constraint with explicit
fetch-then-update at each write site (which `SeedImporter` already does — it fetches by
`stableID` before deciding to insert), and add a uniqueness test per model so a duplicate
becomes a failing test rather than a silent data bug. Do this *before* there are users, or
not at all.

---

## What I would not build

- **Gamification** — leaderboards, lives, hearts, streak-loss pressure. `docs/DESIGN.md`
  commits to "calm, not gamified", and that is a positioning choice, not timidity. The
  streak already counts *any* review rather than a completed goal precisely so it rewards
  showing up instead of punishing a busy day. Adding loss aversion would undo that.
- **Image occlusion** — consistently among the most-requested Anki features, and the wrong
  product. It exists for medical students memorising anatomy diagrams. A vocabulary app has
  no diagrams.
- **"Generate a deck from this PDF"** — popular in the Anki add-on ecosystem. It is a
  different product: bulk card generation for exam cramming, versus a curated dictionary
  with a good scheduler. Building it would make the content packs pointless.
- **A REST sync server**, per the section above.
- **Pronunciation scoring** — attractive, but Apple's speech APIs give you transcription,
  not a pronunciation score. Building real scoring means acoustic modelling; faking it with
  "did the transcript match" gives learners confidently wrong feedback on exactly the sounds
  they most need help with. Better not to ship it than to ship it wrong.

---

## Status of the three picks

- **Cloze cards** — done. 100% coverage of the bundled content, language-aware masking,
  opt-in per user.
- **App Intents** — done, in the app target: Siri, Shortcuts and Spotlight work now.
  The Widget Extension target is documented in [`WIDGET.md`](WIDGET.md) rather than
  hand-written, for the reason given there.
- **Optimiser** — plumbing done: training-set construction, the readiness gate, CSV export
  and the apply path. The fit itself still needs the FFI decision.

---

## If I had to pick three

**Cloze cards** (Tier 1.2) — largest learning gain per line of code, and the schema already
holds the sentences.

**Widget + App Intent** (Tier 2.4) — the retention mechanism, and it needs no new domain
logic. Do the App Group move now rather than after there is data to migrate.

**The optimiser** (Tier 1.1) — the reason to have built the app this way. It needs review
data to be worth anything, so start the plumbing early and let the data accumulate.

---

## Sources

- [FSRS FAQ — AnkiWeb](https://faqs.ankiweb.net/frequently-asked-questions-about-fsrs.html) and
  [How many reviews for accurate optimization? — Anki Forums](https://forums.ankiweb.net/t/how-many-reviews-for-accurate-optimization/53320) — optimiser data thresholds
- [awesome-fsrs](https://open-spaced-repetition.github.io/awesome-fsrs/) — `fsrs-rs` training support, Discito's `swift-bridge` FFI optimiser, `swift-fsrs`
- [Apple Newsroom — Foundation Models framework](https://www.apple.com/newsroom/2025/09/apples-foundation-models-framework-unlocks-new-intelligent-app-experiences/) — on-device, offline, free of inference cost
- [Getting Started with Apple's Foundation Models — Kodeco](https://www.kodeco.com/53631607-getting-started-with-apple-s-foundation-models) — `@Generable` structured output, availability checks
- [The iOS 26 Widget Surface: One App Intent, Many Places](https://blakecrosley.com/blog/ios-26-widget-and-control-surface) — one intent across widget, control, Live Activity
- [AnkiDroid changelog](https://ankidroid.org/changelog.html) — image occlusion and CSV import as long-standing top requests
- [Designing Models for CloudKit Sync — fatbobman](https://fatbobman.com/en/snippet/rules-for-adapting-data-models-to-cloudkit/) and
  [SwiftData limitations](https://fatbobman.com/en/posts/key-considerations-before-using-swiftdata/) — `.unique` unsupported, optional/defaulted requirement
- Context and cloze: the claim that contextual retrieval retains better is well established
  in the wider literature, but the pages that surface on this search are mostly published by
  [Clozemaster](https://www.clozemaster.com/blog/cloze-deletion-vs-flashcards/) and
  [Rhythm Word](https://rhythmword.com/blog/anki-vs-spaced-repetition-apps), who sell cloze
  products. Treat the *effect size* they quote as marketing; the direction is not in doubt.
