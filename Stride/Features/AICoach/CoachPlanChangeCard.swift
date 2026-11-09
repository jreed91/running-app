import SwiftUI
import SwiftData

/// The card under a coach reply that proposed a plan change: what would change, and the
/// one button that changes it.
///
/// The coach only proposes (`ProposePlanChangeTool`); this is where the runner says yes.
/// The session is built and saved by `PlanChangeApplier`, then brought to the copies
/// outside the store the way the run page's "Update next session" does: the widgets, the
/// morning reminders and the Watch.
struct CoachPlanChangeCard: View {
    let change: PlanChangePlanner.Change

    @Environment(AppSettings.self) private var appSettings
    @Environment(AppContainer.self) private var container
    @Environment(\.modelContext) private var modelContext

    private enum Phase: Equatable {
        case ready
        case applying
        case applied
        case failed(String)
    }

    @State private var phase: Phase = .ready

    /// The same history the run page's coach update reads, for today's paces.
    private static let historyRunCount = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.dsSubhead.weight(.semibold))
                    .foregroundStyle(.brand)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.dsSubhead.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.dsFootnote)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            switch phase {
            case .ready, .applying:
                Button {
                    Task { await apply() }
                } label: {
                    if phase == .applying {
                        ProgressView()
                    } else {
                        Text(buttonTitle)
                    }
                }
                .buttonStyle(.strideButton(.primary, compact: true, fullWidth: false))
                .disabled(phase == .applying)
            case .applied:
                Label("Your plan is updated", systemImage: "checkmark.circle.fill")
                    .font(.dsFootnote.weight(.semibold))
                    .foregroundStyle(Color.success)
            case .failed(let message):
                Text(message)
                    .font(.dsFootnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.surfacePrimary, in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).strokeBorder(.cardStroke, lineWidth: 1))
    }

    // MARK: Copy

    private var dayText: String {
        change.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private var symbol: String {
        switch change {
        case .add: return "calendar.badge.plus"
        case .changeType: return "arrow.triangle.2.circlepath"
        case .makeRest: return "moon.zzz"
        }
    }

    private var title: String {
        switch change {
        case let .add(_, type, _, _):
            return String(localized: "Add \(type.localizedName) on \(dayText)", comment: "Coach plan change card: the run type and the day")
        case let .changeType(_, _, from, to, _) where from == to:
            return String(localized: "Change \(dayText)'s \(from.localizedName)", comment: "Coach plan change card: the day and the run type whose distance changes")
        case let .changeType(_, _, from, to, _):
            return String(localized: "\(dayText): \(from.localizedName) to \(to.localizedName)", comment: "Coach plan change card: the day, the old run type and the new one")
        case let .makeRest(_, _, type):
            return String(localized: "Rest on \(dayText) instead of \(type.localizedName)", comment: "Coach plan change card: the day and the run type it replaces")
        }
    }

    private var detail: String {
        let unit = appSettings.unitPreference
        switch change {
        case let .add(_, type, distance, _), let .changeType(_, _, _, type, distance):
            if type == .interval {
                return String(localized: "Reps and paces come from your plan.", comment: "Coach plan change card detail for an interval session")
            }
            guard let distance else {
                return String(localized: "Paces come from your plan.", comment: "Coach plan change card detail with no distance")
            }
            let formatted = distance.distanceString(unit: unit)
            return String(localized: "\(formatted), paces from your plan.", comment: "Coach plan change card detail: the run's distance")
        case .makeRest:
            return String(localized: "The run comes off your plan and your Watch.", comment: "Coach plan change card detail for a rest day")
        }
    }

    private var buttonTitle: String {
        switch change {
        case .add: return String(localized: "Add to plan", comment: "Coach plan change card button")
        case .changeType: return String(localized: "Update plan", comment: "Coach plan change card button")
        case .makeRest: return String(localized: "Make it a rest day", comment: "Coach plan change card button")
        }
    }

    // MARK: Apply

    @MainActor
    private func apply() async {
        guard phase == .ready else { return }
        phase = .applying

        var planFetch = FetchDescriptor<TrainingPlan>(
            predicate: #Predicate { $0.isActive },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        planFetch.fetchLimit = 1
        var profileFetch = FetchDescriptor<UserProfile>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        profileFetch.fetchLimit = 1

        guard let plan = (try? modelContext.fetch(planFetch))?.first,
              let profile = (try? modelContext.fetch(profileFetch))?.first else {
            phase = .failed(String(localized: "There's no active plan to change.", comment: "Coach plan change card error"))
            return
        }
        let history = (try? modelContext.fetch(RunWorkout.runsOnlyDescriptor(fetchLimit: Self.historyRunCount))) ?? []

        let session: ScheduledWorkout
        do {
            session = try PlanChangeApplier.apply(
                change,
                to: plan,
                context: modelContext,
                history: history,
                profile: profile,
                unitPreference: appSettings.unitPreference
            )
        } catch {
            phase = .failed(String(
                localized: "Your plan changed since the coach suggested this. Ask again and it will look at the plan as it is now.",
                comment: "Coach plan change card error when the plan moved before the runner confirmed"
            ))
            return
        }

        // Saved, so Plan and Home already show it. Say so before the Watch catches up.
        phase = .applied

        WidgetRefreshService.refresh(context: modelContext, appSettings: appSettings)
        if appSettings.morningReminderEnabled {
            // The whole set, not one reminder: a run turned into a rest day has to lose
            // the reminder it had, and a single re-schedule never removes one.
            await container.notificationService.scheduleMorningReminders(for: plan)
        }
        // Re-files this one session with the Watch, or takes it off for a rest day.
        try? await container.healthKitRepository.syncWorkoutPlan(
            for: session,
            unitPreference: appSettings.unitPreference
        )
        modelContext.saveOrLog("the coach plan change's Watch workout id")
    }
}
