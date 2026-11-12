import SwiftUI
import SwiftData

/// A planned session, before it is run.
///
/// Laid out like the run detail screen (PR #334): the summary first, the detail under it.
/// The hero answers "what am I doing and how long will it take" — distance, time and pace
/// on two lines, where to run it, and the button that starts it. Under it come the coach's
/// note on how it should feel and the session's steps, then the playlist. A completed run
/// shows its `RunSummaryView` instead.
struct WorkoutDetailView: View {
    let workout: ScheduledWorkout

    @Environment(AppContainer.self) private var container
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ScaledMetric(relativeTo: .largeTitle) private var heroMetricSize: CGFloat = 56

    @State private var isSyncingLocation = false
    /// Strength has no minimised form, so it is presented here rather than through
    /// `ActiveRunPresentation`, the same way Home does.
    @State private var strengthWorkout: ScheduledWorkout?
    @State private var showRouteGenius = false

    private var unit: UnitPreference { appSettings.unitPreference }

    private var goalRacePlan: TrainingPlan? {
        workout.week?.plan
    }

    private var isCompletedGoalRace: Bool {
        guard workout.workoutType == .race, workout.isCompleted, let plan = goalRacePlan else {
            return false
        }
        let hasRaceName = plan.raceName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let matchesRaceDate = plan.raceDate.map {
            Calendar.current.isDate(workout.scheduledDate, inSameDayAs: $0)
        } ?? false
        return hasRaceName || matchesRaceDate
    }

    /// The playlist shape for this session, or nil when there is nothing to score (N40).
    ///
    /// Nil covers rest days, strength and cross-training sessions, and any run whose length
    /// cannot be estimated — `RunPlaylistPlanner` decides all three, so the card's presence
    /// and its contents can never disagree. A session already behind the runner is excluded
    /// here rather than there: the planner is about what a session *is*, and offering to
    /// build a playlist for a run that has been completed is a question about *when*.
    private var playlistPlan: RunPlaylistPlan? {
        guard !workout.isCompleted else { return nil }
        return RunPlaylistPlanner.plan(for: .init(workout: workout))
    }

    private var goalRaceName: String {
        if let name = goalRacePlan?.raceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return workout.week?.plan?.targetRace.localizedName ?? "Goal race"
    }

