# Route Loop — Stride's design system

Stride's icon is a GPS loop with a start pin on a night map. The app speaks in the same
three things, and nothing else carries the brand:

| Element | What it is | In code |
| --- | --- | --- |
| **The route** | One stroke with round caps, amber where it starts and orange where it ends | `LinearGradient.route` (`.fill(.route)`, `.stroke(.route, …)`) |
| **The start pin** | A white disc with an orange centre | `StartPin(diameter:)` |
| **The map** | A faint square grid on the page: daylight paper in light, night ink in dark | `MapGridPattern`, `MapBackdrop`, `.heroCard()` |

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
- Motion tokens live in `AppAnimations.swift`; every animation goes through
  `adaptiveAnimation` (or reads `accessibilityReduceMotion`) so Reduce Motion is honoured.

## Motion

The route draws itself, then the pin lands. `StrideAppMark(size:, drawsOn: true)` strokes
the loop in with `AppAnimation.routeDraw` (1.1s ease-in-out) and drops the pin with
`pinDrop` 0.85s later; `ProgressRingView` fills from zero with `gentle`;
`StartPin(diameter:, pulses: true)` ripples with `pinPulse` for a live position.
Everything else uses `entrance` (staggered 80ms), `bouncy`, `snappy` and `gentle`. Only
the route and the pin get signature motion, a route draws once, one pulse per screen, and
under Reduce Motion the mark appears whole and the pulse is off.

## Controls

Shared in `Stride/Shared/Components/StrideControls.swift`. Use these rather than system or hand-drawn styles, so a button or a list looks the same on every screen.

| Need | Use |
| --- | --- |
| A button | `.buttonStyle(.strideButton())`: `.primary` (the route, one per screen), `.secondary` (brand tint), `.quiet` (card), `.destructive`; `compact:` for rows, `fullWidth: false` to hug |
| A filter or quick reply | `.buttonStyle(.strideChip(selected:))` |
| A segmented choice on a page | `StrideSegmentedControl`; inside a `Form` the system `.segmented` picker, tinted by `AppChrome` |
| Progress along a line | `StrideProgressBar(value:, tint:)`, the route on a `surfaceTertiary` track |
| A free-standing text field | `.strideField()`; a field inside a card is a well on `surfacePrimary` with the hairline |
| A `List` or `Form` | `.strideList()` on it and `.strideListRow()` on each `Section`, so dark mode is ink, not system black |
| A sheet with its own scroll view | `.strideSheet()` |
| An empty screen | `StrideEmptyState(title, systemImage:, description:) { actions }`, not `ContentUnavailableView` |
| A chart | Bars in `.routeBar`, a progress line in `.route` at 3pt with round caps, the selection rule dashed in brand, tooltips as cards; zone and data colours stay as they are |

Text on the route or on brand is always `onFill`, never white (2.8:1).

## App Store screenshots

`.github/workflows/app-store-screenshots.yml` captures them from the demo history (run it
from the Actions tab, or label a PR `app-store-screenshots`). `AppStoreScreenshotTests`
takes the iPhone screens at 9:41 on the largest iPhone; the Watch app's
`--seed-demo-data --demo-page <n>` gives each Watch page; `design/appstore/compose.mjs`
frames the iPhone ones with the captions in `design/appstore/captions.json`.

## Rules

1. **One ground per appearance.** Light is daylight paper everywhere, dark is the night
   map everywhere. No always-dark card on a light page, no forced-dark screen.
2. **One hero per screen.** `.heroCard()` marks the card that matters most: today's
   session, the race, the profile. Every other card is `.strideCard()`.
3. **The route gradient means progress or go.** Use it for progress rings and bars, primary
   actions and drawn routes. Not for decoration or backgrounds.
4. **The start pin means "you are here".** The start of a route, today on a plan, the
   current point on a chart. One per view.
5. **The grid is a texture, not a chart.** Only on heroes and full-screen backdrops (welcome, onboarding),
   at a 30–36pt pitch, never under data.
6. **Zone colours stay data.** They mark training intensity and nothing else.

## Icon

`icon-light.svg` (the App Store icon), `icon-dark.svg` and `icon-tinted.svg` are the
sources for `AppIcon.appiconset` and the Watch's `WatchAppIcon`. Render a variant to a
1024 px RGB PNG with no alpha (any SVG renderer; Chrome headless was used) and copy it
over the matching file. `StrideAppMark` draws the same geometry live in the app.
