import SwiftUI
import SwiftData

/// Lists every training plan — the active one plus all past plans — with
/// completion stats. Pushed from the Plan tab's history toolbar button.
struct TrainingPlanListView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var container

    @Query(sort: \TrainingPlan.createdAt, order: .reverse)
    private var plans: [TrainingPlan]

    @Query private var profiles: [UserProfile]

    /// The new-plan flow open as a sheet, if any. See `NewPlanFlow`.
    @State private var newPlanFlow: NewPlanFlow?
    /// Plans the runner has swiped away, held until the confirmation is answered (U6).
    @State private var pendingDeletion: [TrainingPlan] = []

    private var currentPlans: [TrainingPlan] { plans.filter(\.isActive) }
    private var pastPlans: [TrainingPlan] { plans.filter { !$0.isActive } }

    var body: some View {
        List {
            if !currentPlans.isEmpty {
                Section("Current") {
                    planRows(currentPlans)
                }
                .strideListRow()
            }
            if !pastPlans.isEmpty {
                Section("Past plans") {
                    planRows(pastPlans)
                }
                .strideListRow()
            }
        }
        .strideList()
        .navigationTitle("Plan history")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // The Plan tab's own "+", so a plan started here is built the same way.
                NewPlanMenu(selection: $newPlanFlow)
                .disabled(profiles.isEmpty)
            }
        }
        .newPlanSheets($newPlanFlow)
        // Deleting a plan from its detail screen asks first; deleting the same plan by
        // swiping here did not, even though the swipe cascades to every scheduled
        // workout, Watch entry and reminder the plan owns (U6).
        .confirmationDialog(
            "Delete this plan?",
            isPresented: Binding(
                get: { !pendingDeletion.isEmpty },
                set: { if !$0 { pendingDeletion = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let plans = pendingDeletion
                pendingDeletion = []
                Task {
                    // `deletePlan` owns the order: the Watch entries and reminders are
                    // reachable only through the plan, so they go before the record does (D3).
                    for plan in plans {
                        await container.planLifecycle.deletePlan(plan, context: context)
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = [] }
        } message: {
            Text("Its scheduled workouts, reminders and Watch entries go with it. Completed runs are kept.")
        }
        .overlay {
            if plans.isEmpty {
                StrideEmptyState(
                    "No training plans yet",
                    systemImage: "calendar.badge.plus",
                    description: Text("Plans you create appear here, along with the workouts you completed in them.")
                )
            }
        }
    }

    private func planRows(_ sectionPlans: [TrainingPlan]) -> some View {
        ForEach(sectionPlans) { plan in
            NavigationLink {
                PlanDetailView(plan: plan)
            } label: {
                PlanRowView(plan: plan)
            }
        }
        .onDelete { offsets in
            pendingDeletion = offsets.map { sectionPlans[$0] }
        }
    }
}

// MARK: - PlanRowView

struct PlanRowView: View {
    let plan: TrainingPlan

    @Environment(AppSettings.self) private var appSettings

    private var summary: PlanSummary { PlanSummaryService.summary(for: plan) }

    private var planTitle: String { plan.displayTitle }

    private var dateRange: String {
        let start = plan.startDate.formatted(.dateTime.month(.abbreviated).day().year())
        let end = plan.endDate.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(start) – \(end)"
    }

    var body: some View {
        let summary = self.summary
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(planTitle).font(.bodyStrong)
                PlanStatusBadge(status: summary.status)
            }

            Text("\(plan.totalWeeks) weeks · \(dateRange)")
                .font(.dsCaption)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Text("\(summary.completedCount)/\(summary.scheduledCount) workouts")
                Text("·").foregroundStyle(.tertiary)
                Text(summary.completedDistanceMeters.distanceString(unit: appSettings.unitPreference))
            }
            .font(.dsCaption)
            .foregroundStyle(.secondary)

            StrideProgressBar(value: summary.adherence, tint: summary.status == .active ? nil : .success)
        }
        .padding(.vertical, AppSpacing.xs)
    }
}

// MARK: - PlanStatusBadge

struct PlanStatusBadge: View {
    let status: PlanStatus

    /// A label, not a control, so the shared tag: the active plan in brand, a finished
    /// one with its status in the glyph, an ended one neutral.
    var body: some View {
        switch status {
        case .active:
            StrideTag(status.displayName, tone: .brand)
        case .finished:
            StrideTag(status.displayName, systemImage: "checkmark.circle.fill", iconTint: .success)
        case .ended:
            StrideTag(status.displayName)
        }
    }
}
