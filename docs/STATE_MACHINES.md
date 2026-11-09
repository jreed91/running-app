# State machines in Stride

An *implicit* state machine is a set of `Bool`s and optionals that move together and
describe one lifecycle — `isLoading` beside `result` beside `errorMessage` — where only
some combinations are meant and nothing stops the others. This file lists every one found
in the app on 2026-11-09, what was made explicit, and what was left as it is and why.

**Read this before adding a second flag beside an existing one.** If the new `Bool` or
optional only has meaning in some values of another, the pair is a state: write an enum.

## The rule

1. **One enum per lifecycle.** Cases name what the screen or service is doing
   (`.waiting`, `.resting`), and associated values carry what only exists in that case
   (the deadline exists only while resting). A combination that should not happen should
   not be writable.
2. **Transitions are methods on the enum, pure and clock-free.** Pass `now: Date` in;
   no `Task`, `Date()`, `UserDefaults` or SwiftData inside. The view or service owns the
   effects (the ticking `Task`, the HealthKit call) and calls a transition when one lands.
3. **Put it in `Stride/Core/Services/`, or beside the one feature that uses it, with a
   `…Tests.swift`** covering every arrow,
   including the no-ops (an event in the wrong state). The diagram in its doc comment is
   the contract; keep it current.
4. **Keep the reads the view used.** Give the enum the computed properties the old
   variables answered (`isActive`, `remainingSeconds`), so a refactor is a rename at each
   read site rather than a rewrite of the body. That is how the conversions below changed
   no behaviour.
5. **Keep it Foundation-only.** Then the type and its tests compile with a plain Swift
   toolchain, no Xcode: copy them into a scratch SwiftPM package whose library target is
   named `Stride` (so `@testable import Stride` resolves) and run `swift test`. Every
   type above was checked that way on Linux. Bind a mutating call's result before
   `#expect`; the macro cannot call a mutating method.
6. **A one-off screen flag can stay a private nested enum** (`RestorePermissionCheck`
   in `StrideApp`). Lift it into `Core/Services` once it has more than one transition
   worth testing, or a second screen wants it.

## Explicit (use these as the pattern)

| State | Where | Cases |
| --- | --- | --- |
| `TrackingState` | `Core/Services/WorkoutTrackerService.swift` | idle → active ⇄ paused → finished → idle. Every public method guards its source state. |
| `RestTimerState` | `Core/Services/RestTimerState.swift` | idle ⇄ resting(deadline, remaining, total). Strength rest between sets. |
| `CoachReplyStream` | `Core/Services/CoachReplyStream.swift` | idle → waiting → streaming(text) → idle. Coach chat and the run's coaching read. |
| `SyncPassQueue` | `Core/Services/SyncPassQueue.swift` | idle ⇄ syncing(queued: Request?). HealthKit import: one pass at a time, never drop a trigger (M1), keep the widest window asked for. |
| `RunSaveState<Run>` | `Core/Services/RunSaveState.swift` | unsaved → held(run) → failed(run, message) → held / unsaved. The finished run until the store save succeeds (N15). |
| `ExportState<Output>` | `Core/Services/ExportState.swift` | idle → working → ready(output) / failed(message) → idle. Settings data export, run share card, GPX export. |
| `OnboardingStep` | `Features/Onboarding/OnboardingStep.swift` | welcome → goal → timing → level → calibrate → schedule → strength → permissions → ready. Raw values are the UI tests' step numbers. |
| `SmartAdaptState` | `Features/Training/SmartAdaptState.swift` | idle → running(progress) → finished(progress) / idle. The outcome stays on the card. |
| `NextSessionUpdate` | `Features/History/NextSessionUpdate.swift` | idle / unavailable(reason) / applying(label) / updated(id, label) / failed. Coach page's "Update next session". |
| `RouteGenerationState<Route>` | `Features/Training/RouteGenius/RouteGenerationState.swift` | idle → generating → options(routes, selected:) / failed(message). |
| `NewPlanFlow?` | `Features/Training/PlanTabView.swift` | nil / training / startRunning / pregnancy: one sheet at a time. |
| `RestoreFlow`, `RestorePermissionCheck` | `App/StrideApp.swift` (private) | notRestoring / awaitingPlan / planRestored; notStarted / running / done. |
| `CoachPlanChangeCard.Phase` | `Features/AICoach/CoachPlanChangeCard.swift` | ready → applying → applied / failed(message) |
| `HealthKitImportView.ImportState` | `Features/Settings/HealthKitImportView.swift` | idle → importing → done(imported, skipped) / failed |
| `WatchGlanceModel.StartState` | `StrideWatch/WatchGlanceModel.swift` | idle → opening → idle / failed |
| `RouteDeviationMonitor.Status` | `Core/Services/RouteDeviationMonitor.swift` | on route / off route, with hysteresis |
| `RacePhase`, `PlanStatus`, `ScheduledDayResolver.DayState` | `Core/Services/` | Derived states, computed from data rather than stored. The best kind: nothing to keep in sync. |

Generic over the payload (`RunSaveState<Run>`, `ExportState<Output>`,
`RouteGenerationState<Route>`) is deliberate: the tests use `String` in place of a
SwiftData model or a MapKit route, so they need no container and compile anywhere.

## Left implicit on purpose

| Where | Variables | Why it stays |
| --- | --- | --- |
| `ActiveRunPresentation` | `isPresented` × `tracker.isRecording` | Four combinations, three meant (no run, full screen, minimised), documented in place. Make a derived `RunScreenState` if a third screen needs it. |
| `WorkoutSyncService.isObserving` | one `Bool` claimed before an `await`, reset on failure | Registering and registered are treated the same, so a Bool is the whole state. Do not split it into two flags. |
| `RaceDayHubView` briefing, `RaceWeatherCard`, `DashboardView` recovery, `HistoryView.isSyncing`, onboarding permission rows | a busy flag beside a cached or one-shot result | Each is two variables with one meaningful combination at a time and a single writer; an enum would add more than it removes. Convert one when it grows a third variable. |

## Fixed along the way (2026-11-09)

Found by reading these flags side by side, fixed when the flags became one state.
None was reproduced on a device.

- **A queued HealthKit sync lost its look-back window.** Only the source of a trigger
  that arrived mid-pass was queued, and the follow-up reused the window of the call that
  started the loop. So History's 60-day pull, opened while the launch sync was running,
  ran with the 7-day default. `SyncPassQueue.Request` now carries the window, and folded
  triggers keep the widest. (History's `await` still returns when the pull is queued
  rather than when it has run; changing that would hold HealthKit's observer completion
  open longer, and the M1 test pins today's timing.)
- **The post-restore permission prompt was skipped when the plan arrived first.**
  `needsWorkoutKitSync` meant both "re-register WorkoutKit when the plan arrives" and
  "this launch is a restore", and clearing it for the first told the prompt "not a
  restore". `RestoreFlow` keeps the two apart.
- **Smart Adapt's outcome was never visible.** "Plan updated and synced." and "The coach
  response could not be applied…" were written as the run ended, and the panel that
  showed them hid in the same `defer`. A failed adapt looked like nothing happening.
  `SmartAdaptState.finished` keeps the outcome on the card until the next run.
- **The next-session caption's colour came from its text.** `hasPrefix("Updated")`
  decided green; a reword or a translation would have broken it silently.
  `NextSessionUpdate.isSuccess` comes from the case.
