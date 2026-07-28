import Foundation

// MARK: - CoachNutrition

/// Turns a session and a body mass into the amounts a runner can actually act on.
///
/// The fuelling cards used to quote guideline ranges at everyone — "thirty to sixty grams
/// of carbohydrate an hour" — which is the published advice and is also the least useful
/// form of it: the runner still has to do the arithmetic, and the range is wide enough
/// that both ends are wrong for most people. Sports-nutrition guidance is written per
/// kilogram for exactly that reason, so with a body mass the same rules give a number.
///
/// Every target below carries its own derivation string, because a computed figure with
/// no visible basis reads as a guess. When body mass is unknown the targets fall back to
/// the per-hour ranges and the derivation says what is missing — the card is still worth
/// showing, it just cannot be specific yet.
///
/// Pure and Foundation-only, so all of it is testable without a store or a view.
enum CoachNutrition {

    // MARK: Rates
    //
    // Grams per kilogram per hour, and the absorption ceilings that cap them. These are
    // the standard endurance figures; they are named here so a card quotes one constant
    // rather than restating a number inside a sentence.

    /// Carbohydrate per hour, per kg of body mass, for a session long enough to fuel
    /// during. Below the ~1.2 g/kg/h that trained guts tolerate, because this is the rate
    /// to *practise* at rather than the maximum to attempt.
    static let carbGramsPerKilogramPerHour = 0.9
    /// Absorption ceiling. Past roughly this, more carbohydrate goes through the runner
    /// rather than into them, whatever their mass.
    static let carbGramsPerHourCeiling = 90.0
    /// Floor, so a very light runner is not told to take a rate that would not sustain
    /// anyone over a long effort.
    static let carbGramsPerHourFloor = 30.0

    /// Carbohydrate per kg for the meal 2–3 hours before a quality session.
    static let preSessionCarbGramsPerKilogram = 1.5
    /// Carbohydrate per kg inside the recovery window.
    static let recoveryCarbGramsPerKilogram = 1.0
    /// Protein per kg inside the recovery window.
    static let recoveryProteinGramsPerKilogram = 0.3

    /// Fluid in ml per kg per hour in temperate conditions.
    static let fluidMillilitresPerKilogramPerHour = 6.0
    /// The same in heat — sweat rate rises with the apparent temperature, and this is the
    /// upper anchor the heat card interpolates toward.
    static let fluidMillilitresPerKilogramPerHourInHeat = 10.0
    /// Apparent temperature at which the heat anchor is reached.
    static let fluidHeatCeilingCelsius = 32.0
    /// Apparent temperature below which the temperate rate applies unchanged.
    static let fluidHeatFloorCelsius = 20.0

    // MARK: - Target

    /// One computed amount and the working behind it.
    struct Target: Equatable, Sendable {
        /// The amount, already formatted — "62 g an hour", "30–60 g an hour".
        let amount: String
        /// What it was computed from, for the card's derivation line. Nil only when there
        /// is genuinely nothing to show.
        let derivation: String?
        /// Whether `amount` was computed from this runner's mass rather than quoted as a
        /// guideline range. Drives whether the card can claim to be specific.
        let isPersonalised: Bool
    }

    // MARK: - In-session carbohydrate

    /// Carbohydrate per hour for a session long enough to fuel during it.
    static func inSessionCarbohydrate(bodyMassKg: Double?, durationSeconds: Double) -> Target {
        guard let mass = validMass(bodyMassKg) else {
            return Target(
                amount: String(
                    localized: "30–60 g an hour",
                    comment: "Guideline carbohydrate rate when body mass is unknown"
                ),
                derivation: missingMassDerivation(),
                isPersonalised: false
            )
        }

        let perHour = (mass * carbGramsPerKilogramPerHour)
            .clamped(to: carbGramsPerHourFloor...carbGramsPerHourCeiling)
        let hours = max(durationSeconds / 3_600, 0)
        // The duration and the total stand or fall together. Quoting "11 g total" for a
        // ten-minute session is arithmetic, not advice — nothing that short needs fuel
        // during it, and the rate is what the runner is being told.
        let isWorthTotalling = hours >= 0.5
        let total = perHour * hours

        return Target(
            amount: String(
                localized: "\(Int(perHour.rounded())) g an hour",
                comment: "Computed carbohydrate rate"
            ),
            derivation: derivation([
                rateText(carbGramsPerKilogramPerHour, unit: "g/kg/h"),
                massText(mass),
                isWorthTotalling ? durationText(hours) : nil,
                isWorthTotalling ? totalText(Int(total.rounded())) : nil
            ]),
            isPersonalised: true
        )
    }

    // MARK: - Pre-session carbohydrate

    /// The carbohydrate in the meal before a quality session.
    static func preSessionCarbohydrate(bodyMassKg: Double?) -> Target {
        guard let mass = validMass(bodyMassKg) else {
            return Target(
                amount: String(
                    localized: "a carb-led meal",
                    comment: "Guideline pre-session meal when body mass is unknown"
                ),
                derivation: missingMassDerivation(),
                isPersonalised: false
            )
        }

        let grams = Int((mass * preSessionCarbGramsPerKilogram).rounded())
        return Target(
            amount: String(localized: "about \(grams) g of carbohydrate", comment: "Computed pre-session carbohydrate"),
            derivation: derivation([
                rateText(preSessionCarbGramsPerKilogram, unit: "g/kg"),
                massText(mass)
            ]),
            isPersonalised: true
        )
    }

