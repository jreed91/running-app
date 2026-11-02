import Foundation

// The run read's inputs: what a run is judged against (`ReadBasis`), the summary and focus
// areas the app works out before the model is asked (also the local summary when there is
// no model), and the workout details in the model's prompt.

extension AICoachService {

    /// What a run's read judges it against, worked out once so the local summary and the
    /// model's prompt cannot disagree about it.
    struct ReadBasis {
        /// The session the run was meant to be: the planned session's type when it
        /// fulfilled one, else its own. A run imported from the Watch carries a type guessed
        /// from its average pace, which is never `.interval` and is `.easy` for a tempo whose
        /// warm-up and cool-down pull the average down, so its own type is the fallback.
        let type: WorkoutType
        /// What the planned pace is for; for an unplanned run, what its type implies.
        let paceScope: CoachRunComparison.PlannedPaceScope
        /// The runner's usual for `type`, from the history handed to the read.
        let usual: CoachRunComparison.Baseline?
        /// The plan set this run's pace, so the plan, not the usual, says if it was right.
        let planSetsPace: Bool
        /// The heart-rate zones come from a max heart rate estimated from age.
        let maxHRIsEstimated: Bool

        /// Whether the splits were all meant to be one effort; see `RunWorkout.splitsAreOneEffort`.
        var isSteadyEffort: Bool { paceScope == .wholeRun }
    }

    func readBasis(
        workout: RunWorkout,
        recentHistory: [RunWorkout],
        profile: UserProfile?,
        plannedSession: ScheduledWorkout?
    ) -> ReadBasis {
        let type = plannedSession?.workoutType ?? workout.intendedWorkoutType
        let sameType = recentHistory.runsOnly
            .filter { $0.id != workout.id && $0.intendedWorkoutType == type }
            .map {
                CoachRunComparison.Sample(
                    paceSecondsPerKm: $0.averagePaceSecondsPerKm,
                    heartRate: $0.averageHeartRate,
                    distanceMeters: $0.distanceMeters
                )
            }
        return ReadBasis(
            type: type,
            paceScope: plannedSession?.paceScope
                ?? CoachRunComparison.plannedPaceScope(type: type, structure: nil, intervals: []),
            usual: CoachRunComparison.baseline(from: sameType),
            planSetsPace: plannedSession?.targetPaceRange != nil,
            maxHRIsEstimated: (profile?.maxHeartRateBPM ?? 0) <= 0
        )
    }

    /// "easy run", "long run", "race": a type as a noun a sentence can put after "this".
    static func sessionName(_ type: WorkoutType) -> String {
        let name = type.displayName.lowercased()
        return name.hasSuffix("run") || type == .race ? name : "\(name) run"
    }

