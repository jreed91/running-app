import Foundation

// MARK: - YearRecapCard

/// One card of the year-in-running recap, as display strings.
///
/// Every card shares one layout (`YearRecapCardView`): an eyebrow, one big figure, a line
/// under it, and then at most one of: a row of stats, the month bars, or the best-effort
/// rows. Keeping the cards as plain data means the choice of *which* cards appear, and
/// every string on them, is unit-tested here rather than living in a view body.
struct YearRecapCard: Equatable, Identifiable, Sendable {

    enum Kind: String, Sendable, CaseIterable {
        case cover, distance, consistency, months, longestRun, bestEfforts, fitness, outro
        /// Plan Replay only: the goal race's result.
        case race
    }

    struct Stat: Equatable, Sendable {
        let label: String
        let value: String
    }

    struct MonthBar: Equatable, Sendable, Identifiable {
        /// 1 = January.
        let month: Int
        /// One-letter label, from the calendar ("J", "F", ...).
        let label: String
        /// `0...1`, the biggest month at 1.
        let height: Double
        let isBiggest: Bool
        var id: Int { month }
    }

    struct Effort: Equatable, Sendable, Identifiable {
        let distance: String
        let time: String
        let date: String
        let isPersonalBest: Bool
        var id: String { distance }
    }

    let kind: Kind
    /// Small uppercase line at the top, e.g. "2026 SO FAR".
    let eyebrow: String
    /// The one big figure or phrase.
    let headline: String
    /// The line under it.
    let caption: String
    var stats: [Stat] = []
    var months: [MonthBar] = []
    var efforts: [Effort] = []

    var id: Kind { kind }

    /// What VoiceOver reads for the card in the app.
    var accessibilityText: String {
        var parts = [eyebrow, headline, caption]
        parts += stats.map { "\($0.label): \($0.value)" }
        parts += efforts.map { effort in
            "\(effort.distance): \(effort.time), \(effort.date)" + (effort.isPersonalBest ? ", personal best" : "")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ". ")
    }
}

// MARK: - YearRecapCards

/// Turns a `YearInRunning` into the ordered cards of the recap.
///
/// A card is left out when its numbers have nothing worth sharing (no best efforts, a
/// fitness change too small to call, no climb), so the story never shows an empty card
/// or a dash. Fitness only appears when it went *up*: the recap is a celebration, and a
/// drop over a year with an injury in it is not something anyone wants on a share card.
enum YearRecapCards {

    /// Fitness must rise at least this much (percent of the early VDOT) to get a card.
    static let minimumFitnessGainPercent = 1.0

    static func make(
        from year: YearInRunning,
        unit: UnitPreference,
        calendar: Calendar = .current
    ) -> [YearRecapCard] {
        guard year.hasEnoughForRecap else { return [] }

        let yearLabel = year.isInProgress ? "\(year.year) so far" : "\(year.year)"
        let eyebrow = yearLabel.uppercased()

        var cards: [YearRecapCard] = []

        cards.append(YearRecapCard(
            kind: .cover,
            eyebrow: "STRIDE",
            headline: "\(year.year)",
            caption: year.isInProgress ? "My year in running, so far" : "My year in running"
        ))

        cards.append(distanceCard(year, unit: unit, eyebrow: eyebrow))
        cards.append(consistencyCard(year, eyebrow: eyebrow))

        if let months = monthsCard(year, unit: unit, eyebrow: eyebrow, calendar: calendar) {
            cards.append(months)
        }
        if let longest = longestRunCard(year, unit: unit, eyebrow: eyebrow, calendar: calendar) {
            cards.append(longest)
        }
        if let efforts = bestEffortsCard(year, eyebrow: eyebrow, calendar: calendar) {
            cards.append(efforts)
        }
        if let fitness = fitnessCard(year, eyebrow: eyebrow) {
            cards.append(fitness)
        }

        cards.append(YearRecapCard(
            kind: .outro,
            eyebrow: eyebrow,
            headline: "On to \(year.year + 1)",
            caption: year.isInProgress
                ? "There's still time to add to it."
                : "Same time next year."
        ))

        return cards
    }

    // MARK: Cards

    private static func distanceCard(_ year: YearInRunning, unit: UnitPreference, eyebrow: String) -> YearRecapCard {
        var stats = [
            YearRecapCard.Stat(label: "Runs", value: year.runCount.formatted()),
            YearRecapCard.Stat(label: "Time", value: hoursString(year.totalSeconds)),
        ]
        if let climb = year.elevationGainMeters {
            stats.append(YearRecapCard.Stat(label: "Climb", value: wholeElevation(climb, unit: unit)))
        }
        return YearRecapCard(
            kind: .distance,
            eyebrow: eyebrow,
            headline: wholeDistance(year.totalMeters, unit: unit),
            caption: previousYearLine(year) ?? "Every one of them counted.",
            stats: stats
        )
    }

    private static func consistencyCard(_ year: YearInRunning, eyebrow: String) -> YearRecapCard {
        let caption = year.usualTimeOfDay.map { time in
            "Days I ran. Mostly \(article(for: time.runnerLabel)) \(time.runnerLabel) runner."
        } ?? "Days I ran."
        return YearRecapCard(
            kind: .consistency,
            eyebrow: eyebrow,
            headline: days(year.activeDays),
            caption: caption,
            stats: [YearRecapCard.Stat(label: "Longest streak", value: days(year.longestStreakDays))]
        )
    }

