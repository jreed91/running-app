# Pregnancy running plan — evidence base

The rules in `PregnancyPlanService` and `PregnancyRunningPolicy` are not invented. Every
number and every guardrail below traces to a published guideline or a peer-reviewed study,
and the code carries a pointer back to the row it came from. If a rule changes, change the
row too — a prescription in a health app with no source behind it is the thing this file
exists to prevent.

**Stride is not a clinician.** The plan this evidence supports is a *starting draft for a
runner who already has clearance from their own maternity provider*, not medical advice.
The screening gate, the red-flag list, and the "check with your provider" copy are load-
bearing parts of the feature, not decoration.

---

## 1. The primary guidelines

| Source | What it is |
| --- | --- |
| **ACOG Committee Opinion No. 804** — *Physical Activity and Exercise During Pregnancy and the Postpartum Period*, Obstet Gynecol 2020 (replaces CO 650) | The US obstetric standard. Includes explicit guidance for athletes for the first time. |
| **SOGC/CSEP No. 367 — 2019 Canadian Guideline for Physical Activity throughout Pregnancy**, J Obstet Gynaecol Can 2018;40(11):1528–1537 | The most prescriptive of the guidelines: graded recommendations, an intensity method, and a pelvic-floor recommendation. |
| **WHO 2020 Guidelines on Physical Activity and Sedentary Behaviour** | Pregnant and postpartum women should do ≥150 min of moderate-intensity aerobic activity per week. |

### The dose

- **≥150 minutes of moderate-intensity physical activity per week**, accumulated over **at
  least 3 days**, with activity on most or all days encouraged (SOGC/CSEP 2019; ACOG 804;
  WHO 2020).
- **A variety of aerobic *and* resistance training**, which produces greater benefit than
  either alone; yoga/gentle stretching may add benefit (SOGC/CSEP 2019).
- Benefits documented across the guidelines: reduced risk of gestational diabetes,
  preeclampsia/gestational hypertension, and caesarean birth, and a protective effect
  against postpartum depressive disorders (ACOG 804).

→ **Code:** `PregnancyRunningPolicy.minimumWeeklyActiveMinutes = 150`. The generator tops a
week up with cross-training whenever the running prescription alone falls below it, and
never schedules fewer than 3 active days.

### Who may keep going hard

> Women who habitually engaged in vigorous-intensity aerobic activity or who were
> physically active before pregnancy can continue these activities during pregnancy and the
> postpartum period. — ACOG 804

→ **Code:** the `habituallyVigorous` input. It is the only thing that unlocks a
moderate-effort "steady" session, and it stops unlocking it at 28 weeks (see §4).

---

## 2. What runners actually do — and what happens

These are the observational studies that shape the *curve*, as distinct from the guidelines
that set the *floor*.

| Finding | Source |
| --- | --- |
| 70% of competitive runners ran during pregnancy; only **31% still ran in the third trimester**. Days per week barely moved across trimesters (**6, 6, 5**) while **run duration shortened** and **medium- and high-intensity runs dropped sharply**. Cross-training rose so that total training time held. Few reported a running injury while pregnant. | Tenforde AS, Toth KES, Langen E, Fredericson M, Sainani KL. *Running Habits of Competitive Runners During Pregnancy and Breastfeeding.* Sports Health 2015;7(2):172–176 (n = 110) |
| Reported third-trimester training-volume reductions of **30–60%** in recreational and competitive runners. | Same literature, summarised in reviews of exercise dose in pregnancy |
| Continuing to run **did not affect gestational age at delivery or birthweight centile**, regardless of mean weekly distance or of which trimester the runner ran until. Assisted vaginal delivery rates were higher among runners. | Kuhrt K, Harmon M, Hezelgrave NL, Seed PT, Shennan AH. *Is recreational running associated with earlier delivery and lower birth weight in women who continue to run during pregnancy?* BMJ Open Sport Exerc Med 2018;4:e000296 (n = 1,293, international parkrun cohort) |
| Vigorous-intensity exercise in the third trimester was not associated with adverse infant or maternal outcomes in the pooled studies, though the evidence base is small and drawn largely from already-trained women. | Beetham KS, Giles C, Noetel M, Clifton V, Jones JC, Naughton G. *The effects of vigorous intensity exercise in the third trimester of pregnancy: a systematic review and meta-analysis.* BMC Pregnancy Childbirth 2019;19:281 |

→ **Code:** `PregnancyRunningPolicy.runningVolumeShare(atGestationalWeek:)` holds **frequency**
constant and cuts **duration**, landing at 0.35–0.65 of pre-pregnancy running minutes across
the third trimester — i.e. the documented 35–65% reduction — while
`crossTrainingMinutes(...)` backfills the difference, which is exactly the substitution
Tenforde et al. observed. Running is not the hazard the plan is designed around; heat,
falls, dehydration, and unreported symptoms are.

