import Foundation
import Testing
@testable import Stride

/// Covers `CoachNutrition`, which turns a body mass into the amounts the cards quote.
///
/// The fallback path matters as much as the computed one: most runners will have a
/// weight in Health, but the ones who don't must still get correct guideline advice
/// rather than a blank card or a figure derived from nothing.
struct CoachNutritionTests {

    // MARK: - Plausibility

    @Test("Implausible masses are rejected so a bad sample cannot drive an amount")
    func massPlausibility() {
        #expect(CoachNutrition.validMass(72) == 72)
        #expect(CoachNutrition.validMass(nil) == nil)
        #expect(CoachNutrition.validMass(0) == nil)
        #expect(CoachNutrition.validMass(-5) == nil)
        // A weight recorded in pounds and read as kilograms.
        #expect(CoachNutrition.validMass(340) == nil)
        // A scale that reported nothing useful.
        #expect(CoachNutrition.validMass(2) == nil)
        #expect(CoachNutrition.validMass(.nan) == nil)
        #expect(CoachNutrition.validMass(.infinity) == nil)
    }

    // MARK: - In-session carbohydrate

    @Test("A known mass gives a rate, and the derivation shows the working")
    func inSessionCarbsArePersonalised() {
        // 72 kg at 0.9 g/kg/h is 64.8, which rounds to 65.
        let target = CoachNutrition.inSessionCarbohydrate(bodyMassKg: 72, durationSeconds: 2 * 3_600)
        #expect(target.isPersonalised)
        #expect(target.amount == "65 g an hour")
        #expect(target.derivation?.contains("0.9 g/kg/h") == true)
        #expect(target.derivation?.contains("72 kg") == true)
        // Two hours at 65 an hour is about 130 g in total.
        #expect(target.derivation?.contains("130 g total") == true)
    }

    @Test("The rate is capped at what a gut can absorb and floored below it")
    func inSessionCarbsAreBounded() {
        // 120 kg at 0.9 would be 108 g an hour, past the absorption ceiling.
        let heavy = CoachNutrition.inSessionCarbohydrate(bodyMassKg: 120, durationSeconds: 3_600)
        #expect(heavy.amount == "90 g an hour")

        // 30 kg at 0.9 would be 27, below what sustains anyone over a long effort.
        let light = CoachNutrition.inSessionCarbohydrate(bodyMassKg: 30, durationSeconds: 3_600)
        #expect(light.amount == "30 g an hour")
    }

    @Test("Without a mass the advice is the guideline range, and says so")
    func inSessionCarbsFallBack() {
        let target = CoachNutrition.inSessionCarbohydrate(bodyMassKg: nil, durationSeconds: 3_600)
        #expect(!target.isPersonalised)
        #expect(target.amount == "30–60 g an hour")
        #expect(target.derivation?.isEmpty == false)
        // The card is still worth showing; the derivation says what would sharpen it.
        #expect(target.derivation?.contains("weight") == true)
    }

    @Test("A session too short to fuel during leaves the total out of the derivation")
    func shortSessionOmitsTheTotal() {
        let target = CoachNutrition.inSessionCarbohydrate(bodyMassKg: 72, durationSeconds: 600)
        #expect(target.derivation?.contains("total") == false)
    }

    // MARK: - Pre-session and recovery

    @Test("Pre-session carbohydrate scales with mass")
    func preSessionCarbs() {
        let target = CoachNutrition.preSessionCarbohydrate(bodyMassKg: 60)
        // 60 kg at 1.5 g/kg is 90 g.
        #expect(target.amount.contains("90"))
        #expect(target.isPersonalised)

        let fallback = CoachNutrition.preSessionCarbohydrate(bodyMassKg: nil)
        #expect(!fallback.isPersonalised)
    }

    @Test("Recovery intake gives both carbohydrate and protein")
    func recoveryIntake() {
        // 70 kg: 70 g of carbohydrate at 1.0, 21 g of protein at 0.3.
        let target = CoachNutrition.recovery(bodyMassKg: 70)
        #expect(target.amount.contains("70 g"))
        #expect(target.amount.contains("21 g"))
        #expect(target.isPersonalised)

        let fallback = CoachNutrition.recovery(bodyMassKg: nil)
        #expect(!fallback.isPersonalised)
        #expect(fallback.amount.contains("protein"))
    }

    // MARK: - Fluid

    @Test("Fluid rises with the apparent temperature between the two anchors")
    func fluidScalesWithHeat() {
        let temperate = CoachNutrition.fluidRate(feelsLikeCelsius: 12)
        let warm = CoachNutrition.fluidRate(feelsLikeCelsius: 26)
        let hot = CoachNutrition.fluidRate(feelsLikeCelsius: 32)

        #expect(temperate == CoachNutrition.fluidMillilitresPerKilogramPerHour)
        #expect(warm > temperate)
        #expect(warm < hot)
        #expect(hot == CoachNutrition.fluidMillilitresPerKilogramPerHourInHeat)
    }

    @Test("Beyond the heat anchor the rate stops climbing")
    func fluidSaturates() {
        #expect(
            CoachNutrition.fluidRate(feelsLikeCelsius: 45)
                == CoachNutrition.fluidMillilitresPerKilogramPerHourInHeat
        )
    }

    @Test("Unknown conditions are treated as temperate rather than as hot")
    func fluidWithoutWeather() {
        #expect(
            CoachNutrition.fluidRate(feelsLikeCelsius: nil)
                == CoachNutrition.fluidMillilitresPerKilogramPerHour
        )
    }

    @Test("Fluid amounts round to something a bottle can measure")
    func fluidRoundsToFifty() {
        // 72 kg at 6 ml/kg/h is 432, which is not a number anyone can pour.
        let target = CoachNutrition.fluid(bodyMassKg: 72, feelsLikeCelsius: 12)
        #expect(target.amount == "450 ml an hour")
        #expect(target.isPersonalised)
    }

    @Test("Without a mass the fluid advice is a range too")
    func fluidFallsBack() {
        let target = CoachNutrition.fluid(bodyMassKg: nil, feelsLikeCelsius: 30)
        #expect(!target.isPersonalised)
        #expect(target.amount == "400–800 ml an hour")
    }

    // MARK: - Derivation assembly

    @Test("Empty derivation parts drop out rather than leaving dangling separators")
    func derivationSkipsNils() {
        #expect(CoachNutrition.derivation([nil, "72 kg", nil]) == "72 kg")
        #expect(CoachNutrition.derivation(["a", "b"]) == "a · b")
        #expect(CoachNutrition.derivation([nil, nil]) == nil)
        #expect(CoachNutrition.derivation([]) == nil)
    }
}
