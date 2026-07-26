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
| Design-system adoption | 🟢 Fixed | ✅ Type, radius and elevation/glow adopted and guarded; spacing adopted for exact matches |
| Dynamic Type | 🟢 Fixed | ✅ 262 sites on `ds*`, `@ScaledMetric` on badges, 2 grids clamped |
| Colour contrast | 🟢 Fixed | ✅ CTAs, HUD, dark-mode zone collisions, high-contrast variants |
| Haptics and audio | 🟢 Fixed | ✅ `sensoryFeedback` on run, guided steps, splits, strength sets; ✅ spoken splits |
| iOS 26/27 API adoption | 🟢 Fixed | ✅ `Tab` builder, native `Color.mix`, real `glassEffect`, `tabViewBottomAccessory` + `tabBarMinimizeBehavior`, Live Activity / Dynamic Island |
| Destructive-action safety | 🟢 Fixed | ✅ Both swipe paths confirm; delete failures surface |
| History discoverability | 🟢 Fixed | ✅ Search, pull-to-refresh, first-sync loading state, date/distance filter |
| Onboarding length | 🟢 Fixed | ✅ 8 steps, not 9 — units follow the locale and moved onto "About you" |

**Pass 1 (2026-07-26) closed:** the whole of Tier 1, plus §5a, §5d, §8, §9 and most
of §10. **Pass 2** closed Tier 2 — the type-scale migration and the SwiftLint rule
that holds it. **Pass 3** closed the rest of Tier 3 and the §1 remainder: the radius
and elevation scales are adopted and guarded, the hand-rolled glass is now
`glassEffect`, GPS quality reaches the runner (§5c), and Differentiate Without Color
is handled (§3d). **Pass 4** closed the audio channel (spoken splits, §4), History's
date/distance filter (§8), and the whole of the §10 remainder — the onboarding step
merge, Audio Graph descriptors, and press feedback on the two primary CTAs. **Pass 5**
took the tab-bar restructure: the run HUD is presented by `MainTabView` and minimises
into `tabViewBottomAccessory`, so a run no longer has to be *ended* to leave its screen
(§7, Tier 4 #12). **Pass 6** took the last three: the Live Activity (§5b, a new
`StrideWidgets` extension target), the `GeometryReader` retirements (§7) and the spacing
scale (§1) — the two of those the audit asked to be settled per site rather than swept,
which is how they were settled.

**Nothing in this document is open.** Two items were closed by *decision* rather than by
code, and both say so where they live: seven of the twelve `GeometryReader`s stay, because
`visualEffect` and `onGeometryChange` can move a view and not size one; and the spacing
scale is adopted only where a literal already equalled a token, because snapping the rest
is a density redesign that needs a device. Anything future work should not assume is called
out at the site rather than left implied.

The blocked items in [`APP_ANALYSIS_2026-07-24.md`](APP_ANALYSIS_2026-07-24.md) are
untouched and still blocked: the CI toolchain pins need a run that reaches the test job,
and `.externalStorage` needs a migration exercised on hardware.

---

## 1. The design system is defined but not adopted

`Stride/Shared/Theme/` defines five token scales. Three of them have **zero call
sites outside their own file**:

| Scale | Defined in | Uses outside `Shared/Theme/` | After passes 2–3 |
| --- | --- | --- | --- |
| Type (`ds*`) | `AppFonts.swift:59-83` | **0** | 262 ✅ |
| Elevation (`appShadow` / `AppElevation`) | `AppElevation.swift` | **0** | 5 + 19 on the new `AppGlow` ✅ |
| Radius (`AppRadius`) | `AppRadius.swift` | 4 | 212 ✅ |
| Spacing (`AppSpacing`) | `AppSpacing.swift` | 18 | 228 ✅ (exact matches; see below) |
| Animation (`AppAnimation`) | `AppAnimations.swift` | widely used ✅ | ✅ |

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

✅ **FIXED** for the three dead scales — type, radius and elevation are all adopted
and guarded.

**Spacing** ✅ **closed in pass 6, on different terms from the others.** The radius
migration snapped all 208 literals to their nearest token; spacing is deliberately *not*
migrated that way, because a corner radius moving 2pt is decorative while a padding moving
2pt is a density change on every card in the app at once — and that judgement cannot be
made without looking at the result.

