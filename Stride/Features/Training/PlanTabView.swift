import SwiftUI
import SwiftData

// MARK: - PlanTabView

struct PlanTabView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(AppContainer.self) private var container
    @Environment(\.modelContext) private var context

    @Query(filter: #Predicate<TrainingPlan> { $0.isActive == true })
    private var activePlans: [TrainingPlan]

    @Query private var profiles: [UserProfile]
    @Query(sort: \RunWorkout.date, order: .reverse) private var recentWorkouts: [RunWorkout]

    @State private var showNewPlanSheet = false
    @State private var showRouteGenius = false
    @State private var isAdaptingPlan = false
    @State private var smartAdaptProgress = SmartAdaptProgress.idle
    @State private var smartAdaptStreamBuffer = ""
    @State private var adaptTask: Task<Void, Never>?

    private var activePlan: TrainingPlan? { activePlans.first }

    var body: some View {
        NavigationStack {
            Group {
                if let plan = activePlan {
                    ScrollView {
                        VStack(spacing: 20) {
                            PlanOverviewCard(plan: plan)

                            SmartAdaptPlanCard(
                                workoutCount: remainingAdaptableWorkouts(in: plan).count,
                                isAdapting: isAdaptingPlan,
                                progress: smartAdaptProgress,
                                unavailableReason: smartAdaptUnavailableReason(for: plan)
                            ) {
                                adaptTask?.cancel()
                                adaptTask = Task { await adaptRemainingWorkouts(in: plan) }
                            }

                            RouteGeniusCard {
                                showRouteGenius = true
                            }

                            Text("PACE INSIGHTS")
                                .font(.sectionHeader)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            PaceInsightsCard(plan: plan)

                            Text("TRAINING WEEKS")
                                .font(.sectionHeader)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            LazyVStack(spacing: 10) {
                                ForEach((plan.weeks ?? []).sorted { $0.weekNumber < $1.weekNumber }) { week in
                                    PlanWeekSummaryRow(
                                        week: week,
                                        currentWeekID: plan.currentWeek?.id
                                    )
                                }
                            }
                        }
                        .padding()
                    }
                } else {
                    ContentUnavailableView(
                        "No Active Plan",
                        systemImage: "calendar.badge.plus",
                        description: Text("Tap + to generate a personalised training plan.")
                    )
                }
            }
            .navigationTitle("My Plan")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        TrainingPlanListView()
                    } label: {
                        Label("Plan History", systemImage: "clock.arrow.circlepath")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showNewPlanSheet = true } label: {
                        Label("New Plan", systemImage: "plus")
                    }
                    .disabled(profiles.isEmpty)
                }
            }
            .sheet(isPresented: $showNewPlanSheet) {
                NewPlanOnboardingView()
            }
            .sheet(isPresented: $showRouteGenius) {
                RouteGeniusView(
                    viewModel: container.makeRouteGeniusViewModel(appSettings: appSettings)
                )
            }
        }
        .onDisappear {
            // Stop adapting if the user leaves the tab so the fire-and-forget task
            // can't keep mutating and re-syncing a plan that's no longer on screen
            // (or has since been deleted) (M37).
            adaptTask?.cancel()
        }
    }

    /// A plan is safe to keep mutating only while it's still live in the store and
    /// active. Once deleted its `modelContext` is nil and touching relationships
    /// would trap; once deactivated the adaptation is stale.
    private func isPlanAdaptable(_ plan: TrainingPlan) -> Bool {
        plan.modelContext != nil && plan.isActive
    }

    private func remainingAdaptableWorkouts(in plan: TrainingPlan) -> [ScheduledWorkout] {
        AdaptableWorkoutSelector.adaptableWorkouts(in: plan)
    }

    private func smartAdaptUnavailableReason(for plan: TrainingPlan) -> String? {
        guard !remainingAdaptableWorkouts(in: plan).isEmpty else {
            return "No remaining run workouts are available to adapt."
        }
        guard !profiles.isEmpty else {
            return "Create a runner profile before adapting your plan."
        }
        guard appSettings.aiInsightsEnabled else {
            return "Turn on AI Coach in Settings to adapt your plan."
        }
        return nil
    }

    @MainActor
    private func adaptRemainingWorkouts(in plan: TrainingPlan) async {
        guard !isAdaptingPlan,
              smartAdaptUnavailableReason(for: plan) == nil,
              let profile = profiles.first else {
            return
        }

        isAdaptingPlan = true
        smartAdaptProgress = .starting
        smartAdaptStreamBuffer = ""
        defer {
            isAdaptingPlan = false
            smartAdaptProgress.finishIfNeeded()
            smartAdaptStreamBuffer = ""
        }

        // Smart Adapt no longer prunes the plan first (N29). The pruning existed to
        // clean up phantom workouts that H1/H10 auto-inserted by relating an unmanaged
        // model to a persisted week; those producers are gone, so all it could still do
        // was delete real sessions during an ordinary AI operation. A day that genuinely
        // holds two sessions now simply shows both (N12).
        let workoutsToAdapt = remainingAdaptableWorkouts(in: plan)
        smartAdaptProgress = SmartAdaptProgress(
            currentMessage: "Preparing \(workoutsToAdapt.count) workout\(workoutsToAdapt.count == 1 ? "" : "s") for adaptation.",
            completedCount: 0,
            totalCount: workoutsToAdapt.count,
            updates: []
        )
        context.saveOrLog("the plan before Smart Adapt")
        try? await container.healthKitRepository.removeWorkoutPlans(for: plan)

        smartAdaptProgress.currentMessage = "Streaming coach response..."
        let adaptedByID = await container.adaptedWorkouts(
            scheduled: workoutsToAdapt,
            history: Array(recentWorkouts.prefix(50)),
            profile: profile,
            provider: appSettings.aiProvider,
            unitPreference: appSettings.unitPreference,
            onChunk: { chunk in
                Task { @MainActor in
                    appendSmartAdaptSummaryChunk(chunk)
                }
            }
        )

        // The streaming call can take many seconds; bail out if the user left the
        // tab or the plan was deleted/replaced meanwhile rather than writing stale
        // adaptations back into the store (M37).
        guard !Task.isCancelled, isPlanAdaptable(plan) else { return }

        guard !adaptedByID.isEmpty else {
            smartAdaptProgress.currentMessage = "The coach response could not be applied. Make sure Apple Intelligence is enabled on this device, then try again."
            return
        }

        for (index, workout) in workoutsToAdapt.enumerated() {
            guard !Task.isCancelled, isPlanAdaptable(plan) else { break }
            guard let adapted = adaptedByID[workout.id] else {
                smartAdaptProgress.updates.insert(
                    SmartAdaptProgress.Update(
                        title: workoutLabel(workout),
                        message: "No adaptation was returned for this workout, so it was left unchanged."
                    ),
                    at: 0
                )
                smartAdaptProgress.completedCount = index + 1
                continue
            }

            workout.applyAdaptation(from: adapted)

            let response = adapted.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
            smartAdaptProgress.completedCount = index + 1
            if let r = response, !r.isEmpty {
                smartAdaptProgress.currentMessage = r
            } else {
                smartAdaptProgress.currentMessage = "Updated \(workoutLabel(workout))."
            }
            smartAdaptProgress.updates.insert(
                SmartAdaptProgress.Update(
                    title: workoutLabel(workout),
                    message: smartAdaptProgress.currentMessage
                ),
                at: 0
            )
            smartAdaptProgress.updates = Array(smartAdaptProgress.updates.prefix(4))
            context.saveOrLog("a Smart Adapt workout update")
        }

        guard !Task.isCancelled, isPlanAdaptable(plan) else { return }
        try? await container.healthKitRepository.syncWorkoutPlans(for: plan, unitPreference: appSettings.unitPreference)
        smartAdaptProgress.currentMessage = "Plan updated and synced."
    }

    @MainActor
    private func appendSmartAdaptSummaryChunk(_ chunk: String) {
        smartAdaptStreamBuffer += chunk
        let summaries = SmartAdaptSummaryStream.summaries(in: smartAdaptStreamBuffer)
        guard !summaries.isEmpty else {
            smartAdaptProgress.currentMessage = "Reading coach summary..."
            return
        }

        smartAdaptProgress.streamingSummaries = Array(summaries.prefix(SmartAdaptSummaryStream.displayLimit))
        smartAdaptProgress.currentMessage = summaries.last ?? "Reviewing plan changes..."
    }

    private func workoutLabel(_ workout: ScheduledWorkout) -> String {
        "\(workout.workoutType.localizedName) on \(workout.scheduledDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))"
    }
}

