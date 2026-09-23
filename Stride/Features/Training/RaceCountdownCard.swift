import SwiftUI

// MARK: - RaceCountdownCard

/// The race-day hub's entry point: which race, how far off it is, and what it is being
/// run for.
///
/// Drawn on both the Plan tab and — inside the final fortnight — the dashboard, from one
/// definition, because the two screens telling a runner different numbers of days is the
/// drift a shared card exists to prevent. It carries no actions of its own: both call
/// sites wrap it in a `NavigationLink` to ``RaceDayHubView``, so the whole card is the
/// tap target.
struct RaceCountdownCard: View {

    let racePlan: RaceDayPlan
    let unit: UnitPreference

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            iconBadge

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: racePlan.raceName)
                    .font(.bodyStrong)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                countdownLine

                Text(verbatim: detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            StrideIcon(name: .chevronRight, size: 13, color: .secondary, strokeWeight: 2)
                .padding(.top, 4)
        }
        .padding(18)
        .background(cardBackground)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: - Pieces

    private var iconBadge: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.15))
                .frame(width: 48, height: 48)
            StrideIcon(name: .flag, size: 20, color: tint, strokeWeight: 2.2)
        }
    }

    @ViewBuilder
    private var countdownLine: some View {
        switch racePlan.phase {
        case .building(let days), .raceWeek(let days):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(days)")
                    .font(.dsTitle2)
                    .foregroundStyle(tint)
                Text(days == 1 ? "day to go" : "days to go")
                    .font(.dsSubhead)
                    .foregroundStyle(.secondary)
            }
        case .raceDay:
            Text("Race day")
                .font(.dsTitle3)
                .foregroundStyle(tint)
        case .finished(let days):
            Text(days == 1 ? "Raced yesterday" : "Raced \(days) days ago")
                .font(.dsSubhead)
                .foregroundStyle(.secondary)
        }
    }

    /// The race date before it is run; the finish time once it has been.
    private var detailLine: String {
        if let result = racePlan.result {
            return result.finishSeconds.durationString
        }
        if let goal = racePlan.goal {
            let target = String(
                localized: "Goal \(goal.finishSeconds.durationString)",
                comment: "Race countdown card: the runner's goal finish time"
            )
            return "\(dateText) · \(target)"
        }
        return dateText
    }

    private var dateText: String {
        racePlan.raceDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    // MARK: - Styling

    /// Brand while the race is still ahead, `success` once it is the day or behind them —
    /// the app's existing vocabulary for "this is the thing" and "this went well".
    private var tint: Color {
        racePlan.phase.isBeforeRace ? .brand : .success
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: AppRadius.lg)
            .fill(
                LinearGradient(
                    colors: [tint.opacity(0.10), tint.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(tint.opacity(0.2), lineWidth: 0.5)
            )
    }
}

// MARK: - Preview

#Preview {
    let goals = RaceDayPlan.goals(forGoalSeconds: 12_600, distanceMeters: 42_195)
    let plan = RaceDayPlan(
        raceName: "Dublin Marathon",
        raceType: .marathon,
        distanceMeters: 42_195,
        raceDate: Date().adding(days: 12),
        phase: .building(daysOut: 12),
        goals: goals,
        predictedFinishSeconds: 12_900,
        taper: nil,
        result: nil
    )

    return VStack(spacing: 16) {
        RaceCountdownCard(racePlan: plan, unit: .metric)
        RaceCountdownCard(
            racePlan: RaceDayPlan(
                raceName: "Dublin Marathon",
                raceType: .marathon,
                distanceMeters: 42_195,
                raceDate: Date(),
                phase: .raceDay,
                goals: goals,
                predictedFinishSeconds: 12_900,
                taper: nil,
                result: nil
            ),
            unit: .metric
        )
    }
    .padding()
    .background(Color.surfacePrimary)
}
