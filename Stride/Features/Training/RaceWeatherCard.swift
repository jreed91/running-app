import SwiftUI

// MARK: - RaceWeatherCard

/// The race's start time and, once it is in range, the forecast for it (A10).
///
/// Asks for a start time when this race has none, because a forecast is for an hour and
/// the app stored only a date. With one, it shows the conditions at the start and at the
/// expected finish, and the heat tier for the worse of the two with the pace cost the
/// heat advisories already use.
///
/// The forecast is for where the runner last ran (`HeatAdvisoryService.usualRunLocation`),
/// not the race venue — Stride stores no race location — and the card says so.
struct RaceWeatherCard: View {

    let racePlan: RaceDayPlan
    let runs: [RunWorkout]
    let unit: UnitPreference

    @Environment(AppSettings.self) private var appSettings
    @Environment(AppContainer.self) private var container

    @State private var forecast: RaceDayForecast?
    @State private var isLoading = false
    @State private var editingStartTime = false

    /// The start as an instant, when a start time has been entered for *this* race.
    private var start: Date? {
        appSettings.raceStartTime?.startDate(forRaceDate: racePlan.raceDate)
    }

    /// The finish time the runner is aiming at, else what their fitness predicts.
    private var expectedDuration: TimeInterval? {
        racePlan.goal?.finishSeconds ?? racePlan.predictedFinishSeconds
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RACE WEATHER")
                .font(.sectionHeader)
                .foregroundStyle(.secondary)

            if let start {
                startRow(start)
                forecastContent(start)
            } else {
                Text("Add your start time and the forecast for it shows here from ten days out.")
                    .font(.dsSubhead)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Add start time") { editingStartTime = true }
                    .buttonStyle(.strideButton(.secondary, compact: true, fullWidth: false))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.surfaceSecondary)
        )
        .task(id: start) { await loadForecast() }
        .sheet(isPresented: $editingStartTime) {
            RaceStartTimeEditor(raceDate: racePlan.raceDate, initialStart: start)
                .environment(appSettings)
        }
    }

    private func startRow(_ start: Date) -> some View {
        HStack {
            Text("Starts at \(start.formatted(date: .omitted, time: .shortened))")
                .font(.bodyStrong)
            Spacer()
            Button("Edit") { editingStartTime = true }
                .font(.dsSubhead)
        }
    }

    @ViewBuilder
    private func forecastContent(_ start: Date) -> some View {
        if !RaceDayForecast.isWithinHorizon(start: start, now: Date()) {
            Text("The forecast for your start arrives about \(RaceDayForecast.horizonDays) days before the race.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if isLoading {
            ProgressView()
        } else if let forecast {
            forecastRow(forecast.start, label: String(localized: "Start", comment: "Race weather: reading at the gun"))
            if let finish = forecast.finish {
                forecastRow(
                    finish,
                    label: String(localized: "Finish", comment: "Race weather: reading at the expected finish")
                )
            }
            heatLine(forecast.heatTier)
            Text("Forecast for where you last ran. Check the race's own forecast if you're travelling.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("No forecast is available right now. It needs a recent outdoor run for a location, and a connection.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func forecastRow(_ hour: ForecastHour, label: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: hour.conditions.conditionSymbol)
                .symbolRenderingMode(.multicolor)
                .font(.dsTitle3)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(label) · \(hour.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: hour.conditions.temperatureString(unit: unit)
                     + " · " + hour.conditions.conditionDescription)
                    .font(.bodyStrong)
                Text("Feels like \(hour.conditions.feelsLikeString(unit: unit))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// Only speaks up when the heat will cost pace; a comfortable morning needs no line.
    @ViewBuilder
    private func heatLine(_ tier: HeatStressTier) -> some View {
        if tier >= .mild {
            Text(verbatim: heatMessage(tier))
                .font(.dsSubhead)
                .foregroundStyle(tier >= .moderate ? Color.warning : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func heatMessage(_ tier: HeatStressTier) -> String {
        guard let band = HeatAdaptationPolicy.paceAdjustmentPercent(for: tier) else {
            return String(
                localized: "\(tier.localizedName): race for effort, not your goal time.",
                comment: "Race weather: extreme heat, pace targets abandoned"
            )
        }
        let low = band.lowerBound.formatted(.number.precision(.fractionLength(0...1)))
        let high = band.upperBound.formatted(.number.precision(.fractionLength(0...1)))
        return String(
            localized: "\(tier.localizedName): the same effort runs about \(low)–\(high)% slower in this.",
            comment: "Race weather: heat tier and the pace it costs"
        )
    }

    private func loadForecast() async {
        guard let start, RaceDayForecast.isWithinHorizon(start: start, now: Date()) else {
            forecast = nil
            return
        }
        guard let location = HeatAdvisoryService.usualRunLocation(from: runs) else {
            forecast = nil
            return
        }
        isLoading = true
        let hours = await container.weatherService.hourlyForecast(at: location, on: start)
        forecast = RaceDayForecast.make(from: hours, start: start, expectedDuration: expectedDuration)
        isLoading = false
    }
}

// MARK: - RaceStartTimeEditor

/// Picks the time of day the race starts. The day is the race's own and is not editable
/// here: the race date belongs to the plan.
private struct RaceStartTimeEditor: View {

    let raceDate: Date
    let initialStart: Date?

    @Environment(AppSettings.self) private var appSettings
    @Environment(\.dismiss) private var dismiss

    @State private var time: Date

    init(raceDate: Date, initialStart: Date?) {
        self.raceDate = raceDate
        self.initialStart = initialStart
        // 8 a.m. on race day is the most common road-race start, and so the least
        // scrolling for most runners.
        let fallback = Calendar.current.date(
            bySettingHour: 8, minute: 0, second: 0, of: raceDate
        ) ?? raceDate
        _time = State(initialValue: initialStart ?? fallback)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Start time", selection: $time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                Section {
                    if initialStart != nil {
                        Button("Remove start time", role: .destructive) {
                            appSettings.raceStartTime = nil
                            dismiss()
                        }
                    }
                } footer: {
                    Text("Used for the race-day forecast. Syncs to your other devices.")
                }
                .strideListRow()
            }
            .strideList()
            .navigationTitle("Race Start")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        appSettings.raceStartTime = RaceStartTime(raceDate: raceDate, time: time)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
