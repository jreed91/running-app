import Foundation
import SwiftData

// MARK: - ShoeWearPolicy

/// Every judgement shoe tracking makes: how far a pair goes, when to say it is nearly
/// done, and which pair a new run is put on. Pure, so all of it is testable without a
/// store.
///
/// **Convention, not evidence.** The 500 mi / 800 km default is the figure running
/// shops and shoe makers quote, and there is no good study behind it — wear depends on
/// the shoe, the runner's weight and the surface far more than on any one number. That
/// is why it is only a default: every pair carries its own `replacementDistanceMeters`,
/// and the editor says the number is the runner's to change. Do not dress this up with
/// citations it does not have; the same rule as `MusicEnergyPolicy`.
enum ShoeWearPolicy {

    /// The distance a new pair is expected to last, rounded to a figure that reads
    /// cleanly in the runner's own unit rather than converted from the other one.
    static func defaultReplacementMeters(for unit: UnitPreference) -> Double {
        switch unit {
        case .metric:   return 800_000
        case .imperial: return 500 * 1_609.344
        }
    }

    /// The share of the replacement distance after which a pair is "nearly done". The
    /// last tenth is roughly a month of running for most people who log 500 miles a year,
    /// which is long enough to order a pair and break it in.
    static let replaceSoonFraction = 0.9

    enum Wear: Int, Comparable, Sendable {
        /// Plenty of distance left.
        case fresh
        /// Inside the last tenth of the replacement distance.
        case replaceSoon
        /// At or past the replacement distance.
        case worn

        static func < (lhs: Wear, rhs: Wear) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// How worn a pair is. A pair with no sensible limit set never nudges.
    static func wear(totalMeters: Double, replacementMeters: Double) -> Wear {
        guard replacementMeters > 0 else { return .fresh }
        if totalMeters >= replacementMeters { return .worn }
        if totalMeters >= replacementMeters * replaceSoonFraction { return .replaceSoon }
        return .fresh
    }

    /// Distance logged in each shoe, keyed by shoe ID, from the runs that name one.
    /// Does not include a pair's `startingDistanceMeters`; `totalMeters` adds that.
    static func loggedMeters(_ runs: [RunWorkout]) -> [UUID: Double] {
        var totals: [UUID: Double] = [:]
        for run in runs {
            guard let shoeID = run.shoeID else { continue }
            totals[shoeID, default: 0] += run.distanceMeters
        }
        return totals
    }

    /// Everything a pair has covered: what it had on it when it was added, plus every
    /// run that names it.
    static func totalMeters(for shoe: Shoe, logged: [UUID: Double]) -> Double {
        shoe.startingDistanceMeters + (logged[shoe.id] ?? 0)
    }

    /// The pair a run dated `date` should be put on, if any.
    ///
    /// Only a pair that is the default, still in rotation, and already in use on that
    /// day qualifies — the last condition is what keeps a retroactive import from
    /// putting new shoes on old runs. When sync has left two defaults, the most recent
    /// choice wins.
    static func defaultShoe(
        among shoes: [Shoe],
        forRunOn date: Date,
        calendar: Calendar = .current
    ) -> Shoe? {
        let runDay = calendar.startOfDay(for: date)
        return shoes
            .filter { shoe in
                shoe.isDefault
                    && !shoe.isRetired
                    && calendar.startOfDay(for: shoe.startDate) <= runDay
            }
            .max { ($0.defaultSetAt ?? .distantPast) < ($1.defaultSetAt ?? .distantPast) }
    }

    /// The pairs worth a nudge on Home: in rotation, nearly done or past it, and not
    /// already dismissed at this level of wear. Most worn first.
    ///
    /// Dismissal is keyed by wear level, the way a heat advisory is keyed by tier: saying
    /// "not yet" at nearly done does not silence the pair once it is actually worn out.
    static func shoesToNudge(
        _ shoes: [Shoe],
        logged: [UUID: Double],
        dismissed: [UUID: Wear]
    ) -> [(shoe: Shoe, totalMeters: Double, wear: Wear)] {
        shoes
            .filter { !$0.isRetired }
            .compactMap { shoe -> (shoe: Shoe, totalMeters: Double, wear: Wear)? in
                let total = totalMeters(for: shoe, logged: logged)
                let level = wear(totalMeters: total, replacementMeters: shoe.replacementDistanceMeters)
                guard level > .fresh else { return nil }
                if let settled = dismissed[shoe.id], settled >= level { return nil }
                return (shoe, total, level)
            }
            .sorted { lhs, rhs in
                if lhs.wear != rhs.wear { return lhs.wear > rhs.wear }
                return lhs.totalMeters / lhs.shoe.replacementDistanceMeters
                    > rhs.totalMeters / rhs.shoe.replacementDistanceMeters
            }
    }
}

// MARK: - Mileage fetch

extension RunWorkout {

