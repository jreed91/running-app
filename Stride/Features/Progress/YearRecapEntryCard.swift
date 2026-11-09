import SwiftUI

/// The way into the year-in-running recap: a card with the app mark, "Your 2026 in
/// running", and a line saying what's inside. Tapping it opens `YearRecapView` full screen.
///
/// Used at the top of Achievements all year, and on Home in December and January with a
/// close button (`onDismiss`). A plain card rather than a hero: both screens already have
/// their hero, and Route Loop allows one per screen.
struct YearRecapEntryCard: View {
    let year: Int
    /// Shown on Home only; Achievements keeps the card for good.
    var onDismiss: (() -> Void)?

    @Environment(AppSettings.self) private var appSettings
    @State private var isPresenting = false

    private var isInProgress: Bool {
        Calendar.current.component(.year, from: Date()) == year
    }

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Button {
                isPresenting = true
            } label: {
                HStack(spacing: AppSpacing.md) {
                    StrideAppMark(size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isInProgress ? "\(String(year)) so far" : String(year))
                            .strideEyebrow()
                            .foregroundStyle(.secondary)
                        Text("Your year in running")
                            .font(.bodyStrong)
                            .foregroundStyle(.primary)
                        Text("Your distance, streaks and best times, ready to share.")
                            .font(.dsFootnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if onDismiss == nil {
                        StrideIcon(name: .chevronRight, size: 12, color: .secondary, strokeWeight: 2)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(BouncyButtonStyle())
            .accessibilityHint("Opens your year in running")

            if let onDismiss {
                Button(action: onDismiss) {
                    StrideIcon(name: .close, size: 12, color: .secondary, strokeWeight: 2)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide year in running")
            }
        }
        .padding(AppSpacing.lg)
        .strideCard()
        .fullScreenCover(isPresented: $isPresenting) {
            YearRecapView(year: year)
                .environment(appSettings)
        }
    }
}
