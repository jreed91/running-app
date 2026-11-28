import Foundation

extension Comparable {
    /// This value pulled inside `range`.
    ///
    /// Was file-private in `ActiveRunView`, where the pace-zone indicator needed it, and
    /// was about to be written a second time for the coach's nutrition rates. Two private
    /// copies of a three-line clamp is how they drift, so it lives here once.
    func clamped(to range: ClosedRange<Self>) -> Self {
        max(range.lowerBound, min(self, range.upperBound))
    }
}
