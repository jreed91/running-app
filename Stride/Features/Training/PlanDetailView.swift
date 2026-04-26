import SwiftUI
import SwiftData

struct PlanDetailView: View {
    let plan: TrainingPlan

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteConfirmation = false

    private var planTitle: String {
        plan.raceName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? plan.raceName!
            : plan.targetRace.displayName
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach((plan.weeks ?? []).sorted(by: { $0.weekNumber < $1.weekNumber })) { week in
                    WeekCardView(week: week)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("\(planTitle) Plan")
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
    }
}

// MARK: - WeekCardView

struct WeekCardView: View {
    let week: TrainingWeek

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
                    Divider().padding(.leading)
                }
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
