import SwiftUI
import SwiftData

struct PlanDetailView: View {
    let plan: TrainingPlan

    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteConfirmation = false

    private var planTitle: String {
        if let name = plan.raceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return plan.targetRace.localizedName
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                PlanSummaryCard(plan: plan)

                Text("TRAINING WEEKS")
                    .font(.sectionHeader)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

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
                dismiss()
                // `deletePlan` owns the order: the Watch entries and reminders are
                // reachable only through the plan, so they go before the record does (D3).
                Task { await container.planLifecycle.deletePlan(plan, context: context) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove all \(plan.totalWeeks) weeks and scheduled workouts.")
        }
    }
}

// MARK: - PlanSummaryCard

/// Aggregate "how did this plan go" card: adherence, completed distance and
/// time, pace, and a per-workout-type completion breakdown.
struct PlanSummaryCard: View {
    let plan: TrainingPlan

    @Environment(AppSettings.self) private var appSettings

    private var dateRange: String {
        let start = plan.startDate.formatted(.dateTime.month(.abbreviated).day().year())
        let end = plan.endDate.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(start) – \(end)"
    }

    var body: some View {
        let summary = PlanSummaryService.summary(for: plan)

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SUMMARY")
                        .font(.sectionHeader)
                        .foregroundStyle(.secondary)
                    Text(dateRange)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                PlanStatusBadge(status: summary.status)
            }

            // Adherence
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .lastTextBaseline) {
                    Text("\(Int((summary.adherence * 100).rounded()))%")
                        .font(.dsTitle1.monospaced())
                        .foregroundStyle(.brand)
                    Text("\(summary.completedCount) of \(summary.scheduledCount) workouts completed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                ProgressView(value: summary.adherence)
                    .tint(.brand)
            }

            Divider()

            // Totals grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                SummaryStat(
                    value: summary.completedDistanceMeters.distanceString(unit: appSettings.unitPreference),
                    label: "Distance"
                )
                SummaryStat(
                    value: summary.totalDurationSeconds > 0 ? summary.totalDurationSeconds.durationString : "--",
                    label: "Time"
                )
                SummaryStat(
                    value: summary.averagePaceSecondsPerKm.map {
                        $0.paceString(unit: appSettings.unitPreference)
                            .replacingOccurrences(of: " \(appSettings.unitPreference.paceLabel)", with: "")
                    } ?? "--:--",
                    label: "Avg Pace"
                )
                SummaryStat(
                    value: summary.longestRunMeters > 0
                        ? summary.longestRunMeters.distanceString(unit: appSettings.unitPreference)
                        : "--",
                    label: "Longest Run"
                )
                SummaryStat(
                    value: "\(summary.weeksCompleted)/\(summary.totalWeeks)",
                    label: "Weeks Done"
                )
                SummaryStat(
                    value: "\(summary.completedRunCount + summary.completedStrengthCount)",
                    label: "Sessions"
                )
            }

            if !summary.typeBreakdown.isEmpty {
                Divider()

                VStack(spacing: 10) {
                    ForEach(summary.typeBreakdown) { stat in
                        TypeBreakdownRow(stat: stat)
                    }
                }
            }
        }
        .padding()
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}

// MARK: - SummaryStat

private struct SummaryStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.bodyStrong)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - TypeBreakdownRow

private struct TypeBreakdownRow: View {
    let stat: PlanSummary.TypeStat

    private var fraction: Double {
        stat.scheduled > 0 ? Double(stat.completed) / Double(stat.scheduled) : 0
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(stat.type.color.opacity(0.15))
                    .frame(width: 28, height: 28)
                StrideIcon(name: stat.type.strideIcon, size: 13,
                           color: stat.type.color, strokeWeight: 1.8)
            }

            Text(stat.type.localizedName)
                .font(.bodyRegular)

            Spacer()

            Text("\(stat.completed)/\(stat.scheduled)")
                .font(.dsFootnote.weight(.medium).monospaced())
                .foregroundStyle(.secondary)

            ProgressView(value: fraction)
                .tint(stat.type.color)
                .frame(width: 56)
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
                        Text("Week \(week.weekNumber) · \(week.phase.localizedName)")
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
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))
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
                Text(workout.workoutType.localizedName).font(.bodyRegular)
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
