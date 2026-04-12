import SwiftUI
import SwiftData
import CoreLocation

struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.appContainer) private var container

    @State private var name = ""
    @State private var goalRace: RaceType = .fiveK
    @State private var fitnessLevel: FitnessLevel = .beginner
    @State private var weeklyRunDays = 3
    @State private var goalMinutes = 25.0
    @State private var step = 0
    @State private var isCreatingPlan = false
    @State private var locationManager = CLLocationManager()

    var body: some View {
        TabView(selection: $step) {
            nameStep.tag(0)
            goalStep.tag(1)
            fitnessStep.tag(2)
            scheduleStep.tag(3)
            locationStep.tag(4)
            notificationsStep.tag(5)
            healthKitStep.tag(6)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .animation(.easeInOut, value: step)
        .ignoresSafeArea(edges: .top)
        .safeAreaInset(edge: .bottom) {
            stepButton
                .padding(.horizontal)
                .padding(.bottom)
        }
    }

    // MARK: - Step button

    @ViewBuilder
    private var stepButton: some View {
        switch step {
        case 0:
            nextButton(enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty)
        case 1, 2:
            nextButton(enabled: true)
        case 3:
            nextButton(enabled: weeklyRunDays >= 2)
        case 4:
            Button {
                locationManager.requestWhenInUseAuthorization()
                withAnimation { step += 1 }
            } label: {
                Text("Enable Location").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        case 5:
            Button {
                Task {
                    try? await NotificationService.shared.requestAuthorization()
                    withAnimation { step += 1 }
                }
            } label: {
                Text("Enable Notifications").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        case 6:
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
        default:
            EmptyView()
        }
    }

    // MARK: - Steps

    private var nameStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("What's your name?")
                .font(.metricMedium)
            TextField("Runner name", text: $name)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .submitLabel(.next)
                .onSubmit {
                    if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                        withAnimation { step += 1 }
                    }
                }
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
        Button { withAnimation { step += 1 } } label: {
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
        let profile = UserProfile(
            name: name.trimmingCharacters(in: .whitespaces),
            goalRace: goalRace,
            goalFinishTime: goalMinutes * 60,
            weeklyRunDays: weeklyRunDays,
            fitnessLevel: fitnessLevel
        )
        context.insert(profile)

        let startDate = Date().startOfWeek.adding(weeks: 1)
        let numberOfWeeks = goalRace == .fiveK ? 8 : 12
        let plan = container.trainingPlanService.generatePlan(
            profile: profile,
            startDate: startDate,
            numberOfWeeks: numberOfWeeks
        )
        context.insert(plan)
        try? context.save()
    }
}
