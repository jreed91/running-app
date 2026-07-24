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
> says where, with the landing commit). **🔨 IN PROGRESS** marks the feature
> currently being implemented. `file:line` references in shipped items point at
> the original analysis commit and may have drifted.

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
| Notifications | Morning workout reminders, synced-run banners | `Core/Services/NotificationService.swift` |

**Structurally absent** (no source references anywhere in the tree, verified by
search): home-screen **Widgets** (WidgetKit), **Live Activities** (ActivityKit),
a **watchOS companion / WatchConnectivity**, **GPX/route export or run sharing**
(no `ShareLink`), and **in-run audio/voice cues or haptics** (no
`AVSpeechSynthesizer` / `CHHapticEngine`). These frame Section B.

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

### A2. Active-run screen has dead "Lap" UI and no manual/auto lap feature *(medium impact, medium effort)*
`Features/ActiveRun/ActiveRunView.swift:300` renders a `metricCell(value: "1", label: "Lap")`
hardcoded to `1` — the lap counter never advances and there is no lap button.
Manual laps and auto-lap-by-distance are table stakes for interval sessions.
**Improve:** wire a real lap model into `WorkoutTrackerService`, add a lap
button, and show per-lap pace — this directly serves the tempo/interval
workouts the plan engine prescribes.

### A3. In-run guidance is silent — no audio/voice cues, no haptics *(high impact, medium effort)*
There is no `AVSpeechSynthesizer` or `CHHapticEngine` usage anywhere. A runner
executing a prescribed 6×800 m interval gets no spoken "rep 3, target pace 3:55,
you're 8s fast" and no buzz at the split. For a coaching app this is the gap
between a passive logger and an active coach. **Improve:** add configurable
audio announcements (split pace/HR/distance) and haptic split alerts, driven by
the scheduled workout's structure so intervals and tempo blocks are cued.

### A4. Training plans have no in-run structured-workout execution *(high impact, high effort)*
`ScheduledWorkout` already stores a rich `WorkoutStructure` (segments/sets —
`Core/Models/ValueTypes.swift`), but `ActiveRunView` starts a single flat run of
one `WorkoutType` (`ActiveRunView` `startType`) and never steps the runner
through warm-up → reps → recovery → cool-down. The app *prescribes* structure it
cannot *guide*. **Improve:** a guided-workout mode that reads `WorkoutStructure`,
advances segments (by time/distance), and (with A3) cues each transition. This is
the highest-leverage upgrade to the core product loop.

### A5. AI coach only sees runs — no HR-zone, cadence, or recovery context *(medium impact, medium effort)*
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

### ✅ A8. Progress "Medals" is a thin achievement layer *(medium impact, low effort)*

**SHIPPED (commit `a8d8a77`, via B4):** the thin distance-PR medals layer was
expanded into a proper achievements/streak system — run streaks, a weekly goal
with a progress ring, and consistency badges. See B4.

`Features/Progress/MedalsView.swift` (128 lines) is distance-PR medals only.
There are no streaks, no volume milestones (first 50 km week, 1000 km lifetime),
no consistency badges — the retention mechanics a training app leans on.
**Improve:** expand into a proper achievements/streak system (see B4).

### A9. Notifications are one-dimensional (morning reminder + sync banner) *(low impact, low effort)*
`NotificationService` schedules only morning workout reminders and synced-run
banners. No pre-long-run weather warning, no "you're 2 days into a streak", no
weekly-recap push, no missed-workout nudge tied to the recovery card. **Improve:**
add a small set of coaching-moment notifications keyed off existing detectors
(`MissedWorkoutDetector`, `WeatherService`).

### A10. Custom race distance exists but race-day experience doesn't *(medium impact, medium effort)*
The plan builds toward `raceDate`/`raceName` (`UserProfile:15-16`) but there is
no race-day countdown, no taper-status view, no goal-pace race plan, and no
post-race result capture/celebration. **Improve:** a race-day hub (countdown,
goal splits, weather, A/B/C goal times) that closes the plan's narrative arc.

---

## 3. B. Feature-set expansion opportunities

Net-new capabilities, ordered by product leverage. Each is currently absent from
the codebase (verified by search), not merely thin.

### B1. Home-screen Widgets *(high impact, medium effort)*
No WidgetKit target exists. A running app without a "next workout" / "weekly
progress" / "days to race" widget leaves the most valuable glanceable surface on
iOS empty. The data (`IntentDataProvider` already assembles Today's Run and
Weekly Summary for Siri) is reusable, so most of the model work is done.

