import SwiftUI
import Charts

// MARK: - RaceCourseCard

/// The race's course: an invitation to add the GPX, or its elevation profile once added.
///
/// The numbers come from ``RaceCourse`` and the splits it drives from ``CoursePacing``;
/// this decides layout only. The hub owns the file picker and the store, so this card
/// only says what the runner tapped.
struct RaceCourseCard: View {

    let stored: StoredRaceCourse?
    let unit: UnitPreference
    /// Why the last import failed, in the runner's words, else nil.
    let errorMessage: String?
    let onAdd: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("COURSE")
                .strideEyebrow()
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)

            VStack(alignment: .leading, spacing: 12) {
                if let stored {
                    loaded(stored)
                } else {
                    empty
                }

                if let errorMessage {
                    Text(verbatim: errorMessage)
                        .font(.dsCaption)
                        .foregroundStyle(.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.lg)
            .strideCard()
        }
    }

    // MARK: Empty

    private var empty: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                iconTile
                Text("Add the course GPX from the race website or a Strava route, and your splits follow its hills.")
                    .font(.dsSubhead)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Add course GPX", action: onAdd)
                .buttonStyle(.strideButton(.secondary, compact: true, fullWidth: false))
        }
    }

    private var iconTile: some View {
        ZStack {
            Circle()
                .fill(Color.brand.opacity(0.12))
                .frame(width: 48, height: 48)
            StrideIcon(name: .mountain, size: 20, color: .brandText, strokeWeight: 2.2)
        }
        .accessibilityHidden(true)
    }

    // MARK: Loaded

    private func loaded(_ stored: StoredRaceCourse) -> some View {
        let course = stored.course
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: stored.displayName ?? String(localized: "Race course", comment: "Race hub: an added course with no name"))
                        .font(.bodyStrong)
                        .lineLimit(2)
                    Text(verbatim: summary(course))
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: AppSpacing.sm)
                Menu {
                    Button("Replace course", action: onAdd)
                    Button("Remove course", role: .destructive, action: onRemove)
                } label: {
                    Text("Edit")
                }
                .menuStyle(.button)
                .buttonStyle(.strideButton(.quiet, compact: true, fullWidth: false))
            }
            .accessibilityElement(children: .contain)

            RaceCourseProfileChart(course: course, unit: unit)
                .frame(height: 120)
        }
    }

    private func summary(_ course: RaceCourse) -> String {
        let climb = String(
            localized: "\(course.climbMeters.elevationString(unit: unit)) up",
            comment: "Race hub course card: total climb, e.g. '312 m up'"
        )
        let descent = String(
            localized: "\(course.descentMeters.elevationString(unit: unit)) down",
            comment: "Race hub course card: total descent, e.g. '298 m down'"
        )
        return [course.lengthMeters.distanceString(unit: unit), climb, descent].joined(separator: " · ")
    }
}

// MARK: - RaceCourseProfileChart

/// The course's elevation along its length: the route line over a soft fill.
private struct RaceCourseProfileChart: View {

    let course: RaceCourse
    let unit: UnitPreference

    /// A flat course drawn to fill the chart would look like the Alps, so the y axis
    /// always spans at least this much.
    private static let minimumSpanMeters = 40.0

    private var yDomain: ClosedRange<Double> {
        let low = course.lowestElevationMeters
        let high = course.highestElevationMeters
        let pad = max(0, Self.minimumSpanMeters - (high - low)) / 2
        return (low - pad).elevationValue(unit: unit)...(high + pad).elevationValue(unit: unit)
    }

    var body: some View {
        Chart {
            ForEach(course.samples, id: \.distanceMeters) { sample in
                AreaMark(
                    x: .value("Distance", sample.distanceMeters.distanceValue(unit: unit)),
                    yStart: .value("Base", yDomain.lowerBound),
                    yEnd: .value("Elevation", sample.elevationMeters.elevationValue(unit: unit))
                )
                .foregroundStyle(Color.brand.opacity(0.12))

                LineMark(
                    x: .value("Distance", sample.distanceMeters.distanceValue(unit: unit)),
                    y: .value("Elevation", sample.elevationMeters.elevationValue(unit: unit))
                )
                .foregroundStyle(.route)
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: 0...course.lengthMeters.distanceValue(unit: unit))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(Color.mapGrid)
                AxisValueLabel()
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Color.mapGrid)
                AxisValueLabel()
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Course elevation profile"))
        .accessibilityValue(Text(verbatim: accessibilitySummary))
    }

    private var accessibilitySummary: String {
        String(
            localized: "From \(course.lowestElevationMeters.elevationString(unit: unit)) to \(course.highestElevationMeters.elevationString(unit: unit))",
            comment: "Race hub course chart, VoiceOver: the lowest and highest point"
        )
    }
}