    var body: some View {
        Group {
            if let completed = workout.completedWorkout {
                RunSummaryView(workout: completed)
            } else if let lifted = workout.completedStrengthWorkout {
                // A done strength day shows what was lifted, as History does, rather
                // than the plan for a session that is already behind the runner.
                StrengthSummaryView(workout: lifted)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.lg) {
                        if isCompletedGoalRace {
                            GoalRaceCelebrationCard(
                                raceName: goalRaceName,
                                raceDate: goalRacePlan?.raceDate ?? workout.scheduledDate,
                                reduceMotion: reduceMotion
                            )
                        }
                        hero
                        if let notes = trimmedNotes {
                            notesCard(notes)
                        }
                        if workout.workoutType == .strength, let plan = workout.strengthPlan {
                            strengthSection(plan: plan)
                        } else if let structure = workout.workoutStructure {
                            stepsSection(structure: structure)
                        } else if !workout.intervals.isEmpty {
                            intervalsSection
                        }
                        if let playlistPlan {
                            RunPlaylistCard(workout: workout, plan: playlistPlan)
                        }
                    }
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.top, AppSpacing.sm)
                    .padding(.bottom, AppSpacing.xxl)
                    .strideReadableWidth()
                }
                .background(Color.surfacePrimary)
                .navigationTitle(workout.workoutType.localizedName)
                .navigationBarTitleDisplayMode(.inline)
                .fullScreenCover(item: $strengthWorkout) { session in
                    StrengthActiveView(scheduledWorkout: session)
                }
                .sheet(isPresented: $showRouteGenius) {
                    RouteGeniusView(
                        viewModel: container.makeRouteGeniusViewModel(
                            appSettings: appSettings,
                            initialDistanceMeters: plannedDistanceMeters
                        )
                    )
                    .strideSheet()
                }
            }
        }
    }

    // MARK: - Hero

    /// The session at a glance: type and day, the distance as the big number, time and
    /// pace under it, where to run it, and the start button.
    ///
    /// Replaces the old icon-and-title header plus the separate Target pace, Distance and
    /// summary-chip rows, which said the distance twice and spread one fact per section.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            kicker

            if let lead = heroLead {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(lead.value)
                        .font(.system(size: heroMetricSize, weight: .semibold, design: .rounded).monospacedDigit())
                        .kerning(-2.2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(lead.unit)
                        .font(.dsCallout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else {
                Text(workout.workoutType.localizedName)
                    .font(.dsTitle1)
            }

            let details = heroDetails
            if !details.isEmpty {
                HStack(spacing: 12) {
                    ForEach(Array(details.enumerated()), id: \.offset) { index, detail in
                        if index > 0 {
                            Text("·").foregroundStyle(.tertiary)
                        }
                        metricInline(value: detail.value, label: detail.unit)
                    }
                }
            }

            if !workout.isCompleted && workout.workoutType.sessionKind == .run {
                locationPicker
                    .padding(.top, AppSpacing.xs)
            }

            if canStart {
                startButton
            }

            if canPlanRoute {
                planRouteButton
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The celebration is the hero once the goal race is run.
        .strideSurface(isHero: !isCompletedGoalRace)
    }

    /// "● EASY · FRI, NOV 6", the run detail hero's kicker. The dot carries the type's
    /// colour; the words stay neutral, since zone colours are data, not text decoration.
    private var kicker: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(workout.workoutType.color)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(workout.workoutType.color.opacity(0.25), lineWidth: 6))
            Text(workout.workoutType.localizedName)
                .strideEyebrow()
                .foregroundStyle(.secondary)
            Circle()
                .fill(.tertiary)
                .frame(width: 3, height: 3)
            Text(dayLabel)
                .font(.dsCaption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if workout.isCompleted {
                StrideTag(String(localized: "Done"), systemImage: "checkmark", tone: .brand)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var dayLabel: String {
        let date = workout.scheduledDate
        if Calendar.current.isDateInToday(date) { return String(localized: "Today") }
        if Calendar.current.isDateInTomorrow(date) { return String(localized: "Tomorrow") }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "Yesterday") }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private struct HeroFigure {
        let value: String
        let unit: String
    }

    private var plannedDistanceMeters: Double? {
        if let meters = workout.targetDistanceMeters, meters > 0 { return meters }
        if let total = workout.workoutStructure?.totalEstimatedDistanceMeters, total > 0 { return total }
        return nil
    }

    /// The hero's big number: the distance, or the time when there is no distance
    /// (strength, cross-training).
    private var heroLead: HeroFigure? {
        if let meters = plannedDistanceMeters {
            return HeroFigure(
                value: String(format: "%.1f", meters.distanceValue(unit: unit)),
                unit: unit == .metric ? "km" : "mi"
            )
        }
        if let minutes = strengthMinutes {
            return HeroFigure(value: "\(minutes)", unit: "min")
        }
        return nil
    }

    /// The line under the big number: the expected time, then the pace band in the short
    /// "9:51–11:46 /mi" form, so the range fits on one line.
    private var heroDetails: [HeroFigure] {
        var figures: [HeroFigure] = []
        if plannedDistanceMeters != nil,
           let seconds = NextUpBriefing.estimatedDurationSeconds(for: workout),
           let text = NextUpBriefing.approximateDurationText(seconds: seconds) {
            figures.append(HeroFigure(value: text, unit: ""))
        }
        if let range = workout.targetPaceRange {
            let low = range.lowerBound.paceValueString(unit: unit)
            let high = range.upperBound.paceValueString(unit: unit)
            figures.append(HeroFigure(value: low == high ? low : "\(low)–\(high)", unit: paceSuffix))
        }
        return figures
    }

    private var strengthMinutes: Int? {
        guard workout.workoutType == .strength, let plan = workout.strengthPlan,
              plan.estimatedDurationMinutes > 0 else { return nil }
        return plan.estimatedDurationMinutes
    }

    private var paceSuffix: String { unit == .metric ? "/km" : "/mi" }

    private func metricInline(value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.dsFootnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
            if !label.isEmpty {
                Text(label)
                    .font(.dsFootnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Start

    /// Today's session, or one missed by a day — the same window Home offers a start for
    /// (`ScheduledDayResolver.canStart`).
    private var canStart: Bool {
        guard !workout.isCompleted else { return false }
        switch workout.workoutType.sessionKind {
        case .run, .strength: break
        case .walk, .crossTraining, .rest: return false
        }
        return ScheduledDayResolver.canStart(workoutScheduledOn: workout.scheduledDate)
    }

    private var startButton: some View {
        Button {
            if workout.workoutType == .strength {
                strengthWorkout = workout
            } else {
                container.activeRunPresentation.startOrReopen(
                    scheduledWorkout: workout,
                    isRunInProgress: container.workoutTrackerService.isRecording
                )
            }
        } label: {
            HStack(spacing: 10) {
                // `onFill` on the route: white on orange is 2.8:1 (U3a).
                StrideIcon(name: .play, size: 18, color: .onFill, strokeWeight: 2.2)
                Text(startButtonTitle)
            }
        }
        .buttonStyle(.strideButton())
        .accessibilityIdentifier("workoutDetail.start")
    }

    /// Typed `LocalizedStringKey` so the literals stay in the string catalog.
    private var startButtonTitle: LocalizedStringKey {
        let isStrength = workout.workoutType == .strength
        if !isStrength && container.workoutTrackerService.isRecording {
            return "Back to your run"
        }
        if Calendar.current.isDateInToday(workout.scheduledDate) {
            return isStrength ? "Start strength workout" : "Start this workout"
        }
        return isStrength ? "Start yesterday's strength workout" : "Start yesterday's workout"
    }

    // MARK: - Route

    /// An outdoor run still ahead, with a distance to build the route around. Not tied to
    /// `canStart`: planning Saturday's long run on Thursday is the point.
    private var canPlanRoute: Bool {
        !workout.isCompleted
            && workout.workoutType.sessionKind == .run
            && workout.workoutLocation == .outdoor
            && plannedDistanceMeters != nil
    }

    /// Route Genius with this session's distance already in the field. Quiet, as on Home:
    /// the start button stays the screen's one primary action.
    private var planRouteButton: some View {
        Button {
            showRouteGenius = true
        } label: {
            HStack(spacing: 8) {
                StrideIcon(name: .bolt, size: 16, color: .brandText, strokeWeight: 2.2)
                Text("Plan a route")
            }
        }
        .buttonStyle(.strideButton(.quiet))
        .accessibilityHint(
            String(
                localized: "Builds a route matched to this workout's distance",
                comment: "Hint on the planned workout screen's route button"
            )
        )
        .accessibilityIdentifier("workoutDetail.planRoute")
    }

    // MARK: - Location toggle

    private var locationPicker: some View {
        StrideSegmentedControl(
            selection: Binding(
                get: { workout.workoutLocation },
                set: { location in
                    guard workout.workoutLocation != location else { return }
                    Task { await changeLocation(to: location) }
                }
            ),
            options: WorkoutLocation.allCases
        ) { location in
            Text("\(Image(systemName: location.systemImage)) \(location.localizedName)")
        }
        // One change at a time: each one re-syncs the plan to the watch.
        .disabled(isSyncingLocation)
    }

    @MainActor
    private func changeLocation(to location: WorkoutLocation) async {
        guard !workout.isCompleted else { return }
        isSyncingLocation = true
        defer { isSyncingLocation = false }
        workout.workoutLocation = location
        // Clear the stale WorkoutKit plan so the next sync reschedules with the new location.
        workout.healthKitPlanID = nil
        context.saveOrLog("the workout's indoor/outdoor change")
        if let plan = workout.week?.plan {
            try? await container.healthKitRepository.syncWorkoutPlans(for: plan, unitPreference: unit)
        }
    }

    // MARK: - Notes

    private var trimmedNotes: String? {
        guard let notes = workout.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
              !notes.isEmpty else { return nil }
        return notes
    }

    /// The coach's note on how the session should feel. Directly under the hero and with
    /// no header: it is the one sentence of advice, not a section to look for.
    private func notesCard(_ notes: String) -> some View {
        Text(notes)
            .font(.dsCallout)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.lg)
            .strideCard()
    }

    // MARK: - Steps

    /// Warm-up, the main work and the cool-down as rows in one card. Segments the plan
    /// left empty (no label, no distance, no time) are skipped rather than drawn blank.
    private func stepsSection(structure: WorkoutStructure) -> some View {
        let steps = PlannedStep.steps(from: structure, unit: unit)
        return Group {
            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text("Steps")
                        .strideEyebrow()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, AppSpacing.xs)
                    VStack(spacing: 0) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            if index > 0 {
                                Divider().padding(.leading, 26)
                            }
                            PlannedStepRow(step: step)
                        }
                    }
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.vertical, AppSpacing.xs)
                    .strideCard()
                }
            }
        }
    }

    /// Older plans stored a flat interval list instead of a structure.
    private var intervalsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Steps")
                .strideEyebrow()
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)
            VStack(spacing: 0) {
                ForEach(Array(workout.intervals.enumerated()), id: \.offset) { index, interval in
                    if index > 0 {
                        Divider().padding(.leading, 26)
                    }
                    PlannedStepRow(step: PlannedStep(
                        title: String(localized: "Repeats"),
                        amount: intervalAmount(interval),
                        pace: interval.targetPaceSecondsPerKm.map { PlannedStep.paceText($0, unit: unit) },
                        note: interval.recoverySeconds > 0
                            ? String(localized: "\(Int(interval.recoverySeconds)) s recovery between")
                            : nil,
                        isWork: true
                    ))
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.xs)
            .strideCard()
        }
    }

    private func intervalAmount(_ interval: WorkoutInterval) -> String {
        var each = ""
        if let meters = interval.distanceMeters, meters > 0 {
            each = PlannedStep.distanceText(meters, unit: unit)
        } else if let seconds = interval.durationSeconds, seconds > 0 {
            each = seconds.durationString
        }
        return each.isEmpty ? "\(interval.repetitions) ×" : "\(interval.repetitions) × \(each)"
    }

    // MARK: - Strength section

    /// The duration is the hero's big number, so the old duration chip is gone from here.
    private func strengthSection(plan: StrengthWorkoutPlan) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Exercises")
                .strideEyebrow()
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)
            ForEach(Array(plan.exercises.enumerated()), id: \.offset) { _, exercise in
                ExerciseRow(exercise: exercise)
            }
        }
    }
}

