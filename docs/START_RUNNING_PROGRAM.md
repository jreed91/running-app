# Start Running program

The run/walk plan for someone new to running, or coming back to it. Built by
`StartRunningPlanService` from the table in `StartRunningProgram`. Read this before changing a
number in that table, and update it in the same change.

Stride is not a clinician, and nothing here is a medical prescription. The table is a product
choice checked against a widely used public programme, not a protocol from a trial.

## What it is checked against

The NHS Couch to 5K programme
([NHS: Get running with Couch to 5K](https://www.nhs.uk/live-well/exercise/running-and-aerobic-exercises/get-running-with-couch-to-5k/))
says, on that page:

- "The plan has you running 3 times a week, with rest days in between."
- "In the first week, you'll start with 1 minute runs, followed by a 1 minute 30 second walk."
- "by the end you'll be running for 30 minutes without stopping."
- It takes 9 weeks, "or longer, depending on what works best for you."
- Anyone worried about their health should see a GP first.

Its fifth week goes from runs of 8 minutes (two of them, with a 5 minute walk between) to
20 minutes without stopping. That week-by-week detail is in the NHS Couch to 5K podcast and
app, not on the page above; it was checked against transcriptions of the podcast, so confirm
it against the current NHS app before quoting it.

## The table

Ten stages, one a week. Every session is a 5 minute brisk walk, the stage's main set, and a
5 minute walk to finish. There is no walk after the last run of the main set: the cool-down
follows it.

| Stage | Main set | Longest run | Running | Main set length |
| --- | --- | --- | --- | --- |
| 1 | 8 × (1:00 run, 1:30 walk) | 1 min | 8 min | 18:30 |
| 2 | 7 × (1:30 run, 1:30 walk) | 1.5 min | 10:30 | 19:30 |
| 3 | 6 × (2:00 run, 1:30 walk) | 2 min | 12 min | 19:30 |
| 4 | 5 × (3:00 run, 1:30 walk) | 3 min | 15 min | 21 min |
| 5 | 4 × (5:00 run, 1:30 walk) | 5 min | 20 min | 24:30 |
| 6 | 3 × (8:00 run, 1:30 walk) | 8 min | 24 min | 27 min |
| 7 | 2 × (12:00 run, 1:30 walk) | 12 min | 24 min | 25:30 |
| 8 | 18 min without stopping | 18 min | 18 min | 18 min |
| 9 | 24 min without stopping | 24 min | 24 min | 24 min |
| 10 | 30 min without stopping | 30 min | 30 min | 30 min |

Why it looks like this:

- **Same start and finish as Couch to 5K.** Stage 1 is the NHS first week (1 minute runs,
  90 second walks); stage 10 is the NHS finish (30 minutes without stopping).
- **No big jump.** The longest run grows by at most 1.7× a stage (1, 1.5, 2, 3, 5, 8, 12, 18,
  24, 30 minutes). The NHS schedule's jump from 8 minutes to 20 inside week 5 is the step this
  table spreads over more weeks. That is why it has ten stages, not nine.
- **Total running can dip.** Stage 8 has less running than stage 7 (18 minutes against 24),
  because it is the first run without a break. The continuous stretch is what grows.
- **Walk breaks stay at 90 seconds.** One number for the runner to learn.
- **Three runs a week with a day between.** The NHS rule. `StartRunningPlanService.runOffsets`
  takes up to three of the runner's chosen days, as far apart as those days allow.
- **The same session every run day of a week.** A runner repeats a session until it is
  familiar before the next stage asks for more.

## Starting points

One question places the runner: how long can you run without stopping today? The first stage
is the one whose longest run is no longer than the answer, so week one is never a step up.

| Answer | First stage | Weeks |
| --- | --- | --- |
| Not yet, or under a minute | 1 | 10 |
| 2 to 3 minutes | 3 | 8 |
| About 5 minutes | 5 | 6 |
| 10 minutes or more | 6 | 5 |

A runner who can already run about 20 minutes is better served by a 5K plan.

## What the plan never does

- **No pace targets.** Every session leaves `targetPaceLowerBound`/`UpperBound` nil and asks
  for a pace the runner could talk at in short sentences. Someone who can't yet run for five
  minutes has no pace worth training at, so a VDOT band would be wrong by construction.
- **Nothing rewrites it.** `PlanKind.prescribesByTime` keeps the post-run pace refresh, Smart
  Adapt, the coach's "update next session" and the heat sheet off it. The week-to-week
  progression is the plan; any of those would change it out from under the runner.
- **No race.** `PlanKind.hasGoalRace` is false, so no race-day hub or countdown appears even
  if an old race date is still on the profile.

The distance shown on each session is an estimate from the minutes (the runner's easy pace
when there is a 5K time on file, otherwise 8:00 per km running and 12:00 per km walking). It
is never a target, and the coach is told so.

## On the run

The guided run steps through the session and, with spoken cues on, calls it in run/walk words
(`GuidedCueStyle.runWalk`): "Brisk walk. 5 minutes.", "Run 1 of 8. 60 seconds. Go.", "Walk. 90
seconds.", "10 seconds. Get ready to run.", and after the last run "Running done. Walk to
finish. 5 minutes." The last run goes straight into that walk; there is no 90 second walk in
front of it, on the phone or on the Watch.

## Safety wording

Every session note and the Plan tab card carry: "Stop and get checked if you have chest pain,
feel faint, or have pain that gets worse as you run." The card adds the NHS page's advice to
talk to a doctor first if worried about health.
