import Foundation
import SwiftData

// MARK: - FriendsWeekPublisher

/// Builds this runner's ``FriendWeek`` from the store and writes it to their training
/// groups.
///
/// Called on every foreground and background (beside the widget refresh) and when the
/// friends page opens. It does nothing most of those times:
///
/// - no more than once every ``minimumInterval``, unless forced;
/// - while the last check found no groups, iCloud is asked again only every
///   ``noGroupsRecheckInterval``, so a runner who never uses groups costs one CloudKit
///   call a few times a day rather than one per foreground.
@MainActor
enum FriendsWeekPublisher {

    static let minimumInterval: TimeInterval = 10 * 60
    static let noGroupsRecheckInterval: TimeInterval = 6 * 60 * 60

    private static let lastPublishKey = "friends.lastPublishAt"
    private static let lastGroupCountKey = "friends.lastGroupCount"
    private static let lastGroupCheckKey = "friends.lastGroupCheckAt"

    /// The task in flight, so overlapping calls share it instead of publishing twice.
    private static var running: Task<Void, Never>?

    /// Publishes when due. `force` skips both intervals: the friends page wants the
    /// runner's own row current the moment it opens.
    static func publishIfDue(
        context: ModelContext,
        groups service: any TrainingGroupSyncing,
        force: Bool = false,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) async {
        if let running {
            await running.value
            if !force { return }
        }
        if !force {
            let last = defaults.object(forKey: lastPublishKey) as? Date ?? .distantPast
            guard now.timeIntervalSince(last) >= minimumInterval else { return }
            let lastCheck = defaults.object(forKey: lastGroupCheckKey) as? Date ?? .distantPast
            if defaults.integer(forKey: lastGroupCountKey) == 0,
               now.timeIntervalSince(lastCheck) < noGroupsRecheckInterval {
                return
            }
        }

        // Built now, on the main actor, from the store; only the finished value crosses.
        let week = makeWeek(context: context, now: now)
        let task = Task {
            do {
                let groups = try await service.groups()
                defaults.set(groups.count, forKey: lastGroupCountKey)
                defaults.set(now, forKey: lastGroupCheckKey)
                guard !groups.isEmpty else { return }
                try await service.publish(week, to: groups)
                defaults.set(now, forKey: lastPublishKey)
            } catch {
                AppLogger.log("Publishing my week failed: \(String(describing: error))", label: "friends", level: .warning)
            }
        }
        running = task
        await task.value
        running = nil
    }

    /// Notes how many groups the friends page just found, so a runner who has just
    /// started or joined one is published to on the next foreground, not hours later.
    static func noteGroupCount(_ count: Int, now: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(count, forKey: lastGroupCountKey)
        defaults.set(now, forKey: lastGroupCheckKey)
    }

    // MARK: Building

    /// This week as the store has it: the active plan's sessions, every finished workout
    /// (runs, walks, cross training, strength), the chosen name and the goal race.
    static func makeWeek(
        context: ModelContext,
        now: Date = Date(),
        calendar baseCalendar: Calendar = .current,
        defaults: UserDefaults = .standard
    ) -> FriendWeek {
        var calendar = baseCalendar
        calendar.firstWeekday = 2
        let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? now

        let sessionDescriptor = FetchDescriptor<ScheduledWorkout>(
            predicate: #Predicate { $0.scheduledDate >= start && $0.scheduledDate < end }
        )
        let sessions = ((try? context.fetch(sessionDescriptor)) ?? [])
            .filter { $0.week?.plan?.isActive == true }
            .map { FriendWeek.PlannedSession(date: $0.scheduledDate, type: $0.workoutType, targetMeters: $0.targetDistanceMeters) }

        var runDescriptor = FetchDescriptor<RunWorkout>(
            predicate: #Predicate { $0.date >= start && $0.date < end }
        )
        runDescriptor.propertiesToFetch = RunWorkout.summaryProperties
        let runs = ((try? context.fetch(runDescriptor)) ?? []).map {
            FriendWeek.FinishedWorkout(id: $0.id, date: $0.date, type: $0.workoutType,
                                       meters: $0.distanceMeters, seconds: $0.durationSeconds)
        }

        let strengthDescriptor = FetchDescriptor<StrengthWorkout>(
            predicate: #Predicate { $0.date >= start && $0.date < end }
        )
        let strength = ((try? context.fetch(strengthDescriptor)) ?? []).map {
            FriendWeek.FinishedWorkout(id: $0.id, date: $0.date, type: .strength,
                                       meters: 0, seconds: $0.durationSeconds)
        }

        let plan = (try? context.fetch(FetchDescriptor<TrainingPlan>(predicate: #Predicate { $0.isActive })))?.first
        let profile = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first
        let race = RaceDayPlan.resolve(profile: profile, plan: plan, now: now, calendar: calendar)
            .flatMap { RaceInvite(racePlan: $0, calendar: calendar) }

        return FriendWeek.make(
            name: defaults.string(forKey: TrainingGroup.displayNameKey) ?? "",
            planned: sessions,
            done: runs + strength,
            race: race,
            now: now,
            calendar: calendar
        )
    }
}
