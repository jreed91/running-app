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
    /// Deliberately *not* date-bounded, unlike the other two Progress screens (U9):
    /// the medals are all-time personal records, and the badges count lifetime
    /// distance and the longest streak ever recorded — a window would quietly
    /// redefine all three. What made this screen expensive was recomputing those
    /// derivations several times per render, and that is fixed in `body`.
    ///
    /// Runs only, and for the same reason the window is absent: a medal is a running
    /// record, the badges count kilometres run and days run in a row, and an imported
    /// walk would quietly redefine all of them (N38).
    @Query(RunWorkout.runsOnlyDescriptor(sortBy: [SortDescriptor(\RunWorkout.date)]))
    private var workouts: [RunWorkout]

    @Environment(AppSettings.self) private var appSettings

    @State private var appeared = false
    @State private var editingGoal = false

    // Symbols sized by `.font` and the circles behind them have to scale *together*,
    // or the glyph outgrows its badge at large content sizes (U2). `@ScaledMetric`
    // was unused anywhere in the app before this.
    @ScaledMetric(relativeTo: .largeTitle) private var streakBadgeSize: CGFloat = 64
    @ScaledMetric(relativeTo: .title2) private var badgeCircleSize: CGFloat = 52
    @ScaledMetric(relativeTo: .largeTitle) private var medalGlyphSize: CGFloat = 34

    private let eligibleTypes: Set<WorkoutType> = [.easy, .tempo, .interval, .longRun, .race]

    // MARK: Derived stats

    var body: some View {
        // Each of these walks the whole run history, and `achievements` walks it
        // several times over. They used to be computed properties read from inside
        // the section builders — and `badgeSection` is called once per category, so
        // the full set was recomputed four times on every render pass (U9). Derived
        // once here and handed down instead.
        let streak = StreakGoalService.streak(for: workouts)
        let weekly = StreakGoalService.weeklyProgress(
            for: workouts,
            goalMeters: appSettings.weeklyGoalMeters
        )
        let achievements = StreakGoalService.achievements(
            for: workouts,
            unit: appSettings.unitPreference
        )

        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                streakCard(streak)
                    .fadeSlide(appeared, delay: 0.05)

                weeklyGoalCard(weekly)
                    .fadeSlide(appeared, delay: 0.10)

                ForEach(Array(StreakGoalService.AchievementCategory.allCases.enumerated()), id: \.element) { index, category in
                    badgeSection(for: category, achievements: achievements)
                        .fadeSlide(appeared, delay: 0.15 + Double(index) * 0.05)
                }

                medalsSection
                    .fadeSlide(
                        appeared,
                        delay: 0.15 + Double(StreakGoalService.AchievementCategory.allCases.count) * 0.05
                    )
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

    private func streakCard(_ streak: StreakGoalService.StreakSummary) -> some View {
        HStack(spacing: AppSpacing.lg) {
            ZStack {
                Circle()
                    .fill(streak.current > 0 ? Color.warning.opacity(0.15) : Color.secondary.opacity(0.12))
                    .frame(width: streakBadgeSize, height: streakBadgeSize)
                Image(systemName: "flame.fill")
                    .font(.system(size: streakBadgeSize * 0.47))
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
                Text(streakSubtitle(streak))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(AppSpacing.lg)
        .strideCard(cornerRadius: AppRadius.lg)
    }

    private func streakSubtitle(_ streak: StreakGoalService.StreakSummary) -> String {
        if streak.current == 0 {
            return streak.longest > 0 ? "Longest: \(streak.longest) days • run today to start again" : "Run today to start a streak"
        }
        if !streak.isActiveToday {
            return "Longest: \(streak.longest) days • run today to keep it going"
        }
        return "Longest: \(streak.longest) days"
    }

    // MARK: Weekly goal

    private func weeklyGoalCard(_ weekly: StreakGoalService.WeeklyGoalProgress) -> some View {
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
                Text(weeklyGoalSubtitle(weekly))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                editingGoal = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.dsCallout.weight(.semibold))
                    .foregroundStyle(.brand)
                    .padding(AppSpacing.sm)
                    .background(Color.brand.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("Edit weekly goal")
        }
        .padding(AppSpacing.lg)
        .strideCard(cornerRadius: AppRadius.lg)
    }

    private func weeklyGoalSubtitle(_ weekly: StreakGoalService.WeeklyGoalProgress) -> String {
        let goal = appSettings.weeklyGoalMeters.distanceString(unit: appSettings.unitPreference)
        if weekly.isMet {
            return "Goal reached — \(goal) 🎉"
        }
        return "\(weekly.remainingMeters.distanceString(unit: appSettings.unitPreference)) to go of \(goal)"
    }

    // MARK: Badges

    private func badgeSection(
        for category: StreakGoalService.AchievementCategory,
        achievements: [StreakGoalService.Achievement]
    ) -> some View {
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
                    .frame(width: badgeCircleSize, height: badgeCircleSize)
                Image(systemName: badge.isEarned ? systemImage : "lock.fill")
                    .font(.system(size: badgeCircleSize * 0.42))
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
        .strideCard(cornerRadius: AppRadius.md)
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
                .font(.system(size: medalGlyphSize))
                .foregroundStyle(bucket.bestRun != nil ? Color.warning : Color.secondary.opacity(0.25))
                .frame(width: medalGlyphSize * 1.3)

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
        .strideCard(cornerRadius: AppRadius.md)
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
                    isComplete ? AnyShapeStyle(Color.success) : AnyShapeStyle(.route),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            if isComplete {
                Image(systemName: "checkmark")
                    .font(.dsTitle3.weight(.bold))
                    .foregroundStyle(Color.success)
                    // Draws itself in the first time the ring closes, rather than
                    // appearing fully formed with no acknowledgement that anything
                    // was earned.
                    .transition(.symbolEffect(.drawOn))
            } else {
                Text("\(Int(fraction * 100))%")
                    .font(.captionStrong)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        // The transition above only runs if the insertion is animated, and the ring's
        // completion is a data change rather than a user gesture. Routed through
        // `adaptiveAnimation` so Reduce Motion still gets a plain cross-fade.
        .adaptiveAnimation(AppAnimation.bouncy, value: isComplete)
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
