import Foundation
import Testing
@testable import Stride

/// Covers `BodyMassSync.shouldAdopt`, which decides whether a Health reading is worth
/// writing to the profile.
///
/// The rule has two jobs and both are easy to get wrong: never store a value the coach
/// would reject anyway, and never write a record for a number that has not meaningfully
/// moved — every write here propagates to CloudKit.
struct BodyMassSyncTests {

    @Test("A first plausible reading is always adopted")
    func firstReadingIsAdopted() {
        #expect(BodyMassSync.shouldAdopt(healthKit: 72, stored: nil))
    }

    @Test("A missing or implausible reading is never adopted")
    func implausibleReadingsAreRejected() {
        #expect(!BodyMassSync.shouldAdopt(healthKit: nil, stored: nil))
        #expect(!BodyMassSync.shouldAdopt(healthKit: nil, stored: 72))
        #expect(!BodyMassSync.shouldAdopt(healthKit: 0, stored: 72))
        // A weight recorded in pounds and read as kilograms.
        #expect(!BodyMassSync.shouldAdopt(healthKit: 340, stored: 72))
        #expect(!BodyMassSync.shouldAdopt(healthKit: .nan, stored: 72))
    }

    @Test("Scale noise does not earn a write")
    func noiseIsIgnored() {
        #expect(!BodyMassSync.shouldAdopt(healthKit: 72.0, stored: 72.0))
        #expect(!BodyMassSync.shouldAdopt(healthKit: 72.04, stored: 72.0))
        #expect(!BodyMassSync.shouldAdopt(healthKit: 71.96, stored: 72.0))
    }

    @Test("A real change is adopted, in either direction")
    func realChangesAreAdopted() {
        #expect(BodyMassSync.shouldAdopt(healthKit: 72.5, stored: 72.0))
        #expect(BodyMassSync.shouldAdopt(healthKit: 71.0, stored: 72.0))
        // Exactly at the floor counts as significant.
        #expect(
            BodyMassSync.shouldAdopt(
                healthKit: 72.0 + BodyMassSync.significantChangeKilograms,
                stored: 72.0
            )
        )
    }

    @Test("Health replaces a value typed in Settings, which is the documented behaviour")
    func healthOverridesATypedValue() {
        // The Settings footnote says as much: a smart scale is a better source than a
        // number typed once a year, and the field exists for runners with neither.
        #expect(BodyMassSync.shouldAdopt(healthKit: 68, stored: 75))
    }
}
