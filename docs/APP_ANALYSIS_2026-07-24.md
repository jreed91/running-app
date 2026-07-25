# Stride Second-Pass Code Analysis — 24 July 2026

A fresh full-app review taken **after** the July audit's fixes landed
([`APP_ANALYSIS_2026-07.md`](./APP_ANALYSIS_2026-07.md), effectively all items
closed). Every finding here was verified directly against the source at commit
`75c0e27` and cites `file:line` as of that commit.

Two kinds of finding are recorded:

- **New defects** (`N*`) — bugs, UX problems, and cleanup found in this pass,
  including several that only became reachable *because* of the earlier fixes
  (retaining past plans, the store-recovery notice, the split-unit rework).
- **Re-verified carry-overs** — items the July document left open or partially
  fixed, confirmed still present today (§6), so they don't get lost.

> **Fix tracking:** mark items **✅ FIXED** with a note on where, in the same
> style as the July document. Line numbers in fixed items refer to this
> document's commit and may drift.
>
> **Status:** Priority 1 (data loss: N1, N2, N6, N15), Priority 2
> (N3, N4, N5, N7, N8, N9, N10, plus the plan-scoping half of N13), Priority 3
> (UX debt: N12, N17, N19, N20, N24, plus the blocking half of N18), and Priority 4
> (hygiene: N11, N13's dialog, N14, N16, N21, N22, N23, N25, N26's code half,
> N27–N30, and the lint half of N31) are fixed — see §8. A third pass then closed
> **N9's split backfill**, the rest of **N18** bar localization, and **D6**. A fourth
> closed **N6's race-date remainder** (the last open half of a Priority 1 item) and
> **D5**. A fifth took the testable halves of **D1** and **D2** and closed **D7**
> (`SmartAdaptSummaryStream`, `AdaptableWorkoutSelector`, `ProgressPeriodStats`,
> `PlanRebuildWindow`, `ScheduledWorkout.applyAdaptation`). What remains open:
> **localization** (the last of N18/D8), N31's two unobserved toolchain pins, and the
> remaining §6 carry-overs (D1's `RunSummaryView` size, D2's orchestration, D3, D4,
> `.externalStorage`, S4).

> **Scope:** correctness, UX, and hygiene. Product/feature gaps live in
> [`FEATURE_IMPROVEMENTS_2026-07.md`](./FEATURE_IMPROVEMENTS_2026-07.md);
> operational/CI topics in [`REPO_ANALYSIS.md`](./REPO_ANALYSIS.md).

