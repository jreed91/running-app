import SwiftUI
import Charts

// Part of `RunSummaryView` (D1).
// Section headers and chips shared by more than one section of the screen.

extension RunSummaryView {

    func sectionHeader(title: LocalizedStringKey) -> some View {
        HStack {
            Text(title)
                .strideEyebrow()
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, AppSpacing.xs)
        .padding(.top, 10)
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
