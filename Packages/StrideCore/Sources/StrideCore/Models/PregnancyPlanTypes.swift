import Foundation

// MARK: - GestationalAge

/// Where a pregnancy is, in the obstetric convention every source behind this feature uses:
/// completed weeks and days since the last menstrual period, with the estimated due date at
/// 40+0. Written the way a maternity note writes it — "24+3".
///
/// This is the plan's clock. A pregnancy plan has no goal race and no race week, so the
/// thing every weekly prescription is indexed by is gestational age, not week number.
///
/// See `docs/PREGNANCY_RUNNING_EVIDENCE.md`.
struct GestationalAge: Hashable, Sendable, Comparable {

    /// Completed weeks since LMP.
    let weeks: Int
    /// Completed days beyond `weeks`, always 0…6.
    let days: Int

    /// Days from LMP to the estimated due date — the 40-week convention.
    static let termDays = 280

    init(weeks: Int, days: Int) {
        self.init(totalDays: weeks * 7 + days)
    }

    /// Clamped at zero: a start date more than 40 weeks before the due date is a data-entry
    /// error, not a negative pregnancy, and the callers downstream index tables by week.
    init(totalDays: Int) {
        let clamped = max(0, totalDays)
        self.weeks = clamped / 7
        self.days = clamped % 7
    }

    var totalDays: Int { weeks * 7 + days }

    /// Gestational age on `date` for a pregnancy with estimated due date `dueDate`.
    static func on(_ date: Date, dueDate: Date, calendar: Calendar = .current) -> GestationalAge {
        let daysUntilDue = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: dueDate)
        ).day ?? 0
        return GestationalAge(totalDays: termDays - daysUntilDue)
    }

    var trimester: PregnancyTrimester { PregnancyTrimester(gestationalWeek: weeks) }

    /// The maternity-note form, e.g. "24+3". Digits and a `+` in every language, so this is
    /// deliberately not localized.
    var noteForm: String { "\(weeks)+\(days)" }

    static func < (lhs: GestationalAge, rhs: GestationalAge) -> Bool {
        lhs.totalDays < rhs.totalDays
    }
}

// MARK: - PregnancyTrimester

enum PregnancyTrimester: String, Codable, CaseIterable, Sendable {
    case first
    case second
    case third

    /// Standard obstetric boundaries: T1 through 13+6, T2 through 27+6, T3 from 28+0.
    init(gestationalWeek week: Int) {
        switch week {
        case ..<14:   self = .first
        case 14..<28: self = .second
        default:      self = .third
        }
    }

    var gestationalWeeks: ClosedRange<Int> {
        switch self {
        case .first:  return 0...13
        case .second: return 14...27
        case .third:  return 28...42
        }
    }

    /// The canonical English form — used by AI prompts and logs, which compare and persist
    /// it, so it must not move with the device language (D8).
    var displayName: String {
        switch self {
        case .first:  return "First Trimester"
        case .second: return "Second Trimester"
        case .third:  return "Third Trimester"
        }
    }

    var localizedName: String {
        switch self {
        case .first:  return String(localized: "First Trimester", comment: "Stage of pregnancy")
        case .second: return String(localized: "Second Trimester", comment: "Stage of pregnancy")
        case .third:  return String(localized: "Third Trimester", comment: "Stage of pregnancy")
        }
    }
}

// MARK: - PregnancyEffort

/// How a pregnancy session is prescribed: by effort, never by pace.
///
/// Pregnancy shifts plasma volume, resting and submaximal heart rate, and body mass, so both
/// a pace band and an absolute bpm ceiling misprescribe as the weeks go on. The Canadian
/// guideline's own method is the **talk test**, backed by a Borg 6–20 rating; that is what
/// this type carries, and it is why every generated pregnancy workout leaves
/// `targetPaceLowerBound` / `targetPaceUpperBound` nil.
enum PregnancyEffort: String, Codable, CaseIterable, Sendable {
    case walk
    case easy
    /// The guideline's "moderate": can talk but not sing. Borg 12–14.
    case moderate

    /// Rating of perceived exertion on the Borg 6–20 scale.
    var borgRange: ClosedRange<Int> {
        switch self {
        case .walk:     return 9...11
        case .easy:     return 11...13
        case .moderate: return 12...14
        }
    }

