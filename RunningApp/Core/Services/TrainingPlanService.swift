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
        runDayIndices: [Int] = []
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
            week.workouts = buildWorkouts(
                weekStart: weekStart,
                runDays: profile.weeklyRunDays,
                dayOffsets: effectiveDayOffsets,
                phase: phase,
                paces: paces,
                raceType: profile.goalRace,
                targetKm: targetKm
            )
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
        targetKm: Double
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
                    raceType: raceType
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
        raceType: RaceType
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
                notes: intervalNote(raceType: raceType)
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

    private func intervalNote(raceType: RaceType) -> String {
        switch raceType {
        case .fiveK:
            return "6 × 800 m @ interval pace with 90 s jog recovery. Hard but controlled."
        case .halfMarathon:
            return "5 × 1000 m @ interval pace with 90 s jog recovery."
        case .marathon:
            return "4 × 1200 m @ interval pace with 2 min jog recovery."
        }
    }
}