### B2. Live Activity + Dynamic Island for the active run *(high impact, medium effort)*
No ActivityKit usage. During a tracked run the lock screen and Dynamic Island
show nothing. This is now an expected feature for any tracker and pairs naturally
with the existing `WorkoutTrackerService` live metrics.

### B3. watchOS companion *(high impact, high effort)*
There is no watch target or `WatchConnectivity`. The app imports Watch-recorded
workouts but can't *start* a run from the wrist or show live coaching there —
the single biggest platform gap for a running product. Large effort, but the
domain models are already CloudKit-shared and Watch-import-aware.

### ✅ B4. Streaks, goals & consistency system *(high impact, low-medium effort)*

**SHIPPED (commit `a8d8a77`):** an Achievements surface now tracks a run-streak
counter, a user-set weekly distance/time goal with a progress ring, and
consistency badges, built on the existing history + `ProgressStatsService`
aggregates. This also delivers the retention layer A8 called for.

No streak or weekly-goal tracking exists beyond plan adherence. A run-streak
counter, a user-set weekly distance/time goal with a progress ring, and
consistency badges are proven retention features and are cheap on top of the
existing history + `ProgressStatsService` aggregates.

### 🔨 B5. Run & achievement sharing *(medium impact, low-medium effort)*

**IN PROGRESS:** implementing v1 run share cards. A share button in the
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

### B6. GPX / data export *(medium impact, low effort)*
No route or workout export path. Power users and privacy-conscious users expect
GPX export of routes and a full-data export (the app already has a "reset all
data" path but no export). Small, and it de-risks the "my data is trapped"
objection.

### B7. Recovery / readiness signal *(medium impact, medium effort)*
Nothing consumes sleep, HRV, or resting-HR from HealthKit. A simple daily
readiness score (HRV + sleep + recent load) feeding the coach and the recovery
card would differentiate the "coach" positioning and reuses the HealthKit
plumbing already in place.

### B8. Broader workout-type support (cycling / cross-training as first-class) *(low-medium impact, medium effort)*
`crossTraining` exists as an enum case but there's no tracking or analytics for
non-running cardio; cross-training days are scheduled but not executable in-app.
**Expand:** at minimum import and display cross-training/cycling from HealthKit
against the plan, so cross-training days can be completed like runs.

### B9. Nutrition / hydration logging for long runs & races *(low impact, medium effort)*
Absent entirely. Marathon plans (the app's longest-horizon product) benefit from
fueling reminders and a simple long-run hydration/gel log. Niche but
differentiating for the marathon segment.

---

## 4. Prioritized roadmap

Sequenced for user-visible impact per unit of effort, reusing existing models.

**P0 — close the "coach vs. logger" gap (core loop):**
1. **A4** guided structured-workout execution (reads existing `WorkoutStructure`).
2. **A3** in-run audio/voice cues + haptics (pairs with A4).
3. **✅ A1** real mile splits *(shipped)* **+ A2** working laps (unblocks interval feedback).

**P1 — glanceable + platform surfaces (high impact, reuse existing data):**
4. **B1** Widgets (reuse `IntentDataProvider`).
5. **B2** Live Activity / Dynamic Island (reuse `WorkoutTrackerService`).
6. **✅ B4** streaks & goals *(shipped)*.

**P2 — depth in data & coaching:**
7. **A5** cadence capture **+ ✅ A6** HR-zone display *(shipped)*; feed the coach.
8. **A10** race-day hub (countdown, goal splits, result capture).
9. **B7** recovery/readiness score.

**P3 — reach & retention:**
10. **🔨 B5** run/achievement sharing *(in progress)* **+ B6** GPX export.
11. **A7** target-distance-aware routes with elevation.
12. **✅ A8** expanded achievements *(shipped via B4)* **+ A9** coaching-moment notifications.

**P4 — larger bets:**
13. **B3** watchOS companion.
14. **B8 + B9** first-class cross-training and long-run fueling.

> **Note on sequencing:** P0 items are the highest leverage because the plan
> engine already *prescribes* structured, paced workouts the app cannot yet
> *guide the runner through* — closing that loop turns existing planning
> investment into a felt coaching experience before any new platform surface is
> built.
</content>
</invoke>
