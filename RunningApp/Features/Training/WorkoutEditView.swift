import SwiftUI
import SwiftData

struct WorkoutEditView: View {
    private enum Mode {
        case edit(ScheduledWorkout)
        case add(TrainingWeek)

        var isAdding: Bool {
            if case .add = self { return true }
            return false
        }
    }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    private let mode: Mode
    @State private var selectedType: WorkoutType
    @State private var selectedDate: Date
    @State private var distanceKmText: String
    @State private var paceLowerText: String
    @State private var paceUpperText: String
    @State private var notesText: String

    // MARK: - Inits

    init(workout: ScheduledWorkout) {
        self.mode = .edit(workout)
        _selectedType = State(initialValue: workout.workoutType)
        _selectedDate = State(initialValue: workout.scheduledDate)
        _distanceKmText = State(initialValue: workout.targetDistanceMeters.map {
            String(format: "%.2f", $0 / 1_000)
        } ?? "")
        _paceLowerText = State(initialValue: workout.targetPaceLowerBound.map {
            WorkoutEditView.secondsToMMSS($0)
        } ?? "")
        _paceUpperText = State(initialValue: workout.targetPaceUpperBound.map {
            WorkoutEditView.secondsToMMSS($0)
        } ?? "")
        _notesText = State(initialValue: workout.notes ?? "")
    }

    init(week: TrainingWeek) {
        self.mode = .add(week)
        _selectedType = State(initialValue: .easy)
        _selectedDate = State(initialValue: week.startDate)
        _distanceKmText = State(initialValue: "")
        _paceLowerText = State(initialValue: "")
        _paceUpperText = State(initialValue: "")
        _notesText = State(initialValue: "")
    }

    // MARK: - Computed helpers

    private var weekStart: Date {
        switch mode {
        case .edit(let w): return w.week?.startDate ?? w.scheduledDate
        case .add(let week): return week.startDate
        }
    }

    private var weekEnd: Date {
        switch mode {
        case .edit(let w): return w.week?.endDate ?? w.scheduledDate
        case .add(let week): return week.endDate
        }
    }

    private var isCompleted: Bool {
        if case .edit(let w) = mode { return w.isCompleted }
        return false
    }

    // MARK: - Validation

    private var parsedDistanceMeters: Double? {
        guard !distanceKmText.isEmpty, let km = Double(distanceKmText) else { return nil }
        return km * 1_000
    }

    private var parsedPaceLower: Double? {
        paceLowerText.isEmpty ? nil : WorkoutEditView.mmssToSeconds(paceLowerText)
    }

    private var parsedPaceUpper: Double? {
        paceUpperText.isEmpty ? nil : WorkoutEditView.mmssToSeconds(paceUpperText)
    }

    private var paceLowerInvalid: Bool {
        !paceLowerText.isEmpty && parsedPaceLower == nil
    }

    private var paceUpperInvalid: Bool {
        !paceUpperText.isEmpty && parsedPaceUpper == nil
    }

    /// Lower bound = faster = smaller sec/km; inverted when the "faster" value is numerically larger.
    private var paceRangeInverted: Bool {
        guard let lo = parsedPaceLower, let hi = parsedPaceUpper else { return false }
        return lo > hi
    }

    private var canSave: Bool {
        !isCompleted && !paceLowerInvalid && !paceUpperInvalid && !paceRangeInverted
    }

    // MARK: - Body

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

                Section("Distance (km)") {
                    TextField("e.g. 10.5", text: $distanceKmText)
                        .keyboardType(.decimalPad)
                }

                Section {
                    LabeledContent("Faster (MM:SS)") {
                        TextField("e.g. 5:30", text: $paceLowerText)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Slower (MM:SS)") {
                        TextField("e.g. 6:00", text: $paceUpperText)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }
                    if paceLowerInvalid || paceUpperInvalid {
                        Text("Enter pace as M:SS — e.g. 5:30")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if paceRangeInverted {
                        Text("Faster pace must be a lower value than slower pace")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Target Pace /km")
                }

                Section("Notes") {
                    TextField("Optional notes", text: $notesText, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle(mode.isAdding ? "Add Workout" : "Edit Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        commitChanges()
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    // MARK: - Actions

    private func commitChanges() {
        guard canSave else { return }
        switch mode {
        case .edit(let workout):
            workout.workoutType = selectedType
            workout.scheduledDate = Calendar.current.startOfDay(for: selectedDate)
            workout.targetDistanceMeters = parsedDistanceMeters
            workout.targetPaceLowerBound = parsedPaceLower
            workout.targetPaceUpperBound = parsedPaceUpper
            workout.notes = notesText.isEmpty ? nil : notesText
            try? context.save()

        case .add(let week):
            let newWorkout = ScheduledWorkout(
                scheduledDate: Calendar.current.startOfDay(for: selectedDate),
                workoutType: selectedType,
                targetDistanceMeters: parsedDistanceMeters,
                targetPaceLowerBound: parsedPaceLower,
                targetPaceUpperBound: parsedPaceUpper,
                notes: notesText.isEmpty ? nil : notesText
            )
            context.insert(newWorkout)
            week.workouts.append(newWorkout)
            try? context.save()
        }
    }

    // MARK: - Pace formatting helpers

    /// Converts a "M:SS" string to total seconds. Returns `nil` on parse failure.
    static func mmssToSeconds(_ text: String) -> Double? {
        let parts = text.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let minutes = Int(parts[0]),
              let seconds = Int(parts[1]),
              minutes >= 0,
              seconds >= 0,
              seconds < 60
        else { return nil }
        return Double(minutes * 60 + seconds)
    }

    /// Converts total seconds to a "M:SS" display string.
    static func secondsToMMSS(_ totalSeconds: Double) -> String {
        let s = Int(totalSeconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
