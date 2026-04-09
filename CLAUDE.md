# Running App — Architecture Guide

## Purpose

A fully native iOS app built with Swift that replicates the core functionality of the Runna app: tracking running workouts and generating adaptive training plans to improve race times for a **5K** or **Half Marathon**.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Language | Swift 6 |
| UI Framework | SwiftUI |
| Navigation | NavigationStack + TabView |
| Concurrency | Swift Concurrency (async/await, Actors) |
| Local Persistence | SwiftData (iOS 17+) |
| Health & GPS | HealthKit + CoreLocation |
| Watch Support | watchOS companion app (WatchKit / SwiftUI) |
| Notifications | UserNotifications framework |
| Charts | Swift Charts |

---

## High-Level Architecture

The app follows **MVVM + Repository** pattern:

```
View (SwiftUI)
  └── ViewModel (@Observable / ObservableObject)
        └── Repository (protocol)
              ├── SwiftData store (local)
              └── HealthKit store (health data)
```

Business logic (plan generation, pace calculations) lives in pure Swift **Services** that are injected into ViewModels, keeping them testable with no UI dependencies.

---

## Directory Structure

```
RunningApp/
├── App/
│   ├── RunningAppApp.swift          # @main entry point, environment setup
│   └── AppContainer.swift           # Dependency injection container
│
├── Core/
│   ├── Models/                      # SwiftData @Model classes
│   │   ├── RunWorkout.swift         # A recorded run session
│   │   ├── TrainingPlan.swift       # A generated multi-week plan
│   │   ├── TrainingWeek.swift       # One week of scheduled workouts
│   │   ├── ScheduledWorkout.swift   # Individual planned workout
│   │   └── UserProfile.swift        # Runner profile & goals
│   │
│   ├── Repositories/
│   │   ├── WorkoutRepository.swift  # CRUD for RunWorkout via SwiftData
│   │   ├── PlanRepository.swift     # CRUD for TrainingPlan via SwiftData
│   │   └── HealthKitRepository.swift# Read/write HealthKit workout samples
│   │
│   └── Services/
│       ├── TrainingPlanService.swift # Plan generation logic
│       ├── PaceCalculatorService.swift# Pace, VDOT, race prediction
│       ├── WorkoutTrackerService.swift# Live GPS tracking session
│       └── NotificationService.swift # Workout reminders
│
├── Features/
│   ├── Onboarding/
│   │   ├── OnboardingView.swift
│   │   └── OnboardingViewModel.swift
│   │
│   ├── Dashboard/
│   │   ├── DashboardView.swift      # Home tab: upcoming workouts + stats
│   │   └── DashboardViewModel.swift
│   │
│   ├── Training/
│   │   ├── PlanSetupView.swift      # Goal race, current fitness, weeks
│   │   ├── PlanSetupViewModel.swift
│   │   ├── PlanDetailView.swift     # Full plan calendar view
│   │   ├── WeekDetailView.swift     # Week breakdown
│   │   └── WorkoutDetailView.swift  # Individual workout instructions
│   │
│   ├── ActiveRun/
│   │   ├── ActiveRunView.swift      # Live tracking HUD
│   │   ├── ActiveRunViewModel.swift
│   │   └── PaceZoneIndicator.swift  # Real-time pace zone widget
│   │
│   ├── History/
│   │   ├── HistoryView.swift        # List of past runs
│   │   ├── HistoryViewModel.swift
│   │   └── RunSummaryView.swift     # Post-run summary & map
│   │
│   ├── Progress/
│   │   ├── ProgressView.swift       # Charts: mileage, pace trends
│   │   └── ProgressViewModel.swift
│   │
│   └── Settings/
│       ├── SettingsView.swift
│       └── SettingsViewModel.swift
│
├── WatchApp/                        # watchOS companion target
│   ├── WatchRunningAppApp.swift
│   ├── ActiveRunWatchView.swift
│   └── WatchWorkoutManager.swift   # HKWorkoutSession on Watch
│
├── Shared/
│   ├── Extensions/                  # Swift / SwiftUI extensions
│   ├── Components/                  # Reusable SwiftUI views
│   │   ├── PaceRingView.swift
│   │   ├── HeartRateGauge.swift
│   │   └── WorkoutTypeTag.swift
│   └── Theme/
│       ├── AppColors.swift
│       └── AppFonts.swift
│
└── Resources/
    ├── Assets.xcassets
    └── Info.plist
```

---

## Core Data Models

