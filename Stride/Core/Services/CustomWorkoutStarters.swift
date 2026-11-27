import Foundation

// MARK: - CustomWorkoutStarters

/// Classic sessions to start a custom workout from, so an empty library is one tap from a
/// real workout instead of a blank form (Custom workouts, PR 2).
///
/// Paces come from the runner's training paces when they are known and are left off when
/// they are not: a made-up 4:00/km rep is worse than none. Every starter is a draft the
/// runner edits before saving, never saved on its own.
enum CustomWorkoutStarters {

    struct Starter: Identifiable, Equatable, Sendable {
        let id: String
        let draft: CustomWorkoutDraft
        /// One line under the name in the picker.
        let summary: String
    }

    static func all(paces: TrainingPaces?, unit: UnitPreference) -> [Starter] {
        let warmup = CustomWorkoutDraft.StepLength.time(seconds: 10 * 60)
        let cooldown = CustomWorkoutDraft.StepLength.time(seconds: 10 * 60)
        let mile = CustomWorkoutDistanceUnit.miles.metersPerUnit
        let tempoMeters = unit == .metric ? 2_000 : mile
        let tempoName = unit == .metric
            ? String(localized: "3 × 2 km tempo", comment: "Custom workout starter name")
            : String(localized: "3 × 1 mile tempo", comment: "Custom workout starter name")

        return [
            Starter(
                id: "800s",
                draft: CustomWorkoutDraft(
                    name: String(localized: "6 × 800 m", comment: "Custom workout starter name"),
                    warmup: warmup,
                    sets: [.init(
                        repetitions: 6,
                        work: .distance(meters: 800),
                        workPaceSecondsPerKm: paces?.interval,
                        recovery: .time(seconds: 90)
                    )],
                    cooldown: cooldown
                ),
                summary: String(localized: "VO2max reps with a 90 s jog", comment: "Custom workout starter summary")
            ),
            Starter(
                id: "tempo",
                draft: CustomWorkoutDraft(
                    name: tempoName,
                    warmup: warmup,
                    sets: [.init(
                        repetitions: 3,
                        work: .distance(meters: tempoMeters),
                        workPaceSecondsPerKm: paces?.threshold,
                        recovery: .time(seconds: 120)
                    )],
                    cooldown: cooldown
                ),
                summary: String(localized: "Threshold blocks with a 2 min jog", comment: "Custom workout starter summary")
            ),
            Starter(
                id: "minutes",
                draft: CustomWorkoutDraft(
                    name: String(localized: "10 × 1 min", comment: "Custom workout starter name"),
                    warmup: warmup,
                    sets: [.init(
                        repetitions: 10,
                        work: .time(seconds: 60),
                        workPaceSecondsPerKm: paces?.interval,
                        recovery: .time(seconds: 60)
                    )],
                    cooldown: cooldown
                ),
                summary: String(localized: "A minute hard, a minute easy. No track needed", comment: "Custom workout starter summary")
            ),
            Starter(
                id: "pyramid",
                draft: CustomWorkoutDraft(
                    name: String(localized: "Pyramid 1-2-3-2-1", comment: "Custom workout starter name"),
                    warmup: warmup,
                    sets: [1, 2, 3, 2, 1].map { minutes in
                        .init(
                            repetitions: 1,
                            work: .time(seconds: Double(minutes * 60)),
                            workPaceSecondsPerKm: paces?.threshold,
                            recovery: .time(seconds: 60)
                        )
                    },
                    cooldown: cooldown
                ),
                summary: String(localized: "Minutes up and back down, 1 min jog between", comment: "Custom workout starter summary")
            ),
            Starter(
                id: "strides",
                draft: CustomWorkoutDraft(
                    name: String(localized: "Easy run with strides", comment: "Custom workout starter name"),
                    warmup: .time(seconds: 25 * 60),
                    sets: [.init(
                        repetitions: 6,
                        work: .time(seconds: 20),
                        workPaceSecondsPerKm: paces?.repetition,
                        recovery: .time(seconds: 60),
                        recoveryKind: .walk
                    )],
                    cooldown: .time(seconds: 5 * 60)
                ),
                summary: String(localized: "25 min easy, then 6 quick 20 s strides", comment: "Custom workout starter summary")
            )
        ]
    }
}
