# Stride Feature-Improvement Analysis — July 2026

A product-feature review of Stride, distinct from the bug/design audits in
[`APP_ANALYSIS_2026-07.md`](./APP_ANALYSIS_2026-07.md) (first pass, all numbered
bugs fixed) and [`APP_ANALYSIS_2026-07-24.md`](./APP_ANALYSIS_2026-07-24.md)
(second pass, currently open defects and UX issues), and from the operational review in
[`REPO_ANALYSIS.md`](./REPO_ANALYSIS.md) (CI, secrets, test depth). This document
asks a different question: **as a running-coach product, where is the existing
feature set thin, and what should be built next?**

Every observation cites `file:line` as of commit `f9db64a`. Items are rated by
**user impact** (how many runners feel it) × **effort** (rough build cost), and
grouped into: (A) existing features that need improvement, and (B) new features
that would meaningfully expand the product.

> **Status tracking:** items marked **✅ SHIPPED** have since been built (the note
> says where, with the landing commit where one was recorded at the time).
> `file:line` references in shipped items point at the original analysis commit and may
> have drifted.
>
> **Status as of the latest pass:** all of **P0** and **P1** are closed; **P2** and **P3**
> are closed except the items listed below. Several were built during the
> UX-audit passes ([`UX_ANALYSIS_2026-07-26.md`](./UX_ANALYSIS_2026-07-26.md)) without this
> document being updated — **A3**, **A4** and **B2** are marked shipped here now, verified
> against the source rather than against a commit message, and **B5** is marked shipped
> rather than in progress. The latest pass built **A2** (manual laps), **A5**'s cadence
> half, and **B6**'s route export.
>
> **What is genuinely open:** **A7** (target-distance-aware routes with elevation),
> **B3** (watchOS),
> **B7** (recovery/readiness — the score, dashboard card and coach chat shipped; the widget
> does not see it yet), **B8**, and the logging half of
> **B9** (its fuelling-advice half shipped as the dashboard's Coach Tips strip). **B6**'s
> full-data export and **A10**'s race-day weather have since shipped too. Each says at its
> own entry what was deferred and why.

**Contents**
1. [Current feature inventory](#1-current-feature-inventory)
2. [A. Existing features that need improvement](#2-a-existing-features-that-need-improvement)
3. [B. Feature-set expansion opportunities](#3-b-feature-set-expansion-opportunities)
4. [Prioritized roadmap](#4-prioritized-roadmap)

---

## 1. Current feature inventory

What ships today, so the gaps below are read in context:

| Area | Current capability | Primary source |
| --- | --- | --- |
| Onboarding | Profile, goal race (5K/HM/Marathon/Maintain/Custom), 5K-time estimate, permissions | `Features/Onboarding/` |
| Training plans | VDOT-periodized plans (Base→Build→Peak→Taper), cutbacks, adaptive pace refresh | `Core/Services/TrainingPlanService.swift` |
| Active run | Outdoor GPS + indoor pedometer tracking, live metrics, per-km splits | `Features/ActiveRun/ActiveRunView.swift`, `Core/Services/WorkoutTrackerService.swift` |
| Active strength | Set/rep logging, rest timer, exercise library | `Features/ActiveStrength/`, `Core/Services/StrengthLibrary.swift` |
| History | Run/strength list, per-run detail (map, splits, charts) | `Features/History/` |
| Progress | Stats / Insights / Medals tabs; volume, pace, HR, elevation, VO₂ trend charts | `Features/Progress/` |
| AI coach | On-device Apple Foundation Models chat + per-run insights | `Core/Services/AICoachService.swift`, `Features/AICoach/` |
| Routes | Loop / out-and-back generation via OpenRouteService | `Core/Services/RouteGeniusService.swift` |
| Sync | HealthKit import, CloudKit private sync, weather attach | `Core/Services/WorkoutSyncService.swift` |
| Siri / Intents | Today's Run, Run Details, Weekly Summary | `Features/AppIntents/` |
| Notifications | Morning workout reminders, synced-run banners, heat advisory, streak / missed-workout / weekly-recap nudges | `Core/Services/NotificationService.swift`, `Core/Services/TrainingNudgePolicy.swift` |
| Run playlists | Apple Music playlist shaped to a session's energy blocks, saved to the runner's library (N40) | `Core/Services/RunPlaylistPlanner.swift`, `Core/Services/RunPlaylistService.swift` |

**Structurally absent** (no source references anywhere in the tree, verified by
search): home-screen **Widgets** (WidgetKit), **Live Activities** (ActivityKit),
a **watchOS companion / WatchConnectivity**, **GPX/route export or run sharing**
(no `ShareLink`), and **in-run audio/voice cues or haptics** (no
`AVSpeechSynthesizer` / `CHHapticEngine`). These frame Section B.

> Of that list only the **watchOS companion** is still absent. Widgets and Live Activities
> both live in the `StrideWidgets` extension (B1, B2), run sharing and GPX export are on
> the run detail (B5, B6), and audio cues and haptics are in the run flow (A3). The
> paragraph above is left as written because it is what the review found; this note is
> what is true now.

---

## 2. A. Existing features that need improvement

Features the app already has, but that are shallow enough to undercut the
product's "coach" promise.

### ✅ A1. Splits are kilometer-only end to end — imperial users get no real mile splits *(high impact, low effort)*

**SHIPPED (commit `e0fead7`):** splits are now bucketed by the user's distance
unit at record time. `WorkoutTrackerService` captures `splitUnit`/`splitLengthMeters`
from the preference at `startWorkout`, buckets via the pure, unit-tested
`SplitBucketing` helper (`Core/Services/SplitBucketing.swift`, `SplitBucketingTests`),
and stamps `RunWorkout.splitUnit` so the run detail view labels each bucket "km"/"mi"
honestly (resolving `APP_ANALYSIS` H11 at the source rather than by relabelling).
Imperial runners get genuine per-mile splits. *Still open:* HealthKit-imported
runs don't synthesize splits at all (empty `splits` array) — a separate gap, not A1.

`Core/Services/WorkoutTrackerService.swift:172-178` buckets splits per kilometer
at record time; the display layer was only patched to *label* them "km"
(`APP_ANALYSIS` H11) rather than re-bucket. An imperial runner therefore never
sees genuine per-mile splits — the single most-requested unit behaviour in a
run tracker. **Improve:** bucket splits by the user's unit at record time (or
store raw distance-stamped samples and bucket on display), unlocking honest
mile splits and the custom-lap feature in A2.

### ✅ A2. Active-run screen has dead "Lap" UI and no manual/auto lap feature *(medium impact, medium effort)*

**SHIPPED.** The dead half was closed first: N20 replaced the hardcoded `"1"` cell with
average pace and N18 removed the flag button that did nothing. This pass builds the
feature they were missing. `WorkoutTrackerService` records a `LapRecorder.Mark` on each
tap of a restored flag button (`activeRun.lap`, live only while a run is recording, with a
medium haptic distinct from the split's light one). `LapRecorder` — pure, unit-tested —
turns those boundaries into `Lap` values, and `finishWorkout` closes the final lap against
the finish so the lap the runner was in is not lost. `RunWorkout.laps` persists them
(`lapsData`, additive for CloudKit), and `RunSummaryView+Laps` renders a lap table above
the splits.

Two decisions worth knowing before reopening any of this:

- **Auto-lap-by-distance was not built, because it already exists.** `SplitBucketing`
  closes a bucket every kilometre or mile and has since A1. Laps are the boundaries that
  math *cannot* know about — the top of a rep, a turnaround, the lap line on a track — so
  the two are stored separately and a run that was never tapped carries no laps at all
  rather than one lap restating the whole run.
- **The lap read-out shares the grid slot with the guided step and average pace**, in that
  order, rather than adding a seventh cell to a grid that is already clamped for Dynamic
  Type (U2). A guided workout's step wins because that is what that screen is for (A4).

*Deferred:* per-lap heart rate and elevation (the tracker has both, but a four-column lap
table on a phone is a layout question, not a data one), and lap announcements through
`RunVoiceCoach`.

`Features/ActiveRun/ActiveRunView.swift:300` renders a `metricCell(value: "1", label: "Lap")`
hardcoded to `1` — the lap counter never advances and there is no lap button.
Manual laps and auto-lap-by-distance are table stakes for interval sessions.
**Improve:** wire a real lap model into `WorkoutTrackerService`, add a lap
button, and show per-lap pace — this directly serves the tempo/interval
workouts the plan engine prescribes.

### ✅ A3. In-run guidance is silent — no audio/voice cues, no haptics *(high impact, medium effort)*

**SHIPPED in the UX-audit passes** (`UX_ANALYSIS_2026-07-26.md` §4, passes 3–4), and
recorded here only now — this document was not updated at the time. `RunVoiceCoach` owns
the audio session and speaks each closed split via the pure `SplitAnnouncement`, judged
against the guided step's target pace or the scheduled workout's band; the announcement is
opt-in (`AppSettings.spokenSplitsEnabled`) because it is the one feature that talks over
whatever else is playing. Haptics are declarative `sensoryFeedback` — run state, each
split, each guided step, each strength set — so they respect the system haptics setting.
`RunSplitFeedback` carries both, and is applied by `ActiveRunView` *and* `MainTabView` so a
minimised run (U7) still speaks and buzzes from a pocket. This pass adds the lap haptic
(A2). *Deferred:* spoken heart rate and distance, and lap announcements.

A later pass speaks the guided steps too — the "rep 3, target pace 3:55" half of the
original ask. `GuidedStepAnnouncement` (pure, unit-tested) builds a start cue for every step
("Rep 3 of 6. 800 metres at 3:55 minutes per kilometre. Go.", "Recover. 90 seconds.") and
one heads-up near the end of each rep and recovery; `GuidedWorkoutFeedback` speaks them,
applied twice like `RunSplitFeedback`. Opt-in on its own switch
(`AppSettings.spokenWorkoutStepsEnabled`), since a runner who wants reps called may not
want kilometres read out mid-rep. A step cue interrupts a split still being spoken rather
than being dropped behind it. Auto-advance moved out of `GuidedWorkoutBanner` into the same
modifier, because the banner only exists on the HUD and a minimised session had stopped
stepping.

There is no `AVSpeechSynthesizer` or `CHHapticEngine` usage anywhere. A runner
executing a prescribed 6×800 m interval gets no spoken "rep 3, target pace 3:55,
you're 8s fast" and no buzz at the split. For a coaching app this is the gap
between a passive logger and an active coach. **Improve:** add configurable
audio announcements (split pace/HR/distance) and haptic split alerts, driven by
the scheduled workout's structure so intervals and tempo blocks are cued.

### ✅ A4. Training plans have no in-run structured-workout execution *(high impact, high effort)*

**SHIPPED in the UX-audit passes**, and recorded here only now. `GuidedWorkoutEngine`
(pure, unit-tested) flattens a `WorkoutStructure` into ordered steps; `GuidedWorkoutState`
lives on `ActiveRunPresentation` rather than in view state, so a runner three intervals in
who minimises the HUD comes back to step 4 and not step 1; `GuidedWorkoutBanner` shows the
current step and its manual Next (auto-advance is `GuidedWorkoutFeedback`'s, so it carries on
while minimised), and the metric grid's third slot shows step *n* of *m*. Flat
easy runs and free runs leave the stepper `nil` and are unchanged. Each step change is
cued by a heavy haptic (A3) — a transition the runner would otherwise only see by looking
at the banner at exactly the right moment.

`ScheduledWorkout` already stores a rich `WorkoutStructure` (segments/sets —
`Core/Models/ValueTypes.swift`), but `ActiveRunView` starts a single flat run of
one `WorkoutType` (`ActiveRunView` `startType`) and never steps the runner
through warm-up → reps → recovery → cool-down. The app *prescribes* structure it
cannot *guide*. **Improve:** a guided-workout mode that reads `WorkoutStructure`,
advances segments (by time/distance), and (with A3) cues each transition. This is
the highest-leverage upgrade to the core product loop.

### ✅ A5. AI coach only sees runs — no HR-zone, cadence, or recovery context *(medium impact, medium effort)*

**SHIPPED, bar recovery.** The HR-zone half landed with A6 (max HR on the profile,
`HeartRateZoneService.timeInZones`, a zone breakdown on the run summary, and
`CoachRunBreakdown.zoneSection`/`zoneSentence` in the prompt and the local read). This pass
closes cadence, which was the odd one out: the pedometer has reported it on *every* run
since N20 — outdoors as well as indoors — and the number was shown live and then thrown
away at finish. So the app measured the one form signal it has and could never say a word
about it.

`WorkoutTrackerService` now keeps every pedometer reading and averages it onto
`RunWorkout.averageCadenceStepsPerMinute` at finish; imported runs derive theirs from the
step count HealthKit recorded *against the workout* (there is no running-cadence quantity
type the way there is for cycling, so it is steps ÷ duration — the same definition
`CMPedometer.currentCadence` reports, which is what makes the two comparable). The run
summary shows an "Avg Cadence" stat, the coach prompt carries an `Avg cadence:` line, and
`CoachRunBreakdown.cadenceSentence`/`cadenceFocus` (pure, unit-tested) put it in the local
summary — the focus item only for a low cadence on an easy or long run, which is where a
runner can change something about their form without costing themselves the session.

Step count is added to HealthKit's **read** set only. Stride's own runs are already counted
by the device that took the steps; writing them back would double them.

*Still open, tracked as B7:* recovery/HRV. Nothing consumes sleep, HRV or resting HR, and a
readiness signal is a feature of its own rather than another field on `RunWorkout`.

`RunWorkout` persists only distance, duration, pace, avg/max HR, elevation,
splits, route, weather (`Core/Models/RunWorkout.swift:8-51`). No **cadence**,
**HR zone distribution**, ground-contact, stride length, or recovery/HRV signal
is captured, so coach commentary and analytics can never reason about form or
readiness. **Improve:** capture cadence and per-zone time from HealthKit at
import, add HR zones to the profile, and feed both into `WorkoutAnalyticsService`
and the coach prompt.

### ✅ A6. Heart-rate zones are computed for pacing but never surfaced to the user *(medium impact, low effort)*

**SHIPPED (commit `0bd672a`):** the profile now carries a max HR (explicit or
age-estimated via `effectiveMaxHeartRate`), a pure `HeartRateZoneService.timeInZones`
computes the per-zone breakdown, and `RunSummaryView` renders a "time in zone"
section. App-recorded runs persist their raw HR series (`RunWorkout.heartRateSamples`);
older imported runs backfill samples from HealthKit on demand and cache them.

"Zone" logic exists only inside pace/plan math (`TrainingPlanService`,
`PaceCalculatorService`); there is no user-facing HR-zone model, no
max-HR/threshold-HR in `UserProfile`, and no zone breakdown on the run detail or
progress screens. **Improve:** add HR-zone thresholds to onboarding/settings and
a "time in zone" chart on `RunSummaryView` and `ProgressView` — cheap, and it
makes the HR data already imported (`HealthKitRepository.fetchHeartRateStats`)
actually useful.

### A7. Route Genius is loop / out-and-back only, with no elevation or saved-route reuse in planning *(medium impact, medium effort)*
`RouteType` offers only `.loop` and `.outAndBack` (`Core/Models/Enums.swift`),
generation ignores elevation profile, and generated routes aren't tied to the
scheduled workout's target distance. **Improve:** add a target-distance-aware
"today's run route" suggestion (pull distance from the scheduled workout),
surface an elevation profile, and let a `SavedRoute` be attached to a plan day.

**Partly built (2026-09):** two pieces the competitive analysis ranked ahead of the
rest. *Keyless routes:* with no OpenRouteService key, `RouteGeniusService` builds
loops and out-and-backs from Apple Maps walking directions (`MapKitWalkingDirections`),
so Route Genius works without Settings; an ORS key, if set, still selects ORS.
*Route following:* the run HUD offers "Follow a saved route" before the start;
`RunRouteGuide` checks every accepted fix against it (`RouteDeviationMonitor`: 50 m
to leave, 30 m to rejoin, three agreeing fixes, never "off" before first joining) and
speaks "Off route" / "Back on route", with a haptic and a status pill while the HUD is
up. Still open: target distance from the scheduled workout, elevation, attaching a
route to a plan day, and a map of the followed route on the HUD.

### ✅ A8. Progress "Medals" is a thin achievement layer *(medium impact, low effort)*

**SHIPPED (commit `a8d8a77`, via B4):** the thin distance-PR medals layer was
expanded into a proper achievements/streak system — run streaks, a weekly goal
with a progress ring, and consistency badges. See B4.

`Features/Progress/MedalsView.swift` (128 lines) is distance-PR medals only.
There are no streaks, no volume milestones (first 50 km week, 1000 km lifetime),
no consistency badges — the retention mechanics a training app leans on.
**Improve:** expand into a proper achievements/streak system (see B4).

### ✅ A9. Notifications are one-dimensional (morning reminder + sync banner) *(low impact, low effort)*

**SHIPPED.** The weather half first (N39, below); the remaining three now follow.

**The streak nudge, the missed-workout push and the weekly recap.**
`TrainingNudgePolicy` holds every decision and is pure; `NotificationService` holds the
copy and the `UNUserNotificationCenter` calls, the same split the heat advisory uses.
`ContentView.refreshTrainingNudges` recomputes on every foreground and whenever the
active plan changes, because all three are decided against *what has happened so far
today* — a run logged at lunchtime has to take the evening's prod back down again.

| Nudge | When | Says |
| --- | --- | --- |
| Streak | 18:00, when a streak of 3+ days has no run logged today | The streak's length and that it ends at midnight |
| Missed workouts | 18:00, on `MissedWorkoutDetector`'s 2+ trailing missed sessions | How many went by and how far the plan can shift forward |
| Weekly recap | Sunday 19:00 | Runs, distance, longest, and how that sat against the weekly goal |

Three rules the implementation exists to keep:

- **One evening push, ever.** The 18:00 slot holds either the streak nudge or the
  missed-workout push, never both. The streak wins, because it is the one that cannot
  be said tomorrow.
- **A slot that has passed is decided, not assumed away.** The app has no background
  wake, so `TrainingNudgeDelivery` resolves to `.scheduled`, `.immediate` or `.skip`
  exactly as `HeatAdvisoryDelivery` does, and everything past the cutoff hour is dropped
  rather than delivered too late to act on. `TrainingNudgeLog` keeps an `.immediate`
  delivery from repeating when the app is opened twice the same evening.
- **The push honours the card's dismissal.** The missed-workout push reads the same
  once-a-week flag as `MissedWorkoutsRecoveryCard`
  (`MissedWorkoutDetector.promptFlaggedDateKey`), so a card the runner has already put
  away does not come back through a louder channel.

A week with no runs in it gets no recap: the other two nudges are the surfaces for not
having run, and a Sunday banner reading "0 runs, 0 km" is a scolding rather than a
summary. The whole set is one switch, **Settings → App → Training Nudges**, on by
default.

**The weather half (N39).** The pre-session weather warning
this item asked for now exists as a heat advisory: `HeatAdvisoryService` reads
tomorrow's hourly forecast at the coordinate of the runner's last recorded run,
scores it with `HeatAdaptationPolicy`, and — when the tier clears the threshold
for that session type — fires a banner at 18:00 the evening before with the
conditions, a cooler hour if the day has one, and a tap that opens the
adaptation sheet. Applying it eases the pace bands, trims quality volume or
long-run distance, converts hard sessions to easy above `.severe`, and drops
pace targets entirely in extreme heat. Every threshold is sourced in
[`HEAT_ADAPTATION_EVIDENCE.md`](./HEAT_ADAPTATION_EVIDENCE.md); the dashboard
card is `HeatAdvisoryCard`, the setting is **Settings → App → Heat Adaptation**.

### ✅ A10. Custom race distance exists but race-day experience doesn't *(medium impact, medium effort)*

**SHIPPED (race-day hub, then the weather half).**
[`RaceDayPlan`](../Stride/Core/Services/RaceDayPlan.swift) resolves the whole arc —
countdown, taper status, the goal ladder, the split table and the result — as one pure
value with an injectable `now`, and
[`RaceDayHubView`](../Stride/Features/Training/RaceDayHubView.swift) draws it.
[`RaceCountdownCard`](../Stride/Features/Training/RaceCountdownCard.swift) is the entry
point: on the Plan tab all season, and on the dashboard from a fortnight out until three
days after.

Details that are decisions rather than defaults:

- **The goal ladder is built *down* from the time the runner set, not up from it.** A
  runner who typed “3:30 marathon” has already named their ambitious number, so that is
  the A goal; B and C are +3 % and +7 %. Inventing a faster rung above their own goal
  would be the app raising it for them on the one morning it has no business doing that.
- **The predicted finish sits beside the ladder rather than inside it.** It comes from
  quality efforts in the last eight weeks via `ProgressStatsService.estimatedVDOT`,
  falling back to the profile's 5 K estimate. A goal is a decision and a prediction is a
  measurement; folding the second into the first would have the hub arguing with the
  runner.
- **Splits are even-pace only.** A negative-split plan needs a start time and a course
  profile, and the app stores neither. The table closes on the race distance rather than
  on a whole marker — the marathon's last 195 m is its own “Finish” row.
- **There is no manual result entry.** A race is recorded the way every other run is, in
  the app or imported from Health, so the hub reads the race-day run: the one linked to
  the plan's race workout, else the longest run that day covering at least 95 % of the
  race distance — which is what stops a race-morning shakeout being reported as the race.
- **A pregnancy plan gets no hub at all**, even with a stale `raceDate` left on the
  profile.

**The weather half shipped later.** The hub's Race Weather card asks for a start time
(`RaceStartTime`) and, from ten days out, shows the forecast at the start and at the
expected finish (the A goal, else the predicted time) with the heat tier of the worse of
the two and its pace cost from `HeatAdaptationPolicy`. `RaceDayForecast` picks the readings
and is pure (`RaceDayForecastTests`). Decisions:

- **The start time is asked for on the hub, not in onboarding.** Most runners do not know
  a race's start time months out, and the hub is where it becomes useful.
- **It is an `AppSettings` string synced through iCloud KVS, not a `@Model` property**, so
  it needs no CloudKit schema deployment. It carries its own race day: change the race date
  and the old start stops matching, rather than silently moving to the new race.
- **The forecast is for where the runner last ran** (`usualRunLocation`), because Stride
  stores no race location, and the card says so. A race-venue location is the next step if
  runners travel to race.

The plan builds toward `raceDate`/`raceName` (`UserProfile:15-16`) but there is
no race-day countdown, no taper-status view, no goal-pace race plan, and no
post-race result capture/celebration. **Improve:** a race-day hub (countdown,
goal splits, weather, A/B/C goal times) that closes the plan's narrative arc.

---

## 3. B. Feature-set expansion opportunities

Net-new capabilities, ordered by product leverage. Each is currently absent from
the codebase (verified by search), not merely thin.

### ✅ B1. Home-screen Widgets *(high impact, medium effort)*

**SHIPPED.** Four `StaticConfiguration` widgets in `StrideWidgets`, all fed by one
snapshot the app publishes into the App Group `group.com.running.stride`:

| Widget | Families | Shows |
| --- | --- | --- |
| Next Workout | small, medium, `.accessoryRectangular` | the next (or overdue) session, its distance and target pace, the plan's note |
| Weekly Goal | small, `.accessoryCircular`, `.accessoryRectangular` | this week's distance against the goal, as a ring |
| Race Countdown | small, `.accessoryRectangular`, `.accessoryInline` | days to race day, the race name, the plan's phase and week |
| Run Streak | small, `.accessoryCircular`, `.accessoryInline` | consecutive run days, and whether today's is in |

The extension cannot open the SwiftData store, so `IntentDataProvider` turned out not to
be reusable after all — it opens the store in-process, which a widget has no entitlement
to do. `WidgetSnapshotBuilder` (pure, unit-tested) plays the same role instead, and
`WidgetRefreshService` publishes its output on launch, on plan change, on scene-phase
change, and immediately after a run is saved. Tapping a widget deep-links to the matching
tab via `stride://plan` / `stride://progress`, which is what gave `MainTabView` a bound
selection. See "Widget Data Flow" in `AGENTS.md`.

*Deferred:* a Control Center `ControlWidget` for starting a run, and an
`AppIntentConfiguration` letting the user choose which metric a widget shows.

No WidgetKit target exists. A running app without a "next workout" / "weekly
progress" / "days to race" widget leaves the most valuable glanceable surface on
iOS empty. The data (`IntentDataProvider` already assembles Today's Run and
Weekly Summary for Siri) is reusable, so most of the model work is done.

### ✅ B2. Live Activity + Dynamic Island for the active run *(high impact, medium effort)*

**SHIPPED in the UX-audit passes** (`UX_ANALYSIS_2026-07-26.md` §5b, pass 6; the
strict-concurrency break it introduced was fixed in pass 7), and recorded here only now.
`RunLiveActivity` in `StrideWidgets` renders the Lock Screen card and both Dynamic Island
presentations from `RunActivityAttributes.ContentState`. `RunActivityController` is the
ActivityKit side, and the activity is driven from `WorkoutTrackerService` rather than from
a view — deliberately, because the case a Live Activity exists for is a locked phone,
where SwiftUI does not update a backgrounded view but the tracker's one-second timer keeps
running. Pause and finish are pushed straight through; the elapsed clock is counted by the
widget rather than pushed at all.

No ActivityKit usage. During a tracked run the lock screen and Dynamic Island
show nothing. This is now an expected feature for any tracker and pairs naturally
with the existing `WorkoutTrackerService` live metrics.

### B3. watchOS companion *(high impact, high effort)*

**IN PROGRESS.** A first slice adds the `StrideWatch` target: a Stride-branded watch app that
shows today's session, the weekly goal and streak, and the race countdown (the widgets'
`WidgetSnapshot`, sent over WatchConnectivity), and a **Start** button that opens today's
session in the Workout app as the same structured WorkoutKit plan the phone schedules. See
AGENTS.md → "Watch app". *Deferred:* recording the run in Stride's own watch app
(`HKWorkoutSession`, live pace and coaching on the wrist), complications, and anything
sent from the watch back to the phone.

The original entry: there is no watch target or `WatchConnectivity`. The app imports Watch-recorded
workouts but can't *start* a run from the wrist or show live coaching there —
the single biggest platform gap for a running product. Large effort, but the
domain models are already CloudKit-shared and Watch-import-aware.

### ✅ B4. Streaks, goals & consistency system *(high impact, low-medium effort)*

**SHIPPED (commit `a8d8a77`):** an Achievements surface now tracks a run-streak
counter, a user-set weekly distance/time goal with a progress ring, and
consistency badges, built on the existing history + `ProgressStatsService`
aggregates. This also delivers the retention layer A8 called for.

**Extended:** two more badge rows sit under Big Weeks. **Big Months** counts the best
calendar month (100/200/300 km, or 60/125/200 mi). **Long Runs** reads the single longest
run against 10K, the half and the marathon, earned at 99% of the distance so a race GPS
measured a little short still counts (`StreakGoalService.longRunTolerance`). Both count
running only, like every other badge.

No streak or weekly-goal tracking exists beyond plan adherence. A run-streak
counter, a user-set weekly distance/time goal with a progress ring, and
consistency badges are proven retention features and are cheap on top of the
existing history + `ProgressStatsService` aggregates.

### ✅ B5. Run & achievement sharing *(medium impact, low-medium effort)*

**SHIPPED.** The description below is what landed, with one change made after it was
written: rendering is deferred to the Share tap rather than run on every open of the run
detail (N21), so the card is produced by `UIActivityViewController` rather than
`ShareLink` — the latter needs its item up front, which is what forced the pre-render. B6
has since turned that single button into a menu. The deferred half below is still deferred.

The original entry, for the record: a share button in the
`RunSummaryView` toolbar renders a fixed-size card (headline distance/time/pace,
the route over a dark `MKMapSnapshotter` map background via `RouteSnapshotService`
— falling back to a self-drawn polyline when offline, and to a route-less panel
for indoor runs — avg HR + elevation when present, a splits summary labelled in
the run's stored `splitUnit`, and Stride branding) to a PNG via `ImageRenderer`
and presents it through `ShareLink`. Card→display mapping lives in a pure,
unit-tested model per AGENTS.md. *Deferred:* History swipe-to-share and
milestone/medal cards.

No `ShareLink` / share-card generation anywhere. Runners share runs; a
rendered share card (map + splits + stats, or a milestone medal) is a low-cost
growth lever built entirely from data already on `RunWorkout`.

### ✅ B6. GPX / data export *(medium impact, low effort)*

**SHIPPED (route export).** `GPXExport` builds a GPX 1.1 document from a run's stored
route; the run summary's share control is now a menu — "Share run card" (B5) and "Export
route as GPX" — and the export writes to the temporary directory and hands the URL to the
same `ShareSheet`, which now takes arbitrary activity items rather than only a `UIImage`.
A failed write surfaces an alert instead of doing nothing.

Details that are decisions rather than defaults:

- **The route carries no timestamps of its own**, so points are laid back onto the run's
  timeline evenly — reusing `HealthKitRepository.sampleTimestamps`, which is the same
  spacing `saveRoute` already applies when it writes this very trace to HealthKit. An
  exported file and the Health copy of the same run therefore agree with each other.
- **Coordinates are formatted through `en_US_POSIX` at six decimals.** A GPX with
  `lat="52,3"` fails to parse in every reader there is, and the app's own locale would
  otherwise decide.
- **The track name and file name are locale-stable** (`displayName`, fixed date patterns),
  because both are read by the importing tool rather than by the runner — the AGENTS.md
  `displayName` vs `localizedName` rule.
- **Indoor and fixless runs offer no export at all**, rather than a menu item that produces
  an empty track.

The pure document builder takes coordinates and timestamps so the XML can be asserted
without a SwiftData model behind it (`GPXExportTests`).

**SHIPPED (full-data export).** **Settings → Data → Export All Data** shares one ZIP:
`runs.csv` (every recorded workout — runs, walks and cross-training, with a `type` column),
`strength.csv`, `shoes.csv`, a `README.txt` naming every unit, and `routes/` holding one GPX
per workout with a route (built by the same `GPXExport`). `DataExport` builds the files as
pure strings (`DataExportTests`); `DataExportWriter` writes them to the temporary directory
and zips the folder through `NSFileCoordinator`'s `.forUploading` read, so there is no
compression dependency. Numbers go through `en_US_POSIX`, so a comma-decimal locale cannot
break a comma-separated file, and route file names that collide in the same minute get a
`-2` suffix. Strength sets export as per-session totals: a logged set names its exercise by
index into the plan, not by name. There is no import back in; this is an export for the
runner's own keeping.

No route or workout export path. Power users and privacy-conscious users expect
GPX export of routes and a full-data export (the app already has a "reset all
data" path but no export). Small, and it de-risks the "my data is trapped"
objection.

### B7. Recovery / readiness signal *(medium impact, medium effort)* — 🟡 PARTIAL
Nothing consumes sleep, HRV, or resting-HR from HealthKit. A simple daily
readiness score (HRV + sleep + recent load) feeding the coach and the recovery
card would differentiate the "coach" positioning and reuses the HealthKit
plumbing already in place.

**The score and the dashboard half shipped.** HealthKit now *reads* (never writes)
SDNN heart-rate variability, resting heart rate and sleep analysis, and
[`RecoveryReadiness`](../Stride/Core/Services/RecoveryReadiness.swift) turns them into a
0–100 score: last night's HRV and resting HR against the runner's own preceding four
weeks (not scored until there are seven days of it), last night's asleep time with
overlapping sources merged, and seven days of running time against the four-week weekly
average. When the score drops under 60 the dashboard's coach strip gets a "Recovery is
running low" card naming what pulled it down, and suggesting the next hard session be run
easy or moved. [`RecoveryReadinessTests`](../StrideTests/RecoveryReadinessTests.swift)
pins each threshold.

The AI coach chat reads the same score: `AICoachChatView` puts
`RecoveryReadiness.promptSummary` (the score, what it means, and each component's reading)
into the context it sends with every message.

*Still open:* the per-run analysis does not see the score, and the widget and Siri do not
show the card, because both build their coach context without a HealthKit read. A runner who granted Health access before this build is not asked for the
new types until the app next requests Health access (the Health import in Settings or
History does), so for them the card stays silent until then.

### B8. Broader workout-type support (cycling / cross-training as first-class) *(low-medium impact, medium effort)*
`crossTraining` exists as an enum case but there's no tracking or analytics for
non-running cardio; cross-training days are scheduled but not executable in-app.
**Expand:** at minimum import and display cross-training/cycling from HealthKit
against the plan, so cross-training days can be completed like runs.

**The import half shipped.** Cycling, swimming, rowing, elliptical, stair and Watch
cross-training / mixed-cardio workouts of ten minutes or more are imported from Apple Health
as `.crossTraining` sessions, appear in History with their time (and distance where the
workout has one), and complete the plan's cross-training day on the same or the next
calendar day. They never count as running: weekly distance, pace, VDOT, the streak and the
coach all leave them out
([`CrossTrainingImportTests`](../StrideTests/CrossTrainingImportTests.swift)).
*Still open:* recording cross-training in-app, naming the activity (a ride is shown as
"Cross Training"), a settings toggle, and the Settings import screen.

### B9. Nutrition / hydration logging for long runs & races *(low impact, medium effort)* — 🟡 PARTIAL
Absent entirely. Marathon plans (the app's longest-horizon product) benefit from
fueling reminders and a simple long-run hydration/gel log. Niche but
differentiating for the marathon segment.

**Half of this shipped** as the *advice* side, without the log:
[`SmartCoachCards`](../Stride/Core/Services/SmartCoachCards.swift) puts a fuelling
strip on the dashboard. It covers race-week carbohydrate, the recovery window after
a hard or long run, fuelling *during* a session past 16 km or ninety minutes,
eating before a quality session, and pre-hydration when the last logged run's
weather was hot or humid — plus the training-side cards (fade, easy-versus-hard
separation, cadence, seven-day load ramp, coming back after a gap). Every rule is a
threshold over data the app already holds, so the cards are there offline, on first
render, and on a device whose on-device model is unavailable, and every one of them
is pinned on both sides of its threshold in
[`SmartCoachCardsTests`](../StrideTests/SmartCoachCardsTests.swift).

**Rebuilt since, as a selection algorithm rather than a rule list.** The first
version was eleven independent rules ordered by a hand-written priority list, which
made the list the design: the answer to "why am I seeing this card" was "because it
was seventh". Selection now runs in three steps.

1. [`CoachSituation`](../Stride/Core/Services/CoachSituation.swift) resolves the
   runner's state — race day, race week, a lay-off, the recovery window, the shape
   of the next session, or one of the four states where the plan has nothing
   outstanding. Each state owns exactly one card, including the empty ones, which
   used to share a single fallback that said the same thing about four different
   problems.
2. Race day, race week and a long lay-off are **exclusive** and take the strip
   outright. A second card there is not extra help, it is something to read past.
3. Everything else **scores**. Each rule reports how far past its threshold the
   runner actually is, normalised to 0–1, so a 45% volume jump and a 21% one are no
   longer the same card with the same claim on attention. The top score is drawn as
   the primary card with its derivation line; the next two sit compact underneath.

Two things fell out of that and are worth knowing on their own:

- [`CoachNutrition`](../Stride/Core/Services/CoachNutrition.swift) computes amounts
  rather than quoting ranges. Sports-nutrition guidance is written per kilogram, so
  with a body mass — read from HealthKit, with a Settings field as the fallback —
  the same rules give "65 g an hour" instead of "30–60 g an hour", and every card
  shows its working (`0.9 g/kg/h · 72 kg · ~2.2 h · 143 g total`). Without a mass
  the ranges still appear and the derivation says what would sharpen them.
- [`CoachBaseline`](../Stride/Core/Services/CoachBaseline.swift) moves thresholds
  from published constants to the runner's own once there is enough history
  (8 readings). This is what the cadence rule needed: against a fixed 165 spm, a
  runner who has always turned over at 158 was told to fix how they run, while one
  who had dropped from 182 to 170 — a real change, usually a tired one — was told
  nothing at all.

**On all three surfaces since.** The dashboard, the Home Screen and Siri now answer
from the one selection rather than from three:

- **App Intents** call `SmartCoachCards` directly — they open the same store through
  `IntentDataProvider`, so `CoachTipIntent` ("what should I eat before my run?")
  runs the same thresholds the dashboard draws.
- **The widget extension cannot**, having no access to SwiftData, so the app runs the
  selection and publishes the winning card into `WidgetSnapshot.coachTip` as finished
  strings — the same treatment every other widget field already gets. `CoachTipWidget`
  renders it in small, medium and Lock Screen sizes.

Two fields on `SmartCoachCard` exist for that hop, and both are about the gap between
when the snapshot is *written* and when it is *read*: `glance` is a short form with no
clock in its wording (the dashboard's copy says "about 30 minutes ago", which would be a
lie by lunchtime — and would make the snapshot differ on every write, spending WidgetKit's
whole daily reload budget on foregrounds), and `expiresAt` carries relevance separately,
resolved against the widget's own entry date.

**Still open:** the *log*. Recording what was actually taken on a long run — gels,
fluid, when — is a model change and an in-run control, and none of it exists yet.
The advice above is prescriptive only; it never claims to know what the runner ate.

Also open, and the natural next step rather than a gap in the above: the strip is
deterministic by design and does not yet consult the on-device coach.
`AICoachService` could take these same signals as context and rewrite the top card
in the runner's own history, with the rule-based text as the fallback whenever the
model is unavailable — which is most of the reason the rules were built first. The
scoring makes that easier rather than harder: there is now a single, ranked, already
-computed signal to hand the model, instead of eleven booleans.

---

## 4. Prioritized roadmap

Sequenced for user-visible impact per unit of effort, reusing existing models.

**P0 — close the "coach vs. logger" gap (core loop) — ✅ DONE:**
1. **✅ A4** guided structured-workout execution (reads existing `WorkoutStructure`).
2. **✅ A3** in-run audio/voice cues + haptics (pairs with A4).
3. **✅ A1** real mile splits **+ ✅ A2** working laps (unblocks interval feedback).

**P1 — glanceable + platform surfaces (high impact, reuse existing data) — ✅ DONE:**
4. **✅ B1** Widgets.
5. **✅ B2** Live Activity / Dynamic Island (reuse `WorkoutTrackerService`).
6. **✅ B4** streaks & goals.

**P2 — depth in data & coaching:**
7. **✅ A5** cadence capture **+ ✅ A6** HR-zone display; both now feed the coach. *(A5's
   recovery third is B7, below.)*
8. **✅ A10** race-day hub (countdown, goal splits, taper status, result, start time and
   race-day forecast).
9. **B7** recovery/readiness score.

**P3 — reach & retention:**
10. **✅ B5** run/achievement sharing **+ ✅ B6** GPX route export and full-data export.
11. **A7** target-distance-aware routes with elevation.
12. **✅ A8** expanded achievements *(shipped via B4)* **+ A9** coaching-moment notifications.

**P4 — larger bets:**
13. **B3** watchOS companion.
14. **B8 + B9** first-class cross-training and long-run fueling.

> **Note on sequencing:** P0 was the highest leverage because the plan engine already
> *prescribed* structured, paced workouts the app could not yet *guide the runner
> through*. That loop is closed, and with P1 closed too, the remaining items no longer
> queue behind each other: **B7** (recovery), **A7** (routes) and the rest of **B6**
> (full-data export) are independent, and are
> ordered by impact rather than by dependency. **B3** (watchOS) is still the one that
> changes the product's shape rather than adding to it.
</content>
</invoke>
