import Foundation

// MARK: - ProgressFilter

/// What the Progress page is showing: a period, a kind of run, and optionally one week,
/// month or day the runner drilled into by tapping the chart.
///
/// Progress used to be a column of cards with a range picker, plus five Explore pages
/// with filter rows of their own, so a choice made in one place never reached the
/// others. Now there is one filter, pinned at the top of the page, and every card
/// follows it.
///
/// Pure and `Sendable`, like ``VolumeExplorer``, whose windows and buckets it reuses.
public enum ProgressFilter {

    // MARK: Period

    /// How far back the page reaches.
    public enum Period: String, CaseIterable, Sendable {
        case month = "1M"
        case threeMonths = "3M"
        case sixMonths = "6M"
        case year = "1Y"
        case all = "All"

        public var window: VolumeExplorer.Window {
            switch self {
            case .month: return .month
            case .threeMonths: return .threeMonths
            case .sixMonths: return .sixMonths
            case .year: return .year
            case .all: return .all
            }
        }

        /// Days back from now, or `nil` for all time.
        public var days: Int? { window.days }

        /// Bars by week up to half a year, by month past that.
        public var grouping: VolumeExplorer.Grouping { window.defaultGrouping }
    }

    // MARK: Run type

    /// The kind of session a run was, as far as the filter cares.
    public enum RunKind: Sendable, Equatable {
        case easy
        case long
        case workout
        case race
        /// Anything else that counts as running (a run logged against a rest or
        /// strength day). Only "All runs" shows it.
        case other
    }

    /// Which runs the page counts.
    public enum RunType: String, CaseIterable, Sendable {
        case all
        case easyAndLong
        case workouts
        case races

        public func includes(_ kind: RunKind) -> Bool {
            switch self {
            case .all: return true
            case .easyAndLong: return kind == .easy || kind == .long
            case .workouts: return kind == .workout
            case .races: return kind == .race
            }
        }
    }

    // MARK: Drill-in

    /// The stretch of time a tapped bar covers.
    public static func drill(for bucket: VolumeExplorer.Bucket) -> DateInterval {
        DateInterval(start: bucket.start, end: max(bucket.start, bucket.end))
    }

    /// The bar a tap at `date` picks, if any: the one holding it, else the nearest.
    public static func bucket(at date: Date, in buckets: [VolumeExplorer.Bucket]) -> VolumeExplorer.Bucket? {
        VolumeExplorer.bucket(nearest: date, in: buckets)
    }

    /// Whether a run on `date` falls in the drill-in. Start inclusive, end exclusive, so
    /// a run at midnight on Monday belongs to the new week, as the bars count it.
    public static func contains(_ drill: DateInterval?, _ date: Date) -> Bool {
        guard let drill else { return true }
        return date >= drill.start && date < drill.end
    }
}
