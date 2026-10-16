import SwiftUI

// MARK: - PregnancyPlanGuidanceCard

/// What a pregnancy plan shows where a race plan shows Smart Adapt.
///
/// The guidance is a pure function of where the pregnancy is
/// (`PregnancyPlanService.guidance(forWeekStarting:dueDate:)`), so nothing here is stored on
/// the plan and nothing goes stale: the card re-derives gestational age from the due date
/// every time it renders, the way the widgets re-resolve "Today" at render time.
struct PregnancyPlanGuidanceCard: View {
    let plan: TrainingPlan

    @State private var showRedFlags = false

    private var guidance: PregnancyPlanService.WeekGuidance? {
        guard let dueDate = plan.dueDate else { return nil }
        let weekStart = (plan.currentWeek?.startDate ?? Date()).startOfWeek
        let lastWeekNumber = (plan.weeks ?? []).map(\.weekNumber).max()
        let isFinalWeek = plan.currentWeek.map { $0.weekNumber == lastWeekNumber } ?? false
        return PregnancyPlanService.guidance(
            forWeekStarting: weekStart,
            dueDate: dueDate,
            isFinalWeek: isFinalWeek
        )
    }

    var body: some View {
        if let guidance {
            VStack(alignment: .leading, spacing: 14) {
                header(guidance)

                Text(guidance.headline)
                    .font(.callout)

                Divider()

                guidanceRow(icon: "figure.walk", text: guidance.terrain)
                guidanceRow(icon: "thermometer.sun", text: guidance.heat)
                guidanceRow(icon: "heart.circle", text: guidance.pelvicFloor)

                if let postpartum = guidance.postpartum {
                    Divider()
                    guidanceRow(icon: "calendar.badge.clock", text: postpartum)
                }

                Button {
                    showRedFlags = true
                } label: {
                    Label("When to stop and call your provider", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.destructive)

                Text(PregnancyRunningPolicy.medicalDisclaimer)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.lg)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(Color.brand.opacity(0.08))
            )
            .sheet(isPresented: $showRedFlags) {
                NavigationStack {
                    PregnancyRedFlagListView()
                }
            }
        }
    }

    private func header(_ guidance: PregnancyPlanService.WeekGuidance) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "heart.text.square")
                .font(.title2)
                .foregroundStyle(.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text(guidance.trimester.localizedName)
                    .font(.dsHeadline.weight(.bold))
                Text("\(guidance.gestationalAge.noteForm) weeks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func guidanceRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(.brand)
                .frame(width: 18)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - PregnancyRedFlagListView

/// The stop-and-call list, reachable from the plan and never abbreviated.
struct PregnancyRedFlagListView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(PregnancyRedFlag.allCases) { flag in
                    Label {
                        Text(flag.localizedText)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.destructive)
                    }
                }
            } footer: {
                Text("Stop exercising immediately and contact your maternity provider if any of these happen.")
            }
            .strideListRow()
        }
        .strideList()
        .navigationTitle("Stop and Call")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
