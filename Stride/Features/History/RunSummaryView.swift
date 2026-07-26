import SwiftUI
import MapKit
import Charts
import SwiftData
import UIKit

// The run detail screen. This file holds the screen's state, the values derived from
// the run, the three on-demand loads (heart-rate zones, split backfill, share card),
// and `body`; each section it composes lives in a `RunSummaryView+*.swift` extension
// alongside it — Overview, TempoInsights, CoachCard, CoachSection, CoachStreaming,
// CoachComponents, Splits, HeartRateZones, PlannedWorkout, Chrome.
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
    /// The rendered share card (B5), non-nil only while the share sheet is up. Rendering
    /// is deferred until the user taps Share (N21) — the map snapshot plus a ×3
    /// `ImageRenderer` pass is far too expensive to run on every run-detail open.
    @State private var shareCard: ShareCardImage?
    @State private var isRenderingShareCard = false

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

        var recent = FetchDescriptor<RunWorkout>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        recent.fetchLimit = Self.adaptationHistoryRunCount + 1
        _recentRuns = Query(recent)

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

    /// Whether the splits table shows an HR column. Asked of `SplitChartMetric` rather
    /// than re-tested here, so the table and the chart tabs can never disagree about
    /// whether this run carries per-split heart rate.
    var hasSplitHR: Bool {
        availableSplitMetrics.contains(.heartRate)
    }

    func split(forKm km: Int) -> Split? {
        workout.splits.first { $0.kilometer == km }
    }

    /// Lowercase label for the unit each split bucket represents ("km" / "mi"), read from the
    /// run's stored `splitUnit` so a mile-bucketed run reads "mi" while legacy km runs read "km".
    var splitLabel: String { workout.splitUnit.distanceLabel }
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
    private func backfillSplits() async {
        let unit = appSettings.unitPreference
        guard SplitBackfill.needsSplits(workout, splitLengthMeters: unit.splitLengthMeters),
              let hkID = workout.healthKitWorkoutID else { return }

        let points = await container.healthKitRepository.fetchDistanceSeries(forWorkoutID: hkID)
        let splits = SplitBucketing.splits(
            from: points,
            splitLengthMeters: unit.splitLengthMeters,
            heartRateSamples: workout.heartRateSamples,
            totalDurationSeconds: workout.durationSeconds
        )
        guard !splits.isEmpty else { return }

        workout.splits = splits
        workout.splitUnit = unit
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
        return workout.scheduledWorkout?.workoutType.localizedName ?? "\(workout.workoutLocation.localizedName) Run"
    }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                titleBlock
                if workout.scheduledWorkout == nil {
                    linkToPlannedWorkoutButton
                }
                routeMap
                aiCoachAccessCard
                statsGrid
                paceInsightsSection
                weatherSection
                plannedWorkoutSection
                // Splits and heart-rate zones come before the coaching read: they are the
                // evidence the insight is written from, and the insight now cites them.
                if !workout.splits.isEmpty {
                    splitsSection
                    splitsTable
                }
                if !zoneSlices.isEmpty, zoneSlices.contains(where: { $0.seconds > 0 }) {
                    heartRateZoneSection
                }
                aiCoachSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .task(id: workout.id) {
            // Heart-rate zones are content on the screen, so they load first; the share
            // card renders on demand (N21). Splits follow the HR load so a backfilled
            // heart-rate series can be bucketed into them (N9).
            await loadHeartRateZones()
            await backfillSplits()
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
                // screen appears once a pre-render finished (N21).
                Button {
                    Task { await renderShareCard() }
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
