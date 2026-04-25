import Foundation
import SwiftData

// MARK: - Protocol

protocol RouteRepositoryProtocol {
    func save(_ route: SavedRoute) throws
    func fetchAll() throws -> [SavedRoute]
    func delete(_ route: SavedRoute) throws
}

// MARK: - SwiftData Implementation

final class RouteRepository: RouteRepositoryProtocol {

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func save(_ route: SavedRoute) throws {
        context.insert(route)
        try context.save()
    }

    func fetchAll() throws -> [SavedRoute] {
        let descriptor = FetchDescriptor<SavedRoute>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    func delete(_ route: SavedRoute) throws {
        context.delete(route)
        try context.save()
    }
}
