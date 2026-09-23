import SwiftUI

// MARK: - WatchHomeView

/// The watch app's one screen: vertical pages for today's session, the week, and the race.
///
/// Every string on it was formatted by the phone (see ``WidgetSnapshot``) except the ones
/// that depend on when they are read — "Today", a race countdown — which are resolved here
/// against the timeline's date, the way the widgets resolve them against an entry's.
struct WatchHomeView: View {
    @Environment(WatchGlanceModel.self) private var model

    var body: some View {
        // Once a minute is far more often than "Today" can change, but it is the cheapest
        // schedule that is guaranteed to cross midnight promptly while the app is open.
        TimelineView(.everyMinute) { timeline in
            content(now: timeline.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let context = model.context, !context.snapshot.isStale(asOf: now) {
            let snapshot = context.snapshot
            NavigationStack {
                TabView {
                    WatchNextWorkoutPage(
                        workout: snapshot.nextWorkout,
                        canStart: context.canStart(asOf: now),
                        now: now
                    )
                    WatchWeekPage(weekly: snapshot.weekly, streak: snapshot.streak)
                    if let race = snapshot.race, race.isUpcoming(asOf: now) {
                        WatchRacePage(race: race, now: now)
                    }
                }
                .tabViewStyle(.verticalPage)
            }
        } else {
            WatchEmptyState()
        }
    }
}

// MARK: - Today

private struct WatchNextWorkoutPage: View {
    @Environment(WatchGlanceModel.self) private var model
    let workout: WidgetSnapshot.NextWorkout?
    let canStart: Bool
    let now: Date

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let workout {
                    card(for: workout)
                } else {
                    Text("No plan yet")
                        .font(.headline)
                    Text("Create a training plan in Stride on your iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Stride")
        .containerBackground((workout?.tint.color ?? .strideBrand).gradient, for: .tabView)
    }

    @ViewBuilder
    private func card(for workout: WidgetSnapshot.NextWorkout) -> some View {
        Label {
            Text(verbatim: workout.dayLabel(asOf: now))
        } icon: {
            Image(systemName: workout.symbolName)
        }
        .font(.caption2.weight(.bold))
        .textCase(.uppercase)

        Text(verbatim: workout.title)
            .font(.title3.weight(.bold))
            .lineLimit(2)

        if let detail = workout.detail {
            Text(verbatim: detail)
                .font(.headline.monospacedDigit())
        }
        if let pace = workout.paceTarget {
            Text(verbatim: pace)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        if workout.isRest {
            Text("Recovery is part of training")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        if canStart {
            Button {
                Task { await model.startToday() }
            } label: {
                Label("Start", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(model.startState == .opening)
            .padding(.top, 4)
            .accessibilityHint(Text("Opens this workout in the Workout app"))

            if model.startState == .failed {
                Text("The Workout app didn't open. Try it from the Workout app's list.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        if let note = workout.note {
            Text(verbatim: note)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }
}

// MARK: - Week

private struct WatchWeekPage: View {
    let weekly: WidgetSnapshot.WeeklyGoal
    let streak: WidgetSnapshot.Streak

    var body: some View {
        VStack(spacing: 8) {
            if weekly.hasGoal {
                ZStack {
                    Circle()
                        .stroke(Color.strideBrand.opacity(0.25), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: min(max(weekly.fraction, 0), 1))
                        .stroke(
                            weekly.isMet ? Color.strideSuccess : Color.strideBrand,
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(verbatim: weekly.completedText)
                            .font(.headline.monospacedDigit())
                            .minimumScaleFactor(0.7)
                        Text("of \(weekly.goalText)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                }
                .frame(maxHeight: 96)
                .accessibilityElement(children: .combine)

                Text(verbatim: weekly.statusText)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            } else {
                Text(verbatim: weekly.completedText)
                    .font(.title2.weight(.bold).monospacedDigit())
                Text("\(weekly.runCount) runs this week")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if streak.current > 0 {
                Label {
                    Text("\(streak.current)-day streak")
                } icon: {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(Color.strideBrand)
                }
                .font(.footnote.weight(.semibold))

                // Two `Text`s rather than one over a ternary: a ternary of literals is a
                // `String`, and `Text(String)` does not localize.
                (streak.isActiveToday ? Text("Done for today") : Text("Run today to keep it going"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("This Week")
        .containerBackground(Color.strideBrand.gradient, for: .tabView)
    }
}

// MARK: - Race

private struct WatchRacePage: View {
    let race: WidgetSnapshot.RaceCountdown
    let now: Date

    var body: some View {
        let days = race.daysRemaining(asOf: now)
        VStack(spacing: 4) {
            Text(verbatim: race.name)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Group {
                if days == 0 {
                    Text("Race day")
                } else {
                    Text("\(days) days")
                }
            }
            .font(.title2.weight(.bold).monospacedDigit())
            if let goal = race.goalTimeText {
                Text("Goal \(goal)")
                    .font(.footnote.monospacedDigit())
            }
            if let phase = race.phaseLabel {
                Text(verbatim: phase)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Race")
        .containerBackground(Color.strideBrand.gradient, for: .tabView)
    }
}

// MARK: - Empty

/// Before the phone has sent anything, or once what it sent is too old to present as
/// current. Both mean the same thing to the runner, the way they do on the widgets.
private struct WatchEmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "figure.run")
                .font(.title2)
                .foregroundStyle(Color.strideBrand)
            Text("Open Stride on your iPhone to sync your plan.")
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
