import SwiftUI
import Charts

// Part of `RunSummaryView` (D1).
// Section headers and chips shared by more than one section of the screen.

extension RunSummaryView {

    func sectionHeader(title: String) -> some View {
        HStack {
            Text(title)
                .strideEyebrow()
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, AppSpacing.xs)
        .padding(.top, 10)
    }

    func confidenceChip(_ value: Int) -> some View {
        HStack(spacing: 6) {
            // The percentage beside it is what VoiceOver reads.
            StrideProgressBar(value: Double(value) / 100, height: 4)
                .frame(width: 36)
                .accessibilityHidden(true)
            Text("\(value)%")
                .font(.dsCaption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    func evidenceChip(label: String, sub: String?, tone: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.dsCaption.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
            if let sub {
                Text(sub)
                    .font(.dsCaption2.weight(.bold))
                    .foregroundStyle(tone)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.surfaceTertiary, in: RoundedRectangle(cornerRadius: AppRadius.xs))
    }

    /// The coach's tone words as status colours. Zone colours stay data (Route Loop rule 6),
    /// so "easy" and "interval" read as good and bad news rather than as training zones.
    func aiTone(_ raw: String) -> Color {
        switch raw.lowercased() {
        case "easy":
            return .success
        case "brand", "medium":
            return .brand
        case "interval", "high":
            return .destructive
        case "warning":
            return .warning
        case "success", "low":
            return .success
        default:
            return .secondary
        }
    }
}
