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
        let endDate = startDate.adding(weeks: numberOfWeeks)
        let plan = TrainingPlan(
            targetRace: profile.goalRace,
            goalTimeSeconds: profile.goalFinishTime,
            startDate: startDate,
            endDate: endDate
        )

        let vdot = estimatedVDOT(from: profile)
        let paces = PaceCalculatorService.trainingPaces(forVDOT: vdot)
        let phases = phaseSchedule(totalWeeks: numberOfWeeks, raceType: profile.goalRace)
        let baseKm = profile.fitnessLevel.startingWeeklyKm(for: profile.goalRace)

        // Prefer explicit indices; fall back to even distribution from profile
        let effectiveDayOffsets: [Int]? = runDayIndices.isEmpty ? nil : runDayIndices.sorted()

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
            // Auto-apply structured warmup/work/cooldown to all quality and long-run sessions.
            // Uses profile-derived VDOT with no history (onTrack defaults) so the plan is
            // immediately structured. Users can re-adapt later via the detail view to
            // personalise based on their actual run history.
            for workout in workouts {
                guard workout.workoutType != .easy,
                      workout.workoutType != .rest,
                      workout.workoutType != .crossTraining else { continue }
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
            week.workouts = workouts
            plan.weeks.append(week)
        }
        return plan
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
            let maxKm = base * 1.5
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
        // Fall back: derive a rough VDOT from fitness level
        let fallback5KSeconds: Double
        switch profile.fitnessLevel {
        case .beginner:     fallback5KSeconds = 35 * 60   // 35:00
        case .intermediate: fallback5KSeconds = 27 * 60   // 27:00
        case .advanced:     fallback5KSeconds = 21 * 60   // 21:00
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

        for (slotIndex, dayOffset) in days.enumerated() {
            let date = weekStart.adding(days: dayOffset)

            // Last run day of the week → long run
            if slotIndex == days.count - 1 {
                let longKm = targetKm * 0.35
                workouts.append(longRunWorkout(date: date, km: longKm, paces: paces))
                continue
            }

            // Insert a quality session if the slot index matches
            if slotIndex < qualityTypes.count {
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

            // Remaining days → easy runs
            let easyKm = targetKm * 0.20 / Double(max(1, runDays - days.count))
            workouts.append(easyWorkout(date: date, km: easyKm, paces: paces))
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

    private func weekQualityTypes(phase: TrainingPhase, raceType: RaceType) -> [WorkoutType] {
        switch (phase, raceType) {
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

    /// Formats a kilometre value as a distance string using the user's unit preference.
    private func kmString(_ km: Double, unit: UnitPreference) -> String {
        switch unit {
        case .metric:  return String(format: "%.1f km", km)
        case .imperial: return String(format: "%.1f mi", km / 1.60934)
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
              scheduled.workoutType != .crossTraining else {
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
        let adapted = ScheduledWorkout(
            scheduledDate: scheduled.scheduledDate,
            workoutType: .easy,
            targetDistanceMeters: scheduled.targetDistanceMeters,
            targetPaceLowerBound: paces.easyRange.lowerBound,
            targetPaceUpperBound: paces.easyRange.upperBound,
            notes: scheduled.notes ?? "Conversational effort – you should be able to speak in sentences."
        )
        adapted.week = scheduled.week
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
        let totalStr = kmString(totalKm, unit: unitPreference)
        let workStr  = kmString(workKm, unit: unitPreference)
        return "\(totalStr) total: warm-up, \(workStr) tempo @ \(pace.paceString(unit: unitPreference)), cool-down. \(trendNote)"
    }

    private func adaptedLongRunNote(km: Double, pace: Double, trend: PerformanceTrend, unitPreference: UnitPreference) -> String {
        let trendNote: String
        switch trend {
        case .improving:  trendNote = "Full distance – aim for a slight negative split."
        case .onTrack:    trendNote = "Keep it conversational throughout."
        case .struggling: trendNote = "Distance trimmed slightly – prioritise recovery."
        }
        return "\(kmString(km, unit: unitPreference)) easy @ ~\(pace.paceString(unit: unitPreference)). \(trendNote)"
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
}