So the rule is **exact matches only**: every literal that already *was* a token value now
names the token — 207 sites across 33 files, a provably zero-pixel change — and the 146
that sit off the 4pt grid stay as literals. Two values account for 56 of those on their
own (14 × 41, 18 × 15), and deciding whether each is a 12, a 16, or a deliberate one-off
is a design pass with a device in hand.

Two things follow, and both are written into `AppSpacing.swift` so the next reader does
not have to rediscover them: re-pointing a token now moves the sites that name it and
leaves the equal-valued literals behind, and there is **no SwiftLint rule** guarding this
scale — unlike `no_fixed_font_size` and `no_raw_corner_radius` — because a raw padding is
still a legitimate thing to write. That asymmetry is the honest state of the scale, not an
oversight.

**Radius.** The design call this was waiting on: *adopt the scale as it stands rather
than redesign it around the literals.* Re-pointing the tokens at the two most common
literals (18 and 22) would have silently changed the four existing `AppRadius` call
sites and discarded the values the design system shipped, so all 208 literals snapped
to their nearest token instead — `1–4 → micro` (a new token for chart-bar caps, where
6 would round the element away), `8 → xs`, `10 → sm`, `12/14/16 → md`, `18/20 → lg`,
`22 → xl`. Nothing moves more than 2pt except the four 22pt floating surfaces. The two
dominant card radii land exactly where `AchievementsView` had already used the tokens
by hand, so the app's rhythm is preserved. The mapping table lives in `AppRadius.swift`.

**Elevation.** The reason this scale had no call sites turned out to be a real gap,
not neglect: **19 of the 26 inline shadows were brand-coloured glows, not elevation.**
A glow says "tap this"; elevation says "this is above the page", and a neutral scale
cannot express the first — so every CTA hand-rolled its own. `AppGlow`
(`.halo/.subtle/.standard/.strong`, applied as `.appGlow(_:color:isActive:)`) closes
that gap and takes all 19. Of the remaining seven, five were genuine elevation and
moved to `.appShadow(.e1/.e2/.e3)`; `e1` and `e2` were retuned to the shadows those
sites actually needed, which cost nothing because both levels had zero call sites. One
was a no-op (`radius: 0` at zero offset, drawing the shape behind itself) and is gone.

Four stay inline, in `ActiveRunView`: they separate white type and white controls from
a saturated full-bleed gradient, which is legibility rather than height. Documented at
the call site and excluded from the rule.

**Guards.** `.swiftlint.yml` gains `no_raw_corner_radius` and `no_inline_shadow`
alongside `no_fixed_font_size`, each with the narrow exclusions above.

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

✅ **FIXED.**

- **262 call sites** moved onto the `ds*` scale, snapped to the nearest text style
  (17 → `dsHeadline`/`dsBody` by weight, 15/14 → `dsSubhead`, 13 → `dsFootnote`,
  12 → `dsCaption`, 9–11 → a new `dsCaption2`). Monospaced faces keep their design
  via `.monospaced()`; the one rounded face uses `system(_:design:weight:)`, which is
  also a text style and also scales.
- **The sub-floor sizes are gone.** The run HUD's 9pt captions use a new fixed
  `Font.metricLabel` at Apple's 11pt floor, and the pace meter's 10pt labels moved
  to 11pt.
- **`@ScaledMetric` is now used** (it was 0) on the seven symbol-in-circle pairs
  where a fixed diameter would have been outgrown by scaling type: the streak,
  badge and medal glyphs, the strength exercise badge and completion mark, the
  weather glyph, the run summary's 56pt hero number, and the Settings avatar. Each
  pair derives the glyph from the container so the ratio holds at every size.
- **`dynamicTypeSize` is now used** (it was 0) on exactly the two layouts §2 names
  as unable to reflow: the run HUD metric grid and the week calendar strip, both
  clamped at `.accessibility1`.