    func makePromptContext(
        workout: RunWorkout,
        basis: ReadBasis,
        profile: UserProfile?,
        heartRateZones: [HRZoneSlice],
        unitPreference: UnitPreference
    ) -> (summary: String, focusAreas: [String]) {
        // Pace fade and heart-rate drift only mean something when the whole run was meant
        // to be one effort. Across a warm-up, reps and a cool-down both climb and fall by
        // design, and an interval session's heart rate rising from the warm-up to the last
        // rep was read as "accumulating fatigue".
        let drift = basis.isSteadyEffort ? paceDriftPercent(for: workout) : nil
        let hrDrift = basis.isSteadyEffort ? heartRateDrift(for: workout) : nil
        let session = Self.sessionName(basis.type)

        var focus: [String] = []
        var summaryBits: [String] = []

        if let drift {
            let driftPct = Int(drift.rounded())
            if drift <= 3 {
                summaryBits.append("Pacing held steady across the run (about \(driftPct)% drift).")
            } else if drift <= 7 {
                focus.append("Start 3–5 sec/\(unitPreference.distanceLabel) easier for the first 2 splits.")
                summaryBits.append("Pace faded around \(driftPct)% from the opening to the closing splits.")
            } else {
                focus.append("Pace conservatively early and protect form in final third.")
                summaryBits.append("A \(driftPct)% late-run fade suggests a pacing or endurance mismatch.")
            }
        }

        // Cardiac drift rises naturally on longer, harder, hotter, or hillier
        // efforts, so only surface it when it is clearly beyond the normal range
        // for this kind of run instead of flagging routine drift every time.
        if let hrDrift {
            let driftThreshold: Double
            switch basis.type {
            case .interval, .tempo, .race: driftThreshold = 16
            case .longRun: driftThreshold = 14
            default: driftThreshold = 12
            }
            if hrDrift > driftThreshold {
                focus.append("Add easy aerobic volume to rebuild durability before the next hard day.")
                summaryBits.append("Heart-rate drift of \(Int(hrDrift.rounded()))% ran high for this \(session), hinting at accumulating fatigue.")
            }
        }

        // The split table and the zone breakdown both sit above the coach card on the run
        // summary, so the read has to speak to them.
        let breakdown = breakdownContext(
            workout: workout,
            basis: basis,
            heartRateZones: heartRateZones,
            // The pace-drift bit above already frames the fade, so the half-to-half
            // comparison is only worth repeating when drift was not computed (fewer than
            // four splits) — and never for a session whose halves differ by design.
            includeHalfComparison: drift == nil && basis.isSteadyEffort,
            unitPreference: unitPreference
        )
        summaryBits.append(contentsOf: breakdown.summaryBits)
        focus.append(contentsOf: breakdown.focusAreas)

        // Against the runner's usual for this kind of run. This used to hold every run
        // against the average of their recent quality sessions, so nearly every easy and
        // long run read "slower than your recent quality baseline" and was told to
        // prioritise recovery. Only a steady effort without a planned pace is judged on
        // pace here: a planned pace is the plan line's to judge, and races differ too much
        // in distance for their average pace to make a usual.
        if basis.isSteadyEffort, !basis.planSetsPace, basis.type != .race,
           let usual = basis.usual, workout.averagePaceSecondsPerKm > 0 {
            let delta = workout.averagePaceSecondsPerKm - usual.paceSecondsPerKm
            if delta < -8 {
                summaryBits.append("This run was faster than your usual \(session).")
            } else if delta > 8 {
                summaryBits.append("This run was slower than your usual \(session).")
                if basis.type.isQualitySession {
                    focus.append("Prioritize recovery before the next quality day.")
                }
            }
        }

        // The runner's own rating is the one thing here they told us rather than a sensor
        // did, and it is what the numbers above cannot say: whether the run felt the way it
        // was meant to. It leads the focus list when it points somewhere.
        if let feel = workout.feel {
            summaryBits.append(RunFeelSignal.runSentence(feel: feel, type: basis.type))
            if let feelFocus = RunFeelSignal.runFocus(feel: feel, type: basis.type) {
                focus.insert(feelFocus, at: 0)
            }
        }

        // Conditions and terrain are unique to each run, so let them shape the
        // analysis rather than leaning on the same generic talking points.
        if let weather = workout.weather, weather.temperatureCelsius >= 24 {
            summaryBits.append("Warm conditions (\(weather.temperatureString(unit: unitPreference))) likely added cardiovascular strain, so weigh effort by feel over pace.")
        }
        if let elevationGain = workout.elevationGainMeters,
           workout.distanceMeters > 0,
           elevationGain / (workout.distanceMeters / 1_000) >= 15 {
            summaryBits.append("Notable climbing (\(elevationGain.elevationString(unit: unitPreference))) shaped pace and heart rate on this route.")
        }

        if focus.isEmpty {
            focus.append("Keep weekly consistency: 1 long run, 1 quality run, remaining easy.")
        }

        let raceContext = profile.map {
            "Goal: \(raceLabel(race: $0.goalRace, distanceMeters: $0.effectiveRaceDistanceMeters, unitPreference: unitPreference))."
        } ?? ""
        let summary = ([raceContext] + summaryBits)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return (summary: summary.isEmpty ? "No local summary available." : summary, focusAreas: Array(focus.prefix(3)))
    }

