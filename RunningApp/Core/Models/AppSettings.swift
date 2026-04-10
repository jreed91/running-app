import Foundation
import Observation

@Observable
@MainActor
final class AppSettings {

    var unitPreference: UnitPreference {
        didSet {
            UserDefaults.standard.set(unitPreference.rawValue, forKey: Self.unitPreferenceKey)
        }
    }

    private static let unitPreferenceKey = "unitPreference"

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.unitPreferenceKey) ?? ""
        self.unitPreference = UnitPreference(rawValue: raw) ?? .metric
    }
}
