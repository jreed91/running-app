import SwiftUI
import SwiftData

struct StrengthSummaryView: View {
    let workout: StrengthWorkout
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var container
    @State private var isEditing = false
    /// What Health knows about a session recorded on the Watch or in another app, read
    /// when the screen opens. Nil for a session logged in Stride, and until it loads.
    @State private var healthDetails: ImportedWorkoutDetails?

    /// Recorded outside Stride and imported from Health. A session logged here gets a
    /// HealthKit id too, once it is exported, but always has sets.
    private var isFromHealth: Bool {
        workout.healthKitWorkoutID != nil && workout.completedSets.isEmpty
    }

    private var title: String {
        workout.scheduledWorkout?.strengthPlan?.focus.localizedName
            ?? healthDetails?.title
            ?? String(localized: "Strength Workout", comment: "Strength session title")
    }

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
        .toolbar {
            // Only sets logged in Stride can be corrected; a Health import has none.
            if !workout.completedSets.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { isEditing = true }
                }
            }
        }
        .task(id: workout.healthKitWorkoutID) {
            guard isFromHealth, let hkID = workout.healthKitWorkoutID else { return }
            healthDetails = await container.healthKitRepository.fetchImportedWorkoutDetails(forWorkoutID: hkID)
        }
        .sheet(isPresented: $isEditing) {
            NavigationStack {
                StrengthSetsEditor(sets: workout.completedSets) { edited in
                    workout.completedSets = edited
                    context.saveOrLog("the corrected strength sets")
                }
            }
        }
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
                    Text(title)
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
                } else if let heartRate = healthDetails?.heartRateText {
                    Divider().frame(height: 36)
                    statCell(value: heartRate, label: "AVG HEART RATE")
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
            if isFromHealth {
                StrideIcon(name: .heart, size: 13, color: .destructive, strokeWeight: 2)
                if let recordedBy = healthDetails?.recordedByText {
                    Text("\(recordedBy) · synced from Apple Health")
                } else {
                    Text("Synced from Apple Health")
                }
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

// MARK: - StrengthSetsEditor

/// Corrects a finished session: the reps and weight of each set, or a set deleted.
///
/// Edits stay on a copy until Save, so Cancel leaves the session as it was. Weights are
/// entered in the runner's unit and stored in kilograms (``StrengthProgression/edited``),
/// so next session's suggestion reads the corrected numbers.
private struct StrengthSetsEditor: View {
    let onSave: ([CompletedStrengthSet]) -> Void

    @Environment(AppSettings.self) private var appSettings
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [Row]

    private struct Row: Identifiable {
        let id = UUID()
        var original: CompletedStrengthSet
        var reps: Int
        var weight: Double?
    }

    init(sets: [CompletedStrengthSet], onSave: @escaping ([CompletedStrengthSet]) -> Void) {
        self.onSave = onSave
        // The unit isn't readable from the environment yet; the weights are filled in
        // `onAppear` once it is.
        _rows = State(initialValue: sets.map { Row(original: $0, reps: $0.completedReps, weight: nil) })
    }

    private var unit: UnitPreference { appSettings.unitPreference }

    var body: some View {
        List {
            ForEach(groups, id: \.self) { exerciseIndex in
                Section(name(ofExercise: exerciseIndex)) {
                    ForEach(indices(ofExercise: exerciseIndex), id: \.self) { index in
                        row(at: index)
                    }
                    .onDelete { offsets in
                        let doomed = Set(offsets.map { indices(ofExercise: exerciseIndex)[$0] })
                        rows = rows.enumerated().filter { !doomed.contains($0.offset) }.map(\.element)
                    }
                }
            }
        }
        .navigationTitle("Edit sets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
            }
        }
        .onAppear(perform: loadWeights)
    }

    @ViewBuilder
    private func row(at index: Int) -> some View {
        let set = rows[index].original
        VStack(alignment: .leading, spacing: 8) {
            Text("Set \(set.setIndex + 1)")
                .font(.dsFootnote.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
            if set.skipped {
                Text("Skipped")
                    .font(.dsFootnote)
                    .foregroundStyle(.tertiary)
            } else {
                Stepper(value: $rows[index].reps, in: 0...100) {
                    Text("\(rows[index].reps) reps")
                        .font(.dsBody.monospacedDigit())
                }
                HStack {
                    Text("Weight")
                        .font(.dsBody)
                    Spacer()
                    TextField("None", value: $rows[index].weight, format: .number.precision(.fractionLength(0...1)))
                        .font(.dsBody.monospacedDigit())
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90)
                        .accessibilityLabel("Weight in \(unit == .metric ? "kg" : "lb")")
                    Text(verbatim: unit == .metric ? "kg" : "lb")
                        .font(.dsFootnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var groups: [Int] {
        Array(Set(rows.map(\.original.exerciseIndex))).sorted()
    }

    private func indices(ofExercise exerciseIndex: Int) -> [Int] {
        rows.indices.filter { rows[$0].original.exerciseIndex == exerciseIndex }
    }

    private func name(ofExercise exerciseIndex: Int) -> String {
        rows.lazy.filter { $0.original.exerciseIndex == exerciseIndex }
            .compactMap(\.original.exerciseName).first
            ?? String(localized: "Exercise \(exerciseIndex + 1)")
    }

    private func loadWeights() {
        for index in rows.indices where rows[index].weight == nil {
            rows[index].weight = StrengthProgression.editableWeight(of: rows[index].original, unit: unit)
        }
    }

    private func save() {
        let edited = rows.map { row in
            row.original.skipped
                ? row.original
                : StrengthProgression.edited(row.original, reps: row.reps, displayWeight: row.weight, unit: unit)
        }
        onSave(edited)
        dismiss()
    }
}
