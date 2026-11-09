import Foundation

// MARK: - OnboardingStep

/// The onboarding screens, in order.
///
/// `OnboardingView` used to keep this as `step: Int`, with `case 4 where
/// isPregnancyPlan:` in its `switch` and the last screen as `default:`, so adding a step
/// meant renumbering every `case` and `OBShell(stepIndex:)` by hand, and `step -= 1` from
/// the welcome screen landed on `default` (the ready screen). The order is the same for
/// every plan kind; what a step *asks* varies by plan (the calibrate step is a health
/// check for a pregnancy plan and a starting point for a Start Running plan), which stays
/// in the view's `where` clauses.
///
/// ```
///   welcome → goal → timing → level → calibrate → schedule → strength → permissions → ready
/// ```
///
/// Raw values are the step numbers the progress bar and the UI tests'
/// `onboarding.primaryCTA.<n>` identifiers already use; never renumber an existing case.
enum OnboardingStep: Int, CaseIterable, Sendable {
    /// Uncounted: sign in, or start fresh.
    case welcome = 0
    case goal
    case timing
    case level
    /// The 5K time; a health check for a pregnancy plan; a starting point for Start Running.
    case calibrate
    case schedule
    case strength
    case permissions
    /// The plan preview and "View my plan". The last step, so its number is the total.
    case ready

    /// How many steps the progress bar counts (the welcome screen is not one).
    static let countedSteps = OnboardingStep.ready.rawValue

    /// The step Continue goes to. The ready screen is the end, so it stays put.
    var next: OnboardingStep {
        OnboardingStep(rawValue: rawValue + 1) ?? self
    }

    /// The step Back goes to. The welcome screen is the start, so it stays put.
    var previous: OnboardingStep {
        OnboardingStep(rawValue: rawValue - 1) ?? self
    }
}
