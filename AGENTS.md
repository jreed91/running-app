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

# Compile the shipping configuration without archiving — what CI's `build-release`
# job runs, and the fastest way to catch a Debug-only declaration read by Release code
xcodebuild build -scheme Stride -configuration Release \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
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

Route generation needs no API key: by default `RouteGeniusService` builds loops and
out-and-backs from Apple Maps walking directions (`MapKitWalkingDirections`, behind the
`WalkingDirectionsProvider` protocol so tests can fake it). An optional OpenRouteService
key switches it to ORS. That key is entered at runtime
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
- `WorkoutType`: `.easy`, `.tempo`, `.interval`, `.longRun`, `.race`, `.rest`, `.crossTraining`,
  `.strength`, `.walk` — the last of which no generator ever prescribes; see "Walking workouts" below
- `TrainingPhase`: `.base`, `.build`, `.peak`, `.taper`
- `RouteType`: `.loop`, `.outAndBack`
- `WorkoutLocation`: `.outdoor`, `.indoor`
- `UnitPreference`: `.metric`, `.imperial`
- `AIProvider`: `.appleOnDevice`, `.applePrivateCloud` (Apple Foundation Models only — no third-party providers or API keys).
  `.applePrivateCloud` is the **default** for new installs; see "AI coaching models" below
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

`Stride/Core/Models/RunFeel.swift` is the runner's post-run "how did that feel?" answer, five
steps stored on `RunWorkout.feelRaw` (raw values are persisted — never renumber them).
`RunFeelSignal` is the one place that judges a rating against the session's intended type
(an easy run rated hard is a fatigue signal; a tempo rated easy means soft paces); the coach
read, the coach chat and both plan-adaptation prompts all read it through that type.

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
- `WorkoutSyncService` imports HealthKit workouts — runs, walks, and strength sessions — and can surface pending review workouts through `AppContainer.pendingReviewWorkout`. See "Walking workouts" below for the rules the walk half carries.
- Simulator builds disable CloudKit in `AppContainer.shouldUseCloudKit` — not because
  Simulator can't sync (Apple says it can) but because the unit-test suite runs there and
  builds real file-backed containers, which would otherwise write into the team's
  development container.
- **Every `ModelConfiguration` must name `cloudKitDatabase:`, including the ones that
  don't sync.** The parameter defaults to `.automatic`, which Apple documents as "enables
  managed CloudKit sync using the primary ubiquity container from the app's entitlements" —
  and `Stride.entitlements` names one. A configuration that omits the argument therefore
  syncs whatever it is called: this is how the local-only path, the tier-1 fallback, the
  simulator carve-out, `IntentDataProvider`, and the test fixtures all came to mirror to
  iCloud while Settings reported `Local Only`. Store opens in the app go through
  `AppContainer.makeConfiguration`, which decides this in one place; anything else says
  `.none` explicitly. See
  [`docs/CLOUDKIT_ANALYSIS_2026-07-28.md`](docs/CLOUDKIT_ANALYSIS_2026-07-28.md) §3 F1.
- **Changing the schema means redeploying it.** Adding a model type or a stored property —
  even an optional one — needs a run with `--init-cloudkit-schema` on a device and a
  **Deploy Schema Changes** in CloudKit Console before the build ships, because App Store
  builds see only the production environment. The release gate is in
  [`docs/CLOUDKIT_VALIDATION.md`](docs/CLOUDKIT_VALIDATION.md); deployment is additive-only
  and cannot be undone.

## Walking workouts

Walking workouts recorded in Apple Health are imported alongside runs (N38). They are
stored as `RunWorkout` rows carrying `WorkoutType.walk` — the same model, which is what
gives a walk the history row, the map, the splits and the heart-rate charts without a
second copy of any of it — and the whole feature rests on one invariant:

> **A walk is history, never training.**

The rules a change here has to keep:

- **`Sequence.runsOnly` and `RunWorkout.runsOnlyDescriptor()` are the two forms of that
  invariant**, in memory and in the fetch. Anything that means *running* — weekly volume,
  average pace, VDOT and the fitness trend, personal records, the streak, the coach's read
  on recent load, the widgets' week, the plan's pace refresh, Siri's totals — goes through
  one of them. Anything that means *what the runner recorded* — the History list, a
  deletion, the HealthKit dedup set — takes everything. Use the **descriptor** whenever the
  fetch is bounded: filtering a `fetchLimit`-ed result afterwards silently shortens the page.
