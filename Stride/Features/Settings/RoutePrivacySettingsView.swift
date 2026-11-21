import CoreLocation
import MapKit
import SwiftUI

// MARK: - RoutePrivacySettingsView

/// What a shared run hides: the first and last stretch of every run, and private places
/// such as home (``RoutePrivacy``).
///
/// Changes save as they're made. They apply the next time a run card or GPX file is made;
/// nothing stored is changed, so turning privacy off brings every route back in full.
struct RoutePrivacySettingsView: View {

    @State private var privacy = RoutePrivacy()
    @State private var hasLoaded = false
    @State private var isAddingPlace = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                endsCard
                placesCard
                Text("Applies to run cards and GPX files you share from a run. The route stays whole in Stride and Apple Health, and in Export All Data, which is your own backup.")
                    .font(.dsFootnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, AppSpacing.xs)
            }
            .padding(AppSpacing.lg)
            .strideReadableWidth()
        }
        .background(Color.surfacePrimary)
        .navigationTitle("Route privacy")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isAddingPlace) {
            AddPrivatePlaceSheet { place in
                privacy.places.append(place)
            }
        }
        .onAppear {
            guard !hasLoaded else { return }
            privacy = RoutePrivacy.load()
            hasLoaded = true
        }
        .onChange(of: privacy) { _, newValue in
            guard hasLoaded else { return }
            newValue.save()
        }
    }

    // MARK: - Start and finish

    private var endsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start and finish")
                .strideEyebrow()
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)
            HStack {
                Text("Hide")
                Spacer()
                Picker("Hide start and finish", selection: $privacy.hideEndsMeters) {
                    ForEach(RoutePrivacy.hideEndsOptions, id: \.self) { meters in
                        Text(Self.endsLabel(meters)).tag(meters)
                    }
                }
                .labelsHidden()
            }
            .font(.dsBody)
            .padding(.vertical, AppSpacing.sm)
            .padding(.horizontal, AppSpacing.md)
            .strideCard(cornerRadius: AppRadius.md)
            Text("Leaves the first and last stretch of every run off the map, wherever it started.")
                .font(.dsFootnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, AppSpacing.xs)
        }
    }

    private static func endsLabel(_ meters: Double) -> String {
        meters == 0 ? "Off" : "First and last \(Int(meters)) m"
    }

    // MARK: - Private places

    private var placesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Private places")
                .strideEyebrow()
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)
            VStack(spacing: 0) {
                if !privacy.places.isEmpty {
                    placesMap
                        .padding(.top, AppSpacing.md)
                        .padding(.bottom, AppSpacing.sm)
                }
                ForEach($privacy.places) { $place in
                    HStack(spacing: AppSpacing.sm) {
                        StrideIcon(name: .lock, size: 18, color: .brand)
                        Text(place.name)
                            .font(.dsBody)
                            .lineLimit(1)
                        Spacer()
                        Picker("Radius for \(place.name)", selection: $place.radiusMeters) {
                            ForEach(RoutePrivacy.radiusOptions, id: \.self) { meters in
                                Text("\(Int(meters)) m").tag(meters)
                            }
                        }
                        .labelsHidden()
                        Button("Remove") {
                            privacy.places.removeAll { $0.id == place.id }
                        }
                        .buttonStyle(.strideButton(.quiet, compact: true, fullWidth: false))
                        .accessibilityLabel("Remove \(place.name)")
                    }
                    .padding(.vertical, AppSpacing.sm)
                    Divider()
                }
                Button {
                    isAddingPlace = true
                } label: {
                    Label("Add a place", strideIcon: .location, size: 18, color: .brand)
                }
                .buttonStyle(.strideButton(.secondary, compact: true))
                .padding(.vertical, AppSpacing.md)
                .accessibilityIdentifier("routePrivacy.addPlace")
            }
            .padding(.horizontal, AppSpacing.md)
            .strideCard(cornerRadius: AppRadius.md)
            Text("Nothing inside a private place's circle shows on a shared run, even mid-run. Add home, work, or anywhere you often start from.")
                .font(.dsFootnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, AppSpacing.xs)
        }
    }

    /// The places and their circles, so a runner can see what "400 m" covers.
    private var placesMap: some View {
        Map(initialPosition: .automatic, interactionModes: []) {
            ForEach(privacy.places) { place in
                MapCircle(center: place.center.clCoordinate, radius: place.radiusMeters)
                    .foregroundStyle(Color.brand.opacity(0.25))
                    .stroke(Color.brand, lineWidth: 2)
            }
        }
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
        // Re-frame when a place or its radius changes; `.automatic` frames once.
        .id(privacy.places)
        .accessibilityHidden(true)
    }
}

// MARK: - AddPrivatePlaceSheet

/// Picks a private place: where the runner is now, or an address they search for.
private struct AddPrivatePlaceSheet: View {

    let onAdd: (RoutePrivacy.Place) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = "Home"
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var isLocating = false
    @State private var locationFailed = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Home", text: $name)
                        .textInputAutocapitalization(.words)
                }
                Section {
                    Button {
                        Task { await addCurrentLocation() }
                    } label: {
                        HStack {
                            Label("Use where I am now", strideIcon: .location, size: 18, color: .brand)
                            Spacer()
                            if isLocating { ProgressView() }
                        }
                    }
                    .disabled(isLocating)
                    if locationFailed {
                        Text("Couldn't find your location. Check that Stride can use Location in Settings, or search for the address below.")
                            .font(.dsFootnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Or search for an address") {
                    TextField("Address", text: $query)
                        .textContentType(.fullStreetAddress)
                        .autocorrectionDisabled()
                        .onChange(of: query) { _, _ in search() }
                    ForEach(results, id: \.self) { item in
                        Button {
                            add(item.placemark.coordinate)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name ?? "")
                                    .foregroundStyle(.primary)
                                if let title = item.placemark.title {
                                    Text(title)
                                        .font(.dsFootnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add a private place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onDisappear { searchTask?.cancel() }
    }

    private var trimmedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Private place" : trimmed
    }

    private func add(_ coordinate: CLLocationCoordinate2D) {
        onAdd(RoutePrivacy.Place(
            name: trimmedName,
            center: Coordinate(coordinate),
            radiusMeters: RoutePrivacy.defaultRadiusMeters
        ))
        dismiss()
    }

    /// The first fix good to 100 m, or give up after 15 seconds.
    private func addCurrentLocation() async {
        isLocating = true
        locationFailed = false
        defer { isLocating = false }

        let fix = await withTaskGroup(of: Coordinate?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let location = update.location, location.horizontalAccuracy >= 0,
                           location.horizontalAccuracy <= 100 {
                            return Coordinate(location.coordinate)
                        }
                        if update.authorizationDenied || update.authorizationDeniedGlobally { return nil }
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(15))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        if let fix {
            add(fix.clCoordinate)
        } else {
            locationFailed = true
        }
    }

    private func search() {
        searchTask?.cancel()
        let text = query
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled,
                  !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                if !Task.isCancelled { results = [] }
                return
            }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            let response = try? await MKLocalSearch(request: request).start()
            guard !Task.isCancelled, text == query else { return }
            results = Array((response?.mapItems ?? []).prefix(5))
        }
    }
}
