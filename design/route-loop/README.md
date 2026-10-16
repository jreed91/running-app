# Route Loop — Stride's design system

Stride's icon is a GPS loop with a start pin on a night map. The app speaks in the same
three things, and nothing else carries the brand:

| Element | What it is | In code |
| --- | --- | --- |
| **The route** | One stroke with round caps, amber where it starts and orange where it ends | `LinearGradient.route` (`.fill(.route)`, `.stroke(.route, …)`) |
| **The start pin** | A white disc with an orange centre | `StartPin(diameter:)` |
| **The night map** | Navy ink ground with a faint square grid | `.inkGround`, `MapGridPattern`, `.inkHero()`, `NightMapBackdrop` |

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
| `ink` | `#1F2433` | `#1F2433` | The always-dark hero ground: up-next card, race card, profile card, share card, welcome screens. |
| `inkDeep` | `#0D1018` | `#0D1018` | Bottom of the ink gradient. |
| `onInk` / `onInkMuted` | `#F5F6FA` / `#A9AFC2` | same | Text on ink: 14:1 and 7:1. `.inkHero()` sets the dark appearance, so `.primary` / `.secondary` also work there. |
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

## App Store screenshots

`.github/workflows/app-store-screenshots.yml` captures them from the demo history (run it
from the Actions tab, or label a PR `app-store-screenshots`). `AppStoreScreenshotTests`
takes the iPhone screens at 9:41 on the largest iPhone; the Watch app's
`--seed-demo-data --demo-page <n>` gives each Watch page; `design/appstore/compose.mjs`
frames the iPhone ones with the captions in `design/appstore/captions.json`.

## Rules

1. **One hero per screen.** `.inkHero()` marks the card that matters most: today's
   session, the race, the profile. A screen of ink cards has no hero.
2. **The route gradient means progress or go.** Use it for progress rings and bars, primary
   actions and drawn routes. Not for decoration or backgrounds.
3. **The start pin means "you are here".** The start of a route, today on a plan, the
   current point on a chart. One per view.
4. **The grid is a texture, not a chart.** Only on ink grounds and full-screen backdrops,
   at a 30–36pt pitch, never under data.
5. **Zone colours stay data.** They mark training intensity and nothing else.

## Icon

`icon-light.svg` (the App Store icon), `icon-dark.svg` and `icon-tinted.svg` are the
sources for `AppIcon.appiconset` and the Watch's `WatchAppIcon`. Render a variant to a
1024 px RGB PNG with no alpha (any SVG renderer; Chrome headless was used) and copy it
over the matching file. `StrideAppMark` draws the same geometry live in the app.