---

## 3. Intensity is prescribed by effort, never by pace, and only loosely by heart rate

Pregnancy changes resting and submaximal heart rate, plasma volume, and the pace–effort
relationship, so both a pace band and an absolute bpm target misprescribe as pregnancy
progresses.

- **Talk test** — moderate intensity is activity during which you *can talk but not sing*
  (SOGC/CSEP 2019; the guideline names the talk test as its intensity method).
- **RPE 12–14 on the Borg 6–20 scale** for moderate intensity (SOGC/CSEP 2019).
- Pregnancy-specific target heart-rate zones **do** exist — Mottola et al. derived e.g.
  **129–144 bpm for ages 20–29 at 60–80% VO₂peak**, and a light-intensity band of
  **102–124 bpm** for sedentary women with overweight/obesity — but they are population-
  specific and validated in the populations they were derived from, not general prescriptions.
  Davenport ML, Mottola MF, et al. *Development and validation of exercise target heart rate
  zones for overweight and obese pregnant women.* Appl Physiol Nutr Metab 2008;33(5):984–989;
  Mottola MF, et al. *VO₂peak prediction and exercise prescription for pregnant women.*
  Med Sci Sports Exerc 2006;38(8):1389–1395.

→ **Code:** every pregnancy `ScheduledWorkout` is generated with
`targetPaceLowerBound == nil` and `targetPaceUpperBound == nil`. This is asserted by a test
(`pregnancyWorkoutsCarryNoPaceTargets`) precisely because "helpfully" adding a pace band
back is the regression this feature is most likely to suffer. Prescription lives in
duration + `PregnancyEffort`, which carries the talk-test wording and the Borg range.

---

## 4. Heat

- The threshold treated as teratogenic is a **maternal core temperature above 39.0 °C**
  (roughly a 1.5–2.0 °C rise), associated with neural tube defects.
- A systematic review of 12 studies (n = 347) found **no reported core temperature above
  39.0 °C**; the highest individual reading was 38.9 °C and the highest post-exercise mean
  was 38.3 °C. Pregnant women exercised without breaching the threshold for **up to 35 min
  at 80–90% of maximum heart rate in 25 °C / 45% RH**, up to 45 min of water immersion
  (≤33.4 °C), and up to 20 min in a 40 °C bath or 70 °C sauna.
  Ravanelli N, Casasola W, English T, Edwards KM, Jay O. *Heat stress and fetal risk.
  Environmental limits for exercise and passive heat stress during pregnancy: a systematic
  review with best evidence synthesis.* Br J Sports Med 2019;53(13):799–805.
- ACOG 804 additionally advises avoiding **hot yoga and hot Pilates** (rooms of ~35–40 °C).

Read together: ordinary moderate running does not push a pregnant runner near 39 °C in
temperate conditions. The limits below are conservative *operating* limits that keep
sessions inside the studied window and cut dehydration exposure — they are not clinical
thresholds, and the code says so.

→ **Code:** `PregnancyRunningPolicy.sessionMinutesCap(for:)` — **90 min (T1) / 75 min (T2) /
45 min (T3)** per session; sustained moderate-effort blocks capped at 20 minutes and
withdrawn entirely from 28 weeks; every generated session carries heat and hydration copy.

---

## 5. Position, falls, and what to avoid outright

- **Avoid exercising supine after ~16 weeks.** The gravid uterus compresses the inferior
  vena cava (aortocaval compression), lowering maternal cardiac output and causing
  symptomatic hypotension. Modify to side-lying or upright. (ACOG 804; SOGC/CSEP 2019.)
  Prolonged motionless standing is also discouraged.
- **Avoid** contact sports (ice hockey, boxing, soccer, basketball), activities with a high
  risk of falling (gymnastics, horseback riding, downhill skiing, surfing, water/jet
  skiing), **scuba diving** (the fetal pulmonary circulation cannot filter bubbles),
  **skydiving**, **hot yoga/hot Pilates**, and **exercise at or above ~6,000 ft / 1,830 m**
  if not acclimatised. (ACOG 804.)

→ **Code:** `PregnancyStrengthAdapter` removes supine-position exercises from generated
strength sessions from gestational week 16 onward and annotates single-leg work with a
"hold a support" cue as balance changes. `PregnancyRunningPolicy.terrainGuidance(for:)`
steers later pregnancy toward even, well-lit, familiar surfaces and away from technical
trails — the same fall-risk logic applied to running, which no guideline lists explicitly
because running itself is not a listed fall-risk sport.

---

## 6. Pelvic floor

