import SwiftUI
import SwiftData

// MARK: - AchievementsView
//
// The Progress → Achievements sub-tab. Surfaces the run streak, the weekly
// distance-goal ring, consistency badges, and the per-distance PR medals.
// All logic lives in `StreakGoalService` / `ProgressStatsService`; this view
// only lays the results out.

private struct MedalBucket: Identifiable {
    let id: String
    let name: String
    let targetMeters: Double
    let bestRun: RunWorkout?
}

@MainActor
struct AchievementsView: View {
    @Query(sort: [SortDescriptor(\RunWorkout.date)])
    private var workouts: [RunWorkout]

    @Environment(AppSettings.self) private var appSettings

    @State private var appeared = false
    @State private var editingGoal = false

    private let eligibleTypes: Set<WorkoutType> = [.easy, .tempo, .interval, .longRun, .race]

    // MARK: Derived stats

    private var streak: StreakGoalService.StreakSummary {
        StreakGoalService.streak(for: workouts)
    }

    private var weekly: StreakGoalService.WeeklyGoalProgress {
        StreakGoalService.weeklyProgress(for: workouts, goalMeters: appSettings.weeklyGoalMeters)
    }

    private var achievements: [StreakGoalService.Achievement] {
        StreakGoalService.achievements(for: workouts, unit: appSettings.unitPreference)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                streakCard
                    .fadeSlide(appeared, delay: 0.05)

                weeklyGoalCard
                    .fadeSlide(appeared, delay: 0.10)

                ForEach(Array(StreakGoalService.AchievementCategory.allCases.enumerated()), id: \.element) { index, category in
                    badgeSection(for: category)
                        .fadeSlide(appeared, delay: 0.15 + Double(index) * 0.05)
                }

                medalsSection
                    .fadeSlide(appeared, delay: 0.30)
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task { appeared = true }
        }
        .background(Color.surfacePrimary)
        .overlay {
            if workouts.isEmpty {
                ContentUnavailableView(
                    "No runs yet",
                    systemImage: "medal",
                    description: Text("Complete your first run to start a streak and earn badges.")
                )
            }
        }
        .sheet(isPresented: $editingGoal) {
            WeeklyGoalEditor()
                .environment(appSettings)
        }
    }

    // MARK: Streak

    private var streakCard: some View {
        HStack(spacing: AppSpacing.lg) {
            ZStack {
                Circle()
                    .fill(streak.current > 0 ? Color.warning.opacity(0.15) : Color.secondary.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: "flame.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(streak.current > 0 ? Color.warning : Color.secondary.opacity(0.35))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(streak.current)")
                        .font(.metricS)
                        .monospacedDigit()
                    Text("day streak")
                        .font(.bodyStrong)
                        .foregroundStyle(.secondary)
                }
                Text(streakSubtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(AppSpacing.lg)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    private var streakSubtitle: String {
        if streak.current == 0 {
            return streak.longest > 0 ? "Longest: \(streak.longest) days • run today to start again" : "Run today to start a streak"
        }
        if !streak.isActiveToday {
            return "Longest: \(streak.longest) days • run today to keep it going"
        }
        return "Longest: \(streak.longest) days"
    }

    // MARK: Weekly goal

    private var weeklyGoalCard: some View {
        HStack(spacing: AppSpacing.lg) {
            ProgressRing(fraction: weekly.fraction, isComplete: weekly.isMet)
                .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 3) {
                Text("This Week")
                    .font(.sectionHeader)
                    .foregroundStyle(.secondary)
                Text(weekly.completedMeters.distanceString(unit: appSettings.unitPreference))
                    .font(.metricS)
                    .monospacedDigit()
                Text(weeklyGoalSubtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                editingGoal = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.brand)
                    .padding(AppSpacing.sm)
                    .background(Color.brand.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("Edit weekly goal")
        }
        .padding(AppSpacing.lg)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    private var weeklyGoalSubtitle: String {
        let goal = appSettings.weeklyGoalMeters.distanceString(unit: appSettings.unitPreference)
        if weekly.isMet {
            return "Goal reached — \(goal) 🎉"
        }
        return "\(weekly.remainingMeters.distanceString(unit: appSettings.unitPreference)) to go of \(goal)"
    }

    // MARK: Badges

    private func badgeSection(for category: StreakGoalService.AchievementCategory) -> some View {
        let items = achievements.filter { $0.category == category }
        return VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(category.sectionTitle)
                .font(.sectionHeader)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: AppSpacing.md), count: 3), spacing: AppSpacing.md) {
                ForEach(items) { badge in
                    badgeCell(badge, systemImage: category.systemImage)
                }
            }
        }
    }

    private func badgeCell(_ badge: StreakGoalService.Achievement, systemImage: String) -> some View {
        VStack(spacing: AppSpacing.xs) {
            ZStack {
                Circle()
                    .fill(badge.isEarned ? Color.brand.opacity(0.16) : Color.secondary.opacity(0.10))
                    .frame(width: 52, height: 52)
                Image(systemName: badge.isEarned ? systemImage : "lock.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(badge.isEarned ? Color.brand : Color.secondary.opacity(0.4))
            }

            Text(badge.title)
                .font(.captionStrong)
                .multilineTextAlignment(.center)
                .foregroundStyle(badge.isEarned ? .primary : .secondary)

            if badge.isEarned {
                Text("Earned")
                    .font(.caption)
                    .foregroundStyle(Color.success)
            } else {
                Text("\(Int(badge.progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.sm)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(badge.title). \(badge.detail). \(badge.isEarned ? "Earned" : "\(Int(badge.progress * 100)) percent complete")")
    }

    // MARK: Distance medals

    private var medalsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Distance Records")
                .font(.sectionHeader)
                .foregroundStyle(.secondary)
            Text("Your fastest time at each distance")
                .font(.bodyRegular)
                .foregroundStyle(.secondary)
                .padding(.bottom, AppSpacing.xs)

            ForEach(buckets) { bucket in
                medalCard(bucket)
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
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}

// MARK: - ProgressRing

/// A thin circular progress ring used for the weekly-goal card.
private struct ProgressRing: View {
    let fraction: Double
    let isComplete: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: 8)
            Circle()
                .trim(from: 0, to: max(0.001, fraction))
                .stroke(
                    isComplete ? Color.success : Color.brand,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            if isComplete {
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.success)
            } else {
                Text("\(Int(fraction * 100))%")
                    .font(.captionStrong)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - WeeklyGoalEditor

/// Sheet for adjusting the weekly distance goal in the user's unit.
private struct WeeklyGoalEditor: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.dismiss) private var dismiss

    private var stepMeters: Double {
        appSettings.unitPreference == .metric ? 1_000 : 1_609.344
    }

    var body: some View {
        @Bindable var settings = appSettings
        NavigationStack {
            Form {
                Section {
                    Stepper(
                        value: $settings.weeklyGoalMeters,
                        in: 3_000...200_000,
                        step: stepMeters
                    ) {
                        HStack {
                            Text("Weekly goal")
                            Spacer()
                            Text(settings.weeklyGoalMeters.distanceString(unit: settings.unitPreference))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } footer: {
                    Text("Your target running distance each week. The Achievements ring fills as you log runs Monday through Sunday.")
                }
            }
            .navigationTitle("Weekly Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Entrance helper

private extension View {
    /// Applies the shared fade-and-slide entrance animation used across the
    /// Achievements surface.
    func fadeSlide(_ appeared: Bool, delay: Double) -> some View {
        opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 18)
            .adaptiveAnimation(AppAnimation.entrance.delay(delay), value: appeared)
    }
}

#Preview {
    AchievementsView()
        .environment(AppSettings())
        .modelContainer(for: RunWorkout.self, inMemory: true)
}
