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
                        FriendWeekCard(row: row, today: today, unit: appSettings.unitPreference)
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
            async let me = container.trainingGroups.myMemberID()
            async let weeks = container.trainingGroups.weeks(in: group)
            let rows = FriendsBoard.rows(try await weeks, myMemberID: try? await me, now: Date(), calendar: .current)
            phase = .loaded(rows)
        } catch {
            phase = .failed(TrainingGroupErrorText.message(for: error))
        }
    }
}

// MARK: - FriendWeekCard

private struct FriendWeekCard: View {
    let row: FriendsBoard.Row
    let today: String
    let unit: UnitPreference

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
                    Text("Training for \(race.name)")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No update this week yet")
                    .font(.dsSubhead)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        .strideCard()
        .accessibilityElement(children: .combine)
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