    // MARK: - Recovery

    /// Carbohydrate and protein for the window straight after a demanding run.
    static func recovery(bodyMassKg: Double?) -> Target {
        guard let mass = validMass(bodyMassKg) else {
            return Target(
                amount: String(
                    localized: "30–60 g of carbohydrate with around 20 g of protein",
                    comment: "Guideline recovery intake when body mass is unknown"
                ),
                derivation: missingMassDerivation(),
                isPersonalised: false
            )
        }

        let carbs = Int((mass * recoveryCarbGramsPerKilogram).rounded())
        let protein = Int((mass * recoveryProteinGramsPerKilogram).rounded())
        return Target(
            amount: String(
                localized: "\(carbs) g of carbohydrate with \(protein) g of protein",
                comment: "Computed recovery intake"
            ),
            derivation: derivation([
                rateText(recoveryCarbGramsPerKilogram, unit: "g/kg"),
                rateText(recoveryProteinGramsPerKilogram, unit: "g/kg protein"),
                massText(mass)
            ]),
            isPersonalised: true
        )
    }

    // MARK: - Fluid

    /// Fluid per hour, scaled between the temperate and heat anchors by how warm it felt.
    ///
    /// Linear between the two anchors rather than stepped: a card that says 6 ml/kg at
    /// 19° and 10 at 21° would be describing the threshold, not the weather.
    static func fluid(bodyMassKg: Double?, feelsLikeCelsius: Double?) -> Target {
        let rate = fluidRate(feelsLikeCelsius: feelsLikeCelsius)

        guard let mass = validMass(bodyMassKg) else {
            return Target(
                amount: String(
                    localized: "400–800 ml an hour",
                    comment: "Guideline fluid rate when body mass is unknown"
                ),
                derivation: missingMassDerivation(),
                isPersonalised: false
            )
        }

        // Rounded to the nearest 50 ml: nobody measures a bottle to 10 ml, and "637 ml"
        // claims a precision that a sweat-rate anchor does not have.
        let perHour = Int(((mass * rate) / 50).rounded() * 50)
        return Target(
            amount: String(localized: "\(perHour) ml an hour", comment: "Computed fluid rate"),
            derivation: derivation([
                rateText(rate, unit: "ml/kg/h"),
                massText(mass),
                feelsLikeCelsius.map { feelsLikeText($0) }
            ]),
            isPersonalised: true
        )
    }

    /// The ml/kg/h anchor for the conditions, interpolated between temperate and hot.
    static func fluidRate(feelsLikeCelsius: Double?) -> Double {
        guard let feelsLike = feelsLikeCelsius, feelsLike > fluidHeatFloorCelsius else {
            return fluidMillilitresPerKilogramPerHour
        }
        let span = fluidHeatCeilingCelsius - fluidHeatFloorCelsius
        let fraction = ((feelsLike - fluidHeatFloorCelsius) / span).clamped(to: 0...1)
        let rise = fluidMillilitresPerKilogramPerHourInHeat - fluidMillilitresPerKilogramPerHour
        return fluidMillilitresPerKilogramPerHour + rise * fraction
    }

    // MARK: - Helpers

    /// A mass only counts if it is physically plausible. HealthKit will hand back whatever
    /// was written to it, including a value in the wrong unit or a stale entry from a
    /// scale that reported zero.
    static func validMass(_ kilograms: Double?) -> Double? {
        guard let kilograms, kilograms.isFinite, (25.0...250.0).contains(kilograms) else { return nil }
        return kilograms
    }

    /// Joins the parts of a derivation line with the separator the cards use.
    static func derivation(_ parts: [String?]) -> String? {
        let kept = parts.compactMap { $0 }
        return kept.isEmpty ? nil : kept.joined(separator: " · ")
    }

    private static func rateText(_ value: Double, unit: String) -> String {
        // One decimal, trimmed: "0.9 g/kg/h", "6 ml/kg/h".
        let rounded = (value * 10).rounded() / 10
        let number = rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
        return "\(number) \(unit)"
    }

    private static func massText(_ mass: Double) -> String {
        String(format: "%.0f kg", mass)
    }

    private static func durationText(_ hours: Double) -> String {
        String(format: "~%.1f h", hours)
    }

    private static func totalText(_ grams: Int) -> String {
        String(localized: "\(grams) g total", comment: "Total computed carbohydrate in a derivation line")
    }

    private static func feelsLikeText(_ celsius: Double) -> String {
        String(format: "felt %.0f°C", celsius)
    }

    /// Says why a figure is a range rather than a number. Shown instead of hiding the
    /// card: the guideline advice is still correct, it just is not about this runner yet.
    private static func missingMassDerivation() -> String {
        String(
            localized: "Guideline range · add your weight for a figure",
            comment: "Derivation line shown when body mass is unknown"
        )
    }
}
