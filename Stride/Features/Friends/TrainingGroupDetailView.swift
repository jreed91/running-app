import SwiftUI

// MARK: - TrainingGroupDetailView

/// One training group: everyone's week side by side, this runner first.
///
/// Each member is a card with their week as seven days (done, missed, planned, rest),
/// their running distance against the plan's, and their race when they have one.
struct TrainingGroupDetailView: View {
    let group: TrainingGroup

    @Environment(AppContainer.self) private var container
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.modelContext) private var context

    @State private var phase: Phase = .loading
    @State private var cheers: [FriendCheer] = []
    @State private var myMemberID: String?
    @State private var errorMessage: String?

    private enum Phase {
        case loading
        case loaded([FriendsBoard.Row])
        case failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                switch phase {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(AppSpacing.xl)
                case .failed(let message):
                    note(message)
                case .loaded(let rows):
                    if rows.allSatisfy(\.isMe) {
                        note(String(localized: "Nobody else is here yet. Send the link from the groups page to invite a friend.",
                                    comment: "Train with friends: a group with only the runner in it"))
                    }
                    ForEach(rows) { row in
                        FriendWeekCard(
                            row: row,
                            today: today,
                            unit: appSettings.unitPreference,
                            cheerLines: row.isMe ? FriendCheers.lines(cheers, for: row.memberID) : [],
                            cheer: cheerState(for: row),
                            raceToJoin: FriendsBoard.raceToJoin(
                                on: row, myRace: myRace(in: rows), now: Date(), calendar: .current
                            ),
                            onCheer: { workout in
                                Task { await send(cheerFor: workout, to: row) }
                            },
                            onJoinRace: { race in
                                // The race invite flow: the new-plan sheet with the race
                                // filled in, built at this runner's own paces.
                                container.appNavigation.openRaceInvite(race)
                            }
                        )
                    }
                }
            }
            .padding()
            .strideReadableWidth()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfacePrimary)
        .navigationTitle(Text(verbatim: group.title))
        .navigationBarTitleDisplayMode(.inline)
        .alert("Something went wrong", isPresented: isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await load(publishFirst: true) }
        .refreshable { await load(publishFirst: true) }
    }

    private var today: String {
        FriendWeek.dayString(Date(), calendar: .current)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.dsSubhead)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.lg)
            .strideCard()
    }

    private func load(publishFirst: Bool) async {
        // This runner's own row should be today's, not whenever the app last published.
        if publishFirst {
            await FriendsWeekPublisher.publishIfDue(context: context, groups: container.trainingGroups, force: true)
        }
        do {
            let me = try? await container.trainingGroups.myMemberID()
            let contents = try await container.trainingGroups.contents(of: group)
            myMemberID = me
            cheers = contents.cheers
            phase = .loaded(FriendsBoard.rows(contents.weeks, myMemberID: me, now: Date(), calendar: .current))
            // Seen on the card now, so no banner for them later.
            if let me {
                FriendsWeekPublisher.markCheersSeen(FriendCheers.unseen(contents.cheers, for: me, seen: []))
            }
        } catch {
            phase = .failed(TrainingGroupErrorText.message(for: error))
        }
    }

    /// This runner's own race, from their row.
    private func myRace(in rows: [FriendsBoard.Row]) -> RaceInvite? {
        rows.first(where: \.isMe)?.week?.race
    }

    // MARK: Cheers

    private func cheerState(for row: FriendsBoard.Row) -> FriendWeekCard.CheerState {
        guard !row.isMe, let me = myMemberID, let week = row.week,
              let latest = FriendCheers.latestDone(in: week)
        else { return .none }
        return FriendCheers.hasCheered(cheers, from: me, workoutID: latest.id) ? .cheered : .canCheer(latest)
    }

    private func send(cheerFor workout: FriendWeek.Done, to row: FriendsBoard.Row) async {
        guard let me = myMemberID else { return }
        let name = UserDefaults.standard.string(forKey: TrainingGroup.displayNameKey) ?? ""
        let cheer = FriendCheer(workout: workout, to: row.memberID, from: me, fromName: name, at: Date())
        cheers.append(cheer) // Shown as sent at once; taken back if iCloud says no.
        do {
            try await container.trainingGroups.send(cheer, in: group)
        } catch {
            cheers.removeAll { $0.recordName == cheer.recordName }
            errorMessage = TrainingGroupErrorText.message(for: error)
        }
    }

    private var isShowingError: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

