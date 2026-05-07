import Foundation

// MARK: - TrainingPlanService

/// Generates a periodised training plan using the 80/20 principle and VDOT-based pacing.
struct TrainingPlanService {

    // MARK: Public API

    /// Builds a complete `TrainingPlan` from the runner's profile.
    ///
    /// - Parameters:
    ///   - profile: The runner's goal, fitness level, and available days.
    ///   - startDate: First day of training (typically next Monday).
    ///   - numberOfWeeks: Total plan length; must be within `profile.goalRace.typicalWeeks`.
    func generatePlan(
        profile: UserProfile,
        startDate: Date,
        numberOfWeeks: Int,
        runDayIndices: [Int] = [],
        unitPreference: UnitPreference = .metric
    ) -> TrainingPlan {
        generatePlan(
            profile: profile,
            startDate: startDate,
            numberOfWeeks: numberOfWeeks,
            endDate: startDate.adding(weeks: numberOfWeeks),
            raceName: nil,
            raceDate: nil,
            runDayIndices: runDayIndices,
            unitPreference: unitPreference
        )
    }

    /// Builds a race-specific plan that ends on the exact goal race date.
    func generateRacePlan(
        profile: UserProfile,
        startDate: Date,
        raceDate: Date,
        raceName: String,
        runDayIndices: [Int] = [],
        unitPreference: UnitPreference = .metric
    ) -> TrainingPlan {
        guard profile.goalRace.isGoalRace else {
            return generatePlan(
                profile: profile,
                startDate: startDate,
                numberOfWeeks: profile.goalRace.typicalWeeks.lowerBound,
                runDayIndices: runDayIndices,
                unitPreference: unitPreference
            )
        }
        let numberOfWeeks = weeksThroughRaceDate(startDate: startDate, raceDate: raceDate)
        return generatePlan(
            profile: profile,
            startDate: startDate.startOfDay,
            numberOfWeeks: numberOfWeeks,
            endDate: raceDate.startOfDay,
            raceName: raceName,
            raceDate: raceDate.startOfDay,
            runDayIndices: runDayIndices,
            unitPreference: unitPreference
        )
    }

    private func generatePlan(
        profile: UserProfile,
        startDate: Date,
        numberOfWeeks: Int,
        endDate: Date,
        raceName: String?,
        raceDate: Date?,
        runDayIndices: [Int],
        unitPreference: UnitPreference
    ) -> TrainingPlan {
        let plan = TrainingPlan(
            targetRace: profile.goalRace,
            goalTimeSeconds: profile.goalFinishTime,
            raceName: raceName,
            raceDate: raceDate,
            startDate: startDate,
            endDate: endDate
        )

        let vdot = estimatedVDOT(from: profile)
        let paces = PaceCalculatorService.trainingPaces(forVDOT: vdot)
        let phases = phaseSchedule(totalWeeks: numberOfWeeks, raceType: profile.goalRace)
        let baseKm = profile.fitnessLevel.startingWeeklyKm(for: profile.goalRace)

        // Prefer explicit indices; fall back to even distribution from profile
        let effectiveDayOffsets: [Int]? = runDayIndices.isEmpty ? nil : sanitizeDayOffsets(runDayIndices)

        for (index, phase) in phases.enumerated() {
            let weekStart = startDate.adding(weeks: index)
            let targetKm = weeklyKm(
                base: baseKm,
                weekIndex: index,
                totalWeeks: numberOfWeeks,
                phase: phase,
                raceType: profile.goalRace
            )
            let week = TrainingWeek(
                weekNumber: index + 1,
                startDate: weekStart,
                phase: phase,
                targetDistanceKm: targetKm
            )
            let workouts = buildWorkouts(
                weekStart: weekStart,
                runDays: profile.weeklyRunDays,
                dayOffsets: effectiveDayOffsets,
                phase: phase,
                paces: paces,
                raceType: profile.goalRace,
                targetKm: targetKm,
                unitPreference: unitPreference
            )
            let weekWorkouts: [ScheduledWorkout]
            if let raceDate,
               profile.goalRace != .maintainFitness,
               index == phases.count - 1 {
                weekWorkouts = workoutsForRaceWeek(
                    workouts,
                    raceDate: raceDate,
                    raceType: profile.goalRace,
                    raceName: raceName,
                    paces: paces
                )
            } else {
                weekWorkouts = workouts
            }
            // Auto-apply structured warmup/work/cooldown to all quality and long-run sessions.
            // Uses profile-derived VDOT with no history (onTrack defaults) so the plan is
            // immediately structured. Users can re-adapt later via the detail view to
            // personalise based on their actual run history.
            for workout in weekWorkouts {
                guard workout.workoutType != .rest,
                      workout.workoutType != .race,
                      workout.workoutType != .crossTraining,
                      workout.workoutType != .strength else { continue }
                let adapted = adaptWorkout(scheduled: workout, history: [], profile: profile, unitPreference: unitPreference)
                workout.structureData        = adapted.structureData
                workout.targetDistanceMeters = adapted.targetDistanceMeters
                workout.targetPaceLowerBound = adapted.targetPaceLowerBound
                workout.targetPaceUpperBound = adapted.targetPaceUpperBound
                workout.notes                = adapted.notes
                if !adapted.intervals.isEmpty {
                    workout.intervals = adapted.intervals
                }
            }
            let strengthWorkouts = buildStrengthWorkouts(
                weekStart: weekStart,
                existingWorkouts: weekWorkouts,
                profile: profile,
                phase: phase
            )
            week.workouts = weekWorkouts + strengthWorkouts
            plan.weeks = (plan.weeks ?? []) + [week]
        }
        return plan
    }

