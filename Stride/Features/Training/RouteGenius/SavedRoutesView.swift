import SwiftUI

// MARK: - SavedRoutesView

/// Displays all saved routes with a detail drill-down showing the map and steps.
struct SavedRoutesView: View {

    @State var viewModel: RouteGeniusViewModel
    @State private var routeToDelete: SavedRoute?
    @State private var showDeleteConfirm = false

    var body: some View {
        Group {
            if viewModel.savedRoutes.isEmpty {
                ContentUnavailableView(
                    "No Saved Routes",
                    systemImage: "map",
                    description: Text("Generate and save a route to see it here.")
                )
            } else {
                List {
                    ForEach(viewModel.savedRoutes) { route in
                        NavigationLink {
                            SavedRouteDetailView(route: route, viewModel: viewModel)
                        } label: {
                            SavedRouteRow(route: route, viewModel: viewModel)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                routeToDelete = route
                                showDeleteConfirm = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Saved Routes")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { viewModel.loadSavedRoutes() }
        .confirmationDialog(
            "Delete Route?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let route = routeToDelete {
                    viewModel.deleteRoute(route)
                    routeToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { routeToDelete = nil }
        } message: {
            Text("This route will be permanently removed.")
        }
    }
}

// MARK: - SavedRouteRow

private struct SavedRouteRow: View {
    let route: SavedRoute
    let viewModel: RouteGeniusViewModel

    var body: some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.brand.opacity(0.12))
                    .frame(width: 44, height: 44)
                StrideIcon(name: route.routeType.strideIcon, size: 22, color: .brand, strokeWeight: 2.0)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(route.name)
                    .font(.bodyStrong)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(viewModel.formattedDistance(route.actualDistanceMeters))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(route.routeType.localizedName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(route.createdAt.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - SavedRouteDetailView

struct SavedRouteDetailView: View {
    let route: SavedRoute
    let viewModel: RouteGeniusViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Stats bar
                HStack {
                    DetailStat(
                        label: "Distance",
                        value: viewModel.formattedDistance(route.actualDistanceMeters)
                    )
                    Divider().frame(height: 40)
                    DetailStat(
                        label: "Est. Time",
                        value: viewModel.formattedDuration(route.estimatedDurationSeconds)
                    )
                    Divider().frame(height: 40)
                    DetailStat(label: "Type", value: route.routeType.localizedName)
                }
                .padding()
                .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))

                // Map
                SavedRouteMapView(route: route)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                // Turn-by-turn
                if !route.steps.isEmpty {
                    savedRouteTurnByTurn
                }
            }
            .padding()
        }
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.large)
    }

    private var savedRouteTurnByTurn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TURN-BY-TURN")
                .font(.sectionHeader)
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)

            VStack(spacing: 0) {
                ForEach(Array(route.steps.enumerated()), id: \.offset) { index, step in
                    TurnByTurnRow(step: step, index: index, viewModel: viewModel)
                    if index < route.steps.count - 1 {
                        Divider().padding(.leading, 48)
                    }
                }
            }
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

// MARK: - DetailStat

private struct DetailStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.bodyStrong)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
