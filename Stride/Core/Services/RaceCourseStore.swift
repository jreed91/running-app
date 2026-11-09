import Foundation

// MARK: - StoredRaceCourse

/// A course as saved on the device: the profile, and which race it was added for.
struct StoredRaceCourse: Codable, Sendable, Equatable {
    let course: RaceCourse
    /// The race's day as `yyyy-MM-dd`, the same day key the start time is stored against
    /// (``RaceStartTime``), so moving the race to another day drops the course with it.
    let raceDay: String
    /// The file's name as the runner picked it, shown when the GPX carries no name.
    let fileName: String?

    /// The course's name, else the file's without its extension.
    var displayName: String? {
        if let name = course.name { return name }
        guard let fileName else { return nil }
        let base = (fileName as NSString).deletingPathExtension
        return base.isEmpty ? nil : base
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Whether this course belongs to a race on `raceDate` over `distanceMeters`.
    func applies(toRaceOn raceDate: Date, distanceMeters: Double, calendar: Calendar = .current) -> Bool {
        raceDay == Self.dayKey(for: raceDate, calendar: calendar)
            && CoursePacing.matches(course, distanceMeters: distanceMeters)
    }
}

// MARK: - RaceCourseStore

/// The one course for the goal race, kept as a JSON file in Application Support.
///
/// A file rather than SwiftData: a course is a few tens of kilobytes that only the race
/// hub reads, and keeping it off the synced schema means no CloudKit migration for a
/// value the runner can import again in seconds. The cost is that it stays on this
/// iPhone: a reinstall or a second device starts without it. Holds one course; adding
/// another replaces it, since there is only ever one goal race.
enum RaceCourseStore {

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("RaceCourse", isDirectory: true)
            .appendingPathComponent("course.json")
    }

    static func load(from url: URL = defaultURL) -> StoredRaceCourse? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StoredRaceCourse.self, from: data)
    }

    static func save(_ stored: StoredRaceCourse, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(stored).write(to: url, options: [.atomic])
    }

    static func remove(at url: URL = defaultURL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Reads a picked file into a course for the race on `raceDate`. Opens the file's
    /// security scope itself, since a document picker hands over a URL outside the app's
    /// container.
    static func importCourse(from fileURL: URL, raceDate: Date, calendar: Calendar = .current) throws -> StoredRaceCourse {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw RaceCourseImportError.unreadable
        }
        let course = try RaceCourse.fromGPX(data)
        return StoredRaceCourse(
            course: course,
            raceDay: StoredRaceCourse.dayKey(for: raceDate, calendar: calendar),
            fileName: fileURL.lastPathComponent
        )
    }
}
