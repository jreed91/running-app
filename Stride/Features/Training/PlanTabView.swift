import SwiftUI
import SwiftData

// MARK: - PlanTabView

struct PlanTabView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(AppContainer.self) private var container
    /// Read here, outside the split view, whose columns are compact even when the window
    /// is wide.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var context

    @Query(filter: #Predicate<TrainingPlan> { $0.isActive == true })
    private var activePlans: [TrainingPlan]

    @Query private var profiles: [UserProfile]
    /// Newest runs first, walks excluded — this feeds Smart Adapt and the pace insights,
    /// both of which read it as training history (N38).
    @Query(RunWorkout.runsOnlyDescriptor()) private var recentWorkouts: [RunWorkout]

    @State private var showNewPlanSheet = false
    @State private var showPregnancyPlanSheet = false
    @State private var isAdaptingPlan = false
    @State private var smartAdaptProgress = SmartAdaptProgress.idle
    @State private var adaptTask: Task<Void, Never>?
    /// The session a week row's tap opens. One destination for the whole tab rather than a
    /// `NavigationLink` per row: a link inside the reorder container would claim the drag.
    @State private var selectedWorkout: ScheduledWorkout?
    /// The plan's other pages, when one is open in the detail column. In a stack they are
    /// ordinary pushes and this stays nil.
    @State private var openPage: PlanPage?
    /// The tab's width and, on iPhone Duo, where its fold is.
    @State private var space = PlanSpace()

    private enum PlanPage: Hashable {
        case raceDay, paceInsights, raceInsights, planHistory
    }

    private struct PlanSpace: Equatable {
        var width: CGFloat = 0
        /// The leading edge of a fold running top to bottom, inactive ones included.
        var foldMinX: CGFloat?
    }

    /// The plan on one side and a session on the other: iPhone Duo open in landscape. It
    /// takes regular width *and* room for two phone-width columns, by the same rule as
    /// `StrideColumns`, so the Duo in portrait keeps the push it has on every other iPhone
    /// rather than squeezing the plan into a sidebar.
    private var showsDetailColumn: Bool {
        horizontalSizeClass == .regular
            && activePlan != nil
            && space.width >= StrideColumnsLayout.minimumColumnWidth * 2
    }

    /// The plan column's width: up to the fold, so each column has one side of it, or
    /// half the width without one.
    private var planColumnWidth: CGFloat {
        let minimum = StrideColumnsLayout.minimumColumnWidth
        let width = space.foldMinX ?? space.width / 2
        return min(max(width, minimum), space.width - minimum)
    }

    private var activePlan: TrainingPlan? { activePlans.first }

    private func raceDayPlan(for plan: TrainingPlan) -> RaceDayPlan? {
        RaceDayPlan.resolve(profile: profiles.first, plan: plan, runs: recentWorkouts)
    }

    private func sectionEyebrow(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .strideEyebrow()
            .foregroundStyle(.secondary)
            .padding(.horizontal, AppSpacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func paceInsightsPage(plan: TrainingPlan) -> some View {
        ScrollView {
            PaceInsightsCard(plan: plan, runs: recentWorkouts, profile: profiles.first)
                .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfacePrimary)
        .navigationTitle("Pace insights")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Race fitness, predicted pace, zones and trends. It was a tab on Progress; it lives
    /// here now, beside the race it predicts.
    private var raceInsightsPage: some View {
        RaceInsightsView()
            .navigationTitle("Race insights")
            .navigationBarTitleDisplayMode(.inline)
    }

    var body: some View {
        Group {
            if showsDetailColumn {
                NavigationSplitView {
                    planPage
                        .navigationSplitViewColumnWidth(planColumnWidth)
                        // The plan is the tab; it isn't put away to read a session.
                        .toolbar(removing: .sidebarToggle)
                } detail: {
                    NavigationStack {
                        detailColumn
                    }
                    // A newly picked session or page opens at its top, not on whatever
                    // the last one had pushed.
                    .id(detailID)
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack {
                    planPage
                        .navigationDestination(item: $selectedWorkout) { workout in
                            WorkoutDetailView(workout: workout)
                        }
                }
            }
        }
        .onGeometryChange(for: PlanSpace.self) { proxy in
            var space = PlanSpace(width: proxy.size.width)
            if #available(iOS 27.1, *) {
                space.foldMinX = proxy
                    .reservedRegions(kind: .division, options: .includeInactive)
                    .first { $0.frame.height > $0.frame.width }?
                    .frame.minX
            }
            return space
        } action: { newSpace in
            space = newSpace
        }
        .onDisappear {
            // Stop adapting if the user leaves the tab so the fire-and-forget task
            // can't keep mutating and re-syncing a plan that's no longer on screen
            // (or has since been deleted) (M37).
            adaptTask?.cancel()
        }
    }

    /// The plan: the whole tab in a stack, the leading column beside a session.
    private var planPage: some View {
        Group {
            if let plan = activePlan {
                ScrollView {
                    VStack(spacing: AppSpacing.xl) {
                        // The plan is built toward a race date and, until now, never
                        // said anything else about it. This is the whole season's
                        // countdown, so it sits here rather than on the dashboard,
                        // which only carries it once the race is close (A10).
                        let racePlan = raceDayPlan(for: plan)
                        if let racePlan {
                            pageLink(to: .raceDay) {
                                RaceDayHubView()
                            } label: {
                                RaceCountdownCard(
                                    racePlan: racePlan,
                                    unit: appSettings.unitPreference
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        // Below the race: when there is one, the countdown is the
                        // screen's hero and leads it, and this card is the progress.
                        // The countdown already names the race and its goal, so the overview
                        // then only says what the plan is.
                        PlanOverviewCard(plan: plan, isHero: racePlan == nil)

                        // This week comes straight after the overview, opened up: it is
                        // what the runner acts on. The rest of the season sits below it,
                        // collapsed, rather than leading with a list of every week.
                        let sortedWeeks = (plan.weeks ?? []).sorted { $0.weekNumber < $1.weekNumber }
                        let currentWeekID = plan.currentWeek?.id
                        if let thisWeek = sortedWeeks.first(where: { $0.id == currentWeekID }) {
                            sectionEyebrow("THIS WEEK")
                            PlanWeekSummaryRow(
                                week: thisWeek,
                                currentWeekID: currentWeekID,
                                startsExpanded: true
                            ) { workout in
                                open(workout)
                            }
                            // The week in a sentence, and the coach's read of it with AI
                            // Coach on. It was Progress's first card; Plan owns the week.
                            WeekReviewCard(runs: recentWorkouts)
                        }

                        // Smart Adapt and Pace Insights are both VDOT machinery, and a
                        // pregnancy plan has no pace targets to insight about and is not
                        // the coach's to rewrite (`AdaptableWorkoutSelector` already
                        // returns nothing for one). Showing a permanently-empty card
                        // instead of the guidance that does apply would be worse than
                        // showing neither.
                        if plan.isPregnancyPlan {
                            PregnancyPlanGuidanceCard(plan: plan)
                        } else {
                            SmartAdaptPlanCard(
                                workoutCount: remainingAdaptableWorkouts(in: plan).count,
                                isAdapting: isAdaptingPlan,
                                progress: smartAdaptProgress,
                                unavailableReason: smartAdaptUnavailableReason(for: plan)
                            ) {
                                adaptTask?.cancel()
                                adaptTask = Task { await adaptRemainingWorkouts(in: plan) }
                            }

                            // The finish estimate and training paces used to fill a card
                            // here on every visit; they are a reference, so one row opens
                            // them on their own page.
                            // A value destination, built in this body: the page reads this
                            // view's `@Query` results, which a closure destination would
                            // read later, outside the body.
                            pageLink(to: .paceInsights) {
                                paceInsightsPage(plan: plan)
                            } label: {
                                PaceInsightsRow()
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("plan.paceInsightsRow")

                            pageLink(to: .raceInsights) {
                                raceInsightsPage
                            } label: {
                                PlanPageRow(
                                    title: "Race insights",
                                    subtitle: "Predicted pace, zones and trends",
                                    icon: .chart
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("plan.raceInsightsRow")
                        }

                        // Route Genius moved to Home, beside the run button, where a
                        // route is wanted.

                        let otherWeeks = sortedWeeks.filter { $0.id != currentWeekID }
                        if !otherWeeks.isEmpty {
                            // "All weeks" once this week is pulled out above; a plan that
                            // has not started has no current week, so it is every week.
                            let weeksTitle: LocalizedStringKey = currentWeekID == nil ? "TRAINING WEEKS" : "ALL WEEKS"
                            sectionEyebrow(weeksTitle)
                                .accessibilityIdentifier("plan.weeksHeader")

                            LazyVStack(spacing: AppSpacing.md) {
                                ForEach(otherWeeks) { week in
                                    PlanWeekSummaryRow(
                                        week: week,
                                        currentWeekID: currentWeekID
                                    ) { workout in
                                        open(workout)
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                    .strideReadableWidth()
                }
            } else {
                StrideEmptyState(
                    "No active plan",
                    systemImage: "calendar.badge.plus",
                    description: Text("Tap + to generate a personalised training plan.")
                ) {
                    // Race insights predict from the profile's goal without a plan, and
                    // since they left Progress this is the only way to them.
                    pageLink(to: .raceInsights) {
                        raceInsightsPage
                    } label: {
                        Text("See race insights")
                    }
                    .buttonStyle(.strideButton(.secondary, compact: true, fullWidth: false))
                }
            }
        }
        // The page's own ground, as on Home and Progress. Without it the tab drew the
        // system background, so its white cards sat on white (and ink cards on black).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfacePrimary)
        .navigationTitle("My plan")
        // A morning-reminder tap names the session the banner was about. `initial` covers
        // the cold launch, where this tab is built after the request was made.
        .onChange(of: container.appNavigation.requestedScheduledWorkoutID, initial: true) { _, id in
            guard let id else { return }
            container.appNavigation.requestedScheduledWorkoutID = nil
            if let workout = scheduledWorkout(id: id) {
                open(workout)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                pageLink(to: .planHistory) {
                    TrainingPlanListView()
                } label: {
                    // Not the History tab's clock: this is past plans, not past runs.
                    Label("Plan history", systemImage: "list.bullet.rectangle")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                NewPlanMenu(
                    showsTrainingPlan: $showNewPlanSheet,
                    showsPregnancyPlan: $showPregnancyPlanSheet
                )
                .disabled(profiles.isEmpty)
            }
        }
        .newPlanSheets(training: $showNewPlanSheet, pregnancy: $showPregnancyPlanSheet)
    }

    // MARK: Detail column

    /// What sits beside the plan: an open page, else the picked session, else the one the
    /// runner is most likely to do next (the session Home's Up Next and the widget show).
    /// The fallback is never written into `selectedWorkout`, so folding the phone doesn't
    /// push a session nobody opened.
    @ViewBuilder
    private var detailColumn: some View {
        if let openPage {
            switch openPage {
            case .raceDay:
                RaceDayHubView()
            case .paceInsights:
                if let plan = activePlan {
                    paceInsightsPage(plan: plan)
                }
            case .raceInsights:
                raceInsightsPage
            case .planHistory:
                TrainingPlanListView()
            }
        } else if let workout = detailWorkout {
            WorkoutDetailView(workout: workout)
        } else {
            StrideEmptyState(
                "Pick a session",
                systemImage: "calendar",
                description: Text("Tap a session in your plan to see it here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.surfacePrimary)
        }
    }

    private var detailWorkout: ScheduledWorkout? {
        selectedWorkout ?? WidgetSnapshotBuilder.nextScheduledWorkout(in: activePlan)
    }

    private var detailID: String {
        if let openPage { return "\(openPage)" }
        return detailWorkout?.id.uuidString ?? "none"
    }

    /// Opens a session: pushed in a stack, beside the plan in a split view.
    private func open(_ workout: ScheduledWorkout) {
        openPage = nil
        selectedWorkout = workout
    }

    /// A link to one of the plan's pages: a push in a stack, the detail column beside the
    /// plan. Not a `NavigationLink` there, which would replace the detail column's stack
    /// and leave `selectedWorkout` with nowhere to show.
    @ViewBuilder
    private func pageLink<Destination: View, LinkLabel: View>(
        to page: PlanPage,
        @ViewBuilder destination: () -> Destination,
        @ViewBuilder label: () -> LinkLabel
    ) -> some View {
        if showsDetailColumn {
            Button {
                openPage = page
            } label: {
                label()
            }
        } else {
            NavigationLink(destination: destination(), label: label)
        }
    }

    /// The session with `id`, or `nil` when it has since been deleted (a replaced plan).
    private func scheduledWorkout(id: UUID) -> ScheduledWorkout? {
        var descriptor = FetchDescriptor<ScheduledWorkout>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
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
        defer {
            isAdaptingPlan = false
            smartAdaptProgress.finishIfNeeded()
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
            onPartialText: { text in
                // Direct assignment on the main actor; see `OnDeviceCoachGenerating` for
                // why this is not wrapped in a `Task`.
                showSmartAdaptSummaries(text)
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

    /// The coach's finished explanations so far, which replace what was shown before.
    ///
    /// The buffer this used to accumulate is gone with it: streaming partials are
    /// cumulative snapshots (see `OnDeviceCoachGenerating`), so the text handed in is
    /// already everything written up to now.
    @MainActor
    private func showSmartAdaptSummaries(_ text: String) {
        let summaries = SmartAdaptSummaryStream.summaries(in: text)
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

// MARK: - New Plan Menu

/// The "+" that starts a plan, on the Plan tab and in Plan History alike, so both build
/// a plan through the same flow. The sheets stay with the screen (`newPlanSheets`) rather
/// than inside the toolbar item, which can be rebuilt while a sheet is up.
struct NewPlanMenu: View {
    @Binding var showsTrainingPlan: Bool
    @Binding var showsPregnancyPlan: Bool

    var body: some View {
        Menu {
            Button {
                showsTrainingPlan = true
            } label: {
                Label("Training plan", systemImage: "figure.run")
            }
            Button {
                showsPregnancyPlan = true
            } label: {
                Label("Pregnancy plan", systemImage: "heart.text.square")
            }
        } label: {
            Label("New plan", systemImage: "plus")
        }
    }
}

extension View {
    /// The two flows `NewPlanMenu` opens.
    func newPlanSheets(training: Binding<Bool>, pregnancy: Binding<Bool>) -> some View {
        sheet(isPresented: training) {
            NewPlanOnboardingView()
                .strideSheet()
        }
        .sheet(isPresented: pregnancy) {
            PregnancyPlanSetupView()
                .strideSheet()
        }
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
                        Circle()
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
                        Text(isAdapting ? "Adapting plan" : "Smart Adapt")
                            .font(.dsHeadline)

                        Text(subtitle)
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    StrideIcon(name: .chevronRight, size: 12, color: .brand, strokeWeight: 2.4)
                }
                .padding(AppSpacing.lg)
                .strideCard()
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            // Not `.opacity(0.55)`: that multiplied into text already carrying alpha —
            // `.secondary` is ~60%, so the subtitle landed near 33% effective and read as
            // broken rather than disabled. Desaturating the accent to grey is the part
            // that actually signals "off"; the copy stays at full contrast so it can
            // still be read, which is the whole point of the row explaining itself.
            .grayscale(isEnabled ? 0 : 1)
            .opacity(isEnabled ? 1 : 0.9)

            if isAdapting {
                VStack(alignment: .leading, spacing: 8) {
                    if let value = progress.fractionCompleted {
                        StrideProgressBar(value: value)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Text(progress.currentMessage)
                        .font(.dsCaption)
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
                                        .font(.dsCaption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                            }
                        }
                        .padding(AppSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .strideCard(cornerRadius: AppRadius.sm)
                    }

                    ForEach(progress.updates) { update in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(update.title)
                                .font(.captionStrong)
                                .foregroundStyle(.primary)
                            Text(update.message)
                                .font(.dsCaption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        .padding(AppSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .strideCard(cornerRadius: AppRadius.sm)
                    }
                }
                .padding(.top, AppSpacing.xs)
            }
        }
    }

    /// When Smart Adapt can't run, the reason is the subtitle, inside the card. It used to
    /// be a loose caption under it while the card still said "Adapt the remaining…".
    private var subtitle: String {
        if let unavailableReason, !isAdapting {
            return unavailableReason
        }
        guard workoutCount > 0 else {
            return "No remaining run workouts are available."
        }

        let workoutLabel = workoutCount == 1 ? "workout" : "workouts"
        return "Adapt the remaining \(workoutCount) \(workoutLabel) in this plan."
    }
}

// MARK: - Plan Overview Card

private struct PlanOverviewCard: View {
    let plan: TrainingPlan
    /// The overview is Plan's hero when there is no race countdown to be it: one hero per
    /// screen, and a plan without a race date still has a card that matters most.
    var isHero = false
    @Environment(AppSettings.self) private var appSettings

    /// "2/12" in the plan's current week; before it starts "0/12", after it ends "12/12".
    private var weekPosition: String {
        let current = plan.currentWeek?.weekNumber
            ?? (hasStarted ? plan.totalWeeks : 0)
        return "\(current)/\(plan.totalWeeks)"
    }

    private var totalCompletedDistanceKm: Double {
        (plan.weeks ?? []).reduce(0) { $0 + $1.completedDistanceKm }
    }

    private var hasStarted: Bool {
        Calendar.current.startOfDay(for: plan.startDate) <= Calendar.current.startOfDay(for: Date())
    }

    private var raceStrideIcon: StrideIconName {
        guard !plan.isPregnancyPlan else { return .heart }
        switch plan.targetRace {
        case .maintainFitness: return .heart
        case .fiveK: return .bolt
        case .halfMarathon: return .tempo
        case .marathon: return .run
        case .custom: return .ruler
        }
    }

    private var planTitle: String {
        if plan.isPregnancyPlan { return PlanKind.pregnancy.localizedName }
        // Not the hero means the race countdown leads the screen with the race's name,
        // date and goal; repeating them here made three cards say the same thing.
        if !isHero {
            return String(
                localized: "\(plan.totalWeeks)-week plan",
                comment: "Plan overview title under the race countdown: the plan's length"
            )
        }
        if let name = plan.raceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return plan.targetRace.localizedName
    }

    /// A pregnancy plan has no goal time, so the line that would read "Goal 0:00" reports
    /// where the pregnancy is instead — the number that actually indexes the plan.
    private var planSubtitle: String? {
        if plan.isPregnancyPlan, let age = plan.gestationalAge() {
            return String(
                localized: "\(age.noteForm) weeks  ·  \(plan.totalWeeks) weeks planned",
                comment: "Pregnancy plan subtitle: gestational age and plan length"
            )
        }
        if !isHero { return nil }
        let length = String(localized: "\(plan.totalWeeks) weeks", comment: "Plan subtitle: plan length")
        // Maintain Fitness has no race, so a bare "Goal 52:35" had no distance to belong to.
        guard plan.targetRace.isGoalRace, plan.goalTimeSeconds > 0 else { return length }
        return String(
            localized: "Goal \(plan.goalTimeSeconds.durationString)  ·  \(length)",
            comment: "Race plan subtitle: goal time and plan length"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header row: race icon + title + goal
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.brand.opacity(0.12))
                        .frame(width: 48, height: 48)
                    StrideIcon(name: raceStrideIcon, size: 26, color: .brand, strokeWeight: 2.0)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(planTitle)
                        .font(.dsTitle3.weight(.bold))
                    if let planSubtitle {
                        Text(planSubtitle)
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            // Phase progress bar with Base / Build / Peak / Taper labels
            PhaseProgressBar(plan: plan)

            Divider()

            // Where the runner is, what they have run, and when it ends. A "0%" in the
            // header counted finished weeks, so in week 2 it sat at 0% beside a non-zero
            // "Completed"; the week number says the same thing without contradicting it.
            HStack {
                OverviewStat(
                    value: weekPosition,
                    label: "Week"
                )
                Divider().frame(height: 36)
                OverviewStat(
                    value: totalCompletedDistanceKm.distanceStringFromKm(unit: appSettings.unitPreference),
                    label: "Completed"
                )
                Divider().frame(height: 36)
                // Before the start, the start date: "Started" was once hardcoded and
                // reported a future date in the past tense (S20). After it, the end, which
                // is the date a runner plans around.
                OverviewStat(
                    value: (hasStarted ? plan.endDate : plan.startDate)
                        .formatted(.dateTime.month(.abbreviated).day()),
                    label: hasStarted ? "Ends" : "Starts"
                )
            }
        }
        .padding()
        .strideSurface(isHero: isHero)
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
                        .fill(.surfaceTertiary)
                        .frame(height: 10)

                    Capsule()
                        .fill(.route)
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
                    Text(phase.localizedName)
                        .strideEyebrow()
                        .foregroundStyle(phase == currentPhase ? Color.brandText : Color.secondary)
                    if phase != .taper { Spacer() }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Training phases")
        .accessibilityValue(
            "\(currentPhase.localizedName), \(Int(plan.progress * 100)) percent of the plan done"
        )
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
                .font(.dsCaption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Plan Week Summary Row

private struct PlanWeekSummaryRow: View {
    let week: TrainingWeek
    let currentWeekID: UUID?
    /// Opens a session's detail. A tap rather than a `NavigationLink`, which would take the
    /// touch the reorder container's lift gesture needs.
    let onSelectWorkout: (ScheduledWorkout) -> Void
    @Environment(AppSettings.self) private var appSettings
    @Environment(AppContainer.self) private var container
    @Environment(\.modelContext) private var context
    @State private var isExpanded: Bool

    init(
        week: TrainingWeek,
        currentWeekID: UUID?,
        startsExpanded: Bool = false,
        onSelectWorkout: @escaping (ScheduledWorkout) -> Void
    ) {
        self.week = week
        self.currentWeekID = currentWeekID
        self.onSelectWorkout = onSelectWorkout
        _isExpanded = State(initialValue: startsExpanded)
    }

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

    /// "Aug 3 – 9", or "Aug 31 – Sep 6" when the week straddles a month.
    private var weekDateRange: String {
        let calendar = Calendar.current
        let start = week.startDate
        let end = week.endDate
        let startText = start.formatted(.dateTime.month(.abbreviated).day())
        let sameMonth = calendar.isDate(start, equalTo: end, toGranularity: .month)
        let endText = sameMonth
            ? end.formatted(.dateTime.day())
            : end.formatted(.dateTime.month(.abbreviated).day())
        return "\(startText) – \(endText)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(AppAnimation.quick) { isExpanded.toggle() }
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
                            // The current week has no badge: it sits under "This week" with
                            // the start pin beside it, and a "CURRENT" tag made a third marker.
                            if week.isCompleted && !isCurrentWeek {
                                StrideTag(
                                    String(localized: "Done", comment: "Tag on a finished plan week"),
                                    systemImage: "checkmark",
                                    iconTint: .success
                                )
                            }
                        }

                        HStack(spacing: 4) {
                            // The week's dates. Without them the list was eight rows reading
                            // "Week N · Base — 0/4 workouts · 12.4 mi target", with no way to
                            // tell when any of them happen or which one is next — and on a
                            // plan that has not started, no "CURRENT" badge to anchor to
                            // either (S21).
                            Text(weekDateRange)
                                .font(.dsCaption)
                                .foregroundStyle(.secondary)
                            Text("·")
                                .font(.dsCaption)
                                .foregroundStyle(.tertiary)
                            Text("\(completedWorkouts)/\(totalWorkouts) workouts")
                                .font(.dsCaption)
                                .foregroundStyle(.secondary)
                            Text("·")
                                .font(.dsCaption)
                                .foregroundStyle(.tertiary)
                            distanceLabel
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    }

                    Spacer()

                    StrideIcon(name: .chevronDown, size: 12, color: .secondary, strokeWeight: 2)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .animation(AppAnimation.quick, value: isExpanded)
                }
                .padding()
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                Divider()
                ForEach(orderedWorkouts) { workout in
                    PlanWorkoutSummaryRow(workout: workout)
                        // The divider used to be this `ForEach`'s second child. Inside a
                        // reorder container that makes it part of the item, so it would
                        // lift with the row and leave a gap behind. As a bottom overlay it
                        // draws in the same place and belongs to the row's frame.
                        .overlay(alignment: .bottom) {
                            // Not under the last row, where it drew over the card's edge.
                            if workout.id != orderedWorkouts.last?.id {
                                Divider().padding(.leading, 60)
                            }
                        }
                        // The lift gesture hit-tests the row's *drawn* content, and a row
                        // is an icon, two labels and a `Spacer`. Without a shape the
                        // transparent middle — most of its width — is not part of the row
                        // for touch purposes, so a drag started there reached the
                        // `ScrollView` and scrolled the plan instead of picking the
                        // session up. A `List` gives its rows this for free; a stack does
                        // not.
                        .contentShape(Rectangle())
                        .onTapGesture { onSelectWorkout(workout) }
                        .accessibilityAddTraits(.isButton)
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
        .strideCard()
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
        guard let offset = dropOffset(difference.destination.position, in: workouts) else { return }

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

    /// Turns a `ReorderDifference.Destination.Position` into the insertion offset
    /// `WorkoutReorderPlanner.plan(slots:moving:toOffset:)` wants.
    ///
    /// A destination is a *position relative to a row*, not a number: `.before(id)`
    /// names the row the lifted sessions were dropped above, and `.end` means past the
    /// last one. The planner counts rendered rows in date order, so `.before` resolves to
    /// that row's own index — an insertion offset into the pre-move array, which is the
    /// same convention the classic `onMove(perform:)` destination used, and what
    /// `plan`'s `ordered.prefix(offset)` is written against.
    ///
    /// The destination's `collectionID` is ignored on purpose: this container is registered
    /// with `reorderContainer(for:itemID:isEnabled:move:)`, whose single collection makes
    /// `ReorderableSingleCollectionIdentifier` the only value it can carry.
    private func dropOffset(
        _ position: ReorderDifference<UUID, ReorderableSingleCollectionIdentifier>.Destination.Position,
        in workouts: [ScheduledWorkout]
    ) -> Int? {
        // `Position` is `@frozen`, so these two cases are the whole enum and there is no
        // `@unknown default` to write. `firstIndex` returning `nil` is still reachable —
        // a row this week does not hold stays a no-op rather than a guess at one end of it.
        switch position {
        case .before(let id):
            return workouts.firstIndex { $0.id == id }
        case .end:
            return workouts.count
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
                .font(.dsCaption)
                .foregroundStyle(.secondary)
        } else if isCurrentWeek {
            HStack(spacing: 2) {
                Text(week.completedDistanceKm.distanceStringFromKm(unit: appSettings.unitPreference))
                    .foregroundStyle(.secondary)
                Text("/ \(week.targetDistanceKm.distanceStringFromKm(unit: appSettings.unitPreference))")
                    .foregroundStyle(.tertiary)
            }
            .font(.dsCaption)
        } else {
            Text("\(week.targetDistanceKm.distanceStringFromKm(unit: appSettings.unitPreference)) target")
                .font(.dsCaption)
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
                StrideIcon(name: workout.workoutType.strideIcon, size: 18,
                           color: workout.workoutType.color, strokeWeight: 1.8)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(workout.workoutType.localizedName)
                    .font(.bodyRegular)
                Text(workout.scheduledDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let dist = workout.targetDistanceMeters {
                Text(dist.distanceString(unit: appSettings.unitPreference))
                    .font(.dsCaption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if workout.isCompleted {
                ZStack {
                    Circle()
                        .fill(Color.success)
                        .frame(width: 18, height: 18)
                    StrideIcon(name: .check, size: 9, color: .onFill, strokeWeight: 3)
                }
            }

            // The row opens the session's detail.
            StrideIcon(name: .chevronRight, size: 11, color: .secondary, strokeWeight: 2)
        }
        .padding(.vertical, AppSpacing.sm)
        // The same inset as the week's header above it, so the icons line up with the
        // header's pin rather than sitting against the card's edge.
        .padding(.horizontal)
    }

}
