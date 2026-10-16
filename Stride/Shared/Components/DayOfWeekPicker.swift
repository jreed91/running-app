import SwiftUI

// MARK: - DayOfWeekPicker

struct DayOfWeekPicker: View {
    @Binding var selectedDays: Set<Int>

    private let labels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<7) { index in
                DayToggleButton(
                    label: labels[index],
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
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(.caption, design: .rounded, weight: .bold))
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
        }
        .buttonStyle(BouncyButtonStyle())
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
