# Stride Repository Analysis (April 24, 2026)

## Executive summary

This repository has a strong foundation: clear domain modeling, sensible service boundaries, and meaningful unit tests around core training logic. The biggest opportunities are **operational hardening** (logging, error handling, secrets hygiene), **test-depth expansion**, and **developer-experience/documentation improvements**.

## What the repo already does well

1. **Clear architecture direction**
   - A single composition root (`AppContainer`) wires repositories/services and isolates app startup behavior.
   - Domain logic is concentrated in services (e.g., `TrainingPlanService`) that are mostly pure and testable.

2. **Good domain-first modeling**
   - The model set (`UserProfile`, `TrainingPlan`, `TrainingWeek`, `ScheduledWorkout`, `RunWorkout`, `SavedRoute`) reflects product requirements for adaptive planning and workout history.

3. **CI automation is present**
   - Xcode Cloud scripts generate projects, set build numbers, and produce TestFlight notes from commit history.

4. **Core algorithm tests exist**
   - `PaceCalculatorService` and `TrainingPlanService` both have direct unit tests using Swift Testing.

---

## Gap analysis and improvements

## 1) Product & architecture

### ✅ Gap 1.1 — No repository-level architecture docs for contributors
- There is no `README.md` at repository root (discoverability and onboarding gap for developers and reviewers).

**Improvements**
- Add a concise `README.md` with:
  - Setup (`xcodegen generate`, simulator/device caveats)
  - Architecture overview diagram
  - Testing commands
  - Release flow and Xcode Cloud notes
- Add `docs/adr/` for architecture decisions (CloudKit fallback strategy, plan adaptation rules).

**MOSTLY FIXED:** `README.md` (setup, architecture map, testing, CI/release) and
`AGENTS.md` (the canonical contributor/agent guide, now including an index of the
`docs/` reviews) both exist. *Still open:* no `docs/adr/` — the CloudKit fallback
tiers and plan-adaptation rules are documented only in the analysis docs and in
source comments.

### Gap 1.2 — Hardcoded environment/business constants in app code
- IDs/identifiers are directly in source and project config (bundle/team/container values).
- This increases friction for forks/staging environments.

**Improvements**
- Move env-specific values to xcconfig files (`Debug.xcconfig`, `Release.xcconfig`, optionally `Staging.xcconfig`).
- Keep source constants for defaults only, with compile-time overrides where appropriate.

---

## 2) Security, secrets, and compliance

### Gap 2.1 — `Secrets.plist` is documented but not gitignored
- The example file instructs contributors to create `Stride/Resources/Secrets.plist`, but `.gitignore` does not exclude that path.

**Risk**
- Accidental API key commits are likely.

**Improvements**
- Add `Stride/Resources/Secrets.plist` to `.gitignore`.
- Optionally add a pre-commit hook or CI check to fail builds if a real key is committed.

### Gap 2.2 — Limited network hardening in route API client
- `RouteGeniusService.fetchRoute` decodes data without checking HTTP status code and has no explicit timeout/backoff strategy.

**Risk**
- Rate-limit, auth, and server failures are collapsed into generic decode/network errors; harder triage and poorer UX.

**Improvements**
- Validate `HTTPURLResponse.statusCode` and map 401/403/429/5xx into explicit error cases.
- Add request timeout and retry policy (with jittered exponential backoff for retryable responses).
- Surface user-facing guidance for quota/invalid-key conditions.

---

## 3) Reliability and observability

### Gap 3.1 — Print-based logging in production paths
- Startup and migration paths use `print(...)` and include `fatalError(...)` fallbacks.

**Risk**
- Logs are unstructured; production diagnosis is harder. Fatal startup paths can reduce resilience.

**Improvements**
- Replace `print` with `Logger` (OSLog) categories (`app.startup`, `data.migration`, `tracking`, `routing`).
- Review `fatalError` usage; where possible, degrade gracefully with telemetry + user-safe fallback.
- Add lightweight analytics/telemetry events for plan generation, sync failures, migration failures.

