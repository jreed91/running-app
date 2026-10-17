import SwiftUI
import Charts
import SwiftData

struct RaceInsightsView: View {

    /// Bounded to a year (U9). Every figure on this screen comes from
    /// `WorkoutAnalyticsService.snapshot`, whose widest lookback is eight weeks, or
    /// from the most recent qualifying run — so a year is already far more history
    /// than anything here reads.
    @Query private var workouts: [RunWorkout]

    @Query private var profiles: [UserProfile]
    private var profile: UserProfile? { profiles.first }

    @Query(filter: #Predicate<TrainingPlan> { $0.isActive == true })
    private var activePlans: [TrainingPlan]

    @Environment(AppSettings.self) private var appSettings

    @State private var selectedPredictionDate: Date? = nil
    @State private var appeared = false

    init() {
        // A `@Query`'s descriptor is fixed at view-initialisation, so the window is
        // set here rather than in a computed property.
        let cutoff = Calendar.current.date(byAdding: .day, value: -365, to: Date())
            ?? Date.distantPast
        // Runs only — this screen predicts race times (N38, B8).
        let walkRaw = WorkoutType.walk.rawValue
        let crossTrainingRaw = WorkoutType.crossTraining.rawValue
        _workouts = Query(
            filter: #Predicate<RunWorkout> {
                $0.date >= cutoff && $0.workoutTypeRaw != walkRaw && $0.workoutTypeRaw != crossTrainingRaw
            },
            sort: [SortDescriptor(\RunWorkout.date)]
        )
    }

    // MARK: - Snapshot

    private var snapshot: PerformanceSnapshot? {
        guard let prof = profile else { return nil }
        return WorkoutAnalyticsService().snapshot(from: workouts, profile: prof)
    }

    // MARK: - Race and fitness

    /// The race being predicted: the active plan's when it has one, as the race hub and
    /// Plan read it, so all three predict the same race against the same goal.
    private var racePlan: TrainingPlan? {
        guard let plan = activePlans.first, !plan.isPregnancyPlan, plan.targetRace.isGoalRace,
              plan.effectiveRaceDistanceMeters > 0 else { return nil }
        return plan
    }

    private var raceDistanceMeters: Double? {
        racePlan?.effectiveRaceDistanceMeters ?? profile?.effectiveRaceDistanceMeters
    }

    private var goalFinishSeconds: TimeInterval {
        racePlan?.goalTimeSeconds ?? profile?.goalFinishTime ?? 0
    }

    private var raceDisplayName: String {
        racePlan?.targetRace.localizedName ?? profile?.goalRace.localizedName ?? "Race"
    }

    /// The fitness every figure here predicts from; see `RaceDayPlan.currentVDOT`.
    private var currentVDOT: Double? {
        RaceDayPlan.currentVDOT(runs: workouts, profile: profile)
    }

    /// The same prediction Plan's pace insights and the race hub show.
    private var predictedFinishSeconds: TimeInterval? {
        guard let distance = raceDistanceMeters else { return nil }
        return RaceDayPlan.predictedFinishSeconds(
            runs: workouts,
            profile: profile,
            distanceMeters: distance,
            now: Date()
        )
    }

    // MARK: - Prediction points

    private struct PacePredictionPoint: Identifiable {
        let id = UUID()
        let date: Date
        let predictedPaceSecondsPerKm: Double
    }

    private var pacePredictionPoints: [PacePredictionPoint] {
        guard let raceDistance = raceDistanceMeters else { return [] }
        return workouts.compactMap { workout in
            guard let pace = PaceCalculatorService.predictedRacePaceSecondsPerKm(
                workoutDistanceMeters: workout.distanceMeters,
                workoutDurationSeconds: workout.durationSeconds,
                raceDistanceMeters: raceDistance
            ) else { return nil }
            return PacePredictionPoint(date: workout.date, predictedPaceSecondsPerKm: pace)
        }
        .sorted { $0.date < $1.date }
    }

    private var paceTrend: (label: String, color: Color) {
        guard pacePredictionPoints.count >= 3 else {
            return ("Not enough data", .secondary)
        }
        let rawPoints = pacePredictionPoints.map {
            (x: $0.date.timeIntervalSinceReferenceDate, y: $0.predictedPaceSecondsPerKm)
        }
        guard let slopePerSecond = PaceCalculatorService.linearRegressionSlope(rawPoints) else {
            return ("Stable", .secondary)
        }
        let slopePerWeek = slopePerSecond * 7 * 86_400
        switch slopePerWeek {
        case ..<(-1.0): return ("Improving", Color.success)
        case 1.0...:    return ("Declining", Color.destructive)
        default:        return ("Stable", .secondary)
        }
    }

    private var currentPredictedFinishTime: String {
        predictedFinishSeconds?.durationString ?? "--:--"
    }

