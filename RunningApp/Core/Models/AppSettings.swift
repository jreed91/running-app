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

    var orsAPIKey: String {
        didSet {
            UserDefaults.standard.set(orsAPIKey, forKey: Self.orsAPIKeyKey)
        }
    }

    private static let unitPreferenceKey = "unitPreference"
    private static let orsAPIKeyKey      = "orsAPIKey"

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.unitPreferenceKey) ?? ""
        self.unitPreference = UnitPreference(rawValue: raw) ?? .metric
        self.orsAPIKey = UserDefaults.standard.string(forKey: Self.orsAPIKeyKey) ?? ""
    }
}
