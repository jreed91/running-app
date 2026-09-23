# Stride

A SwiftUI running coach app that creates adaptive training plans, tracks workouts, and generates routes.

## Setup

1. Install XcodeGen.
2. Generate the Xcode project:
   ```bash
   xcodegen generate
   ```
3. Open `Stride.xcodeproj` and run the `Stride` scheme.

### Route generation

Route Genius works out of the box: with no key configured it builds routes from
Apple Maps walking directions (`MKDirections`), which need no account or token.

Optionally, a runner can use the OpenRouteService Directions API instead, whose
`round_trip` option shapes loops server-side:

1. Get a free token from [openrouteservice.org](https://openrouteservice.org).
2. Run the app, then go to **Settings → Route Genius API key** and paste it.

The token is stored via `KeychainStore` (`AfterFirstUnlockThisDeviceOnly`) and is
never written to `UserDefaults` or synced through iCloud. Nothing reads
`Stride/Resources/Secrets.plist`; the example file is a leftover.

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
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Release / CI notes

- GitHub Actions (`.github/workflows/`) lints with SwiftLint, builds, and gates on tests.
- Xcode Cloud scripts in `ci_scripts/` handle archive/TestFlight builds.
- The app version and build number live in `ci_scripts/Version.xcconfig`.
- Project files are generated from `project.yml` (do not hand-edit generated `.xcodeproj`).
- TestFlight release notes are assembled from commit history by CI: `ci_scripts/ci_post_xcodebuild.sh`
  writes a bulleted changelog of the commits in each archive to `TestFlight/WhatToTest.en-US.txt`.
  Preview what a build would send with
  `CI_XCODEBUILD_ACTION=archive sh ci_scripts/ci_post_xcodebuild.sh`.
