# Handoff: take VocabLoop from green CI to Ready for Review

Paste everything below the line into whatever agent you're handing this to. It is written to be
self-contained — it does not assume the agent can read this repo's history or talk to me.

Everything stated as fact below was verified against the repository at commit `1244fee`. Anything
I could not verify from a Linux container with no Xcode is marked **UNVERIFIED** and carries the
check that settles it. Do not let the agent quietly upgrade those to facts.

---

## ROLE

You are working on **VocabLoop**, an offline-first iOS vocabulary app built with SwiftUI and
SwiftData. Your job is to get it from "builds and tests green in CI" to "submitted to the App
Store". You have macOS, Xcode 16+, a physical iPhone, and the owner is available to make account
and legal decisions.

Repository: `vsv1020/MLE`
Branch: `claude/english-vocab-ios-app-2r5um5`
Project: `VocabLoop.xcodeproj` (objectVersion 77, file-system-synchronized groups — new source
files need no pbxproj edit)

## VERIFIED CURRENT STATE

- CI is green at `1244fee`: builds on `macos-15` / Xcode 16.4, iOS 18.5 simulator, whole test
  suite passes. Workflow is `.github/workflows/ios.yml`.
- **The app has never run on a physical device.** Only a simulator, only in CI.
- `MARKETING_VERSION = 1.0`, `CURRENT_PROJECT_VERSION = 1`
- `PRODUCT_BUNDLE_IDENTIFIER = com.vocabloop.app`
- `CODE_SIGN_STYLE = Automatic`, and **`DEVELOPMENT_TEAM` is not set**
- No `Info.plist` file — generated via `GENERATE_INFOPLIST_FILE = YES` plus
  `INFOPLIST_KEY_*` build settings. Add Info.plist keys as build settings, not by creating a file.
- `Config/VocabLoop.entitlements` exists (Sign in with Apple) but is **not** referenced by
  `CODE_SIGN_ENTITLEMENTS`. This is deliberate: it lets the project build with a free Apple ID.
- iPhone portrait only; iPad all orientations. Category: Education.
- Uses PBKDF2-HMAC-SHA256 via CommonCrypto at 600,000 iterations for local password hashing.
- Stores nothing on any server. There is no backend. `APIConfiguration.baseURL` is nil.

## TASKS, IN DEPENDENCY ORDER

Do not reorder. Later tasks are blocked by earlier ones.

### 1. BLOCKER — The Sign in with Apple button will fail review

The button is on the auth landing screen and in Settings ▸ Account, but the entitlement is not
wired, so tapping it produces a "capability not enabled" error. A reviewer will hit this and
reject under guideline 2.1 (app crashes/non-functional features).

Ask the owner to pick one, then do it:

- **Ship it** — add the Sign in with Apple capability to the VocabLoop target (Xcode ▸ target ▸
  Signing & Capabilities ▸ + Capability), or set
  `CODE_SIGN_ENTITLEMENTS = Config/VocabLoop.entitlements`. Requires a paid account.
- **Cut it for v1** — remove `AppleSignInButton` from `AuthLandingView` and `AccountView`.

Note for the owner: guideline 4.8 only *requires* Sign in with Apple when the app offers another
third-party login. This app doesn't — email/password is entirely local — so cutting it is
compliant, not a compromise.

### 2. BLOCKER — There is no app icon

`VocabLoop/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` declares a single
1024×1024 universal iOS slot, and **the entire asset catalog contains zero PNG files**. App Store
Connect refuses a binary with no icon — this stops the upload, not the review.

Need one 1024×1024 PNG, no alpha channel, no pre-applied rounded corners (iOS masks it). Drop it
into the appiconset and confirm `Contents.json` references the filename.

### 3. BLOCKER — Privacy manifest is missing

There is no `PrivacyInfo.xcprivacy` anywhere in the repo. Required since May 2024 for any app
using a "required reason" API.

Audit the code for required-reason API use, then write the manifest. What I found:

- **`UserDefaults`** — used in `RootView` (`@AppStorage` for `onboarding.completed` and
  `auth.landingShown`), `OptimizerService` (`optimizer.reviewCountAtLastFit`), and
  `VocabLoopApp.resetFirstRunStateIfUITesting`. Category
  `NSPrivacyAccessedAPICategoryUserDefaults`, reason `CA92.1` (accessing your own app's data).
- **File timestamps** — check `DataExporter` and `SeedImporter`. `DataExporter` sets
  `URLResourceValues.isExcludedFromBackup`, which is a *write*, not a timestamp read. Confirm
  nothing reads creation/modification dates before deciding whether
  `NSPrivacyAccessedAPICategoryFileTimestamp` applies.
- Also declare: no tracking, no tracking domains, no data collected, no third-party SDKs.

Verify the completed manifest by building and checking it lands in the bundle.

### 4. BLOCKER — Export compliance key not declared

The app uses CommonCrypto, so every upload will halt on the encryption questionnaire until
`ITSAppUsesNonExemptEncryption` is set. Add it as `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption`.

**Do not decide the value yourself.** Authentication-only use of standard platform crypto
normally qualifies for the exemption, which would make this `false` — but it is a compliance
statement in the owner's name. Show them Apple's export-compliance documentation and have them
answer it.

### 5. BLOCKER — Apple Developer Program membership and team

99 USD/year. Then set `DEVELOPMENT_TEAM` to the 10-character Team ID. Nothing downstream exists
without this.

### 6. BLOCKER — Register the bundle identifier

`com.vocabloop.app` must exist on the developer account and be globally unique. If taken, change
it **before the first upload** — the identifier is permanent once a build is associated with an
App Store Connect record.

### 7. UNVERIFIED — App Intents metadata may not be generating

The build log at `1244fee` still contains:

```
appintentsmetadataprocessor: warning: Metadata extraction skipped.
                                      No AppIntents.framework dependency found.
```

`AppIntents.framework` *was* added to the app target's Frameworks build phase (pbxproj objects
`1A2B3C000000000000000030` and `...031`) and the warning persisted. Two possibilities I could not
distinguish without Xcode:

1. The processor wants a target dependency, not just a link, and the app target is still wrong.
2. The warning comes from a test target (which correctly does not link AppIntents) and the app
   target is now fine.

**The definitive check:** build the app, then look inside the product for
`Metadata.appintents`:

```
find "$(xcodebuild -showBuildSettings -scheme VocabLoop \
  | awk -F'= ' '/ BUILT_PRODUCTS_DIR/{print $2}')/VocabLoop.app" -name 'Metadata.appintents'
```

If it's absent, the four App Intents in `VocabLoop/Core/Intents/VocabLoopIntents.swift` and
`VocabLoopShortcuts` are invisible to Siri and Shortcuts. Fix it through the Xcode UI rather than
by hand-editing pbxproj — the UI writes the entries the build system actually expects. If you
cannot make it work quickly, say so: shipping without working Siri support is acceptable, silently
shipping a dead feature is not.

### 8. BLOCKER — Run it on a physical iPhone

Nothing has ever executed outside a simulator. Things that differ and that tests cannot catch:

- Keychain under `kSecAttrAccessibleAfterFirstUnlock` before the device's first unlock after boot
- Which `AVSpeechSynthesisVoice`s are actually installed (`SpeechService`)
- Haptics (`Haptics.swift` — no-ops in the simulator)
- Real disk pressure during the seed import at first launch
- **PBKDF2 at 600,000 iterations on real silicon.** Time sign-up and sign-in on the oldest device
  you support. If it's a visible stall, report the measured number — do not silently lower the
  iteration count, that is a security parameter and the owner's call.

Do a full manual pass: onboard, create an account, study ten cards, force-quit, reopen, confirm
the streak and progress survived. Then un-enrol a word and confirm its history is still in
Progress.

### 9. App Store Connect metadata

None of this is code; all of it blocks submission.

- **Privacy policy URL** — required for every app, no exception for one that collects nothing.
  Easy to write honestly here: everything stays on device, no server, no analytics, no
  third-party SDKs, no tracking.
- **Support URL** — required.
- **Screenshots** — 6.9″ iPhone required. **Do not use `docs/screenshots/`** — those are renders
  of a design mockup, not the app, and submitting images that don't match the build is a
  rejection. Real captures: the UI test `testCaptureEveryScreenForVisualReview` in
  `VocabLoopUITests` attaches every top-level screen to `TestResults.xcresult`. Point the test
  destination at a 6.9″ simulator and extract them with `xcrun xcresulttool`.
- **App privacy ("Data Collection")** — today the truthful answer is *Data Not Collected*. The
  account lives in the local SwiftData store and the Keychain and never leaves the device.
- **Age rating** — expect 4+. No shared user content, no web views, no ads.
- **Name, subtitle, description, keywords** — "VocabLoop" must be free as an App Store name. Lead
  the description with what is actually unusual: a real FSRS-5 scheduler and full offline
  operation, not the feature list every vocabulary app has.

### 10. Archive, TestFlight, submit

Bump `CURRENT_PROJECT_VERSION` on every upload attempt, including after a rejection.

```
xcodebuild -project VocabLoop.xcodeproj -scheme VocabLoop \
  -destination 'generic/platform=iOS' \
  -archivePath build/VocabLoop.xcarchive archive

xcodebuild -exportArchive \
  -archivePath build/VocabLoop.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist
```

Use Xcode ▸ Product ▸ Archive ▸ Organizer for the first one — the errors are far more readable.

Then install the uploaded build via **TestFlight internal testing** (no review needed) and use it
for a day before submitting. This catches Release-configuration and real-signing problems for the
cost of a day instead of a rejection cycle.

## ALREADY HANDLED — do not redo

Several of these are common rejection causes:

- **In-app account deletion** — guideline 5.1.1(v), two taps from Settings ▸ Account
- **Fully usable with no account** — guest is a real session, not a trial
- **No usage-description strings needed** — no camera, microphone, location, contacts or photos
- **Launch screen** — `INFOPLIST_KEY_UILaunchScreen_Generation = YES`
- **Category and orientation** — already set
- **Data export** — GDPR portability, written with `.completeFileProtection`, excluded from backup

## OPEN DESIGN DECISION — flag it, do not decide it

`docs/DECISION-SYNC.md` documents an unresolved choice between CloudKit and a REST server. It
matters *now* because shipping means real users, and both paths are a schema migration that is
cheap against an empty database and expensive against a populated one. The forcing constraint:
SwiftData's CloudKit mirroring rejects `@Attribute(.unique)`, and seven properties use it.

Raise this with the owner before task 5. Do not implement either path on your own initiative.

## RULES

- **Do not lower the PBKDF2 iteration count, weaken the Keychain accessibility class, or relax
  the HTTPS-only check in `APIConfiguration`** to make anything easier. If one of them is a real
  problem, measure it and report it.
- **Do not replace mockup screenshots with real ones in `docs/`** and call it done — the point of
  task 9 is store-dimension captures, and `docs/` is documentation.
- Run the existing test suite before and after every change you make. It is the only thing that
  has ever verified this code.
- When you hit something you cannot verify, say so explicitly and give the check that would
  settle it. Do not present an inference as a finding — the App Intents item above is in this
  document precisely because that mistake was already made once.
