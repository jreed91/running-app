import AppIntents
import CoreSpotlight
import CoreTransferable
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

    // The `@Property` values are what Siri, Shortcuts and Apple Intelligence can read off
    // a run ("how far was my long run on Saturday?"). Before these existed the entity
    // exposed only its display title, so a run could be found and shown but none of its
    // numbers could be answered from or passed on (Siri AI Developer Preview, "Add
    // information to your app entities"). The preview also asks for a `description:` on
    // each property; that initializer is iOS 27.3+ and a stored property can't be gated
    // below the 27.0 deployment target, so it waits until the target moves.
    @Property(title: "Date")
    var date: Date

    @Property(title: "Workout Type")
    var workoutTypeName: String

    @Property(title: "Distance")
    var distance: Measurement<UnitLength>

    @Property(title: "Duration")
    var duration: Measurement<UnitDuration>

    /// Already formatted in the runner's unit ("5:20 /km"); there is no pace unit type.
    @Property(title: "Average Pace")
    var averagePace: String

    let distanceMeters: Double
    let durationSeconds: Double
    let averagePaceSecondsPerKm: Double

    /// Preformatted, unit-aware strings computed when the entity is built. The unit
    /// preference lives on the `@MainActor` `AppSettings`, so it cannot be read from the
    /// nonisolated `displayRepresentation` / `attributeSet` accessors — we bake it in.
    let title: String
    let subtitle: String

    init(
        id: UUID,
        date: Date,
        workoutTypeName: String,
        distanceMeters: Double,
        durationSeconds: Double,
        averagePaceSecondsPerKm: Double,
        averagePaceText: String,
        title: String,
        subtitle: String
    ) {
        self.id = id
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.averagePaceSecondsPerKm = averagePaceSecondsPerKm
        self.title = title
        self.subtitle = subtitle
        self.date = date
        self.workoutTypeName = workoutTypeName
        self.distance = Measurement(value: distanceMeters, unit: .meters)
        self.duration = Measurement(value: durationSeconds, unit: .seconds)
        self.averagePace = averagePaceText
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(subtitle)",
            image: .init(systemName: "figure.run")
        )
    }
}

// MARK: - Sharing

// "Send my long run to Sam": Siri can hand a run to another app (Messages, Mail, Notes)
// only if it has a representation that app understands. Plain text is the one every
// destination takes; the formatted title and subtitle are already in the runner's units.
extension RunWorkoutEntity: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { (run: RunWorkoutEntity) in run.shareText })
    }

    /// "Long Run · 18.2 km\nSat, Nov 1, 2026 · 5:31 /km · 1:40:24"
    var shareText: String {
        "\(title)\n\(subtitle) · \(durationSeconds.durationString)"
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
            averagePaceText: paceText,
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
