import SwiftUI
import SwiftData

// MARK: - StrengthActiveView

struct StrengthActiveView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let scheduledWorkout: ScheduledWorkout?

    // Exercise progression
    @State private var currentExerciseIndex: Int = 0
    @State private var currentSetIndex: Int = 0
    @State private var completedSets: [CompletedStrengthSet] = []

    // Logging inputs
    @State private var repInput: Int = 10
    @State private var weightInput: String = ""

    // Rest timer
    @State private var restTimerActive: Bool = false
    @State private var restTimeRemaining: Int = 0
    @State private var restTimerTask: Task<Void, Never>?
    private let defaultRestSeconds = 60

    // Session timing
    @State private var startTime: Date = Date()

    // Confirmation
    @State private var showFinishConfirmation: Bool = false
    @State private var showSkipConfirmation: Bool = false

    private var plan: StrengthWorkoutPlan? { scheduledWorkout?.strengthPlan }
    private var exercises: [StrengthExercise] { plan?.exercises ?? [] }
    private var currentExercise: StrengthExercise? {
        guard currentExerciseIndex < exercises.count else { return nil }
        return exercises[currentExerciseIndex]
    }

    var body: some View {
        ZStack {
            Color.surfacePrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header bar
                headerBar

                if exercises.isEmpty {
                    noExercisesView
                } else if let exercise = currentExercise {
                    ScrollView {
                        VStack(spacing: 20) {
                            progressHeader
                            exerciseCard(exercise: exercise)
                            if restTimerActive {
                                restTimerCard
                            } else {
                                logSetCard(exercise: exercise)
                            }
                            completedSetsHistory
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 20)
                    }
                } else {
                    workoutCompleteView
                }

                finishButton
            }
        }
        .onAppear { setupForCurrentExercise() }
        .confirmationDialog(
            "Finish Workout?",
            isPresented: $showFinishConfirmation,
            titleVisibility: .visible
        ) {
            Button("Finish & Save") { finishAndSave() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your progress will be saved.")
        }
        .onDisappear { endRestTimer() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Button { showFinishConfirmation = true } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.surfaceSecondary, in: Circle())

            Spacer()

            VStack(spacing: 2) {
                Text("Strength Workout")
                    .font(.system(size: 15, weight: .semibold))
                Text(elapsedTimeString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Placeholder to balance the X button
            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: - Progress Header

    private var progressHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Array(exercises.enumerated()), id: \.offset) { idx, _ in
                    Capsule()
                        .fill(idx < currentExerciseIndex
                              ? Color.brand
                              : (idx == currentExerciseIndex ? Color.brand.opacity(0.6) : Color.surfaceSecondary))
                        .frame(height: 4)
                }
            }

            HStack {
                Text("Exercise \(currentExerciseIndex + 1) of \(exercises.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                if let exercise = currentExercise {
                    Text("Set \(currentSetIndex + 1) of \(exercise.sets)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.brand)
                }
            }
        }
    }

    // MARK: - Exercise Card

    private func exerciseCard(exercise: StrengthExercise) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(exercise.name)
                        .font(.system(size: 22, weight: .bold))
                    HStack(spacing: 6) {
                        ForEach(exercise.muscleGroups.prefix(3), id: \.self) { group in
                            Text(group)
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.brand.opacity(0.12), in: Capsule())
                                .foregroundStyle(Color.brand)
                        }
                    }
                }
                Spacer()
                ZStack {
                    Circle()
                        .fill(Color.brand.opacity(0.12))
                        .frame(width: 52, height: 52)
                    Image(systemName: "figure.strengthtraining.traditional")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.brand)
                }
            }

            Divider()

            HStack(spacing: 24) {
                statPill(label: "TARGET", value: targetRepsLabel(exercise))
                if let weight = exercise.targetWeight {
                    statPill(label: "WEIGHT", value: weight)
                }
                statPill(label: "SETS LEFT", value: "\(exercise.sets - currentSetIndex)")
            }

            if let notes = exercise.notes {
                Text(notes)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - Log Set Card

    private func logSetCard(exercise: StrengthExercise) -> some View {
        VStack(spacing: 16) {
            Text("LOG SET \(currentSetIndex + 1)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let durationSeconds = exercise.durationSeconds {
                // Timed exercise — just log completion with no rep count
                VStack(spacing: 8) {
                    Text("Hold for \(durationSeconds) seconds")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Tap below when done")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            } else {
                // Rep-based exercise
                VStack(spacing: 12) {
                    HStack {
                        Text("Reps completed")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Stepper("\(repInput)", value: $repInput, in: 0...99)
                            .labelsHidden()
                        Text("\(repInput)")
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .frame(minWidth: 40, alignment: .center)
                    }

                    HStack {
                        Text("Weight / resistance")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField(exercise.targetWeight ?? "Optional", text: $weightInput)
                            .font(.system(size: 15))
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 120)
                    }
                }
            }

            Button {
                logSet(exercise: exercise)
            } label: {
                Text(exercise.durationSeconds != nil ? "Done — Next Set" : "Log Set")
                    .font(.system(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .foregroundStyle(.white)
            .background(Color.brand, in: RoundedRectangle(cornerRadius: 14))

            Button {
                skipSet()
            } label: {
                Text("Skip")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - Rest Timer Card

    private var restTimerCard: some View {
        VStack(spacing: 16) {
            Text("REST")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                Circle()
                    .stroke(Color.surfacePrimary, lineWidth: 6)
                    .frame(width: 100, height: 100)
                Circle()
                    .trim(from: 0, to: restProgress)
                    .stroke(Color.brand, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 100, height: 100)
                    .animation(.linear(duration: 1), value: restTimeRemaining)
                VStack(spacing: 2) {
                    Text("\(restTimeRemaining)")
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                    Text("sec")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                endRestTimer()
            } label: {
                Text("Skip Rest")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.brand)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(16)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 18))
    }

    private var restProgress: Double {
        let elapsed = Double(defaultRestSeconds - restTimeRemaining)
        return elapsed / Double(defaultRestSeconds)
    }

    // MARK: - Completed Sets History

    @ViewBuilder
    private var completedSetsHistory: some View {
        let setsForCurrentExercise = completedSets
            .filter { $0.exerciseIndex == currentExerciseIndex && !$0.skipped }
        if !setsForCurrentExercise.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("COMPLETED SETS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(setsForCurrentExercise.enumerated()), id: \.offset) { _, set in
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.brand)
                            .font(.system(size: 14))
                        Text("Set \(set.setIndex + 1)")
                            .font(.system(size: 14))
                        Spacer()
                        if set.completedReps > 0 {
                            Text("\(set.completedReps) reps")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        if let weight = set.actualWeight, !weight.isEmpty {
                            Text("· \(weight)")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    // MARK: - Workout Complete

    private var workoutCompleteView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.brand)
            Text("All exercises done!")
                .font(.system(size: 22, weight: .bold))
            Text("Tap Finish to save your workout.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - No Exercises

    private var noExercisesView: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("No exercises planned")
                .font(.system(size: 17, weight: .semibold))
            Text("This strength workout has no exercise data.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Finish Button

    private var finishButton: some View {
        Button {
            showFinishConfirmation = true
        } label: {
            Text("Finish Workout")
                .font(.system(size: 17, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
        .foregroundStyle(.white)
        .background(Color.brand, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private func statPill(label: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .bold))
        }
    }

    private func targetRepsLabel(_ exercise: StrengthExercise) -> String {
        if let duration = exercise.durationSeconds {
            return "\(duration)s"
        } else if exercise.reps == 0 {
            return "AMRAP"
        } else {
            return "\(exercise.reps) reps"
        }
    }

    private var elapsedTimeString: String {
        let elapsed = Int(Date().timeIntervalSince(startTime))
        let m = elapsed / 60
        let s = elapsed % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Actions

    private func setupForCurrentExercise() {
        guard let exercise = currentExercise else { return }
        repInput = exercise.reps > 0 ? exercise.reps : 10
        weightInput = ""
    }

    private func logSet(exercise: StrengthExercise) {
        let reps = exercise.durationSeconds != nil ? 1 : repInput
        let weight = weightInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let set = CompletedStrengthSet(
            exerciseIndex: currentExerciseIndex,
            setIndex: currentSetIndex,
            completedReps: reps,
            actualWeight: weight.isEmpty ? nil : weight,
            skipped: false
        )
        completedSets.append(set)
        advanceAfterSet(exercise: exercise)
    }

    private func skipSet() {
        let set = CompletedStrengthSet(
            exerciseIndex: currentExerciseIndex,
            setIndex: currentSetIndex,
            completedReps: 0,
            actualWeight: nil,
            skipped: true
        )
        completedSets.append(set)
        advanceAfterSet(exercise: currentExercise ?? exercises[0])
    }

    private func advanceAfterSet(exercise: StrengthExercise) {
        let nextSet = currentSetIndex + 1
        if nextSet < exercise.sets {
            currentSetIndex = nextSet
            startRestTimer()
        } else {
            // Move to next exercise
            let nextExercise = currentExerciseIndex + 1
            currentExerciseIndex = nextExercise
            currentSetIndex = 0
            setupForCurrentExercise()
        }
    }

    private func startRestTimer() {
        restTimerTask?.cancel()
        restTimeRemaining = defaultRestSeconds
        restTimerActive = true
        restTimerTask = Task { @MainActor in
            while restTimeRemaining > 0 && restTimerActive {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                guard restTimerActive else { break }
                restTimeRemaining = max(0, restTimeRemaining - 1)
            }
            if restTimerActive { endRestTimer() }
        }
    }

    private func endRestTimer() {
        restTimerTask?.cancel()
        restTimerTask = nil
        restTimerActive = false
        restTimeRemaining = 0
    }

    private func finishAndSave() {
        endRestTimer()
        let duration = Date().timeIntervalSince(startTime)
        let strengthWorkout = StrengthWorkout(date: startTime, durationSeconds: duration)
        strengthWorkout.completedSets = completedSets
        strengthWorkout.scheduledWorkout = scheduledWorkout
        strengthWorkout.linkedScheduledWorkoutID = scheduledWorkout?.id
        context.insert(strengthWorkout)
        if let scheduled = scheduledWorkout {
            scheduled.completedStrengthWorkout = strengthWorkout
            scheduled.isCompleted = true
            scheduled.linkedStrengthWorkoutID = strengthWorkout.id
        }
        try? context.save()
        dismiss()
    }
}
