import SwiftUI
import SwiftData

// MARK: - StartRunningGuidanceCard

/// What a Start Running plan shows where a race plan shows Smart Adapt.
///
/// Derived from the plan each time it renders (`StartRunningPlanService.guidance(for:)`),
/// so nothing is stored and nothing goes stale: the stage is read back from this week's
/// sessions. The advice lines are fixed; their reasons are in
/// `docs/START_RUNNING_PROGRAM.md`.
///
/// Two actions: "Repeat this week", for a runner not ready for the next step, and once
/// the program is done, "Start a 5K plan", which opens New Plan set up for a first 5K.
struct StartRunningGuidanceCard: View {
    let plan: TrainingPlan

    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var container
    @Environment(AppSettings.self) private var appSettings
    @Query private var profiles: [UserProfile]

    @State private var confirmsRepeat = false
    @State private var showsFiveKSetup = false
    @State private var repeatError: String?

    private var guidance: StartRunningPlanService.WeekGuidance? {
        StartRunningPlanService.guidance(for: plan)
    }

    private var canRepeatWeek: Bool {
        profiles.first != nil && StartRunningPlanService.canRepeatWeek(in: plan)
    }

    var body: some View {
        if let guidance {
            VStack(alignment: .leading, spacing: 14) {
                if guidance.isFinished {
                    finishedHeader
                } else {
                    header(guidance.stage)
                }

                Text(guidance.next)
                    .font(.dsCallout)

                if guidance.isFinished {
                    Button("Start a 5K plan") { showsFiveKSetup = true }
                        .buttonStyle(.strideButton())
                        .accessibilityIdentifier("plan.startRunning.startFiveK")
                } else if canRepeatWeek {
                    repeatButton(guidance.stage)
                }

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
            .sheet(isPresented: $showsFiveKSetup) {
                NewPlanOnboardingView(startsAfterStartRunning: true)
                    .strideSheet()
            }
            .alert(
                "Couldn't repeat the week",
                isPresented: Binding(
                    get: { repeatError != nil },
                    set: { if !$0 { repeatError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { repeatError = nil }
            } message: {
                Text(repeatError ?? "")
            }
        }
    }

    // MARK: - Repeat this week

    private func repeatButton(_ stage: StartRunningProgram.Stage) -> some View {
        Button("Repeat this week") { confirmsRepeat = true }
            .buttonStyle(.strideButton(.quiet, compact: true, fullWidth: false))
            .accessibilityIdentifier("plan.startRunning.repeatWeek")
            .confirmationDialog(
                "Repeat this week?",
                isPresented: $confirmsRepeat,
                titleVisibility: .visible
            ) {
                Button("Repeat this week") { repeatWeek() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("""
                Next week is \(stage.summary) again, and the rest of the plan moves back a week. \
                Take the step up when this week feels comfortable.
                """)
            }
    }

    private func repeatWeek() {
        guard let profile = profiles.first else { return }
        do {
            try container.planLifecycle.repeatStartRunningWeek(
                plan: plan,
                profile: profile,
                context: context,
                morningRemindersEnabled: appSettings.morningReminderEnabled,
                unitPreference: appSettings.unitPreference
            )
        } catch {
            repeatError = String(
                localized: "Your plan couldn't be saved. Please try again.",
                comment: "Start Running repeat-a-week save failure"
            )
            AppLogger.log("Failed to repeat a Start Running week: \(error)", label: "startRunning", level: .error)
        }
    }

    // MARK: - Headers

    private var finishedHeader: some View {
        HStack(spacing: 12) {
            StrideIcon(name: .trophy, size: 26, color: .brandText, strokeWeight: 2.0)
            VStack(alignment: .leading, spacing: 2) {
                Text("30 minutes without stopping")
                    .font(.dsHeadline.weight(.bold))
                Text("Start Running complete")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
