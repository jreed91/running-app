import SwiftUI
import MapKit
import Charts
import SwiftData
import UIKit

// The run detail screen. This file holds the screen's state, the values derived from
// the run, the three on-demand loads (heart-rate zones, split backfill, share card),
// and `body`; each section it composes lives in a `RunSummaryView+*.swift` extension
// alongside it — Overview, Feel, TempoInsights, CoachCard, CoachSection, CoachStreaming,
// CoachComponents, Splits, HeartRateZones, PlannedWorkout, Chrome, Strava.
//
// The screen used to be one 2,232-line file carrying a `swiftlint:disable file_length
// type_body_length` banner, which is the last of D1. The logic came out first — the
// coach prose (`CoachInsightText`), the chart availability rule (`SplitChartMetric`),
// the adaptation filter (`AdaptableWorkoutSelector`), the backfills — so what was left
// was view code and thin delegation, and splitting it needed no behaviour change.
// Members are `internal` rather than `private` only where a sibling file reads them.
struct RunSummaryView: View {
    let workout: RunWorkout

    @Environment(AppSettings.self) var appSettings
    @Environment(\.modelContext) var context
    @Environment(\.dismiss) var dismiss
    @Environment(AppContainer.self) var container
    /// The plan day this run fulfilled, found by the run's own id — where this screen used
    /// to fetch **every** `ScheduledWorkout` in the store and scan it (D6).
    @Query private var scheduledLinkingThisRun: [ScheduledWorkout]
    /// The newest runs, for the two coach requests. One more than the longest slice either
    /// takes, so dropping this run from the list can never shorten it (D6).
    @Query var recentRuns: [RunWorkout]
    /// Every tempo and race run, all-time — the only history `tempoInsights` consults, so
    /// this preserves its all-time "previous best tempo" while replacing a whole-table
    /// fetch with a narrow one (D6).
    @Query private var qualityRuns: [RunWorkout]
    @Query var profiles: [UserProfile]
    @Query(
        filter: #Predicate<TrainingPlan> { $0.isActive },
        sort: \TrainingPlan.createdAt, order: .reverse
    )
    private var activePlans: [TrainingPlan]

    // Chart selection state
    @State var selectedSplitPaceKm: Int? = nil
    @State var selectedSplitHRKm: Int? = nil
    @State var selectedSplitElevKm: Int? = nil
    /// Which split chart the tab row is showing (N22).
    @State var selectedSplitMetric: SplitChartMetric = .pace

    /// The bucketed series behind the split charts, resolved once per run (N34). `nil` until
    /// the first resolve, which `chartedSplits` covers with the run's stored splits.
    @State var resolvedSplitSeries: SplitChartSeries.Resolved?
    @State private var showDeleteConfirmation = false

    // Sizes that have to track the text beside them rather than staying pinned (U2).
    // Declared here rather than in `RunSummaryView+Overview` because a Swift
    // extension can't carry stored properties.
    @ScaledMetric(relativeTo: .largeTitle) var heroMetricSize: CGFloat = 56
    @ScaledMetric(relativeTo: .title) var weatherGlyphSize: CGFloat = 32
    @State var showAssociateSheet = false
    @State var aiInsight: AICoachInsight?
    @State var isLoadingAIInsight = false
    @State var aiStreamBuffer = ""
    @State var showFullAIAnalysis = false
    @State var isApplyingNextSessionFeedback = false
    @State var nextSessionUpdateMessage: String?
    @State var coachChatRequest: AICoachChatRequest?
    @State var zoneSlices: [HRZoneSlice] = []
    /// Whether the feel rating changed after a coach read was requested — the cue for the
    /// feel card to point at Refresh, since that read was written without it.
    @State var feelChangedSinceInsight = false
    /// The rendered share card (B5), non-nil only while the share sheet is up. Rendering
    /// is deferred until the user taps Share (N21) — the map snapshot plus a ×3
    /// `ImageRenderer` pass is far too expensive to run on every run-detail open.
    @State private var shareCard: ShareCardImage?
    @State private var isRenderingShareCard = false
    /// The run's route written out as GPX (B6), non-nil only while its share sheet is up.
    @State private var gpxFile: ExportedFile?
    /// Shown when the export could not be written — a full disk or a sandbox refusal is
    /// rare, but silently doing nothing when the runner taps Export is worse.
    @State private var exportErrorMessage: String?

    /// Runs the coach's per-run insight summarises.
    static let insightHistoryRunCount = 8
    /// Runs the coach's plan-adaptation request summarises.
    static let adaptationHistoryRunCount = 50

