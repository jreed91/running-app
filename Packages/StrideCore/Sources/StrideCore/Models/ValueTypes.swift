import Foundation

// MARK: - Coordinate

/// Sendable, Codable wrapper around CLLocationCoordinate2D for storage. The CoreLocation
/// conversions live in the app (`Coordinate+CoreLocation.swift`): this package is
/// Foundation only.
public struct Coordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// Metres above sea level, when the fix had a valid one. Older routes, and fixes
    /// made from a bare coordinate, have none; it is left out of the stored JSON then.
    public var altitude: Double?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

// MARK: - Split

/// Per-kilometre split data captured during a run.
public struct Split: Codable, Hashable, Sendable {
    public var kilometer: Int
    public var paceSecondsPerKm: Double
    public var heartRate: Double?
    public var elevationGainMeters: Double
    public var cumulativeDistanceMeters: Double

    public init(
        kilometer: Int,
        paceSecondsPerKm: Double,
        heartRate: Double? = nil,
        elevationGainMeters: Double,
        cumulativeDistanceMeters: Double
    ) {
        self.kilometer = kilometer
        self.paceSecondsPerKm = paceSecondsPerKm
        self.heartRate = heartRate
        self.elevationGainMeters = elevationGainMeters
        self.cumulativeDistanceMeters = cumulativeDistanceMeters
    }
}

// MARK: - Lap

/// One lap of a run, closed by the runner tapping the lap control (A2).
///
/// Laps are **manual** and so are not splits: a split closes every kilometre or mile
/// whether the runner asked for it or not, while a lap closes exactly where they said
/// — the top of a rep, the bottom of a hill, the lap line on a track. A run that was
/// never lapped carries none, which is why this is stored separately from ``Split``
/// rather than folded into it.
public struct Lap: Codable, Hashable, Sendable {
    /// 1-based position in the run.
    public var number: Int
    /// Elapsed run time at which this lap opened, in seconds. Lap 1 opens at 0.
    public var startElapsedSeconds: Double
    public var durationSeconds: Double
    public var distanceMeters: Double
    /// Average pace across the lap in seconds per kilometre, regardless of the runner's
    /// display unit — the same convention ``Split/paceSecondsPerKm`` uses. `0` for a lap
    /// that covered no measurable distance, which formats as "--:--".
    public var paceSecondsPerKm: Double

    public init(
        number: Int,
        startElapsedSeconds: Double,
        durationSeconds: Double,
        distanceMeters: Double,
        paceSecondsPerKm: Double
    ) {
        self.number = number
        self.startElapsedSeconds = startElapsedSeconds
        self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters
        self.paceSecondsPerKm = paceSecondsPerKm
    }
}

// MARK: - WorkoutInterval

/// A single repeat within an interval training session.
public struct WorkoutInterval: Codable, Hashable, Sendable {
    public var repetitions: Int
    public var distanceMeters: Double?
    public var durationSeconds: Double?
    public var targetPaceSecondsPerKm: Double?
    public var recoverySeconds: Double
    public var recoveryType: RecoveryType

    public init(
        repetitions: Int,
        distanceMeters: Double? = nil,
        durationSeconds: Double? = nil,
        targetPaceSecondsPerKm: Double? = nil,
        recoverySeconds: Double,
        recoveryType: RecoveryType
    ) {
        self.repetitions = repetitions
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.targetPaceSecondsPerKm = targetPaceSecondsPerKm
        self.recoverySeconds = recoverySeconds
        self.recoveryType = recoveryType
    }
}

// WorkoutSegment, WorkoutSet and WorkoutStructure live in WorkoutStructure.swift, which
// the watch app compiles too.

// MARK: - WorkoutWeather

/// Weather conditions recorded at the start of a run.
public struct WorkoutWeather: Codable, Hashable, Sendable {
    /// Ambient temperature in Celsius.
    public var temperatureCelsius: Double
    /// Apparent ("feels like") temperature in Celsius.
    public var feelsLikeCelsius: Double
    /// Relative humidity as a percentage (0–100).
    public var humidityPercent: Double
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
    public var dewPointCelsius: Double?
    /// Wind speed in km/h.
    public var windSpeedKmh: Double
    /// SF Symbol name for the weather condition (e.g. "sun.max.fill").
    public var conditionSymbol: String
    /// Human-readable weather condition (e.g. "Partly Cloudy").
    public var conditionDescription: String

    public func temperatureString(unit: UnitPreference) -> String {
        switch unit {
        case .metric:   return String(format: "%.0f°C", temperatureCelsius)
        case .imperial: return String(format: "%.0f°F", temperatureCelsius * 9 / 5 + 32)
        }
    }

    public func feelsLikeString(unit: UnitPreference) -> String {
        switch unit {
        case .metric:   return String(format: "%.0f°C", feelsLikeCelsius)
        case .imperial: return String(format: "%.0f°F", feelsLikeCelsius * 9 / 5 + 32)
        }
    }

    public func windString(unit: UnitPreference) -> String {
        switch unit {
        case .metric:   return String(format: "%.0f km/h", windSpeedKmh)
        case .imperial: return String(format: "%.0f mph", windSpeedKmh * 0.621371)
        }
    }

