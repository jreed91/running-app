import Foundation
import SwiftData

// MARK: - Protocol

protocol WorkoutRepositoryProtocol {
    func save(_ workout: RunWorkout) throws
    func fetchAll() throws -> [RunWorkout]
    func fetch(from startDate: Date, to endDate: Date) throws -> [RunWorkout]
    func fetchRecent(limit: Int) throws -> [RunWorkout]
    func delete(_ workout: RunWorkout) throws
}

// MARK: - SwiftData implementation

final class WorkoutRepository: WorkoutRepositoryProtocol {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func save(_ workout: RunWorkout) throws {
        context.insert(workout)
        try context.save()
    }

    func fetchAll() throws -> [RunWorkout] {
        let descriptor = FetchDescriptor<RunWorkout>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    func fetch(from startDate: Date, to endDate: Date) throws -> [RunWorkout] {
        let descriptor = FetchDescriptor<RunWorkout>(
            predicate: #Predicate { $0.date >= startDate && $0.date <= endDate },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    func fetchRecent(limit: Int) throws -> [RunWorkout] {
        var descriptor = FetchDescriptor<RunWorkout>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    func delete(_ workout: RunWorkout) throws {
        context.delete(workout)
        try context.save()
    }
}
