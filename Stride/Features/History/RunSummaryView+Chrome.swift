import SwiftUI
import Charts

// Part of `RunSummaryView` (D1).
// Section headers, tabs, and chips shared by more than one section of the screen.

extension RunSummaryView {

    func sectionHeader(title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.dsCaption2.weight(.bold))
                .kerning(1.4)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, AppSpacing.xs)
        .padding(.top, 10)
    }

    func splitTab(_ metric: SplitChartMetric, active: Bool) -> some View {
        Button {
            selectedSplitMetric = metric
        } label: {
            Text(metric.tabTitle)
                .font(.dsCaption2.weight(.bold))
                .foregroundStyle(active ? Color.brand : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, AppSpacing.xs)
                .background(
                    active ? Color.brand.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: AppRadius.xs)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    func confidenceChip(_ value: Int) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 36, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.brand)
                        .frame(width: 36 * CGFloat(value) / 100, height: 4)
                }
            Text("\(value)%")
                .font(.dsCaption2.weight(.bold).monospaced())
                .foregroundStyle(.secondary)
        }
    }

    func evidenceChip(label: String, sub: String?, tone: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.dsCaption.weight(.bold).monospaced())
                .foregroundStyle(.primary)
            if let sub {
                Text(sub)
                    .font(.dsCaption2.weight(.bold))
                    .foregroundStyle(tone)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.xs))
    }

    func aiTone(_ raw: String) -> Color {
        switch raw.lowercased() {
        case "easy":
            return .zoneEasy
        case "brand", "medium":
            return .brand
        case "interval", "high":
            return .zoneInterval
        case "warning":
            return .warning
        case "success", "low":
            return .success
        default:
            return .secondary
        }
    }
}
