import SwiftUI
import MapKit

// Part of `RunSummaryView` (D1).
// The run's own summary: the plan link, the title block, the route map, the stats
// grid, and the weather strip — the parts of the screen that describe the run itself
// rather than reading it back to the runner.

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

    /// The screen's hero: what the run was, its distance (or time), and its time and pace.
    /// The stats grid below carries only what this block does not.
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
            }
        }
    }

    // MARK: Stats grid

    /// The run's other figures. Distance, time and pace are in the title block above and
    /// are not repeated here.
    var statsGrid: some View {
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) {
            if let hr = workout.averageHeartRate {
                statCell(value: "\(Int(hr))", unit: "bpm", label: "Avg HR", tone: hrTone(hr))
            }
            if let maxHR = workout.maxHeartRate {
                statCell(value: "\(Int(maxHR))", unit: "bpm", label: "Max HR", tone: hrTone(maxHR))
            }
            // Cadence was live-only until A5 — the HUD showed it mid-run and nothing kept
            // it, so the run you had just finished could not tell you what it was.
            if let cadence = workout.averageCadenceStepsPerMinute, cadence > 0 {
                statCell(value: "\(Int(cadence.rounded()))", unit: "spm", label: "Avg Cadence")
            }
            if let gain = workout.elevationGainMeters {
                statCell(
                    value: "\(Int(gain.elevationValue(unit: appSettings.unitPreference)))",
                    unit: appSettings.unitPreference.elevationLabel,
                    label: "Elevation"
                )
            }
            if let vo2 = estimatedVO2Max {
                statCell(value: String(format: "%.1f", vo2), label: "Est. VO₂ Max", colSpan: true)
            }
        }
    }

    private func statCell(value: String, unit: String? = nil, label: String, tone: Color? = nil, colSpan: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.dsTitle2.weight(.semibold).monospacedDigit())
                    .kerning(-0.5)
                    .foregroundStyle(tone ?? .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if let unit {
                    Text(unit)
                        .font(.dsCaption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            Text(label)
                .font(.dsCaption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
        .strideCard()
        .gridCellColumns(colSpan ? 2 : 1)
        // One element per cell, or the grid reads as loose fragments with no pairing
        // between a number and the metric it belongs to (N18).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(SpokenMetric.spoken(value: value, unit: unit))
    }

    private func hrTone(_ value: Double) -> Color? {
        value >= 155 ? .warning : nil
    }

    // MARK: Weather section

    @ViewBuilder
    var weatherSection: some View {
        if let w = workout.weather {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(title: "Conditions")

                HStack(spacing: 0) {
                    // Icon + condition description
                    VStack(spacing: 6) {
                        Image(systemName: w.conditionSymbol)
                            .font(.system(size: weatherGlyphSize))
                            .symbolRenderingMode(.multicolor)
                        Text(w.conditionDescription)
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)

                    Divider().frame(height: 56)

                    // Temperature
                    VStack(spacing: 4) {
                        Text(w.temperatureString(unit: appSettings.unitPreference))
                            .font(.metricSmall)
                        Text("Feels \(w.feelsLikeString(unit: appSettings.unitPreference))")
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    Divider().frame(height: 56)

                    // Humidity + wind
                    VStack(alignment: .leading, spacing: 8) {
                        Label("\(Int(w.humidityPercent))%", systemImage: "humidity")
                        Label(w.windString(unit: appSettings.unitPreference), systemImage: "wind")
                    }
                    .font(.dsCaption)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.vertical, AppSpacing.md)
                .strideCard()
            }
        }
    }
}
