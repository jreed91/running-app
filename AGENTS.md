# AGENTS.md

This file provides guidance to coding agents working in this repository.

## Purpose

Stride is a fully native iOS running coach app built with Swift and SwiftUI. It tracks running and strength workouts, imports/syncs HealthKit workouts, generates adaptive training plans, records weather, and creates route options for:

- Maintain Fitness
- 5K
- Half Marathon
- Marathon

## Key Commands

```bash
# Generate Xcode project from project.yml (required after editing project.yml)
xcodegen generate

# Run unit and UI tests from the generated scheme
xcodebuild test -scheme Stride -destination 'platform=iOS Simulator,name=iPhone 17'

# Run only unit tests
xcodebuild test -scheme Stride -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:StrideTests

# Run a single Swift Testing test class
xcodebuild test -scheme Stride -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:StrideTests/PaceCalculatorTests

# Run UI tests
xcodebuild test -scheme Stride -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:StrideUITests

# Build for release/archive
xcodebuild archive -scheme Stride -archivePath build/Stride.xcarchive
```

GPS, HealthKit, WeatherKit, CloudKit, and background delivery behavior require device entitlements and may need a physical device. The simulator is suitable for pure logic tests and most UI flow checks.

## Project Configuration

The Xcode project is generated from `project.yml` using XcodeGen. Edit `project.yml` to add targets, files, capabilities, packages, or build settings. Do not hand-edit the generated `.xcodeproj`.

- Targets: `Stride` (app), `StrideWidgets` (widget extension — the run's Live Activity plus
  the Home Screen / Lock Screen widgets), `StrideTests`, `StrideUITests`. The app embeds the
  extension via a target dependency.
- `StrideWidgets` compiles `Stride/Core/Models/RunActivityAttributes.swift`,
  `Stride/Core/Models/WidgetSnapshot.swift` and `Stride/Resources/Assets.xcassets` from the
  app's tree: ActivityKit matches the two sides on the attributes *type*, the snapshot is the
  payload the app publishes for the widgets to read, and a widget bundle cannot read the app's
  asset catalog. Keep both Swift files free of app-only dependencies (Foundation only) or the
  extension stops building.
- App Group `group.com.running.stride` is the only channel between the app and the extension —
  a widget runs in its own process with its own container. Both targets declare it; see
  "Widget data flow" below.
- iOS deployment target: 27.0
- Xcode version in config: 27.0
- Swift: 6.0 with `SWIFT_STRICT_CONCURRENCY: complete`
- App target: iPhone only
- Bundle ID: `com.running.stride`
- CloudKit container: `iCloud.com.running.stride`
- Swift package dependency: Pulse (`Pulse`, `PulseProxy`, `PulseUI`) for diagnostics/log inspection
- Apple frameworks/capabilities include SwiftUI, SwiftData, HealthKit, CloudKit, WeatherKit, CoreLocation, background location, Sign in with Apple, App Intents, and local notifications

Route generation requires an OpenRouteService API key. It is entered at runtime
in **Settings → Route Genius API key** and stored in the Keychain via
`KeychainStore` (`AfterFirstUnlockThisDeviceOnly`) — never in `UserDefaults` and
never synced through iCloud KVS. No code reads `Stride/Resources/Secrets.plist`;
that path and its `.example` template are leftovers from an earlier design.

## Architecture

The app follows MVVM plus repository/service boundaries:

```text
View (SwiftUI)
  -> ViewModel or view-local state (@Observable where used)
      -> Repository protocol
          -> SwiftData store
          -> HealthKit store
      -> Service (pure Swift where possible, injected from AppContainer)
```

`AppContainer` (`Stride/App/AppContainer.swift`) is the dependency-injection root. It is created once at launch and injected through SwiftUI environment as `.appContainer`. It owns the `ModelContainer`, repositories, and long-lived services.

Business logic belongs in services or repositories, not directly in SwiftUI views. Keep plan generation, pace math, route generation, workout sync, analytics, and migration behavior unit-testable.

## Key Directories