    var displayName: String {
        switch self {
        case .walk:     return "Walk"
        case .easy:     return "Easy"
        case .moderate: return "Moderate"
        }
    }

    var localizedName: String {
        switch self {
        case .walk:     return String(localized: "Walk", comment: "Pregnancy run effort")
        case .easy:     return String(localized: "Easy", comment: "Pregnancy run effort")
        case .moderate: return String(localized: "Moderate", comment: "Pregnancy run effort")
        }
    }

    /// The talk test, in the words the guideline uses for it.
    var talkTest: String {
        switch self {
        case .walk:
            return String(
                localized: "Easy enough to sing.",
                comment: "Talk-test description of a walking effort in pregnancy"
            )
        case .easy:
            return String(
                localized: "Conversational — full sentences, no gaps for breath.",
                comment: "Talk-test description of an easy effort in pregnancy"
            )
        case .moderate:
            return String(
                localized: "You can talk but not sing. That is the whole ceiling — never race it.",
                comment: "Talk-test description of a moderate effort in pregnancy"
            )
        }
    }

    /// Effort plus its Borg range, for a workout note.
    var prescription: String {
        String(
            localized: "\(localizedName) effort (RPE \(borgRange.lowerBound)–\(borgRange.upperBound) of 20). \(talkTest)",
            comment: "Effort prescription on a pregnancy workout: effort name, Borg range, talk test"
        )
    }
}

// MARK: - PregnancyRedFlag

/// Reasons to stop exercising immediately and contact a maternity provider.
///
/// The shared list from ACOG Committee Opinion 804 and the 2019 Canadian guideline. It is
/// deliberately reproduced in full and never summarised for a smaller screen: a shortened
/// red-flag list is worse than none, because it reads as complete.
enum PregnancyRedFlag: String, CaseIterable, Sendable, Identifiable {
    case vaginalBleeding
    case fluidLoss
    case contractions
    case breathlessness
    case chestPain
    case dizziness
    case headache
    case muscleWeakness
    case calfPainOrSwelling
    case reducedFetalMovement

    var id: String { rawValue }

    var localizedText: String {
        switch self {
        case .vaginalBleeding:
            return String(localized: "Vaginal bleeding", comment: "Pregnancy exercise red flag")
        case .fluidLoss:
            return String(localized: "Persistent loss of fluid from the vagina", comment: "Pregnancy exercise red flag")
        case .contractions:
            return String(localized: "Regular, painful uterine contractions", comment: "Pregnancy exercise red flag")
        case .breathlessness:
            return String(localized: "Excessive shortness of breath that does not settle with rest", comment: "Pregnancy exercise red flag")
        case .chestPain:
            return String(localized: "Severe chest pain", comment: "Pregnancy exercise red flag")
        case .dizziness:
            return String(localized: "Dizziness or faintness that does not resolve with rest", comment: "Pregnancy exercise red flag")
        case .headache:
            return String(localized: "Headache that does not resolve with rest", comment: "Pregnancy exercise red flag")
        case .muscleWeakness:
            return String(localized: "Muscle weakness affecting your balance", comment: "Pregnancy exercise red flag")
        case .calfPainOrSwelling:
            return String(localized: "Calf pain or swelling", comment: "Pregnancy exercise red flag")
        case .reducedFetalMovement:
            return String(localized: "Decreased fetal movement", comment: "Pregnancy exercise red flag")
        }
    }
}

// MARK: - PregnancyContraindication

/// The screening list a runner confirms before Stride will build a pregnancy plan.
///
/// `absolute` means the guidelines say not to undertake more strenuous physical activity
/// than the usual activities of daily living. `relative` means the decision belongs with the
/// runner's own maternity provider, not with this app. Either way Stride's job is the same:
/// stop, and say who to ask.
struct PregnancyContraindication: Hashable, Sendable, Identifiable {

    enum Severity: String, Hashable, Sendable {
        case absolute
        case relative
    }

    let id: String
    let severity: Severity
    let localizedText: String