    /// Summary sentences and focus items drawn from the run's splits and its time-in-zone
    /// breakdown — the two blocks the run summary shows directly above the coaching read.
    private func breakdownContext(
        workout: RunWorkout,
        basis: ReadBasis,
        heartRateZones: [HRZoneSlice],
        includeHalfComparison: Bool,
        unitPreference: UnitPreference
    ) -> (summaryBits: [String], focusAreas: [String]) {
        var summaryBits: [String] = []
        var focus: [String] = []

        if let trend = CoachRunBreakdown.splitTrend(splits: workout.splits, unit: unitPreference) {
            let splitLabel = workout.splitUnit.distanceLabel
            summaryBits.append(
                includeHalfComparison
                    ? CoachRunBreakdown.splitTrendSentence(trend, splitLabel: splitLabel, unit: unitPreference)
                    : CoachRunBreakdown.splitRangeSentence(trend, splitLabel: splitLabel, unit: unitPreference)
            )
        }

        if let zoneSentence = CoachRunBreakdown.zoneSentence(heartRateZones) {
            summaryBits.append(zoneSentence)
        }

        // Cadence: captured on every run but discarded at finish until A5, so no coaching
        // read — local or model — could ever say anything about form.
        // Judged against the run's pace: cadence falls as pace slows.
        let cadence = workout.averageCadenceStepsPerMinute
        let pace = workout.averagePaceSecondsPerKm
        if let cadenceSentence = CoachRunBreakdown.cadenceSentence(cadence, paceSecondsPerKm: pace) {
            summaryBits.append(cadenceSentence)
        }
        if let cadenceFocus = CoachRunBreakdown.cadenceFocus(cadence, workoutType: basis.type, paceSecondsPerKm: pace) {
            focus.append(cadenceFocus)
        }

        // An easy or long run that spent a big share of its time at threshold or above is
        // the one zone read that changes the next session's advice. Not from zones built on
        // an age-estimated max heart rate: those can sit well under a fit runner's real
        // max and put an easy run "at threshold", which the instructions already tell the
        // model not to call too hard on its own.
        if let hardShare = CoachRunBreakdown.hardEffortShare(heartRateZones),
           hardShare >= 0.20,
           !basis.maxHRIsEstimated,
           basis.type == .easy || basis.type == .longRun {
            focus.append(
                "Hold the next \(Self.sessionName(basis.type)) by effort in Z1–Z2 — "
                    + "\(Int((hardShare * 100).rounded()))% of this one sat at threshold or harder."
            )
        }

        return (summaryBits: summaryBits, focusAreas: focus)
    }

    private func paceDriftPercent(for workout: RunWorkout) -> Double? {
        guard workout.splits.count >= 4 else { return nil }
        let quarter = max(1, workout.splits.count / 4)
        let first = workout.splits.prefix(quarter).reduce(0) { $0 + $1.paceSecondsPerKm } / Double(quarter)
        let last = workout.splits.suffix(quarter).reduce(0) { $0 + $1.paceSecondsPerKm } / Double(quarter)
        guard first > 0 else { return nil }
        return max(0, ((last - first) / first) * 100)
    }

    private func heartRateDrift(for workout: RunWorkout) -> Double? {
        let hrs = workout.splits.compactMap(\.heartRate)
        guard hrs.count >= 4 else { return nil }
        let quarter = max(1, hrs.count / 4)
        let first = hrs.prefix(quarter).reduce(0, +) / Double(quarter)
        let last = hrs.suffix(quarter).reduce(0, +) / Double(quarter)
        guard first > 0 else { return nil }
        return ((last - first) / first) * 100
    }

