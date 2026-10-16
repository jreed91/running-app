import Foundation
import SwiftData

// MARK: - BodyMassSync

/// Keeps ``UserProfile/bodyMassKilograms`` in step with Apple Health.
///
/// The coach's fuelling amounts are all per kilogram, so this one number is the
/// difference between "thirty to sixty grams an hour" and "62 g an hour". Most runners
/// already have it in Health — from a scale, a watch, or the Health app itself — so
/// asking them to type it again would be asking for data the phone already holds.
///
/// **Health wins when it has a sample.** The Settings field is the path for runners with
/// nothing in Health, and it takes effect immediately, but a later Health sample will
/// replace it. That is the right way round — a smart scale is a better source than a
/// number typed once a year — and it is why the Settings row says where the value came
/// from rather than presenting it as a plain preference.
enum BodyMassSync {

    /// How much the Health value has to differ before it is worth a write.
    ///
    /// SwiftData writes propagate to CloudKit, and body mass arrives from a scale with
    /// a few grams of noise on it. Without a floor, every launch would push a record for
    /// a number that has not meaningfully changed.
    static let significantChangeKilograms = 0.1

    /// Whether `healthKit`'s reading should replace `stored`.
    ///
    /// Pure, so the "don't write noise" rule and the plausibility gate are testable
    /// without a store or a HealthKit permission.
    static func shouldAdopt(healthKit: Double?, stored: Double?) -> Bool {
        guard let candidate = CoachNutrition.validMass(healthKit) else { return false }
        guard let stored else { return true }
        // The tolerance absorbs binary rounding: 72.1 − 72.0 is a hair under 0.1, and a
        // change exactly at the floor counts.
        return abs(candidate - stored) >= significantChangeKilograms - 1e-9
    }

    /// Reads the latest body mass from Health and stores it on the profile if it is worth
    /// storing. Silent on every failure path — a missing weight costs one line of one
    /// card, and is never worth an alert.
    @MainActor
    static func refresh(
        profile: UserProfile,
        repository: HealthKitRepositoryProtocol,
        context: ModelContext
    ) async {
        let healthKit = await repository.fetchLatestBodyMassKilograms()
        guard shouldAdopt(healthKit: healthKit, stored: profile.bodyMassKilograms) else { return }

        profile.bodyMassKilograms = healthKit
        profile.updatedAt = Date()
        context.saveOrLog("body mass from Health")
    }
}
