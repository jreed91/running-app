import SwiftUI
import SwiftData

struct WorkoutDetailView: View {
    let workout: ScheduledWorkout

    @Environment(AppContainer.self) private var container
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isSyncingLocation = false

    private var goalRacePlan: TrainingPlan? {
        workout.week?.plan
    }

    private var isCompletedGoalRace: Bool {
        guard workout.workoutType == .race, workout.isCompleted, let plan = goalRacePlan else {
            return false
        }
        let hasRaceName = plan.raceName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let matchesRaceDate = plan.raceDate.map {
            Calendar.current.isDate(workout.scheduledDate, inSameDayAs: $0)
        } ?? false
        return hasRaceName || matchesRaceDate
    }

    /// The playlist shape for this session, or nil when there is nothing to score (N40).
    ///
    /// Nil covers rest days, strength and cross-training sessions, and any run whose length
    /// cannot be estimated — `RunPlaylistPlanner` decides all three, so the card's presence
    /// and its contents can never disagree. A session already behind the runner is excluded
    /// here rather than there: the planner is about what a session *is*, and offering to
    /// build a playlist for a run that has been completed is a question about *when*.
    private var playlistPlan: RunPlaylistPlan? {
        guard !workout.isCompleted else { return nil }
        return RunPlaylistPlanner.plan(for: .init(workout: workout))
    }

    private var goalRaceName: String {
        if let name = goalRacePlan?.raceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return workout.week?.plan?.targetRace.localizedName ?? "Goal Race"
    }

    var body: some View {
        Group {
            if let completed = workout.completedWorkout {
                RunSummaryView(workout: completed)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if isCompletedGoalRace {
                            GoalRaceCelebrationCard(
                                raceName: goalRaceName,
                                raceDate: goalRacePlan?.raceDate ?? workout.scheduledDate,
                                reduceMotion: reduceMotion
                            )
                        }
                        headerSection
                            // The celebration is the hero once the goal race is run.
                            .strideSurface(isHero: !isCompletedGoalRace)
                        if let range = workout.targetPaceRange {
                            paceSection(range: range)
                        }
                        if workout.workoutType == .strength, let plan = workout.strengthPlan {
                            strengthSection(plan: plan)
                        } else if let structure = workout.workoutStructure {
                            structuredWorkoutSection(structure: structure)
                        } else if !workout.intervals.isEmpty {
                            intervalsSection
                        }
                        if let dist = workout.targetDistanceMeters {
                            distanceSection(dist: dist)
                        }
                        if let notes = workout.notes {
                            notesSection(notes: notes)
                        }
                        if let playlistPlan {
                            RunPlaylistCard(workout: workout, plan: playlistPlan)
                        }
                    }
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.vertical, AppSpacing.lg)
                    .frame(maxWidth: .infinity)
                }
                .background(Color.surfacePrimary)
                .navigationTitle(workout.workoutType.localizedName)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    // MARK: - Location toggle

    @MainActor
    private func changeLocation(to location: WorkoutLocation) async {
        guard !workout.isCompleted else { return }
        isSyncingLocation = true
        defer { isSyncingLocation = false }
        workout.workoutLocation = location
        // Clear the stale WorkoutKit plan so the next sync reschedules with the new location.
        workout.healthKitPlanID = nil
        context.saveOrLog("the workout's indoor/outdoor change")
        if let plan = workout.week?.plan {
            try? await container.healthKitRepository.syncWorkoutPlans(for: plan, unitPreference: appSettings.unitPreference)
        }
    }

    // MARK: - Structured workout timeline

    private func structuredWorkoutSection(structure: WorkoutStructure) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WORKOUT STRUCTURE")
                .strideEyebrow()
                .foregroundStyle(.secondary)

            // Summary chips
            HStack(spacing: 12) {
                summaryChip(
                    label: structure.totalEstimatedDistanceMeters.distanceString(unit: appSettings.unitPreference),
                    systemImage: "arrow.right"
                )
                summaryChip(
                    label: structure.totalEstimatedDurationSeconds.durationString,
                    systemImage: "clock"
                )
            }

