import SwiftUI
import SwiftData

struct WorkoutDetailView: View {
    let workout: ScheduledWorkout

    @Environment(\.appContainer) private var container
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var appSettings

    @Query(sort: \RunWorkout.date, order: .reverse) private var recentWorkouts: [RunWorkout]
    @Query private var profiles: [UserProfile]
    @State private var isAdapting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                if let range = workout.targetPaceRange {
                    paceSection(range: range)
                }
                if let structure = workout.workoutStructure {
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
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(workout.workoutType.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let profile = profiles.first, !workout.isCompleted {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await adaptThisWorkout(profile: profile) }
                    } label: {
                        if isAdapting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Smart Adapt", systemImage: "sparkles")
                        }
                    }
                    .disabled(isAdapting)
                }
            }
        }
    }

    // MARK: - Adaptation

    @MainActor
    private func adaptThisWorkout(profile: UserProfile) async {
        isAdapting = true
        defer { isAdapting = false }
        let adapted = container.adaptedWorkout(
            scheduled: workout,
            history: Array(recentWorkouts.prefix(50)),
            profile: profile
        )
        // Mutate the existing model in-place so SwiftData tracks the change
        workout.workoutStructure     = adapted.workoutStructure
        workout.targetDistanceMeters = adapted.targetDistanceMeters
        workout.targetPaceLowerBound = adapted.targetPaceLowerBound
        workout.targetPaceUpperBound = adapted.targetPaceUpperBound
        workout.notes                = adapted.notes
        if !adapted.intervals.isEmpty {
            workout.intervals = adapted.intervals
        }
        // Clear the old WorkoutKit plan ID so the next sync re-schedules this workout
        // with the updated structure (warmup/work/cooldown goals).
        workout.healthKitPlanID = nil
        try? context.save()
        // Immediately re-sync this workout's plan to WorkoutKit with the new structure.
        if let plan = workout.week?.plan {
            try? await container.healthKitRepository.syncWorkoutPlans(for: plan)
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
        Label(label, systemImage: systemImage)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.surfaceTertiary, in: Capsule())
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
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(workout.workoutType.displayName)
                    .font(.metricSmall)
                Text(workout.scheduledDate, style: .date)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if workout.isCompleted {
                Label("Done", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.success)
            }
        }
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
                    .font(.system(size: 12, weight: .bold, design: .rounded))
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
