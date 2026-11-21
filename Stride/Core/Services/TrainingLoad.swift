import Foundation

// MARK: - TrainingLoad

/// Fitness, fatigue and form: a load score for every session, and the long and short
/// running averages of it that show a build, a taper and a block's toll.
///
/// The model is the one coaches and most training apps use (Banister's impulse-response,
/// as popularised by TrainingPeaks' CTL / ATL / TSB):
///
/// - **Load** per session is a heart-rate TRIMP: minutes × intensity × 0.64·e^(1.92·intensity),
///   where intensity is the heart-rate reserve fraction the run averaged. A run without
///   heart rate falls back to an intensity from how it felt, or from its workout type.
/// - **Fitness** is a 42-day exponentially weighted average of daily load.
/// - **Fatigue** is the same over 7 days.
/// - **Form** is fitness minus fatigue: negative while building, positive when fresh.
///
/// Pure and `Sendable`. The view turns runs into ``Session``s, choosing the fallback
/// intensity, so this is tested without SwiftData.
enum TrainingLoad {

    static let fitnessDays = 42.0
    static let fatigueDays = 7.0
    /// Used when the runner's resting heart rate isn't known. Most adult runners sit
    /// between 50 and 70; an error here shifts every run's intensity the same way, so
    /// the shape of the chart holds even when the absolute numbers drift.
    static let defaultRestingHeartRate = 60.0

    /// One session's inputs.
    struct Session: Equatable, Sendable {
        let id: UUID
        let date: Date
        let durationSeconds: Double
        let averageHeartRate: Double?
        /// Heart-rate reserve fraction to assume when the session has no usable heart
        /// rate, from ``fallbackIntensity(feel:typeIntensity:)``.
        let fallbackIntensity: Double
    }

    // MARK: Per session

    /// The fraction of heart-rate reserve a session averaged, clamped to 0...1, or `nil`
    /// without a usable heart rate or max.
    static func intensity(
        averageHeartRate: Double?,
        maxHeartRate: Double?,
        restingHeartRate: Double = defaultRestingHeartRate
    ) -> Double? {
        guard let averageHeartRate, let maxHeartRate,
              averageHeartRate > 0, maxHeartRate > restingHeartRate else { return nil }
        let fraction = (averageHeartRate - restingHeartRate) / (maxHeartRate - restingHeartRate)
        guard fraction.isFinite else { return nil }
        return min(max(fraction, 0), 1)
    }

    /// The intensity to assume without heart rate: from a 1–5 feel rating when there is
    /// one, otherwise the workout type's typical intensity.
    static func fallbackIntensity(feel: Int?, typeIntensity: Double) -> Double {
        switch feel {
        case 1: return 0.50
        case 2: return 0.60
        case 3: return 0.70
        case 4: return 0.80
        case 5: return 0.90
        default: return typeIntensity
        }
    }

    /// Heart-rate TRIMP: minutes weighted so that harder minutes count for much more.
    static func load(durationSeconds: Double, intensity: Double) -> Double {
        guard durationSeconds > 0, durationSeconds.isFinite, intensity.isFinite else { return 0 }
        let minutes = durationSeconds / 60
        let clamped = min(max(intensity, 0), 1)
        return minutes * clamped * 0.64 * exp(1.92 * clamped)
    }

    static func load(of session: Session, maxHeartRate: Double?, restingHeartRate: Double) -> Double {
        let measured = intensity(
            averageHeartRate: session.averageHeartRate,
            maxHeartRate: maxHeartRate,
            restingHeartRate: restingHeartRate
        )
        return load(durationSeconds: session.durationSeconds, intensity: measured ?? session.fallbackIntensity)
    }

    // MARK: Daily series

    struct Day: Equatable, Sendable, Identifiable {
        let date: Date
        /// Total load of the sessions that day.
        let load: Double
        let fitness: Double
        let fatigue: Double
        let sessionIDs: [UUID]

        var id: Date { date }
        var form: Double { fitness - fatigue }
    }

    /// One day per calendar day from the first session's day to `now`'s, rest days
    /// included: a day off is what lets fatigue fall.
    static func days(
        for sessions: [Session],
        maxHeartRate: Double?,
        restingHeartRate: Double = defaultRestingHeartRate,
        through now: Date,
        calendar: Calendar
    ) -> [Day] {
        guard let first = sessions.map(\.date).min() else { return [] }
        var loads: [Date: Double] = [:]
        var ids: [Date: [UUID]] = [:]
        for session in sessions.sorted(by: { $0.date < $1.date }) {
            let day = calendar.startOfDay(for: session.date)
            loads[day, default: 0] += load(of: session, maxHeartRate: maxHeartRate, restingHeartRate: restingHeartRate)
            ids[day, default: []].append(session.id)
        }

        var result: [Day] = []
        var fitness = 0.0
        var fatigue = 0.0
        var day = calendar.startOfDay(for: first)
        let last = calendar.startOfDay(for: max(now, first))
        // Bounded: 30 years of days.
        while day <= last, result.count < 11_000 {
            let todays = loads[day] ?? 0
            fitness += (todays - fitness) / fitnessDays
            fatigue += (todays - fatigue) / fatigueDays
            result.append(Day(date: day, load: todays, fitness: fitness, fatigue: fatigue, sessionIDs: ids[day] ?? []))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return result
    }

    // MARK: Reading form

    enum FormZone: Equatable, Sendable {
        /// Well rested; fitness may be slipping if it lasts.
        case fresh
        /// Balanced.
        case neutral
        /// The productive training range.
        case building
        /// Deep fatigue: rest soon.
        case overreaching
    }

    /// Bands on form, in the same load units: the conventional TSB ranges, which hold up
    /// for TRIMP-scaled loads of a typical recreational runner.
    static func zone(forForm form: Double) -> FormZone {
        switch form {
        case 5...: return .fresh
        case -10..<5: return .neutral
        case -30 ..< -10: return .building
        default: return .overreaching
        }
    }
}
