import SwiftUI
import SwiftData

/// The runner's shoes: how far each pair has gone, which one new runs go on, and the
/// pairs already retired. Reached from **Settings → Shoes**.
struct ShoesView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var appSettings

    @Query(sort: \Shoe.createdAt, order: .reverse) private var shoes: [Shoe]
    /// Only the runs that name a shoe — the whole of what mileage is summed from.
    @Query(RunWorkout.shoeMileageDescriptor) private var shoeRuns: [RunWorkout]

    @State private var editing: ShoeEditorView.Target?
    @State private var pendingDeletion: Shoe?

    private var logged: [UUID: Double] { ShoeWearPolicy.loggedMeters(shoeRuns) }
    private var inRotation: [Shoe] { shoes.filter { !$0.isRetired } }
    private var retired: [Shoe] { shoes.filter(\.isRetired) }

    var body: some View {
        List {
            if shoes.isEmpty {
                ContentUnavailableView {
                    Label("No shoes yet", systemImage: "shoeprints.fill")
                } description: {
                    Text("Add the pairs you run in to see how far each has gone and hear when one is nearly worn out.")
                } actions: {
                    Button("Add a pair") { editing = .new }
                }
                .listRowBackground(Color.clear)
            }
            if !inRotation.isEmpty {
                Section("In rotation") {
                    ForEach(inRotation) { shoe in row(shoe) }
                }
            }
            if !retired.isEmpty {
                Section("Retired") {
                    ForEach(retired) { shoe in row(shoe) }
                }
            }
        }
        .navigationTitle("Shoes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = .new
                } label: {
                    Label("Add a pair", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editing) { target in
            ShoeEditorView(target: target, allShoes: shoes)
        }
        .confirmationDialog(
            "Delete \(pendingDeletion?.name ?? "this pair")?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let shoe = pendingDeletion {
                    ShoeAssignment.delete(shoe, in: context)
                    context.saveOrLog("the deletion of a shoe")
                }
                pendingDeletion = nil
            }
        } message: {
            Text("Its runs stay in your history without a shoe. To keep its mileage, retire it instead.")
        }
    }

    private func row(_ shoe: Shoe) -> some View {
        Button {
            editing = .existing(shoe)
        } label: {
            ShoeRow(
                shoe: shoe,
                totalMeters: ShoeWearPolicy.totalMeters(for: shoe, logged: logged),
                unit: appSettings.unitPreference
            )
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { pendingDeletion = shoe }
            if shoe.isRetired {
                Button("Unretire") {
                    shoe.retiredAt = nil
                    context.saveOrLog("unretiring a shoe")
                }
            } else {
                Button("Retire") {
                    ShoeAssignment.retire(shoe)
                    context.saveOrLog("retiring a shoe")
                }
                .tint(.orange)
            }
        }
        .swipeActions(edge: .leading) {
            if !shoe.isDefault, !shoe.isRetired {
                Button("Make default") {
                    ShoeAssignment.makeDefault(shoe, among: shoes)
                    context.saveOrLog("choosing a default shoe")
                }
                .tint(.brand)
            }
        }
    }
}

// MARK: - Row

private struct ShoeRow: View {
    let shoe: Shoe
    let totalMeters: Double
    let unit: UnitPreference

    private var wear: ShoeWearPolicy.Wear {
        ShoeWearPolicy.wear(totalMeters: totalMeters, replacementMeters: shoe.replacementDistanceMeters)
    }

    private var totalText: String { totalMeters.distanceString(unit: unit) }
    private var limitText: String { shoe.replacementDistanceMeters.distanceString(unit: unit) }

    private var progress: Double {
        guard shoe.replacementDistanceMeters > 0 else { return 0 }
        return min(totalMeters / shoe.replacementDistanceMeters, 1)
    }

