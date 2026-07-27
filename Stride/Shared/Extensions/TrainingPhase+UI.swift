import SwiftUI

extension TrainingPhase {

    /// The colour a phase draws in, defined once so the onboarding summary's chart and the
    /// Plan tab's phase bar cannot disagree about the same four names.
    ///
    /// A single-hue ramp on `brand`, not the pace-zone palette. The zones are a *data*
    /// scale — they encode effort on charts and in the run HUD — and borrowing them as a
    /// category scale here made Peak `zoneInterval`, i.e. red: the plan-summary chart told a
    /// runner their hardest training block was an error state, on the one screen whose job
    /// is to make the plan look achievable (S18).
    ///
    /// Intensity rises Base → Build → Peak, which is what those phases mean, so the ramp
    /// carries the ordering the four unrelated hues never did. Taper is `success` rather
    /// than a fourth step, because it is the only phase that says *ease off, you're ready*
    /// instead of another step up — and `success` is already the app's word for that.
    var tint: Color {
        switch self {
        case .base:  return Color.brand.mix(with: .white, by: 0.55)
        case .build: return Color.brand.mix(with: .white, by: 0.25)
        case .peak:  return .brand
        case .taper: return .success
        }
    }
}
