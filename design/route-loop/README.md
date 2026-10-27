# Route Loop — Stride's design system

Stride's icon is a GPS loop with a start pin on a night map. The app speaks in the same
three things, and nothing else carries the brand:

| Element | What it is | In code |
| --- | --- | --- |
| **The route** | One stroke with round caps, amber where it starts and orange where it ends | `LinearGradient.route` (`.fill(.route)`, `.stroke(.route, …)`) |
| **The start pin** | A white disc with an orange centre | `StartPin(diameter:)` |
| **The map** | A faint square grid behind full-screen backdrops (welcome, onboarding) and the app mark: daylight paper in light, night ink in dark | `MapGridPattern`, `MapBackdrop` |

The live reference, with every token, type style and component, is the Design System
artifact *Stride Route Loop*. This file is the in-repo summary; the Swift sources under
`Stride/Shared/Theme/` and `Stride/Shared/Components/RouteLoop.swift` are the truth.

## Colour

Every colour is an asset-catalog colour with light, dark and Increase Contrast values
(`Stride/Resources/Assets.xcassets`), exposed as `Color.<name>` and `.<name>` in
`AppColors.swift`. The widget and Watch targets compile the same catalog.

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `brand` | `#FF5A1A` | `#FF7438` | The route's orange end. Accent, tint, glows, active states. As text only at 24pt+ or bold 19pt+ on light (3.1:1 on white); anything smaller uses Increase Contrast's `#C2410C`. |
| `brandGlow` | `#FFB36B` | `#FFBE7D` | The route's amber start. Only inside `LinearGradient.route` or as a highlight on `ink`; never text on a light surface. |
| `ink` | `#1F2433` | `#1F2433` | The icon's navy: the app mark and the share card only. Never a card on a light page. |
| `inkDeep` | `#0D1018` | `#0D1018` | Bottom of the ink gradient. |
| `onInk` / `onInkMuted` | `#F5F6FA` / `#A9AFC2` | same | Text on ink (share card): 14:1 and 7:1. |
| `brandText` | `#C2410C` | `#FF7438` | Orange *text*: eyebrows, links, inline figures. 4.7:1 on the page in light. |
| `heroTop` → `heroBottom` | `#FFEDE1` → `#FFFFFF` | `#232A3C` → `#171B26` | The hero card's gradient (`LinearGradient.heroGround`): warm dawn paper in light, raised ink in dark. |
| `cardStroke` | ink 8% | white 8% | The hairline on every card (`.strideCard()`) and hero. |
| `onFill` | `#17120E` | `#17120E` | Text and glyphs on `brand`, `route` and the light zone fills: 6.0:1 on `brand`, 10.5:1 on `brandGlow`. Never white on orange (3.1:1). |
| `mapGrid` | ink 6% | white 5% | Grid lines on page surfaces. On ink, `MapGridPattern(onInk: true)` draws white 5%. |
| `surfacePrimary` | `#F3F4F8` | `#0D1018` | Page background. Cool, faintly blue: the map's paper. |
| `surfaceSecondary` | `#FFFFFF` | `#171B26` | Cards on the page. |
| `surfaceTertiary` | `#E9EBF1` | `#232838` | Insets, tracks, chips. |
| `success`, `warning`, `destructive` | unchanged | unchanged | Status only, always with a word or icon. |
| `zoneRecovery` … `zoneMax` | unchanged | unchanged | Training-zone data colours. Not brand: never decorate with them. |

## Type

- **Display** — `dsLargeTitle`, `dsTitle1`–`dsTitle3`: SF Pro Rounded, bold/semibold. The
  rounded terminals are the route line's round caps.
- **Text** — `dsHeadline`, `dsBody`, `dsCallout`, `dsSubhead`, `dsFootnote`, `dsCaption`,
  `dsCaption2`: SF Pro Text, so long copy stays easy to read. All scale with Dynamic Type.
- **Metrics** — `metricHero` 120, `metricXL` 96, `metricL` 64, `metricM` 40, `metricS` 24:
  SF Pro Rounded with tabular digits (`.monospacedDigit()`). Fixed sizes on purpose: they
  sit in fixed grids on the run HUD.