- **`WorkoutType.countsAsRunning` is the predicate behind both**, and it is a different
  question from `isRunType`. `isRunType` asks "can an imported run complete a day scheduled
  as this?"; `countsAsRunning` is asked of recorded history. `.walk` is the case that makes
  the distinction earn its keep.
- **A walk never completes a plan day.** `WorkoutSyncService.linkToScheduledWorkouts` filters
  them out, the walk pass never calls it, and the run summary hides its link-to-plan button
  for a walk. `WalkImportTests` pins all three.
- **Walks import quietly**: no synced-run notification, no review sheet, no weather fetch.
  A banner per walk is what makes people turn notifications off.
- **The floor is `RunEffortPolicy.isRealWalk`, not `isRealRun`.** Runs are started on
  purpose so almost anything recorded is real; a walking workout is as readily the walk to
  the shop, so the floor is 400 m and five minutes.
- Import is on by default and switchable in **Settings → Data → Import Walks**
  (`AppSettings.walkImportEnabled`, read during background sync via
  `AppSettings.syncedWalkImportEnabled()`). Turning it off stops future imports and leaves
  the walks already imported alone.
- Only `HKWorkoutActivityType.walking` is read — not `.hiking`, and not passive step
  tracking. Adding `.walk` needed no CloudKit schema change: it is a new raw value in an
  existing `String` field.

## Cross-training workouts

Rides, swims, rows, elliptical and stair sessions, and Watch "cross training" or "mixed
cardio" workouts, are imported from Apple Health as `RunWorkout` rows carrying
`WorkoutType.crossTraining` (B8) — the walk design above, with one difference: a
cross-training session **completes the plan's cross-training day**.

- **`WorkoutType.countsAsRunning` is false for `.crossTraining`**, so every `runsOnly` /
  `runsOnlyDescriptor()` reader drops it. The store predicates that spell the rule out by
  raw value (`WorkoutRepository.fetch`, `IntentDataProvider`, `ProgressView`,
  `RaceInsightsView`) exclude both raw values; a new one has to as well.
- **Reads through `ScheduledWorkout.completedWorkout` must take `runsOnly`** when they mean
  running: a cross-training day links its session through that same relationship.
  `TrainingWeek.completedDistanceKm`, `PlanSummaryService` and the plan tab's VDOT card do.
- **Linking is one-way per kind.** `WorkoutSyncService.linkCrossTrainingToScheduledWorkouts`
  considers only `.crossTraining` days; the run linker's `runsOnly` guard keeps a ride off a
  run day. `CrossTrainingSyncTests` pins both directions.
- **No walking/running samples.** `HealthKitRepository.ImportKind.readsFootSamples` is false
  for cross-training, so the importer takes distance only as the workout reports it and
  reads no distance series, splits or cadence. The activity list and the floor (ten
  minutes, no distance) live in `CrossTrainingImportPolicy`.
- Imports quietly, like walks: no banner, no review sheet, no weather. There is no settings
  toggle, and the Settings → Import from Health screen does not import cross-training yet;
  the background sync and History's refresh do.
- The run summary hides pace, the coach and the link-to-plan button for a session, and
  leads with its time when it has no distance. The activity (bike vs pool) is not stored:
  that would be a new `RunWorkout` property and so a CloudKit schema deployment.

## Weather-tuned workouts

Stride reads tomorrow's forecast where the runner actually runs, and asks — the evening
before — whether a session that falls in the heat should change (N39). The split of
responsibilities is the point of the feature and is what a change here has to keep:

```text
WeatherKit  →  WeatherService.hourlyForecast  →  [ForecastHour]
                                                       ↓
                              HeatAdvisoryService (plumbing: which session, whose
                              location, what to persist, when to notify)
                                                       ↓
                              HeatAdaptationPolicy (every judgement, every number — pure)
                                                       ↓
                    HeatAdvisory  →  UserDefaults  →  HeatAdvisoryCard / HeatAdaptationSheet
                                  →  NotificationService.scheduleHeatAdvisory (18:00, day before)
```

