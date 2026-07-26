import SwiftUI
import WidgetKit

/// Stride's widget extension.
///
/// It exists for one thing today — the run-in-progress Live Activity (U5b) — which is why
/// this target had to be added at all: an `ActivityConfiguration` can only be declared by a
/// widget extension, not by the app. Home Screen and Lock Screen widgets would go here too.
@main
struct StrideWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RunLiveActivity()
    }
}
