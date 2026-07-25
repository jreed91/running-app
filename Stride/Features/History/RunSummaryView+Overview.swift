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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.brand)
                Text("Link to a planned workout")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.brand)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: Title block

    var titleBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(workoutTone)
                    .frame(width: 8, height: 8)
                    .shadow(color: workoutTone.opacity(0.35), radius: 0, x: 0, y: 0)
                    .overlay(Circle().stroke(workoutTone.opacity(0.25), lineWidth: 6))
                Text("\(displayType.displayName) run")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(workoutTone)
                Circle()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 3, height: 3)
                Text(workout.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(titleMetric.value)
                    .font(.system(size: 56, weight: .semibold, design: .monospaced))
                    .kerning(-2.2)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(titleMetric.unit)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                metricInline(value: workout.durationSeconds.durationString, label: "total")
                Text("·").foregroundStyle(.tertiary)
                metricInline(
                    value: workout.averagePaceSecondsPerKm.paceString(unit: appSettings.unitPreference).replacingOccurrences(of: " \(appSettings.unitPreference.paceLabel)", with: ""),
                    label: appSettings.unitPreference.paceLabel
                )
            }
        }
        .padding(.top, 18)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metricInline(value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Route map

    var routeMap: some View {
        Group {
            if workout.routeCoordinates.isEmpty {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.surfaceSecondary)
                    .frame(height: 180)
                    .overlay {
                        Label("No route data", systemImage: "map")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
            } else {
                ZStack(alignment: .topLeading) {
                    Map {
                        MapPolyline(coordinates: workout.routeCoordinates.map(\.clCoordinate))
                            .stroke(.brand, lineWidth: 4)
                    }
                    Text(routeName)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(10)
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    // MARK: Stats grid

    var statsGrid: some View {
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) {
            statCell(value: titleMetric.value, unit: titleMetric.unit, label: "Distance")
            statCell(value: workout.durationSeconds.durationString, label: "Duration")
            statCell(
                value: workout.averagePaceSecondsPerKm.paceString(unit: appSettings.unitPreference).replacingOccurrences(of: " \(appSettings.unitPreference.paceLabel)", with: ""),
                unit: appSettings.unitPreference.paceLabel,
                label: "Avg Pace"
            )
            if let hr = workout.averageHeartRate {
                statCell(value: "\(Int(hr))", unit: "bpm", label: "Avg HR", tone: hrTone(hr))
            }
            if let maxHR = workout.maxHeartRate {
                statCell(value: "\(Int(maxHR))", unit: "bpm", label: "Max HR", tone: hrTone(maxHR))
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
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .kerning(-0.5)
                    .foregroundStyle(tone ?? .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if let unit {
                    Text(unit)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
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
                            .font(.system(size: 32))
                            .symbolRenderingMode(.multicolor)
                        Text(w.conditionDescription)
                            .font(.caption)
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    Divider().frame(height: 56)

                    // Humidity + wind
                    VStack(alignment: .leading, spacing: 8) {
                        Label("\(Int(w.humidityPercent))%", systemImage: "humidity")
                        Label(w.windString(unit: appSettings.unitPreference), systemImage: "wind")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}