    // MARK: - Strength Day Insertion

    private func buildStrengthWorkouts(
        weekStart: Date,
        existingWorkouts: [ScheduledWorkout],
        profile: UserProfile,
        phase: TrainingPhase
    ) -> [ScheduledWorkout] {
        let equipment = profile.selectedEquipment
        guard !equipment.isEmpty else { return [] }

        let focus = profile.strengthFocus

        // Determine how many strength days to insert based on phase and focus
        let maxStrengthDays: Int
        switch (phase, focus) {
        case (.taper, _):          maxStrengthDays = profile.fitnessLevel == .beginner ? 0 : 1
        case (.peak, _):           maxStrengthDays = 1
        case (_, .generalStrength): maxStrengthDays = 1
        default:                   maxStrengthDays = 2
        }
        guard maxStrengthDays > 0 else { return [] }

        // Build a set of occupied day-offsets (0=Mon … 6=Sun) and find quality/long-run days
        var occupiedOffsets = Set<Int>()
        var qualityOrLongRunOffsets = Set<Int>()
        for workout in existingWorkouts {
            let offset = dayOffset(from: weekStart, to: workout.scheduledDate)
            occupiedOffsets.insert(offset)
            if workout.workoutType == .longRun || workout.workoutType.isQualitySession {
                qualityOrLongRunOffsets.insert(offset)
            }
        }

        // Candidate offsets: unoccupied, not adjacent to a quality or long-run day
        var candidates: [Int] = []
        for offset in 0...6 {
            guard !occupiedOffsets.contains(offset) else { continue }
            let adjacentToProtected = qualityOrLongRunOffsets.contains(offset - 1)
                || qualityOrLongRunOffsets.contains(offset + 1)
            if !adjacentToProtected {
                candidates.append(offset)
            }
        }

        let plan = StrengthLibrary.plan(for: equipment, focus: focus, phase: phase)
        var result: [ScheduledWorkout] = []
        for offset in candidates.prefix(maxStrengthDays) {
            let date = weekStart.adding(days: offset)
            let workout = ScheduledWorkout(
                scheduledDate: date,
                workoutType: .strength,
                notes: "\(focus.displayName) strength — \(plan.estimatedDurationMinutes) min"
            )
            workout.strengthPlan = plan
            result.append(workout)
        }
        return result
    }

    private func dayOffset(from weekStart: Date, to date: Date) -> Int {
        let cal = Calendar.current
        let start = cal.startOfDay(for: weekStart)
        let target = cal.startOfDay(for: date)
        return max(0, cal.dateComponents([.day], from: start, to: target).day ?? 0)
    }

    private func weeksThroughRaceDate(startDate: Date, raceDate: Date) -> Int {
        let start = startDate.startOfDay
        let race = raceDate.startOfDay
        let days = Calendar.current.dateComponents([.day], from: start, to: race).day ?? 0
        return max(1, Int(ceil(Double(max(days, 0) + 1) / 7.0)))
    }

    private func workoutsForRaceWeek(
        _ workouts: [ScheduledWorkout],
        raceDate: Date,
        raceType: RaceType,
        raceName: String?,
        paces: TrainingPaces
    ) -> [ScheduledWorkout] {
        let raceDay = raceDate.startOfDay
        let trainingWorkouts = workouts.filter {
            $0.scheduledDate.startOfDay < raceDay
        }
        return trainingWorkouts + [
            raceWorkout(date: raceDay, raceType: raceType, raceName: raceName, paces: paces)
        ]
    }

    private func raceWorkout(
        date: Date,
        raceType: RaceType,
        raceName: String?,
        paces: TrainingPaces
    ) -> ScheduledWorkout {
        let racePace = targetRacePace(for: raceType, paces: paces)
        let displayName = raceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteName = (displayName?.isEmpty == false ? displayName : nil) ?? raceType.displayName
        return ScheduledWorkout(
            scheduledDate: date.startOfDay,
            workoutType: .race,
            targetDistanceMeters: raceType.distanceMeters,
            targetPaceLowerBound: racePace - 5,
            targetPaceUpperBound: racePace + 5,
            notes: "\(noteName) goal race. Trust the taper, start controlled, and race the final third."
        )
    }

    private func targetRacePace(for raceType: RaceType, paces: TrainingPaces) -> Double {
        switch raceType {
        case .maintainFitness: return paces.easyRange.lowerBound
        case .fiveK: return paces.interval
        case .halfMarathon: return (paces.threshold + paces.marathon) / 2
        case .marathon: return paces.marathon
        }
    }

    // MARK: Phase schedule

    /// Maps each week index to a `TrainingPhase`.
    ///
    /// Layout:
    /// - 5K     (8–12 w):  Base 40% | Build 30% | Peak 20% | Taper 10%
    /// - HM    (12–20 w):  Base 40% | Build 35% | Peak 15% | Taper 10%
    /// - Marathon (16–24 w): Base 40% | Build 30% | Peak 18% | Taper 12%
    private func phaseSchedule(totalWeeks: Int, raceType: RaceType) -> [TrainingPhase] {
        let taperWeeks: Int
        let peakWeeks: Int
        let buildWeeks: Int
        switch raceType {
        case .maintainFitness:
            taperWeeks = max(1, Int(Double(totalWeeks) * 0.10))
            peakWeeks  = max(1, Int(Double(totalWeeks) * 0.15))
            buildWeeks = max(1, Int(Double(totalWeeks) * 0.25))
        case .fiveK:
            taperWeeks = max(1, Int(Double(totalWeeks) * 0.10))
            peakWeeks  = max(1, Int(Double(totalWeeks) * 0.20))
            buildWeeks = max(1, Int(Double(totalWeeks) * 0.30))
        case .halfMarathon:
            taperWeeks = max(1, Int(Double(totalWeeks) * 0.10))
            peakWeeks  = max(1, Int(Double(totalWeeks) * 0.15))
            buildWeeks = max(1, Int(Double(totalWeeks) * 0.35))
        case .marathon:
            taperWeeks = max(2, Int(Double(totalWeeks) * 0.12))
            peakWeeks  = max(2, Int(Double(totalWeeks) * 0.18))
            buildWeeks = max(1, Int(Double(totalWeeks) * 0.30))
        }
        let baseWeeks = totalWeeks - taperWeeks - peakWeeks - buildWeeks

        return Array(repeating: .base, count: baseWeeks)
             + Array(repeating: .build, count: buildWeeks)
             + Array(repeating: .peak, count: peakWeeks)
             + Array(repeating: .taper, count: taperWeeks)
    }

