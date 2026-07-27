# Stride — Screenshot-Driven UX Review (2026-07-27)

Fourth-pass review, and the first taken from **rendered screenshots rather than
source**. The three earlier audits
([`APP_ANALYSIS_2026-07.md`](APP_ANALYSIS_2026-07.md),
[`APP_ANALYSIS_2026-07-24.md`](APP_ANALYSIS_2026-07-24.md),
[`UX_ANALYSIS_2026-07-26.md`](UX_ANALYSIS_2026-07-26.md)) all read the code. This
one drives the app and looks at what actually lands on the glass, which surfaces a
different class of defect: text that overflows its frame, controls that are dimmed
with no explanation, two screens that disagree about the same number, and empty
states that render as a blank white box.

## How these screenshots were produced

`StrideUITests/StrideScreenshotTests.swift` walks the first-run flow and attaches a
screenshot of every screen as an `XCTAttachment`. It asserts almost nothing — it
exists to produce artefacts.

```bash
xcodebuild test -project Stride.xcodeproj -scheme Stride \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:StrideUITests/StrideScreenshotTests \
  -resultBundlePath /tmp/shots.xcresult

xcrun xcresulttool export attachments --path /tmp/shots.xcresult --output-path /tmp/shots
```

Captured on iPhone 17 / iOS 27.0, light appearance, default Dynamic Type, imperial
units, with the app's own `--uitesting` flag (in-memory store, wiped preferences),
so every screen below is a **genuine first-run state**. Every finding cites
`file:line` as of commit `4811ca3`.

> **Fix tracking:** items marked **✅ FIXED** have been resolved; the note says
> where. Line numbers in fixed items refer to commit `4811ca3` and may have drifted.

## Scorecard

| Area | State | Notes |
| --- | --- | --- |
| Text fitting its frame | 🔴 Broken | Hero pace overflows the screen; an equipment label truncates mid-word |
| First-run day 0 | 🔴 Broken | Onboarding ends on "Outside your plan" — nothing to do for a week |
| Empty states | 🟡 Mixed | History and Average Pace are good; Weekly Volume is a blank card |
| Cross-screen consistency | 🔴 Broken | Max HR, VDOT, fitness level and goal time each differ between two screens |
| Disabled-state affordance | 🟡 Mixed | Plan tab explains itself; onboarding's Training Focus does not |
| Selection colour semantics | 🟡 Mixed | Default goal selection is red; step 3 selection is orange |
| Screen density | 🟡 Mixed | Home and three onboarding steps are >50% empty with a pinned CTA |
| Overlap / occlusion | 🟡 Mixed | Plan's floating calendar button sits on top of a week row |

---

## 1. Text that does not fit

### S1 — Hero pace overflows the run HUD 🔴

