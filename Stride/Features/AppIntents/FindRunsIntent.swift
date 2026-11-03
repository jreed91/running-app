// Siri AI Developer Preview: a "find runs" tool whose search Siri fills in straight from
// the request ("my long runs over 20 km last month") instead of asking Stride first.
// Everything here is iOS 27.3 SDK only (`@AppEntity(.generable)`, `TransientAppEntity`
// generation, `@Property(description:)`, `@AppIntent(.tool)`). `SiriEvaluations` ships
// in that same SDK, so older Xcodes skip the file. See docs/siri-ai-developer-preview.md.
#if canImport(SiriEvaluations)
import AppIntents
import Foundation

/// The kinds of run a search can ask for. `any` keeps the search open, since a generable
/// entity's properties are filled in by the model and have no "unset".
@available(iOS 27.3, *)
enum RunSearchKind: String, AppEnum {
    case any
    case easy
    case tempo
    case interval
    case longRun
    case race

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Run Type"
    static let caseDisplayRepresentations: [RunSearchKind: DisplayRepresentation] = [
        .any: "Any run",
        .easy: "Easy",
        .tempo: "Tempo",
        .interval: "Interval",
        .longRun: "Long Run",
        .race: "Race",
    ]

    var workoutType: WorkoutType? {
        switch self {
        case .any: return nil
        case .easy: return .easy
        case .tempo: return .tempo
        case .interval: return .interval
        case .longRun: return .longRun
        case .race: return .race
        }
    }
}

@available(iOS 27.3, *)
@AppEntity(.generable)
struct RunSearch: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Run Search"

    @Property(title: "Run Type", description: "The kind of run to find. Use any when the runner doesn't name one.")
    var kind: RunSearchKind

    @Property(title: "From", description: "The first day to include. Use one year before today if no start is given.")
    var from: Date

    @Property(title: "To", description: "The last day to include. Use today if no end is given.")
    var to: Date

    @Property(
        title: "Minimum Distance",
        description: "The shortest run to include, in kilometres (1 mile is 1.609 km). Use 0 for no minimum."
    )
    var minimumKilometres: Double

    var displayRepresentation: DisplayRepresentation {
        "Run search"
    }

    init() {}
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct FindRunsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Runs"
    static let description = IntentDescription(
        "Finds finished runs by type, date range and minimum distance, newest first, up to 20."
    )
    static let openAppWhenRun = false

    static let resultLimit = 20

    @Parameter(title: "Search", description: "Which runs to find: the type, the days to search, and a minimum distance.")
    var search: RunSearch

    func perform() async throws -> some IntentResult & ReturnsValue<[RunWorkoutEntity]> & ProvidesDialog {
        let unit = await MainActor.run { AppSettings.syncedUnitPreference() }
        let actor = IntentModelActor(modelContainer: try IntentDataProvider.makeContainer())
        let runs = try await actor.findRuns(
            workoutType: search.kind.workoutType,
            from: search.from,
            to: search.to,
            minimumMeters: max(0, search.minimumKilometres) * 1_000,
            limit: Self.resultLimit,
            unit: unit
        )
        let dialog = RunSearchDialog.text(
            count: runs.count,
            totalMeters: runs.reduce(0) { $0 + $1.distanceMeters },
            unit: unit
        )
        return .result(value: runs, dialog: IntentDialog(stringLiteral: dialog))
    }
}
#endif
