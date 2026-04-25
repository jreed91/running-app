# Stride

A SwiftUI running coach app that creates adaptive training plans, tracks workouts, and generates routes.

## Setup

1. Install XcodeGen.
2. Generate the Xcode project:
   ```bash
   xcodegen generate
   ```
3. Open `Stride.xcodeproj` and run the `Stride` scheme.

### Secrets

Route generation requires an OpenRouteService API key:

1. Copy `Stride/Resources/Secrets.plist.example` to `Stride/Resources/Secrets.plist`.
2. Set `ORSAPIKey` to your token.

## Architecture overview

- `Stride/App/AppContainer.swift`: composition root for repositories + services.
- `Stride/Core/Models`: domain models (`UserProfile`, `TrainingPlan`, `ScheduledWorkout`, etc.).
- `Stride/Core/Services`: business logic (plan generation, analytics, migration, routes).
- `Stride/Features`: SwiftUI feature modules and view models.

## Testing

Run unit tests from Xcode, or with `xcodebuild`:

```bash
xcodebuild test \
  -scheme Stride \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Release / CI notes

- CI uses Xcode Cloud scripts in `ci_scripts/`.
- Project files are generated from `project.yml` (do not hand-edit generated `.xcodeproj`).
- TestFlight release notes are assembled from commit history by CI.
