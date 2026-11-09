import SwiftUI
import SwiftData

// MARK: - StrengthActiveView

struct StrengthActiveView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppSettings.self) private var appSettings

    let scheduledWorkout: ScheduledWorkout?
    /// The exercises for a session the plan didn't schedule ("Strength session" on Home).
    /// Ignored when `scheduledWorkout` carries its own plan.
    let unplannedPlan: StrengthWorkoutPlan?

    init(scheduledWorkout: ScheduledWorkout?, unplannedPlan: StrengthWorkoutPlan? = nil) {
        self.scheduledWorkout = scheduledWorkout
        self.unplannedPlan = unplannedPlan
    }

    /// Recent sessions, newest first, for "last time" and the next-load suggestion. Sixty
    /// sessions is over a year at a typical one or two a week, far more than any one
    /// exercise's last outing needs, without loading a lifetime of history.
    @Query(StrengthActiveView.recentSessionsDescriptor)
    private var recentSessions: [StrengthWorkout]

    @Query private var profiles: [UserProfile]
    @Query(filter: #Predicate<TrainingPlan> { $0.isActive == true })
    private var activePlans: [TrainingPlan]

    /// Exercises swapped for this session only, by position in the plan. The plan itself
    /// is left alone: next week's session still has the original, and the logged sets
    /// carry the name of what was actually done.
    @State private var swaps: [Int: StrengthExercise] = [:]
    @State private var guideExercise: StrengthExercise?
    /// An unplanned session's exercises as they were when it was interrupted, so a resume
    /// doesn't pick up a different week's session from Home.
    @State private var restoredPlan: StrengthWorkoutPlan?
    @State private var hasRestored = false
    @State private var showSwapOptions = false
    @State private var showSessionEditor = false

    static var recentSessionsDescriptor: FetchDescriptor<StrengthWorkout> {
        var descriptor = FetchDescriptor<StrengthWorkout>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 60
        return descriptor
    }

    // Exercise progression
    @State private var currentExerciseIndex: Int = 0
    @State private var currentSetIndex: Int = 0
    @State private var completedSets: [CompletedStrengthSet] = []

    // Logging inputs
    @State private var repInput: Int = 10
    /// The load in the runner's unit (kg or lb), for exercises done with a weight.
    @State private var weightInput: Double?
    /// Free text for unloaded work: the band's colour, a harder variation.
    @State private var noteInput: String = ""

    // What happened last time, and what to try now, for the current exercise.
    @State private var lastPerformance: ExercisePerformance?
    @State private var suggestion: LoadSuggestion?

    // Rest timer
    /// Idle, or resting toward a deadline. See `RestTimerState` for the transitions.
    @State private var restTimer: RestTimerState = .idle
    @State private var restTimerTask: Task<Void, Never>?
    /// This exercise's rest, from ``StrengthProgression/restSeconds(for:)``.
    @State private var restSeconds: Int = 60

    // Session timing
    @State private var startTime: Date = Date()

    // Symbols sized by `.font` scale with the circles behind them, so the glyph
    // can't outgrow its badge at large content sizes (U2).
    @ScaledMetric(relativeTo: .title2) private var exerciseBadgeSize: CGFloat = 52
    @ScaledMetric(relativeTo: .largeTitle) private var completionGlyphSize: CGFloat = 64

    // Confirmation
    @State private var showFinishConfirmation: Bool = false
    @State private var showSkipConfirmation: Bool = false

    private var unit: UnitPreference { appSettings.unitPreference }

    private var plan: StrengthWorkoutPlan? { scheduledWorkout?.strengthPlan ?? restoredPlan ?? unplannedPlan }
    private var exercises: [StrengthExercise] {
        (plan?.exercises ?? []).enumerated().map { index, exercise in swaps[index] ?? exercise }
    }

    /// What the current exercise could be swapped for with the runner's equipment.
    private var swapOptions: [StrengthExercise] {
        guard let exercise = currentExercise else { return [] }
        return StrengthLibrary.alternatives(
            to: exercise,
            equipment: profiles.first?.selectedEquipment ?? [],
            excluding: StrengthPreferences.load().excluded
        )
    }
    private var currentExercise: StrengthExercise? {
        guard currentExerciseIndex < exercises.count else { return nil }
        return exercises[currentExerciseIndex]
    }

    var body: some View {
        ZStack {
            Color.surfacePrimary.ignoresSafeArea()

            // Propped half-open on the floor (iPhone Duo, fold across the display), the
            // exercise is read from the mat on the upper half and the set is logged on the
            // lower half, which rests on the floor. Flat or closed, the same screen as
            // always. See `TabletopLayout`.
            TabletopLayout(isEnabled: currentExercise != nil) {
                flatLayout
            } top: {
                if let exercise = currentExercise {
                    VStack(spacing: 0) {
                        headerBar
                        ScrollView {
                            VStack(spacing: 20) {
                                progressHeader
                                exerciseCard(exercise: exercise)
                                completedSetsHistory
                            }
                            .padding(.horizontal, AppSpacing.lg)
                            .padding(.vertical, AppSpacing.md)
                            .strideReadableWidth()
                        }
                    }
                }
            } bottom: {
                if let exercise = currentExercise {
                    VStack(spacing: 0) {
                        ScrollView {
                            Group {
                                if restTimer.isResting {
                                    restTimerCard
                                } else {
                                    logSetCard(exercise: exercise)
                                }
                            }
                            .padding(.horizontal, AppSpacing.lg)
                            .padding(.vertical, AppSpacing.md)
                            .strideReadableWidth()
                        }
                        finishButton
                    }
                }
            }
        }
        .onAppear {
            restoreIfInterrupted()
            setupForCurrentExercise()
        }
        .confirmationDialog(
            hasLoggedWork ? "Finish workout?" : "Discard workout?",
            isPresented: $showFinishConfirmation,
            titleVisibility: .visible
        ) {
            // Only offer to save when something was actually logged — otherwise an
            // accidentally opened session must not be force-saved and mark the day
            // complete with zero sets (H5).
            if hasLoggedWork {
                Button("Finish & save") { finishAndSave() }
            }
            Button("Discard workout", role: .destructive) { discard() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(hasLoggedWork
                 ? "Your progress will be saved."
                 : "No sets were logged — this workout won't be saved and the day stays open.")
        }
        .onDisappear { endRestTimer() }
        .sheet(item: $guideExercise) { exercise in
            StrengthExerciseGuide(exercise: exercise)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSessionEditor) {
            StrengthSessionEditor(
                exercises: exercises,
                equipment: profiles.first?.selectedEquipment ?? [],
                onSave: applyEdit
            )
        }
        .sheet(isPresented: $showSwapOptions) {
            if let current = currentExercise {
                StrengthSwapSheet(
                    exercise: current,
                    options: swapOptions,
                    onToday: { swap(to: $0) },
                    onEverySession: { alwaysSwap(current, to: $0) },
                    onNeverSuggest: { first in neverSuggest(current, replacingWith: first) }
                )
                .presentationDetents([.medium, .large])
            }
        }
        // Haptics (U4). Logging a set and the rest timer expiring are both moments
        // the lifter is mid-movement and not looking at the phone.
        .sensoryFeedback(.selection, trigger: completedSets.count) { old, new in new > old }
        .sensoryFeedback(.success, trigger: restTimer.remainingSeconds) { old, new in old == 1 && new == 0 }
    }

    /// The session as it has always been laid out: everything in one scroll.
    private var flatLayout: some View {
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
                        if restTimer.isResting {
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

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Button { showFinishConfirmation = true } label: {
                StrideIcon(name: .close, size: 16, color: .secondary, strokeWeight: 2)
                    // 44pt: the minimum tap target, on a screen used mid-set.
                    .frame(width: 44, height: 44)
                    .background(.surfaceSecondary, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
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

            // Before the first set, the session can be changed: sets, reps, exercises.
            // Afterwards the logged sets point into it, so it stays as it is.
            if !hasLoggedWork && !exercises.isEmpty {
                Button("Edit") { showSessionEditor = true }
                    .font(.dsSubhead.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityHint("Change this session's exercises, sets and reps before you start.")
            } else {
                // Placeholder to balance the X button
                Color.clear.frame(width: 44, height: 44)
            }
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
                    progressSegment(idx)
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

    /// The route means progress: done exercises take it, the current one a faded route,
    /// and the rest sit on the track colour.
    @ViewBuilder
    private func progressSegment(_ idx: Int) -> some View {
        if idx < currentExerciseIndex {
            Capsule().fill(.route)
        } else if idx == currentExerciseIndex {
            Capsule().fill(.route).opacity(0.45)
        } else {
            Capsule().fill(.surfaceTertiary)
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
                        // A muscle group is a label, not a control: the shared brand tag.
                        ForEach(exercise.muscleGroups.prefix(3), id: \.self) { group in
                            StrideTag(group, tone: .brand)
                        }
                    }
                }
                Spacer()
                ZStack {
                    Circle()
                        .fill(Color.brand.opacity(0.12))
                        .frame(width: exerciseBadgeSize, height: exerciseBadgeSize)
                    StrideIcon(name: .barbell, size: exerciseBadgeSize * 0.46, color: .brand)
                }
            }

            Divider()

            HStack(spacing: 24) {
                statPill(label: "TARGET", value: targetRepsLabel(exercise))
                if let weight = suggestion?.weightKilograms {
                    statPill(label: "WEIGHT", value: StrengthProgression.weightText(weight, unit: unit))
                } else if let weight = exercise.targetWeight {
                    statPill(label: "WEIGHT", value: weight)
                }
                statPill(label: "SETS LEFT", value: "\(exercise.sets - currentSetIndex)")
            }

            lastTimeLine

            if let notes = exercise.notes {
                Text(notes)
                    .font(.dsFootnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            exerciseActions(exercise)
        }
        .padding(AppSpacing.lg)
        .strideCard(cornerRadius: AppRadius.lg)
    }

    /// "How to" for any exercise the library knows; "Swap" before the exercise's first
    /// set, when there is something to swap it for.
    @ViewBuilder
    private func exerciseActions(_ exercise: StrengthExercise) -> some View {
        let hasGuide = StrengthLibrary.cues(forExerciseNamed: exercise.name) != nil
        let canSwap = currentSetIndex == 0 && !swapOptions.isEmpty
        if hasGuide || canSwap {
            HStack(spacing: 10) {
                if hasGuide {
                    Button("How to") { guideExercise = exercise }
                        .buttonStyle(.strideButton(.quiet, compact: true, fullWidth: false))
                        .accessibilityHint("Shows how to do \(exercise.name)")
                }
                if canSwap {
                    Button("Swap") { showSwapOptions = true }
                        .buttonStyle(.strideButton(.quiet, compact: true, fullWidth: false))
                        .accessibilityHint("Replaces \(exercise.name) for this session only")
                }
            }
        }
    }

    /// What was done last time and why the suggested load is what it is. Nothing the
    /// first time an exercise comes up.
    @ViewBuilder
    private var lastTimeLine: some View {
        if let lastPerformance {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    StrideIcon(name: .history, size: 13, color: .secondary, strokeWeight: 2)
                    Text("Last time: \(StrengthProgression.summary(of: lastPerformance, unit: unit)), \(lastPerformance.date.formatted(.relative(presentation: .named)))")
                        .font(.dsFootnote)
                        .foregroundStyle(.secondary)
                }
                if let suggestion, let explanation = StrengthProgression.explanation(of: suggestion, unit: unit) {
                    Text(verbatim: explanation)
                        .font(.dsFootnote.weight(.semibold))
                        .foregroundStyle(.brandText)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Log Set Card

    private func logSetCard(exercise: StrengthExercise) -> some View {
        VStack(spacing: 16) {
            Text("LOG SET \(currentSetIndex + 1)")
                .strideEyebrow()
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

                    if takesLoad(exercise) {
                        HStack {
                            Text("Weight")
                                .font(.dsSubhead)
                                .foregroundStyle(.secondary)
                            Spacer()
                            StrengthWeightField(
                                value: $weightInput,
                                step: StrengthProgression.displayValue(
                                    StrengthProgression.stepKilograms(for: StrengthProgression.equipment(for: exercise), unit: unit),
                                    unit: unit
                                ),
                                unitLabel: unit == .metric ? "kg" : "lb"
                            )
                        }
                    } else {
                        HStack {
                            Text("Band or variation")
                                .font(.dsSubhead)
                                .foregroundStyle(.secondary)
                            Spacer()
                            TextField(exercise.targetWeight ?? "Optional", text: $noteInput)
                                .font(.dsSubhead)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 140)
                        }
                    }
                }
            }

            Button {
                logSet(exercise: exercise)
            } label: {
                Text(exercise.durationSeconds != nil ? "Done — next set" : "Log set")
            }
            .buttonStyle(.strideButton())

            Button {
                skipSet()
            } label: {
                Text("Skip")
            }
            .buttonStyle(.strideButton(.quiet, compact: true))
        }
        .padding(AppSpacing.lg)
        .strideCard(cornerRadius: AppRadius.lg)
    }

    // MARK: - Rest Timer Card

    private var restTimerCard: some View {
        VStack(spacing: 16) {
            Text("REST")
                .strideEyebrow()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                Circle()
                    .stroke(Color.surfaceTertiary, lineWidth: 6)
                    .frame(width: 100, height: 100)
                Circle()
                    .trim(from: 0, to: restProgress)
                    .stroke(.route, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 100, height: 100)
                    .animation(AppAnimation.countdown, value: restTimer.remainingSeconds)
                VStack(spacing: 2) {
                    Text("\(restTimer.remainingSeconds)")
                        .font(.dsTitle1.monospacedDigit())
                    Text("sec")
                        .font(.dsCaption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button {
                    adjustRest(by: -StrengthProgression.restAdjustSeconds)
                } label: {
                    Text("−\(StrengthProgression.restAdjustSeconds)s")
                }
                .buttonStyle(.strideButton(.quiet, compact: true))
                .accessibilityLabel("Take \(StrengthProgression.restAdjustSeconds) seconds off the rest")

                Button {
                    adjustRest(by: StrengthProgression.restAdjustSeconds)
                } label: {
                    Text("+\(StrengthProgression.restAdjustSeconds)s")
                }
                .buttonStyle(.strideButton(.quiet, compact: true))
                .accessibilityLabel("Add \(StrengthProgression.restAdjustSeconds) seconds to the rest")
            }

            Button {
                endRestTimer()
            } label: {
                Text("Skip rest")
            }
            .buttonStyle(.strideButton(.secondary))
        }
        .padding(AppSpacing.lg)
        .strideCard(cornerRadius: AppRadius.lg)
    }

    private var restProgress: Double { restTimer.progress }

    // MARK: - Completed Sets History

    @ViewBuilder
    private var completedSetsHistory: some View {
        let setsForCurrentExercise = completedSets
            .filter { $0.exerciseIndex == currentExerciseIndex && !$0.skipped }
        if !setsForCurrentExercise.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("COMPLETED SETS")
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
                ForEach(Array(setsForCurrentExercise.enumerated()), id: \.offset) { _, set in
                    HStack {
                        // Stride's check on a filled disc, as a done workout shows it.
                        ZStack {
                            Circle().fill(Color.brand).frame(width: 18, height: 18)
                            StrideIcon(name: .check, size: 9, color: .onFill, strokeWeight: 3)
                        }
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
                .symbolEffect(.bounce, options: .nonRepeating, isActive: !reduceMotion)
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
            Text("Finish workout")
        }
        // Quiet while "Log set" is on screen, so that stays the one route-gradient
        // primary; once every exercise is done, finishing is the only thing left to do.
        .buttonStyle(.strideButton(currentExercise == nil && hasLoggedWork ? .primary : .quiet))
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
        let sessions = recentSessions.map { $0.sessionLog(unit: unit) }
        let last = StrengthProgression.lastPerformance(of: exercise.name, in: sessions, before: startTime)
        let next = StrengthProgression.suggestion(for: exercise, last: last, unit: unit)
        lastPerformance = last
        suggestion = next
        repInput = exercise.reps > 0 ? exercise.reps : 10
        // The suggestion when there is one; else last time's top load, so the field starts
        // somewhere real; else empty for the lifter to fill in.
        weightInput = (next.weightKilograms ?? last?.topWeightKilograms)
            .map { StrengthProgression.displayValue($0, unit: unit) }
        noteInput = ""
        restSeconds = StrengthProgression.restSeconds(for: exercise)
    }

    private func swap(to option: StrengthExercise) {
        swaps[currentExerciseIndex] = option
        setupForCurrentExercise()
        saveCheckpoint()
    }

    /// Puts the edited exercises in place of the session's, before anything is logged.
    /// A scheduled session keeps the edit (it is that day's session, and leaving and
    /// coming back should show it); an unplanned one holds it like a restored plan.
    private func applyEdit(_ edited: [StrengthExercise]) {
        guard !hasLoggedWork, let current = plan, !edited.isEmpty else { return }
        var next = current
        next.exercises = edited
        next.estimatedDurationMinutes = StrengthLibrary.estimatedMinutes(of: edited)
        if let scheduledWorkout {
            scheduledWorkout.strengthPlan = next
            context.saveOrLog("the edited strength session")
        } else {
            restoredPlan = next
        }
        // The edit already has today's swaps in it.
        swaps = [:]
        currentExerciseIndex = 0
        currentSetIndex = 0
        setupForCurrentExercise()
    }

    /// Swaps `exercise` for `standIn` today and in every session from now on. The sessions
    /// still ahead are rebuilt with it; the one on screen keeps its plan.
    private func alwaysSwap(_ exercise: StrengthExercise, to standIn: StrengthExercise) {
        var preferences = StrengthPreferences.load()
        // A swapped-in exercise's rule is keyed by what the plan originally had there.
        let original = plan?.exercises.indices.contains(currentExerciseIndex) == true
            ? plan?.exercises[currentExerciseIndex].name ?? exercise.name
            : exercise.name
        preferences.replace(original, with: standIn.name)
        preferences.save()
        swap(to: standIn)
        refreshSessionsAhead(with: preferences)
    }

    private func refreshSessionsAhead(with preferences: StrengthPreferences) {
        guard let profile = profiles.first, let activePlan = activePlans.first else { return }
        StrengthPlanRefresher.refresh(
            activePlan,
            equipment: profile.selectedEquipment,
            focus: profile.strengthFocus,
            preferences: preferences,
            except: scheduledWorkout?.id
        )
        context.saveOrLog("the strength sessions ahead after a swap or exclusion")
    }

    /// Takes `exercise` out for good: today it becomes the closest alternative, and the
    /// sessions still ahead are rebuilt without it (Fitbod's "Exclude", in Stride's terms).
    private func neverSuggest(_ exercise: StrengthExercise, replacingWith replacement: StrengthExercise) {
        var preferences = StrengthPreferences.load()
        preferences.exclude(exercise.name)
        preferences.save()
        swap(to: replacement)
        refreshSessionsAhead(with: preferences)
    }

    // MARK: - Checkpoint

    /// Picks the session back up where it was if the app closed mid-session: same
    /// scheduled day (or both unplanned), within six hours, with a set done.
    private func restoreIfInterrupted() {
        guard !hasRestored else { return }
        hasRestored = true
        guard let checkpoint = StrengthSessionCheckpoint.load(),
              checkpoint.resumes(scheduledWorkoutID: scheduledWorkout?.id)
        else { return }
        if scheduledWorkout == nil {
            restoredPlan = checkpoint.plan
        }
        swaps = checkpoint.swaps
        completedSets = checkpoint.completedSets
        currentExerciseIndex = checkpoint.currentExerciseIndex
        currentSetIndex = checkpoint.currentSetIndex
        startTime = checkpoint.startTime
    }

    private func saveCheckpoint() {
        guard let plan, hasLoggedWork else { return }
        StrengthSessionCheckpoint(
            scheduledWorkoutID: scheduledWorkout?.id,
            plan: plan,
            swaps: swaps,
            completedSets: completedSets,
            currentExerciseIndex: currentExerciseIndex,
            currentSetIndex: currentSetIndex,
            startTime: startTime,
            savedAt: Date()
        ).save()
    }

    private func takesLoad(_ exercise: StrengthExercise) -> Bool {
        exercise.durationSeconds == nil && StrengthProgression.takesLoad(StrengthProgression.equipment(for: exercise))
    }

    private func logSet(exercise: StrengthExercise) {
        let reps = exercise.durationSeconds != nil ? 1 : repInput
        let kilograms = takesLoad(exercise)
            ? weightInput.flatMap { $0 > 0 ? StrengthProgression.kilograms(fromDisplay: $0, unit: unit) : nil }
            : nil
        let note = noteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        // The load is also written as text: a device still on an older version shows
        // `actualWeight` and nothing else, and would otherwise show the set unweighted.
        let text = kilograms.map { StrengthProgression.weightText($0, unit: unit) } ?? (note.isEmpty ? nil : note)
        let set = CompletedStrengthSet(
            exerciseIndex: currentExerciseIndex,
            setIndex: currentSetIndex,
            completedReps: reps,
            actualWeight: text,
            skipped: false,
            exerciseName: exercise.name,
            weightKilograms: kilograms
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
            skipped: true,
            exerciseName: currentExercise?.name
        )
        completedSets.append(set)
        advanceAfterSet(exercise: currentExercise ?? exercises[0])
    }

    private func advanceAfterSet(exercise: StrengthExercise) {
        defer { saveCheckpoint() }
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
        restTimer = .start(seconds: restSeconds, now: Date())
        restTimerTask = Task { @MainActor in
            // Derive the remaining time from the deadline each tick so a suspended app
            // resumes with the correct countdown (M27) rather than freezing at whatever
            // value it held when it went to the background. Read from state, not
            // captured, so the +/− buttons move it. A tick that reaches 0 ends the rest.
            while restTimer.isResting {
                restTimer.tick(now: Date())
                guard restTimer.isResting else { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
            }
            restTimerTask = nil
        }
    }

    /// Moves the running rest by `seconds`, within ``StrengthProgression/restRange``, and
    /// keeps the change for the rest of this exercise's sets: a lifter who wanted longer
    /// after set one will want it after set two.
    private func adjustRest(by seconds: Int) {
        guard restTimer.adjust(by: seconds, now: Date()) else { return }
        restSeconds = min(StrengthProgression.restRange.upperBound,
                          max(StrengthProgression.restRange.lowerBound, restSeconds + seconds))
        if !restTimer.isResting { endRestTimer() }
    }

    private func endRestTimer() {
        restTimerTask?.cancel()
        restTimerTask = nil
        restTimer.end()
    }

    /// Leave without persisting anything — the scheduled day stays open (H5).
    private func discard() {
        endRestTimer()
        StrengthSessionCheckpoint.clear()
        dismiss()
    }

    private func finishAndSave() {
        endRestTimer()
        StrengthSessionCheckpoint.clear()
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
            container.notificationService.cancelMorningReminder(for: scheduled)
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

// MARK: - StrengthWeightField

/// A load in the runner's unit: a number to type, with − and + that move it one plate
/// step. Empty until there is something to put in it.
private struct StrengthWeightField: View {
    @Binding var value: Double?
    /// One step in the runner's unit (2.5 kg on a bar, 5 lb...).
    let step: Double
    let unitLabel: String

    var body: some View {
        HStack(spacing: 8) {
            Button {
                value = max(0, (value ?? 0) - step)
            } label: {
                Text(verbatim: "−")
                    .font(.dsTitle3)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.strideButton(.quiet, compact: true, fullWidth: false))
            .accessibilityLabel("Lighter")

            HStack(spacing: 3) {
                TextField("0", value: $value, format: .number.precision(.fractionLength(0...1)))
                    .font(.dsTitle3.monospacedDigit())
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 44, maxWidth: 72)
                    .accessibilityLabel("Weight in \(unitLabel)")
                Text(verbatim: unitLabel)
                    .font(.dsFootnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                value = (value ?? 0) + step
            } label: {
                StrideIcon(name: .plus, size: 14, color: .primary, strokeWeight: 2.4)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.strideButton(.quiet, compact: true, fullWidth: false))
            .accessibilityLabel("Heavier")
        }
    }
}

// MARK: - StrengthExerciseGuide

/// How to do one exercise: the muscles it works and three cues, as a sheet over the
/// session so the lifter doesn't lose their place.
private struct StrengthExerciseGuide: View {
    let exercise: StrengthExercise

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    HStack(spacing: 6) {
                        ForEach(exercise.muscleGroups.prefix(3), id: \.self) { group in
                            StrideTag(group, tone: .brand)
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array((StrengthLibrary.cues(forExerciseNamed: exercise.name) ?? []).enumerated()), id: \.offset) { index, cue in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(verbatim: "\(index + 1)")
                                    .font(.dsHeadline.monospacedDigit())
                                    .foregroundStyle(.brandText)
                                    .frame(width: 20, alignment: .leading)
                                Text(verbatim: cue)
                                    .font(.dsBody)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(AppSpacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .strideCard()

                    if let notes = exercise.notes {
                        Text(notes)
                            .font(.dsFootnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(AppSpacing.lg)
            }
            .background(Color.surfacePrimary)
            .navigationTitle(exercise.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .strideSheet()
    }
}

// MARK: - StrengthSwapSheet

/// What the current exercise could become, each for today or for every session, and
/// "Don't suggest again" to take it out for good.
private struct StrengthSwapSheet: View {
    let exercise: StrengthExercise
    let options: [StrengthExercise]
    let onToday: (StrengthExercise) -> Void
    let onEverySession: (StrengthExercise) -> Void
    let onNeverSuggest: (StrengthExercise) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    ForEach(options, id: \.name) { option in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(option.name)
                                .font(.dsHeadline)
                            if !option.muscleGroups.isEmpty {
                                Text(option.muscleGroups.prefix(3).joined(separator: ", "))
                                    .font(.dsFootnote)
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: AppSpacing.sm) {
                                Button("Today") { choose { onToday(option) } }
                                    .buttonStyle(.strideButton(.secondary, compact: true))
                                    .accessibilityLabel("Swap for \(option.name) today")
                                Button("Every session") { choose { onEverySession(option) } }
                                    .buttonStyle(.strideButton(.quiet, compact: true))
                                    .accessibilityLabel("Swap for \(option.name) in every session")
                            }
                        }
                        .padding(AppSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .strideCard(cornerRadius: AppRadius.md)
                    }

                    if let first = options.first {
                        Button(role: .destructive) {
                            choose { onNeverSuggest(first) }
                        } label: {
                            Text("Don't suggest \(exercise.name) again")
                        }
                        .buttonStyle(.strideButton(.destructive))
                    }

                    Text("\"Today\" changes only this session. \"Every session\" and \"Don't suggest again\" also change the sessions ahead, keeping their sets and reps. Settings > Strength training undoes either.")
                        .font(.dsFootnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(AppSpacing.lg)
            }
            .background(Color.surfacePrimary)
            .navigationTitle("Swap \(exercise.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .strideSheet()
    }

    private func choose(_ action: () -> Void) {
        action()
        dismiss()
    }
}

// MARK: - StrengthSessionEditor

/// Today's session before it starts: sets and reps per exercise, reorder, remove, and
/// add from the library with the equipment at hand. Edits stay on a copy until Save.
private struct StrengthSessionEditor: View {
    let equipment: [StrengthEquipment]
    let onSave: ([StrengthExercise]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var exercises: [StrengthExercise]
    @State private var showAdd = false

    init(exercises: [StrengthExercise], equipment: [StrengthEquipment], onSave: @escaping ([StrengthExercise]) -> Void) {
        self.equipment = equipment
        self.onSave = onSave
        _exercises = State(initialValue: exercises)
    }

    private var addable: [StrengthExercise] {
        StrengthLibrary.addable(to: exercises, equipment: equipment, excluding: StrengthPreferences.load().excluded)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($exercises, id: \.name) { $exercise in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(exercise.name)
                                .font(.dsHeadline)
                            Stepper(value: $exercise.sets, in: 1...6) {
                                Text("\(exercise.sets) sets")
                                    .font(.dsBody.monospacedDigit())
                            }
                            .frame(minHeight: 44)
                            if exercise.durationSeconds != nil {
                                Stepper(
                                    value: Binding(
                                        get: { exercise.durationSeconds ?? 30 },
                                        set: { exercise.durationSeconds = $0 }
                                    ),
                                    in: 10...180,
                                    step: 5
                                ) {
                                    Text("\(exercise.durationSeconds ?? 30) s hold")
                                        .font(.dsBody.monospacedDigit())
                                }
                                .frame(minHeight: 44)
                            } else {
                                Stepper(value: $exercise.reps, in: 1...30) {
                                    Text("\(exercise.reps) reps")
                                        .font(.dsBody.monospacedDigit())
                                }
                                .frame(minHeight: 44)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { exercises.remove(atOffsets: $0) }
                    .onMove { exercises.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text("About \(StrengthLibrary.estimatedMinutes(of: exercises)) min. Swipe left to remove an exercise, or touch and hold to drag it. Changes apply to today's session only.")
                }

                Section {
                    Button {
                        showAdd = true
                    } label: {
                        Label("Add exercise", systemImage: "plus")
                    }
                    .disabled(addable.isEmpty)
                }
            }
            .navigationTitle("Edit session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(exercises)
                        dismiss()
                    }
                    .disabled(exercises.isEmpty)
                }
            }
            .sheet(isPresented: $showAdd) {
                NavigationStack {
                    List(addable, id: \.name) { candidate in
                        Button {
                            exercises.append(StrengthLibrary.added(candidate, to: exercises))
                            showAdd = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.name)
                                    .font(.dsBody)
                                    .foregroundStyle(.primary)
                                Text(candidate.muscleGroups.prefix(3).joined(separator: ", "))
                                    .font(.dsFootnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .navigationTitle("Add exercise")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showAdd = false }
                        }
                    }
                }
            }
        }
        .strideSheet()
    }
}