- **Eyebrows** — `dsCaption2.weight(.bold)`, uppercase, kerning 1.2–1.8, in `brand` on a
  hero or `.secondary` on a card.

## Shape, depth and motion

- Radii come from `AppRadius` (3, 6, 10, 14, 20, 26, pill). Cards use `lg` (20), buttons
  `lg` or `md`, chips `pill`.
- Strokes are round-capped and round-joined, like the route.
- `appShadow(.e1–.e3)` for height; `appGlow(_, color: .brand)` for emphasis. A primary
  action is the route gradient with a `.strong` brand glow.
- Motion tokens live in `AppAnimations.swift`; see Motion below.

## Motion

Motion in Stride says one thing: *you are moving along a route*. Things draw in along a
line, land like the start pin, or rise into place. Nothing loops for decoration, nothing
spins, and nothing moves under Reduce Motion except a short cross-fade.

### Tokens (`AppAnimation`, `Stride/Shared/Theme/AppAnimations.swift`)

| Token | Curve | Use |
| --- | --- | --- |
| `snappy` | spring 0.22s, damping 0.78 | Press feedback on buttons and chips |
| `bouncy` | spring 0.32s, damping 0.72 | Selection: a segment sliding, a chip turning on |
| `gentle` | spring 0.45s, damping 0.82 | A value moving: progress bars and rings |
| `entrance` | spring 0.40s, damping 0.75 | Content arriving on a screen |
| `routeDraw` | ease-in-out 1.1s | The app mark's loop stroking itself in |
| `pinDrop` | spring 0.35s, damping 0.55 | Something landing: the start pin, an empty state's disc |
| `pinPulse` | ease-out 1.8s, repeating | A live position's ripple. One per screen |
| `quick` | ease-in-out 0.2s | A state flipping with no spring: a disclosure chevron, a status line changing |
| `thinking` | ease-in-out 0.8s, repeating | Waiting on the coach: skeleton lines and typing dots breathe |
| `celebrate` | spring 0.9s, damping 0.82 | A goal met: the confetti burst, once |
| `countdown` | linear 1s | A countdown ring moving at clock speed (strength rest timer) |
| `stagger` | 0.06s | The gap between items in a staggered entrance |
| `reduced` | ease-in-out 0.2s | What everything becomes under Reduce Motion |

### What moves, and how

| Thing | Motion | Under Reduce Motion |
| --- | --- | --- |
| A screen's sections | `.strideEntrance(appeared, delay:)`: fade and rise 18pt with `entrance`, staggered | Fade only, no delay |
| A changing figure | `.strideNumericTransition()`: digits roll when the change is animated (Progress totals when the range changes) | Cross-fade |
| `.heroCard()` | Nothing. The route's light in the corner is part of the card, there from the start | Same |
| `StrideProgressBar` | Draws in from empty on first appear, then slides between values with `gentle` | Appears filled |
| `ProgressRingView` (Home) | Same as the bar, as a ring | Same |
| `StrideSegmentedControl` | The route slides to the chosen segment (`bouncy`, matched geometry) | Jumps there |
| `.strideChip(selected:)` | Presses to 95%; turning on, the route fades in under the label (`bouncy`) | Cross-fade, no press scale |
| `.strideButton()` | Presses to 97% and darkens slightly (`snappy`) | Darkens only |
| `StrideEmptyState` | The disc lands with `pinDrop` and its symbol bounces once; title, text and action rise in behind it | Fades in whole |
| `StrideAppMark(drawsOn: true)` | The loop draws itself in (`routeDraw`), then the pin drops 0.85s later | Appears whole |
| `StartPin(pulses: true)` | One slow ripple outwards, repeated | No ripple |
| Coach skeleton and typing dots | Breathe with `thinking` while the coach writes | Still |
| A disclosure row (Plan weeks) | The chevron turns with `quick` | Same |

### Rules

1. **Go through the system.** Use the tokens and modifiers above, not a bare
   `.spring(...)` or `.easeInOut(...)`. A one-off animation reads `accessibilityReduceMotion`
   or uses `adaptiveAnimation`.
