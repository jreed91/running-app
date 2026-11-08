import SwiftUI
import SwiftData

struct PlanDetailView: View {
    let plan: TrainingPlan

    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteConfirmation = false

    private var planTitle: String { plan.displayTitle }

    // MARK: - Body

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                PlanSummaryCard(plan: plan)

                Text("TRAINING WEEKS")
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach((plan.weeks ?? []).sorted(by: { $0.weekNumber < $1.weekNumber })) { week in
                    WeekCardView(week: week)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(Color.surfacePrimary)
        .navigationTitle("\(planTitle) plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete plan", systemImage: "trash")
                }
            }
        }
        .confirmationDialog(
            "Delete this plan?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete plan", role: .destructive) {
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
                        .strideEyebrow()
                        .foregroundStyle(.secondary)
                    Text(dateRange)
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                PlanStatusBadge(status: summary.status)
            }

            // Adherence
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .lastTextBaseline) {
                    Text("\(Int((summary.adherence * 100).rounded()))%")
                        .font(.dsTitle1.monospacedDigit())
                        .foregroundStyle(.brandText)
                    Text("\(summary.completedCount) of \(summary.scheduledCount) workouts completed")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                StrideProgressBar(value: summary.adherence)
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
                    label: "Avg pace"
                )
                SummaryStat(
                    value: summary.longestRunMeters > 0
                        ? summary.longestRunMeters.distanceString(unit: appSettings.unitPreference)
                        : "--",
                    label: "Longest run"
                )
                SummaryStat(
                    value: "\(summary.weeksCompleted)/\(summary.totalWeeks)",
                    label: "Weeks done"
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
        .strideCard()
    }
}

// MARK: - SummaryStat

private struct SummaryStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.bodyStrong.monospacedDigit())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.dsCaption)
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
                StrideIcon(name: stat.type.strideIcon, size: 16,
                           color: stat.type.color, strokeWeight: 1.8)
            }

            Text(stat.type.localizedName)
                .font(.bodyRegular)

            Spacer()

            Text("\(stat.completed)/\(stat.scheduled)")
                .font(.dsFootnote.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)

            StrideProgressBar(value: fraction, tint: stat.type.color, height: 6)
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
                withAnimation(AppAnimation.quick) { isExpanded.toggle() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Week \(week.weekNumber) · \(week.phase.localizedName)")
                            .font(.bodyStrong)
                        Text(week.targetDistanceKm.distanceStringFromKm(unit: appSettings.unitPreference) + " target")
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if week.isCompleted {
                        ZStack {
                            Circle().fill(Color.success).frame(width: 20, height: 20)
                            StrideIcon(name: .check, size: 10, color: .onFill, strokeWeight: 3)
                        }
                    }
                    StrideIcon(name: .chevronDown, size: 12, color: .secondary, strokeWeight: 2)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .animation(AppAnimation.quick, value: isExpanded)
                }
                .padding()
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

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
        .strideCard()
    }
}

// MARK: - ScheduledWorkoutRow

struct ScheduledWorkoutRow: View {
    let workout: ScheduledWorkout
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        HStack(spacing: 12) {
            // Done is a filled dot; not done is a hollow ring, as Home marks a missed day.
            // A surfaceTertiary fill all but vanished on the card, and the ring is a shape
            // change, so it reads with Differentiate Without Color too.
            Group {
                if workout.isCompleted {
                    Circle().fill(Color.success)
                } else {
                    Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
                }
            }
            .frame(width: 10, height: 10)
            .padding(.leading)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(workout.workoutType.localizedName).font(.bodyRegular)
                Text(workout.scheduledDate, style: .date)
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let dist = workout.targetDistanceMeters {
                Text(dist.distanceString(unit: appSettings.unitPreference))
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
            StrideIcon(name: .chevronRight, size: 10, color: Color.secondary.opacity(0.5), strokeWeight: 2)
                .padding(.trailing)
        }
        .padding(.vertical, 10)
    }
}