- **Every number carries its source.** `HeatAdaptationPolicy` is a wall of constants with
  citations attached, and [`docs/HEAT_ADAPTATION_EVIDENCE.md`](docs/HEAT_ADAPTATION_EVIDENCE.md)
  is the file to read *before* touching any of them — the same arrangement, and the same
  reason, as `PregnancyRunningPolicy`. Update the doc's row in the same change.
- **The tier is the worst of three scales**, never an average: temperature + dew point
  (°F sum), dew point alone, and apparent temperature. No single one covers both a dry
  38 °C afternoon and a saturated 24 °C dawn, and both change what a session should be.
  `SmartCoachCards.heatCard` takes `max` of two urgencies for the same reason.
- **Dew point, not relative humidity.** `WorkoutWeather.dewPointCelsius` is optional
  because it is newer than the type; rows without it fall back to the Magnus derivation in
  `HeatAdaptationPolicy.dewPointCelsius(for:)`. It cost no CloudKit schema change —
  `WorkoutWeather` is JSON inside `RunWorkout.weatherData`, not a stored property.
- **The prompt threshold depends on the session.** Quality and long runs prompt from
  `.moderate`, easy runs from `.high`, and a race never prompts at all — the same
  fixed-point rule `AdaptableWorkoutSelector` and `MissedWorkoutShift` follow. Pregnancy
  plans are excluded outright: their sessions are prescribed by effort, which already
  self-corrects in heat.
- **The advisory is derived data and lives in `UserDefaults`, not SwiftData.** It is
  rebuilt from the plan and the forecast whenever the app runs, it is worthless once the
  session is behind the runner, and it describes a forecast rather than something that
  happened. A `@Model` for it would mean a schema deployment and rows syncing between
  devices that will each re-derive it more accurately from their own location.
- **Dismissals are keyed by session *and* tier.** Answering a `.moderate` advisory settles
  the moderate one; a forecast that worsens to `.severe` overnight is new information about
  a materially different day and gets to ask again.
- **Location comes from the last recorded run's start**, not from a live location request.
  No new permission, and it answers the question that matters — where this person will be
  running tomorrow, not where the phone is tonight.
- **The banner fires at 18:00 the day before** (`NotificationService.heatAdvisoryDelivery`),
  delivers immediately if the app is opened later that same evening, and sends nothing once
  the session's own day has begun — a warning the runner can no longer plan around is the
  thing the feature exists to avoid. From then on the dashboard card is the surface.
- **An unanswered advisory is a decision, not a notice.** It sits at the very top of the
  Home tab, above the week summary, and `HeatAdaptationSheet` presents itself over Home the
  moment one exists — with no Close button and `interactiveDismissDisabled(true)`, so the
  only exits are "Apply to tomorrow's workout" and "Run it as planned". Both count as an
  answer and both clear the card; nothing else does, including a relaunch. Auto-presentation
  is held back in UI tests (a modal over Home would block every flow starting there) and
  while the strength `fullScreenCover` is up (a sheet raised over a cover from the same
  presenter silently fails to appear), retrying when that closes.
- Applying an adaptation goes through `HeatAdaptationPolicy.apply`, which touches the
  prescription and nothing else, and clears `healthKitPlanID` because the workout already
  on the Watch describes the old one. The structured form's per-segment paces move with the
  band, or the structure is cleared — leaving it would have the guided-run engine calling
  out the pace the runner just agreed to back off from.
- On by default, switchable in **Settings → App → Heat Adaptation**
  (`AppSettings.heatAdaptationEnabled`).

## Training nudges (A9)

Three evening notifications beyond the 8 AM workout reminder: the **streak nudge**, the
**missed-workout push** and the Sunday **weekly recap**. Same split as the heat advisory —
`TrainingNudgePolicy` is pure and holds every decision, `NotificationService` holds the
copy and the `UNUserNotificationCenter` calls, and `ContentView.refreshTrainingNudges`
does the plumbing on every foreground and on every plan change. All of it is gated by
`AppSettings.trainingNudgesEnabled` (**Settings → App → Training Nudges**, on by default).

Rules a change here has to keep:

- **The 18:00 slot holds one push.** Streak or missed-workout, never both, and the streak
  wins because it is the one that cannot be said tomorrow. The recap keeps a Sunday 19:00
  slot of its own so a readout is never crowded out by a prod.
