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
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                }
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
                .font(.sectionHeader)
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
            .font(.dsCaption.weight(.semibold).monospaced())
            .padding(.horizontal, 12)
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
            // Zone-color hero band
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(workout.workoutType.color.opacity(0.22))
                        .frame(width: 52, height: 52)
                    StrideIcon(name: workout.workoutType.strideIcon, size: 28,
                               color: workout.workoutType.color, strokeWeight: 2.0)
                }
                .frame(width: 52, height: 52)

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
                                StrideIcon(name: .check, size: 11, color: .white, strokeWeight: 3)
                            }
                        }
                    }
                    Text(workout.scheduledDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Indoor / outdoor toggle
            if !workout.isCompleted && workout.workoutType != .strength {
                locationPicker
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .background(
            LinearGradient(
                colors: [workout.workoutType.color.opacity(0.12), workout.workoutType.color.opacity(0.03)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(workout.workoutType.color.opacity(0.18), lineWidth: 0.5)
        )
    }

    private var locationPicker: some View {
        HStack(spacing: 0) {
            ForEach(WorkoutLocation.allCases, id: \.self) { location in
                Button {
                    guard workout.workoutLocation != location else { return }
                    Task { await changeLocation(to: location) }
                } label: {
                    HStack(spacing: 6) {
                        if isSyncingLocation && workout.workoutLocation == location {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: location.systemImage)
                                .font(.dsCaption.weight(.semibold))
                        }
                        Text(location.localizedName)
                            .font(.dsFootnote.weight(.semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        workout.workoutLocation == location
                            ? workout.workoutType.color.opacity(0.18)
                            : Color.clear
                    )
                    .foregroundStyle(
                        workout.workoutLocation == location
                            ? workout.workoutType.color
                            : Color.secondary
                    )
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.18), value: workout.workoutLocation)

                if location != WorkoutLocation.allCases.last {
                    Divider().frame(height: 24)
                }
            }
        }
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(workout.workoutType.color.opacity(0.15), lineWidth: 0.5)
        )
    }

    private func paceSection(range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TARGET PACE").font(.sectionHeader).foregroundStyle(.secondary)
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
            Text("INTERVALS").font(.sectionHeader).foregroundStyle(.secondary)
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
                .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func distanceSection(dist: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DISTANCE").font(.sectionHeader).foregroundStyle(.secondary)
            Text(dist.distanceString(unit: appSettings.unitPreference)).font(.metricSmall)
        }
    }

    private func notesSection(notes: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOTES").font(.sectionHeader).foregroundStyle(.secondary)
            Text(notes)
                .font(.bodyRegular)
                .padding()
                .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Strength section

    private func strengthSection(plan: StrengthWorkoutPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("EXERCISES").font(.sectionHeader).foregroundStyle(.secondary)
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
                    .font(.dsFootnote.weight(.medium).monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(exercise.muscleGroups.prefix(3), id: \.self) { group in
                    Text(group)
                        .font(.dsCaption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.brand.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.brand)
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
        .padding(12)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 18)
        }
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [Color.brand.opacity(0.14), Color.success.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.brand.opacity(0.22), lineWidth: 0.75)
        )
        .clipped()
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
        GeometryReader { geo in
            ForEach(ConfettiParticle.samples) { particle in
                RoundedRectangle(cornerRadius: 2)
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
        switch colorIndex % 5 {
        case 0: return .brand
        case 1: return .success
        case 2: return .zoneTempo
        case 3: return .zoneInterval
        default: return .zoneEasy
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
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let pace = segment.targetPaceSecondsPerKm {
            Text("@ \(pace.paceString(unit: appSettings.unitPreference))")
                .font(.caption)
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
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.12))
                    .frame(width: 34, height: 34)
                Text("\(workoutSet.repetitions)×")
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(workoutSet.label).font(.bodyStrong)
                workDetailText
            }
            Spacer()
        }
        .padding()
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
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
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let recDur = rec.durationSeconds, recDur > 0 {
            Text(String(format: "%.0f s recovery jog", recDur))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