    private static func entry(_ id: String, _ severity: Severity, _ text: String) -> PregnancyContraindication {
        PregnancyContraindication(id: id, severity: severity, localizedText: text)
    }

    /// ACOG Committee Opinion 804; 2019 Canadian guideline (triplets or higher).
    static let absolute: [PregnancyContraindication] = [
        entry("heart_disease", .absolute, String(localized: "Haemodynamically significant heart disease", comment: "Absolute contraindication to exercise in pregnancy")),
        entry("restrictive_lung", .absolute, String(localized: "Restrictive lung disease", comment: "Absolute contraindication to exercise in pregnancy")),
        entry("cerclage", .absolute, String(localized: "Incompetent cervix, or a cerclage in place", comment: "Absolute contraindication to exercise in pregnancy")),
        entry("multiple_gestation", .absolute, String(localized: "Multiple gestation at risk of premature labour (triplets or more)", comment: "Absolute contraindication to exercise in pregnancy")),
        entry("bleeding", .absolute, String(localized: "Persistent second- or third-trimester bleeding", comment: "Absolute contraindication to exercise in pregnancy")),
        entry("placenta_praevia", .absolute, String(localized: "Placenta praevia after 26 weeks", comment: "Absolute contraindication to exercise in pregnancy")),
        entry("premature_labour", .absolute, String(localized: "Premature labour during this pregnancy", comment: "Absolute contraindication to exercise in pregnancy")),
        entry("ruptured_membranes", .absolute, String(localized: "Ruptured membranes", comment: "Absolute contraindication to exercise in pregnancy")),
        entry("preeclampsia", .absolute, String(localized: "Preeclampsia or pregnancy-induced hypertension", comment: "Absolute contraindication to exercise in pregnancy")),
        entry("severe_anaemia", .absolute, String(localized: "Severe anaemia", comment: "Absolute contraindication to exercise in pregnancy"))
    ]

    /// ACOG Committee Opinion 804; 2019 Canadian guideline (twin pregnancy after 28 weeks).
    static let relative: [PregnancyContraindication] = [
        entry("anaemia", .relative, String(localized: "Anaemia", comment: "Relative contraindication to exercise in pregnancy")),
        entry("arrhythmia", .relative, String(localized: "Unevaluated maternal cardiac arrhythmia", comment: "Relative contraindication to exercise in pregnancy")),
        entry("chronic_bronchitis", .relative, String(localized: "Chronic bronchitis", comment: "Relative contraindication to exercise in pregnancy")),
        entry("type1_diabetes", .relative, String(localized: "Poorly controlled type 1 diabetes", comment: "Relative contraindication to exercise in pregnancy")),
        entry("extreme_obesity", .relative, String(localized: "Extreme morbid obesity", comment: "Relative contraindication to exercise in pregnancy")),
        entry("extreme_underweight", .relative, String(localized: "Extreme underweight (BMI under 12)", comment: "Relative contraindication to exercise in pregnancy")),
        entry("sedentary_history", .relative, String(localized: "A history of an extremely sedentary lifestyle", comment: "Relative contraindication to exercise in pregnancy")),
        entry("iugr", .relative, String(localized: "Intrauterine growth restriction in this pregnancy", comment: "Relative contraindication to exercise in pregnancy")),
        entry("hypertension", .relative, String(localized: "Poorly controlled hypertension", comment: "Relative contraindication to exercise in pregnancy")),
        entry("orthopaedic", .relative, String(localized: "Orthopaedic limitations", comment: "Relative contraindication to exercise in pregnancy")),
        entry("seizure_disorder", .relative, String(localized: "Poorly controlled seizure disorder", comment: "Relative contraindication to exercise in pregnancy")),
        entry("hyperthyroidism", .relative, String(localized: "Poorly controlled hyperthyroidism", comment: "Relative contraindication to exercise in pregnancy")),
        entry("heavy_smoker", .relative, String(localized: "Heavy smoker", comment: "Relative contraindication to exercise in pregnancy")),
        entry("twins_after_28", .relative, String(localized: "Twin pregnancy after 28 weeks", comment: "Relative contraindication to exercise in pregnancy"))
    ]

    static var all: [PregnancyContraindication] { absolute + relative }
}
