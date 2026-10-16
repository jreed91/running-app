import SwiftUI
import SwiftData

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
                    "No Goal Race",
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
            VStack(alignment: .leading, spacing: 20) {
                header(racePlan)

                if let result = racePlan.result {
                    RaceResultCard(result: result, unit: unit)
                }

                if !racePlan.goals.isEmpty {
                    goalLadder(racePlan)
                }

                if let taper = racePlan.taper, racePlan.result == nil {
                    RaceTaperCard(status: taper, unit: unit)
                }

                if showsWeather(racePlan) {
                    RaceWeatherCard(racePlan: racePlan, runs: recentRuns, unit: unit)
                }

                if showsSplits(racePlan), let goal = selectedGoal(racePlan) {
                    RaceSplitsTable(splits: racePlan.splits(for: goal, unit: unit), goal: goal, unit: unit)
                }
            }
            .padding()
        }
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
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func countdownHero(_ racePlan: RaceDayPlan) -> some View {
        switch racePlan.phase {
        case .building(let days), .raceWeek(let days):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "\(days)")
                    .font(.dsLargeTitle)
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
                    .font(.caption)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: goal.finishSeconds.durationString)
                    .font(.metricS)
                    .monospacedDigit()
                Text(verbatim: goal.paceSecondsPerKm.paceString(unit: unit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .fill(isSelected ? Color.brand.opacity(0.12) : Color.surfaceSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .strokeBorder(isSelected ? Color.brand.opacity(0.35) : .clear, lineWidth: 1)
                )
        )
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

            if splits.isEmpty {
                Text("No splits to show for this distance.")
                    .font(.caption)
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
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .fill(Color.surfaceSecondary)
                )
            }
        }
    }

    private func row(_ split: RaceSplit) -> some View {
        HStack {
            Text(verbatim: markerLabel(split))
                .font(.dsSubhead)
                .foregroundStyle(split.isPartial ? .secondary : .primary)
            Spacer(minLength: AppSpacing.sm)
            Text(verbatim: split.elapsedSeconds.durationString)
                .font(.dsSubhead)
                .monospacedDigit()
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .accessibilityElement(children: .combine)
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.surfaceSecondary)
        )
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            Text(verbatim: verdict)
                .font(.dsSubhead)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(tint.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.lg)
                        .strokeBorder(tint.opacity(0.2), lineWidth: 0.5)
                )
        )
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
