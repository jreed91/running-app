import SwiftUI

// MARK: - DayOfWeekPicker

struct DayOfWeekPicker: View {
    @Binding var selectedDays: Set<Int>
    /// Adds this week's day of the month under each day (onboarding's schedule step).
    var showsDates = false

    /// The model's indices are Monday-first (0 = Monday … 6 = Sunday, see
    /// `UserProfile.preferredRunDayIndices`); the calendar's symbols are Sunday-first,
    /// so index `i` reads symbol `(i + 1) % 7`. Localized rather than hard-coded English.
    private static func symbol(_ symbols: [String], forIndex index: Int) -> String {
        let position = (index + 1) % 7
        return symbols.indices.contains(position) ? symbols[position] : ""
    }

    var body: some View {
        let weekStart = Date().startOfWeek
        HStack(spacing: 6) {
            ForEach(0..<7) { index in
                DayToggleButton(
                    label: Self.symbol(Calendar.current.shortWeekdaySymbols, forIndex: index),
                    accessibilityName: Self.symbol(Calendar.current.weekdaySymbols, forIndex: index),
                    detail: showsDates
                        ? "\(Calendar.current.component(.day, from: weekStart.adding(days: index)))"
                        : nil,
                    isOn: selectedDays.contains(index)
                ) {
                    if selectedDays.contains(index) {
                        selectedDays.remove(index)
                    } else {
                        selectedDays.insert(index)
                    }
                }
            }
        }
    }
}

// MARK: - DayToggleButton

struct DayToggleButton: View {
    let label: String
    /// The full day name for VoiceOver ("Monday", not "Mon").
    var accessibilityName: String?
    /// A second line under the day, such as its date.
    var detail: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(label)
                    .font(.dsCaption.weight(.bold))
                if let detail {
                    Text(detail)
                        .font(.dsSubhead.weight(.bold).monospacedDigit())
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            // On is the route with `onFill` (white on orange is 2.8:1); off is a card.
            .foregroundStyle(isOn ? Color.onFill : Color.primary)
            .background {
                let shape = RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                if isOn {
                    shape.fill(.route)
                } else {
                    shape.fill(.surfaceSecondary)
                        .overlay(shape.strokeBorder(.cardStroke, lineWidth: 1))
                }
            }
            .appGlow(.subtle, color: .brand, isActive: isOn)
            .adaptiveAnimation(AppAnimation.snappy, value: isOn)
        }
        .buttonStyle(BouncyButtonStyle())
        .accessibilityLabel(accessibilityName ?? label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
