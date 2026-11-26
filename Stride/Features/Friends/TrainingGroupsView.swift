import CloudKit
import SwiftUI

// MARK: - TrainingGroupsView

/// "Train with friends": the runner's training groups, a way to start one and send its
/// link, and the name friends see. Opened from the Plan tab.
///
/// Everyone's weeks come in the next step; this page is the groups themselves.
struct TrainingGroupsView: View {
    @Environment(AppContainer.self) private var container

    @AppStorage(TrainingGroup.displayNameKey) private var displayName = ""

    @State private var phase: Phase = .loading
    @State private var isNaming = false
    @State private var newTitle = ""
    @State private var isCreating = false
    @State private var groupToLeave: TrainingGroup?
    @State private var errorMessage: String?

    private enum Phase {
        case loading
        case loaded([TrainingGroup])
        case failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                intro
                nameCard
                groupsSection
            }
            .padding()
            .strideReadableWidth()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfacePrimary)
        .navigationTitle("Train with friends")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert("Name your group", isPresented: $isNaming) {
            TextField("Tuesday club", text: $newTitle)
            Button("Start group") { Task { await create() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Friends see this name when you invite them.")
        }
        .confirmationDialog(
            leaveTitle,
            isPresented: isAskingToLeave,
            titleVisibility: .visible,
            presenting: groupToLeave
        ) { group in
            Button(group.isOwner ? "End group" : "Leave group", role: .destructive) {
                Task { await leave(group) }
            }
        } message: { group in
            Text(group.isOwner
                 ? "Everyone in \(group.title) stops seeing each other's weeks."
                 : "You stop seeing \(group.title), and its members stop seeing your week.")
        }
        .alert(
            "Something went wrong",
            isPresented: isShowingError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Sections

    private var intro: some View {
        Text("Invite friends with a link and see each other's training weeks: what was planned and what got done. Your routes, heart rate and times of day stay on your phone.")
            .font(.dsSubhead)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("YOUR NAME IN GROUPS")
                .strideEyebrow()
                .foregroundStyle(.secondary)
            TextField("First name or nickname", text: $displayName)
                .textContentType(.givenName)
                .submitLabel(.done)
                .padding(AppSpacing.md)
                .strideCard()
                .accessibilityIdentifier("friends.displayName")
        }
    }

    @ViewBuilder
    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("YOUR GROUPS")
                .strideEyebrow()
                .foregroundStyle(.secondary)

            switch phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(AppSpacing.lg)
            case .failed(let message):
                Text(message)
                    .font(.dsSubhead)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppSpacing.lg)
                    .strideCard()
            case .loaded(let groups):
                if groups.isEmpty {
                    Text("No groups yet. Start one and send the link to a friend.")
                        .font(.dsSubhead)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppSpacing.lg)
                        .strideCard()
                }
                ForEach(groups) { group in
                    TrainingGroupRow(group: group, inviteMessage: inviteMessage(for: group)) {
                        groupToLeave = group
                    }
                }
            }

            Button {
                newTitle = ""
                isNaming = true
            } label: {
                if isCreating {
                    ProgressView()
                } else {
                    Text("Start a group")
                }
            }
            .buttonStyle(.strideButton(.primary))
            .disabled(isCreating || isFailed)
            .accessibilityIdentifier("friends.startGroup")
        }
    }

    // Named rather than inline: an inline `Binding(get:set:)` in a long body can time out
    // the type checker.
    private var isAskingToLeave: Binding<Bool> {
        Binding(get: { groupToLeave != nil }, set: { if !$0 { groupToLeave = nil } })
    }

    private var isShowingError: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private var leaveTitle: String {
        guard let group = groupToLeave else { return "" }
        return group.isOwner ? "End \(group.title)?" : "Leave \(group.title)?"
    }

    private func inviteMessage(for group: TrainingGroup) -> String {
        String(
            localized: "Train with me in \(group.title) on Stride. We'll see each other's training weeks:",
            comment: "Train with friends: the message sent with a group's invite link, followed by the link"
        )
    }

    // MARK: Actions

    private func load() async {
        do {
            let groups = try await container.trainingGroups.groups()
            phase = .loaded(groups.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
        } catch {
            phase = .failed(TrainingGroupErrorText.message(for: error))
        }
    }

    private func create() async {
        isCreating = true
        defer { isCreating = false }
        do {
            let group = try await container.trainingGroups.createGroup(title: newTitle)
            if case .loaded(let groups) = phase {
                phase = .loaded(groups + [group])
            } else {
                phase = .loaded([group])
            }
        } catch {
            errorMessage = TrainingGroupErrorText.message(for: error)
        }
    }

    private func leave(_ group: TrainingGroup) async {
        do {
            try await container.trainingGroups.leave(group)
            if case .loaded(let groups) = phase {
                phase = .loaded(groups.filter { $0.id != group.id })
            }
        } catch {
            errorMessage = TrainingGroupErrorText.message(for: error)
        }
    }
}

// MARK: - TrainingGroupRow

private struct TrainingGroupRow: View {
    let group: TrainingGroup
    let inviteMessage: String
    let onLeave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                StrideIcon(name: .person, size: 16, color: .brand, strokeWeight: 2)
                    .frame(width: 32, height: 32)
                    .background(Color.brand.opacity(0.13), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: group.title)
                        .font(.dsSubhead.weight(.semibold))
                    Text(group.isOwner ? "You started this group" : "You joined this group")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Menu {
                    Button(group.isOwner ? "End group" : "Leave group", role: .destructive, action: onLeave)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More for \(group.title)")
            }

            if let url = group.shareURL {
                ShareLink(
                    item: url,
                    subject: Text(verbatim: group.title),
                    message: Text(verbatim: inviteMessage)
                ) {
                    Text("Invite a friend")
                }
                .buttonStyle(.strideButton(.secondary, compact: true, fullWidth: false))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        .strideCard()
    }
}

// MARK: - TrainingGroupErrorText

/// What a runner reads when iCloud says no.
enum TrainingGroupErrorText {
    static func message(for error: Error) -> String {
        // Logged in full every time: the alert can only say so much, and TestFlight
        // builds keep this in the Pulse log.
        AppLogger.log("Training group error: \(String(describing: error))", label: "friends", level: .error)
        if let ckError = error as? CKError {
            switch ckError.code {
            case .notAuthenticated:
                return String(localized: "Sign in to iCloud in Settings to train with friends.",
                              comment: "Train with friends: iCloud is signed out")
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
                return String(localized: "iCloud can't be reached right now. Try again in a moment.",
                              comment: "Train with friends: iCloud is offline or busy")
            case .quotaExceeded:
                return String(localized: "Your iCloud storage is full, so the group can't be saved.",
                              comment: "Train with friends: iCloud storage full")
            case .zoneNotFound, .userDeletedZone, .unknownItem:
                return String(localized: "This group no longer exists.",
                              comment: "Train with friends: the group was ended by its owner")
            case .participantMayNeedVerification:
                return String(localized: "iCloud needs to confirm it's you before you can join. Open the link again.",
                              comment: "Train with friends: share acceptance needs verification")
            default:
                break
            }
        }
        // The code goes on the end so a screenshot of this alert says which error it was.
        let code = (error as NSError).code
        return String(localized: "iCloud couldn't finish that. Try again in a moment. (Error \(code))",
                      comment: "Train with friends: any other iCloud error, with its numeric code")
    }
}