// MARK: - FriendWeekCard

private struct FriendWeekCard: View {
    let row: FriendsBoard.Row
    let today: String
    let unit: UnitPreference
    /// For this runner's own card: who cheered what.
    let cheerLines: [String]
    let cheer: CheerState
    /// A friend's race this runner could train for too.
    let raceToJoin: RaceInvite?
    let onCheer: (FriendWeek.Done) -> Void
    let onJoinRace: (RaceInvite) -> Void

    enum CheerState: Equatable {
        case none
        case canCheer(FriendWeek.Done)
        case cheered
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: row.name)
                    .font(.dsHeadline)
                if row.isMe {
                    Text("You")
                        .font(.dsCaption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let week = row.week {
                    Text(totals(week))
                        .font(.dsSubhead.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let week = row.week {
                FriendWeekStrip(states: week.dayStates(today: today), days: week.days.map(\.date))
                if let race = week.race {
                    HStack {
                        Text("Training for \(race.name)")
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if let raceToJoin {
                            Button("Train for this too") { onJoinRace(raceToJoin) }
                                .font(.dsCaption.weight(.semibold))
                                .foregroundStyle(Color.brandText)
                                .accessibilityIdentifier("friends.joinRace")
                        }
                    }
                }
            } else {
                Text("No update this week yet")
                    .font(.dsSubhead)
                    .foregroundStyle(.secondary)
            }

            ForEach(cheerLines, id: \.self) { line in
                Text(verbatim: "👏 " + line)
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }

            switch cheer {
            case .none:
                EmptyView()
            case .canCheer(let workout):
                Button {
                    onCheer(workout)
                } label: {
                    Text("Cheer their \(FriendCheers.workoutName(workout.kind))")
                }
                .buttonStyle(.strideButton(.secondary, compact: true, fullWidth: false))
                .accessibilityIdentifier("friends.cheer")
            case .cheered:
                Label("Cheered", systemImage: "hands.clap.fill")
                    .font(.dsCaption.weight(.semibold))
                    .foregroundStyle(Color.brandText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        .strideCard()
        .accessibilityElement(children: .contain)
    }

    /// "18.2 of 30.0 km", or just the distance without a plan.
    private func totals(_ week: FriendWeek) -> String {
        let done = Double(week.runMeters).distanceString(unit: unit)
        guard week.plannedRunMeters > 0 else { return done }
        let planned = Double(week.plannedRunMeters).distanceString(unit: unit)
        return String(localized: "\(done) of \(planned)",
                      comment: "Train with friends: distance run this week of the distance planned")
    }
}

// MARK: - FriendWeekStrip

/// Seven day marks, Monday first: filled for done, ringed for planned, a cross-out for
/// missed, a faint dot for rest.
private struct FriendWeekStrip: View {
    let states: [FriendWeek.DayState]
    let days: [String]

    private static let letters = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(states.enumerated()), id: \.offset) { index, state in
                VStack(spacing: 4) {
                    mark(state)
                        .frame(width: 22, height: 22)
                    Text(verbatim: Self.letters[index % 7])
                        .font(.dsCaption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label(state, day: index < days.count ? days[index] : ""))
            }
        }
    }

    @ViewBuilder
    private func mark(_ state: FriendWeek.DayState) -> some View {
        switch state {
        case .done:
            Circle().fill(Color.brand)
        case .planned:
            Circle().strokeBorder(Color.brand, lineWidth: 2)
        case .missed:
            Circle().strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
        case .rest, .upcoming:
            Circle().fill(Color.secondary.opacity(0.18)).padding(7)
        }
    }

    private func label(_ state: FriendWeek.DayState, day: String) -> String {
        switch state {
        case .done: String(localized: "\(day): done", comment: "Train with friends: a day with a workout done")
        case .planned: String(localized: "\(day): planned", comment: "Train with friends: a planned day")
        case .missed: String(localized: "\(day): missed", comment: "Train with friends: a planned day with nothing done")
        case .rest, .upcoming: String(localized: "\(day): rest", comment: "Train with friends: a day with nothing planned")
        }
    }
}