// MARK: - Smart Adapt Card

private struct SmartAdaptProgress: Equatable {
    struct Update: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    var currentMessage: String
    var completedCount: Int
    var totalCount: Int
    var updates: [Update]
    var streamingSummaries: [String] = []

    static let idle = SmartAdaptProgress(currentMessage: "", completedCount: 0, totalCount: 0, updates: [])
    static let starting = SmartAdaptProgress(currentMessage: "Preparing plan...", completedCount: 0, totalCount: 0, updates: [])

    var fractionCompleted: Double? {
        guard totalCount > 0 else { return nil }
        return Double(completedCount) / Double(totalCount)
    }

    mutating func finishIfNeeded() {
        guard totalCount > 0 else {
            self = .idle
            return
        }
        if completedCount >= totalCount {
            currentMessage = "Plan updated."
        }
    }
}

private struct SmartAdaptPlanCard: View {
    let workoutCount: Int
    let isAdapting: Bool
    let progress: SmartAdaptProgress
    let unavailableReason: String?
    let action: () -> Void

    private var isEnabled: Bool {
        workoutCount > 0 && unavailableReason == nil && !isAdapting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: action) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: AppRadius.md)
                            .fill(Color.brand.opacity(0.12))
                            .frame(width: 48, height: 48)
                        if isAdapting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.dsTitle3)
                                .foregroundStyle(.brand)
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(isAdapting ? "Adapting Plan" : "Smart Adapt")
                            .font(.dsHeadline.weight(.bold))
                            .foregroundStyle(.brand)

                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 8)

                    StrideIcon(name: .chevronRight, size: 12, color: .brand, strokeWeight: 2.4)
                }
                .padding(AppSpacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.lg)
                        .fill(Color.brand.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.lg)
                                .strokeBorder(Color.brand.opacity(0.2), lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.55)

            if let unavailableReason {
                Text(unavailableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isAdapting {
                VStack(alignment: .leading, spacing: 8) {
                    if let value = progress.fractionCompleted {
                        ProgressView(value: value)
                            .tint(.brand)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Text(progress.currentMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !progress.streamingSummaries.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Live summary")
                                .font(.captionStrong)
                                .foregroundStyle(.primary)

                            ForEach(progress.streamingSummaries, id: \.self) { summary in
                                HStack(alignment: .top, spacing: 6) {
                                    Circle()
                                        .fill(Color.brand)
                                        .frame(width: 5, height: 5)
                                        .padding(.top, 6)
                                    Text(summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.sm))
                    }

                    ForEach(progress.updates) { update in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(update.title)
                                .font(.captionStrong)
                                .foregroundStyle(.primary)
                            Text(update.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.sm))
                    }
                }
                .padding(.top, AppSpacing.xs)
            }
        }
    }

    private var subtitle: String {
        guard workoutCount > 0 else {
            return "No remaining run workouts are available."
        }

        let workoutLabel = workoutCount == 1 ? "workout" : "workouts"
        return "Adapt the remaining \(workoutCount) \(workoutLabel) in this plan."
    }
}