    // MARK: Weekly mileage progression

    private func weeklyKm(
        base: Double,
        weekIndex: Int,
        totalWeeks: Int,
        phase: TrainingPhase,
        raceType: RaceType
    ) -> Double {
        switch phase {
        case .taper:
            return base * 0.55
        case .peak:
            let maxKm = raceType == .maintainFitness ? base * 1.2 : base * 1.5
            return maxKm
        case .build, .base:
            // 10% increase per week with a cutback every 4th week
            let isCutback = (weekIndex + 1) % 4 == 0
            let multiplier = isCutback
                ? pow(1.10, Double(weekIndex - 1))  // step back ~20%
                : pow(1.10, Double(weekIndex))
            return min(base * multiplier, base * 1.45)
        }
    }

    // MARK: VDOT estimate

    private func estimatedVDOT(from profile: UserProfile) -> Double {
        if let time5K = profile.currentEstimated5KTimeSeconds, time5K > 0 {
            return PaceCalculatorService.vdot(distanceMeters: 5_000, timeSeconds: time5K)
        }
        let baseline = baselineVDOT(from: profile)
        guard profile.goalFinishTime > 0 else { return baseline }

        // Use goal race/time as a directional signal while keeping the outcome bounded
        // by a fitness-level prior to avoid over-prescribing intensity from optimistic goals.
        let goalVDOT = PaceCalculatorService.vdot(
            distanceMeters: profile.goalRace.distanceMeters,
            timeSeconds: profile.goalFinishTime
        )
        guard goalVDOT.isFinite, goalVDOT > 0 else { return baseline }

        let blendWeight: Double
        let maxDelta: Double
        switch profile.fitnessLevel {
        case .beginner:
            blendWeight = 0.20
            maxDelta = 5.0
        case .intermediate:
            blendWeight = 0.35
            maxDelta = 7.0
        case .advanced:
            blendWeight = 0.50
            maxDelta = 9.0
        }
        let blended = baseline * (1.0 - blendWeight) + goalVDOT * blendWeight
        return min(max(blended, baseline - maxDelta), baseline + maxDelta)
    }

    /// Derive a rough baseline VDOT from fitness level and gender.
    private func baselineVDOT(from profile: UserProfile) -> Double {
        let fallback5KSeconds: Double
        switch profile.gender {
        case .female:
            switch profile.fitnessLevel {
            case .beginner:     fallback5KSeconds = 40 * 60   // 40:00
            case .intermediate: fallback5KSeconds = 31 * 60   // 31:00
            case .advanced:     fallback5KSeconds = 24 * 60   // 24:00
            }
        case .male, .preferNotToShare:
            switch profile.fitnessLevel {
            case .beginner:     fallback5KSeconds = 35 * 60   // 35:00
            case .intermediate: fallback5KSeconds = 27 * 60   // 27:00
            case .advanced:     fallback5KSeconds = 21 * 60   // 21:00
            }
        }
        return PaceCalculatorService.vdot(distanceMeters: 5_000, timeSeconds: fallback5KSeconds)
    }

    // MARK: Workout builder

    private func buildWorkouts(
        weekStart: Date,
        runDays: Int,
        dayOffsets: [Int]?,
        phase: TrainingPhase,
        paces: TrainingPaces,
        raceType: RaceType,
        targetKm: Double,
        unitPreference: UnitPreference
    ) -> [ScheduledWorkout] {
        let days = dayOffsets ?? runDayOffsets(count: runDays)
        var workouts: [ScheduledWorkout] = []

        // Determine quality session types for the week
        let qualityTypes = weekQualityTypes(phase: phase, raceType: raceType)

        // Pre-calculate volume distribution so every easy run gets an equal share of
        // whatever weekly km remains after the long run and quality sessions are budgeted.
        // qualitySlots: quality sessions that fit (all slots except the long-run slot)
        // easySlots:    remaining slots after quality + long run
        let qualityCap = qualitySessionCap(runDays: days.count, phase: phase, raceType: raceType)
        let qualitySlots = min(qualityTypes.count, min(max(0, days.count - 1), qualityCap))
        let easySlots    = max(0, days.count - qualitySlots - 1)
        let totalQualityFraction = 0.15 * Double(qualitySlots)
        let easyFractionEach = easySlots > 0
            ? max(0.0, 1.0 - 0.35 - totalQualityFraction) / Double(easySlots)
            : 0.0
        let easyKmEach = targetKm * easyFractionEach

        for (slotIndex, dayOffset) in days.enumerated() {
            let date = weekStart.adding(days: dayOffset)

            // Last run day of the week → long run
            if slotIndex == days.count - 1 {
                let longKm = targetKm * 0.35
                workouts.append(longRunWorkout(date: date, km: longKm, paces: paces))
                continue
            }

            // Insert a quality session if the slot index matches
            if slotIndex < qualitySlots {
                workouts.append(qualityWorkout(
                    date: date,
                    type: qualityTypes[slotIndex],
                    targetKm: targetKm * 0.15,
                    paces: paces,
                    raceType: raceType,
                    unitPreference: unitPreference
                ))
                continue
            }

            // Remaining days → easy runs with equally distributed volume
            workouts.append(easyWorkout(date: date, km: easyKmEach, paces: paces))
        }

        return workouts
    }

