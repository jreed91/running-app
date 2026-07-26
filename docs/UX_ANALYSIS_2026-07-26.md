# Stride — UX & SwiftUI Best-Practice Analysis (2026-07-26)

Third-pass review, scoped to **user experience and SwiftUI platform conformance**
rather than correctness. The two earlier audits
([`APP_ANALYSIS_2026-07.md`](APP_ANALYSIS_2026-07.md),
[`APP_ANALYSIS_2026-07-24.md`](APP_ANALYSIS_2026-07-24.md)) worked bug-by-bug and
closed nearly everything they found. This one looks for *systemic* gaps — places
where the app is individually correct on every screen but collectively off-standard.

Modern-API claims were validated against current SwiftUI guidance (Context7:
`/avdlee/swiftui-agent-skill`, `/websites/developer_apple_swiftui`). Contrast
ratios are computed from `Stride/Resources/Assets.xcassets`, not eyeballed.

## Scorecard

| Area | State | Notes |
| --- | --- | --- |
| VoiceOver labelling | 🟢 Strong | N18/D8 work paid off; charts, metric cells, day cells all speak well |
| Error recovery in the run flow | 🟢 Strong | Save-retry, discard, race-clamp notices are genuinely well designed |
| Information architecture | 🟢 Good | Tab split is sensible; empty states are specific, not generic |
| Design-system adoption | 🔴 Failing | Tokens exist and are ~unused; 3 of 5 scales are dead code |
| Dynamic Type | 🔴 Failing | 296 fixed font sizes; text does not scale app-wide (9pt floor fixed) |
| Colour contrast | 🟢 Fixed | ✅ CTAs, HUD, dark-mode zone collisions, high-contrast variants |
| Haptics | 🟢 Fixed | ✅ `sensoryFeedback` on run, guided steps, splits, strength sets |
| iOS 26/27 API adoption | 🟠 Started | ✅ `Tab` builder, native `Color.mix`; glass and Live Activity still absent |
| Destructive-action safety | 🟢 Fixed | ✅ Both swipe paths confirm; delete failures surface |
| History discoverability | 🟢 Fixed | ✅ Search, pull-to-refresh, first-sync loading state |

**Pass 1 (2026-07-26) closed:** the whole of Tier 1, plus §5a, §5d, §8, §9 and most
of §10. Still open: the §1/§2 typography migration (Tier 2) and the Tier 4 feature
work (Live Activity, spoken splits, `tabViewBottomAccessory`).

---

## 1. The design system is defined but not adopted

`Stride/Shared/Theme/` defines five token scales. Three of them have **zero call
sites outside their own file**:

| Scale | Defined in | Uses outside `Shared/Theme/` |
| --- | --- | --- |
| Type (`ds*`) | `AppFonts.swift:59-83` | **0** |
| Elevation (`appShadow` / `AppElevation`) | `AppElevation.swift` | **0** |
| Radius (`AppRadius`) | `AppRadius.swift` | 4 |
| Spacing (`AppSpacing`) | `AppSpacing.swift` | 18 |
| Animation (`AppAnimation`) | `AppAnimations.swift` | widely used ✅ |

What the app uses instead:

- **212** hardcoded `cornerRadius:` literals across 13 distinct values
  (`0, 1, 2, 3, 4, 8, 10, 12, 14, 16, 18, 20, 22`). `AppRadius` defines six
  (`6, 10, 14, 20, 26, pill`). The two sets barely overlap — `18` and `22` are
  the most common card radii in the app and neither exists in the scale.
- **353** hardcoded numeric `.padding()` values.
- **24** inline `.shadow(...)` calls, each with its own bespoke colour/radius/offset,
  while a four-level stacked-shadow scale sits unused.

This is the root cause of several findings below rather than a cosmetic
complaint: **the `ds*` type scale was created specifically to fix Dynamic Type
(N19) and then never wired up.** `AppFonts.swift:64-83` carries a careful comment
explaining why `ds`-prefixed tokens exist; the SwiftLint `custom_rules` entry
(`.swiftlint.yml:72`) guards against the *old* bug returning, but nothing pushes
call sites onto the new tokens.

