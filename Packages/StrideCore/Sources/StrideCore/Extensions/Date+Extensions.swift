import Foundation

extension Date {
    /// Monday of the week containing this date.
    public var startOfWeek: Date {
        var cal = Calendar.current
        cal.firstWeekday = 2 // Monday
        let components = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: self)
        return cal.date(from: components) ?? self
    }

    public var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }

    public var isToday: Bool {
        Calendar.current.isDateInToday(self)
    }

    public var isTomorrow: Bool {
        Calendar.current.isDateInTomorrow(self)
    }

    public func adding(days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: self) ?? self
    }

    public func adding(weeks: Int) -> Date {
        Calendar.current.date(byAdding: .weekOfYear, value: weeks, to: self) ?? self
    }
}