// MARK: - ExerciseRow

struct ExerciseRow: View {
    let exercise: StrengthExercise

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(exercise.name)
                    .font(.dsSubhead.weight(.semibold))
                Spacer()
                Text(repsLabel)
                    .font(.dsFootnote.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(exercise.muscleGroups.prefix(3), id: \.self) { group in
                    StrideTag(group, tone: .brand)
                }
                if let weight = exercise.targetWeight {
                    StrideTag(weight)
                }
            }
            if let notes = exercise.notes {
                Text(notes)
                    .font(.dsCaption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppSpacing.md)
        .strideCard(cornerRadius: AppRadius.md)
    }

    private var repsLabel: String {
        if let duration = exercise.durationSeconds {
            return "\(exercise.sets) × \(duration)s"
        } else if exercise.reps == 0 {
            return "\(exercise.sets) × AMRAP"
        } else {
            return "\(exercise.sets) × \(exercise.reps)"
        }
    }
}

// MARK: - GoalRaceCelebrationCard

private struct GoalRaceCelebrationCard: View {
    let raceName: String
    let raceDate: Date
    let reduceMotion: Bool

    @State private var burst = false

    var body: some View {
        ZStack {
            if reduceMotion {
                StaticConfettiView()
            } else {
                ConfettiBurstView(isExpanded: burst)
            }

            VStack(spacing: 8) {
                StrideIcon(name: .trophy, size: 34, color: .brand, strokeWeight: 2.2)
                Text(raceName)
                    .font(.dsTitle1.weight(.heavy))
                    .multilineTextAlignment(.center)
                Text("Goal race completed")
                    .font(.bodyStrong)
                    .foregroundStyle(.secondary)
                Text(raceDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, AppSpacing.xxl)
            .padding(.horizontal, AppSpacing.lg)
        }
        .frame(maxWidth: .infinity)
        // The confetti stays inside the card's shape.
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        // The screen's one hero in this state; the session header steps down to a card.
        .heroCard()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(AppAnimation.celebrate.delay(0.1)) {
                burst = true
            }
        }
    }
}

