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
        .padding(18)
        .background(cardBackground)
        .overlay {
            if isLoading {
                RoundedRectangle(cornerRadius: 18)
                    .fill(.regularMaterial)
                    .overlay { ProgressView() }
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
                Text("You've missed \(info.count) workout\(info.count == 1 ? "" : "s")")
                    .font(.bodyStrong)
                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var subtitleText: String {
        info.daysToShift == 1
            ? "Your plan is 1 day behind schedule."
            : "Your plan is \(info.daysToShift) days behind schedule."
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 8) {
            primaryButton(
                title: "Pick up where I left off",
                action: onPickUpWhereLeftOff
            )
            secondaryButton(
                title: "Rebuild from today",
                action: onRebuild
            )
            Button(action: onDismiss) {
                Text("Skip missed workouts")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
    }

    private func primaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.dsSubhead.weight(.semibold))
                .foregroundStyle(.onFill)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.brand)
                )
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.dsSubhead.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.surfaceSecondary)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Background

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(
                LinearGradient(
                    colors: [Color.warning.opacity(0.10), Color.warning.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.warning.opacity(0.2), lineWidth: 0.5)
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
