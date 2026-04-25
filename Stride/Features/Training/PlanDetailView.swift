import SwiftUI
import SwiftData

struct PlanDetailView: View {
    let plan: TrainingPlan

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appContainer) private var container
    @Environment(AppSettings.self) private var appSettings

    @Query private var profiles: [UserProfile]
    private var profile: UserProfile? { profiles.first }

    @State private var showDeleteConfirmation = false
    @State private var workoutToEdit: ScheduledWorkout? = nil
    @State private var weekToAddWorkout: TrainingWeek? = nil

    // MARK: - Body

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach((plan.weeks ?? []).sorted(by: { $0.weekNumber < $1.weekNumber })) { week in
                    WeekCardView(
                        week: week,
                        onEditWorkout: { workout in workoutToEdit = workout },
                        onDeleteWorkout: { workout in deleteWorkout(workout) },
                        onAddWorkout: { week in weekToAddWorkout = week }
                    )
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("\(plan.targetRace.displayName) Plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete Plan", systemImage: "trash")
                }
            }
        }
        .confirmationDialog(
            "Delete this plan?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Plan", role: .destructive) {
                context.delete(plan)
                try? context.save()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove all \(plan.totalWeeks) weeks and scheduled workouts.")
        }
        .sheet(item: $workoutToEdit) { workout in
            WorkoutEditView(workout: workout, unitPreference: appSettings.unitPreference)
        }
        .sheet(item: $weekToAddWorkout) { week in
            WorkoutEditView(week: week, unitPreference: appSettings.unitPreference)
        }
    }

    // MARK: - Helpers

    private func deleteWorkout(_ workout: ScheduledWorkout) {
        guard !workout.isCompleted else { return }
        context.delete(workout)
        try? context.save()
    }
}

// MARK: - WeekCardView

struct WeekCardView: View {
    let week: TrainingWeek
    var onEditWorkout: (ScheduledWorkout) -> Void
    var onDeleteWorkout: (ScheduledWorkout) -> Void
    var onAddWorkout: (TrainingWeek) -> Void

    @Environment(AppSettings.self) private var appSettings
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Week \(week.weekNumber) · \(week.phase.displayName)")
                            .font(.bodyStrong)
                        Text(week.targetDistanceKm.distanceStringFromKm(unit: appSettings.unitPreference) + " target")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if week.isCompleted {
                        ZStack {
                            Circle().fill(Color.success).frame(width: 20, height: 20)
                            StrideIcon(name: .check, size: 10, color: .white, strokeWeight: 3)
                        }
                    }
                    StrideIcon(name: .chevronDown, size: 12, color: .secondary, strokeWeight: 2)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                }
                .padding()
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                ForEach((week.workouts ?? []).sorted(by: { $0.scheduledDate < $1.scheduledDate })) { workout in
                    NavigationLink {
                        WorkoutDetailView(workout: workout)
                    } label: {
                        ScheduledWorkoutRow(workout: workout)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if !workout.isCompleted {
                            Button {
                                onEditWorkout(workout)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                onDeleteWorkout(workout)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    Divider().padding(.leading)
                }
                Button {
                    onAddWorkout(week)
                } label: {
                    Label("Add Workout", systemImage: "plus")
                        .font(.bodyRegular)
                        .foregroundStyle(.brand)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
        }
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - ScheduledWorkoutRow

struct ScheduledWorkoutRow: View {
    let workout: ScheduledWorkout
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(workout.isCompleted ? Color.success : Color.surfaceTertiary)
                .frame(width: 10)
                .padding(.leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(workout.workoutType.displayName).font(.bodyRegular)
                Text(workout.scheduledDate, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let dist = workout.targetDistanceMeters {
                Text(dist.distanceString(unit: appSettings.unitPreference))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            StrideIcon(name: .chevronRight, size: 10, color: Color.secondary.opacity(0.5), strokeWeight: 2)
                .padding(.trailing)
        }
        .padding(.vertical, 10)
    }
}