**Contents**
1. [High-severity bugs](#1-high-severity-bugs)
2. [Medium-severity bugs](#2-medium-severity-bugs)
3. [UX issues](#3-ux-issues)
4. [Cleanup, dead code & drift](#4-cleanup-dead-code--drift)
5. [Test coverage gaps](#5-test-coverage-gaps)
6. [Carry-overs from the July analysis (re-verified open)](#6-carry-overs-from-the-july-analysis-re-verified-open)
7. [What got better](#7-what-got-better)
8. [Prioritized action plan](#8-prioritized-action-plan)

---

## 1. High-severity bugs

The first three share a root cause: **H3 changed the plan lifecycle from
"delete" to "deactivate", but three code paths were never brought along.** Past
plans now persist as inactive rows, which two of those paths delete outright and
a third silently mistakes for the active plan.

### ✅ N1. "Rebuild my plan" still deletes the plan it replaces

**FIXED:** `rebuildPlan` no longer deletes anything. `PlanRepository.save(newPlan)`
already enforces the single-active invariant by deactivating every other plan, so
the replaced block is retired and stays in Plan History with its completed
workouts and their run links intact. The retired plan's WorkoutKit entries are
removed on a fire-and-forget task, which the delete path never did (they were
orphaned on the Watch with no way left to find them). Covered by
`MissedWorkoutsRecoveryTests` (`rebuildRetiresOldAndCreatesNew`,
`rebuildPreservesCompletedHistory`).

`Stride/App/AppContainer.swift:573-612` (delete at `:609`); invoked from
`Stride/Features/Dashboard/DashboardView.swift:620-630`

```swift
try planRepository.delete(oldPlan)
try planRepository.save(newPlan)
```

`TrainingPlan.weeks` and `TrainingWeek.workouts` both cascade
(`TrainingPlan.swift:27`, `TrainingWeek.swift:22`), so one tap on the
missed-workout card's **Rebuild** button destroys the plan, every week, and
every `ScheduledWorkout` in it — including completed ones. The runs survive
(`ScheduledWorkout.completedWorkout` is `.nullify`), but they lose their plan
link, so Plan History loses the block, `PlanSummaryCard` has nothing to show,
and adherence stats for that block are gone. This is exactly the data loss H3
fixed for the *creation* flows, left intact in the *recovery* flow — and it fires
from a card the app itself puts in front of a user who has fallen behind.

**Fix:** deactivate `oldPlan` (`isActive = false`) and save the new plan through
`PlanRepository.save`, which already enforces the single-active invariant.
Deletion should stay a deliberate swipe in Plan History.

### ✅ N2. Launch-time dedup deletes duplicate active plans instead of deactivating them

**FIXED:** the rule moved out of the view into
`ProfileRestoreDeduplicator.retireDuplicateActivePlans(_:in:)` (where the profile
dedup already lives) and now sets `isActive = false` on every plan after the
first instead of deleting it. Covered by `PlanHistoryTests`
(`duplicateActivePlansAreRetiredNotDeleted`, `singleActivePlanIsUntouched`).

`Stride/App/StrideApp.swift:205-215`

```swift
if activePlans.count > 1 {
    activePlans.dropFirst().forEach { context.delete($0) }
    try? context.save()
}
```

`deduplicate()` runs on every launch, on every `activePlans.count` change, and
on every profile-count change. Two active plans is precisely what a CloudKit
multi-device race produces (create a plan on the iPhone while the iPad still has
one active; both records arrive), and the loser is **permanently deleted with its
whole history**, not deactivated. The profile path next to it merges before
deleting; the plan path does not.

**Fix:** `activePlans.dropFirst().forEach { $0.isActive = false }`. The
"only one active" invariant is preserved and nothing is destroyed. Add a
`PlanHistoryTests` case for the two-active-plans restore shape.

### ✅ N3. `ActiveRunView` refreshes paces on an arbitrary plan

**FIXED:** both queries now match the rest of the app — plans filtered to
`isActive` and sorted by `createdAt` descending, profiles sorted by `updatedAt`
descending.

**Related, fixed with it:** retiring plans instead of deleting them means their
future days stay in the store, so the automated paths that pick a scheduled
workout had to learn to ignore them. `WorkoutSyncService.belongsToLivePlan(_:)`
now gates both linkers (a run can no longer complete a retired plan's day), and
`IntentModelActor.todaysRun()` filters the same way so Siri can't read out a
workout from a replaced plan — the plan-scoping half of N13. Workouts with no
plan at all stay eligible, since excluding them would silently break linking on
legacy stores. Covered by `PlanHistoryTests`, `WorkoutSyncServiceTests`
(`syncNowIgnoresRetiredPlanDays`), and `IntentDataProviderTests`.

`Stride/Features/ActiveRun/ActiveRunView.swift:16, 505-514`

```swift
@Query private var activePlans: [TrainingPlan]   // no filter, no sort
...
if let profile = profiles.first, let plan = activePlans.first {
    container.refreshPlanAfterWorkout(plan: plan, ...)
}
```

Every other site filters (`PlanTabView.swift:11`, `RunSummaryView.swift:22-26`,
`SettingsView.swift:14-18`, `StrideApp.swift:122-126`). Here the query is
unfiltered *and* unsorted, so `.first` is whatever SwiftData returns — and now
that past plans are retained, that is frequently a finished plan. Finishing a run
then re-derives training paces for a **completed** block while the real active
plan is never refreshed. `profiles.first` is likewise unsorted, where
`ContentView` deliberately sorts by `updatedAt` descending during restore.

**Fix:** `@Query(filter: #Predicate<TrainingPlan> { $0.isActive }, sort: \.createdAt, order: .reverse)`
and sort profiles by `updatedAt` descending, matching the rest of the app.
Better: resolve both through `AppContainer`/`PlanRepository.fetchActivePlan()` so
there is one definition of "the active plan".

### ✅ N4. The History tab is a second, divergent HealthKit importer

**FIXED:** the local import is gone. `WorkoutSyncService` gained
`syncNow(lookbackDays:source:)` — the same pass the observer runs, with a caller-
supplied window — and History calls it with 60 days. Linking, tombstones, strength
merge-by-start-time, weather attach, notification batching, and the review sheet
are now identical no matter which screen triggers the import, and an authorization
failure is logged instead of swallowed. Covered by `WorkoutSyncServiceTests`
(`syncNowLinksImportedRunToPlan`).

`Stride/Features/History/HistoryView.swift:134-186`

Opening History runs its own 60-day import that bypasses `WorkoutSyncService`
entirely, and it differs from the canonical path in four ways:

1. **No plan linking.** Imported runs never go through `linkToScheduledWorkouts`
   (`WorkoutSyncService.swift:261-305`). Because History usually wins the race
   (it imports on tab appear), the run is already in the store when the real sync
   next runs, so it is skipped as "existing" — and its scheduled day *never*
   completes. The calendar keeps showing the workout as missed and the
   recovery card nags about a run the user actually did. This is H4/H8's symptom
   arriving through a different door.
2. **Same-calendar-day strength dedup** (`:170-180`) — the exact rule M8 replaced
   with `WorkoutSyncService.isSameStrengthSession` (±3 h). A morning app-logged
   session and an evening Watch session still collapse into one here, discarding
   the Watch workout's real time and duration.
3. **No notifications and no review snapshot**, so runs imported this way never
   surface the post-run review sheet.
4. **Errors are swallowed silently** (`:183-185`, `// Silent failure`) with no
   log line at all, so a failing import is undiagnosable from Pulse.

**Fix:** delete the local import and call
`container.workoutSyncService` (add a `syncNow()` entry point that takes a
lookback window). One importer, one set of rules — the D3 recommendation, now
with a concrete second offender.

### ✅ N5. The store-recovery alert cannot appear in the case it was written for

**FIXED:** the `.task`/`.alert` pair moved from `MainTabView` up to `ContentView`,
above the onboarding/tab-bar branch, so the notice presents whichever screen the
launch lands on. `MainTabView` keeps a comment pointing at the new home.

`Stride/Features/Dashboard/MainTabView.swift:38-54`; root switch at
`Stride/App/StrideApp.swift:138-145`

C3's fix surfaces `AppContainer.StoreRecoveryNotice` — but only from
`MainTabView`, and `ContentView` shows `MainTabView` **only when a profile
exists**:

```swift
if profiles.isEmpty { OnboardingView() } else { MainTabView() }
```

The `.storeMovedAside` case *means the store was recreated empty*, so
`profiles.isEmpty` is true and the user lands in onboarding. The one screen that
would explain "your database couldn't be read, nothing was deleted, iCloud will
restore it" is never mounted. The notice is also cleared on read, so the next
launch shows nothing either. `.runningInMemory` has the same hole whenever it
happens on a device whose profile hasn't loaded.

**Fix:** attach the alert at the root (in `ContentView`'s `Group`, or on
`ContentView` itself) so it presents over onboarding as well. Add a test that
asserts the notice survives to a view presented when `profiles.isEmpty`.

### ✅ N6. Smart Adapt deletes any second workout scheduled on the same day — including strength

**FIXED,** both halves:

- **The rule.** Duplicate detection moved out of `PlanTabView` into the pure
  `PlanDuplicateResolver`, which groups by day **and** `WorkoutType.SessionKind`
  (run / strength / cross-training / rest). Only a second session *of the same
  kind* is a duplicate, so a paired run + gym day survives adaptation.
  *Superseded by N29:* pruning is gone entirely, and the resolver with it — nothing
  deletes a "duplicate" now, and `ScheduledDayResolver` renders both sessions.
- **The collision.** `shiftMissedWorkoutsForward` now moves strength and
  cross-training with the runs rather than holding them still, so "pick up where
  I left off" preserves the week's spacing instead of dropping runs onto gym days.
  Rest days still stay put. Covered by `MissedWorkoutsRecoveryTests`
  (`shiftMovesStrengthWorkouts`).

**The race-date remainder is now fixed too.** Holding the race workout still was never
enough on its own — the rest of the block slid straight over it, so a runner four days
behind could end up with a tempo session on race morning and a long run the day after
the finish. `MissedWorkoutShift.resolve` clamps the requested shift to the headroom
that actually exists between the last movable session and the day *before* the race,
so the shift stays uniform (the whole point: it preserves the spacing the plan was
generated with) and simply travels less far. A shift the race blocks outright changes
nothing, leaves the recovery card up — Rebuild is the only recovery left, and hiding
the prompt for a week would take it away — and says so. Covered by
`MissedWorkoutShiftTests` and a plan-level
`MissedWorkoutsRecoveryTests.shiftIsClampedByRaceDate`.

(N12 — the dashboard showing only one of a day's two sessions — is fixed, so same-day
pairs are now both visible as well as both retained.)

`Stride/Features/Training/PlanTabView.swift:322-366`

`removeSameDayDuplicateWorkouts` groups **all** of a week's workouts by calendar
day and deletes everything but the highest-priority one, where
`duplicatePriority` ranks `easy` (4) above `strength` (5). Plan generation never
double-books a day (`TrainingPlanService.buildStrengthWorkouts:195` blocks run
days), but the app creates that state itself:
`AppContainer.shiftMissedWorkoutsForward:548-555` shifts runs forward while
explicitly *excluding* strength, cross-training, and rest from the shift.

So the sequence is entirely ordinary: fall behind → tap **Pick up where I left
off** (runs shift onto strength days) → tap **Smart Adapt** → the strength
sessions are silently deleted from the plan, reported to the user as
"Schedule cleanup: removed 1 same-day duplicate workout".
`RunSummaryView.removeDuplicateFutureRuns:1434-1463` has a narrower version of
the same behaviour (run-types only) on the coach-feedback path.

**Fix:** two changes. (a) Scope duplicate detection to same-day workouts *of the
same kind* (run vs strength vs cross-training) so a legitimately paired day is
never collapsed. (b) Make the shift collision-aware — either shift the whole day
(strength included) or skip a target date that is already occupied. And see N29:
the pruning exists to clean up phantom workouts whose producers were removed.

---

## 2. Medium-severity bugs

### ✅ N7. A split's pace is not that split's pace

**FIXED:** both paths now close a bucket with its own Δtime ÷ Δdistance via
`SplitBucketing.splitPaceSecondsPerKm`, with the bucket's opening elapsed time and
distance tracked alongside `lastSplitDistance`. `currentPaceSecondsPerKm` is now
HUD-only and smoothed, since nothing derived reads it. Covered by `SplitPaceTests`,
including the negative-split case the indoor path could not express.

`Stride/Core/Services/WorkoutTrackerService.swift:333-356` (outdoor),
`:216-248` (indoor)

Outdoor, `currentPaceSecondsPerKm = 1_000 / location.speed` — the *instantaneous*
speed of one GPS fix — and that instant is what gets stored as the split's pace
when the boundary is crossed:

```swift
let split = Split(kilometer: unitsCovered, paceSecondsPerKm: currentPaceSecondsPerKm, ...)
```

Indoor, the pedometer path sets `currentPaceSecondsPerKm = elapsedSeconds / meters * 1_000`
— the *cumulative session average* — so every indoor split reports the same
running average and a negative-split run renders flat.

Neither is the split's average pace (Δtime ÷ Δdistance within the bucket), which
is what a split chart, a splits table, and the share card's "fastest split"
callout all claim to show. It also degrades H2's fix:
`WorkoutAnalyticsService.intervalEffortPace` derives rep pace from the fastest
third of splits, so its input is a single noisy GPS sample per bucket.

**Fix:** track `splitStartElapsedSeconds`/`splitStartDistanceMeters` alongside the
existing bucket state and compute the split pace from the deltas. Keep
`currentPaceSecondsPerKm` (smoothed) for the live HUD only. This is pure math
around `SplitBucketing` and should get direct unit tests.

### ✅ N8. No GPS quality filtering on the tracking path

**FIXED:** `LocationQualityFilter` is a pure accept/reject decision over accuracy
(invalid or worse than 25 m), staleness (older than 15 s — the cached fix Core
Location replays when updates start), and implied speed (faster than 12.5 m/s, or
a jump with no elapsed time). `processLocation` applies it before a fix reaches
the route or the distance total, and counts discards by reason for one debug line
at finish. Pausing an outdoor run now also clears `lastLocation`, so distance
covered while paused is no longer measured against the pre-pause fix and added on
resume — the outdoor twin of the pedometer replay M24 fixed. Covered by
`LocationQualityFilterTests`.

`Stride/Core/Services/WorkoutTrackerService.swift:312-359`

`processLocation` appends every fix to `coordinates` and accumulates
`location.distance(from: last)` with no check on `horizontalAccuracy` (negative
means invalid), no staleness check on `location.timestamp`, and no sanity cap on
the per-fix delta. Under trees, between buildings, or in the seconds after
`startUpdatingLocation()` while the fix converges, jitter is recorded as real
distance and drawn into the route. The auto-pause guard only suppresses *slow*
movement; a 40 m accuracy spike reads as fast movement and is kept.

**Fix:** drop fixes with `horizontalAccuracy < 0 || horizontalAccuracy > 25`, drop
fixes older than a few seconds, and ignore deltas implying an impossible speed.
Extract the accept/reject decision as a pure function and test it — the tracker
still has no unit tests for `processLocation` (see §5).

### ✅ N9. Imported runs have no splits at all

**FIXED:** the importer reads the workout's `distanceWalkingRunning` series
(`fetchDistanceSeries`) and buckets it through `SplitBucketing.splits`, which
interpolates the moment each boundary is crossed inside the sample spanning it and
drops any bucket whose timing can't be established rather than storing a zero
pace. Buckets use the runner's own unit, and each split carries a heart rate
averaged over the matching window of the run's HR series. Covered by
`ImportedSplitsTests`.

**The backfill half is now fixed too.** Opening a run that predates the change fetches
its distance series once — `HealthKitRepository.fetchDistanceSeries(forWorkoutID:)`, the
twin of the HR fetch, both now resolving the workout through one `hkWorkout(withID:)` —
buckets it through the same `SplitBucketing.splits`, and caches the result on the run, so
the split charts and the splits table appear where they had been permanently hidden. It
runs *after* `loadHeartRateZones`, so a just-backfilled heart-rate series gives each split
its own heart rate, exactly as an import does. `SplitBackfill.needsSplits` holds the "is
this worth a query?" rule — no splits yet, a HealthKit id to fetch from, and at least one
whole bucket covered — and is covered by `SplitBackfillTests`.

`Stride/Core/Repositories/HealthKitRepository.swift:604-665`

The importer builds heart rate, elevation, and the route, but never
`run.splits`. For an Apple Watch user — whose runs *all* arrive by import — the
run detail screen therefore never shows the split pace chart, split HR chart,
split elevation chart, or splits table (`RunSummaryView.swift:176-181` gates all
four on `!workout.splits.isEmpty`), the share card has no split bars, and
`intervalEffortPace` falls back to the session average, which is the exact
misclassification H2.1 fixed. HealthKit has what's needed: the
`HKQuantityType(.distanceWalkingRunning)` samples the importer already knows how
to query (`fetchDistanceMeters(for:)`, `:728`) carry per-sample timestamps.

**Fix:** bucket the imported distance samples into splits at import time (reuse
`SplitBucketing`, set `splitUnit` from the user's preference), and backfill
lazily for already-imported runs the same way `loadHeartRateZones` backfills HR.

### ✅ N10. Workout-type inference uses an absolute pace threshold

**FIXED:** `inferWorkoutType` is now static, takes the runner's `TrainingPaces`,
and classifies a run as quality only if its average is at or inside **marathon
pace** — clear of the top of the easy band, and slow enough to admit a tempo
session recorded with its warm-up and cool-down. With no 5 K estimate on the
profile there is nothing to classify against, so the run is `.easy` unless its
distance makes it a long run. Intervals are still not inferred; that needs the
workout's structure, not an average. The paces and the split unit travel together
in a `WorkoutImportContext` resolved from the store
(`WorkoutImportContext.resolve(from:)`), so the background sync and the manual
Settings import agree. Covered by `WorkoutTypeInferenceTests` and a
`WorkoutSyncServiceTests` case asserting the context is resolved and forwarded.

`Stride/Core/Repositories/HealthKitRepository.swift:893-899`

```swift
if distanceKm >= 16 { return .longRun }
if paceSecPerKm < 320 { return .tempo }   // 5:20/km for everyone
return .easy
```

The threshold is runner-independent, and it feeds decisions that matter:
`ProgressStatsService.estimatedVDOT` only samples `isQualitySession` types, and
`RunSummaryView.tempoInsights` only renders for `.tempo`. A sub-40 5K runner has
every easy run labelled "Tempo", inflating the VO₂-max trend with easy efforts; a
6:00/km beginner never produces a quality session, so the "Estimated VO₂ Max"
chart shows "Not enough run data in this period" forever, no matter how much they
run. `.interval` and `.race` are never inferred at all.

**Fix:** classify relative to the runner's own paces —
`PaceCalculatorService.trainingPaces(from5KTimeSeconds:)` already produces the
bands — and default to `.easy` when there is no profile estimate. Structure
(HealthKit workout events / lap markers) can distinguish intervals.

### ✅ N11. "Reset All Data" only resets the database

**FIXED:** the whole teardown is one routine, `AppContainer.resetAllData(context:)`.
It cancels every morning reminder, removes the WorkoutKit entries for **each** plan
being deleted (before the models go, since the entries are found through the plans
that own them), clears the pending-review pointer and every review snapshot via the
new `NotificationService.clearAllReviewState`, and only then deletes the models —
logging the outcome instead of swallowing it. Settings just calls it. The
pending-review defaults key is now a shared constant so its five call sites can't
drift. Covered by `NotificationServiceTests`
(`clearAllReviewStateRemovesPointerAndSnapshots`).

`Stride/Features/Settings/SettingsView.swift:717-730`

Every SwiftData type is deleted, but nothing outside it:

- pending morning reminders keep firing (up to 56 scheduled requests) for a plan
  that no longer exists — `NotificationService.cancelAllMorningReminders()` is
  never called;
- WorkoutKit workouts stay on the Watch and in Fitness —
  `healthKitRepository.removeWorkoutPlans(for:)` is never called;
- `pendingReviewWorkoutID` and any review snapshots stay in `UserDefaults`, so
  the next launch can try to surface a run that no longer exists;
- the app drops to onboarding while the Watch still shows last week's plan.

**Fix:** make reset a single async routine that cancels reminders, removes
WorkoutKit plans for every plan being deleted, clears the pending-review keys,
and *then* deletes the models.

### ✅ N12. A day can hold two scheduled workouts but every surface shows one

**FIXED:** day resolution moved out of the view into the pure `ScheduledDayResolver`,
which returns **every** session scheduled on a date in a stable order (runs first,
then strength, cross-training, rest; ties broken by time then ID, because
relationship order is undefined). The week strip's `DayCell` now draws one indicator
per session — the long-run pill narrows to a dot on a shared day — and the
selected-day card renders a stack, so each session has its own card and its own start
button. Covered by `ScheduledDayResolverTests`.

`Stride/Features/Dashboard/DashboardView.swift:106-114, 575-595`

```swift
for w in week.workouts ?? [] where cal.isDate(w.scheduledDate, inSameDayAs: date) {
    return w      // first match wins; relationship order is undefined
}
```

Both the week strip's dot and the selected-day card resolve a day to a single
workout by first match. After N6's shift the day genuinely holds two, and which
one the user sees — and can therefore start — is arbitrary and can change between
renders. The other session is unreachable from the dashboard entirely.

**Fix:** return all workouts for the day, render them as a small stack, and give
`DayCell` an indicator that can express two sessions.

### ✅ N13. The Siri "Today's Run" intent ignores plan state

**FIXED:** `todaysRun()` filters to the active plan (see N3) and prefers a run-type
session over a strength/cross-training day, and `TodaysRunIntent.dialogText(for:)`
now words the answer by session kind — a gym day is "a Strength session", cross
training is named as itself, and "Long Run"/"Race" aren't suffixed with "run".
Covered by `IntentDataProviderTests` (`dialogWordsEachSessionKind`).

`Stride/Features/AppIntents/IntentDataProvider.swift:34-54`

`todaysRun()` queries `ScheduledWorkout` by date with no join to the active plan,
so a *deactivated* plan whose dates still overlap today can answer Siri — a
regression risk created by retaining past plans. It also takes the first non-rest
workout including `.strength`, and `TodaysRunIntent.dialog` then says
"You have a **Strength** run today" (`TodaysRunIntent.swift:20-23`).

**Fix:** filter to `workout.week?.plan?.isActive == true` (or fetch the active
plan first and walk its weeks), prefer run types, and word the dialog by type.

### ✅ N14. App-logged strength sessions never reach HealthKit

**FIXED:** `HealthKitRepository.save(_ workout: StrengthWorkout)` writes an
`HKWorkout` with `.traditionalStrengthTraining` — the activity type the importer
already reads back — and `finishAndSave` stores the returned UUID in
`healthKitWorkoutID`. App-logged sessions now earn Activity-ring credit and appear in
Fitness, and because the id lands in the importer's `existingIDs`, the Watch-vs-app
merge is by identity rather than the ±3 h heuristic. The export follows the run path:
the session is already safely in the store, so a failure is logged, not fatal.

`Stride/Features/ActiveStrength/StrengthActiveView.swift:536-554`

`finishAndSave` inserts a `StrengthWorkout` locally and stops. Runs recorded in
the app are exported (`HealthKitRepository.save(_:)`, now with HR + route), but a
strength session logged in Stride earns no Activity-ring credit, never appears in
Fitness, and exists only in Stride. It also leaves dedup leaning entirely on the
±3 h time heuristic when the same session arrives from the Watch.

**Fix:** write an `HKWorkout` with
`.traditionalStrengthTraining`/`.functionalStrengthTraining` (matching the types
the importer reads at `:668-673`) and store the returned UUID in
`healthKitWorkoutID`, which also makes the merge exact instead of heuristic.

### ✅ N15. The highest-stakes save in the app is `try?`
`Stride/Features/ActiveRun/ActiveRunView.swift:493, 497, 513`

**FIXED:** the finish path splits into `finishAndSave` / `persistFinishedRun`, with
the run held in `pendingSave` because `finishWorkout()` is one-shot. A failed save
logs, raises a "Couldn't save your run" alert, and keeps the screen up with **Try
Again** / **Discard** — where Discard also unlinks the scheduled day rather than
leaving it marked complete with no run behind it. The follow-on writes (HealthKit
export, weather, pace refresh) stay best-effort: they enrich a run that is already
safely persisted. They — and the other 32 sites — now go through `saveOrLog`, so a
failure is logged rather than silent (D5).

```swift
context.insert(workout)
...
try? context.save()
```

If this save fails, the run the user just finished is gone — no alert, no log,
no retry, and the tracker has already transitioned to `.finished` so the data
cannot be recovered from it. There are 34 `try? context.save()` sites app-wide
(D5); this one deserves a real `do/catch` with an alert and a retry now, before
the broader cleanup.

### ✅ N16. The morning-reminder toggle does nothing without an active plan

**FIXED:** the plan guard now wraps only the *scheduling* step. Disabling always
cancels, enabling always requests authorization, and a missing plan just means there
is nothing to schedule.

`Stride/Features/Settings/SettingsView.swift:295-311`

```swift
.onChange(of: appSettings.morningReminderEnabled) { _, enabled in
    guard let plan = activePlans.first else { return }
```

With no active plan the guard returns before requesting notification
authorization *and* before cancelling. Turning the toggle **off** while a plan is
being replaced therefore leaves previously scheduled reminders in place, and
turning it on never prompts for permission. `ContentView` reconciles on the next
launch/foreground, so the user sees a toggle that appears to have taken effect
and reminders that disagree with it.

**Fix:** always request authorization when enabling and always cancel when
disabling; only the *scheduling* step needs a plan.

---

## 3. UX issues

### ✅ N17. There is no way to discard an accidental run

**FIXED,** both halves. The finish dialog now offers **Finish & Save** /
**Discard Run** / **Cancel**, and discarding just stops the tracker — nothing is
inserted into the context or linked until `persistFinishedRun`, so there is nothing
to unwind. The floor is shared rather than duplicated: `RunEffortPolicy` owns the
"real run" rule (>100 m **and** ≥30 s), `HealthKitRepository.isImportableWorkout`
delegates to it, and a finished run below it is still saved but no longer completes
the scheduled day it was started from. Covered by `RunEffortPolicyTests`.

`Stride/Features/ActiveRun/ActiveRunView.swift:132-135, 481-516`

The finish dialog offers only **Finish** and **Cancel**; "Finish" always saves.
Start a run by mis-tap, stop it twelve seconds later, and the app persists a
12-second run, exports it to HealthKit, marks the scheduled day complete, and
feeds it into pace refresh and the streak. Strength sessions got exactly this
protection in H5 (discard option + `hasLoggedWork` guard); runs never did.

**Fix:** add "Discard run" to the dialog, and refuse to link/complete a scheduled
day for a run under a minimum distance/duration (the importer already has
`isImportableWorkout` — reuse the same floor).

### ⚠️ N18. Accessibility is still largely absent, and one gap blocks a core action

**PARTIALLY FIXED** — everything but localization is now closed. The blocking gap and both
dead controls went first:

- The finish control is a real `Button` with a label and hint, and carries
  `activeRun.finish` for the UI test. Ending a run no longer requires sight.
- The flag/lap button and the "Lock" pill are **deleted** rather than faked; the
  metric cell the flag would have driven now shows average pace (see N20).
- Each metric cell is one accessibility element with a label, a spoken value
  ("no data yet" instead of a run of dashes, units spelled out), and a stable
  `activeRun.metric.*` identifier. The hero pace, pace meter, REC pill, and the
  indoor/outdoor toggle are labelled too, and the toggle is `.disabled` when it is
  inert instead of silently swallowing taps.
- Calendar day cells are `Button`s that read as "Tuesday March 14, Tempo, completed"
  and carry the `.isSelected` trait; the week chevrons are labelled
  "Previous week"/"Next week".

**Then the remainder, bar localization:**

- **Every chart speaks its data.** `ChartAccessibility.summary` builds one spoken shape for
  all ten (`ChartAccessibilityTests`): how many values, where the series starts and ends,
  and its extremes — applied through a `chartAccessibility(_:_:)` modifier that also
  collapses the chart's anonymous marks into one element, since a `Chart` carrying a
  `chartXSelection` overlay often exposed nothing at all. Each chart's summary is built in
  a named property rather than inline, keeping the view bodies (and the type-checker's
  work) as they were.
- **Metric cells outside the run HUD** — the run detail stats grid, the Progress period
  summary and its header, the strength summary — are one element each with a label and a
  spoken value, and the run HUD's own "spell the units out, say *no data yet* instead of
  reading dashes" rule moved out of `ActiveRunView` into `SpokenMetric` so there is one
  definition (`SpokenMetricTests`). It also translates a value that carries its unit
  inline, so "5.2 km" is heard as "5.2 kilometres".
- **The icon-only buttons in the other modules** are labelled: the coach chat's send
  button, the strength session's end button, Route Genius's clear-search button, and
  onboarding's back chevron. The chat's decorative `sparkles` and the search glass are
  hidden from assistive tech instead of read out as "sparkles" and "magnifying glass".
- **History rows read as one sentence** ("Tempo, Tuesday March 3, 5.2 km, 4:32 min/km,
  linked to a planned workout") rather than five loose fragments plus a glyph announced as
  the word "link"; the strength row says "from Apple Health" for its heart icon.

*Still open:* localization — all user-facing strings are still literals (D8).

`Stride/Features/ActiveRun/ActiveRunView.swift:390-425`;
`Stride/Features/Dashboard/DashboardView.swift:57-88`

- The **finish-run control is still an `.onTapGesture` on a decorative `ZStack`**
  (`:422-425`), so VoiceOver users cannot end a run — flagged in D8, still true.
- The flag/lap button (`:390-392`) has no action at all and the "Lock" pill
  (`:164-169`) is decorative — both read as controls and do nothing.
- Calendar day cells advance the selection through `.onTapGesture` on a
  `Rectangle` content shape, so they are not buttons to assistive tech; the week
  chevrons are buttons but carry no label (`StrideIcon` is a raw `Canvas` and
  exposes nothing).
- The whole app contains **8 `accessibilityLabel` calls**, in 3 files. Charts,
  metric cells, and every icon-only toolbar button elsewhere are unlabelled.

**Fix:** make every tappable thing a `Button`, label icon-only buttons, delete
the two dead controls (or implement lap), and add `accessibilityLabel`/`Value` to
the metric grid and charts.

### ✅ N19. Dynamic Type is still disabled app-wide by font shadowing

**FIXED:** the shadowing `static let caption` is gone, so all ~115 `.font(.caption)`
call sites resolve to SwiftUI's own token — 12pt regular at the default content size,
i.e. no visual change, but scaling from there. Every `ds*` and legacy UI alias is now
built from the text style whose default size matches the design token
(`Font.system(.subheadline, weight: .semibold)` for `bodyStrong`, `.caption2` for
`sectionHeader`, and so on), so the whole UI scale tracks the user's setting. The
`metric*` tokens stay deliberately fixed — a 120pt HUD hero and the fixed-height
metric grid have nowhere to grow — and that choice is now documented in the file. A
SwiftLint `custom_rules` entry (`no_builtin_font_shadowing`, error severity) fails the
build if any built-in `Font` static is re-declared again.

`Stride/Shared/Theme/AppFonts.swift:52-57`

```swift
static let caption       = Font.system(size: 12, weight: .regular)
static let bodyRegular   = Font.system(size: 15, weight: .regular)
```

`Font.caption` is SwiftUI's own dynamic-type token; redefining it in an extension
means every `.font(.caption)` in the app — hundreds of call sites — silently gets
a fixed 12pt font instead. The file's own comment explains that the `ds` prefix
exists to avoid this, and then does it anyway for the legacy aliases.

**Fix:** rename to `dsCaption`/`dsBodyRegular` (or make them relative via
`Font.system(.caption)`), migrate call sites mechanically, and add a
SwiftLint `custom_rules` entry banning re-declaration of built-in font names.

### ✅ N20. Live metrics show "--" for data the app already has

**FIXED:** `elevationGainMeters` is `@Published` (it was already being accumulated) and
the cell shows it in the runner's own unit. Cadence comes from `CMPedometer`, which now
runs on **both** paths — indoors it is still the distance source, outdoors it is read
for cadence only, so distance stays with GPS. It starts and stops with the run's active
segments alongside the existing pause/resume banking, and needs no new permission
(`NSMotionUsageDescription` already says "to measure cadence during runs"). The dead
Lap cell is replaced by average pace, which complements the live hero pace; the flag
button that would have driven a lap is deleted (N18).

`Stride/Features/ActiveRun/ActiveRunView.swift:302-326`

The in-run grid hardcodes `--` for **Elev Gain** and **Cadence**, and (without a
guided workout) **Lap**. Elevation is already accumulated during the run —
`WorkoutTrackerService.totalElevationGainMeters` (`:59, 329-331`) — it is simply
not `@Published`, so the number exists and is deliberately not shown while the
runner stares at a dash. Cadence is available from `CMPedometer` on the indoor
path with no new permission.

**Fix:** publish `elevationGainMeters` and bind the cell; expose
`CMPedometerData.currentCadence`; remove the dead Lap cell or wire it to the flag
button from N18.

### ✅ N21. Every run-detail open renders a share card nobody asked for

**FIXED:** the map snapshot and the ×3 `ImageRenderer` pass run only when Share is
tapped. The `.task` now loads heart-rate zones and nothing else, and the share
control is a permanently-present toolbar button (showing a spinner while it renders)
rather than one that pops in seconds after the screen appears. `ShareLink` needs its
item up front, which is what forced the pre-render, so the rendered card is presented
through a small `ShareSheet` (`UIActivityViewController`) instead — still one tap.

`Stride/Features/History/RunSummaryView.swift:105-124, 186-189`

```swift
.task(id: workout.id) {
    await renderShareCard()      // MKMapSnapshotter + ImageRenderer @3x (~1080×1350)
    await loadHeartRateZones()
}
```

Opening any run runs a map snapshot and a full-resolution image render before
anything else — including before HR zones load, which is content the user
actually sees. The share button is also gated on the result (`:203`), so it pops
into the toolbar seconds after the screen appears.

**Fix:** render on demand (or lazily via `ShareLink`'s async item), and load HR
zones first. Keep the pre-render only if a measurement shows it is cheap.

### ✅ N22. The run summary presents three affordances that do nothing

**FIXED,** all three:

- **The tabs are real.** `SplitMetric` drives which chart the splits card shows, the
  tabs are `Button`s carrying `.isSelected`, and only metrics the run actually has
  data for are offered — the row used to show HR and Elev whether or not the run
  carried either.
- **The reaction is persisted.** `AICoachReaction` moved out of the view onto the run
  (`RunWorkout.aiCoachReaction`, optional and additive for CloudKit), so a rating
  survives dismissal instead of dying with the view state.
- **The stream renders.** While the coach is generating, the accumulated text is
  shown in place of the skeleton rather than being buffered and thrown away.

`Stride/Features/History/RunSummaryView.swift:1546-1548, 1085-1098, 36 + 1513-1516`

- **Fake tabs**: `splitTab("Pace", active: true)`, `splitTab("HR", active: false)`,
  `splitTab("Elev", active: false)` render a tab bar above the splits chart that
  is a static picture — all three charts are stacked below regardless.
- **Feedback that goes nowhere**: the thumbs-up/down row writes `aiReaction` to
  view state and nothing reads it — not persisted, not sent to the coach, gone on
  dismiss.
- **Streaming that never streams**: `aiStreamBuffer` accumulates the coach's
  streamed chunks and is never rendered; users watch a skeleton instead of the
  text that is already arriving.

**Fix:** make the tabs real (or delete them), drop the reaction row or persist it
onto the insight, and render the buffer in the skeleton area.

### ✅ N23. "Rest day" is shown for days that are not rest days

**FIXED:** `ScheduledDayResolver.dayState(on:in:)` classifies a day as `.scheduled`,
`.rest`, `.outsidePlan`, or `.noPlan`, and the dashboard renders a distinct card for
each of the last three — the out-of-plan card names the plan's date range, and the
no-plan card points at the Plan tab instead of claiming a rest day. Covered by
`ScheduledDayResolverTests`.

`Stride/Features/Dashboard/DashboardView.swift:497-529, 575-584`

`workoutForSelectedDate` returns `nil` for a rest day, for any date outside the
plan's range, and when there is no plan at all — and the caller renders the same
"Rest day · Recovery is part of training" card for all three. Scrolling to next
month, or using the app before creating a plan, tells the user they are resting
according to a plan that says nothing about that day.

**Fix:** distinguish "explicit rest day in the plan", "outside the plan", and "no
plan", and show a neutral/CTA card for the latter two.

### ✅ N24. A missed workout can only be started on the day it was scheduled

**FIXED:** `ScheduledDayResolver.canStart(workoutScheduledOn:)` allows today **and one
day late** — the same tolerance `WorkoutSyncService` applies when it links an imported
run — judged by calendar day rather than elapsed hours, so a 23:30 session is still
startable at 00:30. Future days stay unstartable so the plan isn't run out of order,
and the button names the day it belongs to ("Start Yesterday's Workout"). Anything
further behind than that is the recovery card's job. Covered by
`ScheduledDayResolverTests`.

`Stride/Features/Dashboard/DashboardView.swift:459`

```swift
if Calendar.current.isDateInToday(selectedDate) && !workout.isCompleted {
```

Selecting yesterday's missed tempo shows the workout card but no start button, so
the only ways to complete a planned session a day late are to run it untracked
and let the importer link it, or to link it manually afterwards from the run
summary. The linker itself already accepts a one-day-late completion
(`WorkoutSyncService.swift:276-282`), so the UI is stricter than the data model.

**Fix:** allow starting a past uncompleted workout (today and yesterday at
minimum), with the card making the date explicit.

### ✅ N25. Aggregate time-in-zone stays empty for imported runs

**FIXED:** imports have persisted HR samples since N9, and runs imported before that
are now backfilled from the Progress tab itself. `HeartRateBackfill.runsNeedingSamples`
picks the candidates — no persisted samples, a HealthKit id to fetch from, newest
first, capped per pass and never re-asking for a run whose source is gone — and the
chart says "Loading heart-rate data…" while a pass runs instead of claiming there is
none. Covered by `HeartRateBackfillTests`.

`Stride/Features/Progress/ProgressView.swift:403-414`

The Progress chart only uses `run.heartRateSamples` that are already persisted,
while `RunSummaryView.loadHeartRateZones` (`:86-102`) backfills from HealthKit on
demand per run. So the aggregate chart says "No heart-rate zone data in this
period" until the user has manually opened each individual run, at which point it
partially fills — behaviour that reads as a bug from the outside.

**Fix:** backfill samples during import (N9's pass can do both), or run a bounded
backfill for the visible period with a progress indicator.

---

## 4. Cleanup, dead code & drift

### N26. The documented API-key setup does not exist ✅ FIXED (docs)
`AGENTS.md:49-54`; `README.md:13-18`; `Stride/Core/Services/RouteGeniusService.swift:10-13, 34`;
`Stride/Resources/Secrets.plist.example:11`

Three documents instruct contributors to copy `Secrets.plist.example` to
`Secrets.plist` and set `ORSAPIKey`. **No code reads that file** — the only
consumer is `RouteGeniusViewModel.swift:190`, which reads
`appSettings.orsAPIKey`, i.e. the Keychain-backed value entered in
Settings (S1). A contributor following the documented steps gets a route feature
that fails with "ORS API key not configured. See Secrets.plist.example." The
example file's own instructions point at `RunningApp/Resources/`, a path that no
longer exists.

**FIXED (docs half):** `AGENTS.md` and `README.md` now document the real path
(Settings → Route Genius → paste token, stored in the Keychain).
**FIXED (code half):** the `RouteGeniusService` doc comment describes the Keychain
path, `missingAPIKey` now reads "Add it in Settings → Route Genius", and
`Secrets.plist.example` — which pointed at a directory that hasn't existed for two
renames — is deleted.

### ✅ N27. Duplicated logic that now has a canonical home
- ✅ `RunSummaryView.isRunWorkout(_:)` (`:1498-1505`) duplicated `WorkoutType.isRunType`
  (`Enums.swift:152-157`), added by H8 precisely to be the single definition.
  **FIXED:** the copy was deleted and the call site uses `isRunType`.
- ✅ `AppContainer.attachWeather` and `WorkoutSyncService.attachWeather` were the same
  function. **FIXED:** the body is `WeatherService.attach(to:coordinate:context:)`;
  both call sites delegate, so the importer now gets the same logging the app path had.
- ✅ The markdown sanitizers — six of them once the chat view is counted, and the chat
  view's stripped only `**` — are now `CoachMarkdown.stripped`/`.attributed`, covered
  by `CoachMarkdownTests`.
- ✅ `DataMigrationService` contained no migration logic. **FIXED:** renamed to
  `BuildEnvironment`, which is what it is.

### ✅ N28. Dead code
- ✅ `RunSummaryView.AIActionItemRow` — deleted.
- ✅ `RunSummaryView.aiStreamBuffer` — no longer write-only; it renders (N22).
- ✅ `AICoachService`'s fault-tolerant JSON decoding — the flexible string/int
  coercion, the alternate `action_items`/`actions` keys, and the per-field defaults —
  is deleted. Nothing has decoded these from JSON since guided generation landed;
  the structured response is only ever built by the Foundation Models backend, so
  `AICoachStructuredResponse` is no longer `Decodable` at all. `AICoachInsight` and
  its items keep `Codable` (they are cached on the run) with synthesized conformances,
  whose keys match the hand-written ones exactly, so cached insights still decode.

### ✅ N29. Duplicate-pruning outlived its producer

**FIXED:** both pruners are gone — the Smart Adapt pass no longer prunes before and
after adapting, and applying coach feedback no longer deletes "duplicate" future
runs. The producers really are absent: the only remaining unmanaged `ScheduledWorkout`
is `AICoachService.makeScheduledWorkout`, whose result is copied field-by-field onto
the persisted workout and discarded, never related to a week. `PlanDuplicateResolver`
and its tests went with them; the rule they encoded (N6) only ever existed to decide
what to delete, and nothing deletes now. A day that genuinely holds two sessions is no
longer a problem to clean up — `ScheduledDayResolver` renders both (N12).

`Stride/Features/Training/PlanTabView.swift:322-349`;
`Stride/Features/History/RunSummaryView.swift:1434-1463`

Both pruners exist because H1 and H10 auto-inserted phantom `ScheduledWorkout`s
into the plan. Those producers were removed. What remains is a mechanism that
**deletes persisted workouts** during ordinary AI operations, with no remaining
source of the duplicates it was written to clean up — and, per N6, with an
over-broad rule. Removing them (after confirming no other path relates an
unmanaged model to a persisted week) is a net reduction in data-loss surface.

### ✅ N30. `AuthService` instances never deallocate

**FIXED:** the revocation listener iterates inline and re-checks `self` on each
element, the shape `AppSettings.observeExternalChanges` already used.

`Stride/Core/Services/AuthService.swift:22-25, 62-68`

```swift
Task { @MainActor [weak self] in await self?.listenForRevocation() }
```

The `[weak self]` is defeated immediately: the optional chain resolves once, and
the call then holds a strong `self` for the lifetime of an infinite
`for await` sequence. One instance is created per app launch so the practical
impact is small, but the same pattern in `AppSettings.observeExternalChanges`
(`:176-188`) does hold it weakly across iterations and is the version to copy.

### ⚠️ N31. CI toolchain pins are still empty, lint thresholds were unreachable — and no macOS job was being scheduled at all

**MOSTLY FIXED.** The lint half is done, and doing it turned up something this
document missed: **the lint job was failing at error level**, so no run has reached
the test job in weeks. `StrideIcon.draw` — one flat switch of drawing commands, one
case per icon — spans 384 lines against a 350 error. It now carries a documented
`swiftlint:disable:next function_body_length`, and `RunSummaryView` carries
`type_body_length` alongside the `file_length` disable it already had. With those two
exempted the thresholds are set from the next-worst real code, measured from the run's
own output: `type_body_length` 2000 → 1100 (worst remaining ~1,000),
`function_body_length` 350 → 150 (worst remaining ~100), `cyclomatic_complexity`
80 → 40 (worst measured 33).

`SWIFTLINT_VERSION` is pinned to `0.65.0`, the version the lint job's Homebrew step
actually poured. *Still open:* `XCODEGEN_VERSION` and `XCBEAUTIFY_VERSION` have no
observed value to pin — their install step lives in the test job, which `needs: lint`
has been skipping. Fill them in from the first run that gets that far.

**The stated reason above is wrong, and the real one is worse.** A fifth pass read the
Actions API instead of the workflow file and found the macOS side of CI has not been
*running at all* — not failing, unscheduled. Every macOS job was labelled `macos-27`,
which never provisions: those jobs are assigned no runner (`runner_id: 0`,
`runner_name: ""`) and sit queued until GitHub times them out. Run `30050008858` is the
clearest sample, because it straddles the change: its lint job on **`macos-26`** picked
up a runner in three seconds and passed in sixteen, while its test job on **`macos-27`**
waited *exactly* twenty-four hours and was cancelled. Once lint moved to `macos-27` too
it began queueing for hours and being cancelled by the next push's concurrency group
(runs `30133817520`, `30140006521`, `30160865168` — all the same shape). So nothing has
been linted, built, tested, or archived in this repo for as long as that label has been
in place, and the lint-threshold work N31 describes has never actually been exercised by
a run.

**FIXED:** all three macOS jobs move to `macos-26`, the label with observed provisioning
— and the image that poured the pinned SwiftLint 0.65.0 in the first place, so the pin
stays honest. Each also gains a `timeout-minutes` so a hung `xcodebuild` costs an hour
rather than a day. The two toolchain pins stay empty by necessity: they need a real
observation, and the run that produces one is now possible for the first time. If
`macos-26` turns out not to carry an Xcode 27 toolchain, the existing "Select Xcode"
step says so with the list of installed Xcodes inside the first minute — which is the
diagnostic this pipeline has been unable to produce.

`.github/workflows/*.yml:31-33`; `.swiftlint.yml:39-58`

`SWIFTLINT_VERSION`, `XCODEGEN_VERSION`, and `XCBEAUTIFY_VERSION` ship as `""`,
so the verification steps added in the July pass no-op and Homebrew can still
move under the pipeline. `type_body_length` error 2000, `function_body_length`
error 350, and `cyclomatic_complexity` error 80 remain unreachable in practice —
a 1,900-line type still passes.

**Fix:** copy the three resolved versions from the next green run's "Install"
step; tighten the three thresholds to just above the current worst file (a local
SwiftLint run is enough to establish the number).

### N32. README drift
`README.md:29-36, 38-42`

The test command names `iPhone 16` while `AGENTS.md` and CI use `iPhone 17`, and
the CI section mentions only Xcode Cloud although `.github/workflows` builds,
lints, and gates tests on GitHub Actions. **✅ FIXED** in this pass.

---

## 5. Test coverage gaps

The suite has grown a lot (38 test files) and the pure services are well covered.
The gaps line up exactly with where this pass found bugs:

| Untested behaviour | Findings it would have caught |
| --- | --- |
| ~~`WorkoutTrackerService.processLocation` / split construction~~ | N7/N8 — mostly closed: the split-pace math (`SplitPaceTests`) and the fix accept/reject decision (`LocationQualityFilterTests`) are extracted and tested. `processLocation` itself — which now composes them — still has no test, because the tracker owns `CLLocationManager` directly |
| ~~HealthKit → `RunWorkout` mapping (`inferWorkoutType`, split building)~~ | N9/N10 — closed for the pure halves: `ImportedSplitsTests`, `WorkoutTypeInferenceTests`, and `SplitBackfillTests` for the backfill's selection rule. The HealthKit queries feeding them (`fetchDistanceSeries`, now also reachable by workout id) are still untested — they need a store fake |
| ~~The `HistoryView` import path~~ | N4 — closed: there is now one importer, and `syncNow` is tested for linking and retired-plan scoping |
| ~~Active-plan resolution across views~~ | N3/N13 — partly closed: `belongsToLivePlan` and the intent are tested. A test asserting *every* `@Query` reader agrees would still be worth having |
| ~~Plan-lifecycle destructive paths~~ | N1/N2 — closed: `MissedWorkoutsRecoveryTests` and `PlanHistoryTests` now assert nothing is deleted |
| ~~Same-day duplicate pruning~~ | N6 — closed, then removed outright by N29: nothing prunes, so there is no rule left to test |
| View-level presentation of `StoreRecoveryNotice` | N5 — the alert moved to the root, but this is still view code with no test; `AppContainerTests` only asserts the notice is *raised* |
| ~~Dashboard day resolution and the start-button window~~ | N12/N24 — closed: both rules live in `ScheduledDayResolver` and are tested (`ScheduledDayResolverTests`). The rendering of a two-session stack is still untested view code |
| ~~The minimum-effort floor for app-recorded runs~~ | N17 — closed: `RunEffortPolicyTests` pins the floor and asserts the importer and the run-finish path agree on it |

Both structural notes are now closed. `AppContainer.rebuildPlan`'s date math moved out
to `PlanRebuildWindow`, following `shiftMissedWorkoutsForward`'s share of it into
`MissedWorkoutShift` (D2). View-embedded stat math — for years the least tested code in
the app — is out of the Progress tab into `ProgressPeriodStats`, and the two adaptation
filters and the Smart Adapt stream parser are out of their views as well (D1). What is
left of D1 is `RunSummaryView`'s size rather than untested arithmetic.

---

## 6. Carry-overs from the July analysis (re-verified open)

Confirmed still present at `75c0e27`. Details in the original document.

| Item | Status today |
| --- | --- |
| **D1** business logic in views | ⚠️ **Partly closed.** Both named offenders are out. `PlanTabView`'s streaming-JSON parser is `SmartAdaptSummaryStream` — a character-level state machine reading a deliberately incomplete document, whose escape handling and stop-at-`]` rule had no test home in a view body (`SmartAdaptSummaryStreamTests`, including a monotonic growing-buffer case: re-scanning a longer prefix may never lose or reorder what a shorter one already published). The pruning rules went with N29. `ProgressDashboardView`'s period arithmetic — range filter, weekly buckets, VDOT series, and the summary card's six aggregates — is `ProgressPeriodStats` (`ProgressPeriodStatsTests`), which also fixes the shape the inline version got wrong: every average is now optional, so "no run recorded heart rate" is distinguishable from "the average is zero", and each divides by its own sample count rather than the period's run count. The two adaptation filters (Smart Adapt's batch, the run summary's next session) were near-duplicate rules written from opposite directions and are now one `AdaptableWorkoutSelector` (`AdaptableWorkoutSelectorTests`). `RunSummaryView` gave up its two remaining rules as well: `CoachInsightText` owns the full-analysis body (including the fallback the card composes when the model returns no `fullAnalysis`, and the three-item cap on it) and the feedback prompt handed back to the coach, which now strips markup rather than spending prompt budget on asterisks; `SplitChartMetric` owns which split charts a run can offer, so the splits table's HR column and the chart's HR tab can no longer disagree (`CoachInsightTextTests`, `SplitChartMetricTests`). *Still open:* the file is ~2,130 lines. What is left in it is view code and thin delegation — `tempoInsights` already calls `WorkoutAnalyticsService`, the HR-zone and split backfills already call `HeartRateZoneService`/`SplitBackfill` — so the remainder is a file-splitting job, not an extraction one. |
| **D2** `AppContainer` god object | ⚠️ **Partly closed.** The date math is out: `shiftMissedWorkoutsForward`'s clamp is `MissedWorkoutShift`, and `rebuildPlan`'s "how many weeks are left of the old block" is `PlanRebuildWindow` (`PlanRebuildWindowTests` — the inclusive span, the round-up, and the already-expired block that must still yield a plan). `attachWeather` delegates to `WeatherService` (N27). *Still open:* the container is the orchestration point for all of it, and N1's plan lifecycle still lives there. |
| **D3** no choke point for invariants | Open, and worse than recorded: N4 is a third importer, N1/N2 a second and third plan-deletion policy. |
| **D4** observation & DI foot-guns | Mostly open. `AppContainer` is still `ObservableObject` behind a custom `EnvironmentKey`; `NotificationService` is still a callback-carrying singleton; N30 is the `AuthService` half. |
| **D5** pervasive `try? context.save()` | ✅ **Closed.** All 35 sites now go through `ModelContext.saveOrLog(_:)`, which keeps the best-effort semantics — most of these are a preference toggle, a cached insight, a weather snapshot, and making them `throws` would push error handling into views with nothing useful to do with it — and adds the trace that was missing. The defect was never that they don't propagate; it is that a store which had started rejecting writes (disk full, CloudKit schema mismatch, one model failing validation) was indistinguishable from a working one, from the user's side *and* from Pulse. Each call names what it was saving, so the log line identifies the site. The two places where a failure must reach the user still use `do`/`catch`: the run-finish save (N15) and the dashboard's plan-recovery mutations. Covered by `ModelContextSaveTests`. |
| **D6** unfiltered `@Query`/full-table fetches | ✅ **Closed** for all four readers, and none of them by simply capping a fetch. The dashboard takes the 60 newest runs and the coach chat the 8 its prompt reads. `RunSummaryView` replaced its two whole-table queries with three narrow ones: the plan day found by the run's own id (`linkedRunWorkoutID`) instead of scanning every `ScheduledWorkout`, the newest 51 runs for the two coach requests, and *tempo + race runs only* for `tempoInsights` — which consults nothing else, so the all-time "previous best tempo" is unchanged (pinned by `WorkoutAnalyticsServiceTests`). `HistoryView`'s list moved into a child view initialised with the page size, so each side fetches `limit + 1` rows and the extra row answers "is there more?" without counting the table. `MissedWorkoutDetector.detect` is `static`, so nothing is constructed in a body-evaluated property. *Deliberately left whole-table:* `ProgressView` and `RaceInsightsView`, whose charts are range- or all-time-scoped; they want the same child-view treatment if it ever measures. |
| **D7** dead code & drift | Mostly closed — see N27/N28. One duplicate outlived them: the eight-field copy that applies an AI adaptation onto a persisted workout was written out in `PlanTabView` and again in `RunSummaryView`, which is a field-drops-off-one-of-them bug waiting to happen. It is now `ScheduledWorkout.applyAdaptation(from:)`. |
| **D8** accessibility & localization | Mostly closed. Dynamic Type works again (N19); the run HUD, week strip, charts, metric cells, history rows, and the other modules' icon-only buttons are all labelled and button-based (N18). Localization is still open — every user-facing string is a literal. |
| **S4** remainder | Open (config). `NSLocalNetworkUsageDescription`/`NSBonjourServices` still ship in the shared `project.yml`. |
| **`.externalStorage` blobs** | Open (deliberately deferred; needs a device-tested migration). |
| **CI toolchain pinning / lint thresholds** | Open — see N31. |

---

## 7. What got better

The July fixes hold up under re-reading, and it is worth being explicit so the
next pass doesn't churn them:

- **Store recovery is genuinely careful** — classification before touching the
  file, move-aside instead of delete, in-memory last resort
  (`AppContainer.swift:168-241`). Only the *presentation* is wrong (N5).
- **Sync races are properly closed** — `pendingSyncSource` replay and the
  claim-before-await observer flag are the right shapes, and they have tests.
- **The pure-service layer keeps growing**: `SplitBucketing`, `WallClockStopwatch`,
  `RestCountdown`, `GuidedWorkoutState`, `HeartRateZoneService`,
  `ShareCardModel`, `StreakGoalService`, `ProgressStatsService`,
  `WorkoutPaceAlert`, `LocationQualityFilter`, `ScheduledDayResolver`,
  `RunEffortPolicy`, `CoachMarkdown`, `HeartRateBackfill`, `SplitBackfill`,
  `ChartAccessibility`, `SpokenMetric`, `MissedWorkoutShift`, `SmartAdaptSummaryStream`,
  `AdaptableWorkoutSelector`, `ProgressPeriodStats`, `PlanRebuildWindow`,
  `CoachInsightText`, `SplitChartMetric` are all UI-free,
  `Sendable`, and directly tested. This is the pattern the remaining view-embedded math should
  follow — `SpokenMetric` and `ChartAccessibility` show it applies to presentation rules
  (what a chart or a metric cell *sounds like*) just as well as to maths, and
  `SmartAdaptSummaryStream` shows it applies to parsing.
- **`GuidedWorkoutState`** in particular is a model implementation: the whole
  state machine is pure, the view only renders and forwards.
- **Deletion has one owner** for runs and strength (`WorkoutRepository.delete`),
  with tombstones and scheduled-day repair in one place.

---

## 8. Prioritized action plan

**1 — Stop losing data — ✅ DONE:**
- ✅ N1 rebuild-plan deletes the plan → deactivate.
- ✅ N2 launch dedup deletes plans → deactivate.
- ✅ N6 same-day pruning deletes strength → scoped by kind, then removed outright by
  N29; the shift moves strength with the runs and is now clamped so it can never carry
  a session onto or past a fixed race date (`MissedWorkoutShift`).
- ✅ N15 run-finish `try?` → real error handling.

**2 — Correctness the user can see — ✅ DONE:**
- ✅ N3 unfiltered active-plan query, plus the retired-plan scoping the fixes above
  made necessary (both linkers and the Siri intent).
- ✅ N4 fold `HistoryView`'s importer into `WorkoutSyncService`.
- ✅ N5 present the store-recovery notice at the root.
- ✅ N7 real split pace + N8 GPS filtering, with tests.
- ✅ N9/N10 import splits and classify types relative to the runner, and ✅ backfill
  splits onto runs imported before that landed (`SplitBackfill` + a HealthKit
  distance-series fetch by workout id).

**3 — UX debt with outsized impact — ✅ DONE:**
- ✅ N17 discard-run, with the importer's effort floor now shared by the run-finish path.
- ⚠️ N18 accessibility: the finish control (the blocking one), both dead controls, the run
  HUD's metric grid, and the week strip; then all ten charts (`ChartAccessibility`), the
  metric cells in the other modules (`SpokenMetric`), the remaining icon-only buttons, and
  the history rows. Only localization is still open.
- ✅ N19 Dynamic Type, with a SwiftLint rule to keep it that way.
- ✅ N20 elevation and cadence, and the dead Lap cell replaced by average pace.
- ✅ N24 start a missed workout (today and one day late).
- ✅ N12 a day's sessions all render, via the pure `ScheduledDayResolver`.

**4 — Hygiene — ✅ DONE (bar two toolchain pins):**
- ✅ N11 full reset, ✅ N13 dialog wording, ✅ N14 strength → HealthKit, ✅ N16 reminder
  toggle, ✅ N21 lazy share card, ✅ N22/N23/N25 honest UI states.
- ✅ N26 (code half), ✅ N27 (remainder)–N30 cleanup.
- ⚠️ N31: lint thresholds tightened and the error-level violation that had been
  failing every lint run fixed; SwiftLint pinned. XcodeGen/xcbeautify pins still need
  a run that reaches the test job.

**5 — What's left after this pass:**
- **Localization** — the last of N18/D8, and now the only accessibility work left. Every
  user-facing string is a literal, including the spoken labels and summaries the fixes
  above added, so this is the natural next step rather than a separate track.
- N31's two toolchain pins (`XCODEGEN_VERSION`, `XCBEAUTIFY_VERSION`), which still need a
  CI run that reaches the test job.
- The §6 carry-overs that are still open: D3 and D4 structural work, the remainder of
  D1 (`RunSummaryView`'s *size* — the logic is out, splitting the file is what's left)
  and D2 (the container as orchestration point), `.externalStorage`, and S4's plist
  keys. (D5, D6, and D7 are closed; D8 is down to localization.) A fifth pass took D1's
  and D2's testable halves: the Smart Adapt stream parser, the two adaptation filters,
  the Progress tab's period arithmetic, the rebuild window, the coach-insight prose, and
  the split-chart availability rule are pure services with tests, and the duplicated
  apply-adaptation field copy has one owner.
- **CI was not running at all** — the finding that pass turned up, and the one that
  matters most, since it means none of the above has been exercised by a build. See N31.
- **S4's remainder is config-only and small**: `NSLocalNetworkUsageDescription` and
  `NSBonjourServices: _pulse._tcp` still ship in the App Store Info.plist even though
  `PulseIntegrationService.activateIfNeeded` only starts `RemoteLogger` under `#if DEBUG`,
  so the shipped app declares a capability it never exercises. XcodeGen writes one
  `info.properties` block for every configuration, so making the keys debug-only needs a
  per-config mechanism rather than a one-line edit — worth doing next to a build that
  can actually be archived and checked.
