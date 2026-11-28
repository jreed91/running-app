import Foundation

// The parts of `HeatAdaptationPolicy` that read or write a `ScheduledWorkout`, a SwiftData
// model the StrideCore package cannot see. The tiers, the pace and volume rules and the
// `Adaptation` value itself live in the package (`HeatAdaptationPolicy.swift`).
extension HeatAdaptationPolicy {

    /// Whether a scheduled session is eligible for a forecast advisory at all, before any
    /// weather is fetched. Cheap enough to run over a whole plan.
    static func isAdvisable(_ workout: ScheduledWorkout, now: Date = Date()) -> Bool {
        guard workout.workoutLocation == .outdoor else { return false }
        guard !workout.isCompleted else { return false }
        guard AdaptableWorkoutSelector.isAdaptableType(workout.workoutType) else { return false }
        return workout.scheduledDate >= now.startOfDay
    }

    /// The adaptation for one session in one set of conditions.
    ///
    /// Reads only the session's prescription and the tier, so the sheet, the tests, and
    /// the apply path all agree by construction.
    static func adaptation(
        for workout: ScheduledWorkout,
        tier: HeatStressTier,
        unit: UnitPreference
    ) -> Adaptation {
        var changes: [String] = []
        // Tracks whether a *field* moved, as opposed to a line of advice being added. See
        // `Adaptation.changesAnything`.
        var mutates = false

        let isQuality = workout.workoutType == .tempo || workout.workoutType == .interval
        let becomesEasy = isQuality && convertsQualityToEasy(tier)
        let newType: WorkoutType = becomesEasy ? .easy : workout.workoutType

        if becomesEasy {
            mutates = true
            changes.append(String(
                localized: "Your \(workout.workoutType.localizedName.lowercased()) becomes an easy run — the quality session isn't worth its recovery cost in this.",
                comment: "Heat adaptation change line: a hard session is converted to an easy run"
            ))
        }

        // MARK: Distance

        let volumeScale = distanceScale(for: workout.workoutType, tier: tier, becameEasy: becomesEasy)
        var distance = workout.targetDistanceMeters
        if let original = distance, volumeScale < 1 {
            let scaled = original * volumeScale
            distance = scaled
            mutates = true
            changes.append(String(
                localized: """
                    Distance trimmed from \(original.distanceString(unit: unit)) to \
                    \(scaled.distanceString(unit: unit)) — heat strain builds with time on your feet.
                    """,
                comment: "Heat adaptation change line: the session's distance is reduced"
            ))
        }

        // MARK: Pace
        //
        // Three outcomes, and the order matters. A converted session loses its targets
        // outright — an eased *tempo* band is still a tempo band, and handing one to a run
        // that is now meant to be easy would have the runner chasing the session they just
        // agreed not to do. Above `.severe` the targets go for the published reason. Below
        // it they are widened.

        var lower = workout.targetPaceLowerBound
        var upper = workout.targetPaceUpperBound
        let hadPaceTargets = lower != nil || upper != nil
        let losesPaceTargets = becomesEasy || dropsPaceTargets(tier)

        if losesPaceTargets {
            lower = nil
            upper = nil
            if hadPaceTargets {
                mutates = true
                changes.append(becomesEasy
                    ? String(
                        localized: "Its pace target goes with it — run this one at a conversational effort.",
                        comment: "Heat adaptation change line: pace targets removed because the session became easy"
                    )
                    : String(
                        localized: "Pace targets removed — run this one entirely on effort.",
                        comment: "Heat adaptation change line: pace targets are dropped in extreme heat"
                    )
                )
            }
        } else if let percent = representativePaceAdjustmentPercent(for: tier), percent > 0 {
            lower = lower.flatMap { adjustedPaceBound($0, for: tier) }
            upper = upper.flatMap { adjustedPaceBound($0, for: tier) }

            if hadPaceTargets,
               let original = workout.targetPaceLowerBound ?? workout.targetPaceUpperBound,
               let adjusted = lower ?? upper {
                // Pace is stored per kilometre whatever the runner reads in, so the
                // difference is converted before it is spoken about.
                mutates = true
                let perUnit = (adjusted - original) * (unit == .metric ? 1 : 1.609344)
                changes.append(String(
                    localized: """
                        Pace targets eased by about \(Int(perUnit.rounded())) seconds per \
                        \(unit.distanceLabel) — roughly \(percentText(percent))% slower for \
                        the same effort.
                        """,
                    comment: "Heat adaptation change line: pace bands are widened"
                ))
            } else if !hadPaceTargets {
                // Nothing to move, but the expectation still belongs on the card.
                changes.append(String(
                    localized: "Expect to run roughly \(percentText(percent))% slower than usual for the same effort.",
                    comment: "Heat adaptation change line: expected slowdown when the session has no pace band"
                ))
            }
        }

        // MARK: Structure

        let structure = adaptedStructure(
            workout.workoutStructure,
            tier: tier,
            clears: losesPaceTargets,
            volumeScale: volumeScale
        )
        // Compared on repetitions alone. Every segment's pace moves whenever the band
        // does, so comparing whole sets would fire this line on a `.moderate` session
        // whose rep count never changed.
        if let original = workout.workoutStructure, !losesPaceTargets, let structure,
           structure.mainSets.map(\.repetitions) != original.mainSets.map(\.repetitions) {
            mutates = true
            changes.append(String(
                localized: "The hard reps are cut back to \(repetitionText(structure.mainSets)) so the session still fits the day.",
                comment: "Heat adaptation change line: a structured session's repetitions are reduced"
            ))
        }

        // MARK: Location

        var location = workout.workoutLocation
        if suggestsIndoor(tier), location == .outdoor {
            location = .indoor
            mutates = true
            changes.append(String(
                localized: "Moved indoors — a treadmill is the safer place for this one.",
                comment: "Heat adaptation change line: the session is moved indoors"
            ))
        }

        return Adaptation(
            workoutType: newType,
            workoutLocation: location,
            targetDistanceMeters: distance,
            targetPaceLowerBound: lower,
            targetPaceUpperBound: upper,
            workoutStructure: structure,
            clearsStructure: losesPaceTargets,
            changes: changes,
            changesAnything: mutates
        )
    }

