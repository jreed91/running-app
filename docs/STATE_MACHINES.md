# State machines in Stride

An *implicit* state machine is a set of `Bool`s and optionals that move together and
describe one lifecycle — `isLoading` beside `result` beside `errorMessage` — where only
some combinations are meant and nothing stops the others. This file lists every one found
in the app on 2026-11-09, what was made explicit, and what is left, ranked.

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
3. **Put it in `Stride/Core/Services/` with a `…Tests.swift`** covering every arrow,
   including the no-ops (an event in the wrong state). The diagram in its doc comment is
   the contract; keep it current.
4. **Keep the reads the view used.** Give the enum the computed properties the old
   variables answered (`isActive`, `remainingSeconds`), so a refactor is a rename at each
   read site rather than a rewrite of the body. That is how the conversions below changed
   no behaviour.
5. **A one-off screen flag can stay a private nested enum** (`RestorePermissionCheck`
   in `StrideApp`). Lift it into `Core/Services` once it has more than one transition
   worth testing, or a second screen wants it.

## Already explicit (use these as the pattern)

| State | Where | Cases |
| --- | --- | --- |
| `TrackingState` | `Core/Services/WorkoutTrackerService.swift` | idle → active ⇄ paused → finished → idle. Every public method guards its source state. |
| `RestTimerState` | `Core/Services/RestTimerState.swift` | idle ⇄ resting(deadline, remaining, total). *Converted 2026-11-09.* |
| `CoachReplyStream` | `Core/Services/CoachReplyStream.swift` | idle → waiting → streaming(text) → idle. Coach chat and the run's coaching read. *Converted 2026-11-09.* |
| `SyncPassQueue` | `Core/Services/SyncPassQueue.swift` | idle ⇄ syncing(queued:). HealthKit import, one pass at a time, never drop a trigger (M1). *Converted 2026-11-09.* |
| `CoachPlanChangeCard.Phase` | `Features/AICoach/CoachPlanChangeCard.swift` | ready → applying → applied / failed(message) |
| `HealthKitImportView.ImportState` | `Features/Settings/HealthKitImportView.swift` | idle → importing → done(imported, skipped) / failed |
| `WatchGlanceModel.StartState` | `StrideWatch/WatchGlanceModel.swift` | idle → opening → idle / failed |
| `RouteDeviationMonitor.Status` | `Core/Services/RouteDeviationMonitor.swift` | on route / off route, with hysteresis |
| `RacePhase`, `PlanStatus`, `ScheduledDayResolver.DayState` | `Core/Services/` | Derived states, computed from data rather than stored. The best kind: nothing to keep in sync. |

## Still implicit, ranked

Ranked by what a wrong combination would cost a runner, then by how often the code is
touched. None of these is known to be broken today; each is a place where the next edit
can break it without the compiler noticing.