    // MARK: Workout factories

    private func easyWorkout(date: Date, km: Double, paces: TrainingPaces) -> ScheduledWorkout {
        ScheduledWorkout(
            scheduledDate: date,
            workoutType: .easy,
            targetDistanceMeters: km * 1_000,
            targetPaceLowerBound: paces.easyRange.lowerBound,
            targetPaceUpperBound: paces.easyRange.upperBound,
            notes: "Conversational effort – you should be able to speak in sentences."
        )
    }

    private func longRunWorkout(date: Date, km: Double, paces: TrainingPaces) -> ScheduledWorkout {
        ScheduledWorkout(
            scheduledDate: date,
            workoutType: .longRun,
            targetDistanceMeters: km * 1_000,
            targetPaceLowerBound: paces.easyRange.lowerBound,
            targetPaceUpperBound: paces.easyRange.upperBound,
            notes: "Keep it easy. Build your aerobic base and practice fuelling if ≥ 90 min."
        )
    }

    private func qualityWorkout(
        date: Date,
        type: WorkoutType,
        targetKm: Double,
        paces: TrainingPaces,
        raceType: RaceType,
        unitPreference: UnitPreference
    ) -> ScheduledWorkout {
        switch type {
        case .tempo:
            return ScheduledWorkout(
                scheduledDate: date,
                workoutType: .tempo,
                targetDistanceMeters: targetKm * 1_000,
                targetPaceLowerBound: paces.threshold - 5,
                targetPaceUpperBound: paces.threshold + 5,
                notes: "Comfortably hard – you can speak a word or two but not a sentence."
            )
        case .interval:
            let workout = ScheduledWorkout(
                scheduledDate: date,
                workoutType: .interval,
                targetDistanceMeters: nil,
                targetPaceLowerBound: paces.interval - 5,
                targetPaceUpperBound: paces.interval + 5,
                notes: intervalNote(raceType: raceType, unitPreference: unitPreference)
            )
            workout.intervals = defaultIntervals(raceType: raceType, paces: paces)
            return workout
        default:
            return easyWorkout(date: date, km: targetKm, paces: paces)
        }
    }

    // MARK: Plan helpers

    /// Spread run days evenly across Mon-Sun (0=Mon … 6=Sun).
    private func runDayOffsets(count: Int) -> [Int] {
        guard count > 0 && count <= 7 else { return [] }
        let step = 7.0 / Double(count)
        return (0..<count).map { Int(Double($0) * step) }
    }

    /// Normalizes run-day offsets into unique Mon-Sun indices.
    private func sanitizeDayOffsets(_ offsets: [Int]) -> [Int] {
        Array(Set(offsets.filter { (0...6).contains($0) })).sorted()
    }

    /// Caps weekly quality frequency to keep plans sustainable at lower run-day counts.
    /// 3 days/week: max 1 quality + 1 long run.
    /// 4+ days/week: up to 2 quality sessions in peak/build phases.
    private func qualitySessionCap(runDays: Int, phase: TrainingPhase, raceType: RaceType) -> Int {
        if runDays <= 3 { return 1 }
        if runDays == 4 && raceType == .marathon && phase == .build { return 1 }
        return 2
    }

    private func weekQualityTypes(phase: TrainingPhase, raceType: RaceType) -> [WorkoutType] {
        switch (phase, raceType) {
        case (.base, .maintainFitness):    return [.tempo]
        case (.build, .maintainFitness):   return [.tempo]
        case (.peak, .maintainFitness):    return [.tempo, .interval]
        case (.taper, .maintainFitness):   return [.tempo]
        case (.base, _):                  return [.tempo]
        case (.build, .fiveK):            return [.interval, .tempo]
        case (.build, .halfMarathon):     return [.tempo, .interval]
        case (.build, .marathon):         return [.tempo, .tempo]
        case (.peak, .marathon):          return [.tempo, .interval]
        case (.peak, _):                  return [.interval, .tempo]
        case (.taper, _):                 return [.tempo]
        default:                          return []
        }
    }

    private func defaultIntervals(raceType: RaceType, paces: TrainingPaces) -> [WorkoutInterval] {
        switch raceType {
        case .maintainFitness:
            // 5 × 3 min @ interval pace, 90 s jog recovery
            return [WorkoutInterval(
                repetitions: 5,
                distanceMeters: nil,
                durationSeconds: 180,
                targetPaceSecondsPerKm: paces.interval,
                recoverySeconds: 90,
                recoveryType: .jog
            )]
        case .fiveK:
            // 6 × 800 m @ interval pace, 90 s jog recovery
            return [WorkoutInterval(
                repetitions: 6,
                distanceMeters: 800,
                durationSeconds: nil,
                targetPaceSecondsPerKm: paces.interval,
                recoverySeconds: 90,
                recoveryType: .jog
            )]
        case .halfMarathon:
            // 5 × 1000 m @ interval pace, 90 s jog recovery
            return [WorkoutInterval(
                repetitions: 5,
                distanceMeters: 1_000,
                durationSeconds: nil,
                targetPaceSecondsPerKm: paces.interval,
                recoverySeconds: 90,
                recoveryType: .jog
            )]
        case .marathon:
            // 4 × 1200 m @ interval pace, 2 min jog recovery
            return [WorkoutInterval(
                repetitions: 4,
                distanceMeters: 1_200,
                durationSeconds: nil,
                targetPaceSecondsPerKm: paces.interval,
                recoverySeconds: 120,
                recoveryType: .jog
            )]
        }
    }