    /// Writes an adaptation onto the session it was computed for.
    ///
    /// Deliberately narrow: this touches the prescription and nothing else. Identity,
    /// scheduling, and completion state are left alone for the same reason
    /// `ScheduledWorkout.applyAdaptation(from:)` leaves them alone — heat changes what the
    /// session *is*, never when it is or whether it happened.
    ///
    /// `healthKitPlanID` is cleared because the workout already on the Watch describes the
    /// old prescription: it has to be re-synced rather than matched. Forgetting that is the
    /// failure `applyAdaptation(from:)`'s doc comment calls out, and it is just as easy to
    /// forget here.
    ///
    /// The session is noted in ``AdaptedSessions`` for the same reason: without it, a run
    /// the day before the hot one re-paced the session back to its fast targets (P1.1).
    @MainActor
    static func apply(_ adaptation: Adaptation, to workout: ScheduledWorkout) {
        workout.workoutType = adaptation.workoutType
        workout.workoutLocation = adaptation.workoutLocation
        workout.targetDistanceMeters = adaptation.targetDistanceMeters
        workout.targetPaceLowerBound = adaptation.targetPaceLowerBound
        workout.targetPaceUpperBound = adaptation.targetPaceUpperBound

        if adaptation.clearsStructure {
            workout.workoutStructure = nil
            workout.intervalsData = nil
        } else if let structure = adaptation.workoutStructure {
            workout.workoutStructure = structure
        }

        workout.healthKitPlanID = nil
        AdaptedSessions.record(workout.id)
    }
}
