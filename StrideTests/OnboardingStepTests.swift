import Testing
@testable import Stride

// MARK: - OnboardingStep tests
//
// The step numbers are what the progress bar shows and what UI tests find buttons by
// (`onboarding.primaryCTA.<n>`), so they are pinned here as well as the order.

struct OnboardingStepTests {

    @Test("Step numbers match the ones the flow has always used")
    func rawValuesArePinned() {
        let expected: [OnboardingStep: Int] = [
            .welcome: 0, .goal: 1, .timing: 2, .level: 3, .calibrate: 4,
            .schedule: 5, .strength: 6, .permissions: 7, .ready: 8,
        ]
        for (step, number) in expected {
            #expect(step.rawValue == number)
        }
        #expect(OnboardingStep.allCases.count == expected.count)
    }

    @Test("The progress bar counts eight steps: welcome is not one")
    func countedSteps() {
        #expect(OnboardingStep.countedSteps == 8)
    }

    @Test("Continue walks every step in order")
    func nextWalksInOrder() {
        var step = OnboardingStep.welcome
        var visited = [step]
        while step != .ready {
            step = step.next
            visited.append(step)
        }
        #expect(visited == OnboardingStep.allCases)
    }

    @Test("Back from each step returns to the one before")
    func previousUndoesNext() {
        for step in OnboardingStep.allCases where step != .ready {
            #expect(step.next.previous == step)
        }
    }

    @Test("The ends stay put: no step before welcome, none after ready")
    func endsAreClamped() {
        #expect(OnboardingStep.welcome.previous == .welcome)
        #expect(OnboardingStep.ready.next == .ready)
    }
}
