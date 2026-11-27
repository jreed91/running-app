import SwiftData
import SwiftUI

// MARK: - CustomWorkoutEditorView

/// Builds or edits one custom workout (Custom workouts, PR 2).
///
/// Works on a ``CustomWorkoutDraft`` and only writes a ``SavedWorkout`` on Save, so Cancel
/// leaves the library as it was. The rules and the totals are ``CustomWorkoutRules``'s, the
/// same ones every other caller saves with.
struct CustomWorkoutEditorView: View {

    enum Target: Identifiable {
        case new(CustomWorkoutDraft)
        case existing(SavedWorkout)

        var id: String {
            switch self {
            case .new(let draft): "new-\(draft.name)"
            case .existing(let workout): workout.id.uuidString
            }
        }
    }

    let target: Target
    let trainingPaces: TrainingPaces?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var appSettings

    /// Set in `init`, not `onAppear`: the fields below read their starting text when they
    /// first appear, and a draft swapped in after that would leave them showing the default.
    @State private var draft: CustomWorkoutDraft
    @State private var confirmingDeletion = false
    /// Problems are shown once the runner has tried to save, not while they type.
    @State private var triedToSave = false

    /// Whether an existing workout offers Delete. Off where the screen underneath shows
    /// the workout itself.
    let allowsDelete: Bool

    init(target: Target, trainingPaces: TrainingPaces?, allowsDelete: Bool = true) {
        self.target = target
        self.trainingPaces = trainingPaces
        self.allowsDelete = allowsDelete
        _draft = State(initialValue: Self.draft(for: target))
    }

    private var unit: UnitPreference { appSettings.unitPreference }

    private var existing: SavedWorkout? {
        if case .existing(let workout) = target { return workout }
        return nil
    }

    private var fallback: CustomWorkoutRules.FallbackPaces {
        trainingPaces.map(CustomWorkoutRules.FallbackPaces.init(paces:)) ?? .standard
    }

    private var problems: [CustomWorkoutRules.Problem] {
        CustomWorkoutRules.problems(name: draft.name, structure: draft.structure())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. 6 × 800 m", text: $draft.name)
                        .accessibilityIdentifier("customWorkout.name")
                }
                .strideListRow()

                Section("Warm-up") {
                    OptionalStepLengthEditor(length: $draft.warmup, unit: unit)
                }
                .strideListRow()

                // By the set's id, not its index: a binding by index outlives a removed set
                // for a frame and reads past the end of the array.
                ForEach($draft.sets) { $set in
                    SetEditorSection(
                        set: $set,
                        number: (draft.sets.firstIndex { $0.id == set.id } ?? 0) + 1,
                        canDelete: draft.sets.count > 1,
                        unit: unit,
                        trainingPaces: trainingPaces
                    ) {
                        let id = set.id
                        draft.sets.removeAll { $0.id == id }
                    }
                }

                Section {
                    Button("Add a set", systemImage: "plus") { draft.addSet() }
                        .accessibilityIdentifier("customWorkout.addSet")
                }
                .strideListRow()

                Section("Cool-down") {
                    OptionalStepLengthEditor(length: $draft.cooldown, unit: unit)
                }
                .strideListRow()

                Section("Notes") {
                    TextField("Where, or how it should feel", text: $draft.notes, axis: .vertical)
                        .lineLimit(1...4)
                }
                .strideListRow()

                summarySection

                if existing != nil, allowsDelete {
                    Section {
                        Button("Delete workout", role: .destructive) { confirmingDeletion = true }
                            .buttonStyle(.strideButton(.destructive))
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .strideList()
            .navigationTitle(existing == nil ? "New workout" : "Edit workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") { save() }
                        .accessibilityIdentifier("customWorkout.save")
                }
            }
            .confirmationDialog(
                "Delete \(draft.name.isEmpty ? String(localized: "this workout") : draft.name)?",
                isPresented: $confirmingDeletion,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { deleteExisting() }
            } message: {
                Text("Runs you did with it stay in your history.")
            }
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        let structure = CustomWorkoutRules.finalized(draft.structure(), fallback: fallback)
        Section {
            if let totals = CustomWorkoutSummary.totalsLine(structure, unit: unit) {
                LabeledContent("Estimate", value: totals)
                    .monospacedDigit()
            }
            if triedToSave {
                ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                    Label(problem.message, systemImage: "exclamationmark.circle")
                        .font(.dsSubhead)
                        .foregroundStyle(Color.red)
                }
            }
        } footer: {
            Text("Paces you leave off are estimated from your easy and threshold paces. Warm-up, cool-down and recoveries are run at an easy effort.")
        }
        .strideListRow()
    }

    // MARK: Actions

    private static func draft(for target: Target) -> CustomWorkoutDraft {
        switch target {
        case .new(let starter):
            return starter
        case .existing(let workout):
            guard let structure = workout.structure else {
                return CustomWorkoutDraft(name: workout.name, notes: workout.notes ?? "")
            }
            return CustomWorkoutDraft(name: workout.name, structure: structure, notes: workout.notes)
        }
    }

    private func save() {
        triedToSave = true
        guard problems.isEmpty else { return }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let structure = CustomWorkoutRules.finalized(draft.structure(), fallback: fallback)
        if let existing {
            existing.update(name: name, structure: structure, notes: notes.isEmpty ? nil : notes)
        } else {
            context.insert(SavedWorkout(name: name, structure: structure, notes: notes.isEmpty ? nil : notes))
        }
        context.saveOrLog("a custom workout")
        dismiss()
    }

    private func deleteExisting() {
        guard let existing else { return }
        context.delete(existing)
        context.saveOrLog("the deletion of a custom workout")
        dismiss()
    }
}