    private func intervalNote(raceType: RaceType, unitPreference: UnitPreference) -> String {
        switch raceType {
        case .maintainFitness:
            return "5 × 3 min @ interval pace with 90 s jog recovery."
        case .fiveK:
            return "6 × \(shortDistanceString(800, unit: unitPreference)) @ interval pace with 90 s jog recovery. Hard but controlled."
        case .halfMarathon:
            return "5 × \(shortDistanceString(1_000, unit: unitPreference)) @ interval pace with 90 s jog recovery."
        case .marathon:
            return "4 × \(shortDistanceString(1_200, unit: unitPreference)) @ interval pace with 2 min jog recovery."
        }
    }

    /// Formats meters as a short distance string using the user's unit preference.
    /// Sub-mile distances use meters (metric) or yards (imperial); longer distances use km or mi.
    private func shortDistanceString(_ meters: Double, unit: UnitPreference) -> String {
        switch unit {
        case .metric:
            return meters >= 1_000
                ? String(format: "%.1f km", meters / 1_000)
                : String(format: "%.0f m", meters)
        case .imperial:
            let miles = meters / 1_609.344
            return miles >= 1.0
                ? String(format: "%.1f mi", miles)
                : String(format: "%.0f yd", meters * 1.09361)
        }
    }

    // MARK: - Smart Workout Adaptation

    /// Returns a new ``ScheduledWorkout`` whose structure, pace targets, and volume have
    /// been adapted to the runner's recent performance history.
    ///
    /// For `.rest` and `.crossTraining` workouts, the original is returned unchanged.
    /// The returned object is a fresh instance; the caller should copy its fields back onto the
    /// persisted workout rather than inserting it into the SwiftData context.
    func adaptWorkout(
        scheduled: ScheduledWorkout,
        history: [RunWorkout],
        profile: UserProfile,
        unitPreference: UnitPreference = .metric
    ) -> ScheduledWorkout {
        guard scheduled.workoutType != .rest,
              scheduled.workoutType != .crossTraining,
              scheduled.workoutType != .strength else {
            return scheduled
        }

        let analytics = WorkoutAnalyticsService()
        let snap = analytics.snapshot(from: history, profile: profile)
        let effectiveVDOT = snap.currentVDOT ?? estimatedVDOT(from: profile)
        let paces = PaceCalculatorService.trainingPaces(forVDOT: effectiveVDOT)

        switch scheduled.workoutType {
        case .interval:
            return adaptIntervalWorkout(scheduled: scheduled, paces: paces, snap: snap, unitPreference: unitPreference)
        case .tempo:
            return adaptTempoWorkout(scheduled: scheduled, paces: paces, snap: snap, unitPreference: unitPreference)
        case .longRun:
            return adaptLongRunWorkout(scheduled: scheduled, paces: paces, snap: snap, unitPreference: unitPreference)
        case .easy:
            return adaptEasyWorkout(scheduled: scheduled, paces: paces)
        default:
            return scheduled
        }
    }

    // MARK: Interval adaptation

    private func adaptIntervalWorkout(
        scheduled: ScheduledWorkout,
        paces: TrainingPaces,
        snap: PerformanceSnapshot,
        unitPreference: UnitPreference
    ) -> ScheduledWorkout {
        let existing = scheduled.intervals.first
        let baseReps     = existing?.repetitions          ?? 5
        let baseDist     = existing?.distanceMeters       ?? 800
        let baseRecovery = existing?.recoverySeconds      ?? 90
        let basePace     = existing?.targetPaceSecondsPerKm ?? paces.interval

        let adaptedReps: Int
        let adaptedPace: Double
        switch snap.performanceTrend {
        case .improving:
            adaptedReps = min(baseReps + 1, baseReps + 2)
            adaptedPace = max(basePace - 2, paces.repetition)
        case .onTrack:
            adaptedReps = baseReps
            adaptedPace = basePace
        case .struggling:
            adaptedReps = max(baseReps - 1, 3)
            adaptedPace = basePace + 3
        }

        let warmupDist: Double   = snap.performanceTrend == .struggling ? 1_500 : 1_000
        let cooldownDist: Double = snap.performanceTrend == .struggling ?   500 : 1_000

        let warmup = WorkoutSegment(
            distanceMeters: warmupDist,
            durationSeconds: nil,
            targetPaceSecondsPerKm: paces.easyRange.upperBound,
            label: "Warm-up"
        )
        let workSegment = WorkoutSegment(
            distanceMeters: baseDist,
            durationSeconds: nil,
            targetPaceSecondsPerKm: adaptedPace,
            label: "Interval"
        )
        let recoverySegment = WorkoutSegment(
            distanceMeters: nil,
            durationSeconds: baseRecovery,
            targetPaceSecondsPerKm: nil,
            label: "Recovery jog"
        )
        let intervalSet = WorkoutSet(
            repetitions: adaptedReps,
            workSegment: workSegment,
            recoverySegment: recoverySegment,
            label: intervalSetLabel(distanceMeters: baseDist, paces: paces, adaptedPace: adaptedPace, unitPreference: unitPreference)
        )
        let cooldown = WorkoutSegment(
            distanceMeters: cooldownDist,
            durationSeconds: nil,
            targetPaceSecondsPerKm: paces.easyRange.upperBound,
            label: "Cool-down"
        )

        let totalWorkDist    = Double(adaptedReps) * baseDist
        let totalRecovery    = Double(adaptedReps) * baseRecovery
        let totalDist        = warmupDist + totalWorkDist + cooldownDist
        let warmupDuration   = warmupDist   / 1_000 * paces.easyRange.upperBound
        let workDuration     = totalWorkDist / 1_000 * adaptedPace
        let cooldownDuration = cooldownDist / 1_000 * paces.easyRange.upperBound
        let totalDuration    = warmupDuration + workDuration + totalRecovery + cooldownDuration

        let structure = WorkoutStructure(
            warmup: warmup,
            mainSets: [intervalSet],
            cooldown: cooldown,
            totalEstimatedDistanceMeters: totalDist,
            totalEstimatedDurationSeconds: totalDuration
        )

        let adapted = ScheduledWorkout(
            scheduledDate: scheduled.scheduledDate,
            workoutType: .interval,
            targetDistanceMeters: totalDist,
            targetPaceLowerBound: adaptedPace - 5,
            targetPaceUpperBound: adaptedPace + 5,
            notes: adaptedIntervalNote(
                reps: adaptedReps,
                distanceMeters: baseDist,
                pace: adaptedPace,
                recoverySeconds: baseRecovery,
                trend: snap.performanceTrend,
                unitPreference: unitPreference
            )
        )
        adapted.week = scheduled.week
        adapted.workoutStructure = structure
        // Preserve flat intervals for backward compat (Watch / widgets)
        adapted.intervals = [WorkoutInterval(
            repetitions: adaptedReps,
            distanceMeters: baseDist,
            durationSeconds: nil,
            targetPaceSecondsPerKm: adaptedPace,
            recoverySeconds: baseRecovery,
            recoveryType: existing?.recoveryType ?? .jog
        )]
        return adapted
    }

