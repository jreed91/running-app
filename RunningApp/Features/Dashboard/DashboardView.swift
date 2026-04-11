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

    @Environment(AppSettings.self) private var appSettings
    @State private var showActiveRun = false
    @State private var selectedDate = Date()

    private var activePlan: TrainingPlan? { activePlans.first }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WeekCalendarView(activePlan: activePlan, selectedDate: $selectedDate)
                    .background(.surfaceSecondary)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        weekSummaryCard
                        selectedDaySection
                        startRunButton
                    }
                    .padding()
                }
            }
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.inline)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
    }

    private var selectedDaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(selectedDayLabel)
                .font(.sectionHeader)
                .foregroundStyle(.secondary)

            if let workout = workoutForSelectedDate {
                NavigationLink {
                    WorkoutDetailView(workout: workout)
                } label: {
                    WorkoutCardView(workout: workout)
                }
                .buttonStyle(.plain)

                if Calendar.current.isDateInToday(selectedDate) && !workout.isCompleted {
                    Button {
                        showActiveRun = true
                    } label: {
                        Label("Start This Workout", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "moon.stars")
                        .foregroundStyle(.secondary)
                    Text("Rest day – recovery is part of training.")
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var startRunButton: some View {
        Button {
            showActiveRun = true
        } label: {
            Label("Start a Free Run", systemImage: "figure.run")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.metricSmall)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Computed

    private var selectedDayLabel: String {
        if Calendar.current.isDateInToday(selectedDate) { return "TODAY" }
        if Calendar.current.isDateInTomorrow(selectedDate) { return "TOMORROW" }
        return selectedDate
            .formatted(.dateTime.weekday(.wide).month().day())
            .uppercased()
    }

    private var workoutForSelectedDate: ScheduledWorkout? {
        guard let plan = activePlan else { return nil }
        for week in plan.weeks {
            for w in week.workouts
            where Calendar.current.isDate(w.scheduledDate, inSameDayAs: selectedDate) {
                return w.workoutType == .rest ? nil : w
            }
        }
        return nil
    }

    private var weekDistanceString: String {
        let monday = Date().startOfWeek
        let total = recentWorkouts
            .filter { $0.date >= monday }
            .reduce(0) { $0 + $1.distanceMeters }
        return total.distanceString(unit: appSettings.unitPreference)
    }

    private var weekRunCountString: String {
        let monday = Date().startOfWeek
        let count = recentWorkouts.filter { $0.date >= monday }.count
        return "\(count)"
    }
}
