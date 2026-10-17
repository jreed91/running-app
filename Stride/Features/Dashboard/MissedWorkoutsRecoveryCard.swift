import SwiftUI

struct MissedWorkoutsRecoveryCard: View {
    let info: MissedWorkoutInfo
    let isLoading: Bool
    let onPickUpWhereLeftOff: () -> Void
    let onRebuild: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().opacity(0.5)
            actionButtons
        }
        .padding(AppSpacing.lg)
        .background(cardBackground)
        .overlay {
            if isLoading {
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .fill(Color.surfaceSecondary.opacity(0.85))
                    .overlay {
                        ProgressView()
                            .accessibilityLabel(Text("Updating your plan"))
                    }
            }
        }
        .allowsHitTesting(!isLoading)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.warning.opacity(0.15))
                    .frame(width: 48, height: 48)
                StrideIcon(name: .flag, size: 20, color: .warning, strokeWeight: 2.2)
            }
            VStack(alignment: .leading, spacing: 3) {
                // `inflect` lets each language pick its own plural, rather than a hand-added "s".
                Text("You've missed ^[\(info.count) workout](inflect: true)")
                    .font(.bodyStrong)
                Text(subtitleText)
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var subtitleText: LocalizedStringKey {
        "Your plan is ^[\(info.daysToShift) day](inflect: true) behind schedule."
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 8) {
            Button("Pick up where I left off", action: onPickUpWhereLeftOff)
                .buttonStyle(.strideButton(.secondary)) // Start is Home's one primary
            Button("Rebuild from today", action: onRebuild)
                .buttonStyle(.strideButton(.quiet, compact: true))
            Button("Skip missed workouts", action: onDismiss)
                .buttonStyle(.strideButton(.quiet, compact: true))
        }
    }

    // MARK: - Background

    /// A plain card, like every other card on Home: the status colour is on the icon
    /// tile and the action, not the card's ground.
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
            .fill(Color.surfaceSecondary)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .strokeBorder(Color.cardStroke, lineWidth: 1)
            )
    }
}

#Preview {
    VStack(spacing: 20) {
        MissedWorkoutsRecoveryCard(
            info: MissedWorkoutInfo(count: 3, firstMissedDate: Date().adding(days: -5), daysToShift: 5),
            isLoading: false,
            onPickUpWhereLeftOff: {},
            onRebuild: {},
            onDismiss: {}
        )
        MissedWorkoutsRecoveryCard(
            info: MissedWorkoutInfo(count: 7, firstMissedDate: Date().adding(days: -12), daysToShift: 12),
            isLoading: true,
            onPickUpWhereLeftOff: {},
            onRebuild: {},
            onDismiss: {}
        )
    }
    .padding()
}
