import SwiftUI
import SwiftData
import CoreLocation
import UserNotifications
import HealthKit

struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.appContainer) private var container
    @Environment(AppSettings.self) private var appSettings

    @State private var name = ""
    @State private var goalRace: RaceType = .fiveK
    @State private var fitnessLevel: FitnessLevel = .beginner
    @State private var weeklyRunDays = 3
    @State private var goalPaceMinutes = 5
    @State private var goalPaceSeconds = 30
    @State private var stepIndex = 0
    @State private var isCreatingPlan = false
    @State private var locationManager = CLLocationManager()
    @State private var visibleSteps: [OnboardingStep] = OnboardingStep.allCases
    @FocusState private var isNameFocused: Bool

    private enum OnboardingStep: CaseIterable {
        case name, unitPreference, goalRace, goalPace, fitnessLevel, schedule,
             location, locationWaiting, notifications, notificationsWaiting, healthKit
    }

    var body: some View {
        TabView(selection: $stepIndex) {
            ForEach(Array(visibleSteps.enumerated()), id: \.offset) { index, stepCase in
                stepView(for: stepCase).tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .animation(.easeInOut, value: stepIndex)
        .ignoresSafeArea(edges: .top)
        .safeAreaInset(edge: .bottom) {
            stepButton
                .padding(.horizontal)
                .padding(.bottom)
        }
        .task { await buildVisibleSteps() }
    }

    // MARK: - Permission-aware step list

    private func buildVisibleSteps() async {
        var steps: [OnboardingStep] = [.name, .unitPreference, .goalRace, .goalPace, .fitnessLevel, .schedule]

        if locationManager.authorizationStatus == .notDetermined {
            steps.append(.location)
            steps.append(.locationWaiting)
        }

        let notifStatus = await UNUserNotificationCenter.current().notificationSettings()
        if notifStatus.authorizationStatus == .notDetermined {
            steps.append(.notifications)
            steps.append(.notificationsWaiting)
        }

        // HealthKit step is always last — it triggers plan creation.
        // requestAuthorization is a no-op if the user has already responded.
        steps.append(.healthKit)

        visibleSteps = steps
    }

    // MARK: - Step button

    @ViewBuilder
    private var stepButton: some View {
        let current = visibleSteps.indices.contains(stepIndex) ? visibleSteps[stepIndex] : .name
        switch current {
        case .name:
            Button {
                isNameFocused = false
                withAnimation { stepIndex += 1 }
            } label: {
                Text("Next").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        case .unitPreference, .goalRace, .goalPace, .fitnessLevel:
            nextButton(enabled: true)
        case .schedule:
            nextButton(enabled: weeklyRunDays >= 2)
        case .locationWaiting, .notificationsWaiting:
            nextButton(enabled: true)
        case .location:
            Button {
                locationManager.requestWhenInUseAuthorization()
                withAnimation { stepIndex += 1 }
            } label: {
                Text("Enable Location").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        case .notifications:
            Button {
                Task {
                    try? await NotificationService.shared.requestAuthorization()
                    withAnimation { stepIndex += 1 }
                }
            } label: {
                Text("Enable Notifications").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        case .healthKit:
            Button {
                Task { await requestHealthKitThenCreatePlan() }
            } label: {
                Group {
                    if isCreatingPlan { ProgressView() } else { Text("Start Training") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isCreatingPlan)
        }
    }

    // MARK: - Step views

    @ViewBuilder
    private func stepView(for step: OnboardingStep) -> some View {
        switch step {
        case .name:                 nameStep
        case .unitPreference:       unitPreferenceStep
        case .goalRace:             goalStep
        case .goalPace:             goalPaceStep
        case .fitnessLevel:         fitnessStep
        case .schedule:             scheduleStep
        case .location:             locationStep
        case .locationWaiting:      locationWaitingStep
        case .notifications:        notificationsStep
        case .notificationsWaiting: notificationsWaitingStep
        case .healthKit:            healthKitStep
        }
    }

    private var nameStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("What's your name?")
                .font(.metricMedium)
            TextField("Runner name", text: $name)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .focused($isNameFocused)
                .submitLabel(.next)
                .onSubmit {
                    if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                        withAnimation { stepIndex += 1 }
                    }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { isNameFocused = false }
                    }
                }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { isNameFocused = false }
    }

    private var unitPreferenceStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "ruler")
                .font(.system(size: 56))
                .foregroundStyle(.blue)
            Text("How do you measure distance?")
                .font(.metricMedium)
                .multilineTextAlignment(.center)
            Picker("Units", selection: Bindable(appSettings).unitPreference) {
                ForEach(UnitPreference.allCases, id: \.self) { unit in
                    Text(unit.displayName).tag(unit)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var goalStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("Pick your race goal")
                .font(.metricMedium)
            Picker("Race", selection: $goalRace) {
                ForEach(RaceType.allCases, id: \.self) { Text($0.displayName) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var goalPaceStep: some View {
        let minutesRange = appSettings.unitPreference == .imperial ? 4...25 : 3...15
        return VStack(spacing: 24) {
            Spacer()
            Text("What's your goal pace?")
                .font(.metricMedium)
            Text(appSettings.unitPreference.paceLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                Picker("Minutes", selection: $goalPaceMinutes) {
                    ForEach(minutesRange, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.wheel)
                .frame(width: 80)
                Text(":")
                    .font(.title2.bold())
                Picker("Seconds", selection: $goalPaceSeconds) {
                    ForEach(stride(from: 0, through: 55, by: 5).map { $0 }, id: \.self) {
                        Text(String(format: "%02d", $0)).tag($0)
                    }
                }
                .pickerStyle(.wheel)
                .frame(width: 80)
                Text("/ \(appSettings.unitPreference.distanceLabel)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fitnessStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("Current fitness level")
                .font(.metricMedium)
            Picker("Fitness", selection: $fitnessLevel) {
                ForEach(FitnessLevel.allCases, id: \.self) { Text($0.displayName) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scheduleStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("How many days per week?")
                .font(.metricMedium)
            Stepper("\(weeklyRunDays) days", value: $weeklyRunDays, in: 2...6)
                .padding(.horizontal)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var locationStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "location.fill")
                .font(.system(size: 56))
                .foregroundStyle(.blue)
            Text("Track Your Route")
                .font(.metricMedium)
            Text("GPS is used to map your runs, measure distance, and calculate pace. Your location is never shared.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notificationsStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "bell.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("Stay on Track")
                .font(.metricMedium)
            Text("Get reminders before each scheduled workout so you never miss a training session.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var locationWaitingStep: some View {
        VStack(spacing: 32) {
            Spacer()
            Text("Tap \u{201C}Allow\u{201D} in the prompt above")
                .font(.metricSmall)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            PermissionAlertMockup(
                symbolName: "location.fill",
                symbolColor: .blue,
                title: "Allow \u{201C}Running App\u{201D} to access your location?",
                message: "Your location is used to map routes and calculate pace. It is never shared.",
                primaryButtonLabel: "Allow While Using App"
            )
            .padding(.horizontal)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notificationsWaitingStep: some View {
        VStack(spacing: 32) {
            Spacer()
            Text("Tap \u{201C}Allow\u{201D} in the prompt above")
                .font(.metricSmall)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            PermissionAlertMockup(
                symbolName: "bell.fill",
                symbolColor: .orange,
                title: "Allow \u{201C}Running App\u{201D} to send you notifications?",
                message: "Notifications are used to remind you about upcoming workouts.",
                primaryButtonLabel: "Allow"
            )
            .padding(.horizontal)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var healthKitStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "heart.fill")
                .font(.system(size: 56))
                .foregroundStyle(.red)
            Text("Connect Health")
                .font(.metricMedium)
            Text("Allow access to Apple Health so your runs are saved and your training plan adapts to your real fitness data.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func nextButton(enabled: Bool) -> some View {
        Button { withAnimation { stepIndex += 1 } } label: {
            Text("Next").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!enabled)
    }

    // MARK: - Actions

    private func requestHealthKitThenCreatePlan() async {
        isCreatingPlan = true
        try? await container.healthKitRepository.requestAuthorization()
        createProfileAndPlan()
    }

    private func createProfileAndPlan() {
        let paceSecondsRaw = Double(goalPaceMinutes * 60 + goalPaceSeconds)
        let paceSecondsPerKm = appSettings.unitPreference == .imperial
            ? paceSecondsRaw / 1.60934
            : paceSecondsRaw
        let distanceKm = goalRace.distanceMeters / 1_000
        let goalFinishTime = paceSecondsPerKm * distanceKm
        let profile = UserProfile(
            name: name.trimmingCharacters(in: .whitespaces),
            goalRace: goalRace,
            goalFinishTime: goalFinishTime,
            weeklyRunDays: weeklyRunDays,
            fitnessLevel: fitnessLevel
        )
        context.insert(profile)

        let startDate = Date().startOfWeek.adding(weeks: 1)
        let numberOfWeeks = goalRace.typicalWeeks.lowerBound
        let plan = container.trainingPlanService.generatePlan(
            profile: profile,
            startDate: startDate,
            numberOfWeeks: numberOfWeeks,
            unitPreference: appSettings.unitPreference
        )
        context.insert(plan)
        try? context.save()
    }
}

// MARK: - Permission alert mockup

private struct PermissionAlertMockup: View {
    let symbolName: String
    let symbolColor: Color
    let title: String
    let message: String
    let primaryButtonLabel: String

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(systemName: symbolName)
                    .font(.system(size: 36))
                    .foregroundStyle(symbolColor)
                    .padding(.top, 20)
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)

            Divider()
            Button { } label: {
                Text(primaryButtonLabel)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .disabled(true)
            Divider()
            Button { } label: {
                Text("Don't Allow")
                    .font(.body)
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .disabled(true)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 16, x: 0, y: 4)
    }
}