- **A missed slot is decided, not assumed away.** The app gets no background wake, so
  `TrainingNudgeDelivery` resolves `.scheduled` / `.immediate` / `.skip` the way
  `NotificationService.HeatAdvisoryDelivery` does. Everything past the kind's cutoff hour
  is dropped rather than delivered too late to act on, and `TrainingNudgeLog` is what
  keeps an `.immediate` delivery from repeating when the app is opened twice the same
  evening. A *scheduled* request needs no such guard — it carries a stable identifier, so
  re-arming replaces it.
- **The push and the card share one dismissal.** The missed-workout push reads
  `MissedWorkoutDetector.promptFlaggedDateKey`, the same once-a-week flag
  `MissedWorkoutsRecoveryCard` writes. Two spellings of that key is how the Lock Screen
  ends up asking a question the runner already answered on the dashboard.
- **Nothing to say means nothing is sent.** A week with no runs gets no recap, a streak
  under `minimumStreakToProtect` is not worth protecting, and the refresh cancels a
  pending nudge whose reason has gone away.

`triggerTrainingNudgeTestNotifications` fires one of each with sample numbers, for reading
the copy on a real Lock Screen.

## Shoe tracking

Runners add their pairs in **Settings → Shoes**; each run can name the pair it was run in,
and Home nudges when a pair in rotation is nearly worn out. `ShoeWearPolicy` holds every
judgement (pure, tested in `ShoeTrackingTests`), `ShoeAssignment` the few writes.

- **Mileage is derived, never stored**: `startingDistanceMeters` plus the runs whose
  `RunWorkout.shoeID` names the pair. Runs point at a shoe by UUID, not a relationship,
  for the same out-of-order-sync reason as `linkedScheduledWorkoutID`. Views fetch through
  `RunWorkout.shoeMileageDescriptor`, which loads only `shoeID` and `distanceMeters`.
- **The default pair is put on new runs only from its `startDate` on**, so a retroactive
  HealthKit import never credits old runs to new shoes. Walks are never auto-assigned.
  The three insert paths that call `ShoeAssignment.assignDefaultShoe` are the run-finish
  path, the background HealthKit sync and the manual import.
- **The 800 km / 500 mi default is convention, not evidence**, and the code says so. Each
  pair carries its own `replacementDistanceMeters`.
- **The nudge's dismissals are keyed by pair and wear level** (`ShoeNudgeDismissals`, in
  `UserDefaults`), so "not yet" at nearly done does not silence a pair once it is worn out.
- Adding `Shoe` and `RunWorkout.shoeID` is a CloudKit schema change: run
  `--init-cloudkit-schema` and deploy before shipping (see "Persistence and Sync").

## Run playlists

Stride builds a playlist shaped like the session and saves it into the runner's Apple
Music library (N40). The split of responsibilities mirrors the heat feature, and the two
boundaries at the top are what a change here has to keep:

```text
ScheduledWorkout  →  RunPlaylistPlanner  →  RunPlaylistPlan   (pure, tested)
                          ↑                       ↓
                  MusicEnergyPolicy        RunPlaylistService  (MusicKit: auth, tracks, write)
                  (every number)                  ↓
                                          MusicLibrary.shared  →  a real library playlist
                                                  ↓
                                          RunPlaylistLink  →  UserDefaults (RunPlaylistStore)
                                                  ↓
                                  RunPlaylistCard (Plan → workout detail)
                                  RunPlaylistSettingsView (access + per-tier overrides)
```

- **Stride writes a playlist; it never plays one.** The result is a real Apple Music
  playlist, so it syncs to the Watch, opens in the Music app and outlives Stride, and the
  runner presses play themselves. The app does not become a music player and it never
  touches the audio session — `RunVoiceCoach` owns that, and it exists to *duck* whatever
  the runner chose rather than to replace it. `ApplicationMusicPlayer` appears nowhere.
- **No claim is ever made about tempo.** The Apple Music catalogue publishes no BPM —
  `Songs.Attributes` carries genre, duration and artwork and nothing about the beat — so
  cadence-matched playlists are not buildable from Apple's data and nothing in the UI
  pretends otherwise. Genre is the only signal Apple gives, so genre is what the tiers are
  built from, and the Settings screen says so in as many words. Adding real BPM means
  adding a third-party audio-analysis source, which is a network dependency and a second
  API key, not a tweak.
