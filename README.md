# RunningApp

A SwiftUI running coach app that creates adaptive training plans, tracks workouts, and generates routes.

## Setup

1. Install XcodeGen.
2. Generate the Xcode project:
   ```bash
   xcodegen generate
   ```
3. Open `RunningApp.xcodeproj` and run the `RunningApp` scheme.

### Secrets

Route generation requires an OpenRouteService API key:

1. Copy `RunningApp/Resources/Secrets.plist.example` to `RunningApp/Resources/Secrets.plist`.
2. Set `ORSAPIKey` to your token.

## Architecture overview

- `RunningApp/App/AppContainer.swift`: composition root for repositories + services.
- `RunningApp/Core/Models`: domain models (`UserProfile`, `TrainingPlan`, `ScheduledWorkout`, etc.).
- `RunningApp/Core/Services`: business logic (plan generation, analytics, migration, routes).
- `RunningApp/Features`: SwiftUI feature modules and view models.

## Testing

Run unit tests from Xcode, or with `xcodebuild`:

```bash
xcodebuild test \
  -scheme RunningApp \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Release / CI notes

- CI uses Xcode Cloud scripts in `ci_scripts/`.
- Project files are generated from `project.yml` (do not hand-edit generated `.xcodeproj`).
- TestFlight release notes are assembled from commit history by CI.