            // Visual timeline
            VStack(spacing: 0) {
                SegmentRow(segment: structure.warmup, color: .zoneEasy, appSettings: appSettings)

                connectorLine

                ForEach(Array(structure.mainSets.enumerated()), id: \.offset) { index, set in
                    WorkoutSetRow(
                        workoutSet: set,
                        color: setColor(setCount: structure.mainSets.count),
                        appSettings: appSettings
                    )
                    if index < structure.mainSets.count - 1 {
                        connectorLine
                    }
                }

                connectorLine

                SegmentRow(segment: structure.cooldown, color: .zoneEasy, appSettings: appSettings)
            }
        }
    }

    private func summaryChip(label: String, systemImage: String) -> some View {
        Text(label)
            .font(.dsCaption.weight(.semibold).monospacedDigit())
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, 6)
            .background(.surfaceTertiary, in: Capsule())
            .foregroundStyle(.secondary)
    }

    private var connectorLine: some View {
        Rectangle()
            .fill(Color.surfaceTertiary)
            .frame(width: 2, height: 12)
            .padding(.leading, 21)
    }

    private func setColor(setCount: Int) -> Color {
        setCount > 1 ? .zoneInterval : .zoneTempo
    }

    // MARK: - Legacy sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The session's hero. The type keeps its colour in the icon tile only: zone
            // colours are data, not a card's ground.
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(workout.workoutType.color.opacity(0.15))
                        .frame(width: 48, height: 48)
                    StrideIcon(name: workout.workoutType.strideIcon, size: 28,
                               color: workout.workoutType.color, strokeWeight: 2.0)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(workout.workoutType.localizedName)
                            .font(.dsTitle2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        if workout.isCompleted {
                            ZStack {
                                Circle()
                                    .fill(Color.success)
                                    .frame(width: 20, height: 20)
                                StrideIcon(name: .check, size: 11, color: .onFill, strokeWeight: 3)
                            }
                        }
                    }
                    Text(workout.scheduledDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.lg)
            .padding(.bottom, AppSpacing.md)

            // Indoor / outdoor toggle
            if !workout.isCompleted && workout.workoutType != .strength {
                locationPicker
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.bottom, AppSpacing.lg)
            }
        }
    }

    private var locationPicker: some View {
        StrideSegmentedControl(
            selection: Binding(
                get: { workout.workoutLocation },
                set: { location in
                    guard workout.workoutLocation != location else { return }
                    Task { await changeLocation(to: location) }
                }
            ),
            options: WorkoutLocation.allCases
        ) { location in
            Text("\(Image(systemName: location.systemImage)) \(location.localizedName)")
        }
        // One change at a time: each one re-syncs the plan to the watch.
        .disabled(isSyncingLocation)
    }

    private func paceSection(range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TARGET PACE").strideEyebrow().foregroundStyle(.secondary)
            Text(
                "\(range.lowerBound.paceString(unit: appSettings.unitPreference))" +
                " – " +
                "\(range.upperBound.paceString(unit: appSettings.unitPreference))"
            )
            .font(.metricSmall)
        }
    }

    private var intervalsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("INTERVALS").strideEyebrow().foregroundStyle(.secondary)
            ForEach(Array(workout.intervals.enumerated()), id: \.offset) { _, interval in
                HStack {
                    Text("\(interval.repetitions) ×")
                        .font(.bodyStrong)
                    if let dist = interval.distanceMeters {
                        Text(dist.distanceString(unit: appSettings.unitPreference))
                    }
                    Spacer()
                    if let pace = interval.targetPaceSecondsPerKm {
                        Text("@ \(pace.paceString(unit: appSettings.unitPreference))")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .strideCard(cornerRadius: AppRadius.sm)
            }
        }
    }

    private func distanceSection(dist: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DISTANCE").strideEyebrow().foregroundStyle(.secondary)
            Text(dist.distanceString(unit: appSettings.unitPreference)).font(.metricSmall)
        }
    }

    private func notesSection(notes: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOTES").strideEyebrow().foregroundStyle(.secondary)
            Text(notes)
                .font(.bodyRegular)
                .padding()
                .strideCard(cornerRadius: AppRadius.md)
        }
    }

    // MARK: - Strength section

    private func strengthSection(plan: StrengthWorkoutPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("EXERCISES").strideEyebrow().foregroundStyle(.secondary)
            // Summary chip
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.dsCaption2)
                Text("\(plan.estimatedDurationMinutes) min")
                    .font(.dsCaption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.surfaceSecondary, in: Capsule())
            .foregroundStyle(.secondary)

            ForEach(Array(plan.exercises.enumerated()), id: \.offset) { _, exercise in
                ExerciseRow(exercise: exercise)
            }
        }
    }
}