| Path | Contents |
| --- | --- |
| `Stride/App/` | `@main` app entry point, `AppContainer`, UI testing support |
| `Stride/Core/Models/` | SwiftData `@Model` classes, shared enums, codable value types |
| `Stride/Core/Repositories/` | SwiftData and HealthKit CRUD behind protocols |
| `Stride/Core/Services/` | Plan generation, pace math, workout tracking/sync, notifications, analytics, routes, weather, AI coach, migration, logging |
| `Stride/Features/` | SwiftUI feature modules: Dashboard, Training, ActiveRun, ActiveStrength, History, Progress, Settings, Onboarding, AppIntents |
| `Stride/Shared/` | Reusable components, extensions, icons, theme primitives |
| `StrideWidgets/` | Widget extension target — the run's Live Activity (Lock Screen + Dynamic Island) and the Home Screen / Lock Screen widgets |
| `StrideTests/` | Unit tests using Swift Testing (`@Test`, `#expect`) |
| `StrideUITests/` | UI tests using XCTest and `XCUIApplication` |
| `ci_scripts/` | Xcode Cloud helper scripts |

## Core Domain Types

`Stride/Core/Models/Enums.swift` contains shared enums:

- `RaceType`: `.maintainFitness`, `.fiveK`, `.halfMarathon`, `.marathon`
- `PlanKind`: `.standard`, `.pregnancy` — *which generator built the plan*, a separate axis from
  `RaceType`, which is *what the runner is training for*. See "Pregnancy plans" below.
- `FitnessLevel`: `.beginner`, `.intermediate`, `.advanced`
- `WorkoutType`: `.easy`, `.tempo`, `.interval`, `.longRun`, `.race`, `.rest`, `.crossTraining`, `.strength`
- `TrainingPhase`: `.base`, `.build`, `.peak`, `.taper`
- `RouteType`: `.loop`, `.outAndBack`
- `WorkoutLocation`: `.outdoor`, `.indoor`
- `UnitPreference`: `.metric`, `.imperial`
- `AIProvider`: `.appleOnDevice`, `.applePrivateCloud` (Apple Foundation Models only — no third-party providers or API keys)
- `StrengthEquipment` and `StrengthFocus`

`Stride/Core/Models/ValueTypes.swift` contains codable/sendable value types used inside SwiftData models:

- `Coordinate`: `CLLocationCoordinate2D` storage wrapper
- `Split`: one bucket per kilometre or per mile, closed automatically by `SplitBucketing`
- `Lap`: a boundary the runner marked by hand mid-run (A2). Deliberately *not* a `Split`:
  splits close on distance whether or not anyone asked, laps close where the runner said —
  the top of a rep, a turnaround, a track's lap line. `LapRecorder` builds them, and a run
  that was never lapped stores none rather than one lap restating the whole run
- `WorkoutSegment`, `WorkoutSet`, `WorkoutStructure`: structured run workout representation stored as JSON in `ScheduledWorkout`
- `WorkoutWeather`: weather snapshot attached to completed runs
- `RouteStep`, `GeneratedRoute`: route-generation results
- `StrengthExercise`, `StrengthWorkoutPlan`, `CompletedStrengthSet`: strength workout representation

`Stride/Core/Models/PregnancyPlanTypes.swift` holds the pregnancy vocabulary: `GestationalAge`
(weeks+days from the due date — a pregnancy plan's clock, the way `raceDate` is a race plan's),
`PregnancyTrimester`, `PregnancyEffort` (talk test + Borg range, the only intensity prescription
a pregnancy plan makes), `PregnancyRedFlag`, and `PregnancyContraindication`.

## Training Plan Logic

`TrainingPlanService` generates periodized plans:

1. VDOT-based paces derived from the user's estimated 5K time via `PaceCalculatorService`.
2. Phases progress through Base, Build, Peak, and Taper, scaled to week count.
3. Weekly volume uses progressive overload with regular cutback weeks.
4. Plans balance easy/long running with quality work such as tempo and intervals.
5. Adaptation logic in `AppContainer.adaptedWorkout(scheduled:history:profile:)` adjusts scheduled workouts based on recent run history.

### Pregnancy plans

`PregnancyPlanService` is a **sibling** of `TrainingPlanService`, not a mode of it. A race plan
periodises upward toward a fixed date and prescribes by VDOT-derived pace; a pregnancy plan
tapers downward toward an estimated due date, prescribes by effort and duration, and has no
goal race, no intervals, and no race week. They share only the SwiftData models, which is what
lets the Plan tab, the widgets, history, and HealthKit sync handle a pregnancy plan without
knowing it is one.