    /// Seconds the predicted finish is behind (+) or ahead (−) of the goal, or
    /// `nil` when there is no goal or not enough data to make a prediction. Returning
    /// `nil` (rather than 0) keeps the "On goal pace" state from showing when the
    /// gap is simply unknown.
    private var goalGapSeconds: Double? {
        guard goalFinishSeconds > 0, let predicted = predictedFinishSeconds else { return nil }
        return predicted - goalFinishSeconds
    }

    /// The same paces as Plan's pace insights, from the same VDOT.
    private var trainingPacesForVDOT: TrainingPaces? {
        currentVDOT.map { PaceCalculatorService.trainingPaces(forVDOT: $0) }
    }

    private var improvementTips: [String] {
        guard let snap = snapshot else { return [] }
        var tips: [String] = []

        switch snap.performanceTrend {
        case .improving:
            tips.append("Your fitness is trending up. Consider adding 4–6 strides after easy runs to sharpen leg turnover.")
        case .onTrack:
            tips.append("You're on track. Adding a weekly tempo run will push your lactate threshold higher.")
        case .struggling:
            tips.append("Your recent sessions show signs of fatigue. Prioritise an extra easy day and focus on sleep quality this week.")
        }

        if let fatigue = snap.intervalFatigueRatio, fatigue > 1.15 {
            tips.append("Your heart rate is drifting high late in intervals. Replace one interval day with an easy aerobic run.")
        }

        let weeklyKm = snap.averageWeeklyDistanceMeters / 1_000
        if tips.count < 3, weeklyKm < 25 {
            // In the runner's own unit; 20 mi is the round figure nearest 30 km.
            let unit = appSettings.unitPreference
            let average: Double
            let target: Int
            switch unit {
            case .metric:   average = weeklyKm;              target = 30
            case .imperial: average = weeklyKm / 1.609_344;  target = 20
            }
            tips.append(String(
                format: "Your weekly volume averages %.0f %@. Gradually building to %d+ %@ (10%% per week) will improve your aerobic base.",
                average, unit.distanceLabel, target, unit.distanceLabel
            ))
        }

        if tips.count < 3, snap.recentQualityPaceSecondsPerKm == nil {
            tips.append("No quality sessions detected recently. Adding one tempo or interval workout per week accelerates fitness gains.")
        }

        if tips.count < 3, let gap = goalGapSeconds, gap > 0 {
            let gapMinutes = Int(gap / 60)
            tips.append(String(format: "You're about %d min behind your goal. Weekly threshold workouts are the most effective way to close that gap.", gapMinutes))
        }

        return Array(tips.prefix(3))
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                raceFitnessHeroCard
                    .opacity(appeared ? 1 : 0)
                    .scaleEffect(appeared ? 1 : 0.96, anchor: .top)
                    .adaptiveAnimation(AppAnimation.entrance.delay(0.05), value: appeared)

                predictedRacePaceChart
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 18)
                    .adaptiveAnimation(AppAnimation.entrance.delay(0.10), value: appeared)