    private var tone: Color {
        switch wear {
        case .fresh:       return .brand
        case .replaceSoon: return .warning
        case .worn:        return .destructive
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(shoe.name.isEmpty ? String(localized: "Unnamed pair") : shoe.name)
                    .font(.bodyStrong)
                if shoe.isDefault {
                    Text("Default")
                        .font(.dsCaption2.weight(.bold))
                        .foregroundStyle(.brandText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.brand.opacity(0.12), in: Capsule())
                }
                Spacer()
                if !shoe.isRetired {
                    switch wear {
                    case .fresh: EmptyView()
                    case .replaceSoon:
                        Text("Nearly done").font(.captionStrong).foregroundStyle(tone)
                    case .worn:
                        Text("Worn out").font(.captionStrong).foregroundStyle(tone)
                    }
                }
            }
            ProgressView(value: progress)
                .tint(shoe.isRetired ? .secondary : tone)
            Text("\(totalText) of \(limitText)")
                .font(.dsCaption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Editor

/// Adds a pair or edits one. Distances are entered in the runner's own unit and stored
/// in metres.
struct ShoeEditorView: View {
    enum Target: Identifiable {
        case new
        case existing(Shoe)

        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let shoe): return shoe.id.uuidString
            }
        }
    }

    let target: Target
    let allShoes: [Shoe]

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var appSettings

    @State private var name = ""
    @State private var startDate = Date()
    @State private var startingDistance: Double = 0
    @State private var replacementDistance: Double = 0
    @State private var isDefault = false
    @State private var isRetired = false
    @State private var loaded = false

    private var unit: UnitPreference { appSettings.unitPreference }
    private var unitLabel: String { unit == .metric ? "km" : "mi" }
    private var metersPerUnit: Double { unit == .metric ? 1_000 : 1_609.344 }

    private var existing: Shoe? {
        if case .existing(let shoe) = target { return shoe }
        return nil
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Pegasus 41", text: $name)
                    DatePicker("In use since", selection: $startDate, in: ...Date(), displayedComponents: .date)
                }
                Section {
                    distanceField("Already run in them", value: $startingDistance)
                    distanceField("Replace at", value: $replacementDistance)
                } footer: {
                    Text("Most pairs are good for about \(defaultReplacementText). It depends on the shoe, the runner and the surface, so change it if your pairs usually last longer or shorter.")
                }
                Section {
                    Toggle("Use for new runs", isOn: $isDefault)
                        .disabled(isRetired)
                    if existing != nil {
                        Toggle("Retired", isOn: $isRetired)
                    }
                } footer: {
                    Text("New runs from the day this pair went into use are put on it. You can change the shoe on any run.")
                }
            }
            .navigationTitle(existing == nil ? "New Pair" : "Edit Pair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(trimmedName.isEmpty || replacementDistance <= 0)
                }
            }
            .onAppear(perform: load)
            .onChange(of: isRetired) { _, retired in
                if retired { isDefault = false }
            }
        }
    }

    private var defaultReplacementText: String {
        ShoeWearPolicy.defaultReplacementMeters(for: unit).distanceString(unit: unit)
    }

    private func distanceField(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("0", value: value, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 100)
                Text(unitLabel).foregroundStyle(.secondary)
            }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let shoe = existing {
            name = shoe.name
            startDate = shoe.startDate
            startingDistance = shoe.startingDistanceMeters / metersPerUnit
            replacementDistance = shoe.replacementDistanceMeters / metersPerUnit
            isDefault = shoe.isDefault
            isRetired = shoe.isRetired
        } else {
            replacementDistance = ShoeWearPolicy.defaultReplacementMeters(for: unit) / metersPerUnit
            // The first pair is the default: with one pair there is no choice to make.
            isDefault = !allShoes.contains { !$0.isRetired }
        }
    }

    private func save() {
        let shoe: Shoe
        if let existing {
            shoe = existing
        } else {
            shoe = Shoe(name: trimmedName, replacementDistanceMeters: 0)
            context.insert(shoe)
        }
        shoe.name = trimmedName
        shoe.startDate = startDate
        shoe.startingDistanceMeters = max(startingDistance, 0) * metersPerUnit
        shoe.replacementDistanceMeters = replacementDistance * metersPerUnit

        if isRetired {
            if !shoe.isRetired { ShoeAssignment.retire(shoe) }
        } else {
            shoe.retiredAt = nil
            if isDefault, !shoe.isDefault {
                ShoeAssignment.makeDefault(shoe, among: allShoes + [shoe])
            } else if !isDefault {
                shoe.defaultSetAt = nil
            }
        }
        context.saveOrLog("saving a shoe")
        dismiss()
    }
}
