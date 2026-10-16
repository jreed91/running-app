import SwiftUI
import SwiftData

// MARK: - StrengthActiveView

struct StrengthActiveView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var container
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
    @State private var restDeadline: Date?
    @State private var restTimerTask: Task<Void, Never>?
    private let defaultRestSeconds = 60

    // Session timing
    @State private var startTime: Date = Date()

    // Symbols sized by `.font` scale with the circles behind them, so the glyph
    // can't outgrow its badge at large content sizes (U2).
    @ScaledMetric(relativeTo: .title2) private var exerciseBadgeSize: CGFloat = 52
    @ScaledMetric(relativeTo: .largeTitle) private var completionGlyphSize: CGFloat = 64

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
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.vertical, AppSpacing.xl)
                    }
                } else {
                    workoutCompleteView
                }

                finishButton
            }
        }
        .onAppear { setupForCurrentExercise() }
        .confirmationDialog(
            hasLoggedWork ? "Finish Workout?" : "Discard Workout?",
            isPresented: $showFinishConfirmation,
            titleVisibility: .visible
        ) {
            // Only offer to save when something was actually logged — otherwise an
            // accidentally opened session must not be force-saved and mark the day
            // complete with zero sets (H5).
            if hasLoggedWork {
                Button("Finish & Save") { finishAndSave() }
            }
            Button("Discard Workout", role: .destructive) { discard() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(hasLoggedWork
                 ? "Your progress will be saved."
                 : "No sets were logged — this workout won't be saved and the day stays open.")
        }
        .onDisappear { endRestTimer() }
        // Haptics (U4). Logging a set and the rest timer expiring are both moments
        // the lifter is mid-movement and not looking at the phone.
        .sensoryFeedback(.selection, trigger: completedSets.count) { old, new in new > old }
        .sensoryFeedback(.success, trigger: restTimeRemaining) { old, new in old == 1 && new == 0 }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Button { showFinishConfirmation = true } label: {
                Image(systemName: "xmark")
                    .font(.dsCallout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.surfaceSecondary, in: Circle())
            .accessibilityLabel("End session")
            .accessibilityHint("Asks whether to save or discard this strength session.")

            Spacer()

            VStack(spacing: 2) {
                Text("Strength Workout")
                    .font(.dsSubhead.weight(.semibold))
                // Tick on the wall clock so the elapsed time advances on its own
                // rather than only refreshing as a side effect of logging a set (M27).
                TimelineView(.periodic(from: startTime, by: 1)) { context in
                    Text(elapsedTimeString(asOf: context.date))
                        .font(.dsCaption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Placeholder to balance the X button
            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.sm)
        .padding(.bottom, AppSpacing.md)
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
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let exercise = currentExercise {
                    Text("Set \(currentSetIndex + 1) of \(exercise.sets)")
                        .font(.dsCaption.weight(.semibold))
                        .foregroundStyle(.brandText)
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
                        .font(.dsTitle2)
                    HStack(spacing: 6) {
                        ForEach(exercise.muscleGroups.prefix(3), id: \.self) { group in
                            Text(group)
                                .font(.dsCaption2.weight(.medium))
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
                        .frame(width: exerciseBadgeSize, height: exerciseBadgeSize)
                    Image(systemName: "figure.strengthtraining.traditional")
                        .font(.system(size: exerciseBadgeSize * 0.46))
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
                    .font(.dsFootnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppSpacing.lg)
        .strideCard(cornerRadius: AppRadius.lg)
    }

    // MARK: - Log Set Card

    private func logSetCard(exercise: StrengthExercise) -> some View {
        VStack(spacing: 16) {
            Text("LOG SET \(currentSetIndex + 1)")
                .font(.dsCaption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let durationSeconds = exercise.durationSeconds {
                // Timed exercise — just log completion with no rep count
                VStack(spacing: 8) {
                    Text("Hold for \(durationSeconds) seconds")
                        .font(.dsHeadline)
                    Text("Tap below when done")
                        .font(.dsFootnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            } else {
                // Rep-based exercise
                VStack(spacing: 12) {
                    HStack {
                        Text("Reps completed")
                            .font(.dsSubhead)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Stepper("\(repInput)", value: $repInput, in: 0...99)
                            .labelsHidden()
                        Text("\(repInput)")
                            .font(.dsTitle2.monospacedDigit())
                            .frame(minWidth: 40, alignment: .center)
                    }

                    HStack {
                        Text("Weight / resistance")
                            .font(.dsSubhead)
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField(exercise.targetWeight ?? "Optional", text: $weightInput)
                            .font(.dsSubhead)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 120)
                    }
                }
            }

            Button {
                logSet(exercise: exercise)
            } label: {
                Text(exercise.durationSeconds != nil ? "Done — Next Set" : "Log Set")
            }
            .buttonStyle(.strideButton())

            Button {
                skipSet()
            } label: {
                Text("Skip")
                    .font(.dsSubhead)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppSpacing.lg)
        .strideCard(cornerRadius: AppRadius.lg)
    }

    // MARK: - Rest Timer Card

    private var restTimerCard: some View {
        VStack(spacing: 16) {
            Text("REST")
                .font(.dsCaption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                Circle()
                    .stroke(Color.surfacePrimary, lineWidth: 6)
                    .frame(width: 100, height: 100)
                Circle()
                    .trim(from: 0, to: restProgress)
                    .stroke(.route, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 100, height: 100)
                    .animation(.linear(duration: 1), value: restTimeRemaining)
                VStack(spacing: 2) {
                    Text("\(restTimeRemaining)")
                        .font(.dsTitle1.monospacedDigit())
                    Text("sec")
                        .font(.dsCaption2)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                endRestTimer()
            } label: {
                Text("Skip Rest")
                    .font(.dsSubhead.weight(.semibold))
                    .foregroundStyle(.brandText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md)
                    .background(Color.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.md))
            }
        }
        .padding(AppSpacing.lg)
        .strideCard(cornerRadius: AppRadius.lg)
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
                    .font(.dsCaption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(setsForCurrentExercise.enumerated()), id: \.offset) { _, set in
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.brand)
                            .font(.dsSubhead)
                        Text("Set \(set.setIndex + 1)")
                            .font(.dsSubhead)
                        Spacer()
                        if set.completedReps > 0 {
                            Text("\(set.completedReps) reps")
                                .font(.dsFootnote)
                                .foregroundStyle(.secondary)
                        }
                        if let weight = set.actualWeight, !weight.isEmpty {
                            Text("· \(weight)")
                                .font(.dsFootnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.sm)
                    .strideCard(cornerRadius: AppRadius.sm)
                }
            }
        }
    }

    // MARK: - Workout Complete

    private var workoutCompleteView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: completionGlyphSize))
                .foregroundStyle(Color.brand)
                // The one moment in the strength flow worth celebrating. Non-repeating:
                // this screen can sit on-screen while the runner catches their breath,
                // and a looping bounce would be the only thing moving on it.
                .symbolEffect(.bounce, options: .nonRepeating)
            Text("All exercises done!")
                .font(.dsTitle2)
            Text("Tap Finish to save your workout.")
                .font(.dsSubhead)
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
                .font(.dsHeadline)
            Text("This strength workout has no exercise data.")
                .font(.dsSubhead)
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
                .font(.dsHeadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.lg)
        }
        .foregroundStyle(.onFill)
        .background(.route, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        .padding(.horizontal, AppSpacing.lg)
        .padding(.bottom, AppSpacing.xl)
        .padding(.top, AppSpacing.sm)
    }

    // MARK: - Helpers

    private func statPill(label: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.dsCaption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.dsSubhead.weight(.bold))
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

    /// True once at least one set has been logged (skipped sets don't count).
    private var hasLoggedWork: Bool {
        completedSets.contains { !$0.skipped }
    }

    private func elapsedTimeString(asOf now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(startTime)))
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
        let deadline = Date().addingTimeInterval(TimeInterval(defaultRestSeconds))
        restDeadline = deadline
        restTimeRemaining = defaultRestSeconds
        restTimerActive = true
        restTimerTask = Task { @MainActor in
            // Derive the remaining time from a fixed deadline each tick so a
            // suspended app resumes with the correct countdown (M27) rather than
            // freezing at whatever value it held when it went to the background.
            while restTimerActive {
                restTimeRemaining = RestCountdown.secondsRemaining(deadline: deadline, now: Date())
                if restTimeRemaining <= 0 { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
            }
            if restTimerActive { endRestTimer() }
        }
    }

    private func endRestTimer() {
        restTimerTask?.cancel()
        restTimerTask = nil
        restTimerActive = false
        restTimeRemaining = 0
        restDeadline = nil
    }

    /// Leave without persisting anything — the scheduled day stays open (H5).
    private func discard() {
        endRestTimer()
        dismiss()
    }

    private func finishAndSave() {
        endRestTimer()
        // Never persist an empty session or mark the scheduled day complete when
        // nothing was logged (H5) — a safety net behind the dialog's gating.
        guard hasLoggedWork else { dismiss(); return }
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
        context.saveOrLog("the finished strength session")
        exportToHealthKit(strengthWorkout)
        dismiss()
    }

    /// Mirrors what a finished run does: the session is already safely in the store,
    /// so the export enriches it rather than gating it (N14). Without this a strength
    /// session logged in Stride earns no Activity-ring credit and never reaches Fitness,
    /// and the Watch-vs-app merge has only the ±3 h heuristic to work with.
    private func exportToHealthKit(_ workout: StrengthWorkout) {
        Task { @MainActor in
            do {
                workout.healthKitWorkoutID = try await container.healthKitRepository.save(workout)
                context.saveOrLog("the strength session's HealthKit id")
            } catch {
                AppLogger.log("Failed to export strength workout to HealthKit: \(error)",
                              label: "HealthKit", level: .error)
            }
        }
    }
}