// MARK: - A set

private struct SetEditorSection: View {
    @Binding var set: CustomWorkoutDraft.SetDraft
    let number: Int
    let canDelete: Bool
    let unit: UnitPreference
    let trainingPaces: TrainingPaces?
    let onDelete: () -> Void

    var body: some View {
        Section {
            TextField("Name (optional), e.g. Tempo", text: $set.label)
            Stepper(value: $set.repetitions, in: CustomWorkoutRules.repetitionRange) {
                LabeledContent("Reps", value: "\(set.repetitions)")
            }
            .accessibilityIdentifier("customWorkout.set\(number).reps")
            StepLengthEditor(length: $set.work, unit: unit)
            PaceEditor(secondsPerKm: $set.workPaceSecondsPerKm, unit: unit, trainingPaces: trainingPaces)
            RecoveryEditor(length: $set.recovery, kind: $set.recoveryKind, unit: unit)
            if canDelete {
                Button("Remove set", systemImage: "trash", role: .destructive, action: onDelete)
            }
        } header: {
            Text("Set \(number)")
        } footer: {
            if set.repetitions > 1 {
                Text("No recovery after the last rep of the last set: the cool-down follows it.")
            }
        }
        .strideListRow()
    }
}

// MARK: - Lengths

/// Distance or time for a step that is always there (a rep).
private struct StepLengthEditor: View {
    @Binding var length: CustomWorkoutDraft.StepLength
    let unit: UnitPreference

    var body: some View {
        Picker("Measure by", selection: isDistance) {
            Text("Distance").tag(true)
            Text("Time").tag(false)
        }
        .pickerStyle(.segmented)
        switch length {
        case .distance(let meters):
            DistanceField(meters: meters, unit: unit) { length = .distance(meters: $0) }
                .id("distance")
        case .time(let seconds):
            DurationField(title: "Time", seconds: seconds) { length = .time(seconds: $0) }
                .id("time")
        }
    }

    private var isDistance: Binding<Bool> {
        Binding(
            get: { length.isDistance },
            set: { distance in
                guard distance != length.isDistance else { return }
                length = distance ? .distance(meters: 400) : .time(seconds: 60)
            }
        )
    }
}

/// None, a distance or a time, for a warm-up or cool-down.
private struct OptionalStepLengthEditor: View {
    @Binding var length: CustomWorkoutDraft.StepLength?
    let unit: UnitPreference

    private enum Choice: Hashable { case none, distance, time }

    var body: some View {
        Picker("Length", selection: choice) {
            Text("None").tag(Choice.none)
            Text("Distance").tag(Choice.distance)
            Text("Time").tag(Choice.time)
        }
        .pickerStyle(.segmented)
        switch length {
        case .distance(let meters):
            DistanceField(meters: meters, unit: unit) { length = .distance(meters: $0) }
                .id("distance")
        case .time(let seconds):
            DurationField(title: "Time", seconds: seconds) { length = .time(seconds: $0) }
                .id("time")
        case nil:
            EmptyView()
        }
    }

    private var choice: Binding<Choice> {
        Binding(
            get: {
                switch length {
                case .distance: .distance
                case .time: .time
                case nil: .none
                }
            },
            set: { new in
                switch new {
                case .none: length = nil
                case .distance: if length?.isDistance != true { length = .distance(meters: 1_000) }
                case .time: if length == nil || length?.isDistance == true { length = .time(seconds: 10 * 60) }
                }
            }
        )
    }
}