**Fix.** Treat this as a mechanical migration, not a redesign. Map
`.font(.system(size: 17, weight: .bold))` → `.dsHeadline.weight(.bold)`,
`size: 15` → `.dsSubhead`, `size: 13` → `.dsFootnote`, `size: 11/12` →
`.dsCaption`, and so on; snap the 13 radius literals onto the 6-value scale;
replace inline shadows with `.appShadow(.e1/.e2)`. Then add SwiftLint custom
rules banning raw `.font(.system(size:`, raw `cornerRadius:` literals, and inline
`.shadow(` in `Stride/Features/`, so the scales cannot rot again.

---

## 2. Dynamic Type is effectively disabled app-wide 🔴

**296** `.font(.system(size: N))` call sites across 25 files. These render a fixed
point size and ignore the user's preferred content size entirely.

Distribution is the problem — the bulk sits at the *small* end, where scaling
matters most:

| Size | Count | Size | Count |
| --- | --- | --- | --- |
| 11pt | 57 | 15pt | 29 |
| 12pt | 45 | 14pt | 28 |
| 13pt | 37 | 10pt | 21 |
| | | 9pt | 12 |

Worst-affected files: `RunSummaryView.swift` (75 sites at ≤17pt),
`OnboardingSubviews.swift` (32), `StrengthActiveView.swift` (29),
`AICoachChatView.swift` (15).

Concrete consequences:

- **The primary CTAs don't scale.** "Start a Free Run" and "Start This Workout"
  are `.font(.system(size: 17, weight: .bold))`
  (`DashboardView.swift:572, 679`). A user at AX5 gets the same 17pt label as a
  user at the default size.
- **9pt labels exist.** `ActiveRunView.swift:438, 462` label every metric cell in
  the run HUD at 9pt. Apple's guidance floor is 11pt, and this is the screen read
  at arm's length, in motion, outdoors.
- **`dynamicTypeSize` is never used** — 0 occurrences. So there is not even a
  deliberate clamp; scaling is simply absent.
- **`@ScaledMetric` is never used** — 0 occurrences. Icon sizes, circle diameters
  and row heights stay fixed even where the adjacent text is dynamic
  (`.font(.caption)` is used correctly 116 times), so those layouts will break
  before the fixed ones do.

`AppFonts.swift:24-31` states the intended rule: *"UI copy scales; HUD metrics
don't."* That rule is right. The code does not implement it — the `metric*`
tokens (correctly fixed) are used 12 times, while UI copy that should scale uses
raw fixed sizes 296 times.

