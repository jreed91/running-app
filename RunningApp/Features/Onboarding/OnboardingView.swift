import SwiftUI
import SwiftData

struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.appContainer) private var container

    @State private var name = ""
    @State private var goalRace: RaceType = .fiveK
    @State private var fitnessLevel: FitnessLevel = .beginner
    @State private var weeklyRunDays = 3
    @State private var known5KMinutes = 30.0
    @State private var goalMinutes = 25.0
    @State private var step = 0

    var body: some View {
        NavigationStack {
            TabView(selection: $step) {
                nameStep.tag(0)
                goalStep.tag(1)
                fitnessStep.tag(2)
                scheduleStep.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .animation(.easeInOut, value: step)
        }
    }

    // MARK: Steps

    private var nameStep: some View {
        VStack(spacing: 24) {
            Text("What's your name?")
                .font(.metricMedium)
            TextField("Runner name", text: $name)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
            nextButton(enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
    }

    private var goalStep: some View {
        VStack(spacing: 24) {
            Text("Pick your race goal")
                .font(.metricMedium)
            Picker("Race", selection: $goalRace) {
                ForEach(RaceType.allCases, id: \.self) { Text($0.displayName) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            nextButton(enabled: true)
        }
        .padding()
    }

    private var fitnessStep: some View {
        VStack(spacing: 24) {
            Text("Current fitness level")
                .font(.metricMedium)
            Picker("Fitness", selection: $fitnessLevel) {
                ForEach(FitnessLevel.allCases, id: \.self) { Text($0.displayName) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            nextButton(enabled: true)
        }
        .padding()
    }

    private var scheduleStep: some View {
        VStack(spacing: 24) {
            Text("How many days per week?")
                .font(.metricMedium)
            Stepper("\(weeklyRunDays) days", value: $weeklyRunDays, in: 2...6)
                .padding(.horizontal)
            Button("Start Training") { createProfile() }
                .buttonStyle(.borderedProminent)
                .disabled(weeklyRunDays < 2)
        }
        .padding()
    }

    private func nextButton(enabled: Bool) -> some View {
        Button("Next") { withAnimation { step += 1 } }
            .buttonStyle(.borderedProminent)
            .disabled(!enabled)
    }

    // MARK: Actions

    private func createProfile() {
        let profile = UserProfile(
            name: name.trimmingCharacters(in: .whitespaces),
            goalRace: goalRace,
            goalFinishTime: goalMinutes * 60,
            weeklyRunDays: weeklyRunDays,
            fitnessLevel: fitnessLevel
        )
        context.insert(profile)
        try? context.save()
    }
}