// MARK: - ExerciseRow

struct ExerciseRow: View {
    let exercise: StrengthExercise

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(exercise.name)
                    .font(.dsSubhead.weight(.semibold))
                Spacer()
                Text(repsLabel)
                    .font(.dsFootnote.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(exercise.muscleGroups.prefix(3), id: \.self) { group in
                    Text(group)
                        .font(.dsCaption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.brand.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.brandText)
                }
                if let weight = exercise.targetWeight {
                    Text(weight)
                        .font(.dsCaption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.surfaceSecondary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
            if let notes = exercise.notes {
                Text(notes)
                    .font(.dsCaption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppSpacing.md)
        .strideCard(cornerRadius: AppRadius.md)
    }

    private var repsLabel: String {
        if let duration = exercise.durationSeconds {
            return "\(exercise.sets) × \(duration)s"
        } else if exercise.reps == 0 {
            return "\(exercise.sets) × AMRAP"
        } else {
            return "\(exercise.sets) × \(exercise.reps)"
        }
    }
}

// MARK: - GoalRaceCelebrationCard

private struct GoalRaceCelebrationCard: View {
    let raceName: String
    let raceDate: Date
    let reduceMotion: Bool

    @State private var burst = false

    var body: some View {
        ZStack {
            if reduceMotion {
                StaticConfettiView()
            } else {
                ConfettiBurstView(isExpanded: burst)
            }

            VStack(spacing: 8) {
                StrideIcon(name: .trophy, size: 34, color: .brand, strokeWeight: 2.2)
                Text(raceName)
                    .font(.dsTitle1.weight(.heavy))
                    .multilineTextAlignment(.center)
                Text("Goal race completed")
                    .font(.bodyStrong)
                    .foregroundStyle(.secondary)
                Text(raceDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, AppSpacing.xxl)
            .padding(.horizontal, AppSpacing.lg)
        }
        .frame(maxWidth: .infinity)
        // The confetti stays inside the card's shape.
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        // The screen's one hero in this state; the session header steps down to a card.
        .heroCard()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.9, dampingFraction: 0.82).delay(0.1)) {
                burst = true
            }
        }
    }
}

private struct ConfettiBurstView: View {
    let isExpanded: Bool

