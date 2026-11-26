import SwiftUI

// MARK: - JoinTrainingGroupSheet

/// Opened by a friend's group link: says whose group it is and what joining shares, asks
/// for the name to show, then joins and lands on the Plan tab's friends page.
struct JoinTrainingGroupSheet: View {
    let invite: TrainingGroupInvite

    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @AppStorage(TrainingGroup.displayNameKey) private var displayName = ""

    @State private var isJoining = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: invite.title)
                            .font(.dsTitle2)
                        if let owner = invite.ownerName {
                            Text("\(owner) invited you to train together.")
                                .font(.dsSubhead)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("WHAT THE GROUP SEES")
                            .strideEyebrow()
                            .foregroundStyle(.secondary)
                        Text("Your name below, this week's planned sessions and what you've done: kind, distance and time. Your routes, heart rate and times of day stay on your phone.")
                            .font(.dsSubhead)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("YOUR NAME IN GROUPS")
                            .strideEyebrow()
                            .foregroundStyle(.secondary)
                        TextField("First name or nickname", text: $displayName)
                            .textContentType(.givenName)
                            .submitLabel(.done)
                            .padding(AppSpacing.md)
                            .strideCard()
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.dsSubhead)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await join() }
                    } label: {
                        if isJoining {
                            ProgressView()
                        } else {
                            Text("Join group")
                        }
                    }
                    .buttonStyle(.strideButton(.primary))
                    .disabled(isJoining)
                    .accessibilityIdentifier("friends.join")
                }
                .padding()
            }
            .background(Color.surfacePrimary)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
            }
        }
    }

    private func join() async {
        isJoining = true
        defer { isJoining = false }
        do {
            _ = try await container.trainingGroups.accept(invite)
            container.appNavigation.openTrainingGroups()
            dismiss()
        } catch {
            errorMessage = TrainingGroupErrorText.message(for: error)
        }
    }
}