                trainingZonesCard
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 18)
                    .adaptiveAnimation(AppAnimation.entrance.delay(0.15), value: appeared)

                performanceMetricsCard
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 18)
                    .adaptiveAnimation(AppAnimation.entrance.delay(0.20), value: appeared)

                improvementTipsCard
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 18)
                    .adaptiveAnimation(AppAnimation.entrance.delay(0.25), value: appeared)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .task { appeared = true }
        }
        .background(Color.surfacePrimary)
    }

    // MARK: - Card 1: Race Fitness Hero

    private var raceFitnessHeroCard: some View {
        let trend = paceTrend
        let raceName = raceDisplayName
        let goalTime = goalFinishSeconds
        let gap = goalGapSeconds

        return VStack(alignment: .leading, spacing: 12) {
            Text("RACE FITNESS")
                .strideEyebrow()
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Predicted \(raceName)")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                    Text(currentPredictedFinishTime)
                        .font(.metricSmall)

                    if goalTime > 0 {
                        HStack(spacing: 4) {
                            Text("Goal:")
                                .font(.captionStrong)
                                .foregroundStyle(.secondary)
                            Text(goalTime.durationString)
                                .font(.captionStrong)
                                .foregroundStyle(.secondary)
                        }
                        // Only show a goal comparison when a prediction exists; a nil
                        // gap means "no data", not "on goal pace".
                        if let gap {
                            if gap > 0 {
                                Text(String(format: "%.0f sec behind goal", gap))
                                    .font(.captionStrong)
                                    .foregroundStyle(.destructive)
                            } else if gap < 0 {
                                Text(String(format: "%.0f sec ahead of goal", -gap))
                                    .font(.captionStrong)
                                    .foregroundStyle(.success)
                            } else {
                                Text("On goal pace")
                                    .font(.captionStrong)
                                    .foregroundStyle(.success)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 4) {
                    Text("Trend")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(trend.color)
                            .frame(width: 8, height: 8)
                        Text(trend.label)
                            .font(.bodyStrong)
                            .foregroundStyle(trend.color)
                    }
                }
            }
        }
        .padding(AppSpacing.lg)
        .strideCard()
    }

    // MARK: - Card 2: Predicted Race Pace Chart

    private var predictedRacePaceChart: some View {
        chartCard("PREDICTED RACE PACE") {
            if pacePredictionPoints.isEmpty {
                emptyDataPlaceholder("Log at least 2 runs of 1.5 km+ to see a prediction.")
            } else {
                Chart {
                    ForEach(pacePredictionPoints) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Predicted Pace", point.predictedPaceSecondsPerKm)
                        )
                        .foregroundStyle(.route)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.catmullRom)
                        PointMark(
                            x: .value("Date", point.date),
                            y: .value("Predicted Pace", point.predictedPaceSecondsPerKm)
                        )
                        .foregroundStyle(Color.brand)
                        .symbolSize(
                            selectedPredictionDate.flatMap { closestPredictionPoint(to: $0) }?.id == point.id ? 80 : 36
                        )
                    }
                    if let selected = selectedPredictionDate,
                       let point = closestPredictionPoint(to: selected) {
                        selectionRule(x: .value("Date", point.date)) {
                            tooltipContainer {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(point.date, format: .dateTime.month(.abbreviated).day())
                                        .font(.dsCaption2).foregroundStyle(.secondary)
                                    Text(point.predictedPaceSecondsPerKm.paceString(unit: appSettings.unitPreference))
                                        .font(.dsCaption).bold()
                                }
                            }
                        }
                    }
                }
                .frame(height: 140)
                // Reversed so a faster pace sits higher and the line climbs as fitness grows.
                .chartYScale(domain: .automatic(includesZero: false, reversed: true))
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let secs = value.as(Double.self) {
                                Text(secs.paceString(unit: appSettings.unitPreference)
                                    .replacingOccurrences(of: " \(appSettings.unitPreference.paceLabel)", with: ""))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
                .chartXSelection(value: $selectedPredictionDate)
                .chartAccessibility("Predicted race pace chart", predictedPaceSeries)
            }
        }
    }

    /// The prediction series' accessible form (N18); built here rather than inline so the
    /// chart body stays one expression. A `Series` rather than a finished summary string,
    /// so the chart is playable as an Audio Graph too (U10).
    private var predictedPaceSeries: ChartAccessibility.Series {
        let unit = appSettings.unitPreference
        return ChartAccessibility.Series(
            points: pacePredictionPoints.map {
                ChartAccessibility.Point(
                    label: $0.date.formatted(.dateTime.month(.abbreviated).day()),
                    value: $0.predictedPaceSecondsPerKm
                )
            },
            valueAxisLabel: String(localized: "Predicted pace", comment: "Chart value axis")
        ) { SpokenMetric.spoken(measurement: $0.paceString(unit: unit)) }
    }

    // MARK: - Card 3: Training Zones

    private var trainingZonesCard: some View {
        chartCard("TRAINING ZONES") {
            if let paces = trainingPacesForVDOT {
                VStack(spacing: 0) {
                    zoneRow(
                        label: "Easy",
                        paceText: "\(paces.easyRange.lowerBound.paceString(unit: appSettings.unitPreference)) – \(paces.easyRange.upperBound.paceString(unit: appSettings.unitPreference))",
                        color: .zoneEasy,
                        icon: .walk
                    )
                    Divider().padding(.leading, AppSpacing.huge)
                    zoneRow(
                        label: "Marathon",
                        paceText: paces.marathon.paceString(unit: appSettings.unitPreference),
                        color: .zoneMarathon,
                        icon: .run
                    )
                    Divider().padding(.leading, AppSpacing.huge)
                    zoneRow(
                        label: "Tempo",
                        paceText: paces.threshold.paceString(unit: appSettings.unitPreference),
                        color: .zoneTempo,
                        icon: .tempo
                    )
                    Divider().padding(.leading, AppSpacing.huge)
                    zoneRow(
                        label: "Interval",
                        paceText: paces.interval.paceString(unit: appSettings.unitPreference),
                        color: .zoneInterval,
                        icon: .bolt
                    )
                    Divider().padding(.leading, AppSpacing.huge)
                    zoneRow(
                        label: "Repetition",
                        paceText: paces.repetition.paceString(unit: appSettings.unitPreference),
                        color: .zoneMax,
                        icon: .flame
                    )
                }
            } else {
                emptyDataPlaceholder("Log quality runs to unlock personalised training zones.")
            }
        }
    }

    private func zoneRow(label: String, paceText: String, color: Color, icon: StrideIconName) -> some View {
        HStack(spacing: 10) {
            StrideIcon(name: icon, size: 18, color: color, strokeWeight: 2.0)
                .frame(width: 22)
            Text(label)
                .font(.bodyStrong)
                .foregroundStyle(.primary)
            Spacer()
            Text(paceText)
                .font(.dsFootnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
        }
        .padding(.vertical, AppSpacing.md)
    }

    // MARK: - Card 4: Performance Metrics

    private var performanceMetricsCard: some View {
        chartCard("PERFORMANCE METRICS") {
            if let snap = snapshot {
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: AppSpacing.md) {
                    // The VDOT the zones and prediction above use, whole like Progress' hero.
                    metricsCell(
                        value: currentVDOT.map { String(format: "%.0f", $0) } ?? "--",
                        label: "VDOT"
                    )
                    metricsCell(
                        value: weeklyVolumeString(meters: snap.averageWeeklyDistanceMeters),
                        label: "Avg Weekly Vol"
                    )
                    if let fatigue = snap.intervalFatigueRatio {
                        metricsCell(
                            value: String(format: "%.2f", fatigue),
                            label: "Interval Fatigue",
                            valueColor: fatigue > 1.15 ? .destructive : .success,
                            // The colour alone is not the verdict.
                            note: fatigue > 1.15 ? "High" : "Normal"
                        )
                    }
                    if let ratio = snap.lastIntervalPaceRatio {
                        metricsCell(
                            value: String(format: "%.0f%%", ratio * 100),
                            label: "vs Interval Target",
                            valueColor: ratio < 1.0 ? .success : (ratio > 1.07 ? .destructive : .primary),
                            note: ratio < 1.0 ? "Faster" : (ratio > 1.07 ? "Slower" : "On target")
                        )
                    }
                }
            } else {
                emptyDataPlaceholder("Log more runs to see performance metrics.")
            }
        }
    }

    private func weeklyVolumeString(meters: Double) -> String {
        switch appSettings.unitPreference {
        case .metric:   return String(format: "%.0f km/wk", meters / 1_000)
        case .imperial: return String(format: "%.0f mi/wk", meters / 1_609.344)
        }
    }

    private func metricsCell(
        value: String,
        label: String,
        valueColor: Color = .primary,
        note: String? = nil
    ) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.dsCallout.weight(.bold).monospacedDigit())
                .foregroundStyle(valueColor)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            if let note {
                Text(note)
                    .font(.dsCaption2.weight(.semibold))
                    .foregroundStyle(valueColor)
            }
            Text(label)
                .font(.dsCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(AppSpacing.md)
        .background(Color.surfaceTertiary, in: RoundedRectangle(cornerRadius: AppRadius.sm))
    }

    // MARK: - Card 5: Improvement Tips

    private var improvementTipsCard: some View {
        let tips = improvementTips
        return VStack(alignment: .leading, spacing: 12) {
            Text("IMPROVEMENT TIPS")
                .strideEyebrow()
                .foregroundStyle(.secondary)

            if tips.isEmpty {
                emptyDataPlaceholder("Log more runs to get personalised tips.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(tips.enumerated()), id: \.offset) { index, tip in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.captionStrong)
                                .foregroundStyle(.onFill)
                                .frame(width: 20, height: 20)
                                .background(Color.brand, in: Circle())
                            Text(tip)
                                .font(.bodyRegular)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(AppSpacing.lg)
        .strideCard()
    }

    // MARK: - Shared helpers (mirrors ProgressDashboardView pattern)

    private func chartCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        // The title sits above the card, as section headers do on every other screen.
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(title)
                .strideEyebrow()
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)
            content()
                .padding(AppSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .strideCard()
        }
    }

    private func emptyDataPlaceholder(_ message: String) -> some View {
        HStack(spacing: 10) {
            StrideIcon(name: .chart, size: 16, color: .secondary, strokeWeight: 1.8)
            Text(message)
                .font(.bodyRegular)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 60)
    }

    private func closestPredictionPoint(to date: Date) -> PacePredictionPoint? {
        pacePredictionPoints.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        })
    }

    @ChartContentBuilder
    private func selectionRule<X: Plottable, Label: View>(
        x: PlottableValue<X>,
        @ViewBuilder label: () -> Label
    ) -> some ChartContent {
        // The selected point is "you are here" on the chart, so the rule is the brand's.
        RuleMark(x: x)
            .foregroundStyle(Color.brand.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4]))
            .annotation(
                position: .top,
                overflowResolution: .init(x: .fit(to: .chart), y: .disabled),
                content: label
            )
    }

    private func tooltipContainer<C: View>(@ViewBuilder content: () -> C) -> some View {
        content()
            .padding(.horizontal, AppSpacing.sm).padding(.vertical, 5)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous).strokeBorder(.cardStroke, lineWidth: 1))
            .appShadow(.e2)
    }
}