    // MARK: Tempo adaptation

    private func adaptTempoWorkout(
        scheduled: ScheduledWorkout,
        paces: TrainingPaces,
        snap: PerformanceSnapshot,
        unitPreference: UnitPreference
    ) -> ScheduledWorkout {
        let totalDist = scheduled.targetDistanceMeters ?? 5_000

        let warmupFraction: Double = snap.performanceTrend == .improving ? 0.10 : 0.15
        let warmupDist   = totalDist * warmupFraction
        let cooldownDist = totalDist * 0.10
        let workDist     = totalDist - warmupDist - cooldownDist

        let adaptedTempoPace: Double
        switch snap.performanceTrend {
        case .improving:  adaptedTempoPace = paces.threshold - 3
        case .onTrack:    adaptedTempoPace = paces.threshold
        case .struggling: adaptedTempoPace = paces.threshold + 5
        }

        let warmup = WorkoutSegment(
            distanceMeters: warmupDist,
            durationSeconds: nil,
            targetPaceSecondsPerKm: paces.easyRange.upperBound,
            label: "Warm-up"
        )
        let tempoSet = WorkoutSet(
            repetitions: 1,
            workSegment: WorkoutSegment(
                distanceMeters: workDist,
                durationSeconds: nil,
                targetPaceSecondsPerKm: adaptedTempoPace,
                label: "Tempo"
            ),
            recoverySegment: WorkoutSegment(
                distanceMeters: nil,
                durationSeconds: nil,
                targetPaceSecondsPerKm: nil,
                label: ""
            ),
            label: "Tempo Block"
        )
        let cooldown = WorkoutSegment(
            distanceMeters: cooldownDist,
            durationSeconds: nil,
            targetPaceSecondsPerKm: paces.easyRange.upperBound,
            label: "Cool-down"
        )

        let warmupDuration   = warmupDist   / 1_000 * paces.easyRange.upperBound
        let workDuration     = workDist     / 1_000 * adaptedTempoPace
        let cooldownDuration = cooldownDist / 1_000 * paces.easyRange.upperBound
        let totalDuration    = warmupDuration + workDuration + cooldownDuration

        let structure = WorkoutStructure(
            warmup: warmup,
            mainSets: [tempoSet],
            cooldown: cooldown,
            totalEstimatedDistanceMeters: totalDist,
            totalEstimatedDurationSeconds: totalDuration
        )

        let adapted = ScheduledWorkout(
            scheduledDate: scheduled.scheduledDate,
            workoutType: .tempo,
            targetDistanceMeters: totalDist,
            targetPaceLowerBound: adaptedTempoPace - 5,
            targetPaceUpperBound: adaptedTempoPace + 5,
            notes: adaptedTempoNote(
                totalKm: totalDist / 1_000,
                workKm: workDist / 1_000,
                pace: adaptedTempoPace,
                trend: snap.performanceTrend,
                unitPreference: unitPreference
            )
        )
        adapted.week = scheduled.week
        adapted.workoutStructure = structure
        return adapted
    }

    // MARK: Long run adaptation

