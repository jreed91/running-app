import Foundation
import SwiftData

// MARK: - Protocol

protocol PlanRepositoryProtocol {
    func save(_ plan: TrainingPlan) throws
    func fetchAll() throws -> [TrainingPlan]
    func fetchActivePlan() throws -> TrainingPlan?
    func setActive(_ plan: TrainingPlan) throws
    func delete(_ plan: TrainingPlan) throws
}

// MARK: - SwiftData implementation

final class PlanRepository: PlanRepositoryProtocol {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Inserts a plan and enforces the single-active-plan invariant: if the incoming
    /// plan is active, every other plan is deactivated so `fetchActivePlan` can never
    /// resolve an arbitrary winner among duplicates.
    func save(_ plan: TrainingPlan) throws {
        context.insert(plan)
        if plan.isActive {
            for other in try fetchAll() where other.id != plan.id {
                other.isActive = false
            }
        }
        try context.save()
    }

    func fetchAll() throws -> [TrainingPlan] {
        let descriptor = FetchDescriptor<TrainingPlan>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    func fetchActivePlan() throws -> TrainingPlan? {
        // Sort newest-first so that if the invariant is ever violated (e.g. a legacy
        // store with multiple actives) the most recently created plan wins deterministically.
        let descriptor = FetchDescriptor<TrainingPlan>(
            predicate: #Predicate { $0.isActive },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor).first
    }

    /// Deactivates all plans, then marks the given plan active.
    func setActive(_ plan: TrainingPlan) throws {
        let all = try fetchAll()
        all.forEach { $0.isActive = false }
        plan.isActive = true
        try context.save()
    }

    func delete(_ plan: TrainingPlan) throws {
        context.delete(plan)
        try context.save()
    }
}