[`ActiveRunView.swift:455`](../Stride/Features/ActiveRun/ActiveRunView.swift#L455)

The 120pt hero calls `paceString(unit:)`, which **includes the unit**
(`"--:-- min/mi"`), and the caption immediately below already reads
`CURRENT PACE · MIN/MI`. With `.lineLimit(1)` and `.minimumScaleFactor(0.6)` the
string cannot fit, so it renders as `--:-- min…` with the tail running off the
right edge of the screen.

`Double.paceValueString(unit:)`
([`Double+Extensions.swift:90`](../Stride/Shared/Extensions/Double+Extensions.swift#L90))
exists for exactly this case — its doc comment says "with no unit label. For
compact metric cells that carry their own label." The hero is such a cell.

**Fix:** call `paceValueString(unit:)`. The unit stays in the caption, where it
already was.

### S2 — "Resistance Bands" truncates to "Resistance…" 🔴

[`OnboardingSubviews.swift:1352`](../Stride/Features/Onboarding/OnboardingSubviews.swift#L1352)

`OBEquipmentCard.labelView` is `.lineLimit(1).minimumScaleFactor(0.8)` inside a
two-column `LazyVGrid`. "Resistance Bands" is the longest of the six equipment
names and does not fit a half-width card at default Dynamic Type, let alone at
larger sizes. Its grid neighbour, "Pull-Up Bar", fits — so the row reads as one
broken cell rather than a uniformly tight layout.

**Fix:** allow two lines and lower the scale floor.

### S3 — Prose rendered in a monospace font, wrapping mid-card 🔴

[`OnboardingSubviews.swift:541`](../Stride/Features/Onboarding/OnboardingSubviews.swift#L541)

`OBGoalCard` applies `.monospaced()` to `distanceLabel`. That is right for the
three numeric values (`3.1 mi`, `13.1 mi`, `26.2 mi`) and wrong for the two that
are phrases: `No race target` and `Set your own`. Monospaced prose is both much
wider than the proportional face and visually foreign to the rest of the card, so
those two badges wrap onto a second line inside a `.firstTextBaseline` `HStack` —
which then pushes "Custom Distance" onto two lines too.

**Fix:** monospace the numeric labels only.

---

## 2. First-run states

### S4 — Onboarding ends on "Outside your plan" 🔴

[`DashboardView.swift:670`](../Stride/Features/Dashboard/DashboardView.swift#L670)

Onboarding defaults the plan start to the next Monday. Finish setup on any other
day and the very first Today screen says, in grey:

> **Outside your plan** — Your plan runs Aug 3 – Sep 21.

`outsidePlanCard`'s own doc comment explains it was written for *scrolling to a
date the plan doesn't cover* ("scrolling to next month is not the plan prescribing
rest (N23)"). It was never meant to be the landing state, and as one it tells a
runner who just spent eight steps building a plan that there is nothing to do for
a week.

**Fix:** a distinct pre-start state — count down to the start date, and frame the
free run as the thing to do in the meantime.

### S5 — Progress → Weekly Volume renders as a blank white card 🔴

[`ProgressView.swift:279`](../Stride/Features/Progress/ProgressView.swift#L279)

`chartCard("WEEKLY VOLUME")` wraps a `Chart` over `weeklyBuckets`. With no runs the
collection is empty, so Swift Charts draws nothing — no bars, no axes, no message —
leaving a ~160pt empty card under a section header. The **Average Pace** card
directly beneath it handles the same condition correctly ("No pace data in this
period"), which makes the blank card read as a rendering failure rather than an
empty state.

**Fix:** the same empty-state treatment the neighbouring cards already use.

### S6 — History's empty state names two actions and offers neither 🟡

[`HistoryView.swift:327`](../Stride/Features/History/HistoryView.swift#L327)

"Start a workout or sync from Apple Health." is a description, not a control. The
`ContentUnavailableView` has an `actions:` slot — the filter variant directly above
it uses one — and sync is otherwise reachable only through an unlabelled toolbar
glyph.

**Fix:** add the two buttons.

---

## 3. Two screens, two answers

### S7 — Max HR is 187 in onboarding and 190 in Settings 🔴

[`UserProfile.swift:98`](../Stride/Core/Models/UserProfile.swift#L98),
[`SettingsView.swift:726`](../Stride/Features/Settings/SettingsView.swift#L726)

Onboarding step 4 shows **187 bpm** and explains it: "Estimated from age
(208 − 0.7 × age)". That is Tanaka, for the default age of 30. Onboarding then
only persists age and max HR when the user actually touched those steppers
([`OnboardingView.swift:763`](../Stride/Features/Onboarding/OnboardingView.swift#L763)),
so for everyone who left the defaults alone `profile.age` is `nil`,
`effectiveMaxHeartRate` is `nil`, and `maxHRBinding` falls back to a hardcoded
`190` — which Settings then displays directly above an Age row reading `30`. The
two rows contradict each other on screen, and the number the user was shown during
setup has silently changed.

**Fix:** default the max-HR fallback to the same Tanaka estimate the rest of the
app uses, so the displayed age and the displayed max HR always agree.

### S8 — Progress shows VDOT `--` right after onboarding showed VDOT 36 🔴

Onboarding step 4 renders a prominent "VDOT 36 · base fitness" card computed from
the 5K time the user just entered. The Progress tab's stat row then shows `--`,
because it derives VDOT from logged runs only. The number is not missing — the app
computed it, used it to build the plan, and showed it — so `--` reads as data loss.

**Fix:** fall back to the profile's VDOT and label the source.

### S9 — "Recreational" in onboarding is "Intermediate" in Settings 🟡

[`OnboardingSubviews.swift:744`](../Stride/Features/Onboarding/OnboardingSubviews.swift#L744)

`OBFitnessSelection` presents four options; `FitnessLevel` has three. The user
picks "Recreational" and Settings' profile header reports "5K · Intermediate" — a
word they were never shown.

**Fix:** name the onboarding options with the vocabulary the rest of the app uses.

### S10 — Two onboarding options produce the same plan 🟡

[`OnboardingSubviews.swift:744`](../Stride/Features/Onboarding/OnboardingSubviews.swift#L744)

`fitnessLevel` maps both `.experienced` and `.competitive` to `.advanced`. The
collapse is visible on the screen itself: both cards read **"Plan starts ~25
mi/week"**, so the step openly shows that two of its four answers do nothing.

**Fix:** give `.competitive` its own level, so the four-way choice has four
outcomes.

### S11 — Goal time drifts between the summary and the Plan tab 🟡

[`OnboardingSubviews.swift:1056`](../Stride/Features/Onboarding/OnboardingSubviews.swift#L1056)

Onboarding's summary shows `GOAL 26:24`; the Plan tab shows `Goal 26:23` for the
same plan. Both derive from `PaceCalculatorService.predictedTime`, but the
onboarding view truncates its own seconds while the plan rounds, so they land a
second apart.

**Fix:** round consistently.

### S12 — "GOAL" is the current-fitness prediction, not a goal 🟡

[`OnboardingSubviews.swift:1107`](../Stride/Features/Onboarding/OnboardingSubviews.swift#L1107)

`goalFinishTimeSeconds` is `predictedTime(vdot:distanceMeters:)` — the time the
runner's *present* VDOT predicts. Labelling it `GOAL` tells a runner their goal is
to run exactly as fast as they already do. The Plan tab compounds it: "Estimated
Finish 26:23 / Goal 26:23 · **On track for goal**" is a tautology on day 0, because
the estimate and the goal are the same computation.

**Fix:** label it for what it is — a projected finish at current fitness.

---

## 4. Affordance and state

### S13 — Training Focus is disabled with no explanation 🔴

[`OnboardingView.swift:511`](../Stride/Features/Onboarding/OnboardingView.swift#L511)

`.opacity(selectedEquipment.isEmpty ? 0.4 : 1)` plus `.disabled(...)`. On arrival
nothing is selected, so the section is greyed out with a pre-checked radio and no
text saying what unlocks it. The Plan tab's disabled Smart Adapt card gets this
right — it carries "Turn on AI Coach in Settings to adapt your plan." directly
beneath it.

**Fix:** say why, the way the Plan tab does.

### S14 — Permission rows look like checkboxes but are not tappable 🔴

[`OnboardingSubviews.swift:967`](../Stride/Features/Onboarding/OnboardingSubviews.swift#L967)

`OBPermissionRow` is a pure status view — no `Button`, no tap target. Its trailing
element is an empty stroked `Circle`, which is the standard unchecked-checkbox
shape, on rows that also carry an icon, a title and a subtitle. Everything about
the row says "tap me to grant this"; only the CTA at the bottom actually does it.

**Fix:** make the trailing element read as status rather than control, and label
the rows as a list of what the CTA will ask for.

### S15 — The Apple Watch row can never be satisfied 🟡

[`OnboardingView.swift:543`](../Stride/Features/Onboarding/OnboardingView.swift#L543)

`isOn: false, isActive: false`, both hardcoded. It is not a permission,
`requestPermissionsSequentially` never touches it, and it sits in a list of three
rows that do change state — so it is permanently the one unchecked item on the
screen. It also reuses `permRowsVisible[2]`, the notifications row's animation
flag, in an array sized for three.

**Fix:** drop it from the permission list.

### S16 — The final onboarding screen has no way back 🟡

[`OnboardingSubviews.swift:1067`](../Stride/Features/Onboarding/OnboardingSubviews.swift#L1067)

`OBReady` draws the progress bar without the back chevron every other step has.
It is the first time the runner sees peak mileage, week count and the phase
breakdown — the screen most likely to make them want to change an answer — and the
only way back is to build the plan and rebuild it.

**Fix:** give it the same back control as every other step.

---

## 5. Colour and semantics

### S17 — The default-selected goal is outlined in red 🟡

[`OnboardingSubviews.swift:495`](../Stride/Features/Onboarding/OnboardingSubviews.swift#L495)

`OBGoalCard` tints per race type from the **pace-zone** palette, and 5K — the
default selection — draws `zoneInterval`, which is red. So the first interactive
screen in the app presents its pre-selected answer with a red border and a red
checkmark. Red is the app's error/destructive signal, and step 3's selection two
screens later is orange, so selection colour is not even internally consistent.

The zone palette is a *data* scale: it encodes effort on charts and in the run HUD.
Reusing it as decoration on a goal picker is what puts red on a selection.

**Fix:** draw selection in the brand colour, and keep the per-race tint for the
icon only.

### S18 — Peak weeks are red on the plan chart 🟡

The `WeeklyMileageChart` legend is Base / Build / Peak / Taper in blue / orange /
red / green. Red for "your hardest training block" reads as a warning on the screen
that is meant to make the plan look achievable. Same root cause as S17: a zone
scale used as a category scale.

**Fix:** deferred — see §7.

---

## 6. Layout

### S19 — ~~The Plan tab's floating calendar button overlaps the week list~~ ⬜ NOT A DEFECT

**Withdrawn.** The unlabelled circular glyph pinned bottom-left over the "Week 4 ·
Base" row is not an app control. It is the **system tab bar in its minimized
state**: `MainTabView` opts into
[`.tabBarMinimizeBehavior(.onScrollDown)`](../Stride/Features/Dashboard/MainTabView.swift#L43),
so scrolling collapses the bar to a pill showing the selected tab's icon — a
calendar, tinted `Color.brand`, because Plan is selected.

Floating over content is what that control is *for*; the platform does not inset
the scroll view behind it, and adding an inset would leave a permanent gap once the
bar re-expands. Nothing to fix.

### S20 — The Plan tab says "Started" for a plan that has not started 🟡

[`PlanTabView.swift:543`](../Stride/Features/Training/PlanTabView.swift#L543)

The third overview stat is `plan.startDate` under a hardcoded `"Started"` label. A
plan created today with next Monday's start renders "Aug 3 / Started" on July 27.

**Fix:** switch the label on whether the date is in the past.

### S21 — Plan week rows carry no dates 🟡

"Week 1 · Base — 0/4 workouts · 12.4 mi target" gives no way to tell which week is
current, or when any of them happen. `TrainingWeek` has `startDate`.

**Fix:** show the week's date range.

### S22 — The weekly-load strip is seven unlabelled bars 🟡

[`DashboardView.swift:483`](../Stride/Features/Dashboard/DashboardView.swift#L483)

The bar for today-with-nothing-logged is drawn with `isActive: true`, which fills
it in the brand colour. On a fresh install that is one orange segment among six
grey ones, directly under "0.0 mi / 0 Runs" — indistinguishable from a progress
meter reading 1/7. The chart has a full `chartAccessibility` summary, so VoiceOver
users get more information here than sighted ones.

**Fix:** label the days.

### S23 — Home is more than half empty and does not scroll 🟡

Below "Start a Free Run" the Today screen is blank to the tab bar; three onboarding
steps (2, 5, 7) have the same void above their pinned CTA. Not a defect on its own,
but it is the reason S4 lands as hard as it does — there is nothing else on the
screen to look at.

**Fix:** deferred — see §7.

### S24 — The units control has two different designs 🟡

Onboarding step 3 draws it as an iOS segmented control (white selection on a grey
track); Settings draws it as a solid orange pill. Same setting, two visual
languages.

**Fix:** deferred — see §7.

### S25 — Age and Max HR are stepper-only 🟡

[`OnboardingSubviews.swift:899`](../Stride/Features/Onboarding/OnboardingSubviews.swift#L899)

Moving age from the default 30 to 45 is fifteen taps, with no keyboard entry.

**Fix:** deferred — see §7.

---

## 7. Deferred, with reasons

These are real, and they are not being fixed in this pass:

- **S18 (Peak = red), S24 (two units controls)** — both are palette/design-system
  decisions that want a device and a designer, not a diff. Changing the phase
  colours in isolation would leave the chart's legend out of step with the phase
  bar on the Plan tab, which uses the same four names.
- **S23 (empty screens)** — density is a redesign, not a patch. The earlier UX
  audit deferred the spacing scale for the same reason and said so.
- **S25 (stepper-only numerics)** — a keyboard-entry affordance is worth having but
  needs a decimal pad, a validation story and a focus model; it is its own change.

## 8. Not UX — found while running the tests

- `StrideTests` does not compile on Xcode 27.0 beta: *"Default initializer for
  `MockHealthKitRepository` cannot be both nonisolated and main actor-isolated"* at
  [`WorkoutSyncServiceTests.swift:39`](../StrideTests/WorkoutSyncServiceTests.swift#L39).
  Because `xcodebuild test` builds every target in the scheme, this blocks the UI
  tests too.
- `app.tabBars["main.tabs"]` no longer resolves on iOS 27 once the floating tab bar
  minimises on scroll. Every test in `StrideUITests.swift` reaches the tab bar that
  way, so the existing suite is affected as well;
  `StrideScreenshotTests` looks the buttons up at app level instead.
