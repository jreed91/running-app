# Stride Comprehensive Code Analysis — July 2026

A full review of the app (all 104 Swift files, ~24.6k lines) covering bugs, design issues, security/privacy, CI/config, and test coverage. Findings were produced by parallel subsystem reviews and the highest-severity items were re-verified directly against the source. Every finding cites `file:line` as of commit `0cc6be7`.

> **Fix tracking:** items marked **✅ FIXED** have been resolved; the note says where. Line numbers in fixed items refer to the original commit and may have drifted.

**Contents**
1. [Critical bugs](#1-critical-bugs)
2. [High-severity bugs](#2-high-severity-bugs)
3. [Medium-severity bugs](#3-medium-severity-bugs)
4. [Security & privacy](#4-security--privacy)
5. [Design & architecture issues](#5-design--architecture-issues)
6. [Low-severity bugs & polish](#6-low-severity-bugs--polish)
7. [CI, config & tooling](#7-ci-config--tooling)
8. [Test coverage gaps](#8-test-coverage-gaps)
9. [What is in good shape](#9-what-is-in-good-shape)
10. [Prioritized action plan](#10-prioritized-action-plan)

---

## 1. Critical bugs

### ✅ C1. Outdoor GPS distance never accumulates — auto-pause threshold is 500 m/s, not 0.5

**FIXED:** threshold corrected to `0.5` and renamed `autoPauseThresholdMetersPerSecond`.
`Stride/Core/Services/WorkoutTrackerService.swift:48, 253-256`

```swift
private let autoPauseThresholdMs: Double = 500  // < 0.5 m/s ≈ standing still
...
if location.speed >= 0 && location.speed < autoPauseThresholdMs {
    lastLocation = location
    return
}
distanceMeters += delta
```

`CLLocation.speed` is in m/s. A runner moves at 2–5 m/s, far below 500, so **every valid GPS fix takes the "stationary" early-return** and `distanceMeters += delta` never runs. Distance only accrues on fixes with *invalid* speed (< 0). An outdoor 5 km run records ~0 m, no splits, and a frozen pace.

**Fix:** change the constant to `0.5`. Add a unit test around `processLocation` (extract it so it is testable — see D-section).

### ✅ C2. A second run can never be started — tracker state machine has no path back to `.idle`

**FIXED:** added `WorkoutTrackerService.prepareForNewWorkout()` (`.finished` → `.idle`), called from `ActiveRunView.onAppear`.
`Stride/Core/Services/WorkoutTrackerService.swift:65, 106-115`; `Stride/App/AppContainer.swift:167`; `Stride/Features/ActiveRun/ActiveRunView.swift:435-461`

`WorkoutTrackerService` is a single long-lived instance owned by `AppContainer`. `finishWorkout()` sets `trackingState = .finished`; `startWorkout` guards `guard trackingState == .idle else { return }`; **nothing ever resets the state to `.idle`** (verified: the only assignments are `.active`, `.paused`, `.active`, `.finished`). After the first completed run, opening the run screen shows the previous run's frozen metrics and the start button silently does nothing until the app is relaunched.

**Fix:** add a `reset()`/`prepareForNewWorkout()` transition back to `.idle` (called from `finishWorkout` consumers or on `ActiveRunView` appear), and cover the full state machine with unit tests.

### ✅ C3. Store-recreation fallback can silently delete all user data (partially fixed)

**FIXED (core danger):** Tier 2 now moves the store aside to `Stride.store.broken-<timestamp>` instead of deleting it, and the identical Tier-1 retry is skipped when CloudKit is off (covered by a new `AppContainerTests` test). *Still open:* distinguishing migration vs. transient failures, and a user-visible recovery alert (only the Settings caption exists).
`Stride/App/AppContainer.swift:101-141`

When CloudKit is off (user toggle, or **every simulator build**), the primary `ModelConfiguration(schema:url:)` is byte-for-byte identical to the Tier-1 fallback `localConfig`. Any *deterministic* open failure — most plausibly a SwiftData schema-migration failure after an app update — therefore fails twice, and Tier 2 then deletes the store:

```swift
for suffix in ["", "-shm", "-wal"] {
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
}
```

With no CloudKit copy, every run, plan, and profile is gone. The only surface signal is a caption buried in Settings. Tier 2 also fires on *transient* failures (disk full, locked WAL) and never backs the file up first.

**Fix:**
- Before deleting, rename the store aside (`Stride.store.broken-<timestamp>`) so data is recoverable.
- Distinguish migration failures from transient I/O failures; never delete on the latter.
- When CloudKit is disabled, skip the pointless identical Tier-1 retry and go straight to explicit recovery handling.
- Surface a user-visible alert when recovery mode was entered.

### ✅ C4. App Intents open the shared store with an incomplete schema

**FIXED:** both paths now build their schema and store URL from the shared `StrideSchema` (`Stride/Core/Models/StrideSchema.swift`), so they can never drift.
`Stride/Features/AppIntents/IntentDataProvider.swift:23-34` vs `Stride/App/AppContainer.swift:67-76`

`makeContainer()` builds a `Schema` of **6** models but opens the **same `Stride.store` file** the app opens with **8** models — `StrengthWorkout.self` and `DeletedWorkout.self` are missing. Invoking any Siri/App Intent opens the store against a mismatched model: best case every intent throws; worst case a lightweight migration to the subset model drops the strength-history and deletion-tombstone tables (which would also resurrect previously deleted HealthKit runs).

**Fix:** share one schema constant between `AppContainer` and `IntentDataProvider` so they can never drift.

### ✅ C5. Plan generation crashes for short or past race dates

**FIXED:** `phaseSchedule` now fits phases from race day backwards (taper → peak → build → base) so short horizons shrink instead of trapping on a negative array count; past race dates fall back to a 1-week plan. Regression tests cover 1–5 week plans and past race dates for 5K/HM/marathon.
`Stride/Core/Services/TrainingPlanService.swift:307-335`, reached via `weeksThroughRaceDate` (`:240-245`)

Each phase count is floored at 1 (or 2 for marathon), so `baseWeeks = totalWeeks - taper - peak - build` goes negative for small `totalWeeks`, and `Array(repeating: .base, count: baseWeeks)` traps on negative counts. A race 2 weeks away → 5K schedule taper=1, peak=1, build=1 → `baseWeeks = -1` → **crash**. A race date in the past also crashes (`weeksThroughRaceDate` floors at 1 → `baseWeeks = -2`). Reachable in production: `AppContainer.rebuildPlan` (`AppContainer.swift:399-411`) regenerates from `Date()` against the *stored* race date, so replanning close to or after race day hits it even if creation UI clamps dates.

**Fix:** clamp `baseWeeks = max(0, ...)` and define explicit minimal-plan layouts for very short horizons; guard race-date-in-past with a graceful fallback. Add tests for 1–5 week plans and past race dates.

---

## 2. High-severity bugs

### ✅ H1. `adaptWorkout` auto-inserts phantom duplicate workouts on every pace refresh

**FIXED:** all four adapt functions (and `AICoachService.makeScheduledWorkout`) no longer set `.week` on the temporary model; callers already copy fields back as documented.
`Stride/Core/Services/TrainingPlanService.swift:781, 873, 943, 1005`; exercised by `refreshPaces` (`:1088-1115`) via `AppContainer.refreshPlanAfterWorkout` (`AppContainer.swift:329`)

The doc comment says the returned adapted workout "should [have] its fields copied back … rather than inserting it into the SwiftData context", but every adapt function assigns `adapted.week = scheduled.week`. Relating an unmanaged model to a managed one **auto-inserts it into the context**, so each pace refresh after a completed run appends uncompleted duplicate workouts to the persisted week — and the next refresh adapts the duplicates too, multiplying workouts run after run.

**Fix:** never set `week` on the temporary model; copy fields back to `scheduled` (as documented), or detach the template type from `@Model` entirely (a plain struct describing the adaptation).

### H2. The adaptation engine systematically misjudges runners (three compounding math bugs)

1. ✅ **Interval sessions always classify as `.struggling`** — `WorkoutAnalyticsService.swift:255-266, 284-287`: `lastIntervalPaceRatio` divided the *whole-session* average pace (warm-up + recovery jogs + cool-down; `RunWorkout.swift:96-98`) by the *rep target* pace. A runner who nailed 6×800 m at target still showed a ratio ≈ 1.3 → `.struggling` → reps cut and paces slowed, locking the engine in permanent downgrade mode. **FIXED:** a new `intervalEffortPace(for:)` derives the rep pace from the fastest third of per-km splits (falling back to the session average only when splits are absent), so on-target intervals now read ≈ 1.0 and classify `onTrack`/`improving` while genuinely slow reps still surface as `.struggling`.
2. ✅ **Threshold/marathon paces double-discount %VO₂max** — `PaceCalculatorService.swift:121-151`: `speedForFraction` multiplied the intensity fraction (already a %VO₂max, e.g. 0.86 for threshold) by `fractionVO2max(forDurationMinutes:)` *again*. For VDOT 50 this prescribed tempo ≈ 4:36/km vs Daniels ≈ 4:15/km, and a marathon pace ~55 s/km slower than the app's own `predictedTime` for the same VDOT. **FIXED:** the second `fractionVO2max` multiplication (and the now-unused `typicalDuration` plumbing) were removed, so `targetVO2 = fraction · vdot`. VDOT-50 paces now land within Daniels tolerance (threshold ≈ 4:20/km, marathon ≈ 4:38/km, interval ≈ 3:55/km); covered by new `PaceCalculatorTests` Daniels-table assertions.
3. ✅ **VDOT estimated from session averages** — `WorkoutAnalyticsService.swift:199-209`: quality sessions including warm-up/recoveries were treated as race efforts, biasing `currentVDOT` low. **FIXED:** VDOT sampling in both `snapshot` and `tempoInsights` is now restricted to `.race` efforts; tempo/interval averages no longer seed VDOT, and non-racers fall back to the profile 5K estimate instead of an inflated-slow value.

**Fix (H2 — all resolved):** interval performance is now computed from splits, and VDOT is estimated only from race efforts. `snapshot(now:)` is injectable for deterministic tests, covered by the new `WorkoutAnalyticsServiceTests` (on-target vs. slow interval classification, race-only VDOT, lookback windowing).

### ✅ H3. Creating a new plan permanently deletes all past plans — wiping the Plan History feature's data
`Stride/Features/Training/PlanSetupView.swift:271, 288-291`; `Stride/Features/Training/NewPlanOnboardingView.swift:600, 629-632`

Both plan-creation flows fetch **every** `TrainingPlan` and delete them all — including completed past plans — yet `TrainingPlanListView.swift:26-30` renders a "Past Plans" section and `PlanSummaryCard` exists specifically to review finished plans. Finishing a half-marathon plan and starting a marathon plan silently erases the entire completed-plan record.

**FIXED:** a new `TrainingPlan.hasLoggedProgress` distinguishes plans worth keeping (any completed non-rest workout) from never-started ones. Both creation flows now deactivate plans with progress (`isActive = false`) and delete only never-started plans. `PlanRepository.save` enforces the single-active invariant (deactivates all others when saving an active plan) and `fetchActivePlan` now resolves the most-recently-created active deterministically. Covered by `PlanHistoryTests`.

**Fix:** deactivate (`isActive = false`) instead of deleting; delete only never-started/abandoned plans. Related: `TrainingPlan.init` always sets `isActive = true` and `PlanRepository.fetchActivePlan` (`PlanRepository.swift:35-40`) resolves multiple actives arbitrarily — repository `save` should own the "only one active plan" invariant.

### H4. "Start This Workout" ignores the scheduled workout — always records an unlinked easy run
`Stride/Features/Dashboard/DashboardView.swift:305-306, 416-431`; `Stride/Features/ActiveRun/ActiveRunView.swift:366-367, 435-444`

The dashboard button for a tempo/interval/long-run day presents `ActiveRunView()` with no parameter; the view hardcodes `tracker.startWorkout(type: .easy)` and `finishAndSave()` never links the run to the `ScheduledWorkout`. The scheduled day stays incomplete, the calendar shows it missed, and the recovery card later nags the user about a workout they did.

**Fix:** pass the scheduled workout into `ActiveRunView`, start with its type, and set `workout.scheduledWorkout`/`isCompleted` on save.

### H5. Closing an accidentally opened strength session force-saves it and marks the day complete
`Stride/Features/ActiveStrength/StrengthActiveView.swift:75-84, 92, 506-519`

The header "X" offers only "Finish & Save" / "Cancel" — there is no discard. `finishAndSave()` unconditionally inserts a `StrengthWorkout` and sets `scheduled.isCompleted = true` even with zero logged sets, corrupting adherence stats.

**Fix:** add a "Discard workout" option; refuse to mark `isCompleted` when nothing was logged.

### ✅ H6. `currentWeek` is nil for the entire last day of every training week
`Stride/Core/Models/TrainingWeek.swift:47`; `Stride/Core/Models/TrainingPlan.swift:31-34`

`endDate = startDate.adding(days: 6)` keeps the 00:00 time component, and `currentWeek` required `endDate >= today`. For a Monday-start week, `endDate` is Sunday 00:00, so **any time Sunday after midnight no week matched**: the dashboard weekly-progress card vanished, `PlanTabView` lost the current-week highlight, and the AI coach reported "week 0 of N" — every Sunday, which is long-run day.

**FIXED:** `currentWeek` now compares on day boundaries (`startDate.startOfDay <= today && endDate.startOfDay >= today` with `today = Date().startOfDay`), so the whole final day resolves. Covered by `TrainingPlanServiceTests` (final-day-included and fully-elapsed cases).

### H7. Historical HealthKit imports get *today's* weather attached permanently
`Stride/Core/Services/WeatherService.swift:28, 51-53`; consumed at `WorkoutSyncService.swift:163-167`

`weather(for: location)` returns current conditions + forward forecast; picking `hourlyForecast.min(by: closest to date)` for a past workout selects roughly *now*. The fresh-install 90-day lookback import stamps six-week-old runs with today's weather, which then feeds AI-coach commentary ("warm conditions added strain") about a winter run.

**Fix:** use the historical API (`weather(for:including: .hourly(startDate:endDate:))`) or skip weather attach when the workout is older than ~1 day.

### ✅ H8. Imported runs can link to (and complete) strength/rest days — and mutate the run's own type

**FIXED:** the two competing linkers were consolidated into one. `linkToScheduledWorkouts` now filters candidates to run-type scheduled workouts only (new `WorkoutType.isRunType`) and no longer overwrites `run.workoutType` from the schedule; the redundant `autoLink` was removed.
`Stride/Core/Services/WorkoutSyncService.swift:235-276` (vs the second linker at `:207-226`)

`linkToScheduledWorkouts` matches by day with **no workout-type filter** (type is only a tiebreaker), then does `run.workoutType = match.workoutType`. A HealthKit run imported on a strength-only day links to the strength workout, marks it complete, and the `RunWorkout` itself becomes `workoutType == .strength`. The sibling `autoLink` uses different rules (excludes `.rest` only) — the two linkers already disagree.

**Fix:** consolidate into one linker that only matches run-type scheduled workouts, and never overwrite the run's type from the schedule.

### ✅ H9. Deleted workouts resurrect on the next sync (three separate holes)

**FIXED:** all deletion now routes through `WorkoutRepository.delete` (extended with a `StrengthWorkout` overload that writes a `DeletedWorkout` tombstone and resets the scheduled day), and every import path unions tombstones: strength sync (`WorkoutSyncService`), `HistoryView` auto-sync (runs + strength), and manual `HealthKitImportView`.

The tombstone mechanism (`DeletedWorkout`) only works on the canonical run path; three paths bypass it:

1. **Strength has no tombstone at all** — `HistoryView.swift:128-132` deletes with no tombstone; strength dedup (`WorkoutSyncService.swift:283-303`) checks only live IDs. Deleted Watch gym sessions re-import within the 7-day lookback, forever.
2. **HistoryView auto-sync ignores run tombstones** — `HistoryView.swift:151-154` builds `existingIDs` from live runs only (the canonical path at `WorkoutSyncService.swift:98-101` unions tombstones).
3. **Manual Health import ignores tombstones** — `HealthKitImportView.swift:114-121`, same defect.

**Fix:** route all deletion through `WorkoutRepository.delete` (extend it to strength + tombstones + `isCompleted` reset) and all import through `WorkoutSyncService` so the exclusion logic exists once.

### ✅ H10. Coach-feedback "next session" seeding persists a phantom workout into the plan

**FIXED:** the seeded temporary `ScheduledWorkout` was removed entirely; coach feedback now flows into the adaptation prompt as a plain string via a new `coachFeedback:` parameter on `AICoachService.adaptScheduledWorkoutWithProvider`.
`Stride/Features/History/RunSummaryView.swift:1362-1376, 1287-1301`

A temporary `ScheduledWorkout` built purely as an LLM prompt input gets `seeded.week = scheduled.week` — the same auto-insert trap as H1 — and survives the subsequent duplicate-pruning (which filters the view's stale `@Query` snapshot). The plan then shows a duplicate workout that also syncs to WorkoutKit.

**Fix:** never attach prompt-only models to persisted relationships; use a plain struct for prompt context.

### H11. Split charts label kilometer buckets as miles for imperial users
`Stride/Features/History/RunSummaryView.swift:1493-1663`

Splits are always built per kilometer (`WorkoutTrackerService.swift:172-178`), but every axis, tooltip, header ("Pace per mi"), and table column uses the user's unit label. An imperial user's 10 km run renders as "MI 1 … MI 10" with min/mi paces per *kilometer* bucket — implying a 10-mile run with wrong per-split paces.

**Fix:** either bucket splits by the user's unit at record time, or label the axis honestly ("km") until splits are re-bucketed for display.

### ✅ H12. Medal "PR" logic crowns slower, shorter runs
`Stride/Features/Progress/MedalsView.swift:77-87`

PRs compare raw `durationSeconds` across a ±10 % distance band: a 4.50 km jog in 22:00 (4:53/km) beats a genuine 5.00 km PR in 23:00 (4:36/km) for the 5K medal. **Fix:** normalize by distance (compare pace, or Riegel-extrapolate to the target distance).

**FIXED (PR #230):** PR ranking normalized via `ProgressStatsService` with tests.

### H13. Environment-key default builds a hidden, side-effectful AppContainer — and can crash
`Stride/App/AppContainer.swift:557-561`

```swift
static let defaultValue: AppContainer = MainActor.assumeIsolated { AppContainer(inMemory: true) }
```

(a) `static let` initializes lazily on first touch from any thread; a non-main first read of `\.appContainer` traps in `assumeIsolated`. (b) Any view whose environment wasn't injected silently gets a fully wired in-memory container — writes disappear without an error. **Fix:** make the default a `fatalError`/assertion (fail loudly) or an optional.

---

## 3. Medium-severity bugs

### Sync & notifications
- **M1. Observer triggers dropped while a sync is in flight** — `WorkoutSyncService.swift:89-95, 130`: `guard !isSyncing else { return }` consumes the HealthKit observer callback without queueing a follow-up; a Watch sync burst can leave the second workout unimported until the next app launch. Queue a pending-sync flag instead.
- **M2. `startObserving()` reentrancy** — `WorkoutSyncService.swift:48-85`: `isObserving` is checked before but set *after* an `await` (actor-reentrancy window), and it is called concurrently from `StrideApp.task` and the restore flow (`StrideApp.swift:25, 257`) → duplicate observer queries. Set the flag before suspending.
- **M3. Notification mutex has the same TOCTOU hole** — `NotificationService.swift:106-112`: `isBulkScheduling` set after `await isAuthorized`; concurrent reschedules interleave cancels and adds. Also the losing call is silently dropped, leaving stale reminders.
- **M4. `cancelReminder(for:)` cancels nothing** — `NotificationService.swift:44-48 vs 162-164`: schedules `"morning-<uuid>"` but removes plain `<uuid>`.
- **M5. Fresh-install import fires one banner per recovered run** — `WorkoutSyncService.swift:114, 171-174`: 90-day lookback + `notifyNewRunSynced` per workout → 50+ simultaneous notifications on reinstall. Batch or suppress on first sync.
- ✅ **M6. Notification-snapshot resurrection duplicates or resurrects runs** — `NotificationService.swift:251-338`; `AppContainer.swift:250-257`: tapping a "Run Synced" banner re-inserts a snapshot `RunWorkout` when the ID isn't found — no tombstone check, no `healthKitWorkoutID` dedup, and no launch-time dedup pass exists for `RunWorkout` (unlike profiles/plans). Deleted runs resurrect; CloudKit race → two rows with the same `id`. **FIXED:** `surfacePendingReviewWorkout` now guards the snapshot-insert path — it skips (and clears) a snapshot whose HealthKit source is tombstoned, and surfaces the existing row instead of inserting a duplicate when a run with the same `healthKitWorkoutID` is already present.
- **M7. 64-notification cap silently truncates long plans** — `NotificationService.swift:103-119`: a 16–18-week plan schedules 80–100 requests; iOS keeps the soonest 64.
- **M8. Strength merge collapses distinct same-day workouts** — `WorkoutSyncService.swift:317-330`: matches purely on same-day and stamps the HK ID onto the app-logged record, discarding the Watch workout's own time/duration.
- **M9. HR stats not scoped to the workout** — `HealthKitRepository.swift:657-678`: missing `HKQuery.predicateForObjects(from: workout)` (the distance query at `:594-605` has it); chest-strap or overlapping samples from other sources skew avg/max HR.
- **M10. Route-fetch continuation can leak** — `HealthKitRepository.swift:644-652`: `HKWorkoutRouteQuery` handler resumes only `if done` and ignores the error parameter; an error callback can hang the whole serial import. Also only `routes.first` is read (`:640`), dropping later route segments.
- **M11. Tiny-workout filter uses `||` where `&&` was intended** — `HealthKitRepository.swift:502`: any ≥30 s workout imports even with 0 m distance.
- **M12. Removing WorkoutKit plans clears tracking IDs even when removal never ran** — `HealthKitRepository.swift:211-226`: the `defer` nulls `healthKitPlanID` on early-return paths (unsupported/unauthorized), permanently orphaning scheduled Watch workouts.
- **M13. Cross-training days sync to the Watch as running workouts** — `HealthKitRepository.swift:181-184, 370-378`: only `.rest` is filtered and only `.strength` special-cased; `.crossTraining` falls into `makeCustomWorkoutLegacy` with `activity: .running`.
- **M14. Deleting a plan leaves orphaned Watch plans and reminders** — `PlanDetailView.swift:54-58`, `TrainingPlanListView.swift:64-67`: plain `context.delete(plan)` with no `removeWorkoutPlans` or notification cleanup (the plan-replacement path does both).

### Settings, state & lifecycle
- **M15. First-launch settings write-back can clobber cross-device settings** — `AppSettings.swift:63-101`: `init()` unconditionally re-persists every value to `NSUbiquitousKeyValueStore` before the first pull arrives; a fresh install pushes defaults over the user's real values. There is also no `didChangeExternallyNotification` observer, so remote changes never land mid-session.
- **M16. The per-device iCloud-sync toggle is itself synced via iCloud** — `AppSettings.swift:42-46, 142-146`: disabling sync on one device eventually disables CloudKit persistence on all of them.
- **M17. HealthKit read permission tested via write-only API** — `StrideApp.swift:248-258`: `authorizationStatus(for:)` reports *share* permission; using it to gate "is Health authorized" misfires in both directions.
- **M18. Onboarding permission rows show green regardless of the user's answer** — `OnboardingView.swift:625-657`: all three flags set `true` unconditionally after a fixed 1.8 s sleep races the system dialogs.
- **M19. Onboarding/plan-setup pickers render hardcoded fake dates** — `OnboardingView.swift:390-404`, `NewPlanOnboardingView.swift:412-423`: `let dayNumbers = [20, 21, ... 26]` renders literal "M 20 … S 26" every day of every month; also assumes Monday-first regardless of locale.
- ✅ **M20. Deleting a run never resets `scheduled.isCompleted`** — `HistoryView.swift:120-127`, `RunSummaryView.swift:160-168`: adherence counts a workout that no longer exists; the intents' `todaysRun()` reports wrongly. **FIXED:** `WorkoutRepository.delete` clears `scheduled.isCompleted`/links; both views now delete through the repository.
- ✅ **M21. "Reset All Data" leaves strength workouts and tombstones behind** — `SettingsView.swift:648-654`: deletes 4 of 8 model types while the dialog promises "all workouts". **FIXED:** `resetAll()` now clears all 8 model types.
- **M22. Missing push entitlement while sync depends on remote notifications** — `Stride.entitlements` / `project.yml:60-72`: `remote-notification` background mode is declared but there's no `aps-environment`, so CloudKit silent pushes are never delivered and sync only happens on foregrounding.

### Timers & active-session tracking
- **M23. Elapsed time counted by timer ticks, not wall clock** — `WorkoutTrackerService.swift:225-232`: `elapsedSeconds += 1` per `Timer` fire undercounts whenever the process is suspended (indoor runs have no background keep-alive) or the run loop stalls. Locked-phone treadmill run records minutes instead of the real duration, corrupting pace and all downstream VDOT analytics. Derive from start/pause timestamps.
- **M24. Indoor resume replays paused distance** — `WorkoutTrackerService.swift:94-104, 149-164`: `pedometer.startUpdates(from: startDate)` on resume replays cumulative distance since original start; walking while paused counts.
- **M25. Indoor pace guards the wrong variable** — `WorkoutTrackerService.swift:158-160`: guard checks `elapsedSeconds > 0` but divides by `meters` → `+inf` pace on the first callbacks.
- **M26. Split elevation gain is the delta of the last two GPS fixes** — `WorkoutTrackerService.swift:272`: a km climbing 50 m steadily records ~0.25 m. Also `finishWorkout` never populates `elevationGainMeters`/`maxHeartRate` despite having the data.
- **M27. Strength rest timer and elapsed display don't track wall-clock** — `StrengthActiveView.swift:105, 429-434, 484-497`: rest countdown pauses while the app is suspended (no `Date`-based deadline); the header elapsed time only updates as a side effect of unrelated state changes.

### Training-plan math
- ✅ **M28. Cutback weeks never cut back; volume flatlines at week ~5** — `TrainingPlanService.swift:352-359`: the "cutback" multiplier equalled the *previous* week (0 % reduction, comment claimed ~20 %), and since `1.1⁴ ≈ 1.464 > 1.45` the clamp made every week from index 4 onward exactly `1.45 × base` — no progression, no cutbacks, contradicting AGENTS.md. **FIXED:** `weeklyKm` now ramps ~8 %/week capped at the phase peak multiplier, and cutback weeks (every 4th) multiply the *capped* trend by 0.8 for a genuine ~20 % dip (e.g. base 30 km → 30 → 32 → 35 → 30 (cut) → 41 → 44 → 45 → 36 (cut) → 45). Covered by `TrainingPlanServiceTests` progression/cutback assertions.
- **M29. Reducing run days deletes the long run** — `TrainingPlanService.swift:1149-1157`: excess (latest-dated) workouts are deleted, and the long run is always last in the week.
- **M30. `applyNewRunDays` creates oversized stub runs** — `TrainingPlanService.swift:1164-1167`: `remainingKm` ignores already-completed volume; a mid-week day-count change can add 35 km of new easy running to a week with 15 km outstanding.
- **M31. Race-week strength sessions can be scheduled after race day** — `TrainingPlanService.swift:159-165, 207-230`.
- **M32. Weekly volume not conserved for 1–2 run days** — `TrainingPlanService.swift:438-453`: with no easy slots the remainder fraction is silently dropped (1 run day → only 35 % of target scheduled).

### Aggregation & display
- ✅ **M33. Period "Avg Pace" is an unweighted mean of per-run paces** — `ProgressView.swift:493-496` (verified): one long fast run + one short slow jog average to 6:30/km when the true distance-weighted pace is ~5:09/km. Use Σduration/Σdistance (as `PlanSummaryService` already does). **FIXED (PR #230):** distance-weighted via `ProgressStatsService`.
- **M34. Weekly Summary intent uses a different week start than the app** — `IntentDataProvider.swift:95-103` uses locale default (Sunday in US) vs the app-wide Monday `startOfWeek` (`Date+Extensions.swift:5-10`); Siri and the dashboard disagree by a whole run.
- **M35. Every run ≥400 m is treated as a VO₂max sample** — `RunSummaryView.swift:52-56`, `ProgressView.swift:59-65`: easy runs systematically depress the "fitness" trend; filter to quality/race efforts like the tempo-insights path does.
- **M36. Address search races** — `RouteGeniusView.swift:198-200`, `RouteGeniusViewModel.swift:107-120`: per-keystroke `MKLocalSearch` tasks aren't cancelled; stale responses clobber newer ones.
- **M37. Smart Adapt runs as an uncancelled fire-and-forget task** — `PlanTabView.swift:39`: keeps mutating and saving `ScheduledWorkout`s (and resyncing HealthKit) after the plan is deleted or the tab is switched; the mid-loop dedup (`:181-230`) can also delete workouts still queued for mutation in the captured array.
- **M38. History multi-delete iterates an `IndexSet` against a recomputed array** — `HistoryView.swift:117-136`: `displayedEntries` is re-derived per access mid-loop; offsets can shift. Snapshot once before the loop.
- ✅ **M39. QA helper writes a fake run into the real store** — `NotificationService.swift:218-228` (from `SettingsView.swift:372`): inserts an unmarked 5 km `RunWorkout` that pollutes stats and syncs to CloudKit; the tag-based `clear` can't remove it. **FIXED:** `triggerSyncedRunTestNotification` now builds a transient sample run and no longer inserts it into the store; the tap-to-review flow rides on the review snapshot (which `AppContainer` surfaces via the snapshot fallback). Covered by `NotificationServiceTests`.
- **M40. Restore timeout indistinguishable from success** — `WelcomeBackRestoreCoordinator.swift:69`: the Bool from `waitForImport` is discarded, so a 60 s timeout routes a returning user into fresh onboarding instead of a "still syncing" state.

---

## 4. Security & privacy

- ✅ **S1 (high). ORS API key in plaintext UserDefaults *and* synced through iCloud KVS** — `AppSettings.swift:16, 24-28, 129-140`: `localOnlyStringKeys` is empty ("kept for future secrets") while `orsAPIKey` — a present-day secret — flows into `NSUbiquitousKeyValueStore` and `UserDefaults`. Minimum fix: add the key to `localOnlyStringKeys`; proper fix: Keychain (pattern already exists in `AuthService`). Note the documented `Secrets.plist` path (AGENTS.md, `RouteGeniusService.swift:10-13`) is dead — no code reads that file. **FIXED:** added a reusable `KeychainStore` (generic-password, `AfterFirstUnlockThisDeviceOnly`); `AppSettings.orsAPIKey` now reads/writes the Keychain and a one-time migration moves any plaintext token out of UserDefaults/KVS and purges both copies.
- **S2 (medium). AppLogger persists every log line to the on-disk Pulse store in production** — `AppLogger.swift:28-37`: `LoggerStore.shared.storeMessage` is gated only on `#if canImport(Pulse)`, not `isDiagnosticsEnabled` — and since `activateIfNeeded()` no-ops in production, the 64 MB/7-day retention limits never apply. `privacy: .public` also exposes payloads in sysdiagnose. Logged payloads include workout coordinates (~10 m precision), distances, and source bundle IDs.
- **S3 (medium). Full GPS traces written to UserDefaults per synced run, mostly never cleaned** — `NotificationService.swift:144-157, 251-255`: `storeReviewSnapshot` serializes the entire `RunWorkout` including route coordinates for *every* import; removed only if that specific notification is tapped. A 90-day import writes dozens of plaintext location traces into the defaults plist.
- **S4 (low). Pulse remote logging enabled for all TestFlight users** — `PulseIntegrationService.swift:34-41, 92`: sandbox-receipt gating turns on `RemoteLogger` (Bonjour) for every tester, and the dev-only `NSLocalNetworkUsageDescription` ships in the release Info.plist.
- **S5 (low). Pulse header redaction is ordering-dependent** — `PulseIntegrationService.swift:43-52` vs `RouteGeniusService.swift:61`: the `Authorization` redaction only exists after `configureNetworkLogger()`; nothing enforces that ordering for future `RouteGeniusService` constructions.

---

## 5. Design & architecture issues

These are the systemic themes; most of the concrete bugs above are downstream of them.

### D1. Business logic in views (the largest theme; violates AGENTS.md)
- `PlanTabView.swift:132-345`: ~100 lines of AI plan-adaptation orchestration including a hand-rolled streaming-JSON parser and dedup-priority rules — none unit-testable.
- `RunSummaryView.swift` (2,038 lines, self-acknowledged `swiftlint:disable file_length`): map, charts, splits table, an entire AI-coach subsystem, and plan-mutation logic (`:1267-1460`) that writes to the training plan and HealthKit from a history detail view.
- `ProgressView.swift:59-65, 492-526, 600-615`, `RaceInsightsView.swift:46-127`, `MedalsView.swift:59-87`: VDOT points, period averages, weekly bucketing, linear-regression trends, PR bucketing — all in view structs. This is exactly how H12, M33, and M34 shipped untested.
- Plan lifecycle (fetch-existing → delete → generate → insert → cleanup) duplicated wholesale between `PlanSetupView.swift:250-297` and `NewPlanOnboardingView.swift:581-638`, already diverged (the `PlanSetupView` path drops race metadata).

**Recommendation:** create `ProgressStatsService` (PRs, weekly buckets, period aggregates), a `PlanLifecycleService` (create/replace/delete with all cleanup), and move Smart Adapt orchestration into a service or view model. Add tests as each moves.

### D2. AppContainer is a god object
`AppContainer.swift:214-231, 283-432`: `attachWeather`, `adaptedWorkout(s)`, `refreshPlanAfterWorkout`, `rescheduleWorkouts`, `shiftMissedWorkoutsForward`, `rebuildPlan` — real date math, deletion policy, and plan regeneration on the DI container, untestable without a full container. `attachWeather` is also duplicated in `WorkoutSyncService.swift:371-375`.

### D3. No single choke point for cross-cutting invariants
- Two competing HealthKit-run linkers with different rules (`WorkoutSyncService.swift:207-226` vs `:231-278`) → H8.
- Deletion logic exists in three variants (repository + two views), each slightly different → H9, M20.
- `pendingReviewWorkoutID` is an undeclared UserDefaults protocol between four types (`NotificationService`, `WorkoutSyncService`, `AppContainer`, `StrideApp`).

### D4. Observation & DI foot-guns
- `ObservableObject` container exposed via a custom `EnvironmentKey` (`AppContainer.swift:563-568`): views reading `@Environment(\.appContainer)` don't re-render on `@Published` changes; the app only works because one view separately takes `@ObservedObject`. Use `.environmentObject` or `@Observable`.
- `NotificationService` is an untestable singleton with a mutable global callback (`NotificationService.swift:8-14, 25-29`) — the exact hidden-container capture hazard AGENTS.md warns about.
- Injected `@Observable` view models stored in `@State` (`RouteGeniusView.swift:15`): sheet re-evaluation constructs throwaway VMs, each starting `CLLocationUpdate.liveUpdates()` in `init`.
- `AuthService` init spawns an infinite `for await` task whose `[weak self]` is defeated immediately (`AuthService.swift:22-25, 62-68`) — instances never deallocate.

### D5. Pervasive `try? context.save()`
Representative: `StrideApp.swift:198,202`, `AppContainer.swift:229,257`, `WorkoutSyncService.swift:225,334,368`, `PlanTabView.swift:159,229`, `ActiveRunView.swift:438-458`, `StrengthActiveView.swift:519`. A save failure after finishing a run loses the workout with zero user feedback and no log. Add a `saveOrLog` helper at minimum; surface failures on user-initiated writes.

### D6. Unfiltered `@Query`/fetches of entire tables
`DashboardView.swift:228-229`, `PlanTabView.swift:15`, `AICoachChatView.swift:11`, `RunSummaryView.swift:18-19` (all workouts fetched per detail push to find one match already available as `workout.scheduledWorkout`), `ProgressView/RaceInsightsView/MedalsView`, `HistoryView.swift:28-32` (fetches all, paginates in memory), `AppContainer.surfacePendingReviewWorkout:250-252` (linear scan for one UUID at cold launch). With years of imported history this is dashboard jank on every save. Also `MissedWorkoutDetector` runs inside `body` on every evaluation (`DashboardView.swift:249-260`).

### D7. Dead code & drift
- `AICoachService.swift` (1,155 lines): the fault-tolerant JSON decoding machinery (`:36-184`) is dead post-guided-generation — and buggy (`decodeFlexibleIntIfPresent` strips minus signs).
- Empty notification stubs `scheduleReminder(s)` + cancels for IDs never scheduled (`NotificationService.swift:66-71, 162-168`).
- `RunSummaryView`: unused `AIActionItemRow` (~67 lines), write-only `aiStreamBuffer`, thumbs up/down feedback discarded, hardcoded pseudo-tabs (`:1496-1498`).
- Onboarding chart re-implements `TrainingPlanService` math by hand (`OnboardingSubviews.swift:1172-1205`) — the preview can drift from the real plan.
- Five near-identical markdown sanitizers in one file (`RunSummaryView.swift:1133-1226, 2003-2016`).
- `DataMigrationService` contains no migration logic; duplicates receipt detection from `PulseIntegrationService`.

### D8. Accessibility & localization
- `AppFonts.swift:59-62` shadows SwiftUI's `Font.caption` etc. with fixed-size fonts, breaking Dynamic Type app-wide (the file's own comment explains why the `ds` prefix exists).
- `ActiveRunView.swift:344-379`: the finish control is an `.onTapGesture` on a non-Button — **a VoiceOver user cannot end a run**; the flag and "Lock" controls are dead UI.
- Dashboard calendar day cells and week chevrons aren't accessible buttons (`DashboardView.swift:59-88`).
- Charts have no accessibility labels; `StrideIcon` (raw `Canvas`) exposes nothing by default.
- Hardcoded HR thresholds (155/175 bpm) in coach heuristics rather than profile-derived (`AICoachChatView.swift:505,539`, `RunSummaryView.swift:486-488`).
- Unit-conversion constants scattered as literals with mixed precision (`1.60934`, `1_609.344`, `0.621371`) across ≥8 files — centralize.
- All user-facing strings are unlocalized literals.

---

## 6. Low-severity bugs & polish

- Race Fitness card shows green "On goal pace" when there is simply no prediction data (`RaceInsightsView.swift:76-87, 196-208`).
- Imperial custom-distance stepper steps in 0.5 km (~0.31 mi) increments (`PlanSetupView.swift:104-117`).
- Onboarding "Build My Plan" wedges the spinner if the profile guard fails (`NewPlanOnboardingView.swift:212-216, 581-582`).
- Strength fullScreenCover can present an empty, undismissable screen if the plan mutates between tap and presentation (`DashboardView.swift:308-312`).
- `phaseTransitions` `ForEach(id: \.self)` can produce duplicate IDs when a phase has zero weeks (`PlanTabView.swift:662-673`).
- Every AI-coach reply gets the "opening" metric chips, and `openingStatus` returns `.dataBacked` when there is *no* data (`AICoachChatView.swift:361-369, 503-546`).
- Weekly load chart hardcodes 15 km = full bar (`DashboardView.swift:381-382`).
- Recovery-card loading overlay can never appear — flag set and cleared synchronously (`DashboardView.swift:568-595`).
- Route out-and-back midpoint uses straight-line distance/2 — real routes systematically overshoot (`RouteGeniusService.swift:179-208`); URL-construction failure reported as "no route found" (`:214-216`).
- `isAuthorized` rejects `.provisional`/`.ephemeral` notification grants (`NotificationService.swift:56-61`).
- Map camera doesn't refit when a same-coordinate-count route is selected (`RouteMapView.swift:36`).
- Interval duration estimate counts a recovery after the final rep; dead `min(baseReps+1, baseReps+2)` expression (`TrainingPlanService.swift:706, 751-756`).
- `AssociateWorkoutSheet` offers strength/cross-training slots as link targets for runs (`AssociateWorkoutSheet.swift:16`).
- `vdot(distanceMeters:timeSeconds:)` returns ∞/NaN on zero time — add a guard at the primitive (`PaceCalculatorService.swift:46-50`).
- `Data+JSON` `try?` in both directions: an encode failure (e.g. NaN in a split) silently **wipes** previously stored data; decode failures read as "no data" (`Data+JSON.swift:6-13`).
- Large route/splits blobs lack `@Attribute(.externalStorage)` despite the doc comment claiming it — long-run records can exceed the ~1 MB CKRecord limit and silently stop syncing (`SavedRoute.swift:9-10, 39-41`; `RunWorkout.swift:32-35`).
- `HealthKitRepository.save` exports only a bare distance sample — no HR, route, or energy — so Stride-recorded runs look empty in Apple Fitness (`HealthKitRepository.swift:127-160`).
- `shortDayLabel` allocates a `DateFormatter` per call with a non-localized format (`Date+Extensions.swift:33-37`).
- Onboarding step counter shows "2/9" on the first step and "9/9" twice (`OnboardingSubviews.swift:387`); skipping the 5K-time step records the untouched default 26:24 as the user's estimate (`OnboardingView.swift:180-182`).
- `AppSpacing` comment says `md` = 16 but `md = 12` (`AppSpacing.swift:4-6`).
- `StrengthLibrary.exercises(for:)` alphabetical sort means the most running-specific equipment is always truncated first (`StrengthLibrary.swift:44-53`).
- Settings "sync restart" note latches on and never clears (`SettingsView.swift:227-237`).
- `CloudKitDebugView` renders six unfiltered tables as one JSON `Text` (`CloudKitDebugView.swift:36-48`).

---

## 7. CI, config & tooling

- **`ENABLE_TESTABILITY: YES` applies to Release/archive builds** (`project.yml:16`) — set in `settings.base` with no Release override; App Store builds compile `-enable-testing`, disabling optimizations. Make it Debug-only.
- **SwiftLint config is misconfigured** (`.swiftlint.yml:1-6, 32-52`): `included` lists a nonexistent `WatchApp` target; `StrideTests`/`StrideUITests` aren't linted; error thresholds are unreachable in practice (`file_length` error 2000, `function_body_length` error 350, `cyclomatic_complexity` error 80) — a 1,900-line type passes CI.
- **CI does run and gate tests** (good), but: lint runs on `macos-26` while build/test run on `macos-27` (two toolchains, one pipeline); `brew install swiftlint`/`xcodegen` are unpinned; the simulator lookup hardcodes runtime `iOS-27-0` (`ci.yml:125-134`) and will break when the runner image moves to 27.1; `continue-on-error: true` steps render green on failure, hurting triage.
- **Info.plist and entitlements have two sources of truth** — checked-in files *and* `project.yml` `properties:` blocks that regenerate them; direct edits are silently reverted by `xcodegen generate`. Pick one.
- **GH Actions and Xcode Cloud archives produce differently-versioned binaries** — Actions never sets `CURRENT_PROJECT_VERSION`; Xcode Cloud's `ci_post_clone.sh:24-26` seds it into `project.yml` (a fragile whole-file substring replace — pass it as an `xcodebuild` setting instead).
- **UI-test runs leak state** — `--uitesting` makes the store in-memory but never resets `UserDefaults`/KVS, so `AppSettings` leak between runs on the same simulator.

---

## 8. Test coverage gaps

Existing test files cover: PaceCalculator, TrainingPlanService, PlanSummaryService, MissedWorkoutDetector, StrengthLibrary, RouteGenius, FoundationModels coach, AppContainer, persistence graph, restore/dedup, WorkoutKit fire dates, missed-workout recovery.

**Services with no test file at all — and where this review found the worst bugs:**

| Untested source | Criticals/highs found there |
| --- | --- |
| `WorkoutTrackerService` | C1 (GPS distance), C2 (stuck state machine), M23–M26 |
| `WorkoutSyncService` | H8 (wrong linking), H9 (resurrection), M1–M8 |
| `WorkoutAnalyticsService` | H2 (adaptation misclassification) — now covered by `WorkoutAnalyticsServiceTests` |
| `HealthKitRepository` | M9–M13 |
| `NotificationService` | M3–M7 (also untestable as a singleton — D4) |
| `WeatherService` | H7 (historical weather) |
| `AppSettings` | M15–M16, S1 |
| All view-embedded stat math | H12, M33, M34, M35 |

Also notable: pace/plan tests exist but did not catch H2.2 (double-discounted paces) or M28 (flat volume) — worth adding assertions against published Daniels values and explicit progression-shape tests rather than testing the implementation against itself. Several services take internal `Date()`/`Calendar.current` (`TrainingPlanService.refreshPaces:1094`, `applyNewRunDays:1135`, `WorkoutAnalyticsService.snapshot:81`), which blocks deterministic tests — inject `now` as the already-good services do (`MissedWorkoutDetector`, `PlanSummaryService`).

---

## 9. What is in good shape

Worth stating so the fixes don't churn what works:

- **Architecture direction is right**: composition root, repository/service protocols, `@Model` design (all attributes defaulted, relationships optional with explicit inverses — CloudKit-safe), and the `@Attribute(originalName:)` migration pattern.
- **`PlanSummaryService` and `MissedWorkoutDetector` are exemplary**: injectable clocks, distance-weighted math, guards on zero denominators — the template the other services should follow.
- **Unit-conversion extension math is correct** (1609.344 m/mi, temperature/wind/elevation), `Date.startOfWeek` correctly pins Monday, `RunWorkout` pace math guards divide-by-zero.
- **CI genuinely builds, lints, and gates on tests**, with sensible path filtering; Xcode Cloud scripts are functional.
- **Onboarding welcome-back CloudKit wait** has proper timeout/continuation-once guards.
- Theme tokens (colors, radius, elevation, animations) are consistent aside from the `AppFonts` shadowing issue.

---

## 10. Prioritized action plan

**P0 — ship-stoppers (small, surgical fixes):**
1. ✅ C1: `autoPauseThresholdMs` 500 → 0.5.
2. ✅ C2: add tracker reset to `.idle`.
3. ✅ C4: share one `Schema` between app and intents.
4. ✅ C5: clamp `phaseSchedule` counts; guard past race dates.
5. ✅ C3: back up instead of deleting the store; remove the identical-config retry.
6. ✅ H1/H10: stop assigning `.week` on prompt/adaptation temporaries (one-line cause, plan-corrupting effect).

**P1 — data integrity:**
7. ✅ H9 + M20/M21: single repository delete path (tombstones for both types, `isCompleted` reset, full reset coverage).
8. ✅ H8: unify the two linkers; type-filter matches; never overwrite run type.
9. ✅ H3: deactivate rather than delete past plans; enforce single-active-plan in the repository.
10. ✅ M6/M39: tombstone-check the snapshot resurrection path; tag or remove the QA fake-run helper.
11. ✅ S1: move the ORS key out of KVS/UserDefaults (Keychain).

**P2 — training-math correctness (the product's core promise):**
12. ✅ H2: pace double-discount (H2.2) removed with Daniels-table tests; interval classification (H2.1) now computed from split efforts; VDOT sampling (H2.3) restricted to race efforts. Covered by `WorkoutAnalyticsServiceTests`.
13. M28–M32: ✅ M28 cutback/progression curve fixed; *remaining:* M29–M32 (long-run preservation, volume conservation).
14. ✅ H6: week `endDate` boundary.
15. H7: historical weather.
16. M23: wall-clock elapsed time.

**P3 — structural (enables everything above to stay fixed):**
17. Extract `ProgressStatsService`, `PlanLifecycleService`, Smart-Adapt service; slim `RunSummaryView` and `AppContainer` (D1/D2).
18. Inject `now:`/notification-center/protocols so the untested services in §8 become testable; add tests as they move.
19. Replace `try? context.save()` with logged/surfaced saves (D5).
20. Filtered queries + move detector work out of `body` (D6).

**P4 — hygiene:**
21. Accessibility pass (Dynamic Type shadowing, run-finish button, calendar cells).
22. CI/config: `ENABLE_TESTABILITY` Debug-only, SwiftLint thresholds + real targets, pin toolchains, single source for plist/entitlements.
23. Dead-code removal (AICoach decoders, notification stubs, RunSummaryView leftovers).
24. Privacy: gate Pulse persistence on diagnostics mode, stop writing GPS snapshots to UserDefaults, TestFlight remote-logger opt-in.
