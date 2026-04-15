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
    @State private var showRescheduleConfirmation = false
    @State private var selectedDays: Set<Int> = []
    @State private var workoutToEdit: ScheduledWorkout? = nil
    @State private var weekToAddWorkout: TrainingWeek? = nil

    // MARK: - Derived state

    /// Day indices (0=Mon … 6=Sun) inferred from uncompleted future workout dates.
    private var currentPlanDayIndices: Set<Int> {
        let cal = Calendar.current
        let now = Date()
        let allWorkouts = (plan.weeks ?? []).flatMap { $0.workouts ?? [] }
        let future = allWorkouts.filter { !$0.isCompleted && $0.workoutType != .rest && $0.scheduledDate > now }
        let weekdays = future.map { cal.component(.weekday, from: $0.scheduledDate) }
        return Set(weekdays.map { ($0 + 5) % 7 }) // Sun=1..Sat=7 → Mon=0..Sun=6
    }

    private var scheduleChanged: Bool {
        !selectedDays.isEmpty && selectedDays != currentPlanDayIndices
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                scheduleSection
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
        .confirmationDialog(
            "Apply new schedule?",
            isPresented: $showRescheduleConfirmation,
            titleVisibility: .visible
        ) {
            Button("Apply to Future Weeks") {
                applyReschedule()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Uncompleted future workouts will be moved to your selected days. Completed workouts are unchanged.")
        }
        .sheet(item: $workoutToEdit) { workout in
            WorkoutEditView(workout: workout, unitPreference: appSettings.unitPreference)
        }
        .sheet(item: $weekToAddWorkout) { week in
            WorkoutEditView(week: week, unitPreference: appSettings.unitPreference)
        }
        .onAppear {
            selectedDays = currentPlanDayIndices
        }
    }

    // MARK: - Schedule section

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Run Days")
                    .font(.bodyStrong)
                Spacer()
                Text("\(selectedDays.count) day\(selectedDays.count == 1 ? "" : "s") / week")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DayOfWeekPicker(selectedDays: $selectedDays)

            if scheduleChanged {
                Button {
                    showRescheduleConfirmation = true
                } label: {
                    Text("Apply to Future Weeks")
                        .font(.bodyStrong)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.brand, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding()
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
        .animation(.easeInOut(duration: 0.2), value: scheduleChanged)
    }

    // MARK: - Helpers

    private func applyReschedule() {
        container.rescheduleWorkouts(
            in: plan,
            newDayIndices: selectedDays.sorted(),
            profile: profile
        )
        try? context.save()
        // Sync selectedDays to reflect the updated plan state
        selectedDays = currentPlanDayIndices
    }

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
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.success)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.trailing)
        }
        .padding(.vertical, 10)
    }
}
