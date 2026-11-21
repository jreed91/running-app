import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - RaceDayHubView

/// Everything about the goal race in one screen: how long is left, what the plan has done
/// to get there, the clock to run to, and — once the run is in the log — how it went.
///
/// The plan has always been built toward `raceDate` and then said nothing about it. The
/// dashboard's coaching strip has a race-morning card, but a card is a sentence; the
/// runner checking their splits at 6 a.m. wants the whole table, and the one checking in
/// a fortnight out wants to see the taper doing its job.
///
/// Every number here comes from ``RaceDayPlan``, which is pure and tested. This file
/// decides layout and nothing else.
struct RaceDayHubView: View {

    @Environment(AppSettings.self) private var appSettings
    @Environment(AppContainer.self) private var container

    @Query(filter: #Predicate<TrainingPlan> { $0.isActive == true })
    private var activePlans: [TrainingPlan]

    @Query private var profiles: [UserProfile]

    /// The newest hundred runs: more than the eight-week fitness sample the prediction
    /// draws on, and more than enough to find race day's own run, without loading a
    /// lifetime of history to answer a question about one week.
    @Query(RunWorkout.runsOnlyDescriptor(fetchLimit: 100))
    private var recentRuns: [RunWorkout]

    /// Which rung the split table is being drawn for. Starts on the goal the runner set.
    @State private var selectedTier: RaceGoal.Tier = .a

    /// Apple Intelligence's race plan, seeded from the last one saved so reopening the hub
    /// on an unchanged day shows it at once. Only drawn once it matches today's facts.
    @State private var briefing: RaceBriefingWording? = RaceBriefingStore.load()
    @State private var isWritingBriefing = false

    /// The course added for the goal race, if any; read from the device on open.
    @State private var storedCourse: StoredRaceCourse? = RaceCourseStore.load()
    @State private var isImportingCourse = false
    @State private var courseError: String?

    private var unit: UnitPreference { appSettings.unitPreference }

    private var racePlan: RaceDayPlan? {
        RaceDayPlan.resolve(
            profile: profiles.first,
            plan: activePlans.first,
            runs: recentRuns
        )
    }

    var body: some View {
        Group {
            if let racePlan = racePlan {
                content(racePlan)
            } else {
                StrideEmptyState(
                    "No goal race",
                    systemImage: "flag.checkered",
                    description: Text("Give your plan a race date and race day lives here.")
                )
            }
        }
        .background(Color.surfacePrimary)
        .navigationTitle("Race Day")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Content

    private func content(_ racePlan: RaceDayPlan) -> some View {
        ScrollView {
            // Two columns on a wide page (iPhone Duo open, in landscape): the race and the
            // goals on the leading side, the plan for the day on the trailing side. One
            // column is the old order.
            StrideColumns(spacing: 20) {
                header(racePlan)

                if let result = racePlan.result {
                    RaceResultCard(result: result, unit: unit)
                }

                if !racePlan.goals.isEmpty {
                    goalLadder(racePlan)
                }

                if let invite = invite(for: racePlan) {
                    RaceInviteCard(invite: invite)
                }
            } trailing: {
                if showsBriefing(racePlan) {
                    RaceBriefingCard(wording: currentBriefing(racePlan))
                }

                if let taper = racePlan.taper, racePlan.result == nil {
                    RaceTaperCard(status: taper, unit: unit)
                }

                if showsWeather(racePlan) {
                    RaceWeatherCard(racePlan: racePlan, runs: recentRuns, unit: unit)
                }

                if showsSplits(racePlan) {
                    RaceCourseCard(
                        stored: course(for: racePlan),
                        unit: unit,
                        errorMessage: courseError,
                        onAdd: {
                            courseError = nil
                            isImportingCourse = true
                        },
                        onRemove: removeCourse
                    )
                }

                if showsSplits(racePlan), let goal = selectedGoal(racePlan) {
                    let raceCourse = course(for: racePlan)?.course
                    RaceSplitsTable(
                        splits: racePlan.splits(for: goal, unit: unit, course: raceCourse),
                        goal: goal,
                        unit: unit,
                        pacedForCourse: raceCourse != nil
                    )
                }
            }
            .padding()
            .strideReadableWidth(hasColumns: true)
        }
        .task(id: briefingRequestKey(racePlan)) { await refreshBriefing(racePlan) }
        .fileImporter(
            isPresented: $isImportingCourse,
            allowedContentTypes: Self.courseFileTypes
        ) { result in
            importCourse(result, for: racePlan)
        }
    }

    // MARK: - Course

    /// A `.gpx` file whichever app on the device declares the type, plus plain XML for
    /// files saved with another extension.
    private static var courseFileTypes: [UTType] {
        [UTType(filenameExtension: "gpx"), .xml].compactMap { $0 }
    }

    /// The saved course when it was added for this race: same day, same distance.
    private func course(for racePlan: RaceDayPlan) -> StoredRaceCourse? {
        guard let storedCourse,
              storedCourse.applies(toRaceOn: racePlan.raceDate, distanceMeters: racePlan.distanceMeters)
        else { return nil }
        return storedCourse
    }

    private func importCourse(_ result: Result<URL, Error>, for racePlan: RaceDayPlan) {
        do {
            let url = try result.get()
            let imported = try RaceCourseStore.importCourse(from: url, raceDate: racePlan.raceDate)
            guard CoursePacing.matches(imported.course, distanceMeters: racePlan.distanceMeters) else {
                courseError = String(
                    localized: "That course is \(imported.course.lengthMeters.distanceString(unit: unit)), but your race is \(racePlan.distanceMeters.distanceString(unit: unit)).",
                    comment: "Race hub: the imported course is a different length from the goal race"
                )
                return
            }
            try RaceCourseStore.save(imported)
            courseError = nil
            withAnimation(AppAnimation.gentle) { storedCourse = imported }
        } catch let error as RaceCourseImportError {
            courseError = error.errorDescription
        } catch {
            // Cancelling the picker is not an error worth a line on the card.
            if (error as NSError).code != NSUserCancelledError {
                courseError = RaceCourseImportError.unreadable.errorDescription
            }
        }
    }

    private func removeCourse() {
        RaceCourseStore.remove()
        courseError = nil
        withAnimation(AppAnimation.gentle) { storedCourse = nil }
    }

    // MARK: - Race plan (Apple Intelligence)

    /// Whether the hub asks for a race plan at all: a race still to come with a goal
    /// time, AI Coach on, and not in UI tests or unit-test hosting.
    private func briefingEnabled(_ racePlan: RaceDayPlan) -> Bool {
        appSettings.aiInsightsEnabled
            && RaceBriefing.applies(to: racePlan)
            && !UITestingSupport.isEnabled
            && !UITestingSupport.isHostingUnitTests
    }

    /// Drawn while writing and once written; a failed or rejected draft draws nothing.
    private func showsBriefing(_ racePlan: RaceDayPlan) -> Bool {
        briefingEnabled(racePlan) && (currentBriefing(racePlan) != nil || isWritingBriefing)
    }

    /// The saved briefing, when it was written from exactly these facts in this unit.
    private func currentBriefing(_ racePlan: RaceDayPlan) -> RaceBriefingWording? {
        guard let briefing,
              briefing.source == RaceBriefing.prompt(for: racePlan, unit: unit, course: course(for: racePlan)?.course)
        else { return nil }
        return briefing
    }

    /// Moves with the facts, the unit, the AI Coach switch and the model choice only.
    private func briefingRequestKey(_ racePlan: RaceDayPlan) -> String {
        [
            RaceBriefing.prompt(for: racePlan, unit: unit, course: course(for: racePlan)?.course),
            briefingEnabled(racePlan) ? "on" : "off",
            appSettings.aiProvider.rawValue,
        ].joined(separator: "\n")
    }

    private func refreshBriefing(_ racePlan: RaceDayPlan) async {
        guard briefingEnabled(racePlan), currentBriefing(racePlan) == nil else { return }
        isWritingBriefing = true
        let fresh = await container.aiCoachService.writeRaceBriefing(
            for: racePlan,
            unit: unit,
            course: course(for: racePlan)?.course,
            provider: appSettings.aiProvider
        )
        // A newer set of facts (or setting) has already started its own request.
        guard !Task.isCancelled else { return }
        isWritingBriefing = false
        guard let fresh else { return }
        briefing = fresh
        RaceBriefingStore.save(fresh)
    }

    /// The split table is a plan for a race that has not been run. Once the result is in
    /// the log it is history, and the result card is the thing worth reading.
    private func showsSplits(_ racePlan: RaceDayPlan) -> Bool {
        racePlan.result == nil
    }

    /// A start time and a forecast are about a race still to come. Once it is run — or
    /// the day has passed without a result syncing — the card has nothing left to say.
    private func showsWeather(_ racePlan: RaceDayPlan) -> Bool {
        guard racePlan.result == nil else { return false }
        if case .finished = racePlan.phase { return false }
        return true
    }

    /// The link "Train with a friend" shares, while there is still time to train for the
    /// race: not on the day, and not after it.
    private func invite(for racePlan: RaceDayPlan) -> RaceInvite? {
        switch racePlan.phase {
        case .building, .raceWeek:
            return RaceInvite(racePlan: racePlan)
        case .raceDay, .finished:
            return nil
        }
    }

    private func selectedGoal(_ racePlan: RaceDayPlan) -> RaceGoal? {
        racePlan.goals.first { $0.tier == selectedTier } ?? racePlan.goals.first
    }

    // MARK: - Header

    private func header(_ racePlan: RaceDayPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: racePlan.raceName)
                .font(.dsTitle2)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(verbatim: subtitle(racePlan))
                .font(.dsSubhead)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            countdownHero(racePlan)
                .padding(.top, AppSpacing.sm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        // The race is what this screen is about, so its countdown is the hero.
        .heroCard()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func countdownHero(_ racePlan: RaceDayPlan) -> some View {
        switch racePlan.phase {
        case .building(let days), .raceWeek(let days):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "\(days)")
                    .font(.dsLargeTitle)
                    .monospacedDigit()
                    .foregroundStyle(.brandText)
                Text(days == 1 ? "day to go" : "days to go")
                    .font(.dsTitle3)
                    .foregroundStyle(.secondary)
            }
        case .raceDay:
            Text("Today is the day")
                .font(.dsTitle3)
                .foregroundStyle(.success)
        case .finished(let days):
            Text(days == 1 ? "Raced yesterday" : "Raced \(days) days ago")
                .font(.dsTitle3)
                .foregroundStyle(.secondary)
        }
    }

    private func subtitle(_ racePlan: RaceDayPlan) -> String {
        [
            racePlan.raceType.localizedName,
            racePlan.distanceMeters.distanceString(unit: unit),
            racePlan.raceDate.formatted(.dateTime.weekday(.wide).day().month(.wide))
        ].joined(separator: " · ")
    }

    // MARK: - Goal ladder

    private func goalLadder(_ racePlan: RaceDayPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GOAL TIMES")
                .strideEyebrow()
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(racePlan.goals) { goal in
                    Button {
                        withAnimation(AppAnimation.snappy) { selectedTier = goal.tier }
                    } label: {
                        RaceGoalRow(
                            goal: goal,
                            unit: unit,
                            isSelected: goal.tier == selectedTier,
                            achieved: racePlan.result?.tierAchieved == goal.tier
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if let predicted = racePlan.predictedFinishSeconds {
                Text(verbatim: predictionText(predicted, racePlan: racePlan))
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func predictionText(_ predicted: TimeInterval, racePlan: RaceDayPlan) -> String {
        let base = String(
            localized: "Your recent quality sessions predict \(predicted.durationString).",
            comment: "Race hub: predicted finish from training history"
        )
        guard let goal = racePlan.goal, predicted > goal.finishSeconds else { return base }
        let stretch = String(
            localized: "The A goal is ahead of that — a good day, not a given.",
            comment: "Race hub: note shown when the A goal is faster than the prediction"
        )
        return "\(base) \(stretch)"
    }
}

// MARK: - RaceGoalRow

/// One rung of the ladder. Selecting it redraws the split table against that pace.
private struct RaceGoalRow: View {

    let goal: RaceGoal
    let unit: UnitPreference
    let isSelected: Bool
    let achieved: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: goal.tier.localizedName)
                        .font(.bodyStrong)
                    if achieved {
                        StrideIcon(name: .check, size: 12, color: .success, strokeWeight: 2.4)
                    }
                }
                Text(verbatim: goal.tier.localizedSubtitle)
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: goal.finishSeconds.durationString)
                    .font(.metricS)
                    .monospacedDigit()
                Text(verbatim: goal.paceSecondsPerKm.paceString(unit: unit))
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppSpacing.lg)
        .strideCard()
        // The chosen rung: the card's own ground, outlined in brand.
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .strokeBorder(Color.brand, lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - RaceSplitsTable

/// The clock to check against, one row per marker in the runner's own unit.
private struct RaceSplitsTable: View {

    let splits: [RaceSplit]
    let goal: RaceGoal
    let unit: UnitPreference
    /// True when the rows are grade-adjusted over the race's course.
    var pacedForCourse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("SPLITS")
                    .strideEyebrow()
                Text(verbatim: goal.tier.localizedName)
                    .strideEyebrow()
                    .foregroundStyle(.brandText)
            }
            .foregroundStyle(.secondary)

            if pacedForCourse && !splits.isEmpty {
                Text("Paced for the course at even effort: slower up the hills, quicker down them.")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if splits.isEmpty {
                Text("No splits to show for this distance.")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(splits) { split in
                        row(split)
                        if split.id != splits.last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
                // With the rows' own `md` inset, the table's edge matches every card's `lg`.
                .padding(.horizontal, AppSpacing.xs)
                .padding(.vertical, AppSpacing.sm)
                .strideCard()
            }
        }
    }

    private func row(_ split: RaceSplit) -> some View {
        HStack {
            Text(verbatim: markerLabel(split))
                .font(.dsSubhead)
                .foregroundStyle(split.isPartial ? .secondary : .primary)
            if let change = elevationLabel(split) {
                Text(verbatim: change)
                    .font(.dsCaption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: AppSpacing.sm)
            if pacedForCourse, let pace = segmentPace(split) {
                Text(verbatim: pace.paceString(unit: unit))
                    .font(.dsCaption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: split.elapsedSeconds.durationString)
                .font(.dsSubhead)
                .monospacedDigit()
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .accessibilityElement(children: .combine)
    }

    /// The rise or fall since the previous marker, when the table is paced for a course
    /// and the change is big enough to read as a hill rather than rounding.
    private func elevationLabel(_ split: RaceSplit) -> String? {
        guard let change = split.elevationChangeMeters, abs(change) >= 2 else { return nil }
        let amount = abs(change).elevationString(unit: unit)
        return change > 0
            ? String(localized: "↑ \(amount)", comment: "Race splits table: climb since the last marker")
            : String(localized: "↓ \(amount)", comment: "Race splits table: descent since the last marker")
    }

    /// This stretch's own pace, in seconds per kilometre.
    private func segmentPace(_ split: RaceSplit) -> Double? {
        guard let index = splits.firstIndex(where: { $0.id == split.id }) else { return nil }
        let startDistance = index == 0 ? 0 : splits[index - 1].distanceMeters
        let startTime = index == 0 ? 0 : splits[index - 1].elapsedSeconds
        let meters = split.distanceMeters - startDistance
        guard meters > 0 else { return nil }
        return (split.elapsedSeconds - startTime) / (meters / 1_000)
    }

    /// Full markers are numbered in the runner's unit; the leftover final segment is the
    /// finish, because "43" on a marathon table would read as a forty-third kilometre.
    private func markerLabel(_ split: RaceSplit) -> String {
        if split.isPartial {
            return String(localized: "Finish", comment: "Race splits table: the final part-marker row")
        }
        switch unit {
        case .metric:
            return String(localized: "\(split.marker) km", comment: "Race splits table: kilometre marker")
        case .imperial:
            return String(localized: "\(split.marker) mi", comment: "Race splits table: mile marker")
        }
    }
}

// MARK: - RaceTaperCard

/// What the plan is doing about the race this week.
private struct RaceTaperCard: View {

    let status: RaceTaperStatus
    let unit: UnitPreference

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Above the card, as every other section header on the screen is.
            Text("THIS WEEK")
                .strideEyebrow()
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 12) {
                Text(verbatim: status.phase.localizedName)
                    .font(.dsCaption.weight(.semibold))
                    .foregroundStyle(.onFill)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, AppSpacing.xs)
                    .background(Capsule().fill(status.phase.tint))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Week \(status.weekNumber) of \(status.totalWeeks)")
                        .font(.bodyStrong)
                    Text(verbatim: volumeLine)
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(AppSpacing.lg)
            .strideCard()
        }
        .accessibilityElement(children: .combine)
    }

    /// Only says "below your peak" once the drop is big enough to be the taper rather
    /// than a week that happens to be slightly lighter.
    private var volumeLine: String {
        let planned = status.plannedKm.weeklyDistanceString(unit: unit)
        guard status.reductionFromPeak >= 0.05 else { return planned }
        let percent = Int((status.reductionFromPeak * 100).rounded())
        return String(
            localized: "\(planned) · \(percent)% below your peak week",
            comment: "Race hub taper card: this week's volume against the plan's biggest week"
        )
    }
}

// MARK: - RaceResultCard

/// How it went, once the race run is in the log.
private struct RaceResultCard: View {

    let result: RaceResult
    let unit: UnitPreference

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.15))
                        .frame(width: 48, height: 48)
                    StrideIcon(name: .trophy, size: 20, color: tint, strokeWeight: 2.2)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: result.finishSeconds.durationString)
                        .font(.metricM)
                        .foregroundStyle(.primary)
                    Text(verbatim: detail)
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            Text(verbatim: verdict)
                .font(.dsSubhead)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // The outcome shows in the trophy's tint, not a tinted ground.
        .padding(AppSpacing.lg)
        .strideCard()
        .accessibilityElement(children: .combine)
    }

    private var tint: Color { result.tierAchieved == nil ? .brand : .success }

    private var detail: String {
        [
            result.distanceMeters.distanceString(unit: unit),
            result.paceSecondsPerKm.paceString(unit: unit)
        ].joined(separator: " · ")
    }

    /// States the gap against the A goal either way. A race that missed it is still a
    /// race that was run, so the card reports the number rather than going quiet.
    private var verdict: String {
        guard let inside = result.secondsInsideGoal else {
            return String(localized: "Race logged.", comment: "Race hub result with no goal time set")
        }
        let gap = abs(inside).durationString
        if inside >= 0 {
            return String(
                localized: "A goal hit, \(gap) inside your goal time.",
                comment: "Race hub result: the finish beat the goal the runner set"
            )
        }
        if let tier = result.tierAchieved {
            return String(
                localized: "\(tier.localizedName) hit, \(gap) outside your A goal.",
                comment: "Race hub result: the finish beat a lower rung but not the goal itself"
            )
        }
        return String(
            localized: "\(gap) outside your goal time.",
            comment: "Race hub result: the finish came in outside every goal rung"
        )
    }
}
