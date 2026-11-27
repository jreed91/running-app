import Foundation
import SwiftData

// MARK: - SavedWorkout

/// A structured session the runner built themselves: "6 × 800 m", "3 × 1 mile tempo",
/// "10 × 1 minute on, 1 off" (Custom workouts, PR 1).
///
/// It is a named ``WorkoutStructure`` and nothing more, on purpose. Every structured plan
/// session is already one — the guided stepper (``GuidedWorkoutState``), the spoken step
/// cues, the WorkoutKit export to Apple's Workout app and the Watch recorder all run from
/// that type — so a workout kept here runs everywhere a plan session runs without a second
/// description of what a rep is.
///
/// A library entry, not a plan day: it has no date and is never completed. Running one, or
/// swapping it onto a plan day, copies its structure out; editing it afterwards does not
/// reach back into runs or plan days it was used for.
///
/// Synced through CloudKit like ``SavedRoute``, so every field has a default and the
/// structure travels as JSON in one `Data` field (`CD_SavedWorkout` in
/// `cloudkit/Stride.ckdb`).
@Model
final class SavedWorkout {
    #Index<SavedWorkout>([\.id], [\.updatedAt])

    var id: UUID = UUID()
    /// What the runner called it. ``CustomWorkoutRules`` keeps it non-empty and short.
    var name: String = ""
    /// Optional free text, for example "on the track" or "hill by the park".
    var notes: String?
    var createdAt: Date = Date()
    /// Bumped on every edit; the library lists the most recently changed first.
    var updatedAt: Date = Date()
    /// When it was last started or put on a plan day, so the Watch can be sent the ones
    /// the runner actually uses. `nil` until then.
    var lastUsedAt: Date?

    /// JSON-encoded ``WorkoutStructure``. Optional only because CloudKit-backed SwiftData
    /// needs every attribute to be; a saved workout without one is not offered to run.
    var structureData: Data?

    var structure: WorkoutStructure? {
        get { structureData?.decode(WorkoutStructure.self) }
        set { structureData = newValue.flatMap { Data.encoded($0, keeping: structureData) } }
    }

    init(name: String, structure: WorkoutStructure, notes: String? = nil, now: Date = Date()) {
        self.id = UUID()
        self.name = name
        self.notes = notes
        self.createdAt = now
        self.updatedAt = now
        self.lastUsedAt = nil
        self.structure = structure
    }

    /// Replaces the workout's content and marks it changed.
    func update(name: String, structure: WorkoutStructure, notes: String?, now: Date = Date()) {
        self.name = name
        self.structure = structure
        self.notes = notes
        self.updatedAt = now
    }

    /// Notes that the runner started it or put it on a plan day.
    func markUsed(now: Date = Date()) {
        lastUsedAt = now
    }
}
