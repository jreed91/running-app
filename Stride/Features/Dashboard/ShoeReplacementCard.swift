import SwiftUI
import SwiftData

/// The replace-soon nudge on Home: a pair in rotation is inside the last tenth of its
/// replacement distance, or past it.
///
/// Self-contained — it queries the shoes and the runs that name one, and renders nothing
/// when no pair needs a word — so the dashboard places it with one line. One pair at a
/// time, the most worn first: two cards about shoes is a shoe shop, not a coach.
struct ShoeReplacementCard: View {
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var appSettings

    @Query private var shoes: [Shoe]
    @Query(RunWorkout.shoeMileageDescriptor) private var shoeRuns: [RunWorkout]

    @State private var dismissed = ShoeNudgeDismissals.load()
    /// The pair whose "Retire them" was tapped, held until the runner confirms.
    @State private var retireCandidate: Shoe?

    private var nudge: (shoe: Shoe, totalMeters: Double, wear: ShoeWearPolicy.Wear)? {
        ShoeWearPolicy.shoesToNudge(
            shoes,
            logged: ShoeWearPolicy.loggedMeters(shoeRuns),
            dismissed: dismissed
        ).first
    }

    var body: some View {
        if let nudge {
            card(shoe: nudge.shoe, totalMeters: nudge.totalMeters, wear: nudge.wear)
        }
    }

    private func card(shoe: Shoe, totalMeters: Double, wear: ShoeWearPolicy.Wear) -> some View {
        let unit = appSettings.unitPreference
        let tone: Color = wear == .worn ? .destructive : .warning
        let total = totalMeters.distanceString(unit: unit)
        let limit = shoe.replacementDistanceMeters.distanceString(unit: unit)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(tone.opacity(0.15))
                        .frame(width: 48, height: 48)
                    // No shoe in `StrideIconName`, so the SF Symbol, sized like the other tiles' glyphs.
                    Image(systemName: "shoeprints.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                        .foregroundStyle(tone)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Group {
                        if wear == .worn {
                            Text("Time for new shoes")
                        } else {
                            Text("New shoes soon")
                        }
                    }
                    .font(.bodyStrong)
                    Text("\(shoe.name) has covered \(total) of \(limit).")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 8) {
                Button {
                    retireCandidate = shoe
                } label: {
                    Text("Retire them")
                }
                // Secondary, not the route: retiring a pair isn't the screen's "go" action.
                .buttonStyle(.strideButton(.secondary, compact: true))
                // Retiring takes the pair out of rotation with no undo here, so ask first.
                .confirmationDialog(
                    "Retire these shoes?",
                    isPresented: Binding(
                        get: { retireCandidate != nil },
                        set: { if !$0 { retireCandidate = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Retire", role: .destructive) {
                        if let candidate = retireCandidate {
                            ShoeAssignment.retire(candidate)
                            context.saveOrLog("retiring a shoe from the dashboard")
                        }
                        retireCandidate = nil
                    }
                    Button("Cancel", role: .cancel) { retireCandidate = nil }
                }

                Button {
                    ShoeNudgeDismissals.dismiss(shoe.id, at: wear)
                    dismissed = ShoeNudgeDismissals.load()
                } label: {
                    Text("Not yet")
                }
                .buttonStyle(.strideButton(.quiet, compact: true))
            }
        }
        .padding(AppSpacing.lg)
        .strideCard()
    }
}
