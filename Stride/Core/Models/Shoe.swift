import Foundation
import SwiftData

// MARK: - Shoe

/// A pair of running shoes, so a run can say what it was run in and a pair can say how
/// far it has gone.
///
/// Runs point at a shoe by `RunWorkout.shoeID` rather than through a SwiftData
/// relationship, for the reason `RunWorkout.linkedScheduledWorkoutID` exists: CloudKit
/// syncs a scalar UUID more reliably than a relationship reference when records arrive
/// out of order, and a shoe deleted on one device then leaves its runs pointing at
/// nothing rather than at a half-restored object. Mileage is therefore always derived —
/// summed from the runs that name this shoe, plus `startingDistanceMeters` — never
/// stored, so it cannot drift from the history it describes.
///
/// Every stored property has a default, as CloudKit requires. Adding this type is a
/// schema change: see `docs/CLOUDKIT_VALIDATION.md` before it ships.
@Model
final class Shoe {
    #Index<Shoe>([\.id])

    var id: UUID = UUID()
    /// What the runner calls the pair, e.g. "Pegasus 41" or "Race shoes".
    var name: String = ""
    var createdAt: Date = Date()
    /// When the pair went into use. The default shoe is only put on runs from this day
    /// on, so a retroactive HealthKit import cannot credit last year's runs to this
    /// year's shoes.
    var startDate: Date = Date()
    /// Distance the pair had already covered before it was added to Stride, in metres.
    var startingDistanceMeters: Double = 0
    /// The distance at which the runner wants to hear the pair is worn out, in metres.
    var replacementDistanceMeters: Double = 800_000
    /// Set while this is the pair new runs are put on. A date rather than a flag so two
    /// devices that each chose a default before syncing still agree on one: the most
    /// recent choice wins (`ShoeWearPolicy.defaultShoe`).
    var defaultSetAt: Date?
    /// Set once the pair is out of rotation. Retired shoes keep their runs and their
    /// mileage but are never offered for a new run and never nudge.
    var retiredAt: Date?

    var isDefault: Bool { defaultSetAt != nil }
    var isRetired: Bool { retiredAt != nil }

    init(
        name: String,
        startDate: Date = Date(),
        startingDistanceMeters: Double = 0,
        replacementDistanceMeters: Double
    ) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.startDate = startDate
        self.startingDistanceMeters = startingDistanceMeters
        self.replacementDistanceMeters = replacementDistanceMeters
    }
}
