import SwiftUI

// MARK: - HistoryFilter

/// What History is currently narrowed to, beyond the search term.
///
/// Search (U8) answers "find the tempo run", but not the two questions a log actually
/// grows into: *what did I do recently* and *where are the long ones*. Both are cheap to
/// answer in the fetch and impossible to answer by scrolling a reverse-chronological list
/// that pages twenty at a time.
///
/// Pure and `Equatable` so `HistoryView` can re-derive its queries from it the way it does
/// from `searchText`, and so the date arithmetic is testable without a store.
struct HistoryFilter: Equatable, Sendable {

    /// How far back the list reaches.
    enum DateRange: String, CaseIterable, Identifiable, Sendable {
        case allTime
        case month
        case threeMonths
        case year

        var id: String { rawValue }

        /// Days of history, or `nil` for "everything".
        var days: Int? {
            switch self {
            case .allTime:     return nil
            case .month:       return 30
            case .threeMonths: return 90
            case .year:        return 365
            }
        }

        var localizedName: String {
            switch self {
            case .allTime:     return String(localized: "Any date", comment: "History date filter: no date limit")
            case .month:       return String(localized: "Last 30 days", comment: "History date filter")
            case .threeMonths: return String(localized: "Last 3 months", comment: "History date filter")
            case .year:        return String(localized: "Last year", comment: "History date filter")
            }
        }

        /// The oldest date this range includes, or `nil` when it includes everything.
        func earliestDate(now: Date = Date(), calendar: Calendar = .current) -> Date? {
            guard let days else { return nil }
            return calendar.date(byAdding: .day, value: -days, to: now)
        }
    }

    /// The shortest run the list will show.
    ///
    /// The thresholds are the four race distances the app already plans for rather than
    /// round numbers in the runner's unit. They mean the same thing in both units — "at
    /// least a 10K" is a fact about the run, not about how it is displayed — so nothing
    /// here has to be converted, and an imperial runner is not offered a 5-mile filter
    /// that no training plan in the app has any concept of.
    enum MinimumDistance: String, CaseIterable, Identifiable, Sendable {
        case any
        case fiveK
        case tenK
        case halfMarathon
        case marathon

        var id: String { rawValue }

        /// The threshold in metres, or `nil` for no limit. Each sits slightly below the
        /// nominal distance, because a GPS trace of a 5K run routinely measures 4.97 km
        /// and a filter that hides it is wrong about what the runner did.
        var meters: Double? {
            switch self {
            case .any:          return nil
            case .fiveK:        return 4_900
            case .tenK:         return 9_800
            case .halfMarathon: return 20_800
            case .marathon:     return 41_800
            }
        }

        var localizedName: String {
            switch self {
            case .any:          return String(localized: "Any distance", comment: "History distance filter: no limit")
            case .fiveK:        return String(localized: "5K or longer", comment: "History distance filter")
            case .tenK:         return String(localized: "10K or longer", comment: "History distance filter")
            case .halfMarathon: return String(localized: "Half marathon or longer", comment: "History distance filter")
            case .marathon:     return String(localized: "Marathon", comment: "History distance filter")
            }
        }
    }

    var dateRange: DateRange = .allTime
    var minimumDistance: MinimumDistance = .any

    /// Whether anything is being filtered out. Drives the toolbar glyph and the
    /// "nothing matched" state, which has to offer a way back out.
    var isActive: Bool {
        dateRange != .allTime || minimumDistance != .any
    }

    /// A distance floor excludes strength sessions outright: they have no distance, so
    /// "10K or longer" cannot be true of one. Spelled out here rather than left implicit
    /// at the merge, because a filter silently dropping a whole workout type is exactly
    /// the kind of thing a reader should not have to infer.
    var includesStrengthWorkouts: Bool {
        minimumDistance == .any
    }
}

// MARK: - HistoryFilterMenu

/// The toolbar control for ``HistoryFilter``.
///
/// A `Menu` of two inline `Picker`s rather than a sheet: both axes are single-choice with
/// four or five options, which is what the menu form is for, and it keeps the whole filter
/// one tap from the list.
struct HistoryFilterMenu: View {
    @Binding var filter: HistoryFilter

    var body: some View {
        Menu {
            Picker("Date", selection: $filter.dateRange) {
                ForEach(HistoryFilter.DateRange.allCases) { range in
                    Text(range.localizedName).tag(range)
                }
            }
            Picker("Distance", selection: $filter.minimumDistance) {
                ForEach(HistoryFilter.MinimumDistance.allCases) { distance in
                    Text(distance.localizedName).tag(distance)
                }
            }
            if filter.isActive {
                Divider()
                Button("Clear Filters", systemImage: "arrow.counterclockwise") {
                    filter = HistoryFilter()
                }
            }
        } label: {
            // The filled variant is the platform's own "a filter is on" signal, and it
            // differs in shape as well as weight, so the state does not rest on colour.
            Image(systemName: filter.isActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filter workouts")
        .accessibilityValue(filter.isActive
                            ? "\(filter.dateRange.localizedName), \(filter.minimumDistance.localizedName)"
                            : String(localized: "Off", comment: "Spoken value of the History filter when nothing is filtered"))
        .accessibilityIdentifier("history.filter")
    }
}
