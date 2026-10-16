import SwiftUI
import MapKit

// MARK: - RouteGeniusView

/// Main Route Genius screen. Presented as a sheet from the Training Plan tab.
///
/// Flow:
///   1. User picks distance, route type, and starting point.
///   2. Taps "Generate Route" → Apple Maps walking directions (or OpenRouteService,
///      when the runner has added a key in Settings).
///   3. Route appears on a map with turn-by-turn steps below.
///   4. User can save the route (name prompt) or regenerate.
struct RouteGeniusView: View {

    @State var viewModel: RouteGeniusViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showSaveSheet = false
    @State private var routeNameInput = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    configSection
                    generateButton

                    if viewModel.isGenerating {
                        generatingIndicator
                    }

                    if let error = viewModel.errorMessage {
                        errorCard(error)
                    }

                    if !viewModel.routeOptions.isEmpty,
                       let coord = viewModel.startCoordinate {
                        routeOptionsSection(startCoord: coord)
                    }
                }
                .padding()
            }
            .navigationTitle("Route Genius")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        SavedRoutesView(viewModel: viewModel)
                    } label: {
                        Label("Saved", systemImage: "bookmark.fill")
                    }
                }
            }
            .sheet(isPresented: $showSaveSheet) {
                saveRouteSheet
            }
        }
    }

    // MARK: Config section

    private var configSection: some View {
        VStack(spacing: 16) {
            distanceField
            routeTypePicker
            startPointPicker
        }
        .padding()
        .strideCard(cornerRadius: AppRadius.md)
    }

    private var distanceField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Distance", systemImage: "ruler")
                .font(.sectionHeader)
                .foregroundStyle(.secondary)

            HStack {
                TextField("e.g. 5", text: $viewModel.distanceInput)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.plain)
                    .font(.dsTitle2)
                    .frame(maxWidth: .infinity)

                Text(viewModel.unitLabel)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding()
            // A well in the card: the page's own ground with a hairline, not the system
            // background (white or black), which broke the one-ground rule.
            .background(.surfacePrimary, in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md).strokeBorder(.cardStroke, lineWidth: 1))
        }
    }

    private var routeTypePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Route Type", systemImage: "arrow.triangle.2.circlepath")
                .font(.sectionHeader)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                ForEach(RouteType.allCases, id: \.self) { type in
                    RouteTypeButton(
                        type: type,
                        isSelected: viewModel.routeType == type
                    ) {
                        viewModel.routeType = type
                    }
                }
            }
        }
    }

    private var startPointPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Starting Point", systemImage: "mappin.and.ellipse")
                .font(.sectionHeader)
                .foregroundStyle(.secondary)

            Picker("Start", selection: $viewModel.startMode) {
                ForEach(StartMode.allCases, id: \.self) { mode in
                    Label(mode.rawValue, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch viewModel.startMode {
            case .address:
                addressSearchField
            case .currentLocation:
                currentLocationStatus
            }
        }
    }

    // MARK: Address search

    private var addressSearchField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search address…", text: $viewModel.addressQuery)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await viewModel.searchAddress() } }
                if !viewModel.addressQuery.isEmpty {
                    Button {
                        viewModel.addressQuery = ""
                        viewModel.addressResults = []
                        viewModel.selectedMapItem = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear address search")
                }
            }
            .padding(10)
            .background(.surfacePrimary, in: RoundedRectangle(cornerRadius: AppRadius.sm))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.sm).strokeBorder(.cardStroke, lineWidth: 1))

            if !viewModel.addressResults.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.addressResults, id: \.self) { item in
                        Button { viewModel.selectAddress(item) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name ?? "Unknown")
                                    .font(.bodyRegular)
                                    .foregroundStyle(.primary)
                                if let title = item.placemark.title {
                                    Text(title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, AppSpacing.md)
                            .padding(.vertical, 10)
                        }
                        if item != viewModel.addressResults.last {
                            Divider().padding(.leading, AppSpacing.md)
                        }
                    }
                }
                .background(.surfacePrimary, in: RoundedRectangle(cornerRadius: AppRadius.sm))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.sm).strokeBorder(.cardStroke, lineWidth: 1))
            }

            if let selected = viewModel.selectedMapItem {
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(Color.success).frame(width: 16, height: 16)
                        StrideIcon(name: .check, size: 8, color: .white, strokeWeight: 2.5)
                    }
                    Text(selected.name ?? "Selected location")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: viewModel.addressQuery) { _, newValue in
            if newValue.count > 2 { viewModel.searchAddressDebounced() }
        }
    }

    private var currentLocationStatus: some View {
        HStack(spacing: 6) {
            if viewModel.currentCoordinate != nil {
                ZStack {
                    Circle().fill(Color.success).frame(width: 16, height: 16)
                    StrideIcon(name: .check, size: 8, color: .white, strokeWeight: 2.5)
                }
                Text("Location acquired").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().scaleEffect(0.7)
                Text("Acquiring location…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Generate button

    private var generateButton: some View {
        Button {
            Task { await viewModel.generateRouteOptions() }
        } label: {
            Label(
                viewModel.routeOptions.isEmpty ? "Generate Routes" : "Regenerate",
                systemImage: viewModel.routeOptions.isEmpty ? "wand.and.stars" : "arrow.clockwise"
            )
            .font(.bodyStrong)
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                viewModel.canGenerate ? Color.brand : Color.secondary.opacity(0.3),
                in: RoundedRectangle(cornerRadius: AppRadius.md)
            )
            .foregroundStyle(viewModel.canGenerate ? .white : .secondary)
        }
        .disabled(!viewModel.canGenerate)
        .animation(.easeInOut(duration: 0.2), value: viewModel.canGenerate)
    }

    // MARK: Generating indicator

    private var generatingIndicator: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Plotting your route…").font(.bodyRegular).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .strideCard(cornerRadius: AppRadius.md)
    }

    // MARK: Error card

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            StrideIcon(name: .flag, size: 16, color: .warning, strokeWeight: 2)
            Text(message).font(.bodyRegular).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    // MARK: Route options

    @ViewBuilder
    private func routeOptionsSection(startCoord: CLLocationCoordinate2D) -> some View {
        VStack(spacing: 12) {
            Text("CHOOSE A ROUTE")
                .font(.sectionHeader)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(Array(viewModel.routeOptions.enumerated()), id: \.offset) { index, route in
                RouteOptionCard(
                    route: route,
                    startCoord: startCoord,
                    isSelected: viewModel.selectedRouteIndex == index,
                    viewModel: viewModel
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.selectedRouteIndex = index
                    }
                }
            }

            if let route = viewModel.selectedRoute {
                selectedRouteDetail(route: route, startCoord: startCoord)
            }
        }
    }

    // MARK: Selected route detail

    @ViewBuilder
    private func selectedRouteDetail(route: GeneratedRoute, startCoord: CLLocationCoordinate2D) -> some View {
        VStack(spacing: 16) {
            RouteMapView(
                coordinates: route.coordinates.map(\.clCoordinate),
                startCoordinate: startCoord
            )
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            .transition(.opacity.combined(with: .scale(scale: 0.97)))

            Button {
                routeNameInput = ""
                showSaveSheet = true
            } label: {
                Label("Save This Route", systemImage: "bookmark")
            }
            .buttonStyle(.strideButton())

            if !route.steps.isEmpty {
                TurnByTurnList(steps: route.steps, viewModel: viewModel)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.selectedRouteIndex)
    }

    // MARK: Save route sheet

    private var saveRouteSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .fill(Color.brand.opacity(0.12))
                        .frame(width: 64, height: 64)
                    StrideIcon(name: .flag, size: 28, color: .brand, strokeWeight: 2.0)
                }

                Text("Name Your Route")
                    .font(.dsTitle2)

                TextField("Route name (optional)", text: $routeNameInput)
                    .strideField()
                    .padding(.horizontal)

                Button {
                    viewModel.saveRoute(name: routeNameInput)
                    showSaveSheet = false
                } label: {
                    Text("Save")
                }
                .buttonStyle(.strideButton())
                .padding(.horizontal)
            }
            .padding(.top, AppSpacing.huge)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showSaveSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - RouteOptionCard