// MARK: - Route Genius Card

private struct RouteGeniusCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .fill(
                            LinearGradient(
                                colors: [.brand, .destructive],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 48, height: 48)
                        .appGlow(.standard, color: .brand)
                    StrideIcon(name: .bolt, size: 22, color: .white, strokeWeight: 2.2)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Route Genius")
                        .font(.dsHeadline.weight(.bold))
                        .foregroundStyle(.brand)
                    Text("AI-generated route matched to today's distance & elevation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                StrideIcon(name: .chevronRight, size: 12, color: .brand, strokeWeight: 2.4)
            }
            .padding(AppSpacing.lg)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(
                        LinearGradient(
                            colors: [Color.brand.opacity(0.10), Color.destructive.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.lg)
                            .strokeBorder(Color.brand.opacity(0.2), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Plan Overview Card

private struct PlanOverviewCard: View {
    let plan: TrainingPlan
    @Environment(AppSettings.self) private var appSettings

    private var weeksCompleted: Int {
        (plan.weeks ?? []).filter(\.isCompleted).count
    }

    private var totalCompletedDistanceKm: Double {
        (plan.weeks ?? []).reduce(0) { $0 + $1.completedDistanceKm }
    }

    private var raceStrideIcon: StrideIconName {
        switch plan.targetRace {
        case .maintainFitness: return .heart
        case .fiveK: return .bolt
        case .halfMarathon: return .tempo
        case .marathon: return .run
        case .custom: return .ruler
        }
    }

    private var planTitle: String {
        if let name = plan.raceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return plan.targetRace.localizedName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header row: race icon + title + goal
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .fill(Color.brand.opacity(0.12))
                        .frame(width: 52, height: 52)
                    StrideIcon(name: raceStrideIcon, size: 26, color: .brand, strokeWeight: 2.0)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(planTitle)
                        .font(.dsTitle3.weight(.bold))
                    Text("Goal \(plan.goalTimeSeconds.durationString)  ·  \(plan.totalWeeks) weeks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(plan.progress * 100))%")
                    .font(.dsTitle2.monospaced())
                    .foregroundStyle(.brand)
            }

            // Phase progress bar with Base / Build / Peak / Taper labels
            PhaseProgressBar(plan: plan)

            Divider()

            HStack {
                OverviewStat(
                    value: "\(weeksCompleted)/\(plan.totalWeeks)",
                    label: "Weeks Done"
                )
                Divider().frame(height: 36)
                OverviewStat(
                    value: totalCompletedDistanceKm.distanceStringFromKm(unit: appSettings.unitPreference),
                    label: "Completed"
                )
                Divider().frame(height: 36)
                OverviewStat(
                    value: plan.startDate.formatted(.dateTime.month(.abbreviated).day()),
                    label: "Started"
                )
            }
        }
        .padding()
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}

// MARK: - Phase Progress Math

/// Pure, unit-testable math backing `PhaseProgressBar`'s divider markers.
enum PhaseProgressMath {

    /// Cumulative phase-transition fractions (0–1, exclusive) for a plan's ordered
    /// per-week phases. Deduplicated so a zero-week phase can't emit a duplicate
    /// marker — duplicate values would collide as `ForEach(id: \.self)` identities.
    static func transitionFractions(weekPhases: [TrainingPhase]) -> [CGFloat] {
        guard !weekPhases.isEmpty else { return [] }
        let total = CGFloat(weekPhases.count)
        let ordered: [TrainingPhase] = [.base, .build, .peak]
        var fractions: [CGFloat] = []
        var seen: Set<CGFloat> = []
        for phase in ordered {
            let through = weekPhases.filter { orderIndex(of: $0) <= orderIndex(of: phase) }.count
            let fraction = CGFloat(through) / total
            if fraction > 0, fraction < 1, seen.insert(fraction).inserted {
                fractions.append(fraction)
            }
        }
        return fractions
    }

    static func orderIndex(of phase: TrainingPhase) -> Int {
        switch phase {
        case .base:  return 0
        case .build: return 1
        case .peak:  return 2
        case .taper: return 3
        }
    }
}

// MARK: - Phase Progress Bar

private struct PhaseProgressBar: View {
    let plan: TrainingPlan

    private var weeks: [TrainingWeek] {
        (plan.weeks ?? []).sorted { $0.weekNumber < $1.weekNumber }
    }

    /// Cumulative fraction (0–1) at which each phase transition occurs.
    /// Returns up to three fractions for Base→Build, Build→Peak, Peak→Taper.
    private var phaseTransitions: [CGFloat] {
        PhaseProgressMath.transitionFractions(weekPhases: weeks.map(\.phase))
    }

    private var currentPhase: TrainingPhase {
        plan.currentWeek?.phase ?? weeks.first?.phase ?? .base
    }

    var body: some View {
        VStack(spacing: 6) {
            // `GeometryReader` stays here deliberately (U7). The phase ticks are offsets and
            // could move to `visualEffect`, but the fill needs a measured width, so the reader
            // would remain either way — and the ticks have to be positioned in the same
            // coordinate space as the fill they mark.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.16))
                        .frame(height: 10)

                    Capsule()
                        .fill(Color.brand)
                        .frame(
                            width: max(geo.size.width * CGFloat(plan.progress), plan.progress > 0 ? 6 : 0),
                            height: 10
                        )
                        .appGlow(.halo, color: .brand)

                    ForEach(phaseTransitions, id: \.self) { p in
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(width: 1, height: 10)
                            .offset(x: geo.size.width * p)
                    }
                }
            }
            .frame(height: 10)

            HStack {
                ForEach([TrainingPhase.base, .build, .peak, .taper], id: \.self) { phase in
                    Text(phase.localizedName.uppercased())
                        .font(.dsCaption2.weight(phase == currentPhase ? .bold : .semibold))
                        .kerning(0.8)
                        .foregroundStyle(phase == currentPhase ? Color.brand : Color.secondary.opacity(0.55))
                    if phase != .taper { Spacer() }
                }
            }
        }
    }
}

// MARK: - Overview Stat

private struct OverviewStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.bodyStrong)
                .minimumScaleFactor(0.8)
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Pace Insights Card