- **`MusicEnergyPolicy` is editorial, not evidence, and says so at the top.** It is shaped
  like `HeatAdaptationPolicy` and `PregnancyRunningPolicy` — one wall of constants rather
  than judgements scattered through a generator — but it carries no citations because there
  are none to carry. Do not add scientific-sounding sourcing to a genre table; that is the
  same failure as an unsourced health prescription, pointing the other way.
- **A pregnancy session is capped at the `steady` tier**, and the cap is asked of
  `TrainingPlan.planKind` via `Session.isPregnancyPlan`, never inferred from the session. A
  pregnancy plan carries its moderate day as `WorkoutType.tempo`, so mapping by type alone
  scores it `hard` — exactly the reading those plans are designed to avoid. Its effort
  ceiling is "talk but not sing"; the music's ceiling matches. Nothing here reads or writes
  a pace, so the no-pace-targets rule is untouched.
- **`RunPlaylistPlanner.WorkingBlock` tracks what each block is made of**, and that is
  load-bearing rather than incidental. Smoothing by "merge into the longer neighbour" reads
  fine until you trace 10 × 400 m: the first rep's long neighbour is the 15-minute warm-up,
  so the interval body gets eaten a rep at a time and the session comes out as one calm
  block. Two rules fix it and both are tested — a **short** neighbour is preferred to a long
  one, and a merged block is named for the energy that contributed the most seconds.
- **The link lives in `UserDefaults`, not on `ScheduledWorkout`.** A new stored property on
  a `@Model` means a `--init-cloudkit-schema` run and a **Deploy Schema Changes** before the
  build can ship, and this feature does not need that gate: the thing worth syncing — the
  playlist — already syncs through the runner's Apple Music account. What stays device-local
  is Stride's note of which playlist belongs to which session, so a second device offers to
  build rather than to open. `AppContainer.resetAllData` clears the links for the same reason
  it clears the widget snapshot; it deliberately does **not** delete the playlists, which are
  in the runner's library and not Stride's.
- **Rebuilding replaces the same playlist's contents** (`MusicLibrary.edit`), so a runner who
  rebuilds three times has one playlist and not three. `edit` throws for a playlist another
  app created — and the runner may simply have deleted it — so both cases fall back to
  creating a fresh one and re-pointing the link. Pools are shuffled per build, which is what
  makes a rebuild worth doing.
- **The Music app URL is bare `music://`. Do not give it a path.** Every path tried on device
  was rejected, each time with Music opening and then showing an error, and the published
  advice was wrong about the second one:
  1. `music://music.apple.com/library/playlist/<id>` — *"item not available"*. iOS deep links
     reach **catalogue** playlists only, and a playlist Stride created in somebody's library is
     private by definition.
  2. `music://music.apple.com/library` — widely documented as working, including on Apple's own
     forums. It is not: Music opens and still errors. The library root is no more linkable than
     the playlist.
  3. Bare `music://` — no path, nothing to reject.

  So the button launches Music and cannot land on the playlist, which is why it is the
  secondary action and is labelled `Open Apple Music` rather than `Open in Music` — the
  earlier label promised a destination and is what made the feature read as broken. The
  playlist's name is on the card, to be found by eye.
- **Playback queues the `MPMediaPlaylist`, not a play-parameters descriptor.** `play(_:)` looks
  the playlist up by name through `MPMediaQuery.playlists()` and hands it to
  `MPMusicPlayerController.systemMusicPlayer` — the same player the Music app drives, so Now
  Playing, the Lock Screen and Control Center all show Music and Stride's audio session is
  still never touched. `ApplicationMusicPlayer` would make Stride the player and is the thing
  being avoided.

  The first attempt built an `MPMusicPlayerPlayParametersQueueDescriptor` from the *playlist's*
  play parameters and always failed with "couldn't start this playlist". The mistake was
  structural, not a matter of tuning: that descriptor takes a queue of **item** parameters — the
  songs — so a playlist's own parameters are not something it can represent. `MPMediaPlaylist`
  is an `MPMediaItemCollection`, which `setQueue(with:)` takes directly, so the whole playlist
  queues with no per-track bookkeeping and no bridging between frameworks. Matching is by name,
  which is why the name is on the link: MusicKit's playlist ID and MediaPlayer's `persistentID`
  are different identifier spaces. A runner who renames the playlist breaks the match and is
  told to rebuild.