- **A SwiftLint rule keeps it done.** `no_fixed_font_size` fails the build on a
  literal `.font(.system(size: 12…))`. A size derived from a `@ScaledMetric` or a
  caller's parameter still passes, and the five files where a fixed size *is* the
  point are excluded by path: `AppFonts` itself, the two Active Run HUD files, the
  share card (it renders a fixed-size PNG), and `StrideIcon`.

What stays fixed, deliberately: the Active Run HUD and `RunShareCardView`.

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

✅ **FIXED.** Every brand, zone and semantic colorset now carries `contrast: high`
variants for both appearances. The light-mode high-contrast values for the fills that
carry `onFill` text are solved to clear 4.5:1 *both* as tinted text on a white surface
and as a fill behind black text.

`accessibilityDifferentiateWithoutColor` is now handled too (pass 3). Auditing the
zone system for colour-*only* encoding found one site rather than the four this
section assumed: `PaceZoneIndicator` already pairs the colour with the zone's glyph
and its name, the HUD background sits under a zone label carrying both, the split
chart encodes faster/slower as bars rising above or hanging below the average rule
(and names the delta in its tooltip), and `PaceRow` labels every zone in text. The
exception was the dashboard week strip, where workout type was a 6×6 coloured dot and
nothing else — a tempo day and an interval day were the same shape. `DayCell` now
reads the environment value and swaps the dot for the type's own glyph, keeping the
colour, since the setting means "don't rely on colour alone", not "remove colour".

**Fix.** All five are now done — 1–4 in pass 1, 5 in pass 3.
1. ✅ Give `ZoneMarathon` and `ZoneMax` genuinely distinct dark variants.
2. ✅ Switch white-on-fill to black-on-fill for `Brand`, `ZoneTempo`, `ZoneEasy`,
   `Success`, `Warning` — or darken those fills for text-bearing surfaces.
3. ✅ On the HUD, raise dimmed labels to ≥0.85 white and darken the gradient's upper
   stop; the current top stop is the raw zone colour at full luminance.
4. ✅ Add `contrast: high` variants for the brand and zone sets.
5. ✅ Add `@Environment(\.accessibilityDifferentiateWithoutColor)` handling so the
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

✅ **FIXED** — `SplitAnnouncement` builds the sentence out of `SpokenMetric`, so a
spoken pace says "minutes per kilometre" rather than "slash km", and `RunVoiceCoach`
speaks it. The pace verdict is the part worth knowing about: a split is judged against
the guided step's target pace if the run is guided, else the scheduled workout's target
range, and the delta is reported in *seconds per display unit* — an imperial runner
hears the number they would get by differencing the paces they can see. The band is
widened by 8 s/km, matching `WorkoutPaceAlert`'s tolerance so the phone and a scheduled
Watch workout agree on what counts as on pace; inside a single kilometre GPS pace is not
accurate to the second, and "2 seconds slow" would be correcting the noise. A free run
has no target and hears the milestone and pace alone. Eleven tests in
`SplitAnnouncementTests`.

Four decisions worth recording:

- **Off by default** (`AppSettings.spokenSplitsEnabled`, with a Settings row that says
  what it will do). This is the only feature in the app that talks over whatever the
  runner is already playing, and one that starts speaking unasked after an update is a
  surprise rather than a coach.
- **The session ducks rather than interrupts** — `.playback` / `.voicePrompt` with
  `.duckOthers` and `.interruptSpokenAudioAndMixWithOthers`, activated per utterance and
  released on `didFinish` with `.notifyOthersOnDeactivation`. Music dips; a podcast (which
  cannot usefully be ducked — you would miss the words) pauses and resumes. A session left
  active would hold the duck for the rest of the run, so `RunVoiceCoach` is owned by
  `AppContainer` and stopped in the HUD's `onDisappear`.
- **`audio` joins `UIBackgroundModes`** in `project.yml`. A runner locks the phone and
  pockets it, so by the time a split closes the app is in the background — which is
  exactly the case the announcement exists for, and where the session could not otherwise
  be activated at all.
- **Announcements are dropped, not queued,** while one is speaking: a backlog read out at
  km 6 is worse than silence.

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

