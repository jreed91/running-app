import Foundation

// MARK: - PregnancyRunningPolicy

/// Every number a pregnancy plan is built from, in one place, each one carrying the source
/// it came from.
///
/// This type is deliberately pure and free of the plan-building machinery around it: the
/// rules are the part a clinician or a reviewer needs to be able to read and check, and
/// they should be readable without following a generator through five call sites. The long
/// form of each citation is in `docs/PREGNANCY_RUNNING_EVIDENCE.md`; the section numbers in
/// the comments below point at it.
///
/// **Stride is not a clinician.** These are the settings for a starting draft that a runner
/// with clearance from their own maternity provider can then take back to that provider.
enum PregnancyRunningPolicy {

    // MARK: The dose (§1)

    /// ACOG 804, SOGC/CSEP 2019, and WHO 2020 all land on the same floor: at least 150
    /// minutes of moderate-intensity activity per week during pregnancy. A generated week
    /// that prescribes less running than this is topped up with cross-training rather than
    /// left short.
    static let minimumWeeklyActiveMinutes = 150

    /// SOGC/CSEP 2019: accumulated over a minimum of three days per week, with activity on
    /// most days encouraged.
    static let minimumActiveDaysPerWeek = 3

    /// Below this a session is not worth scheduling as a run; the day becomes cross-training
    /// instead. Not a guideline figure — an editorial floor so late-pregnancy weeks do not
    /// degrade into a scatter of six-minute jogs.
    static let minimumSessionMinutes = 20

    /// What we assume a runner's pre-pregnancy weekly running was when they have not told us.
    /// Only a starting point: the setup screen asks, and the answer is what actually gets used.
    static func defaultWeeklyRunMinutes(for level: FitnessLevel) -> Int {
        switch level {
        case .beginner:     return 90
        case .intermediate: return 150
        case .advanced:     return 240
        case .competitive:  return 330
        }
    }

    // MARK: The volume curve (§2)

    /// The share of pre-pregnancy weekly *running* minutes retained at a given gestational
    /// week.
    ///
    /// Shaped by what runners are documented to actually do rather than by a prescription,
    /// because there is no prescribed running taper in any guideline. Tenforde et al. (2015,
    /// n = 110 competitive runners) found frequency essentially held across trimesters
    /// (6/6/5 days) while **duration** shortened and intensity fell, with cross-training
    /// taking up the difference; third-trimester volume reductions of 30–60% are the
    /// commonly reported range in recreational and competitive runners. This curve lands
    /// between 0.65 and 0.35 across the third trimester, which is that range.
    ///
    /// The corresponding *outcome* evidence is why the curve is a taper and not a stop:
    /// Kuhrt et al. (2018, n = 1,293) found continuing to run affected neither gestational
    /// age at delivery nor birthweight centile, at any weekly distance or trimester.
    static func runningVolumeShare(atGestationalWeek week: Int) -> Double {
        switch week {
        case ..<9:    return 1.00   // T1, early: no reason to change anything
        case 9...13:  return 0.90   // T1, late: fatigue and nausea are the usual limiter
        case 14...19: return 0.90   // T2, early: the trimester most runners feel best in
        case 20...23: return 0.85
        case 24...27: return 0.75
        case 28...31: return 0.65   // T3 begins
        case 32...34: return 0.55
        case 35...36: return 0.45
        default:      return 0.35   // 37+ weeks, term
        }
    }

    // MARK: Heat (§4)

    /// The longest single run a generated week will prescribe.
    ///
    /// A conservative *operating* limit, not a clinical threshold. Ravanelli et al. (BJSM
    /// 2019, 12 studies, n = 347) found no maternal core temperature above the 39.0 °C
    /// teratogenic threshold in any of the pooled data — the highest individual reading was
    /// 38.9 °C — including up to 35 minutes at 80–90% of maximum heart rate in 25 °C / 45%
    /// RH. Ordinary moderate running in temperate conditions is nowhere near that. These
    /// caps keep sessions inside the studied window with room to spare and cut dehydration
    /// exposure, and they also match the shortening durations Tenforde et al. observed.
    static func sessionMinutesCap(for trimester: PregnancyTrimester) -> Int {
        switch trimester {
        case .first:  return 90
        case .second: return 75
        case .third:  return 45
        }
    }

    static var heatAndHydrationNote: String {
        String(
            localized: "Drink before, during, and after. Skip or move the session indoors if it is hot or humid, and stop if you feel overheated.",
            comment: "Heat and hydration guidance attached to every pregnancy run"
        )
    }

    // MARK: Intensity (§3)