    private func adaptLongRunWorkout(
        scheduled: ScheduledWorkout,
        paces: TrainingPaces,
        snap: PerformanceSnapshot,
        unitPreference: UnitPreference
    ) -> ScheduledWorkout {
        let baseDist = scheduled.targetDistanceMeters ?? 12_000
        let adaptedDist: Double = snap.performanceTrend == .struggling
            ? baseDist * 0.90
            : baseDist

        let warmupDist   = adaptedDist * 0.15
        let workDist     = adaptedDist * 0.75
        let cooldownDist = adaptedDist * 0.10
        let midEasyPace  = (paces.easyRange.lowerBound + paces.easyRange.upperBound) / 2

        let warmup = WorkoutSegment(
            distanceMeters: warmupDist,
            durationSeconds: nil,
            targetPaceSecondsPerKm: paces.easyRange.upperBound,
            label: "Easy start"
        )
        let mainSet = WorkoutSet(
            repetitions: 1,
            workSegment: WorkoutSegment(
                distanceMeters: workDist,
                durationSeconds: nil,
                targetPaceSecondsPerKm: midEasyPace,
                label: "Steady easy"
            ),
            recoverySegment: WorkoutSegment(
                distanceMeters: nil,
                durationSeconds: nil,
                targetPaceSecondsPerKm: nil,
                label: ""
            ),
            label: "Long Run"
        )
        let cooldown = WorkoutSegment(
            distanceMeters: cooldownDist,
            durationSeconds: nil,
            targetPaceSecondsPerKm: paces.easyRange.lowerBound,
            label: "Finish strong"
        )

        let totalDuration = adaptedDist / 1_000 * midEasyPace

        let structure = WorkoutStructure(
            warmup: warmup,
            mainSets: [mainSet],
            cooldown: cooldown,
            totalEstimatedDistanceMeters: adaptedDist,
            totalEstimatedDurationSeconds: totalDuration
        )

        let adapted = ScheduledWorkout(
            scheduledDate: scheduled.scheduledDate,
            workoutType: .longRun,
            targetDistanceMeters: adaptedDist,
            targetPaceLowerBound: paces.easyRange.lowerBound,
            targetPaceUpperBound: paces.easyRange.upperBound,
            notes: adaptedLongRunNote(km: adaptedDist / 1_000, pace: midEasyPace, trend: snap.performanceTrend, unitPreference: unitPreference)
        )
        adapted.week = scheduled.week
        adapted.workoutStructure = structure
        return adapted
    }

    // MARK: Easy adaptation

    private func adaptEasyWorkout(
        scheduled: ScheduledWorkout,
        paces: TrainingPaces
    ) -> ScheduledWorkout {
        let totalDist    = scheduled.targetDistanceMeters ?? 5_000
        let warmupDist   = totalDist * 0.10
        let cooldownDist = totalDist * 0.10
        let workDist     = totalDist - warmupDist - cooldownDist
        let midEasyPace  = (paces.easyRange.lowerBound + paces.easyRange.upperBound) / 2

        let warmup = WorkoutSegment(
            distanceMeters: warmupDist,
            durationSeconds: nil,
            targetPaceSecondsPerKm: paces.easyRange.upperBound,
            label: "Warm-up"
        )
        let easySet = WorkoutSet(
            repetitions: 1,
            workSegment: WorkoutSegment(
                distanceMeters: workDist,
                durationSeconds: nil,
                targetPaceSecondsPerKm: midEasyPace,
                label: "Easy run"
            ),
            recoverySegment: WorkoutSegment(
                distanceMeters: nil,
                durationSeconds: nil,
                targetPaceSecondsPerKm: nil,
                label: ""
            ),
            label: "Easy Run"
        )
        let cooldown = WorkoutSegment(
            distanceMeters: cooldownDist,
            durationSeconds: nil,
            targetPaceSecondsPerKm: paces.easyRange.lowerBound,
            label: "Cool-down"
        )

        let structure = WorkoutStructure(
            warmup: warmup,
            mainSets: [easySet],
            cooldown: cooldown,
            totalEstimatedDistanceMeters: totalDist,
            totalEstimatedDurationSeconds: totalDist / 1_000 * midEasyPace
        )

        let adapted = ScheduledWorkout(
            scheduledDate: scheduled.scheduledDate,
            workoutType: .easy,
            targetDistanceMeters: totalDist,
            targetPaceLowerBound: paces.easyRange.lowerBound,
            targetPaceUpperBound: paces.easyRange.upperBound,
            notes: scheduled.notes ?? "Conversational effort – you should be able to speak in sentences."
        )
        adapted.week = scheduled.week
        adapted.workoutStructure = structure
        return adapted
    }

    // MARK: Adaptation note generators

    private func adaptedIntervalNote(
        reps: Int,
        distanceMeters: Double,
        pace: Double,
        recoverySeconds: Double,
        trend: PerformanceTrend,
        unitPreference: UnitPreference
    ) -> String {
        let distStr = shortDistanceString(distanceMeters, unit: unitPreference)
        let paceStr = pace.paceString(unit: unitPreference)
        let recStr  = recoverySeconds >= 60
            ? String(format: "%.0f min", recoverySeconds / 60)
            : String(format: "%.0f s", recoverySeconds)
        let trendNote: String
        switch trend {
        case .improving:  trendNote = "Volume increased – you've been hitting your targets."
        case .onTrack:    trendNote = "Maintain current effort."
        case .struggling: trendNote = "Volume reduced – focus on quality over quantity."
        }
        return "\(reps) × \(distStr) @ \(paceStr) with \(recStr) jog recovery. \(trendNote)"
    }

    private func adaptedTempoNote(
        totalKm: Double,
        workKm: Double,
        pace: Double,
        trend: PerformanceTrend,
        unitPreference: UnitPreference
    ) -> String {
        let trendNote: String
        switch trend {
        case .improving:  trendNote = "Pace tightened – you're ready for it."
        case .onTrack:    trendNote = "Hold comfortably hard effort throughout."
        case .struggling: trendNote = "Pace eased – focus on consistent effort, not time."
        }
        let totalStr = totalKm.distanceStringFromKm(unit: unitPreference)
        let workStr  = workKm.distanceStringFromKm(unit: unitPreference)
        return "\(totalStr) total: warm-up, \(workStr) tempo @ \(pace.paceString(unit: unitPreference)), cool-down. \(trendNote)"
    }