private struct PaceInsightsCard: View {
    let plan: TrainingPlan
    @Environment(AppSettings.self) private var appSettings

    private var completedRuns: [RunWorkout] {
        (plan.weeks ?? [])
            .flatMap { $0.workouts ?? [] }
            .compactMap(\.completedWorkout)
            .filter { $0.distanceMeters >= 3_000 }
    }

    private var currentVDOT: Double {
        if let best = completedRuns.max(by: {
            PaceCalculatorService.vdot(distanceMeters: $0.distanceMeters, timeSeconds: $0.durationSeconds) <
            PaceCalculatorService.vdot(distanceMeters: $1.distanceMeters, timeSeconds: $1.durationSeconds)
        }) {
            return PaceCalculatorService.vdot(
                distanceMeters: best.distanceMeters,
                timeSeconds: best.durationSeconds
            )
        }
        return PaceCalculatorService.vdot(
            distanceMeters: plan.effectiveRaceDistanceMeters,
            timeSeconds: plan.goalTimeSeconds
        )
    }

    private var estimatedTime: TimeInterval {
        PaceCalculatorService.predictedTime(vdot: currentVDOT, distanceMeters: plan.effectiveRaceDistanceMeters)
    }

    private var trainingPaces: TrainingPaces {
        PaceCalculatorService.trainingPaces(forVDOT: currentVDOT)
    }

