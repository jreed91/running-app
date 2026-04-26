import SwiftUI
import SwiftData

// MARK: - PlanTabView

struct PlanTabView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.appContainer) private var container
    @Environment(\.modelContext) private var context

    @Query(filter: #Predicate<TrainingPlan> { $0.isActive == true })
    private var activePlans: [TrainingPlan]

    @Query private var profiles: [UserProfile]
    @Query(sort: \RunWorkout.date, order: .reverse) private var recentWorkouts: [RunWorkout]

    @State private var showNewPlanSheet = false
    @State private var showRouteGenius = false
    @State private var isAdaptingPlan = false

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
                                unavailableReason: smartAdaptUnavailableReason(for: plan)
                            ) {
                                Task { await adaptRemainingWorkouts(in: plan) }
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
    }

    private func remainingAdaptableWorkouts(in plan: TrainingPlan) -> [ScheduledWorkout] {
        let today = Calendar.current.startOfDay(for: Date())
        return (plan.weeks ?? [])
            .flatMap { $0.workouts ?? [] }
            .filter {
                !$0.isCompleted
                    && $0.workoutType != .rest
                    && $0.workoutType != .crossTraining
                    && $0.scheduledDate >= today
            }
            .sorted { $0.scheduledDate < $1.scheduledDate }
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
        guard !appSettings.aiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Add an AI API key in Settings to adapt your plan."
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
        defer { isAdaptingPlan = false }

        let workoutsToAdapt = uniqueRemainingWorkoutsAfterDeletingSameDayDuplicates(in: plan)
        try? await container.healthKitRepository.removeWorkoutPlans(for: plan)

        for workout in workoutsToAdapt {
            let adapted = await container.adaptedWorkout(
                scheduled: workout,
                history: Array(recentWorkouts.prefix(50)),
                profile: profile,
                provider: appSettings.aiProvider,
                apiKey: appSettings.aiAPIKey,
                modelOverride: appSettings.aiModelOverride,
                unitPreference: appSettings.unitPreference
            )

            workout.workoutType = adapted.workoutType
            workout.workoutStructure = adapted.workoutStructure
            workout.targetDistanceMeters = adapted.targetDistanceMeters
            workout.targetPaceLowerBound = adapted.targetPaceLowerBound
            workout.targetPaceUpperBound = adapted.targetPaceUpperBound
            workout.notes = adapted.notes
            workout.intervals = adapted.intervals
            workout.healthKitPlanID = nil
        }

        try? context.save()
        try? await container.healthKitRepository.syncWorkoutPlans(for: plan)
    }

    @MainActor
    private func uniqueRemainingWorkoutsAfterDeletingSameDayDuplicates(in plan: TrainingPlan) -> [ScheduledWorkout] {
        let calendar = Calendar.current
        var keptWorkouts: [ScheduledWorkout] = []

        for workout in remainingAdaptableWorkouts(in: plan) {
            if keptWorkouts.contains(where: { calendar.isDate($0.scheduledDate, inSameDayAs: workout.scheduledDate) }) {
                context.delete(workout)
            } else {
                keptWorkouts.append(workout)
            }
        }

        return keptWorkouts
    }
}

// MARK: - Smart Adapt Card

