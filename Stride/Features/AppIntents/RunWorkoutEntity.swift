import AppIntents
import CoreSpotlight
import Foundation
import SwiftData
import UniformTypeIdentifiers

// Following Apple's "Apple Intelligence and Siri" App Intents guidance, a completed run
// is modelled as an `AppEntity` and indexed in Spotlight (`IndexedEntity`). That lets
// Siri, the Shortcuts app, Spotlight, and Apple Intelligence discover and reference
// runs from natural language ("my long run last weekend") and pass them into intents.

struct RunWorkoutEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Run")
    static let defaultQuery = RunWorkoutEntityQuery()

    let id: UUID
    let date: Date
    let workoutTypeName: String
    let distanceMeters: Double
    let durationSeconds: Double
    let averagePaceSecondsPerKm: Double

    /// Preformatted, unit-aware strings computed when the entity is built. The unit
    /// preference lives on the `@MainActor` `AppSettings`, so it cannot be read from the
    /// nonisolated `displayRepresentation` / `attributeSet` accessors — we bake it in.
    let title: String
    let subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(subtitle)",
            image: .init(systemName: "figure.run")
        )
    }
}

// MARK: - Spotlight indexing

extension RunWorkoutEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = title
        attributes.contentDescription = subtitle
        attributes.contentCreationDate = date
        attributes.keywords = [workoutTypeName, "run", "running", "workout"]
        return attributes
    }
}

// MARK: - Query

struct RunWorkoutEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [RunWorkoutEntity.ID]) async throws -> [RunWorkoutEntity] {
        let unit = await MainActor.run { AppSettings.syncedUnitPreference() }
        return try await makeActor().runEntities(ids: identifiers, unit: unit)
    }

    func suggestedEntities() async throws -> [RunWorkoutEntity] {
        let unit = await MainActor.run { AppSettings.syncedUnitPreference() }
        return try await makeActor().recentRunEntities(limit: 10, unit: unit)
    }

    func entities(matching string: String) async throws -> [RunWorkoutEntity] {
        let unit = await MainActor.run { AppSettings.syncedUnitPreference() }
        return try await makeActor().runEntities(matching: string, unit: unit)
    }

    private func makeActor() throws -> IntentModelActor {
        IntentModelActor(modelContainer: try IntentDataProvider.makeContainer())
    }
}

// MARK: - Model → entity mapping

extension RunWorkout {
    /// Builds a Sendable `RunWorkoutEntity` snapshot. Called inside `IntentModelActor`,
    /// where the SwiftData model is safe to read; the returned value crosses actor
    /// boundaries. All formatting helpers used here are nonisolated pure functions.
    func runWorkoutEntity(unit: UnitPreference) -> RunWorkoutEntity {
        let distanceText = distanceMeters.distanceString(unit: unit)
        let paceText = averagePaceSecondsPerKm.paceString(unit: unit)
        let dateText = date.formatted(date: .abbreviated, time: .omitted)
        return RunWorkoutEntity(
            id: id,
            date: date,
            workoutTypeName: workoutType.localizedName,
            distanceMeters: distanceMeters,
            durationSeconds: durationSeconds,
            averagePaceSecondsPerKm: averagePaceSecondsPerKm,
            title: "\(workoutType.localizedName) · \(distanceText)",
            subtitle: "\(dateText) · \(paceText)"
        )
    }
}

// MARK: - Spotlight indexer

enum RunSpotlightIndexer {
    /// Indexes recent runs into Spotlight so Apple Intelligence can find them by
    /// semantic search. Best-effort: failures are logged and ignored.
    static func indexRecentRuns(in container: ModelContainer, unit: UnitPreference) async {
        do {
            let actor = IntentModelActor(modelContainer: container)
            let entities = try await actor.recentRunEntities(limit: 50, unit: unit)
            guard !entities.isEmpty else { return }
            try await CSSearchableIndex.default().indexAppEntities(entities)
        } catch {
            AppLogger.log(
                "Spotlight run indexing failed: \(error.localizedDescription)",
                label: "AppIntents",
                level: .error
            )
        }
    }
}