    init(workout: RunWorkout) {
        self.workout = workout

        // Every linker writes the scalar id alongside the relationship
        // (`WorkoutSyncService`, `AssociateWorkoutSheet`, the run-finish path) and
        // `WorkoutRepository` clears both on delete, so this is a faithful mirror of the
        // relationship — and the same field `repairRelationships` restores from.
        // Typed as `UUID?` so the predicate compares like for like against the optional
        // stored property.
        let runID: UUID? = workout.id
        var linked = FetchDescriptor<ScheduledWorkout>(
            predicate: #Predicate { $0.linkedRunWorkoutID == runID }
        )
        linked.fetchLimit = 1
        _scheduledLinkingThisRun = Query(linked)

        // Runs only: both coach requests read this as the runner's training history, and
        // the limit has to count runs for the "one more than the longest slice" promise
        // above to hold (N38).
        _recentRuns = Query(RunWorkout.runsOnlyDescriptor(
            fetchLimit: Self.adaptationHistoryRunCount + 1
        ))

        let tempo = WorkoutType.tempo.rawValue
        let race = WorkoutType.race.rawValue
        _qualityRuns = Query(
            FetchDescriptor<RunWorkout>(
                predicate: #Predicate { $0.workoutTypeRaw == tempo || $0.workoutTypeRaw == race },
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
        )
    }

    /// The plan day this run fulfilled. The relationship is the fast path; the id-matched
    /// query covers a CloudKit restore that landed the scalar backup before the reference.
    var matchedScheduled: ScheduledWorkout? {
        workout.scheduledWorkout ?? scheduledLinkingThisRun.first
    }

    var planForNextSessionUpdate: TrainingPlan? {
        matchedScheduled?.week?.plan
            ?? workout.scheduledWorkout?.week?.plan
            ?? activePlans.first
    }

    var estimatedVO2Max: Double? {
        ProgressStatsService.estimatedVDOT(for: workout)
    }

    /// Whether the splits table shows an HR column. Asked of `SplitChartMetric` rather than
    /// re-tested here, so the table and the chart tabs answer "does this carry per-split
    /// heart rate?" by one rule — but of the table's own whole-unit splits, which are not
    /// always what the chart above it plots (N34).
    var hasSplitHR: Bool {
        SplitChartMetric.available(for: workout.splits).contains(.heartRate)
    }

    /// Uppercase form used in chart/table headers ("KM" / "MI").
    var splitLabelUpper: String { workout.splitUnit.splitLabel }

    /// The runner's max HR (explicit or age-estimated) needed to compute HR zones.
    var maxHeartRate: Double? {
        profiles.first?.effectiveMaxHeartRate.map(Double.init)
    }

    /// Loads the time-in-zone breakdown for this run: uses persisted HR samples when present,
    /// otherwise backfills from HealthKit on demand for older imported runs (A6). No-op when the
    /// runner has no max HR configured.
    func loadHeartRateZones() async {
        guard let maxHR = maxHeartRate else { zoneSlices = []; return }
        var samples = workout.heartRateSamples
        if samples.isEmpty, let hkID = workout.healthKitWorkoutID {
            samples = await container.healthKitRepository.fetchHeartRateSamples(forWorkoutID: hkID)
            if !samples.isEmpty {
                workout.heartRateSamples = samples   // cache so we don't re-fetch next time
                context.saveOrLog("backfilled heart-rate samples")
            }
        }
        zoneSlices = HeartRateZoneService.timeInZones(
            bpmSamples: samples,
            totalSeconds: workout.durationSeconds,
            maxHR: maxHR
        )
    }

    /// Buckets splits onto a run that was imported before the importer built them (N9).
    ///
    /// Imports have carried real splits since that fix, but older imported runs have none,
    /// so this screen hides the split charts and the splits table for them permanently.
    /// This is the same lazy shape `loadHeartRateZones` uses: one query on open, cached
    /// onto the run so it never runs twice. It deliberately runs *after* the HR load, so a
    /// just-backfilled heart-rate series gives each split its own heart rate — exactly what
    /// the importer does.
    ///
    /// Splits are bucketed in the runner's current unit, since a run imported before splits
    /// existed has no recorded bucket unit of its own.
    ///
    /// The same query also stores the distance readings themselves (N34), which is what lets
    /// the charts re-bucket a short imported run into fractions of a mile instead of drawing
    /// its one whole-mile split as a lone marker. A run that already has splits but no
    /// series — everything imported between N9 and N34 — comes here for the series alone.
    private func backfillSplits() async {
        let unit = appSettings.unitPreference
        let needsSplits = SplitBackfill.needsSplits(workout, splitLengthMeters: unit.splitLengthMeters)
        let needsSeries = SplitBackfill.needsDistanceSeries(workout)
        guard needsSplits || needsSeries, let hkID = workout.healthKitWorkoutID else { return }

        let points = await container.healthKitRepository.fetchDistanceSeries(forWorkoutID: hkID)
        guard !points.isEmpty else { return }

        var changed = false
        if needsSeries {
            workout.distanceSeries = points
            changed = true
        }
        if needsSplits {
            let splits = SplitBucketing.splits(
                from: points,
                splitLengthMeters: unit.splitLengthMeters,
                heartRateSamples: workout.heartRateSamples,
                totalDurationSeconds: workout.durationSeconds
            )
            if !splits.isEmpty {
                workout.splits = splits
                workout.splitUnit = unit
                changed = true
            }
        }
        guard changed else { return }

        do {
            try context.save()
        } catch {
            // The splits are on the in-memory model either way, so the screen shows them
            // for this visit; only the cache is lost.
            AppLogger.log("Split backfill save failed: \(error)", label: "HealthKit", level: .error)
        }
    }

    /// Renders the shareable run card (B5) and presents the share sheet.
    ///
    /// A map snapshot (`MKMapSnapshotter`) plus a ×3 `ImageRenderer` pass (~1080×1350)
    /// used to run on every open of this screen, ahead of the heart-rate zones the user
    /// actually looks at, for a card most opens never share (N21). It now runs only when
    /// Share is tapped.
    private func renderShareCard() async {
        guard !isRenderingShareCard else { return }
        isRenderingShareCard = true
        defer { isRenderingShareCard = false }

        let model = ShareCardModel.make(from: workout, unit: appSettings.unitPreference)
        let mapImage = await RouteSnapshotService.routeSnapshot(
            coordinates: workout.routeCoordinates,
            size: RunShareCardView.routePanelSize,
            scale: 3,
            lineColor: UIColor(.brand),
            lineWidth: 3
        )
        let renderer = ImageRenderer(
            content: RunShareCardView(model: model, routeMapImage: mapImage)
        )
        renderer.scale = 3
        guard let uiImage = renderer.uiImage else {
            AppLogger.log("Share card render produced no image", label: "Share", level: .error)
            return
        }
        shareCard = ShareCardImage(image: uiImage)
    }

    /// Writes this run's route out as GPX and presents the share sheet (B6).
    ///
    /// The file goes to the temporary directory because it exists only to be handed to
    /// whatever the runner picks in the share sheet — the system clears it, and keeping a
    /// second copy of every exported route inside the app's container would be a slowly
    /// growing pile of duplicated GPS traces for no benefit. Overwriting a same-named
    /// leftover from an earlier export of the same run is deliberate.
    private func exportGPX() {
        guard let document = GPXExport.document(for: workout) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(GPXExport.fileName(for: workout))
        do {
            try document.write(to: url, atomically: true, encoding: .utf8)
            gpxFile = ExportedFile(url: url)
        } catch {
            AppLogger.log("GPX export failed: \(error.localizedDescription)", label: "Share", level: .error)
            exportErrorMessage = error.localizedDescription
        }
    }

    var recentHistory: [RunWorkout] {
        recentRuns.filter { $0.id != workout.id }
    }

    /// The tempo and race runs before this one. `tempoInsights` consults only those two
    /// types — an all-time best tempo and races inside six weeks — which is why the narrow
    /// query above can stand in for the whole table; `WorkoutAnalyticsServiceTests` pins
    /// that so a future widening of the rule fails a test rather than this screen.
    private var qualityHistory: [RunWorkout] {
        qualityRuns.filter { $0.id != workout.id }
    }

    var tempoInsights: TempoInsights? {
        guard displayType == .tempo, let profile = profiles.first else { return nil }
        return WorkoutAnalyticsService().tempoInsights(
            for: workout,
            history: qualityHistory,
            profile: profile
        )
    }

    var displayType: WorkoutType {
        workout.scheduledWorkout?.workoutType ?? workout.workoutType
    }

    var workoutTone: Color {
        displayType.color
    }

    var titleMetric: (value: String, unit: String) {
        let converted = appSettings.unitPreference == .imperial
            ? workout.distanceMeters / 1_609.344
            : workout.distanceMeters / 1_000
        return (String(format: "%.2f", converted), appSettings.unitPreference.distanceLabel)
    }

    var routeName: String {
        if let name = workout.scheduledWorkout?.week?.plan?.raceName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        if workout.isWalk {
            return String(
                localized: "\(workout.workoutLocation.localizedName) Walk",
                comment: "Title for an imported walk, e.g. Outdoor Walk"
            )
        }
        return workout.scheduledWorkout?.workoutType.localizedName ?? "\(workout.workoutLocation.localizedName) Run"
    }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                titleBlock
                // A walk can never fulfil a planned session, so the screen does not offer
                // to link one — the same rule the importer's linker applies (N38).
                if workout.scheduledWorkout == nil, !workout.isWalk {
                    linkToPlannedWorkoutButton
                }
                // A walk is not training, so there is nothing for its rating to adjust.
                if !workout.isWalk {
                    feelSection
                }
                routeMap
                // The coach and the pace read are both written against the runner's
                // training paces, which say nothing about a walk. Absent rather than
                // shown empty: an insight on a walk is not a smaller insight, it is one
                // about the wrong thing.
                if !workout.isWalk {
                    aiCoachAccessCard
                }
                statsGrid
                RunShoeRow(workout: workout)
                if !workout.isWalk {
                    paceInsightsSection
                }
                weatherSection
                plannedWorkoutSection
                // Splits and heart-rate zones come before the coaching read: they are the
                // evidence the insight is written from, and the insight now cites them.
                // Laps lead that block when there are any — they are the boundaries the
                // runner chose, and the per-unit splits below are the automatic reading (A2).
                if !workout.laps.isEmpty {
                    lapsSection
                }
                // The card can outlive the table: a run under one whole unit has no stored
                // splits to tabulate, but its recorded readings still bucket into a chart
                // worth showing (N34).
                if !chartedSplits.splits.isEmpty {
                    splitsSection
                }
                if !workout.splits.isEmpty {
                    splitsTable
                }
                if !zoneSlices.isEmpty, zoneSlices.contains(where: { $0.seconds > 0 }) {
                    heartRateZoneSection
                }
                if !workout.isWalk {
                    aiCoachSection
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xxxl)
            .frame(maxWidth: .infinity)
        }
        .task(id: workout.id) {
            // Heart-rate zones are content on the screen, so they load first; the share
            // card renders on demand (N21). Splits follow the HR load so a backfilled
            // heart-rate series can be bucketed into them (N9).
            // Bucketed up front so a short run opens straight into its finer charts rather
            // than showing the one whole-mile bar for as long as the two loads below take,
            // and again after them so a backfilled heart-rate or distance series lands in
            // the charts on the same open that fetched it (N34).
            resolveSplitChartSeries()
            await loadHeartRateZones()
            await backfillSplits()
            resolveSplitChartSeries()
        }
        .background(Color.surfacePrimary.ignoresSafeArea())
        .navigationTitle(displayType.localizedName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Close")
            }
            ToolbarItem(placement: .primaryAction) {
                // Always present, rather than popping into the toolbar seconds after the
                // screen appears once a pre-render finished (N21). A menu rather than a
                // button since B6 gave the run a second thing to send: the picture of it
                // and the data behind it are different asks, and neither is the default.
                Menu {
                    Button {
                        Task { await renderShareCard() }
                    } label: {
                        Label("Share run card", systemImage: "photo")
                    }
                    // Only for runs that have a route — an indoor run has nothing to put in
                    // a GPX, so the option is absent rather than disabled and unexplained.
                    if !workout.routeCoordinates.isEmpty {
                        Button {
                            exportGPX()
                        } label: {
                            Label("Export route as GPX", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        }
                    }
                    stravaMenuItems
                } label: {
                    if isRenderingShareCard {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .disabled(isRenderingShareCard)
                .accessibilityLabel("Share run")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete workout")
            }
        }
        .sheet(isPresented: $showAssociateSheet) {
            AssociateWorkoutSheet(workout: workout)
        }
        .sheet(item: $shareCard) { card in
            ShareSheet(image: card.image)
        }
        .sheet(item: $gpxFile) { file in
            ShareSheet(items: [file.url])
        }
        .alert("Couldn't export this route", isPresented: Binding(
            get: { exportErrorMessage != nil },
            set: { if !$0 { exportErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "")
        }
        .alert("Couldn't upload to Strava", isPresented: isShowingStravaFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(stravaFailureMessage ?? "")
        }
        .sheet(item: $coachChatRequest) { request in
            AICoachChatView(workout: workout, initialPrompt: request.prompt)
        }
        .confirmationDialog("Delete this workout?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                // Repository owns tombstone creation + scheduled-day reset (isCompleted).
                try? container.workoutRepository.delete(workout)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This workout will be permanently removed.")
        }
        .onAppear {
            if aiInsight == nil {
                aiInsight = workout.cachedAIInsight
            }
        }
        .task {
            guard workout.weather == nil, let coord = workout.routeCoordinates.first else { return }
            await container.attachWeather(to: workout, coordinate: coord)
        }
    }
}
