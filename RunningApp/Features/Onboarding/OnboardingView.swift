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
    @State private var iCloudSyncEnabled = true
    @State private var locationManager = CLLocationManager()

    var body: some View {
        TabView(selection: $step) {
            nameStep.tag(0)
            goalStep.tag(1)
            fitnessStep.tag(2)
            scheduleStep.tag(3)
            locationStep.tag(4)
            healthKitStep.tag(5)
            iCloudSyncStep.tag(6)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .animation(.easeInOut, value: step)
        .ignoresSafeArea(edges: .top)
    }

    // MARK: Steps

    private var nameStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("What's your name?")
                .font(.metricMedium)
            TextField("Runner name", text: $name)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
            Spacer()
            nextButton(enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty)
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
            nextButton(enabled: true)
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
            nextButton(enabled: true)
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
            nextButton(enabled: weeklyRunDays >= 2)
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
            Button("Enable Location") {
                locationManager.requestWhenInUseAuthorization()
                withAnimation { step += 1 }
            }
            .buttonStyle(.borderedProminent)
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
            Button("Enable Health Access") {
                Task { try? await container.healthKitRepository.requestAuthorization() }
                withAnimation { step += 1 }
            }
            .buttonStyle(.borderedProminent)
            Button("Skip") {
                withAnimation { step += 1 }
            }
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var iCloudSyncStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "icloud.fill")
                .font(.system(size: 56))
                .foregroundStyle(.blue)
            Text("iCloud Sync")
                .font(.metricMedium)
            Text("Keep your workouts and training plans up to date across all your iPhone and iPad devices automatically.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Toggle("Sync with iCloud", isOn: $iCloudSyncEnabled)
                .padding(.horizontal)
                .tint(.blue)
            Spacer()
            Button {
                UserDefaults.standard.set(iCloudSyncEnabled, forKey: AppSettings.iCloudSyncKey)
                isCreatingPlan = true
                createProfileAndPlan()
            } label: {
                Group {
                    if isCreatingPlan {
                        ProgressView()
                    } else {
                        Text("Start Training")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isCreatingPlan)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func nextButton(enabled: Bool) -> some View {
        Button("Next") { withAnimation { step += 1 } }
            .buttonStyle(.borderedProminent)
            .disabled(!enabled)
    }

    // MARK: Actions

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
