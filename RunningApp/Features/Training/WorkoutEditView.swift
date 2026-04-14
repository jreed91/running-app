import SwiftUI
import SwiftData

struct WorkoutEditView: View {
    let workout: ScheduledWorkout

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var selectedType: WorkoutType
    @State private var selectedDate: Date

    private var weekStart: Date { workout.week?.startDate ?? workout.scheduledDate }
    private var weekEnd: Date { workout.week?.endDate ?? workout.scheduledDate }

    init(workout: ScheduledWorkout) {
        self.workout = workout
        _selectedType = State(initialValue: workout.workoutType)
        _selectedDate = State(initialValue: workout.scheduledDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Workout Type") {
                    Picker("Type", selection: $selectedType) {
                        ForEach(WorkoutType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(height: 120)
                }

                Section("Scheduled Day") {
                    DatePicker(
                        "Date",
                        selection: $selectedDate,
                        in: weekStart...weekEnd,
                        displayedComponents: .date
                    )
                }
            }
            .navigationTitle("Edit Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        applyChanges()
                        dismiss()
                    }
                    .disabled(workout.isCompleted)
                }
            }
        }
    }

    private func applyChanges() {
        guard !workout.isCompleted else { return }
        workout.workoutType = selectedType
        workout.scheduledDate = Calendar.current.startOfDay(for: selectedDate)
        try? context.save()
    }
}
