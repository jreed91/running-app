import Foundation
import CoreLocation

// MARK: - Coordinate

/// Sendable, Codable wrapper around CLLocationCoordinate2D for storage.
struct Coordinate: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Split

/// Per-kilometre split data captured during a run.
struct Split: Codable, Hashable, Sendable {
    var kilometer: Int
    var paceSecondsPerKm: Double
    var heartRate: Double?
    var elevationGainMeters: Double
    var cumulativeDistanceMeters: Double
}

// MARK: - Lap

/// One lap of a run, closed by the runner tapping the lap control (A2).
///
/// Laps are **manual** and so are not splits: a split closes every kilometre or mile
/// whether the runner asked for it or not, while a lap closes exactly where they said
/// — the top of a rep, the bottom of a hill, the lap line on a track. A run that was
/// never lapped carries none, which is why this is stored separately from ``Split``
/// rather than folded into it.
struct Lap: Codable, Hashable, Sendable {
    /// 1-based position in the run.
    var number: Int
    /// Elapsed run time at which this lap opened, in seconds. Lap 1 opens at 0.
    var startElapsedSeconds: Double
    var durationSeconds: Double
    var distanceMeters: Double
    /// Average pace across the lap in seconds per kilometre, regardless of the runner's
    /// display unit — the same convention ``Split/paceSecondsPerKm`` uses. `0` for a lap
    /// that covered no measurable distance, which formats as "--:--".
    var paceSecondsPerKm: Double
}

// MARK: - WorkoutInterval

/// A single repeat within an interval training session.
struct WorkoutInterval: Codable, Hashable, Sendable {
    var repetitions: Int
    var distanceMeters: Double?
    var durationSeconds: Double?
    var targetPaceSecondsPerKm: Double?
    var recoverySeconds: Double
    var recoveryType: RecoveryType
}

// MARK: - WorkoutSegment

/// A single continuous segment of a run (warm-up, work repeat, recovery, cool-down).
struct WorkoutSegment: Codable, Hashable, Sendable {
    /// Target distance in meters. Nil when segment is time-based or open.
    var distanceMeters: Double?
    /// Target duration in seconds. Nil when segment is distance-based or open.
    var durationSeconds: Double?
    /// Target pace in seconds/km. Nil for open/recovery segments.
    var targetPaceSecondsPerKm: Double?
    /// Human-readable label, e.g. "Warm-up", "Cool-down", "Recovery jog".
    var label: String
}

// MARK: - WorkoutSet

/// One repeated block: N repetitions of a work segment followed by a recovery segment.
struct WorkoutSet: Codable, Hashable, Sendable {
    var repetitions: Int
    var workSegment: WorkoutSegment
    var recoverySegment: WorkoutSegment
    /// Human-readable label, e.g. "VO2max Intervals", "Tempo Block".
    var label: String

    /// Total recovery time across the whole set, in seconds.
    ///
    /// There are only `repetitions - 1` recovery jogs: the final repetition is
    /// followed by the cool-down, not another recovery, so a recovery is never
    /// counted after the last rep. Returns 0 when there is a single rep (or none)
    /// or when the recovery segment has no duration.
    var totalRecoverySeconds: Double {
        guard repetitions > 1, let recovery = recoverySegment.durationSeconds else { return 0 }
        return Double(repetitions - 1) * recovery
    }
}

// MARK: - WorkoutStructure

/// Full structured representation of a workout with warm-up, main sets, and cool-down.
/// Serialised to JSON and stored in ``ScheduledWorkout/structureData``.
struct WorkoutStructure: Codable, Hashable, Sendable {
    var warmup: WorkoutSegment
    var mainSets: [WorkoutSet]
    var cooldown: WorkoutSegment
    var totalEstimatedDistanceMeters: Double
    var totalEstimatedDurationSeconds: Double
}

// MARK: - WorkoutWeather

