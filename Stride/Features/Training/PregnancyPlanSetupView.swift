import SwiftUI
import SwiftData

// MARK: - PregnancyPlanSetupView

/// Sets up a pregnancy running plan.
///
/// The screening section is the reason this is a screen of its own rather than a goal on
/// `PlanSetupView`: a pregnancy plan cannot be generated until the runner has read the
/// contraindication list and confirmed both that none of it applies and that they have
/// discussed running with their own maternity provider. `PregnancyPlanService` enforces the
/// same gate, so a future caller cannot route around this screen.
///
/// Sources for everything shown here: `docs/PREGNANCY_RUNNING_EVIDENCE.md`.
struct PregnancyPlanSetupView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var appSettings

    @Query private var profiles: [UserProfile]

    @State private var dueDate = Date().adding(weeks: 20)
    @State private var startDate = Date().startOfWeek.adding(days: 7)
    @State private var hasConfirmedScreening = false
    @State private var weeklyRunMinutes = 150
    @State private var habituallyVigorous = false
    @State private var selectedDays: Set<Int> = [0, 2, 4, 6]
    @State private var selectedEquipment: Set<StrengthEquipment> = [.bodyweight]
    @State private var strengthFocus: StrengthFocus = .runningSpecific
    @State private var isGenerating = false
    @State private var errorMessage: String?

    private var profile: UserProfile? { profiles.first }

    private var gestationalAgeAtStart: GestationalAge {
        GestationalAge.on(startDate, dueDate: dueDate)
    }

    private var canGenerate: Bool {
        profile != nil
            && hasConfirmedScreening
            && !selectedDays.isEmpty
            && !isGenerating
            && dueDate.startOfDay >= startDate.startOfWeek
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                dueDateSection
                screeningSection
                runningHistorySection
                runDaysSection
                strengthSection
                startDateSection
                redFlagSection
                disclaimerSection
            }
            .navigationTitle("Pregnancy Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isGenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Generate") { generatePlan() }
                            .disabled(!canGenerate)
                    }
                }
            }
            .alert(
                "Couldn't build the plan",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear { loadFromProfile() }
        }
    }

    // MARK: - Sections

    private var dueDateSection: some View {
        Section {
            DatePicker("Estimated due date", selection: $dueDate, displayedComponents: .date)
            LabeledContent("At plan start") {
                Text("\(gestationalAgeAtStart.noteForm) weeks · \(gestationalAgeAtStart.trimester.localizedName)")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Due Date")
        } footer: {
            Text("Your plan runs from the start date through the week you're due. It shortens and eases as you go — it never builds toward a race.")
        }
    }

    private var screeningSection: some View {
        Section {
            NavigationLink {
                PregnancyScreeningDetailView()
            } label: {
                Label("Read the health checklist", systemImage: "list.clipboard")
            }
            Toggle(isOn: $hasConfirmedScreening) {
                Text("None of those apply to me, and I've talked to my maternity provider about running.")
                    .font(.callout)
            }
        } header: {
            Text("Before You Start")
        } footer: {
            Text("Stride won't build a pregnancy plan until this is confirmed. Some conditions mean no more activity than usual daily living; others mean the decision is your provider's, not this app's.")
        }
    }

    private var runningHistorySection: some View {
        Section {
            Stepper(value: $weeklyRunMinutes, in: 0...600, step: 15) {
                LabeledContent("Weekly running") {
                    Text("\(weeklyRunMinutes) min")
                        .foregroundStyle(.secondary)
                }
            }
            Toggle("I regularly ran hard sessions", isOn: $habituallyVigorous)
        } header: {
            Text("Before Pregnancy")
        } footer: {
            Text("Minutes, not distance — the plan tapers from what you were actually doing. If you regularly ran intervals, tempo, or races, you keep one steadier session per week until 28 weeks.")
        }
    }

    private var runDaysSection: some View {
        Section {
            DayOfWeekPicker(selectedDays: $selectedDays)
                .padding(.vertical, AppSpacing.xs)
        } header: {
            HStack {
                Text("Run Days")
                Spacer()
                Text("\(selectedDays.count) day\(selectedDays.count == 1 ? "" : "s") / week")
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
        } footer: {
            if selectedDays.isEmpty {
                Text("Select at least one run day.")
                    .foregroundStyle(.red)
            } else {
                Text("How often you run stays the same all the way through. It's the length of each run that comes down.")
            }
        }
    }

    private var strengthSection: some View {
        Section {
            OBEquipmentGrid(selectedEquipment: $selectedEquipment)
                .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                .listRowBackground(Color.clear)
            OBStrengthFocusPicker(focus: $strengthFocus)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))
                .listRowBackground(Color.clear)
        } header: {
            Text("Strength & Pelvic Floor")
        } footer: {
            Text("Aerobic and resistance training together beat either alone in pregnancy. Every strength session opens with pelvic floor work — do that part daily, not just on strength days. From 16 weeks nothing is scheduled lying on your back.")
        }
    }

    private var startDateSection: some View {
        Section("Start Date") {
            DatePicker("First day", selection: $startDate, displayedComponents: .date)
        }
    }

    private var redFlagSection: some View {
        Section {
            ForEach(PregnancyRedFlag.allCases) { flag in
                Label {
                    Text(flag.localizedText)
                        .font(.callout)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("Stop and Call Your Provider")
        } footer: {
            Text("This list stays on every workout in the plan.")
        }
    }

    private var disclaimerSection: some View {
        Section {
            Text(PregnancyRunningPolicy.medicalDisclaimer)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func loadFromProfile() {
        guard let profile else { return }
        if let existing = profile.dueDate { dueDate = existing }
        if let minutes = profile.prePregnancyWeeklyRunMinutes {
            weeklyRunMinutes = minutes
        } else {
            weeklyRunMinutes = PregnancyRunningPolicy.defaultWeeklyRunMinutes(for: profile.fitnessLevel)
        }
        habituallyVigorous = profile.pregnancyHabituallyVigorous
            ?? (profile.fitnessLevel == .advanced || profile.fitnessLevel == .competitive)
        if !profile.preferredRunDayIndices.isEmpty {
            selectedDays = Set(profile.preferredRunDayIndices)
        }
        if !profile.selectedEquipment.isEmpty {
            selectedEquipment = Set(profile.selectedEquipment)
        }
        strengthFocus = profile.strengthFocus
    }

    // MARK: - Plan generation

    private func generatePlan() {
        guard let profile, hasConfirmedScreening, !selectedDays.isEmpty else { return }
        isGenerating = true

        profile.dueDate = dueDate.startOfDay
        // Written here rather than when the toggle flips: the record we want is "the screen
        // was confirmed for the plan that was built", not "a toggle was once on".
        profile.pregnancyClearedAt = Date()
        profile.prePregnancyWeeklyRunMinutes = weeklyRunMinutes
        profile.pregnancyHabituallyVigorous = habituallyVigorous
        profile.weeklyRunDays = selectedDays.count
        profile.preferredRunDayIndices = selectedDays.sorted()
        profile.selectedEquipment = Array(selectedEquipment)
        profile.strengthFocus = strengthFocus
        profile.updatedAt = Date()

        let plan: TrainingPlan
        do {
            plan = try container.pregnancyPlanService.generatePlan(
                profile: profile,
                startDate: startDate
            )
        } catch {
            // The gate refused. Roll the clearance back so a failed attempt never leaves the
            // profile looking screened.
            profile.pregnancyClearedAt = nil
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? String(localized: "Check your due date and try again.", comment: "Fallback pregnancy plan generation error")
            isGenerating = false
            return
        }

        // Retires the previous plan, saves, and syncs the Watch and the reminders behind
        // the dismissal. Nothing here waits on `WorkoutScheduler`: awaiting a removal pass
        // for the existing plan and then a re-sync of a plan as long as a pregnancy — before
        // clearing `isGenerating` — is what left this screen spinning.
        do {
            try container.planLifecycle.activateNewPlan(
                plan,
                context: context,
                morningRemindersEnabled: appSettings.morningReminderEnabled,
                unitPreference: appSettings.unitPreference
            )
        } catch {
            profile.pregnancyClearedAt = nil
            errorMessage = String(
                localized: "Your plan couldn't be saved. Please try again.",
                comment: "Pregnancy plan save failure"
            )
            AppLogger.log("Failed to save the pregnancy plan: \(error)", label: "pregnancy", level: .error)
            isGenerating = false
            return
        }

        isGenerating = false
        dismiss()
    }
}

// MARK: - PregnancyScreeningDetailView

/// The contraindication list, in full and unsummarised.
///
/// Split into its own screen rather than shortened into a footnote: an abridged screening
/// list reads as complete, which is the failure mode worth avoiding here.
struct PregnancyScreeningDetailView: View {
    var body: some View {
        List {
            Section {
                ForEach(PregnancyContraindication.absolute) { item in
                    Text(item.localizedText)
                }
            } header: {
                Text("Don't Start Without Talking to Your Provider")
            } footer: {
                Text("With any of these, the guidelines advise no more strenuous activity than the usual activities of daily living.")
            }

            Section {
                ForEach(PregnancyContraindication.relative) { item in
                    Text(item.localizedText)
                }
            } header: {
                Text("Your Provider's Call, Not Ours")
            } footer: {
                Text("Activity may still be right for you with any of these — the decision belongs with your maternity provider.")
            }

            Section {
                Text(PregnancyRunningPolicy.medicalDisclaimer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Health Checklist")
        .navigationBarTitleDisplayMode(.inline)
    }
}
