# RunningApp

A native iOS training app (SwiftUI + SwiftData) for planning and tracking runs across **5K**, **Half Marathon**, **Marathon**, and **Maintain Fitness** goals.

## Tech stack
- Swift 6
- SwiftUI
- SwiftData
- HealthKit
- XcodeGen (`project.yml` is source of truth)

## Quick start
1. Generate the project:
   ```bash
   xcodegen generate
   ```
2. Open the generated project in Xcode.
3. Build and run on simulator/device.

> Note: GPS and HealthKit features require a physical device for full validation.

## Testing
Run all tests:
```bash
xcodebuild test -scheme RunningApp -destination 'platform=iOS Simulator,name=iPhone 17'
```

Run a single test class:
```bash
xcodebuild test -scheme RunningApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RunningAppTests/PaceCalculatorTests
```

## Secrets setup (Route Genius)
Route generation uses OpenRouteService.

1. Copy `RunningApp/Resources/Secrets.plist.example` to `RunningApp/Resources/Secrets.plist`.
2. Add your `ORSAPIKey` value.
3. Do not commit `Secrets.plist` (it is gitignored).

## Project layout
- `RunningApp/App/` — app entry and DI container
- `RunningApp/Core/Models/` — domain + SwiftData models
- `RunningApp/Core/Repositories/` — persistence / HealthKit data access
- `RunningApp/Core/Services/` — plan generation, analytics, tracking, route generation
- `RunningApp/Features/` — SwiftUI screens
- `RunningAppTests/` — Swift Testing unit tests
- `RunningAppUITests/` — XCTest UI smoke tests

## CI notes
Xcode Cloud helper scripts are in `ci_scripts/`:
- `ci_post_clone.sh` installs XcodeGen and generates the project.
- `ci_post_xcodebuild.sh` creates TestFlight "What to Test" notes from commit history.