    private static func monthsCard(
        _ year: YearInRunning,
        unit: UnitPreference,
        eyebrow: String,
        calendar: Calendar
    ) -> YearRecapCard? {
        guard let biggest = year.biggestMonth,
              let peak = year.monthlyMeters.max(), peak > 0 else { return nil }
        let letters = calendar.veryShortStandaloneMonthSymbols
        let names = calendar.standaloneMonthSymbols
        let bars = year.monthlyMeters.enumerated().map { index, meters in
            YearRecapCard.MonthBar(
                month: index + 1,
                label: letters.indices.contains(index) ? letters[index] : "",
                height: meters / peak,
                isBiggest: index + 1 == biggest
            )
        }
        let name = names.indices.contains(biggest - 1) ? names[biggest - 1] : ""
        return YearRecapCard(
            kind: .months,
            eyebrow: eyebrow,
            headline: name,
            caption: "My biggest month: \(wholeDistance(peak, unit: unit)).",
            months: bars
        )
    }

    private static func longestRunCard(
        _ year: YearInRunning,
        unit: UnitPreference,
        eyebrow: String,
        calendar: Calendar
    ) -> YearRecapCard? {
        guard let run = year.longestRun else { return nil }
        return YearRecapCard(
            kind: .longestRun,
            eyebrow: eyebrow,
            headline: run.meters.distanceString(unit: unit),
            caption: "My longest run, on \(dayMonth(run.date, calendar: calendar)).",
            stats: [
                YearRecapCard.Stat(label: "Time", value: run.seconds.durationString),
                YearRecapCard.Stat(
                    label: "Pace",
                    value: (run.seconds / run.meters * 1_000).paceString(unit: unit)
                ),
            ]
        )
    }

    private static func bestEffortsCard(
        _ year: YearInRunning,
        eyebrow: String,
        calendar: Calendar
    ) -> YearRecapCard? {
        guard !year.bestEfforts.isEmpty else { return nil }
        let efforts = year.bestEfforts.map { effort in
            YearRecapCard.Effort(
                distance: effort.distance.rawValue,
                time: effort.run.seconds.durationString,
                date: dayMonth(effort.run.date, calendar: calendar),
                isPersonalBest: effort.isPersonalBest
            )
        }
        let bests = efforts.filter(\.isPersonalBest).count
        let headline: String
        switch bests {
        case 0: headline = "Fastest times"
        case 1: headline = "1 personal best"
        default: headline = "\(bests) personal bests"
        }
        return YearRecapCard(
            kind: .bestEfforts,
            eyebrow: eyebrow,
            headline: headline,
            caption: "My quickest at each distance this year.",
            efforts: efforts
        )
    }

    private static func fitnessCard(_ year: YearInRunning, eyebrow: String) -> YearRecapCard? {
        guard let change = year.fitnessChange, change.startVDOT > 0 else { return nil }
        let percent = change.delta / change.startVDOT * 100
        guard percent >= minimumFitnessGainPercent else { return nil }
        return YearRecapCard(
            kind: .fitness,
            eyebrow: eyebrow,
            headline: "+\(Int(percent.rounded()))%",
            caption: "Fitter than I started, going by my hardest sessions.",
            stats: [
                YearRecapCard.Stat(label: "Fitness score", value: String(format: "%.1f → %.1f", change.startVDOT, change.endVDOT)),
            ]
        )
    }

    // MARK: Formatting

    /// "+25% on 2025", "Same as 2025", "12% less than 2025"; `nil` with no previous year.
    static func previousYearLine(_ year: YearInRunning) -> String? {
        guard let change = year.changeFromPreviousYear else { return nil }
        let percent = Int((change * 100).rounded())
        let previous = year.year - 1
        if percent == 0 { return "About the same as \(previous)." }
        if percent > 0 { return "\(percent)% further than \(previous)." }
        // A smaller year is still a year of running; say it plainly, without a minus sign.
        return "\(-percent)% less than \(previous), and still out there."
    }

    /// Distance with no decimals and grouping, e.g. "1,204 km". Totals this size don't need
    /// tenths, and "1204.3 km" reads as a measurement rather than a year.
    static func wholeDistance(_ meters: Double, unit: UnitPreference) -> String {
        let value = Int(meters.distanceValue(unit: unit).rounded())
        return "\(value.formatted()) \(unit == .metric ? "km" : "mi")"
    }

    static func wholeElevation(_ meters: Double, unit: UnitPreference) -> String {
        switch unit {
        case .metric: return "\(Int(meters.rounded()).formatted()) m"
        case .imperial: return "\(Int((meters * 3.28084).rounded()).formatted()) ft"
        }
    }

    /// "142 hours", or "45 minutes" for a short year.
    static func hoursString(_ seconds: Double) -> String {
        let hours = Int((seconds / 3_600).rounded(.down))
        if hours >= 1 { return hours == 1 ? "1 hour" : "\(hours.formatted()) hours" }
        let minutes = Int((seconds / 60).rounded())
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    static func days(_ count: Int) -> String {
        count == 1 ? "1 day" : "\(count.formatted()) days"
    }

    static func dayMonth(_ date: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.wide)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        if let locale = calendar.locale { style.locale = locale }
        return date.formatted(style)
    }

    /// "an" before a vowel sound, for "an early-morning runner" / "an evening runner".
    private static func article(for word: String) -> String {
        guard let first = word.lowercased().first else { return "a" }
        return "aeiou".contains(first) ? "an" : "a"
    }
}
