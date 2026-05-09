import SwiftUI
import SwiftData

struct TrainingPlanListView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.appContainer) private var container

    @Query(sort: \TrainingPlan.createdAt, order: .reverse)
    private var plans: [TrainingPlan]

    @Query private var profiles: [UserProfile]

    @State private var showNewPlanSheet = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(plans) { plan in
                    NavigationLink {
                        PlanDetailView(plan: plan)
                    } label: {
                        PlanRowView(plan: plan)
                    }
                }
                .onDelete(perform: deletePlans)
            }
            .navigationTitle("Training Plans")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showNewPlanSheet = true } label: {
                        Label("New Plan", strideIcon: .plus)
                    }
                    .disabled(profiles.isEmpty)
                }
            }
            .sheet(isPresented: $showNewPlanSheet) {
                PlanSetupView()
            }
            .overlay {
                if plans.isEmpty {
                    ContentUnavailableView(
                        label: {
                            Label("No training plan", strideIcon: .calendar)
                        },
                        description: {
                            Text("Tap + to generate a personalised plan.")
                        }
                    )
                }
            }
        }
    }

    private func deletePlans(at offsets: IndexSet) {
        for index in offsets { context.delete(plans[index]) }
        try? context.save()
    }
}

// MARK: - PlanRowView

struct PlanRowView: View {
    let plan: TrainingPlan

    private var planTitle: String {
        if let name = plan.raceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return plan.targetRace.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(planTitle).font(.bodyStrong)
                if plan.isActive {
                    Text("ACTIVE")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.brand.opacity(0.15), in: Capsule())
                        .foregroundStyle(.brand)
                }
            }
            Text("\(plan.totalWeeks) weeks · starts \(plan.startDate.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption)
                .foregroundStyle(.secondary)

            ProgressView(value: plan.progress)
                .tint(.brand)
        }
        .padding(.vertical, 4)
    }
}
