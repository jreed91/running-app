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

## Left for later

- **Property `description:`** (`@Property(title:description:)`) is iOS 27.3+. A stored
  property can't be gated below the 27.0 deployment target, so it waits for the target.
- **Entity `authenticationPolicy`** is iOS 27.3+ too. The intents keep today's behaviour.
- **App skills** (`Skills.skillsbundle`) are for multi-step tasks. Stride's tools are each
  one step, and the bundle needs the Xcode 27.3 template plus an XcodeGen resource entry.
- **A generable "find runs" tool** (`@AppEntity(.generable)` search entity: type, date
  range, distance) would answer "my long runs over 20 km last month". New feature, 27.3 only.

## Testing on a device

1. Build with the Xcode 27.3 beta, development signing, on an Apple Intelligence device
   running iOS 27.3 beta.
2. With Stride open, ask without naming the app: "What's my run today?", "How far have I
   run this week?", "What should I eat before my run?". Open a run and ask "Send this run
   to …".
3. With Stride in the background, include the app name.
4. Xcode's Siri Integration Advisor reports on the intents; `SiriEvaluations` can script
   these requests later.