    /// The runs that name a shoe, fetching only the two columns mileage is summed from.
    ///
    /// Once a runner tracks shoes this is most of their history, and a plain fetch would
    /// pull every route and heart-rate blob into memory on each Home render just to add
    /// up distances — the unbounded-fetch cost D6 took off the dashboard.
    static var shoeMileageDescriptor: FetchDescriptor<RunWorkout> {
        var descriptor = FetchDescriptor<RunWorkout>(predicate: #Predicate { $0.shoeID != nil })
        descriptor.propertiesToFetch = [\.shoeID, \.distanceMeters]
        return descriptor
    }
}

// MARK: - ShoeAssignment

/// Puts the default shoe on newly saved runs. The one write shoe tracking makes on its
/// own; everything else is the runner choosing.
enum ShoeAssignment {

    /// Gives each run that has no shoe yet the default pair for its date.
    ///
    /// Walks are left alone. A walk is history, not training (N38), and the pair a
    /// runner runs in is rarely the pair they walk to the shop in; they can still pick a
    /// shoe for a walk by hand. Imported cross-training is left alone too (B8): a 40 km
    /// ride on the default pair would be 40 km of wear it never took. Does not save —
    /// callers already save the runs they insert, and this rides along with that save.
    static func assignDefaultShoe(to runs: [RunWorkout], in context: ModelContext) {
        let candidates = runs.filter { $0.shoeID == nil && $0.countsAsRunning }
        guard !candidates.isEmpty else { return }
        let shoes: [Shoe]
        do {
            shoes = try context.fetch(FetchDescriptor<Shoe>())
        } catch {
            AppLogger.log("Could not read shoes to assign a default: \(error)", label: "Shoes", level: .error)
            return
        }
        guard shoes.contains(where: \.isDefault) else { return }
        for run in candidates {
            run.shoeID = ShoeWearPolicy.defaultShoe(among: shoes, forRunOn: run.date)?.id
        }
    }

    /// Makes `shoe` the pair new runs go on, and stops every other pair being it.
    static func makeDefault(_ shoe: Shoe, among shoes: [Shoe], now: Date = Date()) {
        for other in shoes where other.id != shoe.id {
            other.defaultSetAt = nil
        }
        shoe.defaultSetAt = now
        shoe.retiredAt = nil
    }

    /// Takes a pair out of rotation. It keeps its runs and mileage; it just stops being
    /// offered, stops nudging, and stops being the default.
    static func retire(_ shoe: Shoe, now: Date = Date()) {
        shoe.retiredAt = now
        shoe.defaultSetAt = nil
    }

    /// Deletes a pair and takes it off every run that named it, so no run is left
    /// pointing at a shoe that no longer exists. Does not save.
    static func delete(_ shoe: Shoe, in context: ModelContext) {
        let shoeID: UUID? = shoe.id
        let runs = (try? context.fetch(FetchDescriptor<RunWorkout>(
            predicate: #Predicate { $0.shoeID == shoeID }
        ))) ?? []
        for run in runs {
            run.shoeID = nil
        }
        context.delete(shoe)
    }
}

// MARK: - ShoeNudgeDismissals

/// Which wear level the runner has already said "not yet" to, per pair. Device-local in
/// `UserDefaults`, like the heat advisory's dismissals: it is a note about what this
/// screen has shown, not something that happened on the run.
enum ShoeNudgeDismissals {
    static let key = "shoeNudgeDismissals"

    static func load(from defaults: UserDefaults = .standard) -> [UUID: ShoeWearPolicy.Wear] {
        let raw = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        var result: [UUID: ShoeWearPolicy.Wear] = [:]
        for (id, level) in raw {
            if let uuid = UUID(uuidString: id), let wear = ShoeWearPolicy.Wear(rawValue: level) {
                result[uuid] = wear
            }
        }
        return result
    }

    static func dismiss(_ shoeID: UUID, at wear: ShoeWearPolicy.Wear, in defaults: UserDefaults = .standard) {
        var raw = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        raw[shoeID.uuidString] = wear.rawValue
        defaults.set(raw, forKey: key)
    }

    static func removeAll(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