### Gap 3.2 — CloudKit/local fallback strategy is robust but not externally verified
- Fallback tiers are thoughtfully implemented in `AppContainer`, but there are no tests that exercise each tier.

**Improvements**
- Add integration tests for:
  - normal cloud config boot
  - cloud failure -> local fallback
  - persistent store recreation path
- Add runtime health indicator in diagnostics/settings to show active persistence mode.

---

## 4) Test strategy coverage

### Gap 4.1 — Unit tests are concentrated in only two services
- Current coverage is good for VDOT/plan generation but omits repositories, tracker/sync services, route generation, and migration.

**Improvements**
- Add unit tests for:
  - `WorkoutAnalyticsService`
  - `WorkoutSyncService` conflict/idempotency behavior
  - `RouteGeniusService` response parsing and error mapping
  - `DataMigrationService` versioned migration behavior
- Add repository tests with in-memory SwiftData container.

### Gap 4.2 — UI tests are smoke-level only
- Only onboarding completion + tab accessibility are tested.

**Improvements**
- Add UI tests for:
  - creating/editing plans
  - completing a run and verifying history entry
  - settings toggles (units, iCloud sync)
  - Route Genius generation fallback/error states

### Gap 4.3 — No contract/performance tests for key algorithms

**Improvements**
- Add benchmark-style tests for training plan generation on larger time horizons.
- Add snapshot/contract assertions for generated workout structures to detect accidental logic drift.

---

## 5) CI/CD and developer experience

### Gap 5.1 — CI scripts are useful but minimal quality gates
- CI scripts focus on generation/build notes; no lint/static-analysis gates are evident.

**Improvements**
- Add mandatory CI steps:
  - unit tests
  - UI test smoke suite
  - SwiftLint/format check (if adopted)
  - optional coverage threshold (start modestly, e.g., 50–60%).

### Gap 5.2 — Project generation dependency installed every run
- `brew install xcodegen` each post-clone can add build time and variability.

**Improvements**
- Pin XcodeGen version and prefer a cache-aware install path.
- If possible, cache Homebrew artifacts in CI or use preinstalled toolchain constraints.

---

## 6) UX, accessibility, and internationalization

### Gap 6.1 — Accessibility expectations are not documented/tested

**Improvements**
- Add accessibility acceptance criteria (VoiceOver labels, Dynamic Type, contrast).
- Add a minimal UI test check for critical accessibility identifiers and text scaling.

### Gap 6.2 — Internationalization readiness unclear

**Improvements**
- Externalize user-facing strings (`Localizable.strings`) and begin with EN baseline.
- Ensure pace/distance formatting and dates are locale-aware in all views.

---

## 7) Prioritized roadmap

## Next 2 weeks (high ROI)
- [x] Add root `README.md` and contributor setup guide.
- [x] Add `Stride/Resources/Secrets.plist` to `.gitignore` and CI secret-scan check. *(gitignore done; CI secret-scan still pending)*  
- [x] Implement HTTP status handling + richer errors in `RouteGeniusService`.
- [ ] Replace startup/migration `print` logging with OSLog.
- [~] Add tests for `RouteGeniusService` and `DataMigrationService`. *(RouteGenius tests added; DataMigration tests still pending)*

## Next 4–8 weeks
1. Expand UI test suite across key user journeys.
2. Add CI quality gates (lint/tests/coverage).
3. Introduce xcconfig-based environment separation.
4. Add diagnostics page for sync/persistence status.

## Longer-term
1. Add architecture decision records (ADRs).
2. Add telemetry dashboards for sync and route generation reliability.
3. Add perf regression testing for plan generation and large history datasets.

---

## Suggested success metrics

- **Reliability:** crash-free sessions, sync failure rate, route-generation success rate.
- **Quality:** unit/UI test counts and coverage trend.
- **Velocity:** average CI duration, PR cycle time.
- **Security hygiene:** zero secret leaks in repo history and PR scanning.