    public init(
        temperatureCelsius: Double,
        feelsLikeCelsius: Double,
        humidityPercent: Double,
        dewPointCelsius: Double? = nil,
        windSpeedKmh: Double,
        conditionSymbol: String,
        conditionDescription: String
    ) {
        self.temperatureCelsius = temperatureCelsius
        self.feelsLikeCelsius = feelsLikeCelsius
        self.humidityPercent = humidityPercent
        self.dewPointCelsius = dewPointCelsius
        self.windSpeedKmh = windSpeedKmh
        self.conditionSymbol = conditionSymbol
        self.conditionDescription = conditionDescription
    }
}

// MARK: - RouteStep

/// A single turn-by-turn navigation step returned by the route generation service.
public struct RouteStep: Codable, Hashable, Sendable {
    /// Human-readable direction instruction, e.g. "Turn left onto Oak Street".
    public var instruction: String
    /// Street or path name for this step.
    public var name: String
    /// Distance covered in this step, in metres.
    public var distanceMeters: Double
    /// Estimated duration of this step, in seconds.
    public var durationSeconds: Double

    public init(
        instruction: String,
        name: String,
        distanceMeters: Double,
        durationSeconds: Double
    ) {
        self.instruction = instruction
        self.name = name
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
    }
}

// MARK: - GeneratedRoute

/// A route returned by ``RouteGeniusService`` before it is persisted as a ``SavedRoute``.
public struct GeneratedRoute: Sendable {
    /// Ordered coordinate path for the full route.
    public var coordinates: [Coordinate]
    /// Turn-by-turn steps for the full route.
    public var steps: [RouteStep]
    /// Actual route distance in metres (may differ from requested distance by ±10%).
    public var distanceMeters: Double
    /// Estimated running duration in seconds (at an average pace of ~6 min/km).
    public var durationSeconds: Double
    /// Short human-readable label distinguishing this option, e.g. "Option A" or "Heading North".
    public var label: String

    public init(
        coordinates: [Coordinate],
        steps: [RouteStep],
        distanceMeters: Double,
        durationSeconds: Double,
        label: String
    ) {
        self.coordinates = coordinates
        self.steps = steps
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.label = label
    }
}

// MARK: - Strength Types

public struct StrengthExercise: Codable, Hashable, Sendable {
    public var name: String
    public var sets: Int
    public var reps: Int           // 0 = AMRAP (as many reps as possible)
    public var durationSeconds: Int?  // non-nil for timed exercises (plank, wall sit)
    public var targetWeight: String?  // "Bodyweight", "Light", "Moderate", "Heavy"
    public var notes: String?
    public var muscleGroups: [String]
    /// What the exercise is done with, stamped by ``StrengthLibrary``. It decides whether a
    /// set takes a weight and how big a step the next one is. Nil on plans built before it
    /// existed, which ``StrengthProgression/equipment(for:)`` fills in from the name.
    public var equipment: StrengthEquipment? = nil

    public init(
        name: String,
        sets: Int,
        reps: Int,
        durationSeconds: Int? = nil,
        targetWeight: String? = nil,
        notes: String? = nil,
        muscleGroups: [String],
        equipment: StrengthEquipment? = nil
    ) {
        self.name = name
        self.sets = sets
        self.reps = reps
        self.durationSeconds = durationSeconds
        self.targetWeight = targetWeight
        self.notes = notes
        self.muscleGroups = muscleGroups
        self.equipment = equipment
    }
}

/// Identified by name, which is unique within the library and within any one plan.
extension StrengthExercise: Identifiable {
    public var id: String { name }
}

public struct StrengthWorkoutPlan: Codable, Hashable, Sendable {
    public var focus: StrengthFocus
    public var exercises: [StrengthExercise]
    public var estimatedDurationMinutes: Int
    public var notes: String?

    public init(
        focus: StrengthFocus,
        exercises: [StrengthExercise],
        estimatedDurationMinutes: Int,
        notes: String? = nil
    ) {
        self.focus = focus
        self.exercises = exercises
        self.estimatedDurationMinutes = estimatedDurationMinutes
        self.notes = notes
    }
}

public struct CompletedStrengthSet: Codable, Hashable, Sendable {
    public var exerciseIndex: Int
    public var setIndex: Int
    public var completedReps: Int
    /// Free text, as sets were logged before weights were numbers ("40 kg", "Light"). Kept
    /// for those sets; ``StrengthProgression/legacyWeightKilograms(from:unit:)`` reads a
    /// number out of it where there is one.
    public var actualWeight: String?
    public var skipped: Bool
    /// The exercise's name when the set was logged. `exerciseIndex` points into the
    /// scheduled workout's plan, which a plan rebuild can replace or delete; the name is
    /// what keeps the set attached to the right exercise afterwards. Nil on older sets.
    public var exerciseName: String? = nil
    /// The load in kilograms, whatever the runner's unit: stored in one unit so it keeps
    /// its meaning when they flip the toggle, like `UserProfile.bodyMassKilograms`.
    public var weightKilograms: Double? = nil

    public init(
        exerciseIndex: Int,
        setIndex: Int,
        completedReps: Int,
        actualWeight: String? = nil,
        skipped: Bool,
        exerciseName: String? = nil,
        weightKilograms: Double? = nil
    ) {
        self.exerciseIndex = exerciseIndex
        self.setIndex = setIndex
        self.completedReps = completedReps
        self.actualWeight = actualWeight
        self.skipped = skipped
        self.exerciseName = exerciseName
        self.weightKilograms = weightKilograms
    }
}
