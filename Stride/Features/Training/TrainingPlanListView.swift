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

    @State private var showNewPlanSheet = false

    /// Plans a swipe has asked to delete, held until the runner confirms.
    ///
    /// Deleting a plan from its detail screen has always asked; the swipe here did not,
    /// even though it cascades to every scheduled workout, Watch entry and reminder the
    /// plan owns (§6).
    @State private var pendingDeletion: [TrainingPlan]?

    private var currentPlans: [TrainingPlan] { plans.filter(\.isActive) }
    private var pastPlans: [TrainingPlan] { plans.filter { !$0.isActive } }

    var body: some View {
        List {
            if !currentPlans.isEmpty {
                Section("Current") {
                    planRows(currentPlans)
                }
            }
            if !pastPlans.isEmpty {
                Section("Past Plans") {
                    planRows(pastPlans)
                }
            }
        }
        .navigationTitle("Plan History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showNewPlanSheet = true } label: {
                    Label("New Plan", systemImage: "plus")
                }
                .disabled(profiles.isEmpty)
            }
        }
        .sheet(isPresented: $showNewPlanSheet) {
            PlanSetupView()
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let plans = pendingDeletion { performDeletion(plans) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("This also removes the plan's scheduled workouts, Watch entries and reminders. It can't be undone.")
        }
        .overlay {
            if plans.isEmpty {
                ContentUnavailableView(
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
            let selected: [TrainingPlan] = offsets.compactMap {
                sectionPlans.indices.contains($0) ? sectionPlans[$0] : nil
            }
            guard !selected.isEmpty else { return }
            pendingDeletion = selected
        }
    }

    private var deletionTitle: String {
        let count = pendingDeletion?.count ?? 0
        return count > 1
            ? String(localized: "Delete \(count) plans?", comment: "Swipe-delete confirmation, multiple plans")
            : String(localized: "Delete this plan?", comment: "Swipe-delete confirmation, one plan")
    }

    private func performDeletion(_ toDelete: [TrainingPlan]) {
        Task {
            // `deletePlan` owns the order: the Watch entries and reminders are
            // reachable only through the plan, so they go before the record does (D3).
            for plan in toDelete {
                await container.planLifecycle.deletePlan(plan, context: context)
            }
        }
    }
}

// MARK: - PlanRowView

struct PlanRowView: View {
    let plan: TrainingPlan

    @Environment(AppSettings.self) private var appSettings

    private var summary: PlanSummary { PlanSummaryService.summary(for: plan) }

    private var planTitle: String {
        if let name = plan.raceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return plan.targetRace.localizedName
    }

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
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Text("\(summary.completedCount)/\(summary.scheduledCount) workouts")
                Text("·").foregroundStyle(.tertiary)
                Text(summary.completedDistanceMeters.distanceString(unit: appSettings.unitPreference))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ProgressView(value: summary.adherence)
                .tint(summary.status == .active ? .brand : .success)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - PlanStatusBadge

struct PlanStatusBadge: View {
    let status: PlanStatus

    private var color: Color {
        switch status {
        case .active:   return .brand
        case .finished: return .success
        case .ended:    return .secondary
        }
    }

    var body: some View {
        Text(status.displayName.uppercased())
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