- **Stride is the only place the playlist can be read, so the track list is stored, not
  fetched.** Because no URL opens a private library playlist, `RunPlaylistDetailView` is the
  one surface where a runner can see what they are about to run to — and a screen standing in
  for something that already failed on device should not itself need authorization, a library
  round trip and a network to render. `RunPlaylistLink.tracks` is written at build time and the
  screen groups it back into blocks via `RunPlaylistTrackSection.sections(from:)`, which works
  only because the planner guarantees no two neighbouring blocks share an energy. The cost is
  that it shows the playlist *as Stride built it* and does not follow edits made in Apple
  Music, which the screen says in a line rather than implying a freshness it lacks.
- **A track list per session is why links are pruned.** A name and an ID would have been
  negligible forever; twenty tracks per session in `UserDefaults` — read into memory whole — is
  not, so `RunPlaylistStore.prune` drops links past `retention` after each build. Pruning a
  link never touches the playlist.
- **A missing subscription is a supported path, not a blocked one.** `MusicSubscription`
  decides whether tracks come from the catalogue or the runner's own library; a
  non-subscriber gets a playlist either way and is told afterwards where it came from. There
  is no upsell: a feature that answers "build me a playlist" with a subscription offer is not
  answering the question.
- Two registrations, and both fail the way a missing App Group does — silently locally, then
  fatally at export. `NSAppleMusicUsageDescription` is in `project.yml`'s `info:` block
  (without it the prompt never appears and authorization returns `.denied`), and the
  **MusicKit** service must be enabled on the `com.running.stride` App ID at
  [developer.apple.com → Identifiers](https://developer.apple.com/account/resources/identifiers).
  Automatic signing can look that service up but never create it.
- Entry point is the **Plan tab → workout detail** card, on any run that is not yet
  completed. Access and the per-tier overrides live in **Settings → Run Playlists**.

## AI coaching models

AI coaching runs entirely on Apple's Foundation Models framework. There are no third-party
providers, no API keys and no per-token cost. Two models sit behind one API, chosen by
`AIProvider` in **Settings → AI Coach → Model**:

| | `.appleOnDevice` | `.applePrivateCloud` (default) |
| --- | --- | --- |
| Type | `SystemLanguageModel.default` | `PrivateCloudComputeLanguageModel` (iOS 27+) |
| Context | ~8K tokens | 32K tokens |
| Network | none | required |
| Entitlement | none | `com.apple.developer.private-cloud-compute` |

Both conform to `LanguageModel`, so `LanguageModelSession`, the `@Generable` schemas in
`FoundationModelsCoachTypes.swift`, the instructions and every downstream mapping are shared.
`FoundationModelsCoachBackend.withServerFallback` is the only place the two differ.

- **Private Cloud Compute is the default for new installs** (`AppSettings`). It is safe as a
  default because it *degrades* rather than fails: every server request is gated on
  `PrivateCloudComputeLanguageModel.availability`, and a `.networkFailure` or
  `.serviceUnavailable` is retried on the on-device model, which is what Apple's guidance
  asks for. A runner who explicitly picked on-device keeps that choice — the default only
  applies when the key has never been written (the same M15 no-clobber rule as every other
  setting).
- **The daily quota is the one failure that is not silently downgraded.** PCC gives each
  person a daily request allowance (raisable via iCloud+), and Apple asks apps to keep that
  status *visible* rather than spring it in a dismissible alert. So
  `.quotaLimitReached` becomes `OnDeviceCoachError.serverQuotaExceeded(resetDate:)`,
  **Settings → AI Coach** renders `ServerModelStatus` with the "Show options" upgrade button
  (`QuotaUsage.limitIncreaseSuggestion.show()`), and the chat view names the real cause
  instead of telling the runner to go and enable Apple Intelligence.
- **Reasoning level** is set per task through `ContextOptions(reasoningLevel:)` and only on
  the server path: `.light` for chat (a runner is waiting on it), `.moderate` for run
  insights and single-workout adaptation, `.deep` for whole-plan adaptation. When passing
  `contextOptions` to the guided-generation overload, keep `includeSchemaInPrompt: true` —
  that overload drops the standalone argument and its default is `true`, so omitting it
  loses the schema bias.
- **The Home tab's Coach Tips are worded by the on-device model, not chosen by it.**
  `SmartCoachCards` still picks the cards, scores them and computes every amount; the
  model only rewrites each card's title and message (`CoachTipRewriter`,
  `AICoachService.writeCoachTips`). A rewrite is dropped unless its digit-written numbers
  match the card's exactly, and it is bound to the card text it was written from, so the
  hard-coded copy is what shows while the model writes, on devices without Apple
  Intelligence, and wherever a rewrite fails the check. Always on-device, never PCC: it
  runs unasked, and the daily allowance belongs to requests the runner makes. `glance`
  (widget, Siri) and `derivation` are never rewritten.
