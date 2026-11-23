import SwiftUI
import SwiftData

// MARK: - TrainingBreakCard

/// "Not feeling your best?" on the Plan tab, and the state of a break once there is one.
///
/// With no break it is a row that opens ``TrainingBreakSheet`` (only where `offersEntry`).
/// With one it says where the runner is (on a break until a day, or easing back until a
/// day) and offers "I'm back" and "Undo". Draws nothing when there is no break and no
/// entry to offer, so Home can carry it unconditionally.
struct TrainingBreakCard: View {
    let plan: TrainingPlan
    /// Whether to show the "Not feeling your best?" row when there's no break. The Plan tab
    /// offers it; Home only shows a live break.
    var offersEntry = true

    @Environment(AppContainer.self) private var container
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.modelContext) private var context

    /// Read so the card redraws when a break is saved or removed; the value itself is
    /// decoded by ``TrainingBreakStore``.
    @AppStorage(TrainingBreakStore.key) private var storedBreaks: Data?
    @State private var showingSheet = false
    @State private var confirmingUndo = false

    private static let historyRunCount = 50

    private var trainingBreak: TrainingBreak? {
        _ = storedBreaks
        return TrainingBreakStore.current(forPlan: plan.id)
    }

    var body: some View {
        Group {
            if let trainingBreak {
                status(trainingBreak)
            } else if offersEntry {
                Button { showingSheet = true } label: {
                    PlanPageRow(
                        title: "Not feeling your best?",
                        subtitle: "Ill, injured or away? Ease off or pause the plan.",
                        icon: .heart
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("plan.trainingBreakRow")
            }
        }
        .sheet(isPresented: $showingSheet) {
            TrainingBreakSheet(plan: plan)
        }
    }

    // MARK: Status

    private func status(_ trainingBreak: TrainingBreak) -> some View {
        let phase = trainingBreak.phase(on: Date())
        return VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: 12) {
                StrideIcon(name: icon(for: trainingBreak.reason), size: 16, color: .brand, strokeWeight: 2)
                    .frame(width: 32, height: 32)
                    .background(Color.brand.opacity(0.13), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: TrainingBreakText.headline(trainingBreak, phase: phase))
                        .font(.dsSubhead.weight(.semibold))
                    Text(verbatim: TrainingBreakText.detail(trainingBreak, phase: phase))
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if trainingBreak.mode == .pause,
               trainingBreak.length() >= TrainingBreakPolicy.rebuildSuggestedAfterDays,
               phase != .upcoming {
                Text("After this long away, a new plan built from where you are now may suit you better than picking this one back up.")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: AppSpacing.sm) {
                if phase == .onBreak {
                    Button("I'm back") { endEarly(trainingBreak) }
                        .buttonStyle(.strideButton(.secondary, compact: true, fullWidth: false))
                        .accessibilityHint(Text("Puts the rest of the break back and eases you in from today"))
                }
                if phase != .easingBack {
                    Button("Undo") { confirmingUndo = true }
                        .buttonStyle(.strideButton(.quiet, compact: true, fullWidth: false))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        .strideCard()
        .accessibilityIdentifier("plan.trainingBreakCard")
        .confirmationDialog(
            "Undo this break?",
            isPresented: $confirmingUndo,
            titleVisibility: .visible
        ) {
            Button("Put my plan back", role: .destructive) { undo(trainingBreak) }
        } message: {
            Text("Every session the break changed goes back to what it was, unless you've changed it since.")
        }
    }

    private func icon(for reason: TrainingBreak.Reason) -> StrideIconName {
        switch reason {
        case .ill: return .heart
        case .injured: return .pause
        case .travelling: return .location
        }
    }

    // MARK: Actions

    private func undo(_ trainingBreak: TrainingBreak) {
        container.planLifecycle.undoTrainingBreak(
            trainingBreak,
            plan: plan,
            context: context,
            morningRemindersEnabled: appSettings.morningReminderEnabled,
            unitPreference: appSettings.unitPreference
        )
        WidgetRefreshService.refresh(context: context, appSettings: appSettings)
    }

    private func endEarly(_ trainingBreak: TrainingBreak) {
        guard let profile = TrainingBreakSheet.latestProfile(in: context) else { return }
        let history = (try? context.fetch(RunWorkout.runsOnlyDescriptor(fetchLimit: Self.historyRunCount))) ?? []
        container.planLifecycle.endTrainingBreakEarly(
            trainingBreak,
            plan: plan,
            history: history,
            profile: profile,
            context: context,
            morningRemindersEnabled: appSettings.morningReminderEnabled,
            unitPreference: appSettings.unitPreference
        )
        WidgetRefreshService.refresh(context: context, appSettings: appSettings)
    }
}

// MARK: - TrainingBreakSheet

/// Tell the plan you're ill, injured or travelling. Every change the break would make is
/// listed before the runner confirms, from the same ``TrainingBreakPlanner/Proposal``
/// that is then written, so the list can't drift from what happens.
struct TrainingBreakSheet: View {
    let plan: TrainingPlan

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var container
    @Environment(AppSettings.self) private var appSettings

    @State private var reason: TrainingBreak.Reason = .ill
    @State private var mode: TrainingBreak.Mode = .pause
    @State private var startDate = Calendar.current.startOfDay(for: Date())
    @State private var days = 3
    @State private var failure: String?

    private static let historyRunCount = 50

    private var unit: UnitPreference { appSettings.unitPreference }

    private var modes: [TrainingBreak.Mode] {
        plan.prescribesByTime ? [.pause] : [.easeOff, .pause]
    }

    private var result: Result<TrainingBreakPlanner.Proposal, TrainingBreakPlanner.Refusal> {
        TrainingBreakPlanner.propose(
            TrainingBreakRequest(reason: reason, mode: mode, startDate: startDate, days: days),
            in: PlanChangeApplier.snapshot(of: plan)
        )
    }

    private var latestStart: Date {
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: TrainingBreakPolicy.maximumDaysAhead, to: today) ?? today
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    reasonSection
                    modeSection
                    whenSection
                    switch result {
                    case .success(let proposal):
                        changesSection(proposal)
                    case .failure(let refusal):
                        Text(verbatim: TrainingBreakText.refusal(refusal))
                            .font(.bodyRegular)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(AppSpacing.lg)
                            .strideCard()
                    }
                    disclaimer
                }
                .padding(AppSpacing.lg)
            }
            .background(Color.surfacePrimary)
            .navigationTitle("Not feeling your best")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
            .onChange(of: reason) { _, newReason in
                // A holiday is mostly "keep it light"; illness and injury start at a pause.
                if !plan.prescribesByTime { mode = newReason == .travelling ? .easeOff : .pause }
            }
        }
    }

    // MARK: Sections

    private var reasonSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What's going on?")
                .strideEyebrow()
                .foregroundStyle(.secondary)
            StrideSegmentedControl(
                selection: $reason,
                options: TrainingBreak.Reason.allCases,
                title: { Text(verbatim: TrainingBreakText.reasonName($0)) },
                subtitle: { Text(verbatim: TrainingBreakText.reasonHint($0)) }
            )
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What should the plan do?")
                .strideEyebrow()
                .foregroundStyle(.secondary)
            if modes.count > 1 {
                StrideSegmentedControl(
                    selection: $mode,
                    options: modes,
                    title: { Text(verbatim: TrainingBreakText.modeName($0)) },
                    subtitle: { Text(verbatim: TrainingBreakText.modeHint($0, reason: reason)) }
                )
            } else {
                Text("Your plan is set by time and effort, so it pauses: no runs until you're back.")
                    .font(.bodyRegular)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var whenSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("When?")
                .strideEyebrow()
                .foregroundStyle(.secondary)
            VStack(spacing: AppSpacing.sm) {
                DatePicker(
                    "Starting",
                    selection: $startDate,
                    in: Calendar.current.startOfDay(for: Date())...latestStart,
                    displayedComponents: .date
                )
                Divider()
                Stepper(value: $days, in: 1...TrainingBreakPolicy.maximumDays) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("^[\(days) day](inflect: true)")
                            .monospacedDigit()
                        Text(verbatim: TrainingBreakText.through(startDate: startDate, days: days))
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.bodyRegular)
            .padding(AppSpacing.lg)
            .strideCard()
        }
    }

    private func changesSection(_ proposal: TrainingBreakPlanner.Proposal) -> some View {
        let onBreak = proposal.edits.filter { $0.stage == .onBreak }
        let easing = proposal.edits.filter { $0.stage == .easingBack }
        return VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("What changes")
                .strideEyebrow()
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                if !onBreak.isEmpty {
                    Text(verbatim: TrainingBreakText.breakHeading(reason: reason))
                        .font(.bodyStrong)
                    ForEach(onBreak) { editRow($0) }
                }
                if !easing.isEmpty, let end = proposal.rampEndDate {
                    if !onBreak.isEmpty { Divider() }
                    Text(verbatim: TrainingBreakText.easingHeading(until: end))
                        .font(.bodyStrong)
                    ForEach(easing) { editRow($0) }
                }
                if proposal.ramp == nil, !plan.prescribesByTime {
                    Text("Short enough to pick the plan straight back up afterwards.")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                }
                if plan.isStartRunningPlan {
                    Text("When you're back, \u{201C}Repeat this week\u{201D} on the plan is a gentle way in.")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if proposal.suggestsRebuild {
                    Text("After this long away, a new plan built from where you are when you're back may suit you better than picking this one up.")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.lg)
            .strideCard()
        }
    }

    private func editRow(_ edit: TrainingBreakPlanner.Edit) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(edit.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                .font(.dsFootnote.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 84, alignment: .leading)
            Text(verbatim: TrainingBreakText.change(edit, unit: unit))
                .font(.bodyRegular)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var disclaimer: some View {
        Text(verbatim: TrainingBreakText.disclaimer(reason: reason))
            .font(.dsCaption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actionBar: some View {
        VStack(spacing: AppSpacing.xs) {
            if let failure {
                Text(verbatim: failure)
                    .font(.dsCaption)
                    .foregroundStyle(.destructive)
            }
            Button {
                confirm()
            } label: {
                Text(verbatim: TrainingBreakText.confirm(mode: mode, days: days))
            }
            .buttonStyle(.strideButton())
            .disabled((try? result.get()) == nil)
            .accessibilityIdentifier("trainingBreak.confirm")
        }
        .padding(AppSpacing.lg)
        .background(.bar)
    }

    // MARK: Confirm

    static func latestProfile(in context: ModelContext) -> UserProfile? {
        var descriptor = FetchDescriptor<UserProfile>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func confirm() {
        guard case .success(let proposal) = result,
              let profile = Self.latestProfile(in: context) else { return }
        let history = (try? context.fetch(RunWorkout.runsOnlyDescriptor(fetchLimit: Self.historyRunCount))) ?? []
        do {
            try container.planLifecycle.startTrainingBreak(
                proposal,
                plan: plan,
                history: history,
                profile: profile,
                context: context,
                morningRemindersEnabled: appSettings.morningReminderEnabled,
                unitPreference: unit
            )
            WidgetRefreshService.refresh(context: context, appSettings: appSettings)
            dismiss()
        } catch TrainingBreakApplier.ApplyError.alreadyOnBreak {
            failure = String(localized: "Your plan already has a break. Undo it first to set a new one.", comment: "Training break sheet error")
        } catch {
            failure = String(localized: "Your plan changed while this was open. Close and try again.", comment: "Training break sheet error")
        }
    }
}
