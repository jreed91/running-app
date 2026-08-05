# Heat and humidity adaptation — the evidence behind the numbers

**Read this before changing any constant in `HeatAdaptationPolicy`, and update the row in
the same change.** The policy is deliberately a wall of constants with citations attached
rather than logic scattered through the advisory service, for the same reason
`PregnancyRunningPolicy` is: a prescription in a health feature with no source behind it
is what that arrangement exists to prevent.

Stride is not a clinician. Everything below adjusts *training*; none of it is a medical
judgement about whether a given runner should be outside, and the copy says so.

---

## 1. Why dew point, not relative humidity

Relative humidity is a ratio against what the air *could* hold at its current
temperature, so 80 % at 10 °C and 80 % at 30 °C describe completely different air. Dew
point is the absolute measure — the temperature at which the air is saturated — and it is
what decides whether sweat can evaporate, which is the runner's only meaningful cooling
route once air temperature approaches skin temperature. The US National Weather Service
makes the same argument for using dew point over relative humidity in public forecasts
([NWS, *Dew Point vs. Humidity*](https://www.weather.gov/arx/why_dewpoint_vs_humidity)).

Consequence in code: `HeatAdaptationPolicy` scores on dew point and on the
temperature-plus-dew-point sum. Relative humidity is only ever an *input* — when WeatherKit
gives no dew point, `dewPointCelsius(temperatureCelsius:relativeHumidityPercent:)` derives
one with the Magnus–Tetens approximation (b = 17.62, c = 243.12 °C, accurate to about
±0.35 °C over −45…60 °C; Sonntag 1990, as reproduced in
[Wikipedia, *Dew point*](https://en.wikipedia.org/wiki/Dew_point#Calculating_the_dew_point)).

`WorkoutWeather.humidityPercent` is retained and still shown, because it is the number
runners recognise.

---

## 2. The three scales the tier is taken from

The tier is the **most severe** of three independent reads, the same "whichever is worse
relative to its own threshold" shape `SmartCoachCards.heatCard` already uses. No single
scale covers a dry 38 °C desert morning *and* a 24 °C tropical one, and both change what a
session should be.

### 2a. Temperature + dew point sum (°F) — the primary scale

The long-standing runner-facing scale, published with a pace-adjustment band per bucket.
Values are the sum of air temperature and dew point, both in Fahrenheit.

| Sum (°F) | Published pace adjustment | Tier in code |
| --- | --- | --- |
| ≤ 100 | 0 % | `.none` |
| 101–130 | 0 – 2 % | `.mild` |
| 131–150 | 2 – 4.5 % | `.moderate` |
| 151–170 | 4.5 – 8 % | `.high` |
| 171–180 | 8 – 10 % | `.severe` |
| > 180 | hard running not recommended | `.extreme` |

Source: [RunFit MKE, *How to calculate pace adjustment for hot weather
running*](https://www.runfitmke.com/blog/how-to-calculate-pace-adjustment-for-hot-weather-running),
which reproduces the full bucket table; the same table circulates via
[Precision PT, *Running in the heat and humidity — what to
dew?*](https://www.precisionpt.org/post/running-in-the-heat-and-humidity-what-to-dew).

### 2b. Dew point alone (°C) — the evaporative ceiling

Above a certain dew point the sum scale understates the problem, because the cooling route
is closing regardless of how mild the air is.

| Dew point | Effect on easy / hard running | Tier in code |
| --- | --- | --- |
| < 12.8 °C (55 °F) | unaffected | `.none` |
| 12.8 – 15.6 °C (55–60 °F) | ~1 %; hard running slightly harder | `.mild` |
| 15.6 – 18.3 °C (60–65 °F) | 2–3 %; easy slightly harder, hard is hard | `.moderate` |
| 18.3 – 23.9 °C (65–75 °F) | 3–8 %; easy hard, hard very hard | `.high` |
| 23.9 – 26.7 °C (75–80 °F) | 12–15 %; hard running not recommended | `.severe` |
| ≥ 26.7 °C (80 °F) | run by effort only | `.extreme` |

Source: [RunnersConnect, *How to adjust your pace in hot and humid
weather*](https://runnersconnect.net/dew-point-effect-running/) — its table is reproduced
above with the two 65–70 and 70–75 °F rows merged into one `.high` band, since both
prescribe the same action (abandon pace targets, run on effort).

The `.severe` boundary at 23.9 °C is corroborated independently: above a ~24 °C dew point,
only heat-acclimatised athletes should train outdoors and then at reduced intensity and
duration.

### 2c. Apparent temperature (°C) — the radiant/dry-heat read

WeatherKit's `apparentTemperature` is what `WorkoutWeather.feelsLikeCelsius` already
stores. It is **not** WBGT — it carries no globe (solar radiation) term — so the ACSM /
NATA WBGT flag thresholds are not transplanted onto it directly. The bands below are the
conservative mapping actually used:

| Apparent temperature | Tier in code | Basis |
| --- | --- | --- |
| < 15 °C | `.none` | Below where Daniels starts adjusting at all |
| 15 – 22 °C | `.mild` | Daniels: above ~15 °C (60 °F), slow paces 1–3 % per 5 °C |
| 22 – 27 °C | `.moderate` | Matches the app's existing `heatFeelsLikeCelsius = 22` trigger |
| 27 – 32 °C | `.high` | ACSM: at 30–32 °C WBGT, limit intense exercise for *all* individuals |
| 32 – 37 °C | `.severe` | ACSM black-flag territory once WBGT is factored |
| ≥ 37 °C | `.extreme` | Outdoor exertion cancelled or limited to short low-intensity exposure |

Sources: Jack Daniels' heat adjustment — "in heat above 60 °F (15 °C), slow your paces
1–3 % per 10 °F (5 °C)" ([V.O2 / VDOT O2, *Adjust your training paces for high
temperatures*](https://news.vdoto2.com/2015/07/adjust-your-training-paces-for-high-temperatures/));
ACSM activity-modification thresholds ([ACSM heat guidelines as reproduced by Road Race
Management](https://rrm.com/acsm-heat-guidelines/), and the [ACSM expert consensus
statement on exertional heat
illness](https://www.khsaa.org/common_documents/Sports%20Medicine/EHIPositionStatement/B-ACSM%20EHI%20Consensus%20Statement%202023.pdf),
2023).

Because apparent temperature reads *higher* than WBGT in dry conditions and *lower* in
still, humid, sunny conditions, this scale is deliberately never the only one consulted —
2a and 2b cover the humid case it under-reads.

---

## 3. Pace adjustment applied to the plan's targets

`paceAdjustmentPercent(for:)` returns the published band; `representativePaceAdjustmentPercent`
returns its midpoint, which is what actually widens a session's `targetPaceLowerBound` /
`targetPaceUpperBound`.

| Tier | Band | Midpoint used | Reconciles |
| --- | --- | --- | --- |
| `.none` | 0 % | 0 % | — |
| `.mild` | 0.5 – 2 % | 1.25 % | 2a bucket 101–130, Daniels' first step |
| `.moderate` | 2 – 4.5 % | 3.25 % | 2a bucket 131–150, RunnersConnect 2–3 % |
| `.high` | 4.5 – 8 % | 6.25 % | 2a bucket 151–170, RunnersConnect 3–8 % |
| `.severe` | 8 – 12 % | 10 % | 2a gives 8–10 %, RunnersConnect 12–15 %; the band spans both and the midpoint sits between them |
| `.extreme` | *no target* | — | Both sources: abandon pace targets, run by effort |

**`.extreme` returns `nil`, and the adaptation strips the pace bounds entirely.** A number
that has stopped being achievable is worse than no number: it is a target the runner will
chase. This is the same reasoning that keeps pregnancy plans free of pace targets.

Adjustment is applied to pace *in seconds per kilometre*, so a percentage slower is a
percentage larger — `bound * (1 + percent / 100)`.

---

## 4. What changes about the session itself

Slowing the pace band is not enough on its own above `.moderate`: a tempo run held at a
correct effort in 30 °C is no longer a tempo stimulus, it is a hard aerobic run with a
larger recovery cost, and the interval session it precedes is the one that suffers.

| Tier | Quality sessions (tempo, intervals) | Long run | Easy | Location |
| --- | --- | --- | --- | --- |
| `.mild` | unchanged | unchanged | unchanged | outdoor |
| `.moderate` | pace bands widened | pace bands widened | pace bands widened | outdoor |
| `.high` | pace bands widened, work volume cut 20 % | distance cut 10 % | pace bands widened | outdoor, cooler hour suggested |
| `.severe` | converted to an easy run | distance cut 25 % | pace bands widened | indoor suggested |
| `.extreme` | converted to an easy run, no pace target | distance cut 30 % | no pace target | indoor |

The `.severe` conversion of quality work follows the source guidance directly: above a
~24 °C dew point "most hard sessions should be postponed or moved indoors"
([RunnersConnect](https://runnersconnect.net/dew-point-effect-running/)), and ACSM limits
intense exercise for all individuals well before that point. Volume reductions on the long
run are the conservative end of the same advice — heat strain accumulates with duration,
so the session that spends longest out there is the one whose duration is trimmed rather
than its intensity, which was already low.

---

## 5. When the runner is prompted, and when they are not

A prompt the evening before is only worth sending when the *session* is at stake, so the
trigger tier depends on what is scheduled (`shouldPrompt(tier:workoutType:)`):

- **Quality (tempo, interval) and long runs** prompt from `.moderate`. These are the
  sessions with a pace target to miss and a recovery cost to pay, and they are the ones a
  runner would reschedule to a cooler hour if told in time.
- **Easy runs** prompt from `.high`. An easy run in moderate heat needs no intervention
  beyond running to feel, which is what an easy run already asks for. Prompting anyway is
  how a runner learns to swipe the notification away.
- **Nothing else prompts.** Rest, strength, cross-training, and any session already marked
  indoor are unaffected by the forecast. Neither is a race — the race is the fixed point
  the block is built around, the same reason `AdaptableWorkoutSelector` excludes it and
  `MissedWorkoutShift` refuses to move it. A race-day heat plan is a different feature.

Pregnancy plans are excluded outright, via the same `plan.isPregnancyPlan` guard the AI
coach uses. Those sessions are prescribed by effort and duration against published
guidance, which already self-corrects in heat: a talk-test effort in 30 °C is simply
slower. Rewriting them here would hand them the pace bands and volume cuts the evidence
does not support. See [`PREGNANCY_RUNNING_EVIDENCE.md`](PREGNANCY_RUNNING_EVIDENCE.md).

---

## 6. The cooler-hour suggestion

When the advisory fires, the service also reads the rest of the day's hourly forecast
between 05:00 and 21:00 and reports the coolest hour, but only when moving there would
drop the session at least one whole tier. A suggestion to start "an hour earlier, where
it's 1 °C cooler" is noise; one that turns a `.severe` tempo into a `.moderate` one is the
entire intervention.

`minimumCoolerHourGapCelsius = 2.0` is a floor on top of that, so a tier boundary crossed
by a rounding error does not produce a suggestion the runner cannot feel.

---

## 7. Heat acclimatisation — deliberately *not* modelled

Six to ten consecutive days of exercise-heat exposure produce most of the available
adaptation, and an acclimatised runner genuinely needs less adjustment than these tables
give ([RunnersConnect, *Heat training for
runners*](https://runnersconnect.net/heat-acclimatization/); [Racinais et al., *Consensus
recommendations on training and competing in the
heat*](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC4473280/)).

Stride does not discount the adjustment for it, for two reasons:

1. The app cannot observe acclimatisation. Counting recent runs whose recorded weather was
   hot is a proxy for exposure, not for adaptation, and it fails in exactly the direction
   that matters — a runner who has been running hot *because they had no choice* would be
   handed a smaller adjustment.
2. The cost of the two errors is not symmetric. Over-adjusting costs an acclimatised
   runner a slightly easy session; under-adjusting is a heat-illness risk.

The advisory copy says the adjustment is a starting point and that an acclimatised runner
may need less, which is the honest version of what the app knows.

---

## 8. Rows mapped to code

| Constant in `HeatAdaptationPolicy` | Section above |
| --- | --- |
| `magnusB`, `magnusC` | §1 |
| `sumFahrenheitThresholds` | §2a |
| `dewPointCelsiusThresholds` | §2b |
| `apparentCelsiusThresholds` | §2c |
| `paceAdjustmentPercent(for:)` | §3 |
| `qualityVolumeScale(for:)`, `longRunDistanceScale(for:)` | §4 |
| `convertsQualityToEasy(_:)`, `dropsPaceTargets(_:)`, `suggestsIndoor(_:)` | §4 |
| `shouldPrompt(tier:workoutType:)` | §5 |
| `coolerHourWindow`, `minimumCoolerHourGapCelsius` | §6 |