Rules a change here has to keep — all of them sourced in
[`docs/PREGNANCY_RUNNING_EVIDENCE.md`](docs/PREGNANCY_RUNNING_EVIDENCE.md), which is the file
to read *before* touching any number in `PregnancyRunningPolicy`:

- **Every number carries its source.** `PregnancyRunningPolicy` is deliberately a wall of
  constants with citations attached rather than logic scattered through the generator. A
  prescription in a health feature with no source behind it is what that arrangement exists to
  prevent.
- **`TrainingPlan.planKind` is the discriminator**, not `RaceType`. A pregnancy plan carries
  `.maintainFitness` as its race type because it genuinely has no goal race.
- **No pace targets, ever.** Pregnancy moves the pace–effort relationship week by week, so
  every generated session leaves `targetPaceLowerBound`/`targetPaceUpperBound` nil and
  prescribes minutes plus a talk-test effort. `PregnancyPlanServiceTests` asserts this.
- **Three things must never touch a pregnancy plan**: `TrainingPlanService.refreshPaces` (would
  write VDOT bands over it), `AdaptableWorkoutSelector` (gates both Smart Adapt and
  apply-coach-feedback, and returns no candidates for one), and anything that adds a race. Each
  guard is a one-line `plan.isPregnancyPlan` check and each is tested.
- **The screening gate is load-bearing.** `generatePlan` throws unless
  `UserProfile.pregnancyClearedAt` is set, so a future caller cannot route around
  `PregnancyPlanSetupView`. The contraindication and red-flag lists are reproduced in full and
  must not be summarised for a smaller screen — an abridged red-flag list reads as complete.
- Stride is not a clinician, and the copy says so on the plan, in setup, and in the doc.

Two entry points, and they must stay in step: **onboarding** (a "Specialized" section on the
goal step; picking it re-points steps 2 and 4 and the summary screen — see
`OBPregnancySubviews.swift`) and the **Plan tab's New Plan menu** (`PregnancyPlanSetupView`).
Both collect the same four inputs — due date, screening confirmation, pre-pregnancy weekly
minutes, habitual vigorous running — and both write them to `UserProfile` before calling the
generator. Onboarding also computes the plan's week span itself, to promise a number before
the plan exists; `weekCountBoundaries` in `PregnancyPlanServiceTests` is what keeps that
promise honest.

## Persistence and Sync

- SwiftData is the local persistence layer.
- CloudKit is used for private iCloud sync when enabled and available.
- `AppContainer` falls back from CloudKit to local storage and then emergency in-memory storage if needed.
- `WorkoutSyncService` imports HealthKit workouts and can surface pending review workouts through `AppContainer.pendingReviewWorkout`.
- Simulator builds intentionally disable CloudKit in `AppContainer.shouldUseCloudKit`.

## Widget Data Flow

The widget extension **cannot read the SwiftData store.** It is a separate process with its
own container, so the app publishes a snapshot and the extension renders it:

```text
SwiftData  →  WidgetSnapshotBuilder  →  WidgetSnapshot  →  App Group file
(app)          (pure, tested)            (Codable)          WidgetSnapshotStore
                                                                  ↓
                                             StrideSnapshotProvider  →  the four widgets
                                             (StrideWidgets, read-only)
```

Rules that fall out of it, and that a change here has to keep:

- **The snapshot ships finished strings, not raw metres and seconds** — the same choice
  `RunActivityAttributes.ContentState` makes. The app owns the unit preference and every
  formatter in the repo; the extension owns neither.
- **Except for dates.** Anything whose wording depends on *when it is read* — "Today", a race
  countdown — is stored as a `Date` and resolved at render time (`WidgetRelativeDay`,
  `RaceCountdown.daysRemaining(asOf:)`). The app is not running at midnight to rewrite the
  file, and the provider's timeline crosses each midnight itself.
- **All content decisions live in `WidgetSnapshotBuilder`**, which is pure and takes an
  injectable `now`/`calendar`. The extension does no logic beyond reading the file, so this is
  the whole of the widgets' testable surface (`StrideTests/WidgetSnapshotBuilderTests.swift`).
- **`WidgetRefreshService` only reloads WidgetKit when the snapshot actually changed.**
  Reloads are budgeted per widget per day; spending one on every foreground would mean the
  reload right after a run is the one that gets dropped.
- Refresh triggers: launch and active-plan change (`ContentView`), scene phase active and
  background (`ContentView`), and immediately after a run is saved (`ActiveRunView`).
  `AppContainer.resetAllData` clears the snapshot so the Home Screen is not the one place
  deleted data survives.
