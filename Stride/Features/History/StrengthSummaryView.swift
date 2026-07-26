import SwiftUI
import SwiftData

struct StrengthSummaryView: View {
    let workout: StrengthWorkout
    @Environment(\.modelContext) private var context

    private var durationLabel: String {
        let total = Int(workout.durationSeconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard
                if !workout.completedSets.isEmpty {
                    completedSetsSection
                } else if let plan = workout.scheduledWorkout?.strengthPlan {
                    plannedExercisesSection(plan: plan)
                }
                sourceRow
            }
            .padding(16)
        }
        .navigationTitle("Strength Workout")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(WorkoutType.strength.color.opacity(0.15))
                        .frame(width: 52, height: 52)
                    StrideIcon(name: WorkoutType.strength.strideIcon, size: 26,
                               color: WorkoutType.strength.color, strokeWeight: 2.0)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(workout.scheduledWorkout?.strengthPlan?.focus.localizedName ?? "Strength Workout")
                        .font(.title3.bold())
                    Text(workout.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            HStack(spacing: 0) {
                statCell(value: durationLabel, label: "DURATION")
                if !workout.completedSets.isEmpty {
                    Divider().frame(height: 36)
                    statCell(
                        value: "\(workout.completedSets.filter { !$0.skipped }.count)",
                        label: "SETS DONE"
                    )
                }
            }
        }
        .padding(16)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 18))
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
            Text(label)
                .font(.sectionHeader)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        // Paired rather than read as two loose fragments, and labelled in sentence case
        // rather than the uppercase the layout uses (N18).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.capitalized)
        .accessibilityValue(SpokenMetric.spoken(measurement: value))
    }

    // MARK: - Completed sets

    private var completedSetsSection: some View {
        let plan = workout.scheduledWorkout?.strengthPlan
        return VStack(alignment: .leading, spacing: 12) {
            Text("COMPLETED SETS")
                .font(.sectionHeader)
                .foregroundStyle(.secondary)

            let grouped = Dictionary(grouping: workout.completedSets, by: \.exerciseIndex)
            ForEach(grouped.keys.sorted(), id: \.self) { exerciseIndex in
                let sets = grouped[exerciseIndex] ?? []
                let exerciseName: String = if let plan, plan.exercises.indices.contains(exerciseIndex) {
                    plan.exercises[exerciseIndex].name
                } else {
                    "Exercise \(exerciseIndex + 1)"
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(exerciseName)
                        .font(.system(size: 15, weight: .semibold))

                    ForEach(sets, id: \.setIndex) { set in
                        HStack {
                            Text("Set \(set.setIndex + 1)")
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if set.skipped {
                                Text("Skipped")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text("\(set.completedReps) reps\(set.actualWeight.map { " · \($0)" } ?? "")")
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                            }
                        }
                    }
                }
                .padding(12)
                .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Planned exercises (HealthKit import or unstarted)

    private func plannedExercisesSection(plan: StrengthWorkoutPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("EXERCISES")
                    .font(.sectionHeader)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                    Text("\(plan.estimatedDurationMinutes) min")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.surfaceSecondary, in: Capsule())
                .foregroundStyle(.secondary)
            }

            ForEach(Array(plan.exercises.enumerated()), id: \.offset) { _, exercise in
                ExerciseRow(exercise: exercise)
            }
        }
    }

    // MARK: - Source

    private var sourceRow: some View {
        HStack(spacing: 8) {
            if workout.healthKitWorkoutID != nil {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                Text("Synced from Apple Health")
            } else {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(WorkoutType.strength.color)
                Text("Logged in Stride")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
    }
}