- The Canadian guideline recommends **daily pelvic floor muscle training (PFMT)** during
  pregnancy to reduce the risk of urinary incontinence (SOGC/CSEP 2019).
- Cochrane review: antenatal PFMT in women who are still continent **prevents the onset of
  urinary incontinence in late pregnancy and up to 6 months postpartum**, with a number
  needed to treat of about 4. There is **no** evidence it improves incontinence in women who
  already have it — i.e. it is prophylaxis, and starting early is the point.
  Woodley SJ, Lawrenson P, Boyle R, et al. *Pelvic floor muscle training for preventing and
  treating urinary and faecal incontinence in antenatal and postnatal women.* Cochrane
  Database Syst Rev 2020;5:CD007471.

→ **Code:** every generated week carries a PFMT prescription, and it is attached to each
strength session as an exercise whose note says **daily, not just on strength days**.

---

## 7. The screening gate

A pregnancy plan is not generated until the runner confirms none of these apply and that
they have discussed running with their maternity provider.

**Absolute contraindications to aerobic exercise** (ACOG 804; SOGC/CSEP 2019):
haemodynamically significant heart disease · restrictive lung disease · incompetent cervix
or cerclage · multiple gestation at risk of premature labour (triplets or higher is an
absolute contraindication in the Canadian guideline) · persistent second- or third-trimester
bleeding · placenta praevia after 26 weeks · premature labour in the current pregnancy ·
ruptured membranes · preeclampsia or pregnancy-induced hypertension · severe anaemia.

**Relative contraindications** — exercise may still be appropriate, but the decision belongs
with the provider: anaemia · unevaluated maternal cardiac arrhythmia · chronic bronchitis ·
poorly controlled type 1 diabetes · extreme morbid obesity · extreme underweight (BMI < 12) ·
history of an extremely sedentary lifestyle · intrauterine growth restriction in the current
pregnancy · poorly controlled hypertension · orthopaedic limitations · poorly controlled
seizure disorder · poorly controlled hyperthyroidism · heavy smoker · twin pregnancy after
28 weeks (Canadian guideline).

→ **Code:** `PregnancyContraindication`, surfaced by `PregnancyPlanSetupView` as a gate.
`PregnancyPlanService.generatePlan` refuses to build a plan without
`UserProfile.pregnancyClearedAt` set.

## 8. Stop immediately and contact your provider

The guidelines' shared list of reasons to stop exercising (ACOG 804; SOGC/CSEP 2019):
persistent excessive shortness of breath that does not resolve on rest · severe chest pain ·
regular painful uterine contractions · vaginal bleeding · persistent fluid loss from the
vagina · persistent dizziness or faintness that does not resolve with rest · headache that
does not resolve with rest · muscle weakness affecting balance · calf pain or swelling ·
decreased fetal movement.

→ **Code:** `PregnancyRedFlag`, surfaced on the plan and reachable from every pregnancy
workout. This list is deliberately not summarised or shortened in the UI.

---

## 9. After the birth (documented here; not generated yet)

- ACOG 804: physical activity may be resumed **gradually as soon as it is medically safe**,
  determined by the individual and their provider, and is protective against postpartum
  depression.
- Return to **running** specifically is later than return to activity. The postnatal return-
  to-running guideline recommends **no impact running before 12 weeks postpartum**, preceded
  by pelvic floor and graded load work, and gated on a criteria-based screen rather than the
  calendar — including walking 30 minutes symptom-free — ideally with a pelvic health
  physiotherapy assessment.
  Goom T, Donnelly G, Brockwell E. *Returning to running postnatal — guidelines for medical,
  health and fitness professionals managing this population.* 2019.

→ **Code:** the plan's final week hands off to `PregnancyRunningPolicy.postpartumHandoff`,
which states the 12-week floor and the criteria-based screen. Generating a postpartum
return-to-running plan is deliberately **out of scope** for this change: it is gated on a
clinical screen the app cannot perform.

---

## Deliberate non-goals

- **No heart-rate ceiling is prescribed.** See §3. Zones exist but are population-specific,
  and pregnancy shifts the HR–effort relationship the app would be reading.
- **No race, no intervals, no time trials, ever** — asserted by test. A pregnancy plan has
  no goal race, and `WorkoutType.race`/`.interval` never appear in one.
- **No weight, weight-gain, or energy-availability targets.** Gestational weight gain is a
  clinical matter and the app has no business prescribing it.
- **The AI coach cannot rewrite a pregnancy plan.** `AdaptableWorkoutSelector` returns no
  candidates for one, so neither Smart Adapt nor apply-coach-feedback can turn a pregnancy
  session back into a VDOT-paced one. `TrainingPlanService.refreshPaces` skips them for the
  same reason.