    private func adaptedLongRunNote(km: Double, pace: Double, trend: PerformanceTrend, unitPreference: UnitPreference) -> String {
        let trendNote: String
        switch trend {
        case .improving:  trendNote = "Full distance – aim for a slight negative split."
        case .onTrack:    trendNote = "Keep it conversational throughout."
        case .struggling: trendNote = "Distance trimmed slightly – prioritise recovery."
        }
        return "\(km.distanceStringFromKm(unit: unitPreference)) easy @ ~\(pace.paceString(unit: unitPreference)). \(trendNote)"
    }

    private func intervalSetLabel(
        distanceMeters: Double,
        paces: TrainingPaces,
        adaptedPace: Double,
        unitPreference: UnitPreference
    ) -> String {
        let zone: String
        if adaptedPace <= paces.interval + 5 {
            zone = "VO2max"
        } else if adaptedPace <= paces.threshold + 5 {
            zone = "Threshold"
        } else {
            zone = "Tempo"
        }
        return "\(zone) Intervals (\(shortDistanceString(distanceMeters, unit: unitPreference)))"
    }

    // MARK: - Continuous pace refresh

    /// Re-derives training paces from the runner's completed history and updates every
    /// future uncompleted workout in `plan`.
    ///
    /// Call this after each completed run so workout targets stay aligned with the
    /// runner's current fitness for any number of weekly run days. Uses
    /// ``WorkoutAnalyticsService/snapshot(from:profile:)`` for a live VDOT when sufficient
    /// history exists; falls back to ``estimatedVDOT(from:)`` otherwise.
    func refreshPaces(
        plan: TrainingPlan,
        history: [RunWorkout],
        profile: UserProfile,
        unitPreference: UnitPreference = .metric
    ) {
        let today = Calendar.current.startOfDay(for: Date())
        for week in plan.weeks ?? [] {
            for workout in week.workouts ?? [] {
                guard !workout.isCompleted,
                      workout.scheduledDate > today else { continue }
                let adapted = adaptWorkout(
                    scheduled: workout,
                    history: history,
                    profile: profile,
                    unitPreference: unitPreference
                )
                workout.workoutStructure     = adapted.workoutStructure
                workout.targetDistanceMeters = adapted.targetDistanceMeters
                workout.targetPaceLowerBound = adapted.targetPaceLowerBound
                workout.targetPaceUpperBound = adapted.targetPaceUpperBound
                workout.notes                = adapted.notes
                if !adapted.intervals.isEmpty {
                    workout.intervals = adapted.intervals
                }
            }
        }
    }

    // MARK: - Schedule management

    /// Redistributes uncompleted future workouts in `plan` to match `newDayIndices`.
    ///
    /// Workouts are assigned 1-to-1 to target dates (one per day, no stacking).
    /// Any excess workouts (more workouts than selected days) are returned for the
    /// caller to delete. If more days are selected than there are workouts, stub
    /// easy runs are created for the extra slots.
    ///
    /// - Returns: Workouts that no longer fit the new schedule and should be deleted.
    @discardableResult
    func applyNewRunDays(
        to plan: TrainingPlan,
        newDayIndices: [Int],
        profile: UserProfile?
    ) -> [ScheduledWorkout] {
        let sorted = newDayIndices.sorted()
        guard !sorted.isEmpty else { return [] }
        let today = Calendar.current.startOfDay(for: Date())
        var toDelete: [ScheduledWorkout] = []

        for week in (plan.weeks ?? []).sorted(by: { $0.weekNumber < $1.weekNumber }) {
            let movable = (week.workouts ?? [])
                .filter { !$0.isCompleted && $0.workoutType != .rest && $0.workoutType != .strength && $0.scheduledDate > today }
                .sorted { $0.scheduledDate < $1.scheduledDate }
            guard !movable.isEmpty else { continue }

            let targets = sorted
                .map { week.startDate.adding(days: $0) }
                .filter { $0 > today }
            guard !targets.isEmpty else { continue }

            // Assign workouts 1-to-1 — never place two workouts on the same day.
            let assignCount = min(movable.count, targets.count)
            for i in 0..<assignCount {
                movable[i].scheduledDate = targets[i]
            }
            // Collect excess workouts so the caller can delete them.
            for i in assignCount..<movable.count {
                toDelete.append(movable[i])
            }

            // If more days selected than workouts, fill extra slots with stub easy runs.
            if targets.count > movable.count {
                let paces: TrainingPaces? = profile.map { p in
                    PaceCalculatorService.trainingPaces(forVDOT: estimatedVDOT(from: p))
                }
                let totalMovableKm = movable.reduce(0.0) { $0 + ($1.targetDistanceMeters ?? 0) / 1_000 }
                let stubCount = Double(targets.count - movable.count)
                let remainingKm = week.targetDistanceKm - totalMovableKm
                let stubKm = remainingKm > 0 ? remainingKm / stubCount : 5.0
                for targetDate in targets.dropFirst(movable.count) {
                    let stub = ScheduledWorkout(
                        scheduledDate: targetDate,
                        workoutType: .easy,
                        targetDistanceMeters: stubKm * 1_000,
                        targetPaceLowerBound: paces?.easyRange.lowerBound,
                        targetPaceUpperBound: paces?.easyRange.upperBound,
                        notes: "Conversational effort – you should be able to speak in sentences."
                    )
                    week.workouts = (week.workouts ?? []) + [stub]
                }
            }
        }

        if let profile {
            profile.preferredRunDayIndices = sorted
            profile.weeklyRunDays = sorted.count
            profile.updatedAt = Date()
        }

        return toDelete
    }
}
