import SwiftUI
import SwiftData

/// Which shoes a run was run in, as a menu on the run's detail screen.
///
/// Its own view rather than a `RunSummaryView` extension so it can carry its own shoe
/// query, and so a runner with no shoes set up sees nothing here at all rather than an
/// empty picker.
struct RunShoeRow: View {
    let workout: RunWorkout

    @Environment(\.modelContext) private var context
    @Query(sort: \Shoe.createdAt, order: .reverse) private var shoes: [Shoe]

    /// Pairs in rotation, plus this run's own pair if it has since been retired, so the
    /// menu can always show what the run is on.
    private var options: [Shoe] {
        shoes.filter { !$0.isRetired || $0.id == workout.shoeID }
    }

    private var current: Shoe? {
        guard let id = workout.shoeID else { return nil }
        return shoes.first { $0.id == id }
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { workout.shoeID },
            set: { newValue in
                workout.shoeID = newValue
                context.saveOrLog("the shoe on a run")
            }
        )
    }

    var body: some View {
        if !options.isEmpty {
            Menu {
                Picker("Shoes", selection: selection) {
                    Text("None").tag(UUID?.none)
                    ForEach(options) { shoe in
                        Text(shoe.name).tag(Optional(shoe.id))
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "shoeprints.fill")
                        .font(.dsSubhead.weight(.semibold))
                        .foregroundStyle(.brand)
                    Text("Shoes")
                        .font(.dsSubhead.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(current?.name ?? String(localized: "None"))
                        .font(.dsSubhead)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.dsCaption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, AppSpacing.md)
                .strideCard(cornerRadius: AppRadius.md)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shoes")
            .accessibilityValue(current?.name ?? String(localized: "None"))
        }
    }
}