    /// Whether a moderate-effort ("can talk but not sing") session belongs in this week.
    ///
    /// ACOG 804 is explicit that women who habitually engaged in vigorous-intensity aerobic
    /// activity before pregnancy may continue it, so a runner who was doing quality work
    /// keeps one steadier session. It ends at 28 weeks: the third-trimester evidence base
    /// for vigorous work (Beetham et al. 2019) is reassuring but small and drawn almost
    /// entirely from already-trained women, which is not the margin to design a default on.
    static func allowsModerateSession(atGestationalWeek week: Int, habituallyVigorous: Bool) -> Bool {
        habituallyVigorous && week < 28
    }

    /// The longest continuous moderate-effort block inside a session. Keeps the sustained
    /// portion well inside Ravanelli et al.'s studied window (§4).
    static let moderateBlockMinutesCap = 20

    // MARK: Run/walk (§2)

    /// From the third trimester the default structure becomes run/walk. Pelvic pressure,
    /// balance, and heat all argue for breaking the run up, and it is the change runners
    /// report making themselves. Running the block continuously is fine if it feels fine —
    /// the workout note says so.
    static func usesRunWalk(atGestationalWeek week: Int) -> Bool { week >= 28 }

    static let runWalkRunMinutes = 4
    static let runWalkWalkMinutes = 1

    // MARK: Position and falls (§5)

    /// Exercising supine is avoided from here on: the gravid uterus compresses the inferior
    /// vena cava, lowering cardiac output and causing symptomatic hypotension (ACOG 804;
    /// SOGC/CSEP 2019).
    static let supineCutoffGestationalWeek = 16

    /// Where to run as pregnancy progresses. ACOG 804's fall-risk guidance names sports
    /// rather than surfaces — running is not on its list — so this applies the same logic to
    /// the thing this app actually schedules.
    static func terrainGuidance(for trimester: PregnancyTrimester) -> String {
        switch trimester {
        case .first:
            return String(
                localized: "Run your usual routes. Keep a phone with you and tell someone where you are going.",
                comment: "Pregnancy terrain guidance, first trimester"
            )
        case .second:
            return String(
                localized: "Favour even, well-lit surfaces. Your centre of gravity is moving, so leave technical trails for later.",
                comment: "Pregnancy terrain guidance, second trimester"
            )
        case .third:
            return String(
                localized: "Flat, familiar, even ground — or a treadmill. Balance changes fast now, and a fall matters more than a missed session.",
                comment: "Pregnancy terrain guidance, third trimester"
            )
        }
    }

    // MARK: Cross-training (§1, §2)

    /// The low-fall-risk moderate options the guidelines themselves name: brisk walking,
    /// stationary cycling, swimming and aqua aerobics, elliptical.
    static var crossTrainingNote: String {
        String(
            localized: "Brisk walking, stationary cycling, swimming, aqua aerobics, or the elliptical — anything moderate with no fall risk.",
            comment: "What counts as cross-training on a pregnancy plan"
        )
    }

    // MARK: Strength and pelvic floor (§1, §6)

    /// SOGC/CSEP 2019 recommends a variety of aerobic *and* resistance training. Volume
    /// eases in the third trimester alongside everything else.
    static func strengthSessionsPerWeek(for trimester: PregnancyTrimester) -> Int {
        trimester == .third ? 1 : 2
    }

    /// Daily pelvic floor muscle training, prescribed as an exercise so it travels with the
    /// strength session the runner actually opens.
    ///
    /// SOGC/CSEP 2019 recommends daily PFMT to reduce the risk of urinary incontinence.
    /// Cochrane (Woodley et al. 2020) found antenatal PFMT in continent women prevents the
    /// onset of urinary incontinence in late pregnancy and up to six months postpartum,
    /// NNT ≈ 4 — and found no benefit for women who are already incontinent. It is
    /// prophylaxis, which is why it starts on day one of the plan rather than when something
    /// goes wrong.
    static var pelvicFloorExercise: StrengthExercise {
        StrengthExercise(
            name: "Pelvic Floor (Kegel) Training",
            sets: 3,
            reps: 10,
            durationSeconds: nil,
            targetWeight: nil,
            notes: String(
                localized: "Every day, not just on strength days. Draw up and hold for 5 seconds, then fully release for 5 seconds. Breathe normally throughout — a squeeze you are holding your breath through is the wrong one.",
                comment: "Pelvic floor muscle training prescription in a pregnancy plan"
            ),
            muscleGroups: ["Pelvic Floor"]
        )
    }

    // MARK: Afterwards (§9)

