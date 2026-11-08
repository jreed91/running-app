import SwiftUI

// MARK: - StartRunningGuidanceCard

/// What a Start Running plan shows where a race plan shows Smart Adapt.
///
/// Derived from the plan each time it renders (`StartRunningPlanService.guidance(for:)`),
/// so nothing is stored and nothing goes stale: the stage is read back from this week's
/// sessions. The advice lines are fixed; their reasons are in
/// `docs/START_RUNNING_PROGRAM.md`.
struct StartRunningGuidanceCard: View {
    let plan: TrainingPlan

    private var guidance: StartRunningPlanService.WeekGuidance? {
        StartRunningPlanService.guidance(for: plan)
    }

    var body: some View {
        if let guidance {
            VStack(alignment: .leading, spacing: 14) {
                header(guidance.stage)

                Text(guidance.next)
                    .font(.dsCallout)

                Divider()

                guidanceRow(
                    icon: .walk,
                    text: "Run slowly enough to talk in short sentences. If you can't, slow down or walk sooner."
                )
                guidanceRow(
                    icon: .moon,
                    text: "Leave a day between runs so your legs can recover."
                )
                guidanceRow(
                    icon: .timer,
                    text: "Too hard? Walk more of it. Finishing the time matters more than running all of it."
                )

                Text(
                    """
                    Stop and get checked if you have chest pain, feel faint, or have pain that \
                    gets worse as you run. If you're worried about your health, talk to a doctor \
                    before you start.
                    """
                )
                .font(.dsCaption2)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.lg)
            .strideCard()
            .accessibilityIdentifier("plan.startRunningGuidance")
        }
    }

    private func header(_ stage: StartRunningProgram.Stage) -> some View {
        HStack(spacing: 12) {
            StrideIcon(name: .run, size: 26, color: .brandText, strokeWeight: 2.0)
            VStack(alignment: .leading, spacing: 2) {
                Text("Stage \(stage.number) of \(StartRunningProgram.stageCount)")
                    .font(.dsHeadline.weight(.bold))
                Text(stage.summary)
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func guidanceRow(icon: StrideIconName, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            StrideIcon(name: icon, size: 16, color: .brandText, strokeWeight: 2.0)
                .frame(width: 18)
            Text(text)
                .font(.dsFootnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