### `UserProfile`
```swift
@Model class UserProfile {
    var name: String
    var goalRace: RaceType          // .fiveK | .halfMarathon
    var goalFinishTime: TimeInterval
    var weeklyRunDays: Int
    var fitnessLevel: FitnessLevel  // .beginner | .intermediate | .advanced
    var currentEstimated5KTime: TimeInterval?
}
```

### `RunWorkout` (recorded run)
```swift
@Model class RunWorkout {
    var id: UUID
    var date: Date
    var distanceMeters: Double
    var durationSeconds: Double
    var averagePaceSecondsPerKm: Double
    var averageHeartRate: Double?
    var elevationGainMeters: Double?
    var routeCoordinates: [CLLocationCoordinate2D] // encoded as Data
    var workoutType: WorkoutType    // .easy | .tempo | .interval | .longRun | .race
    var splits: [Split]             // per-km split data
}
```

### `TrainingPlan`
```swift
@Model class TrainingPlan {
    var id: UUID
    var targetRace: RaceType
    var goalTime: TimeInterval
    var startDate: Date
    var endDate: Date
    var weeks: [TrainingWeek]
    var isActive: Bool
}
```

### `ScheduledWorkout`
```swift
@Model class ScheduledWorkout {
    var id: UUID
    var scheduledDate: Date
    var workoutType: WorkoutType
    var targetDistanceMeters: Double?
    var targetPaceRange: ClosedRange<Double>?  // seconds/km
    var intervals: [Interval]?      // for interval sessions
    var completedWorkout: RunWorkout?
    var isCompleted: Bool
}
```

---

## Training Plan Generation

`TrainingPlanService` generates a periodized plan using these principles:

1. **VDOT-based pacing** — Derives training paces (easy, tempo, interval, long run) from the user's estimated 5K time using Jack Daniels' VDOT tables.
2. **Periodization** — Base → Build → Peak → Taper phases scaled to the number of weeks.
3. **Progressive overload** — Weekly mileage increases ~10% per week with a cutback week every 4th week.
4. **Workout type mix** — ~80% easy/long, ~20% quality (tempo + intervals), following 80/20 principle.
5. **Race-specific structure**:
   - **5K plan**: 8–12 weeks, emphasis on VO2max intervals (800m–1200m reps)
   - **Half Marathon plan**: 12–20 weeks, emphasis on tempo runs and progression long runs

---

## Key Features

| Feature | Implementation |
|---|---|
| Live GPS tracking | `CLLocationManager` with background location |
| Auto-pause | Speed threshold detection |
| Pace zones | VDOT-derived, displayed via `PaceZoneIndicator` |
| Heart rate | HealthKit `HKQuantityType.heartRate` |
| Route map | MapKit `Map` view with polyline overlay |
| Workout charts | Swift Charts — weekly mileage, pace trends |
| Apple Watch | WCSession sync + independent HKWorkoutSession |
| HealthKit sync | Write completed runs; read historical runs |
| Notifications | Scheduled reminders for planned workouts |

---

## Navigation Structure

```
TabView
├── Dashboard (home)          — upcoming workout card, weekly summary
├── Training Plan             — plan calendar, workout details
├── Active Run                — fullscreen during a run
├── History                   — past runs list + detail
└── Progress                  — charts & stats
```

---

## Permissions Required

```
NSLocationWhenInUseUsageDescription     — GPS during active run
NSLocationAlwaysUsageDescription        — Background tracking
NSHealthShareUsageDescription           — Read historical workouts
NSHealthUpdateUsageDescription          — Write completed runs
NSMotionUsageDescription                — Cadence via CMPedometer (optional)
```

---

## Development Notes

- **iOS deployment target**: iOS 17.0 (required for SwiftData)
- **Xcode version**: 26.4
- **Swift version**: 6 (strict concurrency enabled)
- **Testing**: XCTest for services; Swift Testing for unit tests on plan generation logic
- **No third-party dependencies** — 100% Apple frameworks

### Running the App
1. Open `RunningApp.xcodeproj` in Xcode 26.4
2. Select a physical device (GPS + HealthKit require real hardware)
3. Enable the `HealthKit` and `Background Modes` capabilities in the project settings
4. Build & run (`Cmd+R`)

### Key Commands
```bash
# Run unit tests
xcodebuild test -scheme RunningApp -destination 'platform=iOS Simulator,name=iPhone 17'

# Build for release
xcodebuild archive -scheme RunningApp -archivePath build/RunningApp.xcarchive
```