    /// What the plan says at the end. Generating a postpartum return-to-running block is out
    /// of scope: the 2019 postnatal return-to-running guidance (Goom, Donnelly, Brockwell) is
    /// criteria-based, and the criteria are a clinical screen this app cannot perform.
    static var postpartumHandoff: String {
        String(
            localized: "After the birth, walking and pelvic floor work can restart as soon as your provider says so. Impact running is different: the postnatal guidance is no running before 12 weeks postpartum, and then only once you can walk 30 minutes and load your pelvic floor symptom-free — ideally after a pelvic health physiotherapy assessment. Stride will not schedule it for you.",
            comment: "Postpartum handoff shown at the end of a pregnancy plan"
        )
    }

    // MARK: The standing disclaimer

    /// One line, and the same line everywhere it appears — the setup screen, the screening
    /// list, the onboarding step, and the plan's guidance card. It was three sentences, and
    /// three sentences repeated on four screens reads as boilerplate, which is how a notice
    /// stops being read at all.
    static var medicalDisclaimer: String {
        String(
            localized: "Please consult your doctor before starting.",
            comment: "Standing disclaimer on a pregnancy training plan"
        )
    }
}

// MARK: - PregnancyStrengthAdapter

/// Makes a `StrengthLibrary` session appropriate for a given point in pregnancy.
///
/// The filter is deliberately narrow — it removes what a guideline actually names, and
/// annotates the rest. ACOG 804 supports resistance training throughout pregnancy, so
/// stripping a session down to nothing would be its own kind of wrong.
enum PregnancyStrengthAdapter {

    /// Exercises performed lying on the back. Excluded from `supineCutoffGestationalWeek`
    /// onward for aortocaval compression (§5). Matched by name against `StrengthLibrary`'s
    /// catalogue — if a supine exercise is added there, add it here too.
    static let supineExerciseNames: Set<String> = [
        "Glute Bridge",
        "Banded Glute Bridge",
        "Dead Bug",
        "Barbell Hip Thrust",
        "Bench Press",
        "DB Bench Press"
    ]

    /// Exercises whose whole shape is a floor-to-standing transition through supine. Same
    /// reason as above, but they cannot simply be re-cued into side-lying.
    static let supineTransitionExerciseNames: Set<String> = [
        "KB Turkish Get-Up"
    ]

    /// Single-leg work, kept but cued. Balance changes as the centre of gravity moves, and
    /// ACOG 804's fall-risk guidance is the reason to hold something rather than to stop.
    static let singleLegExerciseNames: Set<String> = [
        "Single-Leg Deadlift",
        "Single-Leg KB Deadlift",
        "Walking Lunge",
        "Step-Up",
        "DB Step-Up with Knee Drive",
        "DB Lateral Lunge",
        "Copenhagen Plank"
    ]

    static func adapt(
        _ plan: StrengthWorkoutPlan,
        atGestationalWeek week: Int
    ) -> StrengthWorkoutPlan {
        let avoidSupine = week >= PregnancyRunningPolicy.supineCutoffGestationalWeek

        var exercises = plan.exercises.filter { exercise in
            guard avoidSupine else { return true }
            return !supineExerciseNames.contains(exercise.name)
                && !supineTransitionExerciseNames.contains(exercise.name)
        }

        exercises = exercises.map { exercise in
            guard singleLegExerciseNames.contains(exercise.name) else { return exercise }
            var cued = exercise
            cued.notes = [exercise.notes, String(
                localized: "Hold a wall or rail — balance shifts as pregnancy progresses.",
                comment: "Balance cue added to single-leg strength work in pregnancy"
            )]
                .compactMap { $0 }
                .joined(separator: " ")
            return cued
        }

        // Pelvic floor training leads the session so it is the thing that gets done even on
        // a day the runner cuts short (§6).
        exercises.insert(PregnancyRunningPolicy.pelvicFloorExercise, at: 0)

        var note = String(
            localized: "Lighter loads, full control, and breathe out on the effort — no breath-holding.",
            comment: "Strength session guidance in pregnancy"
        )
        if avoidSupine {
            note += " " + String(
                localized: "Nothing flat on your back from 16 weeks: lying supine can drop your blood pressure. Side-lying or upright instead.",
                comment: "Supine-position guidance on a pregnancy strength session"
            )
        }

        return StrengthWorkoutPlan(
            focus: plan.focus,
            exercises: exercises,
            // The pelvic floor block adds a few minutes; the trimmed exercises take some back.
            estimatedDurationMinutes: max(20, plan.estimatedDurationMinutes),
            notes: note
        )
    }
}