    private var timeDiff: TimeInterval { estimatedTime - plan.goalTimeSeconds }

    private var statusColor: Color {
        if abs(timeDiff) < 30 { return .brand }
        return timeDiff > 0 ? .warning : .success
    }

    private var statusText: String {
        if abs(timeDiff) < 30 { return "On track for goal" }
        let formatted = abs(timeDiff).durationString
        return timeDiff > 0 ? "\(formatted) behind goal" : "\(formatted) ahead of goal"
    }

    @ViewBuilder
    private var statusIconView: some View {
        if timeDiff > 0 && abs(timeDiff) >= 30 {
            StrideIcon(name: .flag, size: 14, color: statusColor, strokeWeight: 2)
        } else {
            ZStack {
                Circle().fill(statusColor).frame(width: 16, height: 16)
                StrideIcon(name: .check, size: 8, color: .white, strokeWeight: 2.5)
            }
        }
    }

    /// Whether the computed VDOT falls within a realistic human range (~20–85).
    /// Outside this range the goal time stored on the plan is unreliable and
    /// training paces should not be shown.
    private var isVDOTReliable: Bool {
        (20...85).contains(currentVDOT)
    }

    private func paceRangeString(_ range: ClosedRange<Double>) -> String {
        "\(stripUnit(range.lowerBound)) – \(stripUnit(range.upperBound))"
    }

