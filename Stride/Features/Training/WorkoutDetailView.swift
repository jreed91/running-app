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
    @State private var isSyncingLocation = false

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
            profile: profile,
            unitPreference: appSettings.unitPreference
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

    // MARK: - Location toggle

    @MainActor
    private func changeLocation(to location: WorkoutLocation) async {
        guard !workout.isCompleted else { return }
        isSyncingLocation = true
        defer { isSyncingLocation = false }
        workout.workoutLocation = location
        // Clear the stale WorkoutKit plan so the next sync reschedules with the new location.
        workout.healthKitPlanID = nil
        try? context.save()
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
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
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
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(workout.workoutType.color.opacity(0.22))
                        .frame(width: 56, height: 56)
                    StrideIcon(name: workout.workoutType.strideIcon, size: 28,
                               color: workout.workoutType.color, strokeWeight: 2.0)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(workout.workoutType.displayName)
                            .font(.system(size: 22, weight: .bold))
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
                }
                Spacer()
            }
            .padding([.horizontal, .top], 18)
            .padding(.bottom, 12)

            // Indoor / outdoor toggle
            if !workout.isCompleted {
                locationPicker
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
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
                                .font(.system(size: 12, weight: .semibold))
                        }
                        Text(location.displayName)
                            .font(.system(size: 13, weight: .semibold))
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
