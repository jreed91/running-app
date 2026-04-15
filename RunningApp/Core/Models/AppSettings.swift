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

    var iCloudSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(iCloudSyncEnabled, forKey: Self.iCloudSyncKey)
        }
    }

    private static let unitPreferenceKey = "unitPreference"
    private static let orsAPIKeyKey      = "orsAPIKey"
    // Internal so AppContainer can read the same key before AppSettings is created.
    static let iCloudSyncKey = "iCloudSyncEnabled"

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.unitPreferenceKey) ?? ""
        self.unitPreference = UnitPreference(rawValue: raw) ?? .metric
        self.orsAPIKey = UserDefaults.standard.string(forKey: Self.orsAPIKeyKey) ?? ""

        // Default to true (sync on) when the key has never been set.
        if UserDefaults.standard.object(forKey: Self.iCloudSyncKey) != nil {
            self.iCloudSyncEnabled = UserDefaults.standard.bool(forKey: Self.iCloudSyncKey)
        } else {
            self.iCloudSyncEnabled = true
        }
    }
}