✅ **FIXED in pass 6.** `StrideWidgets` is a new `app-extension` target in `project.yml`
— an `ActivityConfiguration` can only be declared by an extension, which is why this was
the one item here that needed a build target rather than a file. It shows the run on the
Lock Screen and in the Dynamic Island (compact, expanded and minimal), and the design
decisions worth knowing are these:

- **The elapsed clock is not pushed.** Every presentation renders
  `Text(timerInterval:pauseTime:countsDown:)`, so the *system* counts the seconds and the
  app sends nothing for them. Pausing is one push that sets `pauseTime`, not a stream. The
  interval is derived backwards from the tracker's elapsed time, which is what lets an
  activity started or refreshed mid-run still show the right number
  (`RunActivityContentTests`).
- **Distance and pace are pushed as preformatted strings**, every 5 seconds, with pause and
  resume jumping the queue. The app owns unit preference and every formatter in this repo,
  so shipping "5.4 km" rather than `5400` keeps the widget from needing either — and keeps
  the Lock Screen agreeing with the HUD by construction rather than by two implementations
  rounding the same way.
- **It is driven by the tracker, not by a view.** The case a Live Activity exists for is a
  locked phone, and SwiftUI does not update a backgrounded view; `WorkoutTrackerService`'s
  one-second timer is the only pulse in the app that keeps running there. The tracker's
  dependency is on three verbs (`RunActivityPresenting`), not on ActivityKit.
- **Tapping the card lands on the run**, via `stride://active-run` and the URL scheme this
  added — which matters more since §7, because the run may be minimised behind any tab.
- **An app killed mid-run** leaves a card with nothing behind it to update or end, so
  `endActivitiesFromPreviousLaunches()` takes it down on the next launch rather than
  letting it go stale on screen.

The same pass closed what pass 5 left behind: the per-split haptic and the spoken
announcement were modifiers on the HUD, so they stopped when a run was minimised. They are
now one `RunSplitFeedback` modifier applied by both the HUD and `MainTabView` with
`isActive` making the two mutually exclusive — so a split is felt and heard exactly once,
whichever of the two is on screen. Deliberately *not* applied once high up: whether
`sensoryFeedback` fires for a view underneath a `fullScreenCover` is undocumented, and
finding out by losing the HUD's split haptic would be a regression in a shipped feature.

**Not covered, and worth stating:** `.frequentUpdates`, push-token updates (this is a local
activity only), and any interactive `Button`/`Toggle` in the card via App Intents. Pause and
resume are still tap-through-to-the-app.

**5c. GPS quality is computed and thrown away.** `LocationQualityFilter` grades
every fix and `WorkoutTrackerService.swift:68` counts discards by reason — but
nothing surfaces it. A runner under tree cover or between buildings sees a
plausible-looking pace with no indication the signal is poor. A small
accuracy indicator in the top bar would close it. (The top bar has room: the
decorative "Lock" pill was removed there under N18.)
✅ **FIXED** — `LocationQualityFilter.signalQuality(forHorizontalAccuracy:)` grades
the same reading the accept/reject decision already uses into strong/fair/weak, the
tracker publishes it as `gpsSignal` on *every* delivered fix (including the rejected
ones — those are the ones worth knowing about), and `ActiveRunView` draws it as a
three-bar glass pill in the space the Lock pill vacated. The fair/weak boundary is the
filter's own accuracy ceiling, so "weak" means "fixes are being discarded and distance
is being under-counted", not merely "imprecise" — and the weak state adds the words
"Weak GPS", because it is the one state a runner can act on. Quality is carried by
filled bar *count*, so it survives Differentiate Without Color (§3d) and a monochrome
glance. Graded by accuracy alone, deliberately: staleness and out-of-order fixes
describe the delivery path, not reception, and a runner cannot act on either. Covered
by four tests in `LocationQualityFilterTests`.