| # | Where | Variables | Why it matters | Suggested shape |
| --- | --- | --- | --- | --- |
| 1 | `ActiveRunView` save flow | `pendingSave`, `saveErrorMessage`, `showFinishConfirmation` | The finished run lives only in `pendingSave` until `context.save()` succeeds (N15). "Error showing with no run held" or "run held, no error, screen dismissed" would lose a run. | `RunSaveState`: recording → confirming → saving(run) → failed(run, message) → saved. **Run screen is design-frozen and this needs a device test**, so it was not done blind. |
| 2 | `OnboardingView` | `step: Int`, `goingForward`, `case 2 where isPregnancyPlan`, `default:` as the last step | Steps are integers whose meaning depends on `planKind`; a new step means renumbering every `case` and `OBShell(stepIndex:)`. The last step is `default`. | `OnboardingStep` enum with `next(for planKind:)` / `previous`, tested per plan kind. Touches UI tests' navigation; do with a simulator run. |
| 3 | `PlanTabView` Smart Adapt | `isAdaptingPlan`, `smartAdaptProgress` (has its own `.idle`/`.starting` statics), `adaptTask` | Two sources of "is it running"; `finishIfNeeded()` in a `defer` patches the gap. | Fold `isAdaptingPlan` into `SmartAdaptProgress` as a phase (`.idle / .preparing / .streaming / .applying(n of m) / .done(message)`). |
| 4 | `RunSummaryView` next-session update | `isApplyingNextSessionFeedback`, `nextSessionUpdateMessage`, `updatedNextSessionID` | The message's colour is chosen by `hasPrefix("Updated")` on localisable text. | `NextSessionUpdate`: idle / applying(label) / updated(id, label) / failed(reason). Colour from the case, not the string. |
| 5 | `StrideApp` restore flow | `authService.welcomeBackPending`, `needsWorkoutKitSync`, `restorePermissionCheck` | Three variables across two types describe one reinstall-and-restore flow. See *Found while reading* below. | `RestoreFlow` on `AuthService` or the container: none → awaitingCloudKit → restoring(profile) → done. |
| 6 | `RouteGeniusViewModel` | `isGenerating`, `routeOptions`, `selectedRouteIndex`, `errorMessage` | Options and an error can both be set if a later edit forgets a reset. Already in a view model, so cheap to test. | `RouteGenerationState`: idle / generating / options([route], selected) / failed(message). |
| 7 | `SettingsView` data export, `RunSummaryView` share card / GPX | `isExportingData` + `dataExportFile` + `dataExportErrorMessage`; `isRenderingShareCard` + `shareCard` | Busy flag + result + error, three ways. | One small `ExportState<File>` reused by both. |
| 8 | `PlanTabView` new-plan sheets | `showNewPlanSheet`, `showPregnancyPlanSheet`, `showStartRunningPlanSheet` | Three sheets that must never show together. | One `@State var newPlanSheet: PlanKind?` with `.sheet(item:)`. |
| 9 | `ActiveRunPresentation` | `isPresented` × `tracker.isRecording` | Four combinations, three meant (no run, full screen, minimised). Well documented in place, so low risk. | A derived `RunScreenState` computed property if a third screen needs it. |
| 10 | `WorkoutSyncService.isObserving` | `Bool` claimed before an `await`, reset on failure | Fine as a Bool (registering and registered are treated the same). Listed so nobody "fixes" it into two flags. | Leave. |

Smaller ones not worth an enum on their own: `RaceDayHubView` (`isWritingBriefing` +
`briefing`, a cache keyed by its prompt), `RaceWeatherCard` (`isLoading` + `forecast`),
`DashboardView` recovery (`isHandlingRecovery` + `recoveryAlert`), `HistoryView.isSyncing`,
the `Onboarding` permission rows (`isRequestingPermissions` + `activePermission`).

## Found while reading (behaviour, not refactors)

These are inferred from the code, not reproduced. They were left as they are so the
conversions stay behaviour-neutral.

- **A queued HealthKit sync loses its look-back window.** `SyncPassQueue` queues only
  the *source* of a trigger that arrives mid-pass, and the follow-up pass reuses the
  `lookbackDays` of the call that started the loop. History's pull asks for 60 days
  (`HistoryView`, `syncNow(lookbackDays: 60, source: "history")`); if it lands while the
  startup or observer pass is running, it is queued and runs with the 7-day default. Its
  `await` also returns as soon as it is queued, so the refresh ends before the sync does.
  Fix: queue the widest window asked for alongside the source (`syncing(queued:
  (source, lookbackDays))`), with a test in `SyncPassQueueTests`.
- **The post-restore permission prompt can be skipped when the plan arrives first.**
  In `StrideApp`, `onChange(of: activePlans.count)` sets `needsWorkoutKitSync = false`
  *before* launching `requestMissingPermissionsAfterRestoreIfNeeded()`, which then
  returns at `guard needsWorkoutKitSync`. It only runs if the `profiles.count` change
  fires first. CloudKit usually delivers the profile first, so this is likely rare.
  Worth fixing inside the `RestoreFlow` conversion (#5), with a device restore test.