/// Weather conditions recorded at the start of a run.
struct WorkoutWeather: Codable, Hashable, Sendable {
    /// Ambient temperature in Celsius.
    var temperatureCelsius: Double
    /// Apparent ("feels like") temperature in Celsius.
    var feelsLikeCelsius: Double
    /// Relative humidity as a percentage (0–100).
    var humidityPercent: Double
    /// Dew point in Celsius, when the forecast supplied one.
    ///
    /// Optional because it is newer than the type: rows written before this field existed
    /// decode with `nil`, and `HeatAdaptationPolicy.dewPointCelsius(for:)` derives one
    /// from temperature and humidity in that case. Costs no CloudKit schema change —
    /// `WorkoutWeather` is JSON inside `RunWorkout.weatherData`, not a stored property.
    ///
    /// Carried rather than always derived because it is the number that decides whether
    /// sweat can evaporate, which is the whole of `HeatAdaptationPolicy`'s primary scale;
    /// see `docs/HEAT_ADAPTATION_EVIDENCE.md` §1.
    var dewPointCelsius: Double?
    /// Wind speed in km/h.
    var windSpeedKmh: Double
    /// SF Symbol name for the weather condition (e.g. "sun.max.fill").
    var conditionSymbol: String
    /// Human-readable weather condition (e.g. "Partly Cloudy").
    var conditionDescription: String

    func temperatureString(unit: UnitPreference) -> String {
        switch unit {
        case .metric:   return String(format: "%.0f°C", temperatureCelsius)
        case .imperial: return String(format: "%.0f°F", temperatureCelsius * 9 / 5 + 32)
        }
    }

    func feelsLikeString(unit: UnitPreference) -> String {
        switch unit {
        case .metric:   return String(format: "%.0f°C", feelsLikeCelsius)
        case .imperial: return String(format: "%.0f°F", feelsLikeCelsius * 9 / 5 + 32)
        }
    }

    func windString(unit: UnitPreference) -> String {
        switch unit {
        case .metric:   return String(format: "%.0f km/h", windSpeedKmh)
        case .imperial: return String(format: "%.0f mph", windSpeedKmh * 0.621371)
        }
    }

    /// The dew point as shown, derived from temperature and humidity when the forecast
    /// carried none — so this never reads as missing data to someone who can see the
    /// humidity right beside it.
    func dewPointString(unit: UnitPreference) -> String {
        let celsius = HeatAdaptationPolicy.dewPointCelsius(for: self)
        switch unit {
        case .metric:   return String(format: "%.0f°C", celsius)
        case .imperial: return String(format: "%.0f°F", celsius * 9 / 5 + 32)
        }
    }
}

// MARK: - RouteStep

/// A single turn-by-turn navigation step returned by the route generation service.
struct RouteStep: Codable, Hashable, Sendable {
    /// Human-readable direction instruction, e.g. "Turn left onto Oak Street".
    var instruction: String
    /// Street or path name for this step.
    var name: String
    /// Distance covered in this step, in metres.
    var distanceMeters: Double
    /// Estimated duration of this step, in seconds.
    var durationSeconds: Double
}

// MARK: - GeneratedRoute

/// A route returned by ``RouteGeniusService`` before it is persisted as a ``SavedRoute``.
struct GeneratedRoute: Sendable {
    /// Ordered coordinate path for the full route.
    var coordinates: [Coordinate]
    /// Turn-by-turn steps for the full route.
    var steps: [RouteStep]
    /// Actual route distance in metres (may differ from requested distance by ±10%).
    var distanceMeters: Double
    /// Estimated running duration in seconds (at an average pace of ~6 min/km).
    var durationSeconds: Double
    /// Short human-readable label distinguishing this option, e.g. "Option A" or "Heading North".
    var label: String
}

// MARK: - Strength Types

struct StrengthExercise: Codable, Hashable, Sendable {
    var name: String
    var sets: Int
    var reps: Int           // 0 = AMRAP (as many reps as possible)
    var durationSeconds: Int?  // non-nil for timed exercises (plank, wall sit)
    var targetWeight: String?  // "Bodyweight", "Light", "Moderate", "Heavy"
    var notes: String?
    var muscleGroups: [String]
}

struct StrengthWorkoutPlan: Codable, Hashable, Sendable {
    var focus: StrengthFocus
    var exercises: [StrengthExercise]
    var estimatedDurationMinutes: Int
    var notes: String?
}

struct CompletedStrengthSet: Codable, Hashable, Sendable {
    var exerciseIndex: Int
    var setIndex: Int
    var completedReps: Int
    var actualWeight: String?
    var skipped: Bool
}