    private func paceString(_ secs: Double) -> String {
        stripUnit(secs)
    }

    private func stripUnit(_ secs: Double) -> String {
        guard secs > 0 && secs.isFinite else { return "--:--" }
        return secs.paceString(unit: appSettings.unitPreference)
            .replacingOccurrences(of: " \(appSettings.unitPreference.paceLabel)", with: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Estimated Finish")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(isVDOTReliable ? estimatedTime.durationString : "--:--")
                        .font(.metricSmall)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Goal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(plan.goalTimeSeconds.durationString)
                        .font(.bodyStrong)
                }
            }

            HStack(spacing: 6) {
                if isVDOTReliable {
                    statusIconView
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                    if completedRuns.isEmpty {
                        Text("· Based on goal time")
                            .font(.caption)
                            .foregroundStyle(Color.secondary.opacity(0.6))
                    }
                } else {
                    StrideIcon(name: .chart, size: 14, color: .secondary, strokeWeight: 1.8)
                    Text(completedRuns.isEmpty ? "Log a run to calibrate paces" : "Analyzing current pace…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(spacing: 12) {
                if isVDOTReliable {
                    PaceRow(label: "Easy",       zone: .easy,
                            value: paceRangeString(trainingPaces.easyRange))
                    PaceRow(label: "Marathon",   zone: .marathon,
                            value: paceString(trainingPaces.marathon))
                    PaceRow(label: "Tempo",      zone: .tempo,
                            value: paceString(trainingPaces.threshold))
                    PaceRow(label: "Interval",   zone: .interval,
                            value: paceString(trainingPaces.interval))
                    PaceRow(label: "Repetition", zone: .maxEffort,
                            value: paceString(trainingPaces.repetition))
                } else {
                    Text("Analyzing current pace…")
                        .font(.bodyRegular)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding()
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}

// MARK: - Pace Row

private struct PaceRow: View {
    let label: String
    let zone: PaceZone
    let value: String
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: AppRadius.micro)
                .fill(zone.color)
                .frame(width: 3, height: 22)

            Text(label)
                .font(.dsSubhead.weight(.medium))
                .foregroundStyle(.primary)

            Spacer()

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.dsSubhead.weight(.semibold).monospaced())
                Text(appSettings.unitPreference.paceLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Plan Week Summary Row

private struct PlanWeekSummaryRow: View {
    let week: TrainingWeek
    let currentWeekID: UUID?
    @Environment(AppSettings.self) private var appSettings
    @Environment(AppContainer.self) private var container
    @Environment(\.modelContext) private var context
    @State private var isExpanded = false

    private var isCurrentWeek: Bool { week.id == currentWeekID }
    private var isFutureWeek: Bool { week.startDate > Date() && !week.isCompleted }

    /// The week's sessions in the order the rows are drawn, which is also the order the
    /// reorder container reports drop offsets against.
    private var orderedWorkouts: [ScheduledWorkout] {
        (week.workouts ?? []).sorted { lhs, rhs in
            if lhs.scheduledDate != rhs.scheduledDate { return lhs.scheduledDate < rhs.scheduledDate }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// A race date the runner has committed to pins race day; an estimated one does not.
    private var hasFixedRaceDate: Bool { week.plan?.raceDate != nil }

    private var canReorder: Bool {
        WorkoutReorderPlanner.isReorderable(orderedWorkouts, hasFixedRaceDate: hasFixedRaceDate)
    }

    private var totalWorkouts: Int {
        (week.workouts ?? []).filter { $0.workoutType != .rest }.count
    }

    private var completedWorkouts: Int {
        (week.workouts ?? []).filter { $0.workoutType != .rest && $0.isCompleted }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 14) {
                    statusIcon

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Week \(week.weekNumber)")
                                .font(isCurrentWeek ? .bodyStrong : .bodyRegular)
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(week.phase.localizedName)
                                .font(.bodyRegular)
                                .foregroundStyle(.secondary)
                            if isCurrentWeek {
                                Text("CURRENT")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, AppSpacing.xxs)
                                    .background(.brand.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.brand)
                            } else if week.isCompleted {
                                Text("DONE")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, AppSpacing.xxs)
                                    .background(.success.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.success)
                            }
                        }

                        HStack(spacing: 4) {
                            Text("\(completedWorkouts)/\(totalWorkouts) workouts")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            distanceLabel
                        }
                    }

                    Spacer()

                    StrideIcon(name: .chevronDown, size: 12, color: .secondary, strokeWeight: 2)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                }
                .padding()
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                ForEach(orderedWorkouts) { workout in
                    PlanWorkoutSummaryRow(workout: workout)
                        // The divider used to be this `ForEach`'s second child. Inside a
                        // reorder container that makes it part of the item, so it would
                        // lift with the row and leave a gap behind. As a bottom overlay it
                        // draws in the same place and belongs to the row's frame.
                        .overlay(alignment: .bottom) {
                            Divider().padding(.leading, 44)
                        }
                }
                .reorderable()
            }
        }
        // Drag a session onto another day (U7). This sits directly on the stack that holds
        // the rows rather than after the chrome below it, because it is the modifier that
        // marks a view as the reorderable container.
        //
        // A week whose sessions are all completed or all in the past has nothing to
        // rearrange, and `isEnabled` is what keeps the lift gesture off those rows rather
        // than a guard that fires after the drop.
        .reorderContainer(for: ScheduledWorkout.self, itemID: \.id, isEnabled: canReorder) { difference in
            reschedule(difference)
        }
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))
        .opacity(isFutureWeek ? 0.65 : 1.0)
    }

    /// Applies a drop by rewriting `scheduledDate`s — see `WorkoutReorderPlanner` for why
    /// that is the only thing a reorder can mean in a plan.
    ///
    /// `@MainActor` is explicit rather than inherited: this touches the model context and
    /// hands a `TrainingPlan` to an async call, and a `ScheduledWorkout` is not `Sendable`,
    /// so under `SWIFT_STRICT_CONCURRENCY: complete` a nonisolated method here would read
    /// as sending model objects out of the main actor's region.
    @MainActor
    private func reschedule(
        _ difference: ReorderDifference<UUID, ReorderableSingleCollectionIdentifier>
    ) {
        let workouts = orderedWorkouts
        // Resolved against the same array the rows were built from. `nil` means the
        // container named a row this week does not hold, and an unplaceable drop leaves
        // the week alone rather than guessing at one end of it.
        guard let offset = dropOffset(difference.destination, in: workouts) else { return }

        let changes = WorkoutReorderPlanner.plan(
            slots: WorkoutReorderPlanner.slots(for: workouts, hasFixedRaceDate: hasFixedRaceDate),
            moving: Array(difference.sources),
            toOffset: offset
        )
        guard !changes.isEmpty else { return }

        withAnimation(AppAnimation.snappy) {
            for workout in workouts {
                if let newDate = changes[workout.id] {
                    workout.scheduledDate = newDate
                }
            }
        }

        do {
            try context.save()
        } catch {
            // Roll the dates back rather than leave the week showing an order the store
            // rejected — the next fetch would undo it anyway, with no explanation.
            context.rollback()
            AppLogger.log("Reordered week failed to save: \(error)", label: "Plan", level: .error)
            return
        }

        // The 8 AM reminders are addressed to dates, so two of them now point at the wrong
        // sessions. `scheduleMorningReminders` cancels and rebuilds the whole set, so it is
        // safe to call for a two-day swap.
        if let plan = week.plan, plan.isActive {
            Task { @MainActor in
                await container.notificationService.scheduleMorningReminders(for: plan)
            }
        }
    }

    /// Turns a `ReorderDifference.Destination` into the insertion offset
    /// `WorkoutReorderPlanner.plan(slots:moving:toOffset:)` wants.
    ///
    /// The destination is a *position relative to a row*, not a number: `.before(id)`
    /// names the row the lifted sessions were dropped above, and `.end` means past the
    /// last one. The planner counts rendered rows in date order, so `.before` resolves to
    /// that row's own index — an insertion offset into the pre-move array, which is the
    /// same convention the classic `onMove(perform:)` destination used, and what
    /// `plan`'s `ordered.prefix(offset)` is written against.
    private func dropOffset(
        _ destination: ReorderDifference<UUID, ReorderableSingleCollectionIdentifier>.Destination,
        in workouts: [ScheduledWorkout]
    ) -> Int? {
        switch destination {
        case .before(let id):
            return workouts.firstIndex { $0.id == id }
        case .end:
            return workouts.count
        @unknown default:
            // A position this build does not know how to place is a no-op rather than a
            // guess: dropping a session onto an unrecognised target must not silently
            // rewrite a day.
            return nil
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if week.isCompleted {
            ZStack {
                Circle().fill(Color.success).frame(width: 24, height: 24)
                StrideIcon(name: .check, size: 12, color: .onFill, strokeWeight: 3)
            }
        } else if isCurrentWeek {
            ZStack {
                Circle().fill(Color.brand).frame(width: 24, height: 24)
                Circle().fill(Color.onFill).frame(width: 8, height: 8)
            }
        } else {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 2)
                .frame(width: 24, height: 24)
        }
    }

    @ViewBuilder
    private var distanceLabel: some View {
        if week.isCompleted {
            Text(week.completedDistanceKm.distanceStringFromKm(unit: appSettings.unitPreference))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if isCurrentWeek {
            HStack(spacing: 2) {
                Text(week.completedDistanceKm.distanceStringFromKm(unit: appSettings.unitPreference))
                    .foregroundStyle(.secondary)
                Text("/ \(week.targetDistanceKm.distanceStringFromKm(unit: appSettings.unitPreference))")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
        } else {
            Text("\(week.targetDistanceKm.distanceStringFromKm(unit: appSettings.unitPreference)) target")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Plan Workout Summary Row

private struct PlanWorkoutSummaryRow: View {
    let workout: ScheduledWorkout
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(workout.workoutType.color.opacity(0.15))
                    .frame(width: 32, height: 32)
                StrideIcon(name: workout.workoutType.strideIcon, size: 15,
                           color: workout.workoutType.color, strokeWeight: 1.8)
            }
            .padding(.leading, AppSpacing.xs)

            VStack(alignment: .leading, spacing: 1) {
                Text(workout.workoutType.localizedName)
                    .font(.bodyRegular)
                Text(workout.scheduledDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let dist = workout.targetDistanceMeters {
                Text(dist.distanceString(unit: appSettings.unitPreference))
                    .font(.dsCaption.weight(.medium).monospaced())
                    .foregroundStyle(.secondary)
            }

            if workout.isCompleted {
                ZStack {
                    Circle()
                        .fill(Color.success)
                        .frame(width: 18, height: 18)
                    StrideIcon(name: .check, size: 9, color: .white, strokeWeight: 3)
                }
            }
        }
        .padding(.vertical, AppSpacing.sm)
        .padding(.trailing)
    }

}
