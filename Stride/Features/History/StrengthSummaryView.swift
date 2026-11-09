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
            .padding(AppSpacing.lg)
        }
        .background(Color.surfacePrimary)
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
                        .frame(width: 48, height: 48)
                    StrideIcon(name: WorkoutType.strength.strideIcon, size: 24,
                               color: WorkoutType.strength.color, strokeWeight: 2.0)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(workout.scheduledWorkout?.strengthPlan?.focus.localizedName ?? "Strength Workout")
                        .font(.dsTitle3.weight(.bold))
                    Text(workout.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                        .font(.dsSubhead)
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
        .padding(AppSpacing.lg)
        // The screen's one hero; the set cards below are ordinary cards.
        .heroCard()
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.dsTitle2.monospacedDigit())
            Text(label)
                .strideEyebrow()
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
                .strideEyebrow()
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)

            let grouped = Dictionary(grouping: workout.completedSets, by: \.exerciseIndex)
            ForEach(grouped.keys.sorted(), id: \.self) { exerciseIndex in
                let sets = grouped[exerciseIndex] ?? []
                // The name the set was logged under wins: the plan it points into can be
                // rebuilt since, and an unplanned session has no plan at all.
                let exerciseName: String = if let logged = sets.lazy.compactMap(\.exerciseName).first {
                    logged
                } else if let plan, plan.exercises.indices.contains(exerciseIndex) {
                    plan.exercises[exerciseIndex].name
                } else {
                    "Exercise \(exerciseIndex + 1)"
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(exerciseName)
                        .font(.dsSubhead.weight(.semibold))

                    ForEach(sets, id: \.setIndex) { set in
                        HStack {
                            Text("Set \(set.setIndex + 1)")
                                .font(.dsFootnote.weight(.medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            if set.skipped {
                                Text("Skipped")
                                    .font(.dsFootnote)
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text("\(set.completedReps) reps\(set.actualWeight.map { " · \($0)" } ?? "")")
                                    .font(.dsFootnote.weight(.medium).monospacedDigit())
                            }
                        }
                    }
                }
                .padding(AppSpacing.md)
                .strideCard(cornerRadius: AppRadius.md)
            }
        }
    }

    // MARK: - Planned exercises (HealthKit import or unstarted)

    private func plannedExercisesSection(plan: StrengthWorkoutPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("EXERCISES")
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
                Spacer()
                StrideTag("\(plan.estimatedDurationMinutes) min", systemImage: "clock")
            }
            .padding(.leading, AppSpacing.xs)

            ForEach(Array(plan.exercises.enumerated()), id: \.offset) { _, exercise in
                ExerciseRow(exercise: exercise)
            }
        }
    }

    // MARK: - Source

    private var sourceRow: some View {
        HStack(spacing: 8) {
            // A session logged here gets a HealthKit id too, once it is exported, so the
            // id alone would call every Stride session "synced from Apple Health". Sets
            // are only ever logged in Stride.
            if workout.healthKitWorkoutID != nil && workout.completedSets.isEmpty {
                StrideIcon(name: .heart, size: 13, color: .destructive, strokeWeight: 2)
                Text("Synced from Apple Health")
            } else {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(WorkoutType.strength.color)
                Text("Logged in Stride")
            }
        }
        .font(.dsCaption)
        .foregroundStyle(.secondary)
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity)
        .strideCard(cornerRadius: AppRadius.md)
    }
}
