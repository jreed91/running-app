import Foundation

// MARK: - Copy

/// The words for breaks, in one place so the card and the sheet say the same thing.
enum TrainingBreakText {

    static func reasonName(_ reason: TrainingBreak.Reason) -> String {
        switch reason {
        case .ill: return String(localized: "Ill", comment: "Training break reason")
        case .injured: return String(localized: "Injured", comment: "Training break reason")
        case .travelling: return String(localized: "Away", comment: "Training break reason: travelling or on holiday")
        }
    }

    static func reasonHint(_ reason: TrainingBreak.Reason) -> String {
        switch reason {
        case .ill: return String(localized: "Cold, flu, a bug", comment: "Training break reason hint")
        case .injured: return String(localized: "Niggle or injury", comment: "Training break reason hint")
        case .travelling: return String(localized: "Holiday, travel", comment: "Training break reason hint")
        }
    }

    static func modeName(_ mode: TrainingBreak.Mode) -> String {
        switch mode {
        case .easeOff: return String(localized: "Ease off", comment: "Training break mode")
        case .pause: return String(localized: "Pause", comment: "Training break mode")
        }
    }

    static func modeHint(_ mode: TrainingBreak.Mode, reason: TrainingBreak.Reason) -> String {
        switch mode {
        case .easeOff:
            return String(localized: "Short easy runs", comment: "Training break mode hint")
        case .pause:
            return TrainingBreakPolicy.pauseKeepsNonRunning(for: reason)
                ? String(localized: "No running", comment: "Training break mode hint when strength and cross-training stay")
                : String(localized: "Rest completely", comment: "Training break mode hint")
        }
    }

    static func through(startDate: Date, days: Int, calendar: Calendar = .current) -> String {
        let end = calendar.date(byAdding: .day, value: days - 1, to: startDate) ?? startDate
        let format = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide)
        return String(localized: "Through \(end.formatted(format))", comment: "Training break sheet: the break's last day")
    }

    static func breakHeading(reason: TrainingBreak.Reason) -> String {
        switch reason {
        case .ill: return String(localized: "While you're unwell", comment: "Training break sheet heading")
        case .injured: return String(localized: "While you're injured", comment: "Training break sheet heading")
        case .travelling: return String(localized: "While you're away", comment: "Training break sheet heading")
        }
    }

    static func easingHeading(until end: Date) -> String {
        let date = end.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return String(localized: "Easing back in, until \(date)", comment: "Training break sheet heading for the ramp after the break")
    }

    static func change(_ edit: TrainingBreakPlanner.Edit, unit: UnitPreference) -> String {
        let from = describe(edit.fromType, distance: edit.fromDistanceMeters, unit: unit)
        let to: String
        switch edit.outcome {
        case .rest:
            to = String(localized: "Rest", comment: "Training break: a session becomes a rest day")
        case let .run(type, distance):
            to = describe(type, distance: distance, unit: unit)
        }
        return "\(from) → \(to)"
    }

    private static func describe(_ type: WorkoutType, distance: Double?, unit: UnitPreference) -> String {
        guard let distance, distance > 0 else { return type.localizedName }
        return "\(type.localizedName) \(distance.distanceString(unit: unit))"
    }

    static func headline(_ trainingBreak: TrainingBreak, phase: TrainingBreak.Phase) -> String {
        switch phase {
        case .upcoming:
            let date = trainingBreak.startDate.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
            return String(localized: "Break from \(date)", comment: "Training break card headline before it starts")
        case .onBreak:
            switch trainingBreak.mode {
            case .pause: return String(localized: "Plan paused", comment: "Training break card headline")
            case .easeOff: return String(localized: "Easing off", comment: "Training break card headline")
            }
        case .easingBack, .finished:
            return String(localized: "Easing back in", comment: "Training break card headline after the break")
        }
    }

    static func detail(_ trainingBreak: TrainingBreak, phase: TrainingBreak.Phase) -> String {
        let format = Date.FormatStyle.dateTime.weekday(.wide).day().month(.abbreviated)
        let end = trainingBreak.endDate.formatted(format)
        switch phase {
        case .upcoming, .onBreak:
            let why = breakHeading(reason: trainingBreak.reason)
            if let rampEnd = trainingBreak.rampEndDate {
                return String(
                    localized: "\(why), through \(end). Then shorter, easier runs until \(rampEnd.formatted(format)).",
                    comment: "Training break card detail: reason, last day, last easing-back day"
                )
            }
            return String(localized: "\(why), through \(end). Then straight back to your plan.", comment: "Training break card detail with no ramp")
        case .easingBack, .finished:
            let rampEnd = (trainingBreak.rampEndDate ?? trainingBreak.endDate).formatted(format)
            return String(
                localized: "Runs are shorter and easier until \(rampEnd), then your plan carries on as normal.",
                comment: "Training break card detail while easing back in"
            )
        }
    }

    static func refusal(_ refusal: TrainingBreakPlanner.Refusal) -> String {
        switch refusal {
        case .noPlan:
            return String(localized: "There's no active plan to change.", comment: "Training break refusal")
        case .easeOffNeedsPacePlan:
            return String(localized: "This plan is set by time and effort, so it can pause but not ease off.", comment: "Training break refusal")
        case .startInPast:
            return String(localized: "Pick today or a later day to start.", comment: "Training break refusal")
        case .startTooFarAhead:
            return String(localized: "A break can start up to three weeks ahead.", comment: "Training break refusal")
        case .lengthOutOfRange:
            return String(localized: "A break can be one day to four weeks. Longer than that, start a new plan when you're back.", comment: "Training break refusal")
        case .startsAfterPlanEnds:
            return String(localized: "Your plan has finished by then.", comment: "Training break refusal")
        case .raceDuringBreak(let race):
            let date = race.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
            return String(localized: "Your race is on \(date), inside these days. End the break before race day.", comment: "Training break refusal")
        case .nothingToChange:
            return String(localized: "There's nothing on your plan in those days, so there's nothing to change.", comment: "Training break refusal")
        }
    }

    static func disclaimer(reason: TrainingBreak.Reason) -> String {
        switch reason {
        case .ill:
            return String(localized: "Stride isn't a doctor. With a fever, chest symptoms or aching all over, rest rather than run, and see a doctor if you're not getting better.", comment: "Training break disclaimer when ill")
        case .injured:
            return String(localized: "Stride isn't a doctor or physio. If it hurts to walk, the pain changes how you run, or it isn't easing, get it looked at.", comment: "Training break disclaimer when injured")
        case .travelling:
            return String(localized: "Changes you can undo from the plan at any time.", comment: "Training break note when travelling")
        }
    }

    static func confirm(mode: TrainingBreak.Mode, days: Int) -> String {
        switch mode {
        case .pause:
            return days == 1
                ? String(localized: "Pause for 1 day", comment: "Training break confirm button")
                : String(localized: "Pause for \(days) days", comment: "Training break confirm button")
        case .easeOff:
            return days == 1
                ? String(localized: "Ease off for 1 day", comment: "Training break confirm button")
                : String(localized: "Ease off for \(days) days", comment: "Training break confirm button")
        }
    }
}
