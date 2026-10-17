import SwiftUI

// Part of `RunSummaryView` (D1).
// The breakdown list and the detail pages it opens. The summary used to stack every
// reading of the run on one scroll (plan, splits, zones, laps, pace insights, six coach
// cards), which made the screen hard to take in. Each of those now sits behind one row
// here, with a one-line preview, and opens as its own page.

/// A page pushed from the run summary.
enum RunSummaryPage: Hashable {
    case plannedWorkout
    case splits
    case heartRateZones
    case laps
    case paceInsights
    case coach

    var title: String {
        switch self {
        case .plannedWorkout:
            return String(localized: "Planned workout", comment: "Run detail page title")
        case .splits:
            return String(localized: "Splits", comment: "Run detail page title")
        case .heartRateZones:
            return String(localized: "Heart-rate zones", comment: "Run detail page title")
        case .laps:
            return String(localized: "Laps", comment: "Run detail page title")
        case .paceInsights:
            return String(localized: "Pace insights", comment: "Run detail page title")
        case .coach:
            return String(localized: "Coach", comment: "Run detail page title")
        }
    }

    var systemImage: String {
        switch self {
        case .plannedWorkout: return "calendar"
        case .splits: return "chart.bar.xaxis"
        case .heartRateZones: return "heart"
        case .laps: return "flag.checkered"
        case .paceInsights: return "speedometer"
        case .coach: return "sparkles"
        }
    }
}

extension RunSummaryView {

    /// One row of the breakdown list: the page it opens and its one-line preview.
    struct BreakdownRow: Identifiable {
        let page: RunSummaryPage
        let summary: String?
        var id: RunSummaryPage { page }
    }

    /// The rows this run has something behind. The conditions are the ones each section
    /// used to apply inline, so a run never offers an empty page.
    var breakdownRows: [BreakdownRow] {
        var rows: [BreakdownRow] = []
        if let scheduled = matchedScheduled {
            rows.append(BreakdownRow(
                page: .plannedWorkout,
                summary: [
                    scheduled.workoutType.localizedName,
                    scheduled.scheduledDate.formatted(.dateTime.month(.abbreviated).day())
                ].joined(separator: " · ")
            ))
        }
        if !chartedSplits.splits.isEmpty || !workout.splits.isEmpty {
            rows.append(BreakdownRow(page: .splits, summary: splitsPreview))
        }
        if !zoneSlices.isEmpty, zoneSlices.contains(where: { $0.seconds > 0 }) {
            rows.append(BreakdownRow(page: .heartRateZones, summary: zonesPreview))
        }
        if !workout.laps.isEmpty {
            rows.append(BreakdownRow(
                page: .laps,
                summary: String(localized: "\(workout.laps.count) laps", comment: "Run breakdown row preview")
            ))
        }
        if workout.countsAsRunning, let insights = tempoInsights {
            rows.append(BreakdownRow(page: .paceInsights, summary: paceInsightsPreview(insights)))
        }
        return rows
    }

    private var splitsPreview: String? {
        let paces = workout.splits.map(\.paceSecondsPerKm).filter { $0 > 0 }
        guard let fastest = paces.min() else { return nil }
        let pace = fastest.paceString(unit: appSettings.unitPreference)
        return String(
            localized: "\(workout.splits.count) splits · fastest \(pace)",
            comment: "Run breakdown row preview, e.g. 8 splits · fastest 4:41 /km"
        )
    }

    private var zonesPreview: String? {
        let most = zoneSlices.max { $0.seconds < $1.seconds }
        guard let most, most.seconds > 0 else { return nil }
        return String(
            localized: "Mostly \(most.zone.shortName) \(most.zone.label)",
            comment: "Run breakdown row preview, e.g. Mostly Z3 Aerobic"
        )
    }

    private func paceInsightsPreview(_ insights: TempoInsights) -> String {
        if let previous = insights.previousBestTempoSecondsPerKm,
           previous - insights.achievedPaceSecondsPerKm > 1 {
            return String(localized: "New best tempo pace", comment: "Run breakdown row preview")
        }
        let pace = insights.achievedPaceSecondsPerKm.paceString(unit: appSettings.unitPreference)
        return String(localized: "Tempo pace \(pace)", comment: "Run breakdown row preview")
    }

    // MARK: Breakdown list

    @ViewBuilder
    var breakdownSection: some View {
        let rows = breakdownRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(title: "Breakdown")
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider().padding(.leading, 44)
                        }
                        breakdownRowButton(row)
                    }
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.vertical, AppSpacing.xs)
                .strideCard()
            }
        }
    }

    /// A view-destination link, not `navigationDestination(item:)` on this screen: this
    /// screen is itself pushed by view-destination links (History's list, a plan day), and
    /// an item-driven destination declared inside it did nothing on tap and then crashed.
    private func breakdownRowButton(_ row: BreakdownRow) -> some View {
        NavigationLink {
            detailPage(row.page)
        } label: {
            HStack(spacing: 12) {
                // A 32pt icon tile, as a row takes it (Route Loop controls table).
                Image(systemName: row.page.systemImage)
                    .font(.dsFootnote.weight(.semibold))
                    .foregroundStyle(.brand)
                    .frame(width: 32, height: 32)
                    .background(Color.brand.opacity(0.13), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.page.title)
                        .font(.dsSubhead.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let summary = row.summary {
                        Text(summary)
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                StrideIcon(name: .chevronRight, size: 12, color: .secondary, strokeWeight: 2.4)
            }
            .padding(.vertical, AppSpacing.sm)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        // `StrideUITests.testBreakdownRowOpensItsPage` taps these.
        .accessibilityIdentifier("runSummary.breakdown.\(row.page)")
    }

    // MARK: Detail pages

    func detailPage(_ page: RunSummaryPage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                detailPageContent(page)
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.sm)
            .padding(.bottom, AppSpacing.xxxl)
            .frame(maxWidth: .infinity)
        }
        .background(Color.surfacePrimary.ignoresSafeArea())
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func detailPageContent(_ page: RunSummaryPage) -> some View {
        switch page {
        case .plannedWorkout:
            plannedWorkoutSection
        case .splits:
            splitsCard
        case .heartRateZones:
            heartRateZoneSection
        case .laps:
            lapsSection
        case .paceInsights:
            paceInsightsSection
        case .coach:
            aiCoachSection
        }
    }
}