Still absent before the run starts: location updates only begin at `startWorkout`, so
there is no "acquiring signal" state on the idle screen. Fixing that means starting
the location manager earlier, which is a battery and permissions decision rather than
a UI one.

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
| `glassEffect` | 0 → ✅ | | `tabViewBottomAccessory` | 0 → ✅ |
| `GlassEffectContainer` | 0 | | `tabBarMinimizeBehavior` | 0 → ✅ |
| `buttonStyle(.glass)` | 0 | | `scrollEdgeEffectStyle` | 0 |
| `ToolbarSpacer` | 0 | | `backgroundExtensionEffect` | 0 |
| `symbolEffect` | 0 | | `onGeometryChange` | 0 |
| `scrollPosition` | 0 | | `containerRelativeFrame` | 0 |
| `visualEffect` | 0 | | `presentationSizing` | 0 |

🟠 **PARTIALLY FIXED** — `MainTabView.swift` now uses the `Tab` builder, the
hand-rolled `Color.mix` is gone in favour of the native perceptual one, the simulated
glass is now real (pass 3), and the active run minimises into `tabViewBottomAccessory`
(pass 5). The Live Activity and the `GeometryReader` retirements are still open.

On the accessory: this was filed as a Tier 4 *feature*, and turned out to also close a
plain bug. The HUD was a `fullScreenCover` with **no close control at all** — Finish and
Discard were the only ways off it — so a run opened by mistake had to be saved or thrown
away, and a runner mid-tempo could not look at their plan without ending the session.
The cover moved to `MainTabView`, which is what makes minimising possible at all: a
cover owned by the Home tab covers the accessory that offers the way back.

That move meant the run had to outlive the screen showing it, so the two things a run
remembers that `WorkoutTrackerService` does not — the `ScheduledWorkout` it fulfils and
the guided stepper's position — moved out of `@State` into `ActiveRunPresentation`
(`ActiveRunPresentationTests`). Dismissing a cover destroys the view inside it, so the
stepper in particular had to move or reopening a structured session would have put a
runner three intervals in back on step 1; `prepareForAppearance` now has to be safe to
repeat mid-run, which it is (`prepareForNewWorkout` only acts on a finished tracker,
`setLocation` only on an idle one). Three smaller consequences of the run outliving its
screen, each handled rather than left:

- The dashboard's start buttons stay tappable underneath a minimised run, so
  `startOrReopen` reopens the run instead of replacing the session, and the free-run
  button says **"Back to Your Run"** while one is recording.
- The session is torn down in `onDisappear` rather than in the finish/discard actions —
  the HUD is still on screen while the cover slides away, and clearing it any earlier
  pops the guided banner out from under it. `onDisappear` can tell minimising from
  ending, because a minimised run is still recording.
- The accessory carries pause/resume as well as the way back (the Now Playing shape),
  spells "Paused" out in words rather than leaving it to the glyph (§3d), and speaks a
  sentence to VoiceOver rather than "27:14 dot 5.4 k m" (`MinimizedRunSummaryTests`).

*Known remainder:* the split haptic and the spoken split announcement are still
modifiers on the HUD, so they pause while a run is minimised. Both belong with the Live
Activity work below, which is the item that has to answer "what does this run do when
its screen isn't there" in general.

`tabBarMinimizeBehavior(.onScrollDown)` went on at the same time, since it is the
behaviour the accessory is designed to sit alongside.

On glass: all five hand-rolled surfaces in the run flow — the zone pill, the top-bar
pills, the metric grid, the finish button and the guided-workout banner — dropped
`.ultraThinMaterial` plus a hand-drawn `strokeBorder` for `.glassEffect(.regular, in:)`.
That is the point of the change rather than a like-for-like swap: the material
imitation is inert, ignoring Reduce Transparency and Increase Contrast, which matters
most on exactly this screen (§3b). The finish button additionally takes
`.regular.interactive()`, giving it the press response the simulation never had.
`GlassEffectContainer` is deliberately not adopted yet — it earns its keep when glass
elements sit close enough to blend and morph, and these are spread across the screen.

The app pays the full cost of a 27.0 floor (excluding every device below it) and
takes none of the benefit. Specifics worth acting on:

- **`MainTabView.swift:6-27` uses the legacy `.tabItem` API.** The `Tab` builder
  has been the correct form since iOS 18. Current guidance is explicit that
  mixing or retaining `.tabItem` on modern targets is wrong.
