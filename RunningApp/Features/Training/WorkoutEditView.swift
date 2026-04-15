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
    private let unitPreference: UnitPreference
    @State private var selectedType: WorkoutType
    @State private var selectedDate: Date
    @State private var distanceText: String
    @State private var paceLowerText: String
    @State private var paceUpperText: String
    @State private var notesText: String

    // MARK: - Inits

    init(workout: ScheduledWorkout, unitPreference: UnitPreference) {
        self.mode = .edit(workout)
        self.unitPreference = unitPreference
        _selectedType = State(initialValue: workout.workoutType)
        _selectedDate = State(initialValue: workout.scheduledDate)
        _distanceText = State(initialValue: workout.targetDistanceMeters.map {
            let display = unitPreference == .metric ? $0 / 1_000 : $0 / 1_609.344
            return String(format: "%.2f", display)
        } ?? "")
        _paceLowerText = State(initialValue: workout.targetPaceLowerBound.map {
            let display = unitPreference == .metric ? $0 : $0 * 1.60934
            return WorkoutEditView.secondsToMMSS(display)
        } ?? "")
        _paceUpperText = State(initialValue: workout.targetPaceUpperBound.map {
            let display = unitPreference == .metric ? $0 : $0 * 1.60934
            return WorkoutEditView.secondsToMMSS(display)
        } ?? "")
        _notesText = State(initialValue: workout.notes ?? "")
    }

    init(week: TrainingWeek, unitPreference: UnitPreference) {
        self.mode = .add(week)
        self.unitPreference = unitPreference
        _selectedType = State(initialValue: .easy)
        _selectedDate = State(initialValue: week.startDate)
        _distanceText = State(initialValue: "")
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
        guard !distanceText.isEmpty, let value = Double(distanceText) else { return nil }
        return unitPreference == .metric ? value * 1_000 : value * 1_609.344
    }

    private var parsedPaceLower: Double? {
        guard !paceLowerText.isEmpty, let secs = WorkoutEditView.mmssToSeconds(paceLowerText) else { return nil }
        return unitPreference == .metric ? secs : secs / 1.60934
    }

    private var parsedPaceUpper: Double? {
        guard !paceUpperText.isEmpty, let secs = WorkoutEditView.mmssToSeconds(paceUpperText) else { return nil }
        return unitPreference == .metric ? secs : secs / 1.60934
    }

    private var paceLowerInvalid: Bool {
        !paceLowerText.isEmpty && WorkoutEditView.mmssToSeconds(paceLowerText) == nil
    }

    private var paceUpperInvalid: Bool {
        !paceUpperText.isEmpty && WorkoutEditView.mmssToSeconds(paceUpperText) == nil
    }

    /// Lower bound = faster = smaller value; inverted when the "faster" entry is numerically larger.
    private var paceRangeInverted: Bool {
        guard let lo = WorkoutEditView.mmssToSeconds(paceLowerText),
              let hi = WorkoutEditView.mmssToSeconds(paceUpperText) else { return false }
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

                Section("Distance (\(unitPreference == .metric ? "km" : "mi"))") {
                    TextField("e.g. 10.5", text: $distanceText)
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
                    Text("Target Pace /\(unitPreference == .metric ? "km" : "mi")")
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