private struct SmartAdaptPlanCard: View {
    let workoutCount: Int
    let isAdapting: Bool
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
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.brand.opacity(0.12))
                            .frame(width: 48, height: 48)
                        if isAdapting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.brand)
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(isAdapting ? "Adapting Plan" : "Smart Adapt")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.brand)

                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 8)

                    StrideIcon(name: .chevronRight, size: 12, color: .brand, strokeWeight: 2.4)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.brand.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
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
                    RoundedRectangle(cornerRadius: 14)
                        .fill(
                            LinearGradient(
                                colors: [.brand, .destructive],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 48, height: 48)
                        .shadow(color: Color.brand.opacity(0.35), radius: 10, y: 3)
                    StrideIcon(name: .bolt, size: 22, color: .white, strokeWeight: 2.2)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Route Genius")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.brand)
                    Text("AI-generated route matched to today's distance & elevation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                StrideIcon(name: .chevronRight, size: 12, color: .brand, strokeWeight: 2.4)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(
                        LinearGradient(
                            colors: [Color.brand.opacity(0.10), Color.destructive.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
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
        }
    }

    private var planTitle: String {
        let trimmedName = plan.raceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName?.isEmpty == false ? trimmedName! : plan.targetRace.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header row: race icon + title + goal
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.brand.opacity(0.12))
                        .frame(width: 52, height: 52)
                    StrideIcon(name: raceStrideIcon, size: 26, color: .brand, strokeWeight: 2.0)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(planTitle)
                        .font(.system(size: 20, weight: .bold))
                    Text("Goal \(plan.goalTimeSeconds.durationString)  ·  \(plan.totalWeeks) weeks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(plan.progress * 100))%")
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
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
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
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
        guard !weeks.isEmpty else { return [] }
        let total = CGFloat(weeks.count)
        var transitions: [CGFloat] = []
        let ordered: [TrainingPhase] = [.base, .build, .peak]
        for phase in ordered {
            let through = weeks.filter { orderIndex(of: $0.phase) <= orderIndex(of: phase) }.count
            let fraction = CGFloat(through) / total
            if fraction > 0, fraction < 1 { transitions.append(fraction) }
        }
        return transitions
    }

    private func orderIndex(of phase: TrainingPhase) -> Int {
        switch phase {
        case .base:  return 0
        case .build: return 1
        case .peak:  return 2
        case .taper: return 3
        }
    }

    private var currentPhase: TrainingPhase {
        plan.currentWeek?.phase ?? weeks.first?.phase ?? .base
    }

    var body: some View {
        VStack(spacing: 6) {
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
                        .shadow(color: Color.brand.opacity(0.55), radius: 6)

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
                    Text(phase.displayName.uppercased())
                        .font(.system(size: 11, weight: phase == currentPhase ? .bold : .semibold))
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
            distanceMeters: plan.targetRace.distanceMeters,
            timeSeconds: plan.goalTimeSeconds
        )
    }

    private var estimatedTime: TimeInterval {
        PaceCalculatorService.predictedTime(vdot: currentVDOT, distanceMeters: plan.targetRace.distanceMeters)
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
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
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
            RoundedRectangle(cornerRadius: 2)
                .fill(zone.color)
                .frame(width: 3, height: 22)

            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)

            Spacer()

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
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
    @State private var isExpanded = false

    private var isCurrentWeek: Bool { week.id == currentWeekID }
    private var isFutureWeek: Bool { week.startDate > Date() && !week.isCompleted }

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
                            Text(week.phase.displayName)
                                .font(.bodyRegular)
                                .foregroundStyle(.secondary)
                            if isCurrentWeek {
                                Text("CURRENT")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.brand.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.brand)
                            } else if week.isCompleted {
                                Text("DONE")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
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
                ForEach((week.workouts ?? []).sorted { $0.scheduledDate < $1.scheduledDate }) { workout in
                    PlanWorkoutSummaryRow(workout: workout)
                    Divider().padding(.leading, 44)
                }
            }
        }
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
        .opacity(isFutureWeek ? 0.65 : 1.0)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if week.isCompleted {
            ZStack {
                Circle().fill(Color.success).frame(width: 24, height: 24)
                StrideIcon(name: .check, size: 12, color: .white, strokeWeight: 3)
            }
        } else if isCurrentWeek {
            ZStack {
                Circle().fill(Color.brand).frame(width: 24, height: 24)
                Circle().fill(Color.white).frame(width: 8, height: 8)
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
            .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 1) {
                Text(workout.workoutType.displayName)
                    .font(.bodyRegular)
                Text(workout.scheduledDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let dist = workout.targetDistanceMeters {
                Text(dist.distanceString(unit: appSettings.unitPreference))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
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
        .padding(.vertical, 8)
        .padding(.trailing)
    }

}