- A widget's `kind` string (`StrideWidgetKind`) is persistent identity. Changing one orphans
  every already-placed instance of that widget.

## Testing

Unit tests use Swift Testing, not XCTest:

```swift
@Test("Description of what is tested")
func testName() {
    #expect(condition)
    Issue.record("failure message") // for non-fatal failures inside guards
}
```

UI tests use XCTest in `StrideUITests/` and launch with `--uitesting`. `Stride/App/UITestingSupport.swift` contains app-side support for deterministic UI-test behavior.

A test that needs SwiftData goes through `StrideTests/TestStore.swift`, never through
`AppContainer.preview()` or a hand-rolled in-memory `ModelConfiguration` — both share one
store across the host and abort the whole run. It has two entry points, and the choice
matters for suite runtime:

- **`TestStore.makeContext()`** — the default. A bare `ModelContainer` over its own store
  file. Use it whenever a `ModelContext` is all the test needs.
- **`TestStore.makeContainer()`** — only when the test exercises a repository or service the
  `AppContainer` owns. Building one wires the app's entire service graph (audio session,
  notification delegate, CloudKit diagnostics, a long-lived observer task), all retained for
  the rest of the process.

Current unit coverage includes pace calculations, training plan structure/progression, route generation, AI coach behavior, strength library behavior, persistence graph, restore/deduplication, missed-workout detection, and app-container behavior. Add focused tests when changing shared services, repositories, SwiftData models, or cross-feature workflows.

## Navigation

Primary tab structure:

```text
TabView
├── Home / Dashboard
├── Plan / Training Plan
├── History
├── Progress
└── Settings
```

Active run and active strength experiences are launched from feature flows rather than persistent tabs.

## Swift 6 Concurrency Notes

Strict concurrency is enabled. Key patterns:

- `AppContainer` is `@MainActor final class`.
- Repositories and services should be `Sendable` or actor-isolated where appropriate.
- SwiftData model-context work should stay on the actor/context that owns it.
- Use `nonisolated(unsafe)` only for narrowly scoped static defaults, such as environment-key defaults.
- Be careful when adding closures stored on singleton services; avoid accidentally capturing hidden/test containers.

## Implementation Guidance

