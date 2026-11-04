# Siri AI Developer Preview

Apple's preview (App Intents, iOS 27.3 beta SDK) lets Siri call an app's own intents as
tools and read its entities, without the runner naming the app while Stride is in the
foreground. Source: <https://developer.apple.com/documentation/appintents/siri-ai-developer-preview>.

**Who gets it:** only development-signed builds and **internal** TestFlight testers on a
device that supports Apple Intelligence. External TestFlight and the App Store don't get
the preview behaviour, so nothing here changes what App Store users see today.

## What Stride does

| Preview guidance | Stride |
| --- | --- |
| Turn custom intents into tools (`@AppIntent(.tool)`) | Today's Run, Weekly Running Summary, Coach Tip, Get Run Details. All four are read-only, one-sentence asks. |
| Title + description on each intent and parameter | Descriptions say what comes back and in which units. |
| Describe entity properties | `RunWorkoutEntity` exposes date, type, distance, duration, average pace as `@Property`. |
| Let Siri find entities | Already done: `IndexedEntity`, 50 recent runs indexed at launch. |
| Onscreen context | Run detail tags itself with `.appEntityIdentifier(...)`, so "this run" resolves. |
| Behavioural cues | Viewing a run donates `RunDetailsIntent`. |
| Transferable entities | A run exports as plain text (title, date, pace, time). |
| Generable entities | `RunSearch` for the find runs tool (below). |
| App skills | `running-questions` (below). |

## How the tool attribute is gated

`@AppIntent(.tool)` and `ToolIntent` only exist in the iOS 27.3 SDK, and CI plus App Store
archives still build with Xcode 27.0. Each intent carries:

```swift
#if canImport(SiriEvaluations)
@AppIntent(.tool)
#endif
```

`SiriEvaluations` is a framework new in that same SDK, so building with the 27.3 beta
Xcode switches the tools on and older Xcodes compile exactly as before. The macro adds
the conformance with `ToolIntent`'s own availability, so the 27.0 deployment target is
fine. When the 27.3 SDK ships, the gate can go.

## App skill

`Stride/Resources/Skills.skillsbundle/Skills/running-questions/SKILL.md` tells Siri which
tool answers which kind of question (today, this week, one run, a range of runs, the coach)
and how to say numbers (keep the runner's units, paces as time per km or mile). `project.yml`
registers `.skillsbundle` under `options.fileTypes` as one resource file; without it
XcodeGen walks into the folder and copies each `SKILL.md` flat into the app. Xcode 27.3
compiles the bundle; older Xcodes copy it as a plain folder that nothing reads.

## Find runs tool

`FindRunsIntent` takes a generable `RunSearch` entity (`@AppEntity(.generable)`: run type,
from, to, minimum kilometres), so Siri fills the search in from "my long runs over 20 km
last month" without asking Stride first. It returns up to 20 `RunWorkoutEntity` values,
newest first, plus a spoken count and total. The whole file sits inside
`#if canImport(SiriEvaluations)` and `@available(iOS 27.3, *)`. The query
(`IntentModelActor.findRuns`) and the spoken answer (`RunSearchDialog`) are ungated and
unit-tested.

## Still blocked

- **Property `description:`** (`@Property(title:description:)`, `@ComputedProperty`,
  `@DeferredProperty`) is iOS 27.3+. A stored property can't carry availability, so on
  `RunWorkoutEntity` (27.0 target) it waits until the deployment target is 27.3.
  `RunSearch` already uses it, because that whole type is 27.3+.
- **Entity `authenticationPolicy`** is an iOS 27.3+ static requirement; a witness with
  higher availability than the 27.0 type isn't used. Same wait.

## Testing on a device

1. Build with the Xcode 27.3 beta, development signing, on an Apple Intelligence device
   running iOS 27.3 beta.
2. With Stride open, ask without naming the app: "What's my run today?", "How far have I
   run this week?", "What should I eat before my run?", "Find my long runs over 20 km
   since September". Open a run and ask "Send this run to …".
3. In Xcode, check that `Skills.skillsbundle` shows as a Skills Bundle in the File
   inspector and sits in the Stride target's Copy Bundle Resources phase.
4. With Stride in the background, include the app name.
5. Xcode's Siri Integration Advisor reports on the intents; `SiriEvaluations` can script
   these requests later.
