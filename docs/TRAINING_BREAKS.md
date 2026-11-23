# Training breaks: "not feeling 100%" and holiday mode

The runner tells the plan they can't train normally for a few days, because they're
**ill**, **injured** or **travelling**. The plan either **eases off** (every run becomes a
short easy run) or **pauses** (no running), then brings them back in gradually over the
**easing-back** days that follow.

Code: `TrainingBreakPolicy` (every number below), `TrainingBreakPlanner` (the rules, pure,
tested in `TrainingBreakPlannerTests`), `TrainingBreak` and `TrainingBreakStore` (the record
kept on the device).

## What the numbers are

These are conservative coaching rules of thumb, the shape most return-to-run guidance
takes: come back below where you left off, easy running before quality, and the longer
you were away the longer the way back. They are **not** taken from a study, and nothing
here is medical advice. Change a number here and in `TrainingBreakPolicy` together.

| Rule | Value | Why |
| --- | --- | --- |
| Longest break | 28 days | Past four weeks the plan you come back to is the wrong plan; rebuild it instead. |
| Furthest ahead a break can start | 21 days | A holiday booked for the week after next. |
| Suggest rebuilding after a pause of | 15+ days | Two weeks off loses enough fitness that the remaining plan's paces and volume are too much. The ramp still runs; the card says rebuilding is an option. |
| Ease off: share of each run kept | ill/injured 50%, travelling 70% | Ill or hurt: just enough to keep moving. Travelling: healthy, just short on time. |
| Shortest run the break writes | 2 km, never longer than the run it replaced | A run shorter than that isn't worth the change of clothes. |
| Pause: strength and cross-training | rest, except when injured | Injured runners keep fit by cross-training, and the strength card already says to skip what hurts. Ill: rest completely. Travelling: away from the gym. |

### Easing back

An "ease off" break kept the runner running, so it counts as half its length.

| Days off | Easing-back days | First half: share of distance | Second half |
| --- | --- | --- | --- |
| 1–2 | none | | |
| 3–7 | 7 | 70% | 85% |
| 8–14 | 14 | 60% | 80% |
| 15–28 | 14 | 50% | 75% |

- Tempo and interval days become easy runs in the first half of the ramp; after an
  injury they stay easy for the whole ramp.
- Long runs stay long runs, only shorter.
- Interval days kept as intervals (second half) keep the plan's reps.
- The ramp stops the day before race day and at the plan's end. The race itself is never
  changed, and a break that covers race day is refused.

## Plans prescribed by time

A Start Running or pregnancy plan prescribes minutes and effort, so it has no shorter easy
version of a session to write: it can **pause** but not ease off, and gets no ramp. Start
Running has "Repeat this week" for coming back.

## Where the record lives

`TrainingBreakStore`, in `UserDefaults` on the device, because a stored property on a
`@Model` would need a CloudKit schema deployment. The changed sessions themselves are
ordinary plan edits and sync like any other. The record keeps each changed session as it
was, so **Undo** puts it back exactly, and only if it still looks the way the break left
it: a session the runner changed again since stays as they made it. While a break is live
the pace refresh after a run leaves its sessions alone (`TrainingBreakStore.protectedIDs`).

## The coach

- The chat's plan context and the post-run read carry `TrainingBreak.coachNote(on:)`:
  what the break is, until when, not to suggest hard or extra running, not to read the
  shorter runs as missed, and the health cautions for illness and injury.
- The coach chat's plan changes (`PlanChangePlanner`) refuse to add a run or make one
  harder on a break or easing-back day (`Refusal.duringTrainingBreak`); resting a day or
  turning a run easy is still allowed.
- Smart Adapt and "apply coach feedback" skip a live break's sessions
  (`AdaptableWorkoutSelector`, `excluding:`).