- `AICoachService` never imports `FoundationModels`. It talks to `OnDeviceCoachGenerating`,
  and PCC state reaches the UI as `ServerModelStatus`, a plain value type. That is what keeps
  the coach testable with a fake backend — see `StrideTests/FoundationModelsCoachServiceTests.swift`.

The entitlement is **managed**: Apple assigns it to the developer account on request (App
Store Small Business Program, under 2M first-time downloads), and unlike App Groups or
HealthKit it cannot be self-served in the developer portal. Until it is granted, automatic
signing cannot issue a matching profile and signed builds fail at export. An unentitled
build still runs — `availability` reports unavailable and every request goes on-device.

Reference: [Adding server-side intelligence with Private Cloud Compute](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute).

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
- **A string in the snapshot must not contain a clock.** This is the sharpest form of the
  date rule above, and the coach tip is where it bites: `SmartCoachCards` runs in the app
  and its dashboard copy says things like "about 30 minutes ago", so the snapshot ships
  `SmartCoachCard.glance` — a short form written to be true whenever it is read — and
  never `message`. Relevance is carried separately by `expiresAt`, which the widget
  resolves against its *entry* date. Both are anchored to the data (a run's finish, a
  race's date) rather than to `now`, because a value derived from `now` differs on every
  write, and a snapshot that differs on every write spends a reload on every foreground.
  `StrideTests/CoachTipSurfacesTests.swift` asserts the no-clock rule over every card kind.
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
- **A `#if DEBUG` block is a Release compile error waiting to happen.** Anything declared
  inside one — a `@State` property, a helper view, a method, a whole type — does not exist
  in the configuration that archives, so a single non-debug reference to it compiles clean
  locally and fails the archive with `Cannot find 'x' in scope`. `pccStatus` in
  `SettingsView` was exactly that: a `@State` inside the view's debug block, read by the AI
  Coach card, which ships. When a declaration is used by anything that is not itself inside
  `#if DEBUG`, it belongs outside the block. CI now catches this — the `build-release` job
  in `.github/workflows/ci.yml` compiles `-configuration Release` for
  `generic/platform=iOS` on every PR, alongside the Debug tests — but the check costs a
  full runner, so keep the scoping right rather than relying on it.
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
| [`docs/HEAT_ADAPTATION_EVIDENCE.md`](docs/HEAT_ADAPTATION_EVIDENCE.md) | The dew-point, temperature-sum and ACSM sources behind every number in `HeatAdaptationPolicy` — the tier scales, the pace-adjustment bands, what changes about a session, and why heat acclimatisation is deliberately not modelled. **Read before changing any of those numbers** — and update the row in the same change. |
| [`docs/REPO_ANALYSIS.md`](docs/REPO_ANALYSIS.md) | Operational review: CI, secrets hygiene, test depth. |
| [`docs/CLOUDKIT_VALIDATION.md`](docs/CLOUDKIT_VALIDATION.md) | CloudKit sync validation steps. |
| [`docs/CLOUDKIT_ANALYSIS_2026-07-28.md`](docs/CLOUDKIT_ANALYSIS_2026-07-28.md) | CloudKit setup audited against Apple's published requirements, every claim source-linked. **Read before touching `ModelConfiguration`, the store-fallback tiers, or any `@Model`'s stored properties.** All six findings fixed in code; the §6 device validation is still owed. The reasoning is kept in full because it is what stops F1 returning via the next config that omits an argument. |

When you fix something listed there, mark the item **✅ FIXED** in place with a
one-line note on where the fix landed, rather than deleting it.
