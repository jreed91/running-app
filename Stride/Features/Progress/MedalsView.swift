import SwiftUI
import SwiftData

private struct MedalBucket: Identifiable {
    let id: String
    let name: String
    let targetMeters: Double
    let bestRun: RunWorkout?
}

@MainActor
struct MedalsView: View {
    @Query(sort: [SortDescriptor(\RunWorkout.date)])
    private var workouts: [RunWorkout]

    @Environment(AppSettings.self) private var appSettings

    @State private var medalsAppeared = false

    private let eligibleTypes: Set<WorkoutType> = [.easy, .tempo, .interval, .longRun, .race]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text("Your fastest time at each distance")
                    .font(.bodyRegular)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, AppSpacing.xs)
                    .opacity(medalsAppeared ? 1 : 0)
                    .offset(y: medalsAppeared ? 0 : 10)
                    .adaptiveAnimation(AppAnimation.entrance.delay(0.05), value: medalsAppeared)

                ForEach(Array(buckets.enumerated()), id: \.element.id) { index, bucket in
                    medalCard(bucket)
                        .opacity(medalsAppeared ? 1 : 0)
                        .offset(y: medalsAppeared ? 0 : 18)
                        .adaptiveAnimation(
                            AppAnimation.entrance.delay(0.10 + Double(index) * 0.06),
                            value: medalsAppeared
                        )
                }
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity)
            .task { medalsAppeared = true }
        }
        .background(Color.surfacePrimary)
        .overlay {
            if workouts.isEmpty {
                ContentUnavailableView(
                    "No runs yet",
                    systemImage: "medal",
                    description: Text("Complete your first run to start earning medals.")
                )
            }
        }
    }

    private var buckets: [MedalBucket] {
        let shortest: MedalBucket = appSettings.unitPreference == .imperial
            ? makeBucket(id: "1mi", name: "1 Mile", meters: 1_609.344)
            : makeBucket(id: "1K", name: "1K", meters: 1_000)
        return [
            shortest,
            makeBucket(id: "5K",  name: "5K",            meters: 5_000),
            makeBucket(id: "10K", name: "10K",           meters: 10_000),
            makeBucket(id: "HM",  name: "Half Marathon", meters: 21_097.5),
            makeBucket(id: "M",   name: "Marathon",      meters: 42_195),
        ]
    }

    private func makeBucket(id: String, name: String, meters: Double) -> MedalBucket {
        MedalBucket(id: id, name: name, targetMeters: meters, bestRun: prRun(for: meters))
    }

    private func prRun(for targetMeters: Double) -> RunWorkout? {
        ProgressStatsService.personalRecordRun(
            in: workouts,
            targetMeters: targetMeters,
            eligibleTypes: eligibleTypes
        )
    }

    private func medalCard(_ bucket: MedalBucket) -> some View {
        HStack(spacing: AppSpacing.lg) {
            Image(systemName: "medal.fill")
                .font(.system(size: 34))
                .foregroundStyle(bucket.bestRun != nil ? Color.warning : Color.secondary.opacity(0.25))
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(bucket.name)
                    .font(.bodyStrong)
                if let run = bucket.bestRun {
                    Text(run.durationSeconds.durationString)
                        .font(.metricS)
                        .foregroundStyle(.primary)
                } else {
                    Text("No runs yet")
                        .font(.bodyRegular)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if let run = bucket.bestRun {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(run.date, format: .dateTime.month(.abbreviated).day().year())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(run.averagePaceSecondsPerKm.paceString(unit: appSettings.unitPreference))
                        .font(.captionStrong)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(AppSpacing.lg)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
    }
}

#Preview {
    MedalsView()
        .environment(AppSettings())
        .modelContainer(for: RunWorkout.self, inMemory: true)
}
