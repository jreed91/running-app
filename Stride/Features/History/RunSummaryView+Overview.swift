import SwiftUI
import MapKit

// Part of `RunSummaryView` (D1).
// The run's own summary: the plan link, the hero (numbers, vitals and the plan
// verdict), the route map, and the conditions row — the parts of the screen that
// describe the run itself rather than reading it back to the runner.

extension RunSummaryView {

    // MARK: Link to planned workout

    var linkToPlannedWorkoutButton: some View {
        Button {
            showAssociateSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.dsSubhead.weight(.semibold))
                    .foregroundStyle(.brand)
                Text("Link to a planned workout")
                    .font(.dsSubhead.weight(.semibold))
                    .foregroundStyle(.brandText)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.dsCaption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.md)
            .strideCard()
        }
        .buttonStyle(.plain)
    }

    // MARK: Title block

    /// The screen's hero: what the run was, its distance (or time), its time and pace, the
    /// vitals that used to fill a separate stats grid, and how it went against the plan.
    var titleBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(workoutTone)
                    .frame(width: 8, height: 8)
                    // The tinted glow that used to sit here had `radius: 0` at zero
                    // offset, so it drew the shape exactly behind itself and rendered
                    // nothing. The stroke below is what actually halos the dot (U1).
                    .overlay(Circle().stroke(workoutTone.opacity(0.25), lineWidth: 6))
                // The dot carries the workout type's colour; the words stay neutral, since
                // zone colours are data, not text decoration.
                Text(kickerTitle)
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(.tertiary)
                    .frame(width: 3, height: 3)
                Text(workout.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                    .font(.dsCaption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(heroMetric.value)
                    // The card's hero number keeps its 56pt design size and scales
                    // from there, rather than snapping down to `dsLargeTitle` (U2).
                    .font(.system(size: heroMetricSize, weight: .semibold, design: .rounded).monospacedDigit())
                    .kerning(-2.2)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(heroMetric.unit)
                    .font(.dsCallout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            // A cross-training session with no distance already leads with its time, and
            // has no running pace to follow it with (B8).
            if !leadsWithDuration {
                HStack(spacing: 12) {
                    metricInline(value: workout.durationSeconds.durationString, label: "total")
                    if showsPace {
                        Text("·").foregroundStyle(.tertiary)
                        metricInline(
                            value: workout.averagePaceSecondsPerKm.paceValueString(unit: appSettings.unitPreference),
                            label: appSettings.unitPreference.paceLabel
                        )
                    }
                }
            }

            let vitals = heroVitals
            if !vitals.isEmpty {
                Divider()
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 68), spacing: AppSpacing.sm, alignment: .leading)],
                    alignment: .leading,
                    spacing: AppSpacing.sm
                ) {
                    ForEach(vitals) { vital in
                        vitalCell(vital)
                    }
                }
            }

            planVerdict
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .heroCard()
        .padding(.top, AppSpacing.sm)
    }

    private func metricInline(value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.dsFootnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
            Text(label)
                .font(.dsFootnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Route map

    var routeMap: some View {
        Group {
            if workout.routeCoordinates.isEmpty {
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .fill(.surfaceSecondary)
                    .frame(height: 180)
                    .overlay {
                        Label("No route data", systemImage: "map")
                            .font(.dsCaption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
            } else {
                ZStack(alignment: .topLeading) {
                    Map {
                        MapPolyline(coordinates: workout.routeCoordinates.map(\.clCoordinate))
                            .stroke(.route, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                        if let start = workout.routeCoordinates.first {
                            Annotation("Start", coordinate: start.clCoordinate, anchor: .center) {
                                StartPin(diameter: 18)
                                    .appShadow(.e2)
                            }
                            .annotationTitles(.hidden)
                        }
                    }
                    // Muted, so the route reads first — the night map of the Route Loop.
                    .mapStyle(.standard(emphasis: .muted))
                    Text(routeName)
                        .font(.dsCaption2.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppRadius.xs))
                        .padding(10)
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                // One element: MapKit otherwise exposes every street and place label, which
                // VoiceOver has to step through and which is the likely reason UI-test
                // snapshots of this screen timed out in CI.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Route map, \(routeName)"))
            }
        }
    }

    // MARK: Vitals

    /// One of the run's secondary figures in the hero.
    struct RunVital: Identifiable {
        let label: String
        let value: String
        let unit: String?
        var tone: Color?
        var id: String { label }
    }

    /// Heart rate, cadence and climb. Distance, time and pace are the hero's own lines and
    /// are not repeated. The estimated VO₂ max cell is gone from this screen: Progress
    /// carries fitness, and a tempo run's pace insights page still shows this run's VDOT.
    var heroVitals: [RunVital] {
        var vitals: [RunVital] = []
        if let hr = workout.averageHeartRate {
            vitals.append(RunVital(
                label: String(localized: "Avg HR"), value: "\(Int(hr))", unit: "bpm", tone: hrTone(hr)
            ))
        }
        if let maxHR = workout.maxHeartRate {
            vitals.append(RunVital(
                label: String(localized: "Max HR"), value: "\(Int(maxHR))", unit: "bpm", tone: hrTone(maxHR)
            ))
        }
        // Cadence was live-only until A5 — the HUD showed it mid-run and nothing kept
        // it, so the run you had just finished could not tell you what it was.
        if let cadence = workout.averageCadenceStepsPerMinute, cadence > 0 {
            vitals.append(RunVital(
                label: String(localized: "Cadence"), value: "\(Int(cadence.rounded()))", unit: "spm"
            ))
        }
        if let gain = workout.elevationGainMeters {
            vitals.append(RunVital(
                label: String(localized: "Elevation"),
                value: "\(Int(gain.elevationValue(unit: appSettings.unitPreference)))",
                unit: appSettings.unitPreference.elevationLabel
            ))
        }
        return vitals
    }

    private func vitalCell(_ vital: RunVital) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(vital.value)
                    .font(.dsHeadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(vital.tone ?? .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if let unit = vital.unit {
                    Text(unit)
                        .font(.dsCaption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            Text(vital.label)
                .font(.dsCaption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        // One element per figure, or VoiceOver reads a number with no hint which metric
        // it belongs to (N18).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(vital.label)
        .accessibilityValue(SpokenMetric.spoken(value: vital.value, unit: vital.unit))
    }

    private func hrTone(_ value: Double) -> Color? {
        value >= 155 ? .warning : nil
    }

    // MARK: Conditions

    /// The weather as one row rather than a headed three-column card: it is context for
    /// the run, not a reading of it.
    @ViewBuilder
    var weatherSection: some View {
        if let w = workout.weather {
            let unit = appSettings.unitPreference
            HStack(spacing: 12) {
                Image(systemName: w.conditionSymbol)
                    .font(.dsTitle3)
                    .symbolRenderingMode(.multicolor)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(w.temperatureString(unit: unit)) · \(w.conditionDescription)")
                        .font(.dsSubhead.weight(.semibold))
                        .foregroundStyle(.primary)
                    let feels = w.feelsLikeString(unit: unit)
                    let wind = w.windString(unit: unit)
                    Text("Feels \(feels) · \(Int(w.humidityPercent))% humidity · \(wind) wind")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.md)
            .strideCard(cornerRadius: AppRadius.md)
            .accessibilityElement(children: .combine)
        }
    }
}
