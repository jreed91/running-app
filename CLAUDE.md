# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

A fully native iOS app built with Swift that replicates the core functionality of the Runna app: tracking running workouts and generating adaptive training plans for **5K**, **Half Marathon**, and **Marathon** races.

---

## Key Commands

```bash
# Generate Xcode project from project.yml (required after editing project.yml)
xcodegen generate

# Run unit tests
xcodebuild test -scheme Stride -destination 'platform=iOS Simulator,name=iPhone 17'

# Run a single test class
xcodebuild test -scheme Stride -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:StrideTests/PaceCalculatorTests

# Build for release
xcodebuild archive -scheme Stride -archivePath build/Stride.xcarchive
```

> GPS and HealthKit features require a **physical device**. The simulator supports build/test for pure logic.

---

## Project Configuration

The Xcode project is generated from **`project.yml`** using [XcodeGen](https://github.com/yonaskolb/XcodeGen). Edit `project.yml` to add targets, files, capabilities, or build settings — do **not** hand-edit the `.xcodeproj`.

- **iOS deployment target**: 26.0
- **Swift**: 6.0 with `SWIFT_STRICT_CONCURRENCY: complete`
- **No third-party dependencies** — 100% Apple frameworks

---

## Architecture

MVVM + Repository pattern:

```
View (SwiftUI)
  └── ViewModel (@Observable)
        └── Repository (protocol)
              ├── SwiftData store
              └── HealthKit store
        └── Service (pure Swift, injected)
```

**`AppContainer`** (`Stride/App/AppContainer.swift`) is the single DI root, created once at launch and injected via SwiftUI's `Environment` as `.appContainer`. It owns the `ModelContainer`, all repositories, and all services.

Business logic (plan generation, pace calculations) lives in **Services** with no UI dependencies, keeping them unit-testable.

---

## Key Directories

| Path | Contents |
|---|---|
| `Stride/App/` | `@main` entry point, `AppContainer` (DI root) |
| `Stride/Core/Models/` | SwiftData `@Model` classes, `Enums.swift`, `ValueTypes.swift` |
| `Stride/Core/Repositories/` | SwiftData + HealthKit CRUD via protocols |
| `Stride/Core/Services/` | `TrainingPlanService`, `PaceCalculatorService`, `WorkoutTrackerService`, `NotificationService`, `WorkoutAnalyticsService` |
| `Stride/Features/` | One folder per screen: `Dashboard`, `Training`, `ActiveRun`, `History`, `Progress`, `Settings`, `Onboarding` |
| `Stride/Shared/` | Reusable `Components/`, `Extensions/`, `Theme/` |
| `StrideTests/` | Unit tests using **Swift Testing** (`@Test`, `#expect`) |

---

## Core Domain Types

**`Enums.swift`** — All shared enums:
- `RaceType`: `.fiveK` | `.halfMarathon` | `.marathon`
- `WorkoutType`: `.easy` | `.tempo` | `.interval` | `.longRun` | `.race` | `.rest` | `.crossTraining`
- `TrainingPhase`: `.base` | `.build` | `.peak` | `.taper`
- `FitnessLevel`: `.beginner` | `.intermediate` | `.advanced`

**`ValueTypes.swift`** — Codable value types used in models:
- `Coordinate` — Sendable/Codable wrapper around `CLLocationCoordinate2D`
- `Split` — Per-km split data
- `WorkoutStructure` / `WorkoutSet` / `WorkoutSegment` — Structured interval workout representation, serialised as JSON in `ScheduledWorkout`

---

## Training Plan Logic

`TrainingPlanService` generates periodized plans:
1. **VDOT-based pacing** — training paces derived from the user's estimated 5K time (Jack Daniels' VDOT tables), implemented in `PaceCalculatorService`
2. **Phases**: Base → Build → Peak → Taper, scaled to week count
3. **Progressive overload** — ~10% weekly mileage increase with a cutback every 4th week
4. **80/20 principle** — ~80% easy/long, ~20% quality (tempo + intervals)
5. **Workout adaptation** — `AppContainer.adaptedWorkout(scheduled:history:profile:)` adjusts a scheduled workout based on recent run history

---

## Testing

Tests use **Swift Testing** (not XCTest). Pattern:
```swift
@Test("Description of what is tested")
func testName() {
    #expect(condition)
    Issue.record("failure message")  // for non-fatal failures inside guards
}
```

Test files live in `StrideTests/`. Coverage focuses on `PaceCalculatorService` (VDOT math, pace ordering, round-trips) and `TrainingPlanService` (plan structure, phase ordering, volume progression).

---

## Navigation

```
TabView
├── Dashboard     — upcoming workout card, weekly summary
├── Training Plan — plan calendar, workout details
├── Active Run    — fullscreen live tracking HUD
├── History       — past runs list + detail
└── Progress      — charts & stats
```

---

## Swift 6 Concurrency Notes

Strict concurrency is enabled (`complete`). Key patterns in this codebase:
- `AppContainer` is `@MainActor final class`
- Repositories and services must be `Sendable` or actor-isolated
- Use `nonisolated(unsafe)` only for static default values (e.g., `EnvironmentKey.defaultValue`)