private struct ConfettiBurstView: View {
    let isExpanded: Bool

    var body: some View {
        // `GeometryReader` stays here and in `StaticConfettiView` deliberately (U7). Each
        // particle is `.position`ed at a fraction of the *container*, and `visualEffect`'s
        // proxy is the modified view's own geometry — a 5pt square — so it cannot express
        // "38% across the card I am sitting in".
        GeometryReader { geo in
            ForEach(ConfettiParticle.samples) { particle in
                RoundedRectangle(cornerRadius: AppRadius.micro)
                    .fill(particle.color)
                    .frame(width: particle.width, height: particle.height)
                    .rotationEffect(.degrees(isExpanded ? particle.rotation : 0))
                    .position(
                        x: geo.size.width * 0.5,
                        y: geo.size.height * 0.36
                    )
                    .offset(
                        x: isExpanded ? particle.xOffset(in: geo.size.width) : 0,
                        y: isExpanded ? particle.yOffset(in: geo.size.height) : 0
                    )
                    .opacity(isExpanded ? 1 : 0)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct StaticConfettiView: View {
    var body: some View {
        GeometryReader { geo in
            ForEach(ConfettiParticle.samples.prefix(18)) { particle in
                Circle()
                    .fill(particle.color.opacity(0.72))
                    .frame(width: 5, height: 5)
                    .position(
                        x: geo.size.width * particle.staticX,
                        y: geo.size.height * particle.staticY
                    )
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ConfettiParticle: Identifiable, Sendable {
    let id: Int
    let width: Double
    let height: Double
    let xFactor: Double
    let yFactor: Double
    let rotation: Double
    let colorIndex: Int
    let staticX: Double
    let staticY: Double

    var color: Color {
        // The brand's two ends and a win. Zone colours are training data, not decoration.
        switch colorIndex % 3 {
        case 0: return .brand
        case 1: return .brandGlow
        default: return .success
        }
    }

    func xOffset(in width: Double) -> Double {
        xFactor * width * 0.42
    }

    func yOffset(in height: Double) -> Double {
        yFactor * height * 0.40
    }

    static let samples: [ConfettiParticle] = (0..<42).map { index in
        let column = Double(index % 7)
        let row = Double(index / 7)
        let direction = column - 3.0
        return ConfettiParticle(
            id: index,
            width: index % 3 == 0 ? 5 : 7,
            height: index % 2 == 0 ? 10 : 6,
            xFactor: direction / 3.0,
            yFactor: 0.15 + row / 7.0,
            rotation: Double((index * 37) % 180) - 90,
            colorIndex: index,
            staticX: 0.12 + (column / 6.0) * 0.76,
            staticY: 0.12 + (row / 5.0) * 0.30
        )
    }
}

// MARK: - PlannedStep

/// One row of a planned session's steps: what to do, how much, and at what pace.
///
/// Pure, so the step list a structure produces can be tested without a view.
struct PlannedStep: Equatable {
    /// "Warm-up", "Easy Run", "VO2max Intervals".
    let title: String
    /// "0.3 mi", "10:00", "5 × 800 m".
    let amount: String?
    /// "11:46 /mi".
    let pace: String?
    /// "90 s recovery jog between".
    let note: String?
    /// The main work, as opposed to a warm-up or cool-down.
    let isWork: Bool

    static func steps(from structure: WorkoutStructure, unit: UnitPreference) -> [PlannedStep] {
        var steps: [PlannedStep] = []
        if let warmup = segmentStep(structure.warmup, fallbackTitle: String(localized: "Warm-up"), unit: unit) {
            steps.append(warmup)
        }
        for set in structure.mainSets {
            if let step = setStep(set, unit: unit) {
                steps.append(step)
            }
        }
        if let cooldown = segmentStep(structure.cooldown, fallbackTitle: String(localized: "Cool-down"), unit: unit) {
            steps.append(cooldown)
        }
        return steps
    }

    private static func segmentStep(
        _ segment: WorkoutSegment,
        fallbackTitle: String,
        unit: UnitPreference
    ) -> PlannedStep? {
        let amount = amountText(segment, unit: unit)
        let label = segment.label.trimmingCharacters(in: .whitespacesAndNewlines)
        // An open segment the plan left blank (the pregnancy plan's placeholder) is not a step.
        guard amount != nil || !label.isEmpty else { return nil }
        return PlannedStep(
            title: label.isEmpty ? fallbackTitle : label,
            amount: amount,
            pace: segment.targetPaceSecondsPerKm.map { paceText($0, unit: unit) },
            note: nil,
            isWork: false
        )
    }

    private static func setStep(_ set: WorkoutSet, unit: UnitPreference) -> PlannedStep? {
        let work = set.workSegment
        let base = amountText(work, unit: unit)
        let label = set.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let workLabel = work.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = label.isEmpty ? workLabel : label
        guard base != nil || !title.isEmpty else { return nil }

        let amount: String?
        if set.repetitions > 1 {
            amount = base.map { "\(set.repetitions) × \($0)" } ?? "\(set.repetitions) ×"
        } else {
            amount = base
        }

        var note: String?
        if set.repetitions > 1, let recovery = set.recoverySegment.durationSeconds, recovery > 0 {
            let time = recovery < 60 ? "\(Int(recovery)) s" : recovery.durationString
            let kind = set.recoverySegment.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            note = kind.isEmpty
                ? String(localized: "\(time) recovery between")
                : String(localized: "\(time) \(kind) between")
        }

        return PlannedStep(
            title: title.isEmpty ? String(localized: "Main set") : title,
            amount: amount,
            pace: work.targetPaceSecondsPerKm.map { paceText($0, unit: unit) },
            note: note,
            isWork: true
        )
    }

    private static func amountText(_ segment: WorkoutSegment, unit: UnitPreference) -> String? {
        if let meters = segment.distanceMeters, meters > 0 {
            return distanceText(meters, unit: unit)
        }
        if let seconds = segment.durationSeconds, seconds > 0 {
            return seconds.durationString
        }
        return nil
    }

    /// Track-length reps read in metres ("800 m"), everything else in the runner's unit.
    static func distanceText(_ meters: Double, unit: UnitPreference) -> String {
        if unit == .metric && meters < 1_000 {
            return "\(Int(meters.rounded())) m"
        }
        return meters.distanceString(unit: unit)
    }

    /// "11:46 /mi": the short form, so a step's pace fits beside its distance.
    static func paceText(_ secondsPerKm: Double, unit: UnitPreference) -> String {
        "\(secondsPerKm.paceValueString(unit: unit)) \(unit == .metric ? "/km" : "/mi")"
    }
}

// MARK: - PlannedStepRow

/// A step inside the Steps card. The marker is hollow for the warm-up and cool-down and
/// filled with the brand for the work, so the session's shape reads down the left edge.
private struct PlannedStepRow: View {
    let step: PlannedStep

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Group {
                if step.isWork {
                    Circle().fill(Color.brand)
                } else {
                    Circle().strokeBorder(Color.secondary, lineWidth: 2)
                }
            }
            .frame(width: 12, height: 12)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.dsSubhead.weight(.semibold))
                if let note = step.note {
                    Text(note)
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: AppSpacing.sm)

            VStack(alignment: .trailing, spacing: 2) {
                if let amount = step.amount {
                    Text(amount)
                        .font(.dsSubhead.weight(.semibold).monospacedDigit())
                }
                if let pace = step.pace {
                    Text(pace)
                        .font(.dsCaption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