/// The recovery between reps: none, or a time or distance to jog, walk or rest.
private struct RecoveryEditor: View {
    @Binding var length: CustomWorkoutDraft.StepLength?
    @Binding var kind: CustomWorkoutDraft.RecoveryKind
    let unit: UnitPreference

    var body: some View {
        Toggle("Recovery between reps", isOn: hasRecovery)
        if length != nil {
            Picker("Recovery", selection: $kind) {
                ForEach(CustomWorkoutDraft.RecoveryKind.allCases, id: \.self) { kind in
                    Text(verbatim: kind.label).tag(kind)
                }
            }
            StepLengthEditor(length: recoveryLength, unit: unit)
        }
    }

    private var hasRecovery: Binding<Bool> {
        Binding(
            get: { length != nil },
            set: { on in length = on ? (length ?? .time(seconds: 90)) : nil }
        )
    }

    private var recoveryLength: Binding<CustomWorkoutDraft.StepLength> {
        Binding(
            get: { length ?? .time(seconds: 90) },
            set: { length = $0 }
        )
    }
}

// MARK: - Fields

/// A distance typed as a number, in metres, kilometres or miles.
private struct DistanceField: View {
    let meters: Double
    let unit: UnitPreference
    let onChange: (Double) -> Void

    @State private var text = ""
    @State private var distanceUnit: CustomWorkoutDistanceUnit = .meters
    @State private var loaded = false

    var body: some View {
        HStack {
            Text("Distance")
            Spacer()
            TextField("Distance", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(maxWidth: 100)
            Picker("Unit", selection: $distanceUnit) {
                ForEach(CustomWorkoutDistanceUnit.allCases, id: \.self) { unit in
                    Text(verbatim: unit.symbol).tag(unit)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            distanceUnit = .display(for: meters, unit: unit)
            text = CustomWorkoutSummary.number(meters / distanceUnit.metersPerUnit)
        }
        .onChange(of: text) { commit() }
        .onChange(of: distanceUnit) { commit() }
    }

    private func commit() {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0 else { return }
        onChange(value * distanceUnit.metersPerUnit)
    }
}

/// A time typed as "m:ss", or whole minutes.
private struct DurationField: View {
    let title: LocalizedStringKey
    let seconds: Double
    let onChange: (Double) -> Void

    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("m:ss", text: $text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(maxWidth: 120)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = MinutesSecondsText.text(seconds: seconds)
        }
        .onChange(of: text) {
            if let value = MinutesSecondsText.seconds(from: text) { onChange(value) }
        }
    }
}

/// An optional target pace per the runner's unit, with their own paces one tap away.
private struct PaceEditor: View {
    @Binding var secondsPerKm: Double?
    let unit: UnitPreference
    let trainingPaces: TrainingPaces?

    @State private var text = ""

    var body: some View {
        Toggle("Target pace", isOn: hasPace)
        if secondsPerKm != nil {
            HStack {
                Text(unit == .metric ? "Pace per km" : "Pace per mile")
                Spacer()
                TextField("m:ss", text: $text)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(maxWidth: 100)
            }
            .onAppear {
                if text.isEmpty, let secondsPerKm {
                    text = MinutesSecondsText.paceText(secondsPerKm: secondsPerKm, unit: unit)
                }
            }
            .onChange(of: text) {
                if let value = MinutesSecondsText.paceSecondsPerKm(from: text, unit: unit) {
                    secondsPerKm = value
                }
            }
            if let trainingPaces {
                Menu("Use one of my paces") {
                    ForEach(Self.presets(trainingPaces), id: \.name) { preset in
                        Button("\(preset.name) · \(MinutesSecondsText.paceText(secondsPerKm: preset.pace, unit: unit))") {
                            set(preset.pace)
                        }
                    }
                }
            }
        }
    }

    private var hasPace: Binding<Bool> {
        Binding(
            get: { secondsPerKm != nil },
            set: { on in
                if on {
                    set(secondsPerKm ?? trainingPaces?.threshold ?? 300)
                } else {
                    secondsPerKm = nil
                }
            }
        )
    }

    private func set(_ pace: Double) {
        secondsPerKm = pace
        text = MinutesSecondsText.paceText(secondsPerKm: pace, unit: unit)
    }

    private struct Preset { let name: String; let pace: Double }

    private static func presets(_ paces: TrainingPaces) -> [Preset] {
        [
            Preset(name: String(localized: "Easy"), pace: paces.easyRange.upperBound),
            Preset(name: String(localized: "Marathon"), pace: paces.marathon),
            Preset(name: String(localized: "Threshold"), pace: paces.threshold),
            Preset(name: String(localized: "Interval"), pace: paces.interval),
            Preset(name: String(localized: "Repetition"), pace: paces.repetition)
        ]
    }
}