    var body: some View {
        // `GeometryReader` stays here and in `StaticConfettiView` deliberately (U7). Each
        // particle is `.position`ed at a fraction of the *container*, and `visualEffect`'s
        // proxy is the modified view's own geometry — a 5pt square — so it cannot express
        // "38% across the card I am sitting in".
        GeometryReader { geo in
            ForEach(ConfettiParticle.samples) { particle in
                RoundedRectangle(cornerRadius: AppRadius.micro)
                    .fill(particle.color)
                    .frame(width: particle.width, height: particle.height)
                    .rotationEffect(.degrees(isExpanded ? particle.rotation : 0))
                    .position(
                        x: geo.size.width * 0.5,
                        y: geo.size.height * 0.36
                    )
                    .offset(
                        x: isExpanded ? particle.xOffset(in: geo.size.width) : 0,
                        y: isExpanded ? particle.yOffset(in: geo.size.height) : 0
                    )
                    .opacity(isExpanded ? 1 : 0)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct StaticConfettiView: View {
    var body: some View {
        GeometryReader { geo in
            ForEach(ConfettiParticle.samples.prefix(18)) { particle in
                Circle()
                    .fill(particle.color.opacity(0.72))
                    .frame(width: 5, height: 5)
                    .position(
                        x: geo.size.width * particle.staticX,
                        y: geo.size.height * particle.staticY
                    )
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ConfettiParticle: Identifiable, Sendable {
    let id: Int
    let width: Double
    let height: Double
    let xFactor: Double
    let yFactor: Double
    let rotation: Double
    let colorIndex: Int
    let staticX: Double
    let staticY: Double

    var color: Color {
        // The brand's two ends and a win. Zone colours are training data, not decoration.
        switch colorIndex % 3 {
        case 0: return .brand
        case 1: return .brandGlow
        default: return .success
        }
    }

    func xOffset(in width: Double) -> Double {
        xFactor * width * 0.42
    }

    func yOffset(in height: Double) -> Double {
        yFactor * height * 0.40
    }

    static let samples: [ConfettiParticle] = (0..<42).map { index in
        let column = Double(index % 7)
        let row = Double(index / 7)
        let direction = column - 3.0
        return ConfettiParticle(
            id: index,
            width: index % 3 == 0 ? 5 : 7,
            height: index % 2 == 0 ? 10 : 6,
            xFactor: direction / 3.0,
            yFactor: 0.15 + row / 7.0,
            rotation: Double((index * 37) % 180) - 90,
            colorIndex: index,
            staticX: 0.12 + (column / 6.0) * 0.76,
            staticY: 0.12 + (row / 5.0) * 0.30
        )
    }
}

// MARK: - SegmentRow

private struct SegmentRow: View {
    let segment: WorkoutSegment
    let color: Color
    let appSettings: AppSettings

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color.opacity(0.15))
                .frame(width: 34, height: 34)
                .overlay(Circle().stroke(color, lineWidth: 2))

            VStack(alignment: .leading, spacing: 2) {
                Text(segment.label)
                    .font(.bodyStrong)
                subtitleText
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var subtitleText: some View {
        if let dist = segment.distanceMeters {
            Text(dist.distanceString(unit: appSettings.unitPreference))
                .font(.dsCaption)
                .foregroundStyle(.secondary)
        }
        if let pace = segment.targetPaceSecondsPerKm {
            Text("@ \(pace.paceString(unit: appSettings.unitPreference))")
                .font(.dsCaption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - WorkoutSetRow

private struct WorkoutSetRow: View {
    let workoutSet: WorkoutSet
    let color: Color
    let appSettings: AppSettings

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.xs)
                    .fill(color.opacity(0.12))
                    .frame(width: 34, height: 34)
                Text("\(workoutSet.repetitions)×")
                    .font(.dsCaption.weight(.bold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(workoutSet.label).font(.bodyStrong)
                workDetailText
            }
            Spacer()
        }
        .padding()
        .strideCard(cornerRadius: AppRadius.md)
    }

    @ViewBuilder
    private var workDetailText: some View {
        let work = workoutSet.workSegment
        let rec  = workoutSet.recoverySegment

        if let dist = work.distanceMeters {
            HStack(spacing: 4) {
                Text(dist.distanceString(unit: appSettings.unitPreference))
                if let pace = work.targetPaceSecondsPerKm {
                    Text("@ \(pace.paceString(unit: appSettings.unitPreference))")
                }
            }
            .font(.dsCaption)
            .foregroundStyle(.secondary)
        }

        if let recDur = rec.durationSeconds, recDur > 0 {
            Text(String(format: "%.0f s recovery jog", recDur))
                .font(.dsCaption)
                .foregroundStyle(.secondary)
        }
    }
}
