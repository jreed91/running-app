import Testing
import Foundation
@testable import Stride

// MARK: - UserProfile max-HR helpers

struct UserProfileHeartRateTests {

    private func makeProfile() -> UserProfile {
        UserProfile(name: "Test", goalRace: .fiveK, goalFinishTime: 1_500, weeklyRunDays: 3, fitnessLevel: .intermediate)
    }

    @Test("Tanaka estimate is 208 − 0.7 × age")
    func tanaka() {
        #expect(UserProfile.estimatedMaxHeartRate(forAge: 30) == 187)  // 208 − 21
        #expect(UserProfile.estimatedMaxHeartRate(forAge: 40) == 180)  // 208 − 28
    }

    @Test("Effective max HR: explicit value wins over age estimate")
    func explicitWins() {
        let p = makeProfile()
        p.age = 40
        p.maxHeartRateBPM = 195
        #expect(p.effectiveMaxHeartRate == 195)
    }

    @Test("Effective max HR falls back to the age estimate, then the assumed-age estimate Settings shows")
    func fallbacks() {
        let p = makeProfile()
        #expect(p.effectiveMaxHeartRate == 187)       // nothing set: assumed age 30
        p.age = 40
        #expect(p.effectiveMaxHeartRate == 180)        // age estimate
    }
}