    func makeWorkoutDetails(
        workout: RunWorkout,
        basis: ReadBasis,
        recentHistory: [RunWorkout],
        profile: UserProfile?,
        heartRateZones: [HRZoneSlice],
        unitPreference: UnitPreference,
        plannedSession: ScheduledWorkout?,
        nextPlannedSession: ScheduledWorkout?
    ) -> String {
        let date = workout.date.formatted(date: .abbreviated, time: .shortened)
        let avgPace = workout.averagePaceSecondsPerKm.paceString(unit: unitPreference)
        let avgHR = workout.averageHeartRate.map { "\(Int($0)) bpm" } ?? "n/a"
        let maxHR = workout.maxHeartRate.map { "\(Int($0)) bpm" } ?? "n/a"
        let elevation = workout.elevationGainMeters.map { $0.elevationString(unit: unitPreference) } ?? "n/a"
        // The one form signal the app records. Given raw rather than judged — the model has
        // the run's pace and type beside it, which is what makes a number interpretable (A5).
        let cadence = workout.averageCadenceStepsPerMinute
            .map { "\(Int($0.rounded())) spm" } ?? "n/a"
        let weather = workout.weather.map {
            "\($0.conditionDescription), \($0.temperatureString(unit: unitPreference)), humidity \(Int($0.humidityPercent))%"
        } ?? "n/a"
        let feel = workout.feel?.promptDescription ?? "not rated"
        let profileContext = profile.map {
            "Goal race: \(raceLabel(race: $0.goalRace, distanceMeters: $0.effectiveRaceDistanceMeters, unitPreference: unitPreference)), fitness level: \($0.fitnessLevel.displayName), run days/week: \($0.weeklyRunDays)"
        } ?? "No athlete profile available."

        // Splits and zones are what the runner sees immediately above the coach card, so the
        // prompt carries the same two blocks: every split (middle ones dropped only on very
        // long runs), the derived pacing trend, and the time-in-zone table.
        let splitLabel = workout.splitUnit.distanceLabel
        let splitSection = CoachRunBreakdown.splitSection(
            splits: workout.splits,
            unit: unitPreference,
            splitLabel: splitLabel
        )
        var splitTrendSection = CoachRunBreakdown
            .splitTrend(splits: workout.splits, unit: unitPreference)
            .map { CoachRunBreakdown.splitTrendLine($0, splitLabel: splitLabel, unit: unitPreference) }
            ?? "Not enough splits to derive a trend."
        // The trend line's half-to-half comparison reads as a fade or a negative split. For
        // a session that runs easy, hard and easy again by design, say so beside it.
        if !basis.isSteadyEffort {
            splitTrendSection += "\nThese splits mix the work with the easy running around it, so a "
                + "slower or faster half is the session's shape, not a fade."
        }
        let zoneSection = CoachRunBreakdown.zoneSection(
            heartRateZones,
            maxHR: profile?.effectiveMaxHeartRate.map(Double.init),
            maxHRIsEstimated: basis.maxHRIsEstimated
        )

        let recent = recentHistory.runsOnly.prefix(5).map { run in
            "\(run.date.formatted(date: .abbreviated, time: .omitted)) • \(run.intendedWorkoutType.displayName) • \(run.distanceMeters.distanceString(unit: unitPreference)) • \(run.averagePaceSecondsPerKm.paceString(unit: unitPreference))"
                + (run.averageHeartRate.map { " • \(Int($0.rounded())) bpm" } ?? "")
                + (run.feel.map { " • felt \($0.promptName)" } ?? "")
        }.joined(separator: "\n")

        // The references a verdict needs: what this run was meant to be, what is usual for
        // this kind of run, and what comes next. Without them the coach can only restate
        // the totals and fall back on general advice.
        let planSection = plannedSessionSection(plannedSession, workout: workout, unitPreference: unitPreference)
        let usualSection = CoachRunComparison.baselineLine(
            typeName: basis.type.displayName,
            currentPaceSecondsPerKm: workout.averagePaceSecondsPerKm,
            currentHeartRate: workout.averageHeartRate,
            baseline: basis.usual,
            unit: unitPreference
        ) + (basis.planSetsPace ? " " + CoachRunComparison.planSetsPaceNote : "")
        let nextSection = nextPlannedSession.map {
            "\($0.scheduledDate.formatted(.dateTime.weekday(.wide))): "
                + plannedTargetsDescription($0, unitPreference: unitPreference)
        } ?? "Nothing planned yet."
        let recentSection = recent.isEmpty ? "No recent runs." : recent

        // Every figure below is in the runner's unit, but the instructions' examples are
        // written in kilometres; without this line a runner who reads miles could get a
        // mile figure labelled "per km".
        let units = unitPreference == .imperial
            ? "miles: write every pace per mile and every distance in miles"
            : "kilometres: write every pace per km and every distance in km"

        return """
        Units: \(units).
        Date: \(date)
        Type: \(basis.type.displayName)
        Distance: \(workout.distanceMeters.distanceString(unit: unitPreference))
        Duration: \(workout.durationSeconds.durationString)
        Avg pace: \(avgPace)
        Avg HR: \(avgHR)
        Max HR: \(maxHR)
        Avg cadence: \(cadence)
        Elevation gain: \(elevation)
        Weather: \(weather)
        How it felt to the runner: \(feel)
        \(profileContext)

        What this run was meant to be:
        \(planSection)

        Compared with your usual:
        \(usualSection)

        Next planned run:
        \(nextSection)

        Splits (one per \(splitLabel)):
        \(splitSection)

        Split trend: \(splitTrendSection)

        Time in heart-rate zones:
        \(zoneSection)

        Recent history:
        \(recentSection)
        """
    }
}