- ~~**Glass is hand-rolled.**~~ ✅ Fixed in pass 3 — `glassPill`,
  `glassControlButton`, the zone pill, the metric grid and `GuidedWorkoutBanner` all
  use `.glassEffect` now. See the note above.
- ~~**`tabViewBottomAccessory` is tailor-made for this app.**~~ ✅ Fixed in pass 5 —
  a recording run shows as a persistent accessory above the tab bar (the Now Playing
  pattern) whenever the HUD is closed. See the note above; it was not only a missing
  API but a missing exit.
- **12 `GeometryReader`s** remain where `onGeometryChange`, `visualEffect` or
  `containerRelativeFrame` now apply. `GeometryReader` forces greedy sizing and
  is the usual cause of surprising layout in `ScrollView`s.

  ✅ **Closed in pass 6, per site rather than in a sweep** — which is what this entry
  asked for, and the answer turned out to be five retired and seven kept for reasons now
  recorded at each call site:

  | Site | Outcome |
  | --- | --- |
  | `OBWelcome` / `OBWelcomeBack` backgrounds | ✅ `EllipticalGradient` — its radii are fractions of the frame, so a glow sized `max(w, h) * 0.85` needs no measurement at all |
  | Onboarding step-chrome bar, "ready" chrome bar | ✅ `ProgressView(value:total:)` — both were the platform's own 4pt determinate track drawn by hand; `.accessibilityHidden(true)` because the "3/8" counter beside them says it |
  | `WeeklyLoadBar` (Dashboard) | ✅ full height, `scaleEffect(y:anchor: .bottom)`. The only casualty is a `micro` corner radius squashing with the bar — a fraction of a point |
  | HR-zone stacked bar (`RunSummaryView`) | Kept — five segments each need a measured *width*, and none of the three replacements sets a frame |
  | Run HUD zone gradient | Kept — `EllipticalGradient` would retire it, but it would move where the three stops land, and *that* is what the contrast audit measured (§3b). A re-tune, not a refactor |
  | Pace meter (Run HUD) | Kept — the marker's offset could move to `visualEffect`; the target band needs a width, so converting half would split one piece of geometry across two idioms |
  | Guided-workout progress bar | Kept — an 8pt capsule with a 6pt minimum fill on a zone gradient. `ProgressView` fits the onboarding bars because they already *were* a 4pt track; here it would redesign the run HUD |
  | Plan phase-progress bar | Kept — same shape as the pace meter: tick offsets could move, the fill's width cannot |
  | `ConfettiBurstView`, `StaticConfettiView` | Kept — each particle is positioned at a fraction of the *container*, and `visualEffect`'s proxy is the 5pt particle's own geometry |

  The through-line: `visualEffect` and `onGeometryChange` can move a view, not size one, so
  every bar that needs a measured width keeps its reader. All seven are wrapped in an
  explicit `.frame(height:)`, which is what makes the greedy-sizing objection theoretical at
  these particular sites — none of them is the layout bug this entry warns about.
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
now calls `paceValueString(unit:)` directly.

✅ **The filter is closed too** (pass 4) — `HistoryFilter` adds a date range (any / 30
days / 3 months / year) and a distance floor, driven from a toolbar `Menu` and applied
through the fetch descriptor the way `searchText` is, so a narrowed list is a narrower
*fetch* rather than a filtered page. Two decisions:

- **The distance thresholds are the four race distances the app already plans for** (5K,
  10K, half, marathon), not round numbers in the runner's unit. "At least a 10K" is a fact
  about the run rather than about how it is displayed, so nothing needs converting and an
  imperial runner is not offered a 5-mile filter no plan in the app has a concept of. Each
  sits ~2% below its nominal distance: a GPS trace of a 5K routinely measures 4.97 km, and
  a filter that hides it is wrong about what the runner did.
- **A distance floor excludes strength sessions outright** — they have no distance, so no
  floor can be true of one. Spelled out as `HistoryFilter.includesStrengthWorkouts` rather
  than left implicit at the merge. A date range keeps them; a session does have a date.