🟠 **PARTIALLY FIXED** — the sub-floor sizes are gone: the run HUD's 9pt metric
captions now use a new fixed `Font.metricLabel` (11pt, Apple's floor) and the pace
meter's 10pt scale labels moved to 11pt (`AppFonts.swift`, `ActiveRunView.swift`).
The 296-site migration onto `ds*` is still open and is the Tier 2 work.

**Fix.** Migrate per §1. Keep `metricHero`/`metricXL` fixed and add
`.dynamicTypeSize(...(.accessibility1))` clamps on the two fixed-height grids
that genuinely cannot reflow (the run HUD metric grid, the week calendar strip),
so everything else is free to scale. Add `@ScaledMetric` to the icon and avatar
sizes that sit beside scaling text.

---

## 3. Colour contrast fails WCAG AA across the palette 🔴

Computed from the asset catalog. WCAG AA needs **4.5:1** for body text, **3.0:1**
for large text (≥18pt, or ≥14pt bold).

### 3a. White-on-brand — the app's primary CTA

| Fill | Mode | White text | Verdict |
| --- | --- | --- | --- |
| `Brand` #FF6B22 | light | **2.84** | fails even the large-text 3.0 bar |
| `Brand` #FF7F37 | dark | **2.52** | fails |
| `ZoneTempo` #FF9F0A | light | **2.05** | fails badly |
| `ZoneEasy` #32ADE6 | light | **2.55** | fails |
| `Success` #34C759 | light | **2.22** | fails |
| `ZoneRecovery` #007AFF | light | 4.02 | large text only |
| `ZoneMax` #D70015 | light | 5.39 | ✅ passes |

Every one of these fills passes comfortably with **black** text (7.4–11.1). The
palette is a light/vivid palette being used as if it were dark.

`DashboardView.swift:577` and `:684` put white 17pt-bold on `Color.brand` — the
two most-tapped buttons in the app, at 2.84:1.

✅ **FIXED** — a new `Color.onFill` token (`OnFill.colorset`, near-black; pure black
under Increase Contrast) is now the foreground on every solid `brand`/`success`
fill: both Dashboard CTAs, the four onboarding CTAs, the coach Load/Refresh and
ask-bar buttons, Route Genius' two save buttons, both strength buttons, the missed-
workout button, the race-tips numerals, and the plan week markers. 6.5–9:1.

### 3b. The Active Run HUD is the worst offender

The HUD dims white to 55–85% over a saturated zone-coloured gradient
(`ActiveRunView.swift:435, 440, 464, 308, 272`):

| Zone background | white@0.55 (9pt labels) | white@0.65 (units) | white@0.85 (captions) |
| --- | --- | --- | --- |
| ZoneTempo | **1.47** | 1.59 | 1.84 |
| ZoneEasy | **1.68** | 1.85 | 2.23 |
| ZoneMarathon | **1.70** | 1.87 | 2.25 |
| ZoneInterval | 1.91 | 2.19 | 2.90 |
| ZoneMax | 2.26 | 2.76 | 4.09 |
| ZoneRecovery | 2.18 | 2.51 | 3.31 |

Nothing on that screen except the hero pace clears 4.5:1, and the metric labels
sit at 1.47–2.26:1. In direct sunlight — the actual usage condition — these are
unreadable. This is the single highest-impact accessibility fix in the app.

✅ **FIXED** — `ActiveRunView.swift`: the gradient's three stops are now mixed with
black by 0.40/0.56/0.72 (the top stop was the raw zone colour), and every dimmed
label went to 0.92–0.95 white. White clears 4.5:1 even on the lightest zone.

### 3c. Two pace zones collapse in dark mode 🔴

Duplicate hex values in the catalog:

```
dark  #40C8E0: ZoneEasy, ZoneMarathon      ← distinct training zones
dark  #FF453A: ZoneInterval, ZoneMax       ← distinct training zones
```

Pace zones are the app's core visual language — the HUD background, the calendar
dots, the split charts and `PaceZoneIndicator` all encode zone as colour. In dark
mode the six-zone system renders as four. A runner cannot distinguish an easy
from a marathon-pace segment, or an interval from a max effort.

(`Destructive`/`ZoneInterval` and `Warning`/`ZoneTempo` also share values, but
those are semantic aliases that never co-occur, so they're harmless.)

✅ **FIXED** — `ZoneEasy` dark is now Apple's system-cyan dark (`#64D2FF`) and
`ZoneMarathon` moved to a green-side teal in both modes (`#12A594`/`#34D6C8`), so
the two never converge. `ZoneMax` dark is a deep crimson (`#C70A1E`), keeping the
same deeper-than-interval relationship it already had in light mode.

### 3d. No high-contrast variants

No colorset defines a `contrast: high` appearance, and
`\.colorSchemeContrast` / `\.accessibilityDifferentiateWithoutColor` appear
**0 times** in the codebase. The system Increase Contrast setting therefore does
nothing in Stride.

🟠 **PARTIALLY FIXED** — every brand, zone and semantic colorset now carries
`contrast: high` variants for both appearances. The light-mode high-contrast values
for the fills that carry `onFill` text are solved to clear 4.5:1 *both* as tinted
text on a white surface and as a fill behind black text. `accessibilityDifferentiate\
WithoutColor` is still unhandled — the zone system remains colour-only.

**Fix.**
1. Give `ZoneMarathon` and `ZoneMax` genuinely distinct dark variants.
2. Switch white-on-fill to black-on-fill for `Brand`, `ZoneTempo`, `ZoneEasy`,
   `Success`, `Warning` — or darken those fills for text-bearing surfaces.
3. On the HUD, raise dimmed labels to ≥0.85 white and darken the gradient's upper
   stop; the current top stop is the raw zone colour at full luminance.
4. Add `contrast: high` variants for the brand and zone sets.
5. Add `@Environment(\.accessibilityDifferentiateWithoutColor)` handling so the
   zone system carries a shape/label fallback, not colour alone.

---

## 4. Zero haptics in a heads-down app 🔴

`sensoryFeedback`, `UIImpactFeedbackGenerator`, `UINotificationFeedbackGenerator`,
`CoreHaptics` — **0 occurrences, all of them.**

For a running app this is a category-level omission, not a polish item. The
entire point of the Active Run screen is that the runner *isn't looking at it*.
Every competing app confirms state changes through the wrist/pocket:

| Event | Site | Suggested feedback |
| --- | --- | --- |
| Run start | `ActiveRunView.swift:506` | `.impact(weight: .heavy)` |
| Pause / resume | `:490, :498` | `.selection` |
| Finish confirmed | `:151` | `.success` |
| Save failed | `:667` | `.error` |
| Guided-workout segment change | `GuidedWorkoutBanner.swift` | `.impact` — currently silent, so an interval transition is *invisible* mid-run |
| Split / km milestone | `WorkoutTrackerService` | `.impact(weight: .light)` |
| Set completed | `StrengthActiveView.swift` | `.selection` |
| Rest countdown expiry | `RestCountdown.swift` | `.success` |

The guided-workout case is the most serious: `GuidedWorkoutEngine` steps a runner
through structured intervals, and the only signal that a segment changed is a
banner they'd have to be watching to see.

✅ **FIXED** — `ActiveRunView.swift` carries four `sensoryFeedback` modifiers: run
state (heavy impact on start, selection on pause/resume, success on finish), error
on a failed save, light impact per split, and heavy impact on a guided-workout step
change. `StrengthActiveView.swift` adds selection on a logged set and success on
rest-timer expiry. No UIKit generators.

**Fix.** Use the modern declarative API, per current guidance:
`.sensoryFeedback(.impact, trigger: tracker.trackingState)`. No UIKit generators.

**Related:** there is also no **audio** channel — no `AVSpeechSynthesizer`, no
`AVAudioSession`. Spoken split announcements ("kilometre 5, 4:32, on pace") are
the standard solution for the same heads-down problem and would reuse the
existing `SpokenMetric` formatting.

---

## 5. Active Run is missing the platform integrations the screen implies

Beyond haptics, three absences stand out:

**5a. The screen sleeps mid-run.** `isIdleTimerDisabled` appears **0 times**. On
default settings the display sleeps after 30 seconds, so the HUD — hero pace,
zone colour, pace meter, guided-workout banner — goes black while the runner is
running. Everything the screen is for stops working almost immediately.
*Fix:* set `UIApplication.shared.isIdleTimerDisabled = true` while
`trackingState` is `.active`/`.paused`, and clear it on finish/discard.
✅ **FIXED** — `ActiveRunView.swift`, via `onChange(of: tracker.trackingState)`
plus an `onDisappear` release.

**5b. No Live Activity.** `ActivityKit`, `WidgetKit`, `DynamicIsland` — **0
occurrences**; `project.yml` declares no widget extension. On an iOS 27 target,
a run in progress with no Lock Screen or Dynamic Island presence means checking
pace requires a full unlock. This is the highest-value *feature* gap the review
found, and the tracker already publishes everything the activity would need.

**5c. GPS quality is computed and thrown away.** `LocationQualityFilter` grades
every fix and `WorkoutTrackerService.swift:68` counts discards by reason — but
nothing surfaces it. A runner under tree cover or between buildings sees a
plausible-looking pace with no indication the signal is poor. A small
accuracy indicator in the top bar would close it. (The top bar has room: the
decorative "Lock" pill was removed there under N18.)

**5d. Hardcoded safe-area padding.** `ActiveRunView.swift:208` uses
`.padding(.top, 56)` on a `VStack` that already respects the safe area, so the
top bar sits ~56pt below the inset on every device regardless of hardware. Use
the safe area or `safeAreaPadding`.
✅ **FIXED** — reduced to a 12pt gap inside the safe area (`ActiveRunView.swift`).

---

## 6. Destructive actions are inconsistently guarded 🟠

The same operation asks for confirmation in one place and not in another:

| Action | Confirmed? | Site |
| --- | --- | --- |
| Delete a run, from its summary | ✅ dialog | `RunSummaryView.swift:344` |
| Delete a run, by swipe in History | ❌ **none** | `HistoryView.swift:153` |
| Delete a plan, from its detail | ✅ dialog | `PlanDetailView.swift:50` |
| Delete a plan, by swipe in the list | ❌ **none** | `TrainingPlanListView.swift:65` |
| Delete a saved route | ✅ dialog | `SavedRoutesView.swift:44` |
| Discard an active run | ✅ dialog | `ActiveRunView.swift:150` |
| Reset all data | ✅ dialog | `SettingsView.swift:79` |

Swipe-to-delete on a *run* is permanent and also writes a `DeletedWorkout`
tombstone, so the run will not come back on the next HealthKit sync — it is less
recoverable than the confirmed path, not more. Swipe-to-delete on a *plan*
cascades to scheduled workouts, Watch entries and reminders
(`container.deletePlan`).

Both deletes also swallow failures: `HistoryView.swift:206, 208` use
`try? container.workoutRepository.delete(...)`, so a failed delete leaves the row
on screen with no explanation.

**Fix.** Either add confirmation to the two swipe paths, or — better for a list —
keep the swipe immediate and add undo, which is the platform-idiomatic answer to
"destructive but frequent". At minimum, stop discarding the error.

✅ **FIXED** — both swipe paths now confirm before deleting. `HistoryView.swift`
holds the swiped offsets in `pendingDeletion` and asks first, and its delete is a
real `do/catch` that logs and raises an alert instead of a `try?` that dropped the
error. `TrainingPlanListView.swift` does the same, with a message naming what the
cascade takes (and what it keeps).

**Wider pattern:** `Stride/Features/` contains **38** `try?` expressions and only
**3** `.alert(` presentations (`ActiveRunView`, `DashboardView`,
`NewPlanOnboardingView`). Most failure paths in the UI layer are silent. Two of
those `try?`s are gone with the above; the pattern is otherwise untouched.

---

## 7. Zero adoption of iOS 26+ API on an iOS 27 target 🔴

`project.yml:6` sets `deploymentTarget: iOS "27.0"`. Adoption of post-iOS-17 API:

| API | Uses | | API | Uses |
| --- | --- | --- | --- | --- |
| `glassEffect` | 0 | | `tabViewBottomAccessory` | 0 |
| `GlassEffectContainer` | 0 | | `tabBarMinimizeBehavior` | 0 |
| `buttonStyle(.glass)` | 0 | | `scrollEdgeEffectStyle` | 0 |
| `ToolbarSpacer` | 0 | | `backgroundExtensionEffect` | 0 |
| `symbolEffect` | 0 | | `onGeometryChange` | 0 |
| `scrollPosition` | 0 | | `containerRelativeFrame` | 0 |
| `visualEffect` | 0 | | `presentationSizing` | 0 |

🟠 **PARTIALLY FIXED** — `MainTabView.swift` now uses the `Tab` builder, and the
hand-rolled `Color.mix` is gone in favour of the native perceptual one. Glass,
`tabViewBottomAccessory` and the `GeometryReader` retirements are still open.

The app pays the full cost of a 27.0 floor (excluding every device below it) and
takes none of the benefit. Specifics worth acting on:

- **`MainTabView.swift:6-27` uses the legacy `.tabItem` API.** The `Tab` builder
  has been the correct form since iOS 18. Current guidance is explicit that
  mixing or retaining `.tabItem` on modern targets is wrong.
- **Glass is hand-rolled.** `ActiveRunView.swift:544-584` defines `glassPill` and
  `glassControlButton` that simulate glass with `.ultraThinMaterial` plus a
  manual `strokeBorder`. `.glassEffect(.regular, in: .capsule)` is the real
  thing, and — relevant to §3 — it handles Reduce Transparency and contrast
  adaptation automatically, which the hand-rolled version does not.
- **`tabViewBottomAccessory` is tailor-made for this app.** A run in progress
  showing as a persistent accessory above the tab bar (the Now Playing pattern)
  would solve "I navigated away from my run" far better than a `fullScreenCover`.
- **12 `GeometryReader`s** remain where `onGeometryChange`, `visualEffect` or
  `containerRelativeFrame` now apply. `GeometryReader` forces greedy sizing and
  is the usual cause of surprising layout in `ScrollView`s.
- **`Color.mix` is reimplemented.** `ActiveRunView.swift:712-728` hand-rolls
  colour mixing through `UIColor`, dropping alpha and blending naively in sRGB.
  `Color.mix(with:by:in:)` has been native since iOS 18 and blends correctly.

---

## 8. History is thin for a log that grows forever 🟠

`HistoryView` is where a runner goes to find a specific run. It offers no way to
find one:

- **No `.searchable`** — 0 occurrences app-wide. After a season there are
  hundreds of rows and only reverse-chronological paging (20 at a time).
- **No filtering** by workout type, distance or date range.
- **No `.refreshable`** — 0 occurrences app-wide. HealthKit sync runs from
  `.task` (`HistoryView.swift:51`), which fires on the view's lifetime, not on
  each tab visit. A `TabView` keeps its children alive, so a runner who opens
  History, switches tabs, records a Watch run, and returns will not see it — and
  has no gesture to force a sync. Pull-to-refresh is the expected affordance and
  the sync function already exists.
- **First-launch shows a blank screen.** `HistoryView.swift:165` gates
  `ContentUnavailableView` on `entries.isEmpty && !isSyncing`, so during the
  initial sync the user sees an empty list with only a 0.8×-scaled toolbar
  spinner. Show a loading state, or let the empty state carry the spinner.
- **Fragile pace formatting.** `HistoryView.swift:272-274` strips units by
  `replacingOccurrences(of: " min/km", ...)`. `paceValueString(unit:)` already
  returns exactly this and is used in `ActiveRunView.swift:376`. The string
  surgery breaks the moment the app is localized.

✅ **FIXED** — `HistoryView.swift` gains `.searchable` (matching workout type by its
*localized* name, resolved to raw values before the fetch predicate, plus run notes
and the strength focus), `.refreshable` on the canonical importer, a first-sync
loading state and a no-results state in place of the blank list, and the pace column
now calls `paceValueString(unit:)` directly. A dedicated distance/date-range filter
is still open — search covers the type case.

---

## 9. Performance: the D6 query fix stopped short

`APP_ANALYSIS_2026-07-24.md`'s D6 bounded the unbounded `@Query`s in
`DashboardView` (60-run limit) and `HistoryView` (paged). Three screens were
missed and still fetch **every run ever logged** on every render:

- `ProgressView.swift:6`
- `AchievementsView.swift:20`
- `RaceInsightsView.swift:7`

These are the *charting* screens, so they also recompute derived series over the
full set on each pass. `ProgressView` already has a `selectedRange` picker
(`.threeMonths` default) — the fetch should honour it via a date predicate rather
than fetching everything and filtering in `filteredWorkouts` (`:60`).

✅ **FIXED**, two by bounding and one by a different route:

- `ProgressView` fetches a date-predicated window of the widest range its picker can
  ask for (1Y) plus a week of slack, built in a new `init()` since a `@Query`'s
  descriptor is fixed at view-initialisation.
- `RaceInsightsView` is bounded to a year — far more than its widest read, which is
  `WorkoutAnalyticsService`'s eight-week trend lookback.
- `AchievementsView` is *deliberately* left unbounded and documented as such: its
  medals are all-time PRs and its badges count lifetime distance and the longest
  streak ever, so a window would silently redefine them. Its real cost was that
  `badgeSection` is called once per category and each call recomputed the full
  achievement set (which itself recomputes the streak) — the derivations are now
  computed once in `body` and passed down.

---

## 10. Smaller findings

- **Touch targets below 44pt.** ✅ **FIXED** — the week-calendar chevrons are
  44×44 with an explicit `contentShape` (the glyph is unchanged). The onboarding
  controls named here turned out *not* to be targets: the 22–32pt bar glyph and
  `OBRadio` are decorative parts inside full-width row `Button`s, so the tappable
  area was always well over 44pt. `OBRadio`'s white check moved to `onFill`.
- **Onboarding is 9 steps** (`OnboardingView.swift:148-221`: steps 0–8) before
  the app is usable. Steps 3 (Units) and 4 (About you) could merge, and Units has
  a sensible locale-derived default that needs no prompt.
- **`ProgressRingView` has no accessibility label** ✅ **FIXED** —
  `.accessibilityHidden(true)`, since the adjacent `statItem` already speaks the
  number.
- **The weekly load chart is invisible to VoiceOver.** ✅ **FIXED** — the bar
  tuples became a named `WeeklyLoadDay` carrying each day's label and distance, and
  the strip now speaks through `chartAccessibility` like every other chart. Days
  still to come are omitted rather than spoken as zero.
- **Charts collapse rather than describe.** `chartAccessibility` merges each
  chart into one element with a summary sentence. That's a solid pragmatic
  choice, but `.accessibilityChartDescriptor(_:)` (`AXChartDescriptor`) would
  additionally enable **Audio Graphs**, letting a VoiceOver user play the series
  as sound and navigate point-by-point. Worth it for the Progress tab.
- **Redundant computation.** ✅ **FIXED** — the ring takes `pct`; `pct2` is gone.
- **`BouncyButtonStyle` is defined and used 7 times**, while most buttons use
  `.buttonStyle(.plain)` and get no press feedback at all — including both
  primary CTAs.
- ~~**Legacy state management.**~~ **Not a finding** — checked while doing the
  above: `AppContainer` (`AppContainer.swift:20`) and `WorkoutTrackerService`
  (`WorkoutTrackerService.swift:33`) are both already `@Observable`, and both carry
  comments explaining the migration off `ObservableObject` (D4). There is no
  holdout left to migrate.

---

## Recommended order of work

**Tier 1 — accessibility and the run experience (ship first)** — ✅ **DONE**
1. ✅ Contrast: dark-mode zone collisions, white-on-brand CTAs, HUD label opacity (§3)
2. ✅ `isIdleTimerDisabled` during an active run (§5a) — one line, restores the whole screen
3. ✅ `.sensoryFeedback` on run/pause/finish/segment/set (§4)
4. ✅ Confirmation or undo on the two unguarded swipe-deletes (§6)

**Tier 2 — the systemic typography fix** — the next pass
5. Migrate 296 fixed sizes onto `ds*`, add `@ScaledMetric`, clamp the two fixed grids (§1, §2)
6. Add SwiftLint rules so it holds

**Tier 3 — platform conformance**
7. 🟠 `Tab` API ✅, native `Color.mix` ✅; `glassEffect` and the `GeometryReader`
   retirements still open (§7)
8. ✅ `.searchable` + `.refreshable` on History (§8)
9. ✅ Bound the three remaining unbounded queries (§9)

**Tier 4 — features the platform now expects**
10. Live Activity / Dynamic Island for an in-progress run (§5b)
11. Spoken split announcements (§4)
12. `tabViewBottomAccessory` for the active run (§7)

---

## What's working well

Worth stating plainly, because the failures above are systemic rather than a sign
of low care:

- **The N18/D8 VoiceOver pass is genuinely good.** Metric cells merge into
  labelled pairs, calendar days speak their full schedule, charts carry summary
  sentences, and decorative elements that read as controls were *removed* rather
  than papered over. `ChartAccessibility.summary` is a well-designed abstraction.
- **Error recovery in the run-save path is better than most shipping apps.**
  `pendingSave` + retry + explicit discard (`ActiveRunView.swift:588-698`) is the
  right model, and the race-day clamp notice (`DashboardView.swift:766-780`)
  explains a partial success instead of silently doing less than promised.
- **Empty states are specific.** The N23 work splitting "nothing scheduled" into
  rest day / outside plan / no plan is exactly the right instinct.
- **Reduce Motion is respected throughout** via `adaptiveAnimation`, including
  the repeating pulse animations.
- **The code comments are unusually good** — nearly every non-obvious decision
  cites the bug that motivated it, which made this review far faster than it
  would otherwise have been.
