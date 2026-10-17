import SwiftUI

// Part of `RunSummaryView` (D1).
// Small view types used only by the coach cards.

extension RunSummaryView {

    struct AICoachChatRequest: Identifiable {
        let id = UUID()
        let prompt: String?
    }

    struct SparkleShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX + rect.width * 0.12, y: rect.midY - rect.height * 0.12))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX + rect.width * 0.12, y: rect.midY + rect.height * 0.12))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX - rect.width * 0.12, y: rect.midY + rect.height * 0.12))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX - rect.width * 0.12, y: rect.midY - rect.height * 0.12))
            path.closeSubpath()
            return path
        }
    }
}
