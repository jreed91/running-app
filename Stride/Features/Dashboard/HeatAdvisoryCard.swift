import SwiftUI

// MARK: - HeatAdvisoryCard

/// The dashboard's "your next session is going to be hot" prompt.
///
/// Deliberately the same shape as ``MissedWorkoutsRecoveryCard``: a coloured header, the
/// facts, then two actions and a way out. Both cards interrupt the screen to ask the
/// runner to change their plan, and a runner who has learned what one of them does should
/// not have to learn the other.
///
/// It states the conditions rather than only the verdict. "Very hot" is a label the runner
/// has to take on trust; "feels like 31°, dew point 22°" is the thing they can check
/// against the window, and it is what makes the recommendation legible rather than
/// oracular.
struct HeatAdvisoryCard: View {
    let advisory: HeatAdvisory
    let unit: UnitPreference
    let onAdapt: () -> Void
    let onKeepAsPlanned: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            header
            conditionsRow
            if let cooler = advisory.cooler {
                coolerHourRow(cooler)
            }
            AppleWeatherAttribution()
            Divider().opacity(0.5)
            actionButtons
        }
        .padding(AppSpacing.lg)
        .background(cardBackground)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                    .frame(width: 48, height: 48)
                StrideIcon(name: .flame, size: 20, color: tint, strokeWeight: 2.2)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.bodyStrong)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(advisory.tier.localizedName) at \(startTimeText)")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Conditions

    private var conditionsRow: some View {
        HStack(spacing: 0) {
            conditionItem(
                value: advisory.conditions.feelsLikeString(unit: unit),
                label: String(localized: "Feels like", comment: "Heat advisory metric label")
            )
            Spacer(minLength: AppSpacing.sm)
            conditionItem(
                value: advisory.conditions.dewPointString(unit: unit),
                label: String(localized: "Dew point", comment: "Heat advisory metric label")
            )
            Spacer(minLength: AppSpacing.sm)
            conditionItem(
                value: "\(Int(advisory.conditions.humidityPercent.rounded()))%",
                label: String(localized: "Humidity", comment: "Heat advisory metric label")
            )
        }
    }

    private func conditionItem(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.bodyStrong)
                .foregroundStyle(.primary)
            Text(label)
                .font(.dsCaption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private func coolerHourRow(_ cooler: HeatAdvisory.CoolerOption) -> some View {
        HStack(spacing: 8) {
            StrideIcon(name: .timer, size: 14, color: .success, strokeWeight: 2)
            Text("It's \(cooler.conditions.feelsLikeString(unit: unit)) at \(cooler.start.formatted(.dateTime.hour().minute())) — the coolest hour worth running in.")
                .font(.dsCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 8) {
            Button(action: onAdapt) {
                Text(adaptTitle)
            }
            .buttonStyle(.strideButton(.secondary, compact: true)) // Start is the screen's one primary

            Button("Run it as planned", action: onKeepAsPlanned)
                .buttonStyle(.strideButton(.quiet, compact: true))
        }
    }

    // MARK: - Styling

    /// Amber up to `.high`, red once the recommendation is to stop running hard outside.
    /// The colour is carrying the same threshold `HeatAdaptationPolicy` does, so a runner
    /// who never opens the sheet still sees the distinction.
    private var tint: Color {
        HeatAdaptationPolicy.convertsQualityToEasy(advisory.tier) ? .destructive : .warning
    }

    /// Named from the session's own day: an advisory still up on the morning of the run
    /// used to call it "tomorrow's".
    private var headline: String {
        let type = advisory.workoutType.localizedName
        switch advisory.sessionDay() {
        case .today:
            return String(localized: "Today's \(type) falls in the heat", comment: "Heat advisory card title")
        case .tomorrow:
            return String(localized: "Tomorrow's \(type) falls in the heat", comment: "Heat advisory card title")
        case .later(let weekday):
            return String(
                localized: "\(weekday)'s \(type) falls in the heat",
                comment: "Heat advisory card title; the first value is a weekday"
            )
        }
    }

    private var adaptTitle: String {
        switch advisory.sessionDay() {
        case .today:
            return String(localized: "Adapt today's workout", comment: "Heat advisory card action")
        case .tomorrow:
            return String(localized: "Adapt tomorrow's workout", comment: "Heat advisory card action")
        case .later(let weekday):
            return String(
                localized: "Adapt \(weekday)'s workout",
                comment: "Heat advisory card action; the value is a weekday"
            )
        }
    }

    private var startTimeText: String {
        advisory.plannedStart.formatted(.dateTime.hour().minute())
    }

    /// A plain card, like every other card on Home: the status colour is on the icon
    /// tile and the action, not the card's ground.
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
            .fill(Color.surfaceSecondary)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .strokeBorder(Color.cardStroke, lineWidth: 1)
            )
    }
}

// MARK: - Session day

extension HeatAdvisory {
    /// Where the session falls relative to today, for copy that names its day.
    enum SessionDay: Equatable {
        case today
        case tomorrow
        /// Any other day, by its wide weekday name.
        case later(weekday: String)
    }

    /// Read from `scheduledDate`, the plan's day: the advisory is raised the evening
    /// before but stays up through the session's own day.
    func sessionDay(calendar: Calendar = .current) -> SessionDay {
        if calendar.isDateInToday(scheduledDate) { return .today }
        if calendar.isDateInTomorrow(scheduledDate) { return .tomorrow }
        return .later(weekday: scheduledDate.formatted(.dateTime.weekday(.wide)))
    }
}

#Preview {
    let hot = WorkoutWeather(
        temperatureCelsius: 31,
        feelsLikeCelsius: 35,
        humidityPercent: 62,
        dewPointCelsius: 23,
        windSpeedKmh: 6,
        conditionSymbol: "sun.max.fill",
        conditionDescription: "Clear"
    )
    let cool = WorkoutWeather(
        temperatureCelsius: 22,
        feelsLikeCelsius: 23,
        humidityPercent: 78,
        dewPointCelsius: 18,
        windSpeedKmh: 8,
        conditionSymbol: "cloud.fill",
        conditionDescription: "Cloudy"
    )

    return ScrollView {
        VStack(spacing: 20) {
            HeatAdvisoryCard(
                advisory: HeatAdvisory(
                    workoutID: UUID(),
                    workoutType: .tempo,
                    scheduledDate: Date().adding(days: 1),
                    plannedStart: Date().adding(days: 1),
                    conditions: hot,
                    tier: .severe,
                    cooler: HeatAdvisory.CoolerOption(
                        start: Date().adding(days: 1),
                        conditions: cool,
                        tier: .moderate
                    ),
                    generatedAt: Date()
                ),
                unit: .metric,
                onAdapt: {},
                onKeepAsPlanned: {}
            )
            HeatAdvisoryCard(
                advisory: HeatAdvisory(
                    workoutID: UUID(),
                    workoutType: .longRun,
                    scheduledDate: Date().adding(days: 1),
                    plannedStart: Date().adding(days: 1),
                    conditions: cool,
                    tier: .moderate,
                    cooler: nil,
                    generatedAt: Date()
                ),
                unit: .imperial,
                onAdapt: {},
                onKeepAsPlanned: {}
            )
        }
        .padding()
    }
}