- Follow existing SwiftUI, SwiftData, and repository/service patterns.
- Prefer small feature-local views and services over adding large view bodies or unrelated global helpers.
- Keep generated project changes in `project.yml`; run `xcodegen generate` after project config edits.
- `Stride/Resources/Info.plist` and `Stride/Resources/Stride.entitlements` are generated by that command from the `info:` / `entitlements:` blocks in `project.yml`, and are gitignored like `Stride.xcodeproj`. Edit `project.yml`, never those files — direct edits are overwritten on the next generate.
- The app version and build number live in `ci_scripts/Version.xcconfig` (wired in via `configFiles`), not in `project.yml`'s `settings.base` — a project-level build setting would override the xcconfig.
- XcodeGen writes **one** `info:` / `entitlements:` block for every configuration, so anything whose value must differ between Debug and the archive needs a per-config build setting expanded from that block (entitlements go through build-setting expansion at packaging time). `aps-environment` is the live example: it reads `$(APS_ENVIRONMENT)`, which is `development` in Debug and `production` in Release. Hardcoding `development` there fails the Xcode Cloud archive at "Exporting for App Store Distribution", because an App Store profile only ever carries `production`. Info.plist keys can't use that trick, which is why the Pulse local-network keys are removed by a post-build script instead.
- **A new signed bundle needs an App ID registered before it can be exported.** Every target that ships inside the app — today that is the `StrideWidgets` extension — is signed separately and needs its own identifier at [developer.apple.com → Identifiers](https://developer.apple.com/account/resources/identifiers). Xcode Cloud's signing proxy is read-only, so automatic signing there can find an App ID but never create one: an unregistered identifier archives cleanly and then fails all three "Exporting for … Distribution" steps with `Automatic signing cannot register bundle identifier`. Register the identifier (and enable any capability the target's entitlements ask for) *before* the first archive, and again after any rename.
- **TestFlight "What to Test" is a changelog, and commit subjects are what testers read.** `ci_scripts/ci_post_xcodebuild.sh` turns the commits in each archive into a bulleted list in `TestFlight/WhatToTest.en-US.txt`. Merge commits are dropped (their subject names a branch, not a change) and `WIP`/`fixup!`/`squash!` subjects are filtered, so the line that reaches testers is the subject of a real commit — write it as something a tester could act on. Xcode Cloud exposes no "previous build" commit, so the range is taken from the newest `testflight/*` tag if one exists, else from the pull request HEAD merged, else the last 15 commits; pushing a `testflight/<build>` tag after a release makes the next build's range exact. Preview any build's notes with `CI_XCODEBUILD_ACTION=archive sh ci_scripts/ci_post_xcodebuild.sh`.
- **The App Group is a registration of its own.** `group.com.running.stride` must exist under [Identifiers → App Groups](https://developer.apple.com/account/resources/identifiers) and the **App Groups** capability must be enabled on *both* App IDs (`com.running.stride` and `com.running.stride.StrideWidgets`) before either can be exported. It fails exactly the way an unregistered bundle identifier does, and for the same reason: automatic signing can look a group up but never create one. Locally, a missing group is silent rather than fatal — `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` returns `nil`, the app skips its write, and the widgets show their "Open Stride to sync" card forever. If widgets are permanently empty on device, check this first.
- Keep secrets out of git and out of `UserDefaults`/iCloud KVS. Tokens belong in the Keychain via `KeychainStore`, the way the OpenRouteService key is handled.
- **User-facing text is localizable.** `Text("…")`, `Button("…")`, `.navigationTitle("…")`
  and friends take a `LocalizedStringKey`, so a literal written there is extracted into
  `Stride/Resources/Localizable.xcstrings` by the compiler and needs nothing else. A
  string built *outside* a view — a notification body, a spoken accessibility summary,
  alert copy assembled as a `String`, a Siri answer — is invisible to that extraction
  unless it says `String(localized: "…", comment: "…")`. Write it that way.
- Display names for the enums in `Enums.swift` come in two forms: `localizedName` for
  anything a runner reads, and `displayName` for anything a machine reads — AI prompts,
  logs, and the seeded race names in onboarding, which are compared and persisted and so
  must not move with the device language.
- Do not introduce new third-party packages without an explicit reason and a `project.yml` update.
- For frontend/UI work, match the existing theme primitives in `Stride/Shared/Theme/` and reusable components in `Stride/Shared/Components/`.

## Analysis Docs

`docs/` holds the standing reviews. Check them before starting work — a known
issue is usually already written up, with a recommended fix:

| Doc | Covers |
| --- | --- |
| [`docs/UX_ANALYSIS_2026-07-26.md`](docs/UX_ANALYSIS_2026-07-26.md) | UX and SwiftUI platform conformance (third pass): design-token adoption, Dynamic Type, contrast, haptics, iOS 26+ API. Systemic gaps rather than per-screen bugs. **All items closed** — two of them by a documented decision rather than by code, so read those before reopening them. |
| [`docs/APP_ANALYSIS_2026-07-24.md`](docs/APP_ANALYSIS_2026-07-24.md) | Current open bugs, UX issues, and cleanup (second pass). Start here. |
| [`docs/APP_ANALYSIS_2026-07.md`](docs/APP_ANALYSIS_2026-07.md) | First-pass audit; all numbered bugs fixed. Its design (§5) and coverage (§8) sections are still live. |
| [`docs/FEATURE_IMPROVEMENTS_2026-07.md`](docs/FEATURE_IMPROVEMENTS_2026-07.md) | Product/feature roadmap with shipped-status tracking. **The live one** — the two bug audits and the UX audit are closed bar items blocked on CI or a device, so this is where the remaining work is. Its header lists what is genuinely open. |
| [`docs/PREGNANCY_RUNNING_EVIDENCE.md`](docs/PREGNANCY_RUNNING_EVIDENCE.md) | The published guidelines and studies behind every number in `PregnancyRunningPolicy`, with each row mapped to the code rule it drives. **Read before changing any of those numbers** — and update the row in the same change. |
| [`docs/REPO_ANALYSIS.md`](docs/REPO_ANALYSIS.md) | Operational review: CI, secrets hygiene, test depth. |
| [`docs/CLOUDKIT_VALIDATION.md`](docs/CLOUDKIT_VALIDATION.md) | CloudKit sync validation steps. |

When you fix something listed there, mark the item **✅ FIXED** in place with a
one-line note on where the fix landed, rather than deleting it.