2. **Signature motion is for the route and the pin.** Drawing along a line belongs to the
   route (progress, the mark); landing with an overshoot belongs to the pin and things
   that stand in for it. Cards and text only fade and rise.
3. **Once.** A route draws once, an empty state lands once. Only a live position and
   something waiting on the coach (`thinking`) repeat, and only one of each per screen.
4. **Fast enough to ignore.** A screen's entrance is done inside about half a second;
   stagger at most about six items, then let the rest arrive together.
5. **The live run screen keeps its own motion.** It is the written exception here as it
   is for colour (see "The live run screen" below); leave its animations as they are.
6. **Reduce Motion means a cross-fade.** No slide, scale, bounce, draw or ripple.

## Controls

Shared in `Stride/Shared/Components/StrideControls.swift`. Use these rather than system or hand-drawn styles, so a button or a list looks the same on every screen.

| Need | Use |
| --- | --- |
| A button | `.buttonStyle(.strideButton())`: `.primary` (the route, one per screen), `.secondary` (brand tint), `.quiet` (card), `.destructive`; `compact:` for rows, `fullWidth: false` to hug |
| A filter or quick reply | `.buttonStyle(.strideChip(selected:))` |
| A segmented choice on a page | `StrideSegmentedControl`; `subtitle:` adds a hint line under each title (`UnitPreferencePicker`). Inside a `Form`, the system `.segmented` picker, tinted by `AppChrome` |
| Days of the week | `DayOfWeekPicker`: seven route-on, card-off toggles |
| A number to step or type | `NumericStepperField` |
| A tappable card or custom control that isn't a button style | `.buttonStyle(BouncyButtonStyle())`: presses to 95% with `snappy` |
| A label that isn't a control (a duration, a weight, a muscle group) | `StrideTag(text, systemImage:, tone:)`: `.neutral` is the chip's card look in secondary text, `.brand` is brand at 12% with `brandText` |
| A chart's selected-point readout | `StrideTooltip { … }` (or `.strideTooltip()`): a small card on `e2`, never system material |
| A label on a map (the route's name) | `.strideMapLabel()`: the tooltip's card |
| A scheduled workout in a list | `WorkoutCardView` |
| Weather data | `AppleWeatherAttribution()` under it, every time (App Review 5.2.5) |
| A coach reply | `CoachText`, so its lists and headings render as lists and headings |
| A scrolling page's column of cards | `.strideReadableWidth()` on the stack inside the `ScrollView`, after its padding: caps it at 700pt and centres it, for iPhone Duo's inner display |
| Progress along a line | `StrideProgressBar(value:, tint:)`, the route on a `surfaceTertiary` track |
| A free-standing text field | `.strideField()`; a field inside a card is a well on `surfacePrimary` with the hairline |
| A `List` or `Form` | `.strideList()` on it and `.strideListRow()` on each `Section`, so dark mode is ink, not system black |
| A sheet with its own scroll view | `.strideSheet()` |
| A section header | `Text(...).strideEyebrow()` in `.secondary`, above its card (not inside it), with `.padding(.horizontal, AppSpacing.xs)`; `brandText` only on a hero |
| An icon tile | A circle tinted at 12–15% with the glyph in the tint: 48pt leading a card, 32pt in a row. Settings rows keep their small square tiles |
| A card | `.padding(AppSpacing.lg).strideCard()` at the default `lg` radius, never a hand-drawn fill and stroke; status (heat, missed runs) shows in the icon and the action, not a tinted ground |
| An empty screen | `StrideEmptyState(title, systemImage:, description:) { actions }`, not `ContentUnavailableView` |
| A chart | Bars in `.routeBar`, a progress line in `.route` at 3pt with round caps, the selection rule dashed in brand, tooltips as cards; zone and data colours stay as they are |

Text on the route or on brand is always `onFill`, never white (2.8:1).

## Icons

Decided 2026-10-27: **`StrideIcon` wherever it has the glyph, SF Symbols for the rest.**

- `StrideIcon(name:, size:, color:, strokeWeight:)` draws Stride's own set on a 24pt grid
  with round caps, like the route (`StrideIconName`: workout types, tab glyphs, chevrons,
  check, plus, close, play, pause, heart, timer, ruler, flag, gear, music and more). The
  workout-type glyphs render filled SF Symbols underneath (PR #322) so they stay legible.
- Use an SF Symbol only when `StrideIconName` has no such glyph (clock, map, sparkles,
  trash, share…), when iOS draws the glyph itself (`Label` in menus, swipe actions,
  toolbars, `systemImage:` parameters), or when the glyph needs an SF symbol effect
  (the check that draws itself in on Achievements).
- A glyph inside a `.primary` button is `onFill`, like its label.
- Needing a Stride glyph that doesn't exist yet: add a case to `StrideIconName` rather
  than reaching for the SF Symbol.

## App Store screenshots

Screenshots are taken in dark appearance, so the screen, the night-map frame and the
icon are one picture. `.github/workflows/app-store-screenshots.yml` captures them from the demo history (run it
from the Actions tab, or label a PR `app-store-screenshots`). `AppStoreScreenshotTests`
takes the iPhone screens at 9:41 on the largest iPhone; the Watch app's
`--seed-demo-data --demo-page <n>` gives each Watch page; `design/appstore/compose.mjs`
frames the iPhone ones with the captions in `design/appstore/captions.json`.

To take them on a Mac instead (the workflow's steps, by hand):

```sh
xcodegen generate
UDID=<an iPhone 17 Pro Max simulator>   # xcrun simctl list devices available
xcrun simctl boot "$UDID"; xcrun simctl ui "$UDID" appearance dark
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100
TEST_RUNNER_APP_STORE_CAPTURE_DIR="$PWD/AppStore/iphone-raw" xcodebuild test -scheme Stride \
  -destination "platform=iOS Simulator,id=$UDID" -only-testing:StrideUITests/AppStoreScreenshotTests
cd design/appstore && npm install --no-save playwright@1.49.1 && npx playwright install webkit
node compose.mjs ../../AppStore/iphone-raw ../../AppStore/iphone-6.9 webkit
# 6.1" / 6.3" slot (1206 x 2622):
mkdir -p ../../AppStore/iphone-6.3
for f in ../../AppStore/iphone-6.9/*.png; do sips -z 2622 1206 "$f" --out ../../AppStore/iphone-6.3/; done
```

## Rules

1. **One ground per appearance.** Light is daylight paper everywhere, dark is the night
   map everywhere. No always-dark card on a light page, no forced-dark screen. Three
   exceptions, and only these: the share card (ink, it leaves the app), the Watch (ink,
   watchOS is always dark), and the live run screen (below).
2. **One hero per screen.** `.heroCard()` marks the card that matters most: today's
   session, the race, the profile. Every other card is `.strideCard()`.
3. **The route gradient means progress or go.** Use it for progress rings and bars, primary
   actions and drawn routes. Not for decoration or backgrounds.
4. **The start pin means "you are here".** The start of a route, today on a plan, the
   current point on a chart. One per view.
5. **The grid is a texture, not a chart.** Only on full-screen backdrops (welcome, onboarding), the app mark and the share card;
   never on a card in the app (decided 2026-10-27),
   at a 30–36pt pitch, never under data.
6. **Zone colours stay data.** They mark training intensity and nothing else.

### The live run screen

`ActiveRunView` fills the screen with the current zone colour, darkened, with white
figures, in both appearances. It is the one place a zone colour is a ground: mid-run the
screen is read in a glance, often in sunlight, and a screen-wide zone colour is the
fastest thing to read. It covers the live screen only, paused included (pausing is a state of
that screen, not a screen of its own). The finished-run summary and the active strength
screen sit on the normal Route Loop ground.

## Icon

`icon-light.svg` (the App Store icon), `icon-dark.svg` and `icon-tinted.svg` are the
sources for `AppIcon.appiconset` and the Watch's `WatchAppIcon`. Render a variant to a
1024 px RGB PNG with no alpha (any SVG renderer; Chrome headless was used) and copy it
over the matching file. `StrideAppMark` draws the same geometry live in the app.
