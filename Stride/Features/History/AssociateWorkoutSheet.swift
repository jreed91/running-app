import SwiftUI
import SwiftData

struct AssociateWorkoutSheet: View {
    let workout: RunWorkout

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var appSettings

    @Query(sort: \ScheduledWorkout.scheduledDate, order: .reverse)
    private var scheduledWorkouts: [ScheduledWorkout]

    private var unassociated: [ScheduledWorkout] {
        // Only run-type days can be fulfilled by a run — never offer strength,
        // cross-training, or rest days as link targets (see WorkoutType.isRunType).
        scheduledWorkouts
            .filter { $0.completedWorkout == nil && $0.workoutType.isRunType }
            .sorted { abs($0.scheduledDate.timeIntervalSince(workout.date)) < abs($1.scheduledDate.timeIntervalSince(workout.date)) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if unassociated.isEmpty {
                    StrideEmptyState(
                        "No Available Workouts",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("All scheduled workouts are already linked to a completed run.")
                    )
                } else {
                    List(unassociated, id: \.id) { scheduled in
                        Button {
                            associate(scheduled)
                        } label: {
                            ScheduledWorkoutPickerRow(scheduled: scheduled)
                        }
                        .buttonStyle(.plain)
                        .strideListRow()
                    }
                    .strideList()
                }
            }
            .navigationTitle("Link to Planned Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func associate(_ scheduled: ScheduledWorkout) {
        scheduled.completedWorkout = workout
        workout.scheduledWorkout = scheduled
        scheduled.isCompleted = true
        scheduled.linkedRunWorkoutID = workout.id
        workout.linkedScheduledWorkoutID = scheduled.id
        context.saveOrLog("the manual run-to-plan link")
        dismiss()
    }
}

private struct ScheduledWorkoutPickerRow: View {
    let scheduled: ScheduledWorkout
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(scheduled.workoutType.color.opacity(0.15))
                    .frame(width: 44, height: 44)
                StrideIcon(name: scheduled.workoutType.strideIcon, size: 22,
                           color: scheduled.workoutType.color, strokeWeight: 2.0)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(scheduled.workoutType.localizedName)
                    .font(.bodyStrong)
                Text(scheduled.scheduledDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let plan = scheduled.week?.plan {
                    let planTitle: String = {
                        if let name = plan.raceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                            return name
                        }
                        return plan.targetRace.localizedName
                    }()
                    Text(planTitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                if let distance = scheduled.targetDistanceMeters {
                    Text(distance.distanceString(unit: appSettings.unitPreference))
                        .font(.dsSubhead.weight(.semibold).monospacedDigit())
                }
                if let paceRange = scheduled.targetPaceRange {
                    Text(paceRange.lowerBound.paceString(unit: appSettings.unitPreference)
                        .replacingOccurrences(of: " min/km", with: "")
                        .replacingOccurrences(of: " min/mi", with: ""))
                        .font(.dsCaption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
