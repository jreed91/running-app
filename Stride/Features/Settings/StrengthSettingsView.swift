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
    @State private var hasLoaded = false

    private var profile: UserProfile? { profiles.first }
    private var activePlan: TrainingPlan? { activePlans.first }

    private var hasChanges: Bool {
        guard let profile else { return false }
        return equipment != Set(profile.selectedEquipment) || focus != profile.strengthFocus
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
    }

    private func save() {
        guard let profile, !equipment.isEmpty else { return }
        // A stable order, so the same choice always prioritises the same way.
        let chosen = StrengthEquipment.allCases.filter(equipment.contains)
        profile.selectedEquipment = chosen
        profile.strengthFocus = focus
        profile.updatedAt = Date()
        if let activePlan {
            StrengthPlanRefresher.refresh(activePlan, equipment: chosen, focus: focus)
        }
        context.saveOrLog("the strength equipment and focus")
        dismiss()
    }
}