private struct RouteOptionCard: View {
    let route: GeneratedRoute
    let startCoord: CLLocationCoordinate2D
    let isSelected: Bool
    let viewModel: RouteGeniusViewModel
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                // Header row
                HStack {
                    Text(route.label)
                        .font(.bodyStrong)
                        .foregroundStyle(isSelected ? .brand : .primary)

                    Spacer()

                    if isSelected {
                        ZStack {
                            Circle().fill(Color.brand).frame(width: 20, height: 20)
                            StrideIcon(name: .check, size: 10, color: .white, strokeWeight: 2.5)
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                }

                // Mini map thumbnail
                RouteMapView(
                    coordinates: route.coordinates.map(\.clCoordinate),
                    startCoordinate: startCoord
                )
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
                .allowsHitTesting(false)

                // Stats
                HStack(spacing: 16) {
                    Label(viewModel.formattedDistance(route.distanceMeters), systemImage: "arrow.triangle.swap")
                    Label(viewModel.formattedDuration(route.durationSeconds), systemImage: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(AppSpacing.md)
            .background(
                isSelected
                    ? Color.brand.opacity(0.08)
                    : Color.surfaceSecondary,
                in: RoundedRectangle(cornerRadius: AppRadius.md)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(isSelected ? Color.brand : Color.clear, lineWidth: 2)
            )
            .animation(.easeInOut(duration: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - RouteTypeButton

private struct RouteTypeButton: View {
    let type: RouteType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                StrideIcon(name: type.strideIcon, size: 22,
                           color: isSelected ? .onFill : .primary, strokeWeight: 2.0)
                Text(type.localizedName).font(.captionStrong)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.md)
            // Chosen is the route with `onFill`; the others are wells in the card.
            .background {
                let shape = RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                if isSelected {
                    shape.fill(.route)
                } else {
                    shape.fill(.surfacePrimary)
                        .overlay(shape.strokeBorder(.cardStroke, lineWidth: 1))
                }
            }
            .foregroundStyle(isSelected ? Color.onFill : Color.primary)
            .adaptiveAnimation(AppAnimation.snappy, value: isSelected)
        }
        .buttonStyle(BouncyButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - RouteStatPill

private struct RouteStatPill: View {
    let icon: StrideIconName
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            StrideIcon(name: icon, size: 14, color: .brand, strokeWeight: 2.0)
            Text(value).font(.bodyStrong).minimumScaleFactor(0.7).lineLimit(1)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - TurnByTurnList

private struct TurnByTurnList: View {
    let steps: [RouteStep]
    let viewModel: RouteGeniusViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TURN-BY-TURN")
                .font(.sectionHeader)
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)

            VStack(spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    TurnByTurnRow(step: step, index: index, viewModel: viewModel)
                    if index < steps.count - 1 {
                        Divider().padding(.leading, 48)
                    }
                }
            }
            .strideCard(cornerRadius: AppRadius.md)
        }
    }
}

// MARK: - TurnByTurnRow

struct TurnByTurnRow: View {
    let step: RouteStep
    let index: Int
    let viewModel: RouteGeniusViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(index == 0 ? Color.brand : Color.secondary.opacity(0.15))
                    .frame(width: 28, height: 28)
                Text("\(index + 1)")
                    .font(.caption.bold())
                    .foregroundStyle(index == 0 ? .white : .secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(step.instruction).font(.bodyRegular)
                // Apple Maps steps carry no separate street name; only ORS fills it.
                if !step.name.isEmpty {
                    Text(step.name).font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(viewModel.formattedDistance(step.distanceMeters))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, AppSpacing.md)
    }
}
