import SwiftUI
import SwiftData

// MARK: - StrengthSettingsView

/// The strength equipment and focus, chosen once in onboarding and changeable here.
///
/// Saving rewrites the exercises on the plan's strength sessions still ahead
/// (``StrengthPlanRefresher``); days, finished sessions and their logged sets stay as
/// they are.
struct StrengthSettingsView: View {

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var profiles: [UserProfile]
    @Query(filter: #Predicate<TrainingPlan> { $0.isActive == true })
    private var activePlans: [TrainingPlan]

    @State private var equipment: Set<StrengthEquipment> = []
    @State private var focus: StrengthFocus = .runningSpecific
    @State private var preferences = StrengthPreferences()
    @State private var savedPreferences = StrengthPreferences()
    @State private var hasLoaded = false

    private var profile: UserProfile? { profiles.first }
    private var activePlan: TrainingPlan? { activePlans.first }

    private var hasChanges: Bool {
        guard let profile else { return false }
        return equipment != Set(profile.selectedEquipment)
            || focus != profile.strengthFocus
            || preferences != savedPreferences
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Equipment")
                        .strideEyebrow()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, AppSpacing.xs)
                    OBEquipmentGrid(selectedEquipment: $equipment)
                    if equipment.isEmpty {
                        Text("Choose at least one. Bodyweight needs nothing but floor space.")
                            .font(.dsFootnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, AppSpacing.xs)
                    }
                }

                OBStrengthFocusPicker(focus: $focus)

                amountCard

                Text(footnote)
                    .font(.dsFootnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, AppSpacing.xs)
            }
            .padding(AppSpacing.lg)
            .strideReadableWidth()
        }
        .background(Color.surfacePrimary)
        .navigationTitle("Strength training")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!hasChanges || equipment.isEmpty)
            }
        }
        .onAppear(perform: load)
    }

    // MARK: - How much

    /// Sessions a week and minutes a session. "Automatic" is the plan's own rule, which is
    /// what every runner had before these existed.
    private var amountCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How much")
                .strideEyebrow()
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)
            VStack(spacing: 0) {
                HStack {
                    Text("Sessions a week")
                    Spacer()
                    Picker("Sessions a week", selection: $preferences.daysPerWeek) {
                        Text("Automatic").tag(Int?.none)
                        ForEach(Array(StrengthPreferences.daysPerWeekRange), id: \.self) { days in
                            Text(days == 0 ? "None" : "\(days)").tag(Int?.some(days))
                        }
                    }
                    .labelsHidden()
                }
                .font(.dsBody)
                .padding(.vertical, AppSpacing.sm)
                Divider()
                HStack {
                    Text("Session length")
                    Spacer()
                    Picker("Session length", selection: $preferences.sessionMinutes) {
                        Text("Full").tag(Int?.none)
                        ForEach(StrengthPreferences.sessionLengthOptions, id: \.self) { minutes in
                            Text("About \(minutes) min").tag(Int?.some(minutes))
                        }
                    }
                    .labelsHidden()
                }
                .font(.dsBody)
                .padding(.vertical, AppSpacing.sm)
            }
            .padding(.horizontal, AppSpacing.md)
            .strideCard(cornerRadius: AppRadius.md)
            Text("Automatic gives two sessions a week in base and build (one with a general strength focus), one in peak, and one or none in a taper. A taper never gets more than one, whatever you choose. Changing the number puts the sessions still ahead back on the plan's own days. A shorter session drops the least important exercises, keeping at least three.")
                .font(.dsFootnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, AppSpacing.xs)
        }
    }

    private var footnote: LocalizedStringKey {
        activePlan == nil
            ? "Used for the strength sessions in your next plan."
            : "Saving updates the strength sessions still ahead in your plan. Finished sessions keep what you lifted."
    }

    private func load() {
        guard !hasLoaded, let profile else { return }
        hasLoaded = true
        equipment = Set(profile.selectedEquipment)
        focus = profile.strengthFocus
        preferences = StrengthPreferences.load()
        savedPreferences = preferences
    }

    private func save() {
        guard let profile, !equipment.isEmpty else { return }
        // A stable order, so the same choice always prioritises the same way.
        let chosen = StrengthEquipment.allCases.filter(equipment.contains)
        profile.selectedEquipment = chosen
        profile.strengthFocus = focus
        profile.updatedAt = Date()
        preferences.save()
        if let activePlan {
            StrengthPlanRefresher.refresh(activePlan, equipment: chosen, focus: focus, minutes: preferences.sessionMinutes)
            // Days move only when the number of sessions changed, so sessions moved by
            // hand stay where they were after an equipment or length change.
            if preferences.daysPerWeek != savedPreferences.daysPerWeek {
                let removed = StrengthPlanRefresher.reschedule(activePlan, profile: profile, preferences: preferences)
                removed.forEach(context.delete)
            }
        }
        savedPreferences = preferences
        context.saveOrLog("the strength equipment and focus")
        dismiss()
    }
}
