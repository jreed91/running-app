import SwiftUI
import SwiftData

struct DashboardView: View {
    @Query(
        filter: #Predicate<TrainingPlan> { $0.isActive },
        sort: \TrainingPlan.createdAt, order: .reverse
    )
    private var activePlans: [TrainingPlan]

    @Query(sort: \RunWorkout.date, order: .reverse)
    private var recentWorkouts: [RunWorkout]

    @State private var showActiveRun = false

    private var activePlan: TrainingPlan? { activePlans.first }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    weekSummaryCard
                    upcomingWorkoutCard
                    startRunButton
                }
                .padding()
            }
            .navigationTitle("Today")
            .fullScreenCover(isPresented: $showActiveRun) {
                ActiveRunView()
            }
        }
    }

    // MARK: Subviews

    private var weekSummaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("THIS WEEK")
                .font(.sectionHeader)
                .foregroundStyle(.secondary)
            HStack(spacing: 24) {
                statItem(value: weekDistanceString, label: "Distance")
                statItem(value: weekRunCountString, label: "Runs")
                if let plan = activePlan, let week = plan.currentWeek {
                    statItem(
                        value: String(format: "%.0f%%", week.completedDistanceKm / week.targetDistanceKm * 100),
                        label: "Plan"
                    )
                }
            }
        }
        .padding()
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
    }

    private var upcomingWorkoutCard: some View {
        Group {
            if let nextWorkout = nextScheduledWorkout {
                NavigationLink {
                    WorkoutDetailView(workout: nextWorkout)
                } label: {
                    WorkoutCardView(workout: nextWorkout)
                }
                .buttonStyle(.plain)
            } else {
                Text("No workouts scheduled today.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var startRunButton: some View {
        Button {
            showActiveRun = true
        } label: {
            Label("Start a Run", systemImage: "figure.run")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.metricSmall)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Computed

    private var weekDistanceString: String {
        let monday = Date().startOfWeek
        let total = recentWorkouts
            .filter { $0.date >= monday }
            .reduce(0) { $0 + $1.distanceMeters }
        return total.distanceKmString
    }

    private var weekRunCountString: String {
        let monday = Date().startOfWeek
        let count = recentWorkouts.filter { $0.date >= monday }.count
        return "\(count)"
    }

    private var nextScheduledWorkout: ScheduledWorkout? {
        activePlan?.currentWeek?.workouts
            .filter { !$0.isCompleted && $0.workoutType != .rest }
            .min(by: { $0.scheduledDate < $1.scheduledDate })
    }
}
