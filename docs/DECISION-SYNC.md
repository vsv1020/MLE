# Decision needed: CloudKit or the REST server

**Status:** open. Nothing is blocked today — sync is off in the shipping build — but this has
to be settled **before there are real users**, because both options are a schema migration and
one of them is much cheaper with an empty database.

This document exists because the choice is not mine to make: it trades a running cost and an
account model against engineering time, and those are product decisions. What follows is the
cost of each path, measured against the code that exists now.

---

## The forcing constraint

SwiftData's CloudKit mirroring **rejects `@Attribute(.unique)`**. The store fails to open — it
is not a warning. Seven properties use it today:

| Model | Property | What the uniqueness is doing |
|---|---|---|
| `Entry` | `stableID` | Makes seed import idempotent — re-importing a pack must not duplicate a word |
| `Card` | `cardID` | One card per (entry, direction); `enroll` relies on it to be a no-op the second time |
| `Deck` | `slug` | Same, for bundled decks |
| `UserAccount` | `userID` | Every query in the app scopes by this |
| `DailyBatch` | `key` | `(userID, dayKey, languageCode)` — stops two batches for one day |
| `StudyDay` | `key` | `(userID, dayKey)` — stops two rollups for one day |
| `SyncOutboxItem` | `itemID` | Nothing, really. A UUID that is unique by construction |

CloudKit also requires every non-optional property to have a default value, and every
relationship to be optional. The models already satisfy the second; the first needs an audit.

---

## Option A — CloudKit (`.private` database)

**What it costs to build.** Drop the seven `.unique` attributes and enforce those invariants in
code instead. Six of the seven already have a fetch-then-decide path in front of them, because
the app never relied on catching a constraint violation:

- `SeedImporter` already fetches by `stableID` before inserting.
- `ReviewService.enroll` already does `if try context.card(cardID:) != nil { continue }`.
- `DailyWordService.batch` already fetches by `key` and returns the existing row.
- `ReviewService.studyDay` already fetches by `key` with `createIfMissing`.

So the constraint is mostly documentation of an invariant the code enforces anyway. What
genuinely changes is that a *merge from another device* can now produce duplicates, which needs
a de-duplication pass on merge — the standard CloudKit pattern, keyed on the same string, keeping
the oldest `createdAt`.

`SyncOutboxItem` disappears entirely under this option, and with it `SyncEngine`,
`SyncPayloads`, the push endpoint contract, and the outbox's whole class of bug — the growth
problem fixed in `676726b` would simply not exist.

**What it costs to run.** Nothing. It is in the paid developer account.

**What the user gets.** Sync across their own devices, automatically, with no account of ours.
Sign in with Apple already maps to the same `Session` type, so the auth story does not change.

**What they do not get.** No web client, ever. No sharing a deck with another person without
building on `CKShare`. No server-side anything — no cross-device analytics, no server-driven
content updates, no way for us to fix a corrupt store remotely.

## Option B — the REST server that is already scaffolded

**What it costs to build.** A server. `RemoteAuthBackend` and `SyncEngine` document the wire
contract in concrete request and response types, and both are written and unit-tested — but
neither has ever spoken to a real server, so treat "already scaffolded" as "the client half is
written", not as "half done". Plus: hosting, a database, migrations, backups, TLS, an
account-deletion endpoint that actually deletes, and a privacy policy that covers holding
review history on our machines.

**What it costs to run.** Real money, forever, proportional to users, for a feature most users
of a single-device vocabulary app will never notice.

**What the user gets.** Everything Option A gives, plus a possible web client, plus deck
sharing, plus the ability for us to diagnose problems.

**What they lose.** Their review history sits on someone else's computer. For this app that is
a real privacy cost with no compensating benefit to them.

---

## My recommendation

**Option A.** The app's entire design premise is that it works with the radio off; the sync
requirement is "my progress follows me to my new phone", which CloudKit satisfies exactly.
Option B's extra capabilities are all things we would build a business around, not things this
app needs, and it charges rent for them monthly.

The deciding argument is asymmetric risk: Option A **deletes** code (`SyncOutboxItem`,
`SyncEngine`, `SyncPayloads`, the outbox tests) and the bugs that live in it. Option B adds a
server to operate. When the cheaper option is also the one with less surface area, it usually
wins.

## If you pick A, do it now

The migration is: remove seven attributes, add a de-duplication pass, delete the outbox layer.
Against an empty database that is an afternoon. Against a database with users in it, it is a
data migration with a failure mode that loses someone's streak.

## What I have done in the meantime

Nothing that presumes an answer. The outbox is now correct and bounded either way, and every
invariant `.unique` was protecting is enforced in code with a test — which is exactly the work
Option A needs done first regardless.
