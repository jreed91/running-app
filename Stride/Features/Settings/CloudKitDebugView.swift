import SwiftUI
import SwiftData

struct CloudKitDebugView: View {
    @Environment(AppSettings.self) private var appSettings

    @Query(sort: \UserProfile.updatedAt, order: .reverse) private var profiles: [UserProfile]
    @Query(sort: \TrainingPlan.createdAt, order: .reverse) private var plans: [TrainingPlan]
    @Query(sort: \TrainingWeek.weekNumber, order: .forward) private var weeks: [TrainingWeek]
    @Query(sort: \ScheduledWorkout.scheduledDate, order: .forward) private var scheduledWorkouts: [ScheduledWorkout]
    @Query(sort: \RunWorkout.date, order: .reverse) private var runWorkouts: [RunWorkout]
    @Query(sort: \SavedRoute.createdAt, order: .reverse) private var savedRoutes: [SavedRoute]

    var body: some View {
        List {
            Section {
                labeled("iCloud Sync Enabled", value: appSettings.iCloudSyncEnabled ? "Yes" : "No")
                labeled("UserDefaults Unit Preference", value: AppSettings.syncedUnitPreference().displayName)
            } header: {
                Text("CloudKit Status")
            } footer: {
                Text("This screen shows all local SwiftData records mirrored by CloudKit plus iCloud key-value settings.")
            }

            recordSection(title: "User Profiles", records: profiles.map(profilePayload))
            recordSection(title: "Training Plans", records: plans.map(planPayload))
            recordSection(title: "Training Weeks", records: weeks.map(weekPayload))
            recordSection(title: "Scheduled Workouts", records: scheduledWorkouts.map(scheduledWorkoutPayload))
            recordSection(title: "Run Workouts", records: runWorkouts.map(runWorkoutPayload))
            recordSection(title: "Saved Routes", records: savedRoutes.map(savedRoutePayload))
        }
        .navigationTitle("CloudKit Debug")
    }

    @ViewBuilder
    private func recordSection(title: String, records: [[String: Any]]) -> some View {
        Section(title) {
            if records.isEmpty {
                Text("No records")
                    .foregroundStyle(.secondary)
            } else {
                labeled("Count", value: "\(records.count)")
                Text(prettyPrinted(records) ?? "Unable to serialize records.")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private func labeled(_ name: String, value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func profilePayload(_ profile: UserProfile) -> [String: Any] {
        [
            "id": profile.id.uuidString,
            "name": profile.name,
            "goalRace": profile.goalRaceRaw,
            "goalFinishTime": profile.goalFinishTime,
            "weeklyRunDays": profile.weeklyRunDays,
            "fitnessLevel": profile.fitnessLevelRaw,
            "gender": profile.genderRaw,
            "estimated5KSeconds": profile.currentEstimated5KTimeSeconds as Any,
            "preferredRunDayIndices": profile.preferredRunDayIndices,
            "createdAt": profile.createdAt.ISO8601Format(),
            "updatedAt": profile.updatedAt.ISO8601Format()
        ]
    }

    private func planPayload(_ plan: TrainingPlan) -> [String: Any] {
        [
            "id": plan.id.uuidString,
            "targetRace": plan.targetRaceRaw,
            "goalTimeSeconds": plan.goalTimeSeconds,
            "startDate": plan.startDate.ISO8601Format(),
            "endDate": plan.endDate.ISO8601Format(),
            "isActive": plan.isActive,
            "createdAt": plan.createdAt.ISO8601Format(),
            "weekIDs": (plan.weeks ?? []).map(\.id.uuidString)
        ]
    }

    private func weekPayload(_ week: TrainingWeek) -> [String: Any] {
        [
            "id": week.id.uuidString,
            "weekNumber": week.weekNumber,
            "startDate": week.startDate.ISO8601Format(),
            "endDate": week.endDate.ISO8601Format(),
            "phase": week.phaseRaw,
            "targetDistanceKm": week.targetDistanceKm,
            "planID": week.plan?.id.uuidString as Any,
            "workoutIDs": (week.workouts ?? []).map(\.id.uuidString)
        ]
    }

    private func scheduledWorkoutPayload(_ workout: ScheduledWorkout) -> [String: Any] {
        [
            "id": workout.id.uuidString,
            "scheduledDate": workout.scheduledDate.ISO8601Format(),
            "workoutType": workout.workoutTypeRaw,
            "workoutLocation": workout.workoutLocationRaw,
            "targetDistanceMeters": workout.targetDistanceMeters as Any,
            "targetPaceLowerBound": workout.targetPaceLowerBound as Any,
            "targetPaceUpperBound": workout.targetPaceUpperBound as Any,
            "isCompleted": workout.isCompleted,
            "notes": workout.notes as Any,
            "healthKitPlanID": workout.healthKitPlanID as Any,
            "intervalCount": workout.intervals.count,
            "hasStructure": workout.workoutStructure != nil,
            "weekID": workout.week?.id.uuidString as Any,
            "completedWorkoutID": workout.completedWorkout?.id.uuidString as Any
        ]
    }

    private func runWorkoutPayload(_ workout: RunWorkout) -> [String: Any] {
        [
            "id": workout.id.uuidString,
            "date": workout.date.ISO8601Format(),
            "distanceMeters": workout.distanceMeters,
            "durationSeconds": workout.durationSeconds,
            "averagePaceSecondsPerKm": workout.averagePaceSecondsPerKm,
            "averageHeartRate": workout.averageHeartRate as Any,
            "maxHeartRate": workout.maxHeartRate as Any,
            "elevationGainMeters": workout.elevationGainMeters as Any,
            "workoutType": workout.workoutTypeRaw,
            "workoutLocation": workout.workoutLocationRaw,
            "notes": workout.notes as Any,
            "healthKitWorkoutID": workout.healthKitWorkoutID as Any,
            "splitCount": workout.splits.count,
            "routePointCount": workout.routeCoordinates.count,
            "hasWeather": workout.weather != nil,
            "scheduledWorkoutID": workout.scheduledWorkout?.id.uuidString as Any
        ]
    }

    private func savedRoutePayload(_ route: SavedRoute) -> [String: Any] {
        [
            "id": route.id.uuidString,
            "name": route.name,
            "createdAt": route.createdAt.ISO8601Format(),
            "routeType": route.routeTypeRaw,
            "requestedDistanceMeters": route.requestedDistanceMeters,
            "actualDistanceMeters": route.actualDistanceMeters,
            "estimatedDurationSeconds": route.estimatedDurationSeconds,
            "startLatitude": route.startLatitude,
            "startLongitude": route.startLongitude,
            "coordinateCount": route.coordinates.count,
            "stepCount": route.steps.count
        ]
    }

    private func prettyPrinted(_ value: [[String: Any]]) -> String? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