An active filter that matches nothing gets its own `ContentUnavailableView` naming both
axes and offering "Clear Filters" — otherwise it is indistinguishable from "no workouts
yet", and the control that caused it is a glyph in the toolbar. Covered by
`HistoryFilterTests`.

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
  ✅ **FIXED** — 8 steps. `UnitPreference.localeDefault` reads
  `Locale.current.measurementSystem`, so a new install starts on the unit the device
  already measures in (anything non-metric maps to miles: `.uk` measures road distance
  in miles, which is the only measurement this app makes). That turned the units *step*
  into a segmented control on "About you" — a correction rather than a question. The
  old default was the deeper bug: skipping the step silently gave every runner in the
  US kilometres.
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
  ✅ **FIXED** for all seven Progress-tab charts (the six on Stats plus the race-pace
  prediction on Insights). The mechanism matters more than the modifier: call sites used
  to hand `chartAccessibility` a finished summary *string*, which is why a descriptor
  could not be added without duplicating each chart's data. They now pass a
  `ChartAccessibility.Series` — the points, the value-axis name, and the formatter — and
  the modifier derives both the spoken summary and the `AXChartDescriptor` from it, so the
  two cannot describe different data. The x-axis is categorical, reusing the labels the
  summary already renders (a date, a split number, a zone); the series is
  `isContinuous: false` for the same reason. The `String` overload stays for the charts
  outside this tab.
- **Redundant computation.** ✅ **FIXED** — the ring takes `pct`; `pct2` is gone.
- **`BouncyButtonStyle` is defined and used 7 times**, while most buttons use
  `.buttonStyle(.plain)` and get no press feedback at all — including both
  primary CTAs.
  ✅ **FIXED** for the two CTAs ("Start a Free Run" and "Start This Workout"). Both
  needed their `.background` moved *inside* the button's label: the style scales
  `configuration.label`, so a background applied outside it would have held still while
  the text shrank inside a stationary pill. The remaining `.plain` buttons are rows and
  cards whose own selected/unselected state is the feedback.
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

**Tier 2 — the systemic typography fix** — ✅ **DONE**
5. ✅ Migrate 296 fixed sizes onto `ds*`, add `@ScaledMetric`, clamp the two fixed grids (§2)
6. ✅ Add a SwiftLint rule so it holds (`no_fixed_font_size`).

**Tier 3 — platform conformance** — ✅ **DONE** except the `GeometryReader`s
7. 🟠 `Tab` API ✅, native `Color.mix` ✅, `glassEffect` ✅; the `GeometryReader`
   retirements still open (§7)
8. ✅ `.searchable` + `.refreshable` on History (§8)
9. ✅ Bound the three remaining unbounded queries (§9)
9b. ✅ The radius and elevation scales adopted and guarded, `AppGlow` added (§1);
   GPS quality surfaced (§5c); Differentiate Without Color handled (§3d)

**Tier 4 — features the platform now expects** — ✅ **DONE**
10. ✅ Live Activity / Dynamic Island for an in-progress run (§5b) — `StrideWidgets`, a new
    `app-extension` target; the elapsed clock is counted by the system rather than pushed,
    and the tracker drives it because a locked phone is the case it exists for. It also
    closed pass 5's remainder: the split haptic and spoken split are `RunSplitFeedback`
    now, shared by the HUD and `MainTabView`, so they follow the run rather than the screen
11. ✅ Spoken split announcements (§4) — `SplitAnnouncement` + `RunVoiceCoach`, opt-in
12. ✅ `tabViewBottomAccessory` for the active run (§7) — the HUD is presented by
    `MainTabView` and minimises into the accessory, which also gave the screen the close
    control it never had. `ActiveRunPresentation` + `ActiveRunAccessory`,
    `MinimizedRunSummary`, `tabBarMinimizeBehavior(.onScrollDown)`

**Left over, smaller than a tier** — ✅ **DONE**
13. ✅ The `GeometryReader` retirements (§7) — five retired, seven kept with the reason
    recorded at each call site — and the spacing scale (§1), adopted for exact token
    matches only. Both per-site rather than a sweep, which is what the entries asked for
14. ✅ History's distance/date-range filter (§8)
15. ✅ Merging onboarding steps 3 and 4, `.accessibilityChartDescriptor` for Audio
    Graphs, and press feedback on the two primary CTAs (§10)

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
